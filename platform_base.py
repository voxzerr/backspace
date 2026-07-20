"""The contract every platform backend implements.

One rule runs through all of it: an answer of "I don't know" must never
be mistaken for "no". macOS can see a password field, Windows and Linux
cannot, and the difference has to survive the trip up to app.py — because
the caller is deciding whether to replay a sentence the user may have just
typed into a login box.

So the shapes here are deliberately not bools:

  Tri       yes / no / unknown, for questions about the world
  AppRef    an app we identified, or one we could not
  Capabilities  what this backend can actually do, asked before it is asked to

NullBackend at the bottom does nothing and admits everything, so the whole
app imports and tests on a headless runner with no display and no libraries.
"""

from __future__ import annotations

import enum
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Sequence


class UnsupportedPlatform(RuntimeError):
    """Raised by a backend module that cannot run here. Carries the why."""


# --- three-valued answers --------------------------------------------------

class Tri(enum.Enum):
    """A yes/no we might not have. UNKNOWN is a real answer, not an error."""

    YES = "yes"
    NO = "no"
    UNKNOWN = "unknown"

    @property
    def is_yes(self) -> bool:
        return self is Tri.YES

    @property
    def is_no(self) -> bool:
        return self is Tri.NO

    @property
    def known(self) -> bool:
        return self is not Tri.UNKNOWN

    @property
    def blocks(self) -> bool:
        """True unless we positively know it is safe. Every safety gate uses
        this, so a broken probe fails closed instead of waving text through."""
        return self is not Tri.NO

    @classmethod
    def of(cls, value: Optional[bool]) -> "Tri":
        if value is None:
            return cls.UNKNOWN
        return cls.YES if value else cls.NO


@dataclass(frozen=True)
class AppRef:
    """Whatever we managed to learn about the frontmost app.

    ident is the stable key — bundle id on macOS, lowercased exe basename on
    Windows, WM_CLASS on X11. name is the human label and is localized, so it
    is for display and never for matching. Both None means we could not tell,
    which is different from a real app with an empty name.
    """

    ident: Optional[str] = None
    name: Optional[str] = None

    @property
    def known(self) -> bool:
        return bool(self.ident or self.name)

    def matches(self, patterns: Sequence[str]) -> Tri:
        """Is this app on the given list? UNKNOWN when we never identified it.

        The old `frontmost_app() in blocklist` was False for an unidentified
        app, i.e. unknown read as allowed. Returning UNKNOWN here is the fix;
        callers must treat it with Tri.blocks.
        """
        if not self.known:
            return Tri.UNKNOWN
        for pattern in patterns:
            p = pattern.lower()
            if self.ident and (self.ident.lower() == p
                               or self.ident.lower().startswith(p + ".")):
                return Tri.YES
            if self.name and self.name.lower() == p:
                return Tri.YES
        return Tri.NO

    def __str__(self) -> str:
        return self.name or self.ident or "unknown app"


UNKNOWN_APP = AppRef()


# --- what a backend can do -------------------------------------------------

@dataclass
class Capabilities:
    """The honest inventory. app.py asks this instead of guessing from
    sys.platform, and settings.html shows `notes` so a disabled toggle can
    say why rather than just sitting there greyed out."""

    name: str = "null"

    # clipboard
    clipboard: bool = False
    clipboard_change_counter: bool = False   # a real monotonic counter exists

    # input
    synthetic_input: bool = False            # we can send keystrokes at all
    global_hotkey: bool = False
    keystroke_watch: bool = False            # we can observe typing

    # safety probes
    password_field_detection: bool = False   # any signal at all, even partial
    frontmost_app: bool = False

    # ui
    tray_icon: bool = False
    tray_menu: bool = False
    notifications: bool = False
    notification_sound: bool = False

    default_hotkey: str = ""
    notes: List[str] = field(default_factory=list)

    @property
    def hotkey_path(self) -> bool:
        """Can we offer "select text, press hotkey"? Needs no password probe —
        the user pointed at the text, and nothing is buffered."""
        return self.clipboard and self.synthetic_input and self.global_hotkey

    @property
    def as_you_type(self) -> bool:
        """Can we offer as-you-type here, honestly?

        Requires watching keys, typing them back, knowing which app has focus,
        and some password signal. Windows and Linux fail the last one and so
        must not offer the feature at all — not offer it with a warning.
        """
        return (self.keystroke_watch and self.synthetic_input
                and self.frontmost_app and self.password_field_detection)

    def why_no_as_you_type(self) -> str:
        """One sentence for the settings page. Empty when it is available."""
        if self.as_you_type:
            return ""
        if not self.keystroke_watch:
            return "Backspace can't watch keystrokes on this system."
        if not self.password_field_detection:
            return ("This system has no reliable way to tell when you're typing "
                    "a password, so Backspace won't watch your keystrokes here.")
        if not self.frontmost_app:
            return "Backspace can't tell which app has focus on this system."
        return "Backspace can't send keystrokes on this system."

    def note(self, line: str) -> None:
        self.notes.append(line)


# --- the interface ---------------------------------------------------------

class Backend(ABC):
    """Everything app.py needs from the operating system.

    Read every docstring's failure line. Methods that answer questions return
    Tri or Optional and use UNKNOWN/None for "could not tell". Methods that
    do things return bool for "it happened" — False means it did not, which on
    Windows and Wayland is routine rather than exceptional.
    """

    # --- introspection -----------------------------------------------------

    @property
    @abstractmethod
    def caps(self) -> Capabilities:
        """Never raises. On a half-broken system it returns a Capabilities
        with the relevant fields False and the reason appended to notes."""

    @property
    def name(self) -> str:
        return self.caps.name

    # --- clipboard ---------------------------------------------------------

    @abstractmethod
    def clipboard_read(self) -> Optional[str]:
        """Clipboard text, or None if we could not read it.

        None is not "". An empty clipboard is "". Callers that save-and-restore
        must not overwrite the user's clipboard on a None — that is how an
        image on the clipboard gets destroyed. Text only on every platform;
        non-text contents are invisible here and survive only if untouched.
        """

    @abstractmethod
    def clipboard_write(self, text: str) -> bool:
        """Put text on the clipboard. False if the write failed (Windows
        contention, Wayland focus refusal) — the old contents may or may not
        still be there, so treat False as "clipboard state unknown"."""

    @abstractmethod
    def clipboard_counter(self) -> Optional[int]:
        """A monotonic counter that moves whenever the clipboard changes,
        including on our own writes. None when the platform has no such thing
        (X11, Wayland) — those override capture_selection instead.

        Windows returns 0 when the process cannot reach the window station;
        that backend must map 0 to None rather than report a real count of 0.
        """

    def capture_selection(self, timeout: float = 0.7) -> Optional[str]:
        """Send the copy chord and return what the user had selected.

        None means nothing was selected, or the copy never landed — which on
        Windows also happens when the target window is elevated, and on macOS
        when Accessibility was never granted. Backends that can tell the
        difference should say so via notify(), not by returning "".

        Clobbers the clipboard. Callers save and restore around it.

        Default implementation polls clipboard_counter(). Platforms without a
        counter override this with the write-a-sentinel-and-watch-it-change
        trick; the signature and the meaning of None are the contract.
        """
        import time

        before = self.clipboard_counter()
        if before is None:
            return None

        self.copy()
        deadline = time.time() + timeout
        while time.time() < deadline:
            now = self.clipboard_counter()
            if now is not None and now != before:
                text = self.clipboard_read()
                return text if text and text.strip() else None
            time.sleep(0.02)
        return None

    # --- sending keystrokes ------------------------------------------------

    @abstractmethod
    def copy(self) -> None:
        """Send the platform's copy chord — ⌘C or Ctrl+C. A no-op backend
        just returns; there is no way to observe delivery, which is exactly
        why capture_selection watches the clipboard instead of trusting this."""

    @abstractmethod
    def paste(self) -> None:
        """Send the paste chord. Same silence as copy(): synthetic input is
        fire-and-forget on every platform we support."""

    @abstractmethod
    def backspace(self, n: int) -> None:
        """Send n backspaces, paced so fast apps don't drop them. Never call
        this without having checked can_type() on the replacement first — the
        deletions are not undoable if the retype then fails."""

    @abstractmethod
    def type_text(self, text: str) -> bool:
        """Type text. False if the platform refused some character rather than
        typing a partial string — callers must not assume anything landed."""

    def can_type(self, text: str) -> bool:
        """Would type_text(text) succeed, checked before we destroy anything?

        Windows cannot send codepoints above U+FFFF, so an emoji in a
        correction would abort the retype after the backspaces already ran.
        Default True; backends with limits narrow it.
        """
        return bool(self.caps.synthetic_input)

    @abstractmethod
    def clear_modifiers(self) -> None:
        """Release every modifier we might think is held.

        Load-bearing, not hygiene: the user is still physically holding the
        hotkey when the callback fires, so without this the copy chord goes
        out as ⌥⌘C and nothing responds. Releasing a key that is not down is
        harmless everywhere.
        """

    # --- knowing where we are ----------------------------------------------

    @abstractmethod
    def frontmost_app(self) -> AppRef:
        """Which app has keyboard focus.

        Returns UNKNOWN_APP when we could not tell — during app switches, when
        OpenProcess is denied on an elevated window, on GNOME Wayland always.
        Never returns AppRef("") to mean unknown, because `"" in blocklist`
        is False and that quietly turns a failed probe into permission.
        """

    def focused_field(self) -> Optional[str]:
        """An opaque identity for the focused field/window, or None if unknown.

        frontmost_app() only says which application has focus, so two text
        fields in the same app share an AppRef and the as-you-type buffer
        cannot tell a caret jump between them from ordinary typing. A backend
        that can read the focused UI element (macOS Accessibility,
        Windows UI Automation) should return a stable per-field token here so
        that jump is caught. None means "could not tell" — the caller must
        treat that as the absence of a field-level signal, never as a match.

        Default is None: no backend reads this reliably yet (the macOS AX probe
        needs a grant it does not always have), so app-level identity plus the
        idle timeout remain the working guard. This is the seam to fill in.
        """
        return None

    @abstractmethod
    def secure_input_active(self) -> Tri:
        """Is the user typing something secret right now?

        YES      a password field or secure input mode is definitely active.
        NO       we checked, and it is definitely not.
        UNKNOWN  we cannot check here — the only honest answer on Windows and
                 Linux, and on macOS whenever the Carbon probe itself fails.

        UNKNOWN must gate as-you-type off. Note that even YES/NO is partial on
        macOS: a browser password field does not enable secure input, so NO is
        "no global secure input", not "no secret". This is why as-you-type
        also needs the blocklist and the code heuristic.
        """

    def safe_to_retype(self) -> Tri:
        """The single gate as-you-type asks before replaying a sentence.

        NO means go ahead. YES and UNKNOWN both mean stop, so the caller only
        ever writes `if self.safe_to_retype().blocks: return`.
        """
        if not self.caps.as_you_type:
            return Tri.UNKNOWN
        secure = self.secure_input_active()
        if secure.blocks:
            return secure
        return Tri.NO

    # --- hotkey and watcher lifecycle --------------------------------------

    @abstractmethod
    def default_hotkey(self) -> str:
        """The default binding in pynput syntax, per platform.

        ⌥Space on macOS; Ctrl+Alt+Space on Windows, because Alt+Space is the
        window menu and now Copilot; something else again on Linux, where
        Alt+Space belongs to the WM. Empty string if no hotkey is possible.
        """

    def pretty_hotkey(self, hotkey: str) -> str:
        """Display form — Ctrl+Alt+Space. Words joined by "+", because that is
        how every platform but macOS writes a chord; macOS overrides this with
        glyphs, which are the only form where the separators are wrong."""
        labels = {"<cmd>": "Super", "<alt>": "Alt", "<ctrl>": "Ctrl",
                  "<shift>": "Shift", "<space>": "Space"}
        out = []
        for part in (p.strip() for p in hotkey.split("+")):
            if not part:
                continue
            label = labels.get(part.lower())
            if label is None:
                bare = part.strip("<>")
                label = bare.capitalize() if len(bare) > 1 else bare.upper()
            out.append(label)
        return "+".join(out) or hotkey

    @abstractmethod
    def start_hotkey(self, hotkey: str, callback: Callable[[], None]) -> bool:
        """Register the global hotkey. False when it could not be registered.

        Must be False, not True, when the underlying listener starts but can
        never fire — pynput on Wayland constructs happily and receives nothing,
        and a listener's `.running` flag stays True after a permission-denied
        thread has already died. Probe permissions up front instead.
        """

    @abstractmethod
    def stop_hotkey(self) -> None:
        """Unregister. Safe to call when nothing is registered."""

    @abstractmethod
    def start_watcher(self, on_key: Callable[..., None]) -> bool:
        """Start watching keystrokes for as-you-type. False if not started.

        Must return False without installing anything when
        caps.as_you_type is False — on Windows and Linux the exposure is the
        hook itself, and never installing it is a stronger promise than
        installing it and filtering.

        on_key is called with (key) or (key, injected) depending on what it
        accepts; backends that can identify their own synthetic keystrokes
        pass the second argument and must drop them regardless.
        """

    @abstractmethod
    def stop_watcher(self) -> None:
        """Stop watching. Safe to call when not watching."""

    # --- talking to the user -----------------------------------------------

    @abstractmethod
    def notify(self, message: str, title: str = "Backspace",
               sound: bool = False) -> bool:
        """Best-effort toast. False when nothing was shown.

        Never the only channel for something the user must see: an unbundled
        macOS process has no bundle id and the daemon drops its banners
        silently, and most Linux containers have no notification daemon.
        sound is ignored where the platform has no concept of it — caps
        .notification_sound says which.
        """

    # --- shutdown ----------------------------------------------------------

    def shutdown(self) -> None:
        """Release listeners and OS handles. Idempotent."""
        self.stop_hotkey()
        self.stop_watcher()


# --- the backend that admits it can do nothing -----------------------------

class NullBackend(Backend):
    """Does nothing, claims nothing. This is what CI runs against, and what
    a machine with missing libraries falls back to — the app stays up, the
    settings page still serves, and every feature reports why it is off."""

    def __init__(self, reason: str = "no platform backend available"):
        self._caps = Capabilities(name="null", notes=[reason])
        self.reason = reason

    @property
    def caps(self) -> Capabilities:
        return self._caps

    def clipboard_read(self) -> Optional[str]:
        return None

    def clipboard_write(self, text: str) -> bool:
        return False

    def clipboard_counter(self) -> Optional[int]:
        return None

    def capture_selection(self, timeout: float = 0.7) -> Optional[str]:
        return None

    def copy(self) -> None:
        pass

    def paste(self) -> None:
        pass

    def backspace(self, n: int) -> None:
        pass

    def type_text(self, text: str) -> bool:
        return False

    def can_type(self, text: str) -> bool:
        return False

    def clear_modifiers(self) -> None:
        pass

    def frontmost_app(self) -> AppRef:
        return UNKNOWN_APP

    def secure_input_active(self) -> Tri:
        return Tri.UNKNOWN

    def default_hotkey(self) -> str:
        return ""

    def start_hotkey(self, hotkey: str, callback: Callable[[], None]) -> bool:
        return False

    def stop_hotkey(self) -> None:
        pass

    def start_watcher(self, on_key: Callable[..., None]) -> bool:
        return False

    def stop_watcher(self) -> None:
        pass

    def notify(self, message: str, title: str = "Backspace",
               sound: bool = False) -> bool:
        return False
