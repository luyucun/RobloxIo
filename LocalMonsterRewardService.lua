--[[
脚本名字: LocalMonsterRewardService
脚本文件: LocalMonsterRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/LocalMonsterRewardService
说明: 处理客户端私有普通小怪的击杀奖励和接触伤害；服务端仍权威计算玩家状态。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

local function requireSharedModule(moduleName)
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    if sharedFolder then
        local moduleInShared = sharedFolder:FindFirstChild(moduleName)
        if moduleInShared and moduleInShared:IsA("ModuleScript") then
            return require(moduleInShared)
        end
    end

    local moduleInRoot = ReplicatedStorage:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return require(moduleInRoot)
    end

    error(string.format(
        "[LocalMonsterRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local LocalMonsterRewardService = {}

LocalMonsterRewardService._playerStateService = nil
LocalMonsterRewardService._experienceOrbService = nil
LocalMonsterRewardService._healthService = nil
LocalMonsterRewardService._rebirthService = nil
LocalMonsterRewardService._localMonsterSpawnTokenEvent = nil
LocalMonsterRewardService._localMonsterKilledEvent = nil
LocalMonsterRewardService._localMonsterHitPlayerEvent = nil
LocalMonsterRewardService._spawnTokenRequestWindows = {}
LocalMonsterRewardService._killReportWindows = {}
LocalMonsterRewardService._hitReportWindows = {}
LocalMonsterRewardService._recentKillIdsByUserId = {}
LocalMonsterRewardService._spawnAuthorizationsByUserId = {}
LocalMonsterRewardService._perfStats = nil
LocalMonsterRewardService._nextPerfLogClock = 0

local function getUserId(player)
    return player and player.UserId or 0
end

local function isArenaPlayer(playerState)
    return playerState and playerState.Alive == true and playerState.IsInArena == true
end

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function pruneRecentKills(recentKills, now)
    local windowSeconds = math.max(1, tonumber(GameConfig.MONSTER.LocalDuplicateKillWindowSeconds) or 10)
    for monsterId, expiry in pairs(recentKills) do
        if expiry <= now then
            recentKills[monsterId] = nil
        end
    end
    return windowSeconds
end

function LocalMonsterRewardService:_consumeRateLimit(bucketByUserId, player, limitPerSecond)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end

    local now = os.clock()
    local bucket = bucketByUserId[userId]
    if not bucket or now - bucket.WindowStart >= 1 then
        bucket = {
            WindowStart = now,
            Count = 0,
        }
        bucketByUserId[userId] = bucket
    end

    local limit = math.max(1, math.floor(tonumber(limitPerSecond) or 1))
    if bucket.Count >= limit then
        return false
    end

    bucket.Count += 1
    return true
end

function LocalMonsterRewardService:_resetPerfStats()
    self._perfStats = {
        TokenRequests = 0,
        TokensIssued = 0,
        TokenActivates = 0,
        TokensDiscarded = 0,
        KillBatchRequests = 0,
        KillPayloads = 0,
        KillsAccepted = 0,
        KillsRejected = 0,
        HitReports = 0,
        NukeSweeps = 0,
        NukeTokensConsumed = 0,
    }
end

function LocalMonsterRewardService:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function LocalMonsterRewardService:_getAuthorizationCounts()
    local users = 0
    local total = 0
    local active = 0
    local consumed = 0
    for _, authorizations in pairs(self._spawnAuthorizationsByUserId or {}) do
        users += 1
        for _, authorization in pairs(authorizations or {}) do
            total += 1
            if authorization.Active == true then
                active += 1
            end
            if authorization.Consumed == true then
                consumed += 1
            end
        end
    end
    return users, total, active, consumed
end

function LocalMonsterRewardService:_getRecentKillCount()
    local total = 0
    for _, recentKills in pairs(self._recentKillIdsByUserId or {}) do
        total += countMapEntries(recentKills)
    end
    return total
end

function LocalMonsterRewardService:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats or {}
    local authUsers, authTotal, authActive, authConsumed = self:_getAuthorizationCounts()
    print(string.format(
        "[Diag][LocalMonsterRewardService] authUsers=%d authTotal=%d authActive=%d authConsumed=%d recentKills=%d tokenWindows=%d killWindows=%d hitWindows=%d tokenReq=%d tokensIssued=%d activates=%d discarded=%d killBatchReq=%d killPayloads=%d killsAccepted=%d killsRejected=%d hitReports=%d nukeSweeps=%d nukeConsumed=%d",
        authUsers,
        authTotal,
        authActive,
        authConsumed,
        self:_getRecentKillCount(),
        countMapEntries(self._spawnTokenRequestWindows),
        countMapEntries(self._killReportWindows),
        countMapEntries(self._hitReportWindows),
        stats.TokenRequests or 0,
        stats.TokensIssued or 0,
        stats.TokenActivates or 0,
        stats.TokensDiscarded or 0,
        stats.KillBatchRequests or 0,
        stats.KillPayloads or 0,
        stats.KillsAccepted or 0,
        stats.KillsRejected or 0,
        stats.HitReports or 0,
        stats.NukeSweeps or 0,
        stats.NukeTokensConsumed or 0
    ))

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function LocalMonsterRewardService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function LocalMonsterRewardService:_pruneAuthorizationsForUserId(userId)
    local authorizations = self._spawnAuthorizationsByUserId[userId]
    if not authorizations then
        return
    end

    local now = os.clock()
    for token, authorization in pairs(authorizations) do
        if not authorization or authorization.Consumed == true then
            authorizations[token] = nil
        elseif authorization.Active == true then
            -- Active tokens belong to monsters that already exist on a client.
            -- Do not let a long fight turn into a valid kill with no reward.
        elseif (tonumber(authorization.ExpiresAt) or 0) <= now then
            authorizations[token] = nil
        end
    end
end

function LocalMonsterRewardService:_getAuthorization(player, token)
    local userId = getUserId(player)
    local normalizedToken = tostring(token or "")
    if userId <= 0 or normalizedToken == "" then
        return nil
    end

    self:_pruneAuthorizationsForUserId(userId)
    local authorizations = self._spawnAuthorizationsByUserId[userId]
    return authorizations and authorizations[normalizedToken] or nil
end

function LocalMonsterRewardService:_createAuthorization(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return nil
    end

    local definition = MonsterCatalog.GetRandomNormalMonsterDefinition()
        or MonsterCatalog.GetDefinition(GameConfig.MONSTER.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(definition) then
        return nil
    end

    local authorizations = self._spawnAuthorizationsByUserId[userId]
    if not authorizations then
        authorizations = {}
        self._spawnAuthorizationsByUserId[userId] = authorizations
    end

    local token = HttpService:GenerateGUID(false)
    local ttlSeconds = math.max(5, tonumber(GameConfig.MONSTER.LocalSpawnTokenTtlSeconds) or 90)
    authorizations[token] = {
        Token = token,
        MonsterDefinitionId = tostring(definition.Id or GameConfig.MONSTER.MonsterDefinitionId),
        CreatedAt = os.clock(),
        ExpiresAt = os.clock() + ttlSeconds,
        Consumed = false,
    }

    return authorizations[token], definition
end

function LocalMonsterRewardService:_handleSpawnTokenActivated(player, payload)
    local userId = getUserId(player)
    local token = tostring(payload and payload.token or payload and payload.Token or "")
    if userId <= 0 or token == "" then
        return
    end

    local authorizations = self._spawnAuthorizationsByUserId[userId]
    local authorization = authorizations and authorizations[token] or nil
    if not (authorization and authorization.Consumed ~= true) then
        return
    end

    if (tonumber(authorization.ExpiresAt) or 0) <= os.clock() then
        authorizations[token] = nil
        return
    end

    authorization.Active = true
    self:_addPerfStat("TokenActivates")
end

function LocalMonsterRewardService:_handleSpawnTokensDiscarded(player, payload)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local authorizations = self._spawnAuthorizationsByUserId[userId]
    if not authorizations then
        return
    end

    local rawTokens = type(payload) == "table" and payload.tokens or nil
    if type(rawTokens) ~= "table" then
        rawTokens = { payload and (payload.token or payload.Token) }
    end

    for _, rawToken in ipairs(rawTokens) do
        local token = tostring(rawToken or "")
        local authorization = authorizations[token]
        if authorization and authorization.Consumed ~= true then
            authorizations[token] = nil
            self:_addPerfStat("TokensDiscarded")
        end
    end
end

function LocalMonsterRewardService:_buildSpawnTokenPayload(authorization, definition)
    if not (authorization and definition) then
        return nil
    end

    return {
        token = authorization.Token,
        monsterDefinitionId = authorization.MonsterDefinitionId,
        templateName = definition.TemplateName,
        typeName = definition.TypeName,
        maxHealth = definition.MaxHealth or GameConfig.MONSTER.MaxHealth,
        attackDamage = definition.AttackDamage or GameConfig.MONSTER.AttackDamage,
        attackRange = definition.AttackRange or GameConfig.MONSTER.AttackRange,
        aggroRadius = definition.AggroRadius or GameConfig.MONSTER.AggroRadius,
        disengageDistance = definition.DisengageDistance or GameConfig.MONSTER.DisengageDistance,
        contactRadius = definition.ContactRadius or GameConfig.MONSTER.ContactRadius,
        attackCooldownSeconds = definition.AttackCooldownSeconds or GameConfig.MONSTER.AttackCooldownSeconds,
        moveSpeed = definition.MoveSpeed or GameConfig.MONSTER.MoveSpeed,
        expiresAt = authorization.ExpiresAt,
    }
end

function LocalMonsterRewardService:_handleSpawnTokenRequest(player, payload)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent and self._localMonsterSpawnTokenEvent) then
        return
    end

    self:_logPerfStats(os.clock())

    if type(payload) == "table" and tostring(payload.eventType or payload.EventType or "") == "Activate" then
        self:_handleSpawnTokenActivated(player, payload)
        return
    end
    if type(payload) == "table" and tostring(payload.eventType or payload.EventType or "") == "Discard" then
        self:_handleSpawnTokensDiscarded(player, payload)
        return
    end

    if not self:_isPlayerLoaded(player) then
        self._localMonsterSpawnTokenEvent:FireClient(player, {
            eventType = "Denied",
            reason = "DataLoading",
            timestamp = os.clock(),
        })
        return
    end
    if not self:_consumeRateLimit(self._spawnTokenRequestWindows, player, GameConfig.MONSTER.LocalSpawnTokenRequestsPerSecond) then
        self._localMonsterSpawnTokenEvent:FireClient(player, {
            eventType = "Denied",
            reason = "RateLimited",
            timestamp = os.clock(),
        })
        return
    end

    local maxBatchSize = math.max(1, math.floor(tonumber(GameConfig.MONSTER.LocalSpawnTokenRequestBatchSize) or 25))
    local requestedCount = type(payload) == "table" and math.floor(tonumber(payload.count or payload.Count) or maxBatchSize) or maxBatchSize
    requestedCount = math.clamp(requestedCount, 1, maxBatchSize)

    local tokens = {}
    for _ = 1, requestedCount do
        local authorization, definition = self:_createAuthorization(player)
        local tokenPayload = self:_buildSpawnTokenPayload(authorization, definition)
        if tokenPayload then
            table.insert(tokens, tokenPayload)
        end
    end
    self:_addPerfStat("TokenRequests")
    self:_addPerfStat("TokensIssued", #tokens)

    self._localMonsterSpawnTokenEvent:FireClient(player, {
        eventType = "Tokens",
        tokens = tokens,
        timestamp = os.clock(),
    })
end

function LocalMonsterRewardService:_normalizeDeathPosition(player, deathPosition)
    if typeof(deathPosition) == "Vector3" then
        return deathPosition
    end

    local rootPart = ActorUtils.GetRootPart(player)
    return rootPart and rootPart.Position or Vector3.zero
end

function LocalMonsterRewardService:_fireKillAck(player, payload, eventType, reason)
    if not (self._localMonsterKilledEvent and player and player.Parent and type(payload) == "table") then
        return
    end

    local requestId = tostring(payload.requestId or payload.RequestId or "")
    if requestId == "" then
        return
    end

    self._localMonsterKilledEvent:FireClient(player, {
        eventType = eventType,
        requestId = requestId,
        token = tostring(payload.token or payload.Token or ""),
        reason = reason,
        timestamp = os.clock(),
    })
end

function LocalMonsterRewardService:_fireKillBatchAck(player, acceptedRequestIds, rejectedRequests)
    if not (self._localMonsterKilledEvent and player and player.Parent) then
        return
    end

    self._localMonsterKilledEvent:FireClient(player, {
        eventType = "KillBatchResult",
        acceptedRequestIds = acceptedRequestIds or {},
        rejected = rejectedRequests or {},
        timestamp = os.clock(),
    })
end

function LocalMonsterRewardService:_buildKillRewardAccumulator()
    return {
        TotalScore = 0,
        TotalExperience = 0,
        VisualOrbCount = 0,
        DropPosition = nil,
    }
end

function LocalMonsterRewardService:_processLocalMonsterKill(player, payload, now, rewardAccumulator)
    local token = tostring(payload and payload.token or payload and payload.Token or "")
    if token == "" then
        warn("[LocalMonsterRewardService] 拒绝旧版本地怪击杀上报，缺少 token: " .. tostring(player.Name))
        return false, "MissingToken"
    end

    local userId = getUserId(player)
    local recentKills = self._recentKillIdsByUserId[userId]
    if not recentKills then
        recentKills = {}
        self._recentKillIdsByUserId[userId] = recentKills
    end

    local duplicateWindowSeconds = pruneRecentKills(recentKills, now)
    if recentKills[token] then
        return true, "Duplicate"
    end

    local authorization = self:_getAuthorization(player, token)
    if not (authorization and authorization.Consumed ~= true) then
        self:_addPerfStat("KillsRejected")
        return false, "InvalidToken"
    end

    local monsterDefinition = MonsterCatalog.GetDefinition(authorization.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(monsterDefinition) then
        self:_addPerfStat("KillsRejected")
        return false, "InvalidMonsterDefinition"
    end
    authorization.Consumed = true
    recentKills[token] = now + duplicateWindowSeconds
    self:_addPerfStat("KillsAccepted")

    if rewardAccumulator then
        rewardAccumulator.TotalScore += monsterDefinition.KillScoreReward or GameConfig.MONSTER.KillScoreReward
        local experienceDropCount = monsterDefinition.ExperienceDropCount or GameConfig.MONSTER.ExperienceDropCount
        local experiencePerOrb = monsterDefinition.ExperiencePerOrb or GameConfig.MONSTER.ExperiencePerOrb
        rewardAccumulator.TotalExperience += experienceDropCount * experiencePerOrb
        rewardAccumulator.VisualOrbCount += experienceDropCount
        rewardAccumulator.DropPosition = rewardAccumulator.DropPosition or self:_normalizeDeathPosition(player, payload and payload.deathPosition)
    end

    return true, nil
end

function LocalMonsterRewardService:_grantLocalMonsterKillRewards(player, rewardAccumulator)
    if not rewardAccumulator then
        return
    end

    local totalScore = math.max(0, math.floor(tonumber(rewardAccumulator.TotalScore) or 0))
    if totalScore > 0 and self._playerStateService then
        self._playerStateService:AddRebirthScore(player, totalScore)
    end

    local totalExperience = math.max(0, math.floor(tonumber(rewardAccumulator.TotalExperience) or 0))
    if totalExperience <= 0 then
        return
    end

    local visualOrbCount = math.max(1, math.floor(tonumber(rewardAccumulator.VisualOrbCount) or 1))
    local maxBatchOrbCount = math.max(1, math.floor(tonumber(GameConfig.MONSTER.LocalKillBatchExperienceOrbCount) or visualOrbCount))
    visualOrbCount = math.min(visualOrbCount, maxBatchOrbCount)
    local dropPosition = rewardAccumulator.DropPosition or self:_normalizeDeathPosition(player, nil)

    if self._experienceOrbService then
        self._experienceOrbService:DropExperience(
            dropPosition,
            totalExperience,
            visualOrbCount,
            player,
            {
                applyExperienceMultiplier = true,
            }
        )
    elseif self._playerStateService then
        self._playerStateService:AddExperienceWithMultiplier(player, totalExperience)
    end
end

function LocalMonsterRewardService:_handleLocalMonsterKilledBatch(player, payload)
    local kills = type(payload) == "table" and payload.kills or nil
    if type(kills) ~= "table" or #kills <= 0 then
        return
    end
    self:_addPerfStat("KillBatchRequests")
    self:_addPerfStat("KillPayloads", #kills)
    local maxBatchSize = math.max(1, math.floor(tonumber(GameConfig.MONSTER.LocalKillReportBatchSize) or 24))

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not (isArenaPlayer(state) and self:_isPlayerLoaded(player)) then
        local rejected = {}
        for index, killPayload in ipairs(kills) do
            if index > maxBatchSize then
                break
            end
            table.insert(rejected, {
                requestId = tostring(type(killPayload) == "table" and (killPayload.requestId or killPayload.RequestId) or ""),
                token = tostring(type(killPayload) == "table" and (killPayload.token or killPayload.Token) or ""),
                reason = "PlayerInactive",
            })
        end
        self:_fireKillBatchAck(player, {}, rejected)
        return
    end

    if not self:_consumeRateLimit(self._killReportWindows, player, GameConfig.MONSTER.LocalKillReportsPerSecond) then
        local rejected = {}
        for index, killPayload in ipairs(kills) do
            if index > maxBatchSize then
                break
            end
            table.insert(rejected, {
                requestId = tostring(type(killPayload) == "table" and (killPayload.requestId or killPayload.RequestId) or ""),
                token = tostring(type(killPayload) == "table" and (killPayload.token or killPayload.Token) or ""),
                reason = "RateLimited",
            })
        end
        self:_fireKillBatchAck(player, {}, rejected)
        return
    end

    local now = os.clock()
    local rewardAccumulator = self:_buildKillRewardAccumulator()
    local acceptedRequestIds = {}
    local rejected = {}

    for index, killPayload in ipairs(kills) do
        if index > maxBatchSize then
            break
        end
        if type(killPayload) == "table" then
            local requestId = tostring(killPayload.requestId or killPayload.RequestId or "")
            local accepted, reason = self:_processLocalMonsterKill(player, killPayload, now, rewardAccumulator)
            if accepted then
                if requestId ~= "" then
                    table.insert(acceptedRequestIds, requestId)
                end
            else
                table.insert(rejected, {
                    requestId = requestId,
                    token = tostring(killPayload.token or killPayload.Token or ""),
                    reason = reason or "Rejected",
                })
            end
        end
    end

    self:_grantLocalMonsterKillRewards(player, rewardAccumulator)
    self:_fireKillBatchAck(player, acceptedRequestIds, rejected)
end

function LocalMonsterRewardService:_handleLocalMonsterKilled(player, payload)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent) then
        return
    end

    if type(payload) == "table" and tostring(payload.eventType or payload.EventType or "") == "Batch" then
        self:_handleLocalMonsterKilledBatch(player, payload)
        self:_logPerfStats(os.clock())
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not (isArenaPlayer(state) and self:_isPlayerLoaded(player)) then
        self:_fireKillAck(player, payload, "KillRejected", "PlayerInactive")
        return
    end

    if not self:_consumeRateLimit(self._killReportWindows, player, GameConfig.MONSTER.LocalKillReportsPerSecond) then
        self:_fireKillAck(player, payload, "KillRejected", "RateLimited")
        return
    end

    local rewardAccumulator = self:_buildKillRewardAccumulator()
    local accepted, reason = self:_processLocalMonsterKill(player, payload, os.clock(), rewardAccumulator)
    if accepted then
        self:_grantLocalMonsterKillRewards(player, rewardAccumulator)
        self:_fireKillAck(player, payload, "KillAccepted", reason)
    else
        self:_fireKillAck(player, payload, "KillRejected", reason)
    end
    self:_logPerfStats(os.clock())
end

function LocalMonsterRewardService:_handleLocalMonsterHitPlayer(player, payload)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent) then
        return
    end
    self:_addPerfStat("HitReports")
    self:_logPerfStats(os.clock())

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not (isArenaPlayer(state) and self:_isPlayerLoaded(player)) then
        return
    end

    if not self:_consumeRateLimit(self._hitReportWindows, player, GameConfig.MONSTER.LocalHitReportsPerSecond) then
        return
    end

    local token = tostring(payload and payload.token or payload and payload.Token or "")
    if token == "" then
        warn("[LocalMonsterRewardService] 拒绝旧版本地怪碰撞上报，缺少 token: " .. tostring(player.Name))
        return
    end

    local authorization = self:_getAuthorization(player, token)
    if not (authorization and authorization.Consumed ~= true) then
        return
    end

    local monsterDefinition = MonsterCatalog.GetDefinition(authorization.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(monsterDefinition) then
        return
    end

    local damage = monsterDefinition.AttackDamage or GameConfig.MONSTER.AttackDamage
    if self._healthService then
        self._healthService:ApplyWeaponDamage(player, damage, nil)
    end
end

function LocalMonsterRewardService:ConsumeNukeSweepTokens(player, tokens)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent and type(tokens) == "table") then
        return 0, 0
    end
    if not self:_isPlayerLoaded(player) then
        return 0, 0
    end
    self:_addPerfStat("NukeSweeps")

    local remainingCount = math.max(0, math.floor(tonumber(GameConfig.MONSTER.MaxActiveCount) or 0))
    local totalExperience = 0
    local totalScore = 0
    local consumedCount = 0
    local seenTokens = {}

    for _, rawToken in ipairs(tokens) do
        if remainingCount <= 0 then
            break
        end

        local token = tostring(rawToken or "")
        if token ~= "" and not seenTokens[token] then
            seenTokens[token] = true
            local authorization = self:_getAuthorization(player, token)
            if authorization and authorization.Consumed ~= true then
                local definition = MonsterCatalog.GetDefinition(authorization.MonsterDefinitionId)
                if MonsterCatalog.IsNormalMonsterDefinition(definition) then
                    authorization.Consumed = true
                    remainingCount -= 1
                    consumedCount += 1
                    totalScore += definition.KillScoreReward or GameConfig.MONSTER.KillScoreReward
                    totalExperience += (definition.ExperienceDropCount or GameConfig.MONSTER.ExperienceDropCount)
                        * (definition.ExperiencePerOrb or GameConfig.MONSTER.ExperiencePerOrb)
                end
            end
        end
    end

    self:_addPerfStat("NukeTokensConsumed", consumedCount)
    self:_logPerfStats(os.clock())
    return consumedCount, totalScore, totalExperience
end

function LocalMonsterRewardService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    if userId > 0 then
        self._spawnTokenRequestWindows[userId] = nil
        self._killReportWindows[userId] = nil
        self._hitReportWindows[userId] = nil
        self._recentKillIdsByUserId[userId] = nil
        self._spawnAuthorizationsByUserId[userId] = nil
    end
end

function LocalMonsterRewardService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._experienceOrbService = dependencies.ExperienceOrbService
    self._healthService = dependencies.HealthService
    self._rebirthService = dependencies.RebirthService
    self._localMonsterSpawnTokenEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LocalMonsterSpawnToken") or nil
    self._localMonsterKilledEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LocalMonsterKilled") or nil
    self._localMonsterHitPlayerEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LocalMonsterHitPlayer") or nil
    self._spawnTokenRequestWindows = {}
    self._killReportWindows = {}
    self._hitReportWindows = {}
    self._recentKillIdsByUserId = {}
    self._spawnAuthorizationsByUserId = {}
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()

    if self._localMonsterSpawnTokenEvent then
        self._localMonsterSpawnTokenEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleSpawnTokenRequest(player, payload)
        end)
    end

    if self._localMonsterKilledEvent then
        self._localMonsterKilledEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleLocalMonsterKilled(player, payload)
        end)
    end

    if self._localMonsterHitPlayerEvent then
        self._localMonsterHitPlayerEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleLocalMonsterHitPlayer(player, payload)
        end)
    end
end

return LocalMonsterRewardService
