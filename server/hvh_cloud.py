"""Cloud configs for unsyk. Stdlib only.

One JSON file per account (license key name, or "owner" for the master token) in CLOUD_DIR:
  {"configs": {name: {"data": {...}, "ts": int, "code": "ABC123"}}}
plus shares.json: {code: [acct, name]} so a config can be loaded by anyone logged in who has its code.

data is a flat {"Section/Item": value} map written by the script; values must be bool, number or short string.
"""
import hashlib
import json
import os
import re
import secrets
import threading
import time

MAX_CONFIGS = 20
MAX_BYTES = 32 * 1024
MAX_KEYS = 400
NAME_RE = re.compile(r"^[A-Za-z0-9 _.\-]{1,24}$")
CODE_RE = re.compile(r"^[A-Z2-9]{6}$")
_lock = threading.Lock()


def _file(d, acct):
    return os.path.join(d, hashlib.sha256(acct.encode()).hexdigest()[:24] + ".json")


def _read(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, separators=(",", ":"))
    os.replace(tmp, path)


def _load(d, acct):
    data = _read(_file(d, acct), {})
    if not isinstance(data.get("configs"), dict):
        data = {"acct": acct, "configs": {}}
    return data


def count(d, acct):
    return len(_load(d, acct)["configs"])


def _clean(data):
    if not isinstance(data, dict) or not data or len(data) > MAX_KEYS:
        raise ValueError("config data must be a non-empty object")
    out = {}
    for k, v in data.items():
        if not isinstance(k, str) or len(k) > 80:
            raise ValueError("bad key")
        if isinstance(v, bool) or (isinstance(v, (int, float)) and abs(v) < 1e7):
            out[k] = v
        elif isinstance(v, str) and len(v) <= 64:
            out[k] = v
        else:
            raise ValueError(f"bad value for {k}")
    if len(json.dumps(out)) > MAX_BYTES:
        raise ValueError("config too large")
    return out


def get(d, acct, name=None, code=None):
    if code:
        code = code.strip().upper()
        if not CODE_RE.match(code):
            return 400, {"error": "bad code"}
        ref = _read(os.path.join(d, "shares.json"), {}).get(code)
        if not ref:
            return 404, {"error": "no config with that code"}
        c = _load(d, ref[0])["configs"].get(ref[1])
        if not c:
            return 404, {"error": "that config was deleted"}
        return 200, {"name": ref[1], "by": ref[0], "ts": c["ts"], "data": c["data"]}
    cfgs = _load(d, acct)["configs"]
    if name:
        c = cfgs.get(name)
        if not c:
            return 404, {"error": "no such config"}
        return 200, {"name": name, "ts": c["ts"], "code": c.get("code"), "data": c["data"]}
    rows = [{"name": n, "ts": c["ts"], "code": c.get("code"), "size": len(c["data"])} for n, c in cfgs.items()]
    rows.sort(key=lambda r: -r["ts"])
    return 200, {"configs": rows, "max": MAX_CONFIGS}


def post(d, acct, req):
    op, name = req.get("op"), req.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name.strip()):
        return 400, {"error": "name: 1-24 letters, digits, space . _ -"}
    name = name.strip()
    with _lock:
        store = _load(d, acct)
        cfgs = store["configs"]
        shares_path = os.path.join(d, "shares.json")
        shares = _read(shares_path, {})
        if op == "save":
            try:
                data = _clean(req.get("data"))
            except ValueError as e:
                return 400, {"error": str(e)}
            if name not in cfgs and len(cfgs) >= MAX_CONFIGS:
                return 409, {"error": f"limit is {MAX_CONFIGS} configs, delete one first"}
            code = (cfgs.get(name) or {}).get("code")
            if not code:
                alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
                while True:
                    code = "".join(secrets.choice(alphabet) for _ in range(6))
                    if code not in shares:
                        break
                shares[code] = [acct, name]
                _write(shares_path, shares)
            cfgs[name] = {"data": data, "ts": int(time.time()), "code": code}
            store["acct"] = acct
            _write(_file(d, acct), store)
            return 200, {"ok": True, "name": name, "code": code}
        if op == "delete":
            c = cfgs.pop(name, None)
            if not c:
                return 404, {"error": "no such config"}
            if c.get("code"):
                shares.pop(c["code"], None)
                _write(shares_path, shares)
            _write(_file(d, acct), store)
            return 200, {"ok": True}
    return 400, {"error": "op must be save or delete"}


def list_all(d):
    """[(acct, name, ts, code, size)] for hvhctl."""
    out = []
    try:
        files = [f for f in os.listdir(d) if f.endswith(".json") and f != "shares.json"]
    except OSError:
        return out
    for f in files:
        s = _read(os.path.join(d, f), {})
        for n, c in (s.get("configs") or {}).items():
            out.append((s.get("acct", "?"), n, c.get("ts", 0), c.get("code"), len(c.get("data") or {})))
    return sorted(out, key=lambda r: -r[2])


# ---------------- official presets (published by the admin, readable by every logged-in user) ----------------
# official.json in CLOUD_DIR: {"presets": {name: {"data": {...}, "ts": int, "note": str, "order": int, "from": str}}}

MAX_PRESETS = 12


def _off_path(d):
    return os.path.join(d, "official.json")


def presets(d, with_data=False):
    p = _read(_off_path(d), {}).get("presets") or {}
    rows = []
    for n, c in p.items():
        r = {"name": n, "ts": c.get("ts", 0), "note": c.get("note", ""), "order": c.get("order", 99),
             "size": len(c.get("data") or {}), "from": c.get("from", "")}
        if with_data:
            r["data"] = c.get("data") or {}
        rows.append(r)
    rows.sort(key=lambda r: (r["order"], r["name"].lower()))
    return rows


def preset_get(d, name):
    c = (_read(_off_path(d), {}).get("presets") or {}).get(name)
    if not c:
        return 404, {"error": "no such official config"}
    return 200, {"name": name, "ts": c.get("ts", 0), "note": c.get("note", ""), "official": True, "data": c.get("data") or {}}


def preset_save(d, name, data, note="", source="", rename_from=None):
    if not isinstance(name, str) or not NAME_RE.match(name.strip()):
        raise ValueError("name: 1-24 letters, digits, space . _ -")
    name = name.strip()
    data = _clean(data)
    with _lock:
        store = _read(_off_path(d), {})
        p = store.get("presets") if isinstance(store.get("presets"), dict) else {}
        old = p.get(rename_from) if rename_from else p.get(name)
        if rename_from and rename_from != name:
            if name in p:
                raise ValueError(f"an official config named {name} exists already")
            p.pop(rename_from, None)
        if name not in p and not old and len(p) >= MAX_PRESETS:
            raise ValueError(f"limit is {MAX_PRESETS} official configs")
        order = (old or {}).get("order", len(p))
        p[name] = {"data": data, "ts": int(time.time()), "note": str(note or "")[:140], "order": order,
                   "from": str(source or (old or {}).get("from", ""))[:64]}
        _write(_off_path(d), {"presets": p})
    return name


def preset_delete(d, name):
    with _lock:
        store = _read(_off_path(d), {})
        p = store.get("presets") if isinstance(store.get("presets"), dict) else {}
        if p.pop(name, None) is None:
            raise ValueError("no such official config")
        _write(_off_path(d), {"presets": p})


def preset_order(d, names):
    with _lock:
        store = _read(_off_path(d), {})
        p = store.get("presets") if isinstance(store.get("presets"), dict) else {}
        for i, n in enumerate(names):
            if n in p:
                p[n]["order"] = i
        _write(_off_path(d), {"presets": p})


# ---------------- admin access to everyone's configs ----------------

def admin_list(d):
    """[{acct, name, ts, code, size}] for every account, newest first."""
    return [{"acct": a, "name": n, "ts": ts, "code": code, "size": size} for a, n, ts, code, size in list_all(d)]


def admin_get(d, acct, name):
    c = _load(d, acct)["configs"].get(name)
    if not c:
        return None
    return {"acct": acct, "name": name, "ts": c["ts"], "code": c.get("code"), "data": c["data"]}


def admin_delete(d, acct, name):
    return post(d, acct, {"op": "delete", "name": name})
