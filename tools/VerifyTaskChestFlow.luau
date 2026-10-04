-- V6.22 isolated Studio Edit regression: real sources, fake services/remotes and cloned formal GUI.
-- Never calls production Init, starts Play, accesses DataStores or changes a real player's inventory.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit only")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local previousTaskSource = nil -- Runner can inject the exact pre-change config for equality checks.
local HttpService = game:GetService("HttpService")
local shared = game.ReplicatedStorage.Shared
local services = game.ServerScriptService.Services
local controllers = game.StarterPlayer.StarterPlayerScripts.Controllers
local results, warnings = {}, {}
local verified = true
local temporary, tasks, chests, navigation, gate

local function check(name, callback)
    local ok, failure = pcall(callback)
    table.insert(results, { name = name, passed = ok, detail = not ok and tostring(failure) or nil })
    if not ok then verified = false end
end
local function fresh(module, overrides)
    local env = setmetatable({ script = module }, { __index = getfenv() })
    env.require = function(dependency)
        if overrides and overrides[dependency.Name] then return overrides[dependency.Name] end
        return require(dependency)
    end
    env.warn = function(message) table.insert(warnings, tostring(message)) end
    local chunk = assert(loadstring(module.Source, module.Name))
    setfenv(chunk, env)
    return chunk()
end
local function same(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not same(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

local setupOk, setupFailure = pcall(function()
    local config = fresh(shared.TaskConfig)
    local actorUtils = {
        IsPlayer = function(actor) return type(actor) == "table" and actor.kind == "Player" end,
        IsBot = function(actor) return type(actor) == "table" and actor.IsBot == true end,
    }
    local server = fresh(services.TaskService, { TaskConfig = config, ActorUtils = actorUtils })
    local player = { kind = "Player", UserId = 1, Parent = true }
    local enemy = { kind = "Player", UserId = 2, Parent = true }
    local bot = { IsBot = true, UserId = -1 }
    local states = {}
    for _, actor in ipairs({ player, enemy, bot }) do
        states[actor] = { Alive = true, IsInArena = true }
    end
    local inventory, dirtyCount, syncCount, loaded = 0, 0, 0, true
    server._playerStateService = {
        GetState = function(_, actor) return states[actor] end,
        AddChest = function(_, who, id, amount)
            assert(who == player and id == 101)
            inventory += amount
            return true
        end,
    }
    server._rebirthService = {
        IsPlayerLoaded = function() return loaded end,
        MarkDirty = function() dirtyCount += 1 end,
    }
    server._taskStateSyncEvent = { FireClient = function() syncCount += 1 end }
    local function progress() return states[player].TaskState.Daily.ProgressByTaskId["107"] or 0 end
    check("Only one new daily task; Blade Breaker is 30 breaks and chest 101 x2", function()
        assert(#config.GetAllTasks() == 15)
        local row = config.GetTask(107)
        assert(row.Period == "Daily" and row.TaskType == "EnemyWeaponsBroken" and row.TaskTypeId == 1005)
        assert(row.Target == 30 and row.ShortTitle == "Blade Breaker")
        assert(row.RewardType == "Chest" and row.ChestId == 101 and row.Amount == 2)
        assert(#row.Rewards == 1 and row.Rewards[1].Amount == 2)
        if previousTaskSource then
            local before = assert(loadstring(previousTaskSource))()
            assert(#before.GetAllTasks() == 14)
            for _, old in ipairs(before.GetAllTasks()) do assert(same(old, config.GetTask(old.TaskId)), "Old task changed") end
        end
    end)
    states[player].TaskState = server:NormalizeState(nil, os.time())
    states[player].TaskState.Daily.ProgressByTaskId["101"] = 420
    check("29 real breaks stay unclaimable, old progress untouched and state marked dirty", function()
        for _ = 1, 29 do assert(server:RecordEnemyWeaponBroken(player, enemy)) end
        assert(progress() == 29 and inventory == 0)
        local ok, reason = server:ClaimTask(player, 107)
        assert(not ok and reason == "NotComplete", tostring(reason))
        assert(states[player].TaskState.Daily.ProgressByTaskId["101"] == 420 and dirtyCount >= 29 and syncCount >= 29)
    end)
    check("Bot target credits the player; 30th break completes, clamps and grants exactly two once", function()
        assert(server:RecordEnemyWeaponBroken(player, bot) and progress() == 30)
        assert(not server:RecordEnemyWeaponBroken(player, enemy) and progress() == 30)
        table.clear(server._lastRequestClockByUserId)
        assert(server:ClaimTask(player, 107) and inventory == 2)
        table.clear(server._lastRequestClockByUserId)
        local ok, reason = server:ClaimTask(player, 107)
        assert(not ok and reason == "AlreadyClaimed" and inventory == 2, tostring(reason))
    end)
    check("Daily persistence survives normalization and resets at the next UTC day", function()
        local saved = server:NormalizeState(states[player].TaskState, os.time())
        assert(saved.Daily.ProgressByTaskId["107"] == 30 and saved.Daily.ClaimedByTaskId["107"])
        local nextDay = config.GetResetTimestamp("Daily", os.time())
        assert(server:NormalizeState(saved, nextDay).Daily.ProgressByTaskId["107"] == nil)
    end)
    states[player].TaskState.Daily.ProgressByTaskId["107"] = 0
    check("Self, invalid, Bot source, dead, outside arena and unloaded data do not count", function()
        assert(not server:RecordEnemyWeaponBroken(player, player))
        assert(not server:RecordEnemyWeaponBroken(player, {}))
        assert(not server:RecordEnemyWeaponBroken(bot, player))
        states[enemy].Alive = false
        assert(not server:RecordEnemyWeaponBroken(player, enemy))
        states[enemy].Alive = true; states[player].IsInArena = false
        assert(not server:RecordEnemyWeaponBroken(player, enemy))
        states[player].IsInArena = true; loaded = false
        assert(not server:RecordEnemyWeaponBroken(player, enemy))
        loaded = true
        assert(progress() == 0)
    end)
    local combat = fresh(services.CombatService, { ActorUtils = actorUtils })
    combat._taskService = server
    combat._weaponService = {
        _resolveActorByCombatUserId = function(_, id) return id == 1 and player or enemy end,
        GetWeaponHitPosition = function() return nil end,
        HandleBrokenWeapon = function(_, weapon)
            if not weapon.Alive or weapon.protected then return false end
            weapon.Alive = false
            return true
        end,
    }
    local function weapon(id, rank, protected)
        return { Id = tostring(id), OwnerUserId = id, CombatRank = rank, TierIndex = rank, Alive = true, protected = protected }
    end
    check("Both rank win branches count only successful enemy breaks", function()
        combat:_applyWeaponVsWeapon(weapon(1, 3), weapon(2, 1))
        combat:_applyWeaponVsWeapon(weapon(2, 1), weapon(1, 3))
        assert(progress() == 2)
    end)
    check("Equal-rank double break credits both captured owners", function()
        combat:_applyWeaponVsWeapon(weapon(1, 2), weapon(2, 2))
        assert(progress() == 3 and states[enemy].TaskState.Daily.ProgressByTaskId["107"] == 1)
    end)
    check("Protected last weapon, repeat dead weapon and safe zone yield no break progress", function()
        combat:_applyWeaponVsWeapon(weapon(1, 3), weapon(2, 1, true))
        local a, b = weapon(1, 3), weapon(2, 1)
        b.Alive = false
        combat:_applyWeaponVsWeapon(a, b)
        combat._arenaService = { IsActorInsideSafeZone = function() return true end }
        combat:_applyWeaponVsWeapon(weapon(1, 3), weapon(2, 1))
        combat._arenaService = nil
        assert(progress() == 3)
    end)
    check("Progress reporting exception cannot stop the clash outcome", function()
        combat._taskService = { RecordEnemyWeaponBroken = function() error("fixture failure") end }
        local a, b = weapon(1, 2), weapon(2, 2)
        combat:_applyWeaponVsWeapon(a, b)
        assert(not a.Alive and not b.Alive and #warnings == 2)
    end)
    local chestServer = fresh(services.ChestService, { ActorUtils = actorUtils })
    local rejection
    chestServer._playerStateService = { GetChestCount = function() return 0 end, GetChests = function() return {} end }
    chestServer._stateSyncEvent = { FireClient = function(_, _, payload) rejection = payload end }
    check("Server NoChest denial includes the optional reason; normal state has no rejection", function()
        local ok, reason = chestServer:OpenChest(player, 101, "One")
        assert(not ok and reason == "NoChest" and rejection.openRejectedReason == "NoChest")
        chestServer:PushState(player)
        assert(rejection.openRejectedReason == nil)
    end)

    temporary = Instance.new("Folder")
    temporary.Name = "TaskChestFlowVerification_" .. HttpService:GenerateGUID(false)
    temporary.Parent = game.ServerStorage
    local main = game.StarterGui.Main:Clone()
    main.Parent = temporary
    local fakeGui = { FindFirstChild = function(_, name) return name == "Main" and main or nil end }
    local fakePlayer = { FindFirstChild = function(_, name) return name == "PlayerGui" and fakeGui or nil end }
    gate = fresh(controllers.CinematicUiGate)
    tasks = fresh(controllers.TaskController, { CinematicUiGate = gate })
    chests = fresh(controllers.ChestController)
    navigation = fresh(controllers.TaskChestNavigationController, { CinematicUiGate = gate })
    navigation:Init({ TaskController = tasks, ChestController = chests })
    tasks._localPlayer, chests._localPlayer = fakePlayer, fakePlayer
    tasks._navigationController, chests._navigationController = navigation, navigation
    local callbacks, openRequests = {}, 0
    for _, controller in ipairs({ tasks, chests }) do
        local original = controller._bindButton
        controller._bindButton = function(self, button, callback, ...)
            if button then callbacks[button] = callback end
            return original(self, button, callback, ...)
        end
    end
    chests._requestOpenEvent = { FireServer = function(_, payload) openRequests += 1; assert(payload.chestId == 101) end }
    assert(tasks:_bindUi(true) and chests:_bindUi(true))
    tasks:_applyStatePayload(server:BuildStatePayload(player))
    local function chestCallback()
        local row = tasks._generatedRewardRows[1]
        local button = row and row:FindFirstChild("RewardChestClickTarget", true)
        return assert(button and callbacks[button], "Missing reward chest click binding")
    end
    check("Loading inventory does not request opening or redirect", function()
        chests:Open()
        chests:_requestOpen("One")
        assert(navigation._currentPage == "Chests" and openRequests == 0 and not chests._openOneBinding.enabled)
    end)
    check("Zero chest Open enters Tasks; closing Tasks restores Box", function()
        chests:_applyPayload({ chests = {} })
        assert(chests._openOneBinding.enabled)
        callbacks[chests._openOneBinding.button]()
        assert(tasks._panel.Visible and not chests._panel.Visible and openRequests == 0)
        callbacks[tasks._closeButton]()
        assert(chests._panel.Visible and not tasks._panel.Visible and navigation._currentPage == "Chests")
    end)
    check("Open All with zero count also enters Tasks and returns to Box", function()
        callbacks[chests._openAllBinding.button]()
        assert(navigation._currentPage == "Tasks" and openRequests == 0)
        tasks:Close()
        assert(navigation._currentPage == "Chests")
    end)
    check("Reward chest preview opens Box without consuming; closing restores weekly selection and scroll", function()
        tasks:Open(); tasks:_selectPeriod("weekly"); tasks:_selectTask(208)
        tasks._scrollingFrame.CanvasPosition = Vector2.new(0, 125)
        local saved = tasks:_captureNavigationState()
        chestCallback()()
        assert(chests._panel.Visible and not tasks._panel.Visible and openRequests == 0)
        chests:Close()
        assert(tasks._panel.Visible and not chests._panel.Visible)
        assert(tasks._selectedPeriod == "weekly" and tasks._selectedTaskIdByPeriod.weekly == 208)
        assert(tasks._scrollingFrame.CanvasPosition == saved.canvasPosition)
    end)
    check("Reward cache retains buttons on unchanged payload and disconnects removed reward rows", function()
        local row = tasks._generatedRewardRows[1]
        local binding = tasks._rewardBindings[1]
        tasks:_renderRewardList({ rewards = { { rewardType = "Chest", chestId = 101, amount = 20, icon = "rbxassetid://89590364394067" } } })
        assert(tasks._generatedRewardRows[1] == row and tasks._rewardBindings[1] == binding)
        tasks:_renderRewardList({ rewards = { { rewardType = "Diamonds", amount = 20, icon = "rbxassetid://89590364394067" } } })
        assert(#tasks._rewardBindings == 0)
        for _, connection in ipairs(binding.connections) do assert(not connection.Connected) end
        tasks:_renderAll()
    end)
    check("Repeat link clicks are ignored; nested round trips restore each immediate origin", function()
        local click = chestCallback()
        click(); click()
        assert(#navigation._history == 1)
        chests:_requestOpen("One")
        assert(navigation._currentPage == "Tasks" and #navigation._history == 2)
        tasks:Close()
        assert(navigation._currentPage == "Chests" and #navigation._history == 1)
        chests:Close()
        assert(navigation._currentPage == "Tasks" and #navigation._history == 0)
        tasks:Close()
        assert(navigation._currentPage == nil)
    end)
    check("Blade Breaker detail renders 30-break target and two-chest reward with an active preview", function()
        tasks:Open(); tasks:_selectPeriod("daily"); tasks:_selectTask(107)
        local row = tasks._generatedRewardRows[1]
        assert(row.RewardNum.Text == "x2" and #tasks._rewardBindings == 1)
        assert(tasks._state.tasks.daily[#tasks._state.tasks.daily].taskId == 107)
        assert(chestCallback())
        tasks:Close()
    end)
    check("Positive inventory sends one request; consuming the last chest does not redirect", function()
        chests:Open(); chests:_applyPayload({ chests = { ["101"] = 1 } })
        chests:_requestOpen("One"); chests:_requestOpen("All")
        assert(openRequests == 1)
        chests:_applyPayload({ chests = {} })
        assert(navigation._currentPage == "Chests")
    end)
    check("Authoritative NoChest denial redirects only while Box is current", function()
        chests:_applyPayload({ chests = {}, openRejectedReason = "NoChest" })
        assert(navigation._currentPage == "Tasks")
        tasks:Close()
        chests._openRequestPending = true
        chests:Close()
        chests:_applyPayload({ chests = {}, openRejectedReason = "NoChest" })
        assert(navigation._currentPage == nil)
    end)
    check("Fresh HUD entry clears old history; rebind keeps current page visible", function()
        tasks:Open(); chestCallback()()
        chests:Open()
        assert(#navigation._history == 0)
        assert(chests:_bindUi(true) and chests._panel.Visible)
        chests:Close()
        assert(navigation._currentPage == nil and not tasks._isOpen)
    end)
    check("Late task panel retains open intent and appears when the formal template binds", function()
        local originalBind, originalRetry = tasks._bindUi, tasks._queueBindRetry
        local retries = 0
        tasks._panel = nil
        tasks._bindUi = function() return false end
        tasks._queueBindRetry = function() retries += 1 end
        tasks:Open()
        assert(tasks._isOpen and retries == 1)
        tasks._bindUi, tasks._queueBindRetry = originalBind, originalRetry
        assert(tasks:_bindUi(true) and tasks._panel.Visible)
        tasks:Close(); tasks:_setOpen(false, true)
    end)
    check("Cinematic-deferred navigation opens only the latest route; close cancels delayed reopen", function()
        local token = gate:Acquire("fixture")
        chests:Open()
        assert(not chests._panel.Visible)
        navigation:Navigate("Chests", "Tasks")
        assert(not tasks._panel.Visible)
        tasks:Close(); chests:Close()
        gate:Release(token)
        task.wait(0.1)
        assert(navigation._currentPage == nil and not chests._panel.Visible and not tasks._panel.Visible)
    end)
    check("Deferred destination opens after cinematic release and still returns to its source", function()
        local token = gate:Acquire("fixture")
        chests:Open(); navigation:Navigate("Chests", "Tasks")
        assert(not chests._panel.Visible and not tasks._panel.Visible)
        gate:Release(token); task.wait(0.15)
        assert(tasks._panel.Visible and not chests._panel.Visible)
        tasks:Close()
        assert(chests._panel.Visible and not tasks._panel.Visible)
        chests:Close()
    end)
end)
if not setupOk then check("Setup/execution", function() error(setupFailure) end) end
check("All private bindings, deferred work and GUI copies cleaned up", function()
    if navigation and gate then gate:CancelDeferred(navigation) end
    if tasks then
        tasks._isOpen = false; tasks._panelAnimationSerial += 1
        tasks:_cancelPanelTweens(); tasks:_stopAmbientEffects(); tasks:_cancelMotionTweens()
        tasks:_disconnectBindings(tasks._buttonBindings); tasks:_disconnectBindings(tasks._detailBindings)
        tasks:_clearRows(); tasks:_clearRewardRows()
        for _, connection in ipairs(tasks._panelConnections) do connection:Disconnect() end
    end
    if chests then chests._openRequestSerial += 1; chests:_disconnectButtonBindings() end
end)
if temporary then temporary:Destroy() end
return HttpService:JSONEncode({ verified = verified, results = results, warnings = warnings,
    excluded = { "Edit fixtures do not verify rendered layout, physical mouse/touch input, real networking or DataStore persistence across live sessions." } })
