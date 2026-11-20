#!/usr/bin/env python3
"""Tiny ingest endpoint for the desync_aa Lua feed. Stdlib only.

POST /ingest  (header X-Token: <INGEST_TOKEN>)  body: {"session": "...", "events": [{"kind": "...", ...}, ...]}
GET  /health  -> "ok"

Listens on 127.0.0.1 only; Caddy terminates TLS and proxies to it.
There is deliberately NO read endpoint: read the data over SSH with sqlite3.
"""
import hmac
import json
import os
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("INGEST_TOKEN", "")
DB_PATH = os.environ.get("INGEST_DB", "/var/lib/hvh-ingest/events.db")
HOST = os.environ.get("INGEST_HOST", "127.0.0.1")
PORT = int(os.environ.get("INGEST_PORT", "8787"))
MAX_BODY = 256 * 1024          # bytes per request
MAX_EVENTS_PER_REQ = 200
MAX_REQ_PER_MIN = 120          # global, simple fixed window

if not TOKEN or len(TOKEN) < 24:
    raise SystemExit("INGEST_TOKEN must be set (24+ chars)")

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
_db = sqlite3.connect(DB_PATH, check_same_thread=False)
_db.execute("PRAGMA journal_mode=WAL")
_db.execute(
    "CREATE TABLE IF NOT EXISTS events ("
    "id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, session TEXT, kind TEXT, data TEXT NOT NULL)"
)
_db.execute("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)")
_db.execute("CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind, ts)")
_db.commit()
_lock = threading.Lock()
_window = {"start": 0.0, "count": 0}


def rate_ok() -> bool:
    now = time.time()
    with _lock:
        if now - _window["start"] >= 60:
            _window["start"], _window["count"] = now, 0
        _window["count"] += 1
        return _window["count"] <= MAX_REQ_PER_MIN


class Handler(BaseHTTPRequestHandler):
    server_version = "ingest"

    def log_message(self, fmt, *args):  # keep journal quiet
        pass

    def _reply(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, b"ok")
        else:
            self._reply(404)

    def do_POST(self):
        if self.path != "/ingest":
            return self._reply(404)
        if not hmac.compare_digest(self.headers.get("X-Token", ""), TOKEN):
            return self._reply(401)
        if not rate_ok():
            return self._reply(429)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400)
        if length <= 0 or length > MAX_BODY:
            return self._reply(413)
        try:
            payload = json.loads(self.rfile.read(length))
            events = payload.get("events", [])
            session = str(payload.get("session", ""))[:64]
            if not isinstance(events, list):
                raise ValueError("events must be a list")
        except (ValueError, AttributeError):
            return self._reply(400)

        now = time.time()
        rows = []
        for ev in events[:MAX_EVENTS_PER_REQ]:
            if not isinstance(ev, dict):
                continue
            rows.append((now, session, str(ev.get("kind", ""))[:32], json.dumps(ev, separators=(",", ":"))))
        with _lock:
            _db.executemany("INSERT INTO events (ts, session, kind, data) VALUES (?,?,?,?)", rows)
            _db.commit()
        self._reply(204)


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
