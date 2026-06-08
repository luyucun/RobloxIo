--[[
Script: AttributeCapUpgradeService
Type: ModuleScript
Studio path: ServerScriptService/Services/AttributeCapUpgradeService
Purpose: Server-authoritative global attribute cap upgrades.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

    error(string.format("[AttributeCapUpgradeService] Missing shared module %s", tostring(moduleName or "")))
end

local AttributeConfig = requireSharedModule("AttributeConfig")

local AttributeCapUpgradeService = {}

AttributeCapUpgradeService._remoteEventService = nil
AttributeCapUpgradeService._playerStateService = nil
AttributeCapUpgradeService._rebirthService = nil
AttributeCapUpgradeService._requestEvent = nil
AttributeCapUpgradeService._feedbackEvent = nil
AttributeCapUpgradeService._requestConnection = nil

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

function AttributeCapUpgradeService:_isPlayerLoaded(player)
    return not self._rebirthService
        or not self._rebirthService.IsPlayerLoaded
        or self._rebirthService:IsPlayerLoaded(player)
end

function AttributeCapUpgradeService:_fireFeedback(player, payload)
    if self._feedbackEvent and player and player.Parent then
        self._feedbackEvent:FireClient(player, payload)
    end
end

function AttributeCapUpgradeService:_buildFeedback(player, success, attributeKey, reason, message, extra)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local statePayload = nil
    if self._playerStateService and self._playerStateService.BuildAttributeStatePayload then
        statePayload = self._playerStateService:BuildAttributeStatePayload(player)
    end

    local caps = statePayload and statePayload.attributeCaps or {}
    local cap = key and math.max(0, math.floor(tonumber(caps and caps[key]) or 0)) or 0
    local info = key and AttributeConfig.GetCapUpgradeInfo(key, cap) or nil
    local state = self._playerStateService and self._playerStateService.GetState and self._playerStateService:GetState(player) or nil
    local payload = {
        success = success == true,
        attributeKey = key or "",
        reason = tostring(reason or ""),
        message = tostring(message or ""),
        currentCap = cap,
        nextCap = info and info.NextCap or cap,
        maxCap = info and info.MaxCap or 0,
        gemCost = info and info.GemCost or nil,
        diamonds = state and math.max(0, math.floor(tonumber(state.Diamonds) or 0)) or 0,
        attributeCaps = caps,
        timestamp = os.clock(),
    }
    if type(extra) == "table" then
        for extraKey, value in pairs(extra) do
            payload[extraKey] = value
        end
    end
    return payload
end

function AttributeCapUpgradeService:_handleRequest(player, requestedAttributeKey)
    if not (player and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, self:_buildFeedback(player, false, requestedAttributeKey, "DataLoading", "Data loading"))
        return
    end

    local attributeKey = AttributeConfig.NormalizeKey(requestedAttributeKey)
    if not attributeKey then
        self:_fireFeedback(player, self:_buildFeedback(player, false, "", "InvalidAttribute", "Invalid attribute"))
        return
    end

    local success, reason, message, cap, diamonds, gemCost = self._playerStateService:TryUpgradeAttributeCapWithDiamonds(player, attributeKey)
    self:_fireFeedback(player, self:_buildFeedback(player, success == true, attributeKey, reason, message, {
        currentCap = cap,
        diamonds = diamonds,
        gemCost = gemCost,
    }))
end

function AttributeCapUpgradeService:ProcessReceipt(receiptInfo)
    local productId = math.floor(tonumber(receiptInfo and receiptInfo.ProductId) or 0)
    local attributeKey = AttributeConfig.GetAttributeByCapUpgradeProductId(productId)
    if not attributeKey then
        return false, nil
    end

    local player = Players:GetPlayerByUserId(math.floor(tonumber(receiptInfo.PlayerId) or 0))
    if not player then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end
    if not self:_isPlayerLoaded(player) then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end
    if not self._playerStateService then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local success, reason, message, cap, diamonds, gemCost = self._playerStateService:GrantAttributeCapProduct(player, attributeKey)
    self:_fireFeedback(player, self:_buildFeedback(player, success == true, attributeKey, reason, message, {
        currentCap = cap,
        diamonds = diamonds,
        gemCost = gemCost,
        productId = productId,
    }))
    return true, success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end

function AttributeCapUpgradeService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
end

function AttributeCapUpgradeService:Init(dependencies)
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._requestEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestAttributeCapUpgrade") or nil
    self._feedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("AttributeCapUpgradeFeedback") or nil

    disconnectConnection(self._requestConnection)
    self._requestConnection = nil

    if self._requestEvent then
        self._requestConnection = self._requestEvent.OnServerEvent:Connect(function(player, attributeKey)
            self:_handleRequest(player, attributeKey)
        end)
    else
        warn("[AttributeCapUpgradeService] RequestAttributeCapUpgrade RemoteEvent is unavailable")
    end
end

return AttributeCapUpgradeService
