#!/usr/bin/env bash
# Build the served copy of unsyk.lua with the Prometheus obfuscator (levno-710), RENAME-ONLY config
# (no steps: strips comments, renames LOCALS). See scripts/prometheus.config.lua for why string encryption
# and the VM are off (string encryption cost ~10 fps in game). The repo keeps the readable unsyk.lua; only
# what the loader downloads is obfuscated. Globals (entity, rage, aa, plist, UNSYK_AUTH, UNSYK_VERSION, ...)
# survive as identifiers. Usage: scripts/obfuscate.sh IN OUT
set -euo pipefail
cd "$(dirname "$0")/.."
IN="${1:-unsyk.lua}"
OUT="${2:-build/unsyk.min.lua}"
CFG="scripts/prometheus.config.lua"
PROM_DIR="tools/prometheus"
PROM_COMMIT="a98c50165f2a53f6d765a82eee60dfea53803445"   # pinned; bump deliberately
mkdir -p "$(dirname "$OUT")"

command -v luajit >/dev/null 2>&1 || { echo "obfuscate: luajit not found (needed to run Prometheus). Aborting." >&2; exit 2; }

# Prometheus is a build tool, vendored under tools/ (gitignored). Auto-clone+pin if missing.
if [ ! -f "$PROM_DIR/cli.lua" ]; then
    echo "obfuscate: fetching Prometheus into $PROM_DIR ..." >&2
    rm -rf "$PROM_DIR"
    git clone --quiet https://github.com/levno-710/Prometheus.git "$PROM_DIR"
fi
git -C "$PROM_DIR" rev-parse HEAD 2>/dev/null | grep -q "^$PROM_COMMIT" || {
    git -C "$PROM_DIR" fetch --quiet origin "$PROM_COMMIT" 2>/dev/null || true
    git -C "$PROM_DIR" checkout --quiet "$PROM_COMMIT" 2>/dev/null \
        || { echo "obfuscate: Prometheus is not at the pinned commit $PROM_COMMIT and could not check it out." >&2; exit 2; }
}

luac -p "$IN"   # syntax-gate the readable source first (Lua 5.5: catches syntax + the 200-local limit)

luajit "$PROM_DIR/cli.lua" --config "$CFG" --nocolors --out "$OUT" "$IN" >/dev/null 2>/tmp/obf_prom.err || {
    echo "obfuscate: Prometheus failed:" >&2; tail -5 /tmp/obf_prom.err >&2; exit 3; }

# ---- sanity gates ----------------------------------------------------------
test -s "$OUT" || { echo "obfuscate: empty output" >&2; exit 3; }

# Parses (also catches a main chunk over Lua's 200-local limit: wrap a top-level section in an IIFE).
luac -p "$OUT" 2>/tmp/obf_luac.err || {
    echo "obfuscate: Prometheus output does not parse:" >&2; head -1 /tmp/obf_luac.err >&2
    grep -q "too many local variables" /tmp/obf_luac.err && \
      echo "  -> main chunk is over the 200-local limit; wrap a top-level section in ;(function() ... end)()" >&2
    exit 4; }

# Comments gone, and no string-rewriting step slipped back in (it costs fps: see the config).
grep -q "hard way\|incoming-shot event" "$OUT" && { echo "obfuscate: comments survived — obfuscation did not run" >&2; exit 5; }
grep -qF "Override yaw offset" "$OUT" || { echo "obfuscate: string literals were rewritten — that step costs ~10 fps in game (see prometheus.config.lua)" >&2; exit 5; }

# API globals survived as identifiers (Prometheus never touches globals).
for g in entity rage aa plist weapon UNSYK_AUTH UNSYK_VERSION UNSYK_STOP; do
    grep -q "\b$g\b" "$OUT" || { echo "obfuscate: global '$g' missing from output — would break the script" >&2; exit 6; }
done

# Pure ASCII (the cheat's Lua mangles \u{..} and stray UTF-8 in the served copy). Fail loudly if any slips through.
LC_ALL=C grep -q '[^ -~'$'\t'']' "$OUT" && { echo "obfuscate: non-ASCII bytes left in output — the game may mis-render them" >&2; exit 7; }

# Size band: rename-only SHRINKS the file (comments/whitespace gone). Reject if it did nothing (>=95%) or
# grew (a step slipped in).
in_b=$(wc -c <"$IN"); out_b=$(wc -c <"$OUT")
[ "$out_b" -lt $(( in_b * 95 / 100 )) ] || { echo "obfuscate: output >=95% of source ($out_b B) — obfuscation did nothing, or a step that grows code slipped in" >&2; exit 8; }

echo "obfuscate: $IN ($in_b B) -> $OUT ($out_b B, $(( out_b * 100 / in_b ))% — Prometheus rename-only)"
