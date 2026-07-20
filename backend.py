"""Picks the backend for this machine, or explains why there isn't one.

Importing this module must never raise, on any platform, with any subset of
libraries installed. That is the whole point of it: app.py used to import
AppKit at line 23 and a Linux user got a traceback from a framework they
have never heard of, three lines before the check that would have told them
what was wrong.

So every platform import happens inside get_backend(), inside a try, and a
failure becomes a NullBackend carrying the reason rather than an exception.
"""

from __future__ import annotations

import sys
from typing import Optional

from platform_base import Backend, Capabilities, NullBackend

# Module names must match the files on disk. They did not until now: this
# mapped to backend_mac/backend_windows/backend_linux while the modules ship as
# platform_*.py, so load_backend() returned a NullBackend on every platform and
# the app was inert everywhere while every test still passed.
_BACKENDS = {
    "darwin": ("platform_mac", "MacBackend"),
    "win32": ("platform_win", "WindowsBackend"),
    "linux": ("platform_linux", "LinuxBackend"),
}

_cached: Optional[Backend] = None


def platform_key(platform: Optional[str] = None) -> str:
    """Normalise sys.platform. linux2 is old but still turns up in the wild."""
    p = platform if platform is not None else sys.platform
    if p.startswith("linux"):
        return "linux"
    if p.startswith("win"):
        return "win32"
    return p


def load_backend(platform: Optional[str] = None) -> Backend:
    """Build a fresh backend. Never raises — a failure comes back as a
    NullBackend whose notes say what was missing."""
    key = platform_key(platform)
    entry = _BACKENDS.get(key)
    if entry is None:
        return NullBackend(f"no backend for platform {key!r}")

    module_name, class_name = entry
    try:
        module = __import__(module_name, fromlist=[class_name])
        return getattr(module, class_name)()
    except ImportError as e:
        # the ordinary case: right platform, dependency not installed
        return NullBackend(f"{module_name} unavailable: {e}")
    except Exception as e:
        # pynput's xorg backend raises DisplayNameError, not ImportError, when
        # there is no display. Anything that gets here still degrades, not dies.
        return NullBackend(f"{module_name} failed to start: "
                           f"{type(e).__name__}: {e}")


def get_backend() -> Backend:
    """The process-wide backend. Cached because probes cost real time and
    the answers do not change while the app is running."""
    global _cached
    if _cached is None:
        _cached = load_backend()
    return _cached


def reset() -> None:
    """Drop the cache. For tests; nothing in the app should need this."""
    global _cached
    _cached = None


# --- the doctor report -----------------------------------------------------

_FIELDS = [
    ("clipboard", "clipboard read/write"),
    ("clipboard_change_counter", "clipboard change counter"),
    ("synthetic_input", "send keystrokes"),
    ("global_hotkey", "global hotkey"),
    ("keystroke_watch", "watch keystrokes"),
    ("password_field_detection", "detect password fields"),
    ("frontmost_app", "identify frontmost app"),
    ("tray_icon", "tray icon"),
    ("tray_menu", "tray menu"),
    ("notifications", "notifications"),
    ("notification_sound", "notification sound"),
]


def describe(backend: Optional[Backend] = None) -> str:
    """Human-readable capability report — what --doctor prints and what CI
    dumps when a platform job fails."""
    b = backend if backend is not None else get_backend()
    caps: Capabilities = b.caps

    lines = ["Backspace backend: {} (sys.platform={})".format(caps.name, sys.platform), ""]
    width = max(len(label) for _, label in _FIELDS)
    for attr, label in _FIELDS:
        mark = "yes" if getattr(caps, attr) else "no"
        lines.append("  {:<{w}}  {}".format(label, mark, w=width))

    lines += [
        "",
        "  {:<{w}}  {}".format("hotkey correction", "available" if caps.hotkey_path
                               else "unavailable", w=width),
        "  {:<{w}}  {}".format("as-you-type", "available" if caps.as_you_type
                               else "unavailable", w=width),
    ]
    if not caps.as_you_type:
        lines.append("      " + caps.why_no_as_you_type())
    if caps.default_hotkey:
        lines.append("")
        lines.append("  default hotkey: {} ({})".format(
            b.pretty_hotkey(caps.default_hotkey), caps.default_hotkey))
    if caps.notes:
        lines.append("")
        lines.append("  notes:")
        for note in caps.notes:
            lines.append("    - " + note)
    return "\n".join(lines)


if __name__ == "__main__":
    print(describe())
