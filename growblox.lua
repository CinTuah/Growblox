-- growblox.lua — single file untuk Delta mobile
-- Ubah REMOTES di [2] kalau nama remote Growblox berubah.

-- ============================================================
-- [1] SESSION
-- ============================================================
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer
if not LP then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LP = Players.LocalPlayer
end

local G = (getgenv and getgenv()) or _G
if G.__growblox and G.__growblox.cleanup then
    pcall(G.__growblox.cleanup)
end
local Session = { connections = {} }
G.__growblox = Session

local function alive() return G.__growblox == Session end

local function track(conn)
    table.insert(Session.connections, conn)
    return conn
end

local function safeGuiParent()
    local ok, hui = pcall(function() return gethui and gethui() end)
    if ok and hui then return hui, "gethui" end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg, "CoreGui" end
    local ok3, pg = pcall(function() return LP:WaitForChild("PlayerGui", 5) end)
    if ok3 and pg then return pg, "PlayerGui" end
    return nil, "none"
end

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

-- ============================================================
-- [2] CONFIG
-- ============================================================
local REMOTES = {
    setTile     = { service = "ReplicatedStorage", path = "Remotes.SetTile" },
    breakTile   = { service = "ReplicatedStorage", path = "Remotes.BreakTile" },
    plantSeed   = { service = "ReplicatedStorage", path = "Remotes.PlantSeed" },
    collect     = { service = "ReplicatedStorage", path = "Remotes.Collect" },
    changeWorld = { service = "ReplicatedStorage", path = "Remotes.ChangeWorld" },
    clearWorld  = { service = "ReplicatedStorage", path = "Remotes.ClearWorld" },
}

local INTERVALS = {
    place = 0.20, break = 0.22, afterBreak = 0.30, collect = 0.10, antiAfk = 60,
}

local COLORS = {
    bg     = Color3.fromRGB(24, 26, 30),
    accent = Color3.fromRGB(70, 180, 120),
    danger = Color3.fromRGB(200, 70, 70),
    text   = Color3.fromRGB(230, 230, 235),
    muted  = Color3.fromRGB(150, 150, 160),
    cell   = Color3.fromRGB(44, 46, 52),
    cellOn = Color3.fromRGB(60, 160, 100),
    cellMe = Color3.fromRGB(60, 110, 200),
}

-- ============================================================
-- [3] REMOTE
-- ============================================================
local function resolve(spec)
    local ok, svc = pcall(function() return game:GetService(spec.service) end)
    if not ok or not svc then return nil end
    local node = svc
    for part in string.gmatch(spec.path, "[^%.]+") do
        if not node then return nil end
        node = node:FindFirstChild(part)
    end
    return node
end

local RemoteCache = {}
local function getRemote(name)
    if RemoteCache[name] then return RemoteCache[name] end
    local spec = REMOTES[name]
    if not spec then return nil end
    local obj = resolve(spec)
    if obj then RemoteCache[name] = obj end
    return obj
end

local function fire(name, ...)
    local obj = getRemote(name)
    if not obj then return false, "remote tidak ditemukan: " .. name end
    local args = table.pack(...)
    for attempt = 1, 3 do
        local ok, err = pcall(function()
            obj:FireServer(table.unpack(args, 1, args.n))
        end)
        if ok then return true end
        if attempt == 3 then return false, tostring(err) end
        task.wait(0.1)
    end
    return false
end

local function checkRemotes()
    local total, ok, missing = 0, 0, {}
    for name in pairs(REMOTES) do
        total = total + 1
        if getRemote(name) then ok = ok + 1 else missing[#missing + 1] = name end
    end
    return ok, total, missing
end

-- ============================================================
-- [4] STATE
-- ============================================================
local State = {
    running = { autoFarm = false, autoClear = false, autoCollect = false, antiAfk = true },
    offsets = {},
    selectedBlock = nil,
    counters = { placed = 0, broken = 0, collected = 0 },
    lastAction = "-",
    startFarm = nil, stopFarm = nil,
    startClear = nil, stopClear = nil,
}

local function setFeature(name, value)
    if State.running[name] == nil then return end
    if value and not State.running[name] then
        State.running[name] = true
        if name == "autoFarm" and State.startFarm then State.startFarm() end
        if name == "autoClear" and State.startClear then State.startClear() end
    elseif not value and State.running[name] then
        State.running[name] = false
        if name == "autoFarm" and State.stopFarm then State.stopFarm() end
        if name == "autoClear" and State.stopClear then State.stopClear() end
    end
end

-- ============================================================
-- [5] INPUT
-- ============================================================
local function getChar()
    local c = LP.Character
    if not c then return nil end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then return nil end
    return hrp, hum
end

local function getPosition()
    local hrp = getChar()
    if not hrp then return nil end
    return hrp.Position.X, hrp.Position.Y
end

local function worldTile()
    local x, y = getPosition()
    if not x then return nil end
    return math.floor(x), math.floor(y - 2)
end

local function moveToX(targetX, tolerance)
    local hrp, hum = getChar()
    if not hrp then return end
    tolerance = tolerance or 0.3
    local dx = targetX - hrp.Position.X
    if math.abs(dx) <= tolerance then
        hum:Move(Vector3.zero, false)
        return true
    end
    local dir = dx > 0 and 1 or -1
    local dist = math.abs(dx)
    hum.WalkSpeed = math.min(24, math.max(8, dist * 6))
    hum:Move(Vector3.new(dir, 0, 0), false)
    return false
end

local function stopMove()
    local _, hum = getChar()
    if hum then hum:Move(Vector3.zero, false) end
end

local function isGrounded()
    local hrp = getChar()
    if not hrp then return false end
    local ray = Ray.new(hrp.Position, Vector3.new(0, -3, 0))
    local hit = workspace:FindPartOnRay(ray, LP.Character)
    return hit ~= nil
end

-- ============================================================
-- [6] ASTAR
-- ============================================================
local AStar = {}

local function key(dx, dy) return dx .. "," .. dy end

local function buildOccupancy(centerX, centerY, radius)
    local grid = {}
    for dy = -radius, radius do
        grid[dy] = {}
        for dx = -radius, radius do
            local wx, wy = centerX + dx, centerY + dy
            local ray = Ray.new(Vector3.new(wx, wy + 2, 0), Vector3.new(0, -6, 0))
            local hit = workspace:FindPartOnRay(ray, LP.Character)
            grid[dy][dx] = hit ~= nil
        end
    end
    return grid
end

function AStar.findPath(grid, sx, sy, tx, ty)
    local open = { { dx = sx, dy = sy, g = 0, f = math.abs(tx - sx) + math.abs(ty - sy), parent = nil } }
    local seen = { [key(sx, sy)] = 0 }
    local closed = {}
    while #open > 0 do
        table.sort(open, function(a, b) return a.f < b.f end)
        local cur = table.remove(open, 1)
        if cur.dx == tx and cur.dy == ty then
            local path, node = {}, cur
            while node do
                table.insert(path, 1, { dx = node.dx, dy = node.dy })
                node = node.parent
            end
            return path
        end
        closed[key(cur.dx, cur.dy)] = true
        for _, d in ipairs({ {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1} }) do
            local nx, ny = cur.dx + d[1], cur.dy + d[2]
            local cell = grid[ny] and grid[ny][nx]
            if cell == false and not closed[key(nx, ny)] then
                local g = cur.g + ((d[1] ~= 0 and d[2] ~= 0) and 1.4 or 1)
                if not seen[key(nx, ny)] or g < seen[key(nx, ny)] then
                    seen[key(nx, ny)] = g
                    table.insert(open, {
                        dx = nx, dy = ny, g = g,
                        f = g + math.abs(tx - nx) + math.abs(ty - ny),
                        parent = cur,
                    })
                end
            end
        end
    end
    return nil
end

-- ============================================================
-- [7] ACTIONS
-- ============================================================
local function placeTile(gx, gy, blockId)
    local ok = fire("setTile", "fg", gx, gy, blockId, false)
    if ok then
        State.counters.placed = State.counters.placed + 1
        State.lastAction = ("place %d (%d,%d)"):format(blockId, gx, gy)
    end
    return ok
end

local function breakTile(gx, gy)
    local ok = fire("breakTile", gx, gy)
    if ok then
        State.counters.broken = State.counters.broken + 1
        State.lastAction = ("break (%d,%d)"):format(gx, gy)
    end
    return ok
end

local function collectDrops()
    local ok = fire("collect")
    if ok then
        State.counters.collected = State.counters.collected + 1
        State.lastAction = "collect"
    end
    return ok
end

-- ============================================================
-- [8] FEATURES
-- ============================================================
local function sortedOffsets()
    local list = {}
    for k in pairs(State.offsets) do
        local dx, dy = string.match(k, "^(-?%d+),(-?%d+)$")
        if dx then table.insert(list, { dx = tonumber(dx), dy = tonumber(dy) }) end
    end
    table.sort(list, function(a, b)
        if a.dy ~= b.dy then return a.dy < b.dy end
        return a.dx < b.dx
    end)
    return list
end

local function farmLoop()
    while alive() and State.running.autoFarm do
        local px, py = worldTile()
        if not px then task.wait(0.5) continue end
        local block = State.selectedBlock
        if not block then
            State.lastAction = "block belum dipilih"
            task.wait(1)
            continue
        end
        local offsets = sortedOffsets()
        if #offsets == 0 then
            State.lastAction = "tile grid kosong"
            task.wait(1)
            continue
        end
        for _, o in ipairs(offsets) do
            if not alive() or not State.running.autoFarm then break end
            placeTile(px + o.dx, py + o.dy, block)
            task.wait(INTERVALS.place)
        end
        for _, o in ipairs(offsets) do
            if not alive() or not State.running.autoFarm then break end
            breakTile(px + o.dx, py + o.dy)
            task.wait(INTERVALS.break)
            task.wait(INTERVALS.afterBreak)
        end
        if State.running.autoCollect then
            pcall(collectDrops)
            task.wait(INTERVALS.collect)
        end
    end
end

State.startFarm = function()
    task.spawn(function()
        local ok, err = pcall(farmLoop)
        if not ok then warn("[growblox] farm error: " .. tostring(err)) end
    end)
end
State.stopFarm = function() stopMove() end

local function scanNearestBlock(radius)
    local px, py = worldTile()
    if not px then return nil end
    local grid = buildOccupancy(px, py, radius or 8)
    local best = nil
    for dy = -radius, radius do
        for dx = -radius, radius do
            if grid[dy] and grid[dy][dx] == true and not (dx == 0 and dy == 0) then
                local dist = math.sqrt(dx * dx + dy * dy)
                if not best or dist < best.dist then
                    best = { gx = px + dx, gy = py + dy, dist = dist }
                end
            end
        end
    end
    return best
end

local function clearLoop()
    local idle = 0
    while alive() and State.running.autoClear do
        local target = scanNearestBlock(8)
        if not target then
            idle = idle + 1
            if idle > 5 then
                State.lastAction = "clear selesai (tidak ada block)"
                setFeature("autoClear", false)
                break
            end
            task.wait(1)
            continue
        end
        idle = 0
        local hrp = getChar()
        if hrp then
            local reached = moveToX(target.gx + 0.5, 1.5)
            if reached then
                breakTile(target.gx, target.gy)
                task.wait(INTERVALS.break)
                task.wait(INTERVALS.afterBreak)
            else
                task.wait(0.1)
            end
        else
            task.wait(0.5)
        end
    end
    stopMove()
end

State.startClear = function()
    task.spawn(function()
        local ok, err = pcall(clearLoop)
        if not ok then warn("[growblox] clear error: " .. tostring(err)) end
    end)
end
State.stopClear = function() stopMove() end

local function collectLoop()
    while alive() do
        if State.running.autoCollect then pcall(collectDrops) end
        task.wait(INTERVALS.collect)
    end
end

local function antiAfkHook()
    track(LP.Idled:Connect(function()
        if alive() and State.running.antiAfk then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end
    end))
end

-- ============================================================
-- [9] GUI
-- ============================================================
local function buildGui()
    local parent, parentName = safeGuiParent()
    if not parent then
        warn("[growblox] tidak ada parent GUI yang bisa dipakai")
        return nil
    end
    warn("[growblox] GUI parent: " .. parentName)

    local old = parent:FindFirstChild("GrowbloxUI")
    if old then pcall(function() old:Destroy() end) end

    local screen = Instance.new("ScreenGui")
    screen.Name = "GrowbloxUI"
    screen.ResetOnSpawn = false
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.DisplayOrder = 100
    pcall(function() screen.Parent = parent end)
    if not screen.Parent then
        warn("[growblox] ScreenGui gagal di-parent ke " .. parentName)
        return nil
    end

    local win = Instance.new("Frame")
    win.Size = UDim2.fromOffset(520, 420)
    win.Position = UDim2.fromOffset(30, 80)
    win.BackgroundColor3 = COLORS.bg
    win.BorderSizePixel = 0
    win.Active = true
    win.Parent = screen
    Instance.new("UICorner", win).CornerRadius = UDim.new(0, 8)

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, 0, 0, 32)
    bar.BackgroundColor3 = COLORS.accent
    bar.BorderSizePixel = 0
    bar.Parent = win
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 8)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -16, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "Growblox"
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = bar

    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = win.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))

    local left = Instance.new("Frame")
    left.Size = UDim2.new(0, 220, 1, -48)
    left.Position = UDim2.fromOffset(8, 40)
    left.BackgroundTransparency = 1
    left.Parent = win

    local list = Instance.new("UIListLayout", left)
    list.Padding = UDim.new(0, 6)
    list.SortOrder = Enum.SortOrder.LayoutOrder

    local function addToggle(label, featureName, init)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 32)
        btn.BackgroundColor3 = init and COLORS.accent or COLORS.cell
        btn.BorderSizePixel = 0
        btn.Font = Enum.Font.Gotham
        btn.TextSize = 13
        btn.TextColor3 = COLORS.text
        btn.Text = label .. ": " .. (init and "ON" or "OFF")
        btn.Parent = left
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        btn.MouseButton1Click:Connect(function()
            local now = not State.running[featureName]
            setFeature(featureName, now)
            btn.Text = label .. ": " .. (now and "ON" or "OFF")
            btn.BackgroundColor3 = now and COLORS.accent or COLORS.cell
        end)
    end

    addToggle("Auto Farm", "autoFarm", State.running.autoFarm)
    addToggle("Auto Clear", "autoClear", State.running.autoClear)
    addToggle("Auto Collect", "autoCollect", State.running.autoCollect)
    addToggle("Anti AFK", "antiAfk", State.running.antiAfk)

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, 0, 0, 80)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextColor3 = COLORS.muted
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextYAlignment = Enum.TextYAlignment.Top
    status.TextWrapped = true
    status.Text = "-"
    status.Parent = left

    local gridHolder = Instance.new("Frame")
    gridHolder.Size = UDim2.fromOffset(264, 264)
    gridHolder.Position = UDim2.fromOffset(240, 40)
    gridHolder.BackgroundColor3 = COLORS.bg
    gridHolder.BorderSizePixel = 0
    gridHolder.Parent = win
    Instance.new("UICorner", gridHolder).CornerRadius = UDim.new(0, 6)

    local CELL, GAP, R = 48, 4, 2
    for row = 0, R * 2 do
        for col = 0, R * 2 do
            local dx, dy = col - R, row - R
            local k = dx .. "," .. dy
            local c = Instance.new("TextButton")
            c.Size = UDim2.fromOffset(CELL, CELL)
            c.Position = UDim2.fromOffset(col * (CELL + GAP) + 4, row * (CELL + GAP) + 4)
            c.BackgroundColor3 = (dx == 0 and dy == 0) and COLORS.cellMe or COLORS.cell
            c.Text = (dx == 0 and dy == 0) and "ME" or ""
            c.Font = Enum.Font.GothamBold
            c.TextSize = 12
            c.TextColor3 = Color3.new(1, 1, 1)
            c.BorderSizePixel = 0
            c.Parent = gridHolder
            Instance.new("UICorner", c).CornerRadius = UDim.new(0, 6)
            if not (dx == 0 and dy == 0) then
                c.MouseButton1Click:Connect(function()
                    if State.offsets[k] then
                        State.offsets[k] = nil
                        c.BackgroundColor3 = COLORS.cell
                    else
                        State.offsets[k] = true
                        c.BackgroundColor3 = COLORS.cellOn
                    end
                end)
            end
        end
    end

    local blockBox = Instance.new("TextBox")
    blockBox.Size = UDim2.new(1, 0, 0, 32)
    blockBox.Position = UDim2.fromOffset(240, 312)
    blockBox.BackgroundColor3 = COLORS.cell
    blockBox.BorderSizePixel = 0
    blockBox.Font = Enum.Font.Gotham
    blockBox.TextSize = 13
    blockBox.TextColor3 = COLORS.text
    blockBox.Text = ""
    blockBox.PlaceholderText = "block id (misal: 1)"
    blockBox.Parent = win
    Instance.new("UICorner", blockBox).CornerRadius = UDim.new(0, 6)
    blockBox.FocusLost: