--[[
脚本名字: PlayerStateService
脚本文件: PlayerStateService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/PlayerStateService
]]

local PhysicsService = game:GetService("PhysicsService")
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
        "[PlayerStateService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")
local PotionConfig = requireSharedModule("PotionConfig")
local SkinConfig = requireSharedModule("SkinConfig")
local TrailConfig = requireSharedModule("TrailConfig")
local TitleConfig = requireSharedModule("TitleConfig")
local SubscriptionConfig = requireSharedModule("SubscriptionConfig")
local AttributeConfig = requireSharedModule("AttributeConfig")
local ChestConfig = requireSharedModule("ChestConfig")

local PlayerStateService = {}

local OVERHEAD_HEALTH_BAR_NAME = "OverheadHealthBar"
local UI_FOLDER_NAME = "UI"
local LEADERSTATS_FOLDER_NAME = "leaderstats"
local LEADERSTAT_LEVEL_NAME = "Level"
local LEADERSTAT_KILLS_NAME = "Kills"
local LEGACY_LEADERSTAT_REBIRTH_NAME = "Rebirth"
local LEGACY_LEADERSTAT_RESPAWN_COUNT_NAME = "RespawnCount"
local DEFAULT_CHARACTER_COLLISION_GROUP = "IOCharacters"
local DEFAULT_MONSTER_COLLISION_GROUP = "IOMonsters"
local FRIEND_EXPERIENCE_BONUS_PER_FRIEND = 0.2
local OFFLINE_PROGRESS_RESPAWN_MODE = "OfflineProgress"
local DEFEATED_HALF_LEVEL_RESPAWN_MODE = "DefeatedHalfLevel"

-- Historical V6.7 allocation bounds, used only to migrate the retired 31-40 range.
local RETIRED_BLADE_RECOVERY_FIRST_LEVEL = 31
local RETIRED_BLADE_RECOVERY_LAST_LEVEL = 40

local function readLegacyBladeRecoveryCap(value)
    local cap = tonumber(value)
    if not cap or cap % 1 ~= 0 or cap < RETIRED_BLADE_RECOVERY_FIRST_LEVEL or cap > RETIRED_BLADE_RECOVERY_LAST_LEVEL then
        return 0
    end
    return cap
end

local function preserveLegacyBladeRecoveryCap(state, caps, savedLegacyCap)
    local rawCap = type(caps) == "table" and caps.BladeRecovery or nil
    state.LegacyBladeRecoveryCap = math.max(
        readLegacyBladeRecoveryCap(state.LegacyBladeRecoveryCap),
        readLegacyBladeRecoveryCap(rawCap),
        readLegacyBladeRecoveryCap(savedLegacyCap)
    )
end

local function countRetiredBladeRecoveryPoints(levels)
    local oldLevel = readLegacyBladeRecoveryCap(type(levels) == "table" and levels.BladeRecovery or nil)
    local retainedLevel = math.max(RETIRED_BLADE_RECOVERY_FIRST_LEVEL - 1, AttributeConfig.GetMaxCap("BladeRecovery"))
    return math.max(0, oldLevel - retainedLevel)
end

PlayerStateService._statesByActorId = {}
PlayerStateService._playerStateSyncEvent = nil
PlayerStateService._requestStateSyncEvent = nil
PlayerStateService._requestOptionStateSyncEvent = nil
PlayerStateService._requestOptionUpdateEvent = nil
PlayerStateService._levelUpFeedbackEvent = nil
PlayerStateService._requestStateConnection = nil
PlayerStateService._requestOptionStateConnection = nil
PlayerStateService._requestOptionUpdateConnection = nil
PlayerStateService._weaponService = nil
PlayerStateService._weaponUnlockRewardService = nil
PlayerStateService._leaderboardService = nil
PlayerStateService._rebirthService = nil
PlayerStateService._arenaProgressService = nil
PlayerStateService._healthService = nil
PlayerStateService._subscriptionService = nil
PlayerStateService._gameAnalyticsService = nil
PlayerStateService._skinService = nil
PlayerStateService._taskService = nil
PlayerStateService._specialEventService = nil
PlayerStateService._friendBonusRefreshToken = 0
PlayerStateService._friendBonusLoopToken = 0
PlayerStateService._onlineTimeLoopToken = 0
PlayerStateService._characterCollisionConnectionsByActorId = {}
PlayerStateService._perfStats = nil
PlayerStateService._nextPerfLogClock = 0

local function getActorId(actor)
    local actorId = ActorUtils.GetActorId(actor)
    if actorId == "" then
        error("[PlayerStateService] 无法解析 ActorId。")
    end
    return actorId
end

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function copyAnalyticsFields(context)
    local fields = {}
    local source = "system"
    local productGroup = nil

    if type(context) == "table" then
        if type(context.fields) == "table" then
            for key, value in pairs(context.fields) do
                fields[key] = value
            end
        end
        source = tostring(context.source or fields.source or source)
        productGroup = context.productGroup or fields.productGroup
        fields.itemSku = fields.itemSku or context.itemSku
    end

    fields.source = source
    if productGroup ~= nil then
        fields.productGroup = tostring(productGroup)
    end
    return fields
end

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function shouldBypassCombatSnapshotMaxAge(respawnMode)
    return respawnMode == DEFEATED_HALF_LEVEL_RESPAWN_MODE or respawnMode == OFFLINE_PROGRESS_RESPAWN_MODE
end

local function buildWeaponLoadout(level)
    return WeaponTierConfig.ResolveLoadoutForLevel(level)
end

local function normalizeLevel(value)
    return math.clamp(math.floor(tonumber(value) or GameConfig.PLAYER.BaseLevel), 1, GameConfig.PLAYER.MaxSupportedLevel)
end

local function getMoveSpeedForLevel(level)
    local normalizedLevel = normalizeLevel(level)
    if normalizedLevel >= 241 then
        return 18
    elseif normalizedLevel >= 161 then
        return 19
    end
    return 20
end

local function copyAttributeFinalStats(stats)
    local result = {}
    for key, value in pairs(stats or {}) do
        result[key] = value
    end
    return result
end

local function normalizeTierIndex(value)
    return math.clamp(
        math.floor(tonumber(value) or 1),
        1,
        math.max(1, #WeaponTierConfig.Order)
    )
end

local function ensureLevelGradient(levelLabel, gradientName, colorSequence)
    local gradient = levelLabel:FindFirstChild(gradientName)
    if gradient and not gradient:IsA("UIGradient") then
        gradient:Destroy()
        gradient = nil
    end

    if not gradient then
        gradient = Instance.new("UIGradient")
        gradient.Name = gradientName
        gradient.Color = colorSequence
        gradient.Enabled = false
        gradient.Parent = levelLabel
    end
    return gradient
end

local function ensureOverheadLevelLabel(root)
    if not root then
        return nil
    end

    local levelLabel = root:FindFirstChild("Level")
    if levelLabel and not levelLabel:IsA("TextLabel") then
        levelLabel:Destroy()
        levelLabel = nil
    end

    if not levelLabel then
        levelLabel = Instance.new("TextLabel")
        levelLabel.Name = "Level"
        levelLabel.BackgroundTransparency = 1
        levelLabel.Size = UDim2.new(1, 0, 0, 18)
        levelLabel.Font = Enum.Font.GothamBold
        levelLabel.Text = "Lv.1"
        levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        levelLabel.TextSize = 13
        levelLabel.TextStrokeTransparency = 0.6
        levelLabel.Parent = root
    end

    ensureLevelGradient(levelLabel, "High", ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 124)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 89, 89)),
    }))
    ensureLevelGradient(levelLabel, "Low", ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 220, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 145, 255)),
    }))

    return levelLabel
end

local function ensureOverheadTitleImage(root)
    if not root then
        return nil
    end

    local titleImage = root:FindFirstChild("Title")
    if titleImage and not titleImage:IsA("ImageLabel") then
        titleImage:Destroy()
        titleImage = nil
    end

    if not titleImage then
        titleImage = Instance.new("ImageLabel")
        titleImage.Name = "Title"
        titleImage.BackgroundTransparency = 1
        titleImage.BorderSizePixel = 0
        titleImage.AnchorPoint = Vector2.new(0.5, 1)
        titleImage.Position = UDim2.new(0.5, 0, 0, -4)
        titleImage.Size = UDim2.fromOffset(112, 30)
        titleImage.ScaleType = Enum.ScaleType.Fit
        titleImage.Visible = false
        titleImage.Parent = root
    end

    return titleImage
end

local function normalizePotionInventory(potions)
    local normalized = {}
    if type(potions) ~= "table" then
        return normalized
    end

    for potionId, count in pairs(potions) do
        local potion = PotionConfig.GetPotion(potionId)
        local resolvedCount = math.max(0, math.floor(tonumber(count) or 0))
        if potion and resolvedCount > 0 then
            normalized[tostring(potion.Id)] = resolvedCount
        end
    end
    return normalized
end

local function normalizeGroupRewards(groupRewards)
    local normalized = {}
    if type(groupRewards) ~= "table" then
        return normalized
    end

    for groupId, claimed in pairs(groupRewards) do
        local resolvedGroupId = math.floor(tonumber(groupId) or 0)
        if resolvedGroupId > 0 and claimed == true then
            normalized[tostring(resolvedGroupId)] = true
        end
    end
    return normalized
end

local function normalizeSubscriptionClaims(subscriptionClaims)
    local normalized = {}
    if type(subscriptionClaims) ~= "table" then
        return normalized
    end

    for subscriptionId, utcDay in pairs(subscriptionClaims) do
        local key = tostring(subscriptionId or "")
        local day = tostring(utcDay or "")
        if key ~= "" and day ~= "" then
            normalized[key] = day
        end
    end
    return normalized
end

local function normalizeShopClaims(shopClaims)
    local normalized = {}
    if type(shopClaims) ~= "table" then
        return normalized
    end

    for claimKey, claimed in pairs(shopClaims) do
        local key = tostring(claimKey or "")
        if key ~= "" and claimed == true then
            normalized[key] = true
        end
    end
    return normalized
end

local function normalizeCodeClaims(codeClaims)
    local normalized = {}
    if type(codeClaims) ~= "table" then
        return normalized
    end

    for claimKey, claimed in pairs(codeClaims) do
        local key = tostring(claimKey or "")
        if key ~= "" and claimed == true then
            normalized[key] = true
        end
    end
    return normalized
end

local function normalizeDailyFreeReviveClaims(dailyFreeReviveClaims)
    local normalized = {}
    if type(dailyFreeReviveClaims) ~= "table" then
        return normalized
    end

    for claimKey, utcDay in pairs(dailyFreeReviveClaims) do
        local key = tostring(claimKey or "")
        local day = tostring(utcDay or "")
        if key ~= "" and day ~= "" then
            normalized[key] = day
        end
    end
    return normalized
end

local function normalizeSevenDayLoginRewardState(rewardState)
    local source = type(rewardState) == "table" and rewardState or {}

    local function normalizeDayFlags(values)
        local normalized = {}
        if type(values) ~= "table" then
            return normalized
        end
        for key, value in pairs(values) do
            local dayIndex = math.max(0, math.floor(tonumber(key) or tonumber(value) or 0))
            if dayIndex >= 1 and dayIndex <= 7 and value == true then
                normalized[dayIndex] = true
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
        LastSequentialUnlockDay = math.clamp(math.floor(tonumber(source.LastSequentialUnlockDay or source.lastSequentialUnlockDay) or 0), 0, 7),
        CycleStartUtcDay = math.max(0, math.floor(tonumber(source.CycleStartUtcDay or source.cycleStartUtcDay) or 0)),
        CycleStartsLockedUntilNextUtc = source.CycleStartsLockedUntilNextUtc == true or source.cycleStartsLockedUntilNextUtc == true,
        PendingCycleReset = source.PendingCycleReset == true or source.pendingCycleReset == true,
        ProcessedPurchaseIds = normalizeProcessedPurchases(source.ProcessedPurchaseIds or source.processedPurchaseIds),
    }
end

local function normalizeOptions(options)
    local normalized = {
        Music = true,
        Sfx = true,
    }
    if type(options) ~= "table" then
        return normalized
    end

    if type(options.Music) == "boolean" then
        normalized.Music = options.Music
    elseif type(options.musicEnabled) == "boolean" then
        normalized.Music = options.musicEnabled
    end

    if type(options.Sfx) == "boolean" then
        normalized.Sfx = options.Sfx
    elseif type(options.sfxEnabled) == "boolean" then
        normalized.Sfx = options.sfxEnabled
    end

    return normalized
end

local function normalizeGuideCompleted(value, defaultValue)
    if type(value) == "boolean" then
        return value
    end
    return defaultValue == true
end

local function readGuideCompleted(data, defaultValue)
    if type(data) ~= "table" then
        return defaultValue == true
    end
    if type(data.guideCompleted) == "boolean" then
        return data.guideCompleted
    end
    if type(data.GuideCompleted) == "boolean" then
        return data.GuideCompleted
    end
    return defaultValue == true
end

local function normalizeOwnedSkins(ownedSkins)
    local normalized = {}
    if type(ownedSkins) ~= "table" then
        return normalized
    end

    for skinKey, owned in pairs(ownedSkins) do
        local skinId = owned == true and math.floor(tonumber(skinKey) or 0) or math.floor(tonumber(owned) or 0)
        if skinId > 0 and SkinConfig.GetSkin(skinId) and (owned == true or tonumber(owned) ~= nil) then
            normalized[tostring(skinId)] = true
        end
    end
    return normalized
end

local function normalizeEquippedSkinId(equippedSkinId, ownedSkins)
    local skinId = math.floor(tonumber(equippedSkinId) or 0)
    if skinId > 0 and SkinConfig.GetSkin(skinId) and type(ownedSkins) == "table" and ownedSkins[tostring(skinId)] == true then
        return skinId
    end
    return nil
end

local function normalizeOwnedTrails(ownedTrails)
    local normalized = {}
    if type(ownedTrails) == "table" then
        for trailKey, owned in pairs(ownedTrails) do
            local trailId = owned == true and math.floor(tonumber(trailKey) or 0) or math.floor(tonumber(owned) or 0)
            if trailId > 0 and TrailConfig.GetTrail(trailId) and (owned == true or tonumber(owned) ~= nil) then
                normalized[tostring(trailId)] = true
            end
        end
    end

    for _, trail in ipairs(TrailConfig.GetAllTrails()) do
        if trail.IsDefaultUnlocked == true then
            normalized[tostring(trail.Id)] = true
        end
    end
    return normalized
end

local function normalizeEquippedTrailId(equippedTrailId, ownedTrails)
    local trailId = math.floor(tonumber(equippedTrailId) or 0)
    if trailId > 0 and TrailConfig.GetTrail(trailId) and type(ownedTrails) == "table" and ownedTrails[tostring(trailId)] == true then
        return trailId
    end
    return nil
end

local function normalizeChests(chests)
    local normalized = {}
    if type(chests) ~= "table" then
        return normalized
    end

    for chestKey, count in pairs(chests) do
        local chestId = math.floor(tonumber(chestKey) or 0)
        local amount = math.max(0, math.floor(tonumber(count) or 0))
        if chestId > 0 and amount > 0 and ChestConfig.GetChest(chestId) then
            normalized[tostring(chestId)] = amount
        end
    end
    return normalized
end

local function normalizeOwnedTitles(ownedTitles)
    local normalized = {}
    if type(ownedTitles) ~= "table" then
        return normalized
    end

    for titleKey, owned in pairs(ownedTitles) do
        local titleId = owned == true and math.floor(tonumber(titleKey) or 0) or math.floor(tonumber(owned) or 0)
        if titleId > 0 and TitleConfig.GetTitle(titleId) and (owned == true or tonumber(owned) ~= nil) then
            normalized[tostring(titleId)] = true
        end
    end
    return normalized
end

local function normalizeEquippedTitleId(equippedTitleId, ownedTitles)
    local titleId = math.floor(tonumber(equippedTitleId) or 0)
    if titleId > 0 and TitleConfig.GetTitle(titleId) and type(ownedTitles) == "table" and ownedTitles[tostring(titleId)] == true then
        return titleId
    end
    return nil
end

local function shouldCountDiamondEarn(delta, context)
    if math.floor(tonumber(delta) or 0) <= 0 then
        return false
    end
    local source = ""
    if type(context) == "table" then
        source = tostring(context.source or context.Source or "")
    end
    source = string.lower(source)
    if source == "skin_refund" or source == "trail_refund" or string.find(source, "refund", 1, true) then
        return false
    end
    return true
end

local function copyArray(values)
    local result = {}
    if type(values) ~= "table" then
        return result
    end

    for _, value in ipairs(values) do
        table.insert(result, value)
    end
    return result
end

local function copyBooleanMap(values)
    local result = {}
    if type(values) ~= "table" then
        return result
    end

    for key, value in pairs(values) do
        if value == true then
            result[tostring(key)] = true
        end
    end
    return result
end

local function copyNumberMap(values)
    local result = {}
    if type(values) ~= "table" then
        return result
    end

    for key, value in pairs(values) do
        local amount = math.max(0, math.floor(tonumber(value) or 0))
        if amount > 0 then
            result[tostring(key)] = amount
        end
    end
    return result
end

local function normalizeNonNegativeInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function getUtcDayKey(timestamp)
    return math.floor(normalizeNonNegativeInteger(timestamp) / 86400)
end

local function normalizeFavoritePromptState(favoritePromptState)
    local source = type(favoritePromptState) == "table" and favoritePromptState or {}
    local promptedAt = normalizeNonNegativeInteger(source.PromptedAt or source.promptedAt)
    local lastPromptUtcDay = normalizeNonNegativeInteger(source.LastPromptUtcDay or source.lastPromptUtcDay)
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
        LastResultAt = normalizeNonNegativeInteger(source.LastResultAt or source.lastResultAt),
    }
end

local function normalizeWeaponUnlockRewards(rewards, maxPromptedTierIndex)
    local maxPromptedTier = normalizeTierIndex(maxPromptedTierIndex)
    local normalized = {
        ClaimedTiers = {},
        PendingQueue = {},
        LastPromptedTierIndex = maxPromptedTier,
    }
    if type(rewards) ~= "table" then
        return normalized
    end

    local savedLastPromptedTierIndex = rewards.LastPromptedTierIndex
        or rewards.lastPromptedTierIndex
        or rewards.MaxPromptedTierIndex
        or rewards.maxPromptedTierIndex
    if savedLastPromptedTierIndex ~= nil then
        normalized.LastPromptedTierIndex = math.clamp(
            math.floor(tonumber(savedLastPromptedTierIndex) or maxPromptedTier),
            1,
            maxPromptedTier
        )
    end

    local claimedTiers = rewards.ClaimedTiers or rewards.claimedTiers or rewards.claimed or rewards.Claimed
    if type(claimedTiers) == "table" then
        for tierKey, claimed in pairs(claimedTiers) do
            local tierIndex = math.floor(tonumber(tierKey) or tonumber(claimed) or 0)
            if tierIndex > 0 and (claimed == true or tonumber(claimed) ~= nil) then
                normalized.ClaimedTiers[tostring(tierIndex)] = true
            end
        end
    end

    local pendingQueue = rewards.PendingQueue or rewards.pendingQueue or rewards.PendingTiers or rewards.pendingTiers
    if type(pendingQueue) == "table" then
        local seenPending = {}
        for _, pendingTier in ipairs(pendingQueue) do
            local tierIndex = math.floor(tonumber(pendingTier) or 0)
            local key = tostring(tierIndex)
            if tierIndex > 1
                and tierIndex <= maxPromptedTier
                and normalized.ClaimedTiers[key] ~= true
                and seenPending[key] ~= true
            then
                seenPending[key] = true
                table.insert(normalized.PendingQueue, tierIndex)
            end
        end
        table.sort(normalized.PendingQueue)
    end

    return normalized
end

local function getMaxUnlockedTierIndexForLevel(level)
    local loadout = buildWeaponLoadout(level)
    return math.max(1, math.floor(tonumber(loadout.TierIndex) or 1))
end

local function buildHandledWeaponUnlockRewardsForLevel(level)
    local maxTierIndex = getMaxUnlockedTierIndexForLevel(level)
    return normalizeWeaponUnlockRewards({
        LastPromptedTierIndex = maxTierIndex,
    }, maxTierIndex)
end

local function normalizeActivePotion(activePotion, fallbackPotionId)
    if type(activePotion) ~= "table" then
        return nil
    end

    local potion = PotionConfig.GetPotion(activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId or fallbackPotionId)
    if not potion then
        return nil
    end

    local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
    if expiresAt <= os.time() then
        return nil
    end

    return {
        Id = potion.Id,
        StartedAt = tonumber(activePotion.StartedAt or activePotion.startedAt) or os.time(),
        ExpiresAt = expiresAt,
        ExperienceBonus = math.max(0, tonumber(activePotion.ExperienceBonus or activePotion.experienceBonus) or tonumber(potion.ExperienceBonus) or 0),
        MoveSpeedBonus = math.max(0, tonumber(activePotion.MoveSpeedBonus or activePotion.moveSpeedBonus) or tonumber(potion.MoveSpeedBonus) or 0),
        Source = tostring(activePotion.Source or activePotion.source or "Saved"),
    }
end

local function normalizeActivePotions(activePotions, legacyActivePotion)
    local normalized = {}

    if type(activePotions) == "table" then
        for potionId, activePotion in pairs(activePotions) do
            local normalizedPotion = normalizeActivePotion(activePotion, potionId)
            if normalizedPotion then
                normalized[tostring(normalizedPotion.Id)] = normalizedPotion
            end
        end
    end

    local normalizedLegacyPotion = normalizeActivePotion(legacyActivePotion)
    if normalizedLegacyPotion then
        local potionKey = tostring(normalizedLegacyPotion.Id)
        if not normalized[potionKey] then
            normalized[potionKey] = normalizedLegacyPotion
        end
    end

    return normalized
end

local function hasActivePotionEntries(activePotions)
    return type(activePotions) == "table" and next(activePotions) ~= nil
end

local function lerpColor(colorA, colorB, alpha)
    local t = math.clamp(tonumber(alpha) or 0, 0, 1)
    return Color3.new(
        colorA.R + ((colorB.R - colorA.R) * t),
        colorA.G + ((colorB.G - colorA.G) * t),
        colorA.B + ((colorB.B - colorA.B) * t)
    )
end

local function getHealthFillColor(healthRatio)
    local ratio = math.clamp(tonumber(healthRatio) or 0, 0, 1)
    local lowColor = Color3.fromRGB(255, 92, 92)
    local midColor = Color3.fromRGB(255, 204, 92)
    local highColor = Color3.fromRGB(90, 255, 138)

    if ratio >= 0.5 then
        return lerpColor(midColor, highColor, (ratio - 0.5) / 0.5)
    end

    return lerpColor(lowColor, midColor, ratio / 0.5)
end

local function updateOverheadShieldUi(root, shieldState, shouldShowHealthBar)
    local barBackground = root and root:FindFirstChild("BarBackground")
    local shield = barBackground and barBackground:FindFirstChild("Shield")
    if not (shield and shield:IsA("GuiObject")) then
        return
    end

    local isActive = shouldShowHealthBar == true and shieldState and shieldState.shieldActive == true
    local remainingSeconds = math.max(0, math.ceil(tonumber(shieldState and shieldState.shieldRemainingSeconds) or 0))
    shield.Visible = isActive and remainingSeconds > 0

    local countDownTime = shield:FindFirstChild("CountDownTime")
    if countDownTime and countDownTime:IsA("TextLabel") then
        countDownTime.Text = string.format("%dS", remainingSeconds)
    end
end

local function ensureOverheadEventImage(root)
    if not root then
        return nil
    end

    local barBackground = root:FindFirstChild("BarBackground")
    if not barBackground then
        return nil
    end

    local eventImage = barBackground:FindFirstChild("Event")
    local legacyEventImage = root:FindFirstChild("Event")
    if legacyEventImage and legacyEventImage ~= eventImage then
        if not eventImage and legacyEventImage:IsA("ImageLabel") then
            eventImage = legacyEventImage
            eventImage.Parent = barBackground
        else
            legacyEventImage:Destroy()
        end
    end

    if eventImage and not eventImage:IsA("ImageLabel") then
        eventImage:Destroy()
        eventImage = nil
    end

    if not eventImage then
        eventImage = Instance.new("ImageLabel")
        eventImage.Name = "Event"
        eventImage.BackgroundTransparency = 1
        eventImage.BorderSizePixel = 0
        eventImage.AnchorPoint = Vector2.new(0, 0.5)
        eventImage.Position = UDim2.new(1, 8, 0.5, 0)
        eventImage.Size = UDim2.fromOffset(28, 28)
        eventImage.ScaleType = Enum.ScaleType.Fit
        eventImage.Visible = false
        eventImage.Parent = barBackground

        local aspect = Instance.new("UIAspectRatioConstraint")
        aspect.AspectRatio = 1
        aspect.Parent = eventImage
    end

    return eventImage
end

local function updateOverheadEventUi(root, visualInfo)
    local eventImage = ensureOverheadEventImage(root)
    if not eventImage then
        return false
    end

    local iconImage = tostring(visualInfo and visualInfo.iconImage or "")
    local isActive = iconImage ~= ""
    if eventImage:GetAttribute("CurrentEventIconImage") ~= iconImage then
        eventImage:SetAttribute("CurrentEventIconImage", iconImage)
        eventImage.Image = iconImage
    end
    if eventImage.Visible ~= isActive then
        eventImage.Visible = isActive
    end
    return isActive
end

local function cacheOriginalNumberAttribute(instance, attributeName, value)
    if instance:GetAttribute(attributeName) == nil then
        instance:SetAttribute(attributeName, value)
    end
end

local function restoreDirectUiStrokeTransparency(container)
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("UIStroke") then
            local originalTransparency = tonumber(child:GetAttribute("OriginalTransparency"))
            if originalTransparency ~= nil and child.Transparency ~= originalTransparency then
                child.Transparency = originalTransparency
            end
        end
    end
end

local function hideDirectUiStrokeTransparency(container)
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("UIStroke") then
            cacheOriginalNumberAttribute(child, "OriginalTransparency", child.Transparency)
            if child.Transparency ~= 1 then
                child.Transparency = 1
            end
        end
    end
end

local function updateOverheadBarBackgroundUi(barBackground, fill, shouldShowHealthBar, hasActiveEventIcon)
    if not (barBackground and barBackground:IsA("GuiObject")) then
        return
    end

    cacheOriginalNumberAttribute(barBackground, "OriginalBackgroundTransparency", barBackground.BackgroundTransparency)
    local shouldShowContainer = shouldShowHealthBar == true or hasActiveEventIcon == true
    if barBackground.Visible ~= shouldShowContainer then
        barBackground.Visible = shouldShowContainer
    end

    if shouldShowHealthBar == true then
        local originalTransparency = tonumber(barBackground:GetAttribute("OriginalBackgroundTransparency"))
        if originalTransparency ~= nil and barBackground.BackgroundTransparency ~= originalTransparency then
            barBackground.BackgroundTransparency = originalTransparency
        end
        restoreDirectUiStrokeTransparency(barBackground)
    elseif hasActiveEventIcon == true then
        if barBackground.BackgroundTransparency ~= 1 then
            barBackground.BackgroundTransparency = 1
        end
        hideDirectUiStrokeTransparency(barBackground)
    end

    if fill and fill:IsA("GuiObject") and fill.Visible ~= shouldShowHealthBar then
        fill.Visible = shouldShowHealthBar == true
    end
end

local function ensureCollisionGroup(groupName)
    local found = false
    local success, groups = pcall(function()
        return PhysicsService:GetRegisteredCollisionGroups()
    end)
    if success and type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group.name == groupName or group.Name == groupName then
                found = true
                break
            end
        end
    end
    if not found then
        pcall(function()
            PhysicsService:RegisterCollisionGroup(groupName)
        end)
    end
end

local function setCollisionRule(groupA, groupB, canCollide)
    pcall(function()
        PhysicsService:CollisionGroupSetCollidable(groupA, groupB, canCollide == true)
    end)
end

local function setPartCollisionGroup(basePart, groupName)
    pcall(function()
        basePart.CollisionGroup = groupName
    end)
end

local function getCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.CharacterGroupName) or DEFAULT_CHARACTER_COLLISION_GROUP
end

local function getMonsterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.MonsterGroupName) or DEFAULT_MONSTER_COLLISION_GROUP
end

local function configureCharacterCollision(character)
    if not character then
        return
    end

    local characterGroup = getCharacterCollisionGroupName()
    local monsterGroup = getMonsterCollisionGroupName()
    ensureCollisionGroup(characterGroup)
    ensureCollisionGroup(monsterGroup)
    setCollisionRule(characterGroup, monsterGroup, false)

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end

    character.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end)
end

function PlayerStateService:_configureCharacterCollision(actor, character)
    if not character then
        return
    end

    local actorId = getActorId(actor)
    local oldConnection = self._characterCollisionConnectionsByActorId[actorId]
    if oldConnection and oldConnection.Connected then
        oldConnection:Disconnect()
    end
    self._characterCollisionConnectionsByActorId[actorId] = nil

    local characterGroup = getCharacterCollisionGroupName()
    local monsterGroup = getMonsterCollisionGroupName()
    ensureCollisionGroup(characterGroup)
    ensureCollisionGroup(monsterGroup)
    setCollisionRule(characterGroup, monsterGroup, false)

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end

    self._characterCollisionConnectionsByActorId[actorId] = character.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end)
end

local function getOrCreateIntValue(parent, valueName)
    local valueObject = parent:FindFirstChild(valueName)
    if valueObject and not valueObject:IsA("IntValue") then
        valueObject:Destroy()
        valueObject = nil
    end

    if not valueObject then
        valueObject = Instance.new("IntValue")
        valueObject.Name = valueName
        valueObject.Value = 0
        valueObject.Parent = parent
    end

    return valueObject
end

function PlayerStateService:_ensureLeaderstats(player)
    if not ActorUtils.IsPlayer(player) then
        return nil
    end

    local leaderstats = player:FindFirstChild(LEADERSTATS_FOLDER_NAME)
    if leaderstats and not leaderstats:IsA("Folder") then
        leaderstats:Destroy()
        leaderstats = nil
    end

    if not leaderstats then
        leaderstats = Instance.new("Folder")
        leaderstats.Name = LEADERSTATS_FOLDER_NAME
        leaderstats.Parent = player
    end

    local legacyRespawnCount = leaderstats:FindFirstChild(LEGACY_LEADERSTAT_RESPAWN_COUNT_NAME)
    if legacyRespawnCount then
        legacyRespawnCount:Destroy()
    end

    local legacyRebirth = leaderstats:FindFirstChild(LEGACY_LEADERSTAT_REBIRTH_NAME)
    if legacyRebirth then
        legacyRebirth:Destroy()
    end

    getOrCreateIntValue(leaderstats, LEADERSTAT_LEVEL_NAME)
    getOrCreateIntValue(leaderstats, LEADERSTAT_KILLS_NAME)
    return leaderstats
end

function PlayerStateService:_syncLeaderstats(actor, state)
    if not ActorUtils.IsPlayer(actor) then
        return false
    end

    local leaderstats = self:_ensureLeaderstats(actor)
    if not leaderstats then
        return false
    end

    local levelValue = leaderstats:FindFirstChild(LEADERSTAT_LEVEL_NAME)
    if levelValue and levelValue:IsA("IntValue") then
        levelValue.Value = math.max(0, math.floor(tonumber(state.Level) or 0))
    end

    local killsValue = leaderstats:FindFirstChild(LEADERSTAT_KILLS_NAME)
    if killsValue and killsValue:IsA("IntValue") then
        killsValue.Value = math.max(0, math.floor(tonumber(state.TotalPlayerKills) or 0))
    end

    return true
end

function PlayerStateService:_applyLevelDerivedState(state)
    state.Level = normalizeLevel(state.Level)
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or state.Level), state.Level)
    self:_normalizeAttributeState(state)
    local finalStats = state.FinalStats or AttributeConfig.CalculateFinalStats(state.AttributeLevels, state.AttributeCaps)
    local baseMaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    local specialEventEffect = self:GetSpecialEventEffect(state.ActorRef)
    local heartHealthMultiplier = math.max(1, tonumber(specialEventEffect and specialEventEffect.BaseMaxHealthMultiplier) or 1)
    state.BaseMaxHealth = baseMaxHealth
    state.MaxHealth = math.max(1, math.floor((baseMaxHealth * heartHealthMultiplier * (tonumber(finalStats.MaxHealthMultiplier) or 1)) + 0.5))
    state.NextLevelExperience = GameConfig.GetNextLevelExperience(state.Level)
    state.BaseMoveSpeed = getMoveSpeedForLevel(state.Level)
    state.MoveSpeed = state.BaseMoveSpeed
    state.Rebirth = math.max(0, math.floor(tonumber(state.Rebirth or state.RespawnCount) or 0))
    state.RespawnCount = nil
    state.RebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0))
    state.ExtraExperienceBonus = math.max(0, tonumber(state.ExtraExperienceBonus) or 0)
    state.FriendExperienceBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    state.FriendCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0))
    state.WheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0))
    state.Potions = normalizePotionInventory(state.Potions)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    state.SubscriptionClaims = normalizeSubscriptionClaims(state.SubscriptionClaims)
    state.ShopClaims = normalizeShopClaims(state.ShopClaims)
    state.CodeClaims = normalizeCodeClaims(state.CodeClaims)
    state.DailyFreeReviveClaims = normalizeDailyFreeReviveClaims(state.DailyFreeReviveClaims)
    state.SevenDayLoginRewardState = normalizeSevenDayLoginRewardState(state.SevenDayLoginRewardState)
    state.Options = normalizeOptions(state.Options)
    state.GuideCompleted = normalizeGuideCompleted(state.GuideCompleted, true)
    state.FavoritePromptState = normalizeFavoritePromptState(state.FavoritePromptState)
    state.OwnedSkins = normalizeOwnedSkins(state.OwnedSkins)
    state.EquippedSkinId = normalizeEquippedSkinId(state.EquippedSkinId, state.OwnedSkins)
    state.OwnedTrails = normalizeOwnedTrails(state.OwnedTrails)
    state.EquippedTrailId = normalizeEquippedTrailId(state.EquippedTrailId, state.OwnedTrails)
    state.OwnedTitles = normalizeOwnedTitles(state.OwnedTitles)
    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, state.OwnedTitles)
    state.TotalDeaths = normalizeNonNegativeInteger(state.TotalDeaths)
    state.TotalDiamondsEarned = normalizeNonNegativeInteger(state.TotalDiamondsEarned)
    state.TotalOnlineSeconds = normalizeNonNegativeInteger(state.TotalOnlineSeconds)
    state.HasUnseenTitleUnlock = state.HasUnseenTitleUnlock == true
    state.WeaponUnlockRewards = normalizeWeaponUnlockRewards(
        state.WeaponUnlockRewards,
        getMaxUnlockedTierIndexForLevel(state.HighestLevelReached or state.Level)
    )
    state.ActivePotions = normalizeActivePotions(state.ActivePotions, state.ActivePotion)
    state.ActivePotion = nil

    local loadout = buildWeaponLoadout(state.Level)
    state.DesiredWeaponTier = loadout.Tier
    state.DesiredWeaponTierIndex = loadout.TierIndex
    state.DesiredWeaponCount = loadout.Count
    state.DesiredWeaponIcon = loadout.IconImage or WeaponTierConfig.GetIconImageForTier(loadout.Tier)
    if state.IsInArena then
        state.WeaponTier = loadout.Tier
        state.WeaponTierIndex = loadout.TierIndex
        state.WeaponCount = loadout.Count
        state.WeaponIcon = state.DesiredWeaponIcon
    else
        state.WeaponTier = "None"
        state.WeaponTierIndex = 0
        state.WeaponCount = 0
        state.WeaponIcon = WeaponTierConfig.DefaultIconImage
    end

    state.CurrentHealth = math.clamp(tonumber(state.CurrentHealth) or state.MaxHealth, 0, state.MaxHealth)
end

function PlayerStateService:_createDefaultState(actor)
    local state = {
        ActorId = getActorId(actor),
        ActorKind = ActorUtils.GetActorKind(actor),
        ActorRef = actor,
        UserId = ActorUtils.GetCombatUserId(actor),
        IsInArena = false,
        Alive = true,
        Level = GameConfig.PLAYER.BaseLevel,
        HighestLevelReached = GameConfig.PLAYER.BaseLevel,
        Experience = GameConfig.PLAYER.BaseExperience,
        NextLevelExperience = GameConfig.GetNextLevelExperience(GameConfig.PLAYER.BaseLevel),
        CurrentHealth = GameConfig.PLAYER.BaseMaxHealth,
        MaxHealth = GameConfig.PLAYER.BaseMaxHealth,
        MoveSpeed = GameConfig.PLAYER.BaseMoveSpeed,
        WeaponTier = GameConfig.PLAYER.BaseWeaponTier,
        WeaponTierIndex = 1,
        WeaponCount = GameConfig.PLAYER.BaseWeaponCount,
        WeaponIcon = WeaponTierConfig.GetIconImageForTier(GameConfig.PLAYER.BaseWeaponTier),
        DesiredWeaponTier = GameConfig.PLAYER.BaseWeaponTier,
        DesiredWeaponTierIndex = 1,
        DesiredWeaponCount = GameConfig.PLAYER.BaseWeaponCount,
        DesiredWeaponIcon = WeaponTierConfig.GetIconImageForTier(GameConfig.PLAYER.BaseWeaponTier),
        KillCount = 0,
        TotalPlayerKills = 0,
        Rebirth = 0,
        RebirthScore = 0,
        ExtraExperienceBonus = 0,
        FriendExperienceBonus = 0,
        FriendCount = 0,
        Diamonds = 0,
        WheelSpins = 0,
        Potions = {},
        GroupRewards = {},
        SubscriptionClaims = {},
        ShopClaims = {},
        CodeClaims = {},
        DailyFreeReviveClaims = {},
        TaskState = {
            Daily = {
                CycleKey = "",
                ProgressByTaskId = {},
                ClaimedByTaskId = {},
                CompletedReportedByTaskId = {},
                LoginDays = {},
            },
            Weekly = {
                CycleKey = "",
                ProgressByTaskId = {},
                ClaimedByTaskId = {},
                CompletedReportedByTaskId = {},
                LoginDays = {},
            },
        },
        SevenDayLoginRewardState = normalizeSevenDayLoginRewardState(nil),
        Options = normalizeOptions(),
        GuideCompleted = true,
        FavoritePromptState = normalizeFavoritePromptState(nil),
        OwnedSkins = {},
        EquippedSkinId = nil,
        OwnedTrails = {},
        EquippedTrailId = nil,
        Chests = {},
        OwnedTitles = {},
        EquippedTitleId = nil,
        TotalDeaths = 0,
        TotalDiamondsEarned = 0,
        TotalOnlineSeconds = 0,
        HasUnseenTitleUnlock = false,
        WeaponUnlockRewards = normalizeWeaponUnlockRewards(nil, getMaxUnlockedTierIndexForLevel(GameConfig.PLAYER.BaseLevel)),
        ActivePotions = {},
        ActivePotion = nil,
        SkillPoints = 0,
        UsedSkillPoints = 0,
        MasteryPoints = 0,
        AttributeLevels = AttributeConfig.BuildDefaultLevels(),
        AttributeCaps = AttributeConfig.BuildDefaultCaps(),
        LegacyBladeRecoveryCap = 0,
        FinalStats = AttributeConfig.CalculateFinalStats(nil, nil),
        SessionStartedAt = os.time(),
        LastOnlineClock = os.clock(),
        Buffs = {},
    }
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    return state
end

function PlayerStateService:_normalizeAttributeState(state)
    if not state then
        return nil
    end

    preserveLegacyBladeRecoveryCap(state, state.AttributeCaps)
    state.AttributeCaps = AttributeConfig.NormalizeCaps(state.AttributeCaps)
    local disabledProgressionPoints = AttributeConfig.CountDisabledProgressionPoints(state.AttributeLevels, state.AttributeCaps)
    local retiredBladeRecoveryPoints = countRetiredBladeRecoveryPoints(state.AttributeLevels)
    state.AttributeLevels = AttributeConfig.NormalizeLevels(state.AttributeLevels, state.AttributeCaps)
    state.SkillPoints = math.max(0, math.floor(tonumber(state.SkillPoints) or 0)) + disabledProgressionPoints + retiredBladeRecoveryPoints
    state.UsedSkillPoints = AttributeConfig.CountUsedPoints(state.AttributeLevels)
    state.MasteryPoints = math.max(0, math.floor(tonumber(state.MasteryPoints) or 0))
    state.FinalStats = AttributeConfig.CalculateFinalStats(state.AttributeLevels, state.AttributeCaps)
    return state
end

function PlayerStateService:_resetAttributeProgress(state)
    if not state then
        return nil
    end

    state.SkillPoints = 0
    state.UsedSkillPoints = 0
    state.AttributeLevels = AttributeConfig.BuildDefaultLevels()
    preserveLegacyBladeRecoveryCap(state, state.AttributeCaps)
    state.AttributeCaps = AttributeConfig.NormalizeCaps(state.AttributeCaps)
    state.MasteryPoints = math.max(0, math.floor(tonumber(state.MasteryPoints) or 0))
    state.FinalStats = AttributeConfig.CalculateFinalStats(state.AttributeLevels, state.AttributeCaps)
    return state
end

function PlayerStateService:_awardSkillPointsForLevelGain(state, previousLevel, newLevel)
    local levelDelta = math.max(0, math.floor(tonumber(newLevel) or 0) - math.floor(tonumber(previousLevel) or 0))
    if levelDelta <= 0 then
        return 0
    end

    self:_normalizeAttributeState(state)
    local previousTotalPoints = AttributeConfig.GetTotalSkillPointsForLevel(previousLevel)
    local newTotalPoints = AttributeConfig.GetTotalSkillPointsForLevel(newLevel)
    local gainedPoints = math.max(0, newTotalPoints - previousTotalPoints)
    state.SkillPoints = math.max(0, math.floor(tonumber(state.SkillPoints) or 0)) + gainedPoints
    return gainedPoints
end

function PlayerStateService:_ensureSkillPointsForLevel(state, level)
    if not state then
        return 0
    end

    self:_normalizeAttributeState(state)
    local expectedTotalPoints = AttributeConfig.GetTotalSkillPointsForLevel(level)
    local availablePoints = math.max(0, math.floor(tonumber(state.SkillPoints) or 0))
    local usedPoints = math.max(0, math.floor(tonumber(state.UsedSkillPoints) or 0))
    local currentTotalPoints = availablePoints + usedPoints
    local missingPoints = math.max(0, expectedTotalPoints - currentTotalPoints)
    if missingPoints > 0 then
        state.SkillPoints += missingPoints
    end
    return missingPoints
end

function PlayerStateService:BuildAttributeSnapshot(actor)
    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    return {
        skillPoints = state.SkillPoints,
        usedSkillPoints = state.UsedSkillPoints,
        masteryPoints = state.MasteryPoints,
        attributeLevels = AttributeConfig.CopyNumberMap(state.AttributeLevels),
        attributeCaps = AttributeConfig.CopyNumberMap(state.AttributeCaps),
    }
end

function PlayerStateService:_applyAttributeSnapshot(state, snapshot)
    if type(snapshot) ~= "table" then
        return self:_resetAttributeProgress(state)
    end

    local snapshotCaps = snapshot.attributeCaps or snapshot.AttributeCaps or state.AttributeCaps
    preserveLegacyBladeRecoveryCap(state, state.AttributeCaps)
    preserveLegacyBladeRecoveryCap(state, snapshotCaps)
    state.AttributeCaps = AttributeConfig.NormalizeCaps(snapshotCaps)
    local snapshotLevels = snapshot.attributeLevels or snapshot.AttributeLevels
    local disabledProgressionPoints = AttributeConfig.CountDisabledProgressionPoints(snapshotLevels, state.AttributeCaps)
    local retiredBladeRecoveryPoints = countRetiredBladeRecoveryPoints(snapshotLevels)
    state.AttributeLevels = AttributeConfig.NormalizeLevels(snapshotLevels, state.AttributeCaps)
    state.SkillPoints = math.max(0, math.floor(tonumber(snapshot.skillPoints or snapshot.SkillPoints) or 0)) + disabledProgressionPoints + retiredBladeRecoveryPoints
    state.MasteryPoints = math.max(0, math.floor(tonumber(snapshot.masteryPoints or snapshot.MasteryPoints or state.MasteryPoints) or 0))
    state.UsedSkillPoints = AttributeConfig.CountUsedPoints(state.AttributeLevels)
    state.FinalStats = AttributeConfig.CalculateFinalStats(state.AttributeLevels, state.AttributeCaps)
    return state
end

function PlayerStateService:BuildAttributeStatePayload(actor)
    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    return {
        skillPoints = state.SkillPoints,
        usedSkillPoints = state.UsedSkillPoints,
        masteryPoints = state.MasteryPoints,
        attributeLevels = AttributeConfig.CopyNumberMap(state.AttributeLevels),
        attributeCaps = AttributeConfig.CopyNumberMap(state.AttributeCaps),
        finalStats = copyAttributeFinalStats(state.FinalStats),
    }
end

function PlayerStateService:GetAttributeCap(actor, attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return nil
    end

    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    return math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or 0))
end

function PlayerStateService:SetAttributeCap(actor, attributeKey, cap, context)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false, "InvalidAttribute", "Invalid attribute"
    end
    if AttributeConfig.IsProgressionDisabled(key) then
        return false, "AttributeDisabled", "Attribute disabled"
    end

    local definition = AttributeConfig.GetDefinition(key)
    local minCap = math.max(0, math.floor(tonumber(definition and definition.InitialCap) or 0))
    local maxCap = AttributeConfig.GetMaxCap(key)
    local targetCap = math.clamp(math.floor(tonumber(cap) or minCap), minCap, maxCap)
    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)

    local oldCap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or minCap))
    if oldCap == targetCap then
        return true, "Unchanged", "Unchanged", targetCap
    end

    state.AttributeCaps[key] = targetCap
    state.AttributeLevels = AttributeConfig.NormalizeLevels(state.AttributeLevels, state.AttributeCaps)
    self:_normalizeAttributeState(state)
    self:RecalculateDerivedStats(actor, type(context) == "table" and context.recalculateOptions or nil)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, "Updated", "Updated", targetCap, oldCap
end

function PlayerStateService:AddAttributeCap(actor, attributeKey, amount, context)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false, "InvalidAttribute", "Invalid attribute"
    end

    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    local currentCap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or 0))
    local delta = math.floor(tonumber(amount) or 0)
    return self:SetAttributeCap(actor, key, currentCap + delta, context)
end

function PlayerStateService:SetAllAttributeCaps(actor, cap, context)
    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)

    local requestedCap = math.floor(tonumber(cap) or 0)
    local changed = false
    for _, key in ipairs(AttributeConfig.Order) do
        if AttributeConfig.IsProgressionDisabled(key) then
            continue
        end
        local definition = AttributeConfig.GetDefinition(key)
        local minCap = math.max(0, math.floor(tonumber(definition and definition.InitialCap) or 0))
        local maxCap = AttributeConfig.GetMaxCap(key)
        local targetCap = math.clamp(requestedCap, minCap, maxCap)
        local oldCap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or minCap))
        if oldCap ~= targetCap then
            state.AttributeCaps[key] = targetCap
            changed = true
        end
    end

    if not changed then
        return true, "Unchanged", "Unchanged", AttributeConfig.CopyNumberMap(state.AttributeCaps)
    end

    state.AttributeLevels = AttributeConfig.NormalizeLevels(state.AttributeLevels, state.AttributeCaps)
    self:_normalizeAttributeState(state)
    self:RecalculateDerivedStats(actor, type(context) == "table" and context.recalculateOptions or nil)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, "Updated", "Updated", AttributeConfig.CopyNumberMap(state.AttributeCaps)
end

function PlayerStateService:ResetAttributeCaps(actor)
    local state = self:_getOrCreateState(actor)
    state.AttributeCaps = AttributeConfig.BuildDefaultCaps()
    state.AttributeLevels = AttributeConfig.NormalizeLevels(state.AttributeLevels, state.AttributeCaps)
    self:_normalizeAttributeState(state)
    self:RecalculateDerivedStats(actor)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return AttributeConfig.CopyNumberMap(state.AttributeCaps)
end

function PlayerStateService:MaxAttributeCaps(actor)
    local state = self:_getOrCreateState(actor)
    state.AttributeCaps = {}
    for _, key in ipairs(AttributeConfig.Order) do
        if not AttributeConfig.IsProgressionDisabled(key) then
            state.AttributeCaps[key] = AttributeConfig.GetMaxCap(key)
        end
    end
    self:_normalizeAttributeState(state)
    self:RecalculateDerivedStats(actor)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return AttributeConfig.CopyNumberMap(state.AttributeCaps)
end

function PlayerStateService:TryUpgradeAttributeCapWithDiamonds(actor, attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false, "InvalidAttribute", "Invalid attribute"
    end
    if AttributeConfig.IsProgressionDisabled(key) then
        return false, "AttributeDisabled", "Attribute disabled"
    end

    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    local currentCap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or 0))
    if currentCap >= AttributeConfig.GetMaxCap(key) then
        return false, "MaxLevel", "Max level reached", currentCap, state.Diamonds
    end

    if not AttributeConfig.IsCapUpgradeGemEnabled(key, currentCap) then
        return false, "GemDisabled", "Gem purchase unavailable", currentCap, state.Diamonds
    end

    local gemCost = AttributeConfig.GetCapUpgradeGemCost(key, currentCap)
    if not gemCost then
        return false, "PriceUnavailable", "Price unavailable", currentCap, state.Diamonds
    end

    local spent, remainingDiamonds = self:TrySpendDiamonds(actor, gemCost, {
        source = "attribute_cap_upgrade",
        productGroup = "AttributeCapUpgrade",
        itemSku = key,
    })
    if not spent then
        return false, "NotEnoughGems", "Not enough gems", currentCap, remainingDiamonds, gemCost
    end

    local success = self:AddAttributeCap(actor, key, 1, {
        source = "attribute_cap_upgrade",
    })
    if not success then
        self:AddDiamonds(actor, gemCost, {
            source = "attribute_cap_upgrade_refund",
            productGroup = "AttributeCapUpgrade",
            itemSku = "AttributeCapUpgradeRefund_" .. key,
        })
        return false, "UpgradeFailed", "Upgrade failed", currentCap, self:_getOrCreateState(actor).Diamonds, gemCost
    end

    local newCap = self:GetAttributeCap(actor, key) or currentCap
    return true, "Upgraded", "Upgraded", newCap, self:_getOrCreateState(actor).Diamonds, gemCost
end

function PlayerStateService:GrantAttributeCapProduct(actor, attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false, "InvalidAttribute", "Invalid attribute"
    end
    if AttributeConfig.IsProgressionDisabled(key) then
        return false, "AttributeDisabled", "Attribute disabled"
    end

    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    local currentCap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or 0))
    if currentCap >= AttributeConfig.GetMaxCap(key) then
        local definition = AttributeConfig.GetDefinition(key)
        local refundFromCap = math.max(
            math.max(0, math.floor(tonumber(definition and definition.InitialCap) or 0)),
            AttributeConfig.GetMaxCap(key) - 1
        )
        local gemCost = AttributeConfig.GetCapUpgradeGemCost(key, refundFromCap)
        if gemCost and gemCost > 0 then
            self:AddDiamonds(actor, gemCost, {
                source = "attribute_cap_product_max_refund",
                productGroup = "AttributeCapUpgrade",
                itemSku = "AttributeCapProductMaxRefund_" .. key,
            })
        end
        return true, "MaxRefunded", "Max level reached", currentCap, self:_getOrCreateState(actor).Diamonds, gemCost or 0
    end

    local gemCost = AttributeConfig.GetCapUpgradeGemCost(key, currentCap)
    local success = self:AddAttributeCap(actor, key, 1, {
        source = "attribute_cap_product",
    })
    if not success then
        return false, "GrantFailed", "Upgrade failed", currentCap, state.Diamonds, gemCost or 0
    end

    local newCap = self:GetAttributeCap(actor, key) or currentCap
    return true, "Upgraded", "Upgraded", newCap, self:_getOrCreateState(actor).Diamonds, gemCost or 0
end

function PlayerStateService:GetAttributeFinalStats(actor)
    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    return state.FinalStats
end

function PlayerStateService:GetWeaponDamageMultiplier(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0, tonumber(finalStats and finalStats.WeaponDamageMultiplier) or 1)
end

function PlayerStateService:GetFlashCooldownSeconds(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0, tonumber(finalStats and finalStats.FlashCooldownSeconds) or GameConfig.FLASH.CooldownSeconds)
end

function PlayerStateService:GetFlashDistanceStuds(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0, tonumber(finalStats and finalStats.FlashDistanceStuds) or GameConfig.FLASH.DistanceStuds)
end

function PlayerStateService:GetFinalWeaponDamage(actor, baseDamage)
    return math.max(0, math.floor(((tonumber(baseDamage) or 0) * self:GetWeaponDamageMultiplier(actor)) + 0.5))
end

function PlayerStateService:GetWeaponOrbitSpeedMultiplier(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0.1, tonumber(finalStats and finalStats.OrbitSpeedMultiplier) or 1)
end

function PlayerStateService:GetWeaponOrbitDistanceMultiplier(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0.1, tonumber(finalStats and finalStats.OrbitDistanceMultiplier) or 1)
end

function PlayerStateService:GetHealthRegenPercentPerSecond(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(0, tonumber(finalStats and finalStats.HealthRegenPercentPerSecond) or 0)
end

function PlayerStateService:GetBladeRecoverySeconds(actor)
    local finalStats = self:GetAttributeFinalStats(actor)
    return math.max(
        AttributeConfig.MinBladeRecoverySeconds,
        tonumber(finalStats and finalStats.BladeRecoverySeconds) or AttributeConfig.BaseBladeRecoverySeconds
    )
end

function PlayerStateService:RecalculateDerivedStats(actor, options)
    local state = self:_getOrCreateState(actor)
    local previousCurrentHealth = math.floor(tonumber(state.CurrentHealth) or 0)
    local previousMaxHealth = math.max(1, math.floor(tonumber(state.MaxHealth) or 1))
    local wasFullHealth = previousCurrentHealth >= previousMaxHealth
    self:_applyLevelDerivedState(state)

    if (type(options) == "table" and options.restoreFullHealth == true) or wasFullHealth then
        state.CurrentHealth = state.MaxHealth
    elseif type(options) == "table" and options.preserveHealthRatio == true then
        local ratioBaseMaxHealth = math.max(1, math.floor(tonumber(options.previousMaxHealth) or previousMaxHealth))
        local ratio = math.clamp(previousCurrentHealth / ratioBaseMaxHealth, 0, 1)
        state.CurrentHealth = math.clamp(math.floor((state.MaxHealth * ratio) + 0.5), 0, state.MaxHealth)
    else
        state.CurrentHealth = math.clamp(previousCurrentHealth, 0, state.MaxHealth)
    end

    self:SyncCharacterState(actor)
    return state
end

function PlayerStateService:GetSpecialEventEffect(actor)
    if not ActorUtils.IsPlayer(actor) then
        return nil
    end
    if self._specialEventService and self._specialEventService.GetActiveEffect then
        return self._specialEventService:GetActiveEffect()
    end
    return nil
end

function PlayerStateService:GetBaseHealthRegenMultiplier(actor)
    if not ActorUtils.IsPlayer(actor) then
        return 1
    end

    local effect = self:GetSpecialEventEffect(actor)
    return math.max(1, tonumber(effect and effect.BaseHealthRegenMultiplier) or 1)
end

function PlayerStateService:RefreshSpecialEventEffectForPlayer(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    self:RecalculateDerivedStats(player, {
        preserveHealthRatio = true,
    })
    self:UpdateOverheadHealthBar(player)
    self:PushState(player)
    return true
end

function PlayerStateService:RefreshSpecialEventEffectsForAll()
    for _, player in ipairs(Players:GetPlayers()) do
        if player and player.Parent then
            self:RefreshSpecialEventEffectForPlayer(player)
        end
    end
end

function PlayerStateService:TryUpgradeAttribute(actor, attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false, "InvalidAttribute", "Invalid attribute"
    end
    if AttributeConfig.IsProgressionDisabled(key) then
        return false, "AttributeDisabled", "Attribute disabled"
    end

    local state = self:_getOrCreateState(actor)
    self:_normalizeAttributeState(state)
    if not (state.Alive == true and state.IsInArena == true) then
        return false, "NotInBattle", "Enter battle to upgrade"
    end
    if state.SkillPoints <= 0 then
        return false, "NotEnoughPoints", "Not enough points"
    end

    local currentLevel = math.max(0, math.floor(tonumber(state.AttributeLevels[key]) or 0))
    local cap = math.max(0, math.floor(tonumber(state.AttributeCaps[key]) or 0))
    if currentLevel >= cap then
        return false, "MaxLevel", "Max level reached"
    end

    state.AttributeLevels[key] = currentLevel + 1
    state.SkillPoints = math.max(0, state.SkillPoints - 1)
    self:_normalizeAttributeState(state)
    self:RecalculateDerivedStats(actor)
    return true, "Upgraded", "Upgraded"
end

function PlayerStateService:_getOverheadHealthBarTemplate()
    local uiFolder = ReplicatedStorage:FindFirstChild(UI_FOLDER_NAME)
    local template = uiFolder and uiFolder:FindFirstChild(OVERHEAD_HEALTH_BAR_NAME)
    if template and template:IsA("BillboardGui") then
        return template
    end
    return nil
end

function PlayerStateService:_createDefaultOverheadHealthBarTemplate()
    local billboard = Instance.new("BillboardGui")
    billboard.Name = OVERHEAD_HEALTH_BAR_NAME
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.MaxDistance = 140
    billboard.Size = UDim2.fromOffset(148, 42)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)

    local root = Instance.new("Frame")
    root.Name = "Root"
    root.BackgroundTransparency = 1
    root.Size = UDim2.fromScale(1, 1)
    root.Parent = billboard

    local levelLabel = Instance.new("TextLabel")
    levelLabel.Name = "Level"
    levelLabel.BackgroundTransparency = 1
    levelLabel.Size = UDim2.new(1, 0, 0, 18)
    levelLabel.Font = Enum.Font.GothamBold
    levelLabel.Text = "Lv.1"
    levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    levelLabel.TextSize = 13
    levelLabel.TextStrokeTransparency = 0.6
    levelLabel.Parent = root

    local highGradient = Instance.new("UIGradient")
    highGradient.Name = "High"
    highGradient.Enabled = false
    highGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 124)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 89, 89)),
    })
    highGradient.Parent = levelLabel

    local lowGradient = Instance.new("UIGradient")
    lowGradient.Name = "Low"
    lowGradient.Enabled = false
    lowGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 220, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 145, 255)),
    })
    lowGradient.Parent = levelLabel

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "ValueLabel"
    valueLabel.BackgroundTransparency = 1
    valueLabel.Size = UDim2.new(1, 0, 0, 18)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    valueLabel.TextSize = 13
    valueLabel.TextStrokeTransparency = 0.6
    valueLabel.Parent = root

    local barBackground = Instance.new("Frame")
    barBackground.Name = "BarBackground"
    barBackground.AnchorPoint = Vector2.new(0.5, 1)
    barBackground.Position = UDim2.new(0.5, 0, 1, 0)
    barBackground.Size = UDim2.new(1, 0, 0, 18)
    barBackground.BackgroundColor3 = Color3.fromRGB(24, 28, 33)
    barBackground.BorderSizePixel = 0
    barBackground.Parent = root

    local backgroundCorner = Instance.new("UICorner")
    backgroundCorner.CornerRadius = UDim.new(0, 7)
    backgroundCorner.Parent = barBackground

    local backgroundStroke = Instance.new("UIStroke")
    backgroundStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    backgroundStroke.Color = Color3.fromRGB(255, 255, 255)
    backgroundStroke.Transparency = 0.7
    backgroundStroke.Thickness = 1
    backgroundStroke.Parent = barBackground

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale(1, 1)
    fill.BackgroundColor3 = Color3.fromRGB(90, 255, 138)
    fill.BorderSizePixel = 0
    fill.Parent = barBackground

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 7)
    fillCorner.Parent = fill

    local shield = Instance.new("ImageLabel")
    shield.Name = "Shield"
    shield.AnchorPoint = Vector2.new(1, 0.5)
    shield.Position = UDim2.new(1, 4, 0.5, 0)
    shield.Size = UDim2.fromOffset(32, 32)
    shield.BackgroundTransparency = 1
    shield.BorderSizePixel = 0
    shield.Visible = false
    shield.Parent = barBackground

    local shieldAspect = Instance.new("UIAspectRatioConstraint")
    shieldAspect.AspectRatio = 1
    shieldAspect.Parent = shield

    ensureOverheadEventImage(root)

    local countDownTime = Instance.new("TextLabel")
    countDownTime.Name = "CountDownTime"
    countDownTime.BackgroundTransparency = 1
    countDownTime.Size = UDim2.fromScale(1, 1)
    countDownTime.Font = Enum.Font.GothamBold
    countDownTime.Text = "0S"
    countDownTime.TextColor3 = Color3.fromRGB(255, 255, 255)
    countDownTime.TextSize = 12
    countDownTime.TextStrokeTransparency = 0.45
    countDownTime.Parent = shield

    ensureOverheadTitleImage(root)

    return billboard
end

function PlayerStateService:_cloneOverheadHealthBar()
    local template = self:_getOverheadHealthBarTemplate()
    if template then
        return template:Clone()
    end
    return self:_createDefaultOverheadHealthBarTemplate()
end

function PlayerStateService:_configureHumanoidNameplate(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return nil
    end

    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    pcall(function()
        humanoid.NameDisplayDistance = 0
    end)
    pcall(function()
        humanoid.HealthDisplayDistance = 0
    end)
    pcall(function()
        humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
    end)
    return humanoid
end

function PlayerStateService:_ensureOverheadHealthBar(actor)
    local character = ActorUtils.GetCharacter(actor)
    if not character then
        return nil
    end

    local head = character:FindFirstChild("Head")
    if not (head and head:IsA("BasePart") and self:_configureHumanoidNameplate(actor)) then
        return nil
    end

    local billboard = head:FindFirstChild(OVERHEAD_HEALTH_BAR_NAME)
    if billboard and not billboard:IsA("BillboardGui") then
        billboard:Destroy()
        billboard = nil
    end

    if billboard then
        billboard.Adornee = head
        return billboard
    end

    billboard = self:_cloneOverheadHealthBar()
    billboard.Name = OVERHEAD_HEALTH_BAR_NAME
    billboard.Adornee = head
    local root = billboard:FindFirstChild("Root")
    ensureOverheadLevelLabel(root)
    ensureOverheadTitleImage(root)
    billboard.Parent = head

    return billboard
end

function PlayerStateService:UpdateOverheadHealthBar(actor)
    local state = self:_getOrCreateState(actor)
    local billboard = self:_ensureOverheadHealthBar(actor)
    if not billboard then
        return false
    end

    local root = billboard:FindFirstChild("Root")
    local valueLabel = root and root:FindFirstChild("ValueLabel")
    local levelLabel = ensureOverheadLevelLabel(root)
    local titleImage = ensureOverheadTitleImage(root)
    local barBackground = root and root:FindFirstChild("BarBackground")
    local fill = barBackground and barBackground:FindFirstChild("Fill")
    if not (valueLabel and valueLabel:IsA("TextLabel") and fill and fill:IsA("Frame")) then
        return false
    end

    local maxHealth = math.max(1, math.floor(tonumber(state.MaxHealth) or 1))
    local currentHealth = math.clamp(math.floor(tonumber(state.CurrentHealth) or maxHealth), 0, maxHealth)
    local healthRatio = currentHealth / maxHealth

    fill.Size = UDim2.fromScale(healthRatio, 1)
    fill.BackgroundColor3 = getHealthFillColor(healthRatio)
    valueLabel.Text = string.format("%d / %d", currentHealth, maxHealth)
    if levelLabel and levelLabel:IsA("TextLabel") then
        levelLabel.Text = string.format("Lv.%d", normalizeLevel(state.Level))
    end

    local equippedTitle = self:GetEquippedTitleConfig(actor)
    local titleIcon = equippedTitle and tostring(equippedTitle.IconImage or "") or ""
    local hasEquippedTitle = titleIcon ~= ""
    if titleImage and titleImage:IsA("ImageLabel") then
        titleImage.Image = titleIcon
        titleImage.Visible = hasEquippedTitle
    end

    local shouldShowHealthBar = state.Alive == true and state.IsInArena == true
    if valueLabel and valueLabel:IsA("GuiObject") then
        valueLabel.Visible = shouldShowHealthBar
    end
    if levelLabel and levelLabel:IsA("GuiObject") then
        levelLabel.Visible = shouldShowHealthBar
    end
    billboard.Enabled = shouldShowHealthBar or hasEquippedTitle
    local shieldState = self._healthService and self._healthService.GetShieldState and self._healthService:GetShieldState(actor) or nil
    updateOverheadShieldUi(root, shieldState, shouldShowHealthBar)
    local eventVisualInfo = nil
    if shouldShowHealthBar then
        eventVisualInfo = self._specialEventService
            and self._specialEventService.GetActiveEventVisualInfo
            and self._specialEventService:GetActiveEventVisualInfo()
            or nil
    end
    local hasActiveEventIcon = updateOverheadEventUi(root, eventVisualInfo)
    updateOverheadBarBackgroundUi(barBackground, fill, shouldShowHealthBar, hasActiveEventIcon)
    billboard.Enabled = shouldShowHealthBar or hasEquippedTitle or hasActiveEventIcon
    return true
end

function PlayerStateService:_getOrCreateState(actor)
    local actorId = getActorId(actor)
    local state = self._statesByActorId[actorId]
    if state then
        state.ActorRef = actor
        if ActorUtils.IsBot(actor) then
            actor.State = state
        end
        return state
    end

    state = self:_createDefaultState(actor)
    self._statesByActorId[actorId] = state
    if ActorUtils.IsBot(actor) then
        actor.State = state
    end
    self:_syncLeaderstats(actor, state)
    return state
end

function PlayerStateService:_resetPerfStats()
    self._perfStats = {
        PushState = 0,
        FriendRefreshes = 0,
        FriendPlayersChecked = 0,
        FriendPairsChecked = 0,
        FriendRefreshElapsedSeconds = 0,
        CharacterAdded = 0,
    }
end

function PlayerStateService:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function PlayerStateService:_getStateCounts()
    local total = 0
    local players = 0
    local bots = 0
    local arena = 0
    local alive = 0
    for _, state in pairs(self._statesByActorId or {}) do
        total += 1
        if state.ActorRef then
            if ActorUtils.IsPlayer(state.ActorRef) then
                players += 1
            elseif ActorUtils.IsBot(state.ActorRef) then
                bots += 1
            end
        end
        if state.IsInArena == true then
            arena += 1
        end
        if state.Alive == true then
            alive += 1
        end
    end
    return total, players, bots, arena, alive
end

function PlayerStateService:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local total, players, bots, arena, alive = self:_getStateCounts()
    local stats = self._perfStats or {}
    print(string.format(
        "[Diag][PlayerStateService] playersNow=%d states=%d playerStates=%d botStates=%d arena=%d alive=%d collisionConns=%d pushState=%d friendRefreshes=%d friendPlayers=%d friendPairs=%d friendRefreshMs=%.3f characterAdded=%d",
        #Players:GetPlayers(),
        total,
        players,
        bots,
        arena,
        alive,
        countMapEntries(self._characterCollisionConnectionsByActorId),
        stats.PushState or 0,
        stats.FriendRefreshes or 0,
        stats.FriendPlayersChecked or 0,
        stats.FriendPairsChecked or 0,
        (stats.FriendRefreshElapsedSeconds or 0) * 1000,
        stats.CharacterAdded or 0
    ))

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function PlayerStateService:Init(dependencies)
    self._statesByActorId = {}
    self._characterCollisionConnectionsByActorId = {}
    self._friendBonusRefreshToken = 0
    self._friendBonusLoopToken += 1
    local friendBonusLoopToken = self._friendBonusLoopToken
    self._onlineTimeLoopToken += 1
    local onlineTimeLoopToken = self._onlineTimeLoopToken
    self._weaponService = dependencies and dependencies.WeaponService or nil
    self._weaponUnlockRewardService = dependencies and dependencies.WeaponUnlockRewardService or nil
    self._leaderboardService = dependencies and dependencies.LeaderboardService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._arenaProgressService = dependencies and dependencies.ArenaProgressService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._subscriptionService = dependencies and dependencies.SubscriptionService or nil
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or nil
    self._specialEventService = dependencies and dependencies.SpecialEventService or nil
    self._playerStateSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("PlayerStateSync") or nil
    self._requestStateSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestPlayerStateSync") or nil
    self._requestOptionStateSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestOptionStateSync") or nil
    self._requestOptionUpdateEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestOptionUpdate") or nil
    self._levelUpFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LevelUpFeedback") or nil
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()

    if self._requestStateConnection then
        self._requestStateConnection:Disconnect()
        self._requestStateConnection = nil
    end
    if self._requestOptionStateConnection then
        self._requestOptionStateConnection:Disconnect()
        self._requestOptionStateConnection = nil
    end
    if self._requestOptionUpdateConnection then
        self._requestOptionUpdateConnection:Disconnect()
        self._requestOptionUpdateConnection = nil
    end

    if self._requestStateSyncEvent then
        self._requestStateConnection = self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            if not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player) then
                self:PushState(player)
                if self._weaponUnlockRewardService and self._weaponUnlockRewardService.SyncPendingPrompt then
                    self._weaponUnlockRewardService:SyncPendingPrompt(player)
                end
            end
        end)
    end

    if self._requestOptionStateSyncEvent then
        self._requestOptionStateConnection = self._requestOptionStateSyncEvent.OnServerEvent:Connect(function(player)
            if not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player) then
                self:PushState(player)
            end
        end)
    end

    if self._requestOptionUpdateEvent then
        self._requestOptionUpdateConnection = self._requestOptionUpdateEvent.OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= "table" then
                return
            end
            if self._rebirthService and self._rebirthService.IsPlayerLoaded and not self._rebirthService:IsPlayerLoaded(player) then
                return
            end

            local changed = false
            if type(payload.musicEnabled) == "boolean" then
                changed = self:SetOption(player, "Music", payload.musicEnabled) or changed
            end
            if type(payload.sfxEnabled) == "boolean" then
                changed = self:SetOption(player, "Sfx", payload.sfxEnabled) or changed
            end
            if changed ~= true then
                self:PushState(player)
            end
        end)
    end

    task.spawn(function()
        while self._friendBonusLoopToken == friendBonusLoopToken do
            task.wait(15)
            if self._friendBonusLoopToken ~= friendBonusLoopToken then
                break
            end
            self:RefreshFriendExperienceBonuses()
        end
    end)

    task.spawn(function()
        while self._onlineTimeLoopToken == onlineTimeLoopToken do
            task.wait(30)
            if self._onlineTimeLoopToken ~= onlineTimeLoopToken then
                break
            end
            for _, player in ipairs(Players:GetPlayers()) do
                self:RefreshOnlineTime(player, true)
            end
        end
    end)
end

function PlayerStateService:BindSystems(dependencies)
    self._weaponService = dependencies and dependencies.WeaponService or self._weaponService
    self._weaponUnlockRewardService = dependencies and dependencies.WeaponUnlockRewardService or self._weaponUnlockRewardService
    self._leaderboardService = dependencies and dependencies.LeaderboardService or self._leaderboardService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._arenaProgressService = dependencies and dependencies.ArenaProgressService or self._arenaProgressService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
    self._subscriptionService = dependencies and dependencies.SubscriptionService or self._subscriptionService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
    self._specialEventService = dependencies and dependencies.SpecialEventService or self._specialEventService
    self._skinService = dependencies and dependencies.SkinService or self._skinService
    self._taskService = dependencies and dependencies.TaskService or self._taskService
end

function PlayerStateService:_markArenaProgressDirty()
    if self._arenaProgressService and self._arenaProgressService.MarkDirty then
        self._arenaProgressService:MarkDirty()
    end
end

function PlayerStateService:RegisterBot(botActor)
    self:_getOrCreateState(botActor)
end

function PlayerStateService:UnregisterBot(botActor)
    local actorId = getActorId(botActor)
    self._statesByActorId[actorId] = nil
    if ActorUtils.IsBot(botActor) then
        botActor.State = nil
    end
end

function PlayerStateService:OnPlayerAdded(player)
    local state = self:_getOrCreateState(player)
    state.LastOnlineClock = os.clock()
    self:CheckTitleUnlocks(player)
    self:RefreshSpecialEventEffectForPlayer(player)
    if self._gameAnalyticsService and self._gameAnalyticsService.BeginOnboardingSurvivalCheck then
        self._gameAnalyticsService:BeginOnboardingSurvivalCheck(player, 60)
    end
    self:_syncLeaderstats(player, state)
    if not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player) then
        self:PushState(player)
        if self._weaponUnlockRewardService and self._weaponUnlockRewardService.SyncPendingPrompt then
            self._weaponUnlockRewardService:SyncPendingPrompt(player)
        end
    end
    self:QueueFriendBonusRefresh()
end

function PlayerStateService:BuildStatePayload(actor)
    local state = self:_getOrCreateState(actor)
    self:RefreshOnlineTime(actor, false)
    local activePotion = self:GetActivePotion(actor)
    local activePotions = self:GetActivePotions(actor)
    local attributeState = self:BuildAttributeStatePayload(actor)
    local potionExperienceBonus = self:GetPotionExperienceBonus(actor)
    local potionMoveSpeedBonus = self:GetPotionMoveSpeedBonus(actor)
    local friendExperienceBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    local friendCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
    local weaponUnlockRewards = normalizeWeaponUnlockRewards(
        state.WeaponUnlockRewards,
        getMaxUnlockedTierIndexForLevel(state.HighestLevelReached or state.Level)
    )
    state.WeaponUnlockRewards = weaponUnlockRewards
    local options = normalizeOptions(state.Options)
    state.Options = options
    local favoritePromptState = normalizeFavoritePromptState(state.FavoritePromptState)
    state.FavoritePromptState = favoritePromptState
    local ownedSkins = normalizeOwnedSkins(state.OwnedSkins)
    state.OwnedSkins = ownedSkins
    state.EquippedSkinId = normalizeEquippedSkinId(state.EquippedSkinId, ownedSkins)
    local ownedTrails = normalizeOwnedTrails(state.OwnedTrails)
    state.OwnedTrails = ownedTrails
    state.EquippedTrailId = normalizeEquippedTrailId(state.EquippedTrailId, ownedTrails)
    state.Chests = normalizeChests(state.Chests)
    local ownedTitles = normalizeOwnedTitles(state.OwnedTitles)
    state.OwnedTitles = ownedTitles
    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, ownedTitles)
    local shieldState = self._healthService and self._healthService.GetShieldState and self._healthService:GetShieldState(actor) or nil
    local subscriptionActive = self._subscriptionService and (
        (self._subscriptionService.IsSubscribedCached and self._subscriptionService:IsSubscribedCached(actor) == true)
        or (not self._subscriptionService.IsSubscribedCached and self._subscriptionService.IsSubscribed and self._subscriptionService:IsSubscribed(actor) == true)
    ) or false
    local subscriptionBonus = subscriptionActive and math.max(0, tonumber(SubscriptionConfig.ExperienceBonus) or 0) or 0
    local subscriptionId = tostring(SubscriptionConfig.SubscriptionId or "")
    local currentUtcDay = SubscriptionConfig.GetCurrentUtcDay()
    local subscriptionDailyClaimed = self:HasSubscriptionClaim(actor, subscriptionId, currentUtcDay)
    local subscriptionDailyClaimAvailable = self._subscriptionService
        and self._subscriptionService.IsDailyClaimAvailable
        and self._subscriptionService:IsDailyClaimAvailable(actor) == true
        or false
    return {
        level = state.Level,
        highestLevelReached = state.HighestLevelReached,
        experience = state.Experience,
        nextLevelExperience = state.NextLevelExperience,
        currentHealth = state.CurrentHealth,
        maxHealth = state.MaxHealth,
        moveSpeed = state.MoveSpeed * self:GetMoveSpeedMultiplier(actor),
        weaponTier = state.WeaponTier,
        weaponTierIndex = state.WeaponTierIndex,
        weaponCount = state.WeaponCount,
        weaponIcon = state.WeaponIcon,
        desiredWeaponTier = state.DesiredWeaponTier,
        desiredWeaponTierIndex = state.DesiredWeaponTierIndex,
        desiredWeaponCount = state.DesiredWeaponCount,
        desiredWeaponIcon = state.DesiredWeaponIcon,
        killCount = state.KillCount,
        totalPlayerKills = state.TotalPlayerKills,
        rebirth = state.Rebirth,
        rebirthScore = state.RebirthScore,
        nextRebirthScore = GameConfig.GetRequiredRebirthScore(state.Rebirth),
        rebirthExperienceBonus = GameConfig.GetRebirthExperienceBonus(state.Rebirth),
        diamonds = state.Diamonds,
        totalDiamondsEarned = state.TotalDiamondsEarned,
        totalDeaths = state.TotalDeaths,
        totalOnlineSeconds = state.TotalOnlineSeconds,
        wheelSpins = state.WheelSpins,
        potions = state.Potions,
        groupRewards = state.GroupRewards,
        subscriptionClaims = normalizeSubscriptionClaims(state.SubscriptionClaims),
        shopClaims = copyBooleanMap(normalizeShopClaims(state.ShopClaims)),
        codeClaims = copyBooleanMap(normalizeCodeClaims(state.CodeClaims)),
        dailyFreeReviveClaims = normalizeDailyFreeReviveClaims(state.DailyFreeReviveClaims),
        taskState = state.TaskState or {},
        sevenDayLoginRewardState = normalizeSevenDayLoginRewardState(state.SevenDayLoginRewardState),
        guideCompleted = state.GuideCompleted == true,
        favoritePromptState = {
            hasFavorited = favoritePromptState.HasFavorited == true,
            promptedAt = favoritePromptState.PromptedAt,
            lastPromptUtcDay = favoritePromptState.LastPromptUtcDay,
            lastPromptResult = favoritePromptState.LastPromptResult,
            lastResultAt = favoritePromptState.LastResultAt,
        },
        options = {
            musicEnabled = options.Music == true,
            sfxEnabled = options.Sfx == true,
        },
        subscriptionActive = subscriptionActive,
        subscriptionExperienceBonus = subscriptionBonus,
        subscriptionDailyClaimed = subscriptionDailyClaimed,
        subscriptionDailyClaimAvailable = subscriptionDailyClaimAvailable,
        subscriptionCurrentUtcDay = currentUtcDay,
        ownedSkins = copyBooleanMap(ownedSkins),
        equippedSkinId = state.EquippedSkinId,
        ownedTrails = copyBooleanMap(ownedTrails),
        equippedTrailId = state.EquippedTrailId,
        chests = copyNumberMap(state.Chests),
        ownedTitles = copyBooleanMap(ownedTitles),
        equippedTitleId = state.EquippedTitleId,
        hasUnseenTitleUnlock = state.HasUnseenTitleUnlock == true,
        weaponUnlockRewards = {
            claimedTiers = copyBooleanMap(weaponUnlockRewards.ClaimedTiers or {}),
            pendingQueue = copyArray(weaponUnlockRewards.PendingQueue or {}),
            lastPromptedTierIndex = weaponUnlockRewards.LastPromptedTierIndex,
        },
        activePotions = activePotions,
        activePotion = activePotion,
        potionExperienceBonus = potionExperienceBonus,
        trailExperienceBonus = self:GetTrailExperienceBonus(actor),
        potionMoveSpeedBonus = potionMoveSpeedBonus,
        friendExperienceBonus = friendExperienceBonus,
        friendBonusPercent = math.floor((friendExperienceBonus * 100) + 0.5),
        friendCount = friendCount,
        skillPoints = attributeState.skillPoints,
        usedSkillPoints = attributeState.usedSkillPoints,
        masteryPoints = attributeState.masteryPoints,
        attributeLevels = attributeState.attributeLevels,
        attributeCaps = attributeState.attributeCaps,
        attributeFinalStats = attributeState.finalStats,
        attributeState = attributeState,
        totalExperienceMultiplier = self:GetExperienceMultiplier(actor),
        isInArena = state.IsInArena,
        alive = state.Alive,
        buffs = state.Buffs,
        shieldActive = shieldState and shieldState.shieldActive == true or false,
        shieldRemainingSeconds = shieldState and shieldState.shieldRemainingSeconds or 0,
        shieldExpiresAt = shieldState and shieldState.shieldExpiresAt or nil,
        timestamp = os.clock(),
    }
end

function PlayerStateService:PushState(actor)
    if not ActorUtils.IsPlayer(actor) then
        return
    end
    if not (actor and actor.Parent) then
        return
    end
    if not self._playerStateSyncEvent then
        return
    end

    self:_addPerfStat("PushState")
    self._playerStateSyncEvent:FireClient(actor, self:BuildStatePayload(actor))
end

function PlayerStateService:_fireLevelUpFeedback(actor, previousLevel, newLevel)
    if not (self._levelUpFeedbackEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    local state = self:_getOrCreateState(actor)
    self._levelUpFeedbackEvent:FireClient(actor, {
        previousLevel = previousLevel,
        newLevel = newLevel,
        maxHealth = state.MaxHealth,
        weaponTier = state.WeaponTier,
        weaponTierIndex = state.WeaponTierIndex,
        weaponCount = state.WeaponCount,
        weaponIcon = state.WeaponIcon,
        desiredWeaponTier = state.DesiredWeaponTier,
        desiredWeaponTierIndex = state.DesiredWeaponTierIndex,
        desiredWeaponCount = state.DesiredWeaponCount,
        desiredWeaponIcon = state.DesiredWeaponIcon,
        timestamp = os.clock(),
    })
end

function PlayerStateService:GetHumanoid(actor)
    return ActorUtils.GetHumanoid(actor)
end

function PlayerStateService:SyncHumanoidHealth(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    state.CurrentHealth = math.clamp(state.CurrentHealth, 0, state.MaxHealth)
    humanoid.MaxHealth = state.MaxHealth
    humanoid.Health = math.min(state.CurrentHealth, humanoid.MaxHealth)
    self:UpdateOverheadHealthBar(actor)
    return true
end

function PlayerStateService:SyncHumanoidMovement(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    local previousWalkSpeed = humanoid.WalkSpeed
    local moveSpeedMultiplier = self:GetMoveSpeedMultiplier(actor)
    local targetWalkSpeed = state.MoveSpeed * moveSpeedMultiplier
    humanoid.WalkSpeed = targetWalkSpeed

    if RunService:IsStudio() and math.abs((tonumber(previousWalkSpeed) or 0) - targetWalkSpeed) > 0.001 then
        print(string.format(
            "[Diag][PlayerStateService][MoveSpeed] actor=%s level=%d base=%.2f multiplier=%.3f walkSpeed=%.2f->%.2f",
            tostring(actor and actor.Name or ActorUtils.GetActorId(actor) or ""),
            math.max(1, math.floor(tonumber(state.Level) or 1)),
            tonumber(state.MoveSpeed) or 0,
            moveSpeedMultiplier,
            tonumber(previousWalkSpeed) or 0,
            targetWalkSpeed
        ))
    end
    return true
end

function PlayerStateService:SyncCharacterState(actor)
    local didSyncHealth = self:SyncHumanoidHealth(actor)
    local didSyncMovement = self:SyncHumanoidMovement(actor)
    return didSyncHealth or didSyncMovement
end

function PlayerStateService:SetWeaponState(actor, weaponTier, weaponCount)
    local state = self:_getOrCreateState(actor)
    state.WeaponTier = tostring(weaponTier or "None")
    state.WeaponTierIndex = WeaponTierConfig.GetTierIndex(state.WeaponTier)
    state.WeaponCount = math.max(0, math.floor(tonumber(weaponCount) or 0))
    state.WeaponIcon = WeaponTierConfig.GetIconImageForTier(state.WeaponTier)
end

function PlayerStateService:SetAlive(actor, isAlive)
    self:_getOrCreateState(actor).Alive = isAlive == true
end

function PlayerStateService:AddKillCount(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    if delta <= 0 then
        return state.KillCount, state.TotalPlayerKills
    end
    state.KillCount += delta
    state.TotalPlayerKills += delta
    self:_syncLeaderstats(actor, state)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:CheckTitleUnlocks(actor)
    return state.KillCount, state.TotalPlayerKills
end

function PlayerStateService:SetTotalPlayerKills(actor, count)
    local state = self:_getOrCreateState(actor)
    state.TotalPlayerKills = math.max(0, math.floor(tonumber(count) or 0))
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    self:CheckTitleUnlocks(actor)
    return state.TotalPlayerKills
end

function PlayerStateService:_trackEconomy(actor, flowType, currency, amount, balance, context)
    if not (ActorUtils.IsPlayer(actor) and self._gameAnalyticsService and self._gameAnalyticsService.TrackEconomy) then
        return
    end

    local normalizedAmount = math.max(0, math.floor(tonumber(amount) or 0))
    if normalizedAmount <= 0 then
        return
    end

    local normalizedContext = type(context) == "table" and context or {}
    local fields = copyAnalyticsFields(normalizedContext)
    local itemSku = tostring(normalizedContext.itemSku or fields.itemSku or currency or "Currency")
    local transactionType = normalizedContext.transactionType or Enum.AnalyticsEconomyTransactionType.Gameplay

    self._gameAnalyticsService:TrackEconomy(
        actor,
        flowType,
        currency,
        normalizedAmount,
        balance,
        transactionType,
        itemSku,
        fields
    )
end

function PlayerStateService:AddDiamonds(actor, amount, context)
    local state = self:_getOrCreateState(actor)
    local delta = math.floor(tonumber(amount) or 0)
    if delta == 0 then
        return state.Diamonds
    end

    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0) + delta)
    if shouldCountDiamondEarn(delta, context) then
        state.TotalDiamondsEarned = math.max(0, math.floor(tonumber(state.TotalDiamondsEarned) or 0)) + delta
        if self._taskService and self._taskService.RecordDiamondsEarned then
            self._taskService:RecordDiamondsEarned(actor, delta, context)
        end
    end
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_trackEconomy(
        actor,
        delta >= 0 and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink,
        "Diamonds",
        math.abs(delta),
        state.Diamonds,
        context
    )
    if shouldCountDiamondEarn(delta, context) then
        self:CheckTitleUnlocks(actor)
    end
    return state.Diamonds
end

function PlayerStateService:TrySpendDiamonds(actor, amount, context)
    local state = self:_getOrCreateState(actor)
    local cost = math.max(0, math.floor(tonumber(amount) or 0))
    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0))
    if cost <= 0 then
        return true, state.Diamonds
    end
    if state.Diamonds < cost then
        return false, state.Diamonds
    end

    state.Diamonds -= cost
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_trackEconomy(
        actor,
        Enum.AnalyticsEconomyFlowType.Sink,
        "Diamonds",
        cost,
        state.Diamonds,
        context
    )
    return true, state.Diamonds
end

function PlayerStateService:AddWheelSpins(actor, amount, context)
    local state = self:_getOrCreateState(actor)
    local delta = math.floor(tonumber(amount) or 0)
    if delta == 0 then
        state.WheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0))
        return state.WheelSpins
    end

    state.WheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0) + delta)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_trackEconomy(
        actor,
        delta >= 0 and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink,
        "WheelSpins",
        math.abs(delta),
        state.WheelSpins,
        context
    )
    return state.WheelSpins
end

function PlayerStateService:TryConsumeWheelSpin(actor, context)
    local state = self:_getOrCreateState(actor)
    state.WheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0))
    if state.WheelSpins <= 0 then
        return false, state.WheelSpins
    end

    state.WheelSpins -= 1
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_trackEconomy(
        actor,
        Enum.AnalyticsEconomyFlowType.Sink,
        "WheelSpins",
        1,
        state.WheelSpins,
        context
    )
    return true, state.WheelSpins
end

function PlayerStateService:GetSubscriptionClaims(actor)
    local state = self:_getOrCreateState(actor)
    state.SubscriptionClaims = normalizeSubscriptionClaims(state.SubscriptionClaims)
    return state.SubscriptionClaims
end

function PlayerStateService:HasSubscriptionClaim(actor, subscriptionId, utcDay)
    local claims = self:GetSubscriptionClaims(actor)
    local key = tostring(subscriptionId or "")
    local day = tostring(utcDay or "")
    return key ~= "" and day ~= "" and claims[key] == day
end

function PlayerStateService:MarkSubscriptionClaim(actor, subscriptionId, utcDay)
    local key = tostring(subscriptionId or "")
    local day = tostring(utcDay or "")
    if key == "" or day == "" then
        return false
    end

    local state = self:_getOrCreateState(actor)
    state.SubscriptionClaims = normalizeSubscriptionClaims(state.SubscriptionClaims)
    state.SubscriptionClaims[key] = day
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetDailyFreeReviveClaims(actor)
    local state = self:_getOrCreateState(actor)
    state.DailyFreeReviveClaims = normalizeDailyFreeReviveClaims(state.DailyFreeReviveClaims)
    return state.DailyFreeReviveClaims
end

function PlayerStateService:HasDailyFreeReviveClaim(actor, claimKey, utcDay)
    local claims = self:GetDailyFreeReviveClaims(actor)
    local key = tostring(claimKey or "")
    local day = tostring(utcDay or "")
    return key ~= "" and day ~= "" and claims[key] == day
end

function PlayerStateService:MarkDailyFreeReviveClaim(actor, claimKey, utcDay)
    local key = tostring(claimKey or "")
    local day = tostring(utcDay or "")
    if key == "" or day == "" then
        return false
    end

    local state = self:_getOrCreateState(actor)
    state.DailyFreeReviveClaims = normalizeDailyFreeReviveClaims(state.DailyFreeReviveClaims)
    state.DailyFreeReviveClaims[key] = day
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetShopClaims(actor)
    local state = self:_getOrCreateState(actor)
    state.ShopClaims = normalizeShopClaims(state.ShopClaims)
    return state.ShopClaims
end

function PlayerStateService:HasShopClaim(actor, claimKey)
    local claims = self:GetShopClaims(actor)
    local key = tostring(claimKey or "")
    return key ~= "" and claims[key] == true
end

function PlayerStateService:MarkShopClaim(actor, claimKey)
    local key = tostring(claimKey or "")
    if key == "" then
        return false
    end

    local state = self:_getOrCreateState(actor)
    state.ShopClaims = normalizeShopClaims(state.ShopClaims)
    if state.ShopClaims[key] == true then
        return false
    end

    state.ShopClaims[key] = true
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetCodeClaims(actor)
    local state = self:_getOrCreateState(actor)
    state.CodeClaims = normalizeCodeClaims(state.CodeClaims)
    return state.CodeClaims
end

function PlayerStateService:HasCodeClaim(actor, claimKey)
    local claims = self:GetCodeClaims(actor)
    local key = tostring(claimKey or "")
    return key ~= "" and claims[key] == true
end

function PlayerStateService:MarkCodeClaim(actor, claimKey)
    local key = tostring(claimKey or "")
    if key == "" then
        return false
    end

    local state = self:_getOrCreateState(actor)
    state.CodeClaims = normalizeCodeClaims(state.CodeClaims)
    if state.CodeClaims[key] == true then
        return false
    end

    state.CodeClaims[key] = true
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetOptions(actor)
    local state = self:_getOrCreateState(actor)
    state.Options = normalizeOptions(state.Options)
    return state.Options
end

function PlayerStateService:SetOption(actor, optionKey, enabled)
    local key = tostring(optionKey or "")
    if key ~= "Music" and key ~= "Sfx" then
        return false
    end

    local state = self:_getOrCreateState(actor)
    state.Options = normalizeOptions(state.Options)
    local resolvedEnabled = enabled == true
    if state.Options[key] == resolvedEnabled then
        return false
    end

    state.Options[key] = resolvedEnabled
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:ApplyOptionsData(actor, options)
    local state = self:_getOrCreateState(actor)
    state.Options = normalizeOptions(options)
    return state.Options
end

function PlayerStateService:IsGuideCompleted(actor)
    local state = self:_getOrCreateState(actor)
    state.GuideCompleted = normalizeGuideCompleted(state.GuideCompleted, true)
    return state.GuideCompleted == true
end

function PlayerStateService:MarkGuideCompleted(actor)
    local state = self:_getOrCreateState(actor)
    state.GuideCompleted = normalizeGuideCompleted(state.GuideCompleted, true)
    if state.GuideCompleted == true then
        return false
    end

    state.GuideCompleted = true
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetOwnedSkins(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedSkins = normalizeOwnedSkins(state.OwnedSkins)
    state.EquippedSkinId = normalizeEquippedSkinId(state.EquippedSkinId, state.OwnedSkins)
    return state.OwnedSkins
end

function PlayerStateService:OwnsSkin(actor, skinId)
    local ownedSkins = self:GetOwnedSkins(actor)
    return ownedSkins[tostring(math.floor(tonumber(skinId) or 0))] == true
end

function PlayerStateService:GrantSkin(actor, skinId)
    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        return false, "InvalidSkin"
    end

    local state = self:_getOrCreateState(actor)
    state.OwnedSkins = normalizeOwnedSkins(state.OwnedSkins)
    local key = tostring(skin.Id)
    local alreadyOwned = state.OwnedSkins[key] == true
    state.OwnedSkins[key] = true
    state.EquippedSkinId = normalizeEquippedSkinId(state.EquippedSkinId, state.OwnedSkins)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, alreadyOwned and "AlreadyOwned" or "Granted"
end

function PlayerStateService:EquipSkin(actor, skinId)
    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        return false, "InvalidSkin"
    end
    if not self:OwnsSkin(actor, skin.Id) then
        return false, "NotOwned"
    end

    local state = self:_getOrCreateState(actor)
    state.EquippedSkinId = skin.Id
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if self._weaponService and self._weaponService.RebuildWeaponsForActor then
        self._weaponService:RebuildWeaponsForActor(actor)
    end
    return true, "Equipped"
end

function PlayerStateService:ClearEquippedSkin(actor)
    local state = self:_getOrCreateState(actor)
    if state.EquippedSkinId == nil then
        return true
    end

    state.EquippedSkinId = nil
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if self._weaponService and self._weaponService.RebuildWeaponsForActor then
        self._weaponService:RebuildWeaponsForActor(actor)
    end
    return true
end

function PlayerStateService:GetEquippedSkinId(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedSkins = normalizeOwnedSkins(state.OwnedSkins)
    state.EquippedSkinId = normalizeEquippedSkinId(state.EquippedSkinId, state.OwnedSkins)
    return state.EquippedSkinId
end

function PlayerStateService:GetEquippedSkinConfig(actor)
    local skinId = self:GetEquippedSkinId(actor)
    return skinId and SkinConfig.GetSkin(skinId) or nil
end

function PlayerStateService:GetOwnedTrails(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedTrails = normalizeOwnedTrails(state.OwnedTrails)
    state.EquippedTrailId = normalizeEquippedTrailId(state.EquippedTrailId, state.OwnedTrails)
    return state.OwnedTrails
end

function PlayerStateService:OwnsTrail(actor, trailId)
    local ownedTrails = self:GetOwnedTrails(actor)
    return ownedTrails[tostring(math.floor(tonumber(trailId) or 0))] == true
end

function PlayerStateService:GrantTrail(actor, trailId)
    local trail = TrailConfig.GetTrail(trailId)
    if not trail then
        return false, "InvalidTrail"
    end

    local state = self:_getOrCreateState(actor)
    state.OwnedTrails = normalizeOwnedTrails(state.OwnedTrails)
    local key = tostring(trail.Id)
    local alreadyOwned = state.OwnedTrails[key] == true
    state.OwnedTrails[key] = true
    state.EquippedTrailId = normalizeEquippedTrailId(state.EquippedTrailId, state.OwnedTrails)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, alreadyOwned and "AlreadyOwned" or "Granted"
end

function PlayerStateService:EquipTrail(actor, trailId)
    local trail = TrailConfig.GetTrail(trailId)
    if not trail then
        return false, "InvalidTrail"
    end
    if not self:OwnsTrail(actor, trail.Id) then
        return false, "NotOwned"
    end

    local state = self:_getOrCreateState(actor)
    state.EquippedTrailId = trail.Id
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, "Equipped"
end

function PlayerStateService:ClearEquippedTrail(actor)
    local state = self:_getOrCreateState(actor)
    if state.EquippedTrailId == nil then
        return true
    end

    state.EquippedTrailId = nil
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetEquippedTrailId(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedTrails = normalizeOwnedTrails(state.OwnedTrails)
    state.EquippedTrailId = normalizeEquippedTrailId(state.EquippedTrailId, state.OwnedTrails)
    return state.EquippedTrailId
end

function PlayerStateService:GetEquippedTrailConfig(actor)
    local trailId = self:GetEquippedTrailId(actor)
    return trailId and TrailConfig.GetTrail(trailId) or nil
end

function PlayerStateService:GetTrailExperienceBonus(actor)
    local trail = self:GetEquippedTrailConfig(actor)
    return math.max(0, tonumber(trail and trail.ExperienceBonus) or 0)
end

function PlayerStateService:GetChests(actor)
    local state = self:_getOrCreateState(actor)
    state.Chests = normalizeChests(state.Chests)
    return state.Chests
end

function PlayerStateService:GetChestCount(actor, chestId)
    local chests = self:GetChests(actor)
    return math.max(0, math.floor(tonumber(chests[tostring(math.floor(tonumber(chestId) or 0))]) or 0))
end

function PlayerStateService:AddChest(actor, chestId, amount, context)
    local chest = ChestConfig.GetChest(chestId)
    if not chest then
        return false, "InvalidChest"
    end

    local delta = math.max(1, math.floor(tonumber(amount) or 1))
    local state = self:_getOrCreateState(actor)
    state.Chests = normalizeChests(state.Chests)
    local key = tostring(chest.Id)
    state.Chests[key] = math.max(0, math.floor(tonumber(state.Chests[key]) or 0)) + delta
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService and self._gameAnalyticsService.TrackEconomy then
        local normalizedContext = type(context) == "table" and context or {}
        self._gameAnalyticsService:TrackEconomy(
            actor,
            Enum.AnalyticsEconomyFlowType.Source,
            "Chest" .. tostring(chest.Id),
            delta,
            state.Chests[key],
            Enum.AnalyticsEconomyTransactionType.Gameplay,
            tostring(normalizedContext.itemSku or normalizedContext.productGroup or "ChestReward"),
            normalizedContext
        )
    end
    return true, "Granted", state.Chests[key]
end

function PlayerStateService:ConsumeChest(actor, chestId, amount, context)
    local chest = ChestConfig.GetChest(chestId)
    if not chest then
        return false, "InvalidChest"
    end

    local delta = math.max(1, math.floor(tonumber(amount) or 1))
    local state = self:_getOrCreateState(actor)
    state.Chests = normalizeChests(state.Chests)
    local key = tostring(chest.Id)
    local current = math.max(0, math.floor(tonumber(state.Chests[key]) or 0))
    if current < delta then
        return false, "NotEnoughChest"
    end

    local remaining = current - delta
    if remaining > 0 then
        state.Chests[key] = remaining
    else
        state.Chests[key] = nil
    end
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService and self._gameAnalyticsService.TrackEconomy then
        local normalizedContext = type(context) == "table" and context or {}
        self._gameAnalyticsService:TrackEconomy(
            actor,
            Enum.AnalyticsEconomyFlowType.Sink,
            "Chest" .. tostring(chest.Id),
            delta,
            remaining,
            Enum.AnalyticsEconomyTransactionType.Gameplay,
            tostring(normalizedContext.itemSku or normalizedContext.productGroup or "ChestOpen"),
            normalizedContext
        )
    end
    return true, "Consumed", remaining
end

function PlayerStateService:HasLimitedChestReward(actor, reward)
    if type(reward) ~= "table" or reward.IsLimited ~= true then
        return false
    end

    local rewardType = tostring(reward.RewardType or "")
    if rewardType == "Trail" then
        return self:OwnsTrail(actor, reward.TrailId) == true
    end
    return false
end

function PlayerStateService:_buildTitleUnlockMetrics(state)
    return {
        highestLevelReached = math.max(1, math.floor(tonumber(state.HighestLevelReached or state.Level) or GameConfig.PLAYER.BaseLevel)),
        totalPlayerKills = math.max(0, math.floor(tonumber(state.TotalPlayerKills) or 0)),
        totalDeaths = math.max(0, math.floor(tonumber(state.TotalDeaths) or 0)),
        totalDiamondsEarned = math.max(0, math.floor(tonumber(state.TotalDiamondsEarned) or 0)),
        totalOnlineSeconds = math.max(0, math.floor(tonumber(state.TotalOnlineSeconds) or 0)),
    }
end

function PlayerStateService:_notifyTitleUnlocked(actor, title)
    if self._skinService and self._skinService.NotifyTitleUnlocked then
        self._skinService:NotifyTitleUnlocked(actor, title)
    end
end

function PlayerStateService:CheckTitleUnlocks(actor)
    if not ActorUtils.IsPlayer(actor) then
        return {}
    end

    local state = self:_getOrCreateState(actor)
    state.OwnedTitles = normalizeOwnedTitles(state.OwnedTitles)
    local metrics = self:_buildTitleUnlockMetrics(state)
    local unlockedTitles = {}

    for _, title in ipairs(TitleConfig.GetAllTitles()) do
        local key = tostring(title.Id)
        if state.OwnedTitles[key] ~= true then
            if TitleConfig.IsUnlocked(title, metrics) then
                state.OwnedTitles[key] = true
                state.HasUnseenTitleUnlock = true
                table.insert(unlockedTitles, title)
            elseif type(title.Condition) ~= "table" and title._conditionWarningEmitted ~= true then
                title._conditionWarningEmitted = true
                warn(string.format(
                    "[PlayerStateService] Title %s has an unparsed unlock condition and will remain locked: %s",
                    tostring(title.Id),
                    tostring(title.UnlockConditionText or "")
                ))
            end
        end
    end

    if #unlockedTitles <= 0 then
        return unlockedTitles
    end

    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, state.OwnedTitles)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    for _, title in ipairs(unlockedTitles) do
        self:_notifyTitleUnlocked(actor, title)
    end
    return unlockedTitles
end

function PlayerStateService:GetOwnedTitles(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedTitles = normalizeOwnedTitles(state.OwnedTitles)
    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, state.OwnedTitles)
    return state.OwnedTitles
end

function PlayerStateService:OwnsTitle(actor, titleId)
    local ownedTitles = self:GetOwnedTitles(actor)
    return ownedTitles[tostring(math.floor(tonumber(titleId) or 0))] == true
end

function PlayerStateService:GrantTitle(actor, titleId, options)
    local title = TitleConfig.GetTitle(titleId)
    if not title then
        return false, "InvalidTitle"
    end

    local state = self:_getOrCreateState(actor)
    state.OwnedTitles = normalizeOwnedTitles(state.OwnedTitles)
    local key = tostring(title.Id)
    local alreadyOwned = state.OwnedTitles[key] == true
    state.OwnedTitles[key] = true
    if alreadyOwned ~= true and not (type(options) == "table" and options.silentRedPoint == true) then
        state.HasUnseenTitleUnlock = true
    end
    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, state.OwnedTitles)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if alreadyOwned ~= true and not (type(options) == "table" and options.silentFeedback == true) then
        self:_notifyTitleUnlocked(actor, title)
    end
    return true, alreadyOwned and "AlreadyOwned" or "Granted"
end

function PlayerStateService:EquipTitle(actor, titleId)
    local title = TitleConfig.GetTitle(titleId)
    if not title then
        return false, "InvalidTitle"
    end
    if not self:OwnsTitle(actor, title.Id) then
        return false, "NotOwned"
    end

    local state = self:_getOrCreateState(actor)
    state.EquippedTitleId = title.Id
    self:UpdateOverheadHealthBar(actor)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true, "Equipped"
end

function PlayerStateService:ClearEquippedTitle(actor)
    local state = self:_getOrCreateState(actor)
    if state.EquippedTitleId == nil then
        return true
    end

    state.EquippedTitleId = nil
    self:UpdateOverheadHealthBar(actor)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:GetEquippedTitleId(actor)
    local state = self:_getOrCreateState(actor)
    state.OwnedTitles = normalizeOwnedTitles(state.OwnedTitles)
    state.EquippedTitleId = normalizeEquippedTitleId(state.EquippedTitleId, state.OwnedTitles)
    return state.EquippedTitleId
end

function PlayerStateService:GetEquippedTitleConfig(actor)
    local titleId = self:GetEquippedTitleId(actor)
    return titleId and TitleConfig.GetTitle(titleId) or nil
end

function PlayerStateService:ClearUnseenTitleUnlock(actor)
    local state = self:_getOrCreateState(actor)
    if state.HasUnseenTitleUnlock ~= true then
        return false
    end

    state.HasUnseenTitleUnlock = false
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return true
end

function PlayerStateService:RecordDeath(actor)
    if not ActorUtils.IsPlayer(actor) then
        return 0
    end

    local state = self:_getOrCreateState(actor)
    state.TotalDeaths = math.max(0, math.floor(tonumber(state.TotalDeaths) or 0)) + 1
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:CheckTitleUnlocks(actor)
    return state.TotalDeaths
end

function PlayerStateService:RefreshOnlineTime(actor, shouldCheckTitles)
    if not ActorUtils.IsPlayer(actor) then
        return 0
    end

    local state = self:_getOrCreateState(actor)
    local now = os.clock()
    local lastClock = tonumber(state.LastOnlineClock) or now
    local delta = math.floor(now - lastClock)
    if delta <= 0 then
        state.LastOnlineClock = lastClock
        return math.max(0, math.floor(tonumber(state.TotalOnlineSeconds) or 0))
    end

    state.LastOnlineClock = now
    state.TotalOnlineSeconds = math.max(0, math.floor(tonumber(state.TotalOnlineSeconds) or 0)) + delta
    if self._taskService and self._taskService.RecordOnlineSeconds then
        self._taskService:RecordOnlineSeconds(actor, delta)
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    if shouldCheckTitles == true then
        self:CheckTitleUnlocks(actor)
    end
    return state.TotalOnlineSeconds
end

function PlayerStateService:_addDiamondsWithoutPush(actor, amount, context)
    local state = self:_getOrCreateState(actor)
    local delta = math.floor(tonumber(amount) or 0)
    if delta == 0 then
        return state.Diamonds
    end

    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0) + delta)
    if shouldCountDiamondEarn(delta, context) then
        state.TotalDiamondsEarned = math.max(0, math.floor(tonumber(state.TotalDiamondsEarned) or 0)) + delta
        if self._taskService and self._taskService.RecordDiamondsEarned then
            self._taskService:RecordDiamondsEarned(actor, delta, context)
        end
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_trackEconomy(
        actor,
        delta >= 0 and Enum.AnalyticsEconomyFlowType.Source or Enum.AnalyticsEconomyFlowType.Sink,
        "Diamonds",
        math.abs(delta),
        state.Diamonds,
        context
    )
    if shouldCountDiamondEarn(delta, context) then
        self:CheckTitleUnlocks(actor)
    end
    return state.Diamonds
end

function PlayerStateService:AwardPlayerKillReward(killer, target)
    if not (ActorUtils.IsPlayer(killer) and ActorUtils.IsPlayer(target)) then
        return false
    end
    if ActorUtils.IsSameActor(killer, target) then
        return false
    end

    self:AddKillCount(killer, 1)
    if self._taskService and self._taskService.RecordPlayerKill then
        self._taskService:RecordPlayerKill(killer, 1)
    end
    local rewardAmount = GameConfig.ECONOMY.PlayerKillDiamondReward
    local specialEventEffect = self:GetSpecialEventEffect(killer)
    if specialEventEffect and specialEventEffect.PlayerKillDiamondMultiplier then
        rewardAmount = math.max(0, math.floor((tonumber(rewardAmount) or 0) * math.max(1, tonumber(specialEventEffect.PlayerKillDiamondMultiplier) or 1) + 0.5))
    end

    self:_addDiamondsWithoutPush(killer, rewardAmount, {
        source = "player",
        productGroup = "combat",
        itemSku = "PlayerKillReward",
    })
    return true
end

function PlayerStateService:GetRequiredRebirthScore(actor)
    local state = self:_getOrCreateState(actor)
    return GameConfig.GetRequiredRebirthScore(state.Rebirth)
end

function PlayerStateService:GetExperienceMultiplier(actor)
    local state = self:_getOrCreateState(actor)
    local rebirthBonus = GameConfig.GetRebirthExperienceBonus(state.Rebirth)
    local extraBonus = math.max(0, tonumber(state.ExtraExperienceBonus) or 0)
    local potionBonus = self:GetPotionExperienceBonus(actor)
    local friendBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    local subscriptionBonus = self._subscriptionService and self._subscriptionService.GetExperienceBonus and self._subscriptionService:GetExperienceBonus(actor) or 0
    local attributeBonus = math.max(0, tonumber((self:GetAttributeFinalStats(actor) or {}).ExpGainBonus) or 0)
    local specialEventBonus = math.max(0, tonumber((self:GetSpecialEventEffect(actor) or {}).ExperienceBonus) or 0)
    local trailBonus = self:GetTrailExperienceBonus(actor)
    return math.max(1, 1 + rebirthBonus + extraBonus + potionBonus + friendBonus + attributeBonus + math.max(0, tonumber(subscriptionBonus) or 0) + specialEventBonus + trailBonus)
end

function PlayerStateService:GetActivePotions(actor)
    local state = self:_getOrCreateState(actor)
    local normalized = normalizeActivePotions(state.ActivePotions, state.ActivePotion)
    state.ActivePotions = normalized
    state.ActivePotion = nil
    return normalized
end

function PlayerStateService:GetActivePotion(actor)
    local activePotions = self:GetActivePotions(actor)
    local firstPotion = nil
    for _, activePotion in pairs(activePotions) do
        if not firstPotion or activePotion.ExpiresAt < firstPotion.ExpiresAt then
            firstPotion = activePotion
        end
    end
    return firstPotion
end

function PlayerStateService:GetPotionExperienceBonus(actor)
    local totalBonus = 0
    for _, activePotion in pairs(self:GetActivePotions(actor)) do
        totalBonus += math.max(0, tonumber(activePotion.ExperienceBonus) or 0)
    end
    return totalBonus
end

function PlayerStateService:GetPotionMoveSpeedBonus(actor)
    local totalBonus = 0
    for _, activePotion in pairs(self:GetActivePotions(actor)) do
        totalBonus += math.max(0, tonumber(activePotion.MoveSpeedBonus) or 0)
    end
    return totalBonus
end

function PlayerStateService:ClearExpiredPotions(actor)
    local state = self:_getOrCreateState(actor)
    if not (hasActivePotionEntries(state.ActivePotions) or state.ActivePotion ~= nil) then
        return false
    end

    local changed = state.ActivePotion ~= nil
    local normalized = {}

    if type(state.ActivePotions) == "table" then
        for potionId, activePotion in pairs(state.ActivePotions) do
            local normalizedPotion = normalizeActivePotion(activePotion, potionId)
            if normalizedPotion then
                normalized[tostring(normalizedPotion.Id)] = normalizedPotion
            else
                changed = true
            end
        end
    end

    local normalizedLegacyPotion = normalizeActivePotion(state.ActivePotion)
    if normalizedLegacyPotion then
        local potionKey = tostring(normalizedLegacyPotion.Id)
        if not normalized[potionKey] then
            normalized[potionKey] = normalizedLegacyPotion
        end
    end

    state.ActivePotions = normalized
    state.ActivePotion = nil
    return changed
end

function PlayerStateService:ClearExpiredPotion(actor)
    return self:ClearExpiredPotions(actor)
end

function PlayerStateService:GetMoveSpeedMultiplier(actor)
    local potionMoveSpeedBonus = self:GetPotionMoveSpeedBonus(actor)
    local finalStats = self:GetAttributeFinalStats(actor) or {}
    local attributeMoveSpeedBonus = math.max(0, (tonumber(finalStats.MoveSpeedMultiplier) or 1) - 1)
    local specialEventEffect = self:GetSpecialEventEffect(actor)
    local specialEventMoveSpeedMultiplier = math.max(1, tonumber(specialEventEffect and specialEventEffect.MoveSpeedMultiplier) or 1)
    return math.max(0.1, (1 + potionMoveSpeedBonus + attributeMoveSpeedBonus) * specialEventMoveSpeedMultiplier)
end

function PlayerStateService:_countServerFriends(player)
    if not ActorUtils.IsPlayer(player) then
        return 0
    end

    local friendCount = 0
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player and otherPlayer.Parent then
            self:_addPerfStat("FriendPairsChecked")
            local success, isFriend = pcall(function()
                return player:IsFriendsWith(otherPlayer.UserId)
            end)
            if success and isFriend == true then
                friendCount += 1
            end
        end
    end
    return friendCount
end

function PlayerStateService:RefreshFriendExperienceBonuses()
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    self:_addPerfStat("FriendRefreshes")
    for _, player in ipairs(Players:GetPlayers()) do
        if player and player.Parent then
            self:_addPerfStat("FriendPlayersChecked")
            local state = self:_getOrCreateState(player)
            local friendCount = self:_countServerFriends(player)
            local friendBonus = friendCount * FRIEND_EXPERIENCE_BONUS_PER_FRIEND
            local previousCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
            local previousBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)

            if previousCount ~= friendCount or math.abs(previousBonus - friendBonus) > 0.0001 then
                state.FriendCount = friendCount
                state.FriendExperienceBonus = friendBonus
                self:PushState(player)
            end
        end
    end
    if startedAt then
        self:_addPerfStat("FriendRefreshElapsedSeconds", os.clock() - startedAt)
        self:_logPerfStats(os.clock())
    end
end

function PlayerStateService:QueueFriendBonusRefresh(delaySeconds)
    self._friendBonusRefreshToken += 1
    local token = self._friendBonusRefreshToken
    local delayTime = math.max(0, tonumber(delaySeconds) or 1)

    task.delay(delayTime, function()
        if token ~= self._friendBonusRefreshToken then
            return
        end
        self:RefreshFriendExperienceBonuses()
    end)
end

function PlayerStateService:AddRebirthScore(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    if delta <= 0 then
        return state.RebirthScore or 0
    end

    state.RebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0)) + delta
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.RebirthScore
end

function PlayerStateService:CanRebirth(actor)
    local state = self:_getOrCreateState(actor)
    return math.max(0, tonumber(state.RebirthScore) or 0) >= GameConfig.GetRequiredRebirthScore(state.Rebirth)
end

function PlayerStateService:SetRebirth(actor, count)
    local state = self:_getOrCreateState(actor)
    state.Rebirth = math.max(0, math.floor(tonumber(count) or 0))
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Rebirth
end

function PlayerStateService:AddRebirth(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    state.Rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0))
    state.Rebirth += delta
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Rebirth
end

function PlayerStateService:SetRebirthData(actor, rebirth, rebirthScore, highestLevelReached, savedProgress)
    local state = self:_getOrCreateState(actor)
    state.Rebirth = math.max(0, math.floor(tonumber(rebirth) or 0))
    state.RebirthScore = math.max(0, math.floor(tonumber(rebirthScore) or 0))
    state.HighestLevelReached = math.max(
        normalizeLevel(highestLevelReached),
        normalizeLevel(state.HighestLevelReached or state.Level),
        state.Level
    )
    if type(savedProgress) == "table" then
        state.Diamonds = math.max(0, math.floor(tonumber(savedProgress.diamonds or savedProgress.Diamonds) or 0))
        state.WheelSpins = math.max(0, math.floor(tonumber(savedProgress.wheelSpins or savedProgress.WheelSpins) or 0))
        state.Potions = normalizePotionInventory(savedProgress.potions or savedProgress.Potions)
        state.GroupRewards = normalizeGroupRewards(savedProgress.groupRewards or savedProgress.GroupRewards)
        state.SubscriptionClaims = normalizeSubscriptionClaims(savedProgress.subscriptionClaims or savedProgress.SubscriptionClaims)
        state.ShopClaims = normalizeShopClaims(savedProgress.shopClaims or savedProgress.ShopClaims)
        state.CodeClaims = normalizeCodeClaims(savedProgress.codeClaims or savedProgress.CodeClaims)
        state.DailyFreeReviveClaims = normalizeDailyFreeReviveClaims(savedProgress.dailyFreeReviveClaims or savedProgress.DailyFreeReviveClaims)
        state.TaskState = savedProgress.taskState or savedProgress.TaskState or {}
        state.SevenDayLoginRewardState = normalizeSevenDayLoginRewardState(savedProgress.sevenDayLoginRewardState or savedProgress.SevenDayLoginRewardState)
        state.Options = normalizeOptions(savedProgress.options or savedProgress.Options)
        state.GuideCompleted = readGuideCompleted(savedProgress, true)
        state.FavoritePromptState = normalizeFavoritePromptState(savedProgress.favoritePromptState or savedProgress.FavoritePromptState)
        state.OwnedSkins = normalizeOwnedSkins(savedProgress.ownedSkins or savedProgress.OwnedSkins)
        state.EquippedSkinId = normalizeEquippedSkinId(savedProgress.equippedSkinId or savedProgress.EquippedSkinId, state.OwnedSkins)
        state.OwnedTrails = normalizeOwnedTrails(savedProgress.ownedTrails or savedProgress.OwnedTrails)
        state.EquippedTrailId = normalizeEquippedTrailId(savedProgress.equippedTrailId or savedProgress.EquippedTrailId, state.OwnedTrails)
        state.Chests = normalizeChests(savedProgress.chests or savedProgress.Chests)
        state.OwnedTitles = normalizeOwnedTitles(savedProgress.ownedTitles or savedProgress.OwnedTitles)
        state.EquippedTitleId = normalizeEquippedTitleId(savedProgress.equippedTitleId or savedProgress.EquippedTitleId, state.OwnedTitles)
        local savedAttributeCaps = savedProgress.attributeCaps or savedProgress.AttributeCaps or state.AttributeCaps
        preserveLegacyBladeRecoveryCap(state, savedAttributeCaps, savedProgress.legacyBladeRecoveryCap or savedProgress.LegacyBladeRecoveryCap)
        state.AttributeCaps = AttributeConfig.NormalizeCaps(savedAttributeCaps)
        state.TotalDeaths = normalizeNonNegativeInteger(savedProgress.totalDeaths or savedProgress.TotalDeaths)
        state.TotalDiamondsEarned = normalizeNonNegativeInteger(savedProgress.totalDiamondsEarned or savedProgress.TotalDiamondsEarned)
        state.TotalOnlineSeconds = normalizeNonNegativeInteger(savedProgress.totalOnlineSeconds or savedProgress.TotalOnlineSeconds)
        state.HasUnseenTitleUnlock = savedProgress.hasUnseenTitleUnlock == true or savedProgress.HasUnseenTitleUnlock == true
        state.LastOnlineClock = os.clock()
        local savedWeaponUnlockRewards = savedProgress.weaponUnlockRewards or savedProgress.WeaponUnlockRewards
        local maxPromptedTierIndex = getMaxUnlockedTierIndexForLevel(state.HighestLevelReached)
        if savedWeaponUnlockRewards ~= nil then
            state.WeaponUnlockRewards = normalizeWeaponUnlockRewards(savedWeaponUnlockRewards, maxPromptedTierIndex)
        else
            state.WeaponUnlockRewards = buildHandledWeaponUnlockRewardsForLevel(state.HighestLevelReached)
        end
        local combatSnapshot = savedProgress.combatSnapshot or savedProgress.CombatSnapshot
        if type(combatSnapshot) == "table" then
            local restoreEligible = combatSnapshot.restoreEligible == true
            local savedAt = math.floor(tonumber(combatSnapshot.savedAt) or 0)
            local maxAge = math.max(1, tonumber(GameConfig.REBIRTH.CombatSnapshotMaxAgeSeconds) or 1800)
            local snapshotLevel = math.max(1, math.floor(tonumber(combatSnapshot.level) or 0))
            local snapshotExperience = math.max(0, math.floor(tonumber(combatSnapshot.experience) or 0))
            local respawnMode = tostring(combatSnapshot.respawnMode or "")
            local bypassMaxAge = shouldBypassCombatSnapshotMaxAge(respawnMode)
            if restoreEligible and savedAt > 0 and (bypassMaxAge or (os.time() - savedAt) <= maxAge) then
                local restoredLevel = math.clamp(snapshotLevel, 1, GameConfig.PLAYER.MaxSupportedLevel)
                state.Level = restoredLevel
                state.Experience = math.min(snapshotExperience, GameConfig.GetNextLevelExperience(restoredLevel))
                state.HighestLevelReached = math.max(state.HighestLevelReached, restoredLevel)
                self:_ensureSkillPointsForLevel(state, restoredLevel)
                state.IsInArena = false
                state.Alive = true
                state.KillCount = 0
                state.Buffs = {}
                state.CurrentHealth = GameConfig.GetMaxHealthForLevel(restoredLevel)
            end
        end
        state.ActivePotions = normalizeActivePotions(savedProgress.activePotions or savedProgress.ActivePotions, savedProgress.activePotion or savedProgress.ActivePotion)
        state.ActivePotion = nil
    end
    self:_applyLevelDerivedState(state)
    if state.IsInArena ~= true then
        state.CurrentHealth = state.MaxHealth
    end
    self:_syncLeaderstats(actor, state)
    self:SyncHumanoidMovement(actor)
    self:CheckTitleUnlocks(actor)
    self:PushState(actor)
    if self._weaponUnlockRewardService and self._weaponUnlockRewardService.SyncPendingPrompt then
        self._weaponUnlockRewardService:SyncPendingPrompt(actor)
    end
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state
end

function PlayerStateService:ApplyRebirth(actor, spendRequiredScore)
    local state = self:_getOrCreateState(actor)
    local previousRebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0))
    local currentScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0))
    local requiredScore = spendRequiredScore == true and GameConfig.GetRequiredRebirthScore(previousRebirth) or 0
    if currentScore < requiredScore then
        return nil, "Requirement not met"
    end

    -- Commit both authoritative values before any notification can yield or fail.
    state.RebirthScore = currentScore - requiredScore
    state.Rebirth = previousRebirth + 1
    local syncSuccess, syncError = pcall(function()
        if self._rebirthService then
            self._rebirthService:MarkDirty(actor)
        end
        self:_syncLeaderstats(actor, state)
        self:PushState(actor)
        if self._leaderboardService then
            self._leaderboardService:MarkDirty()
        end
    end)
    if not syncSuccess then
        warn("[PlayerStateService] Rebirth 已结算，但状态通知失败: " .. tostring(syncError))
    end
    return state
end

function PlayerStateService:GetGroupRewards(actor)
    local state = self:_getOrCreateState(actor)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    return state.GroupRewards
end

function PlayerStateService:HasGroupReward(actor, groupId)
    local rewards = self:GetGroupRewards(actor)
    return rewards[tostring(math.floor(tonumber(groupId) or 0))] == true
end

function PlayerStateService:MarkGroupReward(actor, groupId)
    local state = self:_getOrCreateState(actor)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    local resolvedGroupId = math.floor(tonumber(groupId) or 0)
    if resolvedGroupId <= 0 then
        return false
    end
    local key = tostring(resolvedGroupId)
    if state.GroupRewards[key] == true then
        return false
    end
    state.GroupRewards[key] = true
    return true
end

function PlayerStateService:GetFavoritePromptState(actor)
    local state = self:_getOrCreateState(actor)
    state.FavoritePromptState = normalizeFavoritePromptState(state.FavoritePromptState)
    return state.FavoritePromptState
end

function PlayerStateService:GetWeaponUnlockRewards(actor)
    local state = self:_getOrCreateState(actor)
    state.WeaponUnlockRewards = normalizeWeaponUnlockRewards(
        state.WeaponUnlockRewards,
        getMaxUnlockedTierIndexForLevel(state.HighestLevelReached or state.Level)
    )
    return state.WeaponUnlockRewards
end

function PlayerStateService:SetWeaponUnlockRewards(actor, rewards)
    local state = self:_getOrCreateState(actor)
    state.WeaponUnlockRewards = normalizeWeaponUnlockRewards(
        rewards,
        getMaxUnlockedTierIndexForLevel(state.HighestLevelReached or state.Level)
    )
    return state.WeaponUnlockRewards
end

function PlayerStateService:BuildHandledWeaponUnlockRewardsForLevel(level)
    return buildHandledWeaponUnlockRewardsForLevel(level)
end

function PlayerStateService:GetMaxUnlockedWeaponTierIndexForLevel(level)
    return getMaxUnlockedTierIndexForLevel(level)
end

function PlayerStateService:SetRespawnCount(actor, count)
    return self:SetRebirth(actor, count)
end

function PlayerStateService:AddRespawnCount(actor, amount)
    return self:AddRebirth(actor, amount)
end

function PlayerStateService:_addExperience(actor, amount, requireActiveInArena)
    local state = self:_getOrCreateState(actor)
    if requireActiveInArena and not (state.Alive and state.IsInArena) then
        return false, state.Level, state.Experience
    end

    local gained = math.max(0, math.floor(tonumber(amount) or 0))
    if gained <= 0 then
        return false, state.Level, state.Experience
    end

    local previousLevel = state.Level
    state.Experience += gained

    while state.Level < GameConfig.PLAYER.MaxSupportedLevel and state.Experience >= GameConfig.GetNextLevelExperience(state.Level) do
        local needed = GameConfig.GetNextLevelExperience(state.Level)
        state.Experience -= needed
        state.Level += 1
    end

    if state.Level >= GameConfig.PLAYER.MaxSupportedLevel then
        state.Level = GameConfig.PLAYER.MaxSupportedLevel
        state.Experience = math.min(state.Experience, GameConfig.GetNextLevelExperience(state.Level))
    end

    local didLevelUp = state.Level > previousLevel
    local previousMaxHealth = state.MaxHealth
    if didLevelUp then
        self:_awardSkillPointsForLevelGain(state, previousLevel, state.Level)
        self:_applyLevelDerivedState(state)
        local healthGain = math.max(0, state.MaxHealth - previousMaxHealth)
        state.CurrentHealth = math.min(state.MaxHealth, state.CurrentHealth + healthGain)
        if self._weaponUnlockRewardService and self._weaponUnlockRewardService.HandleLevelChanged then
            self._weaponUnlockRewardService:HandleLevelChanged(actor, previousLevel, state.Level)
        end
        self:SyncCharacterState(actor)
        if self._weaponService then
            self._weaponService:RebuildWeaponsForActor(actor, {
                previousLevel = previousLevel,
            })
        end
        if self._rebirthService then
            self._rebirthService:MarkDirty(actor)
        end
        self:_fireLevelUpFeedback(actor, previousLevel, state.Level)
        self:CheckTitleUnlocks(actor)
    else
        state.NextLevelExperience = GameConfig.GetNextLevelExperience(state.Level)
    end

    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if didLevelUp and self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    if didLevelUp then
        self:_markArenaProgressDirty()
        if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService then
            if self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.FirstLevelUp") then
                self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 8, "FirstLevelUp", {
                    source = "experience",
                    previousLevel = previousLevel,
                    level = state.Level,
                })
            end
            self._gameAnalyticsService:TrackCustom(actor, "LevelUp", state.Level, {
                source = "experience",
                previousLevel = previousLevel,
                level = state.Level,
            })
        end
    end
    return didLevelUp, state.Level, state.Experience
end

function PlayerStateService:AddExperience(actor, amount)
    return self:_addExperience(actor, amount, true)
end

function PlayerStateService:AddAuthorizedExperience(actor, amount)
    return self:_addExperience(actor, amount, false)
end

function PlayerStateService:AddExperienceWithMultiplier(actor, amount)
    local totalAmount = math.max(0, math.floor((tonumber(amount) or 0) * self:GetExperienceMultiplier(actor)))
    local didLevelUp, level, experience = self:AddExperience(actor, totalAmount)
    return didLevelUp, level, experience, totalAmount
end

function PlayerStateService:SetLevelForStudioCommand(actor, level)
    local state = self:_getOrCreateState(actor)
    local previousLevel = math.max(1, math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel))
    local targetLevel = math.clamp(
        math.floor(tonumber(level) or previousLevel),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    local previousMaxHealth = math.max(1, math.floor(tonumber(state.MaxHealth) or GameConfig.GetMaxHealthForLevel(previousLevel)))

    state.Level = targetLevel
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or previousLevel), targetLevel)
    state.Experience = math.min(math.max(0, math.floor(tonumber(state.Experience) or 0)), GameConfig.GetNextLevelExperience(targetLevel))
    if targetLevel > previousLevel then
        self:_awardSkillPointsForLevelGain(state, previousLevel, targetLevel)
    end
    self:_applyLevelDerivedState(state)
    local maxHealthDelta = state.MaxHealth - previousMaxHealth
    state.CurrentHealth = math.clamp(math.floor(tonumber(state.CurrentHealth) or state.MaxHealth) + maxHealthDelta, 1, state.MaxHealth)
    self:_syncLeaderstats(actor, state)
    self:SyncCharacterState(actor)
    if self._weaponService then
        self._weaponService:RebuildWeaponsForActor(actor, {
            previousLevel = previousLevel,
        })
    end
    if self._weaponUnlockRewardService and self._weaponUnlockRewardService.HandleLevelChanged and targetLevel > previousLevel then
        self._weaponUnlockRewardService:HandleLevelChanged(actor, previousLevel, targetLevel)
        self:_fireLevelUpFeedback(actor, previousLevel, targetLevel)
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:CheckTitleUnlocks(actor)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    self:_markArenaProgressDirty()
    return targetLevel, state.Experience
end

function PlayerStateService:ApplyLevelMultiplier(actor, multiplier)
    local state = self:_getOrCreateState(actor)
    local resolvedMultiplier = math.max(1, tonumber(multiplier) or 1)
    local previousLevel = math.max(1, math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel))
    local targetLevel = math.clamp(
        math.floor((previousLevel * resolvedMultiplier) + 0.5),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )

    if targetLevel <= previousLevel then
        state.Level = targetLevel
        self:_applyLevelDerivedState(state)
        self:_syncLeaderstats(actor, state)
        self:SyncCharacterState(actor)
        self:PushState(actor)
        return false, state.Level, state.Experience
    end

    local previousMaxHealth = state.MaxHealth
    state.Level = targetLevel
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or previousLevel), targetLevel)
    state.Experience = math.min(math.max(0, math.floor(tonumber(state.Experience) or 0)), GameConfig.GetNextLevelExperience(targetLevel))
    self:_awardSkillPointsForLevelGain(state, previousLevel, state.Level)
    self:_applyLevelDerivedState(state)
    local healthGain = math.max(0, state.MaxHealth - previousMaxHealth)
    state.CurrentHealth = math.min(state.MaxHealth, state.CurrentHealth + healthGain)
    if self._weaponUnlockRewardService and self._weaponUnlockRewardService.HandleLevelChanged then
        self._weaponUnlockRewardService:HandleLevelChanged(actor, previousLevel, state.Level)
    end
    self:SyncCharacterState(actor)
    if self._weaponService then
        self._weaponService:RebuildWeaponsForActor(actor, {
            previousLevel = previousLevel,
        })
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_fireLevelUpFeedback(actor, previousLevel, state.Level)
    self:CheckTitleUnlocks(actor)
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    self:_markArenaProgressDirty()
    return true, state.Level, state.Experience
end

function PlayerStateService:RestoreCombatProgress(actor, snapshot, options)
    if not actor or type(snapshot) ~= "table" then
        return false
    end

    local restoreToLobby = type(options) == "table" and options.restoreToLobby == true
    local state = self:_getOrCreateState(actor)
    local previousLevel = math.max(1, math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel))
    local restoredLevel = math.clamp(
        math.floor(tonumber(snapshot.preDeathLevel or snapshot.level) or GameConfig.PLAYER.BaseLevel),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    local restoredExperience = math.min(
        math.max(0, math.floor(tonumber(snapshot.preDeathExperience or snapshot.experience) or GameConfig.PLAYER.BaseExperience)),
        GameConfig.GetNextLevelExperience(restoredLevel)
    )

    state.Alive = true
    state.IsInArena = not restoreToLobby
    state.Level = restoredLevel
    state.Experience = restoredExperience
    state.KillCount = math.max(0, math.floor(tonumber(snapshot.preDeathKillCount or state.KillCount) or 0))
    state.MoveSpeed = GameConfig.PLAYER.BaseMoveSpeed
    state.Buffs = {}
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or previousLevel), restoredLevel)
    self:_applyAttributeSnapshot(state, snapshot.attributeSnapshot or snapshot.attributes)
    self:_ensureSkillPointsForLevel(state, restoredLevel)
    self:_applyLevelDerivedState(state)
    if type(options) == "table" and options.restoreFullHealth == false then
        state.CurrentHealth = math.clamp(math.floor(tonumber(state.CurrentHealth) or state.MaxHealth), 1, state.MaxHealth)
    else
        state.CurrentHealth = state.MaxHealth
    end

    self:_syncLeaderstats(actor, state)
    self:SyncCharacterState(actor)
    self:UpdateOverheadHealthBar(actor)
    if not restoreToLobby and (type(options) ~= "table" or options.rebuildWeapons ~= false) then
        if self._weaponService and self._weaponService.RebuildWeaponsForPlayer then
            self._weaponService:RebuildWeaponsForPlayer(actor)
        elseif self._weaponService and self._weaponService.RebuildWeaponsForActor then
            self._weaponService:RebuildWeaponsForActor(actor)
        end
    elseif restoreToLobby then
        if self._weaponService and self._weaponService.ClearPlayerWeapons then
            self._weaponService:ClearPlayerWeapons(actor)
        end
    end
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_markArenaProgressDirty()
    return true, state
end

function PlayerStateService:ResetCombatState(actor)
    local wasInArena = self:_getOrCreateState(actor).IsInArena == true
    local state = self:_getOrCreateState(actor)
    state.IsInArena = false
    state.Alive = false
    state.Level = GameConfig.PLAYER.BaseLevel
    state.Experience = GameConfig.PLAYER.BaseExperience
    state.MoveSpeed = GameConfig.PLAYER.BaseMoveSpeed
    state.KillCount = 0
    state.Buffs = {}
    self:_resetAttributeProgress(state)
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    self:_syncLeaderstats(actor, state)
    self:UpdateOverheadHealthBar(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    if wasInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:CaptureHumanoidHealth(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    state.MaxHealth = humanoid.MaxHealth
    state.CurrentHealth = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
    return true
end

function PlayerStateService:OnCharacterAdded(actor)
    self:_addPerfStat("CharacterAdded")
    local wasInArena = self:_getOrCreateState(actor).IsInArena == true
    local state = self:_getOrCreateState(actor)
    state.IsInArena = false
    state.Alive = true
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    self:_configureCharacterCollision(actor, ActorUtils.GetCharacter(actor))
    self:SyncCharacterState(actor)
    self:_syncLeaderstats(actor, state)
    self:UpdateOverheadHealthBar(actor)
    if not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(actor) then
        self:PushState(actor)
    end
    if wasInArena then
        self:_markArenaProgressDirty()
    end
    if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService and self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.CharacterReady") then
        self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 3, "CharacterReady", {
            source = "spawn",
        })
    end
    self:_logPerfStats(os.clock())
end

function PlayerStateService:OnPlayerRemoving(player)
    local state = self._statesByActorId[getActorId(player)]
    local wasInArena = state and state.IsInArena == true
    if state then
        self:RefreshOnlineTime(player, true)
    end
    self._statesByActorId[getActorId(player)] = nil
    local collisionConnection = self._characterCollisionConnectionsByActorId[getActorId(player)]
    if collisionConnection and collisionConnection.Connected then
        collisionConnection:Disconnect()
    end
    self._characterCollisionConnectionsByActorId[getActorId(player)] = nil
    self:QueueFriendBonusRefresh()
    if wasInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:GetState(actor)
    return self:_getOrCreateState(actor)
end

function PlayerStateService:IsInArena(actor)
    return self:_getOrCreateState(actor).IsInArena == true
end

function PlayerStateService:SetInArena(actor, isInArena)
    local state = self:_getOrCreateState(actor)
    local wasActiveInArena = state.IsInArena == true and state.Alive == true
    state.IsInArena = isInArena == true
    if state.IsInArena then
        state.Alive = true
        self:_applyLevelDerivedState(state)
        if state.CurrentHealth <= 0 then
            state.CurrentHealth = state.MaxHealth
        end
        self:SyncCharacterState(actor)
    end
    self:_syncLeaderstats(actor, state)
    self:UpdateOverheadHealthBar(actor)
    local isActiveInArena = state.IsInArena == true and state.Alive == true
    if wasActiveInArena ~= isActiveInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:GetArenaActors()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        local actor = state.ActorRef
        if actor and state.IsInArena and state.Alive then
            if ActorUtils.IsPlayer(actor) then
                if actor.Parent then
                    table.insert(result, actor)
                end
            elseif ActorUtils.IsBot(actor) then
                table.insert(result, actor)
            end
        end
    end
    return result
end

function PlayerStateService:GetArenaPlayers()
    local result = {}
    for _, actor in ipairs(self:GetArenaActors()) do
        if ActorUtils.IsPlayer(actor) then
            table.insert(result, actor)
        end
    end
    return result
end

function PlayerStateService:GetAllActors()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        if state.ActorRef then
            table.insert(result, state.ActorRef)
        end
    end
    return result
end

function PlayerStateService:GetAllPlayerStates()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        if state.ActorKind == "Player" then
            table.insert(result, state)
        end
    end
    return result
end

return PlayerStateService
