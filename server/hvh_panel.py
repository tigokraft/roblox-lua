"""Read-only aggregates for the admin panel's Testing and Players views. Stdlib only.

Everything here takes an open read-only sqlite connection (row_factory = sqlite3.Row) on the events table:
  events(id, ts, session, kind, data JSON)   account = data.lic, or "owner" for the master token.

Alive minutes come from 'state' snapshots (one every 5 s while alive), like everywhere else in the panel.
A session is one script run, so it has one build: deaths/shots are joined to a build through their session.
"""
import json
import math
import re
import time
from collections import defaultdict

ACCT = "COALESCE(json_extract(data,'$.lic'),'owner')"
SNAP_MIN = 5 / 60          # minutes per state snapshot
ONLINE_S = 20              # a state snapshot newer than this = in game now
NAME_RE = re.compile(r"^[\w .:@-]{1,40}$")


def accts_param(q):
    """?accts=a,b,c -> validated list ([] = everyone)."""
    raw = (q.get("accts") or [""])[0]
    return [a for a in (x.strip() for x in raw.split(",")) if a and NAME_RE.match(a)][:40]


def since_param(q, default=""):
    s = (q.get("since") or [default])[0]
    if not s or s == "all":
        return 0.0
    m = re.fullmatch(r"(\d{1,4})([smhd])", s)
    if not m:
        raise ValueError("since must look like 30m, 24h or 7d")
    return time.time() - int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def _where(since, accts, alias=""):
    w, a = [f"{alias}ts >= ?"], [since]
    if accts:
        w.append(f"{ACCT} IN ({','.join('?' * len(accts))})")
        a += accts
    return " AND ".join(w), a


def srv_class(s):
    s = str(s or "").lower()
    return "nospread" if "no" in s else "spread" if "spread" in s else "unknown"


def rate_ci(deaths, minutes):
    """deaths/min with a 95% interval (Poisson, normal approx; exact-ish lower bound 0)."""
    if minutes <= 0:
        return None, None, None
    r = deaths / minutes
    half = 1.96 * math.sqrt(max(deaths, 1)) / minutes
    return round(r, 2), round(max(0.0, r - half), 2), round(r + half, 2)


def rate_z(d1, m1, d2, m2):
    """z for the difference of two Poisson rates (positive = first is higher)."""
    if m1 <= 0 or m2 <= 0:
        return None
    var = max(d1, 1) / m1 ** 2 + max(d2, 1) / m2 ** 2
    return round((d1 / m1 - d2 / m2) / math.sqrt(var), 2)


# ---------------- the one aggregate everything else rolls up ----------------

def chunks(con, since, accts, srv="all"):
    """One row per (session, account, config version, server kind) with counts. srv: all | spread | nospread."""
    w, a = _where(since, accts)
    rows = con.execute(
        f"SELECT session, {ACCT} acct, COALESCE(json_extract(data,'$.cv'),0) cv, json_extract(data,'$.srv') srv,"
        " MIN(ts) a, MAX(ts) b,"
        " SUM(kind='state') snaps,"
        " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0) deaths,"
        " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0"
        "     AND CAST(json_extract(data,'$.hp_before') AS REAL) >= 100) one_shots,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='fire') fired,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit') landed,"
        " SUM(kind='shot' AND json_extract(data,'$.result')='hit' AND CAST(json_extract(data,'$.hp_left') AS REAL) <= 0) kills"
        f" FROM events WHERE {w} AND kind IN ('state','hit','shot') GROUP BY session, acct, cv, srv", a).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        d["srv"] = srv_class(d["srv"])
        if srv != "all" and d["srv"] != srv:
            continue
        d["min"] = (d.pop("snaps") or 0) * SNAP_MIN
        out.append(d)
    return out


def session_builds(con, since, accts):
    """session -> {"build", "ver", "ch"} from state / load events."""
    w, a = _where(since, accts)
    out = {}
    for r in con.execute(
            f"SELECT session, MAX(json_extract(data,'$.build')) build, MAX(json_extract(data,'$.ver')) ver,"
            f" MAX(json_extract(data,'$.ch')) ch FROM events WHERE {w} AND kind IN ('state','load') GROUP BY session", a):
        out[r["session"]] = {"build": r["build"], "ver": r["ver"], "ch": r["ch"]}
    return out


def build_key(b):
    if not b:
        return "?"
    if b.get("build") is not None:
        return f"#{int(b['build'])}"
    return b.get("ver") or "?"


def _roll(rows, keyf):
    g = defaultdict(lambda: {"min": 0.0, "deaths": 0, "kills": 0, "fired": 0, "landed": 0, "one_shots": 0,
                             "sessions": set(), "accts": set(), "a": None, "b": None})
    for r in rows:
        k = keyf(r)
        x = g[k]
        for f in ("min", "deaths", "kills", "fired", "landed", "one_shots"):
            x[f] += r[f] or 0
        x["sessions"].add(r["session"])
        x["accts"].add(r["acct"])
        x["a"] = r["a"] if x["a"] is None else min(x["a"], r["a"])
        x["b"] = r["b"] if x["b"] is None else max(x["b"], r["b"])
    return g


def _stats(x):
    dpm, lo, hi = rate_ci(x["deaths"], x["min"])
    return {"min": round(x["min"], 1), "deaths": x["deaths"], "kills": x["kills"], "fired": x["fired"], "landed": x["landed"],
            "one_shots": x["one_shots"], "dpm": dpm if x["min"] >= 0.5 else None, "lo": lo, "hi": hi,
            "kd": round(x["kills"] / x["deaths"], 2) if x["deaths"] else None,
            # capped: the game sometimes reports a hit whose fire event never came (DT pairs)
            "hit": min(100, round(x["landed"] / x["fired"] * 100)) if x["fired"] else None,
            "one_pct": round(x["one_shots"] / x["deaths"] * 100) if x["deaths"] else None,
            "sessions": len(x["sessions"]), "accts": sorted(x["accts"]), "a": x["a"], "b": x["b"],
            "noise": x["deaths"] < 10 or x["min"] < 5}


def cv_notes(con, since, accts):
    """config version -> {"note", "applied"} from the games' ctrl events (what each push changed)."""
    w, a = _where(since, accts)
    out = {}
    for r in con.execute(f"SELECT data FROM events WHERE {w} AND kind = 'ctrl' ORDER BY id", a):
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        v = ev.get("v")
        if v is None:
            continue
        o = out.setdefault(v, {"note": None, "applied": {}})
        if ev.get("note"):
            o["note"] = ev["note"]
        if isinstance(ev.get("applied"), dict):
            o["applied"].update(ev["applied"])
    return out


def compare(con, q, releases=None):
    """A/B table: rows by config version (by=cv) or by build (by=build), plus the totals."""
    since = since_param(q, "7d")
    accts = accts_param(q)
    by = (q.get("by") or ["cv"])[0]
    srv = (q.get("srv") or ["all"])[0]
    if by not in ("cv", "build") or srv not in ("all", "spread", "nospread", "unknown"):
        raise ValueError("bad parameters")
    rows = chunks(con, since, accts, srv)
    if by == "cv":
        g = _roll(rows, lambda r: r["cv"])
        notes = cv_notes(con, since, accts)
        out = [{"key": k, "label": f"v{k}", **_stats(x), "note": (notes.get(k) or {}).get("note"),
                "applied": (notes.get(k) or {}).get("applied") or {}} for k, x in g.items()]
        out.sort(key=lambda r: r["key"], reverse=True)
    else:
        sb = session_builds(con, since, accts)
        g = _roll(rows, lambda r: build_key(sb.get(r["session"])))
        info = {}
        for h in (releases or {}).get("history", []):
            info[f"#{h['build']}"] = h
        out = []
        for k, x in g.items():
            h = info.get(k) or {}
            out.append({"key": k, "label": k, **_stats(x), "note": h.get("note"), "ch": h.get("ch"), "ver": h.get("ver"),
                        "ts": h.get("ts")})
        out.sort(key=lambda r: r["b"] or 0, reverse=True)
    tot = _stats(_roll(rows, lambda r: 0)[0]) if rows else None
    return {"by": by, "rows": out, "total": tot, "accts": accts, "since": since}


def sessions(con, q):
    """Session list for the Testing view: one row per session with build, config versions and stats."""
    since = since_param(q, "7d")
    accts = accts_param(q)
    rows = chunks(con, since, accts)
    sb = session_builds(con, since, accts)
    g = _roll(rows, lambda r: r["session"])
    cvs, srvs = defaultdict(set), defaultdict(set)
    for r in rows:
        cvs[r["session"]].add(r["cv"])
        srvs[r["session"]].add(r["srv"])
    out = []
    for s, x in g.items():
        b = sb.get(s) or {}
        out.append({"session": s, **_stats(x), "acct": x["accts"] and sorted(x["accts"])[0], "build": build_key(b),
                    "ch": b.get("ch"), "cvs": sorted(cvs[s]), "srv": sorted(srvs[s])})
    out.sort(key=lambda r: r["b"] or 0, reverse=True)
    return {"sessions": out[:200]}


# ---------------- build health ----------------

def health(con, q, releases=None):
    since = since_param(q, "7d")
    accts = accts_param(q)
    rows = chunks(con, since, accts)
    sb = session_builds(con, since, accts)
    g = _roll(rows, lambda r: build_key(sb.get(r["session"])))
    w, a = _where(since, accts)
    loads, errs, stops, err_groups = defaultdict(int), defaultdict(int), defaultdict(lambda: defaultdict(int)), {}
    for r in con.execute(f"SELECT ts, session, kind, {ACCT} acct, data FROM events WHERE {w} AND kind IN ('load','err','stop') "
                         "ORDER BY id", a):
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        k = build_key({"build": ev.get("build"), "ver": ev.get("ver")})
        if r["kind"] == "load":
            loads[k] += 1
        elif r["kind"] == "stop":
            stops[k][str(ev.get("why") or "?")[:120]] += 1
        else:
            n = ev.get("n") if isinstance(ev.get("n"), int) else 1
            errs[k] += n
            gk = (str(ev.get("where") or "?"), str(ev.get("msg") or "?"))
            e = err_groups.setdefault(gk, {"where": gk[0], "msg": gk[1], "n": 0, "accts": set(), "builds": set(),
                                           "first": r["ts"], "last": r["ts"]})
            e["n"] += n
            e["accts"].add(r["acct"])
            e["builds"].add(k)
            e["last"] = r["ts"]
    info = {f"#{h['build']}": h for h in (releases or {}).get("history", [])}
    keys = set(g) | set(loads) | set(errs) | set(stops)
    out = []
    for k in keys:
        x = _stats(g[k]) if k in g else None
        if x is None:  # loads / errors but no play data (died in the menu, or no state snapshot yet)
            x = {"min": 0, "deaths": 0, "kills": 0, "fired": 0, "landed": 0, "one_shots": 0, "dpm": None, "lo": None,
                 "hi": None, "kd": None, "hit": None, "one_pct": None, "sessions": 0, "accts": [], "a": None, "b": None,
                 "noise": True}
        h = info.get(k) or {}
        hours = x["min"] / 60
        out.append({"key": k, **x, "loads": loads.get(k, 0), "errors": errs.get(k, 0),
                    "err_per_h": round(errs.get(k, 0) / hours, 1) if hours >= 0.1 else None,
                    "stops": [{"why": w_, "n": n} for w_, n in sorted(stops[k].items(), key=lambda t: -t[1])],
                    "avg_session": round(x["min"] / x["sessions"], 1) if x["sessions"] else None,
                    "ch": h.get("ch"), "note": h.get("note"), "ver": h.get("ver"), "ts": h.get("ts")})
    out.sort(key=lambda r: (r["b"] or r.get("ts") or 0), reverse=True)
    groups = sorted(({**e, "accts": sorted(e["accts"]), "builds": sorted(e["builds"])} for e in err_groups.values()),
                    key=lambda e: -e["last"])
    return {"builds": out, "errors": groups[:100], "since": since}


# ---------------- players ----------------

def _snapshots(con, accts=None):
    """account -> latest state snapshot (with build, server, session)."""
    w, a = ("", [])
    if accts:
        w = f"AND {ACCT} IN ({','.join('?' * len(accts))})"
        a = list(accts)
    out = {}
    for r in con.execute(f"SELECT {ACCT} acct, ts, session, data FROM events WHERE id IN "
                         f"(SELECT MAX(id) FROM events WHERE kind = 'state' {w} GROUP BY {ACCT})", a):
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        my = ev.get("my") or {}
        out[r["acct"]] = {"ts": r["ts"], "session": r["session"], "ver": ev.get("ver"), "build": ev.get("build"),
                          "ch": ev.get("ch"), "hp": ev.get("hp"), "my_state": ev.get("my_state"), "srv": ev.get("srv"),
                          "job": ev.get("job"), "wep": my.get("wep"), "remote": ev.get("remote"), "cv": ev.get("cv"),
                          "online": time.time() - r["ts"] < ONLINE_S}
    return out


def _users(con):
    out = {}
    for r in con.execute(f"SELECT {ACCT} acct, MAX(json_extract(data,'$.user')) user, MAX(ts) last FROM events "
                         "WHERE kind != 'test' GROUP BY acct"):
        out[r["acct"]] = {"user": r["user"], "last": r["last"]}
    return out


def players(con, q, keys, beta_members):
    """Roster: every license key plus every account seen in the data, with live state, current session and range stats."""
    since = since_param(q, "7d")
    snaps = _snapshots(con)
    users = _users(con)
    rng = _roll(chunks(con, since, []), lambda r: r["acct"])
    cur_sessions = [s["session"] for s in snaps.values() if s.get("session")]
    cur = {}
    if cur_sessions:
        # only each player's latest session: cheap query by session id
        ph = ",".join("?" * len(cur_sessions))
        for r in con.execute(
                f"SELECT {ACCT} acct, session,"
                " SUM(kind='hit' AND CAST(json_extract(data,'$.hp_after') AS REAL) <= 0) deaths,"
                " SUM(kind='shot' AND json_extract(data,'$.result')='hit' AND CAST(json_extract(data,'$.hp_left') AS REAL) <= 0) kills,"
                " SUM(kind='state') snaps, MIN(ts) a"
                f" FROM events WHERE session IN ({ph}) AND kind IN ('state','hit','shot') GROUP BY acct, session", cur_sessions):
            if snaps.get(r["acct"], {}).get("session") == r["session"]:
                cur[r["acct"]] = {"deaths": r["deaths"], "kills": r["kills"], "min": round((r["snaps"] or 0) * SNAP_MIN, 1),
                                  "start": r["a"]}
    by_name = {k["name"]: k for k in keys}
    names = set(by_name) | set(snaps) | set(users)
    out = []
    for n in names:
        k = by_name.get(n)
        s = snaps.get(n)
        st = _stats(rng[n]) if n in rng else None
        out.append({"acct": n, "user": (users.get(n) or {}).get("user") or (k or {}).get("user"),
                    "last": max(filter(None, [(users.get(n) or {}).get("last"), (k or {}).get("last")]), default=None),
                    "online": bool(s and s["online"]), "snap": s, "cur": cur.get(n), "stats": st,
                    "lic": None if not k else {"state": k["state"], "expires": k["expires"], "uid": k["uid"],
                                               "logins": k["logins"], "note": k["note"], "created": k["created"]},
                    "beta": n in beta_members})
    out.sort(key=lambda p: (not p["online"], -(p["last"] or 0)))
    return {"players": out, "since": since}


def player(con, name, q, key, beta_members, configs, downloads):
    """One player's profile: range stats, a per-day series, sessions, weapons, killers, errors."""
    since = since_param(q, "30d")
    acc = [name]
    rows = chunks(con, since, acc)
    sb = session_builds(con, since, acc)
    tot = _stats(_roll(rows, lambda r: 0)[0]) if rows else None
    # per day (local server time)
    day = _roll(rows, lambda r: time.strftime("%Y-%m-%d", time.localtime(r["a"])))
    days = [{"day": d, **_stats(x)} for d, x in sorted(day.items())]
    sess = _roll(rows, lambda r: r["session"])
    slist = sorted(({"session": s, **_stats(x), "build": build_key(sb.get(s)), "ch": (sb.get(s) or {}).get("ch")}
                    for s, x in sess.items()), key=lambda r: -(r["b"] or 0))[:40]
    srvs = _roll(rows, lambda r: r["srv"])
    w, a = _where(since, acc)
    weps, kweps, killers = defaultdict(lambda: [0, 0]), defaultdict(int), defaultdict(int)
    errs = []
    try:
        import hvhctl
        lk = hvhctl.likely_killer
    except Exception:  # panel helper missing: no killer guesses
        lk = None
    for r in con.execute(f"SELECT ts, kind, data FROM events WHERE {w} AND kind IN ('hit','shot','err') ORDER BY id DESC LIMIT 20000", a):
        try:
            ev = json.loads(r["data"])
        except ValueError:
            continue
        k = r["kind"]
        if k == "hit" and (ev.get("hp_after") or 0) <= 0:
            weps[(ev.get("my") or {}).get("wep") or "?"][1] += 1
            if lk:
                x = lk(ev) or {}
                if x.get("name"):
                    killers[x["name"]] += 1
                if x.get("wep"):
                    kweps[x["wep"]] += 1
        elif k == "shot" and ev.get("result") == "hit" and isinstance(ev.get("hp_left"), (int, float)) and ev["hp_left"] <= 0:
            weps[(ev.get("my") or {}).get("wep") or "?"][0] += 1
        elif k == "err" and len(errs) < 30:
            errs.append({"ts": r["ts"], "where": ev.get("where"), "msg": ev.get("msg"), "n": ev.get("n"),
                         "build": build_key({"build": ev.get("build"), "ver": ev.get("ver")})})
    snaps = _snapshots(con, [name])
    users = _users(con)
    return {
        "acct": name, "user": (users.get(name) or {}).get("user") or (key or {}).get("user"),
        "last": (users.get(name) or {}).get("last"), "snap": snaps.get(name), "beta": name in beta_members,
        "lic": key, "total": tot, "days": days, "sessions": slist,
        "srv": [{"srv": s, **_stats(x)} for s, x in srvs.items()],
        "weapons": sorted(([w_, kd[0], kd[1]] for w_, kd in weps.items()), key=lambda t: -(t[1] + t[2]))[:10],
        "killers": sorted(killers.items(), key=lambda t: -t[1])[:10],
        "killer_weps": sorted(kweps.items(), key=lambda t: -t[1])[:8],
        "errors": errs, "configs": configs, "downloads": downloads, "since": since,
    }
