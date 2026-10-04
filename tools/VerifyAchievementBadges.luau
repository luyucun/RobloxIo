-- V6.17 achievement regressions. Studio Edit context, isolated source only.
-- No real BadgeService, DataStore, Player or production service is used.
-- A local runner can replace sourceOverrides to verify unsynced repository code.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local HttpService = game:GetService("HttpService")
local actualTypeof = typeof
local services = game:GetService("ServerScriptService"):WaitForChild("Services")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local passed, failed, warnings = {}, {}, {}

local function forbidden()
    error("Achievement fixture attempted an external side effect")
end
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function count(values)
    local result = 0
    for _ in pairs(values) do result += 1 end
    return result
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
local fakeActors = {
    IsPlayer = function(actor) return type(actor) == "table" and actor.kind == "player" end,
    IsBot = function(actor) return type(actor) == "table" and actor.IsBot == true end,
    GetActorId = function(actor) return tostring(actor.kind) .. ":" .. tostring(actor.UserId) end,
    GetActorKind = function(actor) return actor.kind == "player" and "Player" or "Bot" end,
    GetCombatUserId = function(actor) return actor.UserId end,
    GetRootPart = function() return nil end,
    GetHumanoid = function() return nil end,
    GetCharacter = function() return nil end,
    IsSameActor = function(left, right) return left == right end,
}

-- Controlled coroutines reproduce API yields and task retries without wall-clock waits.
local function scheduler()
    local s = { now = 100, queue = {}, cancelled = {} }
    function s:resume(thread, ...)
        if self.cancelled[thread] or coroutine.status(thread) == "dead" then return end
        local ok, marker, seconds = coroutine.resume(thread, ...)
        assert(ok, tostring(marker))
        if coroutine.status(thread) ~= "dead" and marker == "fixture-wait" then
            table.insert(self.queue, { at = self.now + seconds, thread = thread })
        end
    end
    function s:runAll()
        local iterations = 0
        while #self.queue > 0 do
            iterations += 1
            assert(iterations <= 100, "Retry queue did not terminate")
            table.sort(self.queue, function(left, right) return left.at < right.at end)
            local entry = table.remove(self.queue, 1)
            self.now = math.max(self.now, entry.at)
            self:resume(entry.thread, table.unpack(entry.args or {}))
        end
    end
    s.task = {
        spawn = function(callback, ...)
            local thread = type(callback) == "thread" and callback or coroutine.create(callback)
            s:resume(thread, ...)
            return thread
        end,
        delay = function(seconds, callback, ...)
            local thread = coroutine.create(callback)
            table.insert(s.queue, { at = s.now + seconds, thread = thread, args = { ... } })
            return thread
        end,
        defer = function(callback, ...)
            local thread = coroutine.create(callback)
            table.insert(s.queue, { at = s.now, thread = thread, args = { ... } })
            return thread
        end,
        wait = function(seconds)
            return coroutine.yield("fixture-wait", math.max(0.001, tonumber(seconds) or 0.01))
        end,
        cancel = function(thread) s.cancelled[thread] = true end,
    }
    return s
end

local function fixture()
    local f = { scheduler = scheduler(), activePlayers = {}, checks = {}, awards = {}, infos = {}, loaded = true, dirty = 0 }
    local fakePlayers = {}
    function fakePlayers:GetPlayerByUserId(userId) return f.activePlayers[userId] end
    function fakePlayers:GetPlayers()
        local result = {}
        for _, player in pairs(f.activePlayers) do table.insert(result, player) end
        return result
    end
    f.players = fakePlayers
    function f:newPlayer(userId)
        local player = { kind = "player", UserId = userId or 17001, Name = "AchievementFixture", Parent = fakePlayers }
        player.IsA = function(_, className) return className == "Player" end
        self.activePlayers[player.UserId] = player
        return player
    end
    f.player = f:newPlayer()
    local badgeApi = {}
    function badgeApi:UserHasBadgeAsync(userId, badgeId)
        table.insert(f.checks, { userId = userId, badgeId = badgeId })
        if f.onCheck then return f.onCheck(userId, badgeId, #f.checks) end
        return false
    end
    function badgeApi:AwardBadgeAsync(userId, badgeId)
        table.insert(f.awards, { userId = userId, badgeId = badgeId })
        if f.onAward then return f.onAward(userId, badgeId, #f.awards) end
        return true
    end
    function badgeApi:GetBadgeInfoAsync(badgeId)
        table.insert(f.infos, badgeId)
        if f.onInfo then return f.onInfo(badgeId) end
        return { IsEnabled = true, Name = "Fixture Badge" }
    end
    local isolated = {}
    local fakeGame = setmetatable({ GameId = 10133052560, PlaceId = 73988417166286 }, { __index = game })
    function fakeGame:GetService(name)
        if name == "BadgeService" then return badgeApi end
        if name == "Players" then return fakePlayers end
        if name == "DataStoreService" or name == "MarketplaceService" or name == "PhysicsService" then
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
            task = f.scheduler.task,
            os = setmetatable({ clock = function() return f.scheduler.now end }, { __index = os }),
            typeof = function(value)
                if fakeActors.IsPlayer(value) then return "Instance" end
                return actualTypeof(value)
            end,
            require = loadIsolated,
            warn = function(message) table.insert(warnings, tostring(message)) end,
        }, { __index = getfenv() }))
        isolated[instance] = chunk()
        return isolated[instance]
    end
    f.config = loadIsolated(shared.BadgeConfig)
    f.badges = cloneService(loadIsolated(services.BadgeAwardService))
    f.ps = cloneService(loadIsolated(services.PlayerStateService))
    f.rebirth = cloneService(loadIsolated(services.RebirthService))
    f.monsters = cloneService(loadIsolated(services.MonsterService))
    f.ps._syncLeaderstats = function() end
    f.ps.SyncHumanoidMovement = function() end
    f.ps.SyncCharacterState = function() end
    f.ps.UpdateOverheadHealthBar = function() end
    f.ps.CheckTitleUnlocks = function() end
    f.ps.RefreshOnlineTime = function() end
    f.ps.PushState = function() end
    f.rebirth._playerStateService = f.ps
    f.rebirth._processedPurchaseIdsByPlayerId = {}
    f.rebirth.IsPlayerLoaded = function() return f.loaded end
    f.rebirth.CanWritePersistentProgress = function() return f.loaded end
    f.rebirth.MarkDirty = function() f.dirty += 1 end
    f.ps._rebirthService = f.rebirth
    f.ps._badgeAwardService = f.badges
    f.badges._playerStateService = f.ps
    f.badges._rebirthService = f.rebirth
    f.rebirth._badgeAwardService = f.badges
    f.monsters._playerStateService = f.ps
    f.state = f.ps:_createDefaultState(f.player)
    f.ps._statesByActorId[fakeActors.GetActorId(f.player)] = f.state
    f.rebirth._loadStateByUserId[f.player.UserId] = "Loaded"
    f.badges:Init()
    f.badges:BindSystems({ PlayerStateService = f.ps, RebirthService = f.rebirth })
    f.game = fakeGame
    f.modules = isolated
    return f
end

local function test(name, callback)
    local ok, failure = pcall(callback)
    if ok then
        table.insert(passed, name)
    else
        table.insert(failed, { name = name, error = tostring(failure) })
    end
end
local function awardsByKey(f)
    local result = {}
    for _, award in ipairs(f.awards) do
        local badge = f.config.GetBadge(award.badgeId)
        assert(badge, "Award attempted an unknown badge ID")
        result[badge.Key] = (result[badge.Key] or 0) + 1
    end
    return result
end

-- Tests below exercise real isolated module entry points; the fixture only suppresses
-- unrelated UI/character notifications and substitutes external dependencies.

test("Exactly eight English achievements are configured; subscription badge is removed", function()
    local f = fixture()
    local expected = {
        NewPlayerWelcome = "Welcome, Warrior!", BladeCircle = "Blade Circle", FirstVictory = "First Victory",
        BossSlayer = "Boss Slayer", Reborn = "Reborn", Level100Warrior = "Level 100 Warrior",
        EyeOfTheAbyss = "Eye of the Abyss", LimitBreaker = "Limit Breaker",
    }
    equal(count(f.config.GetAllBadges()), 8)
    local ids = {}
    for key, name in pairs(expected) do
        local badge = f.config.GetBadge(key)
        assert(badge, "Missing " .. key)
        equal(badge.Name, name, key)
        assert(badge.Id > 0 and badge.Id % 1 == 0 and not ids[badge.Id], "IDs must be unique positive integers")
        ids[badge.Id] = true
    end
    equal(f.config.GetBadge("FirstSubscription"), nil)
end)

test("Level boundaries award at 10, 100, 391 and 610, never one level early", function()
    for _, row in ipairs({
        { 9, 0 }, { 10, 1 }, { 99, 1 }, { 100, 2 }, { 390, 2 }, { 391, 3 }, { 609, 3 }, { 610, 4 },
    }) do
        local f = fixture()
        f.state.HighestLevelReached = row[1]
        f.badges:CheckProgress(f.player, "Boundary")
        f.scheduler:runAll()
        equal(#f.awards, row[2] + 1, "Award count at Lv." .. row[1])
        equal(awardsByKey(f).NewPlayerWelcome, 1)
    end
end)

test("Historical highest level awards all skipped milestones despite current Lv.1", function()
    local f = fixture()
    f.state.Level, f.state.HighestLevelReached = 1, 610
    f.badges:CheckProgress(f.player, "HistoricalProgress")
    f.scheduler:runAll()
    local keys = awardsByKey(f)
    for _, key in ipairs({ "NewPlayerWelcome", "BladeCircle", "Level100Warrior", "EyeOfTheAbyss", "LimitBreaker" }) do
        equal(keys[key], 1, key)
    end
    equal(#f.awards, 5)
end)

test("One authoritative experience grant crossing every level threshold awards every milestone", function()
    local f = fixture()
    f.ps:AddAuthorizedExperience(f.player, 1000000000)
    f.scheduler:runAll()
    equal(f.state.Level, 610)
    equal(f.state.HighestLevelReached, 610)
    local keys = awardsByKey(f)
    for _, key in ipairs({ "BladeCircle", "Level100Warrior", "EyeOfTheAbyss", "LimitBreaker" }) do
        equal(keys[key], 1, key)
    end
    equal(#f.awards, 5)
end)

test("Pending data loading blocks awards; loaded progress catches up all eight", function()
    local f = fixture()
    f.loaded = false
    f.state.HighestLevelReached, f.state.TotalPlayerKills, f.state.Rebirth, f.state.FirstBossDefeated = 610, 1, 1, true
    f.badges:CheckProgress(f.player, "BeforeLoad")
    f.scheduler:runAll()
    equal(#f.checks, 0)
    equal(#f.awards, 0)
    f.loaded = true
    f.badges:CheckProgress(f.player, "AfterLoad")
    f.scheduler:runAll()
    equal(#f.awards, 8)
end)

test("Successful award is cached and repeated checks never award or query it twice", function()
    local f = fixture()
    for _ = 1, 100 do
        local ok = f.badges:AwardBadge(f.player, "BladeCircle", "Repeated")
        equal(ok, true)
    end
    equal(#f.checks, 1)
    equal(#f.awards, 1)
end)

test("Official ownership true skips award and caches positive ownership", function()
    local f = fixture()
    f.onCheck = function() return true end
    for _ = 1, 5 do equal(f.badges:AwardBadge(f.player, "BladeCircle", "Owned"), true) end
    equal(#f.checks, 1)
    equal(#f.awards, 0)
end)

test("Award API false is a failure and a later successful attempt still awards", function()
    local f = fixture()
    f.onAward = function(_, _, index) return index ~= 1 end
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "FalseResult"), false)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Retry"), true)
    equal(#f.awards, 2)
end)

test("Award API exception does not poison ownership cache or leave an in-flight lock", function()
    local f = fixture()
    f.onAward = function(_, _, index)
        if index == 1 then error("fixture award exception") end
        return true
    end
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Exception"), false)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Retry"), true)
    equal(#f.awards, 2)
end)

test("Ownership API exception prevents award and a later check can recover", function()
    local f = fixture()
    f.onCheck = function(_, _, index)
        if index == 1 then error("fixture check exception") end
        return false
    end
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "CheckException"), false)
    equal(#f.awards, 0)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Retry"), true)
    equal(#f.awards, 1)
end)

test("Unknown badge and Bot callers make no official API requests", function()
    local f = fixture()
    equal(f.badges:AwardBadge(f.player, "FirstSubscription", "Removed"), false)
    equal(f.badges:AwardBadge({ kind = "bot", IsBot = true, UserId = 17002, Parent = true }, "BladeCircle", "Bot"), false)
    equal(#f.checks, 0)
    equal(#f.awards, 0)
end)

test("Wrong Universe and disabled badges never issue an award", function()
    local wrongUniverse = fixture()
    wrongUniverse.game.GameId = 1
    equal(wrongUniverse.badges:AwardBadge(wrongUniverse.player, "BladeCircle", "WrongUniverse"), false)
    equal(#wrongUniverse.awards, 0)
    local disabled = fixture()
    disabled.onInfo = function() return { IsEnabled = false } end
    equal(disabled.badges:AwardBadge(disabled.player, "BladeCircle", "Disabled"), false)
    equal(#disabled.awards, 0)
end)

test("Metadata API exception releases its lock and permits a later award", function()
    local f = fixture()
    local attempts = 0
    f.onInfo = function()
        attempts += 1
        if attempts == 1 then error("fixture metadata exception") end
        return { IsEnabled = true }
    end
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "MetadataException"), false)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Retry"), true)
    equal(#f.awards, 1)
end)

test("Same badge concurrency is blocked while another badge remains independent", function()
    local f = fixture()
    local bladeId = f.config.GetBadgeId("BladeCircle")
    local firstResult
    f.onCheck = function(_, id)
        if id == bladeId then coroutine.yield("fixture-held") end
        return false
    end
    local thread = coroutine.create(function() firstResult = f.badges:AwardBadge(f.player, "BladeCircle", "Held") end)
    f.scheduler:resume(thread)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Concurrent"), false)
    equal(f.badges:AwardBadge(f.player, "FirstVictory", "Independent"), true)
    f.scheduler:resume(thread)
    equal(firstResult, true)
    equal(#f.checks, 2)
    equal(#f.awards, 2)
end)

test("Async API false retries a bounded number of times and succeeds without duplicate grants", function()
    local f = fixture()
    f.onAward = function(_, _, index) return index >= 3 end
    f.badges:AwardBadgeAsync(f.player, "BladeCircle", "RetrySuccess")
    f.scheduler:runAll()
    equal(#f.awards, 3)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "Cached"), true)
    equal(#f.awards, 3)
end)

test("Async persistent failure exhausts retries, preserves eligibility and permits next-session replay", function()
    local f = fixture()
    f.onAward = function() return false end
    f.badges:AwardBadgeAsync(f.player, "BladeCircle", "RetryExhaustion")
    f.scheduler:runAll()
    equal(#f.awards, 3)
    f.badges:OnPlayerRemoving(f.player)
    f.player.Parent = nil
    f.player = f:newPlayer(17001)
    f.onAward = nil
    f.badges:AwardBadgeAsync(f.player, "BladeCircle", "NextSession")
    f.scheduler:runAll()
    equal(#f.awards, 4)
end)

test("API yield then departure prevents a late ownership result from awarding", function()
    local f = fixture()
    local result
    f.onCheck = function() coroutine.yield("fixture-held"); return false end
    local thread = coroutine.create(function() result = f.badges:AwardBadge(f.player, "BladeCircle", "Departure") end)
    f.scheduler:resume(thread)
    f.badges:OnPlayerRemoving(f.player)
    f.activePlayers[f.player.UserId] = nil
    f.player.Parent = nil
    f.scheduler:resume(thread)
    equal(result, false)
    equal(#f.awards, 0)
end)

test("Old yielded completion cannot clear a replacement-session lock or populate its cache", function()
    local f = fixture()
    local oldPlayer = f.player
    f.onCheck = function() coroutine.yield("fixture-held"); return false end
    local oldResult, newResult
    local oldThread = coroutine.create(function() oldResult = f.badges:AwardBadge(oldPlayer, "BladeCircle", "OldSession") end)
    f.scheduler:resume(oldThread)
    f.badges:OnPlayerRemoving(oldPlayer)
    oldPlayer.Parent = nil
    f.player = f:newPlayer(oldPlayer.UserId)
    local newThread = coroutine.create(function() newResult = f.badges:AwardBadge(f.player, "BladeCircle", "NewSession") end)
    f.scheduler:resume(newThread)
    f.scheduler:resume(oldThread)
    equal(oldResult, false)
    equal(f.badges:AwardBadge(f.player, "BladeCircle", "MustRemainBusy"), false)
    equal(#f.checks, 2, "Old completion released new lock")
    f.scheduler:resume(newThread)
    equal(newResult, true)
    equal(#f.awards, 1)
end)

test("PlayerRemoving blocks session recreation before hierarchy cleanup while a new instance can award", function()
    local f = fixture()
    local oldPlayer, heldThread = f.player, nil
    f.onCheck = function()
        heldThread = coroutine.running()
        coroutine.yield("fixture-held")
        return false
    end
    f.badges:AwardBadgeAsync(oldPlayer, "BladeCircle", "RemovingHeld")
    assert(heldThread, "Ownership API was not reached")
    f.badges:OnPlayerRemoving(oldPlayer)
    -- Roblox's removal callback can yield before Parent and the Players lookup change.
    equal(oldPlayer.Parent, f.players)
    equal(f.players:GetPlayerByUserId(oldPlayer.UserId), oldPlayer)
    equal(f.badges:AwardBadgeAsync(oldPlayer, "BladeCircle", "MustNotRecreate"), false)
    equal(f.badges:CheckProgress(oldPlayer, "MustNotReplay"), false)
    equal(#f.checks, 1, "Removing instance recreated a badge session")
    f.scheduler:resume(heldThread)
    f.scheduler:runAll()
    equal(#f.awards, 0, "Old request awarded during removal")
    f.player = f:newPlayer(oldPlayer.UserId)
    f.onCheck = nil
    equal(f.badges:AwardBadgeAsync(f.player, "BladeCircle", "ReplacementPlayer"), true)
    f.scheduler:runAll()
    equal(#f.awards, 1, "Removal guard blocked the replacement Player instance")
end)

test("Award API false after yield cannot continue retries for a departed session", function()
    local f = fixture()
    local heldThread
    f.onAward = function()
        heldThread = coroutine.running()
        coroutine.yield("fixture-held")
        return false
    end
    f.badges:AwardBadgeAsync(f.player, "BladeCircle", "HeldFalse")
    assert(heldThread, "Award API was not reached")
    f.badges:OnPlayerRemoving(f.player)
    f.activePlayers[f.player.UserId] = nil
    f.player.Parent = nil
    f.scheduler:resume(heldThread)
    f.scheduler:runAll()
    equal(#f.awards, 1)
end)

test("Init invalidates delayed retries from the previous service generation", function()
    local f = fixture()
    f.onAward = function() return false end
    f.badges:AwardBadgeAsync(f.player, "BladeCircle", "OldGeneration")
    equal(#f.awards, 1)
    f.badges:Init()
    f.scheduler:runAll()
    equal(#f.awards, 1)
end)

test("FirstVictory excludes Bot opponents and self kills; real PvP awards once", function()
    local f = fixture()
    local target = f:newPlayer(17002)
    local bot = { kind = "bot", IsBot = true, UserId = -1, Parent = true }
    equal(f.ps:AwardPlayerKillReward(f.player, bot), false)
    equal(f.ps:AwardPlayerKillReward(f.player, f.player), false)
    equal(f.state.TotalPlayerKills, 0)
    equal(#f.awards, 0)
    equal(f.ps:AwardPlayerKillReward(f.player, target), true)
    f.scheduler:runAll()
    equal(f.state.TotalPlayerKills, 1)
    equal(awardsByKey(f).FirstVictory, 1)
    equal(f.ps:AwardPlayerKillReward(f.player, target), true)
    f.scheduler:runAll()
    equal(awardsByKey(f).FirstVictory, 1)
end)

test("Boss fact is recorded once, remains true after API failure, and is marked dirty", function()
    local f = fixture()
    f.onAward = function() return false end
    equal(f.state.FirstBossDefeated, false)
    f.ps:RecordBossDefeated(f.player)
    equal(f.state.FirstBossDefeated, true)
    local dirtyAfterFirst = f.dirty
    assert(dirtyAfterFirst > 0, "First Boss fact was not marked dirty")
    f.ps:RecordBossDefeated(f.player)
    equal(f.dirty, dirtyAfterFirst, "Duplicate Boss fact was marked dirty twice")
    f.scheduler:runAll()
    equal(f.state.FirstBossDefeated, true, "Failed official award cleared gameplay fact")
end)

test("Synchronous badge failure cannot roll back Boss facts or reject a committed rebirth", function()
    local f = fixture()
    f.badges.CheckProgress = function() error("fixture synchronous badge failure") end
    equal(f.ps:RecordBossDefeated(f.player), true)
    equal(f.state.FirstBossDefeated, true)
    assert(f.dirty > 0, "Boss fact was not marked dirty before notification failed")
    f.state.RebirthScore = 1000000
    local required = f.modules[shared.GameConfig].GetRequiredRebirthScore(0)
    local state = f.ps:ApplyRebirth(f.player, true)
    assert(state, "Badge failure changed an already committed rebirth into a failure")
    equal(state.Rebirth, 1)
    equal(state.RebirthScore, 1000000 - required)
    equal(#f.awards, 0)
end)

test("Ordinary Boss reward records BossSlayer, ordinary monsters and Bot kills do not", function()
    local f = fixture()
    local recorded = {}
    f.monsters._playerStateService = {
        AddRebirthScore = function() end,
        RecordBossDefeated = function(_, actor) table.insert(recorded, actor) end,
    }
    f.monsters:_awardMonsterRewards({ IsBoss = false, KillScoreReward = 1 }, f.player, nil)
    f.monsters:_awardMonsterRewards({ IsBoss = true, KillScoreReward = 1 }, f.player, nil)
    equal(#recorded, 1)
    equal(recorded[1], f.player)
    -- The PlayerState method also rejects Bot callers, independently of the death path.
    local bot = { kind = "bot", IsBot = true, UserId = -1 }
    f.ps:RecordBossDefeated(bot)
    equal(count(f.ps._statesByActorId), 1)
end)

test("Nuke Boss rewards never record BossSlayer, even with a forced human source", function()
    local f = fixture()
    f.monsters._playerStateService = {
        AddRebirthScore = function() end,
        RecordBossDefeated = function() error("Nuke Boss granted BossSlayer") end,
    }
    f.monsters:_awardMonsterRewards({ IsBoss = true, KillScoreReward = 300 }, f.player, nil, {
        forceSourceActor = f.player, authorizedExperienceReward = true, isNukeSweep = true,
    })
end)

test("Actual nuke sweep excludes BossSlayer while retaining Boss score settlement", function()
    local f = fixture()
    local score, destroyed = 0, 0
    f.monsters._playerStateService = {
        AddRebirthScore = function(_, actor, amount)
            equal(actor, f.player)
            score += amount
        end,
        RecordBossDefeated = function() error("Actual nuke path granted BossSlayer") end,
    }
    f.monsters._destroyMonster = function() destroyed += 1 end
    local runtime = { Parent = true, IsA = function() return false end }
    local boss = { Id = 1, IsBoss = true, Alive = true, RuntimeInstance = runtime, KillScoreReward = 300 }
    f.monsters._monstersById = { [1] = boss }
    equal(f.monsters:SweepForNuke(f.player, nil), 1)
    equal(score, 300)
    equal(destroyed, 1)
    equal(boss.Alive, false)
end)

test("Free and paid cultivation rebirth both satisfy Reborn", function()
    for _, consumeScore in ipairs({ true, false }) do
        local f = fixture()
        f.state.RebirthScore = 1000000
        local state = f.ps:ApplyRebirth(f.player, consumeScore)
        assert(state, "Cultivation rebirth failed")
        equal(state.Rebirth, 1)
        f.scheduler:runAll()
        equal(awardsByKey(f).Reborn, 1)
    end
end)

test("Stored Boss and real-player kill facts round-trip and old saves remain ineligible", function()
    local f = fixture()
    f.state.FirstBossDefeated, f.state.TotalPlayerKills = true, 7
    f.rebirth._dataStore = { SetAsync = forbidden }
    local payload = f.rebirth:_buildSavePayload(f.player)
    equal(payload.firstBossDefeated, true)
    equal(payload.totalPlayerKills, 7)
    local restored = fixture()
    restored.ps:SetRebirthData(restored.player, 0, 0, 1, payload)
    equal(restored.state.FirstBossDefeated, true)
    equal(restored.state.TotalPlayerKills, 7)
    local old = fixture()
    old.ps:SetRebirthData(old.player, 0, 0, 1, {})
    equal(old.state.FirstBossDefeated, false)
    equal(old.state.TotalPlayerKills, 0)
end)

test("Successful saved-data load awards all eligible badges only after Loaded", function()
    local f = fixture()
    f.rebirth.IsPlayerLoaded = f.modules[services.RebirthService].IsPlayerLoaded
    f.rebirth.CanWritePersistentProgress = f.modules[services.RebirthService].CanWritePersistentProgress
    f.rebirth._loadedByUserId, f.rebirth._loadStateByUserId = {}, {}
    f.rebirth._dataStore = {
        GetAsync = function()
            equal(#f.awards, 0, "Award happened before loaded data arrived")
            return { highestLevelReached = 610, totalPlayerKills = 4, rebirth = 1, firstBossDefeated = true }
        end,
        SetAsync = forbidden,
    }
    f.rebirth:_loadPlayer(f.player)
    f.scheduler:runAll()
    equal(f.rebirth._loadStateByUserId[f.player.UserId], "Loaded")
    equal(#f.awards, 8)
    equal(f.state.TotalPlayerKills, 4)
    equal(f.state.FirstBossDefeated, true)
end)

test("Failed saved-data read never awards Welcome or any provisional progress", function()
    local f = fixture()
    f.rebirth.IsPlayerLoaded = f.modules[services.RebirthService].IsPlayerLoaded
    f.rebirth.CanWritePersistentProgress = f.modules[services.RebirthService].CanWritePersistentProgress
    f.rebirth._loadedByUserId, f.rebirth._loadStateByUserId = {}, {}
    f.state.HighestLevelReached = 610
    f.rebirth._dataStore = { GetAsync = function() error("fixture load failure") end, SetAsync = forbidden }
    f.rebirth:_loadPlayer(f.player)
    f.scheduler:runAll()
    equal(f.rebirth._loadStateByUserId[f.player.UserId], "LoadFailed")
    equal(#f.awards, 0)
end)

test("A stale yielded data load cannot overwrite a replacement player's progress or award", function()
    local f = fixture()
    f.rebirth.IsPlayerLoaded = f.modules[services.RebirthService].IsPlayerLoaded
    f.rebirth.CanWritePersistentProgress = f.modules[services.RebirthService].CanWritePersistentProgress
    f.rebirth._loadedByUserId, f.rebirth._loadStateByUserId = {}, {}
    f.rebirth._dataStore = {
        GetAsync = function() coroutine.yield("fixture-held"); return { highestLevelReached = 610 } end,
        SetAsync = forbidden,
    }
    local oldPlayer = f.player
    local thread = coroutine.create(function() f.rebirth:_loadPlayer(oldPlayer) end)
    f.scheduler:resume(thread)
    oldPlayer.Parent = nil
    f.player = f:newPlayer(oldPlayer.UserId)
    f.rebirth._loadStateByUserId[oldPlayer.UserId] = "Pending"
    f.scheduler:resume(thread)
    equal(f.state.HighestLevelReached, 1)
    equal(f.rebirth._loadStateByUserId[oldPlayer.UserId], "Pending")
    equal(#f.awards, 0)
end)

test("Restoring or setting lower lifetime kill counts never erases previously reached eligibility", function()
    local f = fixture()
    f.state.TotalPlayerKills = 4
    f.ps:SetTotalPlayerKills(f.player, 1)
    equal(f.state.TotalPlayerKills, 4)
    f.ps:SetRebirthData(f.player, 0, 0, 1, { totalPlayerKills = 0, firstBossDefeated = false })
    equal(f.state.TotalPlayerKills, 4)
end)

return HttpService:JSONEncode({ passed = passed, failed = failed, warnings = warnings })
