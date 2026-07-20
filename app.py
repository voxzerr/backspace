"""Backspace — fixes your typing, on whatever machine you are on.

Two ways to use it:

  Hotkey     select any text, press the hotkey, it is replaced corrected.
  As you go  optional. Watches what you type and quietly fixes each sentence
             as you finish it. Off by default, and refused outright on any
             platform that cannot tell when a password field has focus.

Nothing in this file knows what operating system it is running on. Every
keystroke, clipboard read and focus check goes through backend.get_backend(),
which returns a Backend whose capabilities you ask before you ask it to do
anything. On a machine with no libraries at all that is a NullBackend, and the
app still starts, still serves its settings page, and says why each feature is
off instead of dying at an import.

  python3 app.py                      tray icon if there is one, otherwise headless
  python3 app.py --headless           hotkey + settings server, no tray, no display
  python3 app.py --doctor             capability report, then exit
  python3 app.py --fix "some txt"     correct a string and print it, then exit
  echo "some txt" | python3 app.py --fix
"""

from __future__ import annotations

import argparse
import json
import queue
import sys
import threading
import time
import webbrowser
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import backend as backend_mod
import server
from engine import Corrector, summary
from platform_base import AppRef, Backend, Tri

HOME = Path.home() / ".backspace"
CONFIG_PATH = HOME / "config.json"
PORT = server.PORT
MODES = server.MODES

# Pacing. These are app-level, not platform-level: how long to let the user's
# own modifier key-up land before we send a chord, and how long to let the
# target application consume a paste before we take the clipboard back.
SETTLE_AFTER_MODIFIERS = 0.08
SETTLE_BEFORE_PASTE = 0.05
SETTLE_AFTER_PASTE = 0.25
SETTLE_BEFORE_RETYPE = 0.02
SETTLE_AFTER_RETYPE = 0.05

# As-you-type guards, unchanged from the macOS-only version.
MIN_SENTENCE_CHARS = 12
MIN_SENTENCE_WORDS = 3
MAX_LENGTH_DRIFT = 12
MAX_BUFFER = 400
CODE_CHARS = "{}()[]<>=|$\\/`_"

# How long a buffer may sit untouched before we stop believing it. A mouse
# click moves the caret and produces no key event, so when the backend has no
# field-level token this timeout is the only thing that catches a caret jump
# inside one app — a click almost always costs a pause, and a sentence typed in
# one go almost never does. Kept short on purpose: forgetting costs one missed
# correction; remembering wrongly costs the user a paragraph.
BUFFER_MAX_IDLE = 2.5

# Modifiers that are held down *while* you type ordinary text. Anything else
# unrecognised clears the buffer, because it may have moved the caret or
# pasted text we never saw.
PASSIVE_MODIFIERS = frozenset((
    "shift", "shift_l", "shift_r", "caps_lock",
))

# One list per platform, because AppRef.matches() compares against the bundle
# id on macOS, the lowercased exe basename on Windows and WM_CLASS on X11 — a
# single mixed list is two thirds entries that can never match, offered in the
# settings page as if they did something.
#
# Browsers are on all three. macOS's secure input probe is global rather than
# per-field, so a password box on a login page reads as Tri.NO, and this list
# is the only thing between as-you-type and a passphrase long enough to pass
# the three-word gate.
PLATFORM_BLOCKLIST: Dict[str, List[str]] = {
    "macos": [
        "Terminal", "com.apple.Terminal", "iTerm2", "com.googlecode.iterm2",
        "1Password", "com.1password", "com.agilebits.onepassword",
        "Keychain Access", "com.apple.keychainaccess",
        "Xcode", "com.apple.dt.Xcode", "Steam", "com.valvesoftware.steam",
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "org.chromium.Chromium",
        "company.thebrowser.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ],
    "windows": [
        "cmd.exe", "powershell.exe", "pwsh.exe", "windowsterminal.exe",
        "conhost.exe", "putty.exe", "mintty.exe", "keepass.exe",
        "keepassxc.exe", "1password.exe", "bitwarden.exe", "mstsc.exe",
        "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe",
        "vivaldi.exe",
    ],
    "linux": [
        "gnome-terminal", "konsole", "xterm", "alacritty", "kitty",
        "terminator", "xfce4-terminal", "keepassxc", "seahorse",
        "org.remmina.Remmina", "google-chrome", "chromium", "firefox",
        "brave-browser", "microsoft-edge", "vivaldi-stable",
    ],
}

BASE_DEFAULTS: Dict[str, Any] = {
    "hotkey": "",                  # filled from the backend on first load
    "mode": "fix",                 # fix | clean | polish
    "model": "qwen2.5:3b",
    "as_you_type": False,
    "sound": False,
    "blocklist": [],               # filled from the backend on first load
    "blocklist_defaults": [],      # which defaults this config has already seen
    "allowlist": [],
}


def default_blocklist(backend: Optional[Backend] = None) -> List[str]:
    """The blocklist that can actually match on the platform we are on.

    A backend that ships its own list wins for its own entries —
    platform_win.py knows Windows exe names better than this file does — and
    the browsers above are added either way. With no backend at all we hand
    back every platform's list, because a name that cannot match costs
    nothing and a missing one costs a password.
    """
    key = backend.caps.name if backend is not None else ""
    names: List[str] = list(_backend_blocklist(backend))
    known = PLATFORM_BLOCKLIST.get(key)
    if known is None:
        known = [n for group in PLATFORM_BLOCKLIST.values() for n in group]
    for name in known:
        if name not in names:
            names.append(name)
    return names


def _backend_blocklist(backend: Optional[Backend]) -> List[str]:
    """Whatever the platform module offers, on the instance or beside it.

    platform_win.default_blocklist() is a module-level function today; the
    Backend contract has no slot for one, so this looks in both places rather
    than leaving a better list than ours unused.
    """
    if backend is None:
        return []
    fn = getattr(backend, "default_blocklist", None)
    if not callable(fn):
        module = sys.modules.get(type(backend).__module__)
        fn = getattr(module, "default_blocklist", None)
    if not callable(fn):
        return []
    try:
        return [str(n) for n in fn()]
    except Exception:
        return []


# --- config ----------------------------------------------------------------

def default_config(backend: Optional[Backend] = None) -> Dict[str, Any]:
    """Defaults with the hotkey filled in for this platform.

    ⌥Space on macOS, Ctrl+Alt+Space on Windows and Linux where Alt+Space is
    already the window menu. Hardcoding the macOS string bound a hotkey that
    does nothing on two of the three platforms.
    """
    cfg = dict(BASE_DEFAULTS)
    blocked = default_blocklist(backend)
    cfg["blocklist"] = list(blocked)
    cfg["blocklist_defaults"] = list(blocked)
    cfg["allowlist"] = []
    if backend is not None:
        cfg["hotkey"] = backend.default_hotkey()
    return cfg


def load_config(backend: Optional[Backend] = None) -> Dict[str, Any]:
    cfg = default_config(backend)
    try:
        HOME.mkdir(exist_ok=True)
        if CONFIG_PATH.exists():
            cfg.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        # An unreadable config is not a reason to refuse to start. The defaults
        # are safe: as-you-type off, offline mode.
        pass
    if not cfg.get("hotkey") and backend is not None:
        cfg["hotkey"] = backend.default_hotkey()
    return _merge_new_defaults(cfg, default_blocklist(backend))


def _merge_new_defaults(cfg: Dict[str, Any],
                        blocked: List[str]) -> Dict[str, Any]:
    """Let a new default entry reach an install that already has a config.

    Saved settings win over defaults, so the browsers added after the first
    release would otherwise never arrive on the machines that need them.
    blocklist_defaults records what this config has already been offered, so
    an entry the user deliberately deleted stays deleted and only genuinely
    new ones are added.
    """
    seen = list(cfg.get("blocklist_defaults") or [])
    names = list(cfg.get("blocklist") or [])
    for name in blocked:
        if name not in seen and name not in names:
            names.append(name)
    cfg["blocklist"] = names
    cfg["blocklist_defaults"] = list(blocked)
    return cfg


def save_config(cfg: Dict[str, Any]) -> None:
    try:
        HOME.mkdir(exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    except OSError:
        pass


# --- the core, which knows nothing about any operating system ---------------

class Backspace:
    """Config, the two correction paths, and the safety gates.

    Every platform touch goes through self.backend, so this class can be
    constructed with a NullBackend or a fake in a test and exercised end to
    end without a display, a permission grant, or a single real keystroke.
    """

    def __init__(self, backend: Backend, cfg: Optional[Dict[str, Any]] = None):
        self.backend = backend
        self.cfg = cfg if cfg is not None else load_config(backend)
        self.corrector = Corrector(model=self.cfg["model"],
                                   allowlist=set(self.cfg["allowlist"]))
        self.last = {"before": "", "after": ""}
        self.count = 0
        self.busy = threading.Lock()
        self.buffer: List[str] = []
        self.buffer_app: Optional[AppRef] = None
        self.buffer_field: Optional[str] = None
        self.buffer_time = 0.0
        self.notices: List[str] = []
        self._own_keystrokes = False
        self._jobs: "queue.Queue" = queue.Queue(maxsize=1)
        self._worker: Optional[threading.Thread] = None
        self.notices.extend(self.enforce_capabilities())

    # --- config ------------------------------------------------------------

    def save(self) -> List[str]:
        """Called by the settings server after it writes into self.cfg.

        Returns what enforce_capabilities refused and why, so the caller can
        put it in front of the user instead of answering a bare ok.
        """
        messages = self.enforce_capabilities()
        self.notices.extend(messages)
        save_config(self.cfg)
        return messages

    def take_notices(self) -> List[str]:
        """Reasons a setting was refused, handed to whichever front end asks
        first. Drained, because saying it twice is its own kind of noise."""
        out, self.notices = self.notices, []
        return out

    def reload_corrector(self) -> None:
        self.corrector = Corrector(model=self.cfg["model"],
                                   allowlist=set(self.cfg["allowlist"]))

    def enforce_capabilities(self) -> List[str]:
        """Turn off anything this backend cannot honestly do, and say so.

        This runs on load and after every settings write, so a config file
        copied from a Mac cannot switch as-you-type on under a Linux session
        that has no way to see a password field.
        """
        messages: List[str] = []
        caps = self.backend.caps
        if self.cfg.get("as_you_type") and not caps.as_you_type:
            self.cfg["as_you_type"] = False
            messages.append(caps.why_no_as_you_type())
        if not self.cfg.get("hotkey"):
            self.cfg["hotkey"] = self.backend.default_hotkey()
        return messages

    # --- hotkey path: works in every app, uses the selection ----------------

    def fix_selection(self) -> bool:
        """Copy the selection, correct it, paste it back, restore the clipboard.

        Returns True only if a correction was actually pasted. Everything that
        can fail here fails quietly with a notification, because the user
        pressed a key and is waiting.
        """
        if not self.backend.caps.hotkey_path:
            self.notify("Backspace can't send keystrokes on this system.")
            return False
        if not self.busy.acquire(blocking=False):
            return False
        try:
            self.backend.clear_modifiers()
            time.sleep(SETTLE_AFTER_MODIFIERS)

            saved = self.backend.clipboard_read()
            source = self.backend.capture_selection()
            if source is None:
                self._restore(saved)
                self.notify("Select some text first")
                return False

            result = self.corrector.fix(source, self.cfg["mode"])
            if result.text == source:
                self._restore(saved)
                self.notify("Already clean")
                return False

            if not self.backend.clipboard_write(result.text):
                self._restore(saved)
                self.notify("Couldn't write to the clipboard")
                return False

            time.sleep(SETTLE_BEFORE_PASTE)
            self.backend.paste()
            time.sleep(SETTLE_AFTER_PASTE)
            self._restore(saved)

            self.last = {"before": source, "after": result.text}
            self.count += 1
            self.notify(summary(source, result.text)
                        + (" *" if result.used_llm else ""))
            return True
        finally:
            self.busy.release()

    def _restore(self, saved: Optional[str]) -> None:
        """Put the user's clipboard back — but only if we actually read it.

        A None read means we could not see the clipboard, usually because it
        held an image. Writing "" there to "restore" it would destroy content
        we never had. capture_selection has already clobbered it by this point,
        so leaving the corrected text behind is the least bad outcome.
        """
        if saved is not None:
            self.backend.clipboard_write(saved)

    # --- as-you-type path: opt in, offline only, bails on anything risky ----

    def dispatch_key(self, key: Any, injected: bool = False) -> None:
        """Adapter from whatever the backend's listener hands us to on_key().

        The only place in this file that touches a library key object, and it
        does so without importing one: pynput's Key members are enum members
        with .name, its KeyCodes carry .char, and getattr covers both without
        knowing which library produced them.
        """
        if injected:
            return
        self.on_key(getattr(key, "char", None), getattr(key, "name", None))

    def on_key(self, char: Optional[str], name: Optional[str]) -> None:
        """One keystroke, described in plain strings. Fully testable."""
        if not self.cfg.get("as_you_type") or self._own_keystrokes:
            return

        # A gap in typing is a gap in what we know. Nothing reports a mouse
        # click, so a buffer nobody has added to for seconds has probably
        # stopped describing the field it was built from.
        now = time.time()
        if self.buffer and now - self.buffer_time > BUFFER_MAX_IDLE:
            self.clear_buffer()
        self.buffer_time = now

        if char is None:
            if name in ("enter", "tab"):
                # The terminator is already in the field: the watcher only
                # listens, it does not intercept. Worse, we cannot tell a
                # newline from a send, or a tab from focus moving to the next
                # field — so by now the text may not even be there to fix.
                # This sentence goes uncorrected rather than retyped blind.
                self.clear_buffer()
            elif name == "backspace":
                if self.buffer:
                    self.buffer.pop()
            elif name == "space":
                self.buffer_char(" ")
            elif name in PASSIVE_MODIFIERS:
                pass          # held down while typing capitals; not a break
            else:
                # arrows, ctrl, alt, cmd, home, page up — anything that may
                # have moved the caret or pasted text we never saw.
                self.clear_buffer()
            return

        if char in ".!?":
            self.buffer_char(char)
            self.queue_flush(trailing=char)
        elif char.isprintable():
            self.buffer_char(char)
            if len(self.buffer) > MAX_BUFFER:
                self.clear_buffer()

    def buffer_char(self, char: str) -> None:
        """Buffer one character, remembering where it was typed.

        We record the app and, when the backend can supply one, a field-level
        token — so a caret jump between two fields of the same app is caught
        and not just a switch to another app.
        """
        if not self.buffer:
            self.buffer_app = self.backend.frontmost_app()
            self.buffer_field = self.backend.focused_field()
        self.buffer.append(char)

    def clear_buffer(self) -> None:
        """Forget what we think is on screen.

        Also the hook for anything that moves the caret without a key event —
        a mouse click, a focus change, a drag-and-drop. No backend reports
        those yet, so today the callers are all in on_key.
        """
        self.buffer.clear()
        self.buffer_app = None
        self.buffer_field = None

    def queue_flush(self, trailing: str) -> None:
        """Hand the retype to the worker thread and get out of the way.

        On macOS on_key runs on the CGEventTap callback itself. A retype is
        the better part of a second of paced keystrokes, WindowServer disables
        a tap whose callback overruns, and pynput never re-enables it — so
        doing this work here kills as-you-type after the first correction and
        nothing says so.
        """
        sentence = "".join(self.buffer)
        app, field = self.buffer_app, self.buffer_field
        self.clear_buffer()
        self.submit(lambda: self.retype(sentence, trailing, app, field))

    def flush(self, trailing: str) -> bool:
        """Take the buffer and retype it on this thread. What tests call."""
        sentence = "".join(self.buffer)
        app, field = self.buffer_app, self.buffer_field
        self.clear_buffer()
        return self.retype(sentence, trailing, app, field)

    def retype(self, sentence: str, trailing: str,
               app: Optional[AppRef] = None,
               field: Optional[str] = None) -> bool:
        """Correct one sentence and replace it, if all of that is still safe."""
        if not self.safe_to_retype(sentence):
            return False
        if not self.same_field(app, field):
            return False

        fixed = self.corrector.fix(sentence, "fix").text
        if trailing and not fixed.endswith(trailing):
            fixed += trailing
        if fixed == sentence:
            return False
        if abs(len(fixed) - len(sentence)) > MAX_LENGTH_DRIFT:
            return False
        # Asked before the backspaces, not after. Windows cannot send anything
        # above U+FFFF, and finding that out after deleting the sentence would
        # leave the user with a hole where their words were.
        if not self.backend.can_type(fixed):
            return False

        # The same lock the hotkey path takes. Two streams of synthetic
        # keystrokes into one field interleave into nonsense, and a hotkey
        # correction landing mid-retype has invalidated this sentence anyway.
        if not self.busy.acquire(blocking=False):
            return False
        self._own_keystrokes = True
        try:
            time.sleep(SETTLE_BEFORE_RETYPE)
            self.backend.backspace(len(sentence))
            if not self.backend.type_text(fixed):
                # The sentence is already deleted. Put the original back; that
                # is the least-bad outcome. If even that fails, say so out loud
                # rather than leave a silent hole where their words were.
                if not self.backend.type_text(sentence):
                    self.notify("Correction failed, some text may be lost")
                return False
            self.count += 1
            self.last = {"before": sentence, "after": fixed}
            return True
        finally:
            time.sleep(SETTLE_AFTER_RETYPE)
            self._own_keystrokes = False
            self.busy.release()

    def same_field(self, app: Optional[AppRef],
                   field: Optional[str] = None) -> bool:
        """Is focus still where the first character of this sentence went?

        The buffer models a text field in another process. If focus moved
        while it filled — a click into a browser, a switch to another app —
        the backspaces land in text we never saw, which is how a sentence
        typed in a chat window ends up deleting a password.

        App identity is the guard that works today. A field-level token, when
        the backend can supply one, catches the harder case of a jump between
        two fields of the same app; a mismatch there refuses. When either side
        is None the backend gave us no field signal, so we fall back to app
        identity plus the idle timeout rather than inventing certainty.
        """
        if app is None or not app.known:
            return False
        current = self.backend.frontmost_app()
        if not current.known:
            return False
        if (current.ident, current.name) != (app.ident, app.name):
            return False
        now = self.backend.focused_field()
        if field is not None and now is not None and now != field:
            return False
        return True

    # --- the retype thread --------------------------------------------------

    def submit(self, job: Callable[[], Any]) -> bool:
        """Run one job off the keystroke listener, one at a time.

        The queue holds exactly one, so a sentence arriving while a retype is
        still going is dropped rather than queued: by the time it ran, its
        buffer would describe a field that has since been rewritten.
        """
        if self._worker is None:
            # Only the listener thread calls this, so no lock is needed here.
            self._worker = threading.Thread(target=self._work, daemon=True)
            self._worker.start()
        try:
            self._jobs.put_nowait(job)
            return True
        except queue.Full:
            return False

    def _work(self) -> None:
        while True:
            job = self._jobs.get()
            try:
                job()
            except Exception:
                # One failed retype must not take the thread with it, or
                # as-you-type dies for the rest of the session in silence.
                pass

    def safe_to_retype(self, text: str) -> bool:
        """Every gate, in cheapest-first order. Any doubt is a no.

        The two that matter: the backend must be able to see password fields
        at all — otherwise as-you-type is refused on this platform rather than
        run blind — and an unidentified frontmost app blocks, because
        "we could not tell which app this is" is not "this app is fine".
        """
        if len(text) < MIN_SENTENCE_CHARS:
            return False
        if len(text.split()) < MIN_SENTENCE_WORDS:
            return False

        caps = self.backend.caps
        if not caps.as_you_type:
            return False

        # YES (a password field is focused) and UNKNOWN (the probe failed)
        # both block. Only a definite NO gets through.
        if self.backend.safe_to_retype().blocks:
            return False

        # Tri.NO here means "identified, and not on your blocklist".
        if self.backend.frontmost_app().matches(self.cfg["blocklist"]).blocks:
            return False

        if any(c in text for c in CODE_CHARS):     # looks like code
            return False
        return True

    # --- talking to the user ------------------------------------------------

    def notify(self, message: str) -> bool:
        return self.backend.notify(message, "Backspace",
                                   sound=bool(self.cfg.get("sound")))

    def status_lines(self) -> List[str]:
        """What --doctor and the startup banner both print about this config."""
        caps = self.backend.caps
        lines = [
            "hotkey:      {}".format(
                self.backend.pretty_hotkey(self.cfg["hotkey"]) or "none"),
            "mode:        {}".format(self.cfg["mode"]),
            "as-you-type: {}".format("on" if self.cfg["as_you_type"] else "off"),
        ]
        if not caps.as_you_type:
            lines.append("             " + caps.why_no_as_you_type())
        return lines


# --- wiring ----------------------------------------------------------------

class Runner:
    """Owns the backend's listeners and the settings server.

    Shared by every front end — menu bar, tray, headless — so the difference
    between them is only which UI object is constructed, never which OS calls
    are made.
    """

    def __init__(self, core: Backspace):
        self.core = core
        self.backend = core.backend
        self.dirty = False
        self.hotkey_live = False
        self.hotkey_applied: Optional[str] = None
        self.watcher_live = False
        self.httpd = None
        self.warnings: List[str] = []

    def start(self) -> None:
        self.apply_hotkey()
        self.apply_watcher()
        self.httpd = server.serve(self.core, on_change=self.mark_dirty)

    def apply_hotkey(self) -> bool:
        self.backend.stop_hotkey()
        self.hotkey_live = False
        hotkey = self.core.cfg.get("hotkey") or ""
        self.hotkey_applied = hotkey
        if not hotkey or not self.backend.caps.hotkey_path:
            return False
        self.hotkey_live = self.backend.start_hotkey(hotkey, self.trigger)
        if not self.hotkey_live:
            self.warnings.append(
                "The hotkey {} could not be registered. On macOS grant "
                "Accessibility and Input Monitoring to this interpreter; on "
                "Wayland no application can register a global hotkey."
                .format(self.backend.pretty_hotkey(hotkey)))
        return self.hotkey_live

    def apply_watcher(self) -> bool:
        """The keystroke listener only exists while the feature is on — and
        start_watcher refuses to install anything at all where the platform
        cannot see password fields."""
        want = bool(self.core.cfg.get("as_you_type"))
        if not want:
            self.backend.stop_watcher()
            self.watcher_live = False
            return False
        if self.watcher_live:
            return True
        self.watcher_live = self.backend.start_watcher(self.core.dispatch_key)
        if not self.watcher_live:
            self.core.cfg["as_you_type"] = False
            self.warnings.append(
                self.backend.caps.why_no_as_you_type()
                or "Keystroke watching could not be started.")
        return self.watcher_live

    def trigger(self, *_: Any) -> None:
        threading.Thread(target=self.core.fix_selection, daemon=True).start()

    def mark_dirty(self) -> None:
        self.core.reload_corrector()
        self.dirty = True

    def refresh(self) -> bool:
        """Pick up a settings change. Returns True if anything moved."""
        if not self.dirty:
            return False
        self.dirty = False
        self.warnings.extend(self.core.enforce_capabilities())
        # A hotkey edited in the settings page used to keep the old binding
        # until restart while every menu confidently printed the new one.
        # Compared rather than reapplied, so saving an unrelated setting does
        # not tear down a working listener.
        if (self.core.cfg.get("hotkey") or "") != self.hotkey_applied:
            self.apply_hotkey()
        self.apply_watcher()
        return True

    def stop(self) -> None:
        if self.httpd is not None:
            try:
                self.httpd.shutdown()
            except Exception:
                pass
            self.httpd = None
        self.backend.shutdown()

    def drain_warnings(self) -> List[str]:
        """Everything the runner or the core has to say, once, in one place —
        including the sentence enforce_capabilities wrote to explain a refusal,
        which every caller used to throw away."""
        out = self.warnings + self.core.take_notices()
        self.warnings = []
        return out


def build_core(backend: Optional[Backend] = None) -> Backspace:
    b = backend if backend is not None else backend_mod.get_backend()
    return Backspace(b, load_config(b))


def settings_url() -> str:
    return "http://127.0.0.1:{}".format(PORT)


# --- front ends ------------------------------------------------------------

def run_headless(core: Backspace, open_browser: bool = False) -> int:
    """Hotkey listener plus settings server, no tray, no display required."""
    runner = Runner(core)
    runner.start()

    print("Backspace is running.")
    for line in core.status_lines():
        print("  " + line)
    print("  settings:    " + settings_url())
    print("  backend:     " + core.backend.name)
    for warning in runner.drain_warnings():
        print("  ! " + warning)
    if not runner.hotkey_live:
        print("  ! No hotkey. The settings page still works, and "
              "`python3 app.py --fix` corrects text with no GUI at all.")
    print("Ctrl-C to quit.")
    sys.stdout.flush()

    if open_browser:
        try:
            webbrowser.open(settings_url())
        except Exception:
            pass

    stop = threading.Event()
    try:
        while not stop.wait(0.5):
            if runner.refresh():
                for warning in runner.drain_warnings():
                    print("  ! " + warning)
                    sys.stdout.flush()
    except KeyboardInterrupt:
        print("")
    finally:
        runner.stop()
    return 0


def run_menu_bar(core: Backspace) -> int:
    """macOS menu bar via rumps. Imported here, never at module scope."""
    import rumps

    runner = Runner(core)

    class MenuBar(rumps.App):
        def __init__(self) -> None:
            super().__init__("⌫", quit_button=None)
            # Start first, then build: the menu should say "hotkey unavailable"
            # when it is, not promise a binding that never registered.
            runner.start()
            self.build_menu()
            for warning in runner.drain_warnings():
                core.notify(warning)
            rumps.Timer(self.tick, 1).start()

        def build_menu(self) -> None:
            self.menu.clear()
            mode_items = []
            for key, label in MODES.items():
                item = rumps.MenuItem(label, callback=self.pick_mode)
                item.state = key == core.cfg["mode"]
                item._mode = key
                mode_items.append(item)

            caps = core.backend.caps
            if caps.as_you_type:
                auto = rumps.MenuItem("Fix as I type", callback=self.toggle_auto)
                auto.state = core.cfg["as_you_type"]
            else:
                auto = rumps.MenuItem("Fix as I type — unavailable",
                                      callback=self.explain_auto)

            label = "Fix selection  ({})".format(
                core.backend.pretty_hotkey(core.cfg["hotkey"]))
            if not runner.hotkey_live:
                label = "Fix selection  (hotkey unavailable)"

            self.menu = [
                rumps.MenuItem(label, callback=self.trigger),
                None, *mode_items, None, auto,
                rumps.MenuItem("Settings…", callback=self.open_settings),
                None,
                rumps.MenuItem("Quit", callback=self.quit),
            ]

        def pick_mode(self, sender) -> None:
            core.cfg["mode"] = sender._mode
            core.save()
            self.build_menu()

        def toggle_auto(self, sender) -> None:
            sender.state = not sender.state
            core.cfg["as_you_type"] = bool(sender.state)
            core.save()
            runner.apply_watcher()
            for warning in runner.drain_warnings():
                core.notify(warning)
            if core.cfg["as_you_type"]:
                core.notify("Watching as you type. Password fields, blocked "
                            "apps and anything that looks like code are skipped.")
            self.build_menu()

        def explain_auto(self, _) -> None:
            core.notify(core.backend.caps.why_no_as_you_type())

        def open_settings(self, _) -> None:
            webbrowser.open(settings_url())

        def trigger(self, _=None) -> None:
            runner.trigger()

        def quit(self, _) -> None:
            runner.stop()
            rumps.quit_application()

        def tick(self, _) -> None:
            if runner.refresh():
                for warning in runner.drain_warnings():
                    core.notify(warning)
                self.build_menu()

    # start() is inside __init__, so anything that goes wrong from there on
    # leaves a bound port and a registered hotkey behind. run_ui's fallback
    # then builds a second Runner and dies on EADDRINUSE instead of degrading.
    try:
        MenuBar().run()
    except BaseException:
        runner.stop()
        raise
    return 0


def _tray_image():
    """A 64px ⌫ drawn with primitives — no font file, no unicode glyph
    coverage assumption, nothing to ship alongside the script."""
    from PIL import Image, ImageDraw

    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    white = (255, 255, 255, 255)
    d.polygon([(4, 32), (22, 14), (60, 14), (60, 50), (22, 50)],
              outline=white, width=4)
    d.line([(30, 24), (48, 40)], fill=white, width=4)
    d.line([(48, 24), (30, 40)], fill=white, width=4)
    return img


def run_tray(core: Backspace) -> int:
    """Cross-platform tray icon via pystray. Windows and Linux."""
    import pystray

    runner = Runner(core)

    def is_mode(key):
        return lambda _: core.cfg["mode"] == key

    def set_mode(key):
        def handler(icon, _item):
            core.cfg["mode"] = key
            core.save()
            icon.update_menu()
        return handler

    def toggle_auto(icon, _item) -> None:
        if not core.backend.caps.as_you_type:
            core.notify(core.backend.caps.why_no_as_you_type())
            return
        core.cfg["as_you_type"] = not core.cfg["as_you_type"]
        core.save()
        runner.apply_watcher()
        for warning in runner.drain_warnings():
            core.notify(warning)
        icon.update_menu()

    def fix_now(_icon, _item) -> None:
        runner.trigger()

    def open_settings(_icon, _item) -> None:
        webbrowser.open(settings_url())

    def quit_app(icon, _item) -> None:
        runner.stop()
        icon.stop()

    def menu() -> Any:
        items = [pystray.MenuItem(
            "Fix selection ({})".format(
                core.backend.pretty_hotkey(core.cfg["hotkey"]))
            if runner.hotkey_live else "Fix selection (no hotkey)",
            fix_now, default=True)]
        items.append(pystray.Menu.SEPARATOR)
        for key, label in MODES.items():
            items.append(pystray.MenuItem(label, set_mode(key),
                                          checked=is_mode(key), radio=True))
        items.append(pystray.Menu.SEPARATOR)
        caps = core.backend.caps
        items.append(pystray.MenuItem(
            "Fix as I type" if caps.as_you_type
            else "Fix as I type — unavailable",
            toggle_auto,
            checked=lambda _: bool(core.cfg["as_you_type"]),
            enabled=caps.as_you_type))
        items.append(pystray.MenuItem("Settings…", open_settings))
        items.append(pystray.Menu.SEPARATOR)
        items.append(pystray.MenuItem("Quit", quit_app))
        return pystray.Menu(*items)

    # Listeners and the settings server come up before the icon, so the menu
    # is built knowing whether the hotkey actually registered rather than
    # promising one and finding out afterwards.
    runner.start()

    # Everything past this point can raise — pystray constructs fine on a box
    # with no StatusNotifier host and fails at the icon. The port and the
    # hotkey are already taken by now, so the headless fallback would build a
    # second Runner and die on EADDRINUSE rather than degrade.
    try:
        for warning in runner.drain_warnings():
            print("  ! " + warning)

        icon = pystray.Icon("backspace", _tray_image(), "Backspace", menu())

        # The Windows backend does not own a tray, so it cannot show a balloon
        # until we hand it one. Until then its notify() honestly returns False.
        setter = getattr(core.backend, "set_notifier", None)
        if callable(setter):
            setter(lambda message, title: icon.notify(message, title))

        def setup(ic) -> None:
            ic.visible = True
            print("Backspace is running. Settings: " + settings_url())
            sys.stdout.flush()

            def poll() -> None:
                while True:
                    time.sleep(1.0)
                    if runner.refresh():
                        for warning in runner.drain_warnings():
                            core.notify(warning)
                        try:
                            ic.update_menu()
                        except Exception:
                            pass

            threading.Thread(target=poll, daemon=True).start()

        icon.run(setup=setup)
    except BaseException:
        runner.stop()
        raise
    return 0


def run_ui(core: Backspace, prefer: str = "auto") -> int:
    """Pick a front end, degrading to headless rather than failing.

    A missing tray is not an error on any of the three platforms — it is the
    normal state of a server, a container, and a minimal window manager.
    """
    if prefer == "headless":
        return run_headless(core)

    caps = core.backend.caps
    if prefer in ("auto", "tray") and caps.tray_icon:
        if caps.name == "macos":
            try:
                return run_menu_bar(core)
            except Exception as e:
                print("Menu bar unavailable ({}: {}), running headless."
                      .format(type(e).__name__, e))
        else:
            try:
                return run_tray(core)
            except Exception as e:
                print("Tray unavailable ({}: {}), running headless."
                      .format(type(e).__name__, e))
    elif prefer == "tray":
        print("No tray icon on this system ({}), running headless."
              .format(core.backend.name))
    return run_headless(core)


# --- command line ----------------------------------------------------------

def cmd_doctor() -> int:
    b = backend_mod.get_backend()
    print(backend_mod.describe(b))
    core = Backspace(b, load_config(b))
    print("")
    print("Config ({}):".format(CONFIG_PATH))
    for line in core.status_lines():
        print("  " + line)
    for line in core.take_notices():
        print("  ! " + line)
    print("")
    print("Settings page: " + settings_url())
    return 0


def cmd_fix(text: Optional[str], mode: str) -> int:
    """Correct a string with no GUI, no permissions and no backend at all."""
    if text is None or not text.strip():
        if sys.stdin.isatty():
            print("Nothing to fix. Pass text as an argument or on stdin.",
                  file=sys.stderr)
            return 2
        text = sys.stdin.read()
    if not text.strip():
        return 2

    cfg = load_config()
    corrector = Corrector(model=cfg["model"], allowlist=set(cfg["allowlist"]))
    result = corrector.fix(text, mode)
    sys.stdout.write(result.text + ("\n" if not result.text.endswith("\n") else ""))
    if result.note:
        print("({})".format(result.note), file=sys.stderr)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="app.py", description="Backspace — fixes your typing.")
    p.add_argument("--doctor", action="store_true",
                   help="print what this machine can and cannot do, then exit")
    p.add_argument("--fix", nargs="?", const="", metavar="TEXT",
                   help="correct TEXT (or stdin) and print it, then exit")
    p.add_argument("--mode", default=None, choices=sorted(MODES),
                   help="correction mode for --fix (default: your config)")
    p.add_argument("--headless", action="store_true",
                   help="run the hotkey and settings server with no tray")
    p.add_argument("--tray", action="store_true",
                   help="require a tray icon rather than falling back to it")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.doctor:
        return cmd_doctor()

    if args.fix is not None:
        mode = args.mode or load_config().get("mode", "fix")
        return cmd_fix(args.fix or None, mode)

    core = build_core()
    prefer = "headless" if args.headless else ("tray" if args.tray else "auto")
    return run_ui(core, prefer)


if __name__ == "__main__":
    sys.exit(main())
