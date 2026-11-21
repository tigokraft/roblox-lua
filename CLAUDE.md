# unsyk (penablox HvH Lua) — handoff notes for the next Claude session

Read this first. It is the full state of the project as of the end of the first session (2026-11-20).

## What this is
A Luau script (`unsyk.lua`) for the **penablox** cheat (a Roblox-based CS:GO clone, played **HvH**: hack vs hack, everyone is cheating by consent). The user loads it in the cheat as `test2.lua` and pastes console output back to us. There is **no way to run Lua locally** — all testing is in-game, so every claim about behaviour is unverified until the user pastes logs.

Goals the user stated: bring things to HvH (roll / desync control), understand why they keep getting one-tapped, predict enemy AA, find the best peek timing, and have live data streamed to their own server so Claude "is always aware of what's happening in game".

## Repo layout
- `unsyk.lua` — the whole script (~1700 lines, appended in sections, see below).
- `loader.lua` — what the user actually loads: fetches the latest `unsyk.lua` from the feed server and runs it.
- `server/receiver.py` — stdlib Python ingest endpoint (token-checked, size/rate-limited, writes SQLite) + token-checked `GET /config` + LAN-only script copy page. No public read endpoint for events on purpose.
- `server/Caddyfile.snippet` — Caddy block on the VPS proxying `/ingest`, `/config`, `/health` to 10.8.0.8:8787.
- `server/hvh_cloud.py` — cloud config store (one JSON per account in `/var/lib/hvh-ingest/cloud/`, share codes in `shares.json`).
- `scripts/export.sh [NAME] [24h]` — pulls CSVs (deaths/hits/shots/intel/state/ctrl/uploads) into `exports/` (gitignored).
- `server/hvhctl.py` — read/report/live-tail/remote-config CLI, installed in the CT as `/usr/local/bin/hvhctl`.
- `scripts/hvh` (run hvhctl over SSH), `scripts/deploy.sh` (push everything + restart).
- `server/hvh-ingest.service` — hardened systemd unit (reads `INGEST_TOKEN` from `/etc/hvh-ingest.env`).
- `docs/penablox-luapi.md` — the cheat's Lua API docs the user supplied (third-party docs; only the first ~1050 of 1556 lines were read closely, rest was grepped).

### Sections inside `unsyk.lua` (in file order)
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
12. Resolver (`rs_*`, placed before the feed): Off/Shadow/Active. Tracks every alive enemy with its own `new_rec` + `intel_update(..., rs_n)` (intel functions take an optional tick counter now). Side = sign(goal_feet_yaw − eye yaw); leads by ping ticks (or `rs_lead`) and switches to the predicted next side if their flip lands first; per enemy+state learns read vs inverse from resolver misses; Active applies `plist` "Force body yaw" + "Override yaw offset" only after `rs_take` built-in resolver misses on that player, hands back after 2 own misses. Every FIRE logs `rs` (own/off/src/lead/nxt/st/pat); `hvh report` has a RESOLVER section.
13. Remote control (`ctrl_*`): polls `/config`, applies allowlisted `CTRL` keys (AA + `rs_*`), restores the user's values
14. Update check: `/version` every 60s, `[UPDATE]` line

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

- **The main chunk is at Lua's 200-local limit** (`too many local variables` from `luac -p`). New sections must go inside `do ... end` (remote control and update check already are) or hang state off a table. Always run `luac -p unsyk.lua` before deploying.
- Aim events (`aim_fire/hit/miss`) give `e.target` as a number that is NOT `entity.get_player_slot(ent)`; `entity.get_player_name(e.target)` works, so `find_rec` / `rs_find` match by name.
- Menu values reset on every reload unless saved: Stream events / Remote control / Server spread now persist via `database` keys `sv_on`, `sv_ctrl`, `sv_srv`.

- **Roblox GUI input events never fire for script GUIs** (MouseButton1Click, InputBegan on frames). The window (`ui_build`, end of file) hit-tests by polling in a `paint` callback: `UIS:GetMouseLocation()` + `input.is_mouse_down(1)`. The mouse position and GUI AbsolutePosition are offset by an inconsistent inset, so the window uses a user calibration click (database `ui_cal` "x,y", "calibrate" button). Calibration not yet confirmed working by the user.
- **`aim_hit` / `aim_miss` always carry `e.id = 0`**; only `aim_fire` has a real id. `st.rs_match(e)` matches hits/misses to queued fires by name (FIFO, 3s expiry) and sets `e.fid`.
- Enemy entities are `Instance`s and change on respawn; resolver records are keyed by player name.
- `weapon.get_active(enemy)` works on enemies and returns a table: `ammo, category, id, is_grenade, is_knife, is_scoped, is_sniper, name, reserve, scope_level, slot, type` (no `is_reloading`). Whether enemy `ammo` ever changes when they shoot is unverified: the ammo-drop eshot detector produced zero events; a 30s diag (`kind="diag"`, `what="enemy shot signals (30s)"`) was added in build d5716380a6 but has not reported yet.
- `luac` here is Lua 5.5, not Luau: it catches syntax and the 200-local limit, not Luau-only errors. Installing a Luau compiler needs the user's OK.

## What the logs showed (first session)
- Nearly every death was a **single 100-damage hit** (Scout headshots), at 15–150 studs, in all states (stand/air/duck), mostly with the `Delayed` inverter and `Center` modifier, pitch `Down`. The user fired almost nothing before dying ("death (local)" misses), so offense couldn't be assessed.
- Early deaths had manual-yaw keys stuck on (toggle mode) → fixed by making Z/C/X **Hold**; desync limit randomisation lowered to 88–100% and moving/air limits default 84.
- Enemy intel: most tracked enemies run pitch **Up (−70)** ~99% of the time vs our `Down` — a lead worth A/B testing, not proof. Pretalhada13 flips side often (~91 flips, "variable 11±7t").
- `choke=0` on every row even with fake lag 10, and `dt=0/14 off` → fake lag and double tap are probably not enabled in the cheat's own menu, or the API doesn't reflect them. **Unresolved.**
- real/fake delta ≈ 2 × limit (168 at 84°), so desync itself is working as configured.

## Current state / next steps
1. **Live feed deployed 2026-11-20 (session 2), not yet tested from the game.**
   - Public: `https://feed.sites.exxo.world/ingest` (POST), `/config` (GET), both need `X-Token`; `/health`. Everything else 404. Checked with curl: health 200, no token 401, valid token 204/200.
   - Topology: Roblox → Caddy on VPS (`exxo-vps`, TLS) → WireGuard → **pve2 LXC 115 `hvh-ingest`** (Debian 13, LAN 192.168.68.34, WG 10.8.0.8). Public listener binds 10.8.0.8:8787 only. No router ports opened; the CT dials out to the VPS (keepalive 25).
   - In CT: `/opt/hvh-ingest/{receiver.py,unsyk.lua}`, `/usr/local/bin/hvhctl`, unit `hvh-ingest.service` (after `wg-quick@wg0`), `/etc/hvh-ingest.env` (INGEST_TOKEN, INGEST_HOST, LAN_*; 600). Remote config `/var/lib/hvh-ingest/config.json`. WG key `/etc/wireguard/wg0.key`.
   - The token is copied to `server/ingest.env` on the user's Mac (gitignored). Never print it or commit it.
   - **Claude's link to the game: the `/hvh` skill** (`.claude/skills/hvh/SKILL.md`). `scripts/hvh report|follow|events|sessions|config ...` runs `hvhctl` over SSH. Live mode = `scripts/hvh follow` under the Monitor tool.
   - **Remote control (session 2):** script polls `/config` every 5s when "Remote control (Claude)" is on; config is only writable over SSH (`scripts/hvh config set k=v --note ...`). Allowlist `CTRL` in the Lua = `KEYS` in `server/hvhctl.py` (keep in sync). The user's values are restored on `config clear` or toggle off. Unverified in game: `handle:set()` on comboboxes, `HttpService:JSONDecode`, GET through the cheat's proxy.
   - Events carry `my` (own weapon/scope/spread/inaccuracy), `srv` (menu "Server spread" label), `server` events with JobId; the user plays both spread and no-spread servers, so split stats by both. Events now carry `cv` (config version); shots carry `id`, `hc`, `pdmg`, `ryaw`, `bt`, `hp_left`, fire-time `intel`.
   - **Script copy page, home LAN only:** `http://192.168.68.34:8080` (second listener in receiver.py, bound to the LAN IP, never proxied, refuses clients outside 192.168.68.0/22). Serves `/opt/hvh-ingest/unsyk.lua` from disk.
   - **Loader / auto-update (session 2):** `loader.lua` is what the user loads in the cheat. It reads the token from `database.read("sv_tok")`, `http.get`s `https://feed.sites.exxo.world/script.lua` (token-gated; the server prepends `UNSYK_VERSION = "<sha256[:10]>"`), caches it in `database` key `aa_cache`, and runs it with `loadstring`. The script checks `GET /version` every 60s and prints `[UPDATE]` when the server has a newer build; it reports `ver` in state events, so `scripts/hvh follow --all` shows which build the user runs. No in-place hot swap: the cheat only cleans up on a menu reload, so updating = reload the loader.
   - Deploy everything (receiver, hvhctl, unit, script + loader): `scripts/deploy.sh`. **This is how the user gets script changes** (via the loader), so deploy after every edit to `unsyk.lua`.
   - Next: in game, paste the URL and token into the "Live server feed" textboxes, press "Send test event", check `scripts/hvh sessions`. **Unknown whether the cheat's HttpService proxy allows arbitrary domains.** If it fails, the `[FEED] post failed: ...` line says why. Then try remote control with a harmless change (e.g. `config set mod_amt=31`).
2. **choke=0 explained (user, session 2): enabling double tap disables fake lag in this cheat.** So choke=0 is expected with DT on. But `rage.get_double_tap_charge()` read 0/14 in every one of 52 snapshots, and the `on/off` text is only inferred from charge>0, so the HUD/feed DT readout is unreliable. Tested 17:54 with remote `def_shift=0` for ~65s alive: still 0/14, so the defensive burst is NOT draining it; `rage.get_double_tap_charge()` simply always returns 0 here. Treat the DT readout as broken (ignore `dt` in reports).
3. **Session 2 results:** baseline (Delayed, delay 8): ~1.27 deaths/active min, K/D 1.3, 52% of deaths 5–10t into a hold, half standing, 91% Scout one-shots; our own shots 77% hit, only 2 resolver misses in 53. A/B delay 4 (cfg v5): 1.00 deaths/min, K/D 2.2 over ~6 active min (directional). Resolver built 18:33 in Shadow by default, not yet evaluated.
3b. Idea the user liked: an **A/B tester** that cycles inverter/pitch settings per round (`round_start` is NOT in the API docs; with remote control, Claude can run A/B tests by switching configs and comparing deaths/min per `cv`) and counts deaths per setting. Also a resolver built on the enemy intel / `plist` overrides (see the user's other scripts' approach: hybrid brute-force + adaptive, learns from `aim_miss`).
4. Verify the new code actually loads: expect `[unsyk] v4 loaded` (and `v4 feed ready` at the end) in the Lua console. Earlier pastes showed the user running stale copies several times — always check that line first.
5. **Session 3 (2026-11-20 evening):**
   - In-game replacement window (tabs: Overview, Anti-aim, Defensive+Peek, Resolver, Visuals, Intel, Data, Feed, Other), crosshair indicators (ideal-yaw style arrows + DT/state lines), LAN web panel at `http://192.168.68.34:8080` (`server/panel.html`, `/api/status|live|report`, POST `/api/config` same-origin only).
   - Resolver takeover fixed (name keys + FIFO match); confirmed by an `rs=Active:OURS` kill.
   - Peek & extras: `peek_mode` (Off/Hold side/Flip then hold/Max desync hold/Randomize), `peek_len`, `rs_baim`, `anim`. **Peek "Hold side" (cfg v9) lost: 1.58 deaths/min, deaths during 7-30t static holds; reverted to v10** = `delay 4, delay_rnd 4, rs_mode Active, rs_take 1`.
   - Base-rate check: with delay 4 + rnd 4, ~50% of all ticks are 0-2t from a flip, so "deaths at the flip" (59%) is mostly chance.
   - Open offers the user has not answered: Peek "Randomize" as v11; a min-damage setting (wasted 2-8 dmg wallbangs).
   - `loader.lua` v2: loading card (download/compile/start), 3 download retries, falls back to the `aa_cache` copy, shows errors on screen and as `[loader]` lines. The user reported "loader not working" on build d5716380a6 (last confirmed build in game: 657102043e); cause unknown until they paste the `[loader]` line.
   - **License keys (session 3):** `server/hvh_auth.py` (deployed to `/opt/hvh-ingest/`). Keys `DAA-XXXXX-XXXXX-XXXXX-XXXXX`, only sha256 stored in `/var/lib/hvh-ingest/keys.json`; first login locks a key to the Roblox UserId. `POST /auth` -> 12h HMAC session; every X-Token endpoint also accepts `X-Session`; ingest events from a session get `lic=<key name>`. 8 wrong keys per IP per 10 min -> 429. Manage with `hvhctl license [add NAME --days N|revoke|enable|reset|extend|delete]`; **the user runs `license add` themselves** (the key is printed once, Claude should not see it). Loader v3: cheat-menu tab "unsyk login" (Key box, Log in, Log out), saves `aa_key`/`aa_sess`, exposes `UNSYK_AUTH.headers()`; the script's `st.auth(tok)` prefers the session, falls back to the master token box. Needs `/auth` in the VPS Caddy matcher (snippet updated in repo).
   - Window opening animation: `open_anim` in `ui_build` (UIScale pop + loading veil, clicks ignored ~0.75s).
   - **Friends / multi-user (session 3):** each friend gets their own license key; `hvhctl license add NAME --days N` prints the key AND a ready-to-send invite (you forward it + `loader.lua`, which has no secrets). Friend events are tagged `lic=<key name>` server-side. `scripts/hvh friends` = per-person deaths/K-D/hit%/last-seen; `scripts/hvh sessions` and live `follow` show who; `scripts/hvh report --lic NAME --since 2h` = one friend's report. Your own data (master token) shows as "owner".
   - **Obfuscation (session 3):** repo keeps `unsyk.lua` readable; the SERVED copy is minified + locals renamed by **darklua** (`cargo install darklua`, config `.darklua.json`, `scripts/obfuscate.sh`). darklua renames LOCALS only, so API globals and `UNSYK_AUTH/VERSION` survive (obfuscate.sh asserts this + that it parses + got smaller, ~63%). `scripts/deploy.sh` obfuscates by default; **`scripts/deploy.sh --raw` ships the readable copy — the instant fallback if the obfuscated build ever breaks in game.** Every served copy is also watermarked with the downloader's key (`UNSYK_LICENSE`), so a leaked file names the leaker -> `hvhctl license revoke`. First obfuscated build c8f177d666 deployed 2026-11-20, NOT yet verified in game.

6. **Session 4 (2026-11-20 night): window v5, cloud configs, login card, log export. NOT yet tested in game.**
   - Window restyled (user's reference: a modern rounded cheat menu): frosted dark panel (corner 9), centered mark + name
     title bar (license left, K/D + feed right), sidebar tabs with a diamond icon and an accent bar on the sidebar edge,
     two columns of sections = bold header + one rounded row per setting (pill switch, value + chevron dropdown overlay
     `pop`, knob slider with value top-right, key box, input field). Gotham fonts. Accent presets (database `ui_acc`,
     also read by the loader). Background blur via a Lighting BlurEffect while open (Settings > Menu, database `ui_blur`).
     Fake loading veil, green mouse dot and Overview page removed.
     Labels shortened (all renamed; cloud config keys are "Section/Item label", so renaming a label orphans that key).
   - **Mouse auto calibration:** offset = -(viewport - ScreenGui.AbsoluteSize) (the inset the GUI really has); empty
     clicks retry with 0/±36/±58/±inset and adopt one after 3 identical wins ("learned"); manual cross in Settings.
     Saved as database `ui_cal2` "x,y,how" (old `ui_cal` ignored). One `[MENU] mouse ...` diagnostic line 1s after load.
   - Clean defaults: world arrows, view arrow, hit list overlay, intel overlay, peek advisor overlay, fake chams and the
     crosshair title are OFF; the old always-on red debug HUD line is gone. Crosshair "Debug" toggle: yaw dial (grey
     tick = camera, green R = real, red F = fake, relative to camera; mirrors with Arrows > Mirror) + 4 readout lines.
   - Cloud configs: `GET /cloud`, `GET /cloud?name=`, `GET /cloud?code=` (share code, any logged-in user),
     `POST /cloud {op: save|delete}`; `GET /me` (license name, days left). Per account = license name / "owner".
     Max 20 configs, 32 KB. `hvhctl cloud` lists all. **Needs `/me /cloud` in the VPS Caddy matcher** (snippet updated).
   - Log export: `hvhctl export --kind ... [--lic] [--since]` (flat CSV, nested -> a.b columns, intel one row per player),
     `scripts/export.sh`, LAN panel Report tab "Export data". In game, Settings > Logs > "Upload logs" posts every
     buffered hit with its full tick timeline (`hit_full`) + counters (`shotlog`) -> `--kind uploads`.
   - Loader v4: login card with the key box auto-focused (paste + Enter, or click "log in"; leaving the box with a full
     key also submits), turns into the progress card. Cheat tab "unsyk login" still works as fallback.
     `aa_sess` now "sess|exp|name|days" (old 3-field format still parses).

## Safety / conventions
- **Never hardcode the Discord webhook URL or the ingest token** in any file. They live in menu textboxes and the cheat's `database`. The user's webhook was pasted only into the menu.
- Server work touches the user's VPS: confirm each step with them first (config changes, reloads, installs). Do not ask them to paste keys/passwords in chat; use the app's saved SSH connection.
- Logs contain other players' usernames; fine for the user's own server, don't publish them.
- Reference scripts the user collected from the penablox Discord (not in this repo because they are other people's code): `kernel's lua.lua` (open source, asks for credit), `neverpeek.min.lua` (minified), `message.txt` ("Fatality.$win resolver v2"). They were useful as proof of which API calls actually work (see `aa.*`, `plist.set`, `rage.get_double_tap_charge`).
- Style: user likes short, practical replies; they iterate by pasting console output.

7. **Session 5 (2026-11-20): one cheat tab only.** The "Desync AA" cheat tab is gone: `tab` in `unsyk.lua` now makes
   script-side handles (get/set; keybinds poll `input.is_key_down`, Hold/Toggle/Always, ignored while a textbox is
   focused), so settings live only in the custom window. The loader's "unsyk login" tab is the only cheat tab; the
   script adds a "Menu" section to it via `UNSYK_AUTH.tab` (Open/close window, Calibrate mouse by hand). Raw
   script without the loader makes a small "unsyk" tab for those buttons. Loader v5: the tab is built after the
   saved-session check and the status label is created with the right text (label `:set()` likely does nothing,
   which caused "not logged in" while logged in); a change adds a new label and hides the old one. NOT tested in game.

8. **Session 6 (2026-11-20): ideas ported from the public "phobia beta" script (gghgdw5/phobia on GitHub; read only,
   reimplemented, no code copied). Deployed, NOT tested in game.**
   - **Dodge AA** (section "Dodge", Defense page; `st.dodge`, called first in the main AA tick, replaces regular +
     defensive while active, skipped while a manual key is held). While threatened (ragebot target, or an enemy within
     `dodge_range`) re-rolls side / desync size (`dodge_min..max`, asymmetric L/R +-6) / yaw offset / optional pitch
     every `dodge_rate` ms; every `dodge_swing` ms a ~4-tick swing (84 both sides, yaw +-84, pitch +-89,
     `rage.force_shift(dodge_shift)` unconditionally); own hp drop -> reroll + swing. Phase shows as `dodge`.
     **Default Off** -> A/B it with `config set dodge="On threat"`.
   - **Candidate resolver** (`st.rsx`, toggle "Candidates" = `rs_multi`, default ON, only matters with rs_mode Active/
     Shadow): 12 offsets (read, inv, lby, lby+-desync, lby+twist, jitter mean, jitter opposite, +-58, +-84), priors +
     per-enemy per-state scores (own hit +2, own resolver miss -3 and that offset blocked 4s), decay x0.85/2s, wiped on
     AA-signature change, legit-looking players skipped. Shot `rs.src` is now the candidate name. Hand-back after 3 own
     misses (was 2). `rs_multi=false` = the old read/inverse logic. Also `rs_pitch` (plist "Force pitch"/"Force pitch
     value" to their usual pitch when they flick) and `rs_fd` (plist "Override safe point"="Force" on fake duck).
     intel recs now carry `lby`, `dd`, `tw`, `hp`, yaw ring/`yref`/`yjit`, pitch ring `ph`, `fd_until`.
   - **Rage tweaks** (section "Rage", Resolver page): `hc_air`, `hc_noscope`, `hc_duck`, `mindmg` floor, `lethal`; all 0/off
     by default. Re-sent every tick while applying; released with `override_x(nil)` (falls back to the saved menu value).
   - Keybinds also ignore keys while `input.is_typing()` (Roblox chat).
   - New CTRL keys (Lua `CTRL` = `KEYS` in hvhctl.py, 58 keys): dodge, dodge_rate/min/max/asym/yaw/pitch/swing/shift/
     range/hit, rs_multi, rs_pitch, rs_fd, hc_air, hc_noscope, hc_duck, mindmg, lethal.
   - Found while reading: our **defensive burst only shifts ticks when `dt_state().charged`**, and the DT charge read is
     always 0, so `def_shift` has probably never fired. Not changed (would move the baseline); worth an A/B.
   - phobia's "Roll exploit" is only a yaw spin + inverter flip: still no roll setter.

9. **Loader v6 (2026-11-20): login only in the cheat tab.** The login card/window is gone. Without a session the
   loader waits for the "unsyk login" tab (Key box + Log in; a full pasted key also submits itself, once per
   value) and says what to do in a `[loader]` line and the tab label. The small progress card (download/compile/
   start) appears only after login. NOT tested in game.

9. **Session 6b (2026-11-20): renamed everything to "unsyk".** Script file `unsyk.lua` (served copy
   `/opt/hvh-ingest/unsyk.lua`, build `build/unsyk.min.lua`), globals `UNSYK_AUTH / UNSYK_VERSION / UNSYK_LICENSE`, window
   title, cheat tab "unsyk login", console prefixes `[unsyk]`, copy page, panel, unit description. Kept on purpose:
   database keys (`aa_cache`, `aa_key`, `aa_sess`, `sv_*`, `ui_*`) so nobody is logged out or loses settings, license
   key format `DAA-...` and the session HMAC label so existing keys/sessions stay valid, service/CLI names
   (`hvh-ingest`, `hvhctl`, `/hvh`). Compat: the top of `unsyk.lua` maps `DESYNC_AA_AUTH/VERSION` from loaders pasted
   before the rename (their download check looks for the string `DESYNC_AA_VERSION`); remove once friends reloaded.
   Also fixed: darklua turns non-ASCII into `\u{b0}` escapes the cheat's Lua prints literally -> `obfuscate.sh` rewrites
   them as decimal byte escapes and fails if any remain. Window columns are now pixel-sized (16px sides, 12px gap).

10. **Session 6c (2026-11-20): loader card, crosshair peek bar, HUD + effects. Deployed, NOT tested in game.**
   - Loader v7: the progress card uses the window's look (C palette, Gotham, corner 9 + UIStroke, accent diamond +
     "unsyk", rounded accent pill bar, pops in with UIScale). It is the only loading screen.
   - Crosshair "Peek advice" (default on): a bar between the < > arrows coloured by the peek advisor verdict
     (green good / amber ok / red wait) that shrinks as the nearest enemy's next flip nears (full = >= 2x the ticks our
     shot needs), plus a "PEEK 12t name" line under the crosshair. `st.peek_now()` / `st.peek_verdict()` in the peek
     advisor section. Fix: GOOD needed score 2, unreachable with the view-angle check off (max 1) -> now relative.
     Crosshair state word shows DODGE for the dodge phase.
   - HUD + Effects (Visuals page, `;(function() ... end)()` block before the live feed, own ScreenGui `unsyk_hud`):
     watermark (top right: name, ping, fps), keybind list (left, active binds only; no remote-control row, the feed is hidden), target panel (rage target hp bar,
     distance, weapon, state, resolver src/offset), hit log toasts (top left, 4.5s), damage numbers by the crosshair,
     hit/kill sounds via `sounds.override_hitsound/killsound` presets, kill effect (Shockwave/Ascend/Pillar) and hit effect
     (Ring/Spark) via **`render3d.ring/line`** (documented in docs section 15, immediate mode per paint, transparency
     0 = opaque). The window's accent is shared through `st.accent` (+ `st.ch_col.acc`).
   - **Lua local limit:** locals inside a `do ... end` block still count toward the main chunk's 200. Big new
     sections must be wrapped in `;(function() ... end)()`.
   - **Feed hidden in game (session 6d):** the "Live server feed" section is no longer in the window (marked placed, so it
     does not fall onto a Misc page); the title bar shows feed / cfg status only for the owner (`st.sv_owner`), and every
     `[FEED]` / `[CTRL]` / `[REMOTE]` console line goes through `st.flog` (owner only). The feed itself is unchanged:
     URL defaults to feed.sites.exxo.world, token/session from database / loader, Stream locked on for license users,
     remote control auto-on for them. Stream / Spread / Remote control toggles are only reachable through `database`
     keys (`sv_on`, `sv_srv`, `sv_ctrl`) now. Settings > Logs ("Upload logs") is hidden too (`g_log.Visible = false`).

11. **Session 7 (2026-11-20 late): admin panel v2, secure login, subscription enforcement. Deployed 23:39, NOT tested in game.**
   - **Admin panel is HOME LAN ONLY (user's rule: never reachable from the internet):** `http://192.168.68.34:8080/admin`
     (LanHandler in receiver.py: client IP in LAN_ALLOW + Host must be the LAN address; public listener 404s /admin*;
     never add /admin to Caddy). Files `server/admin/{index.html,app.js,app.css}` -> `/opt/hvh-ingest/admin/`. Strict CSP
     (no inline JS/styles: widths set via CSSOM), X-Panel + same-origin Origin on every POST. The old panel.html and
     /copy page are gone. Look dealt by the taste-skill (look only, no marketing gate): palette cool-grey-cobalt,
     Gabarito/Figtree + DM Mono, radius sharp, dark sidebar, light/dark themes.
   - Pages: Live overrides (staged edits + Push dock; null edit = give back), Official presets (editor, order, JSON),
     Player configs (every account's cloud configs, compare with a preset, publish as official, delete), Licenses (new key
     shown once + invite text, +7/+30 days, set expiry, end session, unbind, revoke/enable, delete), Live, Stats and
     export, Script and downloads (served-copies log for leak tracing).
   - **Admin login** (`server/hvh_admin.py`): user + scrypt password + TOTP (RFC 6238, codes single-use), 5 fails/IP/15 min,
     30 total/15 min, in-memory sessions (30 min idle, 12 h max; polling stops while the tab is hidden). Credentials in
     `/var/lib/hvh-ingest/admin.json`, written only by **`hvhctl admin setup` (the user runs it; needs a TTY:
     `ssh -t pve2-claude pct exec 115 -- /usr/local/bin/hvhctl admin setup`)**. Cookie is not Secure (LAN is plain http).
   - **Subscriptions:** sessions are now `s2.<kid>.<uid>.<gen>.<exp>.<sig>`; every login bumps the key's `gen`, so a key
     works on ONE device at a time (old s1 sessions are refused, loaders log in again). revoke/reset/kick bump gen too.
     `/script.lua` stamps `UNSYK_LICENSE/UID/SUB_END/DL` and logs every copy in the `downloads` table (30/hour/key).
     Script guard (top of unsyk.lua wraps `client.set_event_callback` via a local `client` shadow; `UNSYK_STOP(why)` runs
     every shutdown handler + aa.reset + rage overrides nil): stops on 2x 401/403 from the heartbeat, on sub end, on a
     UserId that is not `UNSYK_UID`, or after 30 min with no answer. Heartbeat = `GET /beat` on the pinned host,
     **falls back to `/version` while Caddy 404s /beat** (the auto-mode classifier blocked editing the VPS Caddyfile;
     the snippet in the repo already lists /beat, the user has to apply it). Loader v8: keeps `sub_end`, uses the cached
     copy only when the server is unreachable or sent a build that does not compile, and wipes it on a refused key.
   - Official presets: `GET /cloud` adds `official`, `GET /cloud?preset=NAME`; in game they show first, marked "official",
     load-only. Stored in `cloud/official.json` (max 12).
   - Incident: another session's deploy at 23:10 shipped this work half-done (receiver without hvh_admin.py -> crash loop,
     then a script whose /beat was 404 -> would stop itself after 30 min). Fixed by the 23:39 deploy (fallback).

12. **Session 8 (2026-11-21): No-spread mode, own Quick stop, "Hitchance moving". v2 NOT deployed / NOT tested.**
   - **The cheat's menu is unreachable from Lua:** build 90b70b21ad probed 196 auto stop names with `ui.reference` plus
     the "Double tap" ref: nothing (`diag what="ns probe"`). No auto stop API exists either -> the cheat's auto stop can
     only be switched by hand. The first "Auto stop off" toggle did nothing and is gone.
   - **The cheat's DT works:** Deagle `aim_fire`s arrive in pairs (same pdmg, same tick) although
     `get_double_tap_charge` reads 0. Our "DT follow-up" force_shift was redundant and is gone.
   - `e.hitchance` in aim_fire is 0 on ~half of all fires (even scoped Scout) -> useless. Fires now log
     `ov = {hc, md, rhc, rmd}` (what we override vs `rage.get_hitchance/get_min_damage` read back) to see if overrides stick.
   - v1 fired 2-4 dmg Deagle shots in no-spread mode: "lethal" only LOWERS min dmg to the target's hp, never raises.
     v2 No spread section (Resolver page, right): switch + Toggle key N (XOR), Hitchance (1), Min damage (0 = lethal:
     target hp, `ceil(hp/2)` with a DT weapon when "Half hp with DT weapon"; SSG/AWP count as single-shot), No baim after
     misses. `st.ns.hc / st.ns.md` override everything in Rage tweaks.
   - **Quick stop** (own section, Resolver page left; `st.qs`): our own auto stop while the ragebot has a target, on the
     ground, not knife/grenade (or snipers only), never in no-spread mode. Methods: Velocity (cap root
     AssemblyLinearVelocity in RunService.Stepped + tick), Move (`Humanoid:Move` bound at RenderPriority.Input+5),
     WalkSpeed (scaled, restored only if unchanged). "Auto" self-tests: speed must halve within 4 ticks, a method with
     0 wins in 3 tries is dropped (`[QS]` line + `diag what="qs method"`). Keep speed %, Max hold, Rest after shot
     (released 0.12s after a fire for the DT pair). `diag what="qs rig"` describes the character once (Humanoid,
     root children, PlayerScripts): read it first to see which method can work in this game. The cheat's own auto stop
     must be OFF while testing (else the self-test is confounded). Default Off.
   - Every fire logs `qs = {spd (our speed at fire), ttf (ticks target seen -> fire), m, kept}`, also with Quick stop
     Off: measures the cheat's own auto stop (spd ~0 at fire in no-spread mode = it still brakes).
   - Rage section: "Hitchance moving" (`hc_move`). Events carry `ns=true` while active and "Unknown" srv becomes
     "No spread". `st.push = sv_push` for sections above the feed.
   - CTRL keys (Lua `CTRL` = `KEYS` in hvhctl.py = labels in admin app.js, 69 keys): hc_move, ns, ns_hc, ns_md,
     ns_half, ns_baim, qs, qs_how, qs_keep, qs_hold, qs_rest.

13. **Session 9 (2026-11-21): mouse calibration rework. Deployed as build 43b43b0c16 (with the session 8 No-spread work), NOT tested in game.**
   - Pointer source picked once like phobia: UIS:GetMouseLocation (screen space = our IgnoreGuiInset ScreenGui), else
     `input.get_mouse_position` + GuiService inset. Mapping: gui = raw * scale + auto + rel. `auto` (screen size - gui
     size) is re-measured every 0.5s while the window is open; only `rel` + scale are saved, in database `ui_cal3`
     "rx,ry,sx,sy,how" (old absolute `ui_cal2` manual/learned is converted once). So a reload / window resize keeps
     the calibration instead of going stale.
   - Hand calibration = two crosses (top left, bottom right) -> solves offset AND scale (DPI: one fixed offset is right
     at the cross and a row off near the edges). Scale snaps to 1 within 4%.
   - The calibration prompt now shows only on a first run (nothing saved), not on every load. "Auto calibrate" saves
     auto (rel 0, scale 1). Console `[MENU] mouse ...` line now prints src / auto / rel / scale.

14. **Session 9b (2026-11-21): enemy teleport detector + DT peek. Deployed as build 6acbc60d5c, NOT tested in game.**
   - Data that led here (96h feed): Deagle DT fires a pair ~5ms apart (75% of Deagle shots); Scout DT = teleport only.
     The user says many deaths are enemies **teleport-peeking** (DT shift out of cover, shot in the same tick), which
     nothing can react to after the fact. 23% of deaths came <0.3s after our own shot (mostly 1 tick later).
   - `get_double_tap_charge` is still always 0; `ui.reference` reaches nothing, so the cheat's own DT can't be toggled.
   - **Enemy teleports** (section "Enemy teleports", Defense page; `;(function()` block before REMOTE CONTROL):
     per-enemy 0.3s position ring; movement over the last >=0.15s beyond `Run speed` (30 st/s) x time and >= `Min jump`
     (2.5 st) = teleport; > 40 st = respawn. Events `kind="etp"` (jump, spd, dist, wep, rech, hit within -0.25..+0.35s),
     hits carry `tp` (latest teleport <= 0.5s before), enemies on hits and FIRE carry `tpa` (ms since their last
     teleport). `st.tp_age/tp_ready/tp_recent`. Diag `what="enemy speed (2min)"` = speed/excess percentiles to tune the
     thresholds (Roblox may smooth replicated movement: unverified that a shift shows as a jump). Console `[TP]` line
     on a hit after a teleport. `hvhctl report` has an ENEMY TELEPORTS section, `follow` prints ETP lines, export --kind etp.
   - **DT peek** (section "DT peek", Resolver page; idea from phobia): toggle + Hold key (default LeftAlt). While held,
     min damage = ceil(target hp / 2) (50 without a target) or "Damage", hitchance = "Hitchance" (35). Rage tweaks
     gives it priority over everything (`st.dtp`). Shots log `dtp=true`; keybind list shows it.
   - Not done yet: resolver counting a DT pair as one result (phobia's "series tracking"), Dodge's force_shift
     spending the charge, counters built on `tp_ready` (peek advisor / threat-gated dodge).
   - **Key rebinding (session 9c, deployed as build 48919a216a, NOT tested in game):** every keybind row in the window is now clickable: click the key box
     ("press..."), press a key or Mouse 2/3; Esc cancels, Backspace/Delete = no key, a click elsewhere or 8s = give up.
     Saved per key as database `kb:<section>/<name>` ("None" = unbound), loaded when the keybind is created.
     Key handles keep the key on `h.key`; `tab.keydown(name)` also reads "MouseButtonN". DT peek has ONE key
     (default LeftAlt), picked by rebinding it (the user did not want a second slot; removed in build 6310ea55bf, deployed).
   - **Crosshair self-report (build 0b5e98bc3b, deployed):** the user reported the crosshair arrows stopped showing
     (no crosshair code had changed). The crosshair paint now runs in pcall and reports once per reason why it is
     hidden ("Indicators off", "AA disabled", "is_alive failed", "no viewport"), "drawn" once when it draws, or its
     error (every 10s max): console `[CH] crosshair ...` + feed `kind="diag" what="crosshair"`. Read with
     `scripts/hvh events --kind diag`. Cause NOT found yet.
   - **Crosshair cause found (session 9d, deployed as build 140a2a3867, NOT tested in game):** `[CH] crosshair hidden: Indicators off` 5s after load, and
     no code sets it -> a click did. The window opens on load and the press that loaded the script (cheat menu) was
     taken as a click in it. Fix: `set_open` sets `cal.hold`; the click loop ignores input until the mouse is up and
     0.25s passed.
   - **Real mouse offset found:** `[MENU] mouse` showed `screen 1512x949 gui 1512x949 at 0,-58 | inset 0,58`: this
     cheat's IgnoreGuiInset ScreenGui sits AT y=-58 with full size, so the old size-based auto gave 0 (hence "always
     needs calibrating"). auto = gui.AbsolutePosition - (screen - gui size) now. Saved as `ui_cal4`; `ui_cal3` manual/
     learned values are converted (rel - gui position), ui_cal3 "auto" resets to rel 0. No first-run calibration
     prompt any more (click learning + "Calibrate by hand" remain).

15. **Session 10 (2026-11-21): admin panel on Tailscale (user's choice: own node, not `tailscale serve` on pve2).**
   - CT 115 got `/dev/net/tun` (two `lxc.*` lines in `/etc/pve/lxc/115.conf`, backup in pve2 `/root/115.conf.bak-*`) and
     Tailscale from pkgs.tailscale.com, logged in as **hvh-admin** (`--accept-dns=false`), IP 100.114.136.70.
   - Panel: `http://hvh-admin:8080/admin` (also the full MagicDNS name or the IP). Still never the internet: Caddy has no
     /admin, the public listener 404s it. receiver.py `admin_listener()` runs one LanHandler per listener with its own
     allow nets / Host names / Origins; env `TS_HOST`, `TS_NAMES`, `TS_ALLOW` (default 100.64.0.0/10 = whole tailnet,
     tagged devices included unless ACLs block them). The tailnet bind retries every 10s until tailscaled has the IP.

16. **Session 11 (2026-11-21): beta channel + numbered builds. NOT deployed, NOT tested in game.**
   - **The user's own game account is the license `tigokraft`, NOT `owner`.** `owner` = the master token only. So
     the user's events are tagged `lic=tigokraft`: use `--lic tigokraft` / `--acct tigokraft` for their reports and
     A/B tests, and put them on the beta with `scripts/hvh beta add tigokraft` (do this right after the first deploy).
   - **Test risky script changes on the beta, not on everyone** (friends use the script now):
     `scripts/deploy.sh --beta --note "what changed"` -> the user tests -> `scripts/hvh release promote`.
   - `server/hvh_release.py`: every deploy is build #N; bytes kept as `/var/lib/hvh-ingest/releases/<ver>.lua` (newest
     30 + live ones), state in `releases/channels.json` (stable, beta, beta_members, history). Beta members (license
     names, "owner" = master token) get the beta build while one exists, else stable. Before the first publish the
     legacy `/opt/hvh-ingest/unsyk.lua` is served as stable build 0.
   - `/script.lua`, `/version`, `/beat` are per account; served copies are stamped `UNSYK_BUILD` + `UNSYK_CHANNEL`;
     `/beat` adds `build`/`ch`; `/me` adds `channel`; downloads table got `ch`/`build` columns (auto-migrated).
   - Deploy: `scripts/deploy.sh --beta --note "..."` = beta only (stable and the legacy file untouched);
     plain deploy = stable (beta follows stable unless it is ahead). Server code is shared and always goes live.
   - CLI: `scripts/hvh release [publish|promote|rollback stable|beta N|end-beta]`, `scripts/hvh beta [add|remove NAME]`.
     A stable rollback also moves beta if beta was just following stable. Deleting a license drops it from the beta.
   - Admin panel: Script page = channels, Promote / End beta, members, build history with Make stable / Make beta;
     Licenses page = beta tag + Add to / Remove from beta. POST `/admin/api/releases {op: promote|end_beta|point}`,
     `/admin/api/licenses {op: beta_on|beta_off}`. Checked on a local test instance only.
   - In game: `UNSYK_TAG` ("beta #14" / "#13" / "local") in Settings > Build, the loaded line, `[UPDATE]` (names the
     build waiting for you); watermark shows "beta"; state events carry `build`/`ch`; loader card shows the build.
   - Players switch channel on their next loader start; adding/removing someone makes their script print `[UPDATE]`.
   - Before the first deploy another session (UI reorganization, every feature off by default) asked to deploy; told it
     a deploy also ships this release system and that `--beta` is the safer option. Check `scripts/hvh release` to see
     what actually went out.

17. **Session 12 (2026-11-21): teleport detector v2 (beta #3, NOT tested in game) + flick A/B.**
   - v1 counted movement beyond a fixed 30 st/s over 0.15s (4.5 st allowance), so a shift from standing never
     registered; its ~120 "teleports" per 17 min were fast strafers (45-65 st/s; enemy spd99 ~40, max ~76).
     v2: burst over 0.1s vs their own PATH speed over the 0.2s before. Hits carry `tpx` per enemy (biggest burst in
     the last 0.5s, even below threshold); report prints "burst before death". Diag adds per-tick step stats
     (`zero` % = how bursty replication is). Enemy rigs are anchored Parts moved by the game's ClientEngine, so a
     shift may be interpolated on our side: if `tpx` stays small on deaths the user calls teleports, that is why.
   - Data 10:00-10:17 (no-spread, flick on): flick on ~8.5 alive-min 1.29 deaths/min vs off 4.4 min 2.04 (directional).
     Flick fired only ~36% of its cadence ticks (`fk.nc` > `fk.n`): fake lag rarely chokes with DT on.
     Air = 57% of time / 50% of deaths (not over-represented); stand 33% / 45%.
   - A flick off/on A/B (`--acct tigokraft`, cfg v11+) was started, then stopped early at the user's request
     (another session leads testing now); flick override removed.

18. **Session 13 (2026-11-21): admin panel v3 (Testing | Players) + script error reporting. NOT deployed, NOT tested in game.**
   - Panel split into two workspaces (switch at the top of the sidebar, routes `#t/...` / `#p/...`; old hashes redirect).
     **Testing**: Compare (rows by config version or build: alive min, deaths/min with a 95% Poisson range bar,
     verdict vs a clickable baseline only when |z| >= 1.96, K/D, hit %, one-shot %; "too little data" under 10 deaths
     or 5 min), Builds (stable/beta cards with health metrics, promote/end beta, testers, grouped script errors, health
     per build, history, loader line), Sessions (list -> `#t/session/<id>` = old Stats page per session), Live, Overrides.
     Testing scope = filter bar under the header: accounts (default = beta members), range, server kind; saved in
     localStorage `tfilter`. **Players**: roster (online, license, current game, range stats, ••• license menu),
     profile `#p/player/<name>` (license actions as buttons, now-in-game card, daily activity, weapons, likely killers,
     by server, sessions, cloud configs, downloads, errors), Player configs, Official presets, Served copies.
     The old Licenses / Stats / Script pages are gone (merged in).
   - Server: `server/hvh_panel.py` (read-only aggregates, deployed by deploy.sh) behind `/admin/api/compare|health|
     sessions|players|player`. Alive minutes = state snapshots x 5 s; deaths/shots get their build through the session.
     Hit % is capped at 100 (hits without a matching fire exist).
   - Script: every callback now runs in pcall through the guard at the top. Errors are counted per callback + message
     in `UNSYK_ERRS` (max 40), printed at most every 3 s, sent as `kind="err"` every 20 s; `kind="load"` once per run
     (with `prev_stop` from database `aa_stop`), `kind="stop"` from `UNSYK_STOP_HOOK`. **Tick listeners now use
     `client.on_tick(fn)`** (the shadow, wraps `events.on_tick`): before this, UNSYK_STOP never stopped the 19 tick
     listeners, so a stopped script kept running its AA ticks. No `local events` shadow: the main chunk is at 200 locals.
   - Tested on a local instance (copy of the live DB, throwaway admin login, ports 8917/8918) incl. fake err/load/stop
     events. Ship with `scripts/deploy.sh --beta --note "..."` (the script part should go to the beta first).
   - **Built-in presets (beta #10):** the in-game "unsyk preset" lives in `cfg.builtin` inside unsyk.lua, not on the
     server. deploy.sh now runs `scripts/extract_builtin.py` (fails on an unexpected line in the block) and ships
     `/opt/hvh-ingest/builtin_presets.json`; `GET /admin/api/presets` returns it as `builtin`. Official presets page
     lists them as "script only" / "synced"; opening a script-only one = a prefilled draft, Publish puts it on the
     server. In game (from #10) an official preset with a built-in's name replaces the built-in in the list; the
     built-in copy is only the offline fallback. Older builds show both.

17. **Session 12 (2026-11-21): DRM hardening — authenticated heartbeat + abuse detection. Deployed as BETA build
    #11 ce02a05f1e, NOT yet tested in game.**
    - Reality baseline (told the user): the script runs in a Lua VM the attacker controls, so no client check is
      unbreakable (they can dump the loadstring'd source, fake `http.get` 200s, stub `UNSYK_STOP`, spoof the UserId).
      Goal = raise cost, make bypass server-detectable, keep leaks traceable. Built two of the high-value pieces.
    - **Authenticated /beat heartbeat (server can't be fooled by a fake 200):** `hvh_auth.beat_token(token, acct)` =
      rolling per-account HMAC (5-min window, keyed off INGEST_TOKEN, no new secret). `/beat` returns it as `bt`;
      the client stores it (`st.lic_bt`, sets `st.lic_authed`) and echoes it in every feed batch (`beat` field);
      `/ingest` verifies the echo against the current + previous window and stamps `ev["beat_ok"]` on every license
      event (owner/master-token events are trusted, not stamped). A stubbed or replayed 200 can't produce `bt`.
    - **Client soft-degrade (DEFAULT OFF, database key `lic_enf`):** in the resolver Active apply (the `plist.set`
      "Override yaw offset" at ~line 2060), a copy that has `lic_enf` on AND has never seen a valid beat after 240s
      gets +13° on the resolver offset -> it aims worse at enemies without a visible "stopped" line. A real session
      sets `st.lic_authed` within ~60s, so it's always a no-op for a subscriber. Enemy-facing only — never touches the
      user's own desync/survival. Ships inert; enable per-user with `scripts/hvh config set lic_enf=... ` is NOT wired
      (it's a `database` key, not a CTRL key on purpose — don't make enforcement remote-toggleable). Flip it in game
      via the database, and only AFTER confirming beats echo (see below). Not added to the window UI.
    - **`hvhctl abuse` / `scripts/hvh abuse [--since 24h]`:** per key — distinct Roblox accounts, download IPs,
      sessions, event count, no-beat %, max build, last seen. Flags **SHARED** (>1 Roblox account), many download IPs
      (>2), and **TAMPERED** (on a build >= `HEARTBEAT_BUILD`=11, >50% of >=20 events miss a valid heartbeat).
      Advisory only — prints `hvhctl license revoke <name>`; NO auto-revoke (destructive + user runs license ops).
    - **IMPORTANT rollout caveat:** `beat_ok=False` just means "client didn't echo a valid token," which is true for
      EVERY client on a pre-#11 build (they can't echo). So TAMPERED is gated on the event's `build` >= 11 (state
      events carry `build`); pre-#11 keys show `no-beat=old` and are never flagged. TAMPERED only becomes meaningful
      once the fleet is on #11+ AND the owner's VPS Caddy actually serves `/beat` — if Caddy still 404s /beat, the
      client falls back to `/version` (no `bt`), so even a legit #11 client would read as no-beat and `lic_enf` would
      false-positive. That's why `lic_enf` is default off: confirm `scripts/hvh abuse` shows `tigokraft` at
      `no-beat` near 0% on #11 before enabling it anywhere.
    - Files: `server/hvh_auth.py` (+beat_token), `server/receiver.py` (+hmac import, /beat bt, /ingest verify+stamp),
      `server/hvhctl.py` (+cmd_abuse, HEARTBEAT_BUILD), `unsyk.lua` (heartbeat capture, feed echo, resolver gate).
      hvhctl.py was pushed to the CT directly after the deploy (build-gate fix) without bumping the build number.
    - Not done / next: resolver-offset trim that's cryptographically un-stubbable (needs the server to bake a
      per-build secret into the served source — heavier); string-constant encryption + aliasing API globals to locals
      in the obfuscate pass (darklua leaves globals readable); auto-revoke policy if the user wants it.

18. **Session 14 (2026-11-21): obfuscator switched darklua -> Prometheus. Deployed as BETA build #13 18c4a433df, NOT tested in game.**
    - Trigger: user asked to use https://obfuscator-eight.vercel.app ("Luvyn Studio"). It is just a browser wrapper
      around **Prometheus** (levno-710) running client-side in a WASM worker; `/api/obfuscate` 404s, so no server API.
      Prometheus is open source and runs locally under `luajit` (installed) — the website itself is not used.
    - **The VM presets are unusable here.** Full "Medium" (Vmify + EncryptStrings + AntiTamper + ConstantArray +
      Cff + NumbersToExpressions) turns the 312 KB script into **29 MB** (9364%, ~3 min). The loader streams the
      script over the cheat's HttpService proxy and loadstring's it; 29 MB cannot download or compile in game. The VM
      is off the table for a script this size. (User picked "Full Medium" first; shown the 29 MB number, chose the
      refactor + light path.)
    - **Light config shipped** (`scripts/prometheus.config.lua`): `EncryptStrings` + `ConstantArray` (StringsOnly,
      Shuffle, Rotate) + `WrapInFunction`, NO Vmify/Cff/AntiTamper/NumbersToExpressions. Output ~160% of source
      (~500 KB), pure ASCII (EncryptStrings encodes bytes, so the darklua `\u{b0}` problem is gone), ~1 s build.
      Renames LOCALS + encrypts STRING LITERALS only, so API globals (entity/rage/aa/plist/weapon/UNSYK_* ...) survive
      as identifiers and resolve in the sandbox. Every menu label / method-name string is now encrypted (unreadable).
    - **200-local limit was the blocker.** Every Prometheus pipeline needs `WrapInFunction` to hoist its decoder, which
      puts the whole program in one function — but unsyk.lua's main chunk sat exactly at Lua's 200-local ceiling, so the
      wrapped output would not even parse (`WrapInFunction` alone overflowed). Fix: wrapped two self-contained
      top-level sections in `;(function() ... end)()` to free ~29 locals of headroom — the old **dbg_\*** hit-logger
      (~917-1090) and the dead **dc_\*** Discord export (~1792-1947; its `local HttpService` was pulled OUT to true
      top-level first, since 3826/4834/4924/5777... use it). Headroom now ~15-30 locals (probe: +15 parses, +30
      overflows). Keep new top-level sections wrapped, as before.
    - **obfuscate.sh rewritten** (darklua -> Prometheus). Auto-clones Prometheus into `tools/prometheus` (gitignored,
      `/tools/` added to .gitignore) and pins commit `a98c50165f...`; needs `luajit`. New gates: parses (and names the
      200-local overflow if it returns), comments gone, sample labels NOT in cleartext (EncryptStrings ran), API globals
      present, pure ASCII, and size band 110%-500% of source (rejects "did nothing" AND an accidental VM, which lands
      at ~9000%). `.darklua.json` is now unused (left in repo). `deploy.sh --raw` still ships the readable copy as the
      instant fallback if Prometheus breaks the script in game.
    - **Next (in game):** reload the loader on beta; expect `[unsyk] ... loaded` (not a compile error) and the menu
      labels to still read correctly despite being encrypted on the wire. Risk if it fails: the cheat's sandbox blocks
      a primitive the EncryptStrings decoder needs (string.char / getfenv / arithmetic) at load — the `[loader] compile
      error` line will say which. If so, `deploy.sh --raw` reverts instantly, or drop EncryptStrings and keep only
      ConstantArray+rename. Also still TODO from #8: beta #12 d24ddef2ff removed the RemoteEvent/Bindable class-name
      scan from aim probe 2 (the cheat refused to compile it: "blocked class 'RemoteEvent'") — #13 includes that fix.

19. **Session 14 (2026-11-21): server security hardening. Live.**
   - **Backups:** Proxmox job on pve2 backs up CT 115 nightly 03:30 to `local` (`/var/lib/vz/dump`, keep 7 daily +
     4 weekly; same disk as the CT, so not offsite). First backup taken 15:01 before any change.
   - **CT 115 firewall** = `server/nftables.conf` -> `/etc/nftables.conf` (own `inet hvh` table, NO `flush ruleset`:
     that would wipe Tailscale's rules). wg0: only 10.8.0.1 -> tcp 8787. Panel 8080: LAN 192.168.68.0/22, and on the
     tailnet only the IPs in set `panel_ts` (MacBook, phones, desktop, cachyos; servers and tagged `mail`/`music` are
     blocked). **New personal device -> add its 100.x to `panel_ts`** and `nft -f /etc/nftables.conf`.
   - CT 115 sshd disabled (use `pct exec`). CT has unattended-upgrades on. VPS: packages + kernel updated, rebooted,
     rpcbind disabled; its iptables rules persist via netfilter-persistent (`/etc/iptables/rules.v4`).
     A VPS reboot cuts the feed (502) and mail until the home WireGuard peers re-handshake (~1-3 min, keepalive 25s;
     `ping 10.8.0.1` from the peer speeds it up). Mail CT = pve2 CT 111 (10.8.0.6); it serves 25/465/993, not 587.
   - **receiver.py:** per-account rate limit (120/min each, 3000/min total) instead of one global 120; 20 s socket
     timeout + max 64 connections per listener (`BoundedServer`); ingest answers 507 under 1 GB free disk; deep-JSON
     bodies -> 400; X-Forwarded-For trusted only from `TRUSTED_PROXY` (10.8.0.1); AUTH_FAILS pruned.
   - **`SESSION_SECRET`** in `/etc/hvh-ingest.env` signs license sessions + heartbeat tokens (separate from the master
     token, so a leaked master token can't forge sessions). Unset = old behaviour. Changing it, or INGEST_TOKEN while it
     is unset, logs every license out, and **running scripts stop themselves** (2x 401) -> only swap when nobody plays.
   - systemd unit sandboxed (no capabilities, syscall filter, MemoryMax 512M, TasksMax 200): `systemd-analyze security`
     1.9. If a future feature needs a blocked syscall, the service fails to start: check `journalctl -u hvh-ingest`.
   - Rollback copies in the CT: `/root/rollback/` (pre-hardening receiver + unit), `/root/nftables.conf.bak`,
     `/root/hvh-ingest.env.bak-*`.

20. **Session 15 (2026-11-21): resolver brain server-side. Built + tested locally, NOT deployed yet.**
   - The candidate list, priors, scoring weights, decay/block/hysteresis, pitch-flick and hand-back thresholds are
     gone from `unsyk.lua` (no fallback). They live in `server/hvh_resolver.py` (`CANDIDATES`, `WEIGHTS`; bump `GEN`
     after tuning -> new `rv` -> running clients re-fetch on their next /beat). deploy.sh ships it.
   - `GET /resolver?b=BUILD` (session / master token, per-account rate limit, 404 for a build not in the release
     history; 0 = legacy file). **Caddy still 404s /beat and /resolver**, so the script falls back to
     `/me?resolver=1&b=` (same answer). Snippet in repo lists /resolver; applying it on the VPS is the user's call.
   - Every served copy is stamped `UNSYK_RSEED` = HMAC(SIGN_KEY, build). The client puts its 7 features
     (FEAT b l d t e s a, order must match hvh_resolver.FEAT) into slots + signs derived from that seed
     (minstd + Fisher-Yates, `X.layout` mirrors `hvh_resolver.layout`); the table addresses slots. A table from
     another build gives a different pick ~96% of the time (tested), so a dump goes stale per build.
   - Client: `st.rsx.fetch(get)` runs from the heartbeat loop on the first good beat and when /beat's `rv` differs;
     table only in memory (`st.rsx.data`, never database). No table -> rs_tick behaves as Off (plist reset),
     `[RS] resolver off: <why>` (owner console) + feed `kind="diag" what="resolver"` (ok/rv/why). 401/403 or not
     logged in drops the table. Shots log `rs.rv` (or `why=nodata wd=<reason>`); follow prints `rv=`, report has
     `ours:rv=...` rows.
   - Equivalence test (scratch harness, old HEAD block vs new + real generator): 39917/40000 identical picks; the
     rest come from the old code passing an unrounded float for "jit" (now rounded like the others).
   - Honest scope: a live session can fetch /resolver once and dump it with that build; this stops offline /
     revoked / unstamped copies and makes dumps go stale per build. Cost + traceability, not a wall.

21. **Session 16 (2026-11-21): string encryption dropped ~10 fps -> rename-only. Beta #16 dcd97f04e9, confirmed in game: ~120 fps.**
   - The user had ~10 fps on beta #14. #15 = the same code shipped `--raw` (readable): fps back to normal. Cause = the
     Prometheus EncryptStrings + ConstantArray steps from #13: in Lua every field access (`st.x`, `obj.Text`) is a
     string constant, so every field read in the paint/tick callbacks became a function call + table lookup.
   - `scripts/prometheus.config.lua` now has NO steps (Prometheus still strips comments and renames locals; ~57% of
     source). `obfuscate.sh` gates flipped: output must be < 95% of source, and the label "Override yaw offset" MUST
     still be in cleartext (fails if a string-rewriting step comes back). No WrapInFunction, so the 200-local
     headroom concern from #13 no longer applies to the served copy (still applies to unsyk.lua itself).
   - Never add a step that rewrites string constants or expressions without an fps check on the beta first.

22. **Session 17 (2026-11-21): keyless guest access to STABLE. Code done locally, NOT deployed, NOT tested in game.**
   - `POST /auth {"guest":true,"uid","user"}` (no key) -> session `g1.<user>.<uid>.<exp>.<sig>` (HMAC, no key store); account =
     `guest:<RobloxName>` (colon can't appear in license names, so no collision). `_authed` accepts it in X-Session; events get
     `lic=guest:<name>`, `uid`. 30 guest logins/IP/10 min. `GUEST_ACCESS=0` in `/etc/hvh-ingest.env` turns it off.
   - Guests are ALWAYS stable (`hvh_release.channel_for` forces it); beta stays key-only. Guests can't POST /cloud (disk abuse).
     `/auth` is already in the Caddy matcher, so no VPS change needed.
   - Name and uid are client-claimed, unverifiable: guest data is not trustworthy identity.
   - Loader v9: no saved key (or a failed one) -> guest login and load stable; the tab's Key box still works while guest
     (logs in, then "reload for beta"). Loader card says "guest".
   - **Alive fps ~40 (#16) -> profiler (#17) + fixes (#18 016c3830cf, confirmed in game: "great performance", 89-175 fps).** The guard's `wrap()` times
     every callback into `UNSYK_PROF.list`; `UNSYK_PROF.sub(name)` + `UNSYK_PROF.add(P, dt)` are sub-timers (excluded
     from the total). Every 30s: `kind="diag" what="perf"` {fps, alive %, lua_ms (Lua ms per second), top = 12
     callbacks, sub = 16 sub-timers}. `debug.info` is blocked (ln always nil): callbacks are named `tick#N` / `paint#N`
     in registration order (from #18, tick#1 = the `UNSYK_PROF.tick` counter right after the guard).
   - #17 data: 356-604 ms of Lua per second; the resolver tick (`rs_tick`, every alive enemy) 2.3-5.8 ms/tick,
     teleport detector ~1-1.35 ms, intel_main ~0.8-1.0 ms (2 enemies). Cheat API calls cost ~50-100 us each, and
     `intel_update` makes ~6 per enemy per tick.
   - #18: `intel_update` reads the API once per enemy per tick (`st.ird`, keyed by `UNSYK_PROF.tick`; weapon name every
     16 ticks); `st.epos(e)` / `st.ename(e)` per-tick caches in the tick listeners (not paint); `st.pset` sends plist
     values only on change (+ every 32 ticks; `r.pc = nil` after any plist reset); ping once per tick.
   - #18 data (still ~340-520 ms of Lua per second): resolver tick ~2.7-3.4 ms, now mostly `rs.decide` (~0.5 ms per
     enemy, pure Lua: rs_decide -> rsx.pick), teleport detector tick ~1.37 ms, intel ~1.1 ms. get_info / anim_state
     ~75 us each. The perf diag's `alive` % reads 0 even while alive (is_alive check wrong): ignore it.

23. **Session 18 (2026-11-21): Caddy /beat + /resolver live; Quick stop / aim-wait findings.**
   - VPS `/etc/caddy/Caddyfile` feed block now matches the repo snippet (`/beat /resolver` added; backup
     `/root/Caddyfile.bak-20261121-201740` on exxo-vps). `/beat` returns `bt`, so `beat_ok` should turn true on #11+ builds:
     check `scripts/hvh abuse` before ever enabling `lic_enf`.
   - **Quick stop cannot work on this rig:** `qs rig` diag (112 reports, every player) = character Model with NO Humanoid,
     root `Part:Collide` **anchored**, moved by the game's `ClientEngine`. Velocity / Move / WalkSpeed all need physics or a
     Humanoid. The self-test "successes" (`qs method ok=true`) are confounded by the cheat's own auto stop. No movement
     setter exists in the API.
   - **AIM WAIT "no shot" episodes are not hesitation:** they last 15-19 ticks (= how long `rage.get_target()` keeps a
     stale snapshot) with 1-2 ragebot scans: the target was visible for a scan or two, then gone. When the ragebot can
     shoot it fires in 2-4 ticks at any speed (tester2 fires moving at 5-15 st/s). On tigokraft 20 of 30 no-shots started
     0.01 s after our own fire (post-shot ghosts the `post` flag misses). Hitchance is not the gate (tester2's menu
     hitchance reads 0). So Quick stop / "Hitchance moving" are not the lever for missed shots.

24. **Session 19 (2026-11-21): new cheat API (docs/penablox-luapi.md replaced) -> Roll + Fake pitch. NOT deployed, NOT tested in game.**
   - New API: `aa.override_extended_angles(pct -100..100)` + `_enabled` (= roll, finally), `aa.override_fake_pitch(-70..70 |
     "Down"/"Up"/"Zero")` + `override_fake_pitch_angle(-20..20)`, `entity.get_prop(e, "resolved_yaw"/"resolved_pitch"/
     "torso_yaw"/"duck_amount"/...)`, `aa.set_manual/get_manual`, `rage.get_player_pitch`, plist "Force pitch value" now
     reaches hitboxes/backtrack, `clantag.*` (server-synced tags, readable for every player). Not used yet except roll/fp.
   - Sections "Roll" + "Fake pitch" (Anti-aim page, right; `;(function()` block after Style, `st.rp`). Applied after every
     phase in the main AA tick (`st.rp.run(false)`), released (nil) while Style is not Custom, on AA disable and shutdown.
     Roll modes Off/Static/Follow desync/Against desync/Jitter/Random (follow = sign of `aa.get_inverter()`), "Roll when".
     Fake pitch Off/Down/Up/Zero/Custom/Jitter. All default Off.
   - Logging: per-tick rows + hit timelines carry `roll`/`fp`, hit `settings` string has roll=/fp=, state events carry
     `rp` {roll, fp, fpa, mode, fmode, got = readbacks every 16 ticks}: check `got` first to see if the overrides stick.
   - CTRL keys (Lua = hvhctl KEYS = app.js labels): roll, roll_amt, roll_rate, roll_when, fpitch, fpitch_val, fpitch_off,
     fpitch_rate. Built-in presets do not list these keys (loading one leaves roll/fp as they are).
   - **Anti-roll + pitch resolver** (section "Anti-roll", Resolver page; `;(function()` block after the candidate
     resolver, `st.rx2`). No API reads enemy roll or real pitch, so: lean = angle of head hitbox over pelvis hitbox
     (`get_player_hitbox_position`, every 4 ticks), baseline = 20th percentile of 64 samples, rolled = >= "Lean
     threshold" above it in 40% of the last 24. "Roll counter" (Off/Safe point/Body aim/Both) -> plist "Override safe
     point" / "Override prefer body aim". "Pitch brute force": after N resolver head misses in a row, "Force pitch value"
     cycles opposite-of-shown -> Zero -> remaining -> none; a hit keeps it; wins over the flick fix. Both default Off.
   - rs_tick now writes through `st.rs_apply(r, e, d, xd)`; extras apply in Active mode also to players the built-in
     resolver keeps for yaw. `r.yw` = we own yaw (shots' `own` and learning use it, NOT `r.applied`, which now also
     means "extras set"). Shot `rs.x` = {lean, lb, rl, pv, ps}. Diag `what="enemy lean (2min)"` = lean avg/max/base/
     rolled % per player + how often `get_prop` eye_angles_x vs resolved_pitch differ by > 25 (tune thresholds from it).
   - CTRL keys added: rs_roll, rs_lean, rs_pbrute, rs_pmiss.
