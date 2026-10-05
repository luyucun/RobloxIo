-- V6.29: isolated integration checks for the actual DefeatedController source.
-- Run via execute_luau in Studio Edit only. No instances, production Init,
-- live RemoteEvents, Marketplace requests, rewards, stores or Playtest are used.
-- This verifies controller wiring/data flow; inspect the formal template separately.
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong PlaceId")

local checks, allConnections = {}, {}
local controller
local function check(name, callback)
    local ok, failure = pcall(callback)
    table.insert(checks, { name = name, passed = ok, detail = not ok and tostring(failure) or nil })
end

local function signal()
    local listeners = {}
    local value = {}
    function value:Connect(callback)
        local connection = { Connected = true, callback = callback }
        function connection:Disconnect() self.Connected = false end
        table.insert(listeners, connection)
        table.insert(allConnections, connection)
        return connection
    end
    function value:Fire(...)
        for _, connection in ipairs(table.clone(listeners)) do
            if connection.Connected then connection.callback(...) end
        end
    end
    return value
end

-- GUI doubles expose real button event surfaces, so _bindClickTarget is unchanged.
-- UIScale is provided up front; the isolated controller cannot create Instances.
local function node(name, className, parent)
    local value = {
        Name = name, ClassName = className, Parent = parent,
        Visible = true, Text = "fixture", Scale = 1, children = {},
    }
    function value:IsA(class)
        return class == self.ClassName
            or (class == "GuiObject" and (self.ClassName == "Frame" or self.ClassName == "TextButton"
                or self.ClassName == "TextLabel" or self.ClassName == "ImageLabel"))
            or (class == "GuiButton" and self.ClassName == "TextButton")
    end
    function value:FindFirstChild(childName, recursive)
        for _, child in ipairs(self.children) do
            if child.Name == childName then return child end
        end
        if recursive then
            for _, child in ipairs(self.children) do
                local found = child:FindFirstChild(childName, true)
                if found then return found end
            end
        end
        return nil
    end
    function value:WaitForChild(childName)
        return assert(self:FindFirstChild(childName), "Missing fixture node " .. childName)
    end
    function value:FindFirstChildOfClass(class)
        for _, child in ipairs(self.children) do
            if child.ClassName == class then return child end
        end
        return nil
    end
    if parent then table.insert(parent.children, value) end
    if className == "TextButton" then
        for _, event in ipairs({ "Activated", "MouseEnter", "MouseLeave", "InputBegan", "InputEnded" }) do
            value[event] = signal()
        end
        node("FixtureScale", "UIScale", value)
    end
    return value
end

local function sourceOf(instance)
    local source = sourceOverrides and sourceOverrides[instance.Name] or instance.Source
    assert(type(source) == "string" and #source > 0, "Missing source " .. instance.Name)
    return source
end

local ok, failure = xpcall(function()
    local replicated = game:GetService("ReplicatedStorage")
    local shared = replicated:WaitForChild("Shared")
    local controllers = game:GetService("StarterPlayer").StarterPlayerScripts:WaitForChild("Controllers")
    local original = controllers:WaitForChild("DefeatedController")
    local function forbidden() error("Unexpected external operation in isolated Defeated verification", 2) end
    local rejectedGame = { GetService = forbidden }
    local function loadData(name)
        local chunk, err = loadstring(sourceOf(shared:WaitForChild(name)), "=" .. name .. "_DefeatedFixture")
        assert(chunk, err)
        setfenv(chunk, setmetatable({ game = rejectedGame, require = forbidden, Instance = { new = forbidden } }, { __index = getfenv() }))
        return chunk()
    end
    local config, names = loadData("GameConfig"), loadData("RemoteNames")
    local fixture = { actions = {}, purchases = 0, modals = {}, priceReads = 0 }
    local playerGui = node("PlayerGui", "PlayerGui")
    playerGui.ChildAdded = signal()
    local main = node("Main", "ScreenGui", playerGui)
    local panel = node("Defeated", "Frame", main)
    local free = node("FreeRespawn", "TextButton", panel)
    local lobby = node("Lobby", "TextButton", panel)
    local revive = node("Revive", "TextButton", panel)
    local revenge = node("Revenge", "TextButton", panel)
    local close = node("CloseButton", "TextButton", node("Title", "Frame", panel))
    for _, button in ipairs({ free, lobby, revive, revenge }) do node("Name", "TextLabel", button) end
    for _, button in ipairs({ free, lobby, revive }) do node("Level", "TextLabel", button) end
    for _, button in ipairs({ revive, revenge }) do node("RMoney", "TextLabel", button) end
    node("DailyFree", "TextLabel", free)
    local killer = node("Killer", "Frame", panel)
    node("Name", "TextLabel", killer)
    node("Icon", "ImageLabel", killer)
    node("Num", "TextLabel", node("KillNum", "Frame", killer))
    node("Num", "TextLabel", node("LvInfo", "Frame", killer))
    node("Progress", "Frame", node("ProgressBg", "Frame", panel))
    node("Time", "TextLabel", panel)
    local player = { UserId = 17 }
    function player:FindFirstChild(name) return name == "PlayerGui" and playerGui or nil end

    local events = node(names.RootFolder, "Folder")
    local system = node(names.SystemEventsFolder, "Folder", events)
    local request = node(names.System.RequestDefeatedAction, "RemoteEvent", system)
    function request:FireServer(action) table.insert(fixture.actions, action) end
    local function remote(name)
        local value = node(name, "RemoteEvent", system)
        value.OnClientEvent = signal()
        return value.OnClientEvent
    end
    local death = remote(names.System.DeathFeedback)
    local state = remote(names.System.PlayerStateSync)
    local transition = remote(names.System.ArenaTransitionFeedback)
    local fakeReplicated = {}
    function fakeReplicated:FindFirstChild(name) return name == "Shared" and shared or nil end
    function fakeReplicated:WaitForChild(name)
        assert(name == names.RootFolder, "Unexpected replicated folder " .. name)
        return events
    end
    local marketplace = { PromptProductPurchaseFinished = signal() }
    function marketplace:GetProductInfoAsync()
        fixture.priceReads += 1
        return { PriceInRobux = 17 }
    end
    function marketplace:PromptProductPurchase()
        fixture.purchases += 1
        error("Free actions must not prompt purchases")
    end
    local tweenService = {}
    function tweenService:Create(target, _, goals)
        local tween = { Completed = signal() }
        function tween:Cancel() end
        function tween:Play()
            for property, value in pairs(goals) do target[property] = value end
            self.Completed:Fire()
        end
        return tween
    end
    local gateSignal = signal()
    local gate = { IsBlocked = function() return false end }
    function gate:Subscribe(callback) return gateSignal:Connect(callback) end
    function gate:Defer(_, callback) callback() end
    local modal = {}
    function modal:PlayPanelOpen(owner, root)
        table.insert(fixture.modals, { owner = owner, open = true })
        if root then root.Visible = true end
    end
    function modal:PlayPanelClose(owner, root)
        table.insert(fixture.modals, { owner = owner, open = false })
        if root then root.Visible = false end
    end
    local services = {
        MarketplaceService = marketplace, ReplicatedStorage = fakeReplicated, TweenService = tweenService,
        Players = { LocalPlayer = player, GetUserThumbnailAsync = function() return "fixture://avatar" end },
    }
    local fakeGame = {}
    function fakeGame:GetService(name) return assert(services[name], "Unexpected service " .. name) end
    local imports = { GameConfig = config, RemoteNames = names, ModalUiController = modal, CinematicUiGate = gate }
    local chunk, compileError = loadstring(sourceOf(original), "=DefeatedController_IsolatedVerification")
    assert(chunk, compileError)
    setfenv(chunk, setmetatable({
        game = fakeGame, script = original, Instance = { new = forbidden },
        require = function(module) return assert(imports[module.Name], "Unexpected import " .. module.Name) end,
        task = {
            spawn = function(callback, ...) return callback(...) end,
            defer = function(callback, ...) return callback(...) end,
            delay = forbidden, wait = forbidden,
        },
    }, { __index = getfenv() }))
    controller = chunk()
    controller:Init({ LocalPlayer = player })

    local function die(level, retainedLevel)
        death:Fire({ victimLevel = level, freeRespawnLevel = retainedLevel,
            killer = { userId = 19, name = "Fixture opponent", level = 99, totalPlayerKills = 8 } })
        assert(controller._isDead and controller._isOpen and panel.Visible, "Death feedback must open the panel")
    end
    local function textOf(button, name) return button:WaitForChild(name).Text end
    local function assertLevel(expected)
        assert(textOf(free, "Level") == expected, "Wrong free respawn retained level")
        assert(textOf(lobby, "Level") == expected, "Lobby must display the same retained level")
    end

    check("Death feedback renders both action titles and Lv40 -> Lv20", function()
        die(40)
        assert(textOf(free, "Name") == "Free Respawn")
        assert(textOf(lobby, "Name") == "Free to Lobby")
        assertLevel("With Lv.20")
        assert(textOf(revive, "Level") == "With Lv.40", "Paid revive must keep full level caption")
        assert(not free:WaitForChild("DailyFree").Visible)
    end)
    check("Odd death level rounds down: Lv9 -> Lv4 on both actions", function()
        die(9)
        assertLevel("With Lv.4")
    end)
    check("Minimum death level stays Lv1 on both actions", function()
        die(1)
        assertLevel("With Lv.1")
    end)
    check("Server retained level overrides the local half-level estimate", function()
        die(40, 13)
        assertLevel("With Lv.13")
    end)
    for _, action in ipairs({ { free, "FreeRespawn" }, { lobby, "Lobby" }, { close, "Lobby" } }) do
        check(action[1].Name .. " sends exactly one " .. action[2] .. " intent and closes", function()
            die(40)
            local before = #fixture.actions
            action[1].Activated:Fire()
            assert(#fixture.actions == before + 1 and fixture.actions[#fixture.actions] == action[2])
            assert(not controller._isOpen and not panel.Visible)
            assert(controller._isDead, "A click must not predict successful server revival")
        end)
    end
    for _, mode in ipairs({ "FreeRespawnFailed", "LobbyReviveFailed" }) do
        check(mode .. " reopens the same death panel for retry", function()
            die(9)
            free.Activated:Fire()
            local before = #fixture.actions
            transition:Fire({ status = "Blocked", spawnMode = mode })
            assert(controller._isDead and controller._isOpen and panel.Visible)
            assertLevel("With Lv.4")
            assert(#fixture.actions == before, "Failure feedback must not send another request")
            assert(not panel:WaitForChild("ProgressBg").Visible and not panel:WaitForChild("Time").Visible)
        end)
    end
    check("Alive state closes a reopened panel after successful free respawn", function()
        die(40)
        state:Fire({ alive = true, isInArena = true })
        assert(not controller._isDead and not controller._isOpen and not panel.Visible)
    end)
    check("ReturnHome feedback closes the panel after successful Lobby return", function()
        die(40)
        transition:Fire({ status = "ReturnHome", spawnMode = "Lobby" })
        assert(not controller._isDead and not controller._isOpen and not panel.Visible)
    end)
    check("Unrelated or malformed transition feedback cannot reopen a dismissed panel", function()
        die(40)
        free.Activated:Fire()
        transition:Fire(nil)
        transition:Fire("bad payload")
        transition:Fire({ status = "Blocked", spawnMode = "DataLoading" })
        assert(not controller._isOpen and not panel.Visible)
    end)
    check("Reinitialization disconnects old handlers and sends only one free intent", function()
        controller:Init({ LocalPlayer = player })
        die(40)
        local before = #fixture.actions
        free.Activated:Fire()
        assert(#fixture.actions == before + 1 and fixture.actions[#fixture.actions] == "FreeRespawn")
    end)
    check("All free-action flows avoid purchase prompts", function()
        assert(fixture.purchases == 0)
    end)
end, debug.traceback)

-- Cleanup runs even after compile/init/assertion failure. All connections and GUI
-- objects are Lua tables; no Studio tree, production service, or user state changed.
for _, connection in ipairs(allConnections) do connection:Disconnect() end
local connected = 0
for _, connection in ipairs(allConnections) do if connection.Connected then connected += 1 end end
if not ok then table.insert(checks, { name = "Fixture setup/execution", passed = false, detail = tostring(failure) }) end
table.insert(checks, { name = "Every isolated connection cleaned up", passed = connected == 0 })
local passed = 0
for _, result in ipairs(checks) do if result.passed then passed += 1 end end
return HttpService:JSONEncode({
    verified = passed == #checks, passed = passed, total = #checks, checks = checks,
    mode = "isolated actual-controller Init/events; Studio Edit only; no instance writes or live network",
})
