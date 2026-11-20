# penablox HvH Lua — handoff notes for the next Claude session

Read this first. It is the full state of the project as of the end of the first session (2026-11-20).

## What this is
A Luau script (`desync_aa.lua`) for the **penablox** cheat (a Roblox-based CS:GO clone, played **HvH**: hack vs hack, everyone is cheating by consent). The user loads it in the cheat as `test2.lua` and pastes console output back to us. There is **no way to run Lua locally** — all testing is in-game, so every claim about behaviour is unverified until the user pastes logs.

Goals the user stated: bring things to HvH (roll / desync control), understand why they keep getting one-tapped, predict enemy AA, find the best peek timing, and have live data streamed to their own server so Claude "is always aware of what's happening in game".

## Repo layout
- `desync_aa.lua` — the whole script (~1500 lines, appended in sections, see below).
- `server/receiver.py` — stdlib Python ingest endpoint (token-checked, size/rate-limited, writes SQLite). No read endpoint on purpose.
- `server/Caddyfile.snippet` — Caddy block proxying only `/ingest` and `/health` to `127.0.0.1:8787`.
- `server/hvh-ingest.service` — hardened systemd unit (reads `INGEST_TOKEN` from `/etc/hvh-ingest.env`).
- `docs/penablox-luapi.md` — the cheat's Lua API docs the user supplied (third-party docs; only the first ~1050 of 1556 lines were read closely, rest was grepped).

### Sections inside `desync_aa.lua` (in file order)
1. Menu + config (AA, desync, defensive, on-shot, manual keys)
2. `dt_state()` double-tap detection (neverpeek's fallbacks), `st` state table
3. AA logic: `regular()`, `defensive()`, `onshot()`, per-state limits, inverter modes
4. HUD text + world-space REAL/FAKE/VIEW arrows (`Drawing` lines, `render.world_to_screen`)
5. Debug: old one-line hit logger (`dbg_*`, console print default off)
6. Enemy intel (`intel_*`): nearest N enemies, derives desync side from feet yaw − eye yaw, classifies flip pattern, predicts next flip
7. Peek advisor (`peek_eval`): GOOD/OK/WAIT from pattern stability vs ping, defensive recency
8. Shot log (`sh_*`): own aim_fire/hit/miss with miss reason + target intel; "death (local)" misses are ignored
9. Fine data (`fd_*`): per-tick ring buffer, per-hit timeline with ping marker, crosstab stats, CSV, dump-last-N buttons
10. Discord export (`dc_*`): webhook posting with 429 retry (**does not work in practice, see below**)
11. Live server feed (`sv_*`): batches events to the user's own ingest endpoint

## Engine quirks learned the hard way (IMPORTANT)
- **Never use compound assignment on table fields** (`st.n += 1`). This interpreter turns it into a bad `table.insert` and throws `invalid argument #2 to 'insert' (number expected, got string)` every tick, silently killing the whole tick listener. Write `st.n = st.n + 1`. We stripped them all.
- Do **not** wrap API calls in a varargs helper (`P(fn, ...)`) that passes string args; we replaced it with direct `pcall(fn, a, b)` (this is how working scripts like kernel's do it). Not proven to be the cause, but the error stopped after both changes.
- `render.indicator` called every paint frame **stacks forever and lags the game**. Use one persistent `Drawing.new("Text")` and update `.Text`/`.Visible`.
- `aa.override_desync_limits` docs say 86° but working scripts cap at **84**; we use 84.
- `anim.desync` from `entity.get_anim_state` is a **constant (84)** for most players — useless. Derive side from `goal_feet_yaw − eye_angles_y`.
- Output: `client.log` / `client.color_log` go to the **cheat's Lua console** (user copies from there with Ctrl+C). `print` also reaches the Roblox console. `setclipboard` is blocked by Roblox. The Lua console auto-clears when flooded → keep live output to one line per event; dump details on demand with buttons.
- Callback tick listeners log errors only every ~3s, so an erroring listener looks quiet. A stuck `flipAge` in the logs usually means the main AA tick is throwing.
- Rage players' displayed eye angles are their **AA angles, not their aim** (silent aim). The `aimerr` "who is looking at me" check is unreliable; peek advisor has it off by default.
- Arrow orientation needed `Rotation offset = 180` (VIEW arrow pointed at the camera at 0). Calibrate with the white VIEW arrow.
- No event exists for incoming shots; we detect hits by watching own health each tick and snapshot AA state. No roll setter exists in the API (`client.get_camera_angles_deg` returns roll, read-only) — nobody else's scripts use roll either.
- Discord webhook through the cheat's HttpService proxy returned **429 on every attempt**, even a single message → the proxy's shared IP is throttled. Retry/backoff was added but may not fix it. Hence the own-server feed.

## What the logs showed (first session)
- Nearly every death was a **single 100-damage hit** (Scout headshots), at 15–150 studs, in all states (stand/air/duck), mostly with the `Delayed` inverter and `Center` modifier, pitch `Down`. The user fired almost nothing before dying ("death (local)" misses), so offense couldn't be assessed.
- Early deaths had manual-yaw keys stuck on (toggle mode) → fixed by making Z/C/X **Hold**; desync limit randomisation lowered to 88–100% and moving/air limits default 84.
- Enemy intel: most tracked enemies run pitch **Up (−70)** ~99% of the time vs our `Down` — a lead worth A/B testing, not proof. Pretalhada13 flips side often (~91 flips, "variable 11±7t").
- `choke=0` on every row even with fake lag 10, and `dt=0/14 off` → fake lag and double tap are probably not enabled in the cheat's own menu, or the API doesn't reflect them. **Unresolved.**
- real/fake delta ≈ 2 × limit (168 at 84°), so desync itself is working as configured.

## Current state / next steps
1. **Live feed is written but never deployed or tested.** Needs: the user's VPS saved as an SSH connection in the Claude app (they said they would), a domain pointing at it, then deploy `server/` (receiver in `/opt/hvh-ingest`, token in `/etc/hvh-ingest.env` chmod 600, Caddy block, systemd unit), check `https://<domain>/health`, then in-game: paste URL + token into the "Live server feed" textboxes and press "Send test event". Unknown whether the cheat's HttpService proxy allows arbitrary domains. Read data over SSH: `sqlite3 /var/lib/hvh-ingest/events.db "select ts,kind,data from events order by id desc limit 20"`. The user also floated Appwrite; they chose the simple SQLite receiver.
2. Ask the user to check double tap and fake lag are enabled in the cheat's menu; the HUD shows `choke` and `DT n/14 on|off [source]`.
3. Idea the user liked but not built: an **A/B tester** that cycles inverter/pitch settings per round (`round_start` event exists) and counts deaths per setting. Also a resolver built on the enemy intel / `plist` overrides (see the user's other scripts' approach: hybrid brute-force + adaptive, learns from `aim_miss`).
4. Verify the new code actually loads: expect `[desync_aa] v3 loaded` in the Lua console. Earlier pastes showed the user running stale copies several times — always check that line first.

## Safety / conventions
- **Never hardcode the Discord webhook URL or the ingest token** in any file. They live in menu textboxes and the cheat's `database`. The user's webhook was pasted only into the menu.
- Server work touches the user's VPS: confirm each step with them first (config changes, reloads, installs). Do not ask them to paste keys/passwords in chat; use the app's saved SSH connection.
- Logs contain other players' usernames; fine for the user's own server, don't publish them.
- Reference scripts the user collected from the penablox Discord (not in this repo because they are other people's code): `kernel's lua.lua` (open source, asks for credit), `neverpeek.min.lua` (minified), `message.txt` ("Fatality.$win resolver v2"). They were useful as proof of which API calls actually work (see `aa.*`, `plist.set`, `rage.get_double_tap_charge`).
- Style: user likes short, practical replies; they iterate by pasting console output.
