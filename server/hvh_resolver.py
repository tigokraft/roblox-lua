"""Server side of the candidate resolver ("brain"): the candidate yaw offsets, their priors, the scoring weights
and every threshold the client used to hardcode in st.rsx. The client (unsyk.lua) only measures the enemy
(features) and runs a generic scorer over what GET /resolver returns, held in memory only.

Per build: every served copy is stamped with UNSYK_RSEED = seed(build). The client puts its features into
slots in an order (and with signs) derived from that seed, and this table refers to features by slot. So a table
only makes sense together with the copy of the same build: a dumped table goes stale on the next build, and a
copy without the server has no resolver at all. This is cost + traceability, not a wall: a live session can still
fetch the table once and keep using that build.

rv (resolver version) = HMAC(secret, GEN | build): changes per build, when the secret rotates, or when GEN is
bumped after tuning the numbers below (running clients re-fetch when /beat reports a new rv).
"""

import hashlib
import hmac

GEN = 1   # bump after changing CANDIDATES / WEIGHTS: running clients see a new rv on /beat and re-fetch

# Feature names in the order the client lists them (unsyk.lua, CANDIDATE RESOLVER block, FEAT). Keep in sync.
#   b  base offset (our desync-side read, flip prediction applied)       l  lby - eye yaw
#   d  their desync delta (only when |dd| >= dmin)                       t  lby twist
#   e  eye yaw - jitter reference (only while they jitter)               s  sign opposite to e (-1 / 1)
#   a  min(|dd|, acap) (only when |dd| >= dmin)
FEAT = ("b", "l", "d", "t", "e", "s", "a")

# Each candidate: offset = k + sum(c * F[x] * (F[y] or yd)); unavailable when a needed F is missing.
# need = {feature: min |value|}. "/pred" is appended to the name when it uses b and b came from a prediction.
CANDIDATES = [
    {"n": "read",  "p": 3.0, "t": [(1, "b")]},
    {"n": "inv",   "p": 2.2, "t": [(-1, "b")]},
    {"n": "lby",   "p": 2.6, "t": [(1, "l")], "need": {"l": 6}},
    {"n": "lby+d", "p": 1.8, "t": [(1, "l"), (1, "d")]},
    {"n": "lby-d", "p": 1.8, "t": [(1, "l"), (-1, "d")]},
    {"n": "twist", "p": 1.6, "t": [(1, "l"), (1, "t")], "need": {"t": 5}},
    {"n": "mean",  "p": 1.2, "t": [(-1, "e")]},
    {"n": "jit",   "p": 2.4, "t": [(1, "s", "a", 58)], "need": {"e": 5}},
    {"n": "+58",   "p": 1.0, "k": 58},
    {"n": "-58",   "p": 1.0, "k": -58},
    {"n": "+84",   "p": 0.8, "k": 84},
    {"n": "-84",   "p": 0.8, "k": -84},
]

WEIGHTS = {
    "dmin": 8, "acap": 84, "omax": 90,        # desync read counts from 8 deg; offsets beyond 90 = bad read
    "lr": 15, "ll": 12, "lt": 5,              # legit-looking: base read < 15, |lby| < 12, |twist| < 5
    "dk": 0.85, "dt": 2,                      # score decay x0.85 every 2 s
    "hit": 2, "miss": -3,                     # own hit / own resolver miss
    "bs": 4, "bw": 5, "bp": -12,              # a missed offset is blocked 4 s within +-5 deg, -12 score
    "hy": 0.3, "sig": 20,                     # keep current pick +0.3; AA signature must hold 20 ticks to wipe scores
    "pb": 45, "pfn": 8, "pfs": 0.6,           # pitch buckets at +-45; fix flicks with 8+ samples, 60% in one bucket
    "hb": 3, "hb0": 2,                        # hand back to the built-in resolver after N own misses (cands / plain)
    "raw0": 15, "inv0": 2,                    # plain read/inverse: skip below 15 deg, flip side after misses >= hits+2
}


def _key(secret, what):
    k = secret.encode() if isinstance(secret, str) else secret
    return hmac.new(k, what.encode(), hashlib.sha256).hexdigest()


def seed(secret, build):
    """Integer in [1, 2^31-2] stamped into the served copy as UNSYK_RSEED."""
    return int(_key(secret, f"rseed|{int(build)}")[:7], 16) % 2147483646 + 1


def rv(secret, build):
    return _key(secret, f"rv|{GEN}|{int(build)}")[:10]


def layout(sd, n=len(FEAT)):
    """Slot and sign of each feature, from the seed. Mirrors unsyk.lua X.layout exactly (minstd + Fisher-Yates):
    returns (slot, sign) lists indexed by feature position 0..n-1, slots 1-based."""
    x = int(sd)
    perm = list(range(1, n + 1))          # perm[i-1] = slot of feature i
    for i in range(n, 1, -1):
        x = (x * 48271) % 2147483647
        j = x % i + 1
        perm[i - 1], perm[j - 1] = perm[j - 1], perm[i - 1]
    sign = []
    for _ in range(n):
        x = (x * 48271) % 2147483647
        sign.append(1 if x % 2 == 0 else -1)
    return perm, sign


def table(secret, build):
    """The JSON the client gets from GET /resolver for BUILD."""
    perm, sign = layout(seed(secret, build))
    pos = {f: i for i, f in enumerate(FEAT)}

    def slot(f):
        return perm[pos[f]]

    def sg(f):
        return sign[pos[f]]

    out = []
    for c in CANDIDATES:
        terms = []
        for t in c.get("t", []):
            coef, x = t[0], t[1]
            # the client stores sign * value, so multiply the sign back out of the coefficient
            row = [coef * sg(x), slot(x)]
            if len(t) > 2:
                y, yd = t[2], t[3]
                row[0] = row[0] * sg(y)
                row += [slot(y), yd * sg(y)]   # yd is used in place of F[y], which is stored signed too
            terms.append(row)
        out.append({"n": c["n"], "p": c["p"], "t": terms, "k": c.get("k", 0),
                    "q": [[slot(f), m] for f, m in c.get("need", {}).items()],
                    "b": 1 if any(t[1] == "b" for t in c.get("t", [])) else 0})
    return {"rv": rv(secret, build), "b": int(build), "fs": len(FEAT), "c": out, "w": dict(WEIGHTS)}
