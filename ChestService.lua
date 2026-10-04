--[[
Script: ChestService
Type: ModuleScript
Studio path: ServerScriptService/Services/ChestService
Purpose: V5.9 server-authoritative chest inventory and opening flow.
]]

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

    error(string.format("[ChestService] Missing shared module %s", tostring(moduleName or "")))
end

local ChestConfig = requireSharedModule("ChestConfig")
local ShopConfig = requireSharedModule("ShopConfig")

local ChestService = {}

ChestService.DefaultChestId = 101
ChestService._remoteEventService = nil
ChestService._playerStateService = nil
ChestService._rebirthService = nil
ChestService._potionService = nil
ChestService._skinService = nil
ChestService._gameAnalyticsService = nil
ChestService._stateSyncEvent = nil
ChestService._requestStateSyncEvent = nil
ChestService._requestOpenEvent = nil
ChestService._requestRewardClaimEvent = nil
ChestService._shopRewardFeedbackEvent = nil
ChestService._connections = {}
ChestService._openLocksByUserId = {}
ChestService._pendingRewardsByUserId = {}
ChestService._random = Random.new()

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getUserId(player)
    return player and player.UserId or 0
end

local function copyChests(chests)
    local result = {}
    if type(chests) ~= "table" then
        return result
    end
    for chestId, amount in pairs(chests) do
        local count = math.max(0, math.floor(tonumber(amount) or 0))
        if count > 0 then
            result[tostring(chestId)] = count
        end
    end
    return result
end

local function cloneReward(reward)
    local result = {}
    for key, value in pairs(reward or {}) do
        result[key] = value
    end
    return result
end

local function getRewardMergeKey(reward)
    local rewardType = tostring(reward.RewardType or "")
    if rewardType == "Potion" then
        return rewardType .. ":" .. tostring(reward.PotionId or 0)
    elseif rewardType == "Trail" then
        return rewardType .. ":" .. tostring(reward.TrailId or 0)
    elseif rewardType == "Chest" then
        return rewardType .. ":" .. tostring(reward.ChestId or 0)
    end
    return rewardType
end

local function getLimitedRewardKey(reward)
    if type(reward) ~= "table" or reward.IsLimited ~= true then
        return nil
    end

    local rewardType = tostring(reward.RewardType or "")
    if rewardType == "Trail" then
        return rewardType .. ":" .. tostring(math.floor(tonumber(reward.TrailId) or 0))
    end
    return rewardType
end

local function mergeRewards(rewards)
    local order = {}
    local byKey = {}
    for _, reward in ipairs(rewards or {}) do
        local key = getRewardMergeKey(reward)
        local existing = byKey[key]
        if existing then
            if tostring(existing.RewardType or "") == "Trail" then
                existing.Amount = 1
            else
                existing.Amount = math.max(1, math.floor(tonumber(existing.Amount) or 1))
                    + math.max(1, math.floor(tonumber(reward.Amount) or 1))
            end
        else
            existing = cloneReward(reward)
            byKey[key] = existing
            table.insert(order, key)
        end
    end

    local result = {}
    for _, key in ipairs(order) do
        table.insert(result, byKey[key])
    end
    return result
end

local function makeRewardClaimId(player, chestId)
    return string.format(
        "%d:%d:%d:%d",
        getUserId(player),
        math.floor(tonumber(chestId) or 0),
        math.floor(os.clock() * 1000),
        math.random(100000, 999999)
    )
end

function ChestService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function ChestService:BuildStatePayload(player)
    local chests = self._playerStateService and self._playerStateService.GetChests and self._playerStateService:GetChests(player) or {}
    return {
        chests = copyChests(chests),
        selectedChestId = ChestService.DefaultChestId,
        chestConfigs = ChestConfig.CopyAllForClient(),
        timestamp = os.clock(),
    }
end

function ChestService:PushState(player, openRejectedReason)
    if not (self._stateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    local payload = self:BuildStatePayload(player)
    payload.openRejectedReason = openRejectedReason
    self._stateSyncEvent:FireClient(player, payload)
end

function ChestService:_isLimitedRewardAlreadyOwned(player, reward)
    if not (reward and reward.IsLimited == true) then
        return false
    end
    if self._playerStateService and self._playerStateService.HasLimitedChestReward then
        return self._playerStateService:HasLimitedChestReward(player, reward) == true
    end
    return false
end

function ChestService:_chooseReward(player, chestId, sessionLimitedRewards)
    local pool = ChestConfig.GetDropPoolForChest(chestId)
    local candidates = {}
    local totalWeight = 0
    for _, reward in ipairs(pool) do
        local weight = math.max(0, tonumber(reward.Weight) or 0)
        local limitedKey = getLimitedRewardKey(reward)
        local alreadySelectedThisOpen = limitedKey and type(sessionLimitedRewards) == "table" and sessionLimitedRewards[limitedKey] == true
        if weight > 0 and not alreadySelectedThisOpen and not self:_isLimitedRewardAlreadyOwned(player, reward) then
            totalWeight += weight
            table.insert(candidates, {
                reward = reward,
                weight = weight,
            })
        end
    end

    if totalWeight <= 0 or #candidates <= 0 then
        return nil, "NoAvailableReward"
    end

    local roll = self._random:NextNumber(0, totalWeight)
    local cursor = 0
    for _, candidate in ipairs(candidates) do
        cursor += candidate.weight
        if roll <= cursor then
            return cloneReward(candidate.reward)
        end
    end
    return cloneReward(candidates[#candidates].reward)
end

function ChestService:_grantReward(player, reward, chestId, index)
    local rewardType = tostring(reward.RewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward.Amount) or 1))
    local context = {
        source = "chest",
        productGroup = "Chest",
        itemSku = "Chest_" .. tostring(chestId) .. "_" .. tostring(index or 1),
    }

    if rewardType == "Diamonds" then
        self._playerStateService:AddDiamonds(player, amount, context)
        return true
    elseif rewardType == "WheelSpins" then
        self._playerStateService:AddWheelSpins(player, amount, context)
        return true
    elseif rewardType == "Potion" then
        if not (self._potionService and self._potionService.AddPotion) then
            return false, "PotionServiceUnavailable"
        end
        return self._potionService:AddPotion(player, reward.PotionId, amount, context)
    elseif rewardType == "Trail" then
        if not (self._playerStateService and self._playerStateService.GrantTrail) then
            return false, "TrailServiceUnavailable"
        end
        local success, reason = self._playerStateService:GrantTrail(player, reward.TrailId)
        if success == true or reason == "AlreadyOwned" then
            return true, reason
        end
        return false, reason
    end

    return false, "UnsupportedRewardType"
end

function ChestService:_fireRewardFeedback(player, rewards, reason, rewardClaimId)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardPendingClaim",
        source = "Chest",
        reason = tostring(reason or "ChestOpen"),
        rewardClaimId = rewardClaimId,
        requiresClaim = true,
        rewards = ShopConfig.CopyRewardsForClient(rewards),
        closeDelay = 0.5,
        keepSourceOpen = true,
        timestamp = os.clock(),
    })
end

function ChestService:_grantPendingRewards(player, rewardClaimId, reason)
    if not (ActorUtils.IsPlayer(player) and self._playerStateService) then
        return false, "InvalidPlayer"
    end

    local userId = getUserId(player)
    local pending = self._pendingRewardsByUserId[userId]
    if not pending then
        self._openLocksByUserId[userId] = nil
        return false, "NoPendingReward"
    end
    if tostring(pending.rewardClaimId or "") ~= tostring(rewardClaimId or "") then
        return false, "InvalidRewardClaim"
    end
    if pending.claiming == true then
        return false, "AlreadyClaiming"
    end
    pending.claiming = true

    local grantedRewards = {}
    for index, reward in ipairs(pending.rewards or {}) do
        local granted, grantReason = self:_grantReward(player, reward, pending.chestId, index)
        if granted ~= true then
            warn(string.format(
                "[ChestService] Pending reward grant failed player=%s chest=%s rewardType=%s reason=%s claimReason=%s",
                tostring(player.Name),
                tostring(pending.chestId),
                tostring(reward.RewardType),
                tostring(grantReason),
                tostring(reason or "")
            ))
        else
            table.insert(grantedRewards, reward)
        end
    end

    self._pendingRewardsByUserId[userId] = nil
    self._openLocksByUserId[userId] = nil
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
    if self._skinService and self._skinService.SyncState and player.Parent then
        self._skinService:SyncState(player)
    end
    if self._playerStateService and self._playerStateService.PushState and player.Parent then
        self._playerStateService:PushState(player)
    end
    if player.Parent then
        self:PushState(player)
    end

    return true, "Claimed", mergeRewards(grantedRewards)
end

function ChestService:OpenChest(player, chestId, mode)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        self:PushState(player)
        return false, "DataLoading"
    end

    local normalizedChestId = math.floor(tonumber(chestId) or ChestService.DefaultChestId)
    local chest = ChestConfig.GetChest(normalizedChestId)
    if not chest then
        self:PushState(player)
        return false, "InvalidChest"
    end

    local userId = getUserId(player)
    if self._openLocksByUserId[userId] == true then
        self:PushState(player)
        return false, "Busy"
    end
    if self._pendingRewardsByUserId[userId] then
        self:PushState(player)
        return false, "PendingReward"
    end

    local count = self._playerStateService:GetChestCount(player, chest.Id)
    if count <= 0 then
        self:PushState(player, "NoChest")
        return false, "NoChest"
    end

    self._openLocksByUserId[userId] = true
    local openCount = tostring(mode or "") == "All" and count or 1
    local selectedRewards = {}
    local sessionLimitedRewards = {}
    for index = 1, openCount do
        local reward, reason = self:_chooseReward(player, chest.Id, sessionLimitedRewards)
        if not reward then
            self._openLocksByUserId[userId] = nil
            self:PushState(player)
            return false, reason or "NoAvailableReward"
        end
        local limitedKey = getLimitedRewardKey(reward)
        if limitedKey then
            sessionLimitedRewards[limitedKey] = true
        end
        table.insert(selectedRewards, reward)
    end

    local consumed, consumeReason = self._playerStateService:ConsumeChest(player, chest.Id, openCount, {
        source = "chest",
        productGroup = "Chest",
        itemSku = "ChestOpen_" .. tostring(chest.Id),
    })
    if consumed ~= true then
        self._openLocksByUserId[userId] = nil
        self:PushState(player)
        return false, consumeReason or "ConsumeFailed"
    end

    local rewardClaimId = makeRewardClaimId(player, chest.Id)
    self._pendingRewardsByUserId[userId] = {
        rewardClaimId = rewardClaimId,
        chestId = chest.Id,
        mode = tostring(mode or "") == "All" and "All" or "One",
        rewards = selectedRewards,
        createdAt = os.clock(),
    }
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
    if self._playerStateService and self._playerStateService.PushState then
        self._playerStateService:PushState(player)
    end
    self:PushState(player)

    local mergedRewards = mergeRewards(selectedRewards)
    self:_fireRewardFeedback(player, mergedRewards, mode == "All" and "ChestOpenAll" or "ChestOpen", rewardClaimId)
    return true, "PendingClaim", mergedRewards
end

function ChestService:_handleRequestStateSync(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self:PushState(player)
end

function ChestService:_handleRequestOpen(player, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    local chestId = ChestService.DefaultChestId
    local mode = "One"
    if type(payload) == "table" then
        chestId = math.floor(tonumber(payload.chestId or payload.ChestId) or ChestService.DefaultChestId)
        mode = tostring(payload.mode or payload.Mode or "One")
    end
    if mode ~= "All" then
        mode = "One"
    end
    self:OpenChest(player, chestId, mode)
end

function ChestService:_handleRequestRewardClaim(player, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    local rewardClaimId = nil
    if type(payload) == "table" then
        rewardClaimId = payload.rewardClaimId or payload.RewardClaimId
    end
    self:_grantPendingRewards(player, rewardClaimId, "ClientClosedRewardPopup")
end

function ChestService:AddChestForStudio(player, chestId, amount)
    if not RunService:IsStudio() then
        return false, "StudioOnly"
    end
    if not (self._playerStateService and self._playerStateService.AddChest) then
        return false, "ServiceUnavailable"
    end
    local success, reason = self._playerStateService:AddChest(player, chestId, amount, {
        source = "gm",
        productGroup = "GM_StudioOnly",
        itemSku = "GM_Chest_" .. tostring(chestId),
    })
    self:PushState(player)
    return success, reason
end

function ChestService:ClearChestsForStudio(player, chestId)
    if not RunService:IsStudio() then
        return false, "StudioOnly"
    end
    if not (self._playerStateService and self._playerStateService.GetChests) then
        return false, "ServiceUnavailable"
    end
    local chests = self._playerStateService:GetChests(player)
    if chestId then
        chests[tostring(math.floor(tonumber(chestId) or 0))] = nil
    else
        table.clear(chests)
    end
    if self._playerStateService.PushState then
        self._playerStateService:PushState(player)
    end
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
    self:PushState(player)
    return true, "Cleared"
end

function ChestService:OnPlayerAdded(player)
    self:PushState(player)
end

function ChestService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    local pending = self._pendingRewardsByUserId[userId]
    if pending then
        self:_grantPendingRewards(player, pending.rewardClaimId, "PlayerRemoving")
    end
    self._pendingRewardsByUserId[userId] = nil
    self._openLocksByUserId[userId] = nil
end

function ChestService:BindSystems(dependencies)
    dependencies = dependencies or {}
    self._playerStateService = dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies.PotionService or self._potionService
    self._skinService = dependencies.SkinService or self._skinService
    self._gameAnalyticsService = dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function ChestService:Init(dependencies)
    dependencies = dependencies or {}
    disconnectAll(self._connections)
    self._remoteEventService = dependencies.RemoteEventService or self._remoteEventService
    self._playerStateService = dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies.PotionService or self._potionService
    self._skinService = dependencies.SkinService or self._skinService
    self._gameAnalyticsService = dependencies.GameAnalyticsService or self._gameAnalyticsService

    self._stateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("ChestStateSync") or nil
    self._requestStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestChestStateSync") or nil
    self._requestOpenEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestChestOpen") or nil
    self._requestRewardClaimEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestChestRewardClaim") or nil
    self._shopRewardFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("ShopRewardFeedback") or nil

    if self._requestStateSyncEvent then
        table.insert(self._connections, self._requestStateSyncEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestStateSync(player, payload)
        end))
    end
    if self._requestOpenEvent then
        table.insert(self._connections, self._requestOpenEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestOpen(player, payload)
        end))
    end
    if self._requestRewardClaimEvent then
        table.insert(self._connections, self._requestRewardClaimEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestRewardClaim(player, payload)
        end))
    end
end

return ChestService
