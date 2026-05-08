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

local RebirthService = {}

RebirthService._playerStateService = nil
RebirthService._requestRebirthEvent = nil
RebirthService._rebirthFeedbackEvent = nil
RebirthService._healthService = nil
RebirthService._respawnService = nil
RebirthService._nukeService = nil
RebirthService._potionService = nil
RebirthService._dataStore = nil
RebirthService._dirtyByUserId = {}
RebirthService._loadedByUserId = {}
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
        potions = potions,
        groupRewards = groupRewards,
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
    if userId > 0 then
        self._dirtyByUserId[userId] = true
    end
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

    if not self._dataStore then
        self._playerStateService:SetRebirthData(player, 0, 0, GameConfig.PLAYER.BaseLevel, {})
        self._dirtyByUserId[userId] = nil
        return
    end

    local success, data = pcall(function()
        return self._dataStore:GetAsync(getDataKey(player))
    end)
    if not success then
        warn("[RebirthService] 读取 Rebirth 数据失败: " .. tostring(player.Name))
        return
    end

    local rebirth, rebirthScore, highestLevelReached, savedProgress = normalizeSavedData(data)
    self._playerStateService:SetRebirthData(player, rebirth, rebirthScore, highestLevelReached, savedProgress)
    self._dirtyByUserId[userId] = nil
end

function RebirthService:_savePlayer(player)
    if not (player and self._dataStore and self._playerStateService) then
        return false
    end

    local state = self._playerStateService:GetState(player)
    local payload = {
        rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0)),
        rebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0)),
        highestLevelReached = math.max(1, math.floor(tonumber(state.HighestLevelReached) or GameConfig.PLAYER.BaseLevel)),
        diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0)),
        potions = state.Potions or {},
        groupRewards = state.GroupRewards or {},
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

    local multiplier = GameConfig.MONETIZATION and GameConfig.MONETIZATION.DoubleLevelMultiplier or 2
    local success, newLevel = self._playerStateService:ApplyLevelMultiplier(player, multiplier)
    if success then
        print(string.format("[RebirthService] Double level granted to %s, newLevel=%d", player.Name, newLevel))
    end
    return true
end

function RebirthService:_processNuke(player)
    if not (player and player.Parent and self._nukeService) then
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
    self._respawnService:RevivePlayer(player)

    local killerUserId = defeatRecord and tonumber(defeatRecord.killerUserId) or nil
    if killerUserId and killerUserId > 0 and self._healthService then
        local killerPlayer = Players:GetPlayerByUserId(killerUserId)
        if killerPlayer then
            local didKill = false
            if self._healthService.KillActor then
                didKill = select(2, self._healthService:KillActor(killerPlayer, player))
            else
                didKill = select(2, self._healthService:ApplyWeaponDamage(killerPlayer, GameConfig.MONETIZATION.NukeDamage, player))
            end
            if didKill then
                print(string.format("[RebirthService] Revenge granted to %s against %s", player.Name, killerPlayer.Name))
            end
        end
    end

    return true
end

function RebirthService:_processReceipt(receiptInfo)
    local productId = receiptInfo.ProductId
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
end

function RebirthService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._requestRebirthEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestRebirth") or nil
    self._rebirthFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RebirthFeedback") or nil
    self._healthService = dependencies.HealthService or self._healthService
    self._respawnService = dependencies.RespawnService or self._respawnService
    self._nukeService = dependencies.NukeService or self._nukeService
    self._potionService = dependencies.PotionService or self._potionService
    self._dirtyByUserId = {}
    self._loadedByUserId = {}
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
end

return RebirthService
