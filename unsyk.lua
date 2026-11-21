-- unsyk (penablox)
-- Per-state AA (standing/moving/air/crouch), randomized desync limits, delayed/random inverter,
-- burst defensive (shift ticks + max-fakelag + 84° desync flip + unchoke), level pitch when target is above.

-- No separate cheat tab any more: every control is a script-side handle (get/set like a cheat handle)
-- recorded in tab.sections, and the custom in-game window (end of file) is built from that list.
-- The only cheat tab is the loader's "unsyk login"; tab.ui_sec adds the window/calibration buttons there.

-- Loaders pasted before the rename to unsyk set the old global names (and only accept a download that
-- mentions DESYNC_AA_VERSION). Map them so those loaders keep working; drop this once everyone reloaded.
if UNSYK_AUTH == nil then UNSYK_AUTH = DESYNC_AA_AUTH end
if UNSYK_VERSION == nil then UNSYK_VERSION = DESYNC_AA_VERSION end
-- Release channel + build number, stamped by the feed server (hvh_release.py). Nil on a local copy.
-- UNSYK_TAG = "beta #14" / "#13" / "local", used by the watermark, Settings > Build and the console lines.
UNSYK_TAG = (UNSYK_BUILD and ((UNSYK_CHANNEL == "beta" and "beta " or "") .. "#" .. tostring(UNSYK_BUILD))) or "local"

-- SUBSCRIPTION GUARD (1/2). Every event callback goes through this wrapper, so UNSYK_STOP(why) can switch the
-- whole script off without an unload API: callbacks go quiet, then every "shutdown" handler runs (they destroy
-- the GUIs/drawings and reset aa/sounds), and rage overrides are released. A local shadow of `client` (not a write
-- to the cheat's table, which may be read-only). Part 2 (the /beat heartbeat) is near the end of the file.
-- Tick listeners go through the same wrapper: client.on_tick(fn) (the shadow) instead of events.on_tick (main chunk is at
-- the 200-local limit, so no shadow local for `events`).
-- ERROR REPORTING: every wrapped callback runs in pcall. An error is counted per callback + message in UNSYK_ERRS
-- (max 40 distinct), printed at most every 3s each, and the feed sends them as kind="err" (admin panel build health).
local client = setmetatable({ _stop = {} }, { __index = client })
UNSYK_ERRS = { list = {}, n = 0 }
UNSYK_PROF = { list = {}, by = {}, tick = 0 }
-- sub-timers inside a callback (sub = true: not added to the callback total, which already contains them)
UNSYK_PROF.sub = function(name)
    local P = UNSYK_PROF.by[name]
    if not P then
        P = { where = name, t = 0, n = 0, max = 0, sub = true }
        UNSYK_PROF.by[name] = P
        UNSYK_PROF.list[#UNSYK_PROF.list + 1] = P
    end
    return P
end
UNSYK_PROF.add = function(P, d)
    P.t = P.t + d
    P.n = P.n + 1
    if d > P.max then P.max = d end
end
do
    local real = getmetatable(client).__index.set_event_callback
    local function note_err(where, e)
        local E = UNSYK_ERRS
        local msg = string.sub(tostring(e), 1, 300)
        local key = where .. "|" .. msg
        local r = E.list[key]
        if not r then
            if E.n >= 40 then return end
            r = { where = where, msg = msg, n = 0, sent = 0, logged = -10 }
            E.list[key] = r
            E.n = E.n + 1
        end
        r.n = r.n + 1
        local t = os.clock()
        if t - r.logged > 3 then
            r.logged = t
            pcall(client.color_log, 255, 90, 90, "[unsyk] error in " .. where .. " (x" .. r.n .. "): " .. msg)
        end
    end
    -- PROFILER: time spent in every wrapped callback (UNSYK_PROF.list, one record per callback with the line it
    -- was defined on when debug.info exists). The feed sends the top costs as kind="diag" what="perf" every 30s.
    local clock = os.clock
    local function wrap(where, fn)
        local okl, ln = pcall(function() return debug.info(fn, "l") end)
        local P = { where = where, ln = okl and tonumber(ln) or nil, t = 0, n = 0, max = 0 }
        UNSYK_PROF.list[#UNSYK_PROF.list + 1] = P
        local function finish(t0, ok, ...)
            local d = clock() - t0
            P.t = P.t + d
            P.n = P.n + 1
            if d > P.max then P.max = d end
            if ok then return ... end
            note_err(where, (...))
        end
        return function(...)
            if UNSYK_STOPPED then return end
            return finish(clock(), pcall(fn, ...))
        end
    end
    local evn = {}
    client.set_event_callback = function(ev, fn)
        if ev == "shutdown" then
            client._stop[#client._stop + 1] = fn
        end
        ev = tostring(ev)
        evn[ev] = (evn[ev] or 0) + 1
        return real(ev, wrap(evn[ev] > 1 and (ev .. "#" .. evn[ev]) or ev, fn))
    end
    local ticks = 0
    client.on_tick = function(fn)
        ticks = ticks + 1
        return events.on_tick(wrap("tick#" .. ticks, fn))
    end
    UNSYK_STOP = function(why)
        if UNSYK_STOPPED then return end
        UNSYK_STOPPED = tostring(why or "stopped")
        pcall(client.color_log, 255, 80, 80, "[unsyk] stopped: " .. UNSYK_STOPPED)
        pcall(client.notify, "unsyk stopped: " .. UNSYK_STOPPED)
        -- remembered for the next load's kind="load" event; the feed hook (if loaded) sends kind="stop" now
        pcall(function() database.write("aa_stop", UNSYK_STOPPED .. "|" .. tostring(os.time())); database.flush() end)
        if type(UNSYK_STOP_HOOK) == "function" then pcall(UNSYK_STOP_HOOK, UNSYK_STOPPED) end
        for _, fn in ipairs(client._stop) do pcall(fn) end
        pcall(aa.reset)
        for _, f in ipairs({ "override_hitchance", "override_min_damage", "override_force_baim" }) do
            pcall(rage[f], nil)
        end
    end
end
-- first tick listener: a tick counter shared by every section (UNSYK_PROF.tick), e.g. to read an enemy once per tick
client.on_tick(function() UNSYK_PROF.tick = UNSYK_PROF.tick + 1 end)

local tab = (function()
    local T = { sections = {} }
    local S = {}
    S.__index = S
    local function handle(v)
        -- set() does not fire the callback: the window's hset() calls it, like it did with cheat handles
        local h = { v = v }
        function h:get() return self.v end
        function h:set(x) self.v = x end
        function h:set_visible() end
        function h:set_callback(f) self.cb = f end
        return h
    end
    local function keydown(key)
        if string.sub(key, 1, 11) == "MouseButton" then
            local okm, dm = pcall(function()
                return game:GetService("UserInputService"):IsMouseButtonPressed(Enum.UserInputType[key])
            end)
            return okm and dm == true
        end
        local ok, d = pcall(input.is_key_down, key)
        if ok and type(d) == "boolean" then return d end
        local ok2, d2 = pcall(function() return game:GetService("UserInputService"):IsKeyDown(Enum.KeyCode[key]) end)
        return ok2 and d2 == true
    end
    local function typing()
        -- input.is_typing also covers the Roblox chat box; the focused-textbox check is the fallback
        local okt, t = pcall(input.is_typing)
        if okt and t == true then return true end
        local ok, f = pcall(function() return game:GetService("UserInputService"):GetFocusedTextBox() end)
        return ok and f ~= nil
    end
    local function keyhandle(mode, key)
        -- Hold: true while held; Toggle: flips on each press (edge seen by whoever polls first); Always: true
        -- h.key can be changed at any time (the window rebinds it; nil = no key)
        local h = handle(false)
        h.key = key
        local was = false
        function h:get()
            if mode == "Always" then return true end
            local k = self.key
            local down = k ~= nil and not typing() and keydown(k)
            if mode == "Hold" then was = down; return down end
            if down and not was then self.v = not self.v end
            was = down
            return self.v
        end
        return h
    end
    local function add(sec, item)
        item.tip_id = sec.name .. "/" .. item.name   -- the window's tooltip key (stays the same if a label is shown renamed)
        sec.items[#sec.items + 1] = item
        return item.h
    end
    function S:new_toggle(name, def, cb)
        return add(self, { kind = "toggle", name = name, h = handle(def == true), cb = cb })
    end
    function S:new_slider(name, lo, hi, def, dec, suf, cb)
        return add(self, { kind = "slider", name = name, h = handle(def or lo), lo = lo, hi = hi, dec = dec or 0, suf = suf or "", cb = cb })
    end
    function S:new_combobox(name, opts, def, cb)
        return add(self, { kind = "combo", name = name, h = handle(def or opts[1]), opts = opts, cb = cb })
    end
    function S:new_keybind(name, mode, key)
        -- a key rebound in the window is saved as database "kb:<section>/<name>" ("None" = unbound)
        local id = self.name .. "/" .. name
        local okr, sv = pcall(database.read, "kb:" .. id)
        if okr and type(sv) == "string" and sv ~= "" then
            if sv == "None" then key = nil else key = sv end
        end
        return add(self, { kind = "key", name = name, h = keyhandle(mode, key), mode = mode, key = key, id = id })
    end
    function S:new_textbox(name, ph, def, cb)
        return add(self, { kind = "text", name = name, h = handle(def or ""), ph = ph, cb = cb })
    end
    function S:new_button(name, cb)
        return add(self, { kind = "button", name = name, h = handle(nil), cb = cb })
    end
    function T:new_section(name, side)
        local sec = setmetatable({ name = name, side = side, items = {} }, S)
        self.sections[#self.sections + 1] = sec
        return sec
    end
    T.keydown = keydown
    return T
end)()
-- window buttons go into the loader's login tab; without the loader (raw script) a small tab of their own
do
    local ok, sec = pcall(function()
        local lt = type(UNSYK_AUTH) == "table" and UNSYK_AUTH.tab or nil
        if not lt then lt = menu.new_tab("unsyk", "rbxassetid://10734975692") end
        return lt:new_section("Menu", "Right")
    end)
    tab.ui_sec = ok and sec or { new_button = function() end }
end
local s_main = tab:new_section("Anti-Aim", "Left")
local s_ds   = tab:new_section("Desync", "Right")
local s_def  = tab:new_section("Defensive", "Left")
local s_man  = tab:new_section("Manual", "Right")

local MAXD = 84 -- docs say 86, but 84 is what working scripts cap at

local enabled   = s_main:new_toggle("Enable", false)
local pitch_sel = s_main:new_combobox("Pitch", { "Down", "Up", "Zero", "Flick" }, "Down")
local up_fix    = s_main:new_toggle("Level pitch vs high target", false)
local yaw_off   = s_main:new_slider("Yaw offset", -180, 180, 0, 0, "°")
local yaw_mod   = s_main:new_combobox("Yaw modifier", { "Disabled", "Center", "Sway", "Spin", "Random", "3-Way", "5-Way" }, "Disabled")
local mod_amt   = s_main:new_slider("Modifier amount", 0, 90, 30, 0, "°")
local lag_ticks = s_main:new_slider("Fake lag", 0, 14, 0, 0, "t")
local lag_var   = s_main:new_slider("Lag variability", 0, 100, 0, 0, "%")

local ds_mode   = s_ds:new_combobox("Inverter", { "Static", "Jitter", "Delayed", "Random", "On-shot flip" }, "Static")
local lim_stand = s_ds:new_slider("Limit standing", 0, MAXD, 84, 0, "°")
local lim_move  = s_ds:new_slider("Limit moving", 0, MAXD, 84, 0, "°")
local lim_air   = s_ds:new_slider("Limit in air", 0, MAXD, 84, 0, "°")
local lim_duck  = s_ds:new_slider("Limit crouching", 0, MAXD, 84, 0, "°")
local lim_rnd   = s_ds:new_toggle("Randomize limit", false)
local ds_delay  = s_ds:new_slider("Delay", 1, 32, 4, 0, "t")
local ds_dr     = s_ds:new_slider("Delay jitter", 0, 16, 4, 0, "t")
local ds_inv    = s_ds:new_keybind("Invert", "Toggle", "F")
local ds_fake   = s_ds:new_toggle("Fake chams", false)

local def_on    = s_def:new_toggle("Defensive burst", false)
local def_trig  = s_def:new_combobox("Trigger", { "interval", "after shot", "always" }, "interval")
local def_int   = s_def:new_slider("Interval", 100, 2000, 600, 0, "ms")
local def_dur   = s_def:new_slider("Burst length", 1, 14, 4, 0, "t")
local def_shift = s_def:new_slider("Shift ticks", 0, 14, 14, 0, "t")
local def_pitch = s_def:new_combobox("Burst pitch", { "Up", "Down", "Zero", "Jitter" }, "Up")
local def_yaw   = s_def:new_slider("Burst yaw", 0, 180, 140, 0, "°")
local def_flip  = s_def:new_toggle("Flip desync", true)
local def_lag   = s_def:new_toggle("Max lag in burst", true)
local def_unch  = s_def:new_toggle("Unchoke after burst", true)
local def_rand  = s_def:new_toggle("Randomize bursts", true)

local s_os    = tab:new_section("On-shot", "Right")
local os_on    = s_os:new_toggle("On-shot AA", false)
local os_mode  = s_os:new_combobox("Mode", { "Flip desync", "Max desync flip", "Flip + yaw 180", "Hide head (pitch zero)" }, "Max desync flip")
local os_len   = s_os:new_slider("Duration", 1, 8, 2, 0, "t")
local os_unch  = s_os:new_toggle("Unchoke on shot", true)

local man_l = s_man:new_keybind("Left", "Hold", "Z")
local man_r = s_man:new_keybind("Right", "Hold", "C")
local man_b = s_man:new_keybind("Back", "Hold", "X")

-- helpers ---------------------------------------------------------------

-- Double tap detection, same fallbacks neverpeek uses:
-- charge number from get_double_tap_charge -> get_dt_charge -> is_double_tap_charged (bool),
-- "on" from is_double_tap_active -> is_double_tap -> menu toggle (ui.reference) -> charge > 0
local dt_ref = nil
do
    local okr, a = pcall(ui.reference, "RAGE", "Aimbot", "Double tap")
    if okr then dt_ref = a end
end

local function dt_state()
    local charge, src = nil, "none"
    local ok1, r1 = pcall(rage.get_double_tap_charge)
    if ok1 and type(r1) == "number" then charge, src = r1, "get_double_tap_charge" end
    if charge == nil then
        local ok2, r2 = pcall(rage.get_dt_charge)
        if ok2 and type(r2) == "number" then charge, src = r2, "get_dt_charge" end
    end
    if charge == nil then
        local ok3, r3 = pcall(rage.is_double_tap_charged)
        if ok3 and type(r3) == "boolean" then charge, src = (r3 and 14 or 0), "is_double_tap_charged" end
    end

    local on = nil
    local ok4, r4 = pcall(rage.is_double_tap_active)
    if ok4 and type(r4) == "boolean" then on = r4 end
    if on == nil then
        local ok5, r5 = pcall(rage.is_double_tap)
        if ok5 and type(r5) == "boolean" then on = r5 end
    end
    local menu = nil
    if dt_ref ~= nil then
        local ok6, r6 = pcall(ui.get, dt_ref)
        if ok6 and type(r6) == "boolean" then menu = r6 end
    end
    if on == nil then on = menu end
    if on == nil then on = (charge ~= nil and charge > 0) end

    charge = charge or 0
    return {
        charge = charge, charged = charge >= 14, on = on, menu = menu, src = src,
        text = string.format("%d/14%s%s", charge, on and " on" or " off", menu == false and " (menu OFF)" or ""),
    }
end

local st = {
    n = 0, inv = false, inv_at = 0,
    shot = false, left = 0, nxt = 0, side = 1,
    up_until = 0,
}

local function me() return entity.get_local_player() end

local function my_state()
    local ok, info = pcall(entity.get_info, me())
    if not ok or not info then return "stand" end
    if info.is_in_air then return "air" end
    if info.is_crouching then return "duck" end
    if info.speed and info.speed > 5 then return "move" end
    return "stand"
end

local function limit_for(state)
    local l = ({ stand = lim_stand, move = lim_move, air = lim_air, duck = lim_duck })[state]:get()
    if lim_rnd:get() then l = l * (0.88 + math.random() * 0.12) end
    return math.min(l, MAXD)
end

local function aim_up()
    local ok, t = pcall(rage.get_target)
    if not ok or not t then return false end
    local ap = t.aim_point
    local ok2, pos = pcall(entity.get_player_position, me())
    if not ap or not ok2 or not pos then return false end
    return ap.Y - (pos.Y + 1.5) > 1
end

local function inverter(mode)
    if mode == "Static" then
        st.inv = ds_inv:get()
    elseif mode == "Jitter" then
        st.inv = (st.n % 2) == 0
    elseif mode == "Delayed" or mode == "Random" then
        if st.n >= st.inv_at then
            st.inv = not st.inv
            if mode == "Random" then
                st.inv_at = st.n + math.random(3, 12)
            else
                st.inv_at = st.n + ds_delay:get() + math.random(0, ds_dr:get())
            end
        end
    elseif mode == "On-shot flip" then
        if st.shot then st.inv = not st.inv end
    end
    return st.inv
end

local function manual()
    if man_l:get() then return -90 end
    if man_r:get() then return 90 end
    if man_b:get() then return 0 end
    -- the cheat's own manual AA keys (aa.get_manual, 2026-11 API): before this our yaw offset overrode them.
    -- Read once per tick (manual() is called from several places).
    if st.mk ~= UNSYK_PROF.tick then
        st.mk = UNSYK_PROF.tick
        local ok, d = pcall(aa.get_manual)
        st.mv = ok and d or nil
    end
    local d = st.mv
    if d == "Left" then return -90 elseif d == "Right" then return 90 elseif d == "Back" then return 0 end
end

local function sway(t) return math.sin(t * 0.15) * mod_amt:get() end

local function regular(level)
    local man = manual()
    pcall(aa.override_pitch, level and "Zero" or (pitch_sel:get() == "Flick" and ((st.n % 4 < 2) and 89 or -89) or pitch_sel:get()))
    pcall(aa.override_yaw, 180, "camera")
    pcall(aa.override_yaw_offset, man or yaw_off:get())

    local m = yaw_mod:get()
    if man or m == "Disabled" then
        pcall(aa.override_yaw_modifier, "Disabled")
    elseif m == "Sway" then
        pcall(aa.override_yaw_modifier, sway)
    else
        pcall(aa.override_yaw_modifier, m, mod_amt:get())
    end

    local lim = limit_for(my_state())
    st.cur_lim = lim
    pcall(aa.override_body_yaw, true)
    pcall(aa.override_inverter, inverter(ds_mode:get()))
    pcall(aa.override_desync_limits, lim, lim)
    pcall(aa.override_show_fake, ds_fake:get())

    pcall(aa.override_fake_lag, true)
    pcall(aa.override_fake_lag_limit, lag_ticks:get())
    pcall(aa.override_fake_lag_variability, lag_var:get())
end

local function defensive(level)
    if not def_on:get() then st.left = 0; return false end
    local now = os.clock()

    if st.left <= 0 then
        local fire
        local trig = def_trig:get()
        if trig == "always" then fire = true
        elseif trig == "after shot" then fire = st.shot
        else fire = now >= st.nxt end

        if fire then
            local rnd = def_rand:get()
            st.left = math.max(1, def_dur:get() + (rnd and math.random(-1, 1) or 0))
            st.side = rnd and (math.random() < 0.5 and 1 or -1) or -st.side
            st.nxt = now + def_int:get() / 1000 * (rnd and (0.7 + math.random() * 0.6) or 1)
            local sh = def_shift:get()
            -- the charge read is always 0 in this cheat, so gating on it meant the shift never fired:
            -- send it unconditionally (force_shift like Dodge does), fall back to shift_ticks
            if sh > 0 then
                local ok = pcall(rage.force_shift, sh)
                if not ok then pcall(rage.shift_ticks, sh) end
            end
        end
    end
    if st.left <= 0 then return false end
    st.left = st.left - 1

    local p = def_pitch:get()
    if level then p = "Zero"
    elseif p == "Jitter" then p = (st.n % 2 == 0) and 89 or -89 end
    pcall(aa.override_pitch, p)

    pcall(aa.override_yaw, 180, "camera")
    pcall(aa.override_yaw_offset, st.side * def_yaw:get())
    pcall(aa.override_yaw_modifier, "Disabled")

    if def_flip:get() then
        pcall(aa.override_body_yaw, true)
        pcall(aa.override_inverter, st.side > 0)
        pcall(aa.override_desync_limits, MAXD, MAXD)
    end
    if def_lag:get() then
        pcall(aa.override_fake_lag, true)
        pcall(aa.override_fake_lag_limit, 14)
    end
    if st.left == 0 and def_unch:get() then pcall(aa.unchoke) end
    return true
end

-- on-shot: override angles for a few ticks after firing so the shot record differs from the real angles
st.os_left = 0
local function onshot()
    if st.os_left <= 0 then return false end
    st.os_left = st.os_left - 1
    local m = os_mode:get()
    local flipped = not st.inv
    pcall(aa.override_body_yaw, true)
    pcall(aa.override_inverter, flipped)
    if m == "Flip desync" then
        local lim = limit_for(my_state())
        pcall(aa.override_desync_limits, lim, lim)
    elseif m == "Max desync flip" then
        pcall(aa.override_desync_limits, MAXD, MAXD)
    elseif m == "Flip + yaw 180" then
        pcall(aa.override_desync_limits, MAXD, MAXD)
        pcall(aa.override_yaw, 180, "camera")
        pcall(aa.override_yaw_offset, 180)
        pcall(aa.override_yaw_modifier, "Disabled")
    elseif m == "Hide head (pitch zero)" then
        pcall(aa.override_desync_limits, MAXD, MAXD)
        pcall(aa.override_pitch, "Zero")
    end
    if st.os_left == 0 then
        if os_unch:get() then pcall(aa.unchoke) end
    end
    return true
end

client.set_event_callback("aim_fire", function()
    st.shot = true
    if os_on:get() then st.os_left = os_len:get() end
end)

-- ======================================================================
-- STYLE: the current meta is reportedly "static backwards" (yaw 180, no jitter, one fixed desync side) and
-- sometimes no AA at all. Style replaces EVERYTHING else in the AA tick (dodge, defensive, flick, on-shot,
-- peek AA) so an A/B test compares the bare style, not a mix:
--   Custom      = our normal AA (unchanged)
--   Static back = pitch from the Pitch setting, yaw 180, no modifier, fixed side, "Static desync" degrees
--                 (0 = body yaw off). Manual keys still work.
--   No AA       = pitch off, yaw = camera, body yaw off, fake lag off (unless "Keep fake lag").
--   Swap        = Static back <-> No AA every "Swap every" seconds (+- "Swap jitter" %), so a resolver that
--                 learned one never gets a long run of it.
-- Phases logged as "static" / "noaa" (reports already split deaths by phase). Default Custom.
-- ======================================================================
;(function()
local s = tab:new_section("Style", "Left")
local U = {
    mode = s:new_combobox("Style", { "Custom", "Static back", "No AA", "Swap" }, "Custom"),
    lim  = s:new_slider("Static desync", 0, MAXD, 58, 0, "°"),
    side = s:new_combobox("Static side", { "Invert key", "Fake left", "Fake right" }, "Invert key"),
    swap = s:new_slider("Swap every", 2, 60, 10, 0, "s"),
    jit  = s:new_slider("Swap jitter", 0, 100, 50, 0, "%"),
    lag  = s:new_toggle("Keep fake lag in No AA", false),
}
local S = { ui = U, cur = nil, at = 0, swaps = 0 }
st.sy = S

local function static_back(level)
    local man = manual()
    local p = pitch_sel:get()
    if level then p = "Zero" elseif p == "Flick" then p = "Down" end
    pcall(aa.override_pitch, p)
    pcall(aa.override_yaw, 180, "camera")
    pcall(aa.override_yaw_offset, man or yaw_off:get())
    pcall(aa.override_yaw_modifier, "Disabled")
    local sd = U.side:get()
    local inv
    if sd == "Fake left" then inv = false
    elseif sd == "Fake right" then inv = true
    else inv = ds_inv:get() == true end
    st.inv = inv
    local lim = math.floor(U.lim:get())
    st.cur_lim = lim
    pcall(aa.override_body_yaw, lim > 0)
    pcall(aa.override_inverter, inv)
    pcall(aa.override_desync_limits, lim, lim)
    pcall(aa.override_show_fake, ds_fake:get())
    local lt = lag_ticks:get()
    pcall(aa.override_fake_lag, lt > 0)
    pcall(aa.override_fake_lag_limit, lt)
    pcall(aa.override_fake_lag_variability, lag_var:get())
end

local function no_aa()
    pcall(aa.override_pitch, "Disabled")
    pcall(aa.override_yaw, 0, "camera")
    pcall(aa.override_yaw_offset, 0)
    pcall(aa.override_yaw_modifier, "Disabled")
    pcall(aa.override_body_yaw, false)
    pcall(aa.override_desync_limits, 0, 0)
    pcall(aa.override_show_fake, false)
    st.cur_lim = 0
    local keep = U.lag:get()
    local lt = lag_ticks:get()
    pcall(aa.override_fake_lag, keep and lt > 0)
    pcall(aa.override_fake_lag_limit, keep and lt or 0)
end

-- Returns the phase name ("static" / "noaa") when Style handled this tick, nil for Custom.
S.run = function(level)
    local m = U.mode:get()
    if m == "Custom" then S.cur = nil; return nil end
    local which = m
    if m == "Swap" then
        local now = os.clock()
        if S.cur == nil or now >= S.at then
            S.cur = (S.cur == "Static back") and "No AA" or "Static back"
            local j = U.jit:get() / 100
            S.at = now + U.swap:get() * (1 + (math.random() * 2 - 1) * j)
            S.swaps = S.swaps + 1
        end
        which = S.cur
    else
        S.cur = m
    end
    if which == "No AA" then no_aa(); return "noaa" end
    static_back(level)
    return "static"
end
end)()

-- ======================================================================
-- ROLL + FAKE PITCH (API from the 2026-11 cheat update, NOT tested in game).
--   Roll       = aa.override_extended_angles(pct, -100..100) + aa.override_extended_angles_enabled(true)
--   Fake pitch = aa.override_fake_pitch(-70..70 or "Down"/"Up"/"Zero") + aa.override_fake_pitch_angle(-20..20)
-- Runs after the phase of this tick (regular / defensive / dodge / flick / on-shot) and lays roll + fake pitch on
-- top; skipped (released) while Style is not Custom, so a bare-style A/B stays bare. Off = released with nil once,
-- so the cheat's own menu values come back. Which roll sign hides the head is unknown: "Follow desync" and
-- "Against desync" exist so an A/B can find out. Readbacks (get_extended_angles / get_fake_pitch) are logged every
-- 16 ticks to check that the overrides stick (st.rp.info -> state events, per-tick rows -> hit timelines).
-- ======================================================================
;(function()
local s = tab:new_section("Roll", "Right")
local f = tab:new_section("Fake pitch", "Right")
local U = {
    roll  = s:new_combobox("Roll", { "Off", "Static", "Follow desync", "Against desync", "Jitter", "Random" }, "Off"),
    amt   = s:new_slider("Roll amount", -100, 100, 100, 0, "%"),
    rate  = s:new_slider("Roll jitter rate", 1, 32, 4, 0, "t"),
    when  = s:new_combobox("Roll when", { "Always", "Standing", "On ground", "In air" }, "Always"),
    fp    = f:new_combobox("Fake pitch", { "Off", "Down", "Up", "Zero", "Custom", "Jitter" }, "Off"),
    fpv   = f:new_slider("Fake pitch value", -70, 70, 0, 0, "°"),
    fpa   = f:new_slider("Fake pitch offset", -20, 20, 0, 0, "°"),
    fpr   = f:new_slider("Fake pitch jitter rate", 1, 32, 4, 0, "t"),
}
local R = { ui = U, roll_on = false, fp_on = false, jr = 1, jf = 1, rnd = 0, rb = {} }
st.rp = R

local function roll_release()
    if not R.roll_on then return end
    R.roll_on = false
    pcall(aa.override_extended_angles, nil)
    pcall(aa.override_extended_angles_enabled, nil)
end
local function fp_release()
    if not R.fp_on then return end
    R.fp_on = false
    pcall(aa.override_fake_pitch, nil)
    pcall(aa.override_fake_pitch_angle, nil)
end
R.release = function()
    roll_release(); fp_release()
    st.roll_cur, st.fp_cur = nil, nil
end
client.set_event_callback("shutdown", R.release)

local function roll_ok()
    local w = U.when:get()
    if w == "Always" then return true end
    local state = my_state()    -- one get_info call, only when a state filter is set
    if w == "Standing" then return state == "stand" end
    if w == "On ground" then return state ~= "air" end
    return state == "air"
end

-- the side the desync really sits on this tick (defensive / dodge set the inverter without touching st.inv)
local function inv_now()
    local ok, v = pcall(aa.get_inverter)
    if ok and type(v) == "boolean" then return v end
    return st.inv == true
end

local function roll_value()
    local m = U.roll:get()
    if m == "Off" or not roll_ok() then return nil end
    local a = U.amt:get()
    local mag = math.abs(a)
    if m == "Static" then return a end
    if m == "Follow desync" then return inv_now() and mag or -mag end
    if m == "Against desync" then return inv_now() and -mag or mag end
    local r = math.max(1, math.floor(U.rate:get()))
    if m == "Jitter" then
        if st.n % r == 0 then R.jr = -R.jr end
        return R.jr * mag
    end
    -- Random
    if st.n % r == 0 then R.rnd = math.floor((math.random() * 2 - 1) * mag + 0.5) end
    return R.rnd
end

local function fp_value()
    local m = U.fp:get()
    if m == "Off" then return nil end
    if m == "Custom" then return math.floor(U.fpv:get()) end
    if m == "Jitter" then
        local r = math.max(1, math.floor(U.fpr:get()))
        if st.n % r == 0 then R.jf = -R.jf end
        return R.jf > 0 and "Up" or "Down"
    end
    return m
end

-- called from the main AA tick after every phase; bare = Style handled this tick
R.run = function(bare)
    if bare then R.release(); return end
    local rv = roll_value()
    if rv == nil then
        roll_release()
    else
        if not R.roll_on then pcall(aa.override_extended_angles_enabled, true) end
        R.roll_on = true
        pcall(aa.override_extended_angles, rv)
    end
    st.roll_cur = rv
    local fv = fp_value()
    if fv == nil then
        fp_release()
    else
        R.fp_on = true
        pcall(aa.override_fake_pitch, fv)
        pcall(aa.override_fake_pitch_angle, math.floor(U.fpa:get()))
    end
    st.fp_cur = fv
    -- self-test every 8 ticks: our own lean (head hitbox over pelvis hitbox, same measure the anti-roll detector
    -- uses on enemies) and head height. Roll on vs off in the state events shows whether roll moves the hitbox
    -- the ragebots aim at, which sign does what, and what lean value a real roll gives (-> "Lean threshold").
    if st.n % 8 == 0 then
        local okh, h = pcall(entity.get_player_hitbox_position, me(), "head")
        local okp, p = pcall(entity.get_player_hitbox_position, me(), "pelvis")
        if okh and okp and typeof(h) == "Vector3" and typeof(p) == "Vector3" and h.Y - p.Y > 0.3 then
            local d = h - p
            local lean = math.deg((math.atan2 or math.atan)(math.sqrt(d.X * d.X + d.Z * d.Z), d.Y))
            R.ml = R.ml and (R.ml * 0.8 + lean * 0.2) or lean
            R.mh = R.mh and (R.mh * 0.8 + d.Y * 0.2) or d.Y
            R.mlmax = math.max(R.mlmax or 0, lean)
        end
    end
    -- readback every 16 ticks: does the cheat keep what we set?
    if (R.roll_on or R.fp_on) and st.n % 16 == 0 then
        local o1, g1 = pcall(aa.get_extended_angles)
        local o2, g2 = pcall(aa.get_extended_angles_enabled)
        local o3, g3 = pcall(aa.get_fake_pitch)
        local o4, g4 = pcall(aa.get_fake_pitch_angle)
        R.rb = { r = o1 and g1 or "err", re = o2 and g2 or "err", f = o3 and g3 or "err", fa = o4 and g4 or "err" }
    end
end

-- for state events: nil while both are off
R.info = function()
    -- own lean / head height always (the baseline with roll off matters as much as the value with it on)
    local me_ = R.ml and { ml = math.floor(R.ml * 10 + 0.5) / 10, mh = math.floor(R.mh * 100 + 0.5) / 100,
        mx = math.floor((R.mlmax or 0) + 0.5) } or nil
    R.mlmax = nil    -- max since the last state event (every 5s)
    if not (R.roll_on or R.fp_on) then return me_ end
    return { roll = st.roll_cur, fp = st.fp_cur, fpa = R.fp_on and math.floor(U.fpa:get()) or nil,
        mode = U.roll:get(), fmode = U.fp:get(), got = R.rb,
        ml = me_ and me_.ml or nil, mh = me_ and me_.mh or nil, mx = me_ and me_.mx or nil }
end
end)()

local was_active = false
client.on_tick(function()
    if not enabled:get() then
        if was_active then pcall(aa.reset); pcall(st.rp.release); was_active = false end
        return
    end
    was_active = true
    st.n = st.n + 1

    if up_fix:get() and aim_up() then st.up_until = os.clock() + 0.2 end
    local level = up_fix:get() and os.clock() < st.up_until

    -- regular sets the base state, then on-shot (highest priority) overrides parts of it
    local prev_inv = st.inv
    -- Style (section "Style" above): Static back / No AA / Swap replace everything below
    local oks, sph = pcall(st.sy.run, level)
    if oks and sph then
        st.phase = sph
        if st.inv ~= prev_inv then st.flip_n = st.n end
        st.os_left = 0
        st.shot = false
        pcall(st.rp.run, true)
        return
    end
    -- Dodge AA (section "Dodge", further down) replaces regular + defensive while it is active
    local okd, dodged = false, false
    if st.dodge and manual() == nil then okd, dodged = pcall(st.dodge, level) end
    if okd and dodged then
        st.phase = "dodge"
    elseif defensive(level) then
        st.phase = "defensive"
        if def_flip:get() then st.cur_lim = MAXD end
    else
        st.phase = "regular"
        regular(level)
    end
    if st.flick then    -- Flick (section "Flick", further down): yaw flick overlay + forced fake lag
        local okf, fl = pcall(st.flick, st.phase == "regular" and manual() == nil)
        if okf and fl then st.phase = st.phase .. "+flick" end
    end
    if onshot() then
        st.phase = st.phase .. "+onshot"
        if os_mode:get() ~= "Flip desync" then st.cur_lim = MAXD end
    end
    if st.hook then pcall(st.hook) end    -- peek AA (section "Peek & extras", further down)
    pcall(st.rp.run, false)               -- roll + fake pitch on top (section "Roll + fake pitch" above)
    if st.inv ~= prev_inv then st.flip_n = st.n end
    st.shot = false
end)

-- Angle arrows (world-space, drawn from your feet) ---------------------
local s_arr    = tab:new_section("Arrows", "Left")
local arr_on   = s_arr:new_toggle("World arrows", false)
local arr_view = s_arr:new_toggle("View arrow", false)
local arr_len  = s_arr:new_slider("Length", 2, 12, 5, 0, "st")
local arr_flip = s_arr:new_toggle("Mirror", false)
local arr_off  = s_arr:new_slider("Rotation", -180, 180, 180, 0, "°")

local function mk_arrow(col)
    local a = { shaft = Drawing.new("Line"), h1 = Drawing.new("Line"), h2 = Drawing.new("Line"), label = Drawing.new("Text") }
    for _, l in ipairs({ a.shaft, a.h1, a.h2 }) do
        l.Color = col
        l.Thickness = 2
        l.Visible = false
    end
    a.label.Color = col
    a.label.Size = 13
    a.label.Font = Drawing.Fonts.Plex
    a.label.Outline = true
    a.label.Visible = false
    return a
end

local A_REAL = mk_arrow(color(80, 255, 120))   -- real
local A_FAKE = mk_arrow(color(255, 70, 80))    -- fake / ghost
local A_VIEW = mk_arrow(color(255, 255, 255))  -- view (calibration)

local function hide_arrow(a)
    a.shaft.Visible, a.h1.Visible, a.h2.Visible, a.label.Visible = false, false, false, false
end

local function yaw_to_dir(deg)
    local d = math.rad(deg + arr_off:get())
    if arr_flip:get() then d = -d end
    return Vector3.new(math.sin(d), 0, math.cos(d))
end

local function draw_arrow(a, origin, deg, text)
    local len = arr_len:get()
    local dir = yaw_to_dir(deg)
    local tip = origin + dir * len
    local side = Vector3.new(dir.Z, 0, -dir.X)
    local b1 = tip - dir * 1.2 + side * 0.7
    local b2 = tip - dir * 1.2 - side * 0.7

    local ox, oy, on1 = render.world_to_screen(origin)
    local tx, ty, on2 = render.world_to_screen(tip)
    if not (on1 and on2) then hide_arrow(a) return end
    local x1, y1 = render.world_to_screen(b1)
    local x2, y2 = render.world_to_screen(b2)

    a.shaft.From, a.shaft.To = vector(ox, oy), vector(tx, ty)
    a.h1.From, a.h1.To = vector(tx, ty), vector(x1, y1)
    a.h2.From, a.h2.To = vector(tx, ty), vector(x2, y2)
    a.shaft.Visible, a.h1.Visible, a.h2.Visible = true, true, true
    a.label.Text = text
    a.label.Position = vector(tx + 6, ty - 6)
    a.label.Visible = true
end

local function wrap(a) return ((a + 180) % 360) - 180 end

client.set_event_callback("paint", function()
    if not enabled:get() or not arr_on:get() then
        hide_arrow(A_REAL); hide_arrow(A_FAKE); hide_arrow(A_VIEW)
        return
    end

    local okr, real = pcall(aa.get_lby_deg)
    local okf, fake = pcall(aa.get_fake_lby_deg)
    local okp, pos = pcall(entity.get_player_position, me())
    if not okp or not pos then return end
    local origin = pos + Vector3.new(0, 0.2, 0)

    if okr then draw_arrow(A_REAL, origin, real, "REAL") else hide_arrow(A_REAL) end
    if okf then draw_arrow(A_FAKE, origin, fake, "FAKE") else hide_arrow(A_FAKE) end

    if arr_view:get() then
        local okc, _, yaw = pcall(client.get_camera_angles_deg)
        if okc and yaw then draw_arrow(A_VIEW, origin, yaw, "VIEW") else hide_arrow(A_VIEW) end
    else
        hide_arrow(A_VIEW)
    end
end)

client.set_event_callback("shutdown", function()
    pcall(aa.reset)
    for _, a in ipairs({ A_REAL, A_FAKE, A_VIEW }) do
        for _, o in pairs(a) do pcall(function() o:Destroy() end) end
    end
end)

-- ======================================================================
-- CROSSHAIR INDICATORS: < > around the crosshair (desync side lit, manual yaw red, v = back), state + DT below.
-- Debug: a yaw dial around the crosshair (grey tick = where you look, green = real, red = fake, both relative to
-- the camera) and a live readout of what the AA is doing. Off by default.
-- ======================================================================
do
local s_ch    = tab:new_section("Crosshair", "Right")
local ch_on   = s_ch:new_toggle("Indicators", false)
local ch_gap  = s_ch:new_slider("Arrow gap", 20, 120, 45, 0, "px")
local ch_y    = s_ch:new_slider("Text offset", 10, 80, 24, 0, "px")
local ch_name = s_ch:new_toggle("Title", false)
local ch_dbg  = s_ch:new_toggle("Debug", false)
local ch_dr   = s_ch:new_slider("Dial radius", 20, 120, 34, 0, "px")
local ch_peek = s_ch:new_toggle("Peek advice", false)

local COL = { acc = color(150, 200, 60), amb = color(236, 168, 76), txt = color(225, 225, 225), dim = color(105, 105, 110),
    red = color(235, 85, 85), cyan = color(110, 200, 235), real = color(110, 230, 120), fake = color(235, 85, 85) }
st.ch_col = COL
local centered = true
local function T(size)
    local t = Drawing.new("Text")
    t.Size = size
    t.Font = Drawing.Fonts.Plex
    t.Outline = true
    t.Color = COL.txt
    t.Visible = false
    if not pcall(function() t.Center = true end) then centered = false end
    return t
end
local function L(col, th)
    local l = Drawing.new("Line")
    l.Color = col
    l.Thickness = th
    l.Visible = false
    return l
end
local ch = { l = T(18), r = T(18), b = T(15), t1 = T(12), t2 = T(12), t3 = T(12), pk = T(12) }
-- peek advice bar between the arrows (dim track + coloured fill that shrinks as their next flip nears)
local pb = { bg = L(COL.dim, 2), fg = L(COL.real, 2) }
ch.l.Text, ch.r.Text, ch.b.Text = "<", ">", "v"
local dbg = { d1 = T(12), d2 = T(12), d3 = T(12), d4 = T(12), rl = T(11), fl = T(11),
    real = L(COL.real, 2), fake = L(COL.fake, 2), view = L(COL.dim, 2) }
dbg.rl.Text, dbg.fl.Text = "R", "F"
dbg.rl.Color, dbg.fl.Color = COL.real, COL.fake

local function place(t, x, y)
    if not centered then x = x - #t.Text * t.Size * 0.28 end
    t.Position = vector(x, y)
    t.Visible = true
end
local function hide_all(set) for _, o in pairs(set) do o.Visible = false end end

local last_fire, dt_flash = 0, 0
client.set_event_callback("aim_fire", function()
    local now = globals.realtime()
    if now - last_fire < 0.35 then dt_flash = now + 1.2 end
    last_fire = now
end)

-- needle from the crosshair: rel = yaw relative to the camera (0 = straight up = where you look)
local function needle(line, lab, cx, cy, rel, r)
    local a = math.rad(rel)
    if arr_flip:get() then a = -a end
    local sx, sy = -math.sin(a), -math.cos(a)
    line.From = vector(cx + sx * 8, cy + sy * 8)
    line.To = vector(cx + sx * r, cy + sy * r)
    line.Visible = true
    if lab then place(lab, cx + sx * (r + 9), cy + sy * (r + 9) - 6) end
end

local function draw_debug(cx, cy, y)
    local okr, real = pcall(aa.get_lby_deg)
    local okf, fake = pcall(aa.get_fake_lby_deg)
    local okc, _, cam = pcall(client.get_camera_angles_deg)
    local r = ch_dr:get()
    if okc and type(cam) == "number" then
        dbg.view.From, dbg.view.To = vector(cx, cy - r - 4), vector(cx, cy - r + 4)
        dbg.view.Visible = true
        if okr then needle(dbg.real, dbg.rl, cx, cy, wrap(real - cam), r) else dbg.real.Visible = false; dbg.rl.Visible = false end
        if okf then needle(dbg.fake, dbg.fl, cx, cy, wrap(fake - cam), r) else dbg.fake.Visible = false; dbg.fl.Visible = false end
    else
        dbg.view.Visible, dbg.real.Visible, dbg.fake.Visible, dbg.rl.Visible, dbg.fl.Visible = false, false, false, false, false
    end
    local okch, chk = pcall(aa.get_choked_ticks)
    local d = dt_state()
    local man = manual()
    dbg.d1.Text = string.format("real %s  fake %s  delta %s", okr and string.format("%.0f", real) or "?",
        okf and string.format("%.0f", fake) or "?", (okr and okf) and string.format("%.0f", math.abs(wrap(fake - real))) or "?")
    dbg.d2.Text = string.format("side %s  lim %.0f  flip %dt  %s", st.inv and "R" or "L", tonumber(st.cur_lim) or 0,
        st.n - (st.flip_n or 0), my_state())
    dbg.d3.Text = string.format("phase %s  choke %s%s", tostring(st.phase or "regular"), okch and tostring(chk) or "?",
        man and string.format("  manual %d", man) or "")
    dbg.d4.Text = string.format("dt %s [%s]  def %s", d.text, d.src, (st.left or 0) > 0 and "on" or "-")
    for _, k in ipairs({ "d1", "d2", "d3", "d4" }) do
        dbg[k].Color = COL.dim
        place(dbg[k], cx, y)
        y = y + 12
    end
end

-- self-report: why the crosshair is hidden / the error that stops it, to the console and the feed (diag
-- what="crosshair"), once per change of reason (errors at most every 10s), so a missing crosshair explains itself
local ch_why, ch_err_at, ch_sent = nil, 0, {}
local function ch_report(why, err)
    if why == ch_why and not err then return end
    ch_why = why
    if why == "dead" then return end                 -- normal, every life
    if not err then                                  -- each reason once per load is enough
        if ch_sent[why] then return end
        ch_sent[why] = true
    end
    if err then
        local now = globals.realtime()
        if now < ch_err_at then return end
        ch_err_at = now + 10
    end
    if why ~= "drawn" or err then
        pcall(client.color_log, 255, 170, 90, "[CH] crosshair " .. (err and ("error: " .. tostring(err)) or ("hidden: " .. why)))
    end
    if st.push then pcall(st.push, { kind = "diag", what = "crosshair", why = why, err = err and tostring(err) or nil,
        drawing = type(Drawing), centered = centered }) end
end

local function ch_paint()
    local okl, alive = pcall(entity.is_alive, me())
    local okv, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if not ch_on:get() or not enabled:get() or not (okl and alive) or not okv or not vp then
        hide_all(ch); hide_all(dbg); hide_all(pb)
        ch_report((not ch_on:get() and "Indicators off") or (not enabled:get() and "AA disabled")
            or (not okl and ("is_alive failed: " .. tostring(alive))) or (not alive and "dead")
            or "no viewport")
        return
    end
    local cx, cy = vp.X / 2, vp.Y / 2
    local gap = ch_gap:get()
    local man = manual()

    -- arrows: manual yaw wins (red), else the side the desync sits on (accent), the other side dim
    local right = st.inv
    ch.l.Color = (man == -90) and COL.red or ((man == nil and not right) and COL.acc or COL.dim)
    ch.r.Color = (man == 90) and COL.red or ((man == nil and right) and COL.acc or COL.dim)
    place(ch.l, cx - gap, cy - 10)
    place(ch.r, cx + gap, cy - 10)
    if man == 0 then
        ch.b.Color = COL.red
        place(ch.b, cx, cy + 8)
    else
        ch.b.Visible = false
    end

    -- peek advisor on the arrows: colour = verdict for the nearest enemy, bar length = how long their desync
    -- side should still hold (full = at least 2x what our shot needs at this ping), word under the crosshair
    local pk = nil
    if ch_peek:get() and man == nil and st.peek_now then
        local okp, v = pcall(st.peek_now)
        if okp and v then
            pk = v
            local col = (v.verdict == "good" and COL.real) or (v.verdict == "ok" and COL.amb) or COL.red
            local y0 = cy + 13
            local half = math.max(0, gap - 8)
            pb.bg.From, pb.bg.To = vector(cx - half, y0), vector(cx + half, y0)
            pb.bg.Visible = true
            local f = half * v.frac
            if f >= 1 then
                pb.fg.From, pb.fg.To = vector(cx - f, y0), vector(cx + f, y0)
                pb.fg.Color = col
                pb.fg.Visible = true
            else
                pb.fg.Visible = false
            end
            ch.pk.Text = v.word
            ch.pk.Color = col
        end
    end
    if not pk then hide_all(pb); ch.pk.Visible = false end

    local y = cy + ch_y:get()
    if ch_name:get() then
        ch.t1.Text = "unsyk"
        ch.t1.Color = COL.acc
        place(ch.t1, cx, y)
        y = y + 12
    else
        ch.t1.Visible = false
    end

    if pk then
        place(ch.pk, cx, y)
        y = y + 12
    end

    local phase = tostring(st.phase or "regular")
    local word, col
    if man then
        word, col = (man == -90 and "MANUAL L") or (man == 90 and "MANUAL R") or "MANUAL B", COL.red
    elseif phase == "static" then
        word, col = "STATIC", COL.txt
    elseif phase == "noaa" then
        word, col = "NO AA", COL.amb
    elseif string.find(phase, "onshot", 1, true) then
        word, col = "ON-SHOT", COL.amb
    elseif phase == "defensive" then
        word, col = "DEFENSIVE", COL.cyan
    elseif phase == "dodge" then
        word, col = "DODGE", COL.cyan
    elseif st.fk and st.fk.on then
        word, col = st.fk.nofl and "FLICK NO LAG" or "FLICK", st.fk.nofl and COL.amb or COL.cyan
    else
        local m = ds_mode:get()
        word = (m == "Delayed" or m == "Random") and "DYNAMIC" or string.upper(tostring(m))
        col = COL.txt
    end
    ch.t2.Text = string.format("%s %d°", word, math.floor((tonumber(st.cur_lim) or 0) + 0.5))
    ch.t2.Color = col
    place(ch.t2, cx, y)
    y = y + 12

    local d = dt_state()
    local fl = globals.realtime() < dt_flash
    local on = fl or d.charge > 0 or d.menu == true
    ch.t3.Text = (d.charge > 0) and string.format("DT %d", d.charge) or "DT"
    ch.t3.Color = fl and COL.acc or (on and COL.txt or COL.dim)
    place(ch.t3, cx, y)
    y = y + 16

    if ch_dbg:get() then draw_debug(cx, cy, y) else hide_all(dbg) end
    ch_report("drawn")
end

client.set_event_callback("paint", function()
    local ok, err = pcall(ch_paint)
    if not ok then
        pcall(hide_all, ch)
        ch_report("error", err)
    end
end)

client.set_event_callback("shutdown", function()
    for _, set in ipairs({ ch, dbg, pb }) do
        for _, o in pairs(set) do pcall(function() o:Destroy() end) end
    end
end)
end

-- ======================================================================
-- DEBUG: log every hit you take + what your AA was doing + likely shooter
-- (no incoming-shot event exists, so this watches your health each tick)
-- ======================================================================
;(function() -- wrapped in an IIFE so its ~17 locals do not count against the main chunk's 200-local limit (Prometheus WrapInFunction needs the headroom)
local s_dbg   = tab:new_section("Debug", "Right")
local dbg_on  = s_dbg:new_toggle("Log hits taken", true)
local dbg_con = s_dbg:new_toggle("Console log", false)
local dbg_scr = s_dbg:new_toggle("Hit list overlay", false)

local dbg_log, dbg_stats = {}, {}
local DBG_MAX = 300
local dbg_prev_hp = nil
local dbg_total = 0

local function dbg_bucket(n)
    if n <= 1 then return "0-1t" elseif n <= 4 then return "2-4t" elseif n <= 10 then return "5-10t" end
    return "11t+"
end

local function dbg_count(group, key)
    dbg_stats[group] = dbg_stats[group] or {}
    dbg_stats[group][key] = (dbg_stats[group][key] or 0) + 1
end

-- the enemy whose view direction points most at us = likely shooter
local function find_shooter(my_pos)
    local best
    for _, e in ipairs(entity.get_enemies()) do
        if entity.is_alive(e) then
            local okp, ep = pcall(entity.get_player_position, e)
            local oka, pitch, yaw = pcall(entity.get_player_angles_deg, e)
            if okp and ep and oka and yaw then
                local to_me = my_pos - ep
                local flat = Vector3.new(to_me.X, 0, to_me.Z)
                if flat.Magnitude > 0.01 then
                    local d = yaw_to_dir(yaw)
                    local c = math.clamp(d:Dot(flat.Unit), -1, 1)
                    local err = math.deg(math.acos(c))
                    if not best or err < best.err then
                        local okw, wep = pcall(entity.get_player_weapon_name, e)
                        local oki, info = pcall(entity.get_info, e)
                        best = {
                            err = err, dist = to_me.Magnitude,
                            name = (oki and info and info.name) or tostring(e),
                            wep = okw and wep or "?", pitch = pitch, yaw = yaw,
                            desync = (oki and info and info.desync_delta) or nil,
                        }
                    end
                end
            end
        end
    end
    return best
end

local function dbg_record(dmg, hp)
    local okp, pos = pcall(entity.get_player_position, me())
    local sh = (okp and pos) and find_shooter(pos) or nil
    local _, real = pcall(aa.get_lby_deg)
    local _, fake = pcall(aa.get_fake_lby_deg)
    local _, inv = pcall(aa.get_inverter)
    local _, choke = pcall(aa.get_choked_ticks)
    local dtc = dt_state().text
    local flip_age = st.n - (st.flip_n or 0)
    local state = my_state()
    local side = (inv == true) and "R" or "L"

    dbg_total = dbg_total + 1
    local e = {
        n = dbg_total, t = os.clock(), dmg = dmg, hp = hp,
        phase = st.phase or "?", state = state, side = side,
        lim = st.cur_lim or 0, real = real, fake = fake,
        delta = (type(real) == "number" and type(fake) == "number") and math.abs(((fake - real) + 180) % 360 - 180) or nil,
        flip_age = flip_age, choke = choke, dt = dtc,
        mode = ds_mode:get(), mod = yaw_mod:get(), pitch = pitch_sel:get(),
        manual = manual(), shooter = sh, os_left = st.os_left or 0,
    }
    dbg_log[#dbg_log + 1] = e
    if #dbg_log > DBG_MAX then table.remove(dbg_log, 1) end

    dbg_count("phase", e.phase)
    dbg_count("state", e.state)
    dbg_count("side", e.side)
    dbg_count("flip age", dbg_bucket(flip_age))
    dbg_count("limit", tostring(math.floor(e.lim / 10) * 10) .. "+")
    if sh then dbg_count("weapon", sh.wep) end

    return e
end

local function dbg_fmt(e)
    local s = e.shooter
    local who = s and string.format("%s (%s) dist=%.0f aimerr=%.1f deg eyeP/Y=%.0f/%.0f%s", s.name, s.wep, s.dist, s.err, s.pitch or 0, s.yaw or 0,
        s.desync and string.format(" desync=%.0f", s.desync) or "") or "unknown"
    return string.format("#%d %.1fs -%dhp (hp %d) | by %s | phase=%s state=%s side=%s lim=%.0f real=%s fake=%s delta=%s flipAge=%dt choke=%s dt=%s inv=%s mod=%s pitch=%s manual=%s",
        e.n, e.t, e.dmg, e.hp, who, e.phase, e.state, e.side, e.lim,
        e.real and string.format("%.0f", e.real) or "?", e.fake and string.format("%.0f", e.fake) or "?",
        e.delta and string.format("%.0f", e.delta) or "?", e.flip_age, tostring(e.choke), tostring(e.dt),
        e.mode, e.mod, e.pitch, tostring(e.manual))
end

local function dbg_report()
    local out = {}
    out[#out + 1] = "=== unsyk debug report ==="
    out[#out + 1] = string.format("settings: inverter=%s delay=%d+%d mod=%s/%d lag=%d/%d%% pitch=%s limits(s/m/a/d)=%d/%d/%d/%d rnd=%s",
        ds_mode:get(), ds_delay:get(), ds_dr:get(), yaw_mod:get(), mod_amt:get(), lag_ticks:get(), lag_var:get(), pitch_sel:get(),
        lim_stand:get(), lim_move:get(), lim_air:get(), lim_duck:get(), tostring(lim_rnd:get()))
    out[#out + 1] = string.format("defensive=%s trig=%s int=%d dur=%d | onshot=%s mode=%s dur=%d",
        tostring(def_on:get()), def_trig:get(), def_int:get(), def_dur:get(), tostring(os_on:get()), os_mode:get(), os_len:get())
    out[#out + 1] = "total hits logged: " .. dbg_total
    for group, t in pairs(dbg_stats) do
        local parts = {}
        for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        out[#out + 1] = "by " .. group .. ": " .. table.concat(parts, ", ")
    end
    for _, e in ipairs(dbg_log) do out[#out + 1] = dbg_fmt(e) end
    return table.concat(out, "\n")
end

client.on_tick(function()
    if not dbg_on:get() then dbg_prev_hp = nil return end
    local ok, hp = pcall(entity.get_player_health, me())
    if not ok or type(hp) ~= "number" then return end
    if dbg_prev_hp and enabled:get() then
        if hp > 0 and hp < dbg_prev_hp then
            local e = dbg_record(math.floor(dbg_prev_hp - hp), math.floor(hp))
            if dbg_con:get() then client.color_log(255, 160, 60, "[DBG][hit] " .. dbg_fmt(e)) end
        elseif hp <= 0 and dbg_prev_hp > 0 then
            local e = dbg_record(math.floor(dbg_prev_hp), 0)
            if dbg_con:get() then client.color_log(255, 60, 60, "[DBG][DEATH] " .. dbg_fmt(e)) end
        end
    end
    dbg_prev_hp = hp
end)

s_dbg:new_button("Print report", function()
    -- one log line per entry, into the cheat's Lua console (select + Ctrl+C to copy)
    client.color_log(120, 200, 255, "[DBG] ----- BEGIN REPORT -----")
    for line in string.gmatch(dbg_report(), "[^\n]+") do client.log("[DBG] " .. line) end
    client.color_log(120, 200, 255, "[DBG] ----- END REPORT -----")
end)
s_dbg:new_button("Clear hits", function()
    dbg_log, dbg_stats, dbg_total = {}, {}, 0
    client.log("[debug] cleared")
end)

local dbg_lines = {}
for i = 1, 6 do
    local t = Drawing.new("Text")
    t.Size = 13
    t.Font = Drawing.Fonts.Plex
    t.Outline = true
    t.Color = color(255, 200, 120)
    t.Visible = false
    dbg_lines[i] = t
end

client.set_event_callback("paint", function()
    local show = dbg_on:get() and dbg_scr:get() and enabled:get()
    for i = 1, #dbg_lines do
        local line = dbg_lines[i]
        local e = show and dbg_log[#dbg_log - (i - 1)]
        if e then
            local s = e.shooter
            line.Text = string.format("#%d -%d | %s %s aim%.0f | %s %s %s lim%.0f flip%dt", e.n, e.dmg,
                s and s.name or "?", s and s.wep or "", s and s.err or 0, e.phase, e.state, e.side, e.lim, e.flip_age)
            line.Position = vector(20, 530 + (i - 1) * 16)
            line.Visible = true
        else
            line.Visible = false
        end
    end
end)

client.set_event_callback("shutdown", function()
    for _, l in ipairs(dbg_lines) do pcall(function() l:Destroy() end) end
end)
end)() -- end dbg IIFE

-- ======================================================================
-- ENEMY INTEL: track the N nearest enemies, read their AA pattern, predict next flip
-- ======================================================================
local s_in     = tab:new_section("Enemy intel", "Right")
local in_on    = s_in:new_toggle("Track enemies", true)
local in_cnt   = s_in:new_slider("Max tracked", 1, 4, 2, 0, "")
local in_panel = s_in:new_toggle("Overlay", false)

local intel = {}        -- [enemy] = record
local intel_order = {}  -- records currently tracked, nearest first
local intel_n = 0

local function wrap180(a) return ((a + 180) % 360) - 180 end

local function new_rec(name)
    return {
        name = name, ticks = 0, dist = 0, wep = "?", state = "?", speed = 0, aimerr = 180,
        last_yaw = nil, last_pitch = nil, last_feet = nil,
        ema_dy = 0, ema_des = 0, max_dy = 0,
        side = 0, last_flip = 0, flips = 0, ints = {},
        def_count = 0, last_def = 0, pitch_flicks = 0,
        p_down = 0, p_up = 0, p_mid = 0, lby_breaks = 0,
        yaw_now = 0, pitch_now = 0, des_now = 0,
    }
end

st.ird = setmetatable({}, { __mode = "k" })   -- [enemy entity] = this tick's API reads (intel_update)
-- per-tick caches shared by the tick listeners (each enemy's position read once per tick; a name never changes
-- for an entity, so it is read once). Both return (ok, value) like the pcall they replace. Not for paint callbacks.
st.epos_c = setmetatable({}, { __mode = "k" })
st.epos = function(e)
    local c = st.epos_c[e]
    local tk = UNSYK_PROF.tick
    if c and c.tk == tk then return c.ok, c.p end
    if not c then c = {}; st.epos_c[e] = c end
    c.tk = tk
    c.ok, c.p = pcall(entity.get_player_position, e)
    return c.ok, c.p
end
st.ename_c = setmetatable({}, { __mode = "k" })
st.ename = function(e)
    local n = st.ename_c[e]
    if n then return true, n end
    local ok, v = pcall(entity.get_player_name, e)
    if ok and type(v) == "string" and v ~= "" then st.ename_c[e] = v end
    return ok, v
end
local function intel_update(rec, e, dist, pos, mypos, now)
    now = now or intel_n
    -- API reads once per enemy per tick (intel_main and the resolver both update the nearest enemies), each
    -- timed for the perf diag. The weapon name changes rarely: re-read every 16 ticks.
    local tk = UNSYK_PROF.tick
    local R = st.ird[e]
    if not R or R.tk ~= tk then
        local c, add, sub = os.clock, UNSYK_PROF.add, UNSYK_PROF.sub
        R = R or {}
        st.ird[e] = R
        R.tk = tk
        local t0 = c()
        R.oka, R.pitch, R.yaw = pcall(entity.get_player_angles_deg, e)
        local t1 = c()
        add(sub("api.angles"), t1 - t0)
        R.oki, R.info = pcall(entity.get_info, e)
        local t2 = c()
        add(sub("api.get_info"), t2 - t1)
        R.okn, R.anim = pcall(entity.get_anim_state, e)
        local t3 = c()
        add(sub("api.anim_state"), t3 - t2)
        if not R.wtk or tk - R.wtk >= 16 then
            R.wtk = tk
            R.okw, R.wep = pcall(entity.get_player_weapon_name, e)
            add(sub("api.weapon_name"), c() - t3)
        end
        local inf = R.oki and type(R.info) == "table" and R.info or nil
        R.lby, R.tw = nil, nil
        if not (inf and tonumber(inf.lby)) then
            local t = c()
            local okl, l = pcall(entity.get_player_lby_deg, e)
            add(sub("api.lby"), c() - t)
            if okl then R.lby = tonumber(l) end
        end
        if not (inf and tonumber(inf.twist_deg)) then
            local t = c()
            local okt, v = pcall(entity.get_player_twist_deg, e)
            add(sub("api.twist"), c() - t)
            if okt then R.tw = tonumber(v) end
        end
    end
    local oka, pitch, yaw = R.oka, R.pitch, R.yaw
    local oki, info = R.oki, R.info
    local okn, anim = R.okn, R.anim
    local okw, wep = R.okw, R.wep

    rec.ticks = rec.ticks + 1
    rec.dist = dist
    if okw and wep then rec.wep = wep end
    if oki and info then
        rec.state = info.state or rec.state
        rec.speed = info.speed or 0
        -- extra reads for the candidate resolver (all optional: nil when the API does not give them)
        rec.lby = tonumber(info.lby)
        rec.dd = tonumber(info.desync_delta)
        rec.tw = tonumber(info.twist_deg)
        rec.hp = tonumber(info.health)
        local duck = info.is_crouching == true
        if rec.duck ~= nil and duck ~= rec.duck then
            -- fake duck: 3+ crouch changes inside ~1.2s (77 ticks) -> flagged for ~1.5s
            local dk = rec.dk or {}
            rec.dk = dk
            dk[#dk + 1] = now
            while dk[1] and now - dk[1] > 77 do table.remove(dk, 1) end
            if #dk >= 3 then
                rec.fd_until = now + 96
                rec.dk = {}
            end
        end
        rec.duck = duck
    end
    if rec.lby == nil then rec.lby = R.lby end
    if rec.tw == nil then rec.tw = R.tw end

    if oka and yaw and pitch then
        -- yaw ring (circular mean = their centre while they jitter) + yaw jitter detection
        local yc, ys = rec.yc or {}, rec.ys or {}
        rec.yc, rec.ys = yc, ys
        local yi = (rec.yi or 0) % 16 + 1
        rec.yi = yi
        yc[yi], ys[yi] = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
        local sc_, ss_ = 0, 0
        for i = 1, #yc do sc_ = sc_ + yc[i]; ss_ = ss_ + ys[i] end
        rec.yref = (sc_ * sc_ + ss_ * ss_ > 0.01) and math.deg((math.atan2 or math.atan)(ss_, sc_)) or yaw
        if rec.last_yaw then
            local d = wrap180(yaw - rec.last_yaw)
            if math.abs(d) >= 25 then
                local sg = d > 0 and 1 or -1
                if rec.ysg and rec.ysg ~= sg then
                    rec.yj3, rec.yj2, rec.yj1 = rec.yj2, rec.yj1, now
                end
                rec.ysg = sg
            end
        end
        rec.yjit = rec.yj3 ~= nil and now - rec.yj3 <= 20
        -- pitch ring (the resolver forces their usual pitch when they flick away from it)
        local ph = rec.ph or {}
        rec.ph = ph
        local pi_ = (rec.pi or 0) % 16 + 1
        rec.pi = pi_
        ph[pi_] = pitch
        rec.yaw_now, rec.pitch_now = yaw, pitch
        if rec.last_yaw then
            local dy = math.abs(wrap180(yaw - rec.last_yaw))
            rec.ema_dy = rec.ema_dy * 0.97 + dy * 0.03
            if dy > rec.max_dy then rec.max_dy = dy end
            if dy > 120 then
                rec.def_count = rec.def_count + 1
                rec.last_def = now
            end
            local dp = math.abs(pitch - rec.last_pitch)
            if dp > 60 then rec.pitch_flicks = rec.pitch_flicks + 1 end
        end
        rec.last_yaw, rec.last_pitch = yaw, pitch

        if pitch > 45 then rec.p_down = rec.p_down + 1
        elseif pitch < -45 then rec.p_up = rec.p_up + 1
        else rec.p_mid = rec.p_mid + 1 end

        -- how directly are they looking at us (same yaw convention as the arrows)
        local to_me = mypos - pos
        local flat = Vector3.new(to_me.X, 0, to_me.Z)
        if flat.Magnitude > 0.01 then
            local c = math.clamp(yaw_to_dir(yaw):Dot(flat.Unit), -1, 1)
            rec.aimerr = math.deg(math.acos(c))
        end
    end

    if okn and anim then
        -- anim.desync reads a constant (84) for most players, so derive it ourselves:
        -- signed angle from displayed eye yaw to goal feet yaw
        local eye = anim.eye_angles_y or yaw
        local des = 0
        if anim.goal_feet_yaw and eye then des = wrap180(anim.goal_feet_yaw - eye) end
        rec.des_now = des
        rec.ema_des = rec.ema_des * 0.97 + math.abs(des) * 0.03
        local side = 0
        if des > 10 then side = 1 elseif des < -10 then side = -1 end
        if side ~= 0 then
            if rec.side == 0 then
                rec.last_flip = now
            elseif side ~= rec.side then
                local interval = now - rec.last_flip
                rec.ints[#rec.ints + 1] = interval
                if #rec.ints > 12 then table.remove(rec.ints, 1) end
                rec.flips = rec.flips + 1
                rec.last_flip = now
            end
            rec.side = side
        end

        local feet = anim.goal_feet_yaw
        if feet then
            if rec.last_feet and rec.speed < 5 then
                if math.abs(wrap180(feet - rec.last_feet)) > 35 then rec.lby_breaks = rec.lby_breaks + 1 end
            end
            rec.last_feet = feet
        end
    end
end

-- classify their desync flip pattern + predict the next flip
local function intel_pattern(rec, now)
    now = now or intel_n
    local n = #rec.ints
    if n < 4 then return "learning", nil, nil end
    local sum = 0
    for i = 1, n do sum = sum + rec.ints[i] end
    local mean = sum / n
    local var = 0
    for i = 1, n do var = var + (rec.ints[i] - mean) * (rec.ints[i] - mean) end
    local std = math.sqrt(var / n)

    local label
    if mean <= 2.3 then label = "per-tick jitter"
    elseif std <= 1.2 then label = string.format("fixed ~%.0ft", mean)
    else label = string.format("variable %.0f+-%.0ft", mean, std) end

    local since = now - rec.last_flip
    local next_in = math.max(0, math.floor(mean - since + 0.5))
    local next_side = -rec.side
    return label, next_in, next_side
end

local function intel_main()
    if not in_on:get() then return end
    intel_n = intel_n + 1
    local okp, mypos = pcall(entity.get_player_position, me())
    if not okp or not mypos then return end

    local cands = {}
    for _, e in ipairs(entity.get_enemies()) do
        if entity.is_alive(e) then
            local ok, p = st.epos(e)
            if ok and p then
                cands[#cands + 1] = { e = e, d = (p - mypos).Magnitude, pos = p, used = false }
            end
        end
    end

    intel_order = {}
    local want = math.min(in_cnt:get(), #cands)
    for _ = 1, want do
        local best
        for _, c in ipairs(cands) do
            if not c.used and (not best or c.d < best.d) then best = c end
        end
        if not best then break end
        best.used = true
        local rec = intel[best.e]
        if not rec then
            local oki, info = pcall(entity.get_info, best.e)
            rec = new_rec((oki and info and info.name) or tostring(best.e))
            intel[best.e] = rec
        end
        intel_update(rec, best.e, best.d, best.pos, mypos)
        intel_order[#intel_order + 1] = rec
    end
end
client.on_tick(intel_main)

local function intel_lines(rec)
    local label, next_in, next_side = intel_pattern(rec)
    local total = rec.p_down + rec.p_up + rec.p_mid
    local function pct(v) return total > 0 and math.floor(v / total * 100) or 0 end
    local l1 = string.format("%s | %.0fst | %s | %s | aim@me %.0f deg", rec.name, rec.dist, rec.wep, rec.state, rec.aimerr)
    local l2 = string.format("desync %.0f (avg %.0f) side %s | flips %d | %s%s", rec.des_now, rec.ema_des,
        rec.side > 0 and "R" or (rec.side < 0 and "L" or "?"), rec.flips, label,
        next_in and string.format(" -> %s in ~%dt", next_side > 0 and "R" or "L", next_in) or "")
    local l3 = string.format("yaw d/tick %.0f (max %.0f) | defensive %d | pitch flicks %d | P down/up/mid %d/%d/%d%% | lby breaks %d",
        rec.ema_dy, rec.max_dy, rec.def_count, rec.pitch_flicks, pct(rec.p_down), pct(rec.p_up), pct(rec.p_mid), rec.lby_breaks)
    return l1, l2, l3
end

s_in:new_button("Print intel", function()
    client.color_log(120, 200, 255, "[INTEL] ----- BEGIN -----")
    for _, rec in pairs(intel) do
        local a, b, c = intel_lines(rec)
        client.log("[INTEL] " .. a)
        client.log("[INTEL]   " .. b)
        client.log("[INTEL]   " .. c)
        client.log("[INTEL]   flip intervals: " .. table.concat(rec.ints, ","))
    end
    client.color_log(120, 200, 255, "[INTEL] ----- END -----")
end)
s_in:new_button("Reset intel", function()
    intel, intel_order = {}, {}
    client.log("[INTEL] reset")
end)

local in_lines = {}
for i = 1, 12 do
    local t = Drawing.new("Text")
    t.Size = 13
    t.Font = Drawing.Fonts.Plex
    t.Outline = true
    t.Color = color(150, 220, 255)
    t.Visible = false
    in_lines[i] = t
end

client.set_event_callback("paint", function()
    local show = in_on:get() and in_panel:get()
    local okw, w = pcall(render.screen_size)
    local x = (okw and w or 1280) - 560
    local idx = 0
    for _, rec in ipairs(intel_order) do
        if show and idx + 3 <= #in_lines then
            local a, b, c = intel_lines(rec)
            local lines = { a, b, c }
            for k = 1, 3 do
                idx = idx + 1
                local t = in_lines[idx]
                t.Text = lines[k]
                t.Color = (k == 1) and color(255, 255, 255) or color(150, 220, 255)
                t.Position = vector(x, 140 + (idx - 1) * 15 + math.floor((idx - 1) / 3) * 6)
                t.Visible = true
            end
        end
    end
    for i = idx + 1, #in_lines do in_lines[i].Visible = false end
end)

client.set_event_callback("shutdown", function()
    for _, l in ipairs(in_lines) do pcall(function() l:Destroy() end) end
end)

-- ======================================================================
-- PEEK ADVISOR: uses enemy intel to say when a peek is likely safe / good
-- ======================================================================
local s_pk     = tab:new_section("Peek advisor", "Left")
local pk_on    = s_pk:new_toggle("Overlay", false)
local pk_view  = s_pk:new_toggle("View-angle check", false)
local pk_aim   = s_pk:new_slider("Look-away angle", 5, 90, 25, 0, "°")
local pk_def   = s_pk:new_slider("Defensive cooldown", 0, 128, 64, 0, "t")
local pk_extra = s_pk:new_slider("Safety margin", 0, 8, 2, 0, "t")

local pk_text = Drawing.new("Text")
pk_text.Size = 16
pk_text.Font = Drawing.Fonts.Plex
pk_text.Outline = true
pk_text.Visible = false

local function peek_eval(rec)
    local reasons = {}
    local score = 0

    local okl, lat = pcall(client.latency)
    local lat_ticks = (okl and type(lat) == "number") and (lat / globals.tickinterval()) or 4
    local label, next_in = intel_pattern(rec)

    -- 1) are they looking at us? (pre-aim = bad)
    -- off by default: rage players show their AA angles, not their real aim (silent aim)
    if pk_view:get() then
        if rec.aimerr > pk_aim:get() then
            score = score + 1
            reasons[#reasons + 1] = string.format("not looking at you (%.0f deg)", rec.aimerr)
        else
            score = score - 1
            reasons[#reasons + 1] = string.format("AIMING AT YOU (%.0f deg)", rec.aimerr)
        end
    end

    -- 2) recent defensive burst = their angles/tickbase are weird, wait it out
    local since_def = intel_n - rec.last_def
    if rec.def_count > 0 and since_def < pk_def:get() then
        score = score - 1
        reasons[#reasons + 1] = string.format("defensive %dt ago", since_def)
    end

    -- 3) is their desync side stable long enough for our shot to land?
    if next_in then
        local need = lat_ticks + pk_extra:get()
        if label == "per-tick jitter" then
            reasons[#reasons + 1] = "per-tick jitter (no stable window)"
        elseif next_in > need then
            score = score + 1
            reasons[#reasons + 1] = string.format("side %s stable ~%dt (need %.0f)", rec.side > 0 and "R" or "L", next_in, need)
        else
            score = score - 1
            reasons[#reasons + 1] = string.format("flip in ~%dt (need %.0f)", next_in, need)
        end
    else
        reasons[#reasons + 1] = "pattern still learning"
    end
    return score, reasons
end

-- best possible score is 2 with the view-angle check, else 1 (GOOD used to need 2, so it never showed by default)
st.peek_verdict = function(score)
    if score >= (pk_view:get() and 2 or 1) then return "good" end
    if score >= 0 then return "ok" end
    return "wait"
end

-- for the crosshair: verdict + bar fraction + short word for the nearest tracked enemy
st.peek_now = function()
    local rec = intel_order[1]
    if not (in_on:get() and rec) then return nil end
    local score = peek_eval(rec)
    local label, next_in = intel_pattern(rec)
    local okl, lat = pcall(client.latency)
    local need = ((okl and type(lat) == "number") and (lat / globals.tickinterval()) or 4) + pk_extra:get()
    local verdict = st.peek_verdict(score)
    local frac, word = 0, (verdict == "good" and "PEEK") or (verdict == "ok" and "PEEK?") or "WAIT"
    if label == "learning" then
        word = word .. " ..."
    elseif label == "per-tick jitter" then
        word = word .. " jitter"
    elseif next_in then
        frac = math.min(1, next_in / math.max(need * 2, 1))
        word = word .. string.format(" %dt", next_in)
    end
    return { verdict = verdict, frac = frac, word = word .. "  " .. string.sub(tostring(rec.name), 1, 12) }
end

client.set_event_callback("paint", function()
    local rec = intel_order[1]
    if not (pk_on:get() and in_on:get() and rec) then
        pk_text.Visible = false
        return
    end
    local score, reasons = peek_eval(rec)
    local verdict, col
    local v = st.peek_verdict(score)
    if v == "good" then verdict, col = "PEEK: GOOD", color(80, 255, 120)
    elseif v == "ok" then verdict, col = "PEEK: OK", color(255, 220, 80)
    else verdict, col = "PEEK: WAIT", color(255, 80, 80) end

    local okw, w = pcall(render.screen_size)
    pk_text.Text = verdict .. " vs " .. rec.name .. "  [" .. table.concat(reasons, " | ") .. "]"
    pk_text.Color = col
    pk_text.Position = vector((okw and w or 1280) - 760, 120)
    pk_text.Visible = true
end)

client.set_event_callback("shutdown", function()
    pcall(function() pk_text:Destroy() end)
end)

-- ======================================================================
-- SHOT LOG: your own shots (hit/miss + reason) with the target's AA intel
-- ======================================================================
local s_sh   = tab:new_section("Shot log", "Left")
local sh_on  = s_sh:new_toggle("Log my shots", true)
local sh_log = {}
local sh_cnt = { fire = 0, hit = 0, miss = 0 }
local sh_reasons = {}

local function find_rec(target)
    if target == nil then return nil end
    if intel[target] then return intel[target] end
    for ent, rec in pairs(intel) do
        local ok, slot = pcall(entity.get_player_slot, ent)
        if ok and slot ~= nil and slot == target then return rec end
    end
    -- aim events identify the target with a number that is not the slot; the name lookup accepts it
    local okn, name = pcall(entity.get_player_name, target)
    if okn and type(name) == "string" then
        for _, rec in pairs(intel) do
            if rec.name == name then return rec end
        end
    end
    return nil
end

local function rec_summary(rec)
    if not rec then return "no intel (not among nearest)" end
    local label, next_in, next_side = intel_pattern(rec)
    return string.format("%s dist=%.0f des=%.0f side=%s pat=%s%s", rec.name, rec.dist, rec.des_now,
        rec.side > 0 and "R" or (rec.side < 0 and "L" or "?"), label,
        next_in and string.format(" next=%s in %dt", next_side > 0 and "R" or "L", next_in) or "")
end

local function sh_push(kind, e, extra)
    local rec = find_rec(e and e.target)
    local line = string.format("[SHOT][%s] hitbox=%s dmg=%s %s | %s", kind, tostring(e and e.hitbox), tostring(e and e.damage),
        extra or "", rec_summary(rec))
    sh_log[#sh_log + 1] = line
    if #sh_log > 200 then table.remove(sh_log, 1) end
    if sh_on:get() then
        client.color_log(kind == "HIT" and 120 or 255, kind == "HIT" and 255 or 140, 120, line)
    end
end

client.set_event_callback("aim_fire", function(e)
    if not sh_on:get() then return end
    sh_cnt.fire = sh_cnt.fire + 1
end)
client.set_event_callback("aim_hit", function(e)
    if not sh_on:get() then return end
    sh_cnt.hit = sh_cnt.hit + 1
    sh_push("HIT", e, "bt=" .. tostring(e and e.backtrack_ticks))
end)
client.set_event_callback("aim_miss", function(e)
    if not sh_on:get() then return end
    local r = tostring(e and e.reason)
    -- "death (local)" = we died while the shot was in flight; not a real miss
    if string.find(r, "death", 1, true) then
        sh_cnt.died = (sh_cnt.died or 0) + 1
        return
    end
    sh_cnt.miss = sh_cnt.miss + 1
    sh_reasons[r] = (sh_reasons[r] or 0) + 1
    sh_push("MISS", e, "reason=" .. r)
end)

s_sh:new_button("Print shots", function()
    local parts = {}
    for k, v in pairs(sh_reasons) do parts[#parts + 1] = k .. "=" .. v end
    client.color_log(120, 200, 255, string.format("[SHOT] fired=%d hit=%d miss=%d | miss reasons: %s",
        sh_cnt.fire, sh_cnt.hit, sh_cnt.miss, table.concat(parts, ", ")))
    for _, l in ipairs(sh_log) do client.log(l) end
end)
s_sh:new_button("Clear shots", function()
    sh_log, sh_reasons, sh_cnt = {}, {}, { fire = 0, hit = 0, miss = 0 }
end)

-- ======================================================================
-- FINE DATA (v3): per-tick timeline before each hit, ping-aware, all nearby enemies,
-- crosstab stats and CSV dump. Replaces the one-line [DBG][hit] output.
-- ======================================================================
local s_fd     = tab:new_section("Fine data", "Left")
local fd_on    = s_fd:new_toggle("Record timelines", true)
local fd_print = s_fd:new_toggle("Console summary", true)
local fd_tl    = s_fd:new_toggle("Console timeline", false)
local fd_rows  = s_fd:new_slider("Timeline length", 8, 32, 16, 0, "t")
local fd_dumpn = s_fd:new_slider("Print count", 1, 20, 3, 0, "")
local fd_csvn  = s_fd:new_slider("CSV count", 1, 150, 30, 0, "")

local fd_ring = {}
local FD_RING_MAX = 32
local fd_hits = {}
local fd_stats = {}
local fd_prev_hp = nil
local fd_total = 0

local function fd_tick_ms()
    local ok, ti = pcall(globals.tickinterval)
    return ((ok and type(ti) == "number") and ti or 0.015625) * 1000
end

-- record my AA state every tick (registered after the main AA listener, so st is current)
client.on_tick(function()
    if not enabled:get() then return end
    local okr, real = pcall(aa.get_lby_deg)
    local okf, fake = pcall(aa.get_fake_lby_deg)
    local okc, chk = pcall(aa.get_choked_ticks)
    local oki, info = pcall(entity.get_info, me())
    local row = {
        n = st.n, phase = st.phase or "?", side = st.inv and "R" or "L",
        lim = st.cur_lim or 0, man = manual(), state = my_state(),
        real = okr and real or nil, fake = okf and fake or nil,
        choke = okc and chk or nil,
        speed = (oki and info and info.speed) or 0,
        shot = st.os_left or 0,
        roll = st.roll_cur, fp = st.fp_cur,
    }
    fd_ring[#fd_ring + 1] = row
    if #fd_ring > FD_RING_MAX then table.remove(fd_ring, 1) end
end)

local function fd_bucket(v, cuts, labels)
    for i = 1, #cuts do
        if v <= cuts[i] then return labels[i] end
    end
    return labels[#labels]
end

local function fd_count(key)
    fd_stats[key] = (fd_stats[key] or 0) + 1
end

local function fd_nearest_enemies(mypos, k)
    local cands = {}
    for _, e in ipairs(entity.get_enemies()) do
        if entity.is_alive(e) then
            local ok, p = st.epos(e)
            if ok and p then cands[#cands + 1] = { e = e, d = (p - mypos).Magnitude, pos = p, used = false } end
        end
    end
    local out = {}
    for _ = 1, math.min(k, #cands) do
        local best
        for _, c in ipairs(cands) do
            if not c.used and (not best or c.d < best.d) then best = c end
        end
        if not best then break end
        best.used = true
        local okw, wep = pcall(entity.get_player_weapon_name, best.e)
        local oks, scoped = pcall(entity.is_player_scoped, best.e)
        local oki, info = pcall(entity.get_info, best.e)
        local rec = intel[best.e]
        local label, next_in, next_side
        if rec then label, next_in, next_side = intel_pattern(rec) end
        out[#out + 1] = {
            name = (oki and info and info.name) or tostring(best.e),
            wep = okw and wep or "?", scoped = oks and scoped or false, dist = best.d,
            des = rec and rec.des_now or nil, pat = label,
            side = rec and rec.side or 0,
            nxt = next_in and string.format("%s in %dt", next_side > 0 and "R" or "L", next_in) or nil,
            def_ago = rec and rec.def_count > 0 and (intel_n - rec.last_def) or nil,
        }
    end
    return out
end

local function fd_record(dmg, hp_before, hp_after)
    local tms = fd_tick_ms()
    local okl, lat = pcall(client.latency)
    local ping_ms = (okl and type(lat) == "number") and lat * 1000 or 0
    local okp, mypos = pcall(entity.get_player_position, me())
    local rows = {}
    local take = math.min(fd_rows:get(), #fd_ring)
    for i = #fd_ring - take + 1, #fd_ring do rows[#rows + 1] = fd_ring[i] end
    local last = rows[#rows]

    local flip_age = st.n - (st.flip_n or 0)
    local dtc = dt_state().text
    fd_total = fd_total + 1
    local e = {
        n = fd_total, t = os.clock(), dmg = dmg, hp_before = hp_before, hp_after = hp_after,
        ping = ping_ms, tms = tms, rows = rows, last = last, flip_age = flip_age, dt = dtc,
        enemies = (okp and mypos) and fd_nearest_enemies(mypos, 4) or {},
        settings = string.format("inv=%s mod=%s lag=%d lims=%d/%d/%d/%d def=%s os=%s roll=%s fp=%s",
            ds_mode:get(), yaw_mod:get(), lag_ticks:get(), lim_stand:get(), lim_move:get(), lim_air:get(), lim_duck:get(),
            tostring(def_on:get()), tostring(os_on:get()), st.rp.ui.roll:get(), st.rp.ui.fp:get()),
    }
    fd_hits[#fd_hits + 1] = e
    if #fd_hits > 150 then table.remove(fd_hits, 1) end
    if st.etrace_hit then pcall(st.etrace_hit) end

    if last then
        fd_count("state=" .. last.state)
        fd_count("phase=" .. last.phase)
        fd_count("manual=" .. (last.man ~= nil and "yes" or "no"))
        fd_count("flipAge=" .. fd_bucket(flip_age, { 1, 4, 10 }, { "0-1t", "2-4t", "5-10t", "11t+" }))
        fd_count("limit=" .. fd_bucket(last.lim, { 59, 79 }, { "<60", "60-79", "80+" }))
        fd_count("speed=" .. fd_bucket(last.speed, { 5, 60 }, { "still", "slow", "fast" }))
        fd_count("choke=" .. ((last.choke or 0) > 0 and "yes" or "no"))
    end
    fd_count("dmg=" .. (dmg >= 90 and "oneshot" or "chip"))
    fd_count("ping=" .. fd_bucket(ping_ms, { 40, 90, 150 }, { "<40", "40-90", "90-150", "150+" }))
    return e
end

local function fd_row_text(r, ms_before, mark)
    return string.format("   %s-%4dms  %-17s state=%-5s side=%s lim=%2.0f man=%s real=%s fake=%s choke=%s spd=%.0f%s",
        mark and ">" or " ", ms_before, r.phase, r.state, r.side, r.lim, tostring(r.man),
        r.real and string.format("%.0f", r.real) or "?", r.fake and string.format("%.0f", r.fake) or "?",
        tostring(r.choke), r.speed or 0, mark and "  <== shot fired ~here (ping)" or "")
end

-- print only rows where something changed, plus the shot-fired row and the final row
local function fd_print_hit(e, emit)
    emit(string.format("[HIT #%d] -%d (%d -> %d hp) | ping=%.0fms | flipAge=%dt | dt=%s | %s",
        e.n, e.dmg, e.hp_before, e.hp_after, e.ping, e.flip_age, tostring(e.dt), e.settings))
    if #e.enemies > 0 then
        for i, en in ipairs(e.enemies) do
            emit(string.format("   enemy%d: %s | %s%s | %.0fst | des=%s side=%s pat=%s%s%s", i, en.name, en.wep,
                en.scoped and " (scoped)" or "", en.dist, en.des and string.format("%.0f", en.des) or "?",
                en.side > 0 and "R" or (en.side < 0 and "L" or "?"), en.pat or "n/a",
                en.nxt and (" next " .. en.nxt) or "", en.def_ago and (" def " .. en.def_ago .. "t ago") or ""))
        end
    end
    local shot_idx = nil
    local want = e.ping
    for i = 1, #e.rows do
        local ms = (e.last.n - e.rows[i].n) * e.tms
        if ms >= want and (not shot_idx or ms < (e.last.n - e.rows[shot_idx].n) * e.tms) then shot_idx = i end
    end
    local prev
    for i = 1, #e.rows do
        local r = e.rows[i]
        local changed = (not prev) or r.phase ~= prev.phase or r.side ~= prev.side or r.state ~= prev.state
            or r.man ~= prev.man or math.floor(r.lim / 10) ~= math.floor(prev.lim / 10)
        if changed or i == shot_idx or i == #e.rows then
            emit(fd_row_text(r, math.floor((e.last.n - r.n) * e.tms), i == shot_idx))
        end
        prev = r
    end
end

client.on_tick(function()
    if not fd_on:get() then fd_prev_hp = nil return end
    local ok, hp = pcall(entity.get_player_health, me())
    if not ok or type(hp) ~= "number" then return end
    if fd_prev_hp and enabled:get() and hp < fd_prev_hp then
        local e = fd_record(math.floor(fd_prev_hp - hp), math.floor(fd_prev_hp), math.floor(math.max(hp, 0)))
        if fd_tl:get() then
            fd_print_hit(e, function(line) client.color_log(255, 170, 70, line) end)
        elseif fd_print:get() then
            local r = e.last or {}
            local en = e.enemies[1]
            client.color_log(255, 170, 70, string.format(
                "[HIT #%d] -%d (%d->%d) ping=%.0f %s spd=%.0f %s side=%s lim=%.0f flip=%dt dt=%s | near: %s %s %.0fst %s",
                e.n, e.dmg, e.hp_before, e.hp_after, e.ping, tostring(r.state), r.speed or 0, tostring(r.phase),
                tostring(r.side), r.lim or 0, e.flip_age, tostring(e.dt),
                en and en.name or "-", en and en.wep or "", en and en.dist or 0, en and (en.pat or "") or ""))
        end
    end
    fd_prev_hp = hp
end)

s_fd:new_button("Print stats", function()
    client.color_log(120, 200, 255, "[FD] ----- STATS (" .. fd_total .. " hits) -----")
    local keys = {}
    for k, _ in pairs(fd_stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do client.log(string.format("[FD] %-22s %d", k, fd_stats[k])) end
end)

s_fd:new_button("Print timelines", function()
    client.color_log(120, 200, 255, "[FD] ----- LAST " .. fd_dumpn:get() .. " HITS (of " .. #fd_hits .. ") -----")
    for i = math.max(1, #fd_hits - fd_dumpn:get() + 1), #fd_hits do
        fd_print_hit(fd_hits[i], function(line) client.log("[FD] " .. line) end)
    end
    client.color_log(120, 200, 255, "[FD] ----- END -----")
end)

s_fd:new_button("Print CSV", function()
    client.color_log(120, 200, 255, "[CSV] n,dmg,hp_before,ping_ms,state,speed,phase,side,limit,manual,flip_age,choke,dt,real,fake,e1_name,e1_wep,e1_dist,e1_scoped,e2_name,e2_wep,e2_dist,e2_scoped")
    for i = math.max(1, #fd_hits - fd_csvn:get() + 1), #fd_hits do
        local e = fd_hits[i]
        local r = e.last or {}
        local en1, en2 = e.enemies[1] or {}, e.enemies[2] or {}
        client.log(string.format("[CSV] %d,%d,%d,%.0f,%s,%.0f,%s,%s,%.0f,%s,%d,%s,%s,%s,%s,%s,%s,%.0f,%s,%s,%s,%.0f,%s",
            e.n, e.dmg, e.hp_before, e.ping, tostring(r.state), r.speed or 0, tostring(r.phase), tostring(r.side), r.lim or 0,
            tostring(r.man), e.flip_age, tostring(r.choke), tostring(e.dt),
            r.real and string.format("%.0f", r.real) or "?", r.fake and string.format("%.0f", r.fake) or "?",
            tostring(en1.name), tostring(en1.wep), en1.dist or 0, tostring(en1.scoped),
            tostring(en2.name), tostring(en2.wep), en2.dist or 0, tostring(en2.scoped)))
    end
end)

s_fd:new_button("Clear data", function()
    fd_hits, fd_stats, fd_total = {}, {}, 0
    client.log("[FD] cleared")
end)

client.color_log(120, 255, 160, "[unsyk] v5 core loaded")

-- ======================================================================
-- DISCORD EXPORT: post debug data to YOUR OWN webhook so you can copy it from Discord.
-- The URL is typed into the menu (saved in the script database on your machine), never hardcoded.
-- ======================================================================
local HttpService = game:GetService("HttpService")
;(function() -- dc_* (Discord export, dead in practice) wrapped in an IIFE: frees ~12 top-level locals for the 200-limit
local s_dc    = tab:new_section("Discord export", "Right")
local dc_url  = s_dc:new_textbox("Webhook URL", "https://discord.com/api/webhooks/...", database.read("dc_webhook") or "", function(v)
    pcall(function()
        database.write("dc_webhook", v)
        database.flush()
    end)
end)
local dc_n    = s_dc:new_slider("Hits to send", 1, 30, 5, 0, "")
local dc_auto = s_dc:new_toggle("Auto-send deaths", false)

local function dc_valid()
    local url = dc_url:get()
    return type(url) == "string" and string.find(url, "/api/webhooks/", 1, true) ~= nil
end

-- post one message (<= ~1900 chars), returns ok
local function dc_post_one(text)
    local body = HttpService:JSONEncode({ content = "```\n" .. text .. "\n```", username = "unsyk" })
    for attempt = 1, 4 do
        local ok, res = pcall(function()
            return HttpService:RequestAsync({
                Url = dc_url:get(), Method = "POST",
                Headers = { ["Content-Type"] = "application/json" }, Body = body,
            })
        end)
        if not ok then
            client.color_log(255, 90, 90, "[DC] request failed: " .. tostring(res))
            return false
        end
        local code = type(res) == "table" and (res.StatusCode or res.Status) or nil
        if type(res) == "table" and res.Success == false then
            local snippet = (type(res.Body) == "string") and string.sub(res.Body, 1, 160) or "?"
            if code == 429 and attempt < 4 then
                -- honor Discord's retry_after (body JSON) or the Retry-After header
                local wait_s = 2
                local okj, j = pcall(function() return HttpService:JSONDecode(res.Body) end)
                if okj and type(j) == "table" and type(j.retry_after) == "number" then wait_s = j.retry_after end
                if type(res.Headers) == "table" then
                    local h = res.Headers["retry-after"] or res.Headers["Retry-After"]
                    if tonumber(h) then wait_s = tonumber(h) end
                end
                wait_s = math.min(math.max(wait_s, 1), 15) + 0.5
                client.color_log(255, 200, 80, string.format("[DC] 429 rate limited, retry %d in %.1fs | %s", attempt, wait_s, snippet))
                task.wait(wait_s)
            else
                client.color_log(255, 90, 90, "[DC] discord returned status " .. tostring(code) .. " | " .. snippet)
                return false
            end
        else
            return true
        end
    end
    return false
end

-- split lines into chunks under Discord's 2000-char limit and send them in the background
local function dc_send_lines(lines)
    if not dc_valid() then
        client.color_log(255, 200, 80, "[DC] paste a valid webhook URL into 'Webhook URL' first")
        return
    end
    if #lines == 0 then
        client.log("[DC] nothing to send yet")
        return
    end
    task.spawn(function()
        local chunk, size, sent, total = {}, 0, 0, 0
        local function flush()
            if #chunk == 0 then return end
            total = total + 1
            if dc_post_one(table.concat(chunk, "\n")) then sent = sent + 1 end
            chunk, size = {}, 0
            task.wait(0.7) -- stay well under Discord's rate limit
        end
        for _, line in ipairs(lines) do
            if #line > 1500 then line = string.sub(line, 1, 1500) .. "..." end
            if size + #line + 1 > 1800 then flush() end
            chunk[#chunk + 1] = line
            size = size + #line + 1
        end
        flush()
        client.color_log(120, 255, 160, string.format("[DC] sent %d/%d message(s)", sent, total))
    end)
end

local function dc_last(n)
    local out = {}
    for i = math.max(1, #fd_hits - n + 1), #fd_hits do out[#out + 1] = fd_hits[i] end
    return out
end

local function dc_timeline_lines(n)
    local lines = {}
    for _, e in ipairs(dc_last(n)) do
        fd_print_hit(e, function(l) lines[#lines + 1] = l end)
    end
    return lines
end

local function dc_csv_lines(n)
    local lines = { "n,dmg,hp_before,ping_ms,state,speed,phase,side,limit,manual,flip_age,choke,dt,real,fake,e1,e1_wep,e1_dist,e1_pat,e2,e2_wep,e2_dist" }
    for _, e in ipairs(dc_last(n)) do
        local r = e.last or {}
        local a, b = e.enemies[1] or {}, e.enemies[2] or {}
        lines[#lines + 1] = string.format("%d,%d,%d,%.0f,%s,%.0f,%s,%s,%.0f,%s,%d,%s,%s,%s,%s,%s,%s,%.0f,%s,%s,%s,%.0f",
            e.n, e.dmg, e.hp_before, e.ping, tostring(r.state), r.speed or 0, tostring(r.phase), tostring(r.side), r.lim or 0,
            tostring(r.man), e.flip_age, tostring(r.choke), tostring(e.dt),
            r.real and string.format("%.0f", r.real) or "?", r.fake and string.format("%.0f", r.fake) or "?",
            tostring(a.name), tostring(a.wep), a.dist or 0, tostring(a.pat), tostring(b.name), tostring(b.wep), b.dist or 0)
    end
    return lines
end

local function dc_summary_lines()
    local lines = {}
    lines[#lines + 1] = string.format("=== unsyk summary (%d hits) ===", fd_total)
    lines[#lines + 1] = string.format("settings: inv=%s mod=%s/%d lag=%d/%d%% pitch=%s lims(s/m/a/d)=%d/%d/%d/%d rnd=%s",
        ds_mode:get(), yaw_mod:get(), mod_amt:get(), lag_ticks:get(), lag_var:get(), pitch_sel:get(),
        lim_stand:get(), lim_move:get(), lim_air:get(), lim_duck:get(), tostring(lim_rnd:get()))
    lines[#lines + 1] = string.format("defensive=%s trig=%s | onshot=%s mode=%s | dt=%s", tostring(def_on:get()), def_trig:get(),
        tostring(os_on:get()), os_mode:get(), dt_state().text)
    local keys = {}
    for k, _ in pairs(fd_stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do lines[#lines + 1] = string.format("%-22s %d", k, fd_stats[k]) end
    lines[#lines + 1] = string.format("shots: fired=%d hit=%d miss=%d died_in_flight=%d", sh_cnt.fire, sh_cnt.hit, sh_cnt.miss, sh_cnt.died or 0)
    lines[#lines + 1] = "--- enemy intel ---"
    for _, rec in pairs(intel) do
        local a, b, c = intel_lines(rec)
        lines[#lines + 1] = a
        lines[#lines + 1] = "  " .. b
        lines[#lines + 1] = "  " .. c
        lines[#lines + 1] = "  intervals: " .. table.concat(rec.ints, ",")
    end
    return lines
end

s_dc:new_button("Send summary", function() dc_send_lines(dc_summary_lines()) end)
s_dc:new_button("Send CSV", function() dc_send_lines(dc_csv_lines(dc_n:get())) end)
s_dc:new_button("Send timelines", function() dc_send_lines(dc_timeline_lines(dc_n:get())) end)

-- auto-send the timeline of each death
local dc_last_sent = 0
client.on_tick(function()
    if not dc_auto:get() or not dc_valid() then dc_last_sent = fd_total return end
    if fd_total > dc_last_sent then
        local e = fd_hits[#fd_hits]
        dc_last_sent = fd_total
        if e and e.hp_after <= 0 then
            local lines = {}
            fd_print_hit(e, function(l) lines[#lines + 1] = l end)
            dc_send_lines(lines)
        end
    end
end)
end)() -- end dc IIFE

-- ======================================================================
-- RESOLVER (rs_*): our own desync-side resolver built on the intel reads.
-- Every tick, for every alive enemy: real side = sign(goal_feet_yaw - eye yaw) (same read as intel),
-- plus their flip rhythm. "Ideal tick": we lead by N ticks (from ping, or fixed): if their next flip
-- lands before our shot does, aim at the side they flip to. Per enemy and per state (Stand/Run/Duck/
-- Jumping) it learns whether the read side or its inverse hits, from aim_hit / aim_miss("resolver").
-- Modes: Off | Shadow (compute + log only; the cheat's resolver still aims) | Active (plist override).
-- Takeover: Active only takes a player after the built-in resolver missed them N times (0 = always),
-- and hands them back after 2 of our own resolver misses in a row.
-- ======================================================================
local s_rs    = tab:new_section("Resolver", "Left")
local rs_mode = s_rs:new_combobox("Mode", { "Off", "Shadow", "Active" }, "Off")
local rs_lead = s_rs:new_slider("Lead (-1 auto)", -1, 12, -1, 0, "t")
local rs_take = s_rs:new_slider("Take over after", 0, 5, 1, 0, "")
local rs_max  = s_rs:new_slider("Max offset", 20, MAXD, 58, 0, "°")

local rs = {}          -- [player name] = { ent, rec, st = {[state] = {inv, hit, miss}}, bmiss, omiss, own, applied, d }
local rs_shots = {}    -- FIFO of fired shots { id, name, t, r, d, own } (hit/miss events carry no id)
local rs_n = 0
local rs_was_active = false

local function rs_ping_ticks()
    -- once per tick (rs_decide asks for every enemy)
    if st.rs_pk == UNSYK_PROF.tick and st.rs_pv then return st.rs_pv end
    st.rs_pk = UNSYK_PROF.tick
    st.rs_pv = nil
    local okl, lat = pcall(client.latency)
    local okt, ti = pcall(globals.tickinterval)
    if not okl or type(lat) ~= "number" then return 1 end
    ti = (okt and type(ti) == "number" and ti > 0) and ti or 0.015625
    st.rs_pv = math.max(1, math.floor(lat / ti + 0.5) + 1)   -- latency (s) in ticks, +1 for the shot tick
    return st.rs_pv
end

local function rs_find(target)
    if target == nil then return nil end
    -- records are keyed by player name: the entity changes on respawn, the name does not
    local okn, name = pcall(entity.get_player_name, target)
    if okn and type(name) == "string" and rs[name] then return rs[name] end
    for _, r in pairs(rs) do
        if r.ent == target then return r end
        local ok, slot = pcall(entity.get_player_slot, r.ent)
        if ok and slot ~= nil and slot == target then return r end
    end
    return nil
end

local function rs_decide(r, now)
    local D = st.rsx and st.rsx.data
    if not D then return nil end
    local rec = r.rec
    local base = nil
    if rec.side ~= 0 then
        local label, next_in, next_side = intel_pattern(rec, now)
        local lead = rs_lead:get()
        if lead < 0 then lead = rs_ping_ticks() end
        local side, src = rec.side, "read"
        if next_in ~= nil and next_in <= lead then
            side, src = next_side, "pred"
        end
        local raw = math.max(math.abs(rec.des_now), rec.ema_des)
        local mag = math.min(raw, rs_max:get())
        base = { side = side, off = math.floor(side * mag + 0.5), src = src, lead = lead, nxt = next_in,
            st = rec.state, pat = label, raw = raw }
    end
    -- candidate resolver (CANDIDATE RESOLVER block further down): scores many angles, learns per state
    if st.rsx and st.rsx.on() then return st.rsx.pick(r, base, now) end
    if not base then return nil end
    local stt = r.st[rec.state]
    if stt and stt.inv then
        base.side, base.off = -base.side, -base.off
        base.src = base.src .. "+inv"
    end
    if base.raw < D.w.raw0 then return nil end   -- barely desyncing: leave this player to the built-in resolver
    return base
end

local rs_err, rs_err_at = nil, -100
-- plist.set only when the value changed, re-sent every 32 ticks in case the cheat clears it (r.pc = nil after a reset)
st.pset = function(r, e, k, v)
    local c = r.pc
    if not c then c = { v = {}, t = {} }; r.pc = c end
    local tk = UNSYK_PROF.tick
    if c.v[k] == v and tk - (c.t[k] or -99) < 32 then return end
    c.v[k], c.t[k] = v, tk
    pcall(plist.set, e, k, v)
end
-- writes what the resolver decided for one enemy: d = our yaw pick (nil = the built-in resolver keeps yaw),
-- xd = anti-roll / pitch brute force (ANTI-ROLL block). r.yw/pf/sf/ba remember what is set, to release it.
st.rs_apply = function(r, e, d, xd)
    if d then
        st.pset(r, e, "Force body yaw", true)
        -- licence enforcement (off by default): a copy that never reaches a live /beat heartbeat
        -- (leaked / revoked / stubbed guard) resolves enemies a few degrees wrong, so it aims worse
        -- without an obvious "stopped" message. A valid session clears st.lic_authed within ~60s, so
        -- this is always a no-op for a real subscriber. Gated by database key "lic_enf".
        local off = d.off
        if st.lic_enf and not st.lic_authed and (os.time() - (st.lic_t0 or os.time())) > 240 then
            off = off + 13
        end
        st.pset(r, e, "Override yaw offset", off)
        r.yw = true
    elseif r.yw then
        st.pset(r, e, "Force body yaw", false)
        r.yw = false
    end
    -- pitch: brute force (fake pitch) wins over the flick fix (they flicked away from their usual pitch)
    local pv = (xd and xd.pv) or ((d and d.pf) and d.pv) or nil
    if pv ~= nil then
        st.pset(r, e, "Force pitch", true)
        st.pset(r, e, "Force pitch value", pv)
        r.pf = true
    elseif r.pf then
        st.pset(r, e, "Force pitch", false)
        r.pf = false
    end
    -- safe points: fake duck (head not where the animation says) or a roll lean
    if (d and d.safe) or (xd and xd.safe) then
        st.pset(r, e, "Override safe point", "Force")
        r.sf = true
    elseif r.sf then
        st.pset(r, e, "Override safe point", "-")
        r.sf = false
    end
    if xd and xd.baim then
        st.pset(r, e, "Override prefer body aim", "Force")
        r.ba = true
    elseif r.ba then
        st.pset(r, e, "Override prefer body aim", "-")
        r.ba = false
    end
end
local function rs_tick()
    local mode = rs_mode:get()
    if mode ~= "Off" and st.rsx then
        st.rsx.say()                       -- one [RS] line when the table loads / goes away (owner console)
        if not st.rsx.data then mode = "Off" end   -- no server table: do nothing, hand everyone back
    end
    if mode == "Off" then
        if rs_was_active then
            pcall(plist.reset_all)
            for _, r in pairs(rs) do r.applied, r.own, r.pc, r.yw, r.pf, r.sf, r.ba = false, false, nil, false, false, false, false end
            rs_was_active = false
        end
        return
    end
    rs_n = rs_n + 1
    local okp, mypos = pcall(entity.get_player_position, me())
    if not okp or not mypos then return end
    local take = rs_take:get()
    for _, e in ipairs(entity.get_enemies()) do
        if entity.is_alive(e) then
            local okq, pos = st.epos(e)
            if okq and pos then
                local okn, name = st.ename(e)
                local key = (okn and type(name) == "string") and name or tostring(e)
                local r = rs[key]
                if not r then
                    r = { rec = new_rec(key), st = {}, bmiss = 0, omiss = 0, own = false, applied = false }
                    rs[key] = r
                end
                if r.ent ~= e then
                    if r.applied then pcall(plist.reset, r.ent) end
                    r.ent, r.applied, r.pc, r.yw, r.pf, r.sf, r.ba = e, false, nil, false, false, false, false     -- respawned: same player, new entity
                end
                local c0 = os.clock()
                pcall(intel_update, r.rec, e, (pos - mypos).Magnitude, pos, mypos, rs_n)
                local c1 = os.clock()
                UNSYK_PROF.add(UNSYK_PROF.sub("rs.intel_update"), c1 - c0)
                r.d = rs_decide(r, rs_n)
                local c2 = os.clock()
                UNSYK_PROF.add(UNSYK_PROF.sub("rs.decide"), c2 - c1)
                if mode == "Active" then
                    if not r.own and (take == 0 or r.bmiss >= take) then r.own = true end
                else
                    r.own = false
                end
                -- anti-roll + pitch brute force (ANTI-ROLL block further down): measured for everyone,
                -- applied in Active mode, also to players the built-in resolver keeps for yaw
                local okx, xd = false, nil
                if st.rx2 then okx, xd = pcall(st.rx2.decide, r, e) end
                if not okx then xd = nil end
                local xon = xd ~= nil and (xd.safe or xd.baim or xd.pv ~= nil)
                if mode == "Active" and ((r.own and r.d) or xon) then
                    pcall(st.rs_apply, r, e, (r.own and r.d) or nil, xd)
                    r.applied = true
                    rs_was_active = true
                elseif r.applied then
                    pcall(plist.reset, e)
                    r.applied, r.pf, r.sf, r.ba, r.yw, r.pc = false, false, false, false, false, nil
                end
                UNSYK_PROF.add(UNSYK_PROF.sub("rs.plist"), os.clock() - c2)
            end
        end
    end
end
client.on_tick(function()
    local ok, err = pcall(rs_tick)
    if not ok then
        rs_err = tostring(err)
        if globals.realtime() - rs_err_at > 10 then
            rs_err_at = globals.realtime()
            client.color_log(255, 90, 90, "[RESOLVER] tick error: " .. rs_err)
        end
    end
end)

-- what the resolver had for this target right now (logged with every shot)
local function rs_info(target)
    local D = st.rsx and st.rsx.data
    local rv = D and D.rv or nil
    if not D and rs_mode:get() ~= "Off" then
        return { m = rs_mode:get(), why = "nodata", wd = st.rsx and st.rsx.why or "no rsx" }
    end
    local r = rs_find(target)
    if not r then
        local n = 0
        for _ in pairs(rs) do n = n + 1 end
        return { m = rs_mode:get(), why = "nofind", tracked = n, ttype = typeof and typeof(target) or type(target),
            tval = tostring(target), err = rs_err, rv = rv }
    end
    if not r.d then
        return { m = rs_mode:get(), why = "noside", ticks = r.rec.ticks, des = math.floor(r.rec.des_now or 0),
            side = r.rec.side, st = r.rec.state, err = rs_err, rv = rv, x = st.rx2 and st.rx2.info(r) or nil }
    end
    return { m = rs_mode:get(), own = r.yw == true, off = r.d.off, src = r.d.src, lead = r.d.lead, nxt = r.d.nxt,
        st = r.d.st, pat = r.d.pat, bmiss = r.bmiss, sc = r.d.sc, pf = r.d.pv, fd = r.d.safe or nil,
        aac = r.aa_changes, rv = rv, x = st.rx2 and st.rx2.info(r) or nil }
end

-- Only aim_fire carries a real shot id in this cheat: aim_hit / aim_miss always arrive with id 0.
-- So every fire is queued, and a hit/miss takes the oldest queued shot at the same player (by name),
-- else the oldest one. The matched fire id is written back into the event as e.fid for the feed.
st.rs_match = function(e)
    local now = globals.realtime()
    while rs_shots[1] and now - rs_shots[1].t > 3 do table.remove(rs_shots, 1) end
    local okn, name = pcall(entity.get_player_name, e.target)
    local pick = nil
    for i, p in ipairs(rs_shots) do
        if okn and p.name == name then pick = i; break end
    end
    if not pick and rs_shots[1] then pick = 1 end
    if not pick then return nil end
    local s = table.remove(rs_shots, pick)
    pcall(function() e.fid = s.id end)
    return s
end

client.set_event_callback("aim_fire", function(e)
    if not e then return end
    local r = rs_find(e.target)
    local okn, name = pcall(entity.get_player_name, e.target)
    rs_shots[#rs_shots + 1] = { id = e.id, name = okn and name or nil, t = globals.realtime(),
        r = r, d = r and r.d, own = (r and r.yw) == true }
    if #rs_shots > 32 then table.remove(rs_shots, 1) end
end)

client.set_event_callback("aim_hit", function(e)
    if not e then return end
    local s = st.rs_match(e)
    if s and not s.r then s = nil end
    if s then
        s.r.rmiss = 0
        if st.rx2 then pcall(st.rx2.hit, s.r) end
    end
    if not s or not s.own or not s.d then return end
    if s.d.ci and st.rsx then st.rsx.learn(s.r, s.d, false); s.r.omiss = 0; return end
    local stt = s.r.st[s.d.st] or { inv = false, hit = 0, miss = 0 }
    stt.hit = stt.hit + 1
    s.r.st[s.d.st] = stt
    s.r.omiss = 0
end)

client.set_event_callback("aim_miss", function(e)
    if not e then return end
    local s = st.rs_match(e)
    if not s or not s.r or tostring(e.reason) ~= "resolver" then return end
    local r = s.r
    r.rmiss = (r.rmiss or 0) + 1
    if st.rx2 then pcall(st.rx2.miss, r, e) end   -- pitch brute force counts head misses (ours and built-in)
    if not s.own then
        r.bmiss = r.bmiss + 1          -- the built-in resolver missed this player
        return
    end
    r.omiss = r.omiss + 1
    local D = st.rsx and st.rsx.data
    if not D then return end
    if s.d and s.d.ci and st.rsx then
        st.rsx.learn(r, s.d, true)    -- this angle missed: lower its score, block it for a few seconds
    elseif s.d then
        local stt = r.st[s.d.st] or { inv = false, hit = 0, miss = 0 }
        stt.miss = stt.miss + 1
        if stt.miss >= stt.hit + D.w.inv0 then    -- this state keeps missing: try the inverse side
            stt.inv = not stt.inv
            stt.hit, stt.miss = 0, 0
        end
        r.st[s.d.st] = stt
    end
    if r.omiss >= ((s.d and s.d.ci) and D.w.hb or D.w.hb0) and rs_take:get() > 0 then   -- hand back to the built-in resolver
        r.own, r.omiss, r.bmiss = false, 0, 0
    end
end)


-- ======================================================================
-- PEEK AA, RESOLVER BODY-AIM, ANIM BREAKER (experimental: A/B them with remote config, all Off by default)
-- Peek AA ("Randomize": random flips + random limit every tick while they can see us, so a resolver
--   that learned our side, timing or limit has nothing stable to use).
-- Peek AA: the moment the ragebot gets a target (= an enemy just became shootable, i.e. a peek) it stops
--   the inverter from flipping for "Peek window" ticks, so we never flip mid-duel (most deaths land 0-1t
--   after a flip). "Flip then hold" flips once at peek start (breaks a read taken before the peek),
--   "Max desync hold" also forces 84°. Runs inside the main AA tick through st.hook, so flip age stays right.
-- Body aim: after N resolver misses on a player (ours or built-in, reset on a hit) force body aim on them.
-- Anim breaker: freezes or scrambles our own Roblox animation tracks (legs/torso pose). Unknown whether
--   this game's hitboxes follow them: that is what the A/B is for.
-- Handles hang off st.ui (main chunk is at the 200-local limit) so remote control can drive them.
-- ======================================================================
do
local s_px    = tab:new_section("Peek & extras", "Left")
local px_mode = s_px:new_combobox("Peek AA", { "Off", "Hold side", "Flip then hold", "Max desync hold", "Randomize" }, "Off")
local px_len  = s_px:new_slider("Peek window", 4, 64, 24, 0, "t")
local rx_baim = s_px:new_slider("Baim after misses", 0, 5, 0, 0, "")
local an_mode = s_px:new_combobox("Anim breaker", { "Off", "Freeze in air", "Freeze all", "Jitter" }, "Off")
st.ui = { px_mode = px_mode, px_len = px_len, rx_baim = rx_baim, an_mode = an_mode }

local function target_now()
    local ok, t = pcall(rage.get_target)
    if ok and t then return t end
    return nil
end

local had_target, win_until, hold = false, 0, nil
st.peek_active = false
st.hook = function()
    local mode = px_mode:get()
    if mode == "Off" then st.peek_active = false; hold = nil; return end
    local t = target_now()
    if t and not had_target and st.n >= win_until then
        win_until = st.n + px_len:get()
        hold = st.inv
        if mode == "Flip then hold" then hold = not st.inv end
    end
    had_target = t ~= nil
    local active = st.n < win_until and hold ~= nil and manual() == nil
    st.peek_active = active
    if active then
        if mode == "Randomize" then
            -- no timing or angle to learn while they can see us: flip at random ticks
            -- (never twice in a row) and a fresh random limit every tick
            if st.n - (st.flip_n or 0) >= 2 and math.random() < 0.35 then hold = not hold end
            local lim = math.random(40, MAXD)
            st.cur_lim = lim
            pcall(aa.override_desync_limits, lim, lim)
        end
        st.inv = hold
        pcall(aa.override_inverter, hold)
        if mode == "Max desync hold" then
            st.cur_lim = MAXD
            pcall(aa.override_desync_limits, MAXD, MAXD)
        end
        st.phase = st.phase .. "+peek"
    end
end

-- body aim after resolver misses on the current target
local baim_on = false
client.on_tick(function()
    local n = rx_baim:get()
    local want = false
    if n > 0 then
        local t = target_now()
        if t then
            local r = rs_find(t.player) or rs_find(t.slot)
            want = r ~= nil and (r.rmiss or 0) >= n
        end
    end
    if want ~= baim_on then
        if want then pcall(rage.override_force_baim, true) else pcall(rage.reset) end
        baim_on = want
    end
end)

-- anim breaker on our own character
local Players = game:GetService("Players")
local frozen, an_n = {}, 0
local function tracks()
    local lp = Players.LocalPlayer
    local ch = lp and lp.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not hum then return {} end
    local an = hum:FindFirstChildOfClass("Animator") or hum
    local ok, list = pcall(function() return an:GetPlayingAnimationTracks() end)
    if ok and type(list) == "table" then return list end
    return {}
end
local function unfreeze_all()
    for tr in pairs(frozen) do pcall(function() tr:AdjustSpeed(1) end) end
    frozen = {}
end
client.on_tick(function()
    local mode = an_mode:get()
    if mode == "Off" then
        if next(frozen) then unfreeze_all() end
        return
    end
    an_n = an_n + 1
    local freeze = (mode == "Freeze all") or (mode == "Freeze in air" and my_state() == "air")
    if not freeze and next(frozen) then unfreeze_all() end
    for _, tr in ipairs(tracks()) do
        if freeze then
            if not frozen[tr] then
                pcall(function() tr:AdjustSpeed(0) end)
                frozen[tr] = true
            end
        elseif mode == "Jitter" and an_n % 2 == 0 then
            pcall(function() tr.TimePosition = math.random() * math.max(tr.Length, 0.1) end)
        end
    end
end)
end

-- ======================================================================
-- DODGE AA (idea from the "phobia beta" script). While an enemy is a threat (the ragebot has a target, or an
-- alive enemy is inside "Threat range") it re-rolls every "Reroll every" ms (x0.6..1.4): side, desync size
-- (Min..Max; left and right differ by up to 6 deg when Asymmetric), a random yaw offset, optionally a random
-- pitch. Every "Swing every" ms (x0.4..1.7) a ~4-tick swing: max desync to the other side, yaw offset +-84,
-- pitch +-89 and a tick shift (always fired: our DT charge read is broken, so no charge check here).
-- Taking damage re-rolls at once and swings 50ms later. No fixed side, timing or size for a resolver to learn.
-- Replaces regular + defensive AA while active (main tick, st.dodge). Off by default: A/B it remotely.
-- ======================================================================
do
local s_dg = tab:new_section("Dodge", "Left")
local dg_mode  = s_dg:new_combobox("Dodge AA", { "Off", "On threat", "Always" }, "Off")
local dg_rate  = s_dg:new_slider("Reroll every", 20, 250, 50, 0, "ms")
local dg_min   = s_dg:new_slider("Min desync", 10, MAXD, 30, 0, "°")
local dg_max   = s_dg:new_slider("Max desync", 20, MAXD, MAXD, 0, "°")
local dg_asym  = s_dg:new_toggle("Asymmetric", true)
local dg_yaw   = s_dg:new_slider("Random yaw", 0, 45, 30, 0, "°")
local dg_pitch = s_dg:new_toggle("Pitch scramble", false)
local dg_swing = s_dg:new_slider("Swing every (0 off)", 0, 2000, 700, 0, "ms")
local dg_shift = s_dg:new_slider("Swing shift", 0, 14, 8, 0, "t")
local dg_range = s_dg:new_slider("Threat range", 20, 500, 250, 0, "st")
local dg_hit   = s_dg:new_toggle("Re-roll when hit", true)
st.ui.dg = { mode = dg_mode, rate = dg_rate, min = dg_min, max = dg_max, asym = dg_asym, yaw = dg_yaw,
    pitch = dg_pitch, swing = dg_swing, shift = dg_shift, range = dg_range, hit = dg_hit }

local D = { nxt = 0, swing_at = 0, swing_until = 0, side = false, l = 58, r = 58, off = 0, pitch = nil,
    hp = nil, threat = false, scan_at = 0, active = false, pf = false }
st.dg = { rerolls = 0, swings = 0, hits = 0 }

local function threat(now)
    if now < D.scan_at then return D.threat end
    D.scan_at = now + 0.05
    D.threat = false
    local okt, tg = pcall(rage.get_target)
    if okt and tg then D.threat = true; return true end
    local okp, mypos = pcall(entity.get_player_position, me())
    if not okp or not mypos then return false end
    local oke, list = pcall(entity.get_enemies)
    if not oke or type(list) ~= "table" then return false end
    local reach = dg_range:get()
    for _, e in ipairs(list) do
        local oka, alive = pcall(entity.is_alive, e)
        if oka and alive then
            local okq, pos = st.epos(e)
            if okq and pos and (pos - mypos).Magnitude < reach then D.threat = true; break end
        end
    end
    return D.threat
end

local function reroll(now)
    local lo = math.floor(math.min(dg_min:get(), dg_max:get()))
    local hi = math.floor(math.max(dg_min:get(), dg_max:get()))
    local mag = math.random(lo, hi)
    D.side = math.random() < 0.5
    D.l, D.r = mag, mag
    if dg_asym:get() then D.r = math.max(8, math.min(MAXD, mag + math.random(-6, 6))) end
    local y = math.floor(dg_yaw:get())
    D.off = 0
    if y > 0 then D.off = (D.side and 1 or -1) * math.random(math.min(10, y), y) end
    D.pitch = nil
    if dg_pitch:get() then
        if math.random(10) == 1 then D.pitch = 0
        else D.pitch = (math.random() < 0.5 and 1 or -1) * math.random(55, 78) end
    end
    D.nxt = now + math.max(0.016, dg_rate:get() / 1000 * (0.6 + math.random() * 0.8))
    st.dg.rerolls = st.dg.rerolls + 1
end

local function plan_swing(now, soon)
    if soon then D.swing_at = now + soon; return end
    local ms = dg_swing:get()
    if ms <= 0 then D.swing_at = math.huge; return end
    D.swing_at = now + ms / 1000 * (0.4 + math.random() * 1.3)
end

local function swing(now)
    D.side = not D.side
    D.l, D.r = MAXD, MAXD
    D.off = D.side and MAXD or -MAXD
    D.pf = not D.pf
    D.pitch = D.pf and 89 or -89
    D.swing_until = now + 0.06
    D.nxt = D.swing_until
    local sh = math.floor(dg_shift:get())
    if sh > 0 then
        local ok = pcall(rage.force_shift, sh)
        if not ok then pcall(rage.shift_ticks, sh) end
    end
    st.dg.swings = st.dg.swings + 1
    plan_swing(now)
end

st.dodge = function(level)
    local mode = dg_mode:get()
    if mode == "Off" then D.active = false; return false end
    local now = os.clock()
    local oki, info = pcall(entity.get_info, me())
    local hp = (oki and type(info) == "table") and tonumber(info.health) or nil
    local hit = hp ~= nil and D.hp ~= nil and hp < D.hp and hp > 0
    D.hp = hp
    if not (mode == "Always" or threat(now)) then D.active = false; return false end
    if not D.active then
        D.active = true
        reroll(now)
        plan_swing(now, 0.15)
    end
    if hit and dg_hit:get() then
        st.dg.hits = st.dg.hits + 1
        reroll(now)
        plan_swing(now, 0.05)
    end
    if now >= D.swing_at then
        swing(now)
    elseif now >= D.nxt and now >= D.swing_until then
        reroll(now)
    end

    local p = D.pitch
    if level then
        p = "Zero"
    elseif p == nil then
        p = pitch_sel:get()
        if p == "Flick" then p = (st.n % 4 < 2) and 89 or -89 end
    end
    pcall(aa.override_pitch, p)
    pcall(aa.override_yaw, 180, "camera")
    pcall(aa.override_yaw_offset, ((yaw_off:get() + D.off + 180) % 360) - 180)
    pcall(aa.override_yaw_modifier, "Disabled")
    pcall(aa.override_body_yaw, true)
    pcall(aa.override_inverter, D.side)
    pcall(aa.override_desync_limits, D.l, D.r)
    pcall(aa.override_show_fake, ds_fake:get())
    pcall(aa.override_fake_lag, true)
    pcall(aa.override_fake_lag_limit, lag_ticks:get())
    pcall(aa.override_fake_lag_variability, lag_var:get())
    st.inv = D.side
    st.cur_lim = math.max(D.l, D.r)
    return true
end
end

-- ======================================================================
-- FLICK (idea from the public "Fake Flick v4" script; reimplemented, no code copied). Every "Every" ticks it adds
-- "Angle" to the yaw offset for "Flick ticks" ticks. Its author says it only works with fake lag, i.e. DOUBLE TAP
-- OFF in the cheat menu (DT disables fake lag in this cheat). "Only while choking" flicks only on choked ticks and
-- "Unchoke on flick" sends the packet on the first flick tick of each cycle, so the angle that goes out is the
-- flicked one. "Fake lag" is forced while Flick is on (our own Fake lag default is 0). If nothing is choked for 2s
-- it says so once ([FLICK] line, crosshair "FLICK NO LAG").
-- Side only matters below 180: "Strafe fix" = inverter side, flipped while strafing left (camera-relative; the
-- original used world X, which depends on the map), "Inverter", "Alternate" (every cycle).
-- Overlays regular AA only (not dodge / defensive / manual); fake lag is forced in every phase. Default Off.
-- ======================================================================
;(function()
local s_fk = tab:new_section("Flick", "Left")
local fk_on    = s_fk:new_toggle("Flick", false)
local fk_rate  = s_fk:new_slider("Every", 2, 64, 8, 0, "t")
local fk_len   = s_fk:new_slider("Flick ticks", 1, 8, 2, 0, "t")
local fk_ang   = s_fk:new_slider("Angle", 0, 180, 180, 0, "°")
local fk_side  = s_fk:new_combobox("Side", { "Strafe fix", "Inverter", "Alternate" }, "Strafe fix")
local fk_speed = s_fk:new_slider("Max speed (0 off)", 0, 60, 0, 0, " st/s")
local fk_choke = s_fk:new_toggle("Only while choking", true)
local fk_unch  = s_fk:new_toggle("Unchoke on flick", true)
local fk_lag   = s_fk:new_slider("Fake lag", 0, 14, 14, 0, "t")
st.ui.fk = { on = fk_on, rate = fk_rate, len = fk_len, ang = fk_ang, side = fk_side, speed = fk_speed,
    choke = fk_choke, unch = fk_unch, lag = fk_lag }

-- on: Flick enabled; nofl: no choked tick seen for 2s; flicks / nochoke: counters for the feed
local F = { on = false, nofl = false, flicks = 0, nochoke = 0, since = 0, last_choke = 0, warned = false, unch_cyc = -1 }
st.fk = F

local function lateral()
    local ok, spd, lat = pcall(function()
        local pl = game:GetService("Players").LocalPlayer
        local ch = pl and pl.Character
        local root = ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
        if not root then return 0, 0 end
        local v = root.AssemblyLinearVelocity
        local cam = workspace.CurrentCamera
        local r = cam and cam.CFrame.RightVector or Vector3.new(1, 0, 0)
        return math.sqrt(v.X * v.X + v.Z * v.Z), v.X * r.X + v.Z * r.Z
    end)
    if ok then return spd or 0, lat or 0 end
    return 0, 0
end

local function choking()
    local okk, ck = pcall(aa.is_fake_lag_choking)
    local okc, n = pcall(aa.get_choked_ticks)
    local yes
    if okk and type(ck) == "boolean" then yes = ck
    elseif okc and tonumber(n) then yes = tonumber(n) > 0
    else yes = true end    -- API missing: do not block flicks on an unknown
    if yes or (okc and (tonumber(n) or 0) > 0) then return true, true end
    return false, okk or okc
end

-- can_flick: phase is regular and no manual key is held. Returns true on a tick that flicked.
st.flick = function(can_flick)
    if not fk_on:get() then
        F.on, F.nofl, F.warned = false, false, false
        return false
    end
    local now = os.clock()
    if not F.on then F.on, F.since, F.last_choke = true, now, now end

    pcall(aa.override_fake_lag, true)
    pcall(aa.override_fake_lag_limit, math.floor(fk_lag:get()))

    local ch, known = choking()
    if ch then
        F.last_choke = now
        if F.nofl then client.color_log(120, 255, 140, "[FLICK] fake lag is choking again") end
        F.nofl, F.warned = false, false
    elseif known and now - F.last_choke > 2 and now - F.since > 2 then
        F.nofl = true
        if not F.warned then
            F.warned = true
            client.color_log(255, 190, 80, "[FLICK] no choked ticks for 2s: fake lag is off. Turn DOUBLE TAP OFF in the cheat menu (DT disables fake lag).")
        end
    end

    if not can_flick then return false end
    local spd, lat = lateral()
    local maxs = fk_speed:get()
    if maxs > 0 and spd > maxs then return false end

    local rate = math.max(2, math.floor(fk_rate:get()))
    local len = math.max(1, math.min(rate, math.floor(fk_len:get())))
    local cyc = math.floor(st.n / rate)
    if st.n % rate >= len then return false end
    if fk_choke:get() and not ch then F.nochoke = F.nochoke + 1; return false end

    local mode = fk_side:get()
    local side
    if mode == "Alternate" then
        side = (cyc % 2 == 0) and 1 or -1
    else
        side = st.inv and -1 or 1
        if mode == "Strafe fix" and lat < -4 then side = -side end
    end
    local off = ((yaw_off:get() + side * fk_ang:get() + 180) % 360) - 180
    pcall(aa.override_yaw_offset, off)
    pcall(aa.override_yaw_modifier, "Disabled")
    if fk_unch:get() and F.unch_cyc ~= cyc then
        F.unch_cyc = cyc
        pcall(aa.unchoke)
    end
    F.flicks = F.flicks + 1
    return true
end
end)()

-- ======================================================================
-- CANDIDATE RESOLVER (ideas from "phobia beta"; runs inside rs_decide when "Candidates" is on).
-- Scores several candidate yaw offsets per enemy and per state, learns from own hits / resolver misses.
-- The candidates and all numbers come from the license server (see below). Also: "Fix pitch flicks" forces their
-- usual pitch when they flick away from it, "Safe point on fake duck" forces safe points while they fake duck.
-- ======================================================================
do
local rs_multi = s_rs:new_toggle("Candidates", true)
local rs_pitch = s_rs:new_toggle("Fix pitch flicks", true)
local rs_fd    = s_rs:new_toggle("Safe point on fake duck", true)
st.ui.rs_multi, st.ui.rs_pitch, st.ui.rs_fd = rs_multi, rs_pitch, rs_fd

-- The candidate list, priors, weights and every threshold come from the license server (GET /resolver, see
-- server/hvh_resolver.py), held in memory only (st.rsx.data, never written to database). This file only
-- measures the enemy (features) and scores whatever the table defines. Without the table (no session, refused
-- key, server unreachable, copy not served by the server) the resolver does nothing, like rs_mode Off.
-- Features go into slots in an order + with signs derived from UNSYK_RSEED (stamped per build by the server),
-- and the table addresses slots: a table only fits the copy of its own build.
-- FEAT order must match FEAT in server/hvh_resolver.py.
local FEAT_N = 7   -- b base, l lby, d desync, t twist, e jitter error, s jitter-opposite sign, a desync size
local WKEYS = { "dmin", "acap", "omax", "lr", "ll", "lt", "dk", "dt", "hit", "miss", "bs", "bw", "bp", "hy", "sig",
    "pb", "pfn", "pfs", "hb", "hb0", "raw0", "inv0" }

local function pbucket(p, pb) return p < -pb and 1 or (p > pb and 3 or 2) end

local function scores(r, state)
    r.sc = r.sc or {}
    local s = r.sc[state]
    if not s then s = {}; r.sc[state] = s end
    return s
end

local X = { data = nil, why = "not fetched yet", said = nil }
X.on = function() return rs_multi:get() == true end

-- one [RS] line (owner console) each time the reason the resolver is idle changes
X.say = function()
    local why = X.data and ("table rv=" .. tostring(X.data.rv) .. " loaded") or ("resolver off: " .. tostring(X.why))
    if why ~= X.said then
        X.said = why
        pcall(st.flog, X.data and 120 or 255, X.data and 255 or 200, X.data and 160 or 90, "[RS] " .. why)
        if st.push then pcall(st.push, { kind = "diag", what = "resolver", ok = X.data ~= nil,
            rv = X.data and X.data.rv or nil, why = X.data and nil or tostring(X.why) }) end
    end
end

-- slots + signs from the build seed (mirrors hvh_resolver.layout: minstd + Fisher-Yates)
X.layout = function(sd)
    local x = sd
    local perm, sign = {}, {}
    for i = 1, FEAT_N do perm[i] = i end
    for i = FEAT_N, 2, -1 do
        x = (x * 48271) % 2147483647
        local j = x % i + 1
        perm[i], perm[j] = perm[j], perm[i]
    end
    for i = 1, FEAT_N do
        x = (x * 48271) % 2147483647
        sign[i] = (x % 2 == 0) and 1 or -1
    end
    return perm, sign
end

local function num(v) if type(v) == "number" and v == v then return v end return nil end
local function slotok(v) return num(v) and v >= 1 and v <= FEAT_N and v == math.floor(v) end

-- check + compile the decoded /resolver answer; nil, reason when anything is off
X.load = function(t, sd)
    if type(t) ~= "table" or type(t.c) ~= "table" or type(t.w) ~= "table" or type(t.rv) ~= "string" then
        return nil, "bad table"
    end
    if tonumber(t.b) ~= tonumber(UNSYK_BUILD) then return nil, "table is for build " .. tostring(t.b) end
    if tonumber(t.fs) ~= FEAT_N then return nil, "table has " .. tostring(t.fs) .. " features" end
    local w = {}
    for _, k in ipairs(WKEYS) do
        w[k] = num(t.w[k])
        if w[k] == nil then return nil, "table misses " .. k end
    end
    local c = {}
    for i, cd in ipairs(t.c) do
        if type(cd) ~= "table" or type(cd.n) ~= "string" or not num(cd.p) then return nil, "bad candidate " .. i end
        local terms, q = {}, {}
        for _, tr in ipairs(type(cd.t) == "table" and cd.t or {}) do
            if type(tr) ~= "table" or not num(tr[1]) or not slotok(tr[2]) or (tr[3] ~= nil and not slotok(tr[3])) then
                return nil, "bad term in " .. cd.n
            end
            terms[#terms + 1] = { tr[1], tr[2], tr[3], num(tr[4]) }
        end
        for _, qq in ipairs(type(cd.q) == "table" and cd.q or {}) do
            if type(qq) ~= "table" or not slotok(qq[1]) or not num(qq[2]) then return nil, "bad need in " .. cd.n end
            q[#q + 1] = { qq[1], qq[2] }
        end
        c[i] = { n = string.sub(cd.n, 1, 12), p = cd.p, t = terms, k = num(cd.k) or 0, q = q, b = cd.b == 1 }
    end
    if #c == 0 or #c > 32 then return nil, "table has " .. #c .. " candidates" end
    local perm, sign = X.layout(sd)
    return { rv = string.sub(t.rv, 1, 16), c = c, w = w, perm = perm, sign = sign }
end

-- called from the heartbeat loop with its GET helper (same host + auth headers as /beat)
X.fetch = function(get)
    local sd = tonumber(UNSYK_RSEED)
    if not sd or sd < 1 or not tonumber(UNSYK_BUILD) then
        X.data, X.why = nil, "this copy was not served by the license server"
        return
    end
    local q = "?b=" .. tostring(math.floor(tonumber(UNSYK_BUILD)))
    local code, body = get("/resolver" .. q)
    if code == 404 then code, body = get("/me" .. q .. "&resolver=1") end   -- proxy without the /resolver route
    if code ~= 200 then
        if code == 401 or code == 403 or code == 404 or not X.data then
            X.data, X.why = nil, code and ("server answered " .. tostring(code)) or "server unreachable"
        end
        return
    end
    local okj, t = pcall(function() return HttpService:JSONDecode(body or "") end)
    local d, why = nil, "bad json"
    if okj then d, why = X.load(t, sd) end
    if not d then
        X.data, X.why = nil, why
        return
    end
    X.data, X.why = d, nil
end

X.pick = function(r, base, now)
    local D = X.data
    if not D then return nil end
    local w = D.w
    if r.rvd ~= D then r.sc, r.blk, r.ci, r.rvd = {}, nil, nil, D end   -- new table: start learning again
    local rec = r.rec
    local yaw = rec.yaw_now
    if type(yaw) ~= "number" then return nil end
    local lby, dd, tw = rec.lby, rec.dd, rec.tw
    local hasd = dd ~= nil and math.abs(dd) >= w.dmin

    -- AA signature: wipe what we learned when it changes for good
    local sig = (rec.yjit and "j" or "s") .. pbucket(rec.pitch_now or 0, w.pb) .. (hasd and "d" or "n")
    if sig ~= r.sig then
        r.sig, r.sig_at = sig, now
    elseif r.sig_lock ~= sig and now - (r.sig_at or now) >= w.sig then
        if r.sig_lock ~= nil then
            r.sc = {}
            r.aa_changes = (r.aa_changes or 0) + 1
        end
        r.sig_lock = sig
    end

    -- legit-looking: no jitter, no desync read, lby close to the eye yaw -> leave to the built-in resolver
    local lbyo = (lby ~= nil) and wrap180(lby - yaw) or nil
    if not rec.yjit and (base == nil or base.raw < w.lr) and (lbyo == nil or math.abs(lbyo) < w.ll)
        and (tw == nil or math.abs(tw) < w.lt) then
        r.ci = nil
        return nil
    end

    -- features -> slots
    local e = (rec.yjit and rec.yref) and wrap180(yaw - rec.yref) or nil
    local raw = { base and base.off or nil, lbyo, hasd and dd or nil, tw, e, e and (e > 0 and -1 or 1) or nil,
        hasd and math.min(math.abs(dd), w.acap) or nil }
    local F = {}
    for i = 1, FEAT_N do
        if raw[i] ~= nil then F[D.perm[i]] = raw[i] * D.sign[i] end
    end

    local c = {}
    for i, cd in ipairs(D.c) do
        local ok, v = true, cd.k
        for _, qq in ipairs(cd.q) do
            local f = F[qq[1]]
            if f == nil or math.abs(f) < qq[2] then ok = false; break end
        end
        if ok then
            for _, tr in ipairs(cd.t) do
                local x = F[tr[2]]
                local m = 1
                if tr[3] then
                    m = F[tr[3]]
                    if m == nil then m = tr[4] end
                end
                if x == nil or m == nil then ok = false; break end
                v = v + tr[1] * x * m
            end
        end
        if ok and v == v then
            v = wrap180(v)
            if math.abs(v) <= w.omax then c[i] = math.floor(v + 0.5) end   -- beyond that = a bad read
        end
    end

    local rt = globals.realtime()
    if rt - (r.sc_t or 0) >= w.dt then
        r.sc_t = rt
        for _, s in pairs(r.sc or {}) do
            for k, v in pairs(s) do s[k] = v * w.dk end
        end
    end
    local ss = scores(r, rec.state)
    local blk = r.blk or {}
    local best, bs = nil, -1e9
    for i = 1, #D.c do
        local o = c[i]
        if o ~= nil then
            local s = D.c[i].p + (ss[i] or 0)
            for _, b in ipairs(blk) do
                if b.e > rt and math.abs(wrap180(o - b.o)) < w.bw then s = s + w.bp; break end
            end
            if i == r.ci then s = s + w.hy end
            if s > bs then best, bs = i, s end
        end
    end
    if not best then return nil end
    r.ci = best
    local o = c[best]
    local d = { side = o >= 0 and 1 or -1, off = o, ci = best,
        src = D.c[best].n .. ((D.c[best].b and base and base.src == "pred") and "/pred" or ""),
        lead = base and base.lead or nil, nxt = base and base.nxt or nil, st = rec.state,
        pat = base and base.pat or "?", sc = math.floor(bs * 10 + 0.5) / 10 }

    if rs_pitch:get() and rec.ph and #rec.ph >= w.pfn and type(rec.pitch_now) == "number" then
        local n, sum = { 0, 0, 0 }, { 0, 0, 0 }
        for _, p in ipairs(rec.ph) do
            local b = pbucket(p, w.pb)
            n[b] = n[b] + 1
            sum[b] = sum[b] + p
        end
        local mj = 1
        if n[2] > n[mj] then mj = 2 end
        if n[3] > n[mj] then mj = 3 end
        if pbucket(rec.pitch_now, w.pb) ~= mj and n[mj] >= #rec.ph * w.pfs then
            d.pf = true
            d.pv = math.floor(sum[mj] / n[mj] + 0.5)
        end
    end
    d.safe = rs_fd:get() and rec.fd_until ~= nil and now < rec.fd_until or false
    return d
end

-- own hit (missed=false) or own resolver miss (missed=true, also blocks that offset for a few seconds)
X.learn = function(r, d, missed)
    local D = X.data
    if not D or not r or not d or not d.ci or r.rvd ~= D then return end
    local ss = scores(r, d.st)
    ss[d.ci] = (ss[d.ci] or 0) + (missed and D.w.miss or D.w.hit)
    if missed then
        local rt = globals.realtime()
        local blk = {}
        for _, b in ipairs(r.blk or {}) do
            if b.e > rt then blk[#blk + 1] = b end
        end
        blk[#blk + 1] = { o = d.off, e = rt + D.w.bs }
        r.blk = blk
    end
end
st.rsx = X
end

-- ======================================================================
-- ANTI-ROLL + PITCH RESOLVER (the 2026-11 cheat update gave everyone roll = "extended angles" and fake pitch).
-- NOT tested in game; both counters default Off -> A/B them (rs_roll / rs_pbrute).
-- No API reads an enemy's roll or real pitch, so:
--   Roll: every 4 ticks we measure their lean = angle of head hitbox over pelvis hitbox from vertical
--     (entity.get_player_hitbox_position). Their own upright lean is learned as a low percentile (pitch also
--     tilts the head a bit), so "rolled" = lean above that baseline by >= "Lean threshold" in >= 40% of the
--     last 24 samples. Counter = plist "Override safe point" and/or "Override prefer body aim" while rolled:
--     the head is the hitbox a lean moves most and the one the resolver cannot know.
--   Pitch: fake pitch makes the pitch we see wrong. After N resolver misses in a row aimed at their head, try
--     the next pitch via plist "Force pitch value" (now applied to hitboxes + backtrack): opposite of what they
--     show -> Zero -> back to no force. A hit keeps the current one. Overrides the "Fix pitch flicks" value.
-- Works only while the resolver is Active (rs_tick applies it, also for players the built-in resolver keeps).
-- Measurement (lean stats, visual vs get_prop "resolved_pitch") runs whenever the resolver is not Off and goes
-- out as diag what="enemy lean (2min)" so the thresholds can be tuned from data.
-- ======================================================================
;(function()
local s = tab:new_section("Anti-roll", "Left")
local U = {
    roll  = s:new_combobox("Roll counter", { "Off", "Safe point", "Body aim", "Both" }, "Off"),
    thr   = s:new_slider("Lean threshold", 4, 40, 12, 0, "°"),
    pb    = s:new_toggle("Pitch brute force", false),
    pm    = s:new_slider("Pitch misses", 1, 4, 2, 0, ""),
}
local X = { ui = U, diag = {}, diag_t = globals.realtime(), pd = { n = 0, big = 0, err = 0 } }
st.rx2 = X
local PITCH = { "Up", "Zero", "Down" }

local function pbucket(p)
    if type(p) ~= "number" then return "Zero" end
    if p > 45 then return "Down" elseif p < -45 then return "Up" end
    return "Zero"
end

-- next pitch to try: what they show is wrong -> its opposite first, then Zero, then the remaining one, then none
local function pitch_order(shown)
    if shown == "Down" then return { "Up", "Zero", "Down" } end
    if shown == "Up" then return { "Down", "Zero", "Up" } end
    return { "Down", "Up", "Zero" }
end

local function sample(r, e)
    local okh, h = pcall(entity.get_player_hitbox_position, e, "head")
    local okp, p = pcall(entity.get_player_hitbox_position, e, "pelvis")
    if not (okh and okp) or typeof(h) ~= "Vector3" or typeof(p) ~= "Vector3" then return end
    local dx, dy, dz = h.X - p.X, h.Y - p.Y, h.Z - p.Z
    if dy < 0.3 then return end     -- lying / bad read
    local lean = math.deg((math.atan2 or math.atan)(math.sqrt(dx * dx + dz * dz), dy))
    local x = r.x
    x.i = x.i % 24 + 1
    x.ring[x.i] = lean
    x.lean = lean
    -- baseline: 20th percentile of a slow 64-sample history, refreshed every 16 samples
    x.hi_ = x.hi_ % 64 + 1
    x.hist[x.hi_] = lean
    x.ns = x.ns + 1
    if x.ns % 16 == 0 and #x.hist >= 16 then
        local c = {}
        for i = 1, #x.hist do c[i] = x.hist[i] end
        table.sort(c)
        x.base = c[math.max(1, math.floor(#c * 0.2))]
    end
    if x.base and #x.ring >= 12 then
        local thr, n = U.thr:get(), 0
        for i = 1, #x.ring do
            if x.ring[i] - x.base >= thr then n = n + 1 end
        end
        x.rolled = n >= #x.ring * 0.4
    end
    -- diag: lean per player
    local name = r.rec.name
    local dg = X.diag[name]
    if not dg then dg = { n = 0, sum = 0, max = 0, rolled = 0 }; X.diag[name] = dg end
    dg.n = dg.n + 1
    dg.sum = dg.sum + lean
    if lean > dg.max then dg.max = lean end
    if x.rolled then dg.rolled = dg.rolled + 1 end
    dg.base = x.base
end

local function diag_flush()
    local now = globals.realtime()
    if now - X.diag_t < 120 then return end
    X.diag_t = now
    local list = {}
    for name, d in pairs(X.diag) do
        if d.n > 0 then
            list[#list + 1] = { name = name, n = d.n, avg = math.floor(d.sum / d.n * 10 + 0.5) / 10,
                max = math.floor(d.max + 0.5), base = d.base and math.floor(d.base * 10 + 0.5) / 10 or nil,
                rolled = math.floor(d.rolled / d.n * 100 + 0.5) }
        end
    end
    if #list > 0 and st.push then
        pcall(st.push, { kind = "diag", what = "enemy lean (2min)", players = list, thr = U.thr:get(),
            pitch = { n = X.pd.n, big = X.pd.big, err = X.pd.err } })
    end
    X.diag, X.pd = {}, { n = 0, big = 0, err = 0 }
end

-- called from rs_tick for every alive enemy (mode Shadow or Active); returns what to apply on top
X.decide = function(r, e)
    local x = r.x
    if not x then
        x = { ring = {}, i = 0, hist = {}, hi_ = 0, ns = 0, off = math.random(0, 3), pi = 0, pm = 0 }
        r.x = x
    end
    local tk = UNSYK_PROF.tick
    if (tk + x.off) % 4 == 0 then pcall(sample, r, e) end
    -- visual vs resolved pitch, every 32 ticks: how often does the cheat's resolved pitch differ from what we see?
    if (tk + x.off) % 32 == 0 then
        local o1, v1 = pcall(entity.get_prop, e, "eye_angles_x")
        local o2, v2 = pcall(entity.get_prop, e, "resolved_pitch")
        if o1 and o2 and type(v1) == "number" and type(v2) == "number" then
            X.pd.n = X.pd.n + 1
            if math.abs(v1 - v2) > 25 then X.pd.big = X.pd.big + 1 end
        else
            X.pd.err = X.pd.err + 1
        end
    end
    if tk % 64 == 0 and X.dk ~= tk then X.dk = tk; diag_flush() end   -- realtime() is an API call: not per enemy per tick
    local m = U.roll:get()
    local out = { rolled = x.rolled == true }
    if m ~= "Off" and x.rolled then
        out.safe = (m == "Safe point" or m == "Both")
        out.baim = (m == "Body aim" or m == "Both")
    end
    if U.pb:get() and x.pi > 0 then
        out.pv = x.porder and x.porder[x.pi] or nil
    end
    return out
end

local function is_head(hb)
    return hb == 0 or (type(hb) == "string" and string.lower(hb) == "head")
end

-- resolver miss on this player (ours or the built-in one's): count head misses, step the pitch after N
X.miss = function(r, e)
    local x = r.x
    if not x or not U.pb:get() or not is_head(e.hitbox) then return end
    x.pm = x.pm + 1
    if x.pm < U.pm:get() then return end
    x.pm = 0
    if x.pi == 0 then x.porder = pitch_order(pbucket(r.rec.pitch_now)) end
    x.pi = x.pi + 1
    if x.pi > #PITCH then x.pi = 0 end     -- tried all three: back to no pitch force
    x.steps = (x.steps or 0) + 1
end

X.hit = function(r)
    if r.x then r.x.pm = 0 end    -- the current pitch (forced or not) works: keep it
end

-- our resolver vs the cheat's (aim_fire -> shot "cmp"): entity.get_prop gives the cheat's authoritative
-- resolved yaw / pitch next to what the enemy shows, plus torso yaw (unused by us so far) and whether our pitch
-- override stuck (rage.get_player_pitch). One read per fire. Lets the server see when the built-in resolver is
-- right and when ours is (offset = resolved - eye, compare with rs.off and the hit / miss of the same id).
local function rnd1(v) return type(v) == "number" and math.floor(v * 10 + 0.5) / 10 or nil end
X.cmp = function(target)
    local r = rs_find(target)
    local e = (r and r.ent) or target
    local function gp(k)
        local ok, v = pcall(entity.get_prop, e, k)
        return ok and rnd1(v) or nil
    end
    local okp, fpv = pcall(rage.get_player_pitch, e)
    local out = { ry = gp("resolved_yaw"), ey = gp("eye_angles_y"), rp = gp("resolved_pitch"), ep = gp("eye_angles_x"),
        lby = gp("goal_feet_yaw"), tor = gp("torso_yaw"), fpv = okp and rnd1(fpv) or nil }
    if out.ry and out.ey then out.roff = rnd1(wrap180(out.ry - out.ey)) end
    if next(out) == nil then return nil end
    return out
end

-- logged with every shot through rs_info
X.info = function(r)
    local x = r and r.x
    if not x then return nil end
    return { lean = x.lean and math.floor(x.lean + 0.5) or nil, lb = x.base and math.floor(x.base + 0.5) or nil,
        rl = x.rolled or nil, pv = (U.pb:get() and x.pi > 0 and x.porder) and x.porder[x.pi] or nil, ps = x.steps }
end
end)()

-- ======================================================================
-- CLANTAGS (clantag.* API, 2026-11 update; NOT tested in game). Tags are server-synced for every player, and many
-- scripts set one, so st.ctag(name) reads an enemy's tag (cached 30s) -> intel events and shots carry `tag`: lets
-- the server group enemy AA / resolver results per script. Own tag: section "Clantag" (Visuals), default Off;
-- note that it shows everyone you run unsyk. Reset on unload by the cheat itself (and by us on shutdown).
-- ======================================================================
;(function()
local s = tab:new_section("Clantag", "Right")
local U = {
    mode  = s:new_combobox("Clantag", { "Off", "Static", "Marquee", "Typewriter" }, "Off"),
    text  = s:new_textbox("Tag text", "unsyk", "unsyk"),
    speed = s:new_slider("Tag speed", 100, 1000, 350, 0, "ms"),
}
st.ui.ct = U
local cache = {}
st.ctag = function(name)
    if type(name) ~= "string" or name == "" or type(clantag) ~= "table" then return nil end
    local now = os.clock()
    local c = cache[name]
    if c and now - c.t < 30 then return c.v end
    local ok, f = pcall(clantag.format, name, name)
    local tag = nil
    if ok and type(f) == "string" then tag = string.match(f, "^%[(.-)%]") end
    if tag == "" then tag = nil end
    cache[name] = { t = now, v = tag }
    return tag
end
local last = nil
local function apply()
    local m = U.mode:get()
    local txt = string.sub(tostring(U.text:get() or ""), 1, 32)
    local key = m .. "|" .. txt .. "|" .. tostring(U.speed:get())
    if key == last then return end
    last = key
    if m == "Off" or txt == "" then
        pcall(clantag.reset)
    else
        pcall(clantag.set, txt, string.lower(m), U.speed:get() / 1000)
    end
end
local was = false
client.on_tick(function()
    if type(clantag) ~= "table" then return end
    if UNSYK_PROF.tick % 32 ~= 0 then return end     -- settings are polled, not pushed: twice a second is plenty
    if U.mode:get() == "Off" and not was then return end
    was = U.mode:get() ~= "Off"
    apply()
end)
client.set_event_callback("shutdown", function()
    if was and type(clantag) == "table" then pcall(clantag.reset) end
end)
end)()

-- ======================================================================
-- RAGE TWEAKS: conditional hitchance (we are in the air / unscoped sniper / target crouching), a min damage
-- floor (stops 2-8 dmg wallbangs) and lethal (min damage drops to the target's hp when that is lower).
-- Every 0 / off = the cheat menu value is left alone. Overrides are re-sent every tick while they apply
-- (the body-aim code calls rage.reset), and released once when they stop applying.
-- ======================================================================
do
local s_rg  = tab:new_section("Rage", "Right")
local rg_air = s_rg:new_slider("Hitchance in air", 0, 100, 0, 0, "%")
local rg_ns  = s_rg:new_slider("Hitchance unscoped", 0, 100, 0, 0, "%")
local rg_dk  = s_rg:new_slider("Hitchance vs crouched", 0, 100, 0, 0, "%")
local rg_md  = s_rg:new_slider("Min damage (0 menu)", 0, 100, 0, 0, "hp")
local rg_le  = s_rg:new_toggle("Lethal min damage", false)
-- lower hitchance while we still move = the shot goes out while auto stop is braking instead of after a full stop
local rg_mv  = s_rg:new_slider("Hitchance moving", 0, 100, 0, 0, "%")
st.ui.rg = { air = rg_air, ns = rg_ns, dk = rg_dk, md = rg_md, le = rg_le, mv = rg_mv }

local R = { hc = nil, md = nil, hc_base = nil, md_base = nil }
-- what we asked for vs what the cheat reports back (logged on every shot: shows whether the overrides stick)
st.rg_ov = function()
    local okh, h = pcall(rage.get_hitchance)
    local okm, m = pcall(rage.get_min_damage)
    return { hc = R.hc, md = R.md, rhc = okh and h or nil, rmd = okm and m or nil }
end

local function unscoped_sniper()
    local ok, w = pcall(weapon.get_active)
    if not ok or type(w) ~= "table" then
        ok, w = pcall(client.get_weapon)
        if not ok or type(w) ~= "table" then return false end
    end
    local sniper = w.is_sniper == true or (type(w.type) == "string" and string.find(w.type, "Sniper") ~= nil)
    return sniper and w.is_scoped == false
end

local function release(kind)
    if kind == "hc" then
        local ok = pcall(rage.override_hitchance, nil)
        if not ok and R.hc_base then pcall(rage.override_hitchance, R.hc_base) end
    else
        local ok = pcall(rage.override_min_damage, nil)
        if not ok and R.md_base then pcall(rage.override_min_damage, R.md_base) end
    end
end

client.on_tick(function()
    local air, ns, dk, mdv, le = rg_air:get(), rg_ns:get(), rg_dk:get(), rg_md:get(), rg_le:get()
    local mv = rg_mv:get()
    -- no-spread mode (own section below) wins over every hitchance and min damage here
    local N = st.ns
    local nhc = N and N.active and N.hc or nil
    local nmd = N and N.active and N.md or nil
    -- DT peek (held key, own section below) wins over no-spread too
    local DP = st.dtp
    local dhc = DP and DP.active and DP.hc or nil
    local dmd = DP and DP.active and DP.md or nil
    local FP = st.fdp
    if not dhc then dhc = FP and FP.active and FP.hc or nil end
    if not dmd then dmd = FP and FP.active and FP.md or nil end
    if air <= 0 and ns <= 0 and dk <= 0 and mv <= 0 and mdv <= 0 and not le and not nhc and not nmd
        and not dhc and not dmd then
        if R.hc then release("hc"); R.hc = nil end
        if R.md then release("md"); R.md = nil end
        return
    end
    local okt, t = pcall(rage.get_target)
    t = (okt and type(t) == "table") and t or nil
    local tinfo = nil
    if t and t.player ~= nil then
        local oki, ti = pcall(entity.get_info, t.player)
        if oki and type(ti) == "table" then tinfo = ti end
    end

    -- hitchance: first that applies wins
    local hc = nil
    local mst = my_state()
    if dhc then
        hc = dhc
    elseif nhc then
        hc = nhc
    elseif air > 0 and mst == "air" then
        hc = air
    elseif mv > 0 and mst == "move" then
        hc = mv
    elseif ns > 0 and unscoped_sniper() then
        hc = ns
    elseif dk > 0 and tinfo and tinfo.is_crouching == true then
        hc = dk
    end
    if hc then
        if R.hc == nil then
            local okb, b = pcall(rage.get_hitchance)
            R.hc_base = (okb and type(b) == "number") and b or R.hc_base
        end
        pcall(rage.override_hitchance, hc)
        R.hc = hc
    elseif R.hc then
        release("hc")
        R.hc = nil
    end

    -- min damage: floor, then lethal
    local md = mdv > 0 and mdv or nil
    if R.md == nil then
        local okb, b = pcall(rage.get_min_damage)
        if okb and type(b) == "number" then R.md_base = b end
    end
    if le and tinfo then
        local hp = tonumber(tinfo.health)
        if hp and hp > 0 then
            local cur = md or R.md_base
            if cur == nil or hp < cur then md = math.max(1, math.floor(hp)) end
        end
    end
    if dmd then md = dmd elseif nmd then md = nmd end
    if md then
        pcall(rage.override_min_damage, md)
        R.md = md
    elseif R.md then
        release("md")
        R.md = nil
    end
end)
end

-- ======================================================================
-- NO-SPREAD MODE. On a no-spread server every bullet goes where it is aimed, so the cheat's accuracy gate only costs
-- time. While active: hitchance drops to "Hitchance", min damage follows the target's hp (lethal; half of it with a
-- weapon that double taps, because the cheat's DT fires a pair), the built-in "baim after misses" is 0, and our Quick
-- stop stays off. Rage tweaks (above) reads st.ns.hc / st.ns.md, so the two never fight over one override.
-- Learned in game (build 90b70b21ad): ui.reference reaches nothing in this cheat's menu (196 auto stop names and the
-- double tap toggle all failed), so the cheat's own auto stop can NOT be switched from Lua: it has to be turned off by
-- hand on no-spread servers. The cheat's DT does work (Deagle fires arrive in pairs) although get_double_tap_charge
-- reads 0. The client's inaccuracy reads the same on spread and no-spread servers, so there is no auto-detect.
-- ======================================================================
;(function()
local s_ns    = tab:new_section("No spread", "Right")
local ns_on   = s_ns:new_toggle("No-spread mode", false)
local ns_key  = s_ns:new_keybind("Toggle key", "Toggle", "N")   -- flips the mode (XOR with the switch)
local ns_hc   = s_ns:new_slider("Hitchance", 0, 100, 1, 0, "%")
local ns_md   = s_ns:new_slider("Min damage (0 = lethal)", 0, 100, 0, 0, "hp")
local ns_half = s_ns:new_toggle("Half hp with DT weapon", true)
local ns_ba   = s_ns:new_toggle("No baim after misses", true)
st.ui.ns = { on = ns_on, hc = ns_hc, md = ns_md, half = ns_half, ba = ns_ba }

local N = { active = false, hc = nil, md = nil, nxt = 0, ba_saved = nil, ba_set = false }
st.ns = N

local function ba_off(want)
    if want then
        if not N.ba_set then
            local ok, v = pcall(rage.get_resolver_baim_after_misses)
            N.ba_saved = (ok and type(v) == "number") and v or nil
        end
        pcall(rage.set_resolver_baim_after_misses, 0)
        N.ba_set = true
    elseif N.ba_set then
        if N.ba_saved then pcall(rage.set_resolver_baim_after_misses, N.ba_saved) end
        N.ba_saved, N.ba_set = nil, false
    end
end

-- bolt-action snipers fire once; everything else can come out as a DT pair
local function dt_weapon()
    local ok, w = pcall(weapon.get_active)
    if not ok or type(w) ~= "table" then return true end
    if w.is_knife or w.is_grenade then return false end
    local n = string.upper(tostring(w.name or "") .. " " .. tostring(w.id or ""))
    if string.find(n, "SSG") or string.find(n, "AWP") or string.find(n, "SCOUT") then return false end
    return true
end

client.on_tick(function()
    local act = (ns_on:get() == true) ~= (ns_key:get() == true)
    if act ~= N.active then
        N.active, N.nxt = act, 0
        pcall(client.color_log, 120, 200, 255, act
            and "[NS] no-spread mode ON (switch the cheat's own auto stop off in its menu)"
            or "[NS] no-spread mode off")
        if not act then ba_off(false) end
    end
    if not act then N.hc, N.md = nil, nil; return end
    local hc = ns_hc:get()
    N.hc = hc > 0 and hc or nil
    local md = ns_md:get()
    if md <= 0 then
        local hp = 100
        local okt, t = pcall(rage.get_target)
        if okt and type(t) == "table" and t.player ~= nil then
            local oki, ti = pcall(entity.get_info, t.player)
            local h = (oki and type(ti) == "table") and tonumber(ti.health) or nil
            if h and h > 0 then hp = math.min(h, 100) end
        end
        md = (ns_half:get() and dt_weapon()) and math.ceil(hp / 2) or hp
    end
    N.md = math.max(1, math.floor(md))
    local now = globals.realtime()
    if now >= N.nxt then
        N.nxt = now + 1
        ba_off(ns_ba:get() == true)
    end
end)

client.set_event_callback("shutdown", function() ba_off(false) end)
end)()

-- ======================================================================
-- DT PEEK (idea from phobia's "Double tap peek"): while the key is held, min damage drops to what the double
-- tap pair needs (half the target's hp, or "Damage" if set; 50 before the ragebot has a target, so it picks one
-- up the tick they show) and hitchance to "Hitchance". The first shot goes out the moment we come into view
-- and the DT teleport carries the peek. Rage tweaks reads st.dtp and lets it win over everything (no-spread
-- included). Shots log dtp=true while it is held.
-- ======================================================================
;(function()
local s_dp   = tab:new_section("DT peek", "Left")
local dp_on  = s_dp:new_toggle("DT peek", false)
local dp_key = s_dp:new_keybind("Key", "Hold", "LeftAlt")   -- click the key box in the window to pick another key
local dp_dmg = s_dp:new_slider("Damage (0 = half hp)", 0, 100, 0, 0, "hp")
local dp_hc  = s_dp:new_slider("Hitchance", 0, 100, 35, 0, "%")
st.ui.dp = { on = dp_on, key = dp_key, dmg = dp_dmg, hc = dp_hc }

local D = { active = false, hc = nil, md = nil }
st.dtp = D

client.on_tick(function()
    local act = dp_on:get() == true and dp_key:get() == true
    if act ~= D.active then
        D.active = act
        if act then pcall(client.color_log, 120, 200, 255, "[DTP] DT peek held") end
    end
    if not act then D.hc, D.md = nil, nil; return end
    local hc = dp_hc:get()
    D.hc = hc > 0 and hc or nil
    local md = dp_dmg:get()
    if md <= 0 then
        local hp = 100
        local okt, t = pcall(rage.get_target)
        if okt and type(t) == "table" and t.player ~= nil then
            local oki, ti = pcall(entity.get_info, t.player)
            local h = (oki and type(ti) == "table") and tonumber(ti.health) or nil
            if h and h > 0 then hp = math.min(h, 100) end
        end
        md = math.ceil(hp / 2)
    end
    D.md = math.max(1, math.floor(md))
end)
end)()

-- ======================================================================
-- FAKE DUCK PEEK: the user reports kills come more often when peeking with fake duck. The cheat's fake duck can't
-- be read or switched from Lua, so bind THIS key to the same key as the cheat's fake duck. While held: optional
-- hitchance / min damage overrides (0 = leave the menu value) and every shot is tagged fdk=true so the feed can
-- compare fake-duck peeks against normal ones (`hvh events --kind shot`). Rage tweaks lets DT peek win over it.
-- ======================================================================
;(function()
local s_fp   = tab:new_section("Fake duck peek", "Left")
local fp_on  = s_fp:new_toggle("Fake duck peek", false)
local fp_key = s_fp:new_keybind("Key", "Hold", nil)   -- same key as the cheat's fake duck
local fp_dmg = s_fp:new_slider("Damage (0 menu)", 0, 100, 0, 0, "hp")
local fp_hc  = s_fp:new_slider("Hitchance (0 menu)", 0, 100, 0, 0, "%")
st.ui.fp = { on = fp_on, key = fp_key, dmg = fp_dmg, hc = fp_hc }

local F = { active = false, hc = nil, md = nil }
st.fdp = F

client.on_tick(function()
    local act = fp_on:get() == true and fp_key:get() == true
    if act ~= F.active then
        F.active = act
        if act then pcall(client.color_log, 120, 200, 255, "[FDP] fake duck peek held") end
    end
    if not act then F.hc, F.md = nil, nil; return end
    local hc, md = fp_hc:get(), fp_dmg:get()
    F.hc = hc > 0 and hc or nil
    F.md = md > 0 and math.floor(md) or nil
end)
end)()

-- ======================================================================
-- QUICK STOP: our own auto stop, so it knows what the cheat's cannot (no-spread mode, weapon, when to let go).
-- The cheat's auto stop cannot be read or switched from Lua (see No spread): switch it off in the cheat menu while
-- this one runs, or both brake at once and the self-test below cannot tell which one worked.
-- How: the local character is a Roblox model, so the methods are (1) "Velocity": cap the root part's horizontal
-- velocity before every physics step, (2) "Move": Humanoid:Move bound right after the control script's render step,
-- (3) "WalkSpeed": WalkSpeed scaled down, put back on release. "Keep speed" 0 = full stop, else the cap is that % of
-- the speed we had when the stop started. Each stop checks our speed 4 ticks in; on "Auto" a method that never halved
-- it in 3 tries is dropped and the next one is used ([QS] line + diag event).
-- When: the ragebot has a target, we are on the ground, the weapon is not a knife / grenade (snipers only if set) and
-- no-spread mode is off. Lets go 0.12s after our shot (room for the DT pair) and rests "Rest after shot"; gives up
-- after "Max hold" without a shot. Every shot logs qs = {spd, ttf (ticks from target seen to fire), m, kept}, also
-- with Quick stop off, so the cheat's own auto stop gets measured too. A "qs rig" diag describes the character once.
-- ======================================================================
;(function()
local s_qs    = tab:new_section("Quick stop", "Left")
local qs_mode = s_qs:new_combobox("Quick stop", { "Off", "On target", "Snipers only" }, "Off")
local qs_how  = s_qs:new_combobox("Method", { "Auto", "Velocity", "Move", "WalkSpeed" }, "Auto")
local qs_keep = s_qs:new_slider("Keep speed", 0, 100, 0, 0, "%")
local qs_hold = s_qs:new_slider("Max hold", 100, 1000, 400, 0, "ms")
local qs_rest = s_qs:new_slider("Rest after shot", 0, 1500, 400, 0, "ms")
st.ui.qs = { mode = qs_mode, how = qs_how, keep = qs_keep, hold = qs_hold, rest = qs_rest }

local Players = game:GetService("Players")
local RunS = game:GetService("RunService")
local ORDER = { "Velocity", "Move", "WalkSpeed" }
local Q = { want = false, since = 0, fired_at = 0, rest_until = 0, s0 = 0, cap = 0, k = 0, check_at = 0,
    checked = true, method = nil, dead = {}, works = {}, stat = {}, ws_saved = nil, ws_val = nil, ws_set = false,
    tgt_at = nil, tick = 0, stops = 0, bound = false, last_shot = nil }
for _, m in ipairs(ORDER) do Q.stat[m] = { ok = 0, bad = 0 } end
st.qs = Q
st.qs_shot = function() return Q.last_shot end

local function rig()
    local ch = nil
    pcall(function()
        local m = me()
        if typeof(m) == "Instance" then
            if m:IsA("Player") then ch = m.Character elseif m:IsA("Model") then ch = m end
        end
    end)
    if not ch then
        local lp = Players.LocalPlayer
        ch = lp and lp.Character or nil
    end
    if not ch then return nil end
    local hum = ch:FindFirstChildOfClass("Humanoid")
    local root = (hum and hum.RootPart) or ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
    return ch, hum, root
end

local function my_speed()
    local ok, s = pcall(movement.get_speed)
    if ok and type(s) == "number" then return s end
    local oki, info = pcall(entity.get_info, me())
    if oki and type(info) == "table" and type(info.speed) == "number" then return info.speed end
    return 0
end

local function flat(v) return Vector3.new(v.X, 0, v.Z) end

local function pick()
    local m = qs_how:get()
    if m ~= "Auto" then return m end
    for _, k in ipairs(ORDER) do
        if not Q.dead[k] then return k end
    end
    return nil
end

local function ws_restore()
    if not Q.ws_set then return end
    pcall(function()
        local _, hum = rig()
        -- only if nothing else changed it meanwhile (the game may set its own speed per weapon)
        if hum and Q.ws_saved and math.abs(hum.WalkSpeed - (Q.ws_val or -1)) < 0.01 then hum.WalkSpeed = Q.ws_saved end
    end)
    Q.ws_set, Q.ws_saved, Q.ws_val = false, nil, nil
end

local function apply()
    if not Q.want or not Q.method then return end
    local _, hum, root = rig()
    if Q.method == "Velocity" and root then
        local v = root.AssemblyLinearVelocity
        local h = flat(v)
        if h.Magnitude > Q.cap then
            local s = (Q.cap > 0 and h.Magnitude > 0) and (Q.cap / h.Magnitude) or 0
            root.AssemblyLinearVelocity = Vector3.new(v.X * s, v.Y, v.Z * s)
        end
    elseif Q.method == "WalkSpeed" and hum then
        if not Q.ws_set then Q.ws_saved, Q.ws_set = hum.WalkSpeed, true end
        Q.ws_val = (Q.ws_saved or 16) * Q.k
        hum.WalkSpeed = Q.ws_val
    end
end

local function bind()
    if Q.bound then return end
    Q.bound = pcall(function()
        RunS:BindToRenderStep("unsyk_qs", Enum.RenderPriority.Input.Value + 5, function()
            if not (Q.want and Q.method == "Move") then return end
            local _, hum, root = rig()
            if not hum then return end
            local d = Vector3.new(0, 0, 0)
            if Q.k > 0 and root then
                local h = flat(root.AssemblyLinearVelocity)
                if h.Magnitude > 0.1 then d = h.Unit * Q.k end
            end
            hum:Move(d, false)
        end)
    end)
end
pcall(function() RunS.Stepped:Connect(function() if Q.want then pcall(apply) end end) end)

local function diag(what, extra)
    local ev = { kind = "diag", what = what }
    for k, v in pairs(extra or {}) do ev[k] = v end
    if st.push then pcall(st.push, ev) end
end

local function start(now)
    Q.method = pick()
    if not Q.method then return end
    if Q.method == "Move" then bind() end
    Q.want, Q.since = true, now
    Q.k = qs_keep:get() / 100
    Q.s0 = my_speed()
    local _, _, root = rig()
    Q.cap = root and flat(root.AssemblyLinearVelocity).Magnitude * Q.k or 0
    Q.check_at, Q.checked = Q.tick + 4, false
    Q.stops = Q.stops + 1
end

local function stop()
    Q.want = false
    ws_restore()
end

-- self-test: did this stop at least halve our speed within 4 ticks? (only judged when we were really moving)
local function check()
    Q.checked = true
    if Q.s0 < 4 or Q.k >= 0.5 then return end
    local s = my_speed()
    local m, r = Q.method, Q.stat[Q.method]
    if not r then return end
    if s <= Q.s0 * 0.5 + 0.5 then
        r.ok, r.bad = r.ok + 1, 0
        if not Q.works[m] then
            Q.works[m] = true
            pcall(client.color_log, 120, 255, 160, string.format("[QS] %s stops us (%.1f -> %.1f in 4 ticks)", m, Q.s0, s))
            diag("qs method", { m = m, ok = true, s0 = Q.s0, s4 = s })
        end
    else
        r.bad = r.bad + 1
        if r.ok == 0 and r.bad >= 3 and qs_how:get() == "Auto" and not Q.dead[m] then
            Q.dead[m] = true
            local nxt = pick()
            pcall(client.color_log, 255, 200, 120, string.format("[QS] %s did not slow us (%.1f -> %.1f), next: %s",
                m, Q.s0, s, tostring(nxt or "none left")))
            diag("qs method", { m = m, ok = false, s0 = Q.s0, s4 = s, next = nxt })
        end
    end
end

client.on_tick(function()
    Q.tick = Q.tick + 1
    local now = globals.realtime()
    local okt, t = pcall(rage.get_target)
    local has = okt and type(t) == "table" and t.player ~= nil
    if has then Q.tgt_at = Q.tgt_at or Q.tick else Q.tgt_at = nil end

    local mode, want = qs_mode:get(), false
    if mode ~= "Off" and has and not (st.ns and st.ns.active) and my_state() ~= "air" then
        local okw, w = pcall(weapon.get_active)
        w = (okw and type(w) == "table") and w or {}
        if not w.is_knife and not w.is_grenade and (mode ~= "Snipers only" or w.is_sniper == true) then want = true end
    end
    if want and Q.fired_at > 0 and now >= Q.fired_at + 0.12 and now < Q.rest_until then want = false end
    if want and Q.want and now - Q.since > qs_hold:get() / 1000 then
        want = false
        Q.rest_until = now + 0.5
    end
    if want and not Q.want then start(now) elseif not want and Q.want then stop() end
    if Q.want then
        pcall(apply)
        if not Q.checked and Q.tick >= Q.check_at then check() end
    end
    if has then pcall(st.aw_tick, t) elseif Q.aw then pcall(st.aw_flush, false) end
end)

-- AIM WAIT: one event per ragebot target episode (target held -> fire or target lost), so we can see WHY it
-- holds fire: the target's live hitchance (rage.get_target().hitchance) vs what it fires at, our speed, scope,
-- inaccuracy and predicted damage, sampled every 4 ticks (max 24 samples). Episodes shorter than 8 ticks
-- without a fire are skipped. kind="aimwait".
local function r1(x) x = tonumber(x); return x and math.floor(x * 10 + 0.5) / 10 or nil end
st.aw_tick = function(t)
    local W = Q.aw
    local s = my_speed()
    if not W then
        W = { t0 = Q.tick, n = 0, s0 = r1(s), smin = s, hc = {}, sp = {}, dm = {}, sc = 0, keys = nil,
            who = nil, tc = 0, tl = nil,
            -- the target snapshot outlives a shot by ~16 ticks: an episode that starts right after one is not a wait
            post = Q.fired_at > 0 and globals.realtime() - Q.fired_at < 0.35 }
        pcall(function() W.who = entity.get_player_name(t.player) end)
        if not Q.aw_keys then
            local k = {}
            for kk, vv in pairs(t) do k[#k + 1] = tostring(kk) .. ":" .. type(vv) end
            W.keys = table.concat(k, ",")
            Q.aw_keys = true
        end
        Q.aw = W
    end
    W.n = W.n + 1
    if s < W.smin then W.smin = s end
    if t.time ~= W.tl then W.tc, W.tl = W.tc + 1, t.time end   -- how often the ragebot re-scanned (stale if 1)
    local okw, w = pcall(weapon.get_active)
    if okw and type(w) == "table" then
        W.wep = W.wep or w.name
        if w.is_scoped then W.sc = W.sc + 1 end
    end
    if W.n % 4 == 1 and #W.hc < 24 then
        W.hc[#W.hc + 1] = r1(t.hitchance) or -1
        W.sp[#W.sp + 1] = r1(s)
        W.dm[#W.dm + 1] = r1(t.damage) or -1
        if not W.inacc then
            local oki, ia = pcall(weapon.get_inaccuracy)
            local oks, sp = pcall(weapon.get_spread)
            W.inacc, W.spread = oki and r1((tonumber(ia) or 0) * 1000) or nil, oks and r1((tonumber(sp) or 0) * 1000) or nil
        end
    end
    W.part = t.part_name or W.part
end
st.aw_flush = function(fired, e)
    local W = Q.aw
    Q.aw = nil
    if not W then return end
    if not fired and (W.n < 8 or W.post) then return end
    local ov = nil
    if st.rg_ov then pcall(function() ov = st.rg_ov() end) end
    if st.push then pcall(st.push, {
        kind = "aimwait", fired = fired, ticks = W.n, who = W.who, wep = W.wep, part = W.part,
        scoped = W.n > 0 and math.floor(W.sc * 100 / W.n) or 0, s0 = W.s0, smin = r1(W.smin),
        hc = W.hc, sp = W.sp, dm = W.dm, fhc = e and r1(e.hitchance) or nil, fdmg = e and r1(e.damage) or nil,
        ov = ov,
        inacc = W.inacc, spread = W.spread, qs = Q.want and Q.method or (qs_mode:get() ~= "Off" and "idle" or "off"),
        mst = my_state(), keys = W.keys, scans = W.tc, ns = (st.ns and st.ns.active) or nil,
    }) end
end

client.set_event_callback("aim_fire", function(e)
    pcall(st.aw_flush, true, e)
    local now = globals.realtime()
    Q.last_shot = { spd = math.floor(my_speed() * 10 + 0.5) / 10, ttf = Q.tgt_at and (Q.tick - Q.tgt_at) or nil,
        m = Q.want and Q.method or nil, kept = Q.want and Q.k or nil }
    Q.fired_at = now
    Q.rest_until = now + 0.12 + qs_rest:get() / 1000
end)

-- one description of the character, so we know which method can work in this game
task.delay(6, function()
    local out = {}
    pcall(function()
        local ch, hum, root = rig()
        out.char = ch and (ch.ClassName .. ":" .. ch.Name) or "none"
        if hum then
            out.hum = string.format("ws=%.1f jp=%.1f ps=%s state=%s", hum.WalkSpeed, hum.JumpPower or -1,
                tostring(hum.PlatformStand), tostring(hum:GetState()))
        else
            out.hum = "none"
        end
        out.root = root and (root.ClassName .. ":" .. root.Name .. (root.Anchored and " anchored" or "")) or "none"
        if root then
            local k = {}
            for _, c in ipairs(root:GetChildren()) do k[#k + 1] = c.ClassName .. ":" .. c.Name end
            out.root_kids = table.concat(k, ",")
            out.vel = tostring(root.AssemblyLinearVelocity)
        end
        if ch then
            local k = {}
            for _, c in ipairs(ch:GetChildren()) do
                if #k < 40 then k[#k + 1] = c.ClassName .. ":" .. c.Name end
            end
            out.char_kids = table.concat(k, ",")
        end
    end)
    pcall(function()
        local ps = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
        if ps then
            local k = {}
            for _, c in ipairs(ps:GetChildren()) do k[#k + 1] = c.Name end
            out.pscripts = table.concat(k, ",")
        end
    end)
    out.speed = my_speed()
    diag("qs rig", out)
    if st.flog then
        pcall(st.flog, 150, 200, 255, "[QS] rig: " .. tostring(out.char) .. " | hum " .. tostring(out.hum) .. " | root "
            .. tostring(out.root))
    end
end)

client.set_event_callback("shutdown", function()
    Q.want = false
    ws_restore()
    pcall(function() RunS:UnbindFromRenderStep("unsyk_qs") end)
end)
end)()

-- ======================================================================
-- HUD + EFFECTS (ideas from "phobia beta", rebuilt in the window's look: same palette, Gotham, rounded cards).
-- Panels live in one ScreenGui (unsyk_hud): watermark (top right), keybind list (left), target panel (right of the
-- crosshair), hit log toasts (top left), damage numbers (next to the crosshair). Sounds use the cheat's presets
-- (sounds.override_hitsound / killsound). Kill / hit effects are drawn in the world with render3d (immediate mode,
-- every paint); without render3d they are skipped. Accent follows the window (st.accent, set by ui_build).
-- ======================================================================
-- (own function, not a do-block: the main chunk is at the 200-local limit and do-block locals count too)
;(function()
local s_hud   = tab:new_section("HUD", "Right")
local hd_wm   = s_hud:new_toggle("Watermark", false)
local hd_keys = s_hud:new_toggle("Keybind list", false)
local hd_tgt  = s_hud:new_toggle("Target panel", false)
local hd_log  = s_hud:new_toggle("Hit log", false)
local hd_dmg  = s_hud:new_toggle("Damage numbers", false)
local s_fx    = tab:new_section("Effects", "Right")
local SND = { "Off", "skeet", "neverlose", "fatality", "bell", "bubble", "pop", "ding", "sparkle", "laser", "bip", "punch",
    "crack", "bite", "bonk", "arcade", "metallic", "zap", "click", "coin", "glass", "retro", "hit" }
local fx_kill = s_fx:new_combobox("Kill effect", { "Off", "Shockwave", "Ascend", "Pillar" }, "Off")
local fx_hit  = s_fx:new_combobox("Hit effect", { "Off", "Ring", "Spark" }, "Off")
local fx_snd  = s_fx:new_combobox("Hit sound", SND, "Off")
local fx_ksnd = s_fx:new_combobox("Kill sound", SND, "Off")
local fx_vol  = s_fx:new_slider("Sound volume", 0, 100, 70, 0, "%")
local fx_etr  = s_fx:new_toggle("Enemy tracers", false)
local fx_etl  = s_fx:new_slider("Tracer time", 0.3, 3, 1, 1, "s")

local C = {
    win = Color3.fromRGB(14, 14, 17), line = Color3.fromRGB(40, 40, 46), card = Color3.fromRGB(27, 27, 32),
    ctl = Color3.fromRGB(56, 56, 63), txt = Color3.fromRGB(176, 176, 184), hi = Color3.fromRGB(242, 242, 245),
    mut = Color3.fromRGB(104, 104, 112), bad = Color3.fromRGB(225, 90, 90), warn = Color3.fromRGB(230, 180, 80),
    good = Color3.fromRGB(110, 230, 120),
}
local ACC0 = Color3.fromRGB(150, 200, 60)
do
    local A = { Lime = { 150, 200, 60 }, Blue = { 80, 150, 255 }, Pink = { 230, 95, 170 }, Purple = { 150, 115, 240 },
        Orange = { 240, 150, 60 }, Red = { 225, 70, 70 }, White = { 220, 220, 220 } }
    local ok, a = pcall(database.read, "ui_acc")
    if ok and type(a) == "string" and A[a] then ACC0 = Color3.fromRGB(A[a][1], A[a][2], A[a][3]) end
end
local function accent() return st.accent or ACC0 end
local F, FM, FB = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold
local TS = game:GetService("TweenService")

local H = {}
local okg = pcall(function()
    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    H.new = new
    H.corner = function(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
    H.stroke = function(o) new("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
    H.label = function(parent, text, col, size, font, xa)
        return new("TextLabel", { BackgroundTransparency = 1, Text = text, TextColor3 = col, Font = font or F, TextSize = size or 12,
            TextXAlignment = xa or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, BorderSizePixel = 0 }, parent)
    end
    H.panel = function(parent, w, h)
        local f = new("Frame", { Size = UDim2.new(0, w, 0, h), BackgroundColor3 = C.win, BackgroundTransparency = 0.08,
            BorderSizePixel = 0, Visible = false }, parent)
        H.corner(f, 8)
        H.stroke(f)
        return f
    end
    H.mark = function(parent, x, y)
        local m = new("Frame", { Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, x, 0, y), Rotation = 45, BackgroundColor3 = accent(),
            BorderSizePixel = 0 }, parent)
        H.corner(m, 2)
        local hole = new("Frame", { Size = UDim2.new(0, 3, 0, 3), Position = UDim2.new(0.5, -1, 0.5, -1), BackgroundColor3 = C.win,
            BorderSizePixel = 0 }, m)
        H.corner(hole, 1)
        return m
    end
    local gui = new("ScreenGui", { Name = "unsyk_hud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 55 })
    pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)
    gui.Parent = game:GetService("CoreGui")
    H.gui = gui
end)
if not okg then H.gui = nil end

local function vp_size()
    local ok, v = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if ok and v then return v.X, v.Y end
    return 1280, 720
end
local function short(s, n) s = tostring(s or "?"); return #s > n and (string.sub(s, 1, n - 1) .. "…") or s end

-- ---------- watermark ----------
local WM = {}
if H.gui then
    WM.f = H.panel(H.gui, 220, 26)
    WM.m = H.mark(WM.f, 12, 9)
    WM.name = H.label(WM.f, "unsyk", C.hi, 12, FB); WM.name.Position = UDim2.new(0, 28, 0, 0); WM.name.Size = UDim2.new(0, 40, 1, 0)
    WM.rest = H.label(WM.f, "", C.txt, 12, FM); WM.rest.Position = UDim2.new(0, 70, 0, 0); WM.rest.Size = UDim2.new(1, -80, 1, 0)
end
local frames, fps, fps_t, wm_at = 0, 0, 0, 0
local function wm_paint(now)
    if not WM.f then return end
    frames = frames + 1
    if now - fps_t >= 1 then fps, frames, fps_t = frames, 0, now end
    if not hd_wm:get() then WM.f.Visible = false; return end
    if now >= wm_at then
        wm_at = now + 0.5
        local who = "owner"
        if type(UNSYK_AUTH) == "table" and type(UNSYK_AUTH.info) == "function" then
            local ok, i = pcall(UNSYK_AUTH.info)
            if ok and type(i) == "table" and i.name then who = tostring(i.name) end
        end
        local okl, lat = pcall(client.latency)
        local ms = (okl and type(lat) == "number") and math.floor(lat * 1000 + 0.5) or 0
        WM.rest.Text = string.format("%s·  %s  ·  %dms  ·  %dfps", UNSYK_CHANNEL == "beta" and "beta  " or "", short(who, 14), ms, fps)
        local w = 80 + math.max(80, WM.rest.TextBounds.X)
        local vx = vp_size()
        WM.f.Size = UDim2.new(0, w, 0, 26)
        WM.f.Position = UDim2.new(0, vx - w - 16, 0, 16)
        WM.m.BackgroundColor3 = accent()
    end
    WM.f.Visible = true
end

-- ---------- keybind list ----------
local KB = { rows = {} }
local KEYS = {
    { "Manual left", function() return man_l:get() end, "hold" },
    { "Manual right", function() return man_r:get() end, "hold" },
    { "Manual back", function() return man_b:get() end, "hold" },
    { "Invert", function() return ds_mode:get() == "Static" and ds_inv:get() end, "on" },
    { "Dodge AA", function() return st.phase == "dodge" end, "active" },
    { "Flick", function() return st.fk ~= nil and st.fk.on == true end, "on" },
    { "Peek AA", function() return st.peek_active == true end, "active" },
    { "Double tap", function() return dt_state().menu == true end, "on" },
    { "DT peek", function() return st.dtp ~= nil and st.dtp.active == true end, "hold" },
}
if H.gui then
    KB.f = H.panel(H.gui, 170, 30)
    local t = H.label(KB.f, "keybinds", C.hi, 12, FB); t.Position = UDim2.new(0, 12, 0, 0); t.Size = UDim2.new(1, -24, 0, 28)
    KB.line = H.new("Frame", { Size = UDim2.new(1, -24, 0, 1), Position = UDim2.new(0, 12, 0, 28), BackgroundColor3 = accent(),
        BorderSizePixel = 0 }, KB.f)
    for i = 1, #KEYS do
        local l = H.label(KB.f, KEYS[i][1], C.txt, 12, F); l.Size = UDim2.new(1, -24, 0, 18)
        local r = H.label(KB.f, KEYS[i][3], C.mut, 11, FM, Enum.TextXAlignment.Right); r.Size = UDim2.new(1, -24, 0, 18)
        KB.rows[i] = { l = l, r = r }
    end
end
local kb_at = 0
local function kb_paint(now)
    if not KB.f then return end
    if not hd_keys:get() then KB.f.Visible = false; return end
    if now < kb_at then return end
    kb_at = now + 0.1
    local n = 0
    for i, k in ipairs(KEYS) do
        local ok, on = pcall(k[2])
        local row = KB.rows[i]
        if ok and on then
            n = n + 1
            local y = 32 + (n - 1) * 18
            row.l.Position, row.r.Position = UDim2.new(0, 12, 0, y), UDim2.new(0, 12, 0, y)
            row.l.Visible, row.r.Visible = true, true
        else
            row.l.Visible, row.r.Visible = false, false
        end
    end
    if n == 0 then KB.f.Visible = false; return end
    local _, vy = vp_size()
    KB.f.Size = UDim2.new(0, 170, 0, 36 + n * 18)
    KB.f.Position = UDim2.new(0, 16, 0, math.floor(vy * 0.42))
    KB.line.BackgroundColor3 = accent()
    KB.f.Visible = true
end

-- ---------- target panel ----------
local TP = {}
if H.gui then
    TP.f = H.panel(H.gui, 210, 70)
    TP.name = H.label(TP.f, "", C.hi, 13, FB); TP.name.Position = UDim2.new(0, 12, 0, 8); TP.name.Size = UDim2.new(1, -60, 0, 16)
    TP.hp = H.label(TP.f, "", C.txt, 12, FM, Enum.TextXAlignment.Right); TP.hp.Position = UDim2.new(1, -60, 0, 8)
    TP.hp.Size = UDim2.new(0, 48, 0, 16)
    TP.track = H.new("Frame", { Size = UDim2.new(1, -24, 0, 3), Position = UDim2.new(0, 12, 0, 29), BackgroundColor3 = C.ctl,
        BorderSizePixel = 0 }, TP.f)
    H.corner(TP.track, 2)
    TP.fill = H.new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = accent(), BorderSizePixel = 0 }, TP.track)
    H.corner(TP.fill, 2)
    TP.l1 = H.label(TP.f, "", C.txt, 11); TP.l1.Position = UDim2.new(0, 12, 0, 37); TP.l1.Size = UDim2.new(1, -24, 0, 14)
    TP.l2 = H.label(TP.f, "", C.mut, 11); TP.l2.Position = UDim2.new(0, 12, 0, 51); TP.l2.Size = UDim2.new(1, -24, 0, 14)
end
local tp_at = 0
local function tp_paint(now)
    if not TP.f then return end
    if not hd_tgt:get() then TP.f.Visible = false; return end
    if now < tp_at then return end
    tp_at = now + 0.1
    local okt, t = pcall(rage.get_target)
    if not okt or type(t) ~= "table" or t.player == nil then TP.f.Visible = false; return end
    local p = t.player
    local okn, name = pcall(entity.get_player_name, p)
    local oki, info = pcall(entity.get_info, p)
    info = (oki and type(info) == "table") and info or {}
    local hp = tonumber(info.health) or 100
    TP.name.Text = short(okn and name or "?", 20)
    TP.hp.Text = string.format("%d hp", math.floor(hp + 0.5))
    TP.fill.Size = UDim2.new(math.clamp(hp / 100, 0, 1), 0, 1, 0)
    TP.fill.BackgroundColor3 = hp <= 30 and C.bad or accent()
    local dist = ""
    local okp, mp = pcall(entity.get_player_position, me())
    local okq, tp = pcall(entity.get_player_position, p)
    if okp and okq and mp and tp then dist = string.format("%.0fst  ·  ", (tp - mp).Magnitude) end
    TP.l1.Text = dist .. short(info.weapon_name or "?", 12) .. "  ·  " .. tostring(info.state or "?")
    local r = rs_find(p)
    if r and r.d then
        TP.l2.Text = string.format("res %s %+d  ·  %s", tostring(r.d.src), tonumber(r.d.off) or 0, tostring(r.d.pat or "?"))
    elseif r then
        TP.l2.Text = "res -  ·  " .. (intel_pattern(r.rec, rs_n))
    else
        TP.l2.Text = "res -"
    end
    local vx, vy = vp_size()
    TP.f.Position = UDim2.new(0, math.floor(vx / 2 + 70), 0, math.floor(vy / 2 + 40))
    TP.f.Visible = true
end

-- ---------- hit log toasts ----------
local LOG = { list = {} }
local function toast(text, col)
    if not H.gui or not hd_log:get() then return end
    local f = H.panel(H.gui, 300, 24)
    local dot = H.new("Frame", { Size = UDim2.new(0, 6, 0, 6), Position = UDim2.new(0, 10, 0.5, -3), BackgroundColor3 = col,
        BorderSizePixel = 0 }, f)
    H.corner(dot, 3)
    local l = H.label(f, text, C.hi, 12, FM); l.Position = UDim2.new(0, 24, 0, 0); l.Size = UDim2.new(1, -32, 1, 0)
    local w = math.min(420, math.max(160, l.TextBounds.X + 36))
    f.Size = UDim2.new(0, w, 0, 24)
    table.insert(LOG.list, 1, { f = f, t = globals.realtime() })
    while #LOG.list > 6 do
        local old = table.remove(LOG.list)
        pcall(function() old.f:Destroy() end)
    end
    for i, e in ipairs(LOG.list) do
        local y = 60 + (i - 1) * 28
        if i == 1 then
            e.f.Position = UDim2.new(0, 4, 0, y)
            e.f.BackgroundTransparency = 1
            e.f.Visible = true
            TS:Create(e.f, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { Position = UDim2.new(0, 16, 0, y), BackgroundTransparency = 0.08 }):Play()
        else
            TS:Create(e.f, TweenInfo.new(0.18), { Position = UDim2.new(0, 16, 0, y) }):Play()
        end
    end
end
local function log_paint(now)
    for i = #LOG.list, 1, -1 do
        local e = LOG.list[i]
        if now - e.t > 4.5 then
            table.remove(LOG.list, i)
            local f = e.f
            pcall(function()
                for _, d in ipairs(f:GetDescendants()) do
                    if d:IsA("TextLabel") then TS:Create(d, TweenInfo.new(0.25), { TextTransparency = 1 }):Play() end
                    if d:IsA("Frame") then TS:Create(d, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play() end
                    if d:IsA("UIStroke") then TS:Create(d, TweenInfo.new(0.25), { Transparency = 1 }):Play() end
                end
                TS:Create(f, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
            end)
            task.delay(0.3, function() pcall(function() f:Destroy() end) end)
        end
    end
end

-- ---------- damage numbers ----------
local function dmg_number(dmg, head, killed)
    if not H.gui or not hd_dmg:get() then return end
    local vx, vy = vp_size()
    local x, y = vx / 2 + 30 + math.random(0, 22), vy / 2 - 6 - math.random(0, 16)
    local l = H.label(H.gui, "-" .. tostring(math.floor(dmg + 0.5)), killed and accent() or (head and C.hi or C.txt),
        killed and 18 or 15, FB, Enum.TextXAlignment.Center)
    l.Size = UDim2.new(0, 60, 0, 20)
    l.Position = UDim2.new(0, x - 30, 0, y)
    l.TextStrokeTransparency = 0.6
    TS:Create(l, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Position = UDim2.new(0, x - 30, 0, y - 30), TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
    task.delay(0.95, function() pcall(function() l:Destroy() end) end)
end

-- ---------- world effects (render3d) ----------
local R3 = (type(render3d) == "table" and render3d) or (type(Drawing3D) == "table" and Drawing3D)
    or (type(render) == "table" and (render.d3d or render._3d)) or nil
if R3 and (type(R3.ring) ~= "function" or type(R3.line) ~= "function") then R3 = nil end
local FX = {}
local function out_quint(u) local v = 1 - u; return 1 - v * v * v * v * v end
local function out_cubic(u) local v = 1 - u; return 1 - v * v * v end
local function ring(p, r, th, col, a) if a > 0.02 then pcall(R3.ring, p, r, th, col, 1 - a, true) end end
local function seg(a, b, th, col, al) if al > 0.02 then pcall(R3.line, a, b, col, th, 1 - al, true) end end
local function add_fx(kind, mode, pos)
    if not R3 or not pos or mode == "Off" then return end
    FX[#FX + 1] = { kind = kind, mode = mode, pos = pos, t0 = globals.realtime(), seed = math.random() * 6.2832 }
    if #FX > 8 then table.remove(FX, 1) end
end
local function fx_paint(now)
    if not R3 then return end
    for i = #FX, 1, -1 do
        local m = FX[i]
        local age = now - m.t0
        local col = accent()
        local p = m.pos
        if m.kind == "kill" then
            if age > 1.1 then table.remove(FX, i)
            elseif m.mode == "Shockwave" then
                for k = 0, 2 do
                    local u = (age - k * 0.14) / 0.72
                    if u > 0 and u < 1 then ring(p, 0.5 + out_quint(u) * 7.5, 0.05 + 0.13 * (1 - u), col, 1 - u) end
                end
            elseif m.mode == "Ascend" then
                for k = 0, 2 do
                    local u = age / 0.82 - k * 0.09
                    if u > 0 and u < 1 then
                        local e = 1 - (1 - u) * (1 - u)
                        ring(p + Vector3.new(0, 0.1 + e * 4.4, 0), 0.8 + e * 1.8, 0.08, col, 1 - u)
                    end
                end
            elseif m.mode == "Pillar" then
                local u = math.min(1, age / 0.9)
                seg(p, p + Vector3.new(0, 4 + 12 * out_cubic(u), 0), 0.22 * (1 - u) + 0.04, col, 1 - u)
                ring(p, 0.6 + out_quint(u) * 3, 0.1, col, 1 - u)
            end
        else
            if age > 0.5 then table.remove(FX, i)
            else
                local u = age / 0.5
                if m.mode == "Ring" then
                    ring(p, 0.25 + out_cubic(u) * 1.1, 0.06, col, 1 - u)
                elseif m.mode == "Spark" then
                    for k = 0, 5 do
                        local a = m.seed + k * 1.0472
                        local d = Vector3.new(math.cos(a), 0.35 * math.sin(a * 2), math.sin(a))
                        seg(p + d * (0.2 + u * 0.6), p + d * (0.5 + u * 1.4), 0.05, col, 1 - u)
                    end
                end
            end
        end
    end
end

-- ---------- enemy tracers ----------
-- The API has no event for incoming shots (enemy ammo never changes, nothing is spawned), so a tracer is INFERRED:
-- st.etrace_hit() runs when we take damage (shooter = nearest enemy, red line to our head) and st.etrace_shot(e)
-- runs when an enemy's ammo drops (accent line toward us), if a server ever reports it.
local ETR = {}
local etr_last = 0
local function etr_add(from, to, hit)
    if not R3 or not fx_etr:get() or not from or not to then return end
    ETR[#ETR + 1] = { a = from, b = to, hit = hit, t0 = globals.realtime() }
    if #ETR > 12 then table.remove(ETR, 1) end
end
local function etr_head(e)
    local ok, p = pcall(entity.get_player_hitbox_position, e, "head")
    if ok and typeof and typeof(p) == "Vector3" then return p end
    return nil
end
st.etrace_shot = function(e)
    if globals.realtime() - etr_last < 0.15 then return end
    local mh = etr_head(me())
    local eh = etr_head(e)
    if mh and eh then etr_last = globals.realtime(); etr_add(eh, mh - Vector3.new(0, 0.6, 0), false) end
end
st.etrace_hit = function()
    if not fx_etr:get() then return end
    local mh = etr_head(me())
    if not mh then return end
    local best, bd = nil, 1e9
    for _, e in ipairs(entity.get_enemies()) do
        local h = etr_head(e)
        if h and (h - mh).Magnitude < bd then best, bd = h, (h - mh).Magnitude end
    end
    if best then etr_last = globals.realtime(); etr_add(best, mh, true) end
end
local function etr_paint(now)
    if not R3 then return end
    local life = fx_etl:get()
    for i = #ETR, 1, -1 do
        local m = ETR[i]
        local age = now - m.t0
        if age > life then table.remove(ETR, i)
        else
            local u = 1 - age / life
            seg(m.a, m.b, m.hit and 0.07 or 0.04, m.hit and C.bad or accent(), u)
        end
    end
end

-- ---------- sounds (cheat presets) ----------
local snd = { hit = nil, kill = nil, vol = nil, at = 0 }
local function snd_tick(now)
    if now < snd.at then return end
    snd.at = now + 0.5
    if type(sounds) ~= "table" then return end
    local h, k, v = fx_snd:get(), fx_ksnd:get(), fx_vol:get() / 100
    if h ~= snd.hit or v ~= snd.vol then
        if h == "Off" then
            if snd.hit and snd.hit ~= "Off" then
                if not pcall(sounds.reset_hitsound) then pcall(sounds.override_hitsound, nil) end
            end
        else
            pcall(sounds.override_hitsound, h, v, 1)
        end
    end
    if k ~= snd.kill or v ~= snd.vol then
        if k == "Off" then
            if snd.kill and snd.kill ~= "Off" then
                if not pcall(sounds.reset_killsound) then pcall(sounds.override_killsound, nil) end
            end
        else
            pcall(sounds.override_killsound, k, v, 1)
        end
    end
    snd.hit, snd.kill, snd.vol = h, k, v
end

-- ---------- events ----------
local fired = {}   -- [target name] = { point, src } of the last shot (hit/miss events carry no id / position)
local function tname(t)
    local ok, n = pcall(entity.get_player_name, t)
    return (ok and type(n) == "string") and n or "?"
end
local function hb(x)
    x = tostring(x or "?")
    return string.lower(x)
end
client.set_event_callback("aim_fire", function(e)
    if not e then return end
    local okr, ri = pcall(rs_info, e.target)
    fired[tname(e.target)] = { point = (typeof and typeof(e.point) == "Vector3") and e.point or nil,
        src = okr and type(ri) == "table" and ri.src or nil }
end)
client.set_event_callback("aim_hit", function(e)
    if not e then return end
    local name = tname(e.target)
    local f = fired[name] or {}
    local dmg = tonumber(e.damage) or 0
    local left = tonumber(e.health_remaining)
    local killed = left ~= nil and left <= 0
    local head = string.find(hb(e.hitbox), "head", 1, true) ~= nil
    if killed then
        toast(string.format("killed %s  ·  %s  ·  %d dmg", short(name, 16), hb(e.hitbox), dmg), accent())
        local pos = nil
        local okq, p = pcall(entity.get_player_position, e.target)
        if okq and typeof and typeof(p) == "Vector3" then pos = p end
        if not pos then
            local r = rs_find(e.target)
            if r and r.ent then
                local okr, p2 = pcall(entity.get_player_position, r.ent)
                if okr and typeof and typeof(p2) == "Vector3" then pos = p2 end
            end
        end
        pos = pos or f.point
        if pos then add_fx("kill", fx_kill:get(), pos - Vector3.new(0, 2.8, 0)) end
    else
        toast(string.format("hit %s  ·  %s  ·  %d dmg  ·  %s left", short(name, 16), hb(e.hitbox), dmg,
            left and tostring(math.floor(left + 0.5)) or "?"), head and C.hi or C.txt)
    end
    if f.point then add_fx("hit", fx_hit:get(), f.point) end
    dmg_number(dmg, head, killed)
end)
client.set_event_callback("aim_miss", function(e)
    if not e then return end
    local name = tname(e.target)
    local reason = tostring(e.reason or "?")
    if reason == "death" then return end
    local f = fired[name] or {}
    local extra = (reason == "resolver" and f.src) and ("  ·  " .. tostring(f.src)) or ""
    toast(string.format("missed %s  ·  %s  ·  %s%s", short(name, 16), hb(e.hitbox), reason, extra),
        reason == "resolver" and C.bad or C.warn)
end)

client.set_event_callback("paint", function()
    local now = globals.realtime()
    pcall(wm_paint, now)
    pcall(kb_paint, now)
    pcall(tp_paint, now)
    pcall(log_paint, now)
    pcall(fx_paint, now)
    pcall(etr_paint, now)
    pcall(snd_tick, now)
end)

client.set_event_callback("shutdown", function()
    pcall(function() if H.gui then H.gui:Destroy() end end)
    if type(sounds) == "table" then
        if snd.hit and snd.hit ~= "Off" then pcall(sounds.reset_hitsound) end
        if snd.kill and snd.kill ~= "Off" then pcall(sounds.reset_killsound) end
    end
end)
if not R3 then client.color_log(255, 200, 120, "[unsyk] render3d not found: kill / hit effects are off") end
end)()

-- ======================================================================
-- LIVE SERVER FEED: batches events and POSTs them to YOUR ingest endpoint (Caddy -> receiver.py)
-- URL + token live in the menu / script database, never in this file.
-- Events: hit, shot, intel (every 5s), state (every 5s)
-- ======================================================================
local s_sv   = tab:new_section("Live server feed", "Right")
local sv_url = s_sv:new_textbox("Server", "https://logs.example.com/ingest", (function()
    local u = database.read("sv_url")
    return (type(u) == "string" and u ~= "") and u or "https://feed.sites.exxo.world/ingest"
end)(), function(v)
    pcall(function() database.write("sv_url", v); database.flush() end)
end)
local sv_tok = s_sv:new_textbox("Token", "paste ingest token", database.read("sv_tok") or "", function(v)
    pcall(function() database.write("sv_tok", v); database.flush() end)
    task.spawn(function() if st.sv_check_owner then pcall(st.sv_check_owner) end end)
end)
-- these three survive reloads (the loader reloads the script on every update)
local function sv_saved(key, default)
    local ok, v = pcall(database.read, key)
    if ok and v ~= nil then return v end
    return default
end
local function sv_save(key, v) pcall(function() database.write(key, v); database.flush() end) end
-- Streaming is always on for license users. Only the owner (a master token the server accepts, checked
-- once per load and whenever the Token box changes) may switch it off.
st.sv_owner = false
-- feed / remote-control console lines are for the owner only (license users never see the feed exists)
st.flog = function(r, g, b, msg) if st.sv_owner then client.color_log(r, g, b, msg) end end
local sv_on  = s_sv:new_toggle("Stream", sv_saved("sv_on", true) == true, function(v)
    if v == false and not st.sv_owner then
        pcall(st.flog, 255, 200, 120, "[FEED] streaming is always on for license users")
        return
    end
    sv_save("sv_on", v)
end)
st.sv_live = function() return (not st.sv_owner) or sv_on:get() == true end
local sv_srv = s_sv:new_combobox("Spread", { "Unknown", "Spread", "No spread" }, sv_saved("sv_srv", "Unknown"),
    function(v) sv_save("sv_srv", v) end)

-- my active weapon: name, scope, live spread/inaccuracy (spread ~0 everywhere may mean a no-spread server)
local function sv_myweapon()
    local w = {}
    local oka, a = pcall(weapon.get_active)
    if oka and type(a) == "table" then
        w.wep, w.scoped = a.name, a.is_scoped
    end
    if not w.wep then
        local okn, n = pcall(entity.get_player_weapon_name, entity.get_local_player())
        if okn then w.wep = n end
    end
    local oks, sp = pcall(weapon.get_spread)
    if oks and type(sp) == "number" then w.spr = math.floor(sp * 10000 + 0.5) / 10000 end
    local oki, ia = pcall(weapon.get_inaccuracy)
    if oki and type(ia) == "number" then w.inacc = math.floor(ia * 10000 + 0.5) / 10000 end
    return w
end

local function sv_server()
    local okj, job = pcall(function() return game.JobId end)
    local okp, place = pcall(function() return game.PlaceId end)
    return (okj and type(job) == "string") and job or nil, okp and place or nil
end

local sv_queue = {}
local sv_session = "s" .. tostring(math.floor(tick()))
local sv_next_snap = 0
local sv_backoff_until = 0
local sv_last_err = 0
local sv_sent, sv_failed = 0, 0
local sv_last_job = nil
local ctrl_v = 0          -- remote config version currently applied (0 = none)
local sv_ctrl_on          -- "Remote control (Claude)" toggle, created further down

local function sv_push(ev)
    if not st.sv_live() then return end
    ev.t = ev.t or globals.realtime()
    ev.cv = ctrl_v
    ev.srv = sv_srv:get()
    -- no-spread mode on = the player says this server has no spread; nsh = DT follow-up shifts so far
    if st.ns and st.ns.active then
        ev.ns, ev.nsh = true, st.ns.shifts
        if ev.srv == "Unknown" then ev.srv = "No spread" end
    end
    if ev.my == nil then
        local okw, w = pcall(sv_myweapon)
        if okw then ev.my = w end
    end
    sv_queue[#sv_queue + 1] = ev
    if #sv_queue > 300 then table.remove(sv_queue, 1) end
end
st.push = sv_push   -- for sections defined above the feed

local function sv_err(msg)
    if globals.realtime() - sv_last_err > 20 then
        sv_last_err = globals.realtime()
        st.flog(255, 90, 90, "[FEED] " .. msg)
    end
end

-- auth headers for the feed: the loader's license session (X-Session) when logged in, else the master token box
st.auth = function(tok)
    if type(UNSYK_AUTH) == "table" and type(UNSYK_AUTH.headers) == "function" then
        local ok, h = pcall(UNSYK_AUTH.headers)
        if ok and type(h) == "table" then return h end
    end
    if type(tok) == "string" and #tok >= 24 then return { ["X-Token"] = tok } end
    return nil
end

-- owner = the Token box holds a master token the server accepts (GET /config answers 200 only to it or a session,
-- so the request goes with X-Token alone). Anyone else gets the stream forced on.
st.sv_check_owner = function()
    local tok, u = sv_tok:get(), sv_url:get()
    local base = type(u) == "string" and string.match(u, "^(https://[^/]+)") or nil
    if type(tok) ~= "string" or #tok < 24 or not base then st.sv_owner = false; st.sv_owner_checked = true return end
    local ok, res = pcall(function()
        return HttpService:RequestAsync({ Url = base .. "/config", Method = "GET", Headers = { ["X-Token"] = tok } })
    end)
    local was = st.sv_owner
    st.sv_owner = ok and type(res) == "table" and (res.StatusCode or res.Status) == 200 or false
    st.sv_owner_checked = true
    if st.sv_owner ~= was then
        pcall(st.flog, 120, 255, 160, st.sv_owner and "[FEED] owner token verified: Stream events can be switched off"
            or "[FEED] streaming is locked on (license user)")
    end
end

local function sv_flush()
    if #sv_queue == 0 then return end
    local url, tok = sv_url:get(), sv_tok:get()
    local hdr = st.auth(tok)
    if type(url) ~= "string" or string.sub(url, 1, 8) ~= "https://" or not hdr then
        sv_err("set a https:// ingest URL and log in with the loader (or paste the token) first")
        return
    end
    hdr["Content-Type"] = "application/json"
    local batch = sv_queue
    sv_queue = {}
    local ok, res = pcall(function()
        return HttpService:RequestAsync({
            Url = url, Method = "POST",
            Headers = hdr,
            Body = HttpService:JSONEncode({ session = sv_session, beat = st.lic_bt, user = (function()
                local okp, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
                return okp and lp and lp.Name or nil
            end)(), uid = (function()
                local okp, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
                return okp and lp and lp.UserId or nil
            end)(), events = batch }),
        })
    end)
    local code = ok and type(res) == "table" and (res.StatusCode or res.Status) or nil
    if ok and type(res) == "table" and res.Success ~= false then
        sv_sent = sv_sent + #batch
    else
        sv_failed = sv_failed + #batch
        sv_err("post failed: " .. (ok and ("status " .. tostring(code)) or tostring(res)))
        -- keep the batch for one retry if there is room, and back off
        if #sv_queue + #batch <= 300 then
            for i = #batch, 1, -1 do table.insert(sv_queue, 1, batch[i]) end
        end
        sv_backoff_until = globals.realtime() + 10
    end
end

task.spawn(function()
    pcall(st.sv_check_owner)
    while true do
        task.wait(2)
        -- a license user's toggle snaps back on (the menu click itself is refused in the callback)
        if not st.sv_owner and not sv_on:get() then pcall(function() sv_on:set(true) end) end
        if st.sv_live() and globals.realtime() >= sv_backoff_until then pcall(sv_flush) end
    end
end)

-- BUILD HEALTH for the admin panel: kind="load" once (build + why the previous run stopped), kind="err" with the
-- new callback errors every 20s (UNSYK_ERRS, filled by the guard at the top), kind="stop" when UNSYK_STOP runs.
;(function()
    local okp, prev = pcall(database.read, "aa_stop")
    local why, at = nil, nil
    if okp and type(prev) == "string" and prev ~= "" then
        why, at = string.match(prev, "^(.*)|(%d+)$")
        pcall(function() database.write("aa_stop", ""); database.flush() end)
    end
    sv_push({ kind = "load", ver = UNSYK_VERSION or "local", build = UNSYK_BUILD, ch = UNSYK_CHANNEL,
        prev_stop = why, prev_stop_at = tonumber(at) })
    local function flush_errs()
        for _, r in pairs(UNSYK_ERRS.list) do
            if r.n > r.sent then
                sv_push({ kind = "err", where = r.where, msg = r.msg, n = r.n - r.sent, total = r.n,
                    ver = UNSYK_VERSION or "local", build = UNSYK_BUILD, ch = UNSYK_CHANNEL })
                r.sent = r.n
            end
        end
    end
    UNSYK_STOP_HOOK = function(reason)
        flush_errs()
        sv_push({ kind = "stop", why = reason, ver = UNSYK_VERSION or "local", build = UNSYK_BUILD, ch = UNSYK_CHANNEL })
    end
    task.spawn(function()
        while not UNSYK_STOPPED do
            task.wait(20)
            pcall(flush_errs)
        end
    end)
    -- PERF: every 30s the 12 most expensive callbacks (ms of Lua per second, avg us per call, worst call ms),
    -- the total, fps (calls of the first paint callback) and how much of the window we were alive.
    task.spawn(function()
        local last, alive_s, secs = {}, 0, 0
        local function snap()
            for _, P in ipairs(UNSYK_PROF.list) do last[P] = { t = P.t, n = P.n } end
            for _, P in ipairs(UNSYK_PROF.list) do P.max = 0 end
        end
        snap()
        local t0 = os.clock()
        while not UNSYK_STOPPED do
            task.wait(1)
            secs = secs + 1
            local oka, al = pcall(entity.is_alive, entity.get_local_player())
            if oka and al then alive_s = alive_s + 1 end
            if secs >= 30 then
                pcall(function()
                    local dt = math.max(os.clock() - t0, 0.001)
                    local rows, srows, total, fps = {}, {}, 0, nil
                    for _, P in ipairs(UNSYK_PROF.list) do
                        local l = last[P] or { t = 0, n = 0 }
                        local dtt, dn = P.t - l.t, P.n - l.n
                        if not P.sub then total = total + dtt end
                        if P.where == "paint" then fps = math.floor(dn / dt + 0.5) end
                        if dn > 0 then
                            local into = P.sub and srows or rows
                            into[#into + 1] = { w = P.where, ln = P.ln, ms = math.floor(dtt / dt * 1000 * 100 + 0.5) / 100,
                                us = math.floor(dtt / dn * 1e6 + 0.5), max = math.floor(P.max * 1000 * 10 + 0.5) / 10,
                                hz = math.floor(dn / dt + 0.5) }
                        end
                    end
                    local function best(a, k)
                        table.sort(a, function(x, y) return x.ms > y.ms end)
                        local o = {}
                        for i = 1, math.min(k, #a) do o[i] = a[i] end
                        return o
                    end
                    local top, sub = best(rows, 12), best(srows, 16)
                    sv_push({ kind = "diag", what = "perf", fps = fps, alive = math.floor(alive_s / secs * 100 + 0.5),
                        lua_ms = math.floor(total / dt * 1000 * 100 + 0.5) / 100, ncb = #UNSYK_PROF.list, top = top, sub = sub,
                        ver = UNSYK_VERSION or "local", build = UNSYK_BUILD, ch = UNSYK_CHANNEL })
                end)
                snap()
                t0, secs, alive_s = os.clock(), 0, 0
            end
        end
    end)
end)()

-- hits taken (compact, with a short timeline)
local sv_last_hit = 0
client.on_tick(function()
    if not st.sv_live() then sv_last_hit = fd_total return end
    if fd_total > sv_last_hit then
        local e = fd_hits[#fd_hits]
        sv_last_hit = fd_total
        if e then
            local tl = {}
            local from = math.max(1, #e.rows - 11)
            for i = from, #e.rows do
                local r = e.rows[i]
                tl[#tl + 1] = { ms = math.floor((e.last.n - r.n) * e.tms), phase = r.phase, state = r.state, side = r.side,
                    lim = math.floor(r.lim), man = r.man, choke = r.choke, spd = math.floor(r.speed or 0),
                    roll = r.roll, fp = r.fp }
            end
            local en = {}
            for _, x in ipairs(e.enemies) do
                en[#en + 1] = { name = x.name, wep = x.wep, dist = math.floor(x.dist), scoped = x.scoped, pat = x.pat, side = x.side, nxt = x.nxt,
                    tpa = st.tp_age and st.tp_age(x.name) or nil, tpx = st.tp_peak and st.tp_peak(x.name) or nil }
            end
            sv_push({ kind = "hit", dmg = e.dmg, hp_before = e.hp_before, hp_after = e.hp_after, ping = math.floor(e.ping),
                flip_age = e.flip_age, dt = e.dt, settings = e.settings, timeline = tl, enemies = en,
                tp = st.tp_recent and st.tp_recent(e.t) or nil })
        end
    end
end)

-- my shots
-- e.id links fire -> hit/miss. intel at fire time = what the enemy's AA looked like when we shot.
local function sv_tname(rec, target)
    if rec and rec.name then return rec.name end
    local ok, n = pcall(entity.get_player_name, target)
    if ok and type(n) == "string" and n ~= "" then return n end
    return tostring(target)
end
local function sv_num(x) return type(x) == "number" and math.floor(x * 10 + 0.5) / 10 or nil end
client.set_event_callback("aim_fire", function(e)
    if not st.sv_live() or not e then return end
    local rec = find_rec(e.target)
    sv_push({ kind = "shot", result = "fire", id = e.id, hitbox = e.hitbox, target = sv_tname(rec, e.target),
        hc = sv_num(e.hitchance), pdmg = sv_num(e.damage), ryaw = sv_num(e.resolved_yaw),
        intel = rec and rec_summary(rec) or nil, rs = rs_info(e.target),
        qs = st.qs_shot and st.qs_shot() or nil, ov = st.rg_ov and st.rg_ov() or nil,
        dtp = (st.dtp and st.dtp.active) or nil, fdk = (st.fdp and st.fdp.active) or nil, tpa =st.tp_age and st.tp_age(sv_tname(rec, e.target)) or nil,
        cmp = st.rx2 and st.rx2.cmp(e.target) or nil, tag = st.ctag and st.ctag(sv_tname(rec, e.target)) or nil })
end)
client.set_event_callback("aim_hit", function(e)
    if not st.sv_live() or not e then return end
    local rec = find_rec(e.target)
    sv_push({ kind = "shot", result = "hit", id = e.fid or e.id, hitbox = e.hitbox, dmg = e.damage, target = sv_tname(rec, e.target),
        hp_left = e.health_remaining, bt = e.backtrack_ticks })
end)
client.set_event_callback("aim_miss", function(e)
    if not st.sv_live() or not e then return end
    local rec = find_rec(e.target)
    sv_push({ kind = "shot", result = "miss", id = e.fid or e.id, reason = tostring(e.reason), hitbox = e.hitbox,
        target = sv_tname(rec, e.target), intel = rec and rec_summary(rec) or nil })
end)

-- periodic snapshots: enemy intel + my state
client.on_tick(function()
    if not st.sv_live() then return end
    local now = globals.realtime()
    if now < sv_next_snap then return end
    sv_next_snap = now + 5

    local list = {}
    for _, rec in ipairs(intel_order) do
        local label, next_in, next_side = intel_pattern(rec)
        list[#list + 1] = { name = rec.name, wep = rec.wep, dist = math.floor(rec.dist), state = rec.state,
            des = math.floor(rec.des_now or 0), side = rec.side, flips = rec.flips, pat = label,
            next_in = next_in, next_side = next_side, yaw_dt = math.floor(rec.ema_dy), defensive = rec.def_count,
            p_down = rec.p_down, p_up = rec.p_up, p_mid = rec.p_mid, tag = st.ctag and st.ctag(rec.name) or nil }
    end
    if #list > 0 then sv_push({ kind = "intel", players = list }) end

    local okh, hp = pcall(entity.get_player_health, me())
    local job, place = sv_server()
    if job and job ~= sv_last_job then
        sv_last_job = job
        sv_push({ kind = "server", job = job, place = place })
    end
    sv_push({ kind = "state", ver = UNSYK_VERSION or "local", build = UNSYK_BUILD, ch = UNSYK_CHANNEL, job = job and string.sub(job, 1, 8) or nil, hp = okh and hp or nil, my_state = my_state(), phase = st.phase, side = st.inv and "R" or "L",
        lim = st.cur_lim, dt = dt_state().text, inv = ds_mode:get(), mod = yaw_mod:get(), pitch = pitch_sel:get(),
        remote = st.ctrl_live and st.ctrl_live() or false, feed = { sent = sv_sent, failed = sv_failed },
        peek = st.ui and st.ui.px_mode:get() or nil, anim = st.ui and st.ui.an_mode:get() or nil,
        baim = st.ui and st.ui.rx_baim:get() or nil, rp = st.rp.info(),
        fk =(st.fk and st.fk.on) and { n = st.fk.flicks, nc = st.fk.nochoke, nofl = st.fk.nofl } or nil })
end)

s_sv:new_button("Test connection", function()
    sv_queue[#sv_queue + 1] = { kind = "test", t = globals.realtime(), msg = "hello from unsyk" }
    pcall(sv_flush)
    st.flog(200, 200, 200, string.format("[FEED] test sent. total sent=%d failed=%d", sv_sent, sv_failed))
end)

-- ======================================================================
-- ENEMY SHOTS: there is no incoming-shot event, so watch every enemy's clip ammo. A drop (same weapon,
-- not reloading) = they fired. If my health drops within 0.35s it hit me, else it missed (or was not
-- aimed at me: "los" says whether they had line of sight to my head, so analysis can filter on it).
-- Each shot records MY AA state at the moment they fired: this is the real hit-vs-miss comparison.
-- ======================================================================
do
local es_last = {}      -- [name] = { wep, ammo }
local es_wait = {}      -- shots waiting for the damage check
local Players = game:GetService("Players")

local function es_los(e, mypos)
    local okh, hp = pcall(entity.get_player_hitbox_position, e, "head")
    local okm, mh = pcall(entity.get_player_hitbox_position, me(), "head")
    if not okh or not hp or not okm or not mh then return nil end
    local ok, res = pcall(function()
        local params = RaycastParams.new()
        local lp = Players.LocalPlayer
        params.FilterDescendantsInstances = { lp and lp.Character }
        params.FilterType = Enum.RaycastFilterType.Exclude
        return workspace:Raycast(mh, hp - mh, params)
    end)
    if not ok then return nil end
    if res == nil then return true end
    return (res.Position - hp).Magnitude < 4    -- the ray stopped at their body, not a wall
end

local es_diag_done = false
local function es_diag(e)
    -- one-off: what does the weapon API give for an enemy? (pushed as a "diag" event, read with hvhctl)
    es_diag_done = true
    local d = { kind = "diag", what = "enemy weapon api" }
    local okn, name = pcall(entity.get_player_name, e)
    d.enemy, d.etype = okn and name or "?", typeof and typeof(e) or type(e)
    local ok1, w = pcall(weapon.get_active, e)
    d.active_ok, d.active_type = ok1, type(w)
    if ok1 and type(w) == "table" then
        local keys = {}
        for k, v in pairs(w) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
        table.sort(keys)
        d.active = table.concat(keys, " ")
    else
        d.active = tostring(w)
    end
    local ok2, a = pcall(weapon.get_ammo, e)
    d.ammo_ok, d.ammo = ok2, tostring(a)
    local ok3, wn = pcall(entity.get_player_weapon_name, e)
    d.wname = ok3 and tostring(wn) or ("err " .. tostring(wn))
    sv_push(d)
    client.log("[ESHOT] diag: " .. tostring(d.active) .. " | ammo=" .. tostring(d.ammo))
    -- second pass: does enemy ammo ever change, and what does the game spawn when people shoot?
    task.spawn(function()
        local seen, changes, samples = {}, 0, {}
        local added = {}
        local conn = nil
        pcall(function()
            conn = workspace.DescendantAdded:Connect(function(o)
                local k = o.ClassName .. ":" .. o.Name
                added[k] = (added[k] or 0) + 1
            end)
        end)
        local t0 = os.clock()
        while os.clock() - t0 < 30 do
            for _, e in ipairs(entity.get_enemies()) do
                local okn, nm = pcall(entity.get_player_name, e)
                local okw, w = pcall(weapon.get_active, e)
                if okn and okw and type(w) == "table" then
                    local key = tostring(nm) .. "|" .. tostring(w.name)
                    if seen[key] ~= nil and seen[key] ~= w.ammo then
                        changes = changes + 1
                        if #samples < 6 then samples[#samples + 1] = key .. " " .. tostring(seen[key]) .. "->" .. tostring(w.ammo) end
                    end
                    seen[key] = w.ammo
                end
            end
            task.wait()
        end
        if conn then pcall(function() conn:Disconnect() end) end
        local top = {}
        for k, n in pairs(added) do top[#top + 1] = { k, n } end
        table.sort(top, function(a, b) return a[2] > b[2] end)
        local lst = {}
        for i = 1, math.min(25, #top) do lst[#lst + 1] = top[i][1] .. "=" .. top[i][2] end
        local nk = 0
        for _ in pairs(seen) do nk = nk + 1 end
        sv_push({ kind = "diag", what = "enemy shot signals (30s)", ammo_changes = changes, ammo_keys = nk,
            ammo_samples = table.concat(samples, ", "), spawned = table.concat(lst, ", "), hooked = conn ~= nil })
        client.log(string.format("[ESHOT] 30s: %d enemy ammo changes; spawned: %s", changes, table.concat(lst, ", ")))
    end)
end

client.on_tick(function()
    if not st.sv_live() then return end
    local now = os.clock()
    local okp, mypos = pcall(entity.get_player_position, me())
    local okl, alive = pcall(entity.is_alive, me())
    if not es_diag_done then
        local list = entity.get_enemies()
        if list[1] then pcall(es_diag, list[1]) end
    end
    for _, e in ipairs(entity.get_enemies()) do
        local okn, name = st.ename(e)
        if okn and type(name) == "string" then
            local okw, w = pcall(weapon.get_active, e)
            if okw and type(w) == "table" and type(w.ammo) == "number" then
                local prev = es_last[name]
                if prev and prev.wep == w.name and w.ammo < prev.ammo and not w.is_reloading
                    and okl and alive and okp and mypos then
                    local okq, pos = st.epos(e)
                    if st.etrace_shot then pcall(st.etrace_shot, e) end
                    local rec = nil
                    for _, r in ipairs(intel_order) do
                        if r.name == name then rec = r; break end
                    end
                    es_wait[#es_wait + 1] = {
                        t = now, n0 = fd_total, name = name, wep = w.name,
                        dist = (okq and pos) and math.floor((pos - mypos).Magnitude) or nil,
                        los = es_los(e, mypos), scoped = w.is_scoped,
                        side = st.inv and "R" or "L", flip = st.n - (st.flip_n or 0), lim = math.floor(st.cur_lim or 0),
                        phase = st.phase, mst = my_state(), pat = rec and (intel_pattern(rec)) or nil,
                    }
                end
                es_last[name] = { wep = w.name, ammo = w.ammo }
            end
        end
    end
    -- resolve: did my health drop within 0.35s of their shot?
    local i = 1
    while i <= #es_wait do
        local s = es_wait[i]
        if now - s.t >= 0.35 then
            local hit, dmg = false, nil
            for _, h in ipairs(fd_hits) do
                if h.n > s.n0 and h.t >= s.t - 0.05 and h.t <= s.t + 0.35 then hit, dmg = true, h.dmg; break end
            end
            s.hit, s.dmg = hit, dmg
            s.t, s.n0 = nil, nil
            s.kind = "eshot"
            sv_push(s)
            table.remove(es_wait, i)
        else
            i = i + 1
        end
    end
    if #es_wait > 64 then table.remove(es_wait, 1) end
end)
end

-- ======================================================================
-- ENEMY TELEPORTS: a double tap shift moves a player several ticks of movement at once, so a teleport peek comes
-- out of cover and shoots in the same tick. Every tick, every enemy's horizontal position goes in a 0.5s ring.
-- v2: burst = straight-line move over the last 0.1s; pre = their path speed over the 0.2s before. Teleport =
-- burst - 1.25 x pre x 0.1s - 0.4 >= "Min jump" and burst speed >= "Run speed". (v1 subtracted a fixed 30 st/s
-- over 0.15s = 4.5 st, so a shift from standing never counted and only fast strafers did.) Windows, not single
-- ticks, so bursty replication is not mistaken for one. Respawns (> 40 studs) reset the ring. Hits carry
-- `tpx` per enemy = their biggest burst in the last 0.5s even below the threshold (to tune it from deaths).
-- Logged: kind="etp" per teleport (+ whether my health dropped within 0.35s), `tp` on every hit I take (latest
-- enemy teleport up to 0.5s before it), `tpa` (ms since their last teleport) per enemy on hits and on my shots.
-- Recharge per enemy = shortest gap seen between two of their teleports (0.4s floor); st.tp_ready(name) guesses
-- whether they have it now. A diag with the speed distribution goes out every 2 min to tune the thresholds.
-- ======================================================================
;(function()
local s_tp   = tab:new_section("Enemy teleports", "Right")
local tp_on  = s_tp:new_toggle("Detect teleports", true)
local tp_run = s_tp:new_slider("Run speed", 10, 80, 30, 0, " st/s")
local tp_min = s_tp:new_slider("Min jump", 1, 10, 2.5, 1, " st")
local tp_say = s_tp:new_toggle("Console line per teleport", false)
st.ui.tp = { on = tp_on, run = tp_run, min = tp_min, say = tp_say }

local W, PRE, KEEP = 0.1, 0.2, 0.5
local P = {}                                   -- [name] = { ring = {{t,x,z}}, last, rech, n, seen, pk.. }
local T = { recent = {}, wait = {}, spd = {}, ex = {}, step = {}, zero = 0, n = 0, diag_at = os.clock() + 120 }

local function rec_of(name)
    local r = P[name]
    if not r then r = { ring = {}, n = 0, seen = os.clock() }; P[name] = r end
    return r
end
st.tp_age = function(name)
    local r = P[name]
    if not r or not r.last then return nil end
    return math.floor((os.clock() - r.last) * 1000)
end
st.tp_ready = function(name)
    local r = P[name]
    if not r then return nil end
    if not r.last then return true end
    return os.clock() - r.last >= (r.rech or 1.0)
end
-- evidence even below the threshold: their biggest burst in the last 0.5s ("ex st over pre speed, ms ago")
st.tp_peak = function(name)
    local r = P[name]
    if not r or not r.pk_t or os.clock() - r.pk_t > 0.5 then return nil end
    return { ex = math.floor(r.pk * 10 + 0.5) / 10, bs = math.floor(r.pk_bs), vp = math.floor(r.pk_vp),
        ms = math.floor((os.clock() - r.pk_t) * 1000) }
end
st.tp_recent = function(t, late)
    for i = #T.recent, 1, -1 do
        local x = T.recent[i]
        if x.t <= t + (late or 0.05) and t - x.t <= 0.5 then
            return { name = x.name, ms = math.floor((t - x.t) * 1000), jump = x.jump, dist = x.dist, wep = x.wep }
        end
    end
    return nil
end

local function pct(a, p)
    if #a == 0 then return nil end
    table.sort(a)
    return math.floor(a[math.max(1, math.ceil(#a * p))] * 10 + 0.5) / 10
end

client.on_tick(function()
    if not tp_on:get() then return end
    local now = os.clock()
    local okp, mypos = pcall(entity.get_player_position, me())
    local run, jmin = tp_run:get(), tp_min:get()
    local okl, list = pcall(entity.get_enemies)
    if not okl or type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        local okn, name = st.ename(e)
        local okq, pos = st.epos(e)
        if okn and type(name) == "string" and okq and pos then
            local r = rec_of(name)
            local ring = r.ring
            local prev = ring[#ring]
            if prev and ((pos.X - prev[2]) ^ 2 + (pos.Z - prev[3]) ^ 2) > 1600 then   -- respawn / map teleport
                ring = {}; r.ring = ring; r.seen = now
            end
            if prev and #T.step < 4000 then
                local s = math.sqrt((pos.X - prev[2]) ^ 2 + (pos.Z - prev[3]) ^ 2)
                T.step[#T.step + 1] = s
                if s < 0.001 then T.zero = T.zero + 1 end
            end
            ring[#ring + 1] = { now, pos.X, pos.Z }
            while #ring > 2 and now - ring[1][1] > KEEP do table.remove(ring, 1) end
            -- burst = straight-line move over the last ~W; pre = PATH length (sum of steps, so A/D strafing
            -- keeps its speed) over the PRE seconds before that. Teleport = burst beyond what their own
            -- speed just before explains. (v1 subtracted a fixed 30 st/s, which hid shifts from standing.)
            local bi, pi = nil, nil
            for i = #ring - 1, 1, -1 do
                local age = now - ring[i][1]
                if not bi and age >= W then bi = i end
                if bi and age >= W + PRE then pi = i; break end
            end
            if bi and pi and now - r.seen > 1 then
                local base = ring[bi]
                local el = now - base[1]
                local d = math.sqrt((pos.X - base[2]) ^ 2 + (pos.Z - base[3]) ^ 2)
                local path = 0
                for i = pi + 1, bi do
                    path = path + math.sqrt((ring[i][2] - ring[i - 1][2]) ^ 2 + (ring[i][3] - ring[i - 1][3]) ^ 2)
                end
                local vpre = path / math.max(0.05, base[1] - ring[pi][1])
                local ex = d - vpre * el * 1.25 - 0.4
                local bs = d / el
                if #T.spd < 4000 then T.spd[#T.spd + 1] = bs; T.ex[#T.ex + 1] = ex end
                if not r.pk_t or now - r.pk_t > 0.5 or ex > r.pk then
                    r.pk, r.pk_t, r.pk_bs, r.pk_vp = ex, now, bs, vpre
                end
                if ex >= jmin and bs >= run and (not r.last or now - r.last > 0.4) then
                    if r.last and now - r.last < 3 then
                        local gap = now - r.last
                        r.rech = math.max(0.4, math.min(r.rech or gap, gap))
                    end
                    r.last, r.n = now, r.n + 1
                    T.n = T.n + 1
                    local okw, w = pcall(weapon.get_active, e)
                    -- their reported velocity at the jump: a shift moves the position while velocity stays at run
                    -- speed, a fast strafe has both high (tells real teleports from bursty replication)
                    local okv, vel = pcall(entity.get_player_velocity, e)
                    local vs = (okv and typeof(vel) == "Vector3") and math.floor(Vector3.new(vel.X, 0, vel.Z).Magnitude) or nil
                    local x = { t = now, name = name, jump = math.floor(ex * 10 + 0.5) / 10, spd = math.floor(bs), vs = vs,
                        pre = math.floor(vpre), d = math.floor(d * 10 + 0.5) / 10,
                        dist = (okp and mypos) and math.floor((pos - mypos).Magnitude) or nil,
                        wep = (okw and type(w) == "table") and w.name or nil, rech = r.rech and math.floor(r.rech * 1000) or nil,
                        n0 = fd_total, side = st.inv and "R" or "L", phase = st.phase, mst = my_state() }
                    T.recent[#T.recent + 1] = x
                    if #T.recent > 32 then table.remove(T.recent, 1) end
                    T.wait[#T.wait + 1] = x
                    ring = { { now, pos.X, pos.Z } }; r.ring = ring   -- one jump, one teleport
                    if tp_say:get() then
                        pcall(client.color_log, 200, 160, 255, string.format("[TP] %s jumped %.1f st (%s, %s st away)",
                            name, x.jump, tostring(x.wep), tostring(x.dist)))
                    end
                end
            end
        end
    end
    -- did my health drop within 0.35s of their teleport?
    local i = 1
    while i <= #T.wait do
        local s = T.wait[i]
        if now - s.t >= 0.35 then
            local hit, dmg = false, nil
            for _, h in ipairs(fd_hits) do
                if h.t >= s.t - 0.25 and h.t <= s.t + 0.35 then hit, dmg = true, h.dmg; break end
            end
            if st.sv_live() then
                sv_push({ kind = "etp", name = s.name, jump = s.jump, spd = s.spd, pre = s.pre, d = s.d, dist = s.dist, wep = s.wep,
                    rech = s.rech, v = 2, hit = hit, dmg = dmg, side = s.side, phase = s.phase, mst = s.mst, vs = s.vs })
            end
            table.remove(T.wait, i)
        else
            i = i + 1
        end
    end
    if now >= T.diag_at then
        T.diag_at = now + 120
        if #T.spd > 0 and st.sv_live() then
            sv_push({ kind = "diag", what = "enemy speed (2min)", n = #T.spd, tps = T.n, run = run, min = jmin,
                spd50 = pct(T.spd, 0.5), spd90 = pct(T.spd, 0.9), spd99 = pct(T.spd, 0.99), spdmax = pct(T.spd, 1),
                ex99 = pct(T.ex, 0.99), ex999 = pct(T.ex, 0.999), exmax = pct(T.ex, 1), v = 2,
                steps = #T.step, zero = #T.step > 0 and math.floor(T.zero * 100 / #T.step) or nil,
                st50 = pct(T.step, 0.5), st99 = pct(T.step, 0.99), stmax = pct(T.step, 1) })
        end
        T.spd, T.ex, T.step, T.zero, T.n = {}, {}, {}, 0, 0
    end
end)

-- a hit I take right after an enemy teleport: one console line (deaths matter most)
local seen_hits, pend = fd_total, {}
client.on_tick(function()
    if fd_total > seen_hits then
        seen_hits = fd_total
        if fd_hits[#fd_hits] then pend[#pend + 1] = fd_hits[#fd_hits] end
    end
    local h = pend[1]
    if not h or os.clock() - h.t < 0.3 then return end
    table.remove(pend, 1)
    if not tp_on:get() then return end
    local x = st.tp_recent(h.t, 0.3)
    h.tp = x
    if x then
        pcall(client.color_log, 255, 140, 200, string.format("[TP] -%d hp %dms after %s teleported %.1f st (%s, %s st away)",
            tonumber(h.dmg) or 0, x.ms, x.name, x.jump, tostring(x.wep), tostring(x.dist)))
    end
end)
end)()

-- ======================================================================
-- AIM PROBE (read-only diagnostics, changes nothing in play except one 0.5 deg camera nudge for one frame):
-- can a "shoot where the teleport peeker will be" feature exist at all? The ragebot's aim point cannot be set
-- from the documented API, so this checks what else there is:
--   caps (once, 10s after load): every function name in the cheat's libraries (undocumented ones show up), which
--     executor input functions exist (mouse1click, mousemoverel, keypress, VirtualInputManager, ...) WITHOUT
--     calling them, camera type / subject, how often something else writes the camera's CFrame per second.
--   cam (once, when alive and the mouse is still): rotate the camera 0.5 deg for one frame, then read
--     client.get_camera_angles_deg for 3 frames: if the yaw moved ~0.5 and stayed, camera writes reach the game's aim.
--   predict (2 alive-minutes): for the 3 nearest enemies, every 0.25s, movement.predict_position at +4/+8/+16
--     ticks vs where they really are then; compared with "they stay put" and "pos + velocity x time".
-- All as kind="diag", what="aim probe ...". Read with `hvhctl probe`.
-- ======================================================================
;(function()
local function push(what, ev)
    ev.kind, ev.what = "diag", what
    if st.push then pcall(st.push, ev) end
end
local function r2(x) x = tonumber(x); return x and math.floor(x * 100 + 0.5) / 100 or nil end

-- caps --------------------------------------------------------------
task.delay(10, function()
    local out = {}
    local libs = { "rage", "aa", "client", "input", "movement", "weapon", "entity", "plist", "globals", "render",
        "render3d", "sounds", "events", "ui", "database", "http", "utils", "exploit", "camera", "cmd", "math3d" }
    local env = (getfenv and getfenv(0)) or _G
    for _, name in ipairs(libs) do
        local ok, lib = pcall(function() return env[name] end)
        if ok and type(lib) == "table" then
            local fns = {}
            pcall(function()
                for k, v in pairs(lib) do
                    if type(v) == "function" then fns[#fns + 1] = tostring(k) end
                end
            end)
            table.sort(fns)
            out["lib_" .. name] = table.concat(fns, ",")
        elseif ok and lib ~= nil then
            out["lib_" .. name] = type(lib)
        end
    end
    local ex = {}
    for _, n in ipairs({ "mouse1click", "mouse1press", "mouse1release", "mouse2click", "mouse2press", "mouse2release",
        "mousemoverel", "mousemoveabs", "mousescroll", "keypress", "keyrelease", "keyclick", "getgenv", "getrenv",
        "hookfunction", "hookmetamethod", "getnamecallmethod", "getrawmetatable", "setreadonly", "newcclosure",
        "checkcaller", "firesignal", "getconnections", "fireclickdetector", "iswindowactive", "isrbxactive",
        "getcallingscript", "getsenv", "require", "identifyexecutor", "getexecutorname" }) do
        local ok, v = pcall(function() return env[n] end)
        if ok and v ~= nil then ex[#ex + 1] = n .. ":" .. type(v) end
    end
    out.executor = table.concat(ex, ",")
    pcall(function()
        if identifyexecutor then out.exec_name = tostring((identifyexecutor())) end
    end)
    out.vim = pcall(function() return game:GetService("VirtualInputManager") end) and "service ok" or "blocked"
    pcall(function()
        local cam = workspace.CurrentCamera
        out.cam_type = tostring(cam.CameraType)
        out.cam_subject = cam.CameraSubject and (cam.CameraSubject.ClassName .. ":" .. cam.CameraSubject.Name) or "none"
        out.cam_write = pcall(function() cam.CFrame = cam.CFrame end) and "accepted" or "refused"
        -- how often does something else set the camera? (per second, over 2s)
        local n = 0
        local c = cam:GetPropertyChangedSignal("CFrame"):Connect(function() n = n + 1 end)
        task.wait(2)
        c:Disconnect()
        out.cam_sets_per_s = n / 2
        local fps = 0
        pcall(function() fps = math.floor(workspace:GetRealPhysicsFPS()) end)
        out.physics_fps = fps
    end)
    push("aim probe caps", out)
end)

-- camera nudge test ----------------------------------------------------
local camt = { done = false, still = 0, phase = 0, a0 = nil, reads = {} }
local function cam_yaw()
    local ok, p, y = pcall(client.get_camera_angles_deg)
    if ok then return tonumber(y), tonumber(p) end
    return nil
end
pcall(function()
    game:GetService("RunService").RenderStepped:Connect(function()
        if camt.done then return end
        if camt.phase == 0 then
            local oka, alive = pcall(entity.is_alive, me())
            local okd, dx, dy = pcall(input.get_mouse_delta)
            local still = oka and alive and okd and math.abs(tonumber(dx) or 1) + math.abs(tonumber(dy) or 1) < 0.01
            camt.still = still and camt.still + 1 or 0
            if camt.still >= 30 and os.clock() > 20 then
                camt.a0 = cam_yaw()
                local ok = pcall(function()
                    local cam = workspace.CurrentCamera
                    cam.CFrame = cam.CFrame * CFrame.Angles(0, math.rad(0.5), 0)
                end)
                camt.wrote = ok
                camt.phase = 1
            end
        else
            local y = cam_yaw()
            camt.reads[#camt.reads + 1] = (y and camt.a0) and r2(((y - camt.a0 + 540) % 360) - 180) or "nil"
            camt.phase = camt.phase + 1
            if camt.phase > 4 then
                camt.done = true
                local okd, dx = pcall(input.get_mouse_delta)
                push("aim probe cam", { wrote = camt.wrote, yaw0 = r2(camt.a0), yaw_delta_per_frame = camt.reads,
                    mouse_moved = okd and math.abs(tonumber(dx) or 0) > 0.01 or nil,
                    note = "~0.5 that stays = camera writes reach the game's view angles; ~0 = the game overwrites them" })
            end
        end
    end)
end)

-- prediction accuracy -------------------------------------------------
local H = { 4, 8, 16 }
local PR = { n = 0, wait = {}, err = { [4] = {}, [8] = {}, [16] = {} }, st0 = { [4] = {}, [8] = {}, [16] = {} },
    lin = { [4] = {}, [8] = {}, [16] = {} }, spd = {}, alive_ticks = 0, next = 0, sent = false, api = nil }
local function flat(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2) end
local function pctl(a, p)
    if #a == 0 then return nil end
    table.sort(a)
    return r2(a[math.max(1, math.ceil(#a * p))])
end
client.on_tick(function()
    if PR.sent then return end
    PR.n = PR.n + 1
    local oka, alive = pcall(entity.is_alive, me())
    if not (oka and alive) then return end
    PR.alive_ticks = PR.alive_ticks + 1
    -- resolve due predictions
    local i = 1
    while i <= #PR.wait do
        local w = PR.wait[i]
        if PR.n >= w.due then
            local okq, pos = pcall(entity.get_player_position, w.e)
            if okq and pos and flat(pos, w.p0) < 40 then
                local h = w.h
                if w.pred then table.insert(PR.err[h], flat(pos, w.pred)) end
                table.insert(PR.st0[h], flat(pos, w.p0))
                if w.lin then table.insert(PR.lin[h], flat(pos, w.lin)) end
            end
            table.remove(PR.wait, i)
        else
            i = i + 1
        end
    end
    -- new predictions every 16 ticks for the 3 nearest enemies
    if PR.n >= PR.next and #PR.wait < 300 then
        PR.next = PR.n + 16
        local okm, mp = pcall(entity.get_player_position, me())
        local okl, list = pcall(entity.get_enemies)
        if okm and mp and okl and type(list) == "table" then
            local cand = {}
            for _, e in ipairs(list) do
                local okq, pos = st.epos(e)
                local okv, ea = pcall(entity.is_alive, e)
                if okq and pos and okv and ea then
                    local d = flat(pos, mp)
                    if d < 300 then cand[#cand + 1] = { e = e, p = pos, d = d } end
                end
            end
            table.sort(cand, function(a, b) return a.d < b.d end)
            for k = 1, math.min(3, #cand) do
                local c = cand[k]
                local okv, v = pcall(movement.get_velocity, c.e)
                if okv and typeof(v) == "Vector3" then table.insert(PR.spd, math.sqrt(v.X * v.X + v.Z * v.Z)) end
                for _, h in ipairs(H) do
                    local okp, pp = pcall(movement.predict_position, c.e, h)
                    if PR.api == nil then PR.api = okp and typeof(pp) or ("error: " .. tostring(pp)) end
                    local lin = nil
                    if okv and typeof(v) == "Vector3" then lin = c.p + Vector3.new(v.X, 0, v.Z) * (h / 64) end
                    PR.wait[#PR.wait + 1] = { e = c.e, h = h, due = PR.n + h, p0 = c.p,
                        pred = (okp and typeof(pp) == "Vector3") and pp or nil, lin = lin }
                end
            end
        end
    end
    if PR.alive_ticks >= 64 * 120 then
        PR.sent = true
        local out = { api = PR.api, alive_s = math.floor(PR.alive_ticks / 64), enemy_speed_med = pctl(PR.spd, 0.5),
            enemy_speed_p90 = pctl(PR.spd, 0.9) }
        for _, h in ipairs(H) do
            out["h" .. h] = { n = #PR.st0[h],
                predict_med = pctl(PR.err[h], 0.5), predict_p90 = pctl(PR.err[h], 0.9),
                stay_med = pctl(PR.st0[h], 0.5), stay_p90 = pctl(PR.st0[h], 0.9),
                vel_med = pctl(PR.lin[h], 0.5), vel_p90 = pctl(PR.lin[h], 0.9) }
        end
        push("aim probe predict", out)
        PR.wait = {}
    end
end)
end)()

-- ======================================================================
-- AIM PROBE 2 (read-only + one knife click): could Lua shoot by itself through the GAME's own code?
--   12s after load: ClientEngine's class + child tree (names/classes, 2 levels), ReplicatedStorage top folders;
--     (the network-object scan is gone: the cheat refuses to compile a script that names those classes); keys of the game's _G / shared (getrenv) tables. Nothing is required or called: requiring the
--     game's modules from the executor could start a second copy of them.
--   click (once): only while alive, holding the KNIFE, mouse still and no enemy within 60 st: sends one left click
--     through VirtualInputManager and reports whether the call was allowed and whether UserInputService saw a
--     MouseButton1 InputBegan from it (= the game would receive script clicks).
-- ======================================================================
;(function()
local function push(what, ev)
    ev.kind, ev.what = "diag", what
    if st.push then pcall(st.push, ev) end
end
local Players = game:GetService("Players")

task.delay(12, function()
    local out = {}
    local rs = game:GetService("ReplicatedStorage")
    pcall(function()
        local lp = Players.LocalPlayer
        local ps = lp:FindFirstChildOfClass("PlayerScripts")
        if ps then
            local ce = ps:FindFirstChild("ClientEngine")
            if ce then
                local tree = {}
                for _, c in ipairs(ce:GetChildren()) do
                    if #tree >= 120 then break end
                    local kids = {}
                    for _, g in ipairs(c:GetChildren()) do
                        if #kids >= 15 then break end
                        kids[#kids + 1] = g.Name .. "(" .. g.ClassName .. ")"
                    end
                    tree[#tree + 1] = c.Name .. "(" .. c.ClassName .. ")" .. (#kids > 0 and ("[" .. table.concat(kids, ",") .. "]") or "")
                end
                out.clientengine = ce.ClassName .. ": " .. table.concat(tree, ", ")
            end
        end
    end)
    -- top-level folders in ReplicatedStorage (module locations)
    pcall(function()
        local f = {}
        for _, c in ipairs(rs:GetChildren()) do
            if #f >= 80 then break end
            f[#f + 1] = c.Name .. "(" .. c.ClassName .. "," .. #c:GetChildren() .. ")"
        end
        out.rs_top = table.concat(f, ", ")
    end)
    -- the game's own globals
    pcall(function()
        if not getrenv then out.renv = "no getrenv"; return end
        local renv = getrenv()
        for _, nm in ipairs({ "_G", "shared" }) do
            local t = renv[nm]
            if type(t) == "table" then
                local k = {}
                for kk, vv in pairs(t) do
                    if #k >= 80 then break end
                    k[#k + 1] = tostring(kk) .. ":" .. type(vv)
                end
                out["renv_" .. nm] = table.concat(k, ",")
            end
        end
    end)
    push("aim probe 2 remotes", out)
end)

-- knife click test ------------------------------------------------------
local CT = { done = false, still = 0, seen = 0, sent_at = nil, err = nil }
pcall(function()
    local UIS = game:GetService("UserInputService")
    UIS.InputBegan:Connect(function(io)
        if CT.sent_at and not CT.done and io.UserInputType == Enum.UserInputType.MouseButton1 then
            CT.seen = CT.seen + 1
        end
    end)
end)
local function near_enemy(r)
    local okm, mp = pcall(entity.get_player_position, me())
    local okl, list = pcall(entity.get_enemies)
    if not (okm and mp and okl and type(list) == "table") then return true end
    for _, e in ipairs(list) do
        local okq, p = pcall(entity.get_player_position, e)
        if okq and p and (p - mp).Magnitude < r then return true end
    end
    return false
end
pcall(function()
    game:GetService("RunService").RenderStepped:Connect(function()
        if CT.done then return end
        if CT.sent_at then
            if os.clock() - CT.sent_at > 0.5 then
                CT.done = true
                push("aim probe 2 click", { allowed = CT.err == nil, err = CT.err, uis_saw_click = CT.seen,
                    note = "allowed + uis_saw_click >= 1 = the game receives script clicks" })
            end
            return
        end
        if os.clock() < 25 then return end
        local oka, alive = pcall(entity.is_alive, me())
        local okw, w = pcall(weapon.get_active)
        local okd, dx, dy = pcall(input.get_mouse_delta)
        local ok = oka and alive and okw and type(w) == "table" and w.is_knife == true
            and okd and math.abs(tonumber(dx) or 1) + math.abs(tonumber(dy) or 1) < 0.01
            and not st.win_open and not (select(2, pcall(ui.is_menu_open)) == true)
        CT.still = ok and CT.still + 1 or 0
        if CT.still < 30 or near_enemy(60) then return end
        CT.sent_at = os.clock()
        local okv, e = pcall(function()
            local vim = game:GetService("VirtualInputManager")
            local cam = workspace.CurrentCamera
            local x, y = cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2
            vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.delay(0.05, function() pcall(function() vim:SendMouseButtonEvent(x, y, 0, false, game, 0) end) end)
        end)
        if not okv then CT.err = tostring(e) end
    end)
end)
end)()

-- ======================================================================
-- REMOTE CONTROL: polls GET <ingest URL with /ingest -> /config> (same token) every 5s.
-- The config is written only on the server over SSH (hvhctl config set ...). Only the keys in
-- CTRL below can be changed, values are range/option checked, every change is logged in the
-- Lua console, and the user's own values come back on "clear" or when this toggle is turned off.
-- ======================================================================
-- License users get remote control switched on automatically on every load (st.ctrl_forced); they can still
-- switch it off for the rest of that session. The owner keeps whatever they saved.
st.ctrl_forced = false
sv_ctrl_on = s_sv:new_toggle("Remote control", sv_saved("sv_ctrl", false) == true, function(v)
    if v == false then st.ctrl_forced = false end
    sv_save("sv_ctrl", v)
end)
st.ctrl_live = function() return st.ctrl_forced or (sv_ctrl_on ~= nil and sv_ctrl_on:get() == true) end
do -- remote control internals (own scope: the main chunk is near Lua's 200-local limit)

local CTRL = {
    enabled   = { h = enabled,   t = "b" },
    pitch     = { h = pitch_sel, t = "c", o = { "Down", "Up", "Zero", "Flick" } },
    up_fix    = { h = up_fix,    t = "b" },
    yaw_off   = { h = yaw_off,   t = "n", lo = -180, hi = 180 },
    yaw_mod   = { h = yaw_mod,   t = "c", o = { "Disabled", "Center", "Sway", "Spin", "Random", "3-Way", "5-Way" } },
    mod_amt   = { h = mod_amt,   t = "n", lo = 0, hi = 90 },
    lag       = { h = lag_ticks, t = "n", lo = 0, hi = 14 },
    lag_var   = { h = lag_var,   t = "n", lo = 0, hi = 100 },
    inverter  = { h = ds_mode,   t = "c", o = { "Static", "Jitter", "Delayed", "Random", "On-shot flip" } },
    lim_stand = { h = lim_stand, t = "n", lo = 0, hi = MAXD },
    lim_move  = { h = lim_move,  t = "n", lo = 0, hi = MAXD },
    lim_air   = { h = lim_air,   t = "n", lo = 0, hi = MAXD },
    lim_duck  = { h = lim_duck,  t = "n", lo = 0, hi = MAXD },
    lim_rnd   = { h = lim_rnd,   t = "b" },
    delay     = { h = ds_delay,  t = "n", lo = 1, hi = 32 },
    delay_rnd = { h = ds_dr,     t = "n", lo = 0, hi = 16 },
    def_on    = { h = def_on,    t = "b" },
    def_trig  = { h = def_trig,  t = "c", o = { "interval", "after shot", "always" } },
    def_int   = { h = def_int,   t = "n", lo = 100, hi = 2000 },
    def_len   = { h = def_dur,   t = "n", lo = 1, hi = 14 },
    def_shift = { h = def_shift, t = "n", lo = 0, hi = 14 },
    def_pitch = { h = def_pitch, t = "c", o = { "Up", "Down", "Zero", "Jitter" } },
    def_yaw   = { h = def_yaw,   t = "n", lo = 0, hi = 180 },
    def_flip  = { h = def_flip,  t = "b" },
    def_lag   = { h = def_lag,   t = "b" },
    def_unch  = { h = def_unch,  t = "b" },
    def_rand  = { h = def_rand,  t = "b" },
    os_on     = { h = os_on,     t = "b" },
    os_mode   = { h = os_mode,   t = "c", o = { "Flip desync", "Max desync flip", "Flip + yaw 180", "Hide head (pitch zero)" } },
    os_len    = { h = os_len,    t = "n", lo = 1, hi = 8 },
    os_unch   = { h = os_unch,   t = "b" },
    rs_mode   = { h = rs_mode,   t = "c", o = { "Off", "Shadow", "Active" } },
    rs_lead   = { h = rs_lead,   t = "n", lo = -1, hi = 12 },
    rs_take   = { h = rs_take,   t = "n", lo = 0, hi = 5 },
    rs_max    = { h = rs_max,    t = "n", lo = 20, hi = MAXD },
    peek_mode = { h = st.ui.px_mode, t = "c", o = { "Off", "Hold side", "Flip then hold", "Max desync hold", "Randomize" } },
    peek_len  = { h = st.ui.px_len,  t = "n", lo = 4, hi = 64 },
    rs_baim   = { h = st.ui.rx_baim, t = "n", lo = 0, hi = 5 },
    anim      = { h = st.ui.an_mode, t = "c", o = { "Off", "Freeze in air", "Freeze all", "Jitter" } },
    dodge       = { h = st.ui.dg.mode,  t = "c", o = { "Off", "On threat", "Always" } },
    dodge_rate  = { h = st.ui.dg.rate,  t = "n", lo = 20, hi = 250 },
    dodge_min   = { h = st.ui.dg.min,   t = "n", lo = 10, hi = MAXD },
    dodge_max   = { h = st.ui.dg.max,   t = "n", lo = 20, hi = MAXD },
    dodge_asym  = { h = st.ui.dg.asym,  t = "b" },
    dodge_yaw   = { h = st.ui.dg.yaw,   t = "n", lo = 0, hi = 45 },
    dodge_pitch = { h = st.ui.dg.pitch, t = "b" },
    dodge_swing = { h = st.ui.dg.swing, t = "n", lo = 0, hi = 2000 },
    dodge_shift = { h = st.ui.dg.shift, t = "n", lo = 0, hi = 14 },
    dodge_range = { h = st.ui.dg.range, t = "n", lo = 20, hi = 500 },
    dodge_hit   = { h = st.ui.dg.hit,   t = "b" },
    flick       = { h = st.ui.fk.on,    t = "b" },
    flick_rate  = { h = st.ui.fk.rate,  t = "n", lo = 2, hi = 64 },
    flick_ticks = { h = st.ui.fk.len,   t = "n", lo = 1, hi = 8 },
    flick_ang   = { h = st.ui.fk.ang,   t = "n", lo = 0, hi = 180 },
    flick_side  = { h = st.ui.fk.side,  t = "c", o = { "Strafe fix", "Inverter", "Alternate" } },
    flick_speed = { h = st.ui.fk.speed, t = "n", lo = 0, hi = 60 },
    flick_choke = { h = st.ui.fk.choke, t = "b" },
    flick_unch  = { h = st.ui.fk.unch,  t = "b" },
    flick_lag   = { h = st.ui.fk.lag,   t = "n", lo = 0, hi = 14 },
    rs_multi  = { h = st.ui.rs_multi, t = "b" },
    rs_pitch  = { h = st.ui.rs_pitch, t = "b" },
    rs_fd     = { h = st.ui.rs_fd,    t = "b" },
    hc_air    = { h = st.ui.rg.air, t = "n", lo = 0, hi = 100 },
    hc_noscope = { h = st.ui.rg.ns, t = "n", lo = 0, hi = 100 },
    hc_duck   = { h = st.ui.rg.dk,  t = "n", lo = 0, hi = 100 },
    mindmg    = { h = st.ui.rg.md,  t = "n", lo = 0, hi = 100 },
    lethal    = { h = st.ui.rg.le,  t = "b" },
    hc_move   = { h = st.ui.rg.mv,  t = "n", lo = 0, hi = 100 },
    ns        = { h = st.ui.ns.on,  t = "b" },
    ns_hc     = { h = st.ui.ns.hc,  t = "n", lo = 0, hi = 100 },
    ns_md     = { h = st.ui.ns.md,  t = "n", lo = 0, hi = 100 },
    ns_half   = { h = st.ui.ns.half, t = "b" },
    ns_baim   = { h = st.ui.ns.ba,  t = "b" },
    qs        = { h = st.ui.qs.mode, t = "c", o = { "Off", "On target", "Snipers only" } },
    qs_how    = { h = st.ui.qs.how,  t = "c", o = { "Auto", "Velocity", "Move", "WalkSpeed" } },
    qs_keep   = { h = st.ui.qs.keep, t = "n", lo = 0, hi = 100 },
    qs_hold   = { h = st.ui.qs.hold, t = "n", lo = 100, hi = 1000 },
    qs_rest   = { h = st.ui.qs.rest, t = "n", lo = 0, hi = 1500 },
    style      = { h = st.sy.ui.mode, t = "c", o = { "Custom", "Static back", "No AA", "Swap" } },
    style_lim  = { h = st.sy.ui.lim,  t = "n", lo = 0, hi = MAXD },
    style_side = { h = st.sy.ui.side, t = "c", o = { "Invert key", "Fake left", "Fake right" } },
    style_swap = { h = st.sy.ui.swap, t = "n", lo = 2, hi = 60 },
    style_jit  = { h = st.sy.ui.jit,  t = "n", lo = 0, hi = 100 },
    style_lag  = { h = st.sy.ui.lag,  t = "b" },
    roll       = { h = st.rp.ui.roll, t = "c", o = { "Off", "Static", "Follow desync", "Against desync", "Jitter", "Random" } },
    roll_amt   = { h = st.rp.ui.amt,  t = "n", lo = -100, hi = 100 },
    roll_rate  = { h = st.rp.ui.rate, t = "n", lo = 1, hi = 32 },
    roll_when  = { h = st.rp.ui.when, t = "c", o = { "Always", "Standing", "On ground", "In air" } },
    fpitch     = { h = st.rp.ui.fp,   t = "c", o = { "Off", "Down", "Up", "Zero", "Custom", "Jitter" } },
    fpitch_val = { h = st.rp.ui.fpv,  t = "n", lo = -70, hi = 70 },
    fpitch_off = { h = st.rp.ui.fpa,  t = "n", lo = -20, hi = 20 },
    fpitch_rate = { h = st.rp.ui.fpr, t = "n", lo = 1, hi = 32 },
    rs_roll    = { h = st.rx2.ui.roll, t = "c", o = { "Off", "Safe point", "Body aim", "Both" } },
    rs_lean    = { h = st.rx2.ui.thr,  t = "n", lo = 4, hi = 40 },
    rs_pbrute  = { h = st.rx2.ui.pb,   t = "b" },
    rs_pmiss   = { h = st.rx2.ui.pm,   t = "n", lo = 1, hi = 4 },
}
local ctrl_saved = {}     -- key -> the user's own value from before the first override
local ctrl_last_err = 0

local function ctrl_valid(s, v)
    if s.t == "b" then return type(v) == "boolean" end
    if s.t == "n" then return type(v) == "number" and v >= s.lo and v <= s.hi end
    for _, o in ipairs(s.o) do
        if o == v then return true end
    end
    return false
end

local function ctrl_str(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, " ")
end

local function ctrl_restore_all(why)
    local restored = {}
    for k, orig in pairs(ctrl_saved) do
        pcall(function() CTRL[k].h:set(orig) end)
        restored[k] = orig
    end
    ctrl_saved = {}
    if next(restored) then
        st.flog(255, 200, 90, "[CTRL] " .. why .. ", restored your values: " .. ctrl_str(restored))
    end
    return restored
end

local function ctrl_apply(cfg)
    local set = type(cfg.set) == "table" and cfg.set or {}
    local applied, rejected, restored = {}, {}, {}
    -- keys that are no longer overridden go back to the user's own value
    for k, orig in pairs(ctrl_saved) do
        if set[k] == nil then
            pcall(function() CTRL[k].h:set(orig) end)
            restored[k] = orig
            ctrl_saved[k] = nil
        end
    end
    for k, v in pairs(set) do
        local s = CTRL[k]
        if not s then
            rejected[k] = "unknown key"
        elseif not ctrl_valid(s, v) then
            rejected[k] = "bad value"
        else
            if s.t == "n" then v = math.floor(v + 0.5) end
            local okg, cur = pcall(function() return s.h:get() end)
            if ctrl_saved[k] == nil and okg then ctrl_saved[k] = cur end
            local oks = pcall(function() s.h:set(v) end)
            if oks then applied[k] = v else rejected[k] = "set failed" end
        end
    end
    ctrl_v = tonumber(cfg.v) or 0
    local note = type(cfg.note) == "string" and cfg.note ~= "" and (" (" .. cfg.note .. ")") or ""
    st.flog(120, 200, 255, string.format("[CTRL] v%d %s%s", ctrl_v, ctrl_str(applied), note))
    if next(restored) then st.flog(255, 200, 90, "[CTRL] restored: " .. ctrl_str(restored)) end
    if next(rejected) then st.flog(255, 90, 90, "[CTRL] rejected: " .. ctrl_str(rejected)) end
    sv_push({ kind = "ctrl", v = ctrl_v, applied = applied, rejected = rejected, restored = restored,
        note = type(cfg.note) == "string" and cfg.note or nil })
end

local function ctrl_poll()
    local url, tok = sv_url:get(), sv_tok:get()
    local hdr = st.auth(tok)
    if type(url) ~= "string" or string.sub(url, 1, 8) ~= "https://" or not hdr then return end
    local cfg_url = string.gsub(url, "/ingest$", "/config")
    if cfg_url == url then return end
    local ok, res = pcall(function()
        return HttpService:RequestAsync({ Url = cfg_url, Method = "GET", Headers = hdr })
    end)
    if not ok or type(res) ~= "table" or res.Success == false or type(res.Body) ~= "string" then
        if globals.realtime() - ctrl_last_err > 30 then
            ctrl_last_err = globals.realtime()
            st.flog(255, 90, 90, "[CTRL] poll failed: " .. (ok and ("status " .. tostring(type(res) == "table" and res.StatusCode)) or tostring(res)))
        end
        return
    end
    local okd, cfg = pcall(function() return HttpService:JSONDecode(res.Body) end)
    if okd and type(cfg) == "table" and tonumber(cfg.v) and tonumber(cfg.v) ~= ctrl_v then
        ctrl_apply(cfg)
    end
end

-- Live values for the admin panel: every CTRL key as the game has it now (vals) plus, for overridden keys, the
-- player's own value underneath (own). Sent when anything changes, else once a minute. Kept on st (local limit).
st.ctrl_rep = { sig = nil, nxt = 0 }
st.ctrl_report = function()
    local vals, own = {}, {}
    for k, s in pairs(CTRL) do
        local ok, v = pcall(function() return s.h:get() end)
        if ok and v ~= nil and (type(v) == "boolean" or type(v) == "number" or type(v) == "string") then
            if type(v) == "number" then v = math.floor(v * 100 + 0.5) / 100 end
            vals[k] = v
        end
    end
    for k, v in pairs(ctrl_saved) do own[k] = v end
    local sig = ctrl_str(vals) .. "|" .. ctrl_str(own)
    local now = globals.realtime()
    if sig == st.ctrl_rep.sig and now < st.ctrl_rep.nxt then return end
    st.ctrl_rep.sig, st.ctrl_rep.nxt = sig, now + 60
    sv_push({ kind = "settings", vals = vals, own = own, remote = st.ctrl_live() })
end

task.spawn(function()
    while true do
        task.wait(5)
        pcall(st.ctrl_report)
        if not st.ctrl_auto_done and st.sv_owner_checked then
            st.ctrl_auto_done = true
            if not st.sv_owner and not sv_ctrl_on:get() then
                st.ctrl_forced = true
                pcall(function() sv_ctrl_on:set(true) end)
                pcall(st.flog, 120, 255, 160, "[REMOTE] remote control turned on automatically (license user)")
            end
        end
        if st.ctrl_live() then
            pcall(ctrl_poll)
        elseif ctrl_v ~= 0 or next(ctrl_saved) then
            local restored = ctrl_restore_all("remote control off")
            sv_push({ kind = "ctrl", v = 0, applied = {}, rejected = {}, restored = restored, note = "remote control turned off" })
            ctrl_v = 0
        end
    end
end)
end

do
-- ======================================================================
-- UPDATE CHECK + SUBSCRIPTION GUARD (2/2). Every 60s GET /beat on the license server (pinned host, not the
-- editable feed URL). It answers only to a live session (key active, not expired, and no newer login on another
-- device) or the owner's master token, and says the build + when the sub ends.
-- Stops the script (UNSYK_STOP, part 1 at the top) when: two answers in a row are 401/403, the sub end passes,
-- this copy was served to another Roblox account (UNSYK_UID), or no answer at all for 30 minutes.
-- ======================================================================
task.spawn(function()
    local BASE = "https://feed.sites.exxo.world"
    local upd_warned = nil
    local last_ok, refused, sub_end = os.time(), 0, tonumber(UNSYK_SUB_END) or 0
    st.lic_t0 = os.time()   -- licence enforcement clock (see the resolver); st.lic_authed set on the first good beat
    do local ok, v = pcall(database.read, "lic_enf"); st.lic_enf = ok and (v == "1" or v == "on" or v == "true") or false end
    local function my_uid()
        local ok, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
        return ok and lp and lp.UserId or nil
    end
    while not UNSYK_STOPPED do
        local uid = my_uid()
        if UNSYK_UID and uid and uid ~= UNSYK_UID then
            UNSYK_STOP("this copy belongs to another Roblox account")
            break
        end
        if sub_end > 0 and os.time() > sub_end then
            UNSYK_STOP("your subscription ended")
            break
        end
        local hdr = st.auth(sv_tok:get())
        local code, body = nil, nil
        local function get(path)
            local ok, res = pcall(function()
                return HttpService:RequestAsync({ Url = BASE .. path, Method = "GET", Headers = hdr })
            end)
            if ok and type(res) == "table" then return res.StatusCode, res.Body end
            return nil, nil
        end
        if hdr then
            code, body = get("/beat?b=" .. tostring(math.floor(tonumber(UNSYK_BUILD) or 0)))
            if code == 404 then
                -- proxy without the /beat route yet: /version answers only to a live session too (just no sub end)
                code, body = get("/version")
                if code == 200 then body = HttpService:JSONEncode({ v = body, sub_end = sub_end }) end
            end
        elseif st.rsx then
            st.rsx.data, st.rsx.why = nil, "not logged in"
        end
        if code == 200 then
            last_ok, refused = os.time(), 0
            local okj, b = pcall(function() return HttpService:JSONDecode(body or "") end)
            if okj and type(b) == "table" then
                sub_end = tonumber(b.sub_end) or 0
                -- rolling heartbeat token: echoed back in every feed batch so the server can tell a real live
                -- session from a stubbed/replayed 200 (st.lic_authed also gates licence enforcement above).
                if type(b.bt) == "string" and #b.bt <= 16 then st.lic_bt = b.bt; st.lic_authed = true end
                -- resolver table (memory only): first good beat, or the server has a newer one (rv) for this build
                local X = st.rsx
                if X and (not X.data or (type(b.rv) == "string" and b.rv ~= X.data.rv)) then
                    local okf, ef = pcall(X.fetch, get)
                    if not okf then X.data, X.why = nil, "fetch error: " .. tostring(ef) end
                    pcall(X.say)
                end
                local remote = b.v
                if type(remote) == "string" and #remote < 64 and remote ~= UNSYK_VERSION and remote ~= upd_warned then
                    upd_warned = remote
                    local want = remote
                    if tonumber(b.build) then want = (b.ch == "beta" and "beta " or "") .. "#" .. tostring(b.build) .. " (" .. remote .. ")" end
                    client.color_log(255, 200, 90, string.format("[UPDATE] build %s is on the server for you (running %s). Reload the loader to update.",
                        want, UNSYK_TAG .. " " .. tostring(UNSYK_VERSION or "")))
                end
            end
        elseif code == 401 or code == 403 then
            if st.rsx then st.rsx.data, st.rsx.why = nil, "session refused (" .. tostring(code) .. ")" end
            refused = refused + 1
            if refused >= 2 then
                UNSYK_STOP("session ended (key used on another device, expired or revoked). Reload the loader")
                break
            end
        end
        if os.time() - last_ok > 1800 then
            UNSYK_STOP("no answer from the license server for 30 minutes")
            break
        end
        task.wait(refused > 0 and 15 or 60)
    end
end)
end


-- ======================================================================
-- WINDOW: own in-game menu (ScreenGui): frosted dark panel, centered title, sidebar tabs with an accent bar, two columns
-- of sections where every setting is a rounded row (switch / dropdown / knob slider on the right), blurred game behind.
-- It drives the same handles as the cheat tab, so both stay in sync and remote config changes show up within 0.25s. Also holds Configs (cloud), Account and Logs.
-- Roblox click events never reach script GUIs here, so clicks are polled and hit-tested every frame. The
-- mouse -> GUI offset is worked out automatically (see mouse section); a manual fallback is in Settings.
-- Built under pcall in its own function (main chunk is at the 200-local limit): a GUI error never stops the AA.
-- ======================================================================
do
local function ui_build()
    local UIS = game:GetService("UserInputService")
    local ACCENTS = {
        { "Lime", Color3.fromRGB(150, 200, 60) }, { "Blue", Color3.fromRGB(80, 150, 255) },
        { "Pink", Color3.fromRGB(230, 95, 170) }, { "Purple", Color3.fromRGB(150, 115, 240) },
        { "Orange", Color3.fromRGB(240, 150, 60) }, { "Red", Color3.fromRGB(225, 70, 70) },
        { "White", Color3.fromRGB(220, 220, 220) },
    }
    local C = {
        win = Color3.fromRGB(14, 14, 17), line = Color3.fromRGB(40, 40, 46), card = Color3.fromRGB(27, 27, 32),
        card_hi = Color3.fromRGB(36, 36, 42), ctl = Color3.fromRGB(56, 56, 63), field = Color3.fromRGB(17, 17, 20),
        knob = Color3.fromRGB(235, 235, 240), txt = Color3.fromRGB(176, 176, 184), hi = Color3.fromRGB(242, 242, 245),
        mut = Color3.fromRGB(104, 104, 112), bad = Color3.fromRGB(225, 90, 90), warn = Color3.fromRGB(230, 180, 80),
        acc = ACCENTS[1][2],
    }
    local acc_name = database.read("ui_acc")
    for _, a in ipairs(ACCENTS) do if a[1] == acc_name then C.acc = a[2] end end
    if type(acc_name) ~= "string" then acc_name = "Lime" end
    st.accent = C.acc   -- the HUD and crosshair follow the window's accent
    if st.ch_col then st.ch_col.acc = C.acc end

    local F, FM, FB = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold
    local LEFT, RIGHT, CENTER = Enum.TextXAlignment.Left, Enum.TextXAlignment.Right, Enum.TextXAlignment.Center

    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    local function label(parent, text, color, xa, size, font)
        return new("TextLabel", { BackgroundTransparency = 1, Text = text, TextSize = size or 12, TextColor3 = color,
            Font = font or F, TextXAlignment = xa or LEFT, TextYAlignment = Enum.TextYAlignment.Center,
            TextTruncate = Enum.TextTruncate.AtEnd, BorderSizePixel = 0 }, parent)
    end
    local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
    local function stroke(o, col) new("UIStroke", { Color = col or C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
    local function hget(h)
        local ok, v = pcall(function() return h:get() end)
        if ok then return v end
        return nil
    end
    local function hset(it, v)
        pcall(function() it.h:set(v) end)
        if it.cb then pcall(it.cb, v) end
    end
    local function dbw(k, v) pcall(function() database.write(k, v); database.flush() end) end
    local function say(r, g, b, msg) pcall(client.color_log, r, g, b, "[MENU] " .. msg) end
    -- a value that only lives in the window (config name box, accent, ...) dressed up as a cheat handle
    local function var(v, on_set)
        return { get = function() return v end, set = function(_, x) v = x; if on_set then pcall(on_set, x) end end }
    end

    -- background blur while the menu is open (Lighting BlurEffect: blurs the 3D view, never the GUI)
    local blur = { on = database.read("ui_blur") ~= "0", fx = nil }
    local is_open = true
    local function blur_show(v)
        pcall(function()
            if v and blur.on then
                if not blur.fx or not blur.fx.Parent then
                    blur.fx = Instance.new("BlurEffect")
                    blur.fx.Name = "unsyk_blur"
                    blur.fx.Size = 0
                    blur.fx.Parent = game:GetService("Lighting")
                end
                game:GetService("TweenService"):Create(blur.fx, TweenInfo.new(0.2), { Size = 14 }):Play()
            elseif blur.fx then
                blur.fx:Destroy()
                blur.fx = nil
            end
        end)
    end
    client.set_event_callback("shutdown", function() pcall(function() if blur.fx then blur.fx:Destroy() end end) end)

    -- accent: everything that uses it registers a repaint function
    local acc_fns = {}
    local function acc(fn) acc_fns[#acc_fns + 1] = fn; pcall(fn) end
    local function set_accent(name)
        for _, a in ipairs(ACCENTS) do
            if a[1] == name then C.acc = a[2]; acc_name = name end
        end
        dbw("ui_acc", acc_name)
        st.accent = C.acc
        if st.ch_col then st.ch_col.acc = C.acc end
        for _, fn in ipairs(acc_fns) do pcall(fn) end
    end

    -- ---------- frame ----------
    local gui = new("ScreenGui", { Name = "unsyk_menu", ResetOnSpawn = false, IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 60 })
    pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)
    gui.Parent = game:GetService("CoreGui")
    local W, H, RAIL, TOP = 720, 480, 160, 40
    local px, py = 140, 120
    local sp = database.read("ui_pos")
    if type(sp) == "string" then
        local a, b = string.match(sp, "^(%-?%d+),(%-?%d+)$")
        if a then px, py = tonumber(a), tonumber(b) end
    end
    local okv, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if okv and vp and (px < -W + 80 or py < 0 or px > vp.X - 80 or py > vp.Y - 60) then px, py = 140, 120 end

    -- frosted dark panel; the game behind it is blurred while the menu is open (Settings > Menu > Blur)
    local win = new("Frame", { Size = UDim2.new(0, W, 0, H), Position = UDim2.new(0, px, 0, py), BackgroundColor3 = C.win,
        BackgroundTransparency = 0.06, BorderSizePixel = 0, Active = true, ClipsDescendants = false }, gui)
    corner(win, 9); stroke(win)
    local body = win
    local modal = new("TextButton", { Size = UDim2.new(0, 1, 0, 1), BackgroundTransparency = 1, Text = "", Modal = true }, win)

    -- title bar: mark + name centered, account on the left, session on the right
    local top = new("Frame", { Size = UDim2.new(1, 0, 0, TOP), BackgroundTransparency = 1 }, win)
    local brand = new("Frame", { Size = UDim2.new(0, 110, 1, 0), Position = UDim2.new(0.5, -55, 0, 0), BackgroundTransparency = 1 }, top)
    local mark = new("Frame", { Size = UDim2.new(0, 10, 0, 10), Position = UDim2.new(0, 4, 0.5, -5), Rotation = 45,
        BackgroundColor3 = C.acc, BorderSizePixel = 0 }, brand)
    corner(mark, 2)
    local mark2 = new("Frame", { Size = UDim2.new(0, 4, 0, 4), Position = UDim2.new(0.5, -2, 0.5, -2), BackgroundColor3 = C.win,
        BorderSizePixel = 0 }, mark)
    corner(mark2, 1)
    acc(function() mark.BackgroundColor3 = C.acc end)
    local tname = label(brand, "unsyk", C.hi, LEFT, 15, FB); tname.Position = UDim2.new(0, 24, 0, 0); tname.Size = UDim2.new(1, -24, 1, 0)
    local f_l = label(top, "", C.mut, LEFT, 11); f_l.Position = UDim2.new(0, 16, 0, 0); f_l.Size = UDim2.new(0.5, -80, 1, 0)
    local f_r = label(top, "", C.mut, RIGHT, 11); f_r.Position = UDim2.new(0.5, 64, 0, 0); f_r.Size = UDim2.new(0.5, -80, 1, 0)
    new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, TOP), BackgroundColor3 = C.line, BorderSizePixel = 0 }, win)

    local rail = new("Frame", { Size = UDim2.new(0, RAIL, 1, -TOP - 1), Position = UDim2.new(0, 0, 0, TOP + 1),
        BackgroundTransparency = 1, BorderSizePixel = 0 }, win)
    new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, -1, 0, 0), BackgroundColor3 = C.line, BorderSizePixel = 0 }, rail)

    local order = 0
    local function nexto() order = order + 1; return order end
    local pages, tabs, refresh = {}, {}, {}
    local cur_page = nil
    local function track(p, fn) refresh[#refresh + 1] = { page = p, fn = fn }; pcall(fn) end

    -- ---------- hit testing ----------
    local hits = {}
    local function on(o, p, click, down) hits[#hits + 1] = { o = o, p = p, click = click, down = down } end
    local pop = nil   -- open dropdown: { frame, items = { {o, click} } }

    -- ---------- mouse ----------
    -- One pointer source, picked once (phobia does the same): UserInputService (screen pixels, top bar included,
    -- the same space as this IgnoreGuiInset ScreenGui) or, if UIS fails, the cheat's input.get_mouse_position
    -- (GUI space below the top bar, so the GuiService inset is added back).
    -- gui point = raw * scale + auto + rel. "auto" is the inset this ScreenGui really has (screen size - gui size)
    -- and is re-measured while the window is open, so it follows window resizes / top bar changes by itself.
    -- A hand calibration or click learning stores only "rel" (and scale), the part auto cannot see, in
    -- database ui_cal4 "rx,ry,sx,sy,how". Older ui_cal3 (auto without the GUI position) and absolute ui_cal2
    -- values are converted once.
    -- Hand calibration = two crosses in opposite corners -> solves offset AND scale (mouse vs GUI pixels on DPI
    -- scaled setups, where one fixed offset is right in the middle and a row off near the edges).
    local cal = { ax = 0, ay = 0, rx = 0, ry = 0, sx = 1, sy = 1, how = "auto", src = nil, ix = 0, iy = 0,
        at = 0, saved = false, old = nil, pts = nil, t0 = 0 }
    local function rnd(v) return math.floor(v + 0.5) end
    local function raw_mouse()
        if cal.src ~= "cheat" then
            local okm, m = pcall(function() return UIS:GetMouseLocation() end)
            if okm and m and type(m.X) == "number" then cal.src = "uis"; return m.X, m.Y end
        end
        local ok2, x, y = pcall(input.get_mouse_position)
        if ok2 and type(x) == "number" and type(y) == "number" then
            if cal.src ~= "cheat" then
                cal.src = "cheat"
                local okg, gi = pcall(function() return game:GetService("GuiService"):GetGuiInset() end)
                if okg and gi and gi.Y >= 0 and gi.Y < 200 then cal.ix, cal.iy = gi.X, gi.Y end
            end
            return x + cal.ix, y + cal.iy
        end
        return -1, -1
    end
    -- GUI point = screen point + (ScreenGui AbsolutePosition) - (screen size - ScreenGui size). In this cheat the
    -- IgnoreGuiInset ScreenGui sits AT 0,-58 with the full screen size (seen in game), so the inset shows up in the
    -- position, not the size; a GUI that keeps the inset shows it in the size. Both are covered.
    local function auto_offset()
        local ok, dx, dy, px, py = pcall(function()
            local v = workspace.CurrentCamera.ViewportSize
            local g, a = gui.AbsoluteSize, gui.AbsolutePosition
            if g.Y < 10 or g.X < 10 then return nil end
            return a.X - (v.X - g.X), a.Y - (v.Y - g.Y), a.X, a.Y
        end)
        if ok and type(dx) == "number" then return rnd(dx), rnd(dy), rnd(px), rnd(py) end
        return nil
    end
    local function cal_write()
        dbw("ui_cal4", string.format("%d,%d,%.4f,%.4f,%s", cal.rx, cal.ry, cal.sx, cal.sy, cal.how))
    end
    local function remeasure()
        local x, y, px, py = auto_offset()
        if not x then return end
        cal.ax, cal.ay = x, y
        if cal.old then    -- pre-v6 absolute offset (ui_cal2) -> relative, now that the GUI has a size
            cal.rx, cal.ry, cal.how = cal.old[1] - x, cal.old[2] - y, cal.old[3]
            cal.old = nil
            cal_write()
        elseif cal.old3 then   -- ui_cal3 was relative to an auto value without the GUI position: take it out
            local o = cal.old3
            cal.old3 = nil
            if o[3] == "auto" then cal.rx, cal.ry = 0, 0 else cal.rx, cal.ry = o[1] - px, o[2] - py end
            cal.how = o[3]
            cal_write()
        end
    end
    do
        local PAT = "^(%-?%d+),(%-?%d+),([%d%.]+),([%d%.]+),(%a+)$"
        local sv = database.read("ui_cal4")
        local a, b, c, d, how
        if type(sv) == "string" then a, b, c, d, how = string.match(sv, PAT) end
        local v3 = false
        if not a then
            local s3 = database.read("ui_cal3")
            if type(s3) == "string" then a, b, c, d, how = string.match(s3, PAT) end
            v3 = a ~= nil
        end
        if a then
            cal.how, cal.saved = how, true
            if v3 then cal.old3 = { tonumber(a), tonumber(b), how } else cal.rx, cal.ry = tonumber(a), tonumber(b) end
            cal.sx, cal.sy = tonumber(c) or 1, tonumber(d) or 1
            if cal.sx < 0.4 or cal.sx > 2.5 then cal.sx = 1 end
            if cal.sy < 0.4 or cal.sy > 2.5 then cal.sy = 1 end
        else
            local old = database.read("ui_cal2")
            local x, y, h2
            if type(old) == "string" then x, y, h2 = string.match(old, "^(%-?%d+),(%-?%d+),(%a+)$") end
            if x and (h2 == "manual" or h2 == "learned") then cal.old = { tonumber(x), tonumber(y), h2 }; cal.saved = true end
        end
        remeasure()
    end
    local function mouse()
        local mx, my = raw_mouse()
        return mx * cal.sx + cal.ax + cal.rx, my * cal.sy + cal.ay + cal.ry
    end
    local function cal_text()
        local s = string.format("%s %d,%d", cal.how, cal.ax + cal.rx, cal.ay + cal.ry)
        if cal.sx ~= 1 or cal.sy ~= 1 then s = s .. string.format(" x%.2f/%.2f", cal.sx, cal.sy) end
        return s
    end
    local function diag()
        local ux, uy = -1, -1
        pcall(function() local m = UIS:GetMouseLocation(); ux, uy = m.X, m.Y end)
        local okc, cx, cy = pcall(input.get_mouse_position)
        local okg, gi = pcall(function() return game:GetService("GuiService"):GetGuiInset() end)
        local v = workspace.CurrentCamera.ViewportSize
        say(160, 200, 255, string.format("mouse %s (src %s, auto %d,%d rel %d,%d) | uis %d,%d cheat %s | screen %dx%d gui %dx%d at %d,%d | inset %s",
            cal_text(), tostring(cal.src), cal.ax, cal.ay, cal.rx, cal.ry, ux, uy,
            okc and string.format("%d,%d", cx or -1, cy or -1) or "?", v.X, v.Y,
            gui.AbsoluteSize.X, gui.AbsoluteSize.Y, gui.AbsolutePosition.X, gui.AbsolutePosition.Y,
            okg and gi and string.format("%d,%d", gi.X, gi.Y) or "?"))
    end
    local function save_cal(how)
        cal.how, cal.saved, cal.old, cal.old3 = how, true, nil, nil
        cal_write()
    end

    -- hand calibration: click the centre of two crosses (top left, then bottom right)
    local calf = new("Frame", { Size = UDim2.new(1, 0, 1, -TOP - 1), Position = UDim2.new(0, 0, 0, TOP + 1), BackgroundColor3 = C.win,
        BorderSizePixel = 0, ZIndex = 40, Visible = false }, body)
    local calt = label(calf, "click the centre of the cross", C.txt, CENTER); calt.Size = UDim2.new(1, 0, 0, 20)
    calt.Position = UDim2.new(0, 0, 0.5, -10); calt.ZIndex = 41
    local calh = new("Frame", { Size = UDim2.new(0, 30, 0, 1), BackgroundColor3 = C.acc, BorderSizePixel = 0, ZIndex = 41 }, calf)
    local calv = new("Frame", { Size = UDim2.new(0, 1, 0, 30), BackgroundColor3 = C.acc, BorderSizePixel = 0, ZIndex = 41 }, calf)
    acc(function() calh.BackgroundColor3 = C.acc; calv.BackgroundColor3 = C.acc end)
    local CAL_PTS = { { 0.12, 0.16 }, { 0.88, 0.86 } }
    local function cal_place(i)
        local p = CAL_PTS[i]
        calh.Position = UDim2.new(p[1], -15, p[2], 0)
        calv.Position = UDim2.new(p[1], 0, p[2], -15)
    end
    local cal_mode = false
    local function start_cal(first)
        cal.pts, cal.t0 = {}, tick()
        cal_place(1)
        calt.Text = (first and "one-time setup: " or "") .. "click the centre of the cross (1 of 2)"
        cal_mode = true; calf.Visible = true
    end
    local function finish_cal()
        if tick() - cal.t0 < 0.3 then return end   -- the window is still popping in (UIScale tween)
        local rx, ry = raw_mouse()
        cal.pts[#cal.pts + 1] = { rx, ry, calv.AbsolutePosition.X, calh.AbsolutePosition.Y }
        if #cal.pts < 2 then
            cal_place(2)
            calt.Text = "and this one (2 of 2)"
            cal.t0 = tick()
            return
        end
        local a, b = cal.pts[1], cal.pts[2]
        local function solve(r1, g1, r2, g2)
            local s = 1
            if math.abs(r2 - r1) > 60 then s = (g2 - g1) / (r2 - r1) end
            if s < 0.4 or s > 2.5 then s = 1 end      -- misclick: keep the plain offset
            if math.abs(s - 1) < 0.04 then s = 1 end  -- click jitter, not DPI scaling
            return s, ((g1 - r1 * s) + (g2 - r2 * s)) / 2
        end
        local sx, ox = solve(a[1], a[3], b[1], b[3])
        local sy, oy = solve(a[2], a[4], b[2], b[4])
        remeasure()
        cal.sx, cal.sy = sx, sy
        cal.rx, cal.ry = rnd(ox - cal.ax), rnd(oy - cal.ay)
        save_cal("manual")
        cal_mode = false
        calf.Visible = false
        say(120, 255, 160, "mouse calibrated by hand: " .. cal_text())
    end
    local function reset_cal()
        cal.rx, cal.ry, cal.sx, cal.sy = 0, 0, 1, 1
        remeasure()
        save_cal("auto")
        diag()
    end

    -- ---------- pages + tabs ----------
    local function open_tab(i)
        for j, pg in ipairs(pages) do
            local sel = (j == i)
            pg.Visible = sel
            tabs[j].name.TextColor3 = sel and C.hi or C.mut
            tabs[j].name.Font = sel and FB or FM
            tabs[j].icon.BackgroundColor3 = sel and C.acc or C.ctl
            tabs[j].bar.Visible = sel
        end
        cur_page = pages[i]
        if pop then pop.frame:Destroy(); pop = nil end
        for _, rf in ipairs(refresh) do
            if rf.page == cur_page then pcall(rf.fn) end
        end
        dbw("ui_tab", tostring(i))
    end

    local function add_page(name)
        local i = #pages + 1
        local p = new("ScrollingFrame", { Size = UDim2.new(1, -RAIL, 1, -TOP - 1), Position = UDim2.new(0, RAIL, 0, TOP + 1),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = C.ctl,
            CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false }, win)
        -- columns are sized in pixels: scale sizes inside a padded, auto-sized ScrollingFrame ignore the side
        -- padding, which pushed the right column into the window edge with no gap between the columns
        new("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 16) }, p)
        local PADX, GAP = 16, 12
        local CW = math.floor((W - RAIL - PADX * 2 - GAP) / 2)
        local cols = {}
        for c = 1, 2 do
            local col = new("Frame", { Size = UDim2.new(0, CW, 0, 0), Position = UDim2.new(0, PADX + (c - 1) * (CW + GAP), 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, p)
            new("UIListLayout", { Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder }, col)
            cols[c] = col
        end
        local b = new("TextButton", { Size = UDim2.new(1, -1, 0, 32), Position = UDim2.new(0, 0, 0, 12 + (i - 1) * 34),
            BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", AutoButtonColor = false }, rail)
        local icon = new("Frame", { Size = UDim2.new(0, 8, 0, 8), Position = UDim2.new(0, 20, 0.5, -4), BackgroundColor3 = C.ctl,
            BorderSizePixel = 0, Rotation = 45 }, b)
        corner(icon, 2)
        local nm = label(b, name, C.mut, LEFT, 13, FM); nm.Position = UDim2.new(0, 40, 0, 0); nm.Size = UDim2.new(1, -48, 1, 0)
        local bar = new("Frame", { Size = UDim2.new(0, 2, 0, 18), Position = UDim2.new(1, -2, 0.5, -9), BackgroundColor3 = C.acc,
            BorderSizePixel = 0, Visible = false }, b)
        corner(bar, 1)
        acc(function()
            bar.BackgroundColor3 = C.acc
            if cur_page == p then icon.BackgroundColor3 = C.acc end
        end)
        on(b, nil, function() open_tab(i) end)
        pages[i] = p
        tabs[i] = { btn = b, bar = bar, name = nm, icon = icon }
        return p, cols
    end

    -- tooltip text per setting, keyed "Section/Item" by the name the setting was created with (Settings > Menu > Tooltips)
    local tip = { want = false, row = nil, list = {}, cur = nil, t0 = 0, on = database.read("ui_tips") ~= "0", text = {
        -- rage
        ["Rage/Hitchance in air"] = "Hitchance used while you are in the air. 0 = keep the cheat's own value.",
        ["Rage/Hitchance moving"] = "Hitchance while you still move. Lower = the shot goes out while auto stop is braking instead of after a full stop. 0 = off.",
        ["Rage/Hitchance unscoped"] = "Hitchance for snipers fired without scope. 0 = off.",
        ["Rage/Hitchance vs crouched"] = "Hitchance when the target is crouching. 0 = off.",
        ["Rage/Min damage (0 menu)"] = "Minimum damage floor for every shot. 0 = use the cheat menu's value.",
        ["Rage/Lethal min damage"] = "Lowers min damage to the target's remaining hp, so a weak hit that kills still fires. Never raises it.",
        ["Peek & extras/Baim after misses"] = "Force body aim on a player after this many misses on them. 0 = never.",
        ["DT peek/DT peek"] = "While the key is held, min damage = half the target's hp, so a double tap pair kills.",
        ["DT peek/Key"] = "Hold to use DT peek. Click the box to rebind.",
        ["DT peek/Damage (0 = half hp)"] = "Min damage while DT peek is held. 0 = half the target's hp (50 with no target).",
        ["DT peek/Hitchance"] = "Hitchance while DT peek is held.",
        ["Fake duck peek/Fake duck peek"] = "Tags shots made while the key is held and can loosen hitchance / min damage for fake duck peeks.",
        ["Fake duck peek/Key"] = "Set this to the same key as the cheat's fake duck. Click the box to rebind.",
        ["Fake duck peek/Damage (0 menu)"] = "Min damage while held. 0 = leave the menu value.",
        ["Fake duck peek/Hitchance (0 menu)"] = "Hitchance while held. 0 = leave the menu value.",
        ["Effects/Enemy tracers"] = "Draws a line from an enemy to you when they shoot. Inferred: red when you took damage, otherwise their ammo dropped.",
        ["Effects/Tracer time"] = "How long an enemy tracer stays visible.",
        ["No spread/No-spread mode"] = "For no-spread servers: very low hitchance and lethal min damage. Overrides the Aimbot settings.",
        ["No spread/Toggle key"] = "Flips no-spread mode on/off (swaps whatever the switch says).",
        ["No spread/Hitchance"] = "Hitchance in no-spread mode.",
        ["No spread/Min damage (0 = lethal)"] = "Min damage in no-spread mode. 0 = the target's hp (one shot kill only).",
        ["No spread/Half hp with DT weapon"] = "With a double-tap weapon, half the hp is enough since two bullets go out. Scout/AWP count as single shot.",
        ["No spread/No baim after misses"] = "Ignore 'Baim after misses' in no-spread mode.",
        ["Quick stop/Quick stop"] = "Our own auto stop: brakes while the ragebot has a target and you are on the ground.",
        ["Quick stop/Method"] = "How to brake. Auto tests each method and drops the ones that don't slow you down.",
        ["Quick stop/Keep speed"] = "Percent of your speed to keep while stopping. 0 = full stop.",
        ["Quick stop/Max hold"] = "Longest time to keep braking for one target.",
        ["Quick stop/Rest after shot"] = "Pause braking this long after a shot (lets the DT pair go out, then lets you move).",
        -- anti-aim
        ["Anti-Aim/Enable"] = "Master switch for all anti-aim in this script.",
        ["Anti-Aim/Pitch"] = "Where your head looks up/down. Flick = switches down/up every 2 ticks.",
        ["Anti-Aim/Level pitch vs high target"] = "Sets pitch to zero for a moment while your target is above you.",
        ["Anti-Aim/Yaw offset"] = "Turns your base yaw by this many degrees.",
        ["Anti-Aim/Yaw modifier"] = "Extra yaw movement on top of the offset.",
        ["Anti-Aim/Modifier amount"] = "How far the yaw modifier swings.",
        ["Anti-Aim/Fake lag"] = "How many ticks to choke (hold back packets).",
        ["Anti-Aim/Lag variability"] = "Randomizes the choke amount so the pattern is harder to read.",
        ["Peek & extras/Anim breaker"] = "Breaks your animations (frozen legs in air, jitter) so your hitbox looks odd.",
        ["Desync/Inverter"] = "How the desync side changes. Delayed = flips after a delay; On-shot flip = flips when you shoot.",
        ["Desync/Limit standing"] = "Desync size while standing.",
        ["Desync/Limit moving"] = "Desync size while moving.",
        ["Desync/Limit in air"] = "Desync size while in the air.",
        ["Desync/Limit crouching"] = "Desync size while crouching.",
        ["Desync/Randomize limit"] = "Each flip uses 88-100% of the limit so the angle isn't fixed.",
        ["Desync/Delay"] = "Ticks between flips (Delayed inverter).",
        ["Desync/Delay jitter"] = "Random extra ticks added to each delay.",
        ["Desync/Invert"] = "Key to flip the desync side by hand.",
        ["Manual/Left"] = "Hold to face left.",
        ["Manual/Right"] = "Hold to face right.",
        ["Manual/Back"] = "Hold to face back.",
        -- defense
        ["Defensive/Defensive burst"] = "Short bursts of odd angles (pitch up, big yaw) to break enemy resolvers.",
        ["Defensive/Trigger"] = "When bursts fire: on a timer, right after you shoot, or all the time.",
        ["Defensive/Interval"] = "Time between bursts (interval trigger).",
        ["Defensive/Burst length"] = "How many ticks each burst lasts.",
        ["Defensive/Shift ticks"] = "Ticks to shift at the start of a burst (sent even when the charge reads 0).",
        ["Defensive/Burst pitch"] = "Pitch used during a burst.",
        ["Defensive/Burst yaw"] = "Yaw swing during a burst.",
        ["Defensive/Flip desync"] = "Flip desync side during a burst.",
        ["Defensive/Max lag in burst"] = "Choke the most ticks during a burst.",
        ["Defensive/Unchoke after burst"] = "Send a packet right after the burst ends.",
        ["Defensive/Randomize bursts"] = "Random length, side and timing per burst.",
        ["On-shot/On-shot AA"] = "Changes your angles for a few ticks when you shoot (your head is exposed then).",
        ["On-shot/Mode"] = "What to do on shot.",
        ["On-shot/Duration"] = "Ticks the on-shot AA lasts.",
        ["On-shot/Unchoke on shot"] = "Send a packet right when you shoot.",
        ["Dodge/Dodge AA"] = "Constantly re-rolls side, size and yaw while threatened. Replaces regular + defensive AA while active.",
        ["Dodge/Reroll every"] = "Time between re-rolls.",
        ["Dodge/Min desync"] = "Smallest desync a re-roll can pick.",
        ["Dodge/Max desync"] = "Largest desync a re-roll can pick.",
        ["Dodge/Asymmetric"] = "Left and right get slightly different sizes.",
        ["Dodge/Random yaw"] = "Random yaw added on each re-roll.",
        ["Dodge/Pitch scramble"] = "Also randomize pitch on re-roll.",
        ["Dodge/Swing every (0 off)"] = "Every so often do a big 4-tick swing (both sides, wide yaw and pitch).",
        ["Dodge/Swing shift"] = "Ticks to shift during a swing.",
        ["Dodge/Threat range"] = "An enemy closer than this counts as a threat ('On threat' mode).",
        ["Dodge/Re-roll when hit"] = "Re-roll and swing right after you take damage.",
        ["Clantag/Clantag"] = "Your clantag (killfeed, scoreboard, chat; not on ESP). Everyone can see it, so it shows you run this script.",
        ["Clantag/Tag text"] = "Up to 32 characters.",
        ["Clantag/Tag speed"] = "Animation step for Marquee / Typewriter.",
        ["Roll/Roll"] = "Leans your body sideways (the cheat's extended angles) to move your head. Follow / Against desync lean toward or away from the desync side. Untested: A/B it.",
        ["Roll/Roll amount"] = "How far to lean, -100..100%. Static uses the sign; the other modes use the size only.",
        ["Roll/Roll jitter rate"] = "Jitter: flip the lean every N ticks. Random: new random lean every N ticks.",
        ["Roll/Roll when"] = "Only roll in these movement states.",
        ["Fake pitch/Fake pitch"] = "Pitch desync: the fake pitch enemies' resolvers see, separate from your real pitch. Jitter alternates Up and Down.",
        ["Fake pitch/Fake pitch value"] = "Fake pitch in degrees for Custom (-70..70).",
        ["Fake pitch/Fake pitch offset"] = "The cheat's fake pitch angle offset (-20..20).",
        ["Fake pitch/Fake pitch jitter rate"] = "Jitter: swap Up and Down every N ticks.",
        ["Anti-roll/Roll counter"] = "When an enemy leans (roll), force safe points and/or body aim on them: a lean moves the head, which the resolver cannot know. Needs Resolver Active. Untested: A/B it.",
        ["Anti-roll/Lean threshold"] = "How far above their normal upright lean (head over pelvis) counts as rolled.",
        ["Anti-roll/Pitch brute force"] = "Against fake pitch: after missed head shots, aim as if their pitch were the opposite, then Zero, then back to what they show. A hit keeps it.",
        ["Anti-roll/Pitch misses"] = "Resolver head misses in a row before trying the next pitch.",
        ["Flick/Flick"] = "Adds a big yaw flick for a few ticks on a fixed cadence. Needs fake lag: turn double tap OFF in the cheat menu.",
        ["Flick/Every"] = "Cycle length in ticks.",
        ["Flick/Flick ticks"] = "How many ticks of each cycle are flicked.",
        ["Flick/Angle"] = "Added to your yaw offset during the flick.",
        ["Flick/Side"] = "Which way to flick (only matters below 180). Strafe fix flips it while you strafe left.",
        ["Flick/Max speed (0 off)"] = "No flicks above this speed.",
        ["Flick/Only while choking"] = "Flick only on choked ticks.",
        ["Flick/Unchoke on flick"] = "Send the packet on the first flick tick of each cycle.",
        ["Flick/Fake lag"] = "Fake lag forced while Flick is on.",
        ["Peek & extras/Peek AA"] = "Special AA for a short window when a target first appears (you peek).",
        ["Peek & extras/Peek window"] = "How many ticks the peek AA lasts after a target appears.",
        -- resolver
        ["Resolver/Mode"] = "Off; Shadow = only logs what it would do; Active = takes over a player after the cheat's resolver misses.",
        ["Resolver/Lead (-1 auto)"] = "Ticks to predict ahead. -1 = your ping.",
        ["Resolver/Take over after"] = "Built-in resolver misses on a player before ours takes over. 0 = never take over.",
        ["Resolver/Max offset"] = "Largest body yaw offset the resolver will force.",
        ["Resolver/Candidates"] = "Try 12 possible offsets and learn which ones hit per player. Off = only read side or its inverse.",
        ["Resolver/Fix pitch flicks"] = "Force the enemy's usual pitch when they flick it.",
        ["Resolver/Safe point on fake duck"] = "Force safe points on players who fake duck.",
        ["Enemy intel/Track enemies"] = "Watch the nearest enemies' desync side and flip pattern. The resolver and peek advice use this.",
        ["Enemy intel/Max tracked"] = "How many nearby enemies to track.",
        ["Enemy teleports/Detect teleports"] = "Spot enemies jumping further than they can run (DT teleport peeks) and log them.",
        ["Enemy teleports/Run speed"] = "A teleport must move at least this fast over 0.1s.",
        ["Enemy teleports/Min jump"] = "Studs moved beyond what their own speed just before explains.",
        -- visuals
        ["Crosshair/Indicators"] = "Arrows and status text around the crosshair.",
        ["Crosshair/Arrow gap"] = "Distance of the < > arrows from the center.",
        ["Crosshair/Text offset"] = "Distance of the text lines below the center.",
        ["Crosshair/Title"] = "Show the script name under the crosshair.",
        ["Crosshair/Debug"] = "Yaw dial (grey = camera, green R = real, red F = fake) + readout lines.",
        ["Crosshair/Dial radius"] = "Size of the debug yaw dial.",
        ["Crosshair/Peek advice"] = "Bar between the arrows: green = peek now, amber = ok, red = wait. Shrinks as the enemy's next flip nears.",
        ["Peek advisor/Overlay"] = "Text panel with the peek verdict and reasons for each tracked enemy.",
        ["Peek advisor/View-angle check"] = "Also judge by where enemies are looking.",
        ["Peek advisor/Look-away angle"] = "View-angle check: an enemy looking this far off you counts as not aiming.",
        ["Peek advisor/Defensive cooldown"] = "Wait this many ticks after an enemy's defensive burst.",
        ["Peek advisor/Safety margin"] = "Extra ticks added to your ping when checking if their side stays stable long enough.",
        ["Arrows/World arrows"] = "3D arrows at your feet: real (green) and fake (red) yaw.",
        ["Arrows/View arrow"] = "White arrow for your camera direction. Use it to calibrate Rotation.",
        ["Arrows/Length"] = "Arrow length in studs.",
        ["Arrows/Mirror"] = "Mirror the arrows and the debug dial left/right.",
        ["Arrows/Rotation"] = "Rotates the arrows to line up with your model. Check it with the view arrow.",
        ["Desync/Fake chams"] = "Show the cheat's fake-angle chams (where your fake body is).",
        ["HUD/Watermark"] = "Top right: name, ping, fps.",
        ["HUD/Keybind list"] = "Left side: which binds are active right now.",
        ["HUD/Target panel"] = "Ragebot target: hp, distance, weapon, resolver info.",
        ["HUD/Hit log"] = "Short notes top left for each hit and miss.",
        ["HUD/Damage numbers"] = "Damage pops up next to the crosshair.",
        ["Effects/Kill effect"] = "3D effect where a player dies.",
        ["Effects/Hit effect"] = "3D effect where your shot hits.",
        ["Effects/Hit sound"] = "Sound on hit.",
        ["Effects/Kill sound"] = "Sound on kill.",
        ["Effects/Sound volume"] = "Volume for hit and kill sounds.",
        -- logs
        ["Debug/Hit list overlay"] = "On-screen list of the last hits you took.",
        ["Enemy intel/Overlay"] = "On-screen panel with each tracked enemy's side and flip pattern.",
        ["Shot log/Log my shots"] = "Console line for every hit and miss you make, with the miss reason.",
        ["Shot log/Print shots"] = "Print the recent shots to the console.",
        ["Shot log/Clear shots"] = "Forget recorded shots.",
        ["Debug/Log hits taken"] = "Record every hit you take with your AA state at that moment.",
        ["Debug/Console log"] = "Also print a console line for each hit taken.",
        ["Debug/Print report"] = "Print a summary of hits taken.",
        ["Debug/Clear hits"] = "Forget recorded hits taken.",
        ["Fine data/Record timelines"] = "Keep a tick-by-tick timeline of your AA before each hit taken.",
        ["Fine data/Console summary"] = "One summary line per hit taken.",
        ["Fine data/Console timeline"] = "Print the full timeline per hit (floods the console).",
        ["Fine data/Timeline length"] = "Ticks of history kept before each hit.",
        ["Fine data/Print count"] = "How many hits 'Print timelines' prints.",
        ["Fine data/CSV count"] = "How many hits 'Print CSV' prints.",
        ["Fine data/Print stats"] = "Print deaths split by state, flip timing and settings.",
        ["Fine data/Print timelines"] = "Print the last few hit timelines.",
        ["Fine data/Print CSV"] = "Print the last hits as CSV.",
        ["Fine data/Clear data"] = "Forget all timelines and stats.",
        ["Enemy intel/Print intel"] = "Print what is known about each tracked enemy.",
        ["Enemy intel/Reset intel"] = "Forget all enemy patterns.",
        ["Enemy teleports/Console line per teleport"] = "Console line for every enemy teleport (can be spammy).",
    } }

    -- section: bold header, then one rounded row per setting
    local function group(col, title)
        local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
            LayoutOrder = nexto() }, col)
        new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
        local t = label(holder, title, C.hi, LEFT, 13, FB); t.Size = UDim2.new(1, 0, 0, 20); t.LayoutOrder = nexto()
        return holder
    end
    -- one setting row (a rounded card); clickable rows are TextButtons so the whole card takes the click
    local function row(parent, h, button)
        local r
        if button then
            r = new("TextButton", { Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "",
                AutoButtonColor = false, LayoutOrder = nexto() }, parent)
        else
            r = new("Frame", { Size = UDim2.new(1, 0, 0, h), BackgroundColor3 = C.card, BorderSizePixel = 0, LayoutOrder = nexto() }, parent)
        end
        corner(r, 6)
        if tip.want then tip.row, tip.want = r, false end   -- first row a control makes = where its tooltip hovers
        return r
    end
    local function name_label(r, text, y)
        local l = label(r, text, C.txt, LEFT, 12)
        l.Position = UDim2.new(0, 12, 0, y or 0); l.Size = UDim2.new(1, -24, 0, y and 16 or r.Size.Y.Offset)
        return l
    end
    -- input-looking box inside a row
    local function field(r, y)
        local f = new("Frame", { Size = UDim2.new(1, -24, 0, 22), Position = UDim2.new(0, 12, 0, y), BackgroundColor3 = C.field,
            BorderSizePixel = 0 }, r)
        corner(f, 4)
        return f
    end
    -- small "v" made of two bars
    local function chevron(parent, x)
        local a = new("Frame", { Size = UDim2.new(0, 6, 0, 2), Position = UDim2.new(1, x, 0.5, -1), Rotation = 45,
            BackgroundColor3 = C.txt, BorderSizePixel = 0 }, parent)
        local b = new("Frame", { Size = UDim2.new(0, 6, 0, 2), Position = UDim2.new(1, x + 4, 0.5, -1), Rotation = -45,
            BackgroundColor3 = C.txt, BorderSizePixel = 0 }, parent)
        corner(a, 1); corner(b, 1)
    end

    -- ---------- controls ----------
    local drag_slider = nil
    local focus_tb = nil

    local function ctl_toggle(p, parent, it)
        local r = row(parent, 34, true)
        local l = name_label(r, it.name)
        local pill = new("Frame", { Size = UDim2.new(0, 28, 0, 14), Position = UDim2.new(1, -40, 0.5, -7), BackgroundColor3 = C.ctl,
            BorderSizePixel = 0 }, r)
        corner(pill, 7)
        local knob = new("Frame", { Size = UDim2.new(0, 10, 0, 10), Position = UDim2.new(0, 2, 0.5, -5), BackgroundColor3 = C.knob,
            BorderSizePixel = 0 }, pill)
        corner(knob, 5)
        local last = nil
        local function show(v, force)
            if v == last and not force then return end
            last = v
            pill.BackgroundColor3 = v and C.acc or C.ctl
            knob.Position = v and UDim2.new(1, -12, 0.5, -5) or UDim2.new(0, 2, 0.5, -5)
            l.TextColor3 = v and C.hi or C.txt
        end
        acc(function() show(last, true) end)
        on(r, p, function()
            local v = not (hget(it.h) == true)
            hset(it, v); show(v)
        end)
        track(p, function() show(hget(it.h) == true) end)
    end

    local function fmtnum(v, dec)
        if dec and dec > 0 then return string.format("%." .. tostring(dec) .. "f", v) end
        return tostring(math.floor(v + 0.5))
    end

    local function ctl_slider(p, parent, it)
        local r = row(parent, 48)
        name_label(r, it.name, 8)
        local val = label(r, "", C.hi, RIGHT, 12, FB); val.Size = UDim2.new(0, 70, 0, 16); val.Position = UDim2.new(1, -82, 0, 8)
        local hit = new("TextButton", { Size = UDim2.new(1, -24, 0, 16), Position = UDim2.new(0, 12, 0, 26), BackgroundTransparency = 1,
            Text = "", AutoButtonColor = false }, r)
        local trk = new("Frame", { Size = UDim2.new(1, 0, 0, 4), Position = UDim2.new(0, 0, 0.5, -2), BackgroundColor3 = C.ctl,
            BorderSizePixel = 0 }, hit)
        corner(trk, 2)
        local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C.acc, BorderSizePixel = 0 }, trk)
        corner(fill, 2)
        local knob = new("Frame", { Size = UDim2.new(0, 12, 0, 12), Position = UDim2.new(0, -6, 0.5, -6), BackgroundColor3 = C.knob,
            BorderSizePixel = 0, ZIndex = 2 }, trk)
        corner(knob, 6)
        acc(function() fill.BackgroundColor3 = C.acc end)
        local span = it.hi - it.lo
        if span == 0 then span = 1 end
        local last = nil
        local function show(v)
            if type(v) ~= "number" or v == last then return end
            last = v
            local f = math.clamp((v - it.lo) / span, 0, 1)
            fill.Size = UDim2.new(f, 0, 1, 0)
            knob.Position = UDim2.new(f, -6, 0.5, -6)
            val.Text = fmtnum(v, it.dec) .. (it.suf or "")
        end
        local function from_mouse()
            local mx = mouse()
            local f = math.clamp((mx - trk.AbsolutePosition.X) / math.max(trk.AbsoluteSize.X, 1), 0, 1)
            local mul = 10 ^ (it.dec or 0)
            local v = math.floor((it.lo + f * span) * mul + 0.5) / mul
            if v ~= last then hset(it, v); show(v) end
        end
        on(hit, p, nil, function() drag_slider = from_mouse; pcall(from_mouse) end)
        track(p, function() show(hget(it.h)) end)
    end

    local function close_pop()
        if pop then pcall(function() pop.frame:Destroy() end); pop = nil end
    end
    local function ctl_combo(p, parent, it)
        local r = row(parent, 34, true)
        name_label(r, it.name).Size = UDim2.new(0.5, -12, 1, 0)
        local cur = label(r, "", C.hi, RIGHT, 12, FM); cur.Position = UDim2.new(0.5, 0, 0, 0); cur.Size = UDim2.new(0.5, -34, 1, 0)
        chevron(r, -24)
        local function idx()
            local v = hget(it.h)
            if type(v) == "number" then return v end
            for i, o in ipairs(it.opts) do
                if o == v then return i end
            end
            return 1
        end
        local last = nil
        local function show()
            local i = idx()
            if i ~= last then last = i; cur.Text = tostring(it.opts[i] or "?") end
        end
        on(r, p, function()
            if pop and pop.owner == it then close_pop() return end
            close_pop()
            local ap, wp = r.AbsolutePosition, win.AbsolutePosition
            local n = #it.opts
            local w = math.max(140, math.floor(r.AbsoluteSize.X * 0.55))
            local fr = new("Frame", { Size = UDim2.new(0, w, 0, n * 26 + 8), BackgroundColor3 = C.field, BorderSizePixel = 0,
                Position = UDim2.new(0, ap.X - wp.X + r.AbsoluteSize.X - w, 0, ap.Y - wp.Y + r.AbsoluteSize.Y + 4), ZIndex = 30 }, win)
            corner(fr, 6); stroke(fr)
            pop = { frame = fr, owner = it, items = {} }
            local sel = idx()
            for i, o in ipairs(it.opts) do
                local b = new("TextButton", { Size = UDim2.new(1, -8, 0, 26), Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 26),
                    BackgroundColor3 = C.card_hi, BackgroundTransparency = (i == sel) and 0 or 1, BorderSizePixel = 0, Text = "",
                    AutoButtonColor = false, ZIndex = 31 }, fr)
                corner(b, 4)
                local t = label(b, tostring(o), i == sel and C.acc or C.txt, LEFT, 12, i == sel and FM or F)
                t.Position = UDim2.new(0, 10, 0, 0); t.Size = UDim2.new(1, -10, 1, 0); t.ZIndex = 32
                pop.items[#pop.items + 1] = { o = b, click = function()
                    hset(it, o); close_pop(); last = nil; show()
                end }
            end
        end)
        track(p, show)
    end

    -- rebinding: click the key box, then press a key (or mouse 2 / 3). Esc cancels, Backspace / Delete = no key.
    local kcap = { it = nil, t0 = 0, armed = false }
    local function ctl_key(p, parent, it)
        local r = row(parent, 34)
        name_label(r, it.name)
        local box = new("Frame", { Size = UDim2.new(0, 64, 0, 20), Position = UDim2.new(1, -76, 0.5, -10), BackgroundColor3 = C.field,
            BorderSizePixel = 0 }, r)
        corner(box, 4)
        local k = label(box, "", C.hi, CENTER, 11, FM); k.Size = UDim2.new(1, 0, 1, 0)
        local md = label(r, "", C.mut, RIGHT, 11); md.Position = UDim2.new(1, -150, 0, 0); md.Size = UDim2.new(0, 66, 1, 0)
        local function show()
            if kcap.it == it then
                k.Text = "press..."
                k.TextColor3 = C.acc
            else
                local active = hget(it.h) == true
                local key = it.h.key
                k.Text = key and string.gsub(tostring(key), "^MouseButton", "Mouse ") or "None"
                k.TextColor3 = active and C.acc or C.hi
            end
            md.Text = string.lower(tostring(it.mode or ""))
        end
        track(p, show)
        it.show = show
        on(box, p, function()
            local old = kcap.it
            kcap.it, kcap.t0, kcap.armed = it, tick(), false
            if old and old.show then pcall(old.show) end
            show()
        end)
    end

    local SECRET = { ["Token"] = true, ["Webhook URL"] = true }
    local function ctl_text(p, parent, it)
        local r = row(parent, 60)
        name_label(r, it.name, 8)
        local box = field(r, 28)
        local tb = new("TextBox", { Size = UDim2.new(1, -16, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
            Text = "", PlaceholderText = it.ph or "", PlaceholderColor3 = C.mut, TextColor3 = C.hi, TextSize = 12, Font = F,
            ClearTextOnFocus = false, TextXAlignment = LEFT, TextTruncate = Enum.TextTruncate.AtEnd }, box)
        local secret = SECRET[it.name]
        local function show()
            if tb:IsFocused() then return end
            local v = hget(it.h)
            if secret then
                if tb.Text ~= "" then tb.Text = "" end
                tb.PlaceholderText = (type(v) == "string" and #v > 0) and "saved, type to replace" or (it.ph or "")
            else
                local s = type(v) == "string" and v or ""
                if tb.Text ~= s then tb.Text = s end
            end
        end
        local function commit()
            local v = tb.Text
            if secret and v == "" then show(); return end
            hset(it, v)
            if secret then tb.Text = "" end
            show()
        end
        on(box, p, function() pcall(function() tb:CaptureFocus() end); focus_tb = { tb = tb, commit = commit } end)
        track(p, show)
        return tb
    end

    local function ctl_button(p, parent, it)
        local r = row(parent, 34, true)
        local t = label(r, it.name, C.hi, CENTER, 12, FM); t.Size = UDim2.new(1, 0, 1, 0)
        it.label = t
        on(r, p, function()
            local ok, err = pcall(it.cb)
            t.TextColor3 = ok and C.acc or C.bad
            r.BackgroundColor3 = C.card_hi
            task.delay(0.5, function() t.TextColor3 = C.hi; r.BackgroundColor3 = C.card end)
            if not ok then say(255, 90, 90, it.name .. ": " .. tostring(err)) end
        end)
        return t
    end

    -- key / value row; returns the value label
    local function info(parent, key)
        local r = row(parent, 30)
        local k = label(r, key, C.txt, LEFT, 12); k.Position = UDim2.new(0, 12, 0, 0); k.Size = UDim2.new(0.4, -12, 1, 0)
        local v = label(r, "", C.hi, RIGHT, 12, FM); v.Position = UDim2.new(0.4, 0, 0, 0); v.Size = UDim2.new(0.6, -12, 1, 0)
        return v
    end
    -- plain status text under a section (no card)
    local function line(parent)
        local l = label(parent, "", C.mut, LEFT, 11)
        l.Size = UDim2.new(1, -4, 0, 16); l.Position = UDim2.new(0, 4, 0, 0); l.LayoutOrder = nexto()
        return l
    end

    local CTL = { toggle = ctl_toggle, slider = ctl_slider, combo = ctl_combo, key = ctl_key, text = ctl_text, button = ctl_button }
    local function control(p, parent, it)
        local f = CTL[it.kind]
        if f then
            tip.want, tip.row = true, nil
            local ok, res = pcall(f, p, parent, it)
            tip.want = false
            if not ok then say(255, 90, 90, tostring(it.name) .. ": " .. tostring(res)) end
            local tx = it.tip_id and tip.text[it.tip_id]
            if ok and tip.row and tx then tip.list[#tip.list + 1] = { o = tip.row, p = p, text = tx } end
            return ok and res or nil
        end
    end
    local function find_sec(name)
        for _, s in ipairs(tab.sections) do
            if s.name == name then return s end
        end
        return nil
    end

    -- ---------- http (cloud configs, account, log upload) ----------
    local function base_url()
        local u = sv_url:get()
        return type(u) == "string" and string.match(u, "^(https://[^/]+)") or nil
    end
    local function api(method, path, body)
        local b, hdr = base_url(), st.auth(sv_tok:get())
        if not b or not hdr then return nil, { error = "not logged in" } end
        local h = {}
        for k, v in pairs(hdr) do h[k] = v end
        if body then h["Content-Type"] = "application/json" end
        local ok, res = pcall(function()
            return HttpService:RequestAsync({ Url = b .. path, Method = method, Headers = h,
                Body = body and HttpService:JSONEncode(body) or nil })
        end)
        if not ok or type(res) ~= "table" then return nil, { error = tostring(res) } end
        local okd, out = pcall(function() return HttpService:JSONDecode(res.Body or "") end)
        return res.StatusCode, (okd and type(out) == "table") and out or { error = "status " .. tostring(res.StatusCode) }
    end
    local function urlq(s) return (string.gsub(tostring(s), "[^%w%-_%.]", function(c) return string.format("%%%02X", string.byte(c)) end)) end

    -- ======================= pages =======================
    -- Window layout only: a group lists whole sections ("Name" = that section's items not picked by any other
    -- group) and/or single items { "Section", "Item", "label shown" }. Config / remote keys stay "Section/Item".
    local LAYOUT = {
        Rage = {
            { 1, "Aimbot", { { "Rage", "Hitchance in air" }, { "Rage", "Hitchance moving" }, { "Rage", "Hitchance unscoped" },
                { "Rage", "Hitchance vs crouched" }, { "Rage", "Min damage (0 menu)", "Min damage (0 = menu)" },
                { "Rage", "Lethal min damage" }, { "Peek & extras", "Baim after misses" } } },
            { 1, "DT peek", { "DT peek" } },
            { 1, "Fake duck peek", { "Fake duck peek" } },
            { 2, "No spread", { "No spread" } },
        },
        ["Anti-aim"] = {
            { 1, "Style", { "Style" } },
            { 1, "Anti-aim", { "Anti-Aim" } },
            { 1, "Fake lag", { { "Anti-Aim", "Fake lag" }, { "Anti-Aim", "Lag variability" } } },
            { 1, "Animations", { { "Peek & extras", "Anim breaker" } } },
            { 2, "Desync", { "Desync" } },
            { 2, "Roll", { "Roll" } },
            { 2, "Fake pitch", { "Fake pitch" } },
            { 2, "Manual yaw", { "Manual" } },
        },
        Defense = {
            { 1, "Defensive", { "Defensive" } },
            { 1, "On-shot", { "On-shot" } },
            { 1, "Flick", { "Flick" } },
            { 2, "Dodge AA", { "Dodge" } },
            { 2, "Peek AA", { "Peek & extras" } },
        },
        Resolver = {
            { 1, "Resolver", { "Resolver" } },
            { 1, "Anti-roll", { "Anti-roll" } },
            { 2, "Enemy tracking", { "Enemy intel" } },
            { 2, "Teleport detection", { "Enemy teleports" } },
        },
        Visuals = {
            { 1, "Crosshair", { "Crosshair" } },
            { 1, "Peek advice", { { "Crosshair", "Peek advice", "Show on crosshair" }, { "Peek advisor", "Overlay", "Show panel" },
                "Peek advisor" } },
            { 2, "HUD", { "HUD" } },
            { 2, "World", { { "Arrows", "World arrows" }, "Arrows", { "Desync", "Fake chams" } } },
            { 2, "Effects", { "Effects" } },
            { 2, "Clantag", { "Clantag" } },
        },
        Logs = {
            { 1, "Overlays", { { "Debug", "Hit list overlay", "Hits taken list" }, { "Enemy intel", "Overlay", "Enemy intel" } } },
            { 1, "My shots", { "Shot log" } },
            { 1, "Hits taken", { "Debug" } },
            { 2, "Timelines", { "Fine data" } },
            { 2, "Enemy intel", { { "Enemy intel", "Print intel" }, { "Enemy intel", "Reset intel" },
                { "Enemy teleports", "Console line per teleport" } } },
        },
    }
    -- webhook proxy is rate limited; feed is database/remote only; Quick stop can't move this game's anchored,
    -- Humanoid-less character (qs rig diag), so it stays Off and reachable only by remote control for tests
    local HIDDEN = { ["Discord export"] = true, ["Live server feed"] = true, ["Quick stop"] = true }
    local lay = { claimed = {}, shown = {} }
    function lay.item(sn, iname)
        local s = find_sec(sn)
        if not s then return nil end
        for _, it in ipairs(s.items) do if it.name == iname then return it end end
        return nil
    end
    for _, groups in pairs(LAYOUT) do
        for _, gr in ipairs(groups) do
            for _, pk in ipairs(gr[3]) do
                if type(pk) == "table" then
                    local it = lay.item(pk[1], pk[2])
                    if it then lay.claimed[it] = true end
                end
            end
        end
    end
    function lay.build(p, cols, groups)
        for _, gr in ipairs(groups) do
            local g = nil
            local function put(it, shown_as)
                if not it or lay.shown[it] then return end
                lay.shown[it] = true
                if shown_as then
                    local cp = {}
                    for k, v in pairs(it) do cp[k] = v end
                    cp.name = shown_as
                    it = cp
                end
                g = g or group(cols[gr[1]], gr[2])   -- a group only appears once it has something in it
                control(p, g, it)
            end
            for _, pk in ipairs(gr[3]) do
                if type(pk) == "table" then
                    put(lay.item(pk[1], pk[2]), pk[3])
                else
                    local s = find_sec(pk)
                    for _, it in ipairs(s and s.items or {}) do
                        if not lay.claimed[it] then put(it) end
                    end
                end
            end
        end
    end
    for _, name in ipairs({ "Rage", "Anti-aim", "Defense", "Resolver", "Visuals" }) do
        local p, cols = add_page(name)
        lay.build(p, cols, LAYOUT[name])
    end

    -- logs: session stats + recorders
    local p_dat, c_dat = add_page("Logs")
    local stats = { kills = 0, deaths = 0, seen = fd_total, last = {} }
    client.set_event_callback("aim_hit", function(e)
        if e and type(e.health_remaining) == "number" and e.health_remaining <= 0 then stats.kills = stats.kills + 1 end
    end)
    local g_ses = group(c_dat[1], "Session")
    local i_kd, i_hit = info(g_ses, "K / D"), info(g_ses, "Shots")
    local d_lines = {}
    for i = 1, 5 do d_lines[i] = line(g_ses) end
    lay.build(p_dat, c_dat, LAYOUT.Logs)

    local function ago(t)
        local s = math.max(0, math.floor(tick() - t))
        if s < 60 then return tostring(s) .. "s" end
        return tostring(math.floor(s / 60)) .. "m"
    end
    local function scan_deaths()
        for _, e in ipairs(fd_hits) do
            if e.n > stats.seen then
                stats.seen = e.n
                if type(e.hp_after) == "number" and e.hp_after <= 0 then
                    stats.deaths = stats.deaths + 1
                    local en = e.enemies and e.enemies[1]
                    table.insert(stats.last, 1, { t = tick(), dmg = e.dmg, flip = e.flip_age, state = e.last and e.last.state or "?",
                        who = en and string.format("%s %s %.0fst", tostring(en.name), string.lower(tostring(en.wep)), tonumber(en.dist) or 0) or "?" })
                    if #stats.last > 5 then table.remove(stats.last) end
                end
            end
        end
    end
    track(p_dat, function()
        i_kd.Text = string.format("%d / %d%s", stats.kills, stats.deaths,
            stats.deaths > 0 and string.format("  (%.1f)", stats.kills / stats.deaths) or "")
        local shots = sh_cnt.hit + sh_cnt.miss
        i_hit.Text = shots > 0 and string.format("%d hit, %d miss (%d%%)", sh_cnt.hit, sh_cnt.miss, math.floor(sh_cnt.hit * 100 / shots + 0.5)) or "-"
        for i = 1, 5 do
            local d = stats.last[i]
            d_lines[i].Text = d and string.format("%s  -%s %s flip %st  %s", ago(d.t), tostring(d.dmg), tostring(d.state), tostring(d.flip), d.who)
                or (i == 1 and "no deaths yet" or "")
            d_lines[i].TextColor3 = (d and (tonumber(d.flip) or 99) <= 1) and C.warn or C.mut
        end
    end)

    -- ---------- configs (cloud) ----------
    local p_cfg, c_cfg = add_page("Configs")
    local SKIP_CFG = { ["Live server feed"] = true, ["Discord export"] = true, ["Quick stop"] = true }   -- old configs can't turn QS on
    local function cfg_items()
        local out = {}
        for _, s in ipairs(tab.sections) do
            if not SKIP_CFG[s.name] then
                for _, it in ipairs(s.items) do
                    if it.kind == "toggle" or it.kind == "slider" or it.kind == "combo" then out[s.name .. "/" .. it.name] = it end
                end
            end
        end
        return out
    end
    local function cfg_dump()
        local data, n = {}, 0
        for k, it in pairs(cfg_items()) do
            local v = hget(it.h)
            if it.kind == "combo" and type(v) == "number" then v = it.opts[v] end
            if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then data[k] = v; n = n + 1 end
        end
        return data, n
    end
    local function cfg_apply(data)
        local items, n, bad = cfg_items(), 0, 0
        for k, v in pairs(data) do
            local it = items[k]
            local ok = false
            if it and it.kind == "toggle" then ok = type(v) == "boolean"
            elseif it and it.kind == "slider" then ok = type(v) == "number" and v >= it.lo and v <= it.hi
            elseif it and it.kind == "combo" then
                for _, o in ipairs(it.opts) do if o == v then ok = true end end
            end
            if ok then hset(it, v); n = n + 1 else bad = bad + 1 end
        end
        return n, bad
    end

    local cfg = { list = {}, sel = nil, busy = false, confirm = 0 }
    -- built-in presets ship inside the script (work offline, load-only). The script itself starts with every
    -- feature off; "unsyk preset" = the settings that used to be the defaults.
    cfg.builtin = {
        { name = "unsyk preset", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- tested: bare static-back 84 = 0.92 deaths/min over 52 min vs baseline 1.03 over 68 (no real difference, simpler AA)
        { name = "Static back 84", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Static back",
            ["Style/Static desync"] = 84,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- same as Static back 84 with pitch Up (enemies run Up ~99%); untested
        { name = "Static back + Up", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Up",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Static back",
            ["Style/Static desync"] = 84,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- untested: swaps Static back and No AA every ~10s so resolvers never learn one
        { name = "Swap static / no AA", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Swap",
            ["Style/Static desync"] = 84,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- delay 8 -> 4 improved deaths/min and K/D; this goes further (2 + 0-2 jitter), untested
        { name = "Fast delay", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 2,
            ["Desync/Delay jitter"] = 2,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- baseline with pitch Up and no pitch levelling (mirrors the enemy lead), untested
        { name = "Pitch Up custom", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Up",
            ["Anti-Aim/Level pitch vs high target"] = false,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- untested: dodge AA re-rolls side/size/yaw while an enemy is near; defensive off to avoid overlap
        { name = "Dodge on threat", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = false,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "On threat",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- for no-spread servers: no-spread mode + DT peek key, resolver candidates (baseline AA)
        { name = "No-spread DT peek", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 600,
            ["Defensive/Burst length"] = 4,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Up",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = true,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- from the Discord notes (defensives are 'real now', statics are bad): short interval, long jittery bursts, full shift. Our shift only fires if the DT charge reads >0, which it never has: check the Defensive diag first
        { name = "Defensive heavy", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 2,
            ["Desync/Delay jitter"] = 2,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 300,
            ["Defensive/Burst length"] = 6,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Jitter",
            ["Defensive/Burst yaw"] = 180,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "Off",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- defensive burst on a fast cycle plus Dodge AA while threatened; untested
        { name = "Defensive + dodge", builtin = true, data = {
            ["Anti-Aim/Enable"] = true,
            ["Anti-Aim/Pitch"] = "Down",
            ["Anti-Aim/Level pitch vs high target"] = true,
            ["Anti-Aim/Yaw offset"] = 0,
            ["Anti-Aim/Yaw modifier"] = "Center",
            ["Anti-Aim/Modifier amount"] = 30,
            ["Anti-Aim/Fake lag"] = 10,
            ["Anti-Aim/Lag variability"] = 20,
            ["Desync/Inverter"] = "Delayed",
            ["Desync/Limit standing"] = 84,
            ["Desync/Limit moving"] = 84,
            ["Desync/Limit in air"] = 84,
            ["Desync/Limit crouching"] = 84,
            ["Desync/Randomize limit"] = true,
            ["Desync/Delay"] = 4,
            ["Desync/Delay jitter"] = 4,
            ["Desync/Fake chams"] = false,
            ["Defensive/Defensive burst"] = true,
            ["Defensive/Trigger"] = "interval",
            ["Defensive/Interval"] = 400,
            ["Defensive/Burst length"] = 5,
            ["Defensive/Shift ticks"] = 14,
            ["Defensive/Burst pitch"] = "Jitter",
            ["Defensive/Burst yaw"] = 140,
            ["Defensive/Flip desync"] = true,
            ["Defensive/Max lag in burst"] = true,
            ["Defensive/Unchoke after burst"] = true,
            ["Defensive/Randomize bursts"] = true,
            ["On-shot/On-shot AA"] = true,
            ["On-shot/Mode"] = "Max desync flip",
            ["On-shot/Duration"] = 2,
            ["On-shot/Unchoke on shot"] = true,
            ["Arrows/World arrows"] = false,
            ["Arrows/View arrow"] = false,
            ["Arrows/Length"] = 5,
            ["Arrows/Mirror"] = false,
            ["Arrows/Rotation"] = 180,
            ["Crosshair/Indicators"] = true,
            ["Crosshair/Arrow gap"] = 45,
            ["Crosshair/Text offset"] = 24,
            ["Crosshair/Title"] = false,
            ["Crosshair/Debug"] = false,
            ["Crosshair/Dial radius"] = 34,
            ["Crosshair/Peek advice"] = true,
            ["Debug/Log hits taken"] = true,
            ["Debug/Console log"] = false,
            ["Debug/Hit list overlay"] = false,
            ["Enemy intel/Track enemies"] = true,
            ["Enemy intel/Max tracked"] = 2,
            ["Enemy intel/Overlay"] = false,
            ["Peek advisor/Overlay"] = false,
            ["Peek advisor/View-angle check"] = false,
            ["Peek advisor/Look-away angle"] = 25,
            ["Peek advisor/Defensive cooldown"] = 64,
            ["Peek advisor/Safety margin"] = 2,
            ["Shot log/Log my shots"] = true,
            ["Fine data/Record timelines"] = true,
            ["Fine data/Console summary"] = true,
            ["Fine data/Console timeline"] = false,
            ["Fine data/Timeline length"] = 16,
            ["Fine data/Print count"] = 3,
            ["Fine data/CSV count"] = 30,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Lead (-1 auto)"] = -1,
            ["Resolver/Take over after"] = 1,
            ["Resolver/Max offset"] = 58,
            ["Peek & extras/Peek AA"] = "Off",
            ["Peek & extras/Peek window"] = 24,
            ["Peek & extras/Baim after misses"] = 0,
            ["Peek & extras/Anim breaker"] = "Off",
            ["Dodge/Dodge AA"] = "On threat",
            ["Dodge/Reroll every"] = 50,
            ["Dodge/Min desync"] = 30,
            ["Dodge/Max desync"] = 84,
            ["Dodge/Asymmetric"] = true,
            ["Dodge/Random yaw"] = 30,
            ["Dodge/Pitch scramble"] = false,
            ["Dodge/Swing every (0 off)"] = 700,
            ["Dodge/Swing shift"] = 8,
            ["Dodge/Threat range"] = 250,
            ["Dodge/Re-roll when hit"] = true,
            ["Resolver/Candidates"] = true,
            ["Resolver/Fix pitch flicks"] = true,
            ["Resolver/Safe point on fake duck"] = true,
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Rage/Hitchance moving"] = 0,
            ["No spread/No-spread mode"] = false,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = false,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["HUD/Watermark"] = true,
            ["HUD/Keybind list"] = true,
            ["HUD/Target panel"] = false,
            ["HUD/Hit log"] = true,
            ["HUD/Damage numbers"] = true,
            ["Effects/Kill effect"] = "Shockwave",
            ["Effects/Hit effect"] = "Off",
            ["Effects/Hit sound"] = "Off",
            ["Effects/Kill sound"] = "Off",
            ["Effects/Sound volume"] = 70,
            ["Enemy teleports/Detect teleports"] = true,
            ["Enemy teleports/Run speed"] = 30,
            ["Enemy teleports/Min jump"] = 2.5,
            ["Enemy teleports/Console line per teleport"] = false,
            ["Style/Style"] = "Custom",
            ["Style/Static desync"] = 58,
            ["Style/Static side"] = "Invert key",
            ["Style/Swap every"] = 10,
            ["Style/Swap jitter"] = 50,
            ["Style/Keep fake lag in No AA"] = false,
            ["Flick/Flick"] = false,
        } },
        -- Rage presets: aim settings only (a config sets just the keys it lists), so they layer over any AA preset.
        -- Each lists every rage key, so switching between them never leaves one behind. Hitchance 0 = cheat menu value.
        -- Data 2026-11-21: when the ragebot can shoot it fires in 2-4 ticks at any speed, so hitchance mostly decides
        -- WHICH shots go out, not how fast; the "never fired" episodes were glimpses, not waits.
        { name = "Rage: menu values", builtin = true, data = {
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Hitchance moving"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Peek & extras/Baim after misses"] = 0,
            ["No spread/No-spread mode"] = false,
            ["DT peek/DT peek"] = false,
            ["Resolver/Mode"] = "Off",
        } },
        -- spread servers, Scout: no hard 2-8 dmg wallbangs, finish low targets, careful only where Scout is bad
        { name = "Rage: Scout balanced", builtin = true, data = {
            ["Rage/Hitchance in air"] = 50,
            ["Rage/Hitchance unscoped"] = 60,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Hitchance moving"] = 0,
            ["Rage/Min damage (0 menu)"] = 20,
            ["Rage/Lethal min damage"] = true,
            ["Peek & extras/Baim after misses"] = 2,
            ["No spread/No-spread mode"] = false,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Take over after"] = 1,
            ["Resolver/Candidates"] = true,
        } },
        -- shoot first: low hitchance in every state, any damage that kills, body after one miss
        { name = "Rage: aggressive", builtin = true, data = {
            ["Rage/Hitchance in air"] = 20,
            ["Rage/Hitchance unscoped"] = 25,
            ["Rage/Hitchance vs crouched"] = 15,
            ["Rage/Hitchance moving"] = 15,
            ["Rage/Min damage (0 menu)"] = 10,
            ["Rage/Lethal min damage"] = true,
            ["Peek & extras/Baim after misses"] = 1,
            ["No spread/No-spread mode"] = false,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 25,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Take over after"] = 1,
            ["Resolver/Candidates"] = true,
        } },
        -- fewer, surer shots: high hitchance off the ground / unscoped / moving, only real damage, head first
        { name = "Rage: accurate", builtin = true, data = {
            ["Rage/Hitchance in air"] = 80,
            ["Rage/Hitchance unscoped"] = 85,
            ["Rage/Hitchance vs crouched"] = 70,
            ["Rage/Hitchance moving"] = 65,
            ["Rage/Min damage (0 menu)"] = 50,
            ["Rage/Lethal min damage"] = true,
            ["Peek & extras/Baim after misses"] = 3,
            ["No spread/No-spread mode"] = false,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 50,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Take over after"] = 1,
            ["Resolver/Candidates"] = true,
        } },
        -- body when unsure: any miss goes to the body, damage floor so body shots still matter
        { name = "Rage: safe body", builtin = true, data = {
            ["Rage/Hitchance in air"] = 60,
            ["Rage/Hitchance unscoped"] = 60,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Hitchance moving"] = 40,
            ["Rage/Min damage (0 menu)"] = 35,
            ["Rage/Lethal min damage"] = true,
            ["Peek & extras/Baim after misses"] = 1,
            ["No spread/No-spread mode"] = false,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 40,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Take over after"] = 1,
            ["Resolver/Candidates"] = true,
        } },
        -- no-spread servers: every bullet lands where aimed, so lethal damage (half hp with a DT weapon), hitchance 1
        { name = "Rage: no spread", builtin = true, data = {
            ["Rage/Hitchance in air"] = 0,
            ["Rage/Hitchance unscoped"] = 0,
            ["Rage/Hitchance vs crouched"] = 0,
            ["Rage/Hitchance moving"] = 0,
            ["Rage/Min damage (0 menu)"] = 0,
            ["Rage/Lethal min damage"] = false,
            ["Peek & extras/Baim after misses"] = 0,
            ["No spread/No-spread mode"] = true,
            ["No spread/Hitchance"] = 1,
            ["No spread/Min damage (0 = lethal)"] = 0,
            ["No spread/Half hp with DT weapon"] = true,
            ["No spread/No baim after misses"] = true,
            ["DT peek/DT peek"] = true,
            ["DT peek/Damage (0 = half hp)"] = 0,
            ["DT peek/Hitchance"] = 35,
            ["Resolver/Mode"] = "Active",
            ["Resolver/Take over after"] = 1,
            ["Resolver/Candidates"] = true,
        } },
    }
    for _, c in ipairs(cfg.builtin) do cfg.list[#cfg.list + 1] = c end
    local g_list = group(c_cfg[1], "Cloud configs")
    local rows = {}
    -- room for every built-in + 12 official + 20 own configs (hidden rows take no space; the page scrolls)
    for i = 1, #cfg.builtin + 32 do
        local r = row(g_list, 32, true)
        r.Visible = false
        local n = label(r, "", C.txt, LEFT, 12, FM); n.Position = UDim2.new(0, 12, 0, 0); n.Size = UDim2.new(1, -100, 1, 0)
        local d = label(r, "", C.mut, RIGHT, 11); d.Position = UDim2.new(1, -92, 0, 0); d.Size = UDim2.new(0, 80, 1, 0)
        rows[i] = { r = r, n = n, d = d }
        on(r, p_cfg, function()
            local c = cfg.list[i]
            if c then cfg.sel, cfg.sel_off, cfg.sel_bi = c.name, c.official == true, c.builtin == true; cfg.name_h:set(c.name) end
        end)
    end
    local empty = line(g_list)
    local g_act = group(c_cfg[2], "Config")
    local name_v = var("")
    cfg.name_h = name_v
    local name_tb = ctl_text(p_cfg, g_act, { name = "Name", h = name_v, ph = "config name" })
    local c_status = line(g_act)
    local c_code = info(g_act, "Share code")
    local function cstat(text, col) c_status.Text = text; c_status.TextColor3 = col or C.mut end
    local function draw_list()
        for i, rw in ipairs(rows) do
            local c = cfg.list[i]
            rw.r.Visible = c ~= nil
            if c then
                local on = c.name == cfg.sel and (c.official == true) == (cfg.sel_off == true) and (c.builtin == true) == (cfg.sel_bi == true)
                rw.n.Text = c.name
                rw.n.TextColor3 = on and C.acc or C.txt
                rw.r.BackgroundColor3 = on and C.card_hi or C.card
                rw.d.Text = c.builtin and "built-in" or (c.official and "official" or os.date("%d/%m %H:%M", c.ts))
                rw.d.TextColor3 = (c.official or c.builtin) and C.acc or C.mut
            end
        end
        empty.Text = (#cfg.list <= #cfg.builtin) and (cfg.loaded and "nothing saved yet" or "press refresh") or ""
        local cur = nil
        for _, c in ipairs(cfg.list) do if c.name == cfg.sel and not c.official and not c.builtin then cur = c end end
        c_code.Text = cur and tostring(cur.code or "-") or "-"
    end
    track(p_cfg, draw_list)
    local function job(fn)
        if cfg.busy then return end
        cfg.busy = true
        task.spawn(function()
            local ok, err = pcall(fn)
            if not ok then cstat(tostring(err), C.bad) end
            cfg.busy = false
            draw_list()
        end)
    end
    local function refresh_list()
        local code, out = api("GET", "/cloud")
        if code == 200 and type(out.configs) == "table" then
            -- built-in presets, then official configs (published from the admin panel), then your own.
            -- An official config with a built-in's name replaces it (the server copy is the one the admin edits);
            -- the built-in copy stays only for when the server cannot be reached.
            local list, off = {}, {}
            for _, c in ipairs(type(out.official) == "table" and out.official or {}) do
                if type(c) == "table" and type(c.name) == "string" then off[c.name] = true end
            end
            for _, c in ipairs(cfg.builtin) do
                if not off[c.name] then list[#list + 1] = c end
            end
            for _, c in ipairs(type(out.official) == "table" and out.official or {}) do
                c.official = true
                list[#list + 1] = c
            end
            for _, c in ipairs(out.configs) do list[#list + 1] = c end
            cfg.list, cfg.loaded = list, true
            cstat(string.format("%d of %d slots used", #out.configs, tonumber(out.max) or 20))
        else
            cstat(tostring(out.error or code), C.bad)
        end
    end
    local function cfg_name()
        local n = name_v:get()
        n = type(n) == "string" and string.gsub(n, "^%s+", "") or ""
        n = string.gsub(n, "%s+$", "")
        return n ~= "" and n or cfg.sel
    end
    local cfg_btn = {}
    cfg_btn.save = ctl_button(p_cfg, g_act, { name = "Save", cb = function()
        local n = cfg_name()
        if not n then cstat("type a name first", C.warn) return end
        job(function()
            local data, cnt = cfg_dump()
            cstat("saving…")
            local code, out = api("POST", "/cloud", { op = "save", name = n, data = data })
            if code == 200 then
                cfg.sel, cfg.sel_off, cfg.sel_bi = n, false, false
                refresh_list()
                cstat(string.format("saved %s (%d settings)", n, cnt), C.acc)
            else
                cstat(tostring(out.error or code), C.bad)
            end
        end)
    end })
    ctl_button(p_cfg, g_act, { name = "Load", cb = function()
        local n = cfg_name()
        if not n then cstat("pick a config", C.warn) return end
        if cfg.sel_bi and n == cfg.sel then
            for _, c in ipairs(cfg.builtin) do
                if c.name == n then
                    local ok, bad = cfg_apply(c.data)
                    cstat(string.format("loaded %s (%d set%s)", n, ok, bad > 0 and (", " .. bad .. " skipped") or ""), C.acc)
                    say(120, 255, 160, "config loaded: " .. n)
                end
            end
            return
        end
        job(function()
            local off = cfg.sel_off and n == cfg.sel
            local code, out = api("GET", (off and "/cloud?preset=" or "/cloud?name=") .. urlq(n))
            if code == 200 and type(out.data) == "table" then
                local ok, bad = cfg_apply(out.data)
                cfg.sel = n
                cstat(string.format("loaded %s (%d set%s)", n, ok, bad > 0 and (", " .. bad .. " skipped") or ""), C.acc)
                say(120, 255, 160, "config loaded: " .. n)
            else
                cstat(tostring(out.error or code), C.bad)
            end
        end)
    end })
    local del_t = nil
    del_t = ctl_button(p_cfg, g_act, { name = "Delete", cb = function()
        local n = cfg.sel
        if not n then cstat("pick a config", C.warn) return end
        if cfg.sel_off or cfg.sel_bi then cstat("built-in and official configs can only be loaded", C.warn) return end
        if tick() - cfg.confirm > 3 then
            cfg.confirm = tick()
            cstat("press delete again to remove " .. n, C.warn)
            return
        end
        cfg.confirm = 0
        job(function()
            local code, out = api("POST", "/cloud", { op = "delete", name = n })
            if code == 200 then
                cfg.sel = nil; name_v:set("")
                refresh_list()
                cstat("deleted " .. n)
            else
                cstat(tostring(out.error or code), C.bad)
            end
        end)
    end })
    ctl_button(p_cfg, g_act, { name = "Refresh", cb = function() job(refresh_list) end })

    local g_imp = group(c_cfg[2], "Import")
    local code_v = var("")
    ctl_text(p_cfg, g_imp, { name = "Code", h = code_v, ph = "share code from a friend" })
    local i_status = line(g_imp)
    ctl_button(p_cfg, g_imp, { name = "Load code", cb = function()
        local c = string.upper(string.gsub(tostring(code_v:get() or ""), "%s", ""))
        if not string.find(c, "^[A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9]$") then
            i_status.Text = "codes are 6 letters/digits"; i_status.TextColor3 = C.warn
            return
        end
        job(function()
            local code, out = api("GET", "/cloud?code=" .. c)
            if code == 200 and type(out.data) == "table" then
                local ok = cfg_apply(out.data)
                i_status.Text = string.format("loaded %s by %s (%d set)", tostring(out.name), tostring(out.by), ok)
                i_status.TextColor3 = C.acc
                say(120, 255, 160, string.format("config loaded from code %s: %s by %s", c, tostring(out.name), tostring(out.by)))
            else
                i_status.Text = tostring(out.error or code); i_status.TextColor3 = C.bad
            end
        end)
    end })

    -- ---------- settings: account, menu, feed, logs ----------
    local p_set, c_set = add_page("Settings")
    local g_acc = group(c_set[1], "Account")
    local a_user, a_lic, a_exp, a_srv = info(g_acc, "User"), info(g_acc, "License"), info(g_acc, "Expires"), info(g_acc, "Server")
    local a_build = info(g_acc, "Build")
    track(p_set, function() a_build.Text = UNSYK_TAG .. "  " .. tostring(UNSYK_VERSION or "") end)
    local acct = { name = nil, days = nil, state = "checking" }
    local function check_me()
        local code, out = api("GET", "/me")
        if code == 200 then
            acct.name, acct.days, acct.state = out.name, out.days_left, "ok"
        elseif code == 401 then
            acct.state = "session rejected, reload the loader"
        elseif code == nil then
            acct.state = tostring(out.error or "offline")
        else
            acct.state = "error " .. tostring(code)
        end
    end
    track(p_set, function()
        local okp, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
        a_user.Text = okp and lp and lp.Name or "?"
        a_lic.Text = tostring(acct.name or "-")
        a_exp.Text = acct.name == "owner" and "never" or (acct.days and (tostring(acct.days) .. " days") or "never")
        a_srv.Text = acct.state
        a_srv.TextColor3 = acct.state == "ok" and C.acc or C.warn
    end)
    ctl_button(p_set, g_acc, { name = "Refresh", cb = function() task.spawn(check_me) end })
    ctl_button(p_set, g_acc, { name = "Log out", cb = function()
        if type(UNSYK_AUTH) == "table" and type(UNSYK_AUTH.logout) == "function" then
            UNSYK_AUTH.logout()
            acct.state = "logged out, reload the loader"
        else
            acct.state = "not using the loader"
        end
    end })

    local g_menu = group(c_set[1], "Menu")
    local KEYS = { "RightShift", "Insert", "End", "Home", "RightControl", "Delete" }
    local key_name = database.read("ui_key")
    if type(key_name) ~= "string" then key_name = "RightShift" end
    local acc_opts = {}
    for _, a in ipairs(ACCENTS) do acc_opts[#acc_opts + 1] = a[1] end
    ctl_combo(p_set, g_menu, { name = "Menu key", opts = KEYS, h = var(key_name, function(v) key_name = v; dbw("ui_key", v) end) })
    ctl_combo(p_set, g_menu, { name = "Accent", opts = acc_opts, h = var(acc_name, set_accent) })
    ctl_toggle(p_set, g_menu, { name = "Blur background", h = var(blur.on, function(v)
        blur.on = v == true
        dbw("ui_blur", blur.on and "1" or "0")
        blur_show(is_open)
    end) })
    ctl_toggle(p_set, g_menu, { name = "Tooltips", h = var(tip.on, function(v)
        tip.on = v == true
        dbw("ui_tips", tip.on and "1" or "0")
    end) })
    local m_cal = info(g_menu, "Mouse")
    track(p_set, function() m_cal.Text = cal_text() end)
    ctl_button(p_set, g_menu, { name = "Calibrate by hand", cb = function() start_cal() end })
    ctl_button(p_set, g_menu, { name = "Auto calibrate", cb = function() reset_cal() end })

    local g_log = group(c_set[2], "Logs")
    g_log.Visible = false   -- "Upload logs" sends to the feed server: hidden in game like the feed itself
    local l_status = line(g_log)
    local upl = { done = 0, busy = false }
    track(p_set, function()
        if not upl.busy then
            local fresh = 0
            for _, e in ipairs(fd_hits) do if e.n > upl.done then fresh = fresh + 1 end end
            l_status.Text = string.format("%d hit timelines, %d shots recorded, %d not uploaded", #fd_hits, sh_cnt.fire, fresh)
        end
    end)
    -- full local buffers (every hit with its whole tick timeline + shot/hit counters) -> the feed, 15 per request
    ctl_button(p_set, g_log, { name = "Upload logs", cb = function()
        if upl.busy then return end
        upl.busy = true
        task.spawn(function()
            local evs = {}
            local top = upl.done
            for _, e in ipairs(fd_hits) do
                if e.n > upl.done then
                    local rows_ = {}
                    for _, r in ipairs(e.rows or {}) do
                        rows_[#rows_ + 1] = { n = r.n, phase = r.phase, side = r.side, lim = r.lim, man = r.man, state = r.state,
                            real = r.real, fake = r.fake, choke = r.choke, spd = r.speed, shot = r.shot }
                    end
                    evs[#evs + 1] = { kind = "hit_full", hn = e.n, dmg = e.dmg, hp_before = e.hp_before, hp_after = e.hp_after,
                        ping = e.ping, tms = e.tms, flip_age = e.flip_age, settings = e.settings, rows = rows_, enemies = e.enemies,
                        ver = UNSYK_VERSION or "local" }
                    if e.n > top then top = e.n end
                end
            end
            evs[#evs + 1] = { kind = "shotlog", shots = { fire = sh_cnt.fire, hit = sh_cnt.hit, miss = sh_cnt.miss }, stats = fd_stats,
                kills = stats.kills, deaths = stats.deaths, ver = UNSYK_VERSION or "local" }
            local okp, lp = pcall(function() return game:GetService("Players").LocalPlayer end)
            local sent, failed = 0, nil
            for i = 1, #evs, 15 do
                local chunk = {}
                for j = i, math.min(i + 14, #evs) do chunk[#chunk + 1] = evs[j] end
                l_status.Text = string.format("uploading %d/%d…", i - 1, #evs)
                local code, out = api("POST", "/ingest", { session = "upload-" .. tostring(math.floor(tick())),
                    user = okp and lp and lp.Name or nil, uid = okp and lp and lp.UserId or nil, events = chunk })
                if code ~= 204 and code ~= 200 then failed = tostring(out.error or code) break end
                sent = sent + #chunk
            end
            if failed then
                l_status.Text = "upload failed: " .. failed; l_status.TextColor3 = C.bad
            else
                upl.done = top
                l_status.Text = string.format("uploaded %d events", sent); l_status.TextColor3 = C.acc
                say(120, 255, 160, string.format("logs uploaded (%d events)", sent))
            end
            task.wait(4)
            l_status.TextColor3 = C.mut
            upl.busy = false
        end)
    end })

    -- anything LAYOUT does not mention (a new section or item) lands on a Misc page instead of vanishing
    local misc, misc_c = nil, nil
    for _, s in ipairs(tab.sections) do
        if not HIDDEN[s.name] then
            local left = false
            for _, it in ipairs(s.items) do if not lay.shown[it] then left = true end end
            if left then
                if not misc then misc, misc_c = add_page("Misc") end
                lay.build(misc, misc_c, { { (s.side == "Right") and 2 or 1, s.name, { s.name } } })
            end
        end
    end

    -- ---------- open / close, key ----------
    local s_ui = tab.ui_sec   -- cheat-tab only section created at the top of the tab
    local scale = new("UIScale", { Scale = 1 }, win)
    local function set_open(v)
        -- a press already going when the window appears (the cheat's Load click, a key + click) is not a click
        -- in the window: input is ignored until the mouse is up and 0.25s have passed (see the click loop)
        if v and not is_open then cal.open_t, cal.hold = tick(), true end
        is_open = v
        st.win_open = v
        win.Visible = v
        modal.Modal = v
        pcall(input.set_cursor_unlocked, v)
        blur_show(v)
        if not v then close_pop() end
        if v then
            scale.Scale = 0.97
            pcall(function()
                game:GetService("TweenService"):Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                    { Scale = 1 }):Play()
            end)
            for _, rf in ipairs(refresh) do
                if rf.page == cur_page then pcall(rf.fn) end
            end
        end
    end
    s_ui:new_button("Open / close window", function() set_open(not is_open) end)
    s_ui:new_button("Calibrate mouse by hand", function() set_open(true); start_cal() end)

    local last_toggle = 0
    local function key_toggle(name)
        if name ~= key_name or tick() - last_toggle < 0.25 then return end
        if UIS:GetFocusedTextBox() ~= nil then return end
        last_toggle = tick()
        set_open(not is_open)
    end
    for _, kn in ipairs(KEYS) do
        pcall(input.on_key_press, kn, function() key_toggle(kn) end)
    end
    pcall(function()
        UIS.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.Keyboard then
                for _, kn in ipairs(KEYS) do
                    if inp.KeyCode == Enum.KeyCode[kn] then key_toggle(kn) end
                end
            end
        end)
    end)
    pcall(function()
        UIS.InputChanged:Connect(function(inp)
            if is_open and cur_page and inp.UserInputType == Enum.UserInputType.MouseWheel then
                close_pop()
                local cp = cur_page.CanvasPosition
                cur_page.CanvasPosition = Vector2.new(0, math.max(0, cp.Y - inp.Position.Z * 40))
            end
        end)
    end)

    -- ---------- click loop ----------
    local function lmb()
        local ok1, a1 = pcall(input.is_mouse_down, 1)
        if ok1 and a1 == true then return true end
        local ok2, a2 = pcall(function() return UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
        return ok2 and a2 == true
    end
    local function inside(o, mx, my)
        local ap, sz = o.AbsolutePosition, o.AbsoluteSize
        return mx >= ap.X and mx <= ap.X + sz.X and my >= ap.Y and my <= ap.Y + sz.Y
    end
    local function hit_at(mx, my)
        if pop then
            for _, it in ipairs(pop.items) do
                if inside(it.o, mx, my) then return it end
            end
        end
        for i = #hits, 1, -1 do
            local h = hits[i]
            if (h.p == nil or (h.p == cur_page and inside(h.p, mx, my))) and inside(h.o, mx, my) then return h end
        end
        return nil
    end

    -- click learning (see mouse section)
    local learn = { cand = nil, n = 0 }
    -- mx, my = the mapped point that hit nothing; d = a shift that would have hit exactly one control
    local function try_learn(mx, my)
        if cal.how == "manual" then return end
        local gi = math.abs(cal.ay)
        local found = nil
        for _, d in ipairs({ -36, -58, 36, 58, gi, -gi, -cal.ry }) do
            if d ~= 0 and inside(win, mx, my + d) and hit_at(mx, my + d) then
                if found and found ~= d then return end   -- ambiguous
                found = d
            end
        end
        if not found then return end
        if learn.cand == found then learn.n = learn.n + 1 else learn.cand, learn.n = found, 1 end
        if learn.n >= 3 then
            cal.ry = cal.ry + found
            save_cal("learned")
            learn.cand, learn.n = nil, 0
            say(120, 255, 160, "mouse offset learned from clicks: " .. cal_text())
        end
    end

    local KC = nil
    local function cap_poll()
        local it = kcap.it
        if not it then return end
        local function stop()
            kcap.it = nil
            if it.show then pcall(it.show) end
        end
        if not KC then
            KC = {}
            pcall(function()
                for _, e in ipairs(Enum.KeyCode:GetEnumItems()) do
                    if e.Name ~= "Unknown" then KC[#KC + 1] = e.Name end
                end
            end)
            KC[#KC + 1] = "MouseButton2"
            KC[#KC + 1] = "MouseButton3"
        end
        local hit = nil
        for _, n in ipairs(KC) do
            if tab.keydown(n) then hit = n; break end
        end
        if not kcap.armed then   -- wait until the click that opened it (and every key) is released
            if not hit and not lmb() then kcap.armed = true end
            return
        end
        if lmb() or tick() - kcap.t0 > 8 then stop(); return end   -- clicked elsewhere / gave up
        if not hit then return end
        if hit ~= "Escape" then
            local key = (hit == "Backspace" or hit == "Delete") and nil or hit
            it.h.key, it.key = key, key
            if it.id then dbw("kb:" .. it.id, key or "None") end
            say(120, 255, 160, string.format("%s bound to %s", it.name, key or "nothing"))
        end
        stop()
    end

    local was_down, pressed, drag, scroll = false, nil, nil, nil

    -- ---------- tooltips: hover a setting ~0.4s ----------
    tip.box = new("Frame", { Size = UDim2.new(0, 260, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.card_hi,
        BorderSizePixel = 0, ZIndex = 50, Visible = false }, win)
    corner(tip.box, 6); stroke(tip.box)
    new("UIPadding", { PaddingTop = UDim.new(0, 7), PaddingBottom = UDim.new(0, 7), PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10) }, tip.box)
    tip.lbl = label(tip.box, "", C.txt, LEFT, 12)
    tip.lbl.Size = UDim2.new(1, 0, 0, 0); tip.lbl.AutomaticSize = Enum.AutomaticSize.Y; tip.lbl.ZIndex = 51
    tip.lbl.TextWrapped = true; tip.lbl.TextTruncate = Enum.TextTruncate.None; tip.lbl.TextYAlignment = Enum.TextYAlignment.Top
    function tip.update(mx, my, down)
        local cur = nil
        if tip.on and not down and not pop and not kcap.it and not drag and cur_page and inside(cur_page, mx, my) then
            for _, t in ipairs(tip.list) do
                if t.p == cur_page and inside(t.o, mx, my) then cur = t; break end
            end
        end
        if cur ~= tip.cur then tip.cur, tip.t0 = cur, tick() end
        local show = cur ~= nil and tick() - tip.t0 > 0.4
        if show then
            tip.lbl.Text = cur.text
            local wp = win.AbsolutePosition
            local x, y = mx - wp.X + 16, my - wp.Y + 18
            if x + 260 > W - 8 then x = mx - wp.X - 268 end   -- right column: open to the left of the mouse
            tip.box.Position = UDim2.new(0, x, 0, y)
        end
        tip.box.Visible = show
    end

    client.set_event_callback("paint", function()
        if not is_open then was_down = false; kcap.it = nil; return end
        if cal.hold then
            if not lmb() and tick() - (cal.open_t or 0) > 0.25 then cal.hold = false end
            was_down = false
            return
        end
        pcall(cap_poll)
        if tick() - cal.at > 0.5 then cal.at = tick(); pcall(remeasure) end
        local mx, my = mouse()
        local down = lmb()
        if cal_mode then
            if down and not was_down then finish_cal() end
            was_down = down
            return
        end
        pcall(tip.update, mx, my, down)
        if down and not was_down then
            if focus_tb then
                local f = focus_tb
                focus_tb = nil
                pcall(function() f.tb:ReleaseFocus() end)
                pcall(f.commit)
            end
            local h = hit_at(mx, my)
            if pop and not (h and h.click and pop.items and (function()
                for _, it in ipairs(pop.items) do if it == h then return true end end
                return false
            end)()) then
                close_pop()
                if h and h.p ~= nil then h = nil end   -- the click that closes a dropdown does nothing else
            end
            if inside(win, mx, my) then
                pressed = h
                if h and h.down then pcall(h.down) end
                if not h then
                    pcall(try_learn, mx, my)
                    if inside(top, mx, my) then
                        drag = { mx = mx, my = my, x = win.Position.X.Offset, y = win.Position.Y.Offset }
                    elseif cur_page and inside(cur_page, mx, my) then
                        scroll = { my = my, y = cur_page.CanvasPosition.Y }
                    end
                else
                    learn.cand, learn.n = nil, 0
                end
            end
        elseif down then
            if drag then
                win.Position = UDim2.new(0, drag.x + mx - drag.mx, 0, drag.y + my - drag.my)
            elseif scroll then
                cur_page.CanvasPosition = Vector2.new(0, math.max(0, scroll.y - (my - scroll.my)))
            elseif drag_slider then
                pcall(drag_slider)
            end
        elseif was_down then
            if pressed and pressed.click and inside(pressed.o, mx, my) then pcall(pressed.click) end
            if drag then dbw("ui_pos", string.format("%d,%d", win.Position.X.Offset, win.Position.Y.Offset)) end
            pressed, drag, scroll, drag_slider = nil, nil, nil, nil
        end
        was_down = down
        if focus_tb and not focus_tb.tb:IsFocused() and not down then
            local f = focus_tb
            focus_tb = nil
            pcall(f.commit)
        end
    end)

    local start_tab = tonumber(database.read("ui_tab")) or 1
    if start_tab < 1 or start_tab > #pages then start_tab = 1 end
    open_tab(start_tab)
    set_open(true)
    -- no calibration prompt: auto now reads the GUI's real position (the inset that made clicks land a row off),
    -- click learning corrects what is left, and Settings > Menu > "Calibrate by hand" stays for odd setups.
    task.delay(1, function()
        pcall(remeasure)
        pcall(diag)
    end)
    task.spawn(function()
        task.wait(2)
        pcall(check_me)
        if acct.state == "ok" then pcall(refresh_list) end
        draw_list()
    end)

    -- ---------- sync loop: handles -> window, footer ----------
    local beat = 0
    task.spawn(function()
        while gui.Parent do
            task.wait(0.25)
            pcall(scan_deaths)
            if is_open then
                for _, rf in ipairs(refresh) do
                    if rf.page == cur_page then pcall(rf.fn) end
                end
                beat = beat + 1
                if beat % 2 == 0 then
                    pcall(function()
                        local feed_on = st.sv_live()
                        f_l.Text = string.format("%s%s", tostring(acct.name or "-"),
                            (acct.days and acct.name ~= "owner") and string.format(" · %dd", acct.days) or "")
                        if st.sv_owner then
                            f_r.Text = string.format("K %d  D %d  ·  %s%s", stats.kills, stats.deaths,
                                feed_on and (sv_failed == 0 and "feed ok" or ("feed " .. sv_failed .. " failed")) or "feed off",
                                (ctrl_v > 0) and ("  ·  cfg v" .. ctrl_v) or "")
                            f_r.TextColor3 = (feed_on and sv_failed == 0) and C.mut or C.warn
                        else
                            f_r.Text = string.format("K %d  D %d", stats.kills, stats.deaths)
                            f_r.TextColor3 = C.mut
                        end
                    end)
                end
            end
        end
    end)
    return #pages
end

local ok, res = pcall(ui_build)
if ok then
    client.color_log(120, 255, 160, "[unsyk] window ready (" .. tostring(res) .. " tabs)")
else
    client.color_log(255, 90, 90, "[MENU] window failed: " .. tostring(res))
end
end

client.color_log(120, 255, 160, "[unsyk] v5 loaded, build " .. UNSYK_TAG .. " version " .. tostring(UNSYK_VERSION or "local copy"))
