#!/usr/bin/env bash
# Push receiver, auth/admin/cloud modules, hvhctl (CLI + panel helper), the admin panel (server/admin), the systemd unit
# and unsyk.lua to pve2 LXC 115, then restart. The admin panel is home LAN + tailnet only: http://192.168.68.34:8080/admin
# and http://hvh-admin:8080/admin (CT 115 is its own Tailscale node).
# The token-gated public /script.lua (used by loader.lua) serves the script straight from disk, so this is also how the game updates.
#
# By default the SERVED script is obfuscated (Prometheus EncryptStrings + rename, scripts/obfuscate.sh);
# the repo keeps the readable unsyk.lua. Use  scripts/deploy.sh --raw  to ship the readable copy
# (faster, and the fallback if obfuscation ever breaks the script in game).
#
# Channels (server/hvh_release.py): every deploy is a numbered build.
#   scripts/deploy.sh                    new STABLE build (everyone)
#   scripts/deploy.sh --beta             new BETA build: only beta members get it (scripts/hvh beta add NAME)
#   --note "what changed"                shown in scripts/hvh release and the admin panel
# When the beta is good: scripts/hvh release promote (stable = the exact beta bytes, no rebuild).
# Server code (receiver, hvhctl, panel) is shared by both channels and always goes live.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
HOST=pve2-claude
CT=115
TMP=/root/hvh-deploy

RAW=0
CHANNEL=stable
NOTE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --raw) RAW=1 ;;
        --beta) CHANNEL=beta ;;
        --note) NOTE="${2:-}"; shift ;;
        *) echo "usage: scripts/deploy.sh [--raw] [--beta] [--note TEXT]" >&2; exit 2 ;;
    esac
    shift
done
GIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
git diff --quiet HEAD -- unsyk.lua 2>/dev/null || GIT="$GIT+dirty"

SERVE="unsyk.lua"
if [ "$RAW" = "0" ]; then
    scripts/obfuscate.sh unsyk.lua build/unsyk.min.lua
    SERVE="build/unsyk.min.lua"
else
    luac -p unsyk.lua
    echo "deploy: --raw, serving the readable script"
fi

# the script's built-in config presets, for the admin panel (Official presets page). Fails if the block changed shape.
mkdir -p build
python3 scripts/extract_builtin.py unsyk.lua > build/builtin_presets.json

ssh "$HOST" "rm -rf $TMP && mkdir -p $TMP"
scp -q server/receiver.py server/hvh_release.py server/hvh_auth.py server/hvh_admin.py server/hvh_cloud.py server/hvh_panel.py server/hvh_resolver.py server/hvhctl.py server/hvh-ingest.service loader.lua "$HOST:$TMP/"
scp -q server/admin/index.html server/admin/app.js server/admin/app.css "$HOST:$TMP/"
scp -q "$SERVE" "$HOST:$TMP/unsyk.lua"
scp -q build/builtin_presets.json "$HOST:$TMP/builtin_presets.json"
ssh "$HOST" "set -e
pct push $CT $TMP/receiver.py /opt/hvh-ingest/receiver.py --perms 644
pct push $CT $TMP/hvh_release.py /opt/hvh-ingest/hvh_release.py --perms 644
pct push $CT $TMP/unsyk.lua /tmp/unsyk.deploy.lua --perms 644
pct push $CT $TMP/loader.lua /opt/hvh-ingest/loader.lua --perms 644
pct push $CT $TMP/hvhctl.py /usr/local/bin/hvhctl --perms 755
pct push $CT $TMP/hvhctl.py /opt/hvh-ingest/hvhctl.py --perms 644
pct push $CT $TMP/hvh_auth.py /opt/hvh-ingest/hvh_auth.py --perms 644
pct push $CT $TMP/hvh_cloud.py /opt/hvh-ingest/hvh_cloud.py --perms 644
pct push $CT $TMP/hvh_admin.py /opt/hvh-ingest/hvh_admin.py --perms 644
pct push $CT $TMP/hvh_panel.py /opt/hvh-ingest/hvh_panel.py --perms 644
pct push $CT $TMP/hvh_resolver.py /opt/hvh-ingest/hvh_resolver.py --perms 644
pct push $CT $TMP/builtin_presets.json /opt/hvh-ingest/builtin_presets.json --perms 644
pct exec $CT -- mkdir -p /opt/hvh-ingest/admin
pct push $CT $TMP/index.html /opt/hvh-ingest/admin/index.html --perms 644
pct push $CT $TMP/app.js /opt/hvh-ingest/admin/app.js --perms 644
pct push $CT $TMP/app.css /opt/hvh-ingest/admin/app.css --perms 644
pct push $CT $TMP/hvh-ingest.service /etc/systemd/system/hvh-ingest.service --perms 644
rm -rf $TMP
# the legacy single file stays the stable copy (fallback while the release store is missing)
if [ $CHANNEL = stable ]; then pct exec $CT -- cp /tmp/unsyk.deploy.lua /opt/hvh-ingest/unsyk.lua; fi
pct exec $CT -- /usr/local/bin/hvhctl release publish /tmp/unsyk.deploy.lua --channel $CHANNEL --git $(printf %q "$GIT") --note $(printf %q "$NOTE")
pct exec $CT -- rm -f /tmp/unsyk.deploy.lua
pct exec $CT -- rm -f /opt/hvh-ingest/desync_aa.lua /opt/hvh-ingest/panel.html
pct exec $CT -- sh -c 'systemctl daemon-reload && systemctl restart hvh-ingest && sleep 1 && systemctl is-active hvh-ingest'"
