--[[
脚本名字: OnlineRewardService
脚本文件: OnlineRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/OnlineRewardService
说明: V4.3 单局在线奖励计时、领取、UnlockAll 商品处理。
]]

local Players = game:GetService("Players")
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
        "[OnlineRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local OnlineRewardConfig = requireSharedModule("OnlineRewardConfig")
local ShopConfig = requireSharedModule("ShopConfig")

local OnlineRewardService = {}

OnlineRewardService._playerStateService = nil
OnlineRewardService._rebirthService = nil
OnlineRewardService._potionService = nil
OnlineRewardService._healthService = nil
OnlineRewardService._stateSyncEvent = nil
OnlineRewardService._requestStateSyncEvent = nil
OnlineRewardService._requestClaimEvent = nil
OnlineRewardService._shopRewardFeedbackEvent = nil
OnlineRewardService._lastClaimRequestClockByUserId = {}
OnlineRewardService._sessionStateByUserId = {}

local function getUnlockAllProductId()
    return math.max(0, math.floor(tonumber(OnlineRewardConfig.DeveloperProductId) or 0))
end

local function cloneClaimedMap(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end

    local rewardCount = OnlineRewardConfig.GetRewardCount()
    for key, value in pairs(source) do
        local rewardIndex = math.max(0, math.floor(tonumber(key) or tonumber(value) or 0))
        if rewardIndex >= 1 and rewardIndex <= rewardCount and value == true then
            result[rewardIndex] = true
        end
    end
    return result
end

local function cloneProcessedPurchaseMap(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end

    for key, value in pairs(source) do
        local purchaseId = tostring(key or "")
        if purchaseId ~= "" and value ~= nil then
            result[purchaseId] = math.max(0, math.floor(tonumber(value) or os.time()))
        end
    end
    return result
end

local function countClaimedRewards(sessionState)
    local count = 0
    if type(sessionState) ~= "table" or type(sessionState.ClaimedRewardIndexes) ~= "table" then
        return count
    end

    for _, isClaimed in pairs(sessionState.ClaimedRewardIndexes) do
        if isClaimed == true then
            count += 1
        end
    end
    return count
end

local function hasLockedReward(sessionState, elapsedSeconds)
    local claimed = type(sessionState) == "table" and sessionState.ClaimedRewardIndexes or {}
    local safeElapsedSeconds = math.max(0, math.floor(tonumber(elapsedSeconds) or 0))
    for _, reward in ipairs(OnlineRewardConfig.GetRewards()) do
        if claimed[reward.RewardIndex] ~= true and safeElapsedSeconds < reward.RequiredSeconds then
            return true
        end
    end
    return false
end

function OnlineRewardService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function OnlineRewardService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function OnlineRewardService:_ensureSessionState(player)
    if not ActorUtils.IsPlayer(player) then
        return nil
    end

    local userId = player.UserId
    local sessionState = self._sessionStateByUserId[userId]
    if type(sessionState) ~= "table" then
        sessionState = {
            StartedAt = os.time(),
            ClaimedRewardIndexes = {},
            ProcessedPurchaseIds = {},
        }
        self._sessionStateByUserId[userId] = sessionState
    end

    sessionState.StartedAt = math.max(0, math.floor(tonumber(sessionState.StartedAt) or os.time()))
    sessionState.ClaimedRewardIndexes = cloneClaimedMap(sessionState.ClaimedRewardIndexes)
    sessionState.ProcessedPurchaseIds = cloneProcessedPurchaseMap(sessionState.ProcessedPurchaseIds)
    return sessionState
end

function OnlineRewardService:_startNewCycle(sessionState, startTimestamp)
    if type(sessionState) ~= "table" then
        return false
    end

    sessionState.StartedAt = math.max(0, math.floor(tonumber(startTimestamp) or os.time()))
    sessionState.ClaimedRewardIndexes = {}
    return true
end

function OnlineRewardService:_buildStatePayload(player, sessionState, nowTimestamp)
    local resolvedSessionState = sessionState or self:_ensureSessionState(player)
    local now = math.max(0, math.floor(tonumber(nowTimestamp) or os.time()))
    local startedAt = resolvedSessionState and math.max(0, math.floor(tonumber(resolvedSessionState.StartedAt) or now)) or now
    local elapsedSeconds = math.max(0, now - startedAt)
    local rewards = {}
    local hasClaimableReward = false
    local allClaimed = OnlineRewardConfig.GetRewardCount() > 0

    for _, reward in ipairs(OnlineRewardConfig.GetRewards()) do
        local rewardIndex = reward.RewardIndex
        local isClaimed = resolvedSessionState
            and resolvedSessionState.ClaimedRewardIndexes
            and resolvedSessionState.ClaimedRewardIndexes[rewardIndex] == true
            or false
        local isClaimable = not isClaimed and elapsedSeconds >= reward.RequiredSeconds
        if isClaimable then
            hasClaimableReward = true
        end
        if not isClaimed then
            allClaimed = false
        end

        rewards[rewardIndex] = {
            rewardIndex = rewardIndex,
            id = reward.Id,
            rewardType = reward.RewardType,
            potionId = reward.PotionId,
            amount = reward.Amount,
            durationSeconds = reward.DurationSeconds,
            requiredSeconds = reward.RequiredSeconds,
            icon = reward.Icon,
            label = reward.Label,
            isClaimed = isClaimed,
            isClaimable = isClaimable,
        }
    end

    return {
        rewards = rewards,
        elapsedSeconds = elapsedSeconds,
        serverTimestamp = now,
        hasClaimableReward = hasClaimableReward,
        allClaimed = allClaimed,
        productId = getUnlockAllProductId(),
        canUnlockAll = getUnlockAllProductId() > 0 and hasLockedReward(resolvedSessionState, elapsedSeconds),
        claimedRewardCount = countClaimedRewards(resolvedSessionState),
    }
end

function OnlineRewardService:PushState(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._stateSyncEvent) then
        return
    end

    local sessionState = self:_ensureSessionState(player)
    self._stateSyncEvent:FireClient(player, self:_buildStatePayload(player, sessionState, os.time()))
end

function OnlineRewardService:_fireRewardFeedback(player, reward)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent and type(reward) == "table") then
        return
    end

    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardGranted",
        source = "OnlineReward",
        reason = "OnlineRewardClaim",
        rewards = ShopConfig.CopyRewardsForClient({ reward }),
        timestamp = os.clock(),
    })
end

function OnlineRewardService:_canProcessClaimRequest(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    local debounceSeconds = math.max(0.05, tonumber(OnlineRewardConfig.RequestDebounceSeconds) or 0.2)
    local nowClock = os.clock()
    local lastClock = tonumber(self._lastClaimRequestClockByUserId[player.UserId]) or 0
    if nowClock - lastClock < debounceSeconds then
        return false
    end

    self._lastClaimRequestClockByUserId[player.UserId] = nowClock
    return true
end

function OnlineRewardService:_grantReward(player, reward)
    if not (ActorUtils.IsPlayer(player) and player.Parent and type(reward) == "table" and self._playerStateService) then
        return false, "InvalidReward"
    end

    local rewardType = tostring(reward.RewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward.Amount) or 1))
    local context = {
        source = "online_reward",
        productGroup = "OnlineReward",
        itemSku = "OnlineReward_" .. tostring(reward.Id or reward.RewardIndex or rewardType),
    }

    if rewardType == "Experience" then
        self._playerStateService:AddExperienceWithMultiplier(player, amount)
        return true
    elseif rewardType == "Diamonds" then
        self._playerStateService:AddDiamonds(player, amount, context)
        return true
    elseif rewardType == "WheelSpins" then
        self._playerStateService:AddWheelSpins(player, amount, context)
        return true
    elseif rewardType == "Potion" then
        if not (self._potionService and self._potionService.AddPotion) then
            return false, "PotionServiceUnavailable"
        end
        local success, reason = self._potionService:AddPotion(player, reward.PotionId, amount, context)
        return success == true, reason
    elseif rewardType == "Shield" then
        if not (self._healthService and self._healthService.GrantShield) then
            return false, "HealthServiceUnavailable"
        end
        local durationSeconds = math.max(1, math.floor(tonumber(reward.DurationSeconds) or amount))
        local success, reason = self._healthService:GrantShield(player, durationSeconds, "OnlineReward")
        return success == true, reason
    elseif rewardType == "Chest" then
        if not (self._playerStateService and self._playerStateService.AddChest) then
            return false, "ChestServiceUnavailable"
        end
        local success, reason = self._playerStateService:AddChest(player, reward.ChestId, amount, context)
        return success == true, reason
    end

    return false, "UnsupportedRewardType"
end

function OnlineRewardService:_handleRequestClaim(player, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:PushState(player)
        return
    end
    if not self:_canProcessClaimRequest(player) then
        self:PushState(player)
        return
    end

    local rewardIndex = math.max(0, math.floor(tonumber(type(payload) == "table" and (payload.rewardIndex or payload.id) or 0) or 0))
    local reward = OnlineRewardConfig.GetRewards()[rewardIndex]
    local sessionState = self:_ensureSessionState(player)
    if not (reward and sessionState) then
        self:PushState(player)
        return
    end

    local elapsedSeconds = math.max(0, os.time() - math.max(0, math.floor(tonumber(sessionState.StartedAt) or 0)))
    if sessionState.ClaimedRewardIndexes[rewardIndex] == true or elapsedSeconds < reward.RequiredSeconds then
        self:PushState(player)
        return
    end

    local success, reason = self:_grantReward(player, reward)
    if success ~= true then
        warn(string.format(
            "[OnlineRewardService] 在线奖励发放失败 userId=%d rewardIndex=%d reason=%s",
            player.UserId,
            rewardIndex,
            tostring(reason)
        ))
        self:PushState(player)
        return
    end

    sessionState.ClaimedRewardIndexes[rewardIndex] = true
    local didClaimAll = countClaimedRewards(sessionState) >= OnlineRewardConfig.GetRewardCount()
        and OnlineRewardConfig.GetRewardCount() > 0
    if didClaimAll then
        self:_startNewCycle(sessionState, os.time())
    end

    self:_markDirty(player)
    self:_fireRewardFeedback(player, reward)
    self:PushState(player)
end

function OnlineRewardService:ProcessReceipt(receiptInfo)
    local productId = math.max(0, math.floor(tonumber(receiptInfo and receiptInfo.ProductId) or 0))
    if productId ~= getUnlockAllProductId() then
        return false, nil
    end

    local player = Players:GetPlayerByUserId(math.max(0, math.floor(tonumber(receiptInfo and receiptInfo.PlayerId) or 0)))
    if not player then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local sessionState = self:_ensureSessionState(player)
    if not sessionState then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local purchaseId = tostring(receiptInfo and receiptInfo.PurchaseId or "")
    if purchaseId ~= "" and sessionState.ProcessedPurchaseIds[purchaseId] then
        return true, Enum.ProductPurchaseDecision.PurchaseGranted
    end

    if OnlineRewardConfig.GetRewardCount() <= 0 then
        return true, Enum.ProductPurchaseDecision.PurchaseGranted
    end

    sessionState.StartedAt = math.max(0, os.time() - OnlineRewardConfig.GetMaxRequiredSeconds())
    if purchaseId ~= "" then
        sessionState.ProcessedPurchaseIds[purchaseId] = os.time()
    end
    self:PushState(player)
    return true, Enum.ProductPurchaseDecision.PurchaseGranted
end

function OnlineRewardService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._potionService = dependencies and dependencies.PotionService or nil
    self._healthService = dependencies and dependencies.HealthService or nil

    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._stateSyncEvent = remoteEventService and remoteEventService:GetEvent("OnlineRewardStateSync") or nil
    self._requestStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestOnlineRewardStateSync") or nil
    self._requestClaimEvent = remoteEventService and remoteEventService:GetEvent("RequestOnlineRewardClaim") or nil
    self._shopRewardFeedbackEvent = remoteEventService and remoteEventService:GetEvent("ShopRewardFeedback") or nil

    if self._requestStateSyncEvent then
        self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            self:PushState(player)
        end)
    end
    if self._requestClaimEvent then
        self._requestClaimEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestClaim(player, payload)
        end)
    end
end

function OnlineRewardService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
end

function OnlineRewardService:OnPlayerAdded(player)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    self._sessionStateByUserId[player.UserId] = {
        StartedAt = os.time(),
        ClaimedRewardIndexes = {},
        ProcessedPurchaseIds = {},
    }
    self:PushState(player)
end

function OnlineRewardService:OnPlayerRemoving(player)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    self._lastClaimRequestClockByUserId[player.UserId] = nil
    self._sessionStateByUserId[player.UserId] = nil
end

return OnlineRewardService
