-- V6.18 cinematic popup gate regressions. Studio Edit context, isolated source only.
-- No production module require, GUI, remote, combat service or Roblox instance is used.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local HttpService = game:GetService("HttpService")
local actualTypeof = typeof
local controllers = game:GetService("StarterPlayer").StarterPlayerScripts.Controllers
local gateModule = controllers:FindFirstChild("CinematicUiGate")
local passed, failed, warnings = {}, {}, {}
local integrationPassed, integrationFailed = {}, {}

local function forbidden()
    error("Cinematic UI gate fixture attempted an external side effect")
end
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function fixture()
    local f = { now = 100, queue = {} }
    function f:resume(thread, ...)
        local ok, marker = coroutine.resume(thread, ...)
        assert(ok, tostring(marker))
        assert(coroutine.status(thread) == "dead", "Gate fixture callback unexpectedly yielded")
    end
    function f:step()
        table.sort(self.queue, function(left, right) return left.at < right.at end)
        local entry = table.remove(self.queue, 1)
        if not entry then return false end
        self.now = math.max(self.now, entry.at)
        self:resume(entry.thread, table.unpack(entry.args))
        return true
    end
    function f:drain()
        local steps = 0
        while #self.queue > 0 do
            steps += 1; assert(steps < 1000, "Gate defer queue did not terminate")
            self:step()
        end
    end
    function f:runUntil(target)
        local steps = 0
        while #self.queue > 0 do
            table.sort(self.queue, function(left, right) return left.at < right.at end)
            if self.queue[1].at > target then break end
            steps += 1; assert(steps < 1000, "Gate bounded queue did not terminate")
            self:step()
        end
        self.now = math.max(self.now, target)
    end
    local fakeTask = {
        defer = function(callback, ...)
            local thread = type(callback) == "thread" and callback or coroutine.create(callback)
            table.insert(f.queue, { at = f.now, thread = thread, args = { ... } })
            return thread
        end,
        spawn = function(callback, ...)
            local thread = type(callback) == "thread" and callback or coroutine.create(callback)
            f:resume(thread, ...); return thread
        end,
        delay = function(seconds, callback, ...)
            local thread = coroutine.create(callback)
            table.insert(f.queue, { at = f.now + seconds, thread = thread, args = { ... } })
            return thread
        end,
        wait = forbidden, cancel = forbidden,
    }
    f.task = fakeTask
    local source = sourceOverrides and sourceOverrides.CinematicUiGate or (gateModule and gateModule.Source)
    assert(source, "CinematicUiGate source is required; deploy it or provide a local source override")
    local chunk, compileError = loadstring(source, "=CinematicUiGate")
    assert(chunk, compileError)
    setfenv(chunk, setmetatable({
        script = { Name = "CinematicUiGate" }, game = { GetService = forbidden },
        Instance = { new = forbidden }, require = forbidden, task = fakeTask,
        os = setmetatable({ clock = function() return f.now end }, { __index = os }),
        warn = function(message) table.insert(warnings, tostring(message)) end,
    }, { __index = getfenv() }))
    f.gate = chunk()
    return f
end
local function test(name, callback)
    local ok, failure = pcall(callback)
    if ok then table.insert(passed, name)
    else table.insert(failed, { name = name, error = tostring(failure) }) end
end

local function integrationTest(name, callback)
    local ok, failure = pcall(callback)
    if ok then table.insert(integrationPassed, name)
    else table.insert(integrationFailed, { name = name, error = tostring(failure) }) end
end

-- Private UI source copies share this real isolated gate. All UI/service objects are Lua tables.
local function uiFixture(subscribeModal)
    local f = fixture()
    local function newSignal()
        local result = { entries = {} }
        function result:Connect(callback)
            local connection = { Connected = true, callback = callback }
            function connection:Disconnect() self.Connected = false end
            table.insert(self.entries, connection); return connection
        end
        function result:Fire(...)
            for _, connection in ipairs(table.clone(self.entries)) do
                if connection.Connected then connection.callback(...) end
            end
        end
        function result:Wait() return Enum.PlaybackState.Completed end
        return result
    end
    local methods = {}
    function methods:IsA(className)
        return className == "Instance" or className == self.ClassName
            or (className == "GuiObject" and (self.ClassName == "Frame" or self.ClassName == "TextLabel"))
    end
    function methods:GetChildren() return table.clone(self._children) end
    function methods:GetDescendants()
        local result = {}
        for _, child in ipairs(self._children) do
            table.insert(result, child)
            for _, descendant in ipairs(child:GetDescendants()) do table.insert(result, descendant) end
        end
        return result
    end
    function methods:FindFirstChild(name, recursive)
        for _, child in ipairs(recursive and self:GetDescendants() or self._children) do
            if child.Name == name then return child end
        end
        return nil
    end
    function methods:WaitForChild(name)
        local child = self:FindFirstChild(name)
        assert(child, "Missing fake child: " .. name); return child
    end
    function methods:FindFirstChildOfClass(className)
        for _, child in ipairs(self._children) do if child.ClassName == className then return child end end
        return nil
    end
    function methods:IsAncestorOf(other)
        local current = other and other.Parent
        while current do if current == self then return true end; current = current.Parent end
        return false
    end
    function methods:GetPropertyChangedSignal(key)
        self._signals[key] = self._signals[key] or newSignal()
        return self._signals[key]
    end
    function methods:Destroy() self.Parent = nil end
    local mt = {
        __index = function(self, key)
            if methods[key] then return methods[key] end
            if self._props[key] ~= nil then return self._props[key] end
            return methods.FindFirstChild(self, key)
        end,
        __newindex = function(self, key, value)
            if string.sub(key, 1, 1) == "_" then rawset(self, key, value); return end
            local previous = self._props[key]
            if key == "Parent" then
                if previous then
                    local index = table.find(previous._children, self)
                    if index then table.remove(previous._children, index) end
                end
                if value then table.insert(value._children, self) end
            end
            self._props[key] = value
            if key == "Parent" and value then value.ChildAdded:Fire(self) end
            if previous ~= value and self._signals[key] then self._signals[key]:Fire() end
        end,
    }
    local function newNode(className, name, parent)
        local node = setmetatable({ _fixture = true, _children = {}, _signals = {}, _props = {
            ClassName = className, Name = name or className, Visible = false, Enabled = false,
            Scale = 1, ZIndex = 5, Position = UDim2.fromScale(0, 0), Rotation = 0,
            ChildAdded = newSignal(), BackgroundTransparency = 0,
        } }, mt)
        node.Parent = parent
        if className == "Frame" then newNode("UIScale", "UIScale", node) end
        return node
    end
    f.players = newNode("Players"); f.player = newNode("Player", "FixturePlayer", f.players); f.player.UserId = 17001
    f.players.LocalPlayer = f.player
    f.playerGui = newNode("PlayerGui", "PlayerGui", f.player)
    f.main = newNode("ScreenGui", "Main", f.playerGui)
    f.hud = newNode("Frame", "HUD", f.main); f.hud.Visible = true
    f.shop = newNode("Frame", "Shop", f.main)
    f.titlePanel = newNode("Frame", "TitleUnlock", f.main)
    f.wheelPanel = newNode("Frame", "WheelClaim", f.main)
    f.deathPanel = newNode("Frame", "Defeated", f.main)
    f.nuke = newNode("Frame", "Nuke", f.main); f.nuke.Visible = true
    f.warning = newNode("Frame", "Warning", f.main); f.warning.Visible = true
    f.dim = newNode("Frame", "__ModalDimOverlay", f.main)
    f.lighting = newNode("Lighting"); f.blur = newNode("BlurEffect", "Blur", f.lighting)
    local fakeControllers = newNode("Folder", "Controllers")
    local fakeReplicated = newNode("ReplicatedStorage")
    local fakeShared = newNode("Folder", "Shared", fakeReplicated)
    local moduleRefs = {}
    for _, name in ipairs({ "CinematicUiGate", "ModalUiController", "SkinController", "WheelController", "DefeatedController", "TouchRegionGate" }) do
        moduleRefs[name] = newNode("ModuleScript", name, fakeControllers)
    end
    for _, name in ipairs({ "GameConfig", "RemoteNames", "SkinConfig", "TrailConfig", "TitleConfig", "WheelConfig" }) do
        moduleRefs[name] = newNode("ModuleScript", name, fakeShared)
    end
    local remoteNames = { RootFolder = "FixtureEvents", SystemEventsFolder = "System", System = {} }
    local root = newNode("Folder", remoteNames.RootFolder, fakeReplicated)
    local system = newNode("Folder", remoteNames.SystemEventsFolder, root)
    f.remotes = {}
    for _, name in ipairs({ "RequestDefeatedAction", "DeathFeedback", "PlayerStateSync", "ArenaTransitionFeedback" }) do
        remoteNames.System[name] = name
        local remote = newNode("RemoteEvent", name, system)
        remote.OnClientEvent = newSignal(); remote.FireServer = forbidden; f.remotes[name] = remote
    end
    local tweenService = {}
    function tweenService:Create(node, _, goals)
        local tween = { Completed = newSignal() }
        function tween:Cancel() end
        function tween:Play()
            for key, value in pairs(goals) do node[key] = value end
            self.Completed:Fire(Enum.PlaybackState.Completed)
        end
        return tween
    end
    local fakeServices = {
        Lighting = f.lighting, Players = f.players, ReplicatedStorage = fakeReplicated, TweenService = tweenService,
        MarketplaceService = { PromptProductPurchaseFinished = newSignal(), GetProductInfo = forbidden, PromptProductPurchase = forbidden },
        UserInputService = {}, StarterGui = {}, Workspace = {}, RunService = {},
    }
    local fakeGame = {}
    function fakeGame:GetService(name) assert(fakeServices[name], "Unexpected fixture service " .. name); return fakeServices[name] end
    local modules = { CinematicUiGate = f.gate, TouchRegionGate = {}, RemoteNames = remoteNames,
        GameConfig = { MONETIZATION = {} }, SkinConfig = {}, TrailConfig = {}, TitleConfig = {}, WheelConfig = { FreeSpinIntervalSeconds = 60 } }
    local function loadUi(module)
        if modules[module.Name] ~= nil then return modules[module.Name] end
        local source = sourceOverrides and sourceOverrides[module.Name] or controllers:WaitForChild(module.Name).Source
        local chunk, compileError = loadstring(source, "=" .. module.Name); assert(chunk, compileError)
        setfenv(chunk, setmetatable({ script = module, game = fakeGame, require = loadUi, Instance = { new = forbidden },
            task = f.task, os = setmetatable({ clock = function() return f.now end }, { __index = os }),
            typeof = function(value)
                if type(value) == "table" and rawget(value, "_fixture") then return "Instance" end
                return actualTypeof(value)
            end,
            warn = function(message) table.insert(warnings, tostring(message)) end,
        }, { __index = getfenv() }))
        modules[module.Name] = chunk(); return modules[module.Name]
    end
    f.modal = loadUi(moduleRefs.ModalUiController); f.modal._localPlayer = f.player
    if subscribeModal ~= false then f.gate:Subscribe(function(blocked) f.modal:_onCinematicGateChanged(blocked) end) end
    f.skin = loadUi(moduleRefs.SkinController); f.skin._titleUnlockPopup = f.titlePanel
    f.wheel = loadUi(moduleRefs.WheelController); f.wheel._wheelClaim = f.wheelPanel
    f.skinSeen, f.wheelSeen = {}, {}
    f.skin._presentTitleUnlockPopup = function(self, payload)
        table.insert(f.skinSeen, payload.id); self._titleUnlockCanClose = true
        f.modal:PlayPanelOpen("TitleUnlock", f.titlePanel, { Immediate = true })
    end
    f.wheel._presentWheelClaim = function(_, reward)
        table.insert(f.wheelSeen, reward.id)
        f.modal:PlayPanelOpen("WheelClaim", f.wheelPanel, { Immediate = true }); return true
    end
    f.defeated = loadUi(moduleRefs.DefeatedController); f.defeated._defeatedRoot = f.deathPanel
    f.defeated._stopCountdown = function() end
    f.defeated._bindUi = function() return true end
    f.defeated._disconnectButtonBindings = function() end
    function f:bindFakeDeathEvents()
        -- Init is executed only on the private source copy, exclusively against the fake remotes above.
        self.defeated:Init({ LocalPlayer = self.player, SkinController = self.skin, WheelController = self.wheel })
    end
    return f
end

test("Distinct tokens hold the gate until every owner releases", function()
    local f = fixture(); local gate = f.gate
    equal(gate:IsBlocked(), false)
    local first = gate:Acquire("Nuke"); local second = gate:Acquire("Nuke")
    assert(first ~= second, "same owner must still have distinct session tokens")
    equal(gate:IsBlocked(), true)
    gate:Release(first); f:drain(); equal(gate:IsBlocked(), true)
    gate:Release(second); f:drain(); equal(gate:IsBlocked(), false)
end)

test("Duplicate and unknown releases cannot clear another session hold", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke")
    f.gate:Release({}); f.gate:Release(nil); equal(f.gate:IsBlocked(), true)
    local other = f.gate:Acquire("Revenge")
    f.gate:Release(token); f.gate:Release(token); f:drain(); equal(f.gate:IsBlocked(), true)
    f.gate:Release(other); f:drain(); equal(f.gate:IsBlocked(), false)
end)

test("Listeners see transitions and disconnected listeners stop receiving them", function()
    local f = fixture(); local seen = {}
    local connection = f.gate:Subscribe(function(blocked) table.insert(seen, blocked) end)
    equal(connection.Connected, true)
    local first = f.gate:Acquire("Nuke"); local second = f.gate:Acquire("Revenge")
    equal(#seen, 1); equal(seen[1], true)
    f.gate:Release(first); f:drain(); equal(#seen, 1)
    f.gate:Release(second); f:drain(); equal(#seen, 2); equal(seen[2], false)
    connection:Disconnect(); equal(connection.Connected, false)
    local third = f.gate:Acquire("Nuke"); f.gate:Release(third); f:drain(); equal(#seen, 2)
end)

test("A subscriber added while blocked immediately learns the current barrier", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local seen = {}
    f.gate:Subscribe(function(blocked) table.insert(seen, blocked) end)
    equal(#seen, 1); equal(seen[1], true)
    f.gate:Release(token); f:drain(); equal(seen[2], false)
end)

test("Listener exceptions cannot break other subscribers or release", function()
    local f = fixture(); local seen = {}
    f.gate:Subscribe(function() error("fixture subscriber failure") end)
    f.gate:Subscribe(function(blocked) table.insert(seen, blocked) end)
    local token = f.gate:Acquire("Nuke"); equal(seen[1], true)
    f.gate:Release(token); f:drain(); equal(f.gate:IsBlocked(), false); equal(seen[2], false)
end)

test("Deferred rewards remain queued until the complete barrier is released", function()
    local f = fixture(); local count = 0; local token = f.gate:Acquire("Nuke")
    f.gate:Defer("Reward", function() count += 1 end)
    f:drain(); equal(count, 0)
    f.gate:Release(token); equal(count, 0, "release must not open synchronously")
    f:drain(); equal(count, 1)
    f:drain(); equal(count, 1, "reward must not repeat")
end)

test("Deferred panel keys coalesce to the latest intent while distinct keys keep FIFO", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local seen = {}
    f.gate:Defer("A", function() table.insert(seen, "stale A") end)
    f.gate:Defer("B", function() table.insert(seen, "B") end)
    f.gate:Defer("A", function() table.insert(seen, "latest A") end)
    f.gate:Release(token); f:drain()
    equal(#seen, 2); equal(seen[1], "latest A"); equal(seen[2], "B")
end)

test("An open defer rechecks a new cinematic before rendering the popup", function()
    local f = fixture(); local count = 0
    f.gate:Defer("Reward", function() count += 1 end); equal(count, 0)
    local token = f.gate:Acquire("Nuke"); f:drain(); equal(count, 0)
    f.gate:Release(token); f:drain(); equal(count, 1)
end)

test("Release then reacquire within the frame never publishes a false gap", function()
    local f = fixture(); local seen = {}; local count = 0
    f.gate:Subscribe(function(blocked) table.insert(seen, blocked) end)
    local old = f.gate:Acquire("Nuke")
    f.gate:Defer("Reward", function() count += 1 end)
    f.gate:Release(old); local current = f.gate:Acquire("Nuke")
    f:drain(); equal(count, 0); equal(#seen, 1); equal(seen[1], true)
    f.gate:Release(current); f:drain(); equal(count, 1); equal(seen[2], false)
end)

test("A listener starting another cinematic prevents queued popups from draining", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local nested; local count = 0
    f.gate:Subscribe(function(blocked)
        if not blocked and not nested then nested = f.gate:Acquire("Revenge") end
    end)
    f.gate:Defer("Reward", function() count += 1 end)
    f.gate:Release(token); f:drain(); equal(count, 0); equal(f.gate:IsBlocked(), true)
    f.gate:Release(nested); f:drain(); equal(count, 1); equal(f.gate:IsBlocked(), false)
end)

test("A deferred popup starting a cinematic pauses all following popups", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local nested; local seen = {}
    f.gate:Defer("First", function()
        table.insert(seen, "First"); nested = f.gate:Acquire("Revenge")
    end)
    f.gate:Defer("Second", function() table.insert(seen, "Second") end)
    f.gate:Release(token); f:drain(); equal(#seen, 1); equal(seen[1], "First")
    f.gate:Release(nested); f:drain(); equal(#seen, 2); equal(seen[2], "Second")
end)

test("A failed deferred popup cannot swallow later queued rewards", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local count = 0
    f.gate:Defer("Failure", function() error("fixture deferred failure") end)
    f.gate:Defer("Reward", function() count += 1 end)
    f.gate:Release(token); f:drain(); equal(count, 1); equal(f.gate:IsBlocked(), false)
end)

test("A callback can requeue its own key without losing the next presentation", function()
    local f = fixture(); local seen = {}
    f.gate:Defer("Panel", function()
        table.insert(seen, "first")
        f.gate:Defer("Panel", function() table.insert(seen, "second") end)
    end)
    f:drain(); equal(#seen, 2); equal(seen[1], "first"); equal(seen[2], "second")
end)

test("Cancelling a deferred panel removes the old opening intent", function()
    local f = fixture(); local token = f.gate:Acquire("Nuke"); local count = 0
    f.gate:Defer("Panel", function() count += 1 end)
    f.gate:CancelDeferred("Panel")
    f.gate:Release(token); f:drain(); equal(count, 0)
    f.gate:Defer("Panel", function() count += 1 end); f:drain(); equal(count, 1)
end)

integrationTest("Modal hides all ordinary panels and blur while preserving owner intent and nuke GUI", function()
    local f = uiFixture()
    f.modal:PlayPanelOpen("Shop", f.shop, { Immediate = true })
    equal(f.shop.Visible, true); equal(f.blur.Enabled, true)
    local token = f.gate:Acquire("Nuke")
    equal(f.shop.Visible, false); equal(f.hud.Visible, false); equal(f.blur.Enabled, false); equal(f.dim.Visible, false)
    equal(f.nuke.Visible, true); equal(f.warning.Visible, true)
    equal(f.modal._owners.Shop.Panel, f.shop); equal(f.modal:IsPanelRequestedVisible(f.shop), true)
    f.shop.Visible = true; equal(f.shop.Visible, false, "visibility watcher during cinematic")
    f.gate:Release(token); f:drain()
    equal(f.shop.Visible, true); equal(f.hud.Visible, false); equal(f.blur.Enabled, true)
    f.modal:PlayPanelClose("Shop", f.shop, { Immediate = true })
    equal(f.hud.Visible, true); equal(f.blur.Enabled, false)
end)

integrationTest("Modal opening then closing inside the barrier never resurrects a stale panel", function()
    local f = uiFixture(); local count = 0; local token = f.gate:Acquire("Nuke")
    f.modal:PlayPanelOpen("Shop", f.shop, { Immediate = true, OnOpened = function() count += 1 end })
    equal(f.shop.Visible, false); equal(count, 0)
    f.modal:PlayPanelClose("Shop", f.shop, { Immediate = true })
    f.gate:Release(token); f:drain()
    equal(count, 0); equal(f.shop.Visible, false); equal(f.modal._owners.Shop, nil); equal(f.blur.Enabled, false)
end)

integrationTest("Modal and reward resume in either subscriber order without losing a restored panel", function()
    for _, consumerFirst in ipairs({ true, false }) do
        local f = uiFixture(false)
        f.modal:PlayPanelOpen("Shop", f.shop, { Immediate = true })
        local token = f.gate:Acquire("Nuke"); f.modal:_onCinematicGateChanged(true)
        f.gate:Release(token)
        equal(f.gate:IsBlocked(), false); equal(f.modal._cinematicActive, true)
        if consumerFirst then f.modal:PlayPanelOpen("WheelClaim", f.wheelPanel, { Immediate = true }) end
        f.modal:_onCinematicGateChanged(false)
        if not consumerFirst then f.modal:PlayPanelOpen("WheelClaim", f.wheelPanel, { Immediate = true }) end
        f:drain()
        equal(f.wheelPanel.Visible, true); equal(f.shop.Visible, true); equal(f.blur.Enabled, true)
        equal(f.modal._owners.WheelClaim.Panel, f.wheelPanel)
    end
end)

integrationTest("Skin and Wheel retain two blocked rewards in FIFO and closing advances the queue", function()
    local f = uiFixture(); local token = f.gate:Acquire("Nuke")
    for index = 1, 2 do
        f.skin:_playTitleUnlockPopup({ id = "title" .. index })
        f.wheel:_showWheelClaim({ id = "wheel" .. index })
    end
    f:drain(); equal(#f.skinSeen, 0); equal(#f.wheelSeen, 0)
    equal(#f.skin._titleUnlockQueue, 2); equal(#f.wheel._wheelClaimQueue, 2)
    f.gate:Release(token); f:drain()
    equal(f.skinSeen[1], "title1"); equal(f.wheelSeen[1], "wheel1")
    f.skin:_closeTitleUnlockPopup(); f.wheel:_hideWheelClaim(); f:drain()
    equal(f.skinSeen[2], "title2"); equal(f.wheelSeen[2], "wheel2")
    f.skin:_closeTitleUnlockPopup(); f.wheel:_hideWheelClaim(); f:drain()
    equal(f.skin:HasPendingRewardPresentation(), false); equal(f.wheel:HasPendingRewardPresentation(), false)
    equal(#f.skinSeen, 2); equal(#f.wheelSeen, 2)
end)

integrationTest("Interrupting an active Skin or Wheel reward replays it before later FIFO entries", function()
    local f = uiFixture()
    f.skin:_playTitleUnlockPopup({ id = "title1" }); f.skin:_playTitleUnlockPopup({ id = "title2" })
    f.wheel:_showWheelClaim({ id = "wheel1" }); f.wheel:_showWheelClaim({ id = "wheel2" })
    local token = f.gate:Acquire("Nuke")
    f.skin:_suspendTitleUnlockPopup(); f.wheel:_suspendWheelClaim()
    equal(f.skin._titleUnlockQueue[1].id, "title1"); equal(f.wheel._wheelClaimQueue[1].id, "wheel1")
    equal(f.titlePanel.Visible, false); equal(f.wheelPanel.Visible, false)
    f.gate:Release(token); f:drain()
    equal(f.skinSeen[2], "title1"); equal(f.wheelSeen[2], "wheel1")
    f.skin:_closeTitleUnlockPopup(); f.wheel:_hideWheelClaim(); f:drain()
    equal(f.skinSeen[3], "title2"); equal(f.wheelSeen[3], "wheel2")
end)

integrationTest("Defeated takes exclusive ownership only after all real Skin and Wheel reward queues complete", function()
    local f = uiFixture(); f:bindFakeDeathEvents()
    local token = f.gate:Acquire("Nuke")
    for index = 1, 2 do
        f.skin:_playTitleUnlockPopup({ id = "title" .. index })
        f.wheel:_showWheelClaim({ id = "wheel" .. index })
    end
    f.defeated._isDead = true; f.defeated:_setOpen(true, true)
    f.gate:Release(token); f:runUntil(f.now)
    equal(f.defeated._isOpen, false); equal(f.modal._owners.Defeated, nil)
    f.skin:_closeTitleUnlockPopup(); f.wheel:_hideWheelClaim(); f:runUntil(f.now + 0.3)
    equal(f.skin._activeTitleUnlockPayload.id, "title2"); equal(f.wheel._activeWheelClaimReward.id, "wheel2")
    equal(f.defeated._isOpen, false); equal(f.modal._owners.Defeated, nil)
    f.skin:_closeTitleUnlockPopup(); f.wheel:_hideWheelClaim(); f:runUntil(f.now + 0.3)
    equal(f.defeated._isOpen, true); equal(f.deathPanel.Visible, true)
    equal(f.modal._owners.Defeated.Panel, f.deathPanel)
    local ownerCount = 0; for _ in pairs(f.modal._owners) do ownerCount += 1 end
    equal(ownerCount, 1, "defeated exclusive modal ownership")
end)

integrationTest("Real alive and ReturnHome event handlers cancel a queued old death panel", function()
    for _, eventName in ipairs({ "PlayerStateSync", "ArenaTransitionFeedback" }) do
        local f = uiFixture(); f:bindFakeDeathEvents()
        local token = f.gate:Acquire("Nuke")
        f.skin:_playTitleUnlockPopup({ id = "title" })
        f.defeated._isDead = true; f.defeated:_setOpen(true, true)
        local payload = eventName == "PlayerStateSync" and { alive = true } or { status = "ReturnHome" }
        f.remotes[eventName].OnClientEvent:Fire(payload)
        equal(f.defeated._isDead, false)
        f.gate:Release(token); f:runUntil(f.now + 0.3)
        f.skin:_closeTitleUnlockPopup(); f:runUntil(f.now + 0.3)
        equal(f.defeated._isOpen, false); equal(f.deathPanel.Visible, false); equal(f.modal._owners.Defeated, nil)
    end
end)

return HttpService:JSONEncode({ passed = passed, failed = failed, integrationPassed = integrationPassed,
    integrationFailed = integrationFailed, warnings = warnings })
