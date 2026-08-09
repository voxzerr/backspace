"""Local settings server. Plain HTTP on 127.0.0.1 so the UI is just a web page —
which also means it ports straight to Tauri or Electron later if you want a
real window instead of a browser tab.

Loopback binding keeps other machines out. It does not keep out a web page the
user is browsing, because that browser is on this machine, and DNS rebinding
turns the IP check into nothing. So every request is gated on Host, then Origin,
then a per-process token that only a page this server itself rendered can know.
"""

from __future__ import annotations

import json
import re
import secrets
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from engine import summary, word_diff

HERE = Path(__file__).parent
PORT = 8765

# minted once per process and handed only to the page we serve ourselves
TOKEN = secrets.token_urlsafe(32)
TOKEN_HEADER = "X-Backspace-Token"

TOKEN_META = re.compile(rb'<meta\s+name="csrf-token"[^>]*>', re.I)
HEAD_OPEN = re.compile(rb"<head[^>]*>", re.I)

MODES = {
    "fix": "Fix typos",
    "clean": "Clean up",
    "polish": "Make it professional",
}


def _with_token(html: bytes) -> bytes:
    """The page can only prove it is ours because we put the token in it."""
    tag = ('<meta name="csrf-token" content="%s">' % TOKEN).encode()
    if TOKEN_META.search(html):
        return TOKEN_META.sub(lambda _: tag, html, count=1)
    return HEAD_OPEN.sub(lambda m: m.group(0) + b"\n" + tag, html, count=1)


def build(core, on_change=lambda: None, port: int = PORT) -> HTTPServer:
    """`core` needs .cfg, .count, .last, .corrector and .save()."""

    hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
    origins = {"http://" + h for h in hosts}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        # --- responses ------------------------------------------------------

        def send(self, body: bytes, ctype="application/json", code=200):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            # the page carries the live token, so a cross-origin frame that
            # tricked a click on it would act with our authority. Refuse framing.
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)

        # Enough for any real config post; bounded so a lying Content-Length
        # cannot make us read forever.
        DRAIN_LIMIT = 1 << 20

        def drain(self) -> None:
            """Read and discard the request body, so the socket closes cleanly."""
            try:
                remaining = int(self.headers.get("Content-Length", 0) or 0)
            except ValueError:
                return
            remaining = min(remaining, self.DRAIN_LIMIT)
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)

        def refuse(self, why: str) -> bool:
            # A refusal answers a request whose body the gates never read.
            # Closing the connection with bytes still in the receive buffer
            # makes Windows reset it, and the client's recv() then fails with
            # WinError 10053 *before* it can read this response — so the caller
            # sees a dropped connection instead of the 403 telling it what it
            # did wrong. Draining first is what makes the refusal legible.
            self.drain()
            self.send(json.dumps({"error": why}).encode(), code=403)
            return False

        # --- gates: a check that cannot be made is a reason to stop ---------

        def local(self) -> bool:
            """Host first — an absent or foreign Host is how rebinding arrives."""
            if self.headers.get("Host", "") not in hosts:
                return self.refuse("host not allowed")
            origin = self.headers.get("Origin")
            if origin is not None and origin not in origins:
                return self.refuse("cross-origin request refused")
            return True

        def authed(self) -> bool:
            """A page that cannot read our responses cannot have learned this."""
            # compare bytes, not str: compare_digest raises TypeError on a
            # non-ASCII str, and the gate itself must fail closed, not throw.
            got = self.headers.get(TOKEN_HEADER, "").encode("utf-8", "replace")
            if not secrets.compare_digest(got, TOKEN.encode()):
                return self.refuse("missing or bad token")
            return True

        # --- routes ---------------------------------------------------------

        def do_GET(self):
            if not self.local():
                return
            if not self.path.startswith("/api/"):
                return self.send(_with_token((HERE / "settings.html").read_bytes()),
                                 "text/html; charset=utf-8")
            if not self.authed():
                return
            if self.path.startswith("/api/state"):
                last = getattr(core, "last", None) or {}
                before, after = last.get("before", ""), last.get("after", "")
                # the page gates its as-you-type switch and renders the hotkey
                # from these three, so they must ride along or the UI ships
                # inert. Sourced from the backend, defensive so a core without
                # one (a test double) still answers.
                backend = getattr(core, "backend", None)
                caps = getattr(backend, "caps", None)
                return self.send(json.dumps({
                    "config": core.cfg,
                    "count": core.count,
                    "last_summary": summary(before, after) if before else "",
                    "model_ready": core.corrector.available(),
                    "modes": MODES,
                    # never the text itself — it was typed in someone else's window
                    "as_you_type_ok": bool(caps.as_you_type) if caps else False,
                    "as_you_type_why": caps.why_no_as_you_type() if caps else "",
                    "hotkey_pretty": (backend.pretty_hotkey(core.cfg.get("hotkey", ""))
                                      if backend else ""),
                }).encode())
            return self.send(b'{"error":"not found"}', code=404)

        def do_POST(self):
            if not self.local() or not self.authed():
                return

            try:
                # int() inside the try: a non-numeric Content-Length is a
                # malformed request to refuse, not a traceback to leak.
                size = int(self.headers.get("Content-Length", 0) or 0)
                data = json.loads(self.rfile.read(size) or b"{}")
            except ValueError:
                data = None
            if not isinstance(data, dict):
                return self.send(b'{"error":"expected a json object"}', code=400)

            if self.path.startswith("/api/preview"):
                # the user typed this into the settings page, so it is theirs to see
                text = data.get("text", "")
                result = core.corrector.fix(text, data.get("mode", "fix"))
                return self.send(json.dumps({
                    "text": result.text,
                    "diff": word_diff(text, result.text),
                    "summary": summary(text, result.text),
                    "used_llm": result.used_llm,
                    "note": result.note,
                }).encode())

            if self.path.startswith("/api/config"):
                core.cfg.update(data)
                core.save()
                on_change()
                return self.send(b'{"ok":true}')

            return self.send(b'{"error":"not found"}', code=404)

    httpd = HTTPServer(("127.0.0.1", port), Handler)
    httpd.token = TOKEN
    return httpd


def serve(core, on_change=lambda: None, port: int = PORT) -> HTTPServer:
    httpd = build(core, on_change, port)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd
