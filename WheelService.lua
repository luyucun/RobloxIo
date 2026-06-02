--[[
Script: WheelService
Type: ModuleScript
Studio path: ServerScriptService/Services/WheelService
Purpose: Server-authoritative V3.0 wheel state, free-spin timer, rewards, and purchases.
]]

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
        "[WheelService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local WheelConfig = requireSharedModule("WheelConfig")

local WheelService = {}

WheelService._playerStateService = nil
WheelService._potionService = nil
WheelService._rebirthService = nil
WheelService._skinService = nil
WheelService._healthService = nil
WheelService._shopService = nil
WheelService._wheelStateSyncEvent = nil
WheelService._requestWheelStateSyncEvent = nil
WheelService._requestWheelSpinEvent = nil
WheelService._wheelSpinResultEvent = nil
WheelService._requestStateConnection = nil
WheelService._requestSpinConnection = nil
WheelService._heartbeatConnection = nil
WheelService._nextFreeAtByUserId = {}
WheelService._spinInProgressByUserId = {}
WheelService._lastSyncClockByUserId = {}
WheelService._random = Random.new()
WheelService._gameAnalyticsService = nil

local function getUserId(player)
    return player and player.UserId or 0
end

local function getFreeSpinInterval()
    return math.max(1, tonumber(WheelConfig.FreeSpinIntervalSeconds) or 300)
end

local function getSyncInterval()
    return math.max(0.25, tonumber(WheelConfig.StateSyncIntervalSeconds) or 1)
end

local function copyRewardForClient(reward)
    if type(reward) ~= "table" then
        return nil
    end

    return {
        slot = reward.Slot,
        id = reward.Id,
        rewardType = reward.RewardType,
        label = reward.Label,
        giftName = reward.GiftName,
        targetRotation = reward.TargetRotation,
        amount = reward.Amount,
        durationSeconds = reward.DurationSeconds,
        potionId = reward.PotionId,
        skinId = reward.SkinId,
        pending = reward.Pending == true,
    }
end

function WheelService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function WheelService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function WheelService:_trackWheelFunnel(player, stepNumber, stepName, fields, onceKey)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackFunnel) then
        return
    end
    if onceKey and self._gameAnalyticsService.MarkOnce and not self._gameAnalyticsService:MarkOnce(player, onceKey) then
        return
    end

    self._gameAnalyticsService:TrackFunnel(player, "WheelFlow", stepNumber, stepName, fields)
end

function WheelService:_getWheelSpins(player)
    if not (player and self._playerStateService) then
        return 0
    end

    local state = self._playerStateService:GetState(player)
    state.WheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0))
    return state.WheelSpins
end

function WheelService:_getNextFreeAt(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return os.clock() + getFreeSpinInterval()
    end

    local nextFreeAt = tonumber(self._nextFreeAtByUserId[userId])
    if not nextFreeAt then
        nextFreeAt = os.clock() + getFreeSpinInterval()
        self._nextFreeAtByUserId[userId] = nextFreeAt
    end
    return nextFreeAt
end

function WheelService:BuildStatePayload(player)
    local now = os.clock()
    local nextFreeAt = self:_getNextFreeAt(player)
    return {
        wheelSpins = self:_getWheelSpins(player),
        nextFreeSpinInSeconds = math.max(0, math.ceil(nextFreeAt - now)),
        freeSpinIntervalSeconds = getFreeSpinInterval(),
        serverClock = now,
        timestamp = now,
    }
end

function WheelService:SyncState(player)
    if not (self._wheelStateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._wheelStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
end

function WheelService:_handleStateRequest(player, payload)
    if type(payload) == "table" and tostring(payload.intent or "") == "WheelOpened" then
        self:_trackWheelFunnel(player, 1, "WheelOpened", {
            source = tostring(payload.source or "wheel"),
        }, "WheelFlow.WheelOpened")
    end

    self:SyncState(player)
end

function WheelService:_fireSpinResult(player, payload)
    if not (self._wheelSpinResultEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._wheelSpinResultEvent:FireClient(player, payload)
end

function WheelService:_grantReward(player, reward)
    if not (player and reward and self._playerStateService) then
        return false, "InvalidReward"
    end

    local rewardType = tostring(reward.RewardType or "")
    if rewardType == "Potion" then
        if not (self._potionService and self._potionService.AddPotion) then
            return false, "PotionServiceUnavailable"
        end
        local success, reason = self._potionService:AddPotion(player, reward.PotionId, reward.Amount or 1, "Wheel")
        return success == true, reason
    elseif rewardType == "Diamonds" then
        self._playerStateService:AddDiamonds(player, reward.Amount or 0, {
            source = "wheel",
            productGroup = "wheel",
            itemSku = tostring(reward.Id or reward.Label or "WheelReward"),
        })
        return true
    elseif rewardType == "WheelSpins" then
        self._playerStateService:AddWheelSpins(player, reward.Amount or 0, {
            source = "wheel",
            productGroup = "wheel",
            itemSku = tostring(reward.Id or reward.Label or "WheelReward"),
        })
        return true
    elseif rewardType == "Shield" then
        if not (self._healthService and self._healthService.GrantShield) then
            return false, "HealthServiceUnavailable"
        end
        local success, reason = self._healthService:GrantShield(player, reward.DurationSeconds, "Wheel")
        return success == true, reason
    elseif rewardType == "PendingWeaponSkin" then
        if not (self._skinService and self._skinService.GrantSkin) then
            return false, "SkinServiceUnavailable"
        end
        local success, reason = self._skinService:GrantSkin(player, reward.SkinId, "Wheel")
        return success == true, reason
    elseif reward.Pending == true then
        return true, "PendingReward"
    end

    return false, "UnknownRewardType"
end

function WheelService:_handleSpinRequest(player)
    local userId = getUserId(player)
    if userId <= 0 or not ActorUtils.IsPlayer(player) then
        return
    end

    if not self:_isPlayerLoaded(player) then
        self:_fireSpinResult(player, {
            ok = false,
            reason = "DataLoading",
            state = self:BuildStatePayload(player),
        })
        return
    end

    self:_trackWheelFunnel(player, 2, "SpinClicked", {
        source = "wheel",
    })

    if self._spinInProgressByUserId[userId] then
        self:_fireSpinResult(player, {
            ok = false,
            reason = "SpinInProgress",
            state = self:BuildStatePayload(player),
        })
        return
    end

    self._spinInProgressByUserId[userId] = true
    local consumed = false
    local remainingSpins = self:_getWheelSpins(player)
    if self._playerStateService.TryConsumeWheelSpin then
        consumed, remainingSpins = self._playerStateService:TryConsumeWheelSpin(player, {
            source = "wheel",
            productGroup = "WheelSpins",
            itemSku = "WheelSpin",
        })
    end

    if not consumed then
        self._spinInProgressByUserId[userId] = nil
        self:_fireSpinResult(player, {
            ok = false,
            reason = "NotEnoughSpins",
            state = self:BuildStatePayload(player),
        })
        return
    end

    if self._gameAnalyticsService then
        self._gameAnalyticsService:TrackFunnel(player, "WheelFlow", 3, "SpinAccepted", {
            source = "wheel",
        })
    end

    local reward = WheelConfig.RollReward(self._random)
    local granted, reason = self:_grantReward(player, reward)
    self._spinInProgressByUserId[userId] = nil

    if not granted then
        self._playerStateService:AddWheelSpins(player, 1, {
            source = "wheel_refund",
            productGroup = "WheelSpins",
            itemSku = "WheelGrantRefund",
        })
        self:_fireSpinResult(player, {
            ok = false,
            reason = reason or "GrantFailed",
            state = self:BuildStatePayload(player),
        })
        return
    end

    if self._gameAnalyticsService then
        self._gameAnalyticsService:TrackFunnel(player, "WheelFlow", 4, "SpinResultGranted", {
            source = "wheel",
        })
    end

    self:_markDirty(player)
    self:_fireSpinResult(player, {
        ok = true,
        reward = copyRewardForClient(reward),
        targetRotation = reward.TargetRotation,
        remainingSpins = remainingSpins,
        state = self:BuildStatePayload(player),
        pending = reward.Pending == true,
        reason = reason,
    })
    self:SyncState(player)
end

function WheelService:GrantPurchasedSpins(player, productId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false
    end
    if not self:_isPlayerLoaded(player) then
        return false
    end

    local purchase = WheelConfig.GetPurchaseByProductId(productId)
    if not purchase then
        return false
    end

    self._playerStateService:AddWheelSpins(player, purchase.Spins, {
        source = "shop",
        productGroup = "WheelSpins",
        itemSku = tostring(productId),
    })
    self:_markDirty(player)
    self:SyncState(player)
    if self._shopService and self._shopService.NotifyWheelPurchase then
        self._shopService:NotifyWheelPurchase(player, productId)
    end
    if self._gameAnalyticsService then
        self._gameAnalyticsService:TrackFunnel(player, "WheelFlow", 6, "PaidSpinDelivered", {
            source = "shop",
            productGroup = "WheelSpins",
            itemSku = tostring(productId),
        })
    end
    return true
end

function WheelService:_grantFreeSpin(player, now)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        return
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local interval = getFreeSpinInterval()
    local nextFreeAt = self:_getNextFreeAt(player)
    if now < nextFreeAt then
        return
    end

    self._playerStateService:AddWheelSpins(player, 1, {
        source = "timer",
        productGroup = "WheelSpins",
        itemSku = "FreeSpinTimer",
    })
    repeat
        nextFreeAt += interval
    until nextFreeAt > now
    self._nextFreeAtByUserId[userId] = nextFreeAt
    self:_markDirty(player)
    self:SyncState(player)
end

function WheelService:_step()
    local now = os.clock()
    local syncInterval = getSyncInterval()
    for _, player in ipairs(Players:GetPlayers()) do
        local userId = getUserId(player)
        if userId > 0 then
            self:_grantFreeSpin(player, now)
            local lastSyncClock = tonumber(self._lastSyncClockByUserId[userId]) or 0
            if now - lastSyncClock >= syncInterval then
                self._lastSyncClockByUserId[userId] = now
                self:SyncState(player)
            end
        end
    end
end

function WheelService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._skinService = dependencies and dependencies.SkinService or self._skinService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
    self._shopService = dependencies and dependencies.ShopService or self._shopService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function WheelService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._potionService = dependencies and dependencies.PotionService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._skinService = dependencies and dependencies.SkinService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._shopService = dependencies and dependencies.ShopService or nil
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or nil
    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._wheelStateSyncEvent = remoteEventService and remoteEventService:GetEvent("WheelStateSync") or nil
    self._requestWheelStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestWheelStateSync") or nil
    self._requestWheelSpinEvent = remoteEventService and remoteEventService:GetEvent("RequestWheelSpin") or nil
    self._wheelSpinResultEvent = remoteEventService and remoteEventService:GetEvent("WheelSpinResult") or nil
    self._nextFreeAtByUserId = {}
    self._spinInProgressByUserId = {}
    self._lastSyncClockByUserId = {}

    if self._requestStateConnection then
        self._requestStateConnection:Disconnect()
        self._requestStateConnection = nil
    end
    if self._requestSpinConnection then
        self._requestSpinConnection:Disconnect()
        self._requestSpinConnection = nil
    end

    if self._requestWheelStateSyncEvent then
        self._requestStateConnection = self._requestWheelStateSyncEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleStateRequest(player, payload)
        end)
    end

    if self._requestWheelSpinEvent then
        self._requestSpinConnection = self._requestWheelSpinEvent.OnServerEvent:Connect(function(player)
            self:_handleSpinRequest(player)
        end)
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end
    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

function WheelService:OnPlayerAdded(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    self._nextFreeAtByUserId[userId] = os.clock() + getFreeSpinInterval()
    self._lastSyncClockByUserId[userId] = 0
    task.defer(function()
        if player and player.Parent then
            self:SyncState(player)
        end
    end)
end

function WheelService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    self._nextFreeAtByUserId[userId] = nil
    self._spinInProgressByUserId[userId] = nil
    self._lastSyncClockByUserId[userId] = nil
end

return WheelService
