--[[
Script: AttributeUpgradeService
Type: ModuleScript
Studio path: ServerScriptService/Services/AttributeUpgradeService
Purpose: Server-authoritative in-battle attribute upgrade requests.
]]

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

    error(string.format("[AttributeUpgradeService] Missing shared module %s", tostring(moduleName or "")))
end

local AttributeConfig = requireSharedModule("AttributeConfig")

local AttributeUpgradeService = {}

AttributeUpgradeService._remoteEventService = nil
AttributeUpgradeService._playerStateService = nil
AttributeUpgradeService._weaponService = nil
AttributeUpgradeService._healthService = nil
AttributeUpgradeService._requestEvent = nil
AttributeUpgradeService._feedbackEvent = nil
AttributeUpgradeService._requestConnection = nil

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

function AttributeUpgradeService:_fireFeedback(player, payload)
    if not (self._feedbackEvent and player and player.Parent) then
        return
    end
    self._feedbackEvent:FireClient(player, payload)
end

function AttributeUpgradeService:_buildFeedback(player, success, attributeKey, reason, message)
    local statePayload = nil
    if self._playerStateService and self._playerStateService.BuildAttributeStatePayload then
        statePayload = self._playerStateService:BuildAttributeStatePayload(player)
    end

    local level = 0
    local cap = 0
    if statePayload then
        level = math.max(0, math.floor(tonumber(statePayload.attributeLevels and statePayload.attributeLevels[attributeKey]) or 0))
        cap = math.max(0, math.floor(tonumber(statePayload.attributeCaps and statePayload.attributeCaps[attributeKey]) or 0))
    end

    return {
        success = success == true,
        attributeKey = attributeKey,
        reason = tostring(reason or ""),
        message = tostring(message or ""),
        level = level,
        cap = cap,
        skillPoints = statePayload and statePayload.skillPoints or 0,
        timestamp = os.clock(),
    }
end

function AttributeUpgradeService:_onRequestAttributeUpgrade(player, requestedAttributeKey)
    if not (player and player.Parent and self._playerStateService) then
        return
    end

    local attributeKey = AttributeConfig.NormalizeKey(requestedAttributeKey)
    if not attributeKey then
        self:_fireFeedback(player, self:_buildFeedback(player, false, "", "InvalidAttribute", "Invalid attribute"))
        return
    end

    local success, reason, message = self._playerStateService:TryUpgradeAttribute(player, attributeKey)
    if success then
        if self._weaponService and self._weaponService.RebuildWeaponsForActor then
            self._weaponService:RebuildWeaponsForActor(player, {
                attributeChanged = attributeKey,
            })
        end
        if self._playerStateService.PushState then
            self._playerStateService:PushState(player)
        end
    elseif self._playerStateService.PushState then
        self._playerStateService:PushState(player)
    end

    self:_fireFeedback(player, self:_buildFeedback(
        player,
        success == true,
        attributeKey,
        reason,
        message
    ))
end

function AttributeUpgradeService:Init(dependencies)
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._weaponService = dependencies and dependencies.WeaponService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._requestEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestAttributeUpgrade") or nil
    self._feedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("AttributeUpgradeFeedback") or nil

    disconnectConnection(self._requestConnection)
    self._requestConnection = nil

    if self._requestEvent then
        self._requestConnection = self._requestEvent.OnServerEvent:Connect(function(player, attributeKey)
            self:_onRequestAttributeUpgrade(player, attributeKey)
        end)
    else
        warn("[AttributeUpgradeService] RequestAttributeUpgrade RemoteEvent is unavailable")
    end
end

return AttributeUpgradeService
