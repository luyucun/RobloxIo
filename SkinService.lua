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
local TrailConfig = requireSharedModule("TrailConfig")
local TitleConfig = requireSharedModule("TitleConfig")

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
SkinService._gameAnalyticsService = nil
SkinService._trailCharacterConnectionsByUserId = {}

local LEGACY_TRAIL_ACCESSORY_TAG = "IOEquippedTrail"
local TRAIL_ID_ATTRIBUTE = "EquippedTrailId"

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

function SkinService:_waitForPlayerLoaded(player, timeoutSeconds)
    local deadline = os.clock() + math.max(0.5, tonumber(timeoutSeconds) or 15)
    while player and player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
        task.wait(0.5)
    end
    return player and player.Parent and self:_isPlayerLoaded(player)
end

function SkinService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function SkinService:_buildSkinAnalyticsFields(skin, source)
    return {
        source = tostring(source or "skin"),
        productGroup = "skin",
        itemSku = skin and tostring(skin.Id) or "Unknown",
        skinId = skin and skin.Id or 0,
        gamePassId = skin and math.floor(tonumber(skin.GamePassId) or 0) or 0,
    }
end

function SkinService:_buildTrailAnalyticsFields(trail, source)
    return {
        source = tostring(source or "trail"),
        productGroup = "trail",
        itemSku = trail and tostring(trail.Id) or "Unknown",
        trailId = trail and trail.Id or 0,
        productId = trail and math.floor(tonumber(trail.ProductId) or 0) or 0,
    }
end

function SkinService:_trackSkinFunnel(player, stepNumber, stepName, skin, source)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackFunnel) then
        return
    end

    self._gameAnalyticsService:TrackFunnel(player, "SkinFlow", stepNumber, stepName, self:_buildSkinAnalyticsFields(skin, source))
end

function SkinService:_trackSkinFailure(player, eventName, skin, source)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackCustom) then
        return
    end

    self._gameAnalyticsService:TrackCustom(player, eventName, 1, self:_buildSkinAnalyticsFields(skin, source))
end

local function isTrailPayload(payload)
    if type(payload) ~= "table" then
        return false
    end
    local itemType = tostring(payload.itemType or payload.ItemType or payload.purchaseType or "")
    local productGroup = tostring(payload.productGroup or payload.ProductGroup or "")
    return itemType == "Trail" or productGroup:lower() == "trail"
end

local function isTitlePayload(payload)
    if type(payload) ~= "table" then
        return false
    end
    local itemType = tostring(payload.itemType or payload.ItemType or payload.purchaseType or "")
    local productGroup = tostring(payload.productGroup or payload.ProductGroup or "")
    return itemType == "Title" or productGroup:lower() == "title"
end

local function setTrailAttribute(instance, trailId)
    if not instance then
        return
    end
    local normalizedTrailId = math.floor(tonumber(trailId) or 0)
    if normalizedTrailId > 0 then
        instance:SetAttribute(TRAIL_ID_ATTRIBUTE, normalizedTrailId)
    else
        instance:SetAttribute(TRAIL_ID_ATTRIBUTE, nil)
    end
end

function SkinService:_clearServerCharacterTrail(character)
    if not character then
        return
    end
    for _, child in ipairs(character:GetChildren()) do
        if child:GetAttribute(LEGACY_TRAIL_ACCESSORY_TAG) == true then
            child:Destroy()
        end
    end
end

function SkinService:_getEquippedTrailId(player)
    if not (ActorUtils.IsPlayer(player) and self._playerStateService) then
        return nil
    end
    local trailId = self._playerStateService:GetEquippedTrailId(player)
    local normalizedTrailId = math.floor(tonumber(trailId) or 0)
    return normalizedTrailId > 0 and normalizedTrailId or nil
end

function SkinService:_syncEquippedTrailAttributes(player, character)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    local equippedTrailId = nil
    if player.Parent then
        equippedTrailId = self:_getEquippedTrailId(player)
    end

    setTrailAttribute(player, equippedTrailId)
    if character then
        self:_clearServerCharacterTrail(character)
        setTrailAttribute(character, equippedTrailId)
    end
end

function SkinService:_syncPlayerTrail(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self:_syncEquippedTrailAttributes(player, player.Character)
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

        if hadCheckFailure then
            self._gamePassOwnershipSyncStateByUserId[userId] = nil
        else
            self._gamePassOwnershipSyncStateByUserId[userId] = "Done"
        end
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

function SkinService:_buildTrailList(player)
    local ownedTrails = self._playerStateService and self._playerStateService:GetOwnedTrails(player) or {}
    local equippedTrailId = self._playerStateService and self._playerStateService:GetEquippedTrailId(player) or nil
    local list = {}
    for _, trail in ipairs(TrailConfig.GetAllTrails()) do
        local entry = TrailConfig.CopyForClient(trail)
        entry.itemType = "Trail"
        entry.owned = ownedTrails[tostring(trail.Id)] == true
        entry.equipped = tonumber(equippedTrailId) == tonumber(trail.Id)
        table.insert(list, entry)
    end
    return list
end

function SkinService:_buildTitleList(player)
    local ownedTitles = self._playerStateService and self._playerStateService:GetOwnedTitles(player) or {}
    local equippedTitleId = self._playerStateService and self._playerStateService:GetEquippedTitleId(player) or nil
    local list = {}
    for _, title in ipairs(TitleConfig.GetAllTitles()) do
        local entry = TitleConfig.CopyForClient(title)
        entry.itemType = "Title"
        entry.owned = ownedTitles[tostring(title.Id)] == true
        entry.equipped = tonumber(equippedTitleId) == tonumber(title.Id)
        table.insert(list, entry)
    end
    return list
end

function SkinService:BuildStatePayload(player)
    return {
        skins = self:_buildSkinList(player),
        equippedSkinId = self._playerStateService and self._playerStateService:GetEquippedSkinId(player) or nil,
        trails = self:_buildTrailList(player),
        equippedTrailId = self._playerStateService and self._playerStateService:GetEquippedTrailId(player) or nil,
        titles = self:_buildTitleList(player),
        equippedTitleId = self._playerStateService and self._playerStateService:GetEquippedTitleId(player) or nil,
        hasUnseenTitleUnlock = self._playerStateService and self._playerStateService:GetState(player).HasUnseenTitleUnlock == true or false,
        timestamp = os.clock(),
    }
end

function SkinService:SyncState(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self:_syncPlayerTrail(player)

    if not self._skinStateSyncEvent then
        return
    end

    self._skinStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
end

function SkinService:_fireFeedback(player, eventType, reason, skin, itemType)
    if not (self._skinFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    local normalizedItemType = itemType or "Skin"
    self._skinFeedbackEvent:FireClient(player, {
        eventType = tostring(eventType or ""),
        reason = tostring(reason or ""),
        itemType = normalizedItemType,
        skinId = normalizedItemType == "Skin" and skin and skin.Id or nil,
        trailId = normalizedItemType == "Trail" and skin and skin.Id or nil,
        titleId = normalizedItemType == "Title" and skin and skin.Id or nil,
        titleIconImage = normalizedItemType == "Title" and skin and skin.IconImage or nil,
        title = normalizedItemType == "Title" and TitleConfig.CopyForClient(skin) or nil,
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
        self:_trackSkinFunnel(player, 3, "SkinPurchaseSucceeded", skin, source or "skin")
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
        spent, remainingDiamonds = self._playerStateService:TrySpendDiamonds(player, skin.DiamondPrice, {
            source = "skin",
            productGroup = "skin",
            itemSku = "SkinDiamondPurchase_" .. tostring(skin.Id),
        })
    end
    if not spent then
        self:_trackSkinFailure(player, "SkinPurchaseFailed_NotEnoughDiamonds", skin, "skin")
        self:_fireFeedback(player, "Failed", "NotEnoughDiamonds", skin)
        return false, "NotEnoughDiamonds", remainingDiamonds
    end

    local granted, reason = self._playerStateService:GrantSkin(player, skin.Id)
    if not granted then
        self._playerStateService:AddDiamonds(player, skin.DiamondPrice, {
            source = "skin_refund",
            productGroup = "skin",
            itemSku = "SkinDiamondPurchaseRefund_" .. tostring(skin.Id),
        })
        self:_fireFeedback(player, "Failed", reason or "GrantFailed", skin)
        return false, reason or "GrantFailed"
    end

    self:_markDirty(player)
    self:SyncState(player)
    self:_fireFeedback(player, "Purchased", "Diamonds", skin)
    self:_trackSkinFunnel(player, 3, "SkinPurchaseSucceeded", skin, "skin")
    return true, "Purchased"
end

function SkinService:_tryDiamondTrailPurchase(player, trail)
    if self._playerStateService:OwnsTrail(player, trail.Id) then
        self:SyncState(player)
        self:_fireFeedback(player, "AlreadyOwned", "AlreadyOwned", trail, "Trail")
        return true, "AlreadyOwned"
    end

    local spent = false
    local remainingDiamonds = 0
    if self._playerStateService.TrySpendDiamonds then
        spent, remainingDiamonds = self._playerStateService:TrySpendDiamonds(player, trail.DiamondPrice, {
            source = "trail",
            productGroup = "trail",
            itemSku = "TrailDiamondPurchase_" .. tostring(trail.Id),
        })
    end
    if not spent then
        self:_trackTrailFailure(player, "TrailPurchaseFailed_NotEnoughDiamonds", trail, "trail")
        self:_fireFeedback(player, "Failed", "NotEnoughDiamonds", trail, "Trail")
        return false, "NotEnoughDiamonds", remainingDiamonds
    end

    local granted, reason = self._playerStateService:GrantTrail(player, trail.Id)
    if not granted then
        self._playerStateService:AddDiamonds(player, trail.DiamondPrice, {
            source = "trail_refund",
            productGroup = "trail",
            itemSku = "TrailDiamondPurchaseRefund_" .. tostring(trail.Id),
        })
        self:_fireFeedback(player, "Failed", reason or "GrantFailed", trail, "Trail")
        return false, reason or "GrantFailed"
    end

    self:_markDirty(player)
    self:SyncState(player)
    self:_fireFeedback(player, "Purchased", "Diamonds", trail, "Trail")
    self:_trackTrailFunnel(player, 3, "TrailPurchaseSucceeded", trail, "trail")
    return true, "Purchased"
end

function SkinService:_tryRobuxTrailPurchase(player, trail)
    if self._playerStateService:OwnsTrail(player, trail.Id) then
        self:SyncState(player)
        self:_fireFeedback(player, "AlreadyOwned", "AlreadyOwned", trail, "Trail")
        return true, "AlreadyOwned"
    end

    self:_fireFeedback(player, "OpenProductPurchase", "Robux", trail, "Trail")
    return true, "Prompted"
end

function SkinService:_trackTrailFunnel(player, stepNumber, stepName, trail, source)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackFunnel) then
        return
    end

    self._gameAnalyticsService:TrackFunnel(player, "TrailFlow", stepNumber, stepName, self:_buildTrailAnalyticsFields(trail, source))
end

function SkinService:_trackTrailFailure(player, eventName, trail, source)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackCustom) then
        return
    end

    self._gameAnalyticsService:TrackCustom(player, eventName, 1, self:_buildTrailAnalyticsFields(trail, source))
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

function SkinService:_handleStateRequest(player, payload)
    if type(payload) == "table" and tostring(payload.intent or "") == "SkinPanelOpened" then
        self:_trackSkinFunnel(player, 1, "SkinPanelOpened", nil, payload.source or "skin")
        if self._playerStateService and self._playerStateService.ClearUnseenTitleUnlock then
            local cleared = self._playerStateService:ClearUnseenTitleUnlock(player)
            if cleared then
                self:_markDirty(player)
            end
        end
    end

    self:_queueGamePassOwnershipSync(player)
    self:SyncState(player)
end

function SkinService:_handlePurchaseRequest(player, skinId, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return
    end

    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        self:_trackSkinFailure(player, "SkinPurchaseFailed_InvalidSkin", nil, "skin")
        self:_fireFeedback(player, "Failed", "InvalidSkin")
        return
    end

    self:_trackSkinFunnel(player, 2, "SkinPurchaseClicked", skin, type(payload) == "table" and payload.source or "skin")
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

function SkinService:_handleTrailPurchaseRequest(player, trailId, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", nil, "Trail")
        return
    end

    local trail = TrailConfig.GetTrail(trailId)
    if not trail then
        self:_trackTrailFailure(player, "TrailPurchaseFailed_InvalidTrail", nil, "trail")
        self:_fireFeedback(player, "Failed", "InvalidTrail", nil, "Trail")
        return
    end

    local purchaseMethod = type(payload) == "table" and tostring(payload.purchaseMethod or payload.PurchaseMethod or "") or ""
    self:_trackTrailFunnel(player, 2, "TrailPurchaseClicked", trail, type(payload) == "table" and payload.source or "trail")
    if purchaseMethod == "Robux" then
        self:_tryRobuxTrailPurchase(player, trail)
    elseif trail.DiamondPrice > 0 then
        self:_tryDiamondTrailPurchase(player, trail)
    elseif trail.ProductId > 0 then
        self:_tryRobuxTrailPurchase(player, trail)
    else
        self:_fireFeedback(player, "Failed", "InvalidPurchaseChannel", trail, "Trail")
    end
end

function SkinService:_handleEquipRequest(player, skinId, action)
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

    self:_trackSkinFunnel(player, 4, "SkinEquipClicked", skin, "skin")
    if tostring(action or "") == "Unequip" then
        if not self._playerStateService:OwnsSkin(player, skin.Id) then
            self:_trackSkinFailure(player, "SkinEquipFailed_NotOwned", skin, "skin")
            self:_fireFeedback(player, "Failed", "NotOwned", skin)
            return
        end

        local equippedSkinId = self._playerStateService:GetEquippedSkinId(player)
        if tonumber(equippedSkinId) ~= tonumber(skin.Id) then
            self:SyncState(player)
            self:_fireFeedback(player, "Failed", "NotEquipped", skin)
            return
        end

        local success, reason = self._playerStateService:ClearEquippedSkin(player)
        if success then
            self:_markDirty(player)
            self:SyncState(player)
            self:_fireFeedback(player, "Unequipped", reason or "Unequipped", skin)
        else
            self:_fireFeedback(player, "Failed", reason, skin)
        end
        return
    end

    local success, reason = self._playerStateService:EquipSkin(player, skin.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_fireFeedback(player, "Equipped", reason, skin)
        self:_trackSkinFunnel(player, 5, "SkinEquipped", skin, "skin")
    else
        if reason == "NotOwned" then
            self:_trackSkinFailure(player, "SkinEquipFailed_NotOwned", skin, "skin")
        end
        self:_fireFeedback(player, "Failed", reason, skin)
    end
end

function SkinService:_handleTrailEquipRequest(player, trailId, action)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", nil, "Trail")
        return
    end

    local trail = TrailConfig.GetTrail(trailId)
    if not trail then
        self:_fireFeedback(player, "Failed", "InvalidTrail", nil, "Trail")
        return
    end

    self:_trackTrailFunnel(player, 4, "TrailEquipClicked", trail, "trail")
    if tostring(action or "") == "Unequip" then
        if not self._playerStateService:OwnsTrail(player, trail.Id) then
            self:_trackTrailFailure(player, "TrailEquipFailed_NotOwned", trail, "trail")
            self:_fireFeedback(player, "Failed", "NotOwned", trail, "Trail")
            return
        end

        local equippedTrailId = self._playerStateService:GetEquippedTrailId(player)
        if tonumber(equippedTrailId) ~= tonumber(trail.Id) then
            self:SyncState(player)
            self:_fireFeedback(player, "Failed", "NotEquipped", trail, "Trail")
            return
        end

        local success, reason = self._playerStateService:ClearEquippedTrail(player)
        if success then
            self:_markDirty(player)
            self:SyncState(player)
            self:_syncPlayerTrail(player)
            self:_fireFeedback(player, "Unequipped", reason or "Unequipped", trail, "Trail")
        else
            self:_fireFeedback(player, "Failed", reason, trail, "Trail")
        end
        return
    end

    local success, reason = self._playerStateService:EquipTrail(player, trail.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_syncPlayerTrail(player)
        self:_fireFeedback(player, "Equipped", reason, trail, "Trail")
        self:_trackTrailFunnel(player, 5, "TrailEquipped", trail, "trail")
    else
        if reason == "NotOwned" then
            self:_trackTrailFailure(player, "TrailEquipFailed_NotOwned", trail, "trail")
        end
        self:_fireFeedback(player, "Failed", reason, trail, "Trail")
    end
end

function SkinService:_handleTitleEquipRequest(player, titleId, action)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", nil, "Title")
        return
    end

    local title = TitleConfig.GetTitle(titleId)
    if not title then
        self:_fireFeedback(player, "Failed", "InvalidTitle", nil, "Title")
        return
    end

    if tostring(action or "") == "Unequip" then
        if not self._playerStateService:OwnsTitle(player, title.Id) then
            self:_fireFeedback(player, "Failed", "NotOwned", title, "Title")
            return
        end

        local equippedTitleId = self._playerStateService:GetEquippedTitleId(player)
        if tonumber(equippedTitleId) ~= tonumber(title.Id) then
            self:SyncState(player)
            self:_fireFeedback(player, "Failed", "NotEquipped", title, "Title")
            return
        end

        local success, reason = self._playerStateService:ClearEquippedTitle(player)
        if success then
            self:_markDirty(player)
            self:SyncState(player)
            self:_fireFeedback(player, "Unequipped", reason or "Unequipped", title, "Title")
        else
            self:_fireFeedback(player, "Failed", reason, title, "Title")
        end
        return
    end

    local success, reason = self._playerStateService:EquipTitle(player, title.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_fireFeedback(player, "Equipped", reason, title, "Title")
    else
        self:_fireFeedback(player, "Failed", reason, title, "Title")
    end
end

function SkinService:NotifyTitleUnlocked(player, title)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self:SyncState(player)
    self:_fireFeedback(player, "Unlocked", "TitleUnlocked", title, "Title")
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
            if self._gameAnalyticsService then
                self._gameAnalyticsService:TrackFunnel(player, "ShopPurchase", 5, "ProductReceiptGranted", self:_buildSkinAnalyticsFields(skin, "Skin"))
            end
            local success, reason = self:_tryGamePassGrant(player, skin)
            if not success and reason == "DataLoading" then
                self:_queueGamePassGrantRetry(player, skin)
            end
            return
        end
    end
end

function SkinService:ProcessReceipt(receiptInfo)
    local productId = math.floor(tonumber(receiptInfo and receiptInfo.ProductId) or 0)
    local trail = TrailConfig.GetTrailByProductId(productId)
    if not trail then
        return false, nil
    end

    local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
    if not player then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end
    if not self:_isPlayerLoaded(player) then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end
    if not self._playerStateService then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local success, reason = self._playerStateService:GrantTrail(player, trail.Id)
    if success then
        self:_markDirty(player)
        self:SyncState(player)
        self:_fireFeedback(player, "Purchased", reason or "Robux", trail, "Trail")
        self:_trackTrailFunnel(player, 3, "TrailPurchaseSucceeded", trail, "trail")
        return true, Enum.ProductPurchaseDecision.PurchaseGranted
    end

    self:_fireFeedback(player, "Failed", reason or "GrantFailed", trail, "Trail")
    return true, Enum.ProductPurchaseDecision.NotProcessedYet
end

function SkinService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._shopService = dependencies and dependencies.ShopService or self._shopService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function SkinService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._shopService = dependencies and dependencies.ShopService or nil
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or nil
    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._skinStateSyncEvent = remoteEventService and remoteEventService:GetEvent("SkinStateSync") or nil
    self._requestSkinStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinStateSync") or nil
    self._requestSkinPurchaseEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinPurchase") or nil
    self._requestSkinEquipEvent = remoteEventService and remoteEventService:GetEvent("RequestSkinEquip") or nil
    self._skinFeedbackEvent = remoteEventService and remoteEventService:GetEvent("SkinFeedback") or nil
    self._trailCharacterConnectionsByUserId = self._trailCharacterConnectionsByUserId or {}

    disconnectAll(self._connections)
    if self._requestSkinStateSyncEvent then
        table.insert(self._connections, self._requestSkinStateSyncEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleStateRequest(player, payload)
        end))
    end
    if self._requestSkinPurchaseEvent then
        table.insert(self._connections, self._requestSkinPurchaseEvent.OnServerEvent:Connect(function(player, skinId, payload)
            if isTrailPayload(payload) then
                self:_handleTrailPurchaseRequest(player, skinId, payload)
            else
                self:_handlePurchaseRequest(player, skinId, payload)
            end
        end))
    end
    if self._requestSkinEquipEvent then
        table.insert(self._connections, self._requestSkinEquipEvent.OnServerEvent:Connect(function(player, skinId, action)
            if type(action) == "table" and isTitlePayload(action) then
                self:_handleTitleEquipRequest(player, skinId, action.action or action.Action)
            elseif type(action) == "table" and isTrailPayload(action) then
                self:_handleTrailEquipRequest(player, skinId, action.action or action.Action)
            else
                self:_handleEquipRequest(player, skinId, action)
            end
        end))
    end
    table.insert(self._connections, MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
        self:_handleGamePassFinished(player, gamePassId, wasPurchased)
    end))
end

function SkinService:OnPlayerAdded(player)
    local userId = getUserId(player)
    local existingConnection = self._trailCharacterConnectionsByUserId[userId]
    if existingConnection and existingConnection.Connected then
        existingConnection:Disconnect()
    end
    self._trailCharacterConnectionsByUserId[userId] = player.CharacterAdded:Connect(function(character)
        task.defer(function()
            if self:_waitForPlayerLoaded(player, 15) then
                self:_syncEquippedTrailAttributes(player, character)
            end
        end)
    end)

    task.defer(function()
        if player and player.Parent then
            self:_waitForPlayerLoaded(player, 15)
            self:_queueGamePassOwnershipSync(player)
            self:SyncState(player)
            self:_syncPlayerTrail(player)
        end
    end)
end

function SkinService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    self._pendingGamePassGrantSerialByUserId[userId] = nil
    self._gamePassOwnershipSyncStateByUserId[userId] = nil
    self._lastGamePassOwnershipSyncAttemptByUserId[userId] = nil
    local characterConnection = self._trailCharacterConnectionsByUserId[userId]
    if characterConnection and characterConnection.Connected then
        characterConnection:Disconnect()
    end
    self._trailCharacterConnectionsByUserId[userId] = nil
    setTrailAttribute(player, nil)
end

return SkinService
