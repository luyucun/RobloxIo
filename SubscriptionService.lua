--[[
Script: SubscriptionService
Type: ModuleScript
Studio path: ServerScriptService/Services/SubscriptionService
Purpose: V3.3 official Roblox subscription status, daily claims, and reward authority.
]]

local MarketplaceService = game:GetService("MarketplaceService")
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
        "[SubscriptionService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local SubscriptionConfig = requireSharedModule("SubscriptionConfig")

local SubscriptionService = {}

SubscriptionService._playerStateService = nil
SubscriptionService._rebirthService = nil
SubscriptionService._badgeAwardService = nil
SubscriptionService._subscriptionStateSyncEvent = nil
SubscriptionService._requestSubscriptionStateSyncEvent = nil
SubscriptionService._requestSubscriptionClaimEvent = nil
SubscriptionService._subscriptionFeedbackEvent = nil
SubscriptionService._connections = {}
SubscriptionService._statusByUserId = {}
SubscriptionService._lastRefreshClockByUserId = {}
SubscriptionService._paymentStateByUserId = {}
SubscriptionService._lastPaymentRefreshClockByUserId = {}
SubscriptionService._refreshInProgressByUserId = {}
SubscriptionService._claimInProgressByUserId = {}

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

local function getSubscriptionId()
    return tostring(SubscriptionConfig.SubscriptionId or "")
end

local function normalizeStatusPayload(status)
    if type(status) ~= "table" then
        return false
    end

    if status.IsSubscribed == true or status.isSubscribed == true then
        return true
    end

    local statusValue = status.SubscriptionStatus or status.subscriptionStatus or status.Status or status.status
    if typeof(statusValue) == "EnumItem" then
        local name = tostring(statusValue.Name or "")
        return name == "Subscribed" or name == "Active"
    end

    local statusText = string.lower(tostring(statusValue or ""))
    return statusText == "subscribed" or statusText == "active"
end

local function readPaymentStatus(payment)
    if type(payment) ~= "table" then
        return ""
    end

    local status = payment.Status or payment.status or payment.PaymentStatus or payment.paymentStatus or payment.SubscriptionPaymentStatus or payment.subscriptionPaymentStatus
    if typeof(status) == "EnumItem" then
        return tostring(status.Name or "")
    end
    return tostring(status or "")
end

local function isPaidPaymentStatus(status)
    local normalized = string.lower(tostring(status or ""))
    return normalized == "paid"
        or normalized == "completed"
        or normalized == "success"
        or normalized == "succeeded"
        or string.find(normalized, "paid", 1, true) ~= nil
end

local function getDateTimeUnixTimestamp(value)
    if typeof(value) ~= "DateTime" then
        return nil
    end

    local ok, timestamp = pcall(function()
        return value.UnixTimestamp
    end)
    if ok then
        return tonumber(timestamp)
    end
    return nil
end

function SubscriptionService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function SubscriptionService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function SubscriptionService:_querySubscriptionStatus(player)
    local subscriptionId = getSubscriptionId()
    if subscriptionId == "" then
        return false, "InvalidSubscriptionId"
    end

    local ok, status = pcall(function()
        return MarketplaceService:GetUserSubscriptionStatusAsync(player, subscriptionId)
    end)
    if not ok then
        warn("[SubscriptionService] GetUserSubscriptionStatusAsync failed: " .. tostring(status))
        return false, "StatusCheckFailed"
    end

    return normalizeStatusPayload(status), nil
end

function SubscriptionService:_refreshPaymentState(player, force)
    local subscriptionId = getSubscriptionId()
    if subscriptionId == "" then
        return false, "InvalidSubscriptionId"
    end
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "InvalidPlayer"
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return false, "InvalidPlayer"
    end

    local nowClock = os.clock()
    local cached = self._paymentStateByUserId[userId]
    local cooldown = math.max(1, tonumber(SubscriptionConfig.PaymentRefreshCooldownSeconds) or 60)
    if force ~= true and cached and nowClock - (self._lastPaymentRefreshClockByUserId[userId] or 0) < cooldown then
        return cached.paid == true, cached.reason
    end

    local ok, history = pcall(function()
        return MarketplaceService:GetUserSubscriptionPaymentHistoryAsync(player, subscriptionId)
    end)
    if not ok then
        warn("[SubscriptionService] GetUserSubscriptionPaymentHistoryAsync failed: " .. tostring(history))
        self._paymentStateByUserId[userId] = {
            paid = false,
            reason = "PaymentHistoryCheckFailed",
            checkedAt = os.time(),
        }
        self._lastPaymentRefreshClockByUserId[userId] = nowClock
        return false, "PaymentHistoryCheckFailed"
    end

    if type(history) ~= "table" then
        self._paymentStateByUserId[userId] = {
            paid = false,
            reason = "PaymentPending",
            checkedAt = os.time(),
        }
        self._lastPaymentRefreshClockByUserId[userId] = nowClock
        return false, "PaymentPending"
    end

    local now = os.time()
    for _, payment in ipairs(history) do
        if isPaidPaymentStatus(readPaymentStatus(payment)) then
            local cycleStart = getDateTimeUnixTimestamp(payment.CycleStartTime or payment.cycleStartTime)
            local cycleEnd = getDateTimeUnixTimestamp(payment.CycleEndTime or payment.cycleEndTime)
            if cycleStart and cycleEnd and cycleStart <= now and now < cycleEnd then
                self._paymentStateByUserId[userId] = {
                    paid = true,
                    reason = "Paid",
                    checkedAt = os.time(),
                }
                self._lastPaymentRefreshClockByUserId[userId] = nowClock
                if self._badgeAwardService and self._badgeAwardService.AwardBadgeAsync then
                    self._badgeAwardService:AwardBadgeAsync(player, "FirstSubscription", "SubscriptionPaid")
                end
                return true, "Paid"
            end
        end
    end

    self._paymentStateByUserId[userId] = {
        paid = false,
        reason = "PaymentPending",
        checkedAt = os.time(),
    }
    self._lastPaymentRefreshClockByUserId[userId] = nowClock
    return false, "PaymentPending"
end

function SubscriptionService:_hasPaidCurrentPeriod(player)
    return self:_refreshPaymentState(player, true)
end

function SubscriptionService:_refreshStatus(player, force)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "InvalidPlayer"
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return false, "InvalidPlayer"
    end

    local now = os.clock()
    local cached = self._statusByUserId[userId]
    local cooldown = math.max(1, tonumber(SubscriptionConfig.StateRefreshCooldownSeconds) or 10)
    if force ~= true and cached and now - (self._lastRefreshClockByUserId[userId] or 0) < cooldown then
        return cached.isSubscribed == true, cached.reason
    end
    if self._refreshInProgressByUserId[userId] then
        return cached and cached.isSubscribed == true or false, cached and cached.reason or "StatusChecking"
    end

    self._refreshInProgressByUserId[userId] = true
    local isSubscribed, reason = self:_querySubscriptionStatus(player)
    self._refreshInProgressByUserId[userId] = nil
    self._lastRefreshClockByUserId[userId] = now
    self._statusByUserId[userId] = {
        isSubscribed = isSubscribed == true,
        reason = reason,
        checkedAt = os.time(),
    }
    return isSubscribed == true, reason
end

function SubscriptionService:IsSubscribed(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    local userId = getUserId(player)
    local cached = userId > 0 and self._statusByUserId[userId] or nil
    if cached then
        return cached.isSubscribed == true
    end

    if userId > 0 and not self._refreshInProgressByUserId[userId] then
        task.spawn(function()
            if player and player.Parent then
                self:SyncState(player, true)
            end
        end)
    end
    return false
end

function SubscriptionService:IsSubscribedCached(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    local userId = getUserId(player)
    local cached = userId > 0 and self._statusByUserId[userId] or nil
    return cached and cached.isSubscribed == true or false
end

function SubscriptionService:GetExperienceBonus(player)
    return self:IsSubscribedCached(player) and math.max(0, tonumber(SubscriptionConfig.ExperienceBonus) or 0) or 0
end

function SubscriptionService:IsDailyClaimAvailable(player)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    local userId = getUserId(player)
    local paymentState = userId > 0 and self._paymentStateByUserId[userId] or nil
    if not (self:IsSubscribedCached(player) and paymentState and paymentState.paid == true) then
        return false
    end

    local today = SubscriptionConfig.GetCurrentUtcDay()
    return not (
        self._playerStateService
        and self._playerStateService.HasSubscriptionClaim
        and self._playerStateService:HasSubscriptionClaim(player, getSubscriptionId(), today) == true
    )
end

function SubscriptionService:BuildStatePayload(player)
    local isSubscribed, statusReason = self:_refreshStatus(player, false)
    local paid, paymentReason = false, nil
    if isSubscribed then
        paid, paymentReason = self:_refreshPaymentState(player, false)
    end
    local today = SubscriptionConfig.GetCurrentUtcDay()
    local claimed = self._playerStateService
        and self._playerStateService.HasSubscriptionClaim
        and self._playerStateService:HasSubscriptionClaim(player, getSubscriptionId(), today) == true
        or false
    local dailyClaimAvailable = isSubscribed == true and paid == true and claimed ~= true

    return {
        config = SubscriptionConfig.CopyForClient(),
        subscriptionId = getSubscriptionId(),
        isSubscribed = isSubscribed == true,
        statusReason = statusReason,
        currentPeriodPaid = paid == true,
        paymentReason = paymentReason,
        dailyClaimed = claimed == true,
        dailyClaimAvailable = dailyClaimAvailable,
        currentUtcDay = today,
        dailyDiamonds = SubscriptionConfig.DailyDiamondReward,
        dailyWheelSpins = SubscriptionConfig.DailyWheelSpinReward,
        experienceBonus = isSubscribed and SubscriptionConfig.ExperienceBonus or 0,
        timestamp = os.clock(),
    }
end

function SubscriptionService:SyncState(player, forceRefresh)
    if not (self._subscriptionStateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    if forceRefresh == true then
        local isSubscribed = self:_refreshStatus(player, true)
        if isSubscribed then
            self:_refreshPaymentState(player, true)
        end
    end
    self._subscriptionStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
    if self._playerStateService and self._playerStateService.PushState then
        self._playerStateService:PushState(player)
    end
end

function SubscriptionService:_fireFeedback(player, eventType, reason)
    if not (self._subscriptionFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._subscriptionFeedbackEvent:FireClient(player, {
        eventType = tostring(eventType or ""),
        reason = tostring(reason or ""),
        message = SubscriptionConfig.Messages[tostring(reason or "")] or tostring(reason or ""),
        state = self:BuildStatePayload(player),
        timestamp = os.clock(),
    })
end

function SubscriptionService:_handleClaimRequest(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return
    end

    local userId = getUserId(player)
    if self._claimInProgressByUserId[userId] then
        self:_fireFeedback(player, "Failed", "Busy")
        return
    end
    self._claimInProgressByUserId[userId] = true

    local isSubscribed, statusReason = self:_refreshStatus(player, true)
    if isSubscribed ~= true then
        self._claimInProgressByUserId[userId] = nil
        self:_fireFeedback(player, "Failed", statusReason or "NotSubscribed")
        return
    end

    local paid, paymentReason = self:_hasPaidCurrentPeriod(player)
    if paid ~= true then
        self._claimInProgressByUserId[userId] = nil
        self:_fireFeedback(player, "Failed", paymentReason or "PaymentPending")
        return
    end

    local subscriptionId = getSubscriptionId()
    local today = SubscriptionConfig.GetCurrentUtcDay()
    if self._playerStateService:HasSubscriptionClaim(player, subscriptionId, today) then
        self._claimInProgressByUserId[userId] = nil
        self:_fireFeedback(player, "AlreadyClaimed", "AlreadyClaimed")
        return
    end

    self._playerStateService:AddDiamonds(player, SubscriptionConfig.DailyDiamondReward, {
        source = "subscription",
        productGroup = "Subscription",
        itemSku = "SubscriptionDailyClaimDiamonds",
    })
    self._playerStateService:AddWheelSpins(player, SubscriptionConfig.DailyWheelSpinReward, {
        source = "subscription",
        productGroup = "Subscription",
        itemSku = "SubscriptionDailyClaimWheelSpins",
    })
    self._playerStateService:MarkSubscriptionClaim(player, subscriptionId, today)
    self:_markDirty(player)
    self._claimInProgressByUserId[userId] = nil
    self:SyncState(player)
    self:_fireFeedback(player, "Success", "ClaimSuccess")
end

function SubscriptionService:_queueDelayedRefresh(player)
    local delaySeconds = math.max(1, tonumber(SubscriptionConfig.PurchaseRefreshDelaySeconds) or 10)
    task.delay(delaySeconds, function()
        if player and player.Parent then
            self:SyncState(player, true)
        end
    end)
end

function SubscriptionService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._badgeAwardService = dependencies and dependencies.BadgeAwardService or self._badgeAwardService
end

function SubscriptionService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._badgeAwardService = dependencies and dependencies.BadgeAwardService or nil
    self._statusByUserId = {}
    self._lastRefreshClockByUserId = {}
    self._paymentStateByUserId = {}
    self._lastPaymentRefreshClockByUserId = {}
    self._refreshInProgressByUserId = {}
    self._claimInProgressByUserId = {}

    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._subscriptionStateSyncEvent = remoteEventService and remoteEventService:GetEvent("SubscriptionStateSync") or nil
    self._requestSubscriptionStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestSubscriptionStateSync") or nil
    self._requestSubscriptionClaimEvent = remoteEventService and remoteEventService:GetEvent("RequestSubscriptionClaim") or nil
    self._subscriptionFeedbackEvent = remoteEventService and remoteEventService:GetEvent("SubscriptionFeedback") or nil

    disconnectAll(self._connections)
    if self._requestSubscriptionStateSyncEvent then
        table.insert(self._connections, self._requestSubscriptionStateSyncEvent.OnServerEvent:Connect(function(player)
            self:SyncState(player)
        end))
    end
    if self._requestSubscriptionClaimEvent then
        table.insert(self._connections, self._requestSubscriptionClaimEvent.OnServerEvent:Connect(function(player)
            self:_handleClaimRequest(player)
        end))
    end
    if Players.UserSubscriptionStatusChanged then
        table.insert(self._connections, Players.UserSubscriptionStatusChanged:Connect(function(player, subscriptionId)
            if tostring(subscriptionId or "") == getSubscriptionId() then
                self:SyncState(player, true)
            end
        end))
    end
    if MarketplaceService.PromptSubscriptionPurchaseFinished then
        table.insert(self._connections, MarketplaceService.PromptSubscriptionPurchaseFinished:Connect(function(player, subscriptionId, wasPurchased)
            if wasPurchased == true and tostring(subscriptionId or "") == getSubscriptionId() then
                self:_queueDelayedRefresh(player)
            end
        end))
    end
end

function SubscriptionService:OnPlayerAdded(player)
    task.defer(function()
        if player and player.Parent then
            self:SyncState(player, true)
        end
    end)
end

function SubscriptionService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    self._statusByUserId[userId] = nil
    self._lastRefreshClockByUserId[userId] = nil
    self._paymentStateByUserId[userId] = nil
    self._lastPaymentRefreshClockByUserId[userId] = nil
    self._refreshInProgressByUserId[userId] = nil
    self._claimInProgressByUserId[userId] = nil
end

return SubscriptionService
