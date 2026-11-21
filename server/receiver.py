#!/usr/bin/env python3
"""Ingest endpoint, license server and admin panel for unsyk. Stdlib only.

One listener (INGEST_HOST:INGEST_PORT), reached only through Caddy on the VPS:
  POST /ingest  (X-Token or X-Session)  body: {"session": "...", "events": [{"kind": "...", ...}, ...]}
  GET  /config  -> remote-control settings the script applies
  GET  /script.lua -> the account's build (stable, or beta for beta members, see hvh_release.py), stamped with
                    version / build / channel + the downloader's license, uid, sub end, download id
  GET  /resolver?b=BUILD -> candidate resolver table for that build (hvh_resolver.py; also /me?resolver=1&b=)
  GET  /version -> short version hash (old scripts)     GET /beat -> {"v", "build", "ch", "sub_end", "acct"} (heartbeat)
  POST /auth    {"key", "uid", "user"} -> {"session", "expires", "name", "days_left", "sub_end"} (see hvh_auth.py)
  GET  /me      -> {"acct", "name", "days_left", "expires"}
  GET  /cloud   -> {"configs": [...], "official": [...]}   GET /cloud?name=N   ?code=C (shared)   ?preset=N (official)
  POST /cloud   {"op": "save", "name", "data"} | {"op": "delete", "name"}
  GET  /loader.lua (public, no secrets)    GET /health
  Every X-Token endpoint also accepts a license session in X-Session instead of the master token.
  A session is valid only while the key is active and no newer login replaced it (one device at a time).

Admin panel: HOME LAN + TAILNET ONLY, never the internet. Listeners: LAN_HOST:LAN_PORT (http://192.168.68.34:8080/admin)
and, if TS_HOST is set, TS_HOST:TS_PORT on the CT's own Tailscale node (http://hvh-admin:8080/admin).
Neither is proxied: the client IP must be in that listener's allow list (LAN_ALLOW / TS_ALLOW) and the Host header
one of its own names (no DNS rebinding). The public listener answers 404 for /admin*.
  GET  /admin, /admin/app.js, /admin/app.css   static files from ADMIN_DIR (no secrets in them)
  /admin/api/*  needs the admin cookie (password + TOTP sign-in, hvh_admin.py); POSTs also need X-Panel: 1
                and Origin == the LAN origin.
There is deliberately NO way to read events or the script without either a license session or the admin login.
"""
import hashlib
import argparse
import contextlib
import hmac
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
# the script's built-in config presets (scripts/extract_builtin.py, shipped by deploy.sh) for the Official presets page
BUILTIN_PATH = os.environ.get("BUILTIN_PATH", os.path.join(os.path.dirname(SCRIPT_PATH), "builtin_presets.json"))
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "https://feed.sites.exxo.world")
LAN_HOST = os.environ.get("LAN_HOST", "")
LAN_PORT = int(os.environ.get("LAN_PORT", "8080"))
LAN_ALLOW = [ipaddress.ip_network(n.strip()) for n in os.environ.get("LAN_ALLOW", "192.168.68.0/22").split(",") if n.strip()]
LAN_ORIGIN = f"http://{LAN_HOST}:{LAN_PORT}"
# Tailnet copy of the admin listener (CT 115 is its own Tailscale node "hvh-admin"). TS_HOST = its 100.x address,
# TS_NAMES = the Host names browsers may use (MagicDNS short + full name). TS_ALLOW = which tailnet peers may connect.
TS_HOST = os.environ.get("TS_HOST", "")
TS_PORT = int(os.environ.get("TS_PORT", str(LAN_PORT)))
TS_NAMES = [n.strip() for n in os.environ.get("TS_NAMES", "").split(",") if n.strip()]
TS_ALLOW = [ipaddress.ip_network(n.strip()) for n in os.environ.get("TS_ALLOW", "100.64.0.0/10").split(",") if n.strip()]
MAX_BODY = 256 * 1024          # bytes per request
MAX_EVENTS_PER_REQ = 200
MAX_REQ_PER_MIN = 120          # per account (license name / owner), fixed window
MAX_REQ_PER_MIN_ALL = 3000     # every account together: the cap that protects the disk
MAX_DL_PER_HOUR = 30           # script downloads per account
MIN_FREE_BYTES = 1 << 30       # refuse new events when the state disk has less than 1 GB free
MAX_THREADS = 64               # concurrent connections per listener; more get dropped at once
SOCKET_TIMEOUT = 20            # seconds a client may stall mid-request (slow-loris)
# Only Caddy (the VPS end of the WireGuard tunnel) may tell us the client IP through X-Forwarded-For.
TRUSTED_PROXY = {p.strip() for p in os.environ.get("TRUSTED_PROXY", "10.8.0.1").split(",") if p.strip()}

if not TOKEN or len(TOKEN) < 24:
    raise SystemExit("INGEST_TOKEN must be set (24+ chars)")
# Key that signs license sessions and heartbeat tokens. Set SESSION_SECRET so a leaked master token cannot be used
# to forge sessions for any key. Unset = derived from INGEST_TOKEN (old behaviour). Changing it logs everyone out once.
SIGN_KEY = os.environ.get("SESSION_SECRET", "") or TOKEN
if SIGN_KEY is not TOKEN and len(SIGN_KEY) < 32:
    raise SystemExit("SESSION_SECRET must be 32+ chars")

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
import hvh_panel
import hvh_release
import hvh_resolver
RELEASES_DIR = hvh_release.releases_dir(DB_PATH)
KEYS_PATH = hvh_auth.keys_path(DB_PATH)
ADMIN_PATH = hvh_admin.admin_path(DB_PATH)
hvh_admin.use_store(ADMIN_PATH)  # admin sign-ins survive restarts/deploys
CLOUD_DIR = os.environ.get("INGEST_CLOUD", os.path.join(os.path.dirname(DB_PATH), "cloud"))
AUTH_FAILS = {}                # ip -> [failure timestamps]
AUTH_MAX_FAILS = 8             # per IP per 10 minutes
GUEST_ACCESS = os.environ.get("GUEST_ACCESS", "1") != "0"   # keyless stable access; GUEST_ACCESS=0 = keys only
GUEST_MAX_PER_IP = 30          # guest logins per IP per 10 minutes
GUEST_LOGINS = {}
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
if "ch" not in [r[1] for r in _db.execute("PRAGMA table_info(downloads)")]:
    _db.execute("ALTER TABLE downloads ADD COLUMN ch TEXT")      # which channel / build that copy came from
    _db.execute("ALTER TABLE downloads ADD COLUMN build INTEGER")
_db.commit()
_lock = threading.Lock()
_window = {"start": 0.0, "all": 0, "acct": {}}
_disk = {"ts": 0.0, "ok": True}


def rate_ok(acct="owner") -> bool:
    """Per-account fixed window, so one account (or one leaked key) cannot use up everyone's budget."""
    now = time.time()
    with _lock:
        if now - _window["start"] >= 60:
            _window["start"], _window["all"], _window["acct"] = now, 0, {}
        n = _window["acct"].get(acct, 0) + 1
        _window["acct"][acct] = n
        _window["all"] += 1
        return n <= MAX_REQ_PER_MIN and _window["all"] <= MAX_REQ_PER_MIN_ALL


def disk_ok() -> bool:
    """False while the state disk is nearly full (checked at most every 30 s): a flood of events must not fill it."""
    now = time.time()
    if now - _disk["ts"] >= 30:
        try:
            s = os.statvfs(os.path.dirname(DB_PATH))
            _disk["ok"] = s.f_bavail * s.f_frsize >= MIN_FREE_BYTES
        except OSError:
            _disk["ok"] = True
        if not _disk["ok"]:
            print("ingest paused: less than 1 GB free on the state disk", file=sys.stderr)
        _disk["ts"] = now
    return _disk["ok"]


def read_json(rfile, length):
    """json.loads that also turns absurdly nested input (RecursionError) into ValueError."""
    try:
        return json.loads(rfile.read(length))
    except RecursionError:
        raise ValueError("too deeply nested") from None


class BoundedServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with a cap on live connection threads."""
    daemon_threads = True

    def __init__(self, *a, **kw):
        self._slots = threading.BoundedSemaphore(MAX_THREADS)
        super().__init__(*a, **kw)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)   # full: drop instead of queueing one more thread
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def read_config() -> bytes:
    try:
        with open(CONFIG_PATH, "rb") as f:
            raw = f.read(64 * 1024)
        json.loads(raw)  # never hand the game a broken file
        return raw
    except (OSError, ValueError):
        return b'{"v":0,"set":{}}'


def script_info(acct=None, channel=None):
    """The build ACCT runs (or CHANNEL's): (stamped source bytes, version, mtime string, build dict) or None.
    Version = first 10 hex of sha256 of the file; build = {"build", "ch", "note", ...} from hvh_release."""
    ch = channel or (hvh_release.channel_for(RELEASES_DIR, acct) if acct else "stable")
    b = hvh_release.build_for(RELEASES_DIR, ch, SCRIPT_PATH)
    if not b:
        return None
    mtime = time.strftime("%Y-%m-%d %H:%M", time.localtime(b["ts"]))
    stamped = (f'UNSYK_VERSION = "{b["ver"]}" -- stamped by the feed server, used for update checks\n'
               f'UNSYK_BUILD = {int(b["build"])}\nUNSYK_CHANNEL = "{b["ch"]}"\n'
               f'UNSYK_RSEED = {hvh_resolver.seed(SIGN_KEY, b["build"])}\n').encode() + b["src"]
    return stamped, b["ver"], mtime, b


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


def api_live_values(con):
    """Latest 'settings' event per account: the remote-controllable values the game has right now (vals), and
    for overridden keys the player's own value underneath (own). Games send one on change and once a minute."""
    out = {}
    for r in con.execute(f"SELECT {ACCT} acct, ts, data FROM events WHERE id IN "
                         f"(SELECT MAX(id) FROM events WHERE kind = 'settings' GROUP BY {ACCT})").fetchall():
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        vals, own = ev.get("vals"), ev.get("own")
        out[r["acct"]] = {"ts": r["ts"], "vals": vals if isinstance(vals, dict) else {},
                          "own": own if isinstance(own, dict) else {}, "remote": ev.get("remote"), "cv": ev.get("cv")}
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
        live_vals = api_live_values(con)
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
        "live_vals": live_vals,
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


def builtin_presets():
    """[{"name", "data"}] the script ships (load-only in game, used when the server has no preset of that name)."""
    try:
        with open(BUILTIN_PATH, "r", encoding="utf-8") as f:
            p = json.load(f).get("presets")
        return [x for x in p if isinstance(x, dict) and isinstance(x.get("name"), str) and isinstance(x.get("data"), dict)]
    except (OSError, ValueError, AttributeError, TypeError):
        return []


def known_schema():
    """{"Section/Item": {"t": "b"|"n"|"s", "o": [seen strings]}} from every saved, official and built-in config."""
    seen = {}
    rows = [c["data"] for c in hvh_cloud.presets(CLOUD_DIR, with_data=True)] + [b["data"] for b in builtin_presets()]
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
    try:
        members = set(hvh_release.load(RELEASES_DIR)["beta_members"])
    except OSError:
        members = set()
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
        k["beta"] = k["name"] in members
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
        body = read_json(self.rfile, length)
        if not isinstance(body, dict):
            raise ValueError("body must be an object")
        return body

    def _same_origin(self):
        origins = getattr(self.server, "origins", (LAN_ORIGIN,))
        return self.headers.get("X-Panel") == "1" and self.headers.get("Origin") in origins

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
        except hvh_auth.StoreError as e:
            print(f"admin {path} key store error: {e}", file=sys.stderr)
            return aj({"error": "key file unreadable, nothing was changed (see the service log)"}, 503)
        except Exception as e:  # a panel bug must answer, not drop the connection
            print(f"admin {path} failed: {e!r}", file=sys.stderr)
            return aj({"error": f"server error: {type(e).__name__}"}, 500)

    def _admin_get(self, path, q, aj):
        if path in ("/admin/api/compare", "/admin/api/health", "/admin/api/sessions", "/admin/api/players",
                    "/admin/api/player"):
            return aj(self._panel_get(path, q))
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
                       "schema": known_schema(), "builtin": builtin_presets()})
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
                    "SELECT ts, acct, uid, ip, ver, dl, ch, build FROM downloads ORDER BY id DESC LIMIT 60").fetchall()]
            finally:
                con.close()
            return aj({"ver": info[1] if info else None, "mtime": info[2] if info else None,
                       "size": len(info[0]) if info else 0, "downloads": dl, "base": PUBLIC_BASE,
                       "releases": hvh_release.summary(RELEASES_DIR),
                       "accounts": ["owner"] + [k["name"] for k in hvh_auth.list_keys(KEYS_PATH)]})
        if path == "/admin/api/download":
            what = (q.get("f") or [""])[0]
            if what == "loader":
                with open(LOADER_PATH, "rb") as f:
                    return self._reply(200, f.read(), "text/plain; charset=utf-8", admin=True,
                                       extra={"Content-Disposition": 'attachment; filename="loader.lua"'})
            if what == "script":
                ch = (q.get("ch") or ["stable"])[0]
                info = script_info(channel="beta" if ch == "beta" else "stable")
                if not info:
                    return aj({"error": "script not deployed"}, 503)
                body = self._stamp(info[0], "owner", None, None, "admin")
                name = f"unsyk_{info[3]['ch']}_{info[3]['build']}_{info[1]}.lua"
                return self._reply(200, body, "text/plain; charset=utf-8", admin=True,
                                   extra={"Content-Disposition": f'attachment; filename="{name}"'})
        return aj({"error": "not found"}, 404)

    def _panel_get(self, path, q):
        """Testing (compare / health / sessions) and Players (players / player) views, see hvh_panel.py."""
        try:
            rel = hvh_release.summary(RELEASES_DIR)
        except OSError:
            rel = {"history": [], "beta_members": []}
        con = ro_db()
        try:
            if path == "/admin/api/compare":
                return hvh_panel.compare(con, q, rel)
            if path == "/admin/api/health":
                return hvh_panel.health(con, q, rel) | {"releases": rel}
            if path == "/admin/api/sessions":
                return hvh_panel.sessions(con, q)
            keys = license_rows()
            members = set(rel.get("beta_members") or [])
            if path == "/admin/api/players":
                return hvh_panel.players(con, q, keys, members)
            name = (q.get("name") or [""])[0]
            if not hvh_panel.NAME_RE.match(name):
                raise ValueError("bad name")
            key = next((k for k in keys if k["name"] == name), None)
            cfgs = [c for c in hvh_cloud.admin_list(CLOUD_DIR) if c["acct"] == name]
            dls = [dict(r) for r in con.execute(
                "SELECT ts, uid, ip, ver, dl, ch, build FROM downloads WHERE acct = ? ORDER BY id DESC LIMIT 50", (name,))]
            return hvh_panel.player(con, name, q, key, members, cfgs, dls)
        finally:
            con.close()

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
                if op == "delete":
                    hvh_release.set_member(RELEASES_DIR, name, False)
                return {"ok": True}
            if op in ("beta_on", "beta_off"):
                if name != "owner" and not any(k["name"] == name for k in hvh_auth.list_keys(KEYS_PATH)):
                    raise ValueError(f"no key named {name}")
                return {"ok": True, "beta_members": hvh_release.set_member(RELEASES_DIR, name, op == "beta_on")}
            raise ValueError("unknown license action")
        if path == "/admin/api/releases":
            if op == "promote":
                r = hvh_release.promote(RELEASES_DIR)
            elif op == "end_beta":
                r = hvh_release.end_beta(RELEASES_DIR)
            elif op == "point":
                build = b.get("build")
                if not isinstance(build, int) or isinstance(build, bool):
                    raise ValueError("build must be a number")
                r = hvh_release.point(RELEASES_DIR, str(b.get("channel") or ""), build)
            else:
                raise ValueError("op must be promote, end_beta or point")
            return {"ok": True, "rec": r}
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
    timeout = SOCKET_TIMEOUT   # socket timeout per connection: a stalled client frees its thread

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
        """Master token (owner) or a valid license session. Sets self.lic to the key name for sessions.
        True / False, or None when the key store cannot be read (callers answer 503)."""
        self.lic, self.lic_uid, self.sub_end = None, None, None
        tok = self.headers.get("X-Token", "")
        if tok and hmac.compare_digest(tok.encode(), TOKEN.encode()):
            return True
        sess = self.headers.get("X-Session", "")
        if GUEST_ACCESS and sess.startswith("g1."):
            got = hvh_auth.check_guest(SIGN_KEY, sess)
            if got:
                self.lic, self.lic_uid, self.sub_end = got
                return True
            return False
        try:
            got = hvh_auth.check_session(SIGN_KEY, KEYS_PATH, sess)
        except hvh_auth.StoreError as e:
            # the key file is unreadable: answer 503, not 401, so scripts keep running instead of stopping
            print(f"auth store error: {e}", file=sys.stderr)
            return None
        if got:
            self.lic, self.lic_uid, self.sub_end = got
            return True
        return False

    def _ip(self):
        # Caddy (over WireGuard) replaces any client-sent X-Forwarded-For; trust the header only from Caddy itself
        if self.client_address[0] not in TRUSTED_PROXY:
            return self.client_address[0]
        return (self.headers.get("X-Forwarded-For", "") or self.client_address[0]).split(",")[0].strip()[:45]

    def _auth(self):
        ip, now = self._ip(), time.time()
        with _lock:
            if len(AUTH_FAILS) > 5000:   # many addresses: drop the ones with nothing recent
                for k in [k for k, v in AUTH_FAILS.items() if not v or now - v[-1] >= 600]:
                    del AUTH_FAILS[k]
            fails = [t for t in AUTH_FAILS.get(ip, []) if now - t < 600]
            AUTH_FAILS[ip] = fails
            if len(fails) >= AUTH_MAX_FAILS:
                return self._reply(429, b'{"error":"too many wrong keys, wait 10 minutes"}', "application/json")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2048:
                raise ValueError
            req = read_json(self.rfile, length)
            if not isinstance(req, dict):
                raise ValueError
        except ValueError:
            return self._reply(400, b'{"error":"bad request"}', "application/json")
        if req.get("guest") and not req.get("key"):
            # keyless stable access: counted per IP (not as a wrong key) so one address cannot mint endless names
            if not GUEST_ACCESS:
                return self._reply(403, b'{"error":"guest access is off, a key is needed"}', "application/json")
            with _lock:
                g = [t for t in GUEST_LOGINS.get(ip, []) if now - t < 600]
                GUEST_LOGINS[ip] = g
                if len(g) >= GUEST_MAX_PER_IP:
                    return self._reply(429, b'{"error":"too many guest logins, wait 10 minutes"}', "application/json")
                g.append(now)
                if len(GUEST_LOGINS) > 5000:
                    for k in [k for k, v in GUEST_LOGINS.items() if not v or now - v[-1] >= 600]:
                        del GUEST_LOGINS[k]
            code, out = hvh_auth.guest_login(SIGN_KEY, req.get("uid"), req.get("user"))
            print(f"guest {code} ip={ip} user={str(req.get('user'))[:40]}", file=sys.stderr)
            return self._reply(code, json.dumps(out).encode(), "application/json")
        try:
            code, out = hvh_auth.login(SIGN_KEY, KEYS_PATH, req.get("key"), req.get("uid"), req.get("user"), ip)
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

    def _rbuild(self, q):
        """The build the client says it runs (?b=N), if the release store knows it (0 = legacy file), else None."""
        try:
            b = int((q.get("b") or [""])[0])
        except ValueError:
            return None
        if b == 0:
            return 0
        try:
            hist = hvh_release.load(RELEASES_DIR)["history"]
        except OSError:
            return None
        return b if any(r.get("build") == b for r in hist) else None

    def _rv(self, q):
        b = self._rbuild(q)
        return hvh_resolver.rv(SIGN_KEY, b) if b is not None else None

    def _resolver(self, q):
        """GET /resolver?b=BUILD: the candidate resolver table for that build (see hvh_resolver.py). Live session or
        master token only (checked before this is called); per account rate limit like ingest."""
        if not rate_ok(self._acct()):
            return self._reply(429)
        b = self._rbuild(q)
        if b is None:
            return self._json(404, {"error": "unknown build"})
        print(f"resolver acct={self._acct()} build={b} ip={self._ip()}", file=sys.stderr)
        return self._json(200, hvh_resolver.table(SIGN_KEY, b))

    def _serve_script(self):
        info = script_info(self._acct())
        if not info:
            return self._reply(503)
        acct, now = self._acct(), time.time()
        with _lock:
            n = _db.execute("SELECT COUNT(*) FROM downloads WHERE acct = ? AND ts > ?", (acct, now - 3600)).fetchone()[0]
            if self.lic and n >= MAX_DL_PER_HOUR:
                return self._reply(429, b"too many downloads, wait an hour")
            dl = secrets.token_hex(4)
            _db.execute("INSERT INTO downloads (ts, acct, uid, ip, ver, dl, ch, build) VALUES (?,?,?,?,?,?,?,?)",
                        (now, acct, self.lic_uid, self._ip(), info[1], dl, info[3]["ch"], info[3]["build"]))
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
        ok = self._authed()
        if ok is None:
            return self._reply(503)
        if not ok:
            return self._reply(401) if path in ("/me", "/cloud", "/config", "/script.lua", "/version", "/beat",
                                                "/resolver") else self._reply(404)
        if path == "/resolver" or (path == "/me" and q.get("resolver")):
            # /me?resolver=1 is the same answer through a route the VPS proxy already forwards
            return self._resolver(q)
        if path == "/me":
            info = hvh_auth.entry_info(KEYS_PATH, self.lic) if self.lic else None
            out = {"acct": self._acct(), "name": self._acct(), "days_left": None, "expires": None,
                   "configs": hvh_cloud.count(CLOUD_DIR, self._acct()),
                   "channel": hvh_release.channel_for(RELEASES_DIR, self._acct())}
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
            info = script_info(self._acct())
            return self._reply(200, info[1].encode(), "text/plain") if info else self._reply(503)
        if path == "/beat":
            info = script_info(self._acct())
            return self._json(200, {"v": info[1] if info else None, "build": info[3]["build"] if info else None,
                                    "ch": info[3]["ch"] if info else None, "sub_end": self.sub_end or 0,
                                    "acct": self._acct(), "now": int(time.time()),
                                    "bt": hvh_auth.beat_token(SIGN_KEY, self._acct()),
                                    "rv": self._rv(q)})
        if path == "/script.lua":
            return self._serve_script()
        self._reply(404)

    def do_POST(self):
        parts = urlsplit(self.path)
        if self.path == "/auth":
            return self._auth()
        if self.path == "/cloud":
            ok = self._authed()
            if not ok:
                return self._reply(503 if ok is None else 401)
            if str(self.lic or "").startswith("guest:"):
                return self._json(403, {"error": "saving cloud configs needs a key"})
            if not rate_ok(self._acct()):
                return self._reply(429)
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > hvh_cloud.MAX_BYTES + 1024:
                    return self._reply(413)
                req = read_json(self.rfile, length)
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
        ok = self._authed()
        if not ok:
            return self._reply(503 if ok is None else 401)
        if not rate_ok(self._acct()):
            return self._reply(429)
        if not disk_ok():
            return self._reply(507)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400)
        if length <= 0 or length > MAX_BODY:
            return self._reply(413)
        try:
            payload = read_json(self.rfile, length)
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
        # Did this batch echo a valid rolling heartbeat token? A stubbed/replayed /beat 200 cannot (it never
        # saw the real token). Only stamped for license sessions; the owner's master token is trusted as-is.
        beat = str(payload.get("beat", ""))[:16]
        beat_ok = bool(self.lic) and bool(beat) and any(
            hmac.compare_digest(beat, hvh_auth.beat_token(SIGN_KEY, self._acct(), now, b)) for b in (0, 1))
        rows = []
        for ev in events[:MAX_EVENTS_PER_REQ]:
            if not isinstance(ev, dict):
                continue
            ev.pop("lic", None)   # only the server sets these
            ev.pop("user", None); ev.pop("uid", None); ev.pop("beat_ok", None)
            if self.lic:
                ev["lic"] = self.lic
                ev["beat_ok"] = beat_ok
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
    """Home-LAN / tailnet listener: only the admin panel. Not proxied, so the socket address is the real client.
    Each server instance carries its own allow (networks), hosts (accepted Host headers) and origins."""
    server_version = "hvh-lan"

    def _ip(self):
        return self.client_address[0]

    def _allowed(self):
        try:
            client = ipaddress.ip_address(self.client_address[0])
        except ValueError:
            return False
        if not any(client in net for net in self.server.allow):
            return False
        return self.headers.get("Host", "") in self.server.hosts

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


def admin_listener(bind, port, allow, names, retry=False):
    """Start one admin listener in a thread. retry=True keeps trying to bind (tailscaled may come up after us)."""
    hosts = set()
    for n in names:
        hosts.update((n, f"{n}:{port}"))

    def bind_once():
        srv = BoundedServer((bind, port), LanHandler)
        srv.allow, srv.hosts = allow, hosts
        srv.origins = tuple(f"http://{h}" for h in sorted(hosts) if ":" in h)
        print(f"admin panel on http://{bind}:{port}/admin", file=sys.stderr)
        return srv

    def run(srv):
        while srv is None:
            try:
                srv = bind_once()
            except OSError as e:
                print(f"admin listener {bind}:{port} not up yet ({e}), retrying in 10s", file=sys.stderr)
                time.sleep(10)
        srv.serve_forever()

    # A LAN bind failure crashes the service (systemd restarts it); the tailnet one waits for tailscaled.
    threading.Thread(target=run, args=(None if retry else bind_once(),), daemon=True).start()


if __name__ == "__main__":
    if LAN_HOST:
        admin_listener(LAN_HOST, LAN_PORT, LAN_ALLOW, [LAN_HOST])
    else:
        print("LAN_HOST not set: LAN admin panel disabled", file=sys.stderr)
    if TS_HOST:
        admin_listener(TS_HOST, TS_PORT, TS_ALLOW, [TS_HOST] + TS_NAMES, retry=True)
    BoundedServer((HOST, PORT), Handler).serve_forever()
