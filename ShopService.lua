--[[
Script: ShopService
Type: ModuleScript
Studio path: ServerScriptService/Services/ShopService
Purpose: V3.5 shop state, StarterPack one-time rewards, and shared reward popup feedback.
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
        "[ShopService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local ShopConfig = requireSharedModule("ShopConfig")
local WheelConfig = requireSharedModule("WheelConfig")
local SkinConfig = requireSharedModule("SkinConfig")

local ShopService = {}

ShopService._playerStateService = nil
ShopService._rebirthService = nil
ShopService._potionService = nil
ShopService._shopStateSyncEvent = nil
ShopService._requestShopStateSyncEvent = nil
ShopService._requestStarterPackClaimEvent = nil
ShopService._requestPurchaseContextEvent = nil
ShopService._shopRewardFeedbackEvent = nil
ShopService._connections = {}
ShopService._purchaseContextByUserId = {}
ShopService._starterPackGrantInProgressByUserId = {}
ShopService._gameAnalyticsService = nil

local PURCHASE_CONTEXT_TTL_SECONDS = 120

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

local function normalizePurchaseGroup(payload)
    local productGroup = tostring(type(payload) == "table" and (payload.productGroup or "") or "")
    if productGroup ~= "" then
        return productGroup
    end

    local purchaseType = tostring(type(payload) == "table" and (payload.purchaseType or "") or "")
    if purchaseType == "WheelSpins" then
        return "WheelSpins"
    elseif purchaseType == "Skin" then
        return "GamePassSkin"
    elseif purchaseType == "StarterPack" then
        return "StarterPack"
    elseif purchaseType == "Potion" then
        return "Potion"
    elseif purchaseType ~= "" then
        return purchaseType
    end

    return "Shop"
end

local function normalizeItemSku(payload)
    if type(payload) ~= "table" then
        return "Unknown"
    end

    if payload.itemSku ~= nil then
        return tostring(payload.itemSku)
    end
    if payload.productId ~= nil then
        return tostring(math.floor(tonumber(payload.productId) or 0))
    end
    if payload.gamePassId ~= nil then
        return tostring(math.floor(tonumber(payload.gamePassId) or 0))
    end
    if payload.skinId ~= nil then
        return tostring(math.floor(tonumber(payload.skinId) or 0))
    end
    return "Unknown"
end

local function buildPurchaseFields(payload)
    local source = "Shop"
    if type(payload) == "table" then
        source = tostring(payload.source or source)
    end

    return {
        source = source,
        productGroup = normalizePurchaseGroup(payload),
        itemSku = normalizeItemSku(payload),
        productId = type(payload) == "table" and math.floor(tonumber(payload.productId) or 0) or 0,
        gamePassId = type(payload) == "table" and math.floor(tonumber(payload.gamePassId) or 0) or 0,
        skinId = type(payload) == "table" and math.floor(tonumber(payload.skinId) or 0) or 0,
        intent = type(payload) == "table" and tostring(payload.intent or payload.eventType or "") or "",
    }
end

function ShopService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function ShopService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function ShopService:_trackPurchaseFunnel(player, funnelName, stepNumber, stepName, payload)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackFunnel) then
        return
    end

    self._gameAnalyticsService:TrackFunnel(player, funnelName, stepNumber, stepName, buildPurchaseFields(payload))
end

function ShopService:_ownsGamePass(player, gamePassId)
    local resolvedGamePassId = math.floor(tonumber(gamePassId) or 0)
    if resolvedGamePassId <= 0 then
        return false, "InvalidGamePass"
    end

    local ok, owns = pcall(function()
        return MarketplaceService:UserOwnsGamePassAsync(player.UserId, resolvedGamePassId)
    end)
    if not ok then
        warn("[ShopService] UserOwnsGamePassAsync failed: " .. tostring(owns))
        return false, "OwnershipCheckFailed"
    end
    return owns == true, owns == true and "Owned" or "NotOwned"
end

function ShopService:BuildStatePayload(player)
    local claimKey = ShopConfig.StarterPack.ClaimKey
    local starterPackClaimed = self._playerStateService
        and self._playerStateService.HasShopClaim
        and self._playerStateService:HasShopClaim(player, claimKey) == true
        or false
    local featuredSkinOwned = false
    if self._playerStateService and self._playerStateService.OwnsSkin then
        local ok, owns = pcall(function()
            return self._playerStateService:OwnsSkin(player, ShopConfig.FeaturedSkinId)
        end)
        featuredSkinOwned = ok and owns == true or false
    end

    return {
        starterPackClaimed = starterPackClaimed,
        starterPackGamePassId = ShopConfig.StarterPack.GamePassId,
        featuredSkinId = ShopConfig.FeaturedSkinId,
        featuredSkinOwned = featuredSkinOwned,
        timestamp = os.clock(),
    }
end

function ShopService:SyncState(player)
    if not (self._shopStateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._shopStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
end

function ShopService:_fireRewardFeedback(player, source, rewards, reason)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardGranted",
        source = tostring(source or "Shop"),
        reason = tostring(reason or "Granted"),
        rewards = ShopConfig.CopyRewardsForClient(rewards),
        state = self:BuildStatePayload(player),
        timestamp = os.clock(),
    })
end

function ShopService:_grantStarterPack(player, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end

    local claimKey = ShopConfig.StarterPack.ClaimKey
    if self._playerStateService:HasShopClaim(player, claimKey) then
        self:SyncState(player)
        return true, "AlreadyClaimed"
    end

    local userId = getUserId(player)
    if self._starterPackGrantInProgressByUserId[userId] then
        return false, "Busy"
    end
    self._starterPackGrantInProgressByUserId[userId] = true

    local grantedRewards = {}
    for _, reward in ipairs(ShopConfig.StarterPack.Rewards) do
        local rewardType = tostring(reward.RewardType or "")
        if rewardType == "Potion" then
            if not (self._potionService and self._potionService.AddPotion) then
                self._starterPackGrantInProgressByUserId[userId] = nil
                return false, "PotionServiceUnavailable"
            end
            local success, reason = self._potionService:AddPotion(player, reward.PotionId, reward.Amount or 1, {
                source = "shop",
                productGroup = "StarterPack",
                itemSku = "StarterPackPotion_" .. tostring(reward.PotionId or "Unknown"),
            })
            if not success then
                self._starterPackGrantInProgressByUserId[userId] = nil
                return false, reason or "PotionGrantFailed"
            end
        elseif rewardType == "WheelSpins" then
            self._playerStateService:AddWheelSpins(player, reward.Amount or 0, {
                source = "shop",
                productGroup = "StarterPack",
                itemSku = "StarterPackWheelSpins",
            })
        elseif rewardType == "Diamonds" then
            self._playerStateService:AddDiamonds(player, reward.Amount or 0, {
                source = "shop",
                productGroup = "StarterPack",
                itemSku = "StarterPackDiamonds",
            })
        end
        table.insert(grantedRewards, reward)
    end

    self._playerStateService:MarkShopClaim(player, claimKey)
    self:_markDirty(player)
    self._starterPackGrantInProgressByUserId[userId] = nil
    self:SyncState(player)
    self:_fireRewardFeedback(player, source or "Shop", grantedRewards, "StarterPack")
    self:_trackPurchaseFunnel(player, "ShopPurchase", 6, "RewardDelivered", {
        source = source or "Shop",
        purchaseType = "StarterPack",
        gamePassId = ShopConfig.StarterPack.GamePassId,
        productGroup = "StarterPack",
        itemSku = tostring(ShopConfig.StarterPack.GamePassId),
    })
    return true, "Granted"
end

function ShopService:_queueStarterPackRetry(player, source)
    task.spawn(function()
        local deadline = os.clock() + 15
        while player and player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
            task.wait(0.5)
        end
        if player and player.Parent then
            self:_grantStarterPack(player, source or "Shop")
        end
    end)
end

function ShopService:_tryAutoClaimStarterPack(player, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false
    end
    if not self:_isPlayerLoaded(player) then
        return false
    end
    if self._playerStateService:HasShopClaim(player, ShopConfig.StarterPack.ClaimKey) then
        self:SyncState(player)
        return false
    end

    local owns = self:_ownsGamePass(player, ShopConfig.StarterPack.GamePassId)
    if owns then
        self:_grantStarterPack(player, source or "Shop")
        return true
    end

    self:SyncState(player)
    return false
end

function ShopService:_handleStateRequest(player, payload)
    if type(payload) == "table" and tostring(payload.intent or "") == "ShopOpened" then
        self:_trackPurchaseFunnel(player, "ShopPurchase", 1, "ShopOpened", payload)
    end

    if type(payload) == "table" and payload.autoClaimStarterPack == true then
        self:_tryAutoClaimStarterPack(player, payload.source or "Shop")
        return
    end
    self:SyncState(player)
end

function ShopService:_handleStarterPackClaimRequest(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:SyncState(player)
        return
    end

    if self._playerStateService and self._playerStateService:HasShopClaim(player, ShopConfig.StarterPack.ClaimKey) then
        self:SyncState(player)
        return
    end

    local owns = self:_ownsGamePass(player, ShopConfig.StarterPack.GamePassId)
    if owns then
        self:_grantStarterPack(player, "Shop")
    else
        self:SyncState(player)
    end
end

function ShopService:_handleGamePassFinished(player, gamePassId, wasPurchased)
    if wasPurchased ~= true then
        return
    end
    if math.floor(tonumber(gamePassId) or 0) ~= ShopConfig.StarterPack.GamePassId then
        return
    end
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self:_trackPurchaseFunnel(player, "ShopPurchase", 5, "ProductReceiptGranted", {
        source = "Shop",
        purchaseType = "StarterPack",
        gamePassId = ShopConfig.StarterPack.GamePassId,
        productGroup = "StarterPack",
        itemSku = tostring(gamePassId),
    })

    local success, reason = self:_grantStarterPack(player, "Shop")
    if not success and reason == "DataLoading" then
        self:_queueStarterPackRetry(player, "Shop")
    end
end

function ShopService:RecordPurchaseContext(player, payload)
    if not (ActorUtils.IsPlayer(player) and player.Parent and type(payload) == "table") then
        return false
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end

    self._purchaseContextByUserId[userId] = {
        source = tostring(payload.source or "Shop"),
        purchaseType = tostring(payload.purchaseType or ""),
        productId = math.floor(tonumber(payload.productId) or 0),
        gamePassId = math.floor(tonumber(payload.gamePassId) or 0),
        skinId = math.floor(tonumber(payload.skinId) or 0),
        intent = tostring(payload.intent or payload.eventType or ""),
        productGroup = tostring(payload.productGroup or ""),
        itemSku = tostring(payload.itemSku or ""),
        expiresAt = os.clock() + PURCHASE_CONTEXT_TTL_SECONDS,
    }
    return true
end

function ShopService:_consumePurchaseContext(player, matcher)
    local userId = getUserId(player)
    local context = userId > 0 and self._purchaseContextByUserId[userId] or nil
    if not context then
        return nil
    end
    if tonumber(context.expiresAt) and os.clock() > context.expiresAt then
        self._purchaseContextByUserId[userId] = nil
        return nil
    end
    if type(matcher) == "function" and matcher(context) ~= true then
        return nil
    end

    self._purchaseContextByUserId[userId] = nil
    return context
end

function ShopService:NotifyWheelPurchase(player, productId)
    local purchase = WheelConfig.GetPurchaseByProductId(productId)
    if not purchase then
        return false
    end

    local context = self:_consumePurchaseContext(player, function(candidate)
        return candidate.purchaseType == "WheelSpins" and candidate.productId == tonumber(productId)
    end)
    local source = context and context.source or "Wheel"
    self:_fireRewardFeedback(player, source, {
        { RewardType = "WheelSpins", Amount = purchase.Spins },
    }, "WheelPurchase")
    return true
end

function ShopService:NotifySkinPurchase(player, skinId, gamePassId)
    local skin = SkinConfig.GetSkin(skinId)
    if not skin then
        return false
    end

    local context = self:_consumePurchaseContext(player, function(candidate)
        return candidate.purchaseType == "Skin"
            and (candidate.skinId == tonumber(skinId) or candidate.gamePassId == tonumber(gamePassId))
    end)
    if not context then
        return false
    end

    self:_trackPurchaseFunnel(player, "ShopPurchase", 6, "RewardDelivered", {
        source = context.source or "Shop",
        purchaseType = "Skin",
        skinId = skin.Id,
        gamePassId = gamePassId,
        productGroup = "GamePassSkin",
        itemSku = tostring(gamePassId or skin.Id),
    })

    self:_fireRewardFeedback(player, context.source or "Shop", {
        { RewardType = "Skin", SkinId = skin.Id, Amount = 1, Icon = skin.IconImage, Label = skin.Name },
    }, "SkinPurchase")
    return true
end

function ShopService:_grantDiamondProduct(player, product, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService and product) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end

    local productId = math.floor(tonumber(product.ProductId) or 0)
    local diamonds = math.max(0, math.floor(tonumber(product.Diamonds) or 0))
    if productId <= 0 or diamonds <= 0 then
        return false, "InvalidProduct"
    end

    self._playerStateService:AddDiamonds(player, diamonds, {
        source = "shop",
        productGroup = "DiamondPack",
        itemSku = tostring(productId),
        productId = productId,
    })
    self:_markDirty(player)
    self:SyncState(player)
    self:_fireRewardFeedback(player, source or "Shop", {
        { RewardType = "Diamonds", Amount = diamonds },
    }, "DiamondPack")
    return true, "Granted"
end

function ShopService:ProcessReceipt(receiptInfo)
    local productId = math.floor(tonumber(receiptInfo and receiptInfo.ProductId) or 0)
    local product = ShopConfig.GetDiamondProductByProductId(productId)
    if not product then
        return false, nil
    end

    local player = Players:GetPlayerByUserId(math.floor(tonumber(receiptInfo.PlayerId) or 0))
    if not player then
        return true, Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local context = self:_consumePurchaseContext(player, function(candidate)
        return candidate.purchaseType == "Diamonds" and candidate.productId == productId
    end)
    local source = context and context.source or "Shop"
    local success = self:_grantDiamondProduct(player, product, source)
    if success then
        self:_trackPurchaseFunnel(player, "ShopPurchase", 5, "ProductReceiptGranted", {
            source = source,
            purchaseType = "Diamonds",
            productGroup = "DiamondPack",
            itemSku = tostring(productId),
            productId = productId,
        })
        self:_trackPurchaseFunnel(player, "ShopPurchase", 6, "RewardDelivered", {
            source = source,
            purchaseType = "Diamonds",
            productGroup = "DiamondPack",
            itemSku = tostring(productId),
            productId = productId,
        })
    end

    return true, success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
end

function ShopService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function ShopService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._potionService = dependencies and dependencies.PotionService or nil
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or nil
    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._shopStateSyncEvent = remoteEventService and remoteEventService:GetEvent("ShopStateSync") or nil
    self._requestShopStateSyncEvent = remoteEventService and remoteEventService:GetEvent("RequestShopStateSync") or nil
    self._requestStarterPackClaimEvent = remoteEventService and remoteEventService:GetEvent("RequestShopStarterPackClaim") or nil
    self._requestPurchaseContextEvent = remoteEventService and remoteEventService:GetEvent("RequestShopPurchaseContext") or nil
    self._shopRewardFeedbackEvent = remoteEventService and remoteEventService:GetEvent("ShopRewardFeedback") or nil
    self._purchaseContextByUserId = {}
    self._starterPackGrantInProgressByUserId = {}

    disconnectAll(self._connections)
    if self._requestShopStateSyncEvent then
        table.insert(self._connections, self._requestShopStateSyncEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleStateRequest(player, payload)
        end))
    end
    if self._requestStarterPackClaimEvent then
        table.insert(self._connections, self._requestStarterPackClaimEvent.OnServerEvent:Connect(function(player)
            self:_handleStarterPackClaimRequest(player)
        end))
    end
    if self._requestPurchaseContextEvent then
        table.insert(self._connections, self._requestPurchaseContextEvent.OnServerEvent:Connect(function(player, payload)
            self:RecordPurchaseContext(player, payload)
            local intent = type(payload) == "table" and tostring(payload.intent or payload.eventType or "") or ""
            if intent == "ProductViewed" then
                self:_trackPurchaseFunnel(player, "ShopPurchase", 2, "ProductViewed", payload)
            elseif intent == "BuyClicked" then
                self:_trackPurchaseFunnel(player, "ShopPurchase", 3, "BuyClicked", payload)
            elseif intent == "PurchasePromptRequested" then
                self:_trackPurchaseFunnel(player, "ShopPurchase", 4, "PurchasePromptRequested", payload)
            elseif intent == "PaidSpinPurchaseClicked" then
                self:_trackPurchaseFunnel(player, "WheelFlow", 5, "PaidSpinPurchaseClicked", payload)
            elseif intent == "SkinPanelOpened" then
                self:_trackPurchaseFunnel(player, "SkinFlow", 1, "SkinPanelOpened", payload)
            elseif intent == "SkinEquipClicked" then
                self:_trackPurchaseFunnel(player, "SkinFlow", 4, "SkinEquipClicked", payload)
            end
        end))
    end
    table.insert(self._connections, MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
        self:_handleGamePassFinished(player, gamePassId, wasPurchased)
    end))
end

function ShopService:OnPlayerAdded(player)
    task.defer(function()
        if player and player.Parent then
            self:SyncState(player)
        end
    end)
end

function ShopService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    self._purchaseContextByUserId[userId] = nil
    self._starterPackGrantInProgressByUserId[userId] = nil
end

return ShopService
