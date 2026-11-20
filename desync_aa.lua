-- penablox | Desync AA Suite v2
-- Per-state AA (standing/moving/air/crouch), randomized desync limits, delayed/random inverter,
-- burst defensive (shift ticks + max-fakelag + 84° desync flip + unchoke), level pitch when target is above.

local tab    = menu.new_tab("Desync AA", "rbxassetid://10734975692")
local s_main = tab:new_section("Anti-Aim", "Left")
local s_ds   = tab:new_section("Desync", "Right")
local s_def  = tab:new_section("Defensive", "Left")
local s_man  = tab:new_section("Manual", "Right")

local MAXD = 84 -- docs say 86, but 84 is what working scripts cap at

local enabled   = s_main:new_toggle("Enable", true)
local pitch_sel = s_main:new_combobox("Pitch", { "Down", "Up", "Zero", "Flick" }, "Down")
local up_fix    = s_main:new_toggle("Level pitch when target above", true)
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
local lim_rnd   = s_ds:new_toggle("Randomize limit (60-100%)", true)
local ds_delay  = s_ds:new_slider("Delay (ticks)", 1, 32, 8, 0, "t")
local ds_dr     = s_ds:new_slider("Delay random +", 0, 16, 4, 0, "t")
local ds_inv    = s_ds:new_keybind("Invert (static)", "Toggle", "F")
local ds_fake   = s_ds:new_toggle("Show fake ghost", true)

local def_on    = s_def:new_toggle("Defensive burst", true)
local def_trig  = s_def:new_combobox("Trigger", { "interval", "after shot", "always" }, "interval")
local def_int   = s_def:new_slider("Interval", 100, 2000, 600, 0, "ms")
local def_dur   = s_def:new_slider("Burst length", 1, 14, 4, 0, "t")
local def_shift = s_def:new_slider("Shift ticks", 0, 14, 14, 0, "t")
local def_pitch = s_def:new_combobox("Burst pitch", { "Up", "Down", "Zero", "Jitter" }, "Up")
local def_yaw   = s_def:new_slider("Burst yaw", 0, 180, 140, 0, "°")
local def_flip  = s_def:new_toggle("Flip desync at 84°", true)
local def_lag   = s_def:new_toggle("Max fake lag in burst", true)
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
    if defensive(level) then
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
    if st.inv ~= prev_inv then st.flip_n = st.n end
    st.shot = false
end)

-- ONE persistent text object, updated in place (render.indicator per frame stacks forever)
local hud = Drawing.new("Text")
hud.Size = 14
hud.Font = Drawing.Fonts.Plex
hud.Outline = true
hud.Color = color(240, 60, 70)
hud.Position = vector(20, 500)
hud.Visible = false

-- Angle arrows (world-space, drawn from your feet) ---------------------
local s_arr    = tab:new_section("Arrows", "Left")
local arr_on   = s_arr:new_toggle("Show angle arrows", true)
local arr_view = s_arr:new_toggle("Show view arrow (calibration)", true)
local arr_len  = s_arr:new_slider("Arrow length", 2, 12, 5, 0, " studs")
local arr_flip = s_arr:new_toggle("Invert direction (if arrows are mirrored)", false)
local arr_off  = s_arr:new_slider("Rotation offset", -180, 180, 180, 0, "°")

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
    if not enabled:get() then
        hud.Visible = false
        hide_arrow(A_REAL); hide_arrow(A_FAKE); hide_arrow(A_VIEW)
        return
    end

    local okr, real = pcall(aa.get_lby_deg)
    local okf, fake = pcall(aa.get_fake_lby_deg)
    local delta = (okr and okf) and math.abs(wrap(fake - real)) or 0
    local okc, chk = pcall(aa.get_choked_ticks)
    local dts = dt_state()
    hud.Text = string.format("DESYNC %s | %s | delta %d | choke %s | DT %s [%s]%s", st.inv and "R" or "L", my_state(), delta,
        okc and tostring(chk) or "?", dts.text, dts.src, st.left > 0 and " | DEF" or "")
    hud.Visible = true

    if not arr_on:get() then
        hide_arrow(A_REAL); hide_arrow(A_FAKE); hide_arrow(A_VIEW)
        return
    end

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
    hud.Visible = false
    pcall(function() hud:Destroy() end)
    for _, a in ipairs({ A_REAL, A_FAKE, A_VIEW }) do
        for _, o in pairs(a) do pcall(function() o:Destroy() end) end
    end
end)

-- ======================================================================
-- DEBUG: log every hit you take + what your AA was doing + likely shooter
-- (no incoming-shot event exists, so this watches your health each tick)
-- ======================================================================
local s_dbg   = tab:new_section("Debug", "Right")
local dbg_on  = s_dbg:new_toggle("Log hits taken", true)
local dbg_con = s_dbg:new_toggle("Print to console (old one-liners)", false)
local dbg_scr = s_dbg:new_toggle("Show last hits on screen", true)

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
    out[#out + 1] = "=== desync_aa debug report ==="
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

s_dbg:new_button("Dump report to console", function()
    -- one log line per entry, into the cheat's Lua console (select + Ctrl+C to copy)
    client.color_log(120, 200, 255, "[DBG] ----- BEGIN REPORT -----")
    for line in string.gmatch(dbg_report(), "[^\n]+") do client.log("[DBG] " .. line) end
    client.color_log(120, 200, 255, "[DBG] ----- END REPORT -----")
end)
s_dbg:new_button("Clear debug log", function()
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
local in_on    = s_in:new_toggle("Track nearest enemies", true)
local in_cnt   = s_in:new_slider("Players tracked", 1, 4, 2, 0, "")
local in_panel = s_in:new_toggle("Show panel", true)

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

local function intel_update(rec, e, dist, pos, mypos)
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
    end

    if oka and yaw and pitch then
        rec.yaw_now, rec.pitch_now = yaw, pitch
        if rec.last_yaw then
            local dy = math.abs(wrap180(yaw - rec.last_yaw))
            rec.ema_dy = rec.ema_dy * 0.97 + dy * 0.03
            if dy > rec.max_dy then rec.max_dy = dy end
            if dy > 120 then
                rec.def_count = rec.def_count + 1
                rec.last_def = intel_n
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
                rec.last_flip = intel_n
            elseif side ~= rec.side then
                local interval = intel_n - rec.last_flip
                rec.ints[#rec.ints + 1] = interval
                if #rec.ints > 12 then table.remove(rec.ints, 1) end
                rec.flips = rec.flips + 1
                rec.last_flip = intel_n
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
local function intel_pattern(rec)
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

    local since = intel_n - rec.last_flip
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

s_in:new_button("Dump intel to console", function()
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
local pk_on    = s_pk:new_toggle("Show peek advisor", true)
local pk_view  = s_pk:new_toggle("Use view-angle check (unreliable vs AA)", false)
local pk_aim   = s_pk:new_slider("Safe if they look away more than", 5, 90, 25, 0, " deg")
local pk_def   = s_pk:new_slider("Wait after their defensive", 0, 128, 64, 0, "t")
local pk_extra = s_pk:new_slider("Extra safety margin", 0, 8, 2, 0, "t")

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

client.set_event_callback("paint", function()
    local rec = intel_order[1]
    if not (pk_on:get() and in_on:get() and rec) then
        pk_text.Visible = false
        return
    end
    local score, reasons = peek_eval(rec)
    local verdict, col
    if score >= 2 then verdict, col = "PEEK: GOOD", color(80, 255, 120)
    elseif score >= 0 then verdict, col = "PEEK: OK", color(255, 220, 80)
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

s_sh:new_button("Dump shot summary", function()
    local parts = {}
    for k, v in pairs(sh_reasons) do parts[#parts + 1] = k .. "=" .. v end
    client.color_log(120, 200, 255, string.format("[SHOT] fired=%d hit=%d miss=%d | miss reasons: %s",
        sh_cnt.fire, sh_cnt.hit, sh_cnt.miss, table.concat(parts, ", ")))
    for _, l in ipairs(sh_log) do client.log(l) end
end)
s_sh:new_button("Clear shot log", function()
    sh_log, sh_reasons, sh_cnt = {}, {}, { fire = 0, hit = 0, miss = 0 }
end)

-- ======================================================================
-- FINE DATA (v3): per-tick timeline before each hit, ping-aware, all nearby enemies,
-- crosstab stats and CSV dump. Replaces the one-line [DBG][hit] output.
-- ======================================================================
local s_fd     = tab:new_section("Fine data", "Left")
local fd_on    = s_fd:new_toggle("Log hits with timeline", true)
local fd_print = s_fd:new_toggle("Print one-line summary per hit", true)
local fd_tl    = s_fd:new_toggle("Print full timeline per hit (spammy)", false)
local fd_rows  = s_fd:new_slider("Timeline length", 8, 32, 16, 0, "t")
local fd_dumpn = s_fd:new_slider("Dump last N hits (full)", 1, 20, 3, 0, "")
local fd_csvn  = s_fd:new_slider("CSV last N hits", 1, 150, 30, 0, "")

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

s_fd:new_button("Dump stats (crosstab)", function()
    client.color_log(120, 200, 255, "[FD] ----- STATS (" .. fd_total .. " hits) -----")
    local keys = {}
    for k, _ in pairs(fd_stats) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do client.log(string.format("[FD] %-22s %d", k, fd_stats[k])) end
end)

s_fd:new_button("Dump last N hits (full timelines)", function()
    client.color_log(120, 200, 255, "[FD] ----- LAST " .. fd_dumpn:get() .. " HITS (of " .. #fd_hits .. ") -----")
    for i = math.max(1, #fd_hits - fd_dumpn:get() + 1), #fd_hits do
        fd_print_hit(fd_hits[i], function(line) client.log("[FD] " .. line) end)
    end
    client.color_log(120, 200, 255, "[FD] ----- END -----")
end)

s_fd:new_button("Dump CSV (one line per hit)", function()
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

s_fd:new_button("Clear fine data", function()
    fd_hits, fd_stats, fd_total = {}, {}, 0
    client.log("[FD] cleared")
end)

client.color_log(120, 255, 160, "[desync_aa] v3 loaded (fine data + intel + shot log)")

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
local dc_auto = s_dc:new_toggle("Auto-send each death", false)

local HttpService = game:GetService("HttpService")

local function dc_valid()
    local url = dc_url:get()
    return type(url) == "string" and string.find(url, "/api/webhooks/", 1, true) ~= nil
end

-- post one message (<= ~1900 chars), returns ok
local function dc_post_one(text)
    local body = HttpService:JSONEncode({ content = "```\n" .. text .. "\n```", username = "desync_aa" })
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
    lines[#lines + 1] = string.format("=== desync_aa summary (%d hits) ===", fd_total)
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

s_dc:new_button("Send summary + stats + intel", function() dc_send_lines(dc_summary_lines()) end)
s_dc:new_button("Send last N hits (CSV)", function() dc_send_lines(dc_csv_lines(dc_n:get())) end)
s_dc:new_button("Send last N hits (timelines)", function() dc_send_lines(dc_timeline_lines(dc_n:get())) end)

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
-- LIVE SERVER FEED: batches events and POSTs them to YOUR ingest endpoint (Caddy -> receiver.py)
-- URL + token live in the menu / script database, never in this file.
-- Events: hit, shot, intel (every 5s), state (every 5s)
-- ======================================================================
local s_sv   = tab:new_section("Live server feed", "Right")
local sv_url = s_sv:new_textbox("Ingest URL", "https://logs.example.com/ingest", database.read("sv_url") or "", function(v)
    pcall(function() database.write("sv_url", v); database.flush() end)
end)
local sv_tok = s_sv:new_textbox("Token", "paste ingest token", database.read("sv_tok") or "", function(v)
    pcall(function() database.write("sv_tok", v); database.flush() end)
end)
local sv_on  = s_sv:new_toggle("Stream events", false)

local sv_queue = {}
local sv_session = "s" .. tostring(math.floor(tick()))
local sv_next_snap = 0
local sv_backoff_until = 0
local sv_last_err = 0
local sv_sent, sv_failed = 0, 0

local function sv_push(ev)
    if not sv_on:get() then return end
    ev.t = ev.t or globals.realtime()
    sv_queue[#sv_queue + 1] = ev
    if #sv_queue > 300 then table.remove(sv_queue, 1) end
end

local function sv_err(msg)
    if globals.realtime() - sv_last_err > 20 then
        sv_last_err = globals.realtime()
        client.color_log(255, 90, 90, "[FEED] " .. msg)
    end
end

local function sv_flush()
    if #sv_queue == 0 then return end
    local url, tok = sv_url:get(), sv_tok:get()
    if type(url) ~= "string" or string.sub(url, 1, 8) ~= "https://" or type(tok) ~= "string" or #tok < 24 then
        sv_err("set a https:// ingest URL and the token first")
        return
    end
    local batch = sv_queue
    sv_queue = {}
    local ok, res = pcall(function()
        return HttpService:RequestAsync({
            Url = url, Method = "POST",
            Headers = { ["Content-Type"] = "application/json", ["X-Token"] = tok },
            Body = HttpService:JSONEncode({ session = sv_session, events = batch }),
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
    while true do
        task.wait(2)
        if sv_on:get() and globals.realtime() >= sv_backoff_until then pcall(sv_flush) end
    end
end)

-- hits taken (compact, with a short timeline)
local sv_last_hit = 0
events.on_tick(function()
    if not sv_on:get() then sv_last_hit = fd_total return end
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
client.set_event_callback("aim_fire", function(e)
    sv_push({ kind = "shot", result = "fire", hitbox = e and e.hitbox, target = e and tostring(e.target) })
end)
client.set_event_callback("aim_hit", function(e)
    local rec = find_rec(e and e.target)
    sv_push({ kind = "shot", result = "hit", hitbox = e and e.hitbox, dmg = e and e.damage, target = rec and rec.name })
end)
client.set_event_callback("aim_miss", function(e)
    local rec = find_rec(e and e.target)
    sv_push({ kind = "shot", result = "miss", reason = e and tostring(e.reason), hitbox = e and e.hitbox,
        target = rec and rec.name, intel = rec and rec_summary(rec) or nil })
end)

-- periodic snapshots: enemy intel + my state
events.on_tick(function()
    if not sv_on:get() then return end
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
    sv_push({ kind = "state", hp = okh and hp or nil, my_state = my_state(), phase = st.phase, side = st.inv and "R" or "L",
        lim = st.cur_lim, dt = dt_state().text, inv = ds_mode:get(), mod = yaw_mod:get(), pitch = pitch_sel:get(),
        feed = { sent = sv_sent, failed = sv_failed } })
end)

s_sv:new_button("Send test event", function()
    sv_queue[#sv_queue + 1] = { kind = "test", t = globals.realtime(), msg = "hello from desync_aa" }
    pcall(sv_flush)
    client.log(string.format("[FEED] test sent. total sent=%d failed=%d", sv_sent, sv_failed))
end)
