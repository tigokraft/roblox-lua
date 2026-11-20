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
