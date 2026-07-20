"""The Windows backend: clipboard, synthetic input, hotkey — and a refusal.

Two things here are worth reading before the code.

The first is that as-you-type does not ship on Windows, and the keyboard hook
is never installed. Windows has no equivalent of macOS's IsSecureEventInputEnabled:
password protection is a per-control rendering convention, not a system state,
so there is nothing global to ask. The two probes that exist both fail in the
same place. The classic ES_PASSWORD check only sees the Win32 EDIT control, so
it says "not a password" for every browser login form, every Electron app and
every WPF PasswordBox. UI Automation sees more, but Electron exposes nothing
without a command-line switch we cannot set on the user's Slack, and querying
it forces Chromium to build a full accessibility tree for every tab, forever,
from inside a low-level hook callback that freezes system-wide keyboard input
if it blocks. A gate that answers "safe" for apps it cannot see is worse than
no gate, because the rest of the app believes it. So password_field_detection
is False, which turns as_you_type off in Capabilities, and start_watcher
returns False without installing anything. Never installing a WH_KEYBOARD_LL
hook is a stronger promise than installing one and filtering it.

The second is that everything below is ctypes against user32/kernel32 — no
compiler, no pywin32, no pyperclip. Three rules that ctypes will not enforce
for you and that quietly corrupt everything if broken:

  * every function gets an explicit restype, or 64-bit handles come back
    truncated to 32 bits and every pointer is garbage
  * SetClipboardData transfers ownership of the HGLOBAL to the system, so
    GlobalFree after a *successful* call is a double free
  * CloseClipboard runs in a finally, always. A leaked open clipboard hangs
    every other application on the machine, not just this one.

This module must import cleanly on macOS and Linux with nothing installed —
CI does exactly that — so every risky import is guarded and the class refuses
to construct anywhere but Windows.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from typing import Callable, List, Optional

from platform_base import (UNKNOWN_APP, AppRef, Backend, Capabilities, Tri,
                           UnsupportedPlatform)


# --- win32 constants -------------------------------------------------------

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
HWND_MESSAGE = -3
ERROR_INSUFFICIENT_BUFFER = 122

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000   # survives most elevated targets;
                                             # PROCESS_QUERY_INFORMATION does not

GWL_STYLE = -16
ES_PASSWORD = 0x0020

# clipboard contention is routine, not exceptional: every clipboard manager
# opens the clipboard on each change, including the one our own Ctrl+C causes
CLIPBOARD_ATTEMPTS = 10
CLIPBOARD_RETRY = 0.02          # ~200ms total, inside the 700ms hotkey budget

BACKSPACE_PACE = 0.006          # fast apps drop keys sent faster than this
LISTENER_SETTLE = 0.3           # before asking is_alive() whether it survived

# Alt+Space is the window system menu, PowerToys Run, and on Windows 11
# Copilot. Ctrl+Shift+Space inserts a non-breaking space in Word. Win+Space
# switches keyboard layout. This is what is left, and its final key is a
# special key, which is what pynput's canonical() resolves reliably.
DEFAULT_HOTKEY = "<ctrl>+<alt>+<space>"
ALTGR_ALTERNATIVE = "<ctrl>+<shift>+<f9>"

# the blocklist namespace is different here: lowercased exe basename, not a
# localized display name. mstsc and the VM hosts matter most — keystrokes
# injected there cross into a session where none of these checks apply.
DEFAULT_BLOCKLIST = [
    "windowsterminal.exe", "cmd.exe", "powershell.exe", "pwsh.exe",
    "conhost.exe", "code.exe", "devenv.exe", "putty.exe", "mintty.exe",
    "1password.exe", "keepass.exe", "keepassxc.exe", "bitwarden.exe",
    "mstsc.exe", "vmware.exe", "virtualboxvm.exe", "steam.exe",
]

_PRETTY = {
    "<ctrl>": "Ctrl", "<alt>": "Alt", "<shift>": "Shift", "<cmd>": "Win",
    "<space>": "Space", "<enter>": "Enter", "<tab>": "Tab", "<esc>": "Esc",
    "<backspace>": "Backspace",
}

_FAILED = object()   # "could not open the clipboard", distinct from a None read


# --- the ctypes bindings ---------------------------------------------------

class _Win32:
    """user32/kernel32 with argtypes and restypes pinned on every call.

    Built once per backend. WinDLL instances are private to us, so binding
    argtypes here cannot disturb anything else in the process — which is the
    reason for WinDLL(...) over windll.user32, along with use_last_error
    actually surviving across calls.
    """

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self.ctypes = ctypes
        self.wintypes = wintypes

        u = ctypes.WinDLL("user32", use_last_error=True)
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        self.user32, self.kernel32 = u, k

        LPWCHAR = ctypes.POINTER(ctypes.c_wchar)

        class GUITHREADINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hwndActive", wintypes.HWND), ("hwndFocus", wintypes.HWND),
                ("hwndCapture", wintypes.HWND), ("hwndMenuOwner", wintypes.HWND),
                ("hwndMoveSize", wintypes.HWND), ("hwndCaret", wintypes.HWND),
                ("rcCaret", wintypes.RECT),
            ]

        self.GUITHREADINFO = GUITHREADINFO

        # clipboard
        u.OpenClipboard.argtypes = [wintypes.HWND]
        u.OpenClipboard.restype = wintypes.BOOL
        u.CloseClipboard.argtypes = []
        u.CloseClipboard.restype = wintypes.BOOL
        u.EmptyClipboard.argtypes = []
        u.EmptyClipboard.restype = wintypes.BOOL
        u.IsClipboardFormatAvailable.argtypes = [wintypes.UINT]
        u.IsClipboardFormatAvailable.restype = wintypes.BOOL
        u.GetClipboardData.argtypes = [wintypes.UINT]
        u.GetClipboardData.restype = wintypes.HANDLE
        u.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
        u.SetClipboardData.restype = wintypes.HANDLE
        u.GetClipboardSequenceNumber.argtypes = []
        u.GetClipboardSequenceNumber.restype = wintypes.DWORD

        # global memory
        k.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
        k.GlobalAlloc.restype = wintypes.HGLOBAL
        k.GlobalLock.argtypes = [wintypes.HGLOBAL]
        k.GlobalLock.restype = wintypes.LPVOID
        k.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
        k.GlobalUnlock.restype = wintypes.BOOL
        k.GlobalFree.argtypes = [wintypes.HGLOBAL]
        k.GlobalFree.restype = wintypes.HGLOBAL
        k.GlobalSize.argtypes = [wintypes.HGLOBAL]
        k.GlobalSize.restype = ctypes.c_size_t

        # the message-only window we need to own in order to write
        u.CreateWindowExW.argtypes = [
            wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD,
            ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, wintypes.LPVOID,
        ]
        u.CreateWindowExW.restype = wintypes.HWND
        u.DestroyWindow.argtypes = [wintypes.HWND]
        u.DestroyWindow.restype = wintypes.BOOL
        k.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
        k.GetModuleHandleW.restype = wintypes.HMODULE

        # who has focus
        u.GetForegroundWindow.argtypes = []
        u.GetForegroundWindow.restype = wintypes.HWND
        u.GetWindowThreadProcessId.argtypes = [wintypes.HWND,
                                               ctypes.POINTER(wintypes.DWORD)]
        u.GetWindowThreadProcessId.restype = wintypes.DWORD
        k.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        k.OpenProcess.restype = wintypes.HANDLE
        k.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, LPWCHAR,
            ctypes.POINTER(wintypes.DWORD),
        ]
        k.QueryFullProcessImageNameW.restype = wintypes.BOOL
        k.CloseHandle.argtypes = [wintypes.HANDLE]
        k.CloseHandle.restype = wintypes.BOOL

        # the classic-EDIT password probe (positive-only, see below)
        u.GetGUIThreadInfo.argtypes = [wintypes.DWORD,
                                       ctypes.POINTER(GUITHREADINFO)]
        u.GetGUIThreadInfo.restype = wintypes.BOOL
        u.GetClassNameW.argtypes = [wintypes.HWND, LPWCHAR, ctypes.c_int]
        u.GetClassNameW.restype = ctypes.c_int
        u.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
        u.GetWindowLongW.restype = wintypes.LONG


def _probe(name: str) -> Optional[str]:
    """Import a module for its side effect of existing. None means it is there,
    otherwise the reason it is not — kept as a string for caps.notes."""
    try:
        __import__(name)
        return None
    except Exception as e:                      # ImportError, and worse
        return "{}: {}".format(type(e).__name__, e)


# --- the backend -----------------------------------------------------------

class WindowsBackend(Backend):
    """Hotkey path in full, as-you-type refused, nothing that can lie."""

    def __init__(self) -> None:
        if not sys.platform.startswith("win"):
            raise UnsupportedPlatform(
                "the Windows backend needs Windows; this is " + sys.platform)

        self._clip_lock = threading.RLock()
        self._clip_open = False          # never nest OpenClipboard
        self._owner_hwnd = None
        self._hotkey_listener = None
        self._controller = None
        self._w = None

        caps = Capabilities(name="windows", default_hotkey=DEFAULT_HOTKEY)

        win_error = None
        try:
            self._w = _Win32()
        except Exception as e:
            win_error = "{}: {}".format(type(e).__name__, e)

        if win_error:
            caps.note("user32/kernel32 unavailable (" + win_error +
                      "); clipboard and app detection are off")
        else:
            self._owner_hwnd = self._make_owner_window()
            caps.frontmost_app = True
            caps.clipboard_change_counter = True
            if self._owner_hwnd:
                caps.clipboard = True
            else:
                # reading would still work, but a backend that can read and not
                # write cannot do the round trip the hotkey path is made of
                caps.note("could not create the clipboard owner window, so "
                          "writes would fail; clipboard is off")

        pynput_error = _probe("pynput.keyboard")
        if pynput_error:
            caps.note("pynput unavailable (" + pynput_error +
                      "); hotkey and typing are off")
        else:
            caps.synthetic_input = True
            caps.global_hotkey = True
            # true as a statement about the platform. It stays off in practice:
            # as_you_type also needs password_field_detection, and start_watcher
            # refuses. why_no_as_you_type() then names the real reason.
            caps.keystroke_watch = True

        tray_error = _probe("pystray") or _probe("PIL.Image")
        if tray_error:
            caps.note("pystray/Pillow unavailable (" + tray_error +
                      "); no tray icon and no balloon tips")
        else:
            caps.tray_icon = True
            caps.tray_menu = True
            # notifications stays False here on purpose. The backend owns no
            # tray and Windows gives us no other way to put words on screen,
            # so nothing can be shown until set_notifier() lends us the tray's
            # balloon tip. pystray merely importing is not the same thing.
            caps.note("Balloon tips come from the tray icon, so a headless "
                      "run has no way to show a message.")

        # every honest limit, written down where settings.html can read it
        caps.password_field_detection = False
        caps.notification_sound = False
        caps.note("Windows exposes no system-wide password-field signal, so "
                  "as-you-type is unavailable and no keyboard hook is installed.")
        caps.note("Tray balloon tips have no sound on Windows; the sound "
                  "setting does nothing here.")
        caps.note("Blocklist entries are exe names such as 'code.exe', not "
                  "display names.")
        caps.note("Backspace cannot send keys into an elevated window; the "
                  "hotkey path reports 'nothing selected' there.")
        caps.note("Apps that copy lazily (Excel and some Office windows) may "
                  "miss the 0.7s window and report nothing selected.")
        caps.note("On AltGr keyboard layouts, AltGr+Space can trigger the "
                  "default hotkey; " + ALTGR_ALTERNATIVE + " avoids it.")

        self._caps = caps
        self._notifier = None            # set by app.py once the tray exists

    @property
    def caps(self) -> Capabilities:
        return self._caps

    # --- the clipboard owner window ----------------------------------------

    def _make_owner_window(self):
        """A message-only window, created once and kept for the process.

        EmptyClipboard with a NULL owner succeeds but sets the owner to NULL,
        and SetClipboardData then fails — so writing needs a real HWND. STATIC
        is used because it needs no class registration, and message-only
        windows need no message pump to hold clipboard ownership.
        """
        w = self._w
        try:
            hinst = w.kernel32.GetModuleHandleW(None)
            hwnd = w.user32.CreateWindowExW(
                0, "STATIC", None, 0, 0, 0, 0, 0,
                w.ctypes.c_void_p(HWND_MESSAGE), None, hinst, None)
            return hwnd or None
        except Exception:
            return None

    def _hold_clipboard(self, fn, for_write: bool = False):
        """Run fn() with the clipboard open, retrying while another process
        holds it. Returns _FAILED if it never opened — which the caller must
        distinguish from fn() legitimately returning None.

        CloseClipboard is in a finally because the failure mode of skipping it
        is a machine-wide clipboard lock, not a bug in this process.
        """
        w = self._w
        if w is None:
            return _FAILED
        hwnd = self._owner_hwnd          # reads tolerate NULL, writes do not
        if for_write and not hwnd:
            return _FAILED

        with self._clip_lock:
            if self._clip_open:          # a nested open would deadlock us
                return _FAILED
            for attempt in range(CLIPBOARD_ATTEMPTS):
                opened = False
                try:
                    opened = bool(w.user32.OpenClipboard(hwnd))
                except Exception:
                    return _FAILED
                if opened:
                    self._clip_open = True
                    try:
                        return fn()
                    except Exception:
                        return _FAILED
                    finally:
                        self._clip_open = False
                        try:
                            w.user32.CloseClipboard()
                        except Exception:
                            pass
                if attempt < CLIPBOARD_ATTEMPTS - 1:
                    time.sleep(CLIPBOARD_RETRY)
            return _FAILED

    # --- clipboard ---------------------------------------------------------

    def clipboard_read(self) -> Optional[str]:
        """None when there is no text to read — including when the clipboard
        holds an image, which callers must not then overwrite."""
        if not self._caps.clipboard:
            return None
        w = self._w

        def read():
            if not w.user32.IsClipboardFormatAvailable(CF_UNICODETEXT):
                return None
            handle = w.user32.GetClipboardData(CF_UNICODETEXT)
            if not handle:
                return None
            ptr = w.kernel32.GlobalLock(handle)
            if not ptr:
                return None
            try:
                size = w.kernel32.GlobalSize(handle)
                if not size:
                    return ""
                # bound the read by the allocation rather than trusting the
                # handle to carry a terminator
                raw = w.ctypes.wstring_at(ptr, size // 2)
                return raw.split("\x00", 1)[0]
            finally:
                w.kernel32.GlobalUnlock(handle)   # false at count 0, not an error

        result = self._hold_clipboard(read)
        if result is _FAILED:
            return None
        return result

    def clipboard_write(self, text: str) -> bool:
        """The ownership dance. Read the comments before changing the order."""
        if not self._caps.clipboard:
            return False
        w = self._w
        k = w.kernel32

        try:
            data = text.encode("utf-16-le") + b"\x00\x00"
        except (UnicodeEncodeError, AttributeError):
            return False                  # lone surrogates, or not a str
        size = len(data)

        handle = k.GlobalAlloc(GMEM_MOVEABLE, size)   # MOVEABLE is mandatory
        if not handle:
            return False
        ptr = k.GlobalLock(handle)
        if not ptr:
            k.GlobalFree(handle)
            return False
        try:
            w.ctypes.memmove(ptr, data, size)
        except Exception:
            k.GlobalUnlock(handle)
            k.GlobalFree(handle)
            return False
        k.GlobalUnlock(handle)            # must be unlocked before we close

        def write():
            if not w.user32.EmptyClipboard():
                return False
            # from here on the system may own the handle
            return bool(w.user32.SetClipboardData(CF_UNICODETEXT, handle))

        result = self._hold_clipboard(write, for_write=True)
        if result is _FAILED or result is False:
            # ownership never transferred, so the block is still ours to free.
            # Freeing after a *successful* SetClipboardData would be a double
            # free — that is why this only runs on the failure paths.
            try:
                k.GlobalFree(handle)
            except Exception:
                pass
            return False
        return True

    def clipboard_counter(self) -> Optional[int]:
        """GetClipboardSequenceNumber, which moves on any change including our
        own writes — the same contract as NSPasteboard.changeCount.

        Zero means the process cannot reach the window station, not a count of
        zero, so it maps to None. A caller comparing against a stuck 0 would
        never see a change and would wait out every timeout.
        """
        if not self._caps.clipboard_change_counter:
            return None
        try:
            count = int(self._w.user32.GetClipboardSequenceNumber())
        except Exception:
            return None
        return count or None

    # --- sending keystrokes ------------------------------------------------

    def _keyboard(self):
        """pynput.keyboard, imported on first use. None if it is not there."""
        if not self._caps.synthetic_input:
            return None
        try:
            from pynput import keyboard
            return keyboard
        except Exception:
            return None

    def _kb(self):
        """The shared Controller."""
        if self._controller is None:
            kbd = self._keyboard()
            if kbd is None:
                return None
            try:
                self._controller = kbd.Controller()
            except Exception:
                return None
        return self._controller

    def _chord(self, char: str) -> None:
        """Ctrl, not Cmd. Key.cmd is VK_LWIN on Windows and would open the
        Start menu instead of copying."""
        kbd, kb = self._keyboard(), self._kb()
        if kbd is None or kb is None:
            return
        try:
            with kb.pressed(kbd.Key.ctrl):
                kb.tap(char)
        except Exception:
            pass

    def copy(self) -> None:
        self._chord("c")

    def paste(self) -> None:
        self._chord("v")

    def backspace(self, n: int) -> None:
        kbd, kb = self._keyboard(), self._kb()
        if kbd is None or kb is None or n <= 0:
            return
        for _ in range(int(n)):
            try:
                kb.tap(kbd.Key.backspace)
            except Exception:
                return
            time.sleep(BACKSPACE_PACE)

    def can_type(self, text: str) -> bool:
        """Windows cannot send codepoints above U+FFFF.

        pynput raises ValueError on them partway through the string, so an
        emoji in a correction would abort a retype after the backspaces had
        already run. Callers check this before deleting anything.
        """
        if not self._caps.synthetic_input:
            return False
        try:
            return all(ord(ch) <= 0xFFFF for ch in text)
        except TypeError:
            return False

    def type_text(self, text: str) -> bool:
        if not self.can_type(text):
            return False
        kb = self._kb()
        if kb is None:
            return False
        try:
            kb.type(text)
            return True
        except Exception:
            # ValueError for non-BMP, InvalidCharacterException for anything the
            # layout refuses. Either way part of it may have landed, which is
            # why can_type() is the check that matters.
            return False

    def clear_modifiers(self) -> None:
        """Left and right variants both, explicitly.

        The user is still holding the hotkey when the callback runs, so a
        stuck Alt turns our Ctrl+C into Ctrl+Alt+C and nothing copies.
        Releasing a key that is not down is harmless through SendInput.
        """
        kbd, kb = self._keyboard(), self._kb()
        if kbd is None or kb is None:
            return
        names = ("ctrl_l", "ctrl_r", "alt_l", "alt_r", "alt_gr",
                 "shift_l", "shift_r", "cmd_l", "cmd_r")
        for name in names:
            key = getattr(kbd.Key, name, None)
            if key is None:
                continue
            try:
                kb.release(key)
            except Exception:
                pass

    # --- knowing where we are ----------------------------------------------

    def frontmost_app(self) -> AppRef:
        """The foreground exe, as a lowercased basename.

        OpenProcess denial is UNKNOWN_APP on purpose. It correlates with
        elevated and protected processes — exactly the windows we least want
        to type into, and the ones UIPI would silently swallow our keystrokes
        for anyway. Unknown blocks; it must not read as permission.
        """
        if not self._caps.frontmost_app:
            return UNKNOWN_APP
        w = self._w
        ctypes, wintypes = w.ctypes, w.wintypes

        try:
            hwnd = w.user32.GetForegroundWindow()
            if not hwnd:
                return UNKNOWN_APP
            pid = wintypes.DWORD(0)
            w.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if not pid.value:
                return UNKNOWN_APP

            handle = w.kernel32.OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION, False, pid.value)
            if not handle:
                return UNKNOWN_APP
            try:
                path = self._image_path(handle)
            finally:
                w.kernel32.CloseHandle(handle)   # called per keystroke-ish; leak here is fatal
        except Exception:
            return UNKNOWN_APP

        if not path:
            return UNKNOWN_APP
        base = os.path.basename(path.replace("\\", "/"))
        if not base:
            return UNKNOWN_APP
        return AppRef(ident=base.lower(), name=base)

    def _image_path(self, handle) -> Optional[str]:
        """QueryFullProcessImageNameW, small buffer first. Flag 0 gives a Win32
        path; PROCESS_NAME_NATIVE would give \\Device\\Harddisk0\\... instead."""
        w = self._w
        ctypes, wintypes = w.ctypes, w.wintypes
        for length in (512, 32768):          # 32768 is the long-path maximum
            buf = ctypes.create_unicode_buffer(length)
            size = wintypes.DWORD(length)
            ok = w.kernel32.QueryFullProcessImageNameW(
                handle, 0, buf, ctypes.byref(size))
            if ok:
                return buf.value
            if ctypes.get_last_error() != ERROR_INSUFFICIENT_BUFFER:
                return None
        return None

    def secure_input_active(self) -> Tri:
        """Always UNKNOWN. Windows has no system-wide secure-input signal.

        NO here would be the exact lie the app forbids — it would let
        as-you-type replay a sentence into a login form. classic_password_field()
        below is the one partial signal that exists, and it is deliberately not
        wired in, because it cannot see the browsers where passwords are typed.
        """
        return Tri.UNKNOWN

    def classic_password_field(self) -> Tri:
        """YES when the focused control is definitely a Win32 EDIT with
        ES_PASSWORD. Never NO — only UNKNOWN — and that is the whole point.

        This sees Notepad-era dialogs and installers. It is blind to Chromium
        and every Electron app (one Chrome_RenderWidgetHostHWND covers the
        whole page), to WPF (PasswordBox is not an HWND), to UWP, to Qt and to
        Swing. So it can refuse, and it can never permit. Nothing in this file
        calls it; it is here as the only defensible shape a future as-you-type
        on Windows could take — a narrowing filter, not a gate.
        """
        w = self._w
        if w is None:
            return Tri.UNKNOWN
        ctypes = w.ctypes
        try:
            info = w.GUITHREADINFO()
            info.cbSize = ctypes.sizeof(w.GUITHREADINFO)   # or the call fails
            # thread 0 means the foreground thread, and needs no
            # AttachThreadInput — which would be a deadlock on an input path
            if not w.user32.GetGUIThreadInfo(0, ctypes.byref(info)):
                return Tri.UNKNOWN
            focus = info.hwndFocus
            if not focus:
                return Tri.UNKNOWN
            buf = ctypes.create_unicode_buffer(256)
            if not w.user32.GetClassNameW(focus, buf, 256):
                return Tri.UNKNOWN
            if buf.value.lower() != "edit":
                return Tri.UNKNOWN
            style = w.user32.GetWindowLongW(focus, GWL_STYLE)
            return Tri.YES if style & ES_PASSWORD else Tri.UNKNOWN
        except Exception:
            return Tri.UNKNOWN

    # --- hotkey and watcher lifecycle --------------------------------------

    def default_hotkey(self) -> str:
        return DEFAULT_HOTKEY if self._caps.global_hotkey else ""

    def pretty_hotkey(self, hotkey: str) -> str:
        """Ctrl+Alt+Space. The base version strips the separators, which reads
        right for macOS glyphs and wrong for Windows words."""
        parts = [p.strip() for p in (hotkey or "").split("+") if p.strip()]
        if not parts:
            return hotkey
        out = []
        for part in parts:
            low = part.lower()
            if low in _PRETTY:
                out.append(_PRETTY[low])
            elif low.startswith("<") and low.endswith(">"):
                out.append(low[1:-1].capitalize())
            else:
                out.append(part.upper() if len(part) == 1 else part)
        return "+".join(out)

    def start_hotkey(self, hotkey: str, callback: Callable[[], None]) -> bool:
        """False when the listener could not be registered, or started and
        cannot fire. GlobalHotKeys already drops injected events, so our own
        synthetic Ctrl+C can never re-trigger it."""
        self.stop_hotkey()
        if not self._caps.global_hotkey:
            return False
        kbd = self._keyboard()
        if kbd is None:
            return False

        try:
            listener = kbd.GlobalHotKeys({hotkey or DEFAULT_HOTKEY: callback})
            listener.daemon = True
            listener.start()
        except Exception:
            return False   # a bad hotkey string raises here, before anything runs

        time.sleep(LISTENER_SETTLE)
        try:
            alive = listener.is_alive()   # never .running, which stays True
        except Exception:                 # after a permission-denied thread dies
            alive = False
        if not alive:
            try:
                listener.stop()
            except Exception:
                pass
            return False

        self._hotkey_listener = listener
        return True

    def stop_hotkey(self) -> None:
        listener, self._hotkey_listener = self._hotkey_listener, None
        if listener is None:
            return
        try:
            listener.stop()
        except Exception:
            pass

    def start_watcher(self, on_key: Callable[..., None]) -> bool:
        """Always False, and nothing is installed.

        Not "installed and filtered" — not installed. The exposure as-you-type
        creates on Windows is not the correction logic, it is a WH_KEYBOARD_LL
        hook holding plaintext, and there is no reliable way here to know a
        password field has focus (see the module docstring). Declining is the
        honest degradation; a hook behind a probe that is blind to every
        browser would be the dishonest one.
        """
        return False

    def stop_watcher(self) -> None:
        pass          # nothing was ever started

    # --- talking to the user -----------------------------------------------

    def set_notifier(self, notifier: Optional[Callable[[str, str], None]]) -> None:
        """app.py hands us the tray icon's notify once the tray is running.

        caps.notifications follows the notifier rather than the pystray import,
        because that is the only moment the claim becomes true — otherwise
        --doctor prints "notifications yes" on a headless run where every
        message the user was owed is dropped in silence.
        """
        self._notifier = notifier
        self._caps.notifications = notifier is not None

    def notify(self, message: str, title: str = "Backspace",
               sound: bool = False) -> bool:
        """A tray balloon tip. sound is ignored — Windows tray notifications
        have no sound parameter, which caps.notification_sound reports."""
        notifier = self._notifier        # and caps.notifications says so too
        if notifier is None:
            return False
        try:
            notifier(message, title)
            return True
        except Exception:
            return False

    # --- shutdown ----------------------------------------------------------

    def shutdown(self) -> None:
        """Idempotent, and it destroys the clipboard owner window."""
        self.stop_hotkey()
        self.stop_watcher()
        self.set_notifier(None)          # the tray is going away with us
        hwnd, self._owner_hwnd = self._owner_hwnd, None
        if hwnd and self._w is not None:
            try:
                self._w.user32.DestroyWindow(hwnd)
            except Exception:
                pass
        self._caps.clipboard = False


# --- what app.py merges into the shipped defaults --------------------------

def default_blocklist() -> List[str]:
    """Lowercased exe basenames, which is the only shape AppRef.matches() can
    compare against here — a display name like "Visual Studio Code" matches
    nothing on Windows. app.py adds its own entries on top of these.
    """
    return list(DEFAULT_BLOCKLIST)
