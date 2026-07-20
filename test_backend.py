"""Contract tests every backend must pass. Runs anywhere, needs no display.

Run with: python3 -m pytest test_backend.py -q   (or just: python3 test_backend.py)

These do not test that a backend works — CI has no focused text field to type
into and no way to grant Accessibility. They test that a backend tells the
truth about itself, which is the part that can be checked from a runner and
the part that actually keeps text out of password fields.
"""

import backend as backend_mod
from platform_base import (UNKNOWN_APP, AppRef, Backend, Capabilities,
                           NullBackend, Tri)


def subjects():
    """Every backend we can get our hands on here: the null one, plus whatever
    this machine actually selected. Both must satisfy the same contract."""
    return [NullBackend("test"), backend_mod.load_backend()]


# --- Tri: unknown is not no ------------------------------------------------

def test_tri_unknown_blocks():
    assert Tri.NO.blocks is False
    assert Tri.YES.blocks is True
    assert Tri.UNKNOWN.blocks is True     # the whole reason Tri exists


def test_tri_knows_what_it_knows():
    assert Tri.UNKNOWN.known is False
    assert Tri.YES.known and Tri.NO.known
    assert Tri.of(None) is Tri.UNKNOWN
    assert Tri.of(True) is Tri.YES and Tri.of(False) is Tri.NO


# --- AppRef: an unidentified app is not an allowed app ---------------------

def test_unknown_app_matches_nothing_and_says_so():
    assert UNKNOWN_APP.known is False
    assert UNKNOWN_APP.matches(["Terminal"]) is Tri.UNKNOWN
    assert UNKNOWN_APP.matches([]) is Tri.UNKNOWN


def test_blocklist_matching_is_case_and_key_insensitive():
    app = AppRef(ident="com.apple.Terminal", name="Terminal")
    assert app.matches(["com.apple.terminal"]) is Tri.YES
    assert app.matches(["Terminal"]) is Tri.YES
    assert app.matches(["Safari"]) is Tri.NO


def test_bundle_prefix_matches_a_family():
    app = AppRef(ident="com.jetbrains.pycharm", name="PyCharm")
    assert app.matches(["com.jetbrains"]) is Tri.YES
    assert app.matches(["com.jet"]) is Tri.NO   # prefix on dots, not substrings


# --- capabilities: the as-you-type gate ------------------------------------

def test_as_you_type_needs_every_piece():
    full = dict(keystroke_watch=True, synthetic_input=True,
                frontmost_app=True, password_field_detection=True)
    assert Capabilities(**full).as_you_type is True
    for missing in full:
        partial = dict(full, **{missing: False})
        assert Capabilities(**partial).as_you_type is False


def test_no_password_detection_means_no_as_you_type():
    caps = Capabilities(keystroke_watch=True, synthetic_input=True,
                        frontmost_app=True, password_field_detection=False)
    assert caps.as_you_type is False
    assert "password" in caps.why_no_as_you_type()


def test_hotkey_path_does_not_need_password_detection():
    caps = Capabilities(clipboard=True, synthetic_input=True, global_hotkey=True)
    assert caps.hotkey_path is True
    assert caps.as_you_type is False


def test_reason_is_empty_only_when_available():
    caps = Capabilities(keystroke_watch=True, synthetic_input=True,
                        frontmost_app=True, password_field_detection=True)
    assert caps.why_no_as_you_type() == ""
    assert Capabilities().why_no_as_you_type() != ""


# --- the honesty guarantee, on real backends -------------------------------

def test_capabilities_never_raise():
    for b in subjects():
        assert isinstance(b.caps, Capabilities)
        assert isinstance(b.caps.name, str) and b.caps.name


def test_secure_input_is_unknown_when_undetectable():
    """If a backend admits it cannot see password fields, it must not then
    answer NO to secure_input_active() — that is the lie the app forbids."""
    for b in subjects():
        answer = b.secure_input_active()
        assert isinstance(answer, Tri)
        if not b.caps.password_field_detection:
            assert answer is Tri.UNKNOWN, b.caps.name


def test_safe_to_retype_blocks_wherever_as_you_type_is_off():
    for b in subjects():
        if not b.caps.as_you_type:
            assert b.safe_to_retype().blocks is True, b.caps.name


def test_frontmost_app_returns_appref_never_bare_string():
    for b in subjects():
        app = b.frontmost_app()
        assert isinstance(app, AppRef)
        if not b.caps.frontmost_app:
            assert app.known is False
            assert app.matches(["Terminal"]) is Tri.UNKNOWN


def test_clipboard_read_is_none_or_str_never_a_lie():
    for b in subjects():
        text = b.clipboard_read()
        assert text is None or isinstance(text, str)
        if not b.caps.clipboard:
            assert text is None


def test_counter_absent_means_none_not_zero():
    for b in subjects():
        count = b.clipboard_counter()
        assert count is None or isinstance(count, int)
        if not b.caps.clipboard_change_counter:
            assert count is None


def test_cannot_type_when_no_synthetic_input():
    for b in subjects():
        if not b.caps.synthetic_input:
            assert b.can_type("hello") is False
            assert b.type_text("hello") is False


def test_default_hotkey_is_a_string_and_pretty_survives_it():
    for b in subjects():
        hotkey = b.default_hotkey()
        assert isinstance(hotkey, str)
        assert isinstance(b.pretty_hotkey(hotkey), str)
        if b.caps.global_hotkey:
            assert hotkey


def test_starting_a_watcher_is_refused_when_unsafe():
    """The strong form: not "installed and filtered", not installed."""
    for b in subjects():
        if not b.caps.as_you_type:
            assert b.start_watcher(lambda *a: None) is False, b.caps.name
        b.stop_watcher()  # always safe, even when never started


def test_stop_and_shutdown_are_idempotent():
    for b in subjects():
        b.stop_hotkey()
        b.stop_hotkey()
        b.stop_watcher()
        b.shutdown()
        b.shutdown()


def test_notify_reports_whether_it_showed_anything():
    for b in subjects():
        shown = b.notify("contract test")
        assert isinstance(shown, bool)
        if not b.caps.notifications:
            assert shown is False


# --- NullBackend does nothing, and admits all of it ------------------------

def test_null_backend_is_all_false():
    caps = NullBackend("headless").caps
    for attr in ("clipboard", "clipboard_change_counter", "synthetic_input",
                 "global_hotkey", "keystroke_watch", "password_field_detection",
                 "frontmost_app", "tray_icon", "tray_menu", "notifications",
                 "notification_sound"):
        assert getattr(caps, attr) is False, attr
    assert caps.hotkey_path is False and caps.as_you_type is False


def test_null_backend_keeps_the_reason():
    assert "headless" in NullBackend("headless").caps.notes[0]


def test_null_backend_never_touches_anything():
    b = NullBackend()
    assert b.clipboard_write("x") is False
    assert b.capture_selection() is None
    b.copy(); b.paste(); b.backspace(5); b.clear_modifiers()   # must not raise


def test_null_backend_implements_the_whole_interface():
    """Catches an abstract method added to Backend without a Null stub —
    otherwise CI loses its headless fallback at the worst moment."""
    assert isinstance(NullBackend(), Backend)
    for attr in dir(Backend):
        if not attr.startswith("_"):
            assert hasattr(NullBackend(), attr), attr


# --- selection logic -------------------------------------------------------

def test_platform_key_normalises():
    assert backend_mod.platform_key("linux") == "linux"
    assert backend_mod.platform_key("linux2") == "linux"
    assert backend_mod.platform_key("win32") == "win32"
    assert backend_mod.platform_key("darwin") == "darwin"


def test_unknown_platform_falls_back_with_a_reason():
    b = backend_mod.load_backend("plan9")
    assert isinstance(b, NullBackend)
    assert "plan9" in b.caps.notes[0]


def test_every_platform_loads_something_from_anywhere():
    """Asking for a foreign platform's backend must degrade, not explode —
    this is the test that would have caught the AppKit-import-on-Linux bug."""
    for platform in ("darwin", "win32", "linux"):
        b = backend_mod.load_backend(platform)
        assert isinstance(b, Backend)
        assert isinstance(b.caps, Capabilities)


def test_get_backend_is_cached():
    backend_mod.reset()
    try:
        assert backend_mod.get_backend() is backend_mod.get_backend()
    finally:
        backend_mod.reset()


def test_describe_mentions_the_verdicts():
    for b in subjects():
        report = backend_mod.describe(b)
        assert b.caps.name in report
        assert "as-you-type" in report
        assert "password" in report


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                passed += 1
            except AssertionError:
                failed += 1
                print(f"FAIL {name}")
            except Exception as e:
                failed += 1
                print(f"ERROR {name}: {e}")
    print(f"\n{passed} passed, {failed} failed")

    print()
    print(backend_mod.describe())
