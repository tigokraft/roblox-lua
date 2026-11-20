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

-- SUBSCRIPTION GUARD (1/2). Every event callback goes through this wrapper, so UNSYK_STOP(why) can switch the
-- whole script off without an unload API: callbacks go quiet, then every "shutdown" handler runs (they destroy
-- the GUIs/drawings and reset aa/sounds), and rage overrides are released. A local shadow of `client` (not a write
-- to the cheat's table, which may be read-only). Part 2 (the /beat heartbeat) is near the end of the file.
local client = setmetatable({ _stop = {} }, { __index = client })
do
    local real = getmetatable(client).__index.set_event_callback
    client.set_event_callback = function(ev, fn)
        if ev == "shutdown" then
            client._stop[#client._stop + 1] = fn
            return real(ev, function(...) if UNSYK_STOPPED then return end return fn(...) end)
        end
        return real(ev, function(...) if UNSYK_STOPPED then return end return fn(...) end)
    end
    UNSYK_STOP = function(why)
        if UNSYK_STOPPED then return end
        UNSYK_STOPPED = tostring(why or "stopped")
        pcall(client.color_log, 255, 80, 80, "[unsyk] stopped: " .. UNSYK_STOPPED)
        pcall(client.notify, "unsyk stopped: " .. UNSYK_STOPPED)
        for _, fn in ipairs(client._stop) do pcall(fn) end
        pcall(aa.reset)
        for _, f in ipairs({ "override_hitchance", "override_min_damage", "override_force_baim" }) do
            pcall(rage[f], nil)
        end
    end
end

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
        local h = handle(false)
        local was = false
        function h:get()
            if mode == "Always" then return true end
            local down = key ~= nil and not typing() and keydown(key)
            if mode == "Hold" then was = down; return down end
            if down and not was then self.v = not self.v end
            was = down
            return self.v
        end
        return h
    end
    local function add(sec, item) sec.items[#sec.items + 1] = item; return item.h end
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
        return add(self, { kind = "key", name = name, h = keyhandle(mode, key), mode = mode, key = key })
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

local enabled   = s_main:new_toggle("Enable", true)
local pitch_sel = s_main:new_combobox("Pitch", { "Down", "Up", "Zero", "Flick" }, "Down")
local up_fix    = s_main:new_toggle("Level pitch vs high target", true)
local yaw_off   = s_main:new_slider("Yaw offset", -180, 180, 0, 0, "°")
local yaw_mod   = s_main:new_combobox("Yaw modifier", { "Disabled", "Center", "Sway", "Spin", "Random", "3-Way", "5-Way" }, "Center")
local mod_amt   = s_main:new_slider("Modifier amount", 0, 90, 30, 0, "°")
local lag_ticks = s_main:new_slider("Fake lag", 0, 14, 10, 0, "t")
local lag_var   = s_main:new_slider("Lag variability", 0, 100, 20, 0, "%")

local ds_mode   = s_ds:new_combobox("Inverter", { "Static", "Jitter", "Delayed", "Random", "On-shot flip" }, "Delayed")
local lim_stand = s_ds:new_slider("Limit standing", 0, MAXD, 84, 0, "°")
local lim_move  = s_ds:new_slider("Limit moving", 0, MAXD, 84, 0, "°")
local lim_air   = s_ds:new_slider("Limit in air", 0, MAXD, 84, 0, "°")
local lim_duck  = s_ds:new_slider("Limit crouching", 0, MAXD, 84, 0, "°")
local lim_rnd   = s_ds:new_toggle("Randomize limit", true)
local ds_delay  = s_ds:new_slider("Delay", 1, 32, 8, 0, "t")
local ds_dr     = s_ds:new_slider("Delay jitter", 0, 16, 4, 0, "t")
local ds_inv    = s_ds:new_keybind("Invert", "Toggle", "F")
local ds_fake   = s_ds:new_toggle("Fake chams", false)

local def_on    = s_def:new_toggle("Defensive burst", true)
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
local os_on    = s_os:new_toggle("On-shot AA", true)
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
            local ok, charged = true, dt_state().charged
            if sh > 0 and ok and charged then pcall(rage.shift_ticks, sh) end
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

local was_active = false
events.on_tick(function()
    if not enabled:get() then
        if was_active then pcall(aa.reset); was_active = false end
        return
    end
    was_active = true
    st.n = st.n + 1

    if up_fix:get() and aim_up() then st.up_until = os.clock() + 0.2 end
    local level = up_fix:get() and os.clock() < st.up_until

    -- regular sets the base state, then on-shot (highest priority) overrides parts of it
    local prev_inv = st.inv
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
    if onshot() then
        st.phase = st.phase .. "+onshot"
        if os_mode:get() ~= "Flip desync" then st.cur_lim = MAXD end
    end
    if st.hook then pcall(st.hook) end    -- peek AA (section "Peek & extras", further down)
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
local ch_on   = s_ch:new_toggle("Indicators", true)
local ch_gap  = s_ch:new_slider("Arrow gap", 20, 120, 45, 0, "px")
local ch_y    = s_ch:new_slider("Text offset", 10, 80, 24, 0, "px")
local ch_name = s_ch:new_toggle("Title", false)
local ch_dbg  = s_ch:new_toggle("Debug", false)
local ch_dr   = s_ch:new_slider("Dial radius", 20, 120, 34, 0, "px")
local ch_peek = s_ch:new_toggle("Peek advice", true)

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

client.set_event_callback("paint", function()
    local okl, alive = pcall(entity.is_alive, me())
    local okv, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if not ch_on:get() or not enabled:get() or not (okl and alive) or not okv or not vp then
        hide_all(ch); hide_all(dbg); hide_all(pb)
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
    elseif string.find(phase, "onshot", 1, true) then
        word, col = "ON-SHOT", COL.amb
    elseif phase == "defensive" then
        word, col = "DEFENSIVE", COL.cyan
    elseif phase == "dodge" then
        word, col = "DODGE", COL.cyan
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

events.on_tick(function()
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

local function intel_update(rec, e, dist, pos, mypos, now)
    now = now or intel_n
    local oka, pitch, yaw = pcall(entity.get_player_angles_deg, e)
    local oki, info = pcall(entity.get_info, e)
    local okn, anim = pcall(entity.get_anim_state, e)
    local okw, wep = pcall(entity.get_player_weapon_name, e)

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
    if rec.lby == nil then
        local okl, l = pcall(entity.get_player_lby_deg, e)
        if okl then rec.lby = tonumber(l) end
    end
    if rec.tw == nil then
        local okt, t = pcall(entity.get_player_twist_deg, e)
        if okt then rec.tw = tonumber(t) end
    end

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
            local ok, p = pcall(entity.get_player_position, e)
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
events.on_tick(intel_main)

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
events.on_tick(function()
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
            local ok, p = pcall(entity.get_player_position, e)
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
        settings = string.format("inv=%s mod=%s lag=%d lims=%d/%d/%d/%d def=%s os=%s",
            ds_mode:get(), yaw_mod:get(), lag_ticks:get(), lim_stand:get(), lim_move:get(), lim_air:get(), lim_duck:get(),
            tostring(def_on:get()), tostring(os_on:get())),
    }
    fd_hits[#fd_hits + 1] = e
    if #fd_hits > 150 then table.remove(fd_hits, 1) end

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

events.on_tick(function()
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
local s_dc    = tab:new_section("Discord export", "Right")
local dc_url  = s_dc:new_textbox("Webhook URL", "https://discord.com/api/webhooks/...", database.read("dc_webhook") or "", function(v)
    pcall(function()
        database.write("dc_webhook", v)
        database.flush()
    end)
end)
local dc_n    = s_dc:new_slider("Hits to send", 1, 30, 5, 0, "")
local dc_auto = s_dc:new_toggle("Auto-send deaths", false)

local HttpService = game:GetService("HttpService")

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
events.on_tick(function()
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
local rs_mode = s_rs:new_combobox("Mode", { "Off", "Shadow", "Active" }, "Shadow")
local rs_lead = s_rs:new_slider("Lead (-1 auto)", -1, 12, -1, 0, "t")
local rs_take = s_rs:new_slider("Take over after", 0, 5, 1, 0, "")
local rs_max  = s_rs:new_slider("Max offset", 20, MAXD, 58, 0, "°")

local rs = {}          -- [player name] = { ent, rec, st = {[state] = {inv, hit, miss}}, bmiss, omiss, own, applied, d }
local rs_shots = {}    -- FIFO of fired shots { id, name, t, r, d, own } (hit/miss events carry no id)
local rs_n = 0
local rs_was_active = false

local function rs_ping_ticks()
    local okl, lat = pcall(client.latency)
    local okt, ti = pcall(globals.tickinterval)
    if not okl or type(lat) ~= "number" then return 1 end
    ti = (okt and type(ti) == "number" and ti > 0) and ti or 0.015625
    return math.max(1, math.floor(lat / ti + 0.5) + 1)   -- latency (s) in ticks, +1 for the shot tick
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
    if base.raw < 15 then return nil end   -- barely desyncing: leave this player to the built-in resolver
    return base
end

local rs_err, rs_err_at = nil, -100
local function rs_tick()
    local mode = rs_mode:get()
    if mode == "Off" then
        if rs_was_active then
            pcall(plist.reset_all)
            for _, r in pairs(rs) do r.applied, r.own = false, false end
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
            local okq, pos = pcall(entity.get_player_position, e)
            if okq and pos then
                local okn, name = pcall(entity.get_player_name, e)
                local key = (okn and type(name) == "string") and name or tostring(e)
                local r = rs[key]
                if not r then
                    r = { rec = new_rec(key), st = {}, bmiss = 0, omiss = 0, own = false, applied = false }
                    rs[key] = r
                end
                if r.ent ~= e then
                    if r.applied then pcall(plist.reset, r.ent) end
                    r.ent, r.applied = e, false     -- respawned: same player, new entity
                end
                pcall(intel_update, r.rec, e, (pos - mypos).Magnitude, pos, mypos, rs_n)
                r.d = rs_decide(r, rs_n)
                if mode == "Active" then
                    if not r.own and (take == 0 or r.bmiss >= take) then r.own = true end
                else
                    r.own = false
                end
                if mode == "Active" and r.own and r.d then
                    pcall(plist.set, e, "Force body yaw", true)
                    pcall(plist.set, e, "Override yaw offset", r.d.off)
                    -- pitch fix: they flicked away from their usual pitch -> aim as if they had not
                    if r.d.pf then
                        pcall(plist.set, e, "Force pitch", true)
                        pcall(plist.set, e, "Force pitch value", r.d.pv)
                        r.pf = true
                    elseif r.pf then
                        pcall(plist.set, e, "Force pitch", false)
                        r.pf = false
                    end
                    -- fake duck: their head is not where the animation says -> safe points only
                    if r.d.safe then
                        pcall(plist.set, e, "Override safe point", "Force")
                        r.sf = true
                    elseif r.sf then
                        pcall(plist.set, e, "Override safe point", "-")
                        r.sf = false
                    end
                    r.applied = true
                    rs_was_active = true
                elseif r.applied then
                    pcall(plist.reset, e)
                    r.applied, r.pf, r.sf = false, false, false
                end
            end
        end
    end
end
events.on_tick(function()
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
    local r = rs_find(target)
    if not r then
        local n = 0
        for _ in pairs(rs) do n = n + 1 end
        return { m = rs_mode:get(), why = "nofind", tracked = n, ttype = typeof and typeof(target) or type(target),
            tval = tostring(target), err = rs_err }
    end
    if not r.d then
        return { m = rs_mode:get(), why = "noside", ticks = r.rec.ticks, des = math.floor(r.rec.des_now or 0),
            side = r.rec.side, st = r.rec.state, err = rs_err }
    end
    return { m = rs_mode:get(), own = r.applied, off = r.d.off, src = r.d.src, lead = r.d.lead, nxt = r.d.nxt,
        st = r.d.st, pat = r.d.pat, bmiss = r.bmiss, sc = r.d.sc, pf = r.d.pv, fd = r.d.safe or nil,
        aac = r.aa_changes }
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
        r = r, d = r and r.d, own = r and r.applied or false }
    if #rs_shots > 32 then table.remove(rs_shots, 1) end
end)

client.set_event_callback("aim_hit", function(e)
    if not e then return end
    local s = st.rs_match(e)
    if s and not s.r then s = nil end
    if s then s.r.rmiss = 0 end
    if not s or not s.own or not s.d then return end
    if s.d.ci and st.rsx then st.rsx.learn(s.r, s.d, 2, false); s.r.omiss = 0; return end
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
    if not s.own then
        r.bmiss = r.bmiss + 1          -- the built-in resolver missed this player
        return
    end
    r.omiss = r.omiss + 1
    if s.d and s.d.ci and st.rsx then
        st.rsx.learn(r, s.d, -3, true)    -- this angle missed: lower its score, block it for a few seconds
    elseif s.d then
        local stt = r.st[s.d.st] or { inv = false, hit = 0, miss = 0 }
        stt.miss = stt.miss + 1
        if stt.miss >= stt.hit + 2 then    -- this state keeps missing: try the inverse side
            stt.inv = not stt.inv
            stt.hit, stt.miss = 0, 0
        end
        r.st[s.d.st] = stt
    end
    if r.omiss >= ((s.d and s.d.ci) and 3 or 2) and rs_take:get() > 0 then   -- hand back to the built-in resolver
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
events.on_tick(function()
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
events.on_tick(function()
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
            local okq, pos = pcall(entity.get_player_position, e)
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
-- CANDIDATE RESOLVER (ideas from "phobia beta"; runs inside rs_decide when "Candidates" is on).
-- Builds up to 12 yaw offsets per enemy (relative to their eye yaw, what "Override yaw offset" takes):
--   read / inv (our desync side read, with flip prediction), lby, lby+-desync, lby+twist, mean (their
--   circular-mean yaw while they jitter), jit (opposite side of their current jitter), +-58, +-84.
-- Each has a prior; per enemy and per state (Stand/Run/Duck/Jumping) own hits add +2, own resolver misses
-- add -3 and block that offset (+-5 deg) for 4s. Scores decay x0.85 every 2s, and are wiped when the enemy's
-- AA signature (jitter / pitch bucket / desync) changes for 20+ ticks. Players that look legit (no jitter,
-- no desync read, lby close to eye yaw) are left alone. Also: "Fix pitch flicks" forces their usual pitch
-- when they flick away from it (>= 60% of the last 16 ticks in one bucket), "Safe point on fake duck"
-- forces safe points while they toggle crouch 3+ times in ~1.2s.
-- ======================================================================
do
local rs_multi = s_rs:new_toggle("Candidates", true)
local rs_pitch = s_rs:new_toggle("Fix pitch flicks", true)
local rs_fd    = s_rs:new_toggle("Safe point on fake duck", true)
st.ui.rs_multi, st.ui.rs_pitch, st.ui.rs_fd = rs_multi, rs_pitch, rs_fd

local NAMES = { "read", "inv", "lby", "lby+d", "lby-d", "twist", "mean", "jit", "+58", "-58", "+84", "-84" }
local PRIOR = { 3.0, 2.2, 2.6, 1.8, 1.8, 1.6, 1.2, 2.4, 1.0, 1.0, 0.8, 0.8 }

local function offv(v)
    if v == nil or v ~= v then return nil end
    v = wrap180(v)
    if math.abs(v) > 90 then return nil end   -- desync cannot be that far from the eye yaw: bad read
    return math.floor(v + 0.5)
end
local function pbucket(p) return p < -45 and 1 or (p > 45 and 3 or 2) end

local function scores(r, state)
    r.sc = r.sc or {}
    local s = r.sc[state]
    if not s then s = {}; r.sc[state] = s end
    return s
end

local X = {}
X.on = function() return rs_multi:get() == true end

X.pick = function(r, base, now)
    local rec = r.rec
    local yaw = rec.yaw_now
    if type(yaw) ~= "number" then return nil end
    local lby, dd, tw = rec.lby, rec.dd, rec.tw
    local hasd = dd ~= nil and math.abs(dd) >= 8

    -- AA signature: wipe what we learned when it changes for good
    local sig = (rec.yjit and "j" or "s") .. pbucket(rec.pitch_now or 0) .. (hasd and "d" or "n")
    if sig ~= r.sig then
        r.sig, r.sig_at = sig, now
    elseif r.sig_lock ~= sig and now - (r.sig_at or now) >= 20 then
        if r.sig_lock ~= nil then
            r.sc = {}
            r.aa_changes = (r.aa_changes or 0) + 1
        end
        r.sig_lock = sig
    end

    -- legit-looking: no jitter, no desync read, lby close to the eye yaw -> leave to the built-in resolver
    local lbyo = (lby ~= nil) and wrap180(lby - yaw) or nil
    if not rec.yjit and (base == nil or base.raw < 15) and (lbyo == nil or math.abs(lbyo) < 12)
        and (tw == nil or math.abs(tw) < 5) then
        r.ci = nil
        return nil
    end

    local c = {}
    if base then c[1] = base.off; c[2] = -base.off end
    if lby ~= nil then
        if math.abs(lbyo) >= 6 then c[3] = offv(lbyo) end
        if hasd then c[4] = offv(lby + dd - yaw); c[5] = offv(lby - dd - yaw) end
        if tw ~= nil and math.abs(tw) >= 5 then c[6] = offv(lby + tw - yaw) end
    end
    if rec.yjit and rec.yref then
        c[7] = offv(rec.yref - yaw)
        local e = wrap180(yaw - rec.yref)
        if math.abs(e) >= 5 then
            local m = hasd and math.min(math.abs(dd), MAXD) or 58
            c[8] = e > 0 and -m or m
        end
    end
    c[9], c[10], c[11], c[12] = 58, -58, MAXD, -MAXD

    local rt = globals.realtime()
    if rt - (r.sc_t or 0) >= 2 then
        r.sc_t = rt
        for _, s in pairs(r.sc or {}) do
            for k, v in pairs(s) do s[k] = v * 0.85 end
        end
    end
    local ss = scores(r, rec.state)
    local blk = r.blk or {}
    local best, bs = nil, -1e9
    for i = 1, #NAMES do
        local o = c[i]
        if o ~= nil then
            local s = PRIOR[i] + (ss[i] or 0)
            for _, b in ipairs(blk) do
                if b.e > rt and math.abs(wrap180(o - b.o)) < 5 then s = s - 12; break end
            end
            if i == r.ci then s = s + 0.3 end
            if s > bs then best, bs = i, s end
        end
    end
    if not best then return nil end
    r.ci = best
    local o = c[best]
    local d = { side = o >= 0 and 1 or -1, off = o, ci = best,
        src = NAMES[best] .. ((best <= 2 and base and base.src == "pred") and "/pred" or ""),
        lead = base and base.lead or nil, nxt = base and base.nxt or nil, st = rec.state,
        pat = base and base.pat or "?", sc = math.floor(bs * 10 + 0.5) / 10 }

    if rs_pitch:get() and rec.ph and #rec.ph >= 8 and type(rec.pitch_now) == "number" then
        local n, sum = { 0, 0, 0 }, { 0, 0, 0 }
        for _, p in ipairs(rec.ph) do
            local b = pbucket(p)
            n[b] = n[b] + 1
            sum[b] = sum[b] + p
        end
        local mj = 1
        if n[2] > n[mj] then mj = 2 end
        if n[3] > n[mj] then mj = 3 end
        if pbucket(rec.pitch_now) ~= mj and n[mj] * 10 >= #rec.ph * 6 then
            d.pf = true
            d.pv = math.floor(sum[mj] / n[mj] + 0.5)
        end
    end
    d.safe = rs_fd:get() and rec.fd_until ~= nil and now < rec.fd_until or false
    return d
end

X.learn = function(r, d, delta, block)
    if not r or not d or not d.ci then return end
    local ss = scores(r, d.st)
    ss[d.ci] = (ss[d.ci] or 0) + delta
    if block then
        local rt = globals.realtime()
        local blk = {}
        for _, b in ipairs(r.blk or {}) do
            if b.e > rt then blk[#blk + 1] = b end
        end
        blk[#blk + 1] = { o = d.off, e = rt + 4 }
        r.blk = blk
    end
end
st.rsx = X
end

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
st.ui.rg = { air = rg_air, ns = rg_ns, dk = rg_dk, md = rg_md, le = rg_le }

local R = { hc = nil, md = nil, hc_base = nil, md_base = nil }

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

events.on_tick(function()
    local air, ns, dk, mdv, le = rg_air:get(), rg_ns:get(), rg_dk:get(), rg_md:get(), rg_le:get()
    if air <= 0 and ns <= 0 and dk <= 0 and mdv <= 0 and not le then
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
    if air > 0 and my_state() == "air" then
        hc = air
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
-- HUD + EFFECTS (ideas from "phobia beta", rebuilt in the window's look: same palette, Gotham, rounded cards).
-- Panels live in one ScreenGui (unsyk_hud): watermark (top right), keybind list (left), target panel (right of the
-- crosshair), hit log toasts (top left), damage numbers (next to the crosshair). Sounds use the cheat's presets
-- (sounds.override_hitsound / killsound). Kill / hit effects are drawn in the world with render3d (immediate mode,
-- every paint); without render3d they are skipped. Accent follows the window (st.accent, set by ui_build).
-- ======================================================================
-- (own function, not a do-block: the main chunk is at the 200-local limit and do-block locals count too)
;(function()
local s_hud   = tab:new_section("HUD", "Right")
local hd_wm   = s_hud:new_toggle("Watermark", true)
local hd_keys = s_hud:new_toggle("Keybind list", true)
local hd_tgt  = s_hud:new_toggle("Target panel", false)
local hd_log  = s_hud:new_toggle("Hit log", true)
local hd_dmg  = s_hud:new_toggle("Damage numbers", true)
local s_fx    = tab:new_section("Effects", "Right")
local SND = { "Off", "skeet", "neverlose", "fatality", "bell", "bubble", "pop", "ding", "sparkle", "laser", "bip", "punch",
    "crack", "bite", "bonk", "arcade", "metallic", "zap", "click", "coin", "glass", "retro", "hit" }
local fx_kill = s_fx:new_combobox("Kill effect", { "Off", "Shockwave", "Ascend", "Pillar" }, "Shockwave")
local fx_hit  = s_fx:new_combobox("Hit effect", { "Off", "Ring", "Spark" }, "Off")
local fx_snd  = s_fx:new_combobox("Hit sound", SND, "Off")
local fx_ksnd = s_fx:new_combobox("Kill sound", SND, "Off")
local fx_vol  = s_fx:new_slider("Sound volume", 0, 100, 70, 0, "%")

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
        WM.rest.Text = string.format("·  %s  ·  %dms  ·  %dfps", short(who, 14), ms, fps)
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
    { "Peek AA", function() return st.peek_active == true end, "active" },
    { "Double tap", function() return dt_state().menu == true end, "on" },
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
    if ev.my == nil then
        local okw, w = pcall(sv_myweapon)
        if okw then ev.my = w end
    end
    sv_queue[#sv_queue + 1] = ev
    if #sv_queue > 300 then table.remove(sv_queue, 1) end
end

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
            Body = HttpService:JSONEncode({ session = sv_session, user = (function()
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

-- hits taken (compact, with a short timeline)
local sv_last_hit = 0
events.on_tick(function()
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
                    lim = math.floor(r.lim), man = r.man, choke = r.choke, spd = math.floor(r.speed or 0) }
            end
            local en = {}
            for _, x in ipairs(e.enemies) do
                en[#en + 1] = { name = x.name, wep = x.wep, dist = math.floor(x.dist), scoped = x.scoped, pat = x.pat, side = x.side, nxt = x.nxt }
            end
            sv_push({ kind = "hit", dmg = e.dmg, hp_before = e.hp_before, hp_after = e.hp_after, ping = math.floor(e.ping),
                flip_age = e.flip_age, dt = e.dt, settings = e.settings, timeline = tl, enemies = en })
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
        intel = rec and rec_summary(rec) or nil, rs = rs_info(e.target) })
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
events.on_tick(function()
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
            p_down = rec.p_down, p_up = rec.p_up, p_mid = rec.p_mid }
    end
    if #list > 0 then sv_push({ kind = "intel", players = list }) end

    local okh, hp = pcall(entity.get_player_health, me())
    local job, place = sv_server()
    if job and job ~= sv_last_job then
        sv_last_job = job
        sv_push({ kind = "server", job = job, place = place })
    end
    sv_push({ kind = "state", ver = UNSYK_VERSION or "local", job = job and string.sub(job, 1, 8) or nil, hp = okh and hp or nil, my_state = my_state(), phase = st.phase, side = st.inv and "R" or "L",
        lim = st.cur_lim, dt = dt_state().text, inv = ds_mode:get(), mod = yaw_mod:get(), pitch = pitch_sel:get(),
        remote = st.ctrl_live and st.ctrl_live() or false, feed = { sent = sv_sent, failed = sv_failed },
        peek = st.ui and st.ui.px_mode:get() or nil, anim = st.ui and st.ui.an_mode:get() or nil,
        baim = st.ui and st.ui.rx_baim:get() or nil })
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

events.on_tick(function()
    if not st.sv_live() then return end
    local now = os.clock()
    local okp, mypos = pcall(entity.get_player_position, me())
    local okl, alive = pcall(entity.is_alive, me())
    if not es_diag_done then
        local list = entity.get_enemies()
        if list[1] then pcall(es_diag, list[1]) end
    end
    for _, e in ipairs(entity.get_enemies()) do
        local okn, name = pcall(entity.get_player_name, e)
        if okn and type(name) == "string" then
            local okw, w = pcall(weapon.get_active, e)
            if okw and type(w) == "table" and type(w.ammo) == "number" then
                local prev = es_last[name]
                if prev and prev.wep == w.name and w.ammo < prev.ammo and not w.is_reloading
                    and okl and alive and okp and mypos then
                    local okq, pos = pcall(entity.get_player_position, e)
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
    rs_multi  = { h = st.ui.rs_multi, t = "b" },
    rs_pitch  = { h = st.ui.rs_pitch, t = "b" },
    rs_fd     = { h = st.ui.rs_fd,    t = "b" },
    hc_air    = { h = st.ui.rg.air, t = "n", lo = 0, hi = 100 },
    hc_noscope = { h = st.ui.rg.ns, t = "n", lo = 0, hi = 100 },
    hc_duck   = { h = st.ui.rg.dk,  t = "n", lo = 0, hi = 100 },
    mindmg    = { h = st.ui.rg.md,  t = "n", lo = 0, hi = 100 },
    lethal    = { h = st.ui.rg.le,  t = "b" },
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

task.spawn(function()
    while true do
        task.wait(5)
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
local upd_warned = nil
task.spawn(function()
    local BASE = "https://feed.sites.exxo.world"
    local last_ok, refused, sub_end = os.time(), 0, tonumber(UNSYK_SUB_END) or 0
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
            code, body = get("/beat")
            if code == 404 then
                -- proxy without the /beat route yet: /version answers only to a live session too (just no sub end)
                code, body = get("/version")
                if code == 200 then body = HttpService:JSONEncode({ v = body, sub_end = sub_end }) end
            end
        end
        if code == 200 then
            last_ok, refused = os.time(), 0
            local okj, b = pcall(function() return HttpService:JSONDecode(body or "") end)
            if okj and type(b) == "table" then
                sub_end = tonumber(b.sub_end) or 0
                local remote = b.v
                if type(remote) == "string" and #remote < 64 and remote ~= UNSYK_VERSION and remote ~= upd_warned then
                    upd_warned = remote
                    client.color_log(255, 200, 90, string.format("[UPDATE] new script version %s on the server (running %s). Reload the loader to update.",
                        remote, tostring(UNSYK_VERSION or "a local copy")))
                end
            end
        elseif code == 401 or code == 403 then
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
    -- Mouse position comes from UserInputService (screen pixels, top bar included). GUI AbsolutePosition is
    -- relative to where the ScreenGui starts, which is below the top bar if the cheat's GUI root keeps the inset.
    -- Auto: offset = -(screen height - gui height), i.e. the inset the GUI actually has. If clicks still miss,
    -- every click that hits nothing is tried again with the usual insets (0/36/58 px either way); when the same
    -- one would have hit a control three clicks running, it is adopted. Manual cross calibration overrides all.
    local cal = { x = 0, y = 0, how = "auto" }
    local function raw_mouse()
        local okm, m = pcall(function() return UIS:GetMouseLocation() end)
        if okm and m then return m.X, m.Y end
        local ok2, x, y = pcall(input.get_mouse_position)
        if ok2 and type(x) == "number" then return x, y end
        return -1, -1
    end
    local function auto_offset()
        local ok, dx, dy = pcall(function()
            local v = workspace.CurrentCamera.ViewportSize
            local g = gui.AbsoluteSize
            if g.Y < 10 then return 0, 0 end
            return -(v.X - g.X), -(v.Y - g.Y)
        end)
        if ok and type(dx) == "number" then return math.floor(dx + 0.5), math.floor(dy + 0.5) end
        return 0, 0
    end
    do
        local sv = database.read("ui_cal2")
        local a1, b1 = nil, nil
        if type(sv) == "string" then a1, b1 = string.match(sv, "^(%-?%d+),(%-?%d+),(%a+)$") end
        local how = type(sv) == "string" and string.match(sv, ",(%a+)$") or nil
        if a1 and (how == "manual" or how == "learned") then
            cal.x, cal.y, cal.how = tonumber(a1), tonumber(b1), how
        else
            cal.x, cal.y = auto_offset()
        end
    end
    local function mouse()
        local mx, my = raw_mouse()
        return mx + cal.x, my + cal.y
    end
    local function diag()
        local ux, uy = raw_mouse()
        local okc, cx, cy = pcall(input.get_mouse_position)
        local okg, gi = pcall(function() return game:GetService("GuiService"):GetGuiInset() end)
        local v = workspace.CurrentCamera.ViewportSize
        say(160, 200, 255, string.format("mouse %s offset %d,%d | uis %d,%d cheat %s | screen %dx%d gui %dx%d at %d,%d | inset %s",
            cal.how, cal.x, cal.y, ux, uy, okc and string.format("%d,%d", cx or -1, cy or -1) or "?", v.X, v.Y,
            gui.AbsoluteSize.X, gui.AbsoluteSize.Y, gui.AbsolutePosition.X, gui.AbsolutePosition.Y,
            okg and gi and string.format("%d,%d", gi.X, gi.Y) or "?"))
    end
    local function save_cal(how)
        cal.how = how
        dbw("ui_cal2", string.format("%d,%d,%s", cal.x, cal.y, how))
    end

    -- manual fallback: click the centre of a cross
    local calf = new("Frame", { Size = UDim2.new(1, 0, 1, -TOP - 1), Position = UDim2.new(0, 0, 0, TOP + 1), BackgroundColor3 = C.win,
        BorderSizePixel = 0, ZIndex = 40, Visible = false }, body)
    local calt = label(calf, "click the centre of the cross", C.txt, CENTER); calt.Size = UDim2.new(1, 0, 0, 20)
    calt.Position = UDim2.new(0, 0, 0.5, -60); calt.ZIndex = 41
    local calh = new("Frame", { Size = UDim2.new(0, 30, 0, 1), Position = UDim2.new(0.5, -15, 0.5, 0), BackgroundColor3 = C.acc,
        BorderSizePixel = 0, ZIndex = 41 }, calf)
    local calv = new("Frame", { Size = UDim2.new(0, 1, 0, 30), Position = UDim2.new(0.5, 0, 0.5, -15), BackgroundColor3 = C.acc,
        BorderSizePixel = 0, ZIndex = 41 }, calf)
    acc(function() calh.BackgroundColor3 = C.acc; calv.BackgroundColor3 = C.acc end)
    local cal_mode = false
    local function start_cal() cal_mode = true; calf.Visible = true end
    local function finish_cal()
        local rx, ry = raw_mouse()
        cal.x = math.floor(calv.AbsolutePosition.X - rx + 0.5)
        cal.y = math.floor(calh.AbsolutePosition.Y - ry + 0.5)
        save_cal("manual")
        cal_mode = false
        calf.Visible = false
        say(120, 255, 160, string.format("mouse calibrated by hand (offset %d,%d)", cal.x, cal.y))
    end
    local function reset_cal()
        cal.x, cal.y = auto_offset()
        cal.how = "auto"
        dbw("ui_cal2", "")
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

    local function ctl_key(p, parent, it)
        local r = row(parent, 34)
        name_label(r, it.name)
        local box = new("Frame", { Size = UDim2.new(0, 64, 0, 20), Position = UDim2.new(1, -76, 0.5, -10), BackgroundColor3 = C.field,
            BorderSizePixel = 0 }, r)
        corner(box, 4)
        local k = label(box, "", C.hi, CENTER, 11, FM); k.Size = UDim2.new(1, 0, 1, 0)
        local md = label(r, "", C.mut, RIGHT, 11); md.Position = UDim2.new(1, -150, 0, 0); md.Size = UDim2.new(0, 66, 1, 0)
        local function show()
            local active = hget(it.h) == true
            k.Text = it.key and tostring(it.key) or "None"
            k.TextColor3 = active and C.acc or C.hi
            md.Text = string.lower(tostring(it.mode or ""))
        end
        track(p, show)
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
            local ok, res = pcall(f, p, parent, it)
            if not ok then say(255, 90, 90, tostring(it.name) .. ": " .. tostring(res)) end
            return ok and res or nil
        end
    end
    local function find_sec(name)
        for _, s in ipairs(tab.sections) do
            if s.name == name then return s end
        end
        return nil
    end
    local placed = {}
    local function section(p, col, name, title)
        local s = find_sec(name)
        if not s then return nil end
        placed[s] = true
        local g = group(col, title or name)
        for _, it in ipairs(s.items) do control(p, g, it) end
        return g
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
    local p_aa, c_aa = add_page("Anti-aim")
    section(p_aa, c_aa[1], "Anti-Aim", "Anti-aim")
    section(p_aa, c_aa[1], "Manual")
    section(p_aa, c_aa[2], "Desync")

    local p_def, c_def = add_page("Defense")
    section(p_def, c_def[1], "Defensive")
    section(p_def, c_def[1], "Dodge", "Dodge AA")
    section(p_def, c_def[2], "On-shot")
    section(p_def, c_def[2], "Peek & extras", "Peek")

    local p_rs, c_rs = add_page("Resolver")
    section(p_rs, c_rs[1], "Resolver")
    section(p_rs, c_rs[2], "Rage")
    section(p_rs, c_rs[2], "Enemy intel", "Intel")

    local p_vis, c_vis = add_page("Visuals")
    section(p_vis, c_vis[1], "Crosshair")
    section(p_vis, c_vis[1], "Peek advisor")
    section(p_vis, c_vis[2], "HUD")
    section(p_vis, c_vis[2], "Effects")
    section(p_vis, c_vis[2], "Arrows", "World arrows")

    -- data: session stats + recorders
    local p_dat, c_dat = add_page("Data")
    local stats = { kills = 0, deaths = 0, seen = fd_total, last = {} }
    client.set_event_callback("aim_hit", function(e)
        if e and type(e.health_remaining) == "number" and e.health_remaining <= 0 then stats.kills = stats.kills + 1 end
    end)
    local g_ses = group(c_dat[1], "Session")
    local i_kd, i_hit = info(g_ses, "K / D"), info(g_ses, "Shots")
    local d_lines = {}
    for i = 1, 5 do d_lines[i] = line(g_ses) end
    section(p_dat, c_dat[1], "Shot log")
    section(p_dat, c_dat[2], "Fine data")
    section(p_dat, c_dat[2], "Debug", "Hits taken")
    placed[find_sec("Discord export") or {}] = true   -- the webhook proxy is rate limited for everyone; cheat tab only

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
    local SKIP_CFG = { ["Live server feed"] = true, ["Discord export"] = true }
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
    local g_list = group(c_cfg[1], "Cloud configs")
    local rows = {}
    for i = 1, 12 do
        local r = row(g_list, 32, true)
        r.Visible = false
        local n = label(r, "", C.txt, LEFT, 12, FM); n.Position = UDim2.new(0, 12, 0, 0); n.Size = UDim2.new(1, -100, 1, 0)
        local d = label(r, "", C.mut, RIGHT, 11); d.Position = UDim2.new(1, -92, 0, 0); d.Size = UDim2.new(0, 80, 1, 0)
        rows[i] = { r = r, n = n, d = d }
        on(r, p_cfg, function()
            local c = cfg.list[i]
            if c then cfg.sel, cfg.sel_off = c.name, c.official == true; cfg.name_h:set(c.name) end
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
                local on = c.name == cfg.sel and (c.official == true) == (cfg.sel_off == true)
                rw.n.Text = c.name
                rw.n.TextColor3 = on and C.acc or C.txt
                rw.r.BackgroundColor3 = on and C.card_hi or C.card
                rw.d.Text = c.official and "official" or os.date("%d/%m %H:%M", c.ts)
                rw.d.TextColor3 = c.official and C.acc or C.mut
            end
        end
        empty.Text = (#cfg.list == 0) and (cfg.loaded and "nothing saved yet" or "press refresh") or ""
        local cur = nil
        for _, c in ipairs(cfg.list) do if c.name == cfg.sel and not c.official then cur = c end end
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
            -- official configs (published from the admin panel) first, then your own
            local list = {}
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
                cfg.sel, cfg.sel_off = n, false
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
        if cfg.sel_off then cstat("official configs can only be loaded", C.warn) return end
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
    track(p_set, function() a_build.Text = tostring(UNSYK_VERSION or "local") end)
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
    local m_cal = info(g_menu, "Mouse")
    track(p_set, function() m_cal.Text = string.format("%s %d,%d", cal.how, cal.x, cal.y) end)
    ctl_button(p_set, g_menu, { name = "Calibrate by hand", cb = function() start_cal() end })
    ctl_button(p_set, g_menu, { name = "Auto calibrate", cb = function() reset_cal() end })

    placed[find_sec("Live server feed") or {}] = true   -- feed settings are hidden in game (database + remote only)
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

    -- anything not placed above (new sections) gets its own page
    local misc, misc_c = nil, nil
    for _, s in ipairs(tab.sections) do
        if not placed[s] then
            if not misc then misc, misc_c = add_page("Misc") end
            section(misc, misc_c[(s.side == "Right") and 2 or 1], s.name)
        end
    end

    -- ---------- open / close, key ----------
    local s_ui = tab.ui_sec   -- cheat-tab only section created at the top of the tab
    local scale = new("UIScale", { Scale = 1 }, win)
    local function set_open(v)
        is_open = v
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
    local function try_learn(rx, ry)
        if cal.how == "manual" then return end
        local _, ay = auto_offset()
        local found = nil
        for _, dy in ipairs({ 0, -36, -58, 36, 58, ay, -ay }) do
            if dy ~= cal.y and inside(win, rx + cal.x, ry + dy) and hit_at(rx + cal.x, ry + dy) then
                if found and found ~= dy then return end   -- ambiguous
                found = dy
            end
        end
        if not found then return end
        if learn.cand == found then learn.n = learn.n + 1 else learn.cand, learn.n = found, 1 end
        if learn.n >= 3 then
            cal.y = found
            save_cal("learned")
            learn.cand, learn.n = nil, 0
            say(120, 255, 160, string.format("mouse offset learned from clicks: %d,%d", cal.x, cal.y))
        end
    end

    local was_down, pressed, drag, scroll = false, nil, nil, nil
    client.set_event_callback("paint", function()
        if not is_open then was_down = false; return end
        local mx, my = mouse()
        local down = lmb()
        if cal_mode then
            if down and not was_down then finish_cal() end
            was_down = down
            return
        end
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
                    local rx, ry = raw_mouse()
                    pcall(try_learn, rx, ry)
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
    task.delay(1, function()
        if cal.how == "auto" then cal.x, cal.y = auto_offset() end
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

client.color_log(120, 255, 160, "[unsyk] v5 loaded, version " .. tostring(UNSYK_VERSION or "local copy"))
