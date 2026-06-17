--[[
Script: GameAnalyticsService
Type: ModuleScript
Studio path: ServerScriptService/Services/GameAnalyticsService
Purpose: Central server-side analytics wrapper for funnel, custom, and economy events.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
        "[GameAnalyticsService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local GameAnalyticsService = {}

GameAnalyticsService._playerStateService = nil
GameAnalyticsService._playerJoinClockByUserId = {}
GameAnalyticsService._funnelSessionIdsByUserId = {}
GameAnalyticsService._onceKeysByUserId = {}
GameAnalyticsService._analyticsThrottleUntilClock = 0
GameAnalyticsService._analyticsThrottleWarnClock = 0
GameAnalyticsService._analyticsBudgetWindowClock = 0
GameAnalyticsService._analyticsBudgetTokens = 0
GameAnalyticsService._analyticsLastStatsLogClock = 0
GameAnalyticsService._analyticsStats = {
    attempted = 0,
    sent = 0,
    suppressed = 0,
    rateLimited = 0,
}
GameAnalyticsService._dedupeUntilByUserId = {}
GameAnalyticsService._summaryBucketsByUserId = {}
GameAnalyticsService._heartbeatLoopStarted = false
GameAnalyticsService._sequence = 0

local HIGH_FREQUENCY_CUSTOM_EVENTS = {
    BattleEntered = true,
    MonsterKillBatchAccepted = true,
    PlayerDied = true,
    PlayerKilled = true,
}

local HIGH_FREQUENCY_ECONOMY_SOURCES = {
    monster = true,
    wheel = true,
    wheel_refund = true,
    timer = true,
}

local HIGH_FREQUENCY_ECONOMY_SKUS = {
    FreeSpinTimer = true,
    WheelSpin = true,
}

local DEDUPE_FUNNEL_NAMES = {
    DefeatedFreeRespawn = true,
    DefeatedRevive = true,
    ShopPurchase = true,
    SkinFlow = true,
    WheelFlow = true,
}

local DEDUPE_CUSTOM_EVENTS = {
    RevivePurchaseCancel = true,
    AutoRespawned = true,
    LatePurchaseCompensated = true,
    SkinPurchaseFailed_NotEnoughDiamonds = true,
    SkinPurchaseFailed_InvalidSkin = true,
    SkinEquipFailed_NotOwned = true,
}

local KEY_FUNNEL_STEPS = {
    ShopPurchase = {
        ProductViewed = false,
    },
}

local function getAnalyticsConfig()
    return GameConfig.ANALYTICS or {}
end

local function isPlayer(value)
    return typeof(value) == "Instance" and value:IsA("Player")
end

local function getUserId(player)
    return isPlayer(player) and player.UserId or 0
end

local function getLevelBand(level)
    local normalizedLevel = math.max(1, math.floor(tonumber(level) or 1))
    if normalizedLevel <= 9 then
        return "L1_9"
    elseif normalizedLevel <= 19 then
        return "L10_19"
    elseif normalizedLevel <= 79 then
        return "L20_79"
    elseif normalizedLevel <= 159 then
        return "L80_159"
    elseif normalizedLevel <= 319 then
        return "L160_319"
    end
    return "L320_PLUS"
end

local function getSessionAgeBand(ageSeconds)
    local normalizedAge = math.max(0, tonumber(ageSeconds) or 0)
    if normalizedAge < 60 then
        return "0_60s"
    elseif normalizedAge < 180 then
        return "1_3m"
    elseif normalizedAge < 600 then
        return "3_10m"
    end
    return "10m_plus"
end

local function sanitizeValue(value)
    local valueType = typeof(value)
    if valueType == "string" then
        return string.sub(value, 1, 128)
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return 0
        end
        return value
    elseif valueType == "boolean" then
        return value
    elseif value == nil then
        return nil
    end
    return string.sub(tostring(value), 1, 128)
end

local function sanitizeFields(fields)
    local sanitized = {}
    if type(fields) ~= "table" then
        return sanitized
    end

    for key, value in pairs(fields) do
        local sanitizedKey = sanitizeValue(key)
        local sanitizedValue = sanitizeValue(value)
        if sanitizedKey ~= nil and sanitizedValue ~= nil then
            sanitized[tostring(sanitizedKey)] = sanitizedValue
        end
    end
    return sanitized
end

local function setCustomField(target, fieldName, value)
    local sanitizedValue = sanitizeValue(value)
    if sanitizedValue == nil then
        return
    end
    target[fieldName] = tostring(sanitizedValue)
end

local function getAnalyticsCustomFieldKey(index)
    local enumKey = Enum.AnalyticsCustomFieldKeys["CustomField0" .. tostring(index)]
    return enumKey and enumKey.Name or nil
end

local function encodeDebugPayload(payload)
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)
    if ok then
        return encoded
    end
    return tostring(payload)
end

local function shouldSample(rate)
    local normalizedRate = tonumber(rate)
    if normalizedRate == nil or normalizedRate >= 1 then
        return true
    elseif normalizedRate <= 0 then
        return false
    end
    return math.random() < normalizedRate
end

local function resolveEnumItem(enumType, value, fallback)
    if typeof(value) == "EnumItem" then
        return value
    end

    local key = tostring(value or "")
    if key ~= "" then
        local ok, enumItem = pcall(function()
            return enumType[key]
        end)
        if ok and enumItem then
            return enumItem
        end
    end

    return fallback
end

local function clampNumber(value, minimum, maximum)
    local normalized = tonumber(value)
    if normalized == nil or normalized ~= normalized then
        normalized = minimum
    end
    if normalized < minimum then
        normalized = minimum
    end
    if maximum ~= nil and normalized > maximum then
        normalized = maximum
    end
    return normalized
end

local function shallowCopyTable(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end

    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function serializeKeyPart(value)
    local valueType = typeof(value)
    if value == nil then
        return ""
    elseif valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "0"
        end
        return string.format("%.4f", value)
    elseif valueType == "boolean" then
        return value and "true" or "false"
    end
    return tostring(value)
end

local function buildFieldFingerprint(fields, keys)
    if type(fields) ~= "table" then
        return ""
    end

    local parts = {}
    for _, key in ipairs(keys) do
        local value = fields[key]
        if value ~= nil then
            parts[#parts + 1] = key .. "=" .. serializeKeyPart(value)
        end
    end

    if #parts == 0 then
        return ""
    end

    table.sort(parts)
    return table.concat(parts, "&")
end

local function isHighFrequencyCustomEvent(eventName)
    return HIGH_FREQUENCY_CUSTOM_EVENTS[tostring(eventName or "")] == true
end

local function isDedupeCustomEvent(eventName)
    return DEDUPE_CUSTOM_EVENTS[tostring(eventName or "")] == true
end

local function isDedupeFunnelName(funnelName)
    return DEDUPE_FUNNEL_NAMES[tostring(funnelName or "")] == true
end

local function isHighFrequencyEconomySource(source)
    return HIGH_FREQUENCY_ECONOMY_SOURCES[tostring(source or "")] == true
end

local function isHighFrequencyEconomyItemSku(itemSku)
    return HIGH_FREQUENCY_ECONOMY_SKUS[tostring(itemSku or "")] == true
end

local function isKeyFunnelStep(funnelName, stepName)
    local funnelSteps = KEY_FUNNEL_STEPS[tostring(funnelName or "")]
    if not funnelSteps then
        return true
    end
    local stepKey = tostring(stepName or "")
    if funnelSteps[stepKey] == false then
        return false
    end
    return true
end

local function copySummaryFields(source)
    return shallowCopyTable(type(source) == "table" and source or {})
end

local function isAnalyticsThrottleError(err)
    local message = string.lower(tostring(err or ""))
    return string.find(message, "too many events", 1, true) ~= nil
        or string.find(message, "rate limit", 1, true) ~= nil
        or string.find(message, "throttl", 1, true) ~= nil
end

function GameAnalyticsService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    if not self._heartbeatLoopStarted then
        self._heartbeatLoopStarted = true
        task.spawn(function()
            while true do
                task.wait(1)
                self:OnHeartbeat()
            end
        end)
    end
end

function GameAnalyticsService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
end

function GameAnalyticsService:OnPlayerAdded(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    self._playerJoinClockByUserId[userId] = os.clock()
    self._funnelSessionIdsByUserId[userId] = {}
    self._onceKeysByUserId[userId] = {}

    if self:MarkOnce(player, "Onboarding.JoinedGame") then
        self:TrackFunnel(player, "Onboarding", 1, "JoinedGame", {
            source = "system",
        })
    end
end

function GameAnalyticsService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    self:_flushPlayerSummaries(player, "player_removing")
    self._playerJoinClockByUserId[userId] = nil
    self._funnelSessionIdsByUserId[userId] = nil
    self._onceKeysByUserId[userId] = nil
    self._dedupeUntilByUserId[userId] = nil
    self._summaryBucketsByUserId[userId] = nil
end

function GameAnalyticsService:GetPlayerContext(player)
    local userId = getUserId(player)
    local joinClock = userId > 0 and self._playerJoinClockByUserId[userId] or nil
    local sessionAgeSeconds = joinClock and math.max(0, os.clock() - joinClock) or 0
    local state = nil

    if isPlayer(player) and self._playerStateService and self._playerStateService.GetState then
        local ok, resolvedState = pcall(function()
            return self._playerStateService:GetState(player)
        end)
        if ok then
            state = resolvedState
        end
    end

    local level = state and state.Level or 1
    local arenaState = "lobby"
    if state and state.Alive == false then
        arenaState = "defeated"
    elseif state and state.IsInArena == true then
        arenaState = "battle"
    end

    return {
        levelBand = getLevelBand(level),
        arenaState = arenaState,
        source = "system",
        sessionAgeBand = getSessionAgeBand(sessionAgeSeconds),
    }
end

function GameAnalyticsService:MarkOnce(player, key)
    local userId = getUserId(player)
    local normalizedKey = tostring(key or "")
    if userId <= 0 or normalizedKey == "" then
        return false
    end

    local onceKeys = self._onceKeysByUserId[userId]
    if not onceKeys then
        onceKeys = {}
        self._onceKeysByUserId[userId] = onceKeys
    end

    if onceKeys[normalizedKey] == true then
        return false
    end

    onceKeys[normalizedKey] = true
    return true
end

function GameAnalyticsService:_getAnalyticsThrottleSeconds()
    local config = getAnalyticsConfig()
    return math.max(15, tonumber(config.AnalyticsThrottleCooldownSeconds) or 60)
end

function GameAnalyticsService:_isAnalyticsThrottled()
    return os.clock() < (self._analyticsThrottleUntilClock or 0)
end

function GameAnalyticsService:_enterAnalyticsThrottle(err)
    local now = os.clock()
    local cooldownSeconds = self:_getAnalyticsThrottleSeconds()
    local throttleUntil = now + cooldownSeconds
    self._analyticsThrottleUntilClock = math.max(self._analyticsThrottleUntilClock or 0, throttleUntil)
    self:_recordAnalyticsStat("rateLimited", 1)

    if now - (self._analyticsThrottleWarnClock or 0) >= 30 then
        warn(string.format(
            "[GameAnalyticsService] AnalyticsService rate limited; suppressing analytics traffic for %d seconds. Last error: %s",
            cooldownSeconds,
            tostring(err or "unknown")
        ))
        self._analyticsThrottleWarnClock = now
    end
end

function GameAnalyticsService:_getStatsLogIntervalSeconds()
    local config = getAnalyticsConfig()
    return math.max(15, tonumber(config.AnalyticsStatsLogIntervalSeconds) or 60)
end

function GameAnalyticsService:_recordAnalyticsStat(statName, amount)
    local stats = self._analyticsStats
    stats[statName] = (stats[statName] or 0) + (tonumber(amount) or 1)
    self:_maybeLogAnalyticsStats()
end

function GameAnalyticsService:_maybeLogAnalyticsStats(force)
    local config = getAnalyticsConfig()
    if not (force or config.StudioDebugPrint == true or config.LiveDebugPrint == true) then
        return
    end

    local now = os.clock()
    local intervalSeconds = self:_getStatsLogIntervalSeconds()
    if not force and now - (self._analyticsLastStatsLogClock or 0) < intervalSeconds then
        return
    end

    self._analyticsLastStatsLogClock = now
    local stats = self._analyticsStats
    local hasActivity = (stats.attempted or 0) > 0
        or (stats.sent or 0) > 0
        or (stats.suppressed or 0) > 0
        or (stats.rateLimited or 0) > 0
    if not hasActivity then
        return
    end

    print(string.format(
        "[GameAnalyticsService] stats attempted=%d sent=%d suppressed=%d rateLimited=%d budgetTokens=%.2f",
        stats.attempted or 0,
        stats.sent or 0,
        stats.suppressed or 0,
        stats.rateLimited or 0,
        self._analyticsBudgetTokens or 0
    ))
end

function GameAnalyticsService:_getSendBudgetCapacity()
    local config = getAnalyticsConfig()
    local baseBudget = math.max(1, tonumber(config.SendBudgetBasePerMinute) or 24)
    local perPlayerBudget = math.max(0, tonumber(config.SendBudgetPerPlayerPerMinute) or 12)
    local safetyRatio = clampNumber(config.SendBudgetSafetyRatio, 0.1, 1)
    local playerCount = math.max(1, #Players:GetPlayers())
    return math.max(1, math.floor((baseBudget + perPlayerBudget * playerCount) * safetyRatio))
end

function GameAnalyticsService:_refreshSendBudget(now)
    local currentClock = now or os.clock()
    local capacity = self:_getSendBudgetCapacity()
    local windowClock = self._analyticsBudgetWindowClock or 0

    if windowClock <= 0 then
        self._analyticsBudgetWindowClock = currentClock
        self._analyticsBudgetTokens = capacity
        return capacity
    end

    local elapsed = currentClock - windowClock
    if elapsed <= 0 then
        self._analyticsBudgetTokens = math.min(capacity, self._analyticsBudgetTokens or capacity)
        return capacity
    end

    local refillPerSecond = capacity / 60
    self._analyticsBudgetTokens = math.min(capacity, (self._analyticsBudgetTokens or 0) + elapsed * refillPerSecond)
    self._analyticsBudgetWindowClock = currentClock
    return capacity
end

function GameAnalyticsService:_consumeSendBudget(eventType, eventName)
    self:_refreshSendBudget(os.clock())
    if (self._analyticsBudgetTokens or 0) < 1 then
        self:_recordAnalyticsStat("suppressed", 1)
        self:_debugPrint("Suppressed", {
            reason = "local_budget",
            eventType = tostring(eventType or "Event"),
            eventName = tostring(eventName or ""),
        })
        return false
    end

    self._analyticsBudgetTokens -= 1
    return true
end

function GameAnalyticsService:_getDedupeSeconds()
    local config = getAnalyticsConfig()
    return math.max(0, tonumber(config.EventDedupeSeconds) or 2)
end

function GameAnalyticsService:_consumeDedupe(player, dedupeKey, ttlSeconds)
    local userId = getUserId(player)
    local normalizedKey = tostring(dedupeKey or "")
    local normalizedTtl = math.max(0, tonumber(ttlSeconds) or 0)
    if userId <= 0 or normalizedKey == "" or normalizedTtl <= 0 then
        return true
    end

    local now = os.clock()
    local dedupeUntil = self._dedupeUntilByUserId[userId]
    if not dedupeUntil then
        dedupeUntil = {}
        self._dedupeUntilByUserId[userId] = dedupeUntil
    end

    if (dedupeUntil[normalizedKey] or 0) > now then
        self:_recordAnalyticsStat("suppressed", 1)
        self:_debugPrint("Suppressed", {
            reason = "dedupe",
            key = normalizedKey,
        })
        return false
    end

    dedupeUntil[normalizedKey] = now + normalizedTtl
    return true
end

function GameAnalyticsService:_getSummaryIntervalSeconds()
    local config = getAnalyticsConfig()
    return math.max(10, tonumber(config.HighFrequencySummaryIntervalSeconds) or 45)
end

function GameAnalyticsService:_getPlayerSummaryBuckets(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return nil
    end

    local buckets = self._summaryBucketsByUserId[userId]
    if not buckets then
        buckets = {}
        self._summaryBucketsByUserId[userId] = buckets
    end
    return buckets
end

function GameAnalyticsService:_addSummaryValue(player, bucketKey, eventName, value, fields)
    local buckets = self:_getPlayerSummaryBuckets(player)
    if not buckets then
        return false
    end

    local now = os.clock()
    local normalizedBucketKey = tostring(bucketKey or eventName or "Summary")
    local bucket = buckets[normalizedBucketKey]
    if not bucket then
        self._sequence += 1
        bucket = {
            kind = "custom",
            eventName = tostring(eventName or normalizedBucketKey),
            value = 0,
            count = 0,
            fields = copySummaryFields(fields),
            firstClock = now,
            lastClock = now,
            flushToken = self._sequence,
        }
        buckets[normalizedBucketKey] = bucket
        self:_scheduleSummaryFlush(player, normalizedBucketKey, bucket.flushToken)
    end

    bucket.value += tonumber(value) or 1
    bucket.count += 1
    bucket.lastClock = now
    bucket.fields = bucket.fields or copySummaryFields(fields)
    if type(fields) == "table" then
        for key, fieldValue in pairs(fields) do
            if bucket.fields[key] == nil then
                bucket.fields[key] = fieldValue
            end
        end
    end
    return true
end

function GameAnalyticsService:_addEconomySummaryValue(player, bucketKey, payload)
    local buckets = self:_getPlayerSummaryBuckets(player)
    if not buckets then
        return false
    end

    local now = os.clock()
    local normalizedBucketKey = tostring(bucketKey or "EconomySummary")
    local bucket = buckets[normalizedBucketKey]
    if not bucket then
        self._sequence += 1
        bucket = {
            kind = "economy",
            flowType = payload.flowType,
            currency = tostring(payload.currency or "Currency"),
            amount = 0,
            balance = math.max(0, tonumber(payload.balance) or 0),
            transactionType = payload.transactionType,
            itemSku = tostring(payload.itemSku or "Unknown"),
            count = 0,
            fields = copySummaryFields(payload.fields),
            firstClock = now,
            lastClock = now,
            flushToken = self._sequence,
        }
        buckets[normalizedBucketKey] = bucket
        self:_scheduleSummaryFlush(player, normalizedBucketKey, bucket.flushToken)
    end

    bucket.amount += math.max(0, tonumber(payload.amount) or 0)
    bucket.balance = math.max(0, tonumber(payload.balance) or bucket.balance or 0)
    bucket.flowType = payload.flowType or bucket.flowType
    bucket.currency = tostring(payload.currency or bucket.currency or "Currency")
    bucket.transactionType = payload.transactionType or bucket.transactionType
    bucket.itemSku = tostring(payload.itemSku or bucket.itemSku or "Unknown")
    bucket.count += 1
    bucket.lastClock = now
    bucket.fields = bucket.fields or copySummaryFields(payload.fields)
    if type(payload.fields) == "table" then
        for key, fieldValue in pairs(payload.fields) do
            if bucket.fields[key] == nil then
                bucket.fields[key] = fieldValue
            end
        end
    end
    return true
end

function GameAnalyticsService:_scheduleSummaryFlush(player, bucketKey, bucketToken)
    local delaySeconds = self:_getSummaryIntervalSeconds()
    task.delay(delaySeconds, function()
        local userId = getUserId(player)
        if userId <= 0 then
            return
        end

        local buckets = self._summaryBucketsByUserId[userId]
        local bucket = buckets and buckets[bucketKey]
        if not bucket or bucket.flushToken ~= bucketToken then
            return
        end

        self:_flushSummaryBucket(player, bucketKey, "interval")
    end)
end

function GameAnalyticsService:_flushSummaryBucket(player, bucketKey, reason)
    local userId = getUserId(player)
    local buckets = userId > 0 and self._summaryBucketsByUserId[userId] or nil
    if not buckets then
        return false
    end

    local bucket = buckets[bucketKey]
    if not bucket then
        return false
    end

    buckets[bucketKey] = nil
    if (bucket.count or 0) <= 0 then
        return false
    end

    local fields = copySummaryFields(bucket.fields)
    fields.source = fields.source or "summary"
    fields.summaryReason = tostring(reason or "interval")
    fields.summaryCount = bucket.count
    fields.summaryWindowSeconds = math.max(0, math.floor((bucket.lastClock or os.clock()) - (bucket.firstClock or os.clock())))

    if bucket.kind == "economy" then
        if (bucket.amount or 0) <= 0 then
            return false
        end
        fields.summaryType = "economy"
        return self:_emitEconomy(
            player,
            bucket.flowType,
            bucket.currency,
            bucket.amount,
            bucket.balance,
            bucket.transactionType,
            bucket.itemSku,
            fields
        )
    end

    if (bucket.value or 0) <= 0 then
        return false
    end

    fields.summaryType = "custom"
    return self:_emitCustom(player, bucket.eventName, bucket.value, fields)
end

function GameAnalyticsService:_flushDueSummaries(player)
    local userId = getUserId(player)
    local buckets = userId > 0 and self._summaryBucketsByUserId[userId] or nil
    if not buckets then
        return
    end

    local now = os.clock()
    local intervalSeconds = self:_getSummaryIntervalSeconds()
    local dueKeys = {}
    for bucketKey, bucket in pairs(buckets) do
        if now - (bucket.firstClock or now) >= intervalSeconds then
            dueKeys[#dueKeys + 1] = bucketKey
        end
    end

    for _, bucketKey in ipairs(dueKeys) do
        self:_flushSummaryBucket(player, bucketKey, "interval")
    end
end

function GameAnalyticsService:_flushPlayerSummaries(player, reason)
    local userId = getUserId(player)
    local buckets = userId > 0 and self._summaryBucketsByUserId[userId] or nil
    if not buckets then
        return
    end

    local keys = {}
    for bucketKey in pairs(buckets) do
        keys[#keys + 1] = bucketKey
    end

    for _, bucketKey in ipairs(keys) do
        self:_flushSummaryBucket(player, bucketKey, reason or "flush")
    end
end

function GameAnalyticsService:BeginOnboardingSurvivalCheck(player, delaySeconds)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local delayTime = math.max(1, tonumber(delaySeconds) or 60)
    task.delay(delayTime, function()
        if not (player and player.Parent) then
            return
        end

        local state = nil
        if self._playerStateService and self._playerStateService.GetState then
            local ok, resolvedState = pcall(function()
                return self._playerStateService:GetState(player)
            end)
            if ok then
                state = resolvedState
            end
        end

        if not (state and state.Alive == true and state.IsInArena == true) then
            return
        end

        if self:MarkOnce(player, "Onboarding.FirstDeathOrSurvived60s") then
            self:TrackFunnel(player, "Onboarding", 10, "FirstDeathOrSurvived60s", {
                source = "survived60s",
            })
        end
    end)
end

function GameAnalyticsService:_shouldSendToRoblox()
    local config = getAnalyticsConfig()
    if config.Enabled ~= true then
        return false
    end
    if RunService:IsStudio() and config.StudioSendToRoblox ~= true then
        return false
    end
    return true
end

function GameAnalyticsService:_shouldPrintDebug()
    local config = getAnalyticsConfig()
    if RunService:IsStudio() then
        return config.StudioDebugPrint == true
    end
    return config.LiveDebugPrint == true
end

function GameAnalyticsService:_buildCustomFields(player, fields)
    local context = self:GetPlayerContext(player)
    local sanitizedFields = sanitizeFields(fields)
    local customFields = {}

    local customField01 = getAnalyticsCustomFieldKey(1)
    local customField02 = getAnalyticsCustomFieldKey(2)
    local customField03 = getAnalyticsCustomFieldKey(3)

    if customField01 then
        setCustomField(customFields, customField01, sanitizedFields.CustomField01 or sanitizedFields.levelBand or context.levelBand)
    end
    if customField02 then
        setCustomField(customFields, customField02, sanitizedFields.CustomField02 or sanitizedFields.source or context.source)
    end
    if customField03 then
        setCustomField(customFields, customField03, sanitizedFields.CustomField03 or sanitizedFields.arenaState or context.arenaState)
    end

    return customFields, context, sanitizedFields
end

local function getFunnelSessionStoreKey(funnelName, sessionKey)
    local normalizedFunnelName = tostring(funnelName or "Default")
    local normalizedSessionKey = tostring(sessionKey or "")
    if normalizedSessionKey == "" then
        return normalizedFunnelName
    end
    return normalizedFunnelName .. ":" .. normalizedSessionKey
end

function GameAnalyticsService:_getFunnelSessionId(player, funnelName, sessionKey)
    local userId = getUserId(player)
    local normalizedFunnelName = tostring(funnelName or "Default")
    local sessionStoreKey = getFunnelSessionStoreKey(normalizedFunnelName, sessionKey)
    if userId <= 0 then
        self._sequence += 1
        return string.format("server_%d_%s", self._sequence, normalizedFunnelName)
    end

    local sessions = self._funnelSessionIdsByUserId[userId]
    if not sessions then
        sessions = {}
        self._funnelSessionIdsByUserId[userId] = sessions
    end

    if not sessions[sessionStoreKey] then
        self._sequence += 1
        sessions[sessionStoreKey] = string.format("%d_%s_%d", userId, normalizedFunnelName, self._sequence)
    end

    return sessions[sessionStoreKey]
end

function GameAnalyticsService:_debugPrint(eventType, payload)
    if not self:_shouldPrintDebug() then
        return
    end
    print(string.format("[AnalyticsDebug] %s %s", tostring(eventType or "Event"), encodeDebugPayload(payload or {})))
end

function GameAnalyticsService:_emitFunnel(player, funnelName, stepNumber, stepName, fields, options)
    if self:_isAnalyticsThrottled() then
        return true
    end

    local normalizedOptions = type(options) == "table" and options or {}
    local customFields, context, sanitizedFields = self:_buildCustomFields(player, fields)
    local normalizedFunnelName = tostring(funnelName or "Default")
    local normalizedStepNumber = math.max(1, math.floor(tonumber(stepNumber) or 1))
    local normalizedStepName = tostring(stepName or ("Step" .. tostring(normalizedStepNumber)))
    local sessionId = self:_getFunnelSessionId(player, normalizedFunnelName, normalizedOptions.sessionKey)

    self:_debugPrint("Funnel", {
        funnelName = normalizedFunnelName,
        sessionId = sessionId,
        stepNumber = normalizedStepNumber,
        stepName = normalizedStepName,
        fields = sanitizedFields,
        context = context,
    })

    if not self:_shouldSendToRoblox() then
        return true
    end
    if not isPlayer(player) then
        warn("[GameAnalyticsService] TrackFunnel skipped because player is invalid.")
        return false
    end

    if not self:_consumeSendBudget("Funnel", normalizedFunnelName) then
        return true
    end

    local ok, err = pcall(function()
        if normalizedFunnelName == "Onboarding" then
            AnalyticsService:LogOnboardingFunnelStepEvent(player, normalizedStepNumber, normalizedStepName, customFields)
        else
            AnalyticsService:LogFunnelStepEvent(player, normalizedFunnelName, sessionId, normalizedStepNumber, normalizedStepName, customFields)
        end
    end)

    if not ok then
        if isAnalyticsThrottleError(err) then
            self:_enterAnalyticsThrottle(err)
            return true
        end
        warn("[GameAnalyticsService] TrackFunnel failed: " .. tostring(err))
        return false
    end

    self:_recordAnalyticsStat("sent", 1)
    return true
end

function GameAnalyticsService:_emitCustom(player, eventName, value, fields)
    local customFields, context, sanitizedFields = self:_buildCustomFields(player, fields)
    local normalizedEventName = tostring(eventName or "CustomEvent")
    local normalizedValue = tonumber(value) or 1

    self:_debugPrint("Custom", {
        eventName = normalizedEventName,
        value = normalizedValue,
        fields = sanitizedFields,
        context = context,
    })

    if not self:_shouldSendToRoblox() then
        return true
    end
    if not isPlayer(player) then
        warn("[GameAnalyticsService] TrackCustom skipped because player is invalid.")
        return false
    end

    if not self:_consumeSendBudget("Custom", normalizedEventName) then
        return true
    end

    local ok, err = pcall(function()
        AnalyticsService:LogCustomEvent(player, normalizedEventName, normalizedValue, customFields)
    end)

    if not ok then
        if isAnalyticsThrottleError(err) then
            self:_enterAnalyticsThrottle(err)
            return true
        end
        warn("[GameAnalyticsService] TrackCustom failed: " .. tostring(err))
        return false
    end

    self:_recordAnalyticsStat("sent", 1)
    return true
end

function GameAnalyticsService:_emitEconomy(player, flowType, currency, amount, balance, transactionType, itemSku, fields)
    local customFields, context, sanitizedFields = self:_buildCustomFields(player, fields)
    local normalizedFlowType = resolveEnumItem(
        Enum.AnalyticsEconomyFlowType,
        flowType,
        Enum.AnalyticsEconomyFlowType.Source
    )
    local normalizedCurrency = tostring(currency or "Currency")
    local normalizedAmount = math.max(0, tonumber(amount) or 0)
    local normalizedBalance = math.max(0, tonumber(balance) or 0)
    local normalizedItemSku = tostring(itemSku or "Unknown")
    local normalizedTransactionType = ""
    if typeof(transactionType) == "EnumItem" then
        normalizedTransactionType = transactionType.Name
    else
        normalizedTransactionType = tostring(transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay.Name)
    end
    if normalizedTransactionType == "" then
        normalizedTransactionType = Enum.AnalyticsEconomyTransactionType.Gameplay.Name
    end

    self:_debugPrint("Economy", {
        flowType = tostring(normalizedFlowType),
        currency = normalizedCurrency,
        amount = normalizedAmount,
        balance = normalizedBalance,
        transactionType = normalizedTransactionType,
        itemSku = normalizedItemSku,
        fields = sanitizedFields,
        context = context,
    })

    if not self:_shouldSendToRoblox() then
        return true
    end
    if not isPlayer(player) then
        warn("[GameAnalyticsService] TrackEconomy skipped because player is invalid.")
        return false
    end

    if not self:_consumeSendBudget("Economy", normalizedItemSku) then
        return true
    end

    local ok, err = pcall(function()
        AnalyticsService:LogEconomyEvent(
            player,
            normalizedFlowType,
            normalizedCurrency,
            normalizedAmount,
            normalizedBalance,
            normalizedTransactionType,
            normalizedItemSku,
            customFields
        )
    end)

    if not ok then
        if isAnalyticsThrottleError(err) then
            self:_enterAnalyticsThrottle(err)
            return true
        end
        warn("[GameAnalyticsService] TrackEconomy failed: " .. tostring(err))
        return false
    end

    self:_recordAnalyticsStat("sent", 1)
    return true
end

function GameAnalyticsService:OnHeartbeat()
    local userIds = {}
    for userId in pairs(self._summaryBucketsByUserId) do
        userIds[#userIds + 1] = userId
    end

    for _, userId in ipairs(userIds) do
        local player = Players:GetPlayerByUserId(userId)
        if player and player.Parent then
            self:_flushDueSummaries(player)
        end
    end

    self:_maybeLogAnalyticsStats()
end

function GameAnalyticsService:TrackFunnel(player, funnelName, stepNumber, stepName, fields, options)
    self:_recordAnalyticsStat("attempted", 1)
    local normalizedFunnelName = tostring(funnelName or "Default")
    local normalizedStepNumber = math.max(1, math.floor(tonumber(stepNumber) or 1))
    local normalizedStepName = tostring(stepName or ("Step" .. tostring(normalizedStepNumber)))
    local normalizedFields = type(fields) == "table" and fields or {}
    local normalizedOptions = type(options) == "table" and options or {}
    if isDedupeFunnelName(normalizedFunnelName) then
        local ttlSeconds = math.max(self:_getDedupeSeconds(), 2)
        local dedupeKey = string.format(
            "funnel:%s:%s:%d:%s:%s",
            normalizedFunnelName,
            tostring(normalizedOptions.sessionKey or ""),
            normalizedStepNumber,
            normalizedStepName,
            buildFieldFingerprint(normalizedFields, { "source", "productGroup", "itemSku", "skinId", "gamePassId" })
        )
        if not self:_consumeDedupe(player, dedupeKey, ttlSeconds) then
            return true
        end
    end

    if normalizedFunnelName == "ShopPurchase" and not isKeyFunnelStep(normalizedFunnelName, normalizedStepName) then
        self:_recordAnalyticsStat("suppressed", 1)
        return true
    end

    return self:_emitFunnel(player, normalizedFunnelName, normalizedStepNumber, normalizedStepName, fields, normalizedOptions)
end

function GameAnalyticsService:TrackCustom(player, eventName, value, fields)
    self:_recordAnalyticsStat("attempted", 1)
    local config = getAnalyticsConfig()
    local normalizedEventName = tostring(eventName or "CustomEvent")

    local normalizedFields = type(fields) == "table" and fields or {}
    local configSampleRate = tonumber(config.CustomEventSampleRate)

    if isHighFrequencyCustomEvent(normalizedEventName) then
        local summaryBucketKey = string.format(
            "custom:%s:%s",
            normalizedEventName,
            buildFieldFingerprint(normalizedFields, { "source", "productGroup", "itemSku", "skinId", "gamePassId", "level", "arenaState" })
        )
        self:_addSummaryValue(player, summaryBucketKey, normalizedEventName, value or 1, normalizedFields)
        self:_recordAnalyticsStat("suppressed", 1)
        self:_flushDueSummaries(player)
        return true
    end

    if isDedupeCustomEvent(normalizedEventName) then
        local dedupeKey = string.format(
            "custom:%s:%s",
            normalizedEventName,
            buildFieldFingerprint(normalizedFields, { "source", "productGroup", "itemSku", "skinId", "gamePassId", "level", "arenaState" })
        )
        if not self:_consumeDedupe(player, dedupeKey, self:_getDedupeSeconds()) then
            return true
        end
    end

    if not shouldSample(configSampleRate) then
        self:_recordAnalyticsStat("suppressed", 1)
        return true
    end

    return self:_emitCustom(player, normalizedEventName, value, fields)
end

function GameAnalyticsService:TrackEconomy(player, flowType, currency, amount, balance, transactionType, itemSku, fields)
    self:_recordAnalyticsStat("attempted", 1)
    local config = getAnalyticsConfig()
    local normalizedFields = type(fields) == "table" and fields or {}
    local normalizedCurrency = tostring(currency or "Currency")
    local normalizedAmount = math.max(0, tonumber(amount) or 0)
    local normalizedBalance = math.max(0, tonumber(balance) or 0)
    local normalizedItemSku = tostring(itemSku or "Unknown")
    local normalizedSource = tostring(normalizedFields.source or "")
    local normalizedProductGroup = tostring(normalizedFields.productGroup or "")
    local normalizedTransactionType = ""
    if typeof(transactionType) == "EnumItem" then
        normalizedTransactionType = transactionType.Name
    else
        normalizedTransactionType = tostring(transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay.Name)
    end

    if isHighFrequencyEconomySource(normalizedSource) or isHighFrequencyEconomyItemSku(normalizedItemSku) then
        if not shouldSample(config.GameplayEconomySampleRate) then
            self:_recordAnalyticsStat("suppressed", 1)
            return true
        end

        local summaryBucketKey = string.format(
            "economy:%s:%s:%s:%s",
            normalizedSource,
            normalizedProductGroup,
            normalizedCurrency,
            normalizedItemSku
        )
        self:_addEconomySummaryValue(player, summaryBucketKey, {
            flowType = flowType,
            currency = normalizedCurrency,
            amount = normalizedAmount,
            balance = normalizedBalance,
            transactionType = transactionType,
            itemSku = normalizedItemSku,
            fields = normalizedFields,
        })
        self:_recordAnalyticsStat("suppressed", 1)
        self:_flushDueSummaries(player)
        return true
    end

    return self:_emitEconomy(player, flowType, normalizedCurrency, normalizedAmount, normalizedBalance, normalizedTransactionType, normalizedItemSku, fields)
end

function GameAnalyticsService:DebugSmokeTest(player)
    local targetPlayer = isPlayer(player) and player or Players:GetPlayers()[1]
    return self:TrackCustom(targetPlayer, "AnalyticsSmokeTest", 1, {
        source = "smoke",
    })
end

return GameAnalyticsService
