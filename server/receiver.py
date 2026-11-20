#!/usr/bin/env python3
"""Ingest endpoint, license server and admin panel for unsyk. Stdlib only.

One listener (INGEST_HOST:INGEST_PORT), reached only through Caddy on the VPS:
  POST /ingest  (X-Token or X-Session)  body: {"session": "...", "events": [{"kind": "...", ...}, ...]}
  GET  /config  -> remote-control settings the script applies
  GET  /script.lua -> current unsyk.lua, stamped with version + the downloader's license, uid, sub end, download id
  GET  /version -> short version hash (old scripts)     GET /beat -> {"v", "sub_end", "acct"} (kill-switch heartbeat)
  POST /auth    {"key", "uid", "user"} -> {"session", "expires", "name", "days_left", "sub_end"} (see hvh_auth.py)
  GET  /me      -> {"acct", "name", "days_left", "expires"}
  GET  /cloud   -> {"configs": [...], "official": [...]}   GET /cloud?name=N   ?code=C (shared)   ?preset=N (official)
  POST /cloud   {"op": "save", "name", "data"} | {"op": "delete", "name"}
  GET  /loader.lua (public, no secrets)    GET /health
  Every X-Token endpoint also accepts a license session in X-Session instead of the master token.
  A session is valid only while the key is active and no newer login replaced it (one device at a time).

Admin panel: HOME LAN ONLY, on a second listener (LAN_HOST:LAN_PORT, e.g. http://192.168.68.34:8080/admin).
It is never proxied: the client IP must be in LAN_ALLOW and the Host header must be the LAN address (no DNS
rebinding). The public listener answers 404 for /admin*.
  GET  /admin, /admin/app.js, /admin/app.css   static files from ADMIN_DIR (no secrets in them)
  /admin/api/*  needs the admin cookie (password + TOTP sign-in, hvh_admin.py); POSTs also need X-Panel: 1
                and Origin == the LAN origin.
There is deliberately NO way to read events or the script without either a license session or the admin login.
"""
import hashlib
import hmac
import argparse
import contextlib
import io
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
from collections import Counter, defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TOKEN = os.environ.get("INGEST_TOKEN", "")
DB_PATH = os.environ.get("INGEST_DB", "/var/lib/hvh-ingest/events.db")
CONFIG_PATH = os.environ.get("INGEST_CONFIG", os.path.join(os.path.dirname(DB_PATH), "config.json"))
HOST = os.environ.get("INGEST_HOST", "127.0.0.1")
PORT = int(os.environ.get("INGEST_PORT", "8787"))
SCRIPT_PATH = os.environ.get("SCRIPT_PATH", "/opt/hvh-ingest/unsyk.lua")
LOADER_PATH = os.environ.get("LOADER_PATH", os.path.join(os.path.dirname(SCRIPT_PATH), "loader.lua"))
ADMIN_DIR = os.environ.get("ADMIN_DIR", os.path.join(os.path.dirname(SCRIPT_PATH), "admin"))
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "https://feed.sites.exxo.world")
LAN_HOST = os.environ.get("LAN_HOST", "")
LAN_PORT = int(os.environ.get("LAN_PORT", "8080"))
LAN_ALLOW = [ipaddress.ip_network(n.strip()) for n in os.environ.get("LAN_ALLOW", "192.168.68.0/22").split(",") if n.strip()]
LAN_ORIGIN = f"http://{LAN_HOST}:{LAN_PORT}"
MAX_BODY = 256 * 1024          # bytes per request
MAX_EVENTS_PER_REQ = 200
MAX_REQ_PER_MIN = 120          # global, simple fixed window
MAX_DL_PER_HOUR = 30           # script downloads per account

if not TOKEN or len(TOKEN) < 24:
    raise SystemExit("INGEST_TOKEN must be set (24+ chars)")

# hvhctl.py is deployed next to this file: the panel reuses its formatting, report and config writer.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hvhctl
except Exception as e:  # the ingest side must keep working even if the panel helper is broken
    hvhctl = None
    print(f"panel disabled: cannot import hvhctl ({e})", file=sys.stderr)
import hvh_admin
import hvh_auth
import hvh_cloud
KEYS_PATH = hvh_auth.keys_path(DB_PATH)
ADMIN_PATH = hvh_admin.admin_path(DB_PATH)
CLOUD_DIR = os.environ.get("INGEST_CLOUD", os.path.join(os.path.dirname(DB_PATH), "cloud"))
AUTH_FAILS = {}                # ip -> [failure timestamps]
AUTH_MAX_FAILS = 8             # per IP per 10 minutes
_report_lock = threading.Lock()
_cfg_lock = threading.RLock()   # admin POSTs hold it around api_config, which takes it again

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
_db = sqlite3.connect(DB_PATH, check_same_thread=False)
_db.execute("PRAGMA journal_mode=WAL")
_db.execute(
    "CREATE TABLE IF NOT EXISTS events ("
    "id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, session TEXT, kind TEXT, data TEXT NOT NULL)"
)
_db.execute("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)")
_db.execute("CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind, ts)")
# every served copy of the script: who, from where, which build, and the id stamped into that copy
_db.execute("CREATE TABLE IF NOT EXISTS downloads (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, "
            "acct TEXT, uid INTEGER, ip TEXT, ver TEXT, dl TEXT)")
_db.execute("CREATE INDEX IF NOT EXISTS idx_dl_acct ON downloads(acct, ts)")
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


def read_config() -> bytes:
    try:
        with open(CONFIG_PATH, "rb") as f:
            raw = f.read(64 * 1024)
        json.loads(raw)  # never hand the game a broken file
        return raw
    except (OSError, ValueError):
        return b'{"v":0,"set":{}}'


def script_info():
    """(stamped source bytes, version, mtime string) or None. Version = first 10 hex of sha256 of the file."""
    try:
        with open(SCRIPT_PATH, "rb") as f:
            src = f.read()
        mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(SCRIPT_PATH)))
    except OSError:
        return None
    ver = hashlib.sha256(src).hexdigest()[:10]
    stamped = f'UNSYK_VERSION = "{ver}" -- stamped by the feed server, used for update checks\n'.encode() + src
    return stamped, ver, mtime


# ---------------- panel data (used by the admin API) ----------------

def ro_db():
    con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, timeout=5)
    con.row_factory = sqlite3.Row
    return con


def ev_class(kind, ev):
    if kind == "hit":
        return "death" if (ev.get("hp_after") or 0) <= 0 else "hit"
    if kind == "shot":
        r = ev.get("result")
        if r == "hit":
            return "kill" if isinstance(ev.get("hp_left"), (int, float)) and ev.get("hp_left") <= 0 else "myhit"
        return "fire" if r == "fire" else "miss"
    return kind


def bucket(v, edges, labels):
    if not isinstance(v, (int, float)):
        return "?"
    for e, lab in zip(edges, labels):
        if v <= e:
            return lab
    return labels[-1]


ACCT = "COALESCE(json_extract(data,'$.lic'),'owner')"   # account key: license name, or "owner" for the master token


def q_acct(q):
    a = (q.get("acct") or [""])[0]
    return a if re.fullmatch(r"[\w .:@-]{1,40}", a) else ""


def api_accounts(con):
    """One row per account (license name / owner) with all-time totals and its latest state snapshot."""
    rows = con.execute(
        f"SELECT {ACCT} acct, COUNT(DISTINCT session) sessions, MIN(ts) first, MAX(ts) last,"
        " MAX(json_extract(data,'$.user')) user,"
        " SUM(kind='state') states,"
        " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0) deaths,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit' AND CAST(json_extract(data,'$.hp_left') AS REAL) <= 0) kills,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='fire') fired,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit') landed"
        f" FROM events WHERE kind != 'test' GROUP BY acct ORDER BY last DESC").fetchall()
    snaps = {}
    for r in con.execute(f"SELECT {ACCT} acct, ts, data FROM events WHERE id IN "
                         f"(SELECT MAX(id) FROM events WHERE kind = 'state' GROUP BY {ACCT})").fetchall():
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        snaps[r["acct"]] = {"ts": r["ts"], "ver": ev.get("ver"), "hp": ev.get("hp"), "my_state": ev.get("my_state"),
                            "srv": ev.get("srv"), "wep": (ev.get("my") or {}).get("wep"), "remote": ev.get("remote")}
    out = []
    for r in rows:
        d = dict(r)
        mins = (d.pop("states") or 0) * 5 / 60
        d["alive_min"] = round(mins, 1)
        d["dpm"] = round(d["deaths"] / mins, 2) if mins > 0.5 else None
        d["state"] = snaps.get(d["acct"])
        out.append(d)
    return out


def api_status(q):
    acct = q_acct(q)
    where, args = ("AND " + ACCT + " = ?", (acct,)) if acct else ("", ())
    con = ro_db()
    try:
        sessions = [dict(r) for r in con.execute(
            f"SELECT session, MIN(ts) a, MAX(ts) b, COUNT(*) n, COALESCE(MAX(json_extract(data,'$.lic')),'owner') acct "
            f"FROM events WHERE kind != 'test' {where} GROUP BY session ORDER BY b DESC LIMIT 15", args).fetchall()]
        want = (q.get("session") or ["latest"])[0]
        sess = (sessions[0]["session"] if sessions else "") if want == "latest" else want
        rows = con.execute("SELECT id, ts, kind, data FROM events WHERE session = ? AND kind IN ('hit','shot','state','ctrl') "
                           "ORDER BY id", (sess,)).fetchall()
        last_any = con.execute(f"SELECT MAX(ts) FROM events WHERE 1 {where}", args).fetchone()[0]
        accounts = api_accounts(con)
    finally:
        con.close()

    deaths, hits_taken, fires, myhits, misses, states, ctrls = [], 0, 0, [], [], [], []
    for r in rows:
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        k = r["kind"]
        if k == "hit":
            hits_taken += 1
            if (ev.get("hp_after") or 0) <= 0:
                ev["_ts"] = r["ts"]
                deaths.append(ev)
        elif k == "shot":
            res = ev.get("result")
            if res == "fire":
                fires += 1
            elif res == "hit":
                myhits.append(ev)
            elif res == "miss":
                misses.append(ev)
        elif k == "state":
            ev["_ts"] = r["ts"]
            states.append(ev)
        elif k == "ctrl":
            ev["_ts"] = r["ts"]
            ctrls.append(ev)

    kills = sum(1 for h in myhits if isinstance(h.get("hp_left"), (int, float)) and h["hp_left"] <= 0)
    real_misses = [m for m in misses if not str(m.get("reason")).startswith("death")]
    alive_min = len(states) * 5 / 60
    lk = hvhctl.likely_killer if hvhctl else (lambda e: None)
    ltl = hvhctl.last_tl if hvhctl else (lambda e: {})

    def counter(items, top=8):
        return Counter(items).most_common(top)

    killers = [lk(d) for d in deaths]
    by_cv = defaultdict(lambda: {"min": 0.0, "deaths": 0, "kills": 0})
    for s_ in states:
        by_cv[s_.get("cv") or 0]["min"] += 5 / 60
    for d in deaths:
        by_cv[d.get("cv") or 0]["deaths"] += 1
    for h in myhits:
        if isinstance(h.get("hp_left"), (int, float)) and h["hp_left"] <= 0:
            by_cv[h.get("cv") or 0]["kills"] += 1
    notes = {c.get("v"): c.get("note") for c in ctrls}

    recent = []
    for d in deaths[-8:][::-1]:
        k_ = lk(d) or {}
        me = ltl(d)
        recent.append({"ts": d["_ts"], "dmg": d.get("dmg"), "hp_before": d.get("hp_before"), "state": me.get("state"),
                       "side": me.get("side"), "flip": d.get("flip_age"), "phase": me.get("phase"),
                       "wep": (d.get("my") or {}).get("wep"), "killer": k_.get("name"), "kwep": k_.get("wep"),
                       "kdist": k_.get("dist"), "kpat": k_.get("pat"), "cv": d.get("cv")})

    last = states[-1] if states else {}
    return {
        "now": time.time(), "last_event": last_any, "session": sess, "sessions": sessions, "acct": acct,
        "accounts": accounts,
        "totals": {"deaths": len(deaths), "hits_taken": hits_taken, "kills": kills, "fired": fires, "landed": len(myhits),
                   "misses": len(real_misses), "alive_min": round(alive_min, 1),
                   "one_shots": sum(1 for d in deaths if (d.get("hp_before") or 0) >= 100)},
        "state": {k: last.get(k) for k in ("ver", "job", "hp", "my_state", "side", "lim", "inv", "mod", "pitch", "remote",
                                           "feed", "cv", "srv", "my", "phase")} | {"ts": last.get("_ts")},
        "dist": {
            "flip": counter(bucket(d.get("flip_age"), [1, 4, 10], ["0-1t", "2-4t", "5-10t", "11t+"]) for d in deaths),
            "state": counter(ltl(d).get("state") or "?" for d in deaths),
            "weapon": counter((d.get("my") or {}).get("wep") or "?" for d in deaths),
            "killer": counter(k_.get("name") for k_ in killers if k_),
            "killer_wep": counter(k_.get("wep") for k_ in killers if k_),
            "miss": counter(str(m.get("reason")).split(" ")[0] for m in real_misses),
        },
        "by_cv": [{"v": v, "min": round(x["min"], 1), "deaths": x["deaths"], "kills": x["kills"],
                   "dpm": round(x["deaths"] / x["min"], 2) if x["min"] > 0.5 else None, "note": notes.get(v)}
                  for v, x in sorted(by_cv.items())],
        "recent_deaths": recent,
        "config": cfg_view(acct),
        "keys": {k: ({"t": "b"} if s_ == "b" else {"t": "n", "lo": s_[0], "hi": s_[1]} if isinstance(s_, tuple) else {"t": "c", "o": s_})
                 for k, s_ in (hvhctl.KEYS.items() if hvhctl else [])},
        "ctrl_log": [{"ts": c["_ts"], "v": c.get("v"), "applied": c.get("applied"), "rejected": c.get("rejected"),
                      "restored": c.get("restored"), "note": c.get("note")} for c in ctrls[-10:][::-1]],
    }


def api_live(q):
    try:
        after = int((q.get("after") or ["0"])[0])
    except ValueError:
        after = 0
    acct = q_acct(q)
    where, args = ("AND " + ACCT + " = ?", (acct,)) if acct else ("", ())
    con = ro_db()
    try:
        if after <= 0:
            rows = con.execute("SELECT id, ts, session, kind, data FROM events WHERE kind IN ('hit','shot','ctrl','server') "
                               f"{where} ORDER BY id DESC LIMIT 80", args).fetchall()[::-1]
        else:
            rows = con.execute("SELECT id, ts, session, kind, data FROM events WHERE id > ? AND kind IN ('hit','shot','ctrl','server') "
                               f"{where} ORDER BY id LIMIT 300", (after,) + args).fetchall()
        top = con.execute("SELECT MAX(id) FROM events").fetchone()[0] or 0
    finally:
        con.close()
    out = []
    for r in rows:
        try:
            ev = json.loads(r["data"])
        except ValueError:
            ev = {}
        line = hvhctl.fmt(r) if hvhctl else r["kind"]
        out.append({"id": r["id"], "ts": r["ts"], "kind": r["kind"], "cls": ev_class(r["kind"], ev), "line": line[9:],
                    "acct": ev.get("lic") or "owner"})
    return {"events": out, "last_id": max([after, top] + [e["id"] for e in out])}


def api_report(q):
    if not hvhctl:
        return "panel helper missing"
    sess = (q.get("session") or ["latest"])[0]
    since = (q.get("since") or [""])[0]
    if not re.fullmatch(r"latest|all|s\d{1,20}", sess) or (since and not re.fullmatch(r"\d{1,4}[smhd]", since)):
        return "bad parameters"
    buf = io.StringIO()
    with _report_lock, contextlib.redirect_stdout(buf):
        try:
            hvhctl.cmd_report(argparse.Namespace(session=sess, since=since or None, lic=q_acct(q) or None))
        except Exception as e:  # report bugs should show up in the panel, not kill the thread
            print(f"report failed: {e}")
    return buf.getvalue()


def read_cfg_obj():
    try:
        return json.loads(read_config())
    except ValueError:
        return {"v": 0, "set": {}}


def cfg_view(acct):
    """For the panel: the layer it edits (that account's own overrides, or everyone's) plus what the game gets."""
    g = hvhctl.read_cfg()
    if not acct:
        return {"scope": "everyone", "v": g.get("v", 0), "set": g.get("set") or {}, "everyone": {}, "effective": g.get("set") or {},
                "accounts": {k: (c or {}).get("set") or {} for k, c in hvhctl.read_accounts_cfg().items()}}
    own, eff = hvhctl.read_cfg(acct), hvhctl.effective_cfg(acct)
    return {"scope": acct, "v": eff["v"], "set": own.get("set") or {}, "everyone": g.get("set") or {}, "effective": eff["set"]}


def check_value(key, v):
    spec = hvhctl.KEYS.get(key)
    if spec is None:
        raise ValueError(f"unknown key {key}")
    if spec == "b":
        if isinstance(v, bool):
            return v
        raise ValueError(f"{key} wants true/false")
    if isinstance(spec, tuple):
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not spec[0] <= v <= spec[1]:
            raise ValueError(f"{key} must be a number within {spec[0]}..{spec[1]}")
        return int(v) if float(v).is_integer() else v
    if v in spec:
        return v
    raise ValueError(f"{key} must be one of {spec}")


def api_config(body):
    if not hvhctl:
        raise ValueError("panel helper missing")
    action = body.get("action")
    note = str(body.get("note") or "")[:200]
    acct = body.get("acct") or None
    if acct is not None and (not isinstance(acct, str) or not re.fullmatch(hvhctl.ACCT_NAME_RE, acct)):
        raise ValueError("bad account")
    with _cfg_lock:
        cfg = hvhctl.read_cfg(acct)
        new = dict(cfg.get("set") or {})
        if action == "set":
            vals = body.get("set")
            if not isinstance(vals, dict) or not vals:
                raise ValueError("nothing to set")
            for k, v in vals.items():
                new[k] = check_value(str(k), v)
        elif action == "unset":
            for k in body.get("keys") or []:
                new.pop(str(k), None)
        elif action == "clear":
            new = {}
        else:
            raise ValueError("bad action")
        cfg = {"v": hvhctl.next_v(), "set": new, "note": (note + " [panel]").strip()}
        hvhctl.write_cfg(cfg, acct)
    cfg["acct"] = acct
    return cfg




# ---------------- admin panel API (cookie auth) ----------------

ADMIN_STATIC = {"/admin": ("index.html", "text/html; charset=utf-8"), "/admin/": ("index.html", "text/html; charset=utf-8"),
                "/admin/app.js": ("app.js", "text/javascript; charset=utf-8"),
                "/admin/app.css": ("app.css", "text/css; charset=utf-8")}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self' https://fonts.googleapis.com; "
       "font-src https://fonts.gstatic.com; img-src 'self' data:; connect-src 'self'; "
       "base-uri 'none'; form-action 'self'; frame-ancestors 'none'")


def known_schema():
    """{"Section/Item": {"t": "b"|"n"|"s", "o": [seen strings]}} from every saved and official config."""
    seen = {}
    rows = [c["data"] for c in hvh_cloud.presets(CLOUD_DIR, with_data=True)]
    for r in hvh_cloud.admin_list(CLOUD_DIR):
        c = hvh_cloud.admin_get(CLOUD_DIR, r["acct"], r["name"])
        if c:
            rows.append(c["data"])
    for data in rows:
        for k, v in data.items():
            t = "b" if isinstance(v, bool) else "n" if isinstance(v, (int, float)) else "s"
            s = seen.setdefault(k, {"t": t, "o": set()})
            if t == "s":
                s["o"].add(v)
    return {k: {"t": s["t"], "o": sorted(s["o"])} for k, s in sorted(seen.items())}


def license_rows():
    keys = hvh_auth.list_keys(KEYS_PATH)
    stats = {}
    if hvhctl:
        con = ro_db()
        try:
            for a in api_accounts(con):
                stats[a["acct"]] = a
            dls = {r["acct"]: (r["n"], r["last"]) for r in con.execute(
                "SELECT acct, COUNT(*) n, MAX(ts) last FROM downloads GROUP BY acct").fetchall()}
        finally:
            con.close()
    else:
        dls = {}
    now = time.time()
    for k in keys:
        a = stats.get(k["name"]) or {}
        s = a.get("state") or {}
        k["online"] = bool(s.get("ts") and now - s["ts"] < 20)
        k["seen"] = a.get("last")
        k["kills"], k["deaths"], k["alive_min"] = a.get("kills", 0), a.get("deaths", 0), a.get("alive_min", 0)
        k["ver"] = s.get("ver")
        k["downloads"], k["last_dl"] = dls.get(k["name"], (0, None))
    return keys


class AdminAPI:
    """Mixed into Handler. Every method here runs only after the admin cookie was checked."""

    def _admin_static(self, path):
        name, ctype = ADMIN_STATIC[path]
        try:
            with open(os.path.join(ADMIN_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self._reply(503, b"admin panel not deployed")
        return self._reply(200, body, ctype, admin=True)

    def _admin_tok(self):
        return hvh_admin.cookie_from(self.headers.get("Cookie", ""), secure=False)

    def _admin_body(self, limit=64 * 1024):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length <= 0 or length > limit:
            raise ValueError("bad body size")
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            raise ValueError("body must be an object")
        return body

    def _same_origin(self):
        return self.headers.get("X-Panel") == "1" and self.headers.get("Origin") == LAN_ORIGIN

    def _admin(self, method, path, q):
        aj = lambda obj, code=200: self._reply(code, json.dumps(obj, separators=(",", ":"), default=str).encode(),
                                               "application/json", admin=True)
        if method == "POST" and not self._same_origin():
            return aj({"error": "cross-site request refused"}, 403)
        if path == "/admin/api/login" and method == "POST":
            try:
                b = self._admin_body(2048)
            except ValueError:
                return aj({"error": "bad request"}, 400)
            ok, out = hvh_admin.sign_in(ADMIN_PATH, b.get("user"), b.get("password"), b.get("code"), self._ip())
            print(f"admin sign-in {'ok' if ok else 'FAILED'} ip={self._ip()}", file=sys.stderr)
            if not ok:
                return aj({"error": out}, 429 if "wait" in out or "paused" in out else 401)
            return self._reply(200, b'{"ok":true}', "application/json", admin=True,
                               extra={"Set-Cookie": hvh_admin.cookie_header(out, secure=False)})
        tok = self._admin_tok()
        sess = hvh_admin.check(tok)
        if not sess:
            return aj({"error": "sign in first"}, 401)
        if path == "/admin/api/logout" and method == "POST":
            hvh_admin.sign_out(tok)
            return self._reply(200, b'{"ok":true}', "application/json", admin=True,
                               extra={"Set-Cookie": hvh_admin.cookie_header(None, secure=False)})
        if path == "/admin/api/me":
            return aj({"user": sess["user"], "since": sess["created"], "idle": hvh_admin.IDLE})
        if not hvhctl:
            return aj({"error": "panel helper (hvhctl.py) not deployed"}, 503)
        try:
            if method == "GET":
                return self._admin_get(path, q, aj)
            body = self._admin_body()
            with _cfg_lock:
                out = self._admin_post(path, body)
            if out is None:
                return aj({"error": "not found"}, 404)
            print(f"admin {path} {body.get('op') or body.get('action')} {str(body.get('name') or body.get('acct') or '')[:32]}",
                  file=sys.stderr)
            return aj(out)
        except ValueError as e:
            return aj({"error": str(e)}, 400)
        except sqlite3.Error as e:
            return aj({"error": f"db: {e}"}, 503)
        except Exception as e:  # a panel bug must answer, not drop the connection
            print(f"admin {path} failed: {e!r}", file=sys.stderr)
            return aj({"error": f"server error: {type(e).__name__}"}, 500)

    def _admin_get(self, path, q, aj):
        if path == "/admin/api/status":
            return aj(api_status(q))
        if path == "/admin/api/live":
            return aj(api_live(q))
        if path == "/admin/api/report":
            return self._reply(200, api_report(q).encode(), "text/plain; charset=utf-8", admin=True)
        if path == "/admin/api/export":
            return self._export(q)
        if path == "/admin/api/presets":
            return aj({"presets": hvh_cloud.presets(CLOUD_DIR, with_data=True), "max": hvh_cloud.MAX_PRESETS,
                       "schema": known_schema()})
        if path == "/admin/api/library":
            return aj({"configs": hvh_cloud.admin_list(CLOUD_DIR)})
        if path == "/admin/api/library/item":
            c = hvh_cloud.admin_get(CLOUD_DIR, (q.get("acct") or [""])[0], (q.get("name") or [""])[0])
            return aj(c) if c else aj({"error": "no such config"}, 404)
        if path == "/admin/api/licenses":
            return aj({"keys": license_rows(), "now": time.time()})
        if path == "/admin/api/script":
            info = script_info()
            con = ro_db()
            try:
                dl = [dict(r) for r in con.execute(
                    "SELECT ts, acct, uid, ip, ver, dl FROM downloads ORDER BY id DESC LIMIT 60").fetchall()]
            finally:
                con.close()
            return aj({"ver": info[1] if info else None, "mtime": info[2] if info else None,
                       "size": len(info[0]) if info else 0, "downloads": dl, "base": PUBLIC_BASE})
        if path == "/admin/api/download":
            what = (q.get("f") or [""])[0]
            if what == "loader":
                with open(LOADER_PATH, "rb") as f:
                    return self._reply(200, f.read(), "text/plain; charset=utf-8", admin=True,
                                       extra={"Content-Disposition": 'attachment; filename="loader.lua"'})
            if what == "script":
                info = script_info()
                if not info:
                    return aj({"error": "script not deployed"}, 503)
                body = self._stamp(info[0], "owner", None, None, "admin")
                return self._reply(200, body, "text/plain; charset=utf-8", admin=True,
                                   extra={"Content-Disposition": f'attachment; filename="unsyk_{info[1]}.lua"'})
        return aj({"error": "not found"}, 404)

    def _admin_post(self, path, b):
        op = b.get("op") or b.get("action")
        if path == "/admin/api/overrides":
            return api_config(b)
        if path == "/admin/api/presets":
            if op == "save":
                n = hvh_cloud.preset_save(CLOUD_DIR, b.get("name"), b.get("data"), b.get("note", ""),
                                          b.get("from", ""), b.get("rename_from"))
                return {"ok": True, "name": n}
            if op == "delete":
                hvh_cloud.preset_delete(CLOUD_DIR, b.get("name"))
                return {"ok": True}
            if op == "order":
                names = b.get("names")
                if not isinstance(names, list):
                    raise ValueError("names must be a list")
                hvh_cloud.preset_order(CLOUD_DIR, [str(n) for n in names][:50])
                return {"ok": True}
            raise ValueError("op must be save, delete or order")
        if path == "/admin/api/library":
            acct, name = str(b.get("acct") or ""), str(b.get("name") or "")
            c = hvh_cloud.admin_get(CLOUD_DIR, acct, name)
            if not c:
                raise ValueError("no such config")
            if op == "delete":
                code, out = hvh_cloud.admin_delete(CLOUD_DIR, acct, name)
                if code != 200:
                    raise ValueError(out.get("error", "delete failed"))
                return {"ok": True}
            if op == "publish":
                n = hvh_cloud.preset_save(CLOUD_DIR, b.get("as") or name, c["data"], b.get("note", ""), f"{acct}/{name}")
                return {"ok": True, "name": n}
            raise ValueError("op must be delete or publish")
        if path == "/admin/api/licenses":
            name = str(b.get("name") or "")
            days = b.get("days") or 0
            if not isinstance(days, (int, float)) or isinstance(days, bool) or not 0 <= days <= 3650:
                raise ValueError("days must be 0..3650")
            if op == "add":
                key = hvh_auth.add_key(KEYS_PATH, name, days, b.get("note", ""))
                return {"ok": True, "name": name, "key": key, "invite": hvh_auth.invite_text(key, days, PUBLIC_BASE)}
            if op in ("revoke", "enable", "reset", "extend", "add_days", "kick", "note", "delete"):
                hvh_auth.modify(KEYS_PATH, name, op, days, b.get("note"))
                return {"ok": True}
            raise ValueError("unknown license action")
        return None

    def _export(self, q):
        kind = (q.get("kind") or ["deaths"])[0]
        fmt_ = (q.get("format") or ["csv"])[0]
        since = (q.get("since") or [""])[0]
        if kind not in hvhctl.EXPORT_KINDS or fmt_ not in ("csv", "jsonl") or (since and not re.fullmatch(r"\d{1,4}[smhd]", since)):
            return self._reply(400, b"bad parameters", admin=True)
        acct = q_acct(q) or None
        con = ro_db()
        try:
            body = hvhctl.export_text(con, kind, fmt_, acct=acct, since=hvhctl.parse_since(since or None))
        finally:
            con.close()
        name = f"hvh_{kind}_{acct or 'all'}_{time.strftime('%Y%m%d_%H%M')}.{fmt_}".replace(" ", "_")
        return self._reply(200, body.encode(), "text/csv; charset=utf-8" if fmt_ == "csv" else "application/x-ndjson",
                           admin=True, extra={"Content-Disposition": f'attachment; filename="{name}"'})


class Handler(AdminAPI, BaseHTTPRequestHandler):
    server_version = "ingest"
    sys_version = ""

    def log_message(self, fmt, *args):  # keep journal quiet
        pass

    def _reply(self, code, body=b"", ctype=None, admin=False, extra=None):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        if admin:
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _authed(self) -> bool:
        """Master token (owner) or a valid license session. Sets self.lic to the key name for sessions."""
        self.lic, self.lic_uid, self.sub_end = None, None, None
        tok = self.headers.get("X-Token", "")
        if tok and hmac.compare_digest(tok.encode(), TOKEN.encode()):
            return True
        got = hvh_auth.check_session(TOKEN, KEYS_PATH, self.headers.get("X-Session", ""))
        if got:
            self.lic, self.lic_uid, self.sub_end = got
            return True
        return False

    def _ip(self):
        # only Caddy (over WireGuard) reaches this listener; Caddy replaces any client-sent X-Forwarded-For
        return (self.headers.get("X-Forwarded-For", "") or self.client_address[0]).split(",")[0].strip()[:45]

    def _auth(self):
        ip, now = self._ip(), time.time()
        with _lock:
            fails = [t for t in AUTH_FAILS.get(ip, []) if now - t < 600]
            AUTH_FAILS[ip] = fails
            if len(fails) >= AUTH_MAX_FAILS:
                return self._reply(429, b'{"error":"too many wrong keys, wait 10 minutes"}', "application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2048:
                raise ValueError
            req = json.loads(self.rfile.read(length))
            if not isinstance(req, dict):
                raise ValueError
        except ValueError:
            return self._reply(400, b'{"error":"bad request"}', "application/json")
        try:
            code, out = hvh_auth.login(TOKEN, KEYS_PATH, req.get("key"), req.get("uid"), req.get("user"), ip)
        except OSError:
            code, out = 503, {"error": "server could not save the login, try again"}
        if code != 200:
            with _lock:
                AUTH_FAILS.setdefault(ip, []).append(now)
        print(f"auth {code} ip={ip} user={str(req.get('user'))[:40]} {out.get('name') or out.get('error')}", file=sys.stderr)
        self._reply(code, json.dumps(out).encode(), "application/json")

    def _acct(self):
        return self.lic or "owner"

    def _json(self, code, obj):
        return self._reply(code, json.dumps(obj, separators=(",", ":")).encode(), "application/json")

    def _stamp(self, src, who, uid, sub_end, dl):
        """Watermark a served copy: whose it is (a leaked file names its key), the Roblox account it must run on,
        when the sub ends, and the download id that is also logged in the downloads table."""
        who = re.sub(r'["\\\n]', "", str(who))[:40]
        head = (f'UNSYK_LICENSE = "{who}"\nUNSYK_UID = {int(uid) if uid else "nil"}\n'
                f'UNSYK_SUB_END = {int(sub_end) if sub_end else 0}\nUNSYK_DL = "{dl}"\n')
        return head.encode() + src

    def _serve_script(self):
        info = script_info()
        if not info:
            return self._reply(503)
        acct, now = self._acct(), time.time()
        with _lock:
            n = _db.execute("SELECT COUNT(*) FROM downloads WHERE acct = ? AND ts > ?", (acct, now - 3600)).fetchone()[0]
            if self.lic and n >= MAX_DL_PER_HOUR:
                return self._reply(429, b"too many downloads, wait an hour")
            dl = secrets.token_hex(4)
            _db.execute("INSERT INTO downloads (ts, acct, uid, ip, ver, dl) VALUES (?,?,?,?,?,?)",
                        (now, acct, self.lic_uid, self._ip(), info[1], dl))
            _db.commit()
        return self._reply(200, self._stamp(info[0], acct, self.lic_uid, self.sub_end, dl), "text/plain; charset=utf-8")

    def do_GET(self):
        if self.path == "/health":
            return self._reply(200, b"ok")
        parts = urlsplit(self.path)
        path, q = parts.path, parse_qs(parts.query)
        if path == "/loader.lua":
            # public on purpose: the loader holds no secrets (login happens inside it)
            try:
                with open(LOADER_PATH, "rb") as f:
                    return self._reply(200, f.read(), "text/plain; charset=utf-8")
            except OSError:
                return self._reply(503)
        if not self._authed():
            return self._reply(401) if path in ("/me", "/cloud", "/config", "/script.lua", "/version", "/beat") else self._reply(404)
        if path == "/me":
            info = hvh_auth.entry_info(KEYS_PATH, self.lic) if self.lic else None
            out = {"acct": self._acct(), "name": self._acct(), "days_left": None, "expires": None,
                   "configs": hvh_cloud.count(CLOUD_DIR, self._acct())}
            if info:
                out.update({"days_left": info["days_left"], "expires": info["expires"]})
            return self._json(200, out)
        if path == "/cloud":
            if q.get("preset"):
                code, out = hvh_cloud.preset_get(CLOUD_DIR, q["preset"][0])
                return self._json(code, out)
            code, out = hvh_cloud.get(CLOUD_DIR, self._acct(), (q.get("name") or [None])[0], (q.get("code") or [None])[0])
            if code == 200 and "configs" in out:
                out["official"] = [{"name": p["name"], "ts": p["ts"], "note": p["note"], "official": True}
                                   for p in hvh_cloud.presets(CLOUD_DIR)]
            return self._json(code, out)
        if path == "/config":
            if hvhctl:   # everyone's config with this account's own overrides on top
                cfg = hvhctl.effective_cfg(self.lic or "owner")
                return self._reply(200, json.dumps(cfg, separators=(",", ":")).encode(), "application/json")
            return self._reply(200, read_config(), "application/json")
        if path == "/version":
            info = script_info()
            return self._reply(200, info[1].encode(), "text/plain") if info else self._reply(503)
        if path == "/beat":
            info = script_info()
            return self._json(200, {"v": info[1] if info else None, "sub_end": self.sub_end or 0,
                                    "acct": self._acct(), "now": int(time.time())})
        if path == "/script.lua":
            return self._serve_script()
        self._reply(404)

    def do_POST(self):
        parts = urlsplit(self.path)
        if self.path == "/auth":
            return self._auth()
        if self.path == "/cloud":
            if not self._authed():
                return self._reply(401)
            if not rate_ok():
                return self._reply(429)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > hvh_cloud.MAX_BYTES + 1024:
                    return self._reply(413)
                req = json.loads(self.rfile.read(length))
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                return self._json(400, {"error": "bad request"})
            with _cfg_lock:
                code, out = hvh_cloud.post(CLOUD_DIR, self._acct(), req)
            print(f"cloud {code} acct={self._acct()} op={req.get('op')} name={str(req.get('name'))[:24]}", file=sys.stderr)
            return self._json(code, out)
        if self.path != "/ingest":
            return self._reply(404)
        if not self._authed():
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

        # which Roblox account sent this: name from the script (info only), uid from the license session when there
        # is one (trusted), else from the script. The account key itself stays lic name / "owner".
        user = payload.get("user")
        user = user if isinstance(user, str) and re.fullmatch(r"[A-Za-z0-9_]{1,40}", user) else None
        uid = self.lic_uid if self.lic_uid else payload.get("uid")
        uid = int(uid) if isinstance(uid, (int, float)) and not isinstance(uid, bool) and 0 < uid < 1e15 else None
        now = time.time()
        rows = []
        for ev in events[:MAX_EVENTS_PER_REQ]:
            if not isinstance(ev, dict):
                continue
            ev.pop("lic", None)   # only the server sets these
            ev.pop("user", None); ev.pop("uid", None)
            if self.lic:
                ev["lic"] = self.lic
            if user:
                ev["user"] = user
            if uid:
                ev["uid"] = uid
            rows.append((now, session, str(ev.get("kind", ""))[:32], json.dumps(ev, separators=(",", ":"))))
        with _lock:
            _db.executemany("INSERT INTO events (ts, session, kind, data) VALUES (?,?,?,?)", rows)
            _db.commit()
        self._reply(204)


class LanHandler(Handler):
    """Home-LAN listener: only the admin panel. Not proxied, so the socket address is the real client."""
    server_version = "hvh-lan"

    def _ip(self):
        return self.client_address[0]

    def _allowed(self):
        try:
            client = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        if not any(client in net for net in LAN_ALLOW):
            return False
        return self.headers.get("Host", "") in (LAN_HOST, f"{LAN_HOST}:{LAN_PORT}")

    def do_GET(self):
        if not self._allowed():
            return self._reply(403, b"forbidden")
        parts = urlsplit(self.path)
        if parts.path == "/":
            return self._reply(302, b"", extra={"Location": "/admin"})
        if parts.path in ADMIN_STATIC:
            return self._admin_static(parts.path)
        if parts.path.startswith("/admin/api/"):
            return self._admin("GET", parts.path, parse_qs(parts.query))
        return self._reply(404, b"not found")

    def do_POST(self):
        if not self._allowed():
            return self._reply(403, b"forbidden")
        parts = urlsplit(self.path)
        if parts.path.startswith("/admin/api/"):
            return self._admin("POST", parts.path, parse_qs(parts.query))
        return self._reply(404, b"not found")


if __name__ == "__main__":
    if LAN_HOST:
        lan = ThreadingHTTPServer((LAN_HOST, LAN_PORT), LanHandler)
        threading.Thread(target=lan.serve_forever, daemon=True).start()
    else:
        print("LAN_HOST not set: admin panel disabled", file=sys.stderr)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
