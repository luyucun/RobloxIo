-- V6.29 regression checks: run through execute_luau in Studio EDIT context only.
-- Compiles isolated copies of module source with fake players/services.
-- Does not call Init, start Playtest, create instances, grant rewards or write stores.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local HttpService = game:GetService("HttpService")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local clockNow = 100
local currentPlayers = {}
local deferred = {}
local passed = {}
local fakeActors = {
    IsPlayer = function(actor) return type(actor) == "table" and actor.kind == "player" end,
    IsBot = function(actor) return type(actor) == "table" and actor.kind == "bot" end,
    GetActorId = function(actor) return actor.UserId end,
    GetRootPart = function(actor) return actor.root end,
    GetHumanoid = function(actor) return actor.humanoid end,
    GetCharacter = function(actor) return actor.character end,
}
local fakeGame = {}
function fakeGame:GetService(name)
    if name == "Players" then
        return { GetPlayers = function() return currentPlayers end }
    end
    return game:GetService(name)
end
local config = require(game.ReplicatedStorage.Shared.GameConfig)
local function loadIsolated(instance)
    local source = sourceOverrides and sourceOverrides[instance.Name] or instance.Source
    local chunk, err = loadstring(source, "=" .. instance.Name)
    assert(chunk, err)
    setfenv(chunk, setmetatable({
        script = instance,
        game = fakeGame,
        typeof = function(value)
            if type(value) == "table" and value.kind == "player" then return "Instance" end
            return typeof(value)
        end,
        os = setmetatable({ clock = function() return clockNow end }, { __index = os }),
        task = {
            delay = function(_, callback) table.insert(deferred, callback) end,
            defer = function(callback) table.insert(deferred, callback) end,
            wait = function(seconds) clockNow += seconds or 0.05 end,
        },
        require = function(module)
            if module.Name == "ActorUtils" then return fakeActors end
            return require(module)
        end,
    }, { __index = getfenv() }))
    return chunk()
end
local services = game.ServerScriptService.Services
local controllers = game.StarterPlayer.StarterPlayerScripts.Controllers
local Arena = loadIsolated(services.ArenaService)
local Respawn = loadIsolated(services.RespawnService)
local Auto = loadIsolated(controllers.AutoBattleController)
local Join = loadIsolated(controllers.JoinGameController)
local function test(name, callback)
    clockNow += 10
    table.clear(deferred)
    callback()
    table.insert(passed, name)
end
local function playerFixture()
    return { kind = "player", UserId = 17, Parent = true, root = {}, humanoid = { Health = 100 } }
end
local function analyticsFixture(log)
    local once = {}
    return {
        MarkOnce = function(_, _, key)
            if once[key] then return false end
            once[key] = true
            return true
        end,
        TrackFunnel = function(_, _, funnel, step, stepName)
            table.insert(log, { funnel = funnel, step = step, name = stepName })
        end,
        TrackCustom = function() end,
    }
end
local function arenaFixture()
    local f = { player = playerFixture(), inside = true, loaded = true, teleports = 0, shields = 0, weapons = 0, feedback = {}, events = {} }
    f.state = { Alive = true, IsInArena = false, Level = 100 }
    local a = table.clone(Arena)
    f.service = a
    for _, key in ipairs({
        "_portalEntryAttemptClockByUserId", "_pendingPortalEntryByUserId",
        "_portalEntrySuppressedUntilExitByUserId", "_enterDebounceByActorId",
        "_hasEnteredArenaThisSessionByUserId", "_firstArenaEnterPendingByUserId",
    }) do a[key] = {} end
    a._portalRangeMonitorAccumulator = 0
    a._battlePart = {}
    a._playerStateService = {
        GetState = function() return f.state end,
        SetInArena = function(_, _, value) f.state.IsInArena = value end,
        MarkGuideCompleted = function() end,
        PushState = function() end,
    }
    a._rebirthService = { IsPlayerLoaded = function() return f.loaded end }
    a._healthService = { GrantShield = function() f.shields += 1 end }
    a._weaponService = { RebuildWeaponsForPlayer = function() f.weapons += 1 end }
    a._gameAnalyticsService = analyticsFixture(f.events)
    a._arenaTransitionFeedbackEvent = { FireClient = function(_, _, payload) table.insert(f.feedback, payload) end }
    a._isActorInsidePortalBounds = function() return f.inside end
    a._findBestArenaSpawnPosition = function() return Vector3.zero end
    a._teleportActorToPosition = function()
        f.teleports += 1
        return f.teleportFailure ~= true
    end
    a._isActorInsideBattleBounds = function() return true end
    a._resetSafeReentryLock = function() end
    a._resolveActorFromCharacter = function() return f.player end
    currentPlayers = { f.player }
    return f
end

test("Portal touch enters without a client Join request", function()
    local f = arenaFixture()
    f.service:_onPortalTouched({ FindFirstAncestorOfClass = function() return {} end })
    assert(f.state.IsInArena and f.teleports == 1 and f.shields == 1 and f.weapons == 1)
    assert(f.events[1].name == "PortalReached" and f.events[2].name == "DirectEntryRequested")
end)
test("Range monitor covers missed Touched events", function()
    local f = arenaFixture()
    f.service:_onPortalRangeHeartbeat(0.11)
    assert(f.state.IsInArena and f.teleports == 1)
end)
test("Dead player cannot enter via touch, range or Join", function()
    local f = arenaFixture()
    f.state.Alive = false
    f.service:_onPortalTouched({ FindFirstAncestorOfClass = function() return {} end })
    clockNow += 10
    f.service:_onPortalRangeHeartbeat(0.11)
    clockNow += 10
    f.service:_onRequestJoinBattle(f.player, "Join")
    assert(f.teleports == 0 and not f.state.IsInArena and not f.state.Alive)
end)
test("Loading player waits, retries with debounce and enters when ready", function()
    local f = arenaFixture()
    f.loaded = false
    assert(not f.service:_tryEnterFromPortal(f.player))
    f.loaded = true
    assert(not f.service:_tryEnterFromPortal(f.player))
    clockNow += config.ARENA.EnterDebounceSeconds + 0.1
    f.service:_onPortalRangeHeartbeat(0.11)
    assert(f.state.IsInArena and f.teleports == 1)
end)
test("Leaving Portal cancels loading retry and old grace eligibility", function()
    local f = arenaFixture()
    f.loaded = false
    f.service:_tryEnterFromPortal(f.player)
    f.inside = false
    f.service:_onPortalRangeHeartbeat(0.11)
    f.loaded = true
    clockNow += 10
    f.service:_onRequestJoinBattle(f.player, "Join")
    assert(f.teleports == 0 and not f.service._pendingPortalEntryByUserId[17])
end)
test("Duplicate Join after entry does not reteleport or grant another shield", function()
    local f = arenaFixture()
    f.service:_tryEnterFromPortal(f.player)
    clockNow += 10
    f.service:_onRequestJoinBattle(f.player, "Join")
    f.service:_onPortalRangeHeartbeat(0.11)
    assert(f.teleports == 1 and f.shields == 1 and f.weapons == 1)
end)
test("Return to lobby requires leaving trigger before another entry", function()
    local f = arenaFixture()
    f.service:PrepareForLobbyReturn(f.player)
    f.service:_onPortalRangeHeartbeat(0.11)
    assert(f.teleports == 0)
    f.inside = false
    f.service:_onPortalRangeHeartbeat(0.11)
    f.inside = true
    f.service:_onPortalRangeHeartbeat(0.11)
    assert(f.teleports == 1)
end)
test("Legacy Cancel and invalid actions cannot force entry", function()
    local f = arenaFixture()
    f.service:_onRequestJoinBattle(f.player, {})
    f.service:_onRequestJoinBattle(f.player, "unknown")
    f.service:_onRequestJoinBattle(f.player, "Cancel")
    f.service:_onRequestJoinBattle(f.player, "Join")
    assert(f.teleports == 0)
end)
test("Missing root retries; failed teleport never grants arena state", function()
    local f = arenaFixture()
    f.player.root = nil
    assert(not f.service:_tryEnterFromPortal(f.player))
    assert(f.teleports == 0)
    f.player.root = {}
    f.teleportFailure = true
    clockNow += 10
    assert(not f.service:_tryEnterFromPortal(f.player))
    assert(not f.state.IsInArena and f.shields == 0 and f.weapons == 0)
end)

local function respawnFixture(level)
    local f = { player = playerFixture(), restores = {}, events = {}, lobby = 0, freeArena = 0, paidArena = 0, feedback = {} }
    f.state = { Alive = false, IsInArena = false, Level = 1, Diamonds = 1234 }
    f.record = { deathSerial = 1, analyticsSessionKey = "death_1", combatSnapshot = {
        preDeathLevel = level or 201, preDeathExperience = 77, preDeathKillCount = 12,
        attributeSnapshot = { fixture = true },
    } }
    local r = table.clone(Respawn)
    f.service = r
    r._deathSerialByActorId = { [17] = 1 }
    r._defeatRecordsByUserId = { [17] = f.record }
    r._arenaRevivePendingByUserId = {}
    r._arenaReviveOptionsByUserId = {}
    r._freeRespawnOperationsByUserId = {}
    r._offlineRespawnSaveSnapshotByUserId = {}
    r._weaponService = { ClearPlayerWeapons = function() end }
    r._playerStateService = {
        GetState = function() return f.state end,
        PushState = function() end,
        SyncCharacterState = function() end,
        UpdateOverheadHealthBar = function() end,
        RestoreCombatProgress = function(_, _, snapshot, options)
            table.insert(f.restores, { snapshot = snapshot, options = options })
            if f.restoreFailure then return false end
            f.state.Level = snapshot.preDeathLevel
            f.state.Experience = snapshot.preDeathExperience
            f.state.KillCount = snapshot.preDeathKillCount
            f.state.MaxHealth = 12345 -- Includes derived attribute/event bonuses.
            f.state.CurrentHealth = f.state.MaxHealth
            f.state.Alive = true
            f.state.IsInArena = options.restoreToLobby ~= true
            return true
        end,
    }
    r._arenaService = {
        PrepareForLobbyReturn = function() f.prepared = true end,
        TeleportPlayerToSpawnLocation = function()
            f.lobby += 1
            return f.teleportFailure ~= true
        end,
        TryEnterArena = function(_, _, options)
            assert(options.IgnoreDebounce and options.IsRevive)
            f.freeArena += 1
            if f.arenaException then error("fixture arena exception") end
            if f.teleportFailure then return false end
            f.state.IsInArena = true
            return true
        end,
    }
    r._revivePlayerNow = function()
        f.paidArena += 1
        f.state.Alive = true
        return true
    end
    r._gameAnalyticsService = analyticsFixture(f.events)
    r._arenaTransitionFeedbackEvent = { FireClient = function(_, _, payload) table.insert(f.feedback, payload) end }
    return f
end
test("FreeRespawn restores half level through default arena revive without lobby teleport", function()
    local f = respawnFixture()
    f.service:_onRequestDefeatedAction(f.player, "FreeRespawn")
    assert(f.state.Level == 100 and f.state.Experience == 0 and f.state.KillCount == 0)
    assert(f.state.Alive and f.state.IsInArena and f.state.Diamonds == 1234)
    assert(f.state.MaxHealth == 12345 and f.state.CurrentHealth == 12345)
    assert(f.lobby == 0 and f.freeArena == 1 and f.paidArena == 0 and not f.prepared)
    assert(f.restores[1].options.rebuildWeapons == false and f.restores[1].snapshot.attributeSnapshot == nil)
    assert(f.events[#f.events].name == "FreeRespawnedSuccessfully")
    assert(f.service:GetDefeatRecord(f.player) == nil)
end)
test("Lobby and Close retain half-level rules; every free action keeps at least Lv1", function()
    for _, action in ipairs({ "Lobby", "Close", "FreeRespawn" }) do
        local f = respawnFixture(1)
        f.service:_onRequestDefeatedAction(f.player, action)
        assert(f.state.Level == 1)
        if action == "FreeRespawn" then
            assert(f.state.IsInArena and f.freeArena == 1 and f.lobby == 0)
        else
            assert(not f.state.IsInArena and f.freeArena == 0 and f.lobby == 1 and f.prepared)
        end
    end
end)
test("CharacterAdded observes half level and completes the pending arena revive exactly once", function()
    local f = respawnFixture(201)
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function()
        assert(f.state.Level == 100 and not f.state.IsInArena)
        assert(f.service:GetDefeatRecord(f.player) == f.record)
        assert(f.service:GetOfflineRespawnSaveSnapshot(f.player).level == 100)
        assert(#f.events == 0)
        assert(f.service:ConsumeArenaReviveRequest(f.player))
        f.player.humanoid.Health = 100
        assert(f.service:CompleteArenaRevive(f.player))
    end
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.state.Level == 100 and f.freeArena == 1 and f.lobby == 0 and #f.events == 1)
    assert(not f.service:CompleteArenaRevive(f.player))
    assert(f.freeArena == 1 and not f.service._freeRespawnOperationsByUserId[17])
end)
test("Deferred CharacterAdded completion cannot grant a second entry or reward", function()
    local f = respawnFixture()
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function()
        assert(f.service:ConsumeArenaReviveRequest(f.player))
        f.player.humanoid.Health = 100
    end
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(not f.service:CompleteArenaRevive(f.player))
    assert(f.freeArena == 1 and f.lobby == 0 and #f.events == 1)
end)
test("Failed character load retains original snapshot and reports failure", function()
    local f = respawnFixture()
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function() error("fixture load failure") end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.service:GetDefeatRecord(f.player) == f.record and not f.state.Alive)
    assert(f.lobby == 0 and f.freeArena == 0 and #f.events == 0)
    assert(f.feedback[#f.feedback].spawnMode == "FreeRespawnFailed")
    assert(f.service:GetOfflineRespawnSaveSnapshot(f.player).level == 100)
    assert(f.service._arenaRevivePendingByUserId[17].freeRespawnOperation.finished)
    assert(not f.service._freeRespawnOperationsByUserId[17])
end)
test("Late CharacterAdded consumes the failed operation without returning to lobby", function()
    local f = respawnFixture()
    f.player.root = nil
    f.player.LoadCharacter = function() end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    local shouldRevive, options = f.service:ConsumeArenaReviveRequest(f.player)
    assert(shouldRevive and options.freeRespawnOperation.finished)
    f.player.root = {}
    f.state.Alive = true -- PlayerStateService:OnCharacterAdded runs before the deferred completion.
    assert(not f.service:CompleteArenaRevive(f.player, options))
    assert(not f.state.Alive and not f.state.IsInArena and f.state.Level == 100)
    assert(f.freeArena == 0 and f.lobby == 0 and #f.events == 0)
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.freeArena == 1 and f.state.Level == 100)
end)
test("An old deferred completion cannot finish or cancel a newer free operation", function()
    local f = respawnFixture()
    local oldOptions
    f.player.root = nil
    f.player.LoadCharacter = function()
        local shouldRevive
        shouldRevive, oldOptions = f.service:ConsumeArenaReviveRequest(f.player)
        assert(shouldRevive)
    end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    f.player.root = {}
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function()
        local shouldRevive, newOptions = f.service:ConsumeArenaReviveRequest(f.player)
        assert(shouldRevive and newOptions ~= oldOptions)
        f.player.humanoid.Health = 100
        assert(not f.service:CompleteArenaRevive(f.player, oldOptions))
        assert(f.state.Alive and f.freeArena == 0 and not newOptions.freeRespawnOperation.finished)
        assert(f.service._arenaReviveOptionsByUserId[17] == newOptions)
        assert(f.service:CompleteArenaRevive(f.player, newOptions))
    end
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.freeArena == 1 and f.state.Level == 100 and #f.events == 1)
end)
test("Failed arena teleport retries without halving twice or premature success", function()
    local f = respawnFixture(201)
    f.teleportFailure = true
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(not f.state.Alive and not f.state.IsInArena and #f.events == 0)
    assert(f.service:GetDefeatRecord(f.player) == f.record and f.service:GetOfflineRespawnSaveSnapshot(f.player).level == 100)
    f.teleportFailure = false
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.state.Level == 100 and #f.events == 1)
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.lobby == 0 and f.freeArena == 2 and f.state.IsInArena)
end)
test("Lobby teleport failure remains retryable with the same half-level snapshot", function()
    local f = respawnFixture(201)
    f.teleportFailure = true
    assert(not f.service:_revivePlayerToLobby(f.player, f.record))
    assert(not f.state.Alive and f.service:GetDefeatRecord(f.player) == f.record)
    assert(f.feedback[#f.feedback].spawnMode == "LobbyReviveFailed")
    f.teleportFailure = false
    assert(f.service:_revivePlayerToLobby(f.player, f.record))
    assert(f.state.Level == 100 and f.lobby == 2 and f.freeArena == 0 and #f.events == 0)
end)
test("Character readiness timeout releases the free operation and preserves retry", function()
    local f = respawnFixture()
    f.player.root = nil
    f.player.LoadCharacter = function() assert(f.service:ConsumeArenaReviveRequest(f.player)) end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(not f.state.Alive and f.service:GetDefeatRecord(f.player) == f.record and #f.events == 0)
    f.player.root = {}
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.state.Level == 100 and f.freeArena == 1)
end)
test("Restore or arena exceptions cannot wedge free respawn or clear the death record", function()
    local f = respawnFixture()
    f.restoreFailure = true
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(not f.service._freeRespawnOperationsByUserId[17] and #f.events == 0)
    f.restoreFailure = false
    f.arenaException = true
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(not f.state.Alive and f.service:GetDefeatRecord(f.player) == f.record and #f.events == 0)
    f.arenaException = false
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.state.Level == 100 and #f.events == 1)
end)
test("Concurrent free/lobby/paid requests cannot replace a free respawn in flight", function()
    local f = respawnFixture()
    f.player.humanoid.Health = 0
    f.record.revivePurchasePending = true
    f.player.LoadCharacter = function()
        assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
        for _, action in ipairs({ "FreeRespawn", "Lobby", "Close", "RevivePurchaseCancel" }) do
            f.service:_onRequestDefeatedAction(f.player, action)
        end
        assert(not f.service:GrantDefeatedRevivePurchase(f.player))
        assert(not Respawn._revivePlayerNow(f.service, f.player))
        assert(f.record.revivePurchasePending and #f.restores == 1 and f.lobby == 0 and f.paidArena == 0)
        assert(f.service:ConsumeArenaReviveRequest(f.player))
        f.player.humanoid.Health = 100
    end
    assert(f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.freeArena == 1 and #f.events == 1)
end)
test("Disconnect during LoadCharacter retains a half-level offline save and never enters arena", function()
    local f = respawnFixture()
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function()
        f.service:OnPlayerRemoving(f.player)
        f.player.Parent = nil
    end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.service:GetOfflineRespawnSaveSnapshot(17).level == 100)
    assert(f.freeArena == 0 and f.lobby == 0 and #f.events == 0)
end)
test("A newer death supersedes a yielding free respawn without losing its snapshot", function()
    local f = respawnFixture()
    local nextRecord = { deathSerial = 2, combatSnapshot = { preDeathLevel = 77 } }
    f.player.humanoid.Health = 0
    f.player.LoadCharacter = function()
        f.service._deathSerialByActorId[17] = 2
        f.service._defeatRecordsByUserId[17] = nextRecord
        f.state.Level = 1
        f.state.Alive = false
        f.player.humanoid.Health = 100
    end
    assert(not f.service:_tryGrantFreeRespawn(f.player, f.record))
    assert(f.service:GetDefeatRecord(f.player) == nextRecord and f.state.Level == 1 and not f.state.Alive)
    assert(f.service:GetOfflineRespawnSaveSnapshot(f.player).level == 38)
    assert(f.freeArena == 0 and #f.events == 0)
end)
test("Malformed defeated requests are rejected without restoring progress", function()
    local f = respawnFixture()
    f.service:_onRequestDefeatedAction(f.player, {})
    f.service:_onRequestDefeatedAction(f.player, "unknown")
    assert(#f.restores == 0 and f.freeArena == 0 and f.lobby == 0)
end)
test("Paid keep-level revive still uses full snapshot and arena route", function()
    local f = respawnFixture()
    f.record.revivePurchasePending = true
    assert(f.service:GrantDefeatedRevivePurchase(f.player))
    assert(f.paidArena == 1 and f.lobby == 0 and f.state.IsInArena)
    assert(f.state.Level == 201 and f.state.Experience == 77 and f.state.KillCount == 12)
    assert(f.restores[1].snapshot.attributeSnapshot.fixture and f.restores[1].options.rebuildWeapons)
end)

local function autoFixture()
    local a = table.clone(Auto)
    a._latestState = { alive = true, isInArena = true }
    a._isAutoEnabled = true
    a._isAutoJoining = false
    a._wantsAutoBattle = true
    a._resumeAutoAfterJoin = true
    a._localPlayer = { SetAttribute = function(_, _, value) a.joinAttribute = value end }
    a._stopMovement = function() a.stopped = true; a._isAutoMoving = false; a._autoPath = nil end
    a._resetAutoTargetState = function() a._autoTargetId = nil end
    a._updateBottomVisibility = function() end
    a._updateAutoButtonUi = function() end
    a._isAutoMoving = true
    a._autoPath = {}
    return a
end
test("Death then lobby state cannot resurrect the previous Auto intent", function()
    local a = autoFixture()
    a:_onPlayerStateSync({ alive = false, isInArena = false })
    a:_onPlayerStateSync({ alive = true, isInArena = false })
    assert(not a._wantsAutoBattle and not a._isAutoJoining and not a._isAutoEnabled)
    assert(not a._resumeAutoAfterJoin and not a.joinAttribute and a.stopped and not a._autoPath)
end)
test("Direct return home without a death packet still ends Auto", function()
    local a = autoFixture()
    a:_onPlayerStateSync({ alive = true, isInArena = false })
    assert(not a._wantsAutoBattle and not a._isAutoJoining)
end)
test("Fresh lobby Auto survives state refresh and begins after entry", function()
    local a = autoFixture()
    a:_onPlayerStateSync({ alive = true, isInArena = false })
    a:_handleAutoButtonActivated()
    assert(a._isAutoJoining and a._wantsAutoBattle)
    a:_onPlayerStateSync({ alive = true, isInArena = false })
    assert(a._isAutoJoining and a._wantsAutoBattle)
    a:_onPlayerStateSync({ alive = true, isInArena = true })
    assert(a._isAutoEnabled and not a._isAutoJoining)
end)
test("Dead player cannot activate lobby Auto", function()
    local a = autoFixture()
    a:_onPlayerStateSync({ alive = false, isInArena = false })
    a:_handleAutoButtonActivated()
    assert(not a._isAutoJoining and not a._wantsAutoBattle)
end)
test("Portal feedback clears on leaving or entering without modal UI", function()
    local j = table.clone(Join)
    j._setPortalText = function(_, text) j.text = text end
    j:_onTransition({ status = "Entering", spawnMode = "Portal" })
    assert(j.text == "Entering...")
    j:_onTransition({ status = "Blocked", spawnMode = "DataLoading" })
    assert(j.text == "Preparing...")
    j:_onTransition({ status = "PortalReady", spawnMode = "Portal" })
    assert(j.text == nil)
    j:_onTransition({ status = "EnterBattle", spawnMode = "RandomBattleSpawn" })
    assert(j.text == nil)
end)

return HttpService:JSONEncode({ passed = #passed, checks = passed, mode = "isolated Edit-context tests; no Playtest" })
