--[[
Script: SkinService
Type: ModuleScript
Studio path: ServerScriptService/Services/SkinService
Purpose: Server-authoritative V3.1 weapon skin ownership, purchase, and equip flow.
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
        "[SkinService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local SkinConfig = requireSharedModule("SkinConfig")

local SkinService = {}

SkinService._playerStateService = nil
SkinService._rebirthService = nil
SkinService._shopService = nil
SkinService._skinStateSyncEvent = nil
SkinService._requestSkinStateSyncEvent = nil
SkinService._requestSkinPurchaseEvent = nil
SkinService._requestSkinEquipEvent = nil
SkinService._skinFeedbackEvent = nil
SkinService._connections = {}
SkinService._pendingGamePassGrantSerialByUserId = {}
SkinService._gamePassOwnershipSyncStateByUserId = {}
SkinService._lastGamePassOwnershipSyncAttemptByUserId = {}

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

function SkinService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function SkinService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function SkinService:_queueGamePassOwnershipSync(player, force)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local currentState = self._gamePassOwnershipSyncStateByUserId[userId]
    if currentState == "Checking" or (currentState == "Done" and force ~= true) then
        return
    end

    local now = os.clock()
    local lastAttempt = self._lastGamePassOwnershipSyncAttemptByUserId[userId] or 0
    if force ~= true and now - lastAttempt < 5 then
        return
    end

    self._gamePassOwnershipSyncStateByUserId[userId] = "Checking"
    self._lastGamePassOwnershipSyncAttemptByUserId[userId] = now

    task.spawn(function()
        local deadline = os.clock() + 15
        while player and player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
            task.wait(0.5)
        end

        if not (player and player.Parent) then
            self._gamePassOwnershipSyncStateByUserId[userId] = nil
            return
        end

        if not self:_isPlayerLoaded(player) then
            self._gamePassOwnershipSyncStateByUserId[userId] = nil
            return
        end

        local hadCheckFailure = false
        local changed = false
        for _, skin in ipairs(SkinConfig.GetAllSkins()) do
            if SkinConfig.IsGamePassSkin(skin) and skin.GamePassId > 0 and not self._playerStateService:OwnsSkin(player, skin.Id) then
                local owns, reason = self:_ownsGamePass(player, skin.GamePassId)
                if owns then
                    local granted = self._playerStateService:GrantSkin(player, skin.Id)
                    changed = changed or granted == true
                elseif reason == "OwnershipCheckFailed" then
                    hadCheckFailure = true
                end
            end
        end

        self._gamePassOwnershipSyncStateByUserId[userId] = hadCheckFailure and nil or "Done"
        if changed then
            self:_markDirty(player)
        end
        self:SyncState(player)
    end)
end

function SkinService:_buildSkinList(player)
    local ownedSkins = self._playerStateService and self._playerStateService:GetOwnedSkins(player) or {}
    local equippedSkinId = self._playerStateService and self._playerStateService:GetEquippedSkinId(player) or nil
    local list = {}
    for _, skin in ipairs(SkinConfig.GetAllSkins()) do
        local entry = SkinConfig.CopyForClient(skin)
        entry.owned = ownedSkins[tostring(skin.Id)] == true
        entry.equipped = tonumber(equippedSkinId) == tonumber(skin.Id)
        table.insert(list, entry)
    end
    return list
end

function SkinService:BuildStatePayload(player)
    return {
        skins = self:_buildSkinList(player),
        equippedSkinId = self._playerStateService and self._playerStateService:GetEquippedSkinId(player) or nil,
        timestamp = os.clock(),
    }
end

function SkinService:SyncState(player)
    if not (self._skinStateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._skinStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
end

function SkinService:_fireFeedback(player, eventType, reason, skin)
    if not (self._skinFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._skinFeedbackEvent:FireClient(player, {
        eventType = tostring(eventType or ""),
        reason = tostring(reason or ""),
        skinId = skin and skin.Id or nil,
        state = self:BuildStatePayload(player),
        timestamp = os.clock(),
    })
end

function SkinService:GrantSkin(player, skinId, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end

    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        return false, "InvalidSkin"
    end

    local success, reason = self._playerStateService:GrantSkin(player, skin.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_fireFeedback(player, "Granted", source or reason, skin)
    end
    return success, reason
end

function SkinService:_tryDiamondPurchase(player, skin)
    if not SkinConfig.IsDiamondSkin(skin) then
        return false, "InvalidPurchaseChannel"
    end
    if self._playerStateService:OwnsSkin(player, skin.Id) then
        self:SyncState(player)
        self:_fireFeedback(player, "AlreadyOwned", "AlreadyOwned", skin)
        return true, "AlreadyOwned"
    end

    local spent = false
    local remainingDiamonds = 0
    if self._playerStateService.TrySpendDiamonds then
        spent, remainingDiamonds = self._playerStateService:TrySpendDiamonds(player, skin.DiamondPrice)
    end
    if not spent then
        self:_fireFeedback(player, "Failed", "NotEnoughDiamonds", skin)
        return false, "NotEnoughDiamonds", remainingDiamonds
    end

    local granted, reason = self._playerStateService:GrantSkin(player, skin.Id)
    if not granted then
        self._playerStateService:AddDiamonds(player, skin.DiamondPrice)
        self:_fireFeedback(player, "Failed", reason or "GrantFailed", skin)
        return false, reason or "GrantFailed"
    end

    self:_markDirty(player)
    self:SyncState(player)
    self:_fireFeedback(player, "Purchased", "Diamonds", skin)
    return true, "Purchased"
end

function SkinService:_ownsGamePass(player, gamePassId)
    local ok, owns = pcall(function()
        return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
    end)
    if not ok then
        warn("[SkinService] UserOwnsGamePassAsync failed: " .. tostring(owns))
        return false, "OwnershipCheckFailed"
    end
    return owns == true, owns == true and "Owned" or "NotOwned"
end

function SkinService:_queueGamePassGrantRetry(player, skin)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local nextSerial = (self._pendingGamePassGrantSerialByUserId[userId] or 0) + 1
    self._pendingGamePassGrantSerialByUserId[userId] = nextSerial
    task.spawn(function()
        for _ = 1, 20 do
            if not (player and player.Parent) then
                return
            end
            if self._pendingGamePassGrantSerialByUserId[userId] ~= nextSerial then
                return
            end
            if self:_isPlayerLoaded(player) then
                local success = self:_tryGamePassGrant(player, skin)
                if success then
                    self._pendingGamePassGrantSerialByUserId[userId] = nil
                end
                return
            end
            task.wait(0.5)
        end
        if self._pendingGamePassGrantSerialByUserId[userId] == nextSerial then
            self._pendingGamePassGrantSerialByUserId[userId] = nil
            warn(string.format(
                "[SkinService] GamePass skin grant waited for player data but it did not load in time (userId=%d, skinId=%s).",
                userId,
                tostring(skin and skin.Id or "")
            ))
        end
    end)
end

function SkinService:_tryGamePassGrant(player, skin)
    if not SkinConfig.IsGamePassSkin(skin) or skin.GamePassId <= 0 then
        return false, "InvalidPurchaseChannel"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end
    if self._playerStateService:OwnsSkin(player, skin.Id) then
        self:SyncState(player)
        self:_fireFeedback(player, "AlreadyOwned", "AlreadyOwned", skin)
        return true, "AlreadyOwned"
    end

    local owns, reason = self:_ownsGamePass(player, skin.GamePassId)
    if not owns then
        self:_fireFeedback(player, "Failed", reason or "GamePassNotOwned", skin)
        return false, reason or "GamePassNotOwned"
    end

    local success, reason = self:GrantSkin(player, skin.Id, "GamePass")
    if success and self._shopService and self._shopService.NotifySkinPurchase then
        self._shopService:NotifySkinPurchase(player, skin.Id, skin.GamePassId)
    end
    return success, reason
end

function SkinService:_handlePurchaseRequest(player, skinId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return
    end

    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        self:_fireFeedback(player, "Failed", "InvalidSkin")
        return
    end

    if SkinConfig.IsDiamondSkin(skin) then
        self:_tryDiamondPurchase(player, skin)
    elseif SkinConfig.IsGamePassSkin(skin) then
        self:_tryGamePassGrant(player, skin)
    elseif SkinConfig.IsWheelSkin(skin) then
        self:_fireFeedback(player, "OpenWheel", "WheelOnly", skin)
    else
        self:_fireFeedback(player, "Failed", "InvalidPurchaseChannel", skin)
    end
end

function SkinService:_handleEquipRequest(player, skinId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return
    end

    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        self:_fireFeedback(player, "Failed", "InvalidSkin")
        return
    end

    local success, reason = self._playerStateService:EquipSkin(player, skin.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_fireFeedback(player, "Equipped", reason, skin)
    else
        self:_fireFeedback(player, "Failed", reason, skin)
    end
end

function SkinService:_handleGamePassFinished(player, gamePassId, wasPurchased)
    if wasPurchased ~= true then
        return
    end
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    local resolvedGamePassId = math.floor(tonumber(gamePassId) or 0)
    for _, skin in ipairs(SkinConfig.GetAllSkins()) do
        if SkinConfig.IsGamePassSkin(skin) and skin.GamePassId == resolvedGamePassId then
            local success, reason = self:_tryGamePassGrant(player, skin)
            if not success and reason == "DataLoading" then
                self:_queueGamePassGrantRetry(player, skin)
            end
            return
        end
    end
end

function SkinService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._shopService = dependencies and dependencies.ShopService or self._shopService
end

function SkinService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._shopService = dependencies and dependencies.ShopService or nil
    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._skinStateSyncEvent = remoteEventService and remoteEventService:GetEvent("SkinStateSync") or nil
    self._requestSkinStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinStateSync") or nil
    self._requestSkinPurchaseEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinPurchase") or nil
    self._requestSkinEquipEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinEquip") or nil
    self._skinFeedbackEvent = remoteEventService and remoteEventService:GetEvent("SkinFeedback") or nil

    disconnectAll(self._connections)
    if self._requestSkinStateSyncEvent then
        table.insert(self._connections, self._requestSkinStateSyncEvent.OnServerEvent:Connect(function(player)
            self:_queueGamePassOwnershipSync(player)
            self:SyncState(player)
        end))
    end
    if self._requestSkinPurchaseEvent then
        table.insert(self._connections, self._requestSkinPurchaseEvent.OnServerEvent:Connect(function(player, skinId)
            self:_handlePurchaseRequest(player, skinId)
        end))
    end
    if self._requestSkinEquipEvent then
        table.insert(self._connections, self._requestSkinEquipEvent.OnServerEvent:Connect(function(player, skinId)
            self:_handleEquipRequest(player, skinId)
        end))
    end
    table.insert(self._connections, MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
        self:_handleGamePassFinished(player, gamePassId, wasPurchased)
    end))
end

function SkinService:OnPlayerAdded(player)
    task.defer(function()
        if player and player.Parent then
            self:_queueGamePassOwnershipSync(player)
            self:SyncState(player)
        end
    end)
end

function SkinService:OnPlayerRemoving(player)
    self._pendingGamePassGrantSerialByUserId[getUserId(player)] = nil
    self._gamePassOwnershipSyncStateByUserId[getUserId(player)] = nil
    self._lastGamePassOwnershipSyncAttemptByUserId[getUserId(player)] = nil
end

return SkinService
