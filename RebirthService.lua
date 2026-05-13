--[[
脚本名字: RebirthService
脚本文件: RebirthService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/RebirthService
说明: 管理重生积分、重生请求、付费重生和 Rebirth 数据持久化。
]]

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
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
        "[RebirthService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local PotionConfig = requireSharedModule("PotionConfig")
local WheelConfig = requireSharedModule("WheelConfig")
local SkinConfig = requireSharedModule("SkinConfig")

local RebirthService = {}

RebirthService._playerStateService = nil
RebirthService._requestRebirthEvent = nil
RebirthService._rebirthFeedbackEvent = nil
RebirthService._healthService = nil
RebirthService._respawnService = nil
RebirthService._nukeService = nil
RebirthService._potionService = nil
RebirthService._wheelService = nil
RebirthService._dataStore = nil
RebirthService._dirtyByUserId = {}
RebirthService._loadedByUserId = {}
RebirthService._loadStateByUserId = {}
RebirthService._loadRetryClockByUserId = {}
RebirthService._heartbeatConnection = nil
RebirthService._nextSaveClock = 0

local function getUserId(player)
    return player and player.UserId or 0
end

local function getDataKey(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or tonumber(playerOrUserId)
    return tostring(userId or 0)
end

local function normalizeSavedData(data)
    if type(data) ~= "table" then
        return 0, 0, GameConfig.PLAYER.BaseLevel, {}
    end

    local rebirth = math.max(0, math.floor(tonumber(data.rebirth) or tonumber(data.Rebirth) or 0))
    local rebirthScore = math.max(0, math.floor(tonumber(data.rebirthScore) or tonumber(data.RebirthScore) or 0))
    local highestLevelReached = math.clamp(
        math.floor(tonumber(data.highestLevelReached) or tonumber(data.HighestLevelReached) or GameConfig.PLAYER.BaseLevel),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )

    local potions = {}
    local savedPotions = type(data.potions) == "table" and data.potions or data.Potions
    if type(savedPotions) == "table" then
        for potionId, count in pairs(savedPotions) do
            local potion = PotionConfig.GetPotion(potionId)
            local resolvedCount = math.max(0, math.floor(tonumber(count) or 0))
            if potion and resolvedCount > 0 then
                potions[tostring(potion.Id)] = resolvedCount
            end
        end
    end

    local groupRewards = {}
    local savedGroupRewards = type(data.groupRewards) == "table" and data.groupRewards or data.GroupRewards
    if type(savedGroupRewards) == "table" then
        for groupId, claimed in pairs(savedGroupRewards) do
            local resolvedGroupId = math.floor(tonumber(groupId) or 0)
            if resolvedGroupId > 0 and claimed == true then
                groupRewards[tostring(resolvedGroupId)] = true
            end
        end
    end

    local subscriptionClaims = {}
    local savedSubscriptionClaims = type(data.subscriptionClaims) == "table" and data.subscriptionClaims or data.SubscriptionClaims
    if type(savedSubscriptionClaims) == "table" then
        for subscriptionId, utcDay in pairs(savedSubscriptionClaims) do
            local key = tostring(subscriptionId or "")
            local day = tostring(utcDay or "")
            if key ~= "" and day ~= "" then
                subscriptionClaims[key] = day
            end
        end
    end

    local ownedSkins = {}
    local savedOwnedSkins = type(data.ownedSkins) == "table" and data.ownedSkins or data.OwnedSkins
    if type(savedOwnedSkins) == "table" then
        for skinKey, owned in pairs(savedOwnedSkins) do
            local skinId = owned == true and math.floor(tonumber(skinKey) or 0) or math.floor(tonumber(owned) or 0)
            if skinId > 0 and SkinConfig.GetSkin(skinId) and (owned == true or tonumber(owned) ~= nil) then
                ownedSkins[tostring(skinId)] = true
            end
        end
    end

    local equippedSkinId = math.floor(tonumber(data.equippedSkinId) or tonumber(data.EquippedSkinId) or 0)
    if equippedSkinId <= 0 or not (SkinConfig.GetSkin(equippedSkinId) and ownedSkins[tostring(equippedSkinId)] == true) then
        equippedSkinId = nil
    end

    local function normalizeWeaponUnlockRewards(rewards)
        if type(rewards) ~= "table" then
            return nil
        end

        local normalized = {
            ClaimedTiers = {},
            PendingQueue = {},
        }
        local claimedTiers = rewards.claimedTiers or rewards.ClaimedTiers or rewards.claimed or rewards.Claimed
        if type(claimedTiers) == "table" then
            for tierKey, claimed in pairs(claimedTiers) do
                local tierIndex = math.floor(tonumber(tierKey) or tonumber(claimed) or 0)
                if tierIndex > 0 and (claimed == true or tonumber(claimed) ~= nil) then
                    normalized.ClaimedTiers[tostring(tierIndex)] = true
                end
            end
        end

        local pendingQueue = rewards.pendingQueue or rewards.PendingQueue or rewards.pendingTiers or rewards.PendingTiers
        if type(pendingQueue) == "table" then
            local seen = {}
            for _, pendingTier in ipairs(pendingQueue) do
                local tierIndex = math.floor(tonumber(pendingTier) or 0)
                local key = tostring(tierIndex)
                if tierIndex > 1 and normalized.ClaimedTiers[key] ~= true and seen[key] ~= true then
                    seen[key] = true
                    table.insert(normalized.PendingQueue, tierIndex)
                end
            end
            table.sort(normalized.PendingQueue)
        end

        return normalized
    end

    local function normalizeSavedActivePotion(activePotion, fallbackPotionId)
        if type(activePotion) ~= "table" then
            return nil
        end

        local potion = PotionConfig.GetPotion(activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId or fallbackPotionId)
        local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
        if potion and expiresAt > os.time() then
            return {
                Id = potion.Id,
                StartedAt = tonumber(activePotion.StartedAt or activePotion.startedAt) or os.time(),
                ExpiresAt = expiresAt,
                ExperienceBonus = math.max(0, tonumber(activePotion.ExperienceBonus or activePotion.experienceBonus) or tonumber(potion.ExperienceBonus) or 0),
                MoveSpeedBonus = math.max(0, tonumber(activePotion.MoveSpeedBonus or activePotion.moveSpeedBonus) or tonumber(potion.MoveSpeedBonus) or 0),
                Source = tostring(activePotion.Source or activePotion.source or "Saved"),
            }
        end

        return nil
    end

    local activePotions = {}
    local savedActivePotions = type(data.activePotions) == "table" and data.activePotions or data.ActivePotions
    if type(savedActivePotions) == "table" then
        for potionId, activePotion in pairs(savedActivePotions) do
            local normalizedPotion = normalizeSavedActivePotion(activePotion, potionId)
            if normalizedPotion then
                activePotions[tostring(normalizedPotion.Id)] = normalizedPotion
            end
        end
    end

    local savedActivePotion = type(data.activePotion) == "table" and data.activePotion or data.ActivePotion
    local legacyActivePotion = normalizeSavedActivePotion(savedActivePotion)
    if legacyActivePotion and not activePotions[tostring(legacyActivePotion.Id)] then
        activePotions[tostring(legacyActivePotion.Id)] = legacyActivePotion
    end

    return rebirth, rebirthScore, highestLevelReached, {
        diamonds = math.max(0, math.floor(tonumber(data.diamonds) or tonumber(data.Diamonds) or 0)),
        wheelSpins = math.max(0, math.floor(tonumber(data.wheelSpins) or tonumber(data.WheelSpins) or 0)),
        potions = potions,
        groupRewards = groupRewards,
        subscriptionClaims = subscriptionClaims,
        ownedSkins = ownedSkins,
        equippedSkinId = equippedSkinId,
        weaponUnlockRewards = normalizeWeaponUnlockRewards(data.weaponUnlockRewards or data.WeaponUnlockRewards),
        activePotions = activePotions,
        activePotion = legacyActivePotion,
    }
end

function RebirthService:_fireFeedback(player, eventType, message)
    if not (self._rebirthFeedbackEvent and player and player.Parent) then
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    self._rebirthFeedbackEvent:FireClient(player, {
        eventType = eventType,
        message = message,
        rebirth = state and state.Rebirth or 0,
        rebirthScore = state and state.RebirthScore or 0,
        nextRebirthScore = state and GameConfig.GetRequiredRebirthScore(state.Rebirth) or GameConfig.GetRequiredRebirthScore(0),
        timestamp = os.clock(),
    })
end

function RebirthService:MarkDirty(actor)
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local userId = getUserId(actor)
    if userId > 0 and self:CanWritePersistentProgress(actor) then
        self._dirtyByUserId[userId] = true
    end
end

function RebirthService:IsPlayerLoaded(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end
    return self._loadStateByUserId[userId] == "Loaded"
end

function RebirthService:CanWritePersistentProgress(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end
    return self._loadStateByUserId[userId] == "Loaded"
end

function RebirthService:_loadPlayer(player)
    if not (player and player.Parent and self._playerStateService) then
        return
    end

    local userId = getUserId(player)
    if userId <= 0 or self._loadedByUserId[userId] then
        return
    end
    self._loadedByUserId[userId] = true
    self._loadStateByUserId[userId] = "Pending"

    if not self._dataStore then
        self._playerStateService:SetRebirthData(player, 0, 0, GameConfig.PLAYER.BaseLevel, {})
        self._loadStateByUserId[userId] = "Loaded"
        self._loadRetryClockByUserId[userId] = nil
        return
    end

    local success, data = pcall(function()
        return self._dataStore:GetAsync(getDataKey(player))
    end)
    if not success then
        warn("[RebirthService] 读取 Rebirth 数据失败: " .. tostring(player.Name))
        self._loadedByUserId[userId] = nil
        self._loadStateByUserId[userId] = "LoadFailed"
        self._loadRetryClockByUserId[userId] = os.clock() + 5
        return
    end

    local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(data)
    self._playerStateService:SetRebirthData(player, rebirth, rebirthScore, highestLevelReached, savedProgress)
    self._dirtyByUserId[userId] = nil
    self._loadStateByUserId[userId] = "Loaded"
    self._loadRetryClockByUserId[userId] = nil
end

function RebirthService:_savePlayer(player)
    if not (player and self._dataStore and self._playerStateService) then
        return false
    end

    if not self:CanWritePersistentProgress(player) then
        return false
    end

    local state = self._playerStateService:GetState(player)
    local payload = {
        rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0)),
        rebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0)),
        highestLevelReached = math.max(1, math.floor(tonumber(state.HighestLevelReached) or GameConfig.PLAYER.BaseLevel)),
        diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0)),
        wheelSpins = math.max(0, math.floor(tonumber(state.WheelSpins) or 0)),
        potions = state.Potions or {},
        groupRewards = state.GroupRewards or {},
        subscriptionClaims = state.SubscriptionClaims or {},
        ownedSkins = state.OwnedSkins or {},
        equippedSkinId = state.EquippedSkinId,
        weaponUnlockRewards = state.WeaponUnlockRewards or {},
        activePotions = self._playerStateService:GetActivePotions(player),
        activePotion = self._playerStateService:GetActivePotion(player),
        updatedAt = os.time(),
    }

    local success = pcall(function()
        self._dataStore:SetAsync(getDataKey(player), payload)
    end)
    if success then
        self._dirtyByUserId[getUserId(player)] = nil
    else
        warn("[RebirthService] 保存 Rebirth 数据失败: " .. tostring(player.Name))
    end
    return success
end

function RebirthService:_saveDirtyPlayers()
    for userId in pairs(self._dirtyByUserId) do
        local player = Players:GetPlayerByUserId(userId)
        if player then
            self:_savePlayer(player)
        else
            self._dirtyByUserId[userId] = nil
        end
    end
end

function RebirthService:_step()
    local now = os.clock()
    for userId, retryClock in pairs(self._loadRetryClockByUserId) do
        if retryClock and now >= retryClock then
            local player = Players:GetPlayerByUserId(userId)
            if player then
                self:_loadPlayer(player)
            else
                self._loadRetryClockByUserId[userId] = nil
            end
        end
    end
    if now < self._nextSaveClock then
        return
    end

    self._nextSaveClock = now + math.max(5, tonumber(GameConfig.REBIRTH.AutoSaveIntervalSeconds) or 30)
    self:_saveDirtyPlayers()
end

function RebirthService:TryRebirth(player, options)
    if not (player and player.Parent and self._playerStateService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return false
    end

    local paid = options and options.paid == true
    if not paid and not self._playerStateService:CanRebirth(player) then
        self:_fireFeedback(player, "Failed", "Requirement not met")
        return false
    end

    local state = self._playerStateService:ApplyRebirth(player, not paid)
    self:MarkDirty(player)
    self:_savePlayer(player)
    self:_fireFeedback(player, paid and "PaidSuccess" or "Success")
    return true, state
end

function RebirthService:_processDoubleLevel(player)
    if not (player and player.Parent and self._playerStateService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    local multiplier = GameConfig.MONETIZATION and GameConfig.MONETIZATION.DoubleLevelMultiplier or 2
    local success, newLevel = self._playerStateService:ApplyLevelMultiplier(player, multiplier)
    if success then
        print(string.format("[RebirthService] Double level granted to %s, newLevel=%d", player.Name, newLevel))
        return true
    end
    return false
end

function RebirthService:_processNuke(player)
    if not (player and player.Parent and self._nukeService) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    local queued = self._nukeService:RequestNuke(player)
    if queued then
        print(string.format("[RebirthService] Nuke queued for %s", player.Name))
    end
    return queued
end

function RebirthService:_processRevenge(player)
    if not (player and player.Parent and self._respawnService) then
        return false
    end

    local defeatRecord = self._respawnService:GetDefeatRecord(player)
    if self._respawnService.IsCurrentDefeatRecord
        and not self._respawnService:IsCurrentDefeatRecord(player, defeatRecord)
    then
        return false
    end
    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not (state and state.Alive == false and defeatRecord and defeatRecord.deathSerial) then
        return false
    end

    local killerUserId = defeatRecord and tonumber(defeatRecord.killerUserId) or nil
    if not (killerUserId and killerUserId > 0 and self._healthService) then
        return false
    end

    local killerPlayer = Players:GetPlayerByUserId(killerUserId)
    if not killerPlayer then
        return false
    end

    local didKill = false
    if self._healthService.KillActor then
        didKill = select(2, self._healthService:KillActor(killerPlayer, player))
    else
        didKill = select(2, self._healthService:ApplyWeaponDamage(killerPlayer, GameConfig.MONETIZATION.NukeDamage, player))
    end
    if not didKill then
        return false
    end

    self._respawnService:RevivePlayer(player)
    print(string.format("[RebirthService] Revenge granted to %s against %s", player.Name, killerPlayer.Name))
    return true
end

function RebirthService:_processWheelPurchase(player, productId)
    if not (player and player.Parent and self._wheelService and self._wheelService.GrantPurchasedSpins) then
        return false
    end
    if not self:CanWritePersistentProgress(player) then
        return false
    end

    return self._wheelService:GrantPurchasedSpins(player, productId)
end

function RebirthService:_processReceipt(receiptInfo)
    local productId = receiptInfo.ProductId
    local wheelPurchase = WheelConfig.GetPurchaseByProductId(productId)
    if wheelPurchase then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processWheelPurchase(player, productId)
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    local potion = PotionConfig.GetPotionByProductId(productId)
    if potion then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self._potionService and self._potionService:GrantRobuxPotion(player, productId)
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if productId == GameConfig.REBIRTH.PaidRebirthProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:TryRebirth(player, { paid = true })
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.DoubleLevelProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processDoubleLevel(player)
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.NukeProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processNuke(player)
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    if GameConfig.MONETIZATION and productId == GameConfig.MONETIZATION.RevengeProductId then
        local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
        if not player then
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local success = self:_processRevenge(player)
        return success and Enum.ProductPurchaseDecision.PurchaseGranted or Enum.ProductPurchaseDecision.NotProcessedYet
    end

    return Enum.ProductPurchaseDecision.NotProcessedYet
end

function RebirthService:BindSystems(dependencies)
    self._healthService = dependencies and dependencies.HealthService or self._healthService
    self._respawnService = dependencies and dependencies.RespawnService or self._respawnService
    self._nukeService = dependencies and dependencies.NukeService or self._nukeService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._wheelService = dependencies and dependencies.WheelService or self._wheelService
end

function RebirthService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._requestRebirthEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestRebirth") or nil
    self._rebirthFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RebirthFeedback") or nil
    self._healthService = dependencies.HealthService or self._healthService
    self._respawnService = dependencies.RespawnService or self._respawnService
    self._nukeService = dependencies.NukeService or self._nukeService
    self._potionService = dependencies.PotionService or self._potionService
    self._wheelService = dependencies.WheelService or self._wheelService
    self._dirtyByUserId = {}
    self._loadedByUserId = {}
    self._loadStateByUserId = {}
    self._loadRetryClockByUserId = {}
    self._nextSaveClock = os.clock() + math.max(5, tonumber(GameConfig.REBIRTH.AutoSaveIntervalSeconds) or 30)

    local isStudio = RunService:IsStudio()
    local success, store = false, nil
    if GameConfig.ShouldUsePersistentDataStores(isStudio) then
        local storeName = GameConfig.GetEnvironmentDataStoreName(GameConfig.REBIRTH.DataStoreName, isStudio)
        success, store = pcall(function()
            return DataStoreService:GetDataStore(storeName)
        end)
    end
    self._dataStore = success and store or nil
    if not self._dataStore then
        if isStudio then
            print("[RebirthService] Studio 调试模式使用内存 Rebirth 数据；发布后会使用 DataStore。")
        else
            warn("[RebirthService] DataStore 不可用，Rebirth 本次仅保存在内存中。")
        end
    end

    if self._requestRebirthEvent then
        self._requestRebirthEvent.OnServerEvent:Connect(function(player)
            self:TryRebirth(player)
        end)
    end

    MarketplaceService.ProcessReceipt = function(receiptInfo)
        return self:_processReceipt(receiptInfo)
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end
    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

function RebirthService:OnPlayerAdded(player)
    task.spawn(function()
        self:_loadPlayer(player)
    end)
end

function RebirthService:OnPlayerRemoving(player)
    self:_savePlayer(player)
    local userId = getUserId(player)
    self._dirtyByUserId[userId] = nil
    self._loadedByUserId[userId] = nil
    self._loadStateByUserId[userId] = nil
    self._loadRetryClockByUserId[userId] = nil
end

return RebirthService
