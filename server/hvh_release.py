"""Script releases and channels (stable / beta) for unsyk. Stdlib only.

Every deploy is a numbered build. Its bytes are kept as releases/<ver>.lua (ver = first 10 hex of the sha256 of
the file, the same version string the script has always used for update checks), so a build can be promoted or
rolled back later without rebuilding: what was tested is exactly what everyone gets.

Two channels point at builds:
  stable  everyone
  beta    accounts in beta_members (license names, "owner" = the master token)
A beta member gets the beta build while one exists; a beta that equals stable (after a promote) changes nothing.

State: <state dir>/releases/channels.json
  {"next": 14, "stable": REC, "beta": REC|null, "beta_members": [...], "history": [REC, ...]}
  REC = {"build", "ver", "ch", "ts", "note", "git", "size"}
Written by hvhctl (root, on deploy) and by the receiver (admin panel); files always end up owned by the state
dir's owner (the service's dynamic user), like keys.json.

Before the first publish there is no channels.json: stable then falls back to the legacy file (SCRIPT_PATH) as
build 0, so nothing breaks during the migration.
"""
import hashlib
import json
import os
import re
import threading
import time

CHANNELS = ("stable", "beta")
KEEP_FILES = 30           # newest builds whose files are kept (channel pointers are always kept)
MAX_HISTORY = 200
NAME_RE = re.compile(r"^[A-Za-z0-9_.@-]{1,32}$")
_lock = threading.RLock()
_cache = {}               # path -> (mtime_ns, bytes)


def releases_dir(db_path):
    return os.environ.get("INGEST_RELEASES", os.path.join(os.path.dirname(db_path), "releases"))


def _state_path(d):
    return os.path.join(d, "channels.json")


def _empty():
    return {"next": 1, "stable": None, "beta": None, "beta_members": [], "history": []}


def load(d):
    try:
        with open(_state_path(d), "r", encoding="utf-8") as f:
            s = json.load(f)
        if not isinstance(s, dict):
            raise ValueError
    except FileNotFoundError:
        return _empty()
    except (OSError, ValueError) as e:
        # never treat an unreadable file as "no releases": a writer would save over the real history
        raise OSError(f"cannot read {_state_path(d)}: {e}") from e
    base = _empty()
    base.update(s)
    return base


def _owner_of(d):
    st = os.stat(os.path.dirname(os.path.abspath(d)))
    return st.st_uid, st.st_gid


def _ensure_dir(d):
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o755, exist_ok=True)
        if os.geteuid() == 0:
            os.chown(d, *_owner_of(d))


def _write(d, name, data: bytes, mode=0o644):
    _ensure_dir(d)
    path = os.path.join(d, name)
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    try:
        os.chmod(tmp, mode)
        if os.geteuid() == 0:
            st = os.stat(d)
            os.chown(tmp, st.st_uid, st.st_gid)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _save(d, s):
    s["history"] = s["history"][-MAX_HISTORY:]
    _write(d, "channels.json", json.dumps(s, indent=1, sort_keys=True).encode())


def _prune(d, s):
    keep = {r["ver"] for r in s["history"][-KEEP_FILES:]}
    keep |= {s[c]["ver"] for c in CHANNELS if s.get(c)}
    try:
        names = os.listdir(d)
    except OSError:
        return
    for n in names:
        m = re.fullmatch(r"([0-9a-f]{10})\.lua", n)
        if m and m.group(1) not in keep:
            try:
                os.remove(os.path.join(d, n))
            except OSError:
                pass


def _rec(s, build):
    for r in reversed(s["history"]):
        if r["build"] == build:
            return r
    return None


# ---------------- writes ----------------

def publish(d, src: bytes, channel, note="", git=""):
    """Store a new build and point CHANNEL at it. Returns the record. Publishing to stable also moves beta
    along when beta was not ahead (so beta members never sit on an older build than everyone else)."""
    if channel not in CHANNELS:
        raise ValueError("channel must be stable or beta")
    if len(src) < 1000:
        raise ValueError("that file is too small to be the script")
    ver = hashlib.sha256(src).hexdigest()[:10]
    with _lock:
        s = load(d)
        cur = s.get(channel)
        if cur and cur["ver"] == ver:
            return dict(cur, unchanged=True)
        old = next((r for r in reversed(s["history"]) if r["ver"] == ver), None)
        _write(d, f"{ver}.lua", src)
        rec = {"build": int(s["next"]), "ver": ver, "ch": channel, "ts": int(time.time()),
               "note": str(note or "")[:200], "git": str(git or "")[:40], "size": len(src)}
        if old:
            rec["same_as"] = old["build"]
        s["next"] = rec["build"] + 1
        s["history"].append(rec)
        if channel == "stable":
            beta = s.get("beta")
            if not beta or beta["build"] <= (cur or {}).get("build", 0):
                s["beta"] = dict(rec)
        s[channel] = dict(rec)
        _save(d, s)
        _prune(d, s)
        return rec


def point(d, channel, build):
    """Point CHANNEL at an existing build (rollback, or promote: point stable at the beta build)."""
    if channel not in CHANNELS:
        raise ValueError("channel must be stable or beta")
    with _lock:
        s = load(d)
        r = _rec(s, int(build))
        if not r:
            raise ValueError(f"no build #{build}")
        if not os.path.exists(os.path.join(d, f"{r['ver']}.lua")):
            raise ValueError(f"build #{build} is too old, its file was pruned")
        old = s.get(channel)
        s[channel] = dict(r, moved=int(time.time()))
        # beta that was only following stable follows a stable rollback too (no beta tester stuck on a bad build)
        if channel == "stable" and old and s.get("beta") and s["beta"]["ver"] == old["ver"]:
            s["beta"] = dict(s["stable"])
        _save(d, s)
        return s[channel]


def promote(d):
    """Beta becomes stable: everyone gets exactly the bytes the beta testers ran."""
    s = load(d)
    if not s.get("beta"):
        raise ValueError("there is no beta build")
    if s.get("stable") and s["stable"]["ver"] == s["beta"]["ver"]:
        raise ValueError(f"beta (#{s['beta']['build']}) is already stable")
    return point(d, "stable", s["beta"]["build"])


def end_beta(d):
    """Beta members go back to stable (beta points at the stable build)."""
    s = load(d)
    if not s.get("stable"):
        raise ValueError("there is no stable build yet (deploy one first)")
    return point(d, "beta", s["stable"]["build"])


def set_member(d, name, on):
    name = str(name or "")
    if not NAME_RE.match(name):
        raise ValueError("name: a license name or owner")
    with _lock:
        s = load(d)
        m = [x for x in s["beta_members"] if x != name]
        if on:
            m.append(name)
        s["beta_members"] = sorted(m)
        _save(d, s)
        return s["beta_members"]


# ---------------- reads (the receiver, every request) ----------------

def channel_for(d, acct):
    try:
        s = load(d)
    except OSError:
        return "stable"
    if str(acct).startswith("guest:"):   # keyless guests are always stable, whatever the beta list says
        return "stable"
    return "beta" if acct in s["beta_members"] and s.get("beta") else "stable"


def is_member(d, acct):
    try:
        return acct in load(d)["beta_members"]
    except OSError:
        return False


def _read(path):
    """Bytes of a file, cached by mtime (the script is served on every loader start)."""
    mt = os.stat(path).st_mtime_ns
    with _lock:
        c = _cache.get(path)
        if c and c[0] == mt:
            return c[1]
        with open(path, "rb") as f:
            b = f.read()
        _cache[path] = (mt, b)
        return b


def build_for(d, channel, legacy_path=None):
    """{"src", "ver", "build", "ch", "ts", "note"} for CHANNEL, or None. Falls back: beta -> stable -> the legacy
    single file (build 0) so the game keeps working while channels.json is missing or broken."""
    try:
        s = load(d)
    except OSError:
        s = _empty()
    for ch in ((channel, "stable") if channel == "beta" else ("stable",)):
        r = s.get(ch)
        if not r:
            continue
        try:
            src = _read(os.path.join(d, f"{r['ver']}.lua"))
        except OSError:
            continue
        return {"src": src, "ver": r["ver"], "build": r["build"], "ch": ch, "ts": r.get("moved") or r["ts"],
                "note": r.get("note", "")}
    if legacy_path:
        try:
            src = _read(legacy_path)
            return {"src": src, "ver": hashlib.sha256(src).hexdigest()[:10], "build": 0, "ch": "stable",
                    "ts": int(os.path.getmtime(legacy_path)), "note": "legacy file"}
        except OSError:
            pass
    return None


def summary(d):
    s = load(d)
    return {"stable": s.get("stable"), "beta": s.get("beta"), "beta_members": s["beta_members"],
            "history": list(reversed(s["history"][-40:])), "next": s["next"]}
