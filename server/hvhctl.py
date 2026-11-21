#!/usr/bin/env python3
"""hvhctl: read the unsyk feed and drive remote control. Runs on the feed box (LXC 115) as root.

  hvhctl sessions [-n 10]                    recent sessions (with who played) + death / shot counts
  hvhctl friends                             per-friend summary: sessions, deaths/min, K/D, last seen
  hvhctl follow [--all]                      live tail, one line per event (Ctrl+C to stop)
  hvhctl events [-n 30] [--kind K] [--session S] [--json]
  hvhctl report [--session latest|all|ID] [--since 2h] [--lic NAME]
  hvhctl config                              show the remote-control config the game polls
  hvhctl config set key=value ... [--note "why"]
  hvhctl config unset key ...                give a key back to the user's own menu value
  hvhctl config clear                        give everything back
  hvhctl keys                                list controllable keys
  hvhctl export [--kind deaths|hits|shots|intel|state|ctrl|uploads|all] [--format csv|jsonl] [--lic NAME] [--since 24h] [--session ID]
                                             flat CSV (one row per event, nested fields as a.b columns) to stdout
  hvhctl cloud                               list everyone's cloud configs (account, name, share code)
  hvhctl license                             list license keys (who, bound account, last login)
  hvhctl license add NAME [--days N]         create a key; it is printed ONCE, only its hash is stored
  hvhctl license revoke|enable|reset NAME    revoke / re-enable / unbind from the Roblox account (all end the session)
  hvhctl license extend NAME --days N        set the expiry to N days from now (0 = never)
  hvhctl license add_days NAME --days N      add N days to the current expiry
  hvhctl license kick NAME                   end the live session now (the script stops in game)
  hvhctl license delete NAME
  hvhctl release                             builds per channel (stable / beta), beta members, history
  hvhctl release publish FILE --channel stable|beta [--note N] [--git G]   new build (scripts/deploy.sh does this)
  hvhctl release promote                     beta build becomes stable (the exact bytes the testers ran)
  hvhctl release rollback stable|beta BUILD  point a channel at an older build
  hvhctl release end-beta                    beta members get stable again
  hvhctl beta [add|remove NAME]              beta members (license names, "owner" = the master token)
  hvhctl admin setup                         set the admin panel user, password and authenticator (TOTP)
"""
import argparse
import csv
import io
import json
import os
import re
import sqlite3
import sys
import time
from collections import Counter, defaultdict

sys.path[:0] = [os.path.dirname(os.path.abspath(__file__)), "/opt/hvh-ingest"]
try:
    import hvh_auth
except ImportError:
    hvh_auth = None
try:
    import hvh_release
except ImportError:
    hvh_release = None

DB_PATH = os.environ.get("INGEST_DB", "/var/lib/hvh-ingest/events.db")
CONFIG_PATH = os.environ.get("INGEST_CONFIG", os.path.join(os.path.dirname(DB_PATH), "config.json"))

# Must match CTRL in unsyk.lua. kind: b=bool, n=(lo, hi), c=[options]
KEYS = {
    "enabled": "b", "pitch": ["Down", "Up", "Zero", "Flick"], "up_fix": "b", "yaw_off": (-180, 180),
    "yaw_mod": ["Disabled", "Center", "Sway", "Spin", "Random", "3-Way", "5-Way"], "mod_amt": (0, 90),
    "lag": (0, 14), "lag_var": (0, 100),
    "inverter": ["Static", "Jitter", "Delayed", "Random", "On-shot flip"],
    "lim_stand": (0, 84), "lim_move": (0, 84), "lim_air": (0, 84), "lim_duck": (0, 84), "lim_rnd": "b",
    "delay": (1, 32), "delay_rnd": (0, 16),
    "def_on": "b", "def_trig": ["interval", "after shot", "always"], "def_int": (100, 2000), "def_len": (1, 14),
    "def_shift": (0, 14), "def_pitch": ["Up", "Down", "Zero", "Jitter"], "def_yaw": (0, 180), "def_flip": "b",
    "def_lag": "b", "def_unch": "b", "def_rand": "b",
    "os_on": "b", "os_mode": ["Flip desync", "Max desync flip", "Flip + yaw 180", "Hide head (pitch zero)"],
    "os_len": (1, 8), "os_unch": "b",
    "rs_mode": ["Off", "Shadow", "Active"], "rs_lead": (-1, 12), "rs_take": (0, 5), "rs_max": (20, 84),
    "peek_mode": ["Off", "Hold side", "Flip then hold", "Max desync hold", "Randomize"], "peek_len": (4, 64),
    "rs_baim": (0, 5), "anim": ["Off", "Freeze in air", "Freeze all", "Jitter"],
    "dodge": ["Off", "On threat", "Always"], "dodge_rate": (20, 250), "dodge_min": (10, 84), "dodge_max": (20, 84),
    "dodge_asym": "b", "dodge_yaw": (0, 45), "dodge_pitch": "b", "dodge_swing": (0, 2000), "dodge_shift": (0, 14),
    "dodge_range": (20, 500), "dodge_hit": "b",
    "flick": "b", "flick_rate": (2, 64), "flick_ticks": (1, 8), "flick_ang": (0, 180),
    "flick_side": ["Strafe fix", "Inverter", "Alternate"], "flick_speed": (0, 60), "flick_choke": "b", "flick_unch": "b",
    "flick_lag": (0, 14),
    "rs_multi": "b", "rs_pitch": "b", "rs_fd": "b",
    "hc_air": (0, 100), "hc_noscope": (0, 100), "hc_duck": (0, 100), "mindmg": (0, 100), "lethal": "b",
    "hc_move": (0, 100), "ns": "b", "ns_hc": (0, 100), "ns_md": (0, 100), "ns_half": "b", "ns_baim": "b",
    "qs": ["Off", "On target", "Snipers only"], "qs_how": ["Auto", "Velocity", "Move", "WalkSpeed"],
    "qs_keep": (0, 100), "qs_hold": (100, 1000), "qs_rest": (0, 1500),
    "style": ["Custom", "Static back", "No AA", "Swap"], "style_lim": (0, 84),
    "style_side": ["Invert key", "Fake left", "Fake right"], "style_swap": (2, 60), "style_jit": (0, 100),
    "style_lag": "b",
    "roll": ["Off", "Static", "Follow desync", "Against desync", "Jitter", "Random"], "roll_amt": (-100, 100),
    "roll_rate": (1, 32), "roll_when": ["Always", "Standing", "On ground", "In air"],
    "fpitch": ["Off", "Down", "Up", "Zero", "Custom", "Jitter"], "fpitch_val": (-70, 70), "fpitch_off": (-20, 20),
    "fpitch_rate": (1, 32),
    "rs_roll": ["Off", "Safe point", "Body aim", "Both"], "rs_lean": (4, 40), "rs_pbrute": "b", "rs_pmiss": (1, 4),
}


def db():
    con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def hm(ts):
    return time.strftime("%H:%M:%S", time.localtime(ts))


def load(row):
    try:
        return json.loads(row["data"])
    except ValueError:
        return {}


def parse_since(s):
    if not s:
        return 0
    unit = {"s": 1, "m": 60, "h": 3600, "d": 86400}[s[-1]]
    return time.time() - float(s[:-1]) * unit


def latest_session(con):
    r = con.execute("SELECT session FROM events WHERE kind != 'test' ORDER BY id DESC LIMIT 1").fetchone()
    return r["session"] if r else None


# ---------- one-line formatting ----------

def likely_killer(ev):
    en = ev.get("enemies") or []
    if not en:
        return None
    scoped = [e for e in en if e.get("scoped")]
    pool = scoped if len(scoped) == 1 else (scoped or en)
    return min(pool, key=lambda e: e.get("dist") or 1e9)


def last_tl(ev):
    tl = ev.get("timeline") or []
    return tl[-1] if tl else {}


def mywep(ev):
    m = ev.get("my") or {}
    return m.get("wep") or "?"


def myw(ev):
    m = ev.get("my") or {}
    bits = [str(m.get("wep") or "?")]
    if m.get("scoped"):
        bits.append("scoped")
    if m.get("spr") is not None:
        bits.append(f"spr={m.get('spr')}")
    if m.get("inacc") is not None:
        bits.append(f"inacc={m.get('inacc')}")
    return " ".join(bits)


def rsw(ev):
    r = ev.get("rs") or {}
    if not r or r.get("off") is None:
        if not r:
            return ""
        extra = " ".join(f"{k}={r[k]}" for k in ("why", "wd", "rv", "tracked", "ttype", "tval", "ticks", "des", "side", "st", "err") if r.get(k) is not None)
        return f" rs={r.get('m', '-')}:no-read {extra}"
    who = "OURS" if r.get("own") else "builtin"
    return (f" rs={r.get('m')}:{who} off={r.get('off')} {r.get('src')} lead={r.get('lead')}t nxt={r.get('nxt')} "
            f"{r.get('st')} pat={r.get('pat')} rv={r.get('rv') or '-'}")


def fmt(row):
    ev = load(row)
    k = row["kind"]
    t = hm(row["ts"])
    cv = ev.get("cv")
    tag = ((f" <{ev['lic']}>" if ev.get("lic") else "")
           + (f" [cfg v{cv}]" if cv else "")
           + (f" [{ev['srv']}]" if ev.get("srv") and ev.get("srv") != "Unknown" else ""))
    if k == "hit":
        dead = (ev.get("hp_after") or 0) <= 0
        me = last_tl(ev)
        kl = likely_killer(ev)
        who = (f"likely {kl.get('name')} ({kl.get('wep')}, {kl.get('dist')}st{', scoped' if kl.get('scoped') else ''}, pat={kl.get('pat')})"
               if kl else "attacker unknown")
        tp = ev.get("tp")
        tps = (f" | TELEPORT {tp.get('name')} {tp.get('jump')}st {tp.get('ms')}ms before ({tp.get('wep')}, {tp.get('dist')}st)"
               if isinstance(tp, dict) else "")
        return (f"{t} {'DEATH' if dead else 'HIT  '} -{ev.get('dmg')} ({ev.get('hp_before')}->{ev.get('hp_after')}) | me {me.get('state')} w/{mywep(ev)} "
                f"side={me.get('side')} lim={me.get('lim')} phase={me.get('phase')} flip={ev.get('flip_age')}t choke={me.get('choke')} "
                f"ping={ev.get('ping')} | {who}{tps} | {ev.get('settings')}{tag}")
    if k == "shot":
        r = ev.get("result")
        if r == "fire":
            return (f"{t} FIRE  [{myw(ev)}] -> {ev.get('target')} {ev.get('hitbox')} pdmg={ev.get('pdmg')} "
                    f"ryaw={ev.get('ryaw')}{rsw(ev)}{' DTPEEK' if ev.get('dtp') else ''}{tag}")
        if r == "hit":
            return f"{t} MYHIT -> {ev.get('target')} {ev.get('hitbox')} -{ev.get('dmg')} left={ev.get('hp_left')} bt={ev.get('bt')}t{tag}"
        return f"{t} MISS  -> {ev.get('target')} {ev.get('hitbox')} reason={ev.get('reason')} | {ev.get('intel') or ''}{tag}"
    if k == "ctrl":
        return f"{t} CTRL  v{ev.get('v')} applied={ev.get('applied')} rejected={ev.get('rejected')} restored={ev.get('restored')} {ev.get('note') or ''}"
    if k == "state":
        return (f"{t} STATE hp={ev.get('hp')} {ev.get('my_state')} w/{myw(ev)} ver={ev.get('ver')} job={ev.get('job')} inv={ev.get('inv')} mod={ev.get('mod')} pitch={ev.get('pitch')} "
                f"dt={ev.get('dt')} peek={ev.get('peek')} anim={ev.get('anim')} baim={ev.get('baim')} remote={ev.get('remote')} feed={ev.get('feed')}{tag}")
    if k == "eshot":
        return (f"{t} ESHOT {ev.get('name')} ({ev.get('wep')}{', scoped' if ev.get('scoped') else ''}, {ev.get('dist')}st, los={ev.get('los')}) "
                f"-> {'HIT ' + str(ev.get('dmg')) if ev.get('hit') else 'missed'} | me {ev.get('mst')} side={ev.get('side')} "
                f"flip={ev.get('flip')}t lim={ev.get('lim')} phase={ev.get('phase')}{tag}")
    if k == "etp":
        pre = f" from {ev.get('pre')}st/s" if ev.get('pre') is not None else ""
        return (f"{t} ETP   {ev.get('name')} jumped {ev.get('jump')}st ({ev.get('spd')}st/s{pre}, {ev.get('wep')}, {ev.get('dist')}st away"
                f"{', recharge ' + str(ev.get('rech')) + 'ms' if ev.get('rech') else ''}) -> "
                f"{'HIT ' + str(ev.get('dmg')) if ev.get('hit') else 'no damage'} | me {ev.get('mst')} side={ev.get('side')} phase={ev.get('phase')}{tag}")
    if k == "server":
        return f"{t} SERVER job={ev.get('job')} place={ev.get('place')}"
    if k == "intel":
        ps = ", ".join(f"{p.get('name')}({p.get('wep')},{p.get('dist')}st,{p.get('pat')})" for p in ev.get("players") or [])
        return f"{t} INTEL {ps}"
    return f"{t} {k.upper()} {json.dumps(ev, separators=(',', ':'))[:300]}"


# ---------- commands ----------

def cmd_sessions(a):
    con = db()
    rows = con.execute(
        "SELECT session, MIN(ts) a, MAX(ts) b, COUNT(*) n,"
        " MAX(json_extract(data,'$.lic')) who,"
        " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0) deaths,"
        " SUM(kind='hit') hits,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='fire') fired,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit') landed"
        " FROM events GROUP BY session ORDER BY MAX(id) DESC LIMIT ?", (a.n,)).fetchall()
    if not rows:
        print("no events yet")
    for r in rows:
        who = r["who"] or "owner"
        print(f"{r['session']:<14} {who:<12} {time.strftime('%m-%d %H:%M', time.localtime(r['a']))} - {hm(r['b'])} "
              f"({(r['b'] - r['a']) / 60:.0f}m)  events={r['n']} deaths={r['deaths']} hits_taken={r['hits']} "
              f"fired={r['fired']} landed={r['landed']}")


def cmd_friends(a):
    con = db()
    rows = con.execute(
        "SELECT COALESCE(json_extract(data,'$.lic'),'owner') who,"
        " COUNT(DISTINCT session) sessions, MIN(ts) a, MAX(ts) b, COUNT(*) n,"
        " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0) deaths,"
        " SUM(kind='hit') hits,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='fire') fired,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit') landed"
        " FROM events GROUP BY who ORDER BY MAX(id) DESC").fetchall()
    if not rows:
        print("no events yet"); return
    print(f"{'who':<14}{'sess':>5}{'deaths':>8}{'K/D':>6}{'hit%':>6}{'last seen':>16}")
    for r in rows:
        kd = (r["fired"] / r["deaths"]) if r["deaths"] else (r["fired"] or 0)
        hitp = (100 * r["landed"] / r["fired"]) if r["fired"] else 0
        last = time.strftime("%m-%d %H:%M", time.localtime(r["b"]))
        print(f"{(r['who'] or 'owner'):<14}{r['sessions']:>5}{r['deaths'] or 0:>8}{kd:>6.1f}{hitp:>5.0f}%{last:>16}")
    print("note: the owner (master token) has no license tag; friends are tagged by their key name.")


def cmd_follow(a):
    con = db()
    last = con.execute("SELECT COALESCE(MAX(id),0) FROM events").fetchone()[0]
    print(f"following from id {last} (Ctrl+C to stop)", flush=True)
    quiet = set() if a.all else {"intel", "state", "eshot"}
    last_cv = None
    while True:
        for r in con.execute("SELECT * FROM events WHERE id > ? ORDER BY id", (last,)):
            last = r["id"]
            if r["kind"] in quiet:
                # still surface a state row when the applied config changes
                if r["kind"] == "state":
                    cv = load(r).get("cv")
                    if cv != last_cv and last_cv is not None:
                        print(fmt(r), flush=True)
                    last_cv = cv
                continue
            print(fmt(r), flush=True)
        time.sleep(1)


def cmd_probe(a):
    """Latest result of each aim probe part (caps / cam / predict), newest first per part."""
    con = db()
    rows = con.execute("SELECT * FROM events WHERE kind = 'diag' AND json_extract(data,'$.what') LIKE 'aim probe%' "
                       "ORDER BY id DESC LIMIT 60").fetchall()
    seen = set()
    for r in rows:
        ev = load(r)
        w = ev.get("what")
        if w in seen:
            continue
        seen.add(w)
        print(f"== {w}  ({hm(r['ts'])}, {r['session']}, {ev.get('lic') or 'owner'}, cv {ev.get('cv')})")
        for k in sorted(ev):
            if k in ("kind", "what", "my", "srv", "lic", "user", "uid", "cv", "t", "id", "ts", "session"):
                continue
            print(f"  {k}: {json.dumps(ev[k]) if isinstance(ev[k], (dict, list)) else ev[k]}")
    if not seen:
        print("no aim probe results yet (caps 10s after load, cam once the mouse is still, predict after 2 alive-min)")


def cmd_events(a):
    con = db()
    q, p = "SELECT * FROM events WHERE 1=1", []
    if a.kind:
        q += " AND kind = ?"; p.append(a.kind)
    if a.session:
        s = latest_session(con) if a.session == "latest" else a.session
        q += " AND session = ?"; p.append(s)
    rows = con.execute(q + " ORDER BY id DESC LIMIT ?", (*p, a.n)).fetchall()[::-1]
    for r in rows:
        print(json.dumps({"id": r["id"], "ts": hm(r["ts"]), "session": r["session"], **load(r)}) if a.json else fmt(r))


# ---------- export ----------

EXPORT_KINDS = {
    "deaths": "kind = 'hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0",
    "hits": "kind = 'hit'",
    "shots": "kind = 'shot'",
    "intel": "kind = 'intel'",
    "state": "kind = 'state'",
    "ctrl": "kind = 'ctrl'",
    "aimwait": "kind = 'aimwait'",       # ragebot target episodes: why it held fire
    "etp": "kind = 'etp'",               # enemy teleports (double tap shifts) seen by the script
    "uploads": "kind IN ('hit_full', 'shotlog')",   # "Upload logs" button: full local timelines + counters
    "all": "kind != 'test'",
}
FIRST_COLS = ["id", "time", "ts", "acct", "user", "session", "kind", "ver", "cv", "srv"]


def _flat(prefix, v, out):
    if isinstance(v, dict):
        for k, x in v.items():
            _flat(f"{prefix}.{k}" if prefix else str(k), x, out)
    elif isinstance(v, list):
        out[prefix] = json.dumps(v, separators=(",", ":"))
    else:
        out[prefix] = v


def export_rows(con, kind, acct=None, since=0, session=None):
    """Flat dicts, one per event (intel: one per tracked player). Deaths/hits get the last timeline row
    and the likely killer as columns; the full timeline stays as JSON in the timeline column."""
    q = f"SELECT * FROM events WHERE {EXPORT_KINDS[kind]}"
    p = []
    if acct:
        q += " AND COALESCE(json_extract(data,'$.lic'),'owner') = ?"; p.append(acct)
    if since:
        q += " AND ts >= ?"; p.append(since)
    if session:
        q += " AND session = ?"; p.append(latest_session(con) if session == "latest" else session)
    for r in con.execute(q + " ORDER BY id", p):
        ev = load(r)
        base = {"id": r["id"], "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(r["ts"])), "ts": round(r["ts"], 2),
                "acct": ev.pop("lic", None) or "owner", "session": r["session"], "kind": r["kind"]}
        if r["kind"] == "intel":
            for pl in ev.pop("players", None) or []:
                row = dict(base)
                _flat("", ev, row)
                _flat("p", pl, row)
                yield row
            continue
        row = dict(base)
        if r["kind"] == "hit":
            row["death"] = (ev.get("hp_after") or 0) <= 0
            _flat("last", last_tl(ev), row)
            _flat("killer", likely_killer(ev) or {}, row)
        _flat("", ev, row)
        yield row


def export_text(con, kind, fmt_="csv", acct=None, since=0, session=None):
    rows = list(export_rows(con, kind, acct, since, session))
    if fmt_ == "jsonl":
        return "".join(json.dumps(r, separators=(",", ":"), default=str) + "\n" for r in rows)
    cols, seen = [c for c in FIRST_COLS], set(FIRST_COLS)
    for r in rows:
        for k in r:
            if k not in seen:
                seen.add(k); cols.append(k)
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow(r)
    return buf.getvalue()


def cmd_export(a):
    con = db()
    sys.stdout.write(export_text(con, a.kind, a.format, acct=a.lic, since=parse_since(a.since), session=a.session))


def cmd_cloud(_a):
    try:
        import hvh_cloud
    except ImportError:
        raise SystemExit("hvh_cloud.py not deployed")
    rows = hvh_cloud.list_all(os.environ.get("INGEST_CLOUD", os.path.join(os.path.dirname(DB_PATH), "cloud")))
    if not rows:
        print("no cloud configs yet"); return
    for acct, name, ts, code, size in rows:
        print(f"  {acct:<14} {name:<26} {code or '-':<8} {size:>4} keys  {time.strftime('%m-%d %H:%M', time.localtime(ts))}")


def pct(n, d):
    return f"{100 * n / d:.0f}%" if d else "-"


def show(title, counter, total=None, top=8):
    if not counter:
        return
    total = total or sum(counter.values())
    items = ", ".join(f"{k} {v} ({pct(v, total)})" for k, v in counter.most_common(top))
    print(f"  {title}: {items}")


def bucket(v, edges, labels):
    if v is None:
        return "?"
    for e, l in zip(edges, labels):
        if v <= e:
            return l
    return labels[-1]


HEARTBEAT_BUILD = 11   # first build that echoes the /beat token; earlier builds can't, so their no-beat is expected


def cmd_abuse(a):
    """License-abuse report: per key, distinct Roblox accounts / IPs / sessions seen, and how much of its
    traffic failed to echo the rolling heartbeat token (a stubbed or replayed /beat, i.e. a tampered copy).
    Flags are advisory — revoke a key yourself with: hvhctl license revoke NAME"""
    con = db()
    since = parse_since(a.since) if a.since else (time.time() - 24 * 3600)
    # events carry lic (key name), uid (Roblox account), beat_ok (bool) and session
    rows = con.execute("SELECT ts, session, data FROM events WHERE ts > ? AND kind != 'test'", (since,)).fetchall()
    dls = con.execute("SELECT acct, uid, ip, ts FROM downloads WHERE ts > ?", (since,)).fetchall()
    per = {}
    for r in rows:
        ev = load(r)
        lic = ev.get("lic")
        if not lic:
            continue
        d = per.setdefault(lic, {"uids": set(), "sess": set(), "ev": 0, "beat_ev": 0, "nobeat": 0, "last": 0, "build": 0})
        d["ev"] += 1
        d["last"] = max(d["last"], r["ts"])
        if ev.get("uid"):
            d["uids"].add(ev["uid"])
        if r["session"]:
            d["sess"].add(r["session"])
        if isinstance(ev.get("build"), (int, float)):
            d["build"] = max(d["build"], int(ev["build"]))
        if "beat_ok" in ev:
            d["beat_ev"] += 1
            if not ev["beat_ok"]:
                d["nobeat"] += 1
    dl_per = {}
    for r in dls:
        d = dl_per.setdefault(r["acct"], {"uids": set(), "ips": set(), "n": 0})
        d["n"] += 1
        if r["uid"]:
            d["uids"].add(r["uid"])
        if r["ip"]:
            d["ips"].add(r["ip"])
    names = sorted(set(per) | set(dl_per))
    if not names:
        print("no license traffic in that window")
        return
    print(f"license abuse check (since {hm(since)}), {len(names)} key(s):\n")
    flagged = []
    for lic in names:
        d = per.get(lic, {"uids": set(), "sess": set(), "ev": 0, "beat_ev": 0, "nobeat": 0, "last": 0, "build": 0})
        dd = dl_per.get(lic, {"uids": set(), "ips": set(), "n": 0})
        uids = d["uids"] | dd["uids"]
        flags = []
        if len(uids) > 1:
            flags.append(f"SHARED: {len(uids)} Roblox accounts")
        if len(dd["ips"]) > 2:
            flags.append(f"{len(dd['ips'])} download IPs")
        nobeat_pct = (d["nobeat"] / d["beat_ev"]) if d["beat_ev"] else 0
        # Only meaningful once the client runs a build that echoes the token (>= #11). A client on an older
        # build can't echo, so its no-beat is 100% and expected; don't flag it as tampered.
        if d["build"] >= HEARTBEAT_BUILD and d["beat_ev"] >= 20 and nobeat_pct > 0.5:
            flags.append(f"TAMPERED: {nobeat_pct*100:.0f}% events miss a valid heartbeat (build {d['build']})")
        tag = "  !! " if flags else "     "
        last = hm(d["last"]) if d["last"] else "-"
        beatcol = pct(d["nobeat"], d["beat_ev"]) if d["build"] >= HEARTBEAT_BUILD else "old"
        print(f"{tag}{lic:<20} accts={len(uids)} ips={len(dd['ips'])} sessions={len(d['sess'])} "
              f"events={d['ev']} no-beat={beatcol} build=#{d['build'] or '?'} dls={dd['n']} last={last}")
        if flags:
            flagged.append(lic)
            print(f"        -> {', '.join(flags)}")
    if flagged:
        print(f"\nflagged: {', '.join(flagged)}")
        print(f"revoke one with:  hvhctl license revoke <name>   (kicks it off every device at once)")
    else:
        print("\nnothing flagged.")


def cmd_report(a):
    con = db()
    q, p = "SELECT * FROM events WHERE kind IN ('hit','shot','state','ctrl','server','eshot','etp','aimwait')", []
    if getattr(a, "lic", None):
        if a.lic == "owner":   # the master token's events carry no license tag
            q += " AND json_extract(data,'$.lic') IS NULL"
        else:
            q += " AND json_extract(data,'$.lic') = ?"; p.append(a.lic)
        print(f"account {a.lic}")
        if a.session == "latest":
            a.session = "all"   # a friend's play spans many sessions
    if a.session != "all":
        s = latest_session(con) if a.session == "latest" else a.session
        if not s:
            print("no events yet"); return
        q += " AND session = ?"; p.append(s)
        print(f"session {s}")
    if a.since:
        q += " AND ts >= ?"; p.append(parse_since(a.since))
    rows = con.execute(q + " ORDER BY id", p).fetchall()
    if not rows:
        print("no matching events"); return
    print(f"window {time.strftime('%m-%d %H:%M', time.localtime(rows[0]['ts']))} - {hm(rows[-1]['ts'])}")

    hits, deaths, fires, myhits, misses, states, ctrls, servers, eshots = [], [], [], [], [], [], [], [], []
    etps, aws = [], []
    for r in rows:
        ev = load(r)
        ev.setdefault("session", r["session"])
        if r["kind"] == "hit":
            hits.append(ev)
            if (ev.get("hp_after") or 0) <= 0:
                deaths.append(ev)
        elif r["kind"] == "shot":
            {"fire": fires, "hit": myhits, "miss": misses}.get(ev.get("result"), []).append(ev)
        elif r["kind"] == "state":
            states.append(ev)
        elif r["kind"] == "ctrl":
            ctrls.append(ev)
        elif r["kind"] == "server":
            servers.append(ev)
        elif r["kind"] == "eshot":
            eshots.append(ev)
        elif r["kind"] == "etp":
            etps.append(ev)
        elif r["kind"] == "aimwait":
            aws.append(ev)

    one_taps = sum(1 for d in deaths if (d.get("hp_before") or 0) >= 100)
    print(f"\nDAMAGE TAKEN: {len(hits)} hits, {len(deaths)} deaths, one-shot from full hp {one_taps} ({pct(one_taps, len(deaths))})")
    if deaths:
        show("death state", Counter(last_tl(d).get("state") for d in deaths))
        show("my weapon", Counter(mywep(d) for d in deaths))
        show("death side", Counter(last_tl(d).get("side") for d in deaths))
        show("death phase", Counter(last_tl(d).get("phase") for d in deaths))
        show("flip age", Counter(bucket(d.get("flip_age"), [1, 4, 10], ["0-1t", "2-4t", "5-10t", "11t+"]) for d in deaths))
        show("limit", Counter(bucket(last_tl(d).get("lim"), [59, 79], ["<60", "60-79", "80+"]) for d in deaths))
        show("choke", Counter(bucket(last_tl(d).get("choke"), [0, 4], ["0", "1-4", "5+"]) for d in deaths))
        show("ping", Counter(bucket(d.get("ping"), [60, 120], ["<=60", "61-120", "120+"]) for d in deaths))
        show("manual yaw", Counter("yes" if last_tl(d).get("man") else "no" for d in deaths))
        show("settings", Counter(d.get("settings") for d in deaths), top=4)
        kills = [likely_killer(d) for d in deaths]
        show("likely killer", Counter(k.get("name") for k in kills if k))
        show("killer weapon", Counter(k.get("wep") for k in kills if k))
        show("killer distance", Counter(bucket(k.get("dist"), [20, 60, 120], ["<=20", "21-60", "61-120", "120+"]) for k in kills if k))
        show("killer scoped", Counter(bool(k.get("scoped")) for k in kills if k))
        show("killer pattern", Counter(k.get("pat") for k in kills if k))

    print(f"\nMY SHOTS: fired {len(fires)}, server hits {len(myhits)} ({pct(len(myhits), len(fires))}), misses {len(misses)}")
    show("miss reason", Counter(str(m.get("reason")).split(" ")[0] for m in misses))
    fired_w = Counter(mywep(f) for f in fires)
    for w, n in fired_w.most_common():
        h = sum(1 for x in myhits if mywep(x) == w)
        mr = Counter(str(m.get("reason")).split(" ")[0] for m in misses if mywep(m) == w)
        sp = [((f.get("my") or {}).get("spr")) for f in fires if mywep(f) == w]
        sp = [x for x in sp if isinstance(x, (int, float))]
        spt = f", spread avg {sum(sp) / len(sp):.4f} max {max(sp):.4f}" if sp else ""
        print(f"  with {w}: fired {n}, hits {h}" + (f", misses {dict(mr)}" if mr else "") + spt)
    show("hitbox on hit", Counter(h.get("hitbox") for h in myhits))
    hc_by_id = {f.get("id"): f.get("hc") for f in fires if f.get("id") is not None}
    for name, group in (("hits", myhits), ("misses", misses)):
        hcs = [hc_by_id[g["id"]] for g in group if g.get("id") in hc_by_id and isinstance(hc_by_id[g["id"]], (int, float))]
        if hcs:
            print(f"  avg hitchance on {name}: {sum(hcs) / len(hcs):.0f} (n={len(hcs)})")
    bt = [h.get("bt") for h in myhits if isinstance(h.get("bt"), (int, float))]
    if bt:
        print(f"  backtrack on hits: avg {sum(bt) / len(bt):.1f}t, max {max(bt)}t")
    per = defaultdict(Counter)
    for f in fires:
        per[f.get("target")]["fired"] += 1
    for h in myhits:
        per[h.get("target")]["hit"] += 1
    for m in misses:
        per[m.get("target")]["miss:" + str(m.get("reason"))] += 1
    for tgt, c in sorted(per.items(), key=lambda kv: -sum(kv[1].values()))[:8]:
        print(f"  vs {tgt}: " + ", ".join(f"{k} {v}" for k, v in c.most_common()))

    srv_d = Counter(d.get("srv") or "Unknown" for d in deaths)
    srv_s = Counter(s.get("srv") or "Unknown" for s in states)
    if len(srv_s) > 1 or (srv_s and "Unknown" not in srv_s):
        print("\nBY SERVER SPREAD LABEL")
        for lab, n in srv_s.most_common():
            mins = n * 5 / 60
            print(f"  {lab}: ~{mins:.1f} min, deaths {srv_d.get(lab, 0)}" + (f", deaths/min {srv_d.get(lab, 0) / mins:.2f}" if mins else ""))
    if servers:
        print(f"\nSERVERS: {len(set(s.get('job') for s in servers))} distinct JobIds in this window")

    # resolver: join each hit/miss to its fire by id to see who resolved (ours vs built-in) and how
    fire_rs = {f.get("id"): f.get("rs") or {} for f in fires if f.get("id") is not None}
    groups = defaultdict(Counter)
    for name, group in (("hit", myhits), ("miss", misses)):
        for g in group:
            r = fire_rs.get(g.get("id"))
            if r is None:
                continue
            reason = "hit" if name == "hit" else str(g.get("reason")).split(" ")[0]
            who = "ours" if r.get("own") else "built-in"
            groups[who][reason] += 1
            if r.get("own"):
                groups["ours:" + str(r.get("src"))][reason] += 1
                groups["ours:" + str(r.get("st"))][reason] += 1
                groups["ours:rv=" + str(r.get("rv") or "-")][reason] += 1
    if groups:
        print("\nRESOLVER (shots joined to their fire; resolver misses are the ones that matter)")
        for k in sorted(groups):
            c = groups[k]
            n = sum(c.values())
            print(f"  {k}: {n} shots, hit {c.get('hit', 0)} ({pct(c.get('hit', 0), n)}), resolver misses {c.get('resolver', 0)}"
                  + (f", other {dict((x, y) for x, y in c.items() if x not in ('hit', 'resolver'))}" if set(c) - {'hit', 'resolver'} else ""))

    # aim wait: ragebot target episodes -> fired or not, how long it held fire, and what blocked it.
    # Most "no shot" episodes are not hesitation (checked 2026-11-21): rage.get_target() keeps a stale snapshot for
    # ~16 ticks, so (a) the ~16 ticks right after our own fire look like a wait, and (b) a target the ragebot saw in
    # only 1-2 scans before it left view shows up as a 15-20 tick "wait". Only the rest are real holds.
    if aws:
        fire_t = defaultdict(list)
        for f in fires:
            if isinstance(f.get("t"), (int, float)):
                fire_t[f.get("session")].append(f["t"])
        for v in fire_t.values():
            v.sort()

        def why_lost(w):
            t, n = w.get("t"), w.get("ticks") or 0
            if isinstance(t, (int, float)):
                t0 = t - n / 64
                prev = [x for x in fire_t.get(w.get("session"), []) if x <= t0 + 0.02]
                if prev and t0 - prev[-1] < 0.1:
                    return "leftover after own shot"
                if prev and t0 - prev[-1] < 1.25 and str(w.get("wep") or "") in ("SSG 08", "AWP"):
                    return "bolt cycling"
            sc = w.get("scans")
            if 14 <= n <= 20 and (sc is None or sc <= 2):
                return "glimpse (seen 1-2 scans)" if sc is not None else "glimpse? (old build, no scan count)"
            return "real hold"

        fired = [w for w in aws if w.get("fired")]
        lost_all = [w for w in aws if not w.get("fired")]
        lost_why = Counter(why_lost(w) for w in lost_all)
        lost = [w for w in lost_all if why_lost(w) == "real hold"]
        print(f"\nAIM WAIT: {len(aws)} target episodes, fired in {len(fired)} ({pct(len(fired), len(aws))}), "
              f"no shot {len(lost_all)}, of which real holds {len(lost)}")
        show("no-shot kind", lost_why)
        def med(xs):
            xs = sorted(x for x in xs if isinstance(x, (int, float)))
            return xs[len(xs) // 2] if xs else None
        tf = [w.get("ticks") for w in fired]
        if tf:
            print(f"  ticks target->fire: median {med(tf)}, >=16t (0.25s) {sum(1 for x in tf if x >= 16)}/{len(tf)}")
        fhc = [w.get("fhc") for w in fired if w.get("fhc")]
        if fhc:
            print(f"  hitchance at fire: min {min(fhc)}, median {med(fhc)}")
        for name, grp in (("fired", fired), ("real hold", lost)):
            if not grp:
                continue
            hcs = [max(h for h in w.get("hc") or [-1]) for w in grp]
            sp = [w.get("smin") for w in grp]
            sc = [w.get("scoped") for w in grp]
            dm = [max(d for d in w.get("dm") or [-1]) for w in grp]
            print(f"  {name}: best live hc median {med(hcs)}, min speed median {med(sp)}, scoped% median {med(sc)}, "
                  f"best dmg median {med(dm)}, ticks median {med([w.get('ticks') for w in grp])}, "
                  f"rescans median {med([w.get('scans') for w in grp])}")
        if lost:
            show("real hold with no-spread mode", Counter("on" if w.get("ns") else "off" for w in lost))
            show("real hold weapon", Counter(w.get("wep") for w in lost))
            show("real hold state", Counter(w.get("mst") for w in lost))
        k = next((w.get("keys") for w in aws if w.get("keys")), None)
        if k:
            print(f"  target fields: {k}")
        for w in lost[-4:]:
            print(f"  e.g. {w.get('who')} {w.get('wep')} {w.get('ticks')}t scoped {w.get('scoped')}% hc {w.get('hc')} "
                  f"speed {w.get('sp')} dmg {w.get('dm')}")

    # enemy teleports (double tap shifts) and the deaths that came right after one. Only hits from builds with the
    # detector count (their enemies carry "tpa" or the hit has "tp").
    dz = [d for d in deaths if "tp" in d or any("tpa" in (x or {}) for x in d.get("enemies") or [])]
    if etps or dz:
        nt = sum(1 for d in dz if isinstance(d.get("tp"), dict))
        nh = sum(1 for e in etps if e.get("hit"))
        print(f"\nENEMY TELEPORTS: {len(etps)} seen, {nh} hit me within 0.35s ({pct(nh, len(etps))}); "
              f"deaths with a teleport <=0.5s before: {nt}/{len(dz)} ({pct(nt, len(dz))})")
        jumps = sorted(e.get("jump") or 0 for e in etps)
        if jumps:
            print(f"  jump size st: median {jumps[len(jumps) // 2]}, max {jumps[-1]}")
        # v2 builds: every enemy on a hit carries tpx = their biggest burst in the last 0.5s (even below the threshold)
        bursts = []
        for d in deaths:
            en = [x for x in d.get("enemies") or [] if isinstance((x or {}).get("tpx"), dict)]
            if en:
                bursts.append(max(x["tpx"].get("ex") or 0 for x in en))
        if bursts:
            bursts.sort()
            big = sum(1 for b in bursts if b >= 2.5)
            print(f"  burst before death (max over enemies, 0.5s): median {bursts[len(bursts) // 2]}st, "
                  f"max {bursts[-1]}st, >=2.5st in {big}/{len(bursts)}")
        dp = [f for f in fires if f.get("dtp")]
        if dp:
            print(f"  DT peek shots: {len(dp)}")
        dtp_ids = {f.get("id") for f in dp}
        if dtp_ids:
            hit_ids = {h.get("id") for h in myhits}
            nhit = sum(1 for i in dtp_ids if i in hit_ids)
            print(f"  DT peek hit rate: {nhit}/{len(dtp_ids)} ({pct(nhit, len(dtp_ids))})")

    # enemy shots: my AA state when they fired, split by whether it hit me. Only shots with line of sight
    # to my head count (los False = a wall in between, likely aimed at someone else; None = unknown).
    es = [e for e in eshots if e.get("los") is not False]
    if es:
        nh = sum(1 for e in es if e.get("hit"))
        print(f"\nENEMY SHOTS AT ME (ammo drops with line of sight): {len(es)}, hit me {nh} ({pct(nh, len(es))}), "
              f"missed {len(es) - nh}  [all ammo drops: {len(eshots)}]")

        def rate(title, keyf, order=None):
            g = defaultdict(lambda: [0, 0])
            for e in es:
                k = keyf(e)
                g[k][0] += 1
                g[k][1] += 1 if e.get("hit") else 0
            keys = order or sorted(g, key=lambda k: -g[k][0])
            parts = [f"{k} {g[k][1]}/{g[k][0]} ({pct(g[k][1], g[k][0])})" for k in keys if k in g]
            print(f"  hit rate by {title}: " + ", ".join(parts))
        rate("flip age", lambda e: bucket(e.get("flip"), [1, 3, 6], ["0-1t", "2-3t", "4-6t", "7t+"]), ["0-1t", "2-3t", "4-6t", "7t+"])
        rate("my state", lambda e: e.get("mst"))
        rate("my side", lambda e: e.get("side"))
        rate("phase", lambda e: str(e.get("phase")).replace("regular", "reg"))
        rate("limit", lambda e: bucket(e.get("lim"), [59, 79], ["<60", "60-79", "80+"]), ["<60", "60-79", "80+"])
        rate("their weapon", lambda e: e.get("wep"))
        rate("distance", lambda e: bucket(e.get("dist"), [20, 60, 120], ["<=20", "21-60", "61-120", "120+"]), ["<=20", "21-60", "61-120", "120+"])
        rate("config", lambda e: f"v{e.get('cv') or 0}")
        top = Counter(e.get("name") for e in es).most_common(6)
        print("  by shooter: " + ", ".join(f"{n} {sum(1 for e in es if e.get('name') == n and e.get('hit'))}/{c}" for n, c in top))

    if states:
        cvs = Counter(s.get("cv") or 0 for s in states)
        dcv = Counter(d.get("cv") or 0 for d in deaths)
        print("\nBY REMOTE CONFIG (time from 5s state snapshots)")
        for cv, n in sorted(cvs.items()):
            mins = n * 5 / 60
            print(f"  v{cv}: ~{mins:.1f} min, deaths {dcv.get(cv, 0)}, deaths/min {dcv.get(cv, 0) / mins:.2f}" if mins else f"  v{cv}")
        for c in ctrls:
            print(f"  ctrl v{c.get('v')}: applied={c.get('applied')} rejected={c.get('rejected')} {c.get('note') or ''}")


# ---------- remote config ----------

# Two layers: config.json = "everyone" (every account), config_accounts.json = {account: {v, set, note, ts}}
# on top of it. An account's effective config is everyone's keys overridden by its own; its version is the
# higher of the two, and all layers share one counter, so any change to either reaches the game as a new v.
ACCT_CONFIG_PATH = os.environ.get("INGEST_ACCT_CONFIG", os.path.join(os.path.dirname(CONFIG_PATH), "config_accounts.json"))
ACCT_NAME_RE = r"[\w .:@-]{1,40}"


def _read_json(path, default):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else default
    except (OSError, ValueError):
        return default


def _write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def read_accounts_cfg():
    return _read_json(ACCT_CONFIG_PATH, {})


def read_cfg(acct=None):
    """One layer: everyone (acct None) or that account's own overrides."""
    if acct:
        c = read_accounts_cfg().get(acct)
        return c if isinstance(c, dict) else {"v": 0, "set": {}}
    return _read_json(CONFIG_PATH, {"v": 0, "set": {}})


def next_v():
    vs = [int(read_cfg().get("v", 0) or 0)] + [int((c or {}).get("v", 0) or 0) for c in read_accounts_cfg().values()]
    return max(vs) + 1


def write_cfg(cfg, acct=None):
    cfg["ts"] = time.time()
    if not acct:
        _write_json(CONFIG_PATH, cfg)
        return
    allc = read_accounts_cfg()
    if cfg.get("set") or cfg.get("v"):
        allc[acct] = cfg
    _write_json(ACCT_CONFIG_PATH, allc)


def effective_cfg(acct):
    """What the game of this account gets from GET /config."""
    g, a = read_cfg(), read_cfg(acct) if acct else {"v": 0, "set": {}}
    gv, av = int(g.get("v", 0) or 0), int(a.get("v", 0) or 0)
    merged = dict(g.get("set") or {})
    merged.update(a.get("set") or {})
    note = (a if av > gv else g).get("note") or ""
    return {"v": max(gv, av), "set": merged, "note": note, "acct": acct, "own": sorted((a.get("set") or {}).keys())}


def coerce(key, raw):
    spec = KEYS.get(key)
    if spec is None:
        raise SystemExit(f"unknown key {key!r} (see: hvhctl keys)")
    if spec == "b":
        if raw.lower() in ("1", "true", "on", "yes"):
            return True
        if raw.lower() in ("0", "false", "off", "no"):
            return False
        raise SystemExit(f"{key} wants true/false")
    if isinstance(spec, tuple):
        try:
            v = float(raw)
        except ValueError:
            raise SystemExit(f"{key} wants a number {spec[0]}..{spec[1]}")
        if not spec[0] <= v <= spec[1]:
            raise SystemExit(f"{key} must be within {spec[0]}..{spec[1]}")
        return int(v) if v.is_integer() else v
    match = [o for o in spec if o.lower() == raw.lower()]
    if not match:
        raise SystemExit(f"{key} must be one of {spec}")
    return match[0]


def cmd_config(a):
    acct = getattr(a, "acct", None)
    if acct is not None and not re.fullmatch(ACCT_NAME_RE, acct):
        raise SystemExit("bad account name")
    cfg = read_cfg(acct)

    def line(label, c):
        age = f", written {time.time() - c['ts']:.0f}s ago" if c.get("ts") else ""
        return f"{label:<14} v{c.get('v', 0)}{age}: {json.dumps(c.get('set', {}))} {c.get('note') or ''}"

    if a.action == "show":
        if acct:
            print(line(f"{acct} (own)", cfg))
            e = effective_cfg(acct)
            print(f"{'effective':<14} v{e['v']}: {json.dumps(e['set'])}")
            return
        print(line("everyone", cfg))
        for name, c in sorted(read_accounts_cfg().items()):
            print(line(name, c))
        return
    new = dict(cfg.get("set", {}))
    if a.action == "set":
        if not a.items:
            raise SystemExit("config set key=value ...")
        for it in a.items:
            if "=" not in it:
                raise SystemExit(f"expected key=value, got {it!r}")
            k, v = it.split("=", 1)
            new[k.strip()] = coerce(k.strip(), v.strip())
    elif a.action == "unset":
        for k in a.items:
            new.pop(k, None)
    elif a.action == "clear":
        new = {}
    cfg = {"v": next_v(), "set": new, "note": a.note or ""}
    write_cfg(cfg, acct)
    who = f"{acct} only" if acct else "everyone"
    print(f"v{cfg['v']} ({who}): {json.dumps(new)} (game applies it within ~5s if Remote control is on)")


def cmd_keys(_a):
    for k, s in KEYS.items():
        print(f"  {k:<10} {'true/false' if s == 'b' else (f'{s[0]}..{s[1]}' if isinstance(s, tuple) else ' | '.join(s))}")


def cmd_license(a):
    if hvh_auth is None:
        raise SystemExit("hvh_auth.py not found next to hvhctl or in /opt/hvh-ingest")
    path = hvh_auth.keys_path(DB_PATH)
    now = time.time()

    def when(t):
        return time.strftime("%m-%d %H:%M", time.localtime(t)) if t else "-"

    if a.action == "list":
        rows = hvh_auth.list_keys(path, now)
        if not rows:
            print("no keys yet: hvhctl license add NAME --days 30")
        for e in rows:
            exp = "never" if not e.get("expires") else f"{(e['expires'] - now) / 86400:.1f}d left"
            acct = f"{e.get('user') or '?'} ({e['uid']})" if e.get("uid") is not None else "unbound"
            print(f"  {e['name']:<16} {e['state']:<12} {exp:<12} {acct:<30} logins={e.get('logins', 0)} last={when(e.get('last'))}")
        return
    if not a.name:
        raise SystemExit(f"license {a.action} NAME")
    try:
        if a.action == "import":
            # re-add a key someone still has in clear (typed hidden, never echoed or logged)
            import getpass
            k = getpass.getpass(f"key for {a.name} (hidden): ")
            hvh_auth.add_key(path, a.name, a.days, "re-imported", key=k)
            print(f"{a.name}: key re-added ({'never expires' if not a.days else f'{a.days:.0f} days'}); "
                  "it binds again to the first Roblox account that logs in with it")
            return
        if a.action == "add":
            k = hvh_auth.add_key(path, a.name, a.days)
            bar = "=" * 60
            print(bar)
            print(f"  KEY FOR {a.name}  ({'never expires' if not a.days else f'expires in {a.days:.0f} days'})")
            print(f"  {k}")
            print(bar)
            print("shown once; only its hash is stored. It locks to the first Roblox account that uses it,")
            print("and works on one device at a time (a new login ends the old session).")
            print()
            print("--- send this to your friend ---")
            print(hvh_auth.invite_text(k, a.days))
            print("--- end ---")
            return
        hvh_auth.modify(path, a.name, a.action, a.days)
        if a.action == "delete" and hvh_release is not None:
            hvh_release.set_member(hvh_release.releases_dir(DB_PATH), a.name, False)
    except ValueError as e:
        raise SystemExit(str(e))
    except hvh_auth.StoreError as e:
        raise SystemExit(f"{e}\nnothing was changed")
    print(f"{a.name}: {a.action} done")


def _rel_dir():
    if hvh_release is None:
        raise SystemExit("hvh_release.py not found next to hvhctl or in /opt/hvh-ingest")
    return hvh_release.releases_dir(DB_PATH)


def _rec_line(r):
    if not r:
        return "-"
    when = time.strftime("%m-%d %H:%M", time.localtime(r.get("moved") or r["ts"]))
    git = f" git {r['git']}" if r.get("git") else ""
    note = f"  {r['note']}" if r.get("note") else ""
    return f"#{r['build']} {r['ver']} ({when}{git}){note}"


def cmd_release(a):
    d = _rel_dir()
    try:
        if a.action == "show":
            s = hvh_release.summary(d)
            st, be = s["stable"], s["beta"]
            print(f"stable  {_rec_line(st)}")
            same = st and be and st["ver"] == be["ver"]
            print(f"beta    {'same as stable' if same else _rec_line(be)}")
            print(f"members {', '.join(s['beta_members']) or '(none)'}")
            print("history:")
            for r in s["history"][:15]:
                tags = [c for c in ("stable", "beta") if s[c] and s[c]["build"] == r["build"]]
                print(f"  {_rec_line(r)}  [{r['ch']}]{'  <- ' + ' '.join(tags) if tags else ''}")
            return
        if a.action == "publish":
            if not a.args:
                raise SystemExit("release publish FILE --channel stable|beta")
            with open(a.args[0], "rb") as f:
                src = f.read()
            r = hvh_release.publish(d, src, a.channel, a.note or "", a.git or "")
            if r.get("unchanged"):
                print(f"{a.channel}: build #{r['build']} {r['ver']} is already live, nothing changed")
            else:
                print(f"{a.channel}: build #{r['build']} {r['ver']} published"
                      + (f" (same bytes as #{r['same_as']})" if r.get("same_as") else ""))
            return
        if a.action == "promote":
            r = hvh_release.promote(d)
            print(f"stable is now build #{r['build']} {r['ver']} (everyone gets it on their next loader start)")
            return
        if a.action == "end-beta":
            r = hvh_release.end_beta(d)
            print(f"beta now = stable build #{r['build']}; beta members get stable on their next loader start")
            return
        if a.action == "rollback":
            if len(a.args) != 2 or a.args[0] not in ("stable", "beta") or not a.args[1].lstrip("#").isdigit():
                raise SystemExit("release rollback stable|beta BUILD")
            r = hvh_release.point(d, a.args[0], int(a.args[1].lstrip("#")))
            print(f"{a.args[0]} now points at build #{r['build']} {r['ver']}")
            return
    except ValueError as e:
        raise SystemExit(str(e))


def cmd_beta(a):
    d = _rel_dir()
    if a.action == "list":
        s = hvh_release.summary(d)
        print(f"beta build: {_rec_line(s['beta'])}")
        print(f"members: {', '.join(s['beta_members']) or '(none)'}")
        return
    if not a.name:
        raise SystemExit(f"beta {a.action} NAME")
    if a.action == "add" and a.name != "owner" and hvh_auth is not None:
        names = {k["name"] for k in hvh_auth.list_keys(hvh_auth.keys_path(DB_PATH))}
        if a.name not in names:
            raise SystemExit(f"no license named {a.name} (hvhctl license lists them; 'owner' = the master token)")
    try:
        m = hvh_release.set_member(d, a.name, a.action == "add")
    except ValueError as e:
        raise SystemExit(str(e))
    print(f"{a.name}: {'in' if a.action == 'add' else 'out of'} beta (members: {', '.join(m) or 'none'}). "
          "Their script prints [UPDATE] within a minute; it switches on their next loader start.")


def cmd_admin(a):
    """Set the admin panel sign-in: user, password (asked twice, never echoed) and a new TOTP secret."""
    import getpass
    try:
        import hvh_admin
    except ImportError:
        raise SystemExit("hvh_admin.py not deployed")
    path = hvh_admin.admin_path(DB_PATH)
    if a.action == "show":
        c = hvh_admin.load(path)
        print(f"admin user: {c['user']}" if c else "not set up: hvhctl admin setup")
        return
    user = input("admin user name: ").strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]{3,32}", user):
        raise SystemExit("user: 3-32 letters, digits, _ . -")
    pw = getpass.getpass("password (12+ chars): ")
    if len(pw) < 12:
        raise SystemExit("too short")
    if getpass.getpass("again: ") != pw:
        raise SystemExit("passwords differ")
    secret = hvh_admin.new_totp_secret()
    print()
    print("Add this to your authenticator app (Google Authenticator, 1Password, Aegis, ...):")
    print(f"  secret: {secret}")
    print(f"  or as a link / QR text: {hvh_admin.otpauth_uri(secret, user)}")
    for _ in range(3):
        code = input("enter the 6-digit code it shows now: ").strip()
        if hvh_admin.totp_match(secret, code) is not None:
            break
        print("that code does not match, check the secret and the phone's clock")
    else:
        raise SystemExit("not saved")
    hvh_admin.save(path, {"user": user, "pw": hvh_admin.hash_password(pw), "totp": secret, "last_step": 0,
                          "created": int(time.time())}, owner_of=os.path.dirname(path))
    print(f"saved {path}. Restart the service to end any open admin sessions: systemctl restart hvh-ingest")


def main():
    ap = argparse.ArgumentParser(prog="hvhctl")
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("sessions"); p.add_argument("-n", type=int, default=10); p.set_defaults(fn=cmd_sessions)
    p = sp.add_parser("follow"); p.add_argument("--all", action="store_true"); p.set_defaults(fn=cmd_follow)
    p = sp.add_parser("events"); p.add_argument("-n", type=int, default=30); p.add_argument("--kind")
    p.add_argument("--session"); p.add_argument("--json", action="store_true"); p.set_defaults(fn=cmd_events)
    p = sp.add_parser("report"); p.add_argument("--session", default="latest"); p.add_argument("--since")
    p.add_argument("--lic"); p.set_defaults(fn=cmd_report)
    p = sp.add_parser("friends"); p.set_defaults(fn=cmd_friends)
    p = sp.add_parser("abuse"); p.add_argument("--since", help="e.g. 24h, 7d (default 24h)"); p.set_defaults(fn=cmd_abuse)
    p = sp.add_parser("probe"); p.set_defaults(fn=cmd_probe)
    p = sp.add_parser("config"); p.add_argument("action", nargs="?", default="show", choices=["show", "set", "unset", "clear"])
    p.add_argument("items", nargs="*"); p.add_argument("--note")
    p.add_argument("--acct", help="one account (license name or owner) instead of everyone"); p.set_defaults(fn=cmd_config)
    p = sp.add_parser("keys"); p.set_defaults(fn=cmd_keys)
    p = sp.add_parser("export"); p.add_argument("--kind", default="deaths", choices=list(EXPORT_KINDS))
    p.add_argument("--format", default="csv", choices=["csv", "jsonl"]); p.add_argument("--lic")
    p.add_argument("--since"); p.add_argument("--session"); p.set_defaults(fn=cmd_export)
    p = sp.add_parser("cloud"); p.set_defaults(fn=cmd_cloud)
    p = sp.add_parser("license"); p.add_argument("action", nargs="?", default="list",
                                                 choices=["list", "add", "import", "revoke", "enable", "reset", "extend", "add_days", "kick", "delete"])
    p.add_argument("name", nargs="?"); p.add_argument("--days", type=float, default=0); p.set_defaults(fn=cmd_license)
    p = sp.add_parser("release"); p.add_argument("action", nargs="?", default="show",
                                                 choices=["show", "publish", "promote", "rollback", "end-beta"])
    p.add_argument("args", nargs="*"); p.add_argument("--channel", default="stable", choices=["stable", "beta"])
    p.add_argument("--note"); p.add_argument("--git"); p.set_defaults(fn=cmd_release)
    p = sp.add_parser("beta"); p.add_argument("action", nargs="?", default="list", choices=["list", "add", "remove"])
    p.add_argument("name", nargs="?"); p.set_defaults(fn=cmd_beta)
    p = sp.add_parser("admin"); p.add_argument("action", nargs="?", default="show", choices=["show", "setup"])
    p.set_defaults(fn=cmd_admin)
    a = ap.parse_args()
    try:
        a.fn(a)
    except KeyboardInterrupt:
        pass
    except sqlite3.OperationalError as e:
        sys.exit(f"db: {e}")


if __name__ == "__main__":
    main()
