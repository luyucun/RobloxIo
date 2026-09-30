-- Progression regressions: execute in Studio EDIT context only.
-- Loads isolated copies of actual modules; never calls Init or a real DataStore.
-- Local runner may inject sourceOverrides to exercise unsynced repository sources.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local HttpService = game:GetService("HttpService")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local passed, failed, warnings = {}, {}, {}
local clockNow = 100
local function forbidden()
    error("Regression fixture attempted an external side effect")
end
local fakeActors = {
    IsPlayer = function(actor) return type(actor) == "table" and actor.kind == "player" end,
    IsBot = function() return false end,
    GetActorId = function(actor) return actor.UserId end,
    GetActorKind = function() return "Player" end,
    GetCombatUserId = function(actor) return actor.UserId end,
    GetRootPart = function() return nil end,
    GetHumanoid = function() return nil end,
    GetCharacter = function() return nil end,
}
local isolated = {}
local fakeGame = {}
function fakeGame:GetService(name)
    if name == "Players" then
        return { GetPlayers = function() return {} end, GetPlayerByUserId = function() return nil end }
    elseif name == "DataStoreService" or name == "MarketplaceService" then
        return setmetatable({}, { __index = function() return forbidden end })
    end
    return game:GetService(name)
end
local loadIsolated
loadIsolated = function(instance)
    if instance.Name == "ActorUtils" then return fakeActors end
    if isolated[instance] ~= nil then return isolated[instance] end
    local source = sourceOverrides and sourceOverrides[instance.Name] or instance.Source
    local chunk, compileError = loadstring(source, "=" .. instance.Name)
    assert(chunk, compileError)
    setfenv(chunk, setmetatable({
        script = instance,
        game = fakeGame,
        Instance = { new = forbidden },
        task = { spawn = forbidden, defer = forbidden, delay = forbidden, wait = forbidden },
        os = setmetatable({ clock = function() return clockNow end }, { __index = os }),
        require = loadIsolated,
        warn = function(message) table.insert(warnings, tostring(message)) end,
    }, { __index = getfenv() }))
    isolated[instance] = chunk()
    return isolated[instance]
end
local AttributeConfig = loadIsolated(game.ReplicatedStorage.Shared.AttributeConfig)
local GameConfig = loadIsolated(game.ReplicatedStorage.Shared.GameConfig)
local PlayerState = loadIsolated(game.ServerScriptService.Services.PlayerStateService)
local Rebirth = loadIsolated(game.ServerScriptService.Services.RebirthService)
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function close(actual, expected, label)
    assert(math.abs(actual - expected) < 0.000001, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local expectedWarningTextByTest = {
    ["Mutation error releases request lock and permits a later valid request"] = "fixture apply failure",
    ["Failed store write keeps dirty progress and releases the request lock"] = "[RebirthService] 保存 Rebirth 数据失败: RegressionPlayer",
    ["Unexpected save exception after paid grant cannot demand another grant"] = "fixture unexpected persistence failure",
    ["State notification exception after a paid grant preserves exactly one grant"] = "fixture state notification failure",
}
local function test(name, callback)
    clockNow += 10
    local firstWarningIndex = #warnings + 1
    local ok, failure = pcall(function()
        callback()
        local expectedWarningText = expectedWarningTextByTest[name]
        local expectedCount = expectedWarningText and 1 or 0
        local actualCount = #warnings - firstWarningIndex + 1
        equal(actualCount, expectedCount, "unexpected warning count for " .. name)
        if expectedWarningText then
            assert(string.find(warnings[firstWarningIndex], expectedWarningText, 1, true),
                "Unexpected warning: " .. tostring(warnings[firstWarningIndex]))
        end
    end)
    if ok then
        table.insert(passed, name)
    else
        table.insert(failed, { name = name, error = tostring(failure) })
    end
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function cloneService(module)
    local result = table.clone(module)
    for key, value in pairs(result) do
        if type(value) == "table" and string.sub(key, 1, 1) == "_" then result[key] = {} end
    end
    return result
end
local function fixture(score)
    local f = { player = { kind = "player", UserId = 17001, Name = "RegressionPlayer", Parent = true }, feedback = {}, saves = 0, pushes = 0 }
    local ps = cloneService(PlayerState)
    f.ps = ps
    ps._syncLeaderstats = function() end
    ps.SyncHumanoidMovement = function() end
    ps.SyncCharacterState = function() end
    ps.UpdateOverheadHealthBar = function() end
    ps.CheckTitleUnlocks = function() end
    ps.RefreshOnlineTime = function() end
    ps.PushState = function() f.pushes += 1 end
    f.state = ps:_createDefaultState(f.player)
    ps._statesByActorId[f.player.UserId] = f.state
    f.state.RebirthScore = score or 0
    local r = cloneService(Rebirth)
    f.rebirth = r
    r._playerStateService = ps
    -- This ledger is normally allocated in Init, which isolated tests must not call.
    r._processedPurchaseIdsByPlayerId = {}
    r._loadStateByUserId[f.player.UserId] = "Loaded"
    ps._rebirthService = r
    r._rebirthFeedbackEvent = { FireClient = function(_, _, payload) table.insert(f.feedback, payload) end }
    r._dataStore = {
        GetAsync = function() return copy(f.savedInput) end,
        SetAsync = function(_, _, payload)
            f.saves += 1
            if f.onSave then f.onSave(payload) end
            f.savedOutput = copy(payload)
        end,
    }
    return f
end
local function setBlade(f, level, cap, points)
    f.state.AttributeLevels.BladeRecovery = level
    f.state.AttributeCaps.BladeRecovery = cap
    f.state.SkillPoints = points or 0
    f.state.Alive, f.state.IsInArena = true, true
end

test("Blade Recovery cap is 30; original caps remain 40 and Flash caps are 10", function()
    equal(AttributeConfig.GetMaxCap("BladeRecovery"), 30)
    for _, key in ipairs(AttributeConfig.Order) do
        if key == "FlashCooldown" or key == "FlashDistance" then
            equal(AttributeConfig.GetMaxCap(key), 10, key)
        elseif key ~= "BladeRecovery" then
            equal(AttributeConfig.GetMaxCap(key), 40, key)
        end
    end
end)

test("Blade Recovery level 29 upgrades to 30 and reaches six seconds", function()
    local f = fixture()
    setBlade(f, 29, 30, 2)
    f.ps:_normalizeAttributeState(f.state)
    close(f.state.FinalStats.BladeRecoverySeconds, 6.2)
    assert(f.ps:TryUpgradeAttribute(f.player, "BladeRecovery"))
    equal(f.state.AttributeLevels.BladeRecovery, 30)
    equal(f.state.SkillPoints, 1)
    close(f.state.FinalStats.BladeRecoverySeconds, 6)
    local ok, reason = f.ps:TryUpgradeAttribute(f.player, "BladeRecovery")
    equal(ok, false)
    equal(reason, "MaxLevel")
    equal(f.state.SkillPoints, 1, "rejected upgrade keeps points")
end)

test("Cap 29 upgrades once to 30; cap 30 consumes no more diamonds", function()
    local f = fixture()
    setBlade(f, 0, 29, 2)
    f.state.Diamonds = 50000
    local cost = AttributeConfig.GetCapUpgradeGemCost("BladeRecovery", 29)
    assert(f.ps:TryUpgradeAttributeCapWithDiamonds(f.player, "BladeRecovery"))
    equal(f.state.AttributeCaps.BladeRecovery, 30)
    equal(f.state.Diamonds, 50000 - cost)
    local ok, reason = f.ps:TryUpgradeAttributeCapWithDiamonds(f.player, "BladeRecovery")
    equal(ok, false)
    equal(reason, "MaxLevel")
    equal(f.state.Diamonds, 50000 - cost)
end)

test("Max cap reports IsMax and offers no further price or product", function()
    local info = AttributeConfig.GetCapUpgradeInfo("BladeRecovery", 30)
    assert(info and info.IsMax)
    equal(info.NextCap, 30)
    equal(info.GemCost, nil)
    equal(info.ProductId, nil)
    equal(AttributeConfig.GetCapUpgradeProduct("BladeRecovery", 30), nil)
    assert(AttributeConfig.GetCapUpgradeProduct("BladeSpeed", 30), "other attribute may still buy cap 31")
end)

test("Old level 40 refunds ten points once and archives its old cap", function()
    local f = fixture()
    setBlade(f, 40, 40, 3)
    f.state.AttributeCaps.BladeSpeed = 40
    f.state.AttributeLevels.BladeSpeed = 5
    f.ps:_normalizeAttributeState(f.state)
    equal(f.state.AttributeLevels.BladeRecovery, 30)
    equal(f.state.AttributeCaps.BladeRecovery, 30)
    equal(f.state.LegacyBladeRecoveryCap, 40)
    equal(f.state.SkillPoints, 13)
    equal(f.state.UsedSkillPoints, 35)
    for _ = 1, 5 do f.ps:BuildAttributeStatePayload(f.player) end
    equal(f.state.SkillPoints, 13, "normalization is idempotent")
    equal(f.state.AttributeLevels.BladeSpeed, 5)
end)

test("Owned cap 40 with level 20 archives history without inventing points", function()
    local f = fixture()
    setBlade(f, 20, 40, 3)
    f.ps:_normalizeAttributeState(f.state)
    equal(f.state.AttributeCaps.BladeRecovery, 30)
    equal(f.state.LegacyBladeRecoveryCap, 40)
    equal(f.state.AttributeLevels.BladeRecovery, 20)
    equal(f.state.SkillPoints, 3)
end)

test("Old death snapshot restores level 30 and returns its ten allocated points", function()
    local f = fixture()
    local snapshot = {
        preDeathLevel = 40, preDeathExperience = 0, preDeathKillCount = 2,
        attributeSnapshot = {
            skillPoints = 3, attributeLevels = { BladeRecovery = 40 },
            attributeCaps = { BladeRecovery = 40 }, masteryPoints = 7,
        },
    }
    assert(f.ps:RestoreCombatProgress(f.player, snapshot, { restoreToLobby = true, rebuildWeapons = false }))
    equal(f.state.AttributeLevels.BladeRecovery, 30)
    equal(f.state.SkillPoints, 13)
    equal(f.state.MasteryPoints, 7)
    equal(f.state.LegacyBladeRecoveryCap, 40)
    assert(f.ps:RestoreCombatProgress(f.player, snapshot, { restoreToLobby = true, rebuildWeapons = false }))
    equal(f.state.SkillPoints, 13, "reapplying a snapshot replaces rather than accumulates points")
end)

test("Legacy caps survive load and save without creating currency compensation", function()
    local f = fixture()
    f.savedInput = {
        Rebirth = 2, RebirthScore = 777, HighestLevelReached = 40,
        Diamonds = 4321, WheelSpins = 6, AttributeCaps = { BladeRecovery = 40, BladeSpeed = 35 },
        OwnedSkins = { ["10009"] = true },
    }
    f.rebirth._loadStateByUserId[f.player.UserId] = nil
    f.rebirth:_loadPlayer(f.player)
    equal(f.state.LegacyBladeRecoveryCap, 40)
    equal(f.state.AttributeCaps.BladeRecovery, 30)
    equal(f.state.AttributeCaps.BladeSpeed, 35)
    equal(f.state.Diamonds, 4321)
    equal(f.state.WheelSpins, 6)
    equal(f.state.RebirthScore, 777)
    equal(f.state.OwnedSkins["10009"], true)
    assert(f.rebirth:_savePlayer(f.player))
    equal(f.savedOutput.legacyBladeRecoveryCap, 40)
    equal(f.savedOutput.attributeCaps.BladeRecovery, 30)
    equal(f.rebirth._savedProgressCacheByUserId[f.player.UserId].snapshot.savedProgress.legacyBladeRecoveryCap, 40)
    local nextFixture = fixture()
    nextFixture.savedInput = f.savedOutput
    nextFixture.rebirth._loadStateByUserId[nextFixture.player.UserId] = nil
    nextFixture.rebirth:_loadPlayer(nextFixture.player)
    equal(nextFixture.state.LegacyBladeRecoveryCap, 40)
    equal(nextFixture.state.AttributeCaps.BladeRecovery, 30)
    equal(nextFixture.state.Diamonds, 4321)
end)

test("New progress does not claim a historical cap", function()
    local f = fixture()
    equal(tonumber(f.state.LegacyBladeRecoveryCap) or 0, 0)
    f.ps:_normalizeAttributeState(f.state)
    equal(tonumber(f.state.LegacyBladeRecoveryCap) or 0, 0)
    equal(f.state.SkillPoints, 0)
end)

test("Insufficient score rejects both the direct mutation and free request", function()
    local f = fixture(1499)
    local result = f.ps:ApplyRebirth(f.player, true)
    assert(not result)
    equal(f.state.Rebirth, 0)
    equal(f.state.RebirthScore, 1499)
    equal(f.pushes, 0)
    equal(f.rebirth:TryRebirth(f.player), false)
    equal(f.saves, 0)
end)

test("Exactly 1500 score buys one rebirth and leaves zero", function()
    local f = fixture(1500)
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 0)
    equal(f.savedOutput.rebirthScore, 0)
    equal(f.saves, 1)
end)

test("2000 score retains 500 and raises the next requirement to 2010", function()
    local f = fixture(2000)
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 500)
    equal(GameConfig.GetRequiredRebirthScore(f.state.Rebirth), 2010)
    equal(f.savedOutput.rebirthScore, 500)
    equal(f.rebirth:TryRebirth(f.player), false)
    equal(f.state.RebirthScore, 500)
    equal(f.saves, 1)
end)

test("Consecutive affordable rebirths use each current requirement", function()
    local f = fixture(4000)
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.RebirthScore, 2500)
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.Rebirth, 2)
    equal(f.state.RebirthScore, 490)
    equal(f.rebirth:TryRebirth(f.player), false)
    equal(f.saves, 2)
end)

test("Paid rebirth preserves score even below the free requirement", function()
    local f = fixture(123)
    assert(f.rebirth:TryRebirth(f.player, { paid = true }))
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 123)
    equal(f.savedOutput.rebirthScore, 123)
end)

test("Requests while data is loading cannot mutate score or grant paid rebirth", function()
    local f = fixture(4000)
    f.rebirth._loadStateByUserId[f.player.UserId] = "Pending"
    equal(f.rebirth:TryRebirth(f.player), false)
    equal(f.rebirth:TryRebirth(f.player, { paid = true }), false)
    equal(f.state.Rebirth, 0)
    equal(f.state.RebirthScore, 4000)
    equal(f.saves, 0)
end)

test("Reentrant request during persistence is refused despite sufficient remainder", function()
    local f = fixture(10000)
    local nestedResult
    f.onSave = function()
        if nestedResult == nil then
            nestedResult = "entered"
            nestedResult = f.rebirth:TryRebirth(f.player)
        end
    end
    assert(f.rebirth:TryRebirth(f.player))
    equal(nestedResult, false)
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 8500)
    equal(f.saves, 1)
    assert(not f.rebirth._rebirthInProgressByUserId[f.player.UserId])
    f.onSave = nil
    assert(f.rebirth:TryRebirth(f.player), "lock releases after persistence")
    equal(f.state.Rebirth, 2)
    equal(f.state.RebirthScore, 6490)
end)

test("Mutation error releases request lock and permits a later valid request", function()
    local f = fixture(2000)
    local apply = f.ps.ApplyRebirth
    f.ps.ApplyRebirth = function() error("fixture apply failure") end
    local callOk, result = pcall(function() return f.rebirth:TryRebirth(f.player) end)
    equal(callOk, true, "request contains the exception")
    equal(result, false)
    assert(not f.rebirth._rebirthInProgressByUserId[f.player.UserId])
    equal(f.state.Rebirth, 0)
    equal(f.state.RebirthScore, 2000)
    f.ps.ApplyRebirth = apply
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.RebirthScore, 500)
end)

test("Failed store write keeps dirty progress and releases the request lock", function()
    local f = fixture(4000)
    f.onSave = function() error("fixture store failure") end
    assert(f.rebirth:TryRebirth(f.player), "already applied grant remains successful")
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 2500)
    equal(f.rebirth._dirtyByUserId[f.player.UserId], true)
    assert(not f.rebirth._rebirthInProgressByUserId[f.player.UserId])
    f.onSave = nil
    assert(f.rebirth:TryRebirth(f.player))
    equal(f.state.Rebirth, 2)
    equal(f.state.RebirthScore, 490)
end)

test("Unexpected save exception after paid grant cannot demand another grant", function()
    local f = fixture(123)
    local save = f.rebirth._savePlayer
    f.rebirth._savePlayer = function() error("fixture unexpected persistence failure") end
    local callOk, result = pcall(function() return f.rebirth:TryRebirth(f.player, { paid = true }) end)
    equal(callOk, true)
    equal(result, true, "paid grant is already applied")
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 123)
    equal(f.rebirth._dirtyByUserId[f.player.UserId], true)
    assert(not f.rebirth._rebirthInProgressByUserId[f.player.UserId])
    f.rebirth._savePlayer = save
    assert(f.rebirth:_savePlayer(f.player))
    equal(f.savedOutput.rebirth, 1)
    equal(f.savedOutput.rebirthScore, 123)
end)

test("State notification exception after a paid grant preserves exactly one grant", function()
    local f = fixture(123)
    local notificationAttempts = 0
    f.ps.PushState = function()
        notificationAttempts += 1
        equal(f.state.Rebirth, 1, "authority commits before notification")
        equal(f.rebirth._dirtyByUserId[f.player.UserId], true, "commit is dirty before notification")
        error("fixture state notification failure")
    end
    local callOk, result = pcall(function() return f.rebirth:TryRebirth(f.player, { paid = true }) end)
    equal(callOk, true)
    equal(result, true)
    equal(notificationAttempts, 1)
    equal(f.state.Rebirth, 1)
    equal(f.state.RebirthScore, 123)
    equal(f.savedOutput.rebirth, 1)
    assert(not f.rebirth._rebirthInProgressByUserId[f.player.UserId])
end)

return HttpService:JSONEncode({ passed = #passed, failed = #failed, tests = passed, failures = failed, expectedWarnings = warnings })
