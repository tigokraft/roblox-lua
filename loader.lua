-- unsyk loader: load THIS in the cheat. It logs in with your license key, downloads the newest
-- unsyk.lua from the feed server and runs it. To update, just reload this loader.
-- First time: open the cheat menu tab "unsyk login", paste your key (DAA-XXXXX-...) into Key and press
-- "Log in" (a full key pasted into the box also logs in by itself). There is no login window.
-- The key is saved in the cheat's database and locks to the first Roblox account that uses it.
-- A key works on ONE device at a time: logging in elsewhere ends this session and the script stops itself.
-- After login a small card shows download -> compile -> start and retries the download. The last copy that
-- compiled is used only while the server cannot be reached at all, the session is still valid and the
-- subscription has not ended; a refused key (expired, revoked, other account) also deletes that copy.
local DEFAULT_BASE = "https://feed.sites.exxo.world"
local LOADER_VERSION = 8

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local function log(r, g, b, msg) pcall(client.color_log, r, g, b, "[loader] " .. msg) end
local function now() return os.time() end
local function dbw(k, v) pcall(function() database.write(k, v); database.flush() end) end

-- same palette, fonts and shapes as the script's window (ui_build in unsyk.lua), so the card looks like the menu
local C = {
    win = Color3.fromRGB(14, 14, 17), line = Color3.fromRGB(40, 40, 46), ctl = Color3.fromRGB(56, 56, 63),
    txt = Color3.fromRGB(176, 176, 184), hi = Color3.fromRGB(242, 242, 245), mut = Color3.fromRGB(104, 104, 112),
    acc = Color3.fromRGB(150, 200, 60), bad = Color3.fromRGB(225, 90, 90), warn = Color3.fromRGB(230, 180, 80),
}
do
    local saved = database.read("ui_acc")
    local A = { Lime = { 150, 200, 60 }, Blue = { 80, 150, 255 }, Pink = { 230, 95, 170 }, Purple = { 150, 115, 240 },
        Orange = { 240, 150, 60 }, Red = { 225, 70, 70 }, White = { 220, 220, 220 } }
    if type(saved) == "string" and A[saved] then C.acc = Color3.fromRGB(A[saved][1], A[saved][2], A[saved][3]) end
end
local F, FM, FB = Enum.Font.Gotham, Enum.Font.GothamMedium, Enum.Font.GothamBold

-- ---------- progress card (shown only once logged in; the login itself is in the cheat tab) ----------
local ui = { t = 0, done = false }
pcall(function()
    local function new(class, props, parent)
        local o = Instance.new(class)
        for k, v in pairs(props) do o[k] = v end
        if parent then o.Parent = parent end
        return o
    end
    local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
    local function label(parent, text, col, xa, size, font)
        return new("TextLabel", { BackgroundTransparency = 1, Text = text, TextColor3 = col, Font = font or F, TextSize = size or 13,
            TextXAlignment = xa or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, BorderSizePixel = 0 }, parent)
    end
    local gui = new("ScreenGui", { Name = "unsyk_loader", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 70 })
    pcall(function() gui.ScreenInsets = Enum.ScreenInsets.None end)
    gui.Parent = game:GetService("CoreGui")
    local W, H, TOP = 320, 124, 40
    local card = new("Frame", { Size = UDim2.new(0, W, 0, H), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2), BackgroundColor3 = C.win,
        BackgroundTransparency = 0.06, BorderSizePixel = 0, Visible = false }, gui)
    corner(card, 9)
    new("UIStroke", { Color = C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, card)
    local scale = new("UIScale", { Scale = 0.96 }, card)

    -- title bar: accent diamond + name on the left, current step on the right, hairline under it
    local mark = new("Frame", { Size = UDim2.new(0, 10, 0, 10), Position = UDim2.new(0, 18, 0, TOP / 2 - 5), Rotation = 45,
        BackgroundColor3 = C.acc, BorderSizePixel = 0 }, card)
    corner(mark, 2)
    local hole = new("Frame", { Size = UDim2.new(0, 4, 0, 4), Position = UDim2.new(0.5, -2, 0.5, -2), BackgroundColor3 = C.win,
        BorderSizePixel = 0 }, mark)
    corner(hole, 1)
    local name = label(card, "unsyk", C.hi, nil, 15, FB); name.Position = UDim2.new(0, 38, 0, 0); name.Size = UDim2.new(0, 120, 0, TOP)
    local step = label(card, "", C.mut, Enum.TextXAlignment.Right, 11, FM)
    step.Position = UDim2.new(1, -136, 0, 0); step.Size = UDim2.new(0, 120, 0, TOP)
    new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, TOP), BackgroundColor3 = C.line, BorderSizePixel = 0 }, card)

    local status = label(card, "starting…", C.txt, nil, 13, FM); status.Position = UDim2.new(0, 16, 0, TOP + 12)
    status.Size = UDim2.new(1, -32, 0, 18)
    -- progress: rounded track, accent pill sliding along it until done
    local track = new("Frame", { Size = UDim2.new(1, -32, 0, 4), Position = UDim2.new(0, 16, 0, TOP + 40), BackgroundColor3 = C.ctl,
        BorderSizePixel = 0, ClipsDescendants = true }, card)
    corner(track, 2)
    local fill = new("Frame", { Size = UDim2.new(0.3, 0, 1, 0), BackgroundColor3 = C.acc, BorderSizePixel = 0 }, track)
    corner(fill, 2)
    local status2 = label(card, "", C.mut, nil, 11); status2.Position = UDim2.new(0, 16, 1, -26); status2.Size = UDim2.new(1, -110, 0, 16)
    local foot = label(card, "loader v" .. LOADER_VERSION, C.mut, Enum.TextXAlignment.Right, 11)
    foot.Position = UDim2.new(1, -96, 1, -26); foot.Size = UDim2.new(0, 80, 0, 16)
    ui.gui, ui.card, ui.step, ui.status, ui.status2, ui.fill, ui.track, ui.scale = gui, card, step, status, status2, fill, track, scale
end)

local function show_card()
    pcall(function()
        if ui.card.Visible then return end
        ui.card.Visible = true
        game:GetService("TweenService"):Create(ui.scale, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Scale = 1 }):Play()
    end)
end

pcall(client.set_event_callback, "paint", function(dt)
    if not ui.fill or ui.done then return end
    ui.t = ui.t + (type(dt) == "number" and dt or 0.016)
    ui.fill.Size = UDim2.new(0.3, 0, 1, 0)
    ui.fill.BackgroundColor3 = C.acc
    ui.fill.Position = UDim2.new((ui.t * 0.9) % 1.3 - 0.3, 0, 0, 0)
end)

local STEPS = { login = "login", download = "download 2/4", compile = "compile 3/4", start = "start 4/4" }
local function status(step, text, col, sub)
    log(150, 200, 255, text)
    pcall(function()
        ui.step.Text = STEPS[step] or ""
        ui.status.Text = text
        ui.status.TextColor3 = col or C.txt
        ui.status2.Text = sub or ""
    end)
end

local function finish(ok, text, col, sub)
    ui.done = true
    if not ui.gui then return end
    show_card()
    pcall(function()
        ui.fill.Position = UDim2.new(0, 0, 0, 0)
        ui.fill.Size = UDim2.new(1, 0, 1, 0)
        ui.fill.BackgroundColor3 = col or (ok and C.acc or C.bad)
        ui.step.Text = ok and "done" or "failed"
        ui.status.Text = text
        ui.status.TextColor3 = ok and C.hi or C.bad
        ui.status2.Text = sub or ""
    end)
    task.delay(ok and 2.5 or 12, function()
        pcall(function()
            local ts = game:GetService("TweenService")
            local ti = TweenInfo.new(0.3)
            for _, d in ipairs(ui.card:GetDescendants()) do
                if d:IsA("TextLabel") then ts:Create(d, ti, { TextTransparency = 1 }):Play() end
                if d:IsA("Frame") then ts:Create(d, ti, { BackgroundTransparency = 1 }):Play() end
                if d:IsA("UIStroke") then ts:Create(d, ti, { Transparency = 1 }):Play() end
            end
            ts:Create(ui.card, ti, { BackgroundTransparency = 1 }):Play()
        end)
        task.wait(0.35)
        pcall(function() ui.gui:Destroy() end)
    end)
end

-- ---------- server + http ----------
local base = DEFAULT_BASE
do
    local ingest = database.read("sv_url")
    if type(ingest) == "string" and string.find(ingest, "^https?://.+/ingest$") then
        base = string.gsub(ingest, "/ingest$", "")
    end
end

local function request(method, url, headers, body)
    -- (status code or nil, body or error text)
    local ok, res = pcall(function()
        return HttpService:RequestAsync({ Url = url, Method = method, Headers = headers, Body = body })
    end)
    if ok and type(res) == "table" then return res.StatusCode, res.Body or "" end
    return nil, tostring(res)
end

-- ---------- license login ----------
local lp = Players.LocalPlayer
local auth = { session = nil, expires = 0, name = nil, days = nil, sub_end = 0 }

local function parse_cached()
    local c = database.read("aa_sess")
    if type(c) ~= "string" then return end
    -- "sess|exp|name|days|sub_end"; only current-format (s2) sessions, older ones log in again
    local s, e, n, d, se = string.match(c, "^(s2%.[^|]+)|(%d+)|([^|]*)|?(%-?%d*)|?(%d*)$")
    if s and tonumber(e) and tonumber(e) - now() > 900 then
        auth.session, auth.expires, auth.name, auth.days = s, tonumber(e), n ~= "" and n or nil, tonumber(d)
        auth.sub_end = tonumber(se) or 0
        if auth.sub_end > 0 and now() > auth.sub_end then auth.session = nil end
    end
end

local function login(key)
    -- true, or false + reason + whether the key itself is bad. Saves the session (and the key, once it worked).
    key = string.upper(string.gsub(tostring(key or ""), "%s", ""))
    if not string.find(key, "^DAA%-") then return false, "that is not a key (DAA-XXXXX-...)", true end
    local body = HttpService:JSONEncode({ key = key, uid = lp and lp.UserId or 0, user = lp and lp.Name or "?" })
    local code, res = request("POST", base .. "/auth", { ["Content-Type"] = "application/json" }, body)
    if code == nil then return false, "cannot reach the server: " .. res, false end
    local okj, out = pcall(function() return HttpService:JSONDecode(res) end)
    out = okj and type(out) == "table" and out or {}
    if code ~= 200 or type(out.session) ~= "string" then
        if code == 403 then dbw("aa_cache", ""); dbw("aa_sess", "") end  -- refused key: no offline copy either
        return false, tostring(out.error or ("server said " .. code)), code == 403
    end
    auth.session, auth.expires, auth.name, auth.days = out.session, tonumber(out.expires) or now() + 3600, out.name, out.days_left
    auth.sub_end = tonumber(out.sub_end) or 0
    dbw("aa_key", key)
    dbw("aa_sess", auth.session .. "|" .. auth.expires .. "|" .. tostring(auth.name or "") .. "|" .. tostring(auth.days or "")
        .. "|" .. tostring(auth.sub_end))
    return true
end

-- the script calls this before every feed request: it gets a fresh session when the old one is close to expiry
local refreshing = false
UNSYK_AUTH = {
    headers = function()
        if auth.session and auth.expires - now() < 1800 and not refreshing then
            refreshing = true
            local k = database.read("aa_key")
            if type(k) == "string" then pcall(login, k) end
            refreshing = false
        end
        return auth.session and { ["X-Session"] = auth.session } or nil
    end,
    info = function() return { name = auth.name, expires = auth.expires, days = auth.days, sub_end = auth.sub_end } end,
    logout = function()
        auth.session, auth.expires = nil, 0
        dbw("aa_key", ""); dbw("aa_sess", ""); dbw("aa_cache", "")
        log(255, 200, 120, "logged out: the saved key was removed. Reload the loader to log in again.")
    end,
}

-- the only cheat tab: "unsyk login" (cheat-native widgets always take clicks and typing). The script adds
-- its window/calibration buttons to it through UNSYK_AUTH.tab.
-- Status: label handles may ignore :set(), so the label is created only once the login state is known, and a
-- change adds a fresh label and hides the old one.
local want_login, want_key, key_box, lsec, tab_status, tab_text = false, nil, nil, nil, nil, nil
local function tab_say(text)
    if not lsec or text == tab_text then return end
    tab_text = text
    local old = tab_status
    local okn, h = pcall(function() return lsec:new_label(text) end)
    if okn and h then
        tab_status = h
        if old then pcall(function() old:set_visible(false) end) end
    elseif old then
        pcall(function() old:set(text) end)
    end
end
local function build_tab()
    pcall(function()
        local tab = menu.new_tab("unsyk login", "rbxassetid://10734975692")
        UNSYK_AUTH.tab = tab
        lsec = tab:new_section("License", "Left")
        if not auth.session then
            key_box = lsec:new_textbox("Key", "DAA-XXXXX-XXXXX-XXXXX-XXXXX", "")
            lsec:new_button("Log in", function() want_key = key_box:get(); want_login = true end)
        end
        lsec:new_button("Log out", function() UNSYK_AUTH.logout(); tab_say("logged out, reload the loader") end)
    end)
end
local function who_text()
    return "logged in as " .. tostring(auth.name or "?") .. (auth.days and (", " .. auth.days .. " days left") or "")
end

local first_err = nil
parse_cached()
if auth.session then
    status("login", "logged in as " .. tostring(auth.name or "?"))
else
    local saved = database.read("aa_key")
    if type(saved) == "string" and #saved > 0 then
        status("login", "logging in…")
        local ok, why, bad = login(saved)
        if not ok then
            log(255, 90, 90, "login failed: " .. why)
            if bad then dbw("aa_key", "") end
            status("login", why, C.bad)
            first_err = why
        end
    end
end

build_tab()
if auth.session then tab_say(who_text()) end

if not auth.session then
    tab_say(first_err and ("saved key failed: " .. first_err) or "paste your key and press Log in")
    log(255, 200, 120, "not logged in: open the cheat menu tab \"unsyk login\", paste your key, press Log in")
    -- the tab's button sets want_login; a full key pasted into the box submits by itself (once per new value)
    local tried, started = nil, os.clock()
    while not auth.session do
        if not want_login and key_box then
            local okg, v = pcall(function() return key_box:get() end)
            local k = okg and type(v) == "string" and string.upper(string.gsub(v, "%s", "")) or ""
            if k ~= tried and string.find(k, "^DAA%-") and #k >= 29 then want_key, want_login = k, true end
        end
        if want_login then
            want_login = false
            tried = string.upper(string.gsub(tostring(want_key or ""), "%s", ""))
            tab_say("checking key…")
            log(150, 200, 255, "checking key…")
            local ok, why = login(want_key or "")
            if not ok then
                log(255, 90, 90, "login failed: " .. why)
                tab_say(why)
            end
        end
        if os.clock() - started > 600 then
            log(255, 90, 90, "no key entered for 10 minutes, reload the loader to try again")
            tab_say("timed out, reload the loader")
            return
        end
        task.wait(0.1)
    end
end
show_card()
local who = tostring(auth.name or "?")
tab_say(who_text())

-- ---------- download ----------
local src, why, unreachable = nil, nil, false
for attempt = 1, 3 do
    status("download", attempt == 1 and "downloading…" or ("retry " .. attempt .. "/3…"), nil, "logged in as " .. who)
    local code, res = request("GET", base .. "/script.lua", UNSYK_AUTH.headers() or {})
    if code == 200 and #res > 1000 and string.find(res, "UNSYK_VERSION", 1, true) then
        src = res
        break
    end
    if code == 401 then
        -- session revoked or expired on the server: one fresh login with the saved key, then retry
        auth.session = nil
        local k = database.read("aa_key")
        local ok, lwhy = false, "no saved key"
        if type(k) == "string" and #k > 0 then ok, lwhy = login(k) end
        why = ok and "session renewed" or ("not authorized: " .. tostring(lwhy))
        if not ok then dbw("aa_sess", "") break end
    elseif code == 403 or code == 429 then
        why = "server said " .. code .. ": " .. string.sub(res, 1, 60)
        unreachable = false
        log(255, 90, 90, "download refused: " .. why)
        break
    else
        why = code and ("server said " .. code .. ": " .. string.sub(res, 1, 60)) or res
        unreachable = code == nil or code >= 500
    end
    log(255, 90, 90, "download failed: " .. why)
    task.wait(attempt * 1.5)
end

-- ---------- compile (fresh download first, then the last copy that compiled) ----------
local fn, cerr, used = nil, nil, nil
if src then
    status("compile", "compiling " .. math.floor(#src / 1024) .. " KB…")
    fn, cerr = loadstring(src)
    if fn then
        used = "latest"
        dbw("aa_cache", src)
    else
        log(255, 90, 90, "compile error in the downloaded script: " .. tostring(cerr))
    end
end
-- the cached copy only while the server is down (or sent a build that does not compile): never after a refusal,
-- never past the session or the sub end
local sub_ok = (auth.sub_end or 0) == 0 or now() < auth.sub_end
if not fn and auth.session and (unreachable or src) and sub_ok and auth.expires > now() then
    local cached = database.read("aa_cache")
    if type(cached) == "string" and #cached > 1000 then
        status("compile", "using the cached copy…", C.warn)
        fn, cerr = loadstring(cached)
        if fn then used = "cache" end
    end
end
if not fn then
    local msg = tostring(cerr or why or "no download and no cache")
    log(255, 90, 90, "nothing to run: " .. msg)
    finish(false, msg, C.bad, "copy the [loader] lines from the Lua console")
    return
end

-- ---------- run ----------
status("start", "starting…")
local ok, rerr = pcall(fn)
if not ok then
    log(255, 90, 90, "script error while starting: " .. tostring(rerr))
    finish(false, "script error: " .. tostring(rerr), C.bad, "copy the [loader] lines from the Lua console")
    return
end
local ver = tostring(UNSYK_VERSION or "?")
local days = auth.days and (" · " .. auth.days .. "d left") or ""
if used == "cache" then
    finish(true, "running cached " .. ver, C.warn, "download failed: " .. tostring(why or cerr))
else
    finish(true, "welcome, " .. who .. days, C.acc, "build " .. ver)
end
log(120, 255, 160, "running " .. used .. " version " .. ver .. " as " .. who .. " (loader v" .. LOADER_VERSION .. ")")
