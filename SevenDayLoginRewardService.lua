--[[
脚本名字: SevenDayLoginRewardService
脚本文件: SevenDayLoginRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/SevenDayLoginRewardService
说明: V4.4 七日登录奖励持久化、UTC0 解锁、领取和 UnlockAll 商品处理。
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
        "[SevenDayLoginRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local SevenDayLoginRewardConfig = requireSharedModule("SevenDayLoginRewardConfig")
local ShopConfig = requireSharedModule("ShopConfig")

local SevenDayLoginRewardService = {}

SevenDayLoginRewardService._playerStateService = nil
SevenDayLoginRewardService._rebirthService = nil
SevenDayLoginRewardService._potionService = nil
SevenDayLoginRewardService._skinService = nil
SevenDayLoginRewardService._healthService = nil
SevenDayLoginRewardService._stateSyncEvent = nil
SevenDayLoginRewardService._requestStateSyncEvent = nil
SevenDayLoginRewardService._requestClaimEvent = nil
SevenDayLoginRewardService._shopRewardFeedbackEvent = nil
SevenDayLoginRewardService._lastRequestClockByUserId = {}

local function getRewardCount()
    return SevenDayLoginRewardConfig.GetRewardCount()
end

local function getUnlockAllProductId()
    return math.max(0, math.floor(tonumber(SevenDayLoginRewardConfig.DeveloperProductId) or 0))
end

local function getUtcDayKey(timestamp)
    return math.floor(math.max(0, math.floor(tonumber(timestamp) or 0)) / 86400)
end

local function getNextUtcTimestamp(timestamp)
    return (getUtcDayKey(timestamp) + 1) * 86400
end

local function normalizeDayFlagMap(source)
    local normalized = {}
    if type(source) ~= "table" then
        return normalized
    end

    for key, value in pairs(source) do
        local dayIndex = math.max(0, math.floor(tonumber(key) or tonumber(value) or 0))
        if dayIndex >= 1 and dayIndex <= getRewardCount() and value == true then
            normalized[dayIndex] = true
        end
    end
    return normalized
end

local function normalizeProcessedPurchaseMap(source)
    local normalized = {}
    if type(source) ~= "table" then
        return normalized
    end

    for key, value in pairs(source) do
        local purchaseId = tostring(key or "")
        if purchaseId ~= "" then
            normalized[purchaseId] = math.max(0, math.floor(tonumber(value) or os.time()))
        end
    end
    return normalized
end

local function countDayFlags(dayFlags)
    local count = 0
    if type(dayFlags) ~= "table" then
        return count
    end
    for _, isEnabled in pairs(dayFlags) do
        if isEnabled == true then
            count += 1
        end
    end
    return count
end

local function isAllClaimed(rewardState)
    return countDayFlags(rewardState and rewardState.ClaimedDays) >= getRewardCount()
end

local function hasAnyClaimableDay(rewardState)
    if type(rewardState) ~= "table" then
        return false
    end
    for dayIndex = 1, getRewardCount() do
        if rewardState.UnlockedDays[dayIndex] == true and rewardState.ClaimedDays[dayIndex] ~= true then
            return true
        end
    end
    return false
end

local function getFirstClaimableDayIndex(rewardState)
    if type(rewardState) ~= "table" then
        return 0
    end
    for dayIndex = 1, getRewardCount() do
        if rewardState.UnlockedDays[dayIndex] == true and rewardState.ClaimedDays[dayIndex] ~= true then
            return dayIndex
        end
    end
    return 0
end

local function getNextLockedDayIndex(rewardState)
    if type(rewardState) ~= "table" then
        return 0
    end
    for dayIndex = 1, getRewardCount() do
        if rewardState.UnlockedDays[dayIndex] ~= true and rewardState.ClaimedDays[dayIndex] ~= true then
            return dayIndex
        end
    end
    return 0
end

local function startNewCycle(rewardState, nowTimestamp, unlockImmediately)
    rewardState.CycleId = math.max(0, math.floor(tonumber(rewardState.CycleId) or 0)) + 1
    if rewardState.CycleId <= 0 then
        rewardState.CycleId = 1
    end
    rewardState.UnlockedDays = {}
    rewardState.ClaimedDays = {}
    rewardState.LastClaimAt = 0
    rewardState.LastSequentialUnlockDay = 0
    rewardState.CycleStartUtcDay = getUtcDayKey(nowTimestamp)
    rewardState.CycleStartsLockedUntilNextUtc = unlockImmediately ~= true
    rewardState.PendingCycleReset = false

    if unlockImmediately == true then
        rewardState.UnlockedDays[1] = true
        rewardState.LastSequentialUnlockDay = 1
    end
end

local function unlockAllRemainingDays(rewardState)
    local didChange = false
    if type(rewardState) ~= "table" then
        return false
    end
    for dayIndex = 1, getRewardCount() do
        if rewardState.ClaimedDays[dayIndex] ~= true and rewardState.UnlockedDays[dayIndex] ~= true then
            rewardState.UnlockedDays[dayIndex] = true
            didChange = true
        end
    end
    if didChange then
        rewardState.LastSequentialUnlockDay = getRewardCount()
    end
    return didChange
end

local function ensureRewardState(state, nowTimestamp)
    if type(state) ~= "table" then
        return nil, false
    end

    local didChange = false
    local rewardState = state.SevenDayLoginRewardState
    if type(rewardState) ~= "table" then
        rewardState = {}
        state.SevenDayLoginRewardState = rewardState
        didChange = true
    end

    rewardState.CycleId = math.max(0, math.floor(tonumber(rewardState.CycleId) or 0))
    rewardState.UnlockedDays = normalizeDayFlagMap(rewardState.UnlockedDays)
    rewardState.ClaimedDays = normalizeDayFlagMap(rewardState.ClaimedDays)
    rewardState.LastClaimAt = math.max(0, math.floor(tonumber(rewardState.LastClaimAt) or 0))
    rewardState.LastSequentialUnlockDay = math.clamp(math.floor(tonumber(rewardState.LastSequentialUnlockDay) or 0), 0, getRewardCount())
    rewardState.CycleStartUtcDay = math.max(0, math.floor(tonumber(rewardState.CycleStartUtcDay) or 0))
    rewardState.CycleStartsLockedUntilNextUtc = rewardState.CycleStartsLockedUntilNextUtc == true
    rewardState.PendingCycleReset = rewardState.PendingCycleReset == true
    rewardState.ProcessedPurchaseIds = normalizeProcessedPurchaseMap(rewardState.ProcessedPurchaseIds)

    if rewardState.CycleId <= 0 then
        startNewCycle(rewardState, nowTimestamp, true)
        didChange = true
    end

    if isAllClaimed(rewardState) and rewardState.PendingCycleReset ~= true then
        rewardState.PendingCycleReset = true
        didChange = true
    end

    return rewardState, didChange
end

local function refreshRewardStateForTime(rewardState, nowTimestamp, options)
    if type(rewardState) ~= "table" then
        return false
    end

    local didChange = false
    local allowCycleReset = type(options) == "table" and options.AllowCycleReset == true
    local currentUtcDay = getUtcDayKey(nowTimestamp)

    if isAllClaimed(rewardState) and rewardState.PendingCycleReset ~= true then
        rewardState.PendingCycleReset = true
        didChange = true
    end

    if rewardState.PendingCycleReset == true then
        local cycleStartTimestamp = rewardState.LastClaimAt > 0 and rewardState.LastClaimAt or nowTimestamp
        if allowCycleReset == true or currentUtcDay > getUtcDayKey(cycleStartTimestamp) then
            startNewCycle(rewardState, cycleStartTimestamp, false)
            didChange = true
        else
            return didChange
        end
    end

    if rewardState.CycleStartsLockedUntilNextUtc == true then
        if currentUtcDay > rewardState.CycleStartUtcDay then
            rewardState.CycleStartsLockedUntilNextUtc = false
            rewardState.UnlockedDays[1] = true
            rewardState.LastSequentialUnlockDay = math.max(1, rewardState.LastSequentialUnlockDay)
            didChange = true
        else
            return didChange
        end
    end

    if hasAnyClaimableDay(rewardState) then
        return didChange
    end

    local nextDayIndex = getNextLockedDayIndex(rewardState)
    if nextDayIndex <= 0 then
        return didChange
    end

    if nextDayIndex == 1 then
        rewardState.UnlockedDays[1] = true
        rewardState.LastSequentialUnlockDay = math.max(1, rewardState.LastSequentialUnlockDay)
        return true
    end

    if rewardState.LastClaimAt > 0 and currentUtcDay > getUtcDayKey(rewardState.LastClaimAt) then
        rewardState.UnlockedDays[nextDayIndex] = true
        rewardState.LastSequentialUnlockDay = math.max(nextDayIndex, rewardState.LastSequentialUnlockDay)
        didChange = true
    end

    return didChange
end

function SevenDayLoginRewardService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function SevenDayLoginRewardService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function SevenDayLoginRewardService:_getState(player, options)
    if not (ActorUtils.IsPlayer(player) and self._playerStateService) then
        return nil, nil, false, 0
    end

    local playerState = self._playerStateService:GetState(player)
    local nowTimestamp = math.max(0, math.floor(tonumber(type(options) == "table" and options.NowTimestamp) or os.time()))
    local rewardState, didChange = ensureRewardState(playerState, nowTimestamp)
    if rewardState then
        didChange = refreshRewardStateForTime(rewardState, nowTimestamp, options) or didChange
    end
    return playerState, rewardState, didChange, nowTimestamp
end

function SevenDayLoginRewardService:_buildStatePayload(player, rewardState, nowTimestamp, options)
    local rewards = {}
    local cycleId = math.max(1, math.floor(tonumber(rewardState.CycleId) or 1))
    local cycleRewards = SevenDayLoginRewardConfig.GetRewardsForCycle(cycleId)
    for dayIndex = 1, getRewardCount() do
        local reward = cycleRewards[dayIndex] or {}
        local isClaimed = rewardState.ClaimedDays[dayIndex] == true
        local isUnlocked = rewardState.UnlockedDays[dayIndex] == true
        rewards[dayIndex] = {
            dayIndex = dayIndex,
            rewardType = reward.RewardType,
            potionId = reward.PotionId,
            skinId = reward.SkinId,
            amount = reward.Amount,
            durationSeconds = reward.DurationSeconds,
            icon = reward.Icon,
            label = reward.Label,
            isUnlocked = isUnlocked,
            isClaimed = isClaimed,
            isClaimable = isUnlocked and not isClaimed,
        }
    end

    local hasClaimableReward = hasAnyClaimableDay(rewardState)

    local claimedCount = countDayFlags(rewardState.ClaimedDays)
    local remainingRewardCount = math.max(0, getRewardCount() - claimedCount)
    return {
        cycleId = cycleId,
        rewards = rewards,
        hasClaimableReward = hasClaimableReward,
        remainingRewardCount = remainingRewardCount,
        pendingCycleReset = rewardState.PendingCycleReset == true,
        isWaitingForNextCycleDay1 = rewardState.CycleStartsLockedUntilNextUtc == true,
        productId = getUnlockAllProductId(),
        canUnlockAll = getUnlockAllProductId() > 0 and remainingRewardCount > 0,
        nextRefreshAt = getNextUtcTimestamp(nowTimestamp),
        serverTimestamp = nowTimestamp,
        timestamp = os.clock(),
    }
end

function SevenDayLoginRewardService:PushState(player, options)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._stateSyncEvent) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        return
    end

    local _playerState, rewardState, didChange, nowTimestamp = self:_getState(player, options)
    if not rewardState then
        return
    end
    if didChange and not (type(options) == "table" and options.SkipSave == true) then
        self:_markDirty(player)
    end
    self._stateSyncEvent:FireClient(player, self:_buildStatePayload(player, rewardState, nowTimestamp, options))
end

function SevenDayLoginRewardService:_canProcessRequest(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end
    local debounceSeconds = math.max(0.05, tonumber(SevenDayLoginRewardConfig.RequestDebounceSeconds) or 0.2)
    local nowClock = os.clock()
    local lastClock = tonumber(self._lastRequestClockByUserId[player.UserId]) or 0
    if nowClock - lastClock < debounceSeconds then
        return false
    end
    self._lastRequestClockByUserId[player.UserId] = nowClock
    return true
end

function SevenDayLoginRewardService:_grantReward(player, reward)
    if not (ActorUtils.IsPlayer(player) and player.Parent and type(reward) == "table" and self._playerStateService) then
        return false, "InvalidReward"
    end

    local rewardType = tostring(reward.RewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward.Amount) or 1))
    local context = {
        source = "seven_day_login_reward",
        productGroup = "SevenDayLoginReward",
        itemSku = "SevenDayLoginReward_" .. tostring(reward.DayIndex or rewardType),
    }

    if rewardType == "WheelSpins" then
        self._playerStateService:AddWheelSpins(player, amount, context)
        return true
    elseif rewardType == "Potion" then
        if not (self._potionService and self._potionService.AddPotion) then
            return false, "PotionServiceUnavailable"
        end
        local success, reason = self._potionService:AddPotion(player, reward.PotionId, amount, context)
        return success == true, reason
    elseif rewardType == "Skin" then
        if not (self._skinService and self._skinService.GrantSkin) then
            return false, "SkinServiceUnavailable"
        end
        local success, reason = self._skinService:GrantSkin(player, reward.SkinId, "SevenDayLoginReward")
        if success == true or reason == "AlreadyOwned" then
            return true, reason
        end
        return false, reason
    elseif rewardType == "Diamonds" then
        self._playerStateService:AddDiamonds(player, amount, context)
        return true
    elseif rewardType == "Experience" then
        self._playerStateService:AddExperienceWithMultiplier(player, amount)
        return true
    elseif rewardType == "Shield" then
        if not (self._healthService and self._healthService.GrantShield) then
            return false, "HealthServiceUnavailable"
        end
        local durationSeconds = math.max(1, math.floor(tonumber(reward.DurationSeconds) or amount))
        local success, reason = self._healthService:GrantShield(player, durationSeconds, "SevenDayLoginReward")
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

function SevenDayLoginRewardService:_fireRewardFeedback(player, reward)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent and type(reward) == "table") then
        return
    end
    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardGranted",
        source = "SevenDayLoginReward",
        reason = "SevenDayLoginRewardClaim",
        rewards = ShopConfig.CopyRewardsForClient({ reward }),
        timestamp = os.clock(),
    })
end

function SevenDayLoginRewardService:_handleRequestStateSync(player, payload)
    local reason = type(payload) == "table" and tostring(payload.reason or "") or ""
    self:PushState(player, {
        AllowCycleReset = type(payload) == "table" and (payload.allowCycleReset == true or reason == "Open"),
    })
end

function SevenDayLoginRewardService:_handleRequestClaim(player, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:PushState(player)
        return
    end
    if not self:_canProcessRequest(player) then
        self:PushState(player)
        return
    end

    local _playerState, rewardState = self:_getState(player)
    if not rewardState then
        self:PushState(player)
        return
    end

    local dayIndex = math.max(0, math.floor(tonumber(type(payload) == "table" and payload.dayIndex or 0) or 0))
    if dayIndex <= 0 then
        dayIndex = getFirstClaimableDayIndex(rewardState)
    end
    if dayIndex <= 0 or dayIndex > getRewardCount() then
        self:PushState(player)
        return
    end
    if rewardState.UnlockedDays[dayIndex] ~= true or rewardState.ClaimedDays[dayIndex] == true then
        self:PushState(player)
        return
    end

    local reward = SevenDayLoginRewardConfig.GetReward(rewardState.CycleId, dayIndex)
    if not reward then
        self:PushState(player)
        return
    end

    local success, reason = self:_grantReward(player, reward)
    if success ~= true then
        warn(string.format(
            "[SevenDayLoginRewardService] 七日登录奖励发放失败 userId=%d day=%d reason=%s",
            player.UserId,
            dayIndex,
            tostring(reason)
        ))
        self:PushState(player)
        return
    end

    rewardState.ClaimedDays[dayIndex] = true
    rewardState.LastClaimAt = os.time()
    if isAllClaimed(rewardState) then
        rewardState.PendingCycleReset = true
    end

    self:_markDirty(player)
    self:_fireRewardFeedback(player, reward)
    self:PushState(player)
end

function SevenDayLoginRewardService:ProcessReceipt(receiptInfo)
    local productId = math.max(0, math.floor(tonumber(receiptInfo and receiptInfo.ProductId) or 0))
    if productId ~= getUnlockAllProductId() then
        return false, nil
    end

    local player = Players:GetPlayerByUserId(math.max(0, math.floor(tonumber(receiptInfo and receiptInfo.PlayerId) or 0)))
    if not player then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local _playerState, rewardState, didChange, nowTimestamp = self:_getState(player, {
        AllowCycleReset = true,
    })
    if not rewardState then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local purchaseId = tostring(receiptInfo and receiptInfo.PurchaseId or "")
    if purchaseId ~= "" and rewardState.ProcessedPurchaseIds[purchaseId] then
        return true, Enum.ProductPurchaseDecision.PurchaseGranted
    end

    if unlockAllRemainingDays(rewardState) then
        didChange = true
    end
    if purchaseId ~= "" then
        rewardState.ProcessedPurchaseIds[purchaseId] = os.time()
        didChange = true
    end

    if didChange then
        self:_markDirty(player)
        if self._stateSyncEvent then
            self._stateSyncEvent:FireClient(player, self:_buildStatePayload(player, rewardState, nowTimestamp))
        end
    end
    return true, Enum.ProductPurchaseDecision.PurchaseGranted
end

function SevenDayLoginRewardService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._skinService = dependencies and dependencies.SkinService or self._skinService
    self._healthService = dependencies and dependencies.HealthService or self._healthService

    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._stateSyncEvent = remoteEventService and remoteEventService:GetEvent("SevenDayLoginRewardStateSync") or nil
    self._requestStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestSevenDayLoginRewardStateSync") or nil
    self._requestClaimEvent = remoteEventService and remoteEventService:GetEvent("RequestSevenDayLoginRewardClaim") or nil
    self._shopRewardFeedbackEvent = remoteEventService and remoteEventService:GetEvent("ShopRewardFeedback") or nil

    if self._requestStateSyncEvent then
        self._requestStateSyncEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestStateSync(player, payload)
        end)
    end
    if self._requestClaimEvent then
        self._requestClaimEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRequestClaim(player, payload)
        end)
    end
end

function SevenDayLoginRewardService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._skinService = dependencies and dependencies.SkinService or self._skinService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
end

function SevenDayLoginRewardService:OnPlayerAdded(player)
    if not ActorUtils.IsPlayer(player) then
        return
    end
    task.spawn(function()
        local deadline = os.clock() + 12
        while player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
            task.wait(0.25)
        end
        self:PushState(player)
    end)
end

function SevenDayLoginRewardService:OnPlayerRemoving(player)
    if not ActorUtils.IsPlayer(player) then
        return
    end
    self._lastRequestClockByUserId[player.UserId] = nil
end

return SevenDayLoginRewardService
