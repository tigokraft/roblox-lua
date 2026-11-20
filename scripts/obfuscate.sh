#!/usr/bin/env bash
# Build the served copy of unsyk.lua: minified + locals renamed by darklua (.darklua.json).
# The repo keeps the readable unsyk.lua; only what the loader downloads is obfuscated.
# darklua renames LOCAL variables only, so the cheat's API globals (menu, entity, rage, aa, plist,
# UNSYK_AUTH, UNSYK_VERSION, ...) are left intact. Usage: scripts/obfuscate.sh IN OUT
set -euo pipefail
cd "$(dirname "$0")/.."
IN="${1:-unsyk.lua}"
OUT="${2:-build/unsyk.min.lua}"
mkdir -p "$(dirname "$OUT")"

if ! command -v darklua >/dev/null 2>&1; then
    echo "obfuscate: darklua not found (cargo install darklua). Aborting so we never ship readable code by surprise." >&2
    exit 2
fi

luac -p "$IN"   # syntax-gate the readable source first (Lua 5.5: catches syntax + the 200-local limit)
darklua process --format dense "$IN" "$OUT"

# darklua writes non-ASCII characters (°, ·) as \u{b0}-style escapes, which the cheat's Lua does not know: the
# menu showed "180u{b0}". Rewrite each one as its UTF-8 bytes in decimal escapes ("\194\176"), valid everywhere.
python3 - "$OUT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r"\\u\{([0-9a-fA-F]+)\}",
           lambda m: "".join("\\%d" % b for b in chr(int(m.group(1), 16)).encode("utf-8")), s)
open(p, "w", encoding="utf-8").write(s)
PY
grep -q '\\u{' "$OUT" && { echo "obfuscate: \\u{..} escapes left in output — the game shows them as text" >&2; exit 8; }

# sanity: output exists, parses, comments are gone, API globals survived, and it got meaningfully smaller
test -s "$OUT" || { echo "obfuscate: empty output" >&2; exit 3; }
luac -p "$OUT" || { echo "obfuscate: darklua output does not parse" >&2; exit 4; }
grep -q "hard way\|incoming-shot event" "$OUT" && { echo "obfuscate: comments survived — rules did not run" >&2; exit 5; }
for g in UNSYK_AUTH UNSYK_VERSION menu entity rage aa plist; do
    grep -q "$g" "$OUT" || { echo "obfuscate: global '$g' missing from output — would break the script" >&2; exit 6; }
done
in_b=$(wc -c <"$IN"); out_b=$(wc -c <"$OUT")
[ "$out_b" -lt $(( in_b * 85 / 100 )) ] || { echo "obfuscate: output not smaller — darklua likely did nothing" >&2; exit 7; }
echo "obfuscate: $IN ($in_b B) -> $OUT ($out_b B, $(( out_b * 100 / in_b ))%)"
