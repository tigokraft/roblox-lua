---
name: hvh
description: Watch, analyze and remote-control the user's live penablox game through the unsyk feed. Use when the user says they are playing / about to play, asks why they are dying or missing, asks for a session report, or wants AA settings changed or A/B tested ("/hvh", "/hvh live", "/hvh report", "/hvh set pitch=Up").
---

# hvh: live game link

The game script (`unsyk.lua`) streams events every ~2s to `https://feed.sites.exxo.world/ingest`. They land in SQLite on pve2 LXC 115. Everything is read and controlled from this Mac with `scripts/hvh <hvhctl args>` (SSH → `pct exec 115 -- /usr/local/bin/hvhctl`).

## Commands
- `scripts/hvh sessions`: recent sessions with deaths/shots. Run first to see if data is arriving.
- `scripts/hvh report [--session latest|all|ID] [--since 30m]`: death and shot breakdown.
- `scripts/hvh events -n 40 [--kind hit|shot|state|intel|ctrl] [--json]`: raw rows (use `--json` for full timelines).
- `scripts/hvh follow`: live tail. **Run it with the Monitor tool** (each line becomes an event to you) while the user plays; react to deaths/misses as they come, briefly. `--all` adds 5s state/intel snapshots (noisy).
- `scripts/hvh config`, `config set k=v ... --note "why"`, `config unset k`, `config clear`, `keys`.
- Config is per account: without `--acct` it changes **everyone** (all friends with remote control on, which is now auto-on for license users). `--acct NAME` (license name, or `owner` for the master token) changes only that account; its keys win over everyone's. `config show` lists every layer; `config show --acct NAME` shows that account's effective config. A/B tests on the user alone: always `--acct owner` (or their license name).

## Live mode ("/hvh live" or "I'm playing")
1. `scripts/hvh sessions`. If the newest session isn't from the last minute, ask the user to check "Stream" is on (Settings > Feed) and look for `[FEED]` errors in the Lua console.
2. Start `scripts/hvh follow` under Monitor. Comment only when there is something useful: a pattern (3 deaths in a row standing on side L, same killer), not every event.
3. Every few deaths, run `report --since 10m` and summarise in 2-3 lines.

## Reading the data
- `DEATH -100 (100->0)` = one-shot. `flip=Nt` = ticks since our desync side flipped; deaths clustering at 0-1t mean the flip is being read/predicted. `choke=0` is expected while double tap is on: in this cheat DT disables fake lag.
- "likely killer" is a guess (the only scoped enemy, else the nearest). The API has no death/attacker event.
- Shots: `FIRE` carries hitchance (`hc`), predicted damage, resolver yaw (`ryaw`) and the target's AA pattern at fire time. Hit/miss share `id` with the fire. Miss `reason` comes from the cheat: resolver / spread / occlusion / death. Many resolver misses vs one enemy → look at their `pat` in intel.
- Every event has `my` (my weapon: `wep`, `scoped`, `spr`, `inacc`) and `srv` (the user's "Server spread" label: Unknown/Spread/No spread). `server` events record the Roblox JobId when it changes; `state` has `job` (first 8 chars). Always split analysis by weapon (Scout vs Deagle play very differently) and by server type.
- On **no-spread servers** a miss labelled `spread` is not real spread: treat it as resolver/desync or prediction error. The `[inacc: x]` suffix is the cheat's own figure.
- `hc` (hitchance) and `bt` (backtrack) always come through as 0/None from this cheat: ignore. The DT charge readout (`dt=0/14 off`) is broken too; real double taps show up as two FIREs in the same second.
- Every event has `cv` = remote config version active at that moment, so `report` can compare deaths/min per config.

## Resolver
- FIRE lines show `rs=<mode>:<OURS|builtin> off=<deg> <src> lead=<t> nxt=<t> <state> pat=<pattern>`. `src`: `read` = current side, `pred` = predicted flip before the shot lands, `+inv` = learned inverse for that state.
- Evaluate with `report` RESOLVER section: compare resolver-miss rate of `ours` vs `built-in`. Resolver misses are rare (~4% of shots in session 2), so it needs many shots; say so.
- Rollout: Shadow (default) to sanity-check reads → `config set rs_mode=Active rs_take=1` (takes over only players the built-in already missed) → `rs_take=0` only if `ours` clearly beats `built-in`.

## Remote control rules
- The user must have "Remote control" on (window: Settings > Feed). Changes apply within ~5s and print `[CTRL] vN ...` in their Lua console. Confirm it took effect: the next `state` row shows the new `cv`, or a `CTRL` line appears in follow.
- Change **one thing at a time** for A/B tests and always pass `--note`. Tell the user in chat what you changed and why before or right after.
- Allowed keys only (`scripts/hvh keys`): AA, desync, defensive, on-shot. Never anything else.
- When done testing, or when the user says stop, run `config clear` so their own values come back. Turning the toggle off in game also restores them.
- A/B test: run each config for a similar amount of time (≥5 min, ideally a few rounds), then compare `report` "BY REMOTE CONFIG" deaths/min. Small samples are noise; say so.

## Other
- Admin panel (configs, official presets, licenses, live data, served copies), home LAN only:
  http://192.168.68.34:8080/admin (password + authenticator code; set up with `hvhctl admin setup` in the CT).
  Never proxied by Caddy; /admin is 404 on the public host.
- After editing `unsyk.lua` or `server/*`: `scripts/deploy.sh`. The user runs `loader.lua`, which pulls the deployed script, so they get changes by reloading the loader (the script also prints `[UPDATE]` within 60s). Check `ver=` in `follow --all` state lines to see which build they run. (restarts the receiver, updates the copy page). Changes to the Caddy block are on the VPS: `/etc/caddy/Caddyfile`.
- Never print the ingest token (`server/ingest.env`).
