#!/usr/bin/env bash
# Pull feed data from the server into exports/<date>[_NAME]/ as CSV, one file per kind.
#   scripts/export.sh                 everyone, all time
#   scripts/export.sh NAME [24h]      one license (use "owner" for the master token), optional time window
set -euo pipefail
cd "$(dirname "$0")/.."
who="${1:-}"; since="${2:-}"
dir="exports/$(date +%Y%m%d_%H%M)${who:+_$who}"
mkdir -p "$dir"
for k in deaths hits shots intel state ctrl uploads; do
    args=(export --kind "$k")
    [ -n "$who" ] && args+=(--lic "$who")
    [ -n "$since" ] && args+=(--since "$since")
    scripts/hvh "${args[@]}" > "$dir/$k.csv"
    echo "$dir/$k.csv  $(($(wc -l < "$dir/$k.csv") - 1)) rows"
done
