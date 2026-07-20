"""The Linux backend — X11 via pynput and xclip, Wayland mostly not at all.

Linux is the platform where the honest answer is "no" more often than "yes",
and where saying "yes" wrongly is worst. Three findings shape everything here:

  Wayland has no keystroke story. pynput's Listener and GlobalHotKeys both
  *construct successfully* under Wayland and then never fire for native
  Wayland windows, because XRecord only sees events routed to XWayland. No
  exception, no error, partial capture that looks like a working feature. You
  cannot detect this by trying it, so the gate is session type, decided from
  os.environ before anything is imported.

  There is no IsSecureEventInputEnabled. Not in X11, not in Wayland, not in
  any desktop environment — the API does not exist. So
  password_field_detection is False everywhere on Linux, and
  secure_input_active() returns UNKNOWN forever. That makes caps.as_you_type
  False on every Linux session, and start_watcher() therefore never installs
  a hook at all. That is the intended outcome, not a gap to close later.

  There is no clipboard change counter. X11 and Wayland have nothing like
  NSPasteboard.changeCount, so capture_selection() is overridden with the
  sentinel trick documented at that method.

Session detection order is WAYLAND_DISPLAY, then DISPLAY, then
XDG_SESSION_TYPE. Checking DISPLAY first is the classic bug: XWayland sets
DISPLAY too, so every Wayland session would be misread as X11 and would then
be handed the keystroke capabilities it silently cannot honour.

Importing this module never raises, on any platform, with nothing installed.
pynput in particular raises ImportError at *import* time on a headless Linux
box, so it is imported lazily and only when the session could actually use it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from typing import Any, Callable, List, Optional, Tuple

from platform_base import UNKNOWN_APP, AppRef, Backend, Capabilities, Tri

# --- timings ---------------------------------------------------------------
# Same shape as the macOS backend's, retuned for X11. Named constants so they
# read as tuned values rather than as literals someone feels free to tidy.

SETTLE_AFTER_MODIFIERS = 0.08   # let the user's real Ctrl key-up reach the server
SETTLE_BEFORE_PASTE = 0.05
SETTLE_AFTER_PASTE = 0.25
BACKSPACE_PACE = 0.004
LISTENER_SETTLE = 0.20          # long enough for a dead listener thread to die
SELECTION_POLL = 0.02           # sentinel poll interval, per the 0.7s budget
SENTINEL_SETTLE = 0.30          # how long to wait for our own sentinel write to
                                # become readable before giving up on the whole
                                # capture — see capture_selection()
TOOL_TIMEOUT = 2.0              # every subprocess. wl-copy *hangs* when the
                                # compositor refuses it focus, so this is not
                                # optional politeness.

# Alt+Space is the window menu in Mutter, KWin and most WMs and gets swallowed
# before it ever reaches us, so the macOS default cannot come along.
DEFAULT_HOTKEY = "<ctrl>+<alt>+<space>"

_HOTKEY_LABELS = {
    "<ctrl>": "Ctrl", "<alt>": "Alt", "<shift>": "Shift",
    "<cmd>": "Super", "<super>": "Super",
    "<space>": "Space", "<enter>": "Enter", "<tab>": "Tab",
}

# WM_CLASS classes, lowercased, of terminals that use Ctrl+Shift+C/V. In a
# terminal a plain Ctrl+C is SIGINT — sending it at a selection would kill the
# user's foreground job instead of copying. See _chord().
_TERMINALS = frozenset("""
    gnome-terminal-server konsole xterm uxterm alacritty kitty terminator
    xfce4-terminal tilix urxvt rxvt st wezterm foot guake terminology
    qterminal lxterminal mate-terminal deepin-terminal hyper contour ptyxis
    blackbox cool-retro-term xfce4-terminal-emulator
""".split())


# --- session detection: os.environ only, safe everywhere -------------------

def _detect_session() -> Tuple[str, str]:
    """(session, desktop) from the environment alone — no imports, no calls.

    Returns session as "x11", "wayland", "headless", or "none" when this is
    not a Linux machine at all. Everything downstream keys off this, so it
    runs first and cannot fail.

    XDG_SESSION_TYPE is authoritative when it is set, but it is missing under
    plenty of display managers, over ssh, in su-ed shells and in containers,
    so it corroborates rather than decides.
    """
    if not sys.platform.startswith("linux"):
        return "none", ""

    desktop = (os.environ.get("XDG_CURRENT_DESKTOP")
               or os.environ.get("DESKTOP_SESSION") or "").lower()
    declared = (os.environ.get("XDG_SESSION_TYPE") or "").lower()

    if os.environ.get("WAYLAND_DISPLAY"):
        return "wayland", desktop
    if os.environ.get("DISPLAY"):
        # DISPLAY without WAYLAND_DISPLAY is a real X server, unless the
        # session type says otherwise and we simply inherited a stale DISPLAY.
        if declared == "wayland":
            return "wayland", desktop
        return "x11", desktop
    if declared in ("x11", "wayland"):
        return declared, desktop
    return "headless", desktop


SESSION, DESKTOP = _detect_session()


# --- external tools --------------------------------------------------------
# Nothing on the Linux path is pure pip. xclip, xsel, wl-clipboard, xdotool
# and notify-send are all distro packages, so every one of them is probed for
# rather than required, and its absence turns off exactly one capability.

def _tool(*names: str) -> Optional[str]:
    """First of these on PATH, or None."""
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return None


def _run(argv: List[str], stdin: Optional[str] = None,
         capture: bool = True) -> Optional[str]:
    """Run a tool, return stdout, or None if it failed in any way.

    None covers "not installed", "non-zero exit" and "timed out" alike,
    because none of them is a clipboard value and the caller must not tell
    them apart by accident.

    capture=False is mandatory, not an optimisation, for anything that forks
    into the background. A pipe is only at EOF once every copy of its write
    end is closed, and the daemon xclip leaves behind inherits ours and never
    closes it — so subprocess.run would wait out the whole timeout on a tool
    that already succeeded. Nothing on the write path prints anything, so
    there is no output to give up.
    """
    try:
        proc = subprocess.run(
            argv,
            input=stdin.encode("utf-8") if stdin is not None else None,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=TOOL_TIMEOUT,
        )
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    if not capture:
        return ""
    try:
        return proc.stdout.decode("utf-8", "replace")
    except Exception:
        return None


# --- pynput, imported late and only where it could work --------------------

_pynput_lock = threading.Lock()
_pynput_state: Optional[Tuple[Any, str]] = None


def _pynput() -> Tuple[Any, str]:
    """(keyboard_module, error) — imported on first use, cached forever.

    Deliberately not a module-level import. pynput raises ImportError from its
    own backend loader when no X display is reachable, so a top-level import
    would take this module down on a CI runner. It also raises
    Xlib.error.DisplayNameError rather than ImportError for some malformed
    DISPLAY values, hence the bare except.
    """
    global _pynput_state
    with _pynput_lock:
        if _pynput_state is not None:
            return _pynput_state
        try:
            from pynput import keyboard as kb
            _pynput_state = (kb, "")
        except Exception as e:
            _pynput_state = (None, "{}: {}".format(type(e).__name__, e))
        return _pynput_state


# --- the backend -----------------------------------------------------------

class LinuxBackend(Backend):
    """What Backspace can do on this Linux session, and no more than that.

    Capabilities are decided once at construction from the session type and
    which tools are installed. The headline result: as-you-type is off on
    every Linux session, forever, because no Linux API can tell us a password
    field has focus; and on Wayland the hotkey path is off too, because
    synthetic input and global hotkeys through pynput are a silent no-op there.
    """

    def __init__(self) -> None:
        self._kb: Optional[Any] = None
        self._hotkeys: Optional[Any] = None
        self._watcher: Optional[Any] = None
        self.session = SESSION
        self.desktop = DESKTOP

        # tools, probed once
        self._xclip = self._xsel = None       # type: Optional[str]
        self._wl_copy = self._wl_paste = None  # type: Optional[str]
        self._xdotool = self._xprop = None    # type: Optional[str]
        self._notify_send = None              # type: Optional[str]

        self._caps = self._probe()

    # --- introspection -----------------------------------------------------

    def _probe(self) -> Capabilities:
        notes: List[str] = []

        if self.session == "none":
            caps = Capabilities(name="linux")
            caps.note("This is not a Linux session (sys.platform={!r}), so the "
                      "Linux backend can do nothing here.".format(sys.platform))
            return caps

        if self.session == "headless":
            caps = Capabilities(name="linux-headless")
            caps.note("No WAYLAND_DISPLAY and no DISPLAY, so there is no "
                      "graphical session to correct text in. The settings page "
                      "still works.")
            return caps

        # clipboard tools
        self._xclip = _tool("xclip")
        self._xsel = _tool("xsel")
        self._wl_copy = _tool("wl-copy")
        self._wl_paste = _tool("wl-paste")
        self._xdotool = _tool("xdotool")
        self._xprop = _tool("xprop")
        self._notify_send = _tool("notify-send")

        if self.session == "wayland":
            have_clipboard = bool(self._wl_copy and self._wl_paste)
            have_input = False
            pynput_error = ""
        else:
            have_clipboard = bool(self._xclip or self._xsel)
            kb, pynput_error = _pynput()
            have_input = kb is not None

        have_frontmost = (self.session == "x11"
                          and bool(self._xdotool or self._xprop))
        tray_icon, tray_menu, tray_note = self._probe_tray()

        caps = Capabilities(
            name="linux-" + self.session,
            clipboard=have_clipboard,
            # No X11 or Wayland equivalent of NSPasteboard.changeCount exists.
            # capture_selection() is overridden to compensate.
            clipboard_change_counter=False,
            synthetic_input=have_input,
            global_hotkey=have_input,
            keystroke_watch=have_input,
            # The hard no. There is no Linux API for this at all.
            password_field_detection=False,
            frontmost_app=have_frontmost,
            tray_icon=tray_icon,
            tray_menu=tray_menu,
            notifications=bool(self._notify_send),
            notification_sound=False,
            default_hotkey=DEFAULT_HOTKEY if have_input else "",
        )

        # --- the notes the settings page shows ---
        caps.note("Linux has no way to tell when a password field has focus — "
                  "no X11 API, no Wayland protocol, nothing in any desktop "
                  "environment. As-you-type correction is therefore switched "
                  "off on Linux permanently, not just disabled by default.")

        if self.session == "wayland":
            caps.note("This is a Wayland session ({}). Wayland deliberately "
                      "stops background apps from reading keystrokes or "
                      "injecting them, so the hotkey correction path cannot "
                      "work here. Log into an X11 session to use it."
                      .format(self.desktop or "unknown desktop"))
            caps.note("pynput would appear to start under Wayland and then "
                      "silently never fire, so Backspace refuses to arm it "
                      "rather than claim a hotkey it cannot deliver.")
            if not have_clipboard:
                caps.note("wl-copy and wl-paste (the wl-clipboard package) are "
                          "not installed, so the clipboard is unreadable here.")
        else:
            if not have_input:
                caps.note("pynput is unavailable, so Backspace cannot send or "
                          "watch keystrokes here ({}).".format(pynput_error))
            if not have_clipboard:
                caps.note("Neither xclip nor xsel is installed, so Backspace "
                          "cannot read the clipboard. Install one of them.")
            if not have_frontmost:
                caps.note("Neither xdotool nor xprop is installed, so Backspace "
                          "cannot tell which app has focus and treats every app "
                          "as unidentified.")

        if caps.hotkey_path:
            caps.note("In terminals the copy chord is Ctrl+Shift+C, not Ctrl+C "
                      "— Ctrl+C is SIGINT. Backspace switches chords for "
                      "terminals it recognises by window class, but it cannot "
                      "recognise a terminal embedded inside an editor.")
            caps.note("Whatever Backspace last put on the clipboard is lost "
                      "when Backspace quits, unless a clipboard manager such as "
                      "Klipper or GPaste is running. That is how X11 selections "
                      "work: the owning process serves the data.")
            caps.note("Only text is saved and restored around a correction. An "
                      "image or rich content on the clipboard is left alone "
                      "when it can be, but may not survive.")
        if tray_note:
            caps.note(tray_note)
        elif not tray_icon:
            caps.note("No system tray available. Backspace keeps running and "
                      "the settings page stays at http://127.0.0.1:8765.")
        if not caps.notifications:
            caps.note("notify-send is not installed, so messages go to stderr "
                      "instead of appearing as desktop notifications.")

        for line in notes:
            caps.note(line)
        return caps

    def _probe_tray(self) -> Tuple[bool, bool, str]:
        """(icon, menu, note). pystray picks its backend at *import* time and
        the xorg fallback supports no menus at all, so the only truthful way
        to answer is to import it and read what it chose."""
        try:
            import importlib.util
            if importlib.util.find_spec("pystray") is None:
                return False, False, ("pystray is not installed, so there is no "
                                      "tray icon. Backspace runs headless and "
                                      "serves its settings page as usual.")
        except Exception:
            return False, False, ""

        try:
            import pystray
        except Exception as e:
            return False, False, ("pystray is installed but could not load a "
                                  "tray backend ({}: {}), so Backspace runs "
                                  "without a tray icon."
                                  .format(type(e).__name__, e))

        has_menu = bool(getattr(pystray.Icon, "HAS_MENU", False))
        if not has_menu:
            return True, False, ("The available tray backend supports an icon "
                                 "but no menu, so use the settings page at "
                                 "http://127.0.0.1:8765 to change anything.")
        return True, True, ""

    @property
    def caps(self) -> Capabilities:
        return self._caps

    # --- clipboard ---------------------------------------------------------

    def clipboard_read(self) -> Optional[str]:
        """Clipboard text, or None when we could not read text out of it.

        None here also covers "the clipboard holds an image", because xclip
        exits non-zero when the STRING target is unavailable and we cannot
        tell that from a real failure. Conflating them the other way — calling
        it "" — would let a caller restore an empty string over the user's
        image, so the conservative reading is the safe one.
        """
        if not self._caps.clipboard:
            return None
        if self.session == "wayland":
            return _run([self._wl_paste, "--no-newline", "--type", "text/plain"])
        if self._xclip:
            return _run([self._xclip, "-o", "-selection", "clipboard"])
        if self._xsel:
            return _run([self._xsel, "--clipboard", "--output"])
        return None

    def clipboard_write(self, text: str) -> bool:
        """Put text on the CLIPBOARD selection — never PRIMARY.

        The tool forks and stays alive to serve the selection, which is what
        ICCCM requires of an owner; that background process is the reason the
        content outlives this call at all. It is also why every branch here
        passes capture=False — see _run.

        True means the tool exited cleanly, which is one step short of "the
        clipboard now reads back as text": ownership is taken by the forked
        child, after we have already returned. capture_selection() waits for
        that separately.
        """
        if not self._caps.clipboard:
            return False
        if self.session == "wayland":
            return _run([self._wl_copy, "--type", "text/plain"], text,
                        capture=False) is not None
        if self._xclip:
            return _run([self._xclip, "-i", "-selection", "clipboard"], text,
                        capture=False) is not None
        if self._xsel:
            return _run([self._xsel, "--clipboard", "--input"], text,
                        capture=False) is not None
        return False

    def clipboard_counter(self) -> Optional[int]:
        """Always None. Neither X11 nor Wayland has a change counter of any
        kind — this is not a missing tool, there is nothing to call. The
        contract's None is exactly this case, and capture_selection() below
        is the override it asks for."""
        return None

    def capture_selection(self, timeout: float = 0.7) -> Optional[str]:
        """Send the copy chord and return what the user had selected.

        The sentinel trick, because there is no change counter to poll:

          1. save whatever text is on the clipboard now
          2. write a unique sentinel over it
          3. wait until the sentinel actually reads back
          4. send the copy chord
          5. poll until the clipboard is no longer the sentinel
          6. still the sentinel at the deadline means the copy never landed —
             nothing was selected, or the app ignored the chord — so restore
             the saved text and report None

        Step 3 is not politeness. xclip takes ownership of the selection in
        the child it forked, so clipboard_write() returns before the sentinel
        is readable, and a read in that window still returns the *previous*
        clipboard — which differs from the sentinel and would be captured as
        the user's selection. The correction would then be computed from
        whatever they last copied and pasted over what they actually
        highlighted. If the sentinel never appears we cannot run the test at
        all, and an untestable capture is refused rather than guessed.

        Comparing against a sentinel rather than against the saved text
        matters: a user who copies the same words that were already on the
        clipboard would otherwise look like a copy that never happened.

        A read of None during the poll is treated as "not yet", not as a
        change, because a half-completed ownership transfer reads as None too.
        Ownership moves asynchronously, so the sentinel can outlive a
        *successful* copy by tens of milliseconds; the 0.7s default is sized
        for that and a much shorter one produces false "nothing selected".

        Clobbers the clipboard, as the contract says. The restore on failure
        is ours, so a refused copy does not leave a UUID on the user's
        clipboard.
        """
        if not self._caps.clipboard or not self._caps.synthetic_input:
            return None

        saved = self.clipboard_read()
        sentinel = "backspace-sentinel-" + uuid.uuid4().hex
        if not self.clipboard_write(sentinel):
            return None

        settled = time.time() + SENTINEL_SETTLE
        while self.clipboard_read() != sentinel:
            if time.time() >= settled:
                self.clipboard_write(saved if saved is not None else "")
                return None
            time.sleep(SELECTION_POLL)

        self.copy()
        deadline = time.time() + timeout
        captured: Optional[str] = None
        while time.time() < deadline:
            now = self.clipboard_read()
            if now is not None and now != sentinel:
                captured = now
                break
            time.sleep(SELECTION_POLL)

        if captured is None:
            # saved is None when the clipboard was empty, held an image, or
            # was simply unreadable — xclip exits non-zero for all three and
            # cannot tell them apart. Whatever it was is already gone, because
            # the sentinel write took ownership. So clear rather than restore:
            # an empty clipboard is a worse outcome than the user's text but a
            # far better one than a stray UUID they later paste into something.
            self.clipboard_write(saved if saved is not None else "")
            return None

        return captured if captured.strip() else None

    # --- sending keystrokes ------------------------------------------------

    def _controller(self) -> Optional[Any]:
        if not self._caps.synthetic_input:
            return None
        if self._kb is None:
            kb, _ = _pynput()
            if kb is None:
                return None
            try:
                self._kb = kb.Controller()
            except Exception:
                return None
        return self._kb

    def clear_modifiers(self) -> None:
        """Release Ctrl, Alt, Shift and Super from pynput's modifier set.

        Load-bearing, same as on macOS: the user is still physically holding
        the hotkey when the callback fires, and pynput builds every synthetic
        event's modifier state from that set, so the copy chord would go out
        as Ctrl+Alt+C and nothing would answer. Super replaces macOS's Cmd —
        releasing Key.cmd on Linux is a no-op and would leave Super stuck.
        """
        ctrl = self._controller()
        if ctrl is None:
            return
        kb, _ = _pynput()
        if kb is None:
            return
        for key in (kb.Key.ctrl, kb.Key.alt, kb.Key.shift, kb.Key.cmd):
            try:
                ctrl.release(key)
            except Exception:
                pass

    def _in_terminal(self) -> bool:
        """Does a terminal emulator have focus? False when we cannot tell.

        False is the right default here even though it is fail-open: the
        recognised-terminal case only *changes which chord we send*, and
        guessing Ctrl+Shift+C at a non-terminal does nothing at all, whereas
        this same guess is checked against a real list before we ever risk a
        plain Ctrl+C being read as SIGINT.
        """
        if not self._caps.frontmost_app:
            return False
        app = self.frontmost_app()
        return bool(app.ident and app.ident.lower() in _TERMINALS)

    def _chord(self, char: str) -> None:
        ctrl = self._controller()
        if ctrl is None:
            return
        kb, _ = _pynput()
        if kb is None:
            return
        keys = [kb.Key.ctrl]
        if self._in_terminal():
            # Ctrl+C in a terminal is SIGINT, not copy. Ctrl+Shift+C is copy
            # in GNOME Terminal, Konsole and every VTE terminal.
            keys.append(kb.Key.shift)
        try:
            if len(keys) == 2:
                with ctrl.pressed(keys[0]):
                    with ctrl.pressed(keys[1]):
                        ctrl.tap(char)
            else:
                with ctrl.pressed(keys[0]):
                    ctrl.tap(char)
        except Exception:
            pass

    def copy(self) -> None:
        """Ctrl+C — or Ctrl+Shift+C in a terminal — with the modifier release
        in front of it, so no call site can forget it."""
        self.clear_modifiers()
        time.sleep(SETTLE_AFTER_MODIFIERS)
        self._chord("c")

    def paste(self) -> None:
        self._chord("v")

    def backspace(self, n: int) -> None:
        ctrl = self._controller()
        if ctrl is None or n <= 0:
            return
        kb, _ = _pynput()
        if kb is None:
            return
        for _ in range(n):
            try:
                ctrl.tap(kb.Key.backspace)
            except Exception:
                return
            time.sleep(BACKSPACE_PACE)

    def type_text(self, text: str) -> bool:
        ctrl = self._controller()
        if ctrl is None:
            return False
        try:
            ctrl.type(text)
            return True
        except Exception:
            # XTEST may have emitted part of the string before failing, so the
            # caller must assume nothing landed — that is what False means.
            return False

    # --- knowing where we are ----------------------------------------------

    def frontmost_app(self) -> AppRef:
        """Which app has focus, keyed on WM_CLASS.

        WM_CLASS and not the window title. The blocklist holds application
        names, and titles change constantly ("Inbox (3) — Firefox") so they
        would match unpredictably; they also carry document names and URLs,
        which is content we have no reason to hold. WM_CLASS is the stable
        application identifier and is all we take.

        UNKNOWN_APP on any failure, and always under Wayland: GNOME exposes
        no protocol for an unprivileged client to learn the focused window,
        and the workarounds need a Shell extension we cannot assume. An
        unidentified app must read as unidentified, never as an empty name
        that quietly passes a blocklist check.
        """
        if not self._caps.frontmost_app:
            return UNKNOWN_APP

        if self._xdotool:
            out = _run([self._xdotool, "getactivewindow", "getwindowclassname"])
            if out:
                name = out.strip().splitlines()[0].strip() if out.strip() else ""
                if name:
                    return AppRef(ident=name.lower(), name=name)

        if self._xprop:
            name = self._xprop_class()
            if name:
                return AppRef(ident=name.lower(), name=name)

        return UNKNOWN_APP

    def _xprop_class(self) -> Optional[str]:
        """WM_CLASS of the _NET_ACTIVE_WINDOW, via two xprop calls.

        Needs an EWMH-compliant window manager to have set
        _NET_ACTIVE_WINDOW. Essentially all modern ones do; a few minimal
        ones do not, and there we simply stay unidentified.
        """
        root = _run([self._xprop, "-root", "_NET_ACTIVE_WINDOW"])
        if not root or "0x" not in root:
            return None
        try:
            window_id = "0x" + root.split("0x")[-1].strip().split()[0].strip(",")
        except Exception:
            return None

        out = _run([self._xprop, "-id", window_id, "WM_CLASS"])
        if not out or '"' not in out:
            return None
        # WM_CLASS(STRING) = "instance", "Class" — the second is the app class
        parts = [p for p in out.split('"')[1::2] if p]
        if not parts:
            return None
        return parts[-1]

    def secure_input_active(self) -> Tri:
        """Always UNKNOWN on Linux, and that is a permanent answer.

        There is no equivalent of IsSecureEventInputEnabled anywhere on this
        platform. X11 has no notion of secure input — any client with an
        XRecord connection sees every keystroke, passwords included — and
        Wayland exposes nothing either.

        AT-SPI2 was the one candidate: ATSPI_ROLE_PASSWORD_TEXT exists and can
        be watched over D-Bus. It is not enough. The accessibility bus is often
        absent outside GNOME, querying Electron apps forces accessibility on at
        a real performance cost the user never agreed to, and — decisively — a
        sudo or ssh prompt in a terminal is not a password widget at all. It is
        a VTE text area, reported as role "terminal". The single most dangerous
        case on a developer's machine is exactly the one AT-SPI cannot see.

        Returning NO here would be the precise lie the project forbids, so this
        returns UNKNOWN, which makes safe_to_retype() block forever.
        """
        return Tri.UNKNOWN

    # --- hotkey and watcher lifecycle --------------------------------------

    def default_hotkey(self) -> str:
        return DEFAULT_HOTKEY if self._caps.global_hotkey else ""

    def pretty_hotkey(self, hotkey: str) -> str:
        """Ctrl+Alt+Space, the way a Linux user reads it.

        Overridden rather than inherited because the base implementation
        strips "+" last, which is right for the macOS glyph form and turns
        "Ctrl+Alt+Space" into "CtrlAltSpace" here.
        """
        parts = [p for p in hotkey.split("+") if p]
        out = []
        for part in parts:
            label = _HOTKEY_LABELS.get(part.lower())
            if label is None:
                bare = part.strip("<>")
                label = bare.capitalize() if len(bare) > 1 else bare.upper()
            out.append(label)
        return "+".join(out)

    def _alive(self, listener: Any) -> bool:
        """Did the listener thread survive? Never ask listener.running — it is
        set True before the backend is even tried and stays True on a thread
        that has already returned out of _run."""
        time.sleep(LISTENER_SETTLE)
        try:
            return bool(listener.is_alive())
        except Exception:
            return False

    def start_hotkey(self, hotkey: str, callback: Callable[[], None]) -> bool:
        """Register the global hotkey. X11 only.

        Under Wayland caps.global_hotkey is already False, so this returns
        before construction — which is the whole point. GlobalHotKeys would
        start cleanly there and then never fire, and reporting True for that
        is how the app ends up claiming to be armed while doing nothing. The
        legitimate Wayland answer is the XDG GlobalShortcuts portal, which is
        a D-Bus interface pynput cannot reach and is not implemented here.
        """
        if not self._caps.hotkey_path or not hotkey:
            return False
        self.stop_hotkey()
        kb, _ = _pynput()
        if kb is None:
            return False
        try:
            listener = kb.GlobalHotKeys({hotkey: callback})
            listener.start()
        except Exception:
            # a malformed hotkey string, or no X connection from this thread
            return False
        if not self._alive(listener):
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
        """Always False on Linux, and nothing is installed.

        caps.as_you_type is False on every Linux session because
        password_field_detection is False on every Linux session, so this
        returns at the first line, every time. It is written as the same guard
        the other backends use rather than as `return False` so that the
        reason travels with it: the exposure here is the keyboard hook itself,
        and never installing it is a stronger promise than installing it and
        filtering afterwards.

        Even if a password signal appeared tomorrow, X11's XRecord captures
        every keystroke globally and Wayland captures an unpredictable subset,
        and a sentence buffered half from a GTK window and half from an
        XWayland one is garbage that the backspace-and-retype path would then
        act on.
        """
        if not self._caps.as_you_type:
            return False
        return False  # unreachable today; kept so the guard above is the reason

    def stop_watcher(self) -> None:
        listener, self._watcher = self._watcher, None
        if listener is not None:
            try:
                listener.stop()
            except Exception:
                pass

    # --- talking to the user -----------------------------------------------

    def notify(self, message: str, title: str = "Backspace",
               sound: bool = False) -> bool:
        """Best-effort desktop notification via notify-send.

        sound is accepted and ignored — libnotify has no portable concept of
        one, and caps.notification_sound says False rather than pretending.
        Absent on minimal systems and in most containers, so this is never
        the only channel for anything the user has to see.
        """
        if not self._caps.notifications:
            return False
        return _run([self._notify_send, "-a", "Backspace",
                     title, message]) is not None

    # --- shutdown ----------------------------------------------------------

    def shutdown(self) -> None:
        self.stop_hotkey()
        self.stop_watcher()


if __name__ == "__main__":
    import backend

    print(backend.describe(LinuxBackend()))
