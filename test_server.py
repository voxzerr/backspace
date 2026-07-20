"""Run with: python3 -m pytest test_server.py -q   (or just: python3 test_server.py)"""

import http.client
import json
import socket
import threading

import backend as backend_mod
import server
from engine import Corrector


def _free_port() -> int:
    """Bind :0 to let the OS hand us an open port. A hardcoded one turns a
    stray listener into a collection crash instead of a test result."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


PORT = _free_port()
GOOD_HOST = "127.0.0.1:%d" % PORT
AUTH = {server.TOKEN_HEADER: server.TOKEN}
SECRET = "my password is hunter2 for the bank"


class Core:
    def __init__(self):
        self.cfg = {"mode": "fix", "as_you_type": False, "blocklist": ["1Password"],
                    "hotkey": ""}
        self.count = 3
        self.last = {"before": SECRET, "after": SECRET.capitalize()}
        self.corrector = Corrector()
        # a real backend, so the as-you-type / hotkey contract is exercised
        # rather than mocked — this is the seam the last regression slipped through
        self.backend = backend_mod.get_backend()
        self.saves = 0

    def save(self):
        self.saves += 1


core = Core()
changes = []
httpd = server.build(core, on_change=lambda: changes.append(1), port=PORT)
threading.Thread(target=httpd.serve_forever, daemon=True).start()


def call(method, path, headers=None, body=None):
    h = {"Host": GOOD_HOST}
    h.update(headers or {})
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    out = (r.status, r.read(), dict(r.getheaders()))
    c.close()
    return out


# --- it refuses what it cannot vouch for ----------------------------------

def test_bad_host_refused():
    status, _, _ = call("GET", "/api/state", {"Host": "evil.example.com", **AUTH})
    assert status == 403


def test_missing_host_refused():
    status, _, _ = call("GET", "/api/state", {"Host": "", **AUTH})
    assert status == 403


def test_cross_origin_refused():
    status, _, _ = call("GET", "/api/state",
                        {"Origin": "https://evil.example.com", **AUTH})
    assert status == 403


def test_own_origin_allowed():
    status, _, _ = call("GET", "/api/state",
                        {"Origin": "http://" + GOOD_HOST, **AUTH})
    assert status == 200


def test_api_without_token_refused():
    status, _, _ = call("GET", "/api/state")
    assert status == 403


def test_wrong_token_refused():
    status, _, _ = call("GET", "/api/state", {server.TOKEN_HEADER: "x" * 43})
    assert status == 403


# --- and it still does its job --------------------------------------------

def test_state_with_token_succeeds():
    status, body, _ = call("GET", "/api/state", AUTH)
    assert status == 200
    state = json.loads(body)
    assert state["count"] == 3 and state["modes"] == server.MODES
    assert "blocklist" in state["config"]


def test_state_leaks_no_corrected_text():
    _, body, _ = call("GET", "/api/state", AUTH)
    state = json.loads(body)
    assert "last" not in state
    assert b"hunter2" not in body
    assert state["last_summary"] == "1 fix"


def test_state_carries_the_ui_contract():
    # the page gates its as-you-type switch and renders the hotkey from these;
    # their absence is exactly the regression that shipped the toggle inert.
    _, body, _ = call("GET", "/api/state", AUTH)
    state = json.loads(body)
    assert isinstance(state["as_you_type_ok"], bool)
    assert "as_you_type_why" in state
    assert "hotkey_pretty" in state


def test_preview_still_corrects():
    status, body, _ = call("POST", "/api/preview", AUTH,
                           json.dumps({"text": "teh cat", "mode": "fix"}))
    assert status == 200
    assert json.loads(body)["text"] == "The cat"


def test_config_write_needs_token():
    before = dict(core.cfg)
    saves = core.saves
    status, _, _ = call("POST", "/api/config", None,
                        json.dumps({"as_you_type": True, "blocklist": []}))
    assert status == 403
    assert core.cfg == before and core.saves == saves


def test_config_write_with_token_succeeds():
    status, _, _ = call("POST", "/api/config", AUTH, json.dumps({"mode": "clean"}))
    assert status == 200
    assert core.cfg["mode"] == "clean" and changes


def test_unknown_post_path_writes_nothing():
    before = dict(core.cfg)
    status, _, _ = call("POST", "/", AUTH, json.dumps({"as_you_type": True}))
    assert status == 404 and core.cfg == before


# --- the page carries the token, and nothing is cached --------------------

def test_page_carries_token():
    status, body, headers = call("GET", "/")
    assert status == 200
    assert ('<meta name="csrf-token" content="%s">' % server.TOKEN).encode() in body
    assert headers["Cache-Control"] == "no-store"


def test_security_headers():
    _, _, headers = call("GET", "/api/state", AUTH)
    assert headers["Cache-Control"] == "no-store"
    assert headers["X-Content-Type-Options"] == "nosniff"


def test_binds_loopback_only():
    assert httpd.server_address[0] == "127.0.0.1"


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
