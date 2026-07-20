"""The macOS backend — NSPasteboard, Carbon, NSWorkspace, pynput, rumps.

This is app.py's platform half, lifted out behind platform_base.Backend and
otherwise left alone. The timings are empirically tuned, not guessed; the
modifier release before the copy chord is load-bearing, not hygiene. Both
are commented where they live.

Two things changed on the way out of app.py, both required by the contract:

  a failed probe now fails closed. secure_input_active() and frontmost_app()
  used to return False and "" on exception, which read downstream as "no
  password field" and "not on the blocklist" — a broken probe silently
  permitted a retype. They return Tri.UNKNOWN and UNKNOWN_APP now.

  the frontmost app is identified by bundle id. localizedName is localized
  and user-renamable, so a French system quietly stops matching "Keychain
  Access"; the name still rides along for display.

Importing this module never raises. Every framework import sits in a try at
the bottom of a flag, so a Linux runner gets Capabilities full of False and
a note saying which import failed, not a traceback out of AppKit.
"""

from __future__ import annotations

import ctypes
import inspect
import threading
import time
from typing import Any, Callable, List, Optional

from platform_base import (UNKNOWN_APP, AppRef, Backend, Capabilities, Tri)

# --- optional imports, none of which may take the module down --------------

_MISSING: List[str] = []

try:
    from AppKit import NSPasteboard, NSPasteboardTypeString, NSWorkspace
    _HAVE_APPKIT = True
except Exception as e:  # pyobjc absent, or present but unloadable off-macOS
    NSPasteboard = NSPasteboardTypeString = NSWorkspace = None  # type: ignore
    _HAVE_APPKIT = False
    _MISSING.append("AppKit unavailable ({}: {})".format(type(e).__name__, e))

try:
    from pynput import keyboard
    _HAVE_PYNPUT = True
except Exception as e:
    keyboard = None  # type: ignore
    _HAVE_PYNPUT = False
    _MISSING.append("pynput unavailable ({}: {})".format(type(e).__name__, e))

try:
    import rumps
    _HAVE_RUMPS = True
except Exception as e:
    rumps = None  # type: ignore
    _HAVE_RUMPS = False
    _MISSING.append("rumps unavailable ({}: {})".format(type(e).__name__, e))

try:
    import HIServices  # AXIsProcessTrusted, for the Accessibility grant
    _HAVE_HISERVICES = True
except Exception:
    HIServices = None  # type: ignore
    _HAVE_HISERVICES = False


# --- timings, carried over intact ------------------------------------------
# These were tuned against real apps. Changing them changes whether keystrokes
# land, so they live here as named constants rather than as literals someone
# feels free to tidy.

SETTLE_AFTER_MODIFIERS = 0.08   # let the user's real ⌥ key-up reach WindowServer
SETTLE_BEFORE_PASTE = 0.05      # after writing the clipboard, before ⌘V
SETTLE_AFTER_PASTE = 0.25       # let the target app consume the paste
BACKSPACE_PACE = 0.004          # fast apps drop backspaces sent back to back
LISTENER_SETTLE = 0.20          # long enough for a tapless listener thread to die

DEFAULT_HOTKEY = "<alt>+<space>"

# IOHIDCheckAccess request type and its three answers.
_HID_LISTEN_EVENT = 1
_HID_GRANTED, _HID_DENIED, _HID_UNKNOWN = 0, 1, 2


# --- the two TCC probes ----------------------------------------------------
# Both are check-only. The prompting variants (IOHIDRequestAccess,
# AXIsProcessTrustedWithOptions) raise a system dialog and are never called
# from a capability probe.

def _accessibility_trusted() -> Optional[bool]:
    """Is this process allowed to post events? None when we cannot ask.

    Without this grant CGEventPost silently drops everything — ⌘C just does
    nothing, and the caller sees a copy that never landed rather than a
    permission error. Worth distinguishing before blaming the selection.
    """
    if not _HAVE_HISERVICES:
        return None
    try:
        return bool(HIServices.AXIsProcessTrusted())
    except Exception:
        return None


def _input_monitoring() -> Optional[bool]:
    """Is this process allowed to observe keystrokes? None when undetermined.

    pynput's GlobalHotKeys is a full event tap, not a lightweight
    registration, so the hotkey path needs this as much as the watcher does.
    """
    try:
        import ctypes.util
        path = ctypes.util.find_library("IOKit")
        if not path:
            return None
        fn = ctypes.CDLL(path).IOHIDCheckAccess
        fn.restype = ctypes.c_int
        fn.argtypes = [ctypes.c_uint32]
        answer = fn(_HID_LISTEN_EVENT)
    except Exception:
        return None
    if answer == _HID_GRANTED:
        return True
    if answer == _HID_DENIED:
        return False
    return None  # not determined — the first tap attempt will prompt


def _may_tap() -> bool:
    """Should we even try to install an event tap?

    Denied is a definite no. Not-determined is a maybe, and we try, because
    refusing there would break the very first run before the user has been
    asked. Liveness is checked afterwards either way.
    """
    return _input_monitoring() is not False


def _may_post() -> bool:
    """Should we even try to send a keystroke?

    Unlike Input Monitoring there is no not-determined state to be generous
    about: nothing prompts for Accessibility, so False is not "the user has
    not been asked yet", it is "the next CGEventPost goes on the floor".
    Refusing there is the difference between a message and a mystery.

    None is the one genuinely unknown case — HIServices missing, so we
    cannot ask. We proceed, because refusing would disable a machine that
    works, and _probe says so in the notes rather than pretending we checked.
    """
    return _accessibility_trusted() is not False


def _grant_word(granted: Optional[bool]) -> str:
    return {True: "granted", False: "not granted"}.get(granted,
                                                       "could not be checked")


# --- Carbon secure input ---------------------------------------------------

_CARBON_PATHS = (
    "/System/Library/Frameworks/Carbon.framework/Carbon",
    "/System/Library/Frameworks/Carbon.framework/Frameworks"
    "/HIToolbox.framework/HIToolbox",
)

_secure_fn: Optional[Any] = None
_secure_lock = threading.Lock()


def _secure_input_fn() -> Optional[Any]:
    """IsSecureEventInputEnabled, bound once, or None if we cannot bind it.

    Never gate this on os.path.exists: since macOS 11 the framework lives
    only in the dyld shared cache, so the path CDLL happily resolves is not
    a file on disk. Probe by loading, not by looking.

    restype matters. The C function returns Boolean (unsigned char) and
    ctypes would otherwise read a full int, whose upper bits are formally
    undefined for a byte return — garbage there reads as truthy and would
    disable as-you-type forever.
    """
    global _secure_fn
    with _secure_lock:
        if _secure_fn is not None:
            return _secure_fn
        for path in _CARBON_PATHS:
            try:
                fn = ctypes.CDLL(path).IsSecureEventInputEnabled
                fn.restype = ctypes.c_bool
                fn.argtypes = []
                _secure_fn = fn
                return _secure_fn
            except Exception:
                continue
        return None


# --- the backend -----------------------------------------------------------

class MacBackend(Backend):
    """Everything Backspace needs from macOS.

    Capabilities report what this machine can do, not what macOS can do in
    principle: no pyobjc means no clipboard, no Carbon means no password
    signal and therefore no as-you-type. Permissions are deliberately not
    folded in here — TCC is undetermined until the first attempt, and a
    capability that flips to False before the user has ever been asked would
    disable the app on its first run. start_hotkey and start_watcher carry
    that check, and report False when a listener starts but can never fire.
    """

    def __init__(self) -> None:
        self._pb: Optional[Any] = None
        self._kb: Optional[Any] = None
        self._hotkeys: Optional[Any] = None
        self._watcher: Optional[Any] = None
        self._caps = self._probe()

    # --- introspection -----------------------------------------------------

    def _probe(self) -> Capabilities:
        has_secure = _secure_input_fn() is not None
        caps = Capabilities(
            name="macos",
            clipboard=_HAVE_APPKIT,
            clipboard_change_counter=_HAVE_APPKIT,
            synthetic_input=_HAVE_PYNPUT,
            global_hotkey=_HAVE_PYNPUT,
            keystroke_watch=_HAVE_PYNPUT,
            password_field_detection=has_secure,
            frontmost_app=_HAVE_APPKIT,
            tray_icon=_HAVE_RUMPS,
            tray_menu=_HAVE_RUMPS,
            notifications=_HAVE_RUMPS,
            notification_sound=_HAVE_RUMPS,
            default_hotkey=DEFAULT_HOTKEY if _HAVE_PYNPUT else "",
        )
        for line in _MISSING:
            caps.note(line)
        if not has_secure:
            caps.note("Carbon IsSecureEventInputEnabled could not be loaded, "
                      "so Backspace cannot tell when a password field has focus.")
        else:
            caps.note("Secure input detection is global, not per-field: a browser "
                      "password box does not enable it, so 'no' means 'no system "
                      "secure input', not 'no secret'.")
        if _HAVE_PYNPUT:
            caps.note("Both grants belong to the Python interpreter, not to "
                      "app.py, and are lost when the interpreter is upgraded.")
            caps.note("Input Monitoring (hotkey, watching keystrokes): {}."
                      .format(_grant_word(_input_monitoring())))
            trusted = _accessibility_trusted()
            note = "Accessibility (sending keystrokes): {}.".format(
                _grant_word(trusted))
            if trusted is False:
                note += (" Until it is granted every keystroke Backspace sends "
                         "is dropped without an error, so nothing will happen "
                         "at all. System Settings > Privacy & Security > "
                         "Accessibility.")
            elif trusted is None:
                note += (" HIServices is missing, so this one is a guess and "
                         "Backspace will try anyway.")
            caps.note(note)
        if _HAVE_RUMPS:
            caps.note("Notifications are best-effort: run unbundled there is no "
                      "registered bundle id and the daemon may drop banners "
                      "without error.")
        return caps

    @property
    def caps(self) -> Capabilities:
        return self._caps

    # --- clipboard ---------------------------------------------------------

    def _pasteboard(self) -> Optional[Any]:
        """The general pasteboard, cached. It is a proxy, not a snapshot, so
        holding it is safe."""
        if not _HAVE_APPKIT:
            return None
        if self._pb is None:
            try:
                self._pb = NSPasteboard.generalPasteboard()
            except Exception:
                return None
        return self._pb

    def clipboard_read(self) -> Optional[str]:
        """Clipboard text, or None when there is none to read.

        stringForType_ returns nil when the clipboard holds an image or files.
        That maps to None, not "" — app.py restores whatever this returns, and
        restoring "" over an image is how the image gets destroyed.
        """
        pb = self._pasteboard()
        if pb is None:
            return None
        try:
            value = pb.stringForType_(NSPasteboardTypeString)
        except Exception:
            return None
        return None if value is None else str(value)

    def clipboard_write(self, text: str) -> bool:
        pb = self._pasteboard()
        if pb is None:
            return False
        try:
            pb.clearContents()
            return bool(pb.setString_forType_(text, NSPasteboardTypeString))
        except Exception:
            return False

    def clipboard_counter(self) -> Optional[int]:
        """changeCount — bumped by clearContents, including our own writes.

        The only honest "did the clipboard change" signal. Comparing contents
        instead would call a real copy a no-op whenever the selection happens
        to equal what was already there.
        """
        pb = self._pasteboard()
        if pb is None:
            return None
        try:
            return int(pb.changeCount())
        except Exception:
            return None

    def capture_selection(self, timeout: float = 0.7) -> Optional[str]:
        """The base poll, plus the one failure macOS can actually name.

        Without Accessibility the copy chord is dropped, the change counter
        never moves, and the timeout is indistinguishable from an empty
        selection — so the user is told to select some text they already
        selected. The contract asks the backend that can tell the difference
        to say so, and this one can.
        """
        if _accessibility_trusted() is False:
            self.notify("Backspace can't send keystrokes yet. Grant "
                        "Accessibility to this interpreter in System Settings "
                        "> Privacy & Security > Accessibility.")
            return None
        return super().capture_selection(timeout)

    # --- sending keystrokes ------------------------------------------------

    def _controller(self) -> Optional[Any]:
        if not _HAVE_PYNPUT:
            return None
        if self._kb is None:
            try:
                self._kb = keyboard.Controller()
            except Exception:
                return None
        return self._kb

    def clear_modifiers(self) -> None:
        """Release ⌘⌥⌃⇧ from pynput's internal modifier set.

        Load-bearing. The default hotkey is ⌥Space, so the user is still
        physically holding ⌥ when the callback fires, and pynput builds every
        posted event's flags from that set — the copy chord would go out as
        ⌥⌘C and no app would answer. Releasing a key that is not down is free.
        """
        kb = self._controller()
        if kb is None:
            return
        for key in (keyboard.Key.cmd, keyboard.Key.alt,
                    keyboard.Key.ctrl, keyboard.Key.shift):
            try:
                kb.release(key)
            except Exception:
                pass

    def _chord(self, char: str) -> None:
        kb = self._controller()
        if kb is None:
            return
        try:
            with kb.pressed(keyboard.Key.cmd):
                kb.tap(char)
        except Exception:
            pass

    def copy(self) -> None:
        """⌘C, with the modifier release in front of it.

        The release lives here rather than at the call site so it cannot be
        forgotten by whichever path reaches for a copy — capture_selection
        included. It is idempotent, so a caller that also calls
        clear_modifiers() loses nothing.
        """
        self.clear_modifiers()
        time.sleep(SETTLE_AFTER_MODIFIERS)
        self._chord("c")

    def paste(self) -> None:
        self._chord("v")

    def backspace(self, n: int) -> None:
        kb = self._controller()
        if kb is None or n <= 0:
            return
        for _ in range(n):
            try:
                kb.tap(keyboard.Key.backspace)
            except Exception:
                return
            time.sleep(BACKSPACE_PACE)

    def can_type(self, text: str) -> bool:
        """Asked before the backspaces run, so the Accessibility check belongs
        here too: a retype that will be dropped must not be preceded by
        deletions that would not be."""
        return bool(self._caps.synthetic_input) and _may_post()

    def type_text(self, text: str) -> bool:
        kb = self._controller()
        # pynput reports success on a posted event, not a delivered one, so
        # without the grant this would return True having typed nothing.
        if kb is None or not _may_post():
            return False
        try:
            kb.type(text)
            return True
        except Exception:
            # partial output is possible here; the caller must assume nothing
            # about what landed, which is what False means
            return False

    # --- knowing where we are ----------------------------------------------

    def frontmost_app(self) -> AppRef:
        """Who has keyboard focus, keyed on bundle id.

        frontmostApplication is nil during app switches and CLI binaries have
        no bundle id, so either half can be missing. Both missing is
        UNKNOWN_APP, which AppRef.matches answers with Tri.UNKNOWN — an
        unidentified app is not an allowed one.
        """
        if not _HAVE_APPKIT:
            return UNKNOWN_APP
        try:
            app = NSWorkspace.sharedWorkspace().frontmostApplication()
            if app is None:
                return UNKNOWN_APP
            ident = app.bundleIdentifier()
            name = app.localizedName()
        except Exception:
            return UNKNOWN_APP
        ident = str(ident) if ident else None
        name = str(name) if name else None
        if not ident and not name:
            return UNKNOWN_APP
        return AppRef(ident=ident, name=name)

    def secure_input_active(self) -> Tri:
        """Is secure event input on anywhere in this login session?

        A global WindowServer mode, not a per-field query, and there is no
        public API for the latter. So YES is trustworthy and NO is narrow: a
        browser's password box does not enable it, and neither do native apps
        that never call EnableSecureEventInput. UNKNOWN when the probe itself
        is unavailable, because a probe we cannot run must not read as "safe".
        """
        if not self._caps.password_field_detection:
            return Tri.UNKNOWN
        fn = _secure_input_fn()
        if fn is None:
            return Tri.UNKNOWN
        try:
            return Tri.of(bool(fn()))
        except Exception:
            return Tri.UNKNOWN

    # --- hotkey and watcher lifecycle --------------------------------------

    def default_hotkey(self) -> str:
        return DEFAULT_HOTKEY if _HAVE_PYNPUT else ""

    def pretty_hotkey(self, hotkey: str) -> str:
        """⌥Space, the way a Mac user reads it."""
        for a, b in (("<cmd>", "⌘"), ("<alt>", "⌥"), ("<ctrl>", "⌃"),
                     ("<shift>", "⇧"), ("<space>", "Space"), ("+", "")):
            hotkey = hotkey.replace(a, b)
        return hotkey

    @staticmethod
    def _alive(listener: Any) -> bool:
        """Did the listener actually get a tap?

        Never ask listener.running. AbstractListener.run sets it True before
        calling _run, and the permission-denied path returns straight out of
        _run without ever calling stop — so running stays True on a thread
        that is already dead. is_alive, after a settle, is the truth.
        """
        time.sleep(LISTENER_SETTLE)
        try:
            return bool(listener.is_alive())
        except Exception:
            return False

    def start_hotkey(self, hotkey: str, callback: Callable[[], None]) -> bool:
        if not self._caps.hotkey_path or not hotkey:
            return False
        self.stop_hotkey()
        if not _may_tap():
            return False
        if not _may_post():
            # The listener would install and fire perfectly well, and every
            # chord it sent would be dropped. A hotkey that visibly does
            # nothing is worse than one that says it could not be registered,
            # and app.py's warning for False names the grant.
            return False
        try:
            listener = keyboard.GlobalHotKeys({hotkey: callback})
            listener.start()
        except Exception:
            return False
        if not self._alive(listener):
            # CGEventTapCreate returned NULL and the thread exited. pynput
            # logs a warning and raises nothing, so this is the only signal.
            try:
                listener.stop()
            except Exception:
                pass
            return False
        self._hotkeys = listener
        return True

    def stop_hotkey(self) -> None:
        listener, self._hotkeys = self._hotkeys, None
        if listener is not None:
            try:
                listener.stop()
            except Exception:
                pass

    def start_watcher(self, on_key: Callable[..., None]) -> bool:
        """Install the keystroke tap, or refuse to install anything at all.

        The refusal when as_you_type is unavailable is deliberately before
        construction. Not installed is a stronger promise than installed and
        filtered, and this is the hook that sees every key the user types.
        """
        if not self._caps.as_you_type:
            return False
        self.stop_watcher()
        if not _may_tap():
            return False

        wants_injected = self._takes_two(on_key)

        def on_press(key: Any, injected: bool = False) -> None:
            # macOS tags synthetic events with the posting process id, so our
            # own retypes can be dropped at the source rather than relying
            # only on app.py's flag and its timing window.
            if injected:
                return
            if wants_injected:
                on_key(key, injected)
            else:
                on_key(key)

        try:
            listener = keyboard.Listener(on_press=on_press)
            listener.start()
        except Exception:
            return False
        if not self._alive(listener):
            try:
                listener.stop()
            except Exception:
                pass
            return False
        self._watcher = listener
        return True

    def stop_watcher(self) -> None:
        listener, self._watcher = self._watcher, None
        if listener is not None:
            try:
                listener.stop()
            except Exception:
                pass

    @staticmethod
    def _takes_two(fn: Callable[..., None]) -> bool:
        """Does this callback want the injected flag? Assume not when unsure —
        calling with one argument is what every caller accepts."""
        try:
            params = inspect.signature(fn).parameters
        except (TypeError, ValueError):
            return False
        if any(p.kind is inspect.Parameter.VAR_POSITIONAL
               for p in params.values()):
            return True
        positional = [p for p in params.values()
                      if p.kind in (inspect.Parameter.POSITIONAL_ONLY,
                                    inspect.Parameter.POSITIONAL_OR_KEYWORD)]
        return len(positional) >= 2

    # --- talking to the user -----------------------------------------------

    def notify(self, message: str, title: str = "Backspace",
               sound: bool = False) -> bool:
        """Best-effort banner. Never the only channel for something that
        matters — unbundled, the daemon drops these silently.

        Marshalled to the main thread when we can: this is called from the
        background correction thread, and NSUserNotification off the main
        thread is tolerated rather than contractual.
        """
        if not self._caps.notifications:
            return False

        def show() -> None:
            rumps.notification(title, "", message, sound=bool(sound))

        if threading.current_thread() is threading.main_thread():
            try:
                show()
                return True
            except Exception:
                return False
        try:
            from PyObjCTools import AppHelper
            AppHelper.callAfter(show)
            return True
        except Exception:
            pass
        try:
            show()
            return True
        except Exception:
            return False

    # --- shutdown ----------------------------------------------------------

    def shutdown(self) -> None:
        self.stop_hotkey()
        self.stop_watcher()


if __name__ == "__main__":
    import backend

    print(backend.describe(MacBackend()))
