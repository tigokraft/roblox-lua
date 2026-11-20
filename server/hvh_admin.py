"""Admin login for the unsyk panel (/admin on the public feed host). Stdlib only.

Credentials live in admin.json next to the event db (written by `hvhctl admin setup`, never by the web):
  {"user": "...", "pw": "scrypt$<n>$<r>$<p>$<salt b64>$<hash b64>", "totp": "<base32>", "last_step": int}
Sign-in needs the password AND a current 6-digit TOTP code (RFC 6238, SHA1, 30 s, +-1 step). A code is
accepted once only (last_step), so a sniffed code cannot be replayed.

Sessions are random 256-bit tokens kept in memory (sha256 only), sent as a __Host- cookie (Secure, HttpOnly,
SameSite=Strict, Path=/). 30 min idle, 12 h absolute; a restart logs the admin out.
State-changing requests must also carry X-Panel: 1 and a same-origin Origin (checked by the receiver).

Brute force: 5 failures per IP per 15 min -> that IP is refused; 30 failures in total per 15 min -> all
sign-ins refused for the rest of the window. scrypt runs even for an unknown user, so timing says nothing.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import struct
import threading
import time

IDLE = 30 * 60
ABSOLUTE = 12 * 3600
WINDOW = 15 * 60
MAX_IP_FAILS = 5
MAX_ALL_FAILS = 30
SCRYPT = (2 ** 15, 8, 1)
COOKIE = "__Host-unsyk_admin"

_lock = threading.Lock()
_sessions = {}     # sha256(token) -> {"created", "last", "ip", "user"}
_fails = {}        # ip -> [ts]
_all_fails = []    # [ts]
_DUMMY = None
_mem = {"last_step": 0}


def admin_path(db_path):
    return os.environ.get("INGEST_ADMIN", os.path.join(os.path.dirname(db_path), "admin.json"))


# ---------------- password + TOTP ----------------

def hash_password(pw):
    n, r, p = SCRYPT
    salt = secrets.token_bytes(16)
    h = hashlib.scrypt(pw.encode(), salt=salt, n=n, r=r, p=p, maxmem=64 * 1024 * 1024, dklen=32)
    return f"scrypt${n}${r}${p}${base64.b64encode(salt).decode()}${base64.b64encode(h).decode()}"


def check_password(pw, stored):
    try:
        _, n, r, p, salt, want = stored.split("$")
        got = hashlib.scrypt(pw.encode(), salt=base64.b64decode(salt), n=int(n), r=int(r), p=int(p),
                             maxmem=64 * 1024 * 1024, dklen=32)
        return hmac.compare_digest(got, base64.b64decode(want))
    except (ValueError, TypeError):
        return False


def new_totp_secret():
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_at(secret, step):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    mac = hmac.new(key, struct.pack(">Q", step), hashlib.sha1).digest()
    o = mac[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 1000000)


def totp_match(secret, code, now=None, last_step=0):
    """The matching step (int) or None. Steps at or before last_step are refused (no replay)."""
    code = "".join(ch for ch in str(code or "") if ch.isdigit())
    if len(code) != 6:
        return None
    cur = int((now or time.time()) // 30)
    for step in (cur - 1, cur, cur + 1):
        if step > last_step and hmac.compare_digest(totp_at(secret, step), code):
            return step
    return None


def otpauth_uri(secret, user, issuer="unsyk"):
    from urllib.parse import quote
    return f"otpauth://totp/{quote(issuer)}:{quote(user)}?secret={secret}&issuer={quote(issuer)}&digits=6&period=30"


def load(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) and d.get("pw") and d.get("totp") else None
    except (OSError, ValueError):
        return None


def save(path, data, owner_of=None):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.chmod(tmp, 0o600)
    if owner_of:  # hvhctl runs as root: hand the file to the service's (dynamic) user, who owns the state dir
        st = os.stat(owner_of)
        os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, path)


# ---------------- rate limit ----------------

def _prune(now):
    global _all_fails
    _all_fails = [t for t in _all_fails if now - t < WINDOW]
    for ip in list(_fails):
        _fails[ip] = [t for t in _fails[ip] if now - t < WINDOW]
        if not _fails[ip]:
            del _fails[ip]


def blocked(ip, now=None):
    now = now or time.time()
    with _lock:
        _prune(now)
        if len(_fails.get(ip, [])) >= MAX_IP_FAILS:
            return "too many wrong attempts from this address, wait 15 minutes"
        if len(_all_fails) >= MAX_ALL_FAILS:
            return "sign-in is paused for 15 minutes after many wrong attempts"
    return None


def _fail(ip, now):
    with _lock:
        _fails.setdefault(ip, []).append(now)
        _all_fails.append(now)


# ---------------- sign-in / sessions ----------------

def sign_in(path, user, pw, code, ip, now=None):
    """(ok, token or error text). Same error for every wrong part, so nothing leaks about which one."""
    global _DUMMY
    now = now or time.time()
    why = blocked(ip, now)
    if why:
        return False, why
    cfg = load(path)
    if not isinstance(user, str) or not isinstance(pw, str) or len(pw) > 256 or len(user) > 64:
        _fail(ip, now)
        return False, "wrong user, password or code"
    if cfg is None:
        if _DUMMY is None:
            _DUMMY = hash_password(secrets.token_hex(8))
        check_password(pw, _DUMMY)
        _fail(ip, now)
        return False, "admin sign-in is not set up (run: hvhctl admin setup)"
    ok_user = hmac.compare_digest(user.strip().lower().encode(), str(cfg.get("user", "")).lower().encode())
    ok_pw = check_password(pw, cfg["pw"])
    with _lock:
        last = max(int(cfg.get("last_step", 0)), _mem["last_step"])
        step = totp_match(cfg["totp"], code, now, last) if ok_user and ok_pw else None
        ok = step is not None
        if ok:
            _mem["last_step"] = cfg["last_step"] = step
            try:
                save(path, cfg)
            except OSError:
                pass  # the replay guard is also held in memory
    if not ok:
        _fail(ip, now)
        return False, "wrong user, password or code"
    tok = secrets.token_urlsafe(32)
    with _lock:
        _sessions[hashlib.sha256(tok.encode()).hexdigest()] = {"created": now, "last": now, "ip": ip, "user": cfg["user"]}
        _fails.pop(ip, None)
    return True, tok


def check(tok, now=None):
    """The session dict for a valid cookie token (and touches it), else None."""
    if not tok or len(tok) > 100:
        return None
    now = now or time.time()
    h = hashlib.sha256(tok.encode()).hexdigest()
    with _lock:
        s = _sessions.get(h)
        if not s:
            return None
        if now - s["last"] > IDLE or now - s["created"] > ABSOLUTE:
            del _sessions[h]
            return None
        s["last"] = now
        return dict(s)


def sign_out(tok):
    if tok:
        with _lock:
            _sessions.pop(hashlib.sha256(tok.encode()).hexdigest(), None)


def cookie_header(tok, max_age=ABSOLUTE, secure=True):
    name = COOKIE if secure else "unsyk_admin"
    flags = "Path=/; HttpOnly; SameSite=Strict" + ("; Secure" if secure else "")
    if tok is None:
        return f"{name}=; Max-Age=0; {flags}"
    return f"{name}={tok}; Max-Age={max_age}; {flags}"


def cookie_from(header, secure=True):
    name = COOKIE if secure else "unsyk_admin"
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == name:
            return v
    return None
