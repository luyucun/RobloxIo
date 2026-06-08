--[[
脚本名字: RebirthService
脚本文件: RebirthService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/RebirthService
说明: 管理重生积分、重生请求、付费重生和 Rebirth 数据持久化。
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
        "[RebirthService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local PotionConfig = requireSharedModule("PotionConfig")
local WheelConfig = requireSharedModule("WheelConfig")
local SkinConfig = requireSharedModule("SkinConfig")
local TrailConfig = requireSharedModule("TrailConfig")
local TitleConfig = requireSharedModule("TitleConfig")
local SevenDayLoginRewardConfig = requireSharedModule("SevenDayLoginRewardConfig")
local AttributeConfig = requireSharedModule("AttributeConfig")

local RebirthService = {}

RebirthService._playerStateService = nil
RebirthService._requestRebirthEvent = nil
RebirthService._rebirthFeedbackEvent = nil
RebirthService._healthService = nil
RebirthService._respawnService = nil
RebirthService._nukeService = nil
RebirthService._revengeService = nil
RebirthService._potionService = nil
RebirthService._wheelService = nil
RebirthService._skinService = nil
RebirthService._onlineRewardService = nil
RebirthService._sevenDayLoginRewardService = nil
RebirthService._attributeCapUpgradeService = nil
RebirthService._badgeAwardService = nil
RebirthService._gameAnalyticsService = nil
RebirthService._dataStore = nil
RebirthService._dirtyByUserId = {}
RebirthService._loadedByUserId = {}
RebirthService._loadStateByUserId = {}
RebirthService._loadRetryClockByUserId = {}
RebirthService._savedProgressCacheByUserId = {}
RebirthService._heartbeatConnection = nil
RebirthService._nextSaveClock = 0
RebirthService._shutdownInProgress = false

local function getUserId(player)
    return player and player.UserId or 0
end

local function getDataKey(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or tonumber(playerOrUserId)
    return tostring(userId or 0)
end

local function asNonNegativeInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function buildProgressSnapshot(rebirth, rebirthScore, highestLevelReached, savedProgress)
    return {
        rebirth = math.max(0, math.floor(tonumber(rebirth) or 0)),
        rebirthScore = math.max(0, math.floor(tonumber(rebirthScore) or 0)),
        highestLevelReached = math.clamp(
            math.floor(tonumber(highestLevelReached) or GameConfig.PLAYER.BaseLevel),
            1,
            GameConfig.PLAYER.MaxSupportedLevel
        ),
        savedProgress = type(savedProgress) == "table" and savedProgress or {},
        updatedAt = os.time(),
    }
end

local function buildPurchaseAnalyticsFields(productGroup, productId, source)
    return {
        source = tostring(source or "shop"),
        productGroup = tostring(productGroup or "Unknown"),
        itemSku = tostring(productId or "Unknown"),
    }
end

local function getUtcDayKey(timestamp)
    return math.floor(asNonNegativeInteger(timestamp) / 86400)
end

local function normalizeFavoritePromptState(favoritePromptState)
    local source = type(favoritePromptState) == "table" and favoritePromptState or {}
    local promptedAt = asNonNegativeInteger(source.PromptedAt or source.promptedAt)
    local lastPromptUtcDay = asNonNegativeInteger(source.LastPromptUtcDay or source.lastPromptUtcDay)
    if lastPromptUtcDay <= 0 and promptedAt > 0 then
        lastPromptUtcDay = getUtcDayKey(promptedAt)
    end

    local lastPromptResult = tostring(source.LastPromptResult or source.lastPromptResult or "")
    local legacyHasPrompted = source.HasPrompted == true or source.hasPrompted == true
    local hasFavorited = source.HasFavorited == true
        or source.hasFavorited == true
        or (legacyHasPrompted and lastPromptResult == "Success")

    return {
        HasFavorited = hasFavorited == true,
        PromptedAt = promptedAt,
        LastPromptUtcDay = lastPromptUtcDay,
        LastPromptResult = lastPromptResult,
        LastResultAt = asNonNegativeInteger(source.LastResultAt or source.lastResultAt),
    }
end

local function normalizeSevenDayLoginRewardState(rewardState)
    local source = type(rewardState) == "table" and rewardState or {}
    local rewardCount = SevenDayLoginRewardConfig.GetRewardCount()

    local function normalizeDayFlags(values)
        local normalized = {}
        if type(values) ~= "table" then
            return normalized
        end
        for key, value in pairs(values) do
            local dayIndex = math.max(0, math.floor(tonumber(key) or tonumber(value) or 0))
            if dayIndex >= 1 and dayIndex <= rewardCount and value == true then
                normalized[tostring(dayIndex)] = true
            end
        end
        return normalized
    end

    local function normalizeProcessedPurchases(values)
        local normalized = {}
        if type(values) ~= "table" then
            return normalized
        end
        for key, value in pairs(values) do
            local purchaseId = tostring(key or "")
            if purchaseId ~= "" then
                normalized[purchaseId] = math.max(0, math.floor(tonumber(value) or os.time()))
            end
        end
        return normalized
    end

    return {
        CycleId = math.max(0, math.floor(tonumber(source.CycleId or source.cycleId) or 0)),
        UnlockedDays = normalizeDayFlags(source.UnlockedDays or source.unlockedDays),
        ClaimedDays = normalizeDayFlags(source.ClaimedDays or source.claimedDays),
        LastClaimAt = math.max(0, math.floor(tonumber(source.LastClaimAt or source.lastClaimAt) or 0)),
        LastSequentialUnlockDay = math.clamp(math.floor(tonumber(source.LastSequentialUnlockDay or source.lastSequentialUnlockDay) or 0), 0, rewardCount),
        CycleStartUtcDay = math.max(0, math.floor(tonumber(source.CycleStartUtcDay or source.cycleStartUtcDay) or 0)),
        CycleStartsLockedUntilNextUtc = source.CycleStartsLockedUntilNextUtc == true or source.cycleStartsLockedUntilNextUtc == true,
        PendingCycleReset = source.PendingCycleReset == true or source.pendingCycleReset == true,
        ProcessedPurchaseIds = normalizeProcessedPurchases(source.ProcessedPurchaseIds or source.processedPurchaseIds),
    }
end

local function normalizeSavedData(data)
    if type(data) ~= "table" then
        return 0, 0, GameConfig.PLAYER.BaseLevel, {
            guideCompleted = false,
            favoritePromptState = normalizeFavoritePromptState(nil),
            sevenDayLoginRewardState = normalizeSevenDayLoginRewardState(nil),
            ownedTitles = {},
            equippedTitleId = nil,
            attributeCaps = AttributeConfig.BuildDefaultCaps(),
            totalDeaths = 0,
            totalDiamondsEarned = 0,
            totalOnlineSeconds = 0,
            hasUnseenTitleUnlock = false,
        }
    end

    local rebirth = math.max(0, math.floor(tonumber(data.rebirth) or tonumber(data.Rebirth) or 0))
    local rebirthScore = math.max(0, math.floor(tonumber(data.rebirthScore) or tonumber(data.RebirthScore) or 0))
    local highestLevelReached = math.clamp(
        math.floor(tonumber(data.highestLevelReached) or tonumber(data.HighestLevelReached) or GameConfig.PLAYER.BaseLevel),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )

    local potions = {}
    local savedPotions = type(data.potions) == "table" and data.potions or data.Potions
    if type(savedPotions) == "table" then
        for potionId, count in pairs(savedPotions) do
            local potion = PotionConfig.GetPotion(potionId)
            local resolvedCount = math.max(0, math.floor(tonumber(count) or 0))
            if potion and resolvedCount > 0 then
                potions[tostring(potion.Id)] = resolvedCount
            end
        end
    end

    local groupRewards = {}
    local savedGroupRewards = type(data.groupRewards) == "table" and data.groupRewards or data.GroupRewards
    if type(savedGroupRewards) == "table" then
        for groupId, claimed in pairs(savedGroupRewards) do
            local resolvedGroupId = math.floor(tonumber(groupId) or 0)
            if resolvedGroupId > 0 and claimed == true then
                groupRewards[tostring(resolvedGroupId)] = true
            end
        end
    end

    local subscriptionClaims = {}
    local savedSubscriptionClaims = type(data.subscriptionClaims) == "table" and data.subscriptionClaims or data.SubscriptionClaims
    if type(savedSubscriptionClaims) == "table" then
        for subscriptionId, utcDay in pairs(savedSubscriptionClaims) do
            local key = tostring(subscriptionId or "")
            local day = tostring(utcDay or "")
            if key ~= "" and day ~= "" then
                subscriptionClaims[key] = day
            end
        end
    end

    local shopClaims = {}
    local savedShopClaims = type(data.shopClaims) == "table" and data.shopClaims or data.ShopClaims
    if type(savedShopClaims) == "table" then
        for claimKey, claimed in pairs(savedShopClaims) do
            local key = tostring(claimKey or "")
            if key ~= "" and claimed == true then
                shopClaims[key] = true
            end
        end
    end

    local dailyFreeReviveClaims = {}
    local savedDailyFreeReviveClaims = type(data.dailyFreeReviveClaims) == "table" and data.dailyFreeReviveClaims or data.DailyFreeReviveClaims
    if type(savedDailyFreeReviveClaims) == "table" then
        for claimKey, utcDay in pairs(savedDailyFreeReviveClaims) do
            local key = tostring(claimKey or "")
            local day = tostring(utcDay or "")
            if key ~= "" and day ~= "" then
                dailyFreeReviveClaims[key] = day
            end
        end
    end

    local options = {
        Music = true,
        Sfx = true,
    }
    local savedOptions = type(data.options) == "table" and data.options or data.Options
    if type(savedOptions) == "table" then
        if type(savedOptions.Music) == "boolean" then
            options.Music = savedOptions.Music
        elseif type(savedOptions.musicEnabled) == "boolean" then
            options.Music = savedOptions.musicEnabled
        end
        if type(savedOptions.Sfx) == "boolean" then
            options.Sfx = savedOptions.Sfx
        elseif type(savedOptions.sfxEnabled) == "boolean" then
            options.Sfx = savedOptions.sfxEnabled
        end
    end

    local guideCompleted = true
    if type(data.guideCompleted) == "boolean" then
        guideCompleted = data.guideCompleted
    elseif type(data.GuideCompleted) == "boolean" then
        guideCompleted = data.GuideCompleted
    end

    local favoritePromptState = normalizeFavoritePromptState(data.favoritePromptState or data.FavoritePromptState)
    local sevenDayLoginRewardState = normalizeSevenDayLoginRewardState(data.sevenDayLoginRewardState or data.SevenDayLoginRewardState)

    local ownedSkins = {}
    local savedOwnedSkins = type(data.ownedSkins) == "table" and data.ownedSkins or data.OwnedSkins
    if type(savedOwnedSkins) == "table" then
        for skinKey, owned in pairs(savedOwnedSkins) do
            local skinId = owned == true and math.floor(tonumber(skinKey) or 0) or math.floor(tonumber(owned) or 0)
            if skinId > 0 and SkinConfig.GetSkin(skinId) and (owned == true or tonumber(owned) ~= nil) then
                ownedSkins[tostring(skinId)] = true
            end
        end
    end

    local equippedSkinId = math.floor(tonumber(data.equippedSkinId) or tonumber(data.EquippedSkinId) or 0)
    if equippedSkinId <= 0 or not (SkinConfig.GetSkin(equippedSkinId) and ownedSkins[tostring(equippedSkinId)] == true) then
        equippedSkinId = nil
    end

    local ownedTrails = {}
    local savedOwnedTrails = type(data.ownedTrails) == "table" and data.ownedTrails or data.OwnedTrails
    if type(savedOwnedTrails) == "table" then
        for trailKey, owned in pairs(savedOwnedTrails) do
            local trailId = owned == true and math.floor(tonumber(trailKey) or 0) or math.floor(tonumber(owned) or 0)
            if trailId > 0 and TrailConfig.GetTrail(trailId) and (owned == true or tonumber(owned) ~= nil) then
                ownedTrails[tostring(trailId)] = true
            end
        end
    end
    for _, trail in ipairs(TrailConfig.GetAllTrails()) do
        if trail.IsDefaultUnlocked == true then
            ownedTrails[tostring(trail.Id)] = true
        end
    end

    local equippedTrailId = math.floor(tonumber(data.equippedTrailId) or tonumber(data.EquippedTrailId) or 0)
    if equippedTrailId <= 0 or not (TrailConfig.GetTrail(equippedTrailId) and ownedTrails[tostring(equippedTrailId)] == true) then
        equippedTrailId = nil
    end

    local ownedTitles = {}
    local savedOwnedTitles = type(data.ownedTitles) == "table" and data.ownedTitles or data.OwnedTitles
    if type(savedOwnedTitles) == "table" then
        for titleKey, owned in pairs(savedOwnedTitles) do
            local titleId = owned == true and math.floor(tonumber(titleKey) or 0) or math.floor(tonumber(owned) or 0)
            if titleId > 0 and TitleConfig.GetTitle(titleId) and (owned == true or tonumber(owned) ~= nil) then
                ownedTitles[tostring(titleId)] = true
            end
        end
    end

    local equippedTitleId = math.floor(tonumber(data.equippedTitleId) or tonumber(data.EquippedTitleId) or 0)
    if equippedTitleId <= 0 or not (TitleConfig.GetTitle(equippedTitleId) and ownedTitles[tostring(equippedTitleId)] == true) then
        equippedTitleId = nil
    end

    local attributeCaps = AttributeConfig.NormalizeCaps(data.attributeCaps or data.AttributeCaps)

    local function normalizeWeaponUnlockRewards(rewards)
        if type(rewards) ~= "table" then
            return nil
        end

        local normalized = {
            ClaimedTiers = {},
            PendingQueue = {},
        }
        local savedLastPromptedTierIndex = rewards.lastPromptedTierIndex or rewards.LastPromptedTierIndex
        if savedLastPromptedTierIndex ~= nil then
            normalized.LastPromptedTierIndex = math.max(1, math.floor(tonumber(savedLastPromptedTierIndex) or 1))
        end
        local claimedTiers = rewards.claimedTiers or rewards.ClaimedTiers or rewards.claimed or rewards.Claimed
        if type(claimedTiers) == "table" then
            for tierKey, claimed in pairs(claimedTiers) do
                local tierIndex = math.floor(tonumber(tierKey) or tonumber(claimed) or 0)
                if tierIndex > 0 and (claimed == true or tonumber(claimed) ~= nil) then
                    normalized.ClaimedTiers[tostring(tierIndex)] = true
                end
            end
        end

        local pendingQueue = rewards.pendingQueue or rewards.PendingQueue or rewards.pendingTiers or rewards.PendingTiers
        if type(pendingQueue) == "table" then
            local seen = {}
            for _, pendingTier in ipairs(pendingQueue) do
                local tierIndex = math.floor(tonumber(pendingTier) or 0)
                local key = tostring(tierIndex)
                if tierIndex > 1 and normalized.ClaimedTiers[key] ~= true and seen[key] ~= true then
                    seen[key] = true
                    table.insert(normalized.PendingQueue, tierIndex)
                end
            end
            table.sort(normalized.PendingQueue)
        end

        return normalized
    end

    local function normalizeSavedActivePotion(activePotion, fallbackPotionId)
        if type(activePotion) ~= "table" then
            return nil
        end

        local potion = PotionConfig.GetPotion(activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId or fallbackPotionId)
        local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
        if potion and expiresAt > os.time() then
            return {
                Id = potion.Id,
                StartedAt = tonumber(activePotion.StartedAt or activePotion.startedAt) or os.time(),
                ExpiresAt = expiresAt,
                ExperienceBonus = math.max(0, tonumber(activePotion.ExperienceBonus or activePotion.experienceBonus) or tonumber(potion.ExperienceBonus) or 0),
                MoveSpeedBonus = math.max(0, tonumber(activePotion.MoveSpeedBonus or activePotion.moveSpeedBonus) or tonumber(potion.MoveSpeedBonus) or 0),
                Source = tostring(activePotion.Source or activePotion.source or "Saved"),
            }
        end

        return nil
    end

    local activePotions = {}
    local savedActivePotions = type(data.activePotions) == "table" and data.activePotions or data.ActivePotions
    if type(savedActivePotions) == "table" then
        for potionId, activePotion in pairs(savedActivePotions) do
            local normalizedPotion = normalizeSavedActivePotion(activePotion, potionId)
            if normalizedPotion then
                activePotions[tostring(normalizedPotion.Id)] = normalizedPotion
            end
        end
    end

    local savedActivePotion = type(data.activePotion) == "table" and data.activePotion or data.ActivePotion
    local legacyActivePotion = normalizeSavedActivePotion(savedActivePotion)
    if legacyActivePotion and not activePotions[tostring(legacyActivePotion.Id)] then
        activePotions[tostring(legacyActivePotion.Id)] = legacyActivePotion
    end

    local combatSnapshot = nil
    local savedCombatSnapshot = type(data.combatSnapshot) == "table" and data.combatSnapshot or data.CombatSnapshot
    if type(savedCombatSnapshot) == "table" then
        local restoreEligible = savedCombatSnapshot.restoreEligible == true
        local savedAt = math.floor(tonumber(savedCombatSnapshot.savedAt) or 0)
        local level = math.floor(tonumber(savedCombatSnapshot.level) or 0)
        local experience = math.max(0, math.floor(tonumber(savedCombatSnapshot.experience) or 0))
        local maxAge = math.max(1, tonumber(GameConfig.REBIRTH.CombatSnapshotMaxAgeSeconds) or 1800)
        local respawnMode = tostring(savedCombatSnapshot.respawnMode or "")
        local bypassMaxAge = respawnMode == "DefeatedHalfLevel"
        if restoreEligible and savedAt > 0 and level >= 1 and (bypassMaxAge or (os.time() - savedAt) <= maxAge) then
            combatSnapshot = {
                schemaVersion = math.max(1, math.floor(tonumber(savedCombatSnapshot.schemaVersion) or 1)),
                restoreEligible = true,
                respawnMode = respawnMode,
                savedAt = savedAt,
                level = math.clamp(level, 1, GameConfig.PLAYER.MaxSupportedLevel),
                experience = experience,
            }
        end
    end

    return rebirth, rebirthScore, highestLevelReached, {
        diamonds = math.max(0, math.floor(tonumber(data.diamonds) or tonumber(data.Diamonds) or 0)),
        wheelSpins = math.max(0, math.floor(tonumber(data.wheelSpins) or tonumber(data.WheelSpins) or 0)),
        potions = potions,
        groupRewards = groupRewards,
        subscriptionClaims = subscriptionClaims,
        shopClaims = shopClaims,
        dailyFreeReviveClaims = dailyFreeReviveClaims,
        options = options,
        guideCompleted = guideCompleted,
        favoritePromptState = favoritePromptState,
        sevenDayLoginRewardState = sevenDayLoginRewardState,
        ownedSkins = ownedSkins,
        equippedSkinId = equippedSkinId,
        ownedTrails = ownedTrails,
        equippedTrailId = equippedTrailId,
        ownedTitles = ownedTitles,
        equippedTitleId = equippedTitleId,
        attributeCaps = attributeCaps,
        totalDeaths = asNonNegativeInteger(data.totalDeaths or data.TotalDeaths),
        totalDiamondsEarned = asNonNegativeInteger(data.totalDiamondsEarned or data.TotalDiamondsEarned),
        totalOnlineSeconds = asNonNegativeInteger(data.totalOnlineSeconds or data.TotalOnlineSeconds),
        hasUnseenTitleUnlock = data.hasUnseenTitleUnlock == true or data.HasUnseenTitleUnlock == true,
        weaponUnlockRewards = normalizeWeaponUnlockRewards(data.weaponUnlockRewards or data.WeaponUnlockRewards),
        combatSnapshot = combatSnapshot,
        activePotions = activePotions,
        activePotion = legacyActivePotion,
    }
end

function RebirthService:_fireFeedback(player, eventType, message)
    if not (self._rebirthFeedbackEvent and player and player.Parent) then
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    self._rebirthFeedbackEvent:FireClient(player, {
        eventType = eventType,
        message = message,
        rebirth = state and state.Rebirth or 0,
        rebirthScore = state and state.RebirthScore or 0,
        nextRebirthScore = state and GameConfig.GetRequiredRebirthScore(state.Rebirth) or GameConfig.GetRequiredRebirthScore(0),
        timestamp = os.clock(),
    })
end

function RebirthService:_trackShopPurchaseFunnel(player, stepNumber, stepName, productGroup, productId, source)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackFunnel) then
        return
    end

    self._gameAnalyticsService:TrackFunnel(
        player,
        "ShopPurchase",
        stepNumber,
        stepName,
        buildPurchaseAnalyticsFields(productGroup, productId, source)
    )
end

function RebirthService:MarkDirty(actor)
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local userId = getUserId(actor)
    if userId > 0 and self:CanWritePersistentProgress(actor) then
        self._dirtyByUserId[userId] = true
    end
end

function RebirthService:IsPlayerLoaded(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end
    return self._loadStateByUserId[userId] == "Loaded"
end

function RebirthService:CanWritePersistentProgress(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end
    return self._loadStateByUserId[userId] == "Loaded"
end

function RebirthService:_awardNewPlayerBadge(player)
    if self._badgeAwardService and self._badgeAwardService.AwardBadgeAsync then
        self._badgeAwardService:AwardBadgeAsync(player, "NewPlayerWelcome", "NewPlayer")
    end
end

function RebirthService:_syncSkinStateAfterLoad(player)
    if self._skinService and self._skinService.SyncState and player and player.Parent then
        self._skinService:SyncState(player)
    end
end

function RebirthService:_loadPlayer(player)
    if not (player and player.Parent and self._playerStateService) then
        return
    end

    local userId = getUserId(player)
    if userId <= 0 or self._loadedByUserId[userId] then
        return
    end
    self._loadedByUserId[userId] = true
    self._loadStateByUserId[userId] = "Pending"

    if not self._dataStore then
        local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(nil)
        self._playerStateService:SetRebirthData(player, rebirth, rebirthScore, highestLevelReached, savedProgress)
        self:_awardNewPlayerBadge(player)
        self._loadStateByUserId[userId] = "Loaded"
        self._loadRetryClockByUserId[userId] = nil
        self:_syncSkinStateAfterLoad(player)
        self._savedProgressCacheByUserId[userId] = {
            snapshot = buildProgressSnapshot(rebirth, rebirthScore, highestLevelReached, savedProgress),
            clock = os.clock(),
        }
        if self._gameAnalyticsService and self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(player, "Onboarding.PlayerDataReady") then
            self._gameAnalyticsService:TrackFunnel(player, "Onboarding", 2, "PlayerDataReady", {
                source = "data",
            })
        end
        return
    end

    local success, data = pcall(function()
        return self._dataStore:GetAsync(getDataKey(player))
    end)
    if not success then
        warn("[RebirthService] 读取 Rebirth 数据失败: " .. tostring(player.Name))
        self._loadedByUserId[userId] = nil
        self._loadStateByUserId[userId] = "LoadFailed"
        self._loadRetryClockByUserId[userId] = os.clock() + 5
        return
    end

    local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(data)
    self._playerStateService:SetRebirthData(player, rebirth, rebirthScore, highestLevelReached, savedProgress)
    self._savedProgressCacheByUserId[userId] = {
        snapshot = buildProgressSnapshot(rebirth, rebirthScore, highestLevelReached, savedProgress),
        clock = os.clock(),
    }
    if self._sevenDayLoginRewardService and self._sevenDayLoginRewardService.OnPlayerAdded then
        self._sevenDayLoginRewardService:OnPlayerAdded(player)
    end
    if data == nil then
        self:_awardNewPlayerBadge(player)
    end
    self._loadStateByUserId[userId] = "Loaded"
    self._loadRetryClockByUserId[userId] = nil
    self:_syncSkinStateAfterLoad(player)
    if self._gameAnalyticsService and self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(player, "Onboarding.PlayerDataReady") then
        self._gameAnalyticsService:TrackFunnel(player, "Onboarding", 2, "PlayerDataReady", {
            source = "data",
        })
    end
    if savedProgress and savedProgress.combatSnapshot then
        self._dirtyByUserId[userId] = true
    else
        self._dirtyByUserId[userId] = nil
    end
end

function RebirthService:_buildSavePayload(player, options)
    if not (player and self._dataStore and self._playerStateService) then
        return nil
    end

    if not self:CanWritePersistentProgress(player) then
        return nil
    end

    if self._playerStateService.RefreshOnlineTime then
        self._playerStateService:RefreshOnlineTime(player, true)
    end
    local state = self._playerStateService:GetState(player)
    local includeCombatSnapshot = options and options.includeCombatSnapshot == true
    local combatSnapshot = nil
    if includeCombatSnapshot and state and state.IsInArena == true and state.Alive == true then
        combatSnapshot = {
            schemaVersion = 1,
            restoreEligible = true,
            savedAt = os.time(),
            level = math.max(1, math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel)),
            experience = math.max(0, math.floor(tonumber(state.Experience) or 0)),
        }
    elseif self._respawnService and self._respawnService.GetOfflineRespawnSaveSnapshot then
        combatSnapshot = self._respawnService:GetOfflineRespawnSaveSnapshot(player)
    end

    local payload = {
        rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0)),
        rebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0)),
        highestLevelReached = math.max(1, math.floor(tonumber(state.HighestLevelReached) or GameConfig.PLAYER.BaseLevel)),
        diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0)),
        wheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0)),
        potions = state.Potions or {},
        groupRewards = state.GroupRewards or {},
        subscriptionClaims = state.SubscriptionClaims or {},
        shopClaims = state.ShopClaims or {},
        codeClaims = state.CodeClaims or {},
        dailyFreeReviveClaims = state.DailyFreeReviveClaims or {},
        sevenDayLoginRewardState = normalizeSevenDayLoginRewardState(state.SevenDayLoginRewardState),
        options = state.Options or { Music = true, Sfx = true },
        guideCompleted = state.GuideCompleted == true,
        favoritePromptState = self._playerStateService.GetFavoritePromptState and self._playerStateService:GetFavoritePromptState(player) or state.FavoritePromptState or {},
        ownedSkins = state.OwnedSkins or {},
        equippedSkinId = state.EquippedSkinId,
        ownedTrails = state.OwnedTrails or {},
        equippedTrailId = state.EquippedTrailId,
        ownedTitles = state.OwnedTitles or {},
        equippedTitleId = state.EquippedTitleId,
        attributeCaps = AttributeConfig.CopyNumberMap(state.AttributeCaps),
        totalDeaths = math.max(0, math.floor(tonumber(state.TotalDeaths) or 0)),
        totalDiamondsEarned = math.max(0, math.floor(tonumber(state.TotalDiamondsEarned) or 0)),
        totalOnlineSeconds = math.max(0, math.floor(tonumber(state.TotalOnlineSeconds) or 0)),
        hasUnseenTitleUnlock = state.HasUnseenTitleUnlock == true,
        weaponUnlockRewards = state.WeaponUnlockRewards or {},
        combatSnapshot = combatSnapshot,
        activePotions = self._playerStateService:GetActivePotions(player),
        activePotion = self._playerStateService:GetActivePotion(player),
        updatedAt = os.time(),
    }

    return payload
end

function RebirthService:_savePlayer(player, options)
    local payload = self:_buildSavePayload(player, options)
    if not payload then
        return false
    end

    local success = pcall(function()
        self._dataStore:SetAsync(getDataKey(player), payload)
    end)
    if success then
        self._dirtyByUserId[getUserId(player)] = nil
        self._savedProgressCacheByUserId[getUserId(player)] = {
            snapshot = buildProgressSnapshot(payload.rebirth, payload.rebirthScore, payload.highestLevelReached, {
                diamonds = payload.diamonds,
                wheelSpins = payload.wheelSpins,
                potions = payload.potions,
                groupRewards = payload.groupRewards,
                subscriptionClaims = payload.subscriptionClaims,
                shopClaims = payload.shopClaims,
                dailyFreeReviveClaims = payload.dailyFreeReviveClaims,
                options = payload.options,
                guideCompleted = payload.guideCompleted,
                favoritePromptState = payload.favoritePromptState,
                sevenDayLoginRewardState = payload.sevenDayLoginRewardState,
                ownedSkins = payload.ownedSkins,
                equippedSkinId = payload.equippedSkinId,
                ownedTrails = payload.ownedTrails,
                equippedTrailId = payload.equippedTrailId,
                ownedTitles = payload.ownedTitles,
                equippedTitleId = payload.equippedTitleId,
                attributeCaps = payload.attributeCaps,
                totalDeaths = payload.totalDeaths,
                totalDiamondsEarned = payload.totalDiamondsEarned,
                totalOnlineSeconds = payload.totalOnlineSeconds,
                hasUnseenTitleUnlock = payload.hasUnseenTitleUnlock,
                weaponUnlockRewards = payload.weaponUnlockRewards,
                combatSnapshot = payload.combatSnapshot,
                activePotions = payload.activePotions,
                activePotion = payload.activePotion,
            }),
            clock = os.clock(),
        }
    else
        warn("[RebirthService] 保存 Rebirth 数据失败: " .. tostring(player.Name))
    end
    return success
end

function RebirthService:GetSavedProgressSnapshot(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and getUserId(playerOrUserId) or math.floor(tonumber(playerOrUserId) or 0)
    if userId <= 0 then
        return buildProgressSnapshot(0, 0, GameConfig.PLAYER.BaseLevel)
    end

    local onlinePlayer = Players:GetPlayerByUserId(userId)
    local state = onlinePlayer and self._playerStateService and self._playerStateService:GetState(onlinePlayer) or nil
    if state then
        return buildProgressSnapshot(state.Rebirth, state.RebirthScore, state.HighestLevelReached or state.Level, {
            ownedTitles = state.OwnedTitles or {},
            equippedTitleId = state.EquippedTitleId,
            attributeCaps = AttributeConfig.CopyNumberMap(state.AttributeCaps),
            totalDeaths = state.TotalDeaths,
            totalDiamondsEarned = state.TotalDiamondsEarned,
            totalOnlineSeconds = state.TotalOnlineSeconds,
            hasUnseenTitleUnlock = state.HasUnseenTitleUnlock == true,
        })
    end

    local cached = self._savedProgressCacheByUserId[userId]
    if cached and os.clock() - (tonumber(cached.clock) or 0) < 60 and type(cached.snapshot) == "table" then
        return cached.snapshot
    end

    if not self._dataStore then
        local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(nil)
        return buildProgressSnapshot(rebirth, rebirthScore, highestLevelReached, savedProgress)
    end

    local success, data = pcall(function()
        return self._dataStore:GetAsync(getDataKey(userId))
    end)
    if not success then
        warn("[RebirthService] 读取好友榜进度快照失败: " .. tostring(userId))
        return nil
    end

    local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(data)
    local snapshot = buildProgressSnapshot(rebirth, rebirthScore, highestLevelReached, savedProgress)
    self._savedProgressCacheByUserId[userId] = {
        snapshot = snapshot,
        clock = os.clock(),
    }
    return snapshot
end

function RebirthService:SavePlayerNow(player, options)
    if not (player and player.Parent) then
        return false
    end
    return self:_savePlayer(player, options)
end

function RebirthService:FlushPlayer(player, options)
    return self:SavePlayerNow(player, options)
end

function RebirthService:SaveAllPlayersForShutdown()
    self._shutdownInProgress = true
    local savedCount = 0
    for _, player in ipairs(Players:GetPlayers()) do
        if self:_savePlayer(player, { includeCombatSnapshot = true }) then
            savedCount += 1
        end
    end
    return savedCount
end

function RebirthService:_saveDirtyPlayers()
    for userId in pairs(self._dirtyByUserId) do
        local player = Players:GetPlayerByUserId(userId)
        if player then
            self:_savePlayer(player, { includeCombatSnapshot = self._shutdownInProgress == true })
        else
            self._dirtyByUserId[userId] = nil
        end
    end
end

function RebirthService:_step()
    local now = os.clock()
    for userId, retryClock in pairs(self._loadRetryClockByUserId) do
        if retryClock and now >= retryClock then
            local player = Players:GetPlayerByUserId(userId)
            if player then
                self:_loadPlayer(player)
            else
                self._loadRetryClockByUserId[userId] = nil
            end
        end
    end
    if now < self._nextSaveClock then
        return
    end

    self._nextSaveClock = now + math.max(5, tonumber(GameConfig.REBIRTH.AutoSaveIntervalSeconds) or 30)
    self:_saveDirtyPlayers()
end

function RebirthService:TryRebirth(player, options)
    if not (player and player.Parent and self._playerStateService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return false
    end

    local paid = options and options.paid == true
    if not paid and not self._playerStateService:CanRebirth(player) then
        self:_fireFeedback(player, "Failed", "Requirement not met")
        return false
    end

    local state = self._playerStateService:ApplyRebirth(player, not paid)
    self:MarkDirty(player)
    self:_savePlayer(player, { includeCombatSnapshot = self._shutdownInProgress == true })
    self:_fireFeedback(player, paid and "PaidSuccess" or "Success")
    return true, state
end

function RebirthService:_processDoubleLevel(player)
    if not (player and player.Parent and self._playerStateService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    local multiplier = GameConfig.MONETIZATION and GameConfig.MONETIZATION.DoubleLevelMultiplier or 2
    local success, newLevel = self._playerStateService:ApplyLevelMultiplier(player, multiplier)
    if success then
        print(string.format("[RebirthService] Double level granted to %s, newLevel=%d", player.Name, newLevel))
        return true
    end
    return false
end

function RebirthService:_processNuke(player)
    if not (player and player.Parent and self._nukeService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    local queued = self._nukeService:RequestNuke(player)
    if queued then
        print(string.format("[RebirthService] Nuke queued for %s", player.Name))
    end
    return queued
end

function RebirthService:_processRevenge(player)
    if not (player and player.Parent and self._revengeService and self._revengeService.RequestRevenge) then
        return false
    end

    if self._revengeService.MarkRevengePurchasePending then
        return self._revengeService:MarkRevengePurchasePending(player)
    end

    return self._revengeService:RequestRevenge(player)
end

function RebirthService:_processDefeatedRevive(player)
    if not (player and player.Parent and self._respawnService and self._respawnService.GrantDefeatedRevivePurchase) then
        return false
    end

    local success = self._respawnService:GrantDefeatedRevivePurchase(player)
    if success then
        print(string.format("[RebirthService] Defeated revive granted to %s", player.Name))
    end
    return success
end

function RebirthService:_processWheelPurchase(player, productId)
    if not (player and player.Parent and self._wheelService and self._wheelService.GrantPurchasedSpins) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "WheelSpins", productId, "shop")
    return self._wheelService:GrantPurchasedSpins(player, productId)
end

function RebirthService:_processReceipt(receiptInfo)
    local productId = receiptInfo.ProductId
    if self._skinService and self._skinService.ProcessReceipt then
        local handled, decision = self._skinService:ProcessReceipt(receiptInfo)
        if handled == true then
            return decision or Enum.ProductPurchaseDecision.NotProcessedYet
        end
    end

    if self._onlineRewardService and self._onlineRewardService.ProcessReceipt then
        local handled, decision = self._onlineRewardService:ProcessReceipt(receiptInfo)
        if handled == true then
            return decision or Enum.ProductPurchaseDecision.NotProcessedYet
        end
    end

    if self._sevenDayLoginRewardService and self._sevenDayLoginRewardService.ProcessReceipt then
        local handled, decision = self._sevenDayLoginRewardService:ProcessReceipt(receiptInfo)
        if handled == true then
            return decision or Enum.ProductPurchaseDecision.NotProcessedYet
        end
    end

    if self._attributeCapUpgradeService and self._attributeCapUpgradeService.ProcessReceipt then
        local handled, decision = self._attributeCapUpgradeService:ProcessReceipt(receiptInfo)
        if handled == true then
            return decision or Enum.ProductPurchaseDecision.NotProcessedYet
        end
    end

    local wheelPurchase = WheelConfig.GetPurchaseByProductId(productId)
    if wheelPurchase then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processWheelPurchase(player, productId)
        if success then
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "WheelSpins", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local potion = PotionConfig.GetPotionByProductId(productId)
    if potion then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self._potionService and self._potionService:GrantRobuxPotion(player, productId)
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "Potion", productId, "shop")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "Potion", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if productId == GameConfig.REBIRTH.PaidRebirthProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:TryRebirth(player, { paid = true })
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "PaidRebirth", productId, "shop")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "PaidRebirth", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.DefeatedReviveProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processDefeatedRevive(player)
        if self._gameAnalyticsService and success then
            self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 4, "ProductReceiptGranted", {
                source = "defeated",
            })
        end
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "DefeatedRevive", productId, "defeated")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "DefeatedRevive", productId, "defeated")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.DoubleLevelProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processDoubleLevel(player)
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "DoubleLevel", productId, "shop")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "DoubleLevel", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.NukeProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processNuke(player)
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "Nuke", productId, "shop")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "Nuke", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.RevengeProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processRevenge(player)
        if success then
            self:_trackShopPurchaseFunnel(player, 5, "ProductReceiptGranted", "Revenge", productId, "shop")
            self:_trackShopPurchaseFunnel(player, 6, "RewardDelivered", "Revenge", productId, "shop")
        end
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    return Enum.ProductPurchaseDecision.NotProcessedYet
end

function RebirthService:BindSystems(dependencies)
    self._healthService = dependencies and dependencies.HealthService or self._healthService
    self._respawnService = dependencies and dependencies.RespawnService or self._respawnService
    self._nukeService = dependencies and dependencies.NukeService or self._nukeService
    self._revengeService = dependencies and dependencies.RevengeService or self._revengeService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._wheelService = dependencies and dependencies.WheelService or self._wheelService
    self._skinService = dependencies and dependencies.SkinService or self._skinService
    self._onlineRewardService = dependencies and dependencies.OnlineRewardService or self._onlineRewardService
    self._sevenDayLoginRewardService = dependencies and dependencies.SevenDayLoginRewardService or self._sevenDayLoginRewardService
    self._attributeCapUpgradeService = dependencies and dependencies.AttributeCapUpgradeService or self._attributeCapUpgradeService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function RebirthService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._requestRebirthEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestRebirth") or nil
    self._rebirthFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RebirthFeedback") or nil
    self._healthService = dependencies.HealthService or self._healthService
    self._respawnService = dependencies.RespawnService or self._respawnService
    self._nukeService = dependencies.NukeService or self._nukeService
    self._revengeService = dependencies.RevengeService or self._revengeService
    self._potionService = dependencies.PotionService or self._potionService
    self._wheelService = dependencies.WheelService or self._wheelService
    self._skinService = dependencies.SkinService or self._skinService
    self._onlineRewardService = dependencies.OnlineRewardService or self._onlineRewardService
    self._sevenDayLoginRewardService = dependencies.SevenDayLoginRewardService or self._sevenDayLoginRewardService
    self._attributeCapUpgradeService = dependencies.AttributeCapUpgradeService or self._attributeCapUpgradeService
    self._badgeAwardService = dependencies.BadgeAwardService or self._badgeAwardService
    self._gameAnalyticsService = dependencies.GameAnalyticsService or self._gameAnalyticsService
    self._dirtyByUserId = {}
    self._loadedByUserId = {}
    self._loadStateByUserId = {}
    self._loadRetryClockByUserId = {}
    self._savedProgressCacheByUserId = {}
    self._nextSaveClock = os.clock() + math.max(5, tonumber(GameConfig.REBIRTH.AutoSaveIntervalSeconds) or 30)
    self._shutdownInProgress = false

    local isStudio = RunService:IsStudio()
    local success, store = false, nil
    if GameConfig.ShouldUsePersistentDataStores(isStudio) then
        local storeName = GameConfig.GetEnvironmentDataStoreName(GameConfig.REBIRTH.DataStoreName, isStudio)
        success, store = pcall(function()
            return DataStoreService:GetDataStore(storeName)
        end)
    end
    self._dataStore = success and store or nil
    if not self._dataStore then
        if isStudio then
            print("[RebirthService] Studio 调试模式使用内存 Rebirth 数据；发布后会使用 DataStore。")
        else
            warn("[RebirthService] DataStore 不可用，Rebirth 本次仅保存在内存中。")
        end
    end

    if self._requestRebirthEvent then
        self._requestRebirthEvent.OnServerEvent:Connect(function(player)
            self:TryRebirth(player)
        end)
    end

    MarketplaceService.ProcessReceipt = function(receiptInfo)
        return self:_processReceipt(receiptInfo)
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end
    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

function RebirthService:OnPlayerAdded(player)
    task.spawn(function()
        self:_loadPlayer(player)
    end)
end

function RebirthService:OnPlayerRemoving(player)
    self:_savePlayer(player, { includeCombatSnapshot = self._shutdownInProgress == true })
    if self._respawnService and self._respawnService.ClearOfflineRespawnSaveSnapshot then
        self._respawnService:ClearOfflineRespawnSaveSnapshot(player)
    end
    if self._sevenDayLoginRewardService and self._sevenDayLoginRewardService.OnPlayerRemoving then
        self._sevenDayLoginRewardService:OnPlayerRemoving(player)
    end
    local userId = getUserId(player)
    self._dirtyByUserId[userId] = nil
    self._loadedByUserId[userId] = nil
    self._loadStateByUserId[userId] = nil
    self._loadRetryClockByUserId[userId] = nil
    self._savedProgressCacheByUserId[userId] = nil
end

return RebirthService
