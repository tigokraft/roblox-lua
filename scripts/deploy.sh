#!/usr/bin/env bash
# Push receiver, auth/admin/cloud modules, hvhctl (CLI + panel helper), the admin panel (server/admin), the systemd unit
# and unsyk.lua to pve2 LXC 115, then restart. The admin panel is home-LAN only: http://192.168.68.34:8080/admin.
# The token-gated public /script.lua (used by loader.lua) serves the script straight from disk, so this is also how the game updates.
#
# By default the SERVED script is obfuscated (minified + locals renamed by darklua, scripts/obfuscate.sh);
# the repo keeps the readable unsyk.lua. Use  scripts/deploy.sh --raw  to ship the readable copy
# (faster, and the fallback if obfuscation ever breaks the script in game).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
HOST=pve2-claude
CT=115
TMP=/root/hvh-deploy

RAW=0
[ "${1:-}" = "--raw" ] && RAW=1

SERVE="unsyk.lua"
if [ "$RAW" = "0" ]; then
    scripts/obfuscate.sh unsyk.lua build/unsyk.min.lua
    SERVE="build/unsyk.min.lua"
else
    luac -p unsyk.lua
    echo "deploy: --raw, serving the readable script"
fi

ssh "$HOST" "rm -rf $TMP && mkdir -p $TMP"
scp -q server/receiver.py server/hvh_auth.py server/hvh_admin.py server/hvh_cloud.py server/hvhctl.py server/hvh-ingest.service loader.lua "$HOST:$TMP/"
scp -q server/admin/index.html server/admin/app.js server/admin/app.css "$HOST:$TMP/"
scp -q "$SERVE" "$HOST:$TMP/unsyk.lua"
ssh "$HOST" "set -e
pct push $CT $TMP/receiver.py /opt/hvh-ingest/receiver.py --perms 644
pct push $CT $TMP/unsyk.lua /opt/hvh-ingest/unsyk.lua --perms 644
pct push $CT $TMP/loader.lua /opt/hvh-ingest/loader.lua --perms 644
pct push $CT $TMP/hvhctl.py /usr/local/bin/hvhctl --perms 755
pct push $CT $TMP/hvhctl.py /opt/hvh-ingest/hvhctl.py --perms 644
pct push $CT $TMP/hvh_auth.py /opt/hvh-ingest/hvh_auth.py --perms 644
pct push $CT $TMP/hvh_cloud.py /opt/hvh-ingest/hvh_cloud.py --perms 644
pct push $CT $TMP/hvh_admin.py /opt/hvh-ingest/hvh_admin.py --perms 644
pct exec $CT -- mkdir -p /opt/hvh-ingest/admin
pct push $CT $TMP/index.html /opt/hvh-ingest/admin/index.html --perms 644
pct push $CT $TMP/app.js /opt/hvh-ingest/admin/app.js --perms 644
pct push $CT $TMP/app.css /opt/hvh-ingest/admin/app.css --perms 644
pct push $CT $TMP/hvh-ingest.service /etc/systemd/system/hvh-ingest.service --perms 644
rm -rf $TMP
pct exec $CT -- rm -f /opt/hvh-ingest/desync_aa.lua /opt/hvh-ingest/panel.html
pct exec $CT -- sh -c 'systemctl daemon-reload && systemctl restart hvh-ingest && sleep 1 && systemctl is-active hvh-ingest'"
