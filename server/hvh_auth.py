"""License keys and login sessions for the unsyk loader. Stdlib only.

A key looks like DAA-XXXXX-XXXXX-XXXXX-XXXXX (100 random bits). Only its sha256 is stored (keys.json next to
the event db), so the file never holds a usable key. A new key is shown exactly once, when it is created
(hvhctl license add, or the admin panel).

Login: the loader POSTs {"key", "uid", "user"} to /auth. The first login binds the key to that Roblox
account (uid); later logins from another account are refused until the key is reset.

One device at a time: every key entry has a generation counter `gen`. Each login bumps it and the session
carries it, so a new login ends the previous session at once (its next request gets 401 and the script
stops). Admin "kick" bumps it too. Revoking or expiring the key also kills its sessions at once, because
every request checks the key entry again.

Session = "s2.<kid>.<uid>.<gen>.<exp>.<sig>", sig = HMAC-SHA256(secret, the part before it), secret derived
from INGEST_TOKEN, so no extra secret has to be configured. Changing INGEST_TOKEN logs everyone out.
Old "s1." sessions are refused; the loader logs in again with its saved key.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time

SESSION_TTL = 12 * 3600
KEY_RE = re.compile(r"^DAA(-[A-Z2-7]{5}){4}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.@-]{1,32}$")
_lock = threading.RLock()
_cache = {"mtime": None, "data": None}


def keys_path(db_path):
    return os.environ.get("INGEST_KEYS", os.path.join(os.path.dirname(db_path), "keys.json"))


def norm_key(key):
    return re.sub(r"\s+", "", str(key or "")).upper()


def key_hash(key):
    return hashlib.sha256(norm_key(key).encode()).hexdigest()


def new_key():
    raw = base64.b32encode(secrets.token_bytes(13)).decode().rstrip("=")[:20]
    return "DAA-" + "-".join(raw[i:i + 5] for i in range(0, 20, 5))


class StoreError(OSError):
    """keys.json exists but cannot be read or parsed. Never treat that as "no keys": a writer would then save
    over the real file (that wiped every key on 2026-11-20, when a root-owned 600 file met the dynamic user)."""


def load(path):
    """{"keys": {hash: entry}}; cached by mtime. A missing file means no keys; an unreadable one raises StoreError."""
    try:
        mt = os.stat(path).st_mtime_ns
    except FileNotFoundError:
        return {"keys": {}}
    except OSError as e:
        raise StoreError(f"cannot stat {path}: {e}") from e
    with _lock:
        if _cache["mtime"] == mt and _cache["data"] is not None:
            return _cache["data"]
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data.get("keys"), dict):
                raise ValueError("no 'keys' object")
        except (OSError, ValueError, AttributeError) as e:
            _cache["mtime"], _cache["data"] = None, None
            raise StoreError(f"cannot read {path}: {e}") from e
        _cache["mtime"], _cache["data"] = mt, data
        return data


def save(path, data):
    """Atomic write. The file always ends up owned by the state dir's owner (the service's dynamic user), also
    when hvhctl runs as root, so the receiver can still read it. The previous version is kept as keys.json.bak."""
    d = os.path.dirname(path) or "."
    st = os.stat(d)
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, sort_keys=True)
    try:
        os.chmod(tmp, 0o600)  # hashes only, and the state dir is private to the service anyway
        if os.geteuid() == 0:
            os.chown(tmp, st.st_uid, st.st_gid)
        try:
            with open(path, "rb") as f:
                old = f.read()
            bak = path + ".bak"
            with open(bak + ".tmp", "wb") as f:
                f.write(old)
            os.chmod(bak + ".tmp", 0o600)
            if os.geteuid() == 0:
                os.chown(bak + ".tmp", st.st_uid, st.st_gid)
            os.replace(bak + ".tmp", bak)
        except FileNotFoundError:
            pass
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    with _lock:
        _cache["mtime"] = None


def _copy(path):
    return json.loads(json.dumps(load(path)))


def entry_state(e, now=None):
    """None if usable, else a short reason."""
    now = now or time.time()
    if e.get("disabled"):
        return "key revoked"
    if e.get("expires") and now > e["expires"]:
        return "key expired"
    return None


def _secret(token):
    return hmac.new(token.encode(), b"desync-aa-session-v1", hashlib.sha256).digest()


def beat_token(token, acct, now=None, back=0):
    """Rolling per-account heartbeat token. /beat returns the current one; the client echoes it back in every
    ingest batch. Only a client that actually reached the real /beat (live session) can know it, so a stubbed
    or replayed 200 cannot produce it: the server stamps ev["beat_ok"]=False on batches that fail to echo it.
    5-minute windows; `back` re-checks an earlier window to tolerate clock skew / a stale (<=1 window) echo."""
    win = int((now or time.time()) // 300) - int(back)
    return hmac.new(_secret(token), f"beat:{acct}:{win}".encode(), hashlib.sha256).hexdigest()[:12]


def make_session(token, khash, uid, gen, now=None):
    exp = int((now or time.time()) + SESSION_TTL)
    body = f"s2.{khash[:16]}.{int(uid)}.{int(gen)}.{exp}"
    sig = hmac.new(_secret(token), body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}", exp


def check_session(token, path, sess, now=None):
    """(entry name, uid, sub end or None) for a valid session, else None."""
    if not sess or len(sess) > 140:
        return None
    parts = sess.split(".")
    if len(parts) != 6 or parts[0] != "s2":
        return None
    body = ".".join(parts[:5])
    want = hmac.new(_secret(token), body.encode(), hashlib.sha256).hexdigest()[:32]
    if not hmac.compare_digest(want, parts[5]):
        return None
    now = now or time.time()
    try:
        uid, gen, exp = int(parts[2]), int(parts[3]), int(parts[4])
    except ValueError:
        return None
    if exp < now:
        return None
    for h, e in load(path)["keys"].items():
        if h.startswith(parts[1]):
            if entry_state(e, now) or (e.get("uid") is not None and e["uid"] != uid):
                return None
            if int(e.get("gen", 0)) != gen:
                return None  # a newer login (other device) or an admin kick replaced this session
            return e.get("name", "?"), uid, e.get("expires")
    return None


GUEST_PREFIX = "guest:"
USER_RE = re.compile(r"^[A-Za-z0-9_]{1,40}$")


def guest_session(token, uid, user, now=None):
    """Keyless session for the public stable build: "g1.<user>.<uid>.<exp>.<sig>". The Roblox name and id are
    whatever the client claims (nothing here can verify them), so guests are only ever stable and never beta."""
    exp = int((now or time.time()) + SESSION_TTL)
    body = f"g1.{user}.{int(uid)}.{exp}"
    sig = hmac.new(_secret(token), body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}", exp


def check_guest(token, sess, now=None):
    """(account "guest:<user>", uid, None) for a valid guest session, else None."""
    if not sess or len(sess) > 140:
        return None
    parts = sess.split(".")
    if len(parts) != 5 or parts[0] != "g1" or not USER_RE.match(parts[1]):
        return None
    want = hmac.new(_secret(token), ".".join(parts[:4]).encode(), hashlib.sha256).hexdigest()[:32]
    if not hmac.compare_digest(want, parts[4]):
        return None
    try:
        uid, exp = int(parts[2]), int(parts[3])
    except ValueError:
        return None
    if exp < (now or time.time()):
        return None
    return GUEST_PREFIX + parts[1], uid, None


def guest_login(token, uid, user, now=None):
    """(http code, dict). No key: the Roblox name becomes the account (guest:<name>)."""
    try:
        uid = int(uid)
        if not 0 < uid < 10**15:
            raise ValueError
    except (TypeError, ValueError):
        return 400, {"error": "missing account id"}
    user = str(user or "")
    if not USER_RE.match(user):
        return 400, {"error": "missing Roblox name"}
    sess, exp = guest_session(token, uid, user, now)
    return 200, {"session": sess, "expires": exp, "ttl": SESSION_TTL, "name": GUEST_PREFIX + user,
                 "guest": True, "days_left": None, "sub_end": None}


def login(token, path, key, uid, user, ip=None, now=None):
    """(http code, json-able dict). Binds the key to the Roblox account on first use; ends older sessions."""
    now = now or time.time()
    k = norm_key(key)
    if not KEY_RE.match(k):
        return 403, {"error": "that is not a key (DAA-XXXXX-XXXXX-XXXXX-XXXXX)"}
    try:
        uid = int(uid)
        if not 0 < uid < 10**15:
            raise ValueError
    except (TypeError, ValueError):
        return 400, {"error": "missing account id"}
    h = key_hash(k)
    with _lock:
        data = _copy(path)
        e = data["keys"].get(h)
        if not e:
            return 403, {"error": "unknown key"}
        why = entry_state(e, now)
        if why:
            return 403, {"error": why}
        if e.get("uid") is not None and e["uid"] != uid:
            return 403, {"error": "key is locked to another Roblox account"}
        if e.get("uid") is None:
            e["uid"], e["bound_at"] = uid, int(now)
        e["user"] = re.sub(r"[^A-Za-z0-9_]", "", str(user or ""))[:40]
        e["last"] = int(now)
        e["last_ip"] = str(ip or "")[:45]
        e["logins"] = int(e.get("logins", 0)) + 1
        e["gen"] = int(e.get("gen", 0)) + 1
        save(path, data)  # must succeed: the new gen is what makes this session valid
    sess, exp = make_session(token, h, uid, e["gen"], now)
    days = None if not e.get("expires") else max(0, int((e["expires"] - now) // 86400))
    return 200, {"session": sess, "expires": exp, "ttl": SESSION_TTL, "name": e.get("name", "?"),
                 "days_left": days, "sub_end": e.get("expires")}


def entry_info(path, name):
    """Public info about the key named NAME for /me: {name, user, expires, days_left, created} or None."""
    now = time.time()
    for e in load(path)["keys"].values():
        if e.get("name") == name:
            exp = e.get("expires")
            return {"name": name, "user": e.get("user"), "expires": exp, "created": e.get("created"),
                    "days_left": None if not exp else max(0, int((exp - now) // 86400))}
    return None


# ---------------- admin operations (hvhctl and the admin panel) ----------------

def list_keys(path, now=None):
    now = now or time.time()
    out = []
    for h, e in load(path)["keys"].items():
        out.append({"name": e.get("name", "?"), "id": h[:12], "state": entry_state(e, now) or "active",
                    "created": e.get("created"), "expires": e.get("expires"), "uid": e.get("uid"),
                    "user": e.get("user"), "bound_at": e.get("bound_at"), "last": e.get("last"),
                    "last_ip": e.get("last_ip"), "logins": e.get("logins", 0), "note": e.get("note", "")})
    out.sort(key=lambda r: r.get("created") or 0)
    return out


def add_key(path, name, days=0, note="", now=None, key=None):
    """Create a key; returns it (the only time it exists in clear). key= re-adds a key that already exists in
    clear (a friend still has it saved) instead of making a new one, e.g. after keys.json was lost."""
    now = now or time.time()
    if not NAME_RE.match(name or ""):
        raise ValueError("name: 1-32 letters, digits, _ . @ -")
    if name == "owner":
        raise ValueError("'owner' is reserved for the master token")
    with _lock:
        data = _copy(path)
        if any(e.get("name") == name for e in data["keys"].values()):
            raise ValueError(f"a key named {name} exists already")
        if key is None:
            k = new_key()
        else:
            k = norm_key(key)
            if not KEY_RE.match(k):
                raise ValueError("that is not a key (DAA-XXXXX-XXXXX-XXXXX-XXXXX)")
            if key_hash(k) in data["keys"]:
                raise ValueError("that key exists already")
        data["keys"][key_hash(k)] = {"name": name, "created": int(now), "uid": None, "gen": 0,
                                     "expires": int(now + float(days) * 86400) if days else None,
                                     "note": str(note or "")[:120]}
        save(path, data)
    return k


def modify(path, name, action, days=0, note=None, now=None):
    """revoke | enable | reset | extend (days from now, 0 = never) | add_days | kick | note | delete."""
    now = now or time.time()
    with _lock:
        data = _copy(path)
        hits = [h for h, e in data["keys"].items() if e.get("name") == name]
        if not hits:
            raise ValueError(f"no key named {name}")
        h = hits[0]
        e = data["keys"][h]
        if action == "revoke":
            e["disabled"] = True
        elif action == "enable":
            e.pop("disabled", None)
        elif action == "reset":
            e["uid"], e["user"], e["bound_at"] = None, None, None
        elif action == "extend":
            e["expires"] = int(now + float(days) * 86400) if days else None
        elif action == "add_days":
            base = max(now, e.get("expires") or now)
            e["expires"] = int(base + float(days) * 86400)
        elif action == "kick":
            pass
        elif action == "note":
            e["note"] = str(note or "")[:120]
        elif action == "delete":
            del data["keys"][h]
        else:
            raise ValueError("unknown action")
        # extend/add_days need no kick: sessions read the expiry live and the script learns it from /beat
        if action in ("revoke", "reset", "kick") and h in data["keys"]:
            e["gen"] = int(e.get("gen", 0)) + 1   # end the live session so the change takes effect now
        save(path, data)


def invite_text(key, days, base="https://feed.sites.exxo.world"):
    exp = "never expires" if not days else f"valid for {float(days):.0f} days"
    return "\n".join([
        f"unsyk - HvH helper ({exp}). Setup (2 min):",
        "1. Load this one line in the cheat (where you load scripts):",
        f'   loadstring(game:HttpGet("{base}/loader.lua"))()',
        "2. Open the cheat menu -> tab \"unsyk login\".",
        "3. Paste this key and press Log in:",
        f"   {key}",
        "4. A small card shows the download, then \"welcome\". Done - it auto-updates.",
        "The key locks to your Roblox account and works on one device at a time. Do not share it.",
    ])
