# unsyk

A Luau script for the **penablox** cheat (Roblox CS:GO clone), built for **HvH**: anti-aim, a learning resolver, peek timing, a custom in-game menu and optional live data logging.

> Everything here is for hack-vs-hack play by consent. There is no way to run Lua locally, so all testing happens in game.

## Features

### Anti-aim
- Desync with several inverter modes and per-state limits (stand / move / air / duck)
- Defensive burst, on-shot AA and manual yaw keys (hold)
- **Dodge AA**: while threatened, re-rolls side, desync size, yaw and pitch, with periodic swings
- **Roll** (static, follow, against, jitter, random) and **fake pitch** modes
- Peek modes: hold side, flip then hold, max desync hold, randomize

### Resolver
- Tracks every alive enemy, derives their desync side and predicts their next flip
- Candidate-offset scoring that learns per enemy and state from your misses
- Pitch-flick fix, pitch brute force, fake-duck safe point
- Anti-roll detection with a roll counter (safe point / body aim)
- Modes: Off / Shadow / Active (takes over only after the built-in resolver misses)

### Rage tweaks
- Hitchance and min-damage overrides for air, no-scope, duck and moving
- No-spread mode and a DT peek key
- Lethal min-damage and optional body-aim after misses
- Enemy teleport (double-tap shift) detector

### Peek advisor
- GOOD / OK / WAIT verdict from the enemy's flip pattern and your ping
- Shown as a bar between the crosshair arrows

### Visuals and UI
- Custom rounded in-game window: tabs, sliders, dropdowns, rebindable keys, accent colours, background blur
- Crosshair arrows (real / fake / view), yaw dial and state text
- HUD: watermark, keybind list, target panel, hit log, damage numbers
- Hit and kill sounds, 3D kill and hit effects
- Config system with cloud configs, share codes and official presets

### Data and analysis
- Enemy intel overlay and shot / hit / death logging with misses and reasons
- Per-tick timelines around each hit, CSV export
- Optional live feed to your own ingest server, reports and A/B testing through `hvhctl`

### Admin dashboard
A web panel served only on the home LAN / tailnet (never the public internet), behind its own login: user + scrypt password + TOTP, rate limited, idle timeout.

- **Testing workspace**
  - Compare: deaths per minute with a 95% range and a verdict against a baseline, by config version or build
  - Builds: stable and beta health, error groups, promote or end beta, testers, build history
  - Sessions: per-session stats, plus a live view
  - Live overrides: push config changes to running clients
- **Players workspace**
  - Roster: who is online, license state, current game, range stats
  - Player profile: activity, weapons, likely killers, sessions, cloud configs, downloads, errors
  - Player configs and official presets: publish a player's config as official, compare, delete
  - Served copies log, used to trace leaks

### Licensing
- License keys (`DAA-XXXXX-...`): only the hash is stored, and the first login locks a key to one Roblox account
- One device per key: every login ends the previous session
- Expiry dates: extend, set, revoke, enable, reset or delete from the panel or `hvhctl license`
- Signed 12 h sessions, with the script checking in (`/beat`) and stopping itself if the key is refused, expired or on the wrong account
- Guest access: keyless, stable build only, no cloud config saves
- Every served script copy is stamped with the downloader's key and logged
- `hvhctl abuse` flags shared keys, many download IPs and tampered clients

### Beta channel and releases
- Every deploy is a numbered build kept on the server, with history and rollback
- `stable` and `beta` channels: put risky changes on a beta group first, then promote
- Beta members are chosen per license; players switch channel on their next loader start
- Build, channel and a beta tag are shown in game and in every event
- Commands: `scripts/deploy.sh --beta --note "..."`, `scripts/hvh release [publish|promote|rollback|end-beta]`, `scripts/hvh beta [add|remove NAME]`

### Server and tooling
- Ingest receiver with token and session auth, rate and size limits, SQLite storage
- Remote control: change allowlisted settings live and A/B test them (`hvhctl config set k=v`)
- Reports, live tail and CSV export through `hvhctl` and `scripts/hvh`
- Script obfuscation (Prometheus, local rename only) with a `--raw` fallback
- Resolver tables served server-side per build (`server/hvh_resolver.py`)
- Hardened systemd unit, nftables firewall, nightly backups

## Usage

Load the loader in the cheat:

```lua
loadstring(game:HttpGet("https://feed.sites.exxo.world/loader.lua"))()
```

The loader handles login (license key or guest), downloads the latest build and starts it. To run the raw script instead, paste `unsyk.lua` into the cheat directly.

## Repository layout

| Path | What it is |
| --- | --- |
| `unsyk.lua` | The whole script |
| `loader.lua`, `load.lua` | Loader (login, update, cache) and its one-line bootstrap |
| `server/` | Ingest receiver, auth and license keys, cloud configs, resolver tables, admin panel, release channels, `hvhctl` CLI |
| `scripts/` | Deploy, obfuscate, export and helper scripts |
| `docs/penablox-luapi.md` | The cheat's Lua API reference |
| `CLAUDE.md` | Detailed project state and lessons learned (engine quirks, results, history) |

## Notes

- Engine quirks matter: no compound assignment on table fields (`x.n += 1`), keep new sections wrapped in `;(function() ... end)()` because the main chunk is at Lua's 200-local limit, and run `luac -p unsyk.lua` before shipping.
- Read `CLAUDE.md` for the full list before changing the script.
