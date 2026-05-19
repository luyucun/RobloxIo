--[[
脚本名字: WeaponUnlockRewardService
脚本文件: WeaponUnlockRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/WeaponUnlockRewardService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[WeaponUnlockRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local WeaponUnlockRewardService = {}

WeaponUnlockRewardService._playerStateService = nil
WeaponUnlockRewardService._rebirthService = nil
WeaponUnlockRewardService._weaponUnlockPromptEvent = nil
WeaponUnlockRewardService._requestWeaponUnlockRewardEvent = nil
WeaponUnlockRewardService._weaponUnlockRewardFeedbackEvent = nil
WeaponUnlockRewardService._claimingByUserId = {}

local function getRewardDiamonds()
    return math.max(0, math.floor(tonumber(GameConfig.WEAPON_UNLOCK and GameConfig.WEAPON_UNLOCK.RewardDiamonds) or 0))
end

local function getTierConfig(tierIndex)
    local tierName = WeaponTierConfig.Order[math.max(1, math.floor(tonumber(tierIndex) or 1))]
    return tierName, tierName and WeaponTierConfig.Tiers[tierName] or nil
end

local function buildPromptPayload(tierIndex, rewardDiamonds, rewardCount)
    local tierName, tierConfig = getTierConfig(tierIndex)
    if not tierConfig then
        return nil
    end

    return {
        eventType = "Show",
        tier = tierName,
        tierIndex = tierIndex,
        unlockLevel = WeaponTierConfig.GetUnlockLevelForTierIndex(tierIndex),
        weaponName = WeaponTierConfig.GetDisplayNameForTier(tierName),
        weaponIcon = WeaponTierConfig.GetIconImageForTier(tierName),
        damage = math.max(0, math.floor(tonumber(tierConfig.Damage) or 0)),
        rewardDiamonds = math.max(0, math.floor(tonumber(rewardDiamonds) or getRewardDiamonds())),
        rewardCount = math.max(1, math.floor(tonumber(rewardCount) or 1)),
        timestamp = os.clock(),
    }
end

local function containsTier(queue, tierIndex)
    for _, queuedTierIndex in ipairs(queue or {}) do
        if math.floor(tonumber(queuedTierIndex) or 0) == tierIndex then
            return true
        end
    end
    return false
end

local function getClaimablePendingTiers(queue, claimedTiers, maxUnlockedTierIndex)
    local result = {}
    local seen = {}
    local maxTier = math.max(1, math.floor(tonumber(maxUnlockedTierIndex) or 1))
    for _, queuedTierIndex in ipairs(queue or {}) do
        local tierIndex = math.floor(tonumber(queuedTierIndex) or 0)
        local key = tostring(tierIndex)
        if tierIndex > 1 and tierIndex <= maxTier and claimedTiers[key] ~= true and seen[key] ~= true then
            seen[key] = true
            table.insert(result, tierIndex)
        end
    end
    table.sort(result)
    return result
end

local function cleanPendingQueue(queue, claimedTiers, maxUnlockedTierIndex)
    local result = {}
    local seen = {}
    local maxTier = math.max(1, math.floor(tonumber(maxUnlockedTierIndex) or 1))
    for _, queuedTierIndex in ipairs(queue or {}) do
        local tierIndex = math.floor(tonumber(queuedTierIndex) or 0)
        local key = tostring(tierIndex)
        if tierIndex > 1
            and tierIndex <= maxTier
            and claimedTiers[key] ~= true
            and seen[key] ~= true
        then
            seen[key] = true
            table.insert(result, tierIndex)
        end
    end
    table.sort(result)
    return result
end

local function areQueuesEqual(left, right)
    if #(left or {}) ~= #(right or {}) then
        return false
    end
    for index, value in ipairs(left or {}) do
        if math.floor(tonumber(value) or 0) ~= math.floor(tonumber((right or {})[index]) or 0) then
            return false
        end
    end
    return true
end


local function removeTier(queue, tierIndex)
    local result = {}
    local removed = false
    for _, queuedTierIndex in ipairs(queue or {}) do
        local resolvedTierIndex = math.floor(tonumber(queuedTierIndex) or 0)
        if resolvedTierIndex == tierIndex and removed == false then
            removed = true
        elseif resolvedTierIndex > 0 then
            table.insert(result, resolvedTierIndex)
        end
    end
    return result, removed
end

function WeaponUnlockRewardService:_firePrompt(player, tierIndex, rewardDiamonds, rewardCount)
    if not (self._weaponUnlockPromptEvent and player and player.Parent) then
        return
    end

    local payload = buildPromptPayload(tierIndex, rewardDiamonds, rewardCount)
    if payload then
        self._weaponUnlockPromptEvent:FireClient(player, payload)
    end
end

function WeaponUnlockRewardService:_fireFeedback(player, eventType, message, tierIndex, rewardDiamonds, rewardCount, clearPending)
    if not (self._weaponUnlockRewardFeedbackEvent and player and player.Parent) then
        return
    end

    self._weaponUnlockRewardFeedbackEvent:FireClient(player, {
        eventType = eventType,
        message = message,
        tierIndex = tierIndex,
        rewardDiamonds = math.max(0, math.floor(tonumber(rewardDiamonds) or getRewardDiamonds())),
        rewardCount = math.max(1, math.floor(tonumber(rewardCount) or 1)),
        clearPending = clearPending == true,
        timestamp = os.clock(),
    })
end

function WeaponUnlockRewardService:SyncPendingPrompt(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end

    local rewards = self._playerStateService:GetWeaponUnlockRewards(player)
    local state = self._playerStateService:GetState(player)
    local maxUnlockedTierIndex = self._playerStateService:GetMaxUnlockedWeaponTierIndexForLevel(state.HighestLevelReached or state.Level)
    local cleanedQueue = cleanPendingQueue(rewards.PendingQueue, rewards.ClaimedTiers, maxUnlockedTierIndex)
    if not areQueuesEqual(cleanedQueue, rewards.PendingQueue) then
        rewards.PendingQueue = cleanedQueue
        self._playerStateService:SetWeaponUnlockRewards(player, rewards)
        if self._rebirthService then
            self._rebirthService:MarkDirty(player)
        end
    end
    local claimableTierIndexes = getClaimablePendingTiers(rewards.PendingQueue, rewards.ClaimedTiers, maxUnlockedTierIndex)
    local tierIndex = claimableTierIndexes[1]
    if tierIndex then
        self:_firePrompt(player, tierIndex, getRewardDiamonds(), 1)
    end
end

function WeaponUnlockRewardService:HandleLevelChanged(player, previousLevel, newLevel)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false
    end
    if not (self._rebirthService and self._rebirthService.IsPlayerLoaded and self._rebirthService:IsPlayerLoaded(player)) then
        return false
    end

    local newTierIndex = self._playerStateService:GetMaxUnlockedWeaponTierIndexForLevel(newLevel)
    local rewards = self._playerStateService:GetWeaponUnlockRewards(player)
    local lastPromptedTierIndex = math.max(1, math.floor(tonumber(rewards.LastPromptedTierIndex) or 1))
    local queueFromTierIndex = math.max(
        lastPromptedTierIndex + 1,
        self._playerStateService:GetMaxUnlockedWeaponTierIndexForLevel(previousLevel) + 1
    )
    if newTierIndex < queueFromTierIndex then
        return false
    end

    local didQueue = false
    for tierIndex = queueFromTierIndex, newTierIndex do
        if tierIndex > 1 and not containsTier(rewards.PendingQueue, tierIndex) then
            table.insert(rewards.PendingQueue, tierIndex)
            didQueue = true
        end
    end

    if didQueue or newTierIndex > lastPromptedTierIndex then
        rewards.LastPromptedTierIndex = math.max(lastPromptedTierIndex, newTierIndex)
        rewards.PendingQueue = cleanPendingQueue(rewards.PendingQueue, rewards.ClaimedTiers, newTierIndex)
        table.sort(rewards.PendingQueue)
        self._playerStateService:SetWeaponUnlockRewards(player, rewards)
        if self._rebirthService then
            self._rebirthService:MarkDirty(player)
        end
        if didQueue then
            self:SyncPendingPrompt(player)
        end
    end
    return didQueue
end

function WeaponUnlockRewardService:Claim(player, requestedTierIndex)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "ServiceUnavailable"
    end
    if not (self._rebirthService and self._rebirthService.IsPlayerLoaded and self._rebirthService:IsPlayerLoaded(player)) then
        self:_fireFeedback(player, "Failed", "DataLoading", requestedTierIndex)
        return false, "DataLoading"
    end

    local userId = player.UserId
    if self._claimingByUserId[userId] then
        self:_fireFeedback(player, "Failed", "Busy", requestedTierIndex)
        return false, "Busy"
    end
    self._claimingByUserId[userId] = true

    local rewards = self._playerStateService:GetWeaponUnlockRewards(player)
    local state = self._playerStateService:GetState(player)
    local maxUnlockedTierIndex = self._playerStateService:GetMaxUnlockedWeaponTierIndexForLevel(state.HighestLevelReached or state.Level)
    rewards.PendingQueue = cleanPendingQueue(rewards.PendingQueue, rewards.ClaimedTiers, maxUnlockedTierIndex)
    self._playerStateService:SetWeaponUnlockRewards(player, rewards)
    local claimableTierIndexes = getClaimablePendingTiers(rewards.PendingQueue, rewards.ClaimedTiers, maxUnlockedTierIndex)
    local currentQueuedTierIndex = claimableTierIndexes[1]
    local tierIndex = math.floor(tonumber(requestedTierIndex) or tonumber(currentQueuedTierIndex) or 0)
    local requestedKey = tostring(tierIndex)
    local rewardDiamonds = getRewardDiamonds()

    if not currentQueuedTierIndex then
        self._claimingByUserId[userId] = nil
        self:_fireFeedback(player, "Failed", "NoPendingReward", tierIndex, rewardDiamonds, 1, true)
        return false, "NoPendingReward"
    end

    if tierIndex <= 1
        or tierIndex ~= currentQueuedTierIndex
        or rewards.ClaimedTiers[requestedKey] == true
        or not containsTier(claimableTierIndexes, tierIndex)
    then
        self._claimingByUserId[userId] = nil
        self:_fireFeedback(player, "Failed", "InvalidTier", tierIndex)
        return false, "InvalidTier"
    end

    local nextQueue, didRemove = removeTier(rewards.PendingQueue, tierIndex)
    if not didRemove then
        self._claimingByUserId[userId] = nil
        self:_fireFeedback(player, "Failed", "InvalidTier", tierIndex)
        return false, "InvalidTier"
    end

    rewards.PendingQueue = nextQueue
    rewards.ClaimedTiers[requestedKey] = true
    self._playerStateService:SetWeaponUnlockRewards(player, rewards)
    self._playerStateService:_addDiamondsWithoutPush(player, rewardDiamonds)
    if self._rebirthService then
        self._rebirthService:MarkDirty(player)
    end

    self._claimingByUserId[userId] = nil
    self:_fireFeedback(player, "Success", "Claimed", tierIndex, rewardDiamonds, 1, false)
    task.delay(0.35, function()
        if player and player.Parent then
            self._playerStateService:PushState(player)
            self:SyncPendingPrompt(player)
        end
    end)
    return true
end

function WeaponUnlockRewardService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._weaponUnlockPromptEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("WeaponUnlockPrompt") or nil
    self._requestWeaponUnlockRewardEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestWeaponUnlockReward") or nil
    self._weaponUnlockRewardFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("WeaponUnlockRewardFeedback") or nil
    self._claimingByUserId = {}

    if self._requestWeaponUnlockRewardEvent then
        self._requestWeaponUnlockRewardEvent.OnServerEvent:Connect(function(player, tierIndex)
            self:Claim(player, tierIndex)
        end)
    end
end

function WeaponUnlockRewardService:OnPlayerRemoving(player)
    if player then
        self._claimingByUserId[player.UserId] = nil
    end
end

return WeaponUnlockRewardService
