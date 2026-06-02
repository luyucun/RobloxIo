--[[
脚本名字: PotionService
脚本文件: PotionService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/PotionService
说明: V2.1 药水库存、购买、使用、GM 发放和药水反馈。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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
        "[PotionService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local PotionConfig = requireSharedModule("PotionConfig")
local GameConfig = requireSharedModule("GameConfig")

local PotionService = {}

PotionService._playerStateService = nil
PotionService._rebirthService = nil
PotionService._requestPotionActionEvent = nil
PotionService._potionFeedbackEvent = nil
PotionService._studioBotCommandEvent = nil
PotionService._requestPotionActionConnection = nil
PotionService._studioBotCommandConnection = nil
PotionService._heartbeatConnection = nil
PotionService._nextExpireCheckClock = 0
PotionService._bossPotionDropFolder = nil
PotionService._bossPotionDropsById = {}
PotionService._nextBossPotionDropId = 1

local function getPotionKey(potionId)
    local resolvedPotionId = math.floor(tonumber(potionId) or 0)
    if resolvedPotionId <= 0 then
        return nil
    end
    return tostring(resolvedPotionId)
end

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

local function getPlayerByUserId(userId)
    local resolvedUserId = math.floor(tonumber(userId) or 0)
    if resolvedUserId <= 0 then
        return nil
    end
    return Players:GetPlayerByUserId(resolvedUserId)
end

local function findOrCreateFolder(parent, folderName)
    local folder = parent:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
end

local function getBossPotionDropRuntimeFolderName()
    local bossConfig = GameConfig.BOSS or {}
    return tostring(bossConfig.PotionDropRuntimeFolderName or "BossPotionDrops")
end

local function getModelRootFolder()
    return ReplicatedStorage:FindFirstChild((GameConfig.MONSTER and GameConfig.MONSTER.ModelRootFolderName) or "Model")
end

local function getPotionTemplate(potion)
    local modelRoot = getModelRootFolder()
    local potionFolder = modelRoot and modelRoot:FindFirstChild("Potion")
    local modelName = potion and potion.ModelName
    local template = modelName and potionFolder and potionFolder:FindFirstChild(modelName)
    if template and (template:IsA("Model") or template:IsA("BasePart")) then
        return template
    end
    return nil
end

local function getBaseParts(instance)
    local parts = {}
    if instance:IsA("BasePart") then
        table.insert(parts, instance)
        return parts
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(parts, descendant)
        end
    end
    return parts
end

local function stripScripts(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        end
    end
end

local function setInstanceCFrame(instance, cframe)
    if instance:IsA("Model") then
        instance:PivotTo(cframe)
    elseif instance:IsA("BasePart") then
        instance.CFrame = cframe
    end
end

local function getBottomOffsetFromPivot(instance)
    if instance:IsA("BasePart") then
        return -instance.Size.Y * 0.5
    end
    if instance:IsA("Model") then
        local pivot = instance:GetPivot()
        local boxCFrame, boxSize = instance:GetBoundingBox()
        return (boxCFrame.Position.Y - (boxSize.Y * 0.5)) - pivot.Position.Y
    end
    return 0
end

local function chooseBossPotionId()
    local weights = GameConfig.BOSS and GameConfig.BOSS.PotionDropWeights or nil
    if type(weights) ~= "table" then
        return nil
    end

    local totalWeight = 0
    for _, entry in ipairs(weights) do
        local potion = PotionConfig.GetPotion(entry.PotionId)
        local weight = math.max(0, tonumber(entry.Weight) or 0)
        if potion and weight > 0 then
            totalWeight += weight
        end
    end
    if totalWeight <= 0 then
        return nil
    end

    local roll = math.random() * totalWeight
    local cumulative = 0
    for _, entry in ipairs(weights) do
        local potionId = tonumber(entry.PotionId)
        local potion = PotionConfig.GetPotion(potionId)
        local weight = math.max(0, tonumber(entry.Weight) or 0)
        if potion and weight > 0 then
            cumulative += weight
            if roll <= cumulative then
                return potionId
            end
        end
    end
    return nil
end

function PotionService:_fireFeedback(player, eventType, message, potionId)
    if not (self._potionFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    local payload = {
        eventType = tostring(eventType or ""),
        message = message,
        potionId = tonumber(potionId) or nil,
        timestamp = os.clock(),
    }

    if self._playerStateService then
        local state = self._playerStateService:GetState(player)
        payload.diamonds = state.Diamonds or 0
        payload.potions = state.Potions or {}
        payload.activePotions = self._playerStateService:GetActivePotions(player)
        payload.activePotion = self._playerStateService:GetActivePotion(player)
        payload.totalExperienceMultiplier = self._playerStateService:GetExperienceMultiplier(player)
    end

    self._potionFeedbackEvent:FireClient(player, payload)
end

function PotionService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function PotionService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function PotionService:_activatePotion(player, potion, source, eventType, message)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService and potion) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", potion and potion.Id)
        return false, "DataLoading"
    end

    local now = os.time()
    local state = self._playerStateService:GetState(player)
    local potionKey = getPotionKey(potion.Id)
    if not potionKey then
        self:_fireFeedback(player, "Failed", "InvalidPotion", potion and potion.Id)
        return false, "InvalidPotion"
    end

    state.ActivePotions = self._playerStateService:GetActivePotions(player)
    local currentActivePotion = state.ActivePotions[potionKey]
    local durationSeconds = math.max(1, math.floor(tonumber(potion.DurationSeconds) or 1))
    local startedAt = currentActivePotion and tonumber(currentActivePotion.StartedAt) or now
    local baseExpiresAt = math.max(now, currentActivePotion and tonumber(currentActivePotion.ExpiresAt) or 0)

    state.ActivePotions[potionKey] = {
        Id = potion.Id,
        StartedAt = startedAt,
        ExpiresAt = baseExpiresAt + durationSeconds,
        ExperienceBonus = math.max(0, tonumber(potion.ExperienceBonus) or 0),
        MoveSpeedBonus = math.max(0, tonumber(potion.MoveSpeedBonus) or 0),
        Source = tostring(source or "UsePotion"),
    }
    state.ActivePotion = nil

    self._playerStateService:SyncCharacterState(player)
    self._playerStateService:PushState(player)
    self:_markDirty(player)
    self:_fireFeedback(player, eventType or "Activated", message or "PotionActivated", potion.Id)
    return true, state.ActivePotions[potionKey]
end

function PotionService:AddPotion(player, potionId, amount, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", potionId)
        return false, "DataLoading"
    end

    local potion = PotionConfig.GetPotion(potionId)
    if not potion then
        self:_fireFeedback(player, "Failed", "InvalidPotion", potionId)
        return false, "InvalidPotion"
    end

    local count = math.max(1, math.floor(tonumber(amount) or 1))
    local state = self._playerStateService:GetState(player)
    state.Potions = state.Potions or {}

    local potionKey = getPotionKey(potion.Id)
    state.Potions[potionKey] = math.max(0, math.floor(tonumber(state.Potions[potionKey]) or 0)) + count
    self._playerStateService:PushState(player)
    self:_markDirty(player)
    self:_fireFeedback(player, "Added", source or "PotionAdded", potion.Id)
    return true, state.Potions[potionKey]
end

function PotionService:_createBossPotionDropFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    return findOrCreateFolder(runtimeRoot, getBossPotionDropRuntimeFolderName())
end

function PotionService:_clearBossPotionDropFolder()
    if not self._bossPotionDropFolder then
        return
    end
    for _, child in ipairs(self._bossPotionDropFolder:GetChildren()) do
        child:Destroy()
    end
end

function PotionService:_destroyBossPotionDrop(dropState)
    if not dropState then
        return
    end
    if dropState.TouchConnections then
        for _, connection in ipairs(dropState.TouchConnections) do
            disconnectConnection(connection)
        end
        dropState.TouchConnections = nil
    end
    if dropState.RuntimeInstance and dropState.RuntimeInstance.Parent then
        dropState.RuntimeInstance:Destroy()
    end
    self._bossPotionDropsById[dropState.Id] = nil
end

function PotionService:_setBossPotionDropTouchEnabled(dropState, enabled)
    if not dropState or dropState.TouchEnabled == enabled then
        return
    end

    for _, part in ipairs(dropState.Parts or {}) do
        if part and part.Parent then
            part.CanTouch = enabled
        end
    end
    dropState.TouchEnabled = enabled
end

function PotionService:_handleBossPotionDropTouched(dropId, hit)
    local dropState = self._bossPotionDropsById[tostring(dropId or "")]
    if not dropState or dropState.Collected then
        return
    end
    if os.clock() < (dropState.FallEndClock or 0) then
        return
    end
    if not (hit and hit:IsA("BasePart")) then
        return
    end

    local player = dropState.TargetPlayer
    local character = player and player.Character
    if not (ActorUtils.IsPlayer(player) and player.Parent and character and hit:IsDescendantOf(character)) then
        return
    end

    dropState.Collected = true
    local success = self:AddPotion(player, dropState.PotionId, 1, dropState.Source or "BossDrop")
    if success then
        self:_destroyBossPotionDrop(dropState)
    else
        dropState.Collected = false
    end
end

function PotionService:_spawnBossPotionDropVisual(position, player, potion, source)
    if not (self._bossPotionDropFolder and typeof(position) == "Vector3" and ActorUtils.IsPlayer(player) and potion) then
        return nil
    end

    local template = getPotionTemplate(potion)
    if not template then
        warn(string.format("[PotionService] Boss 药水掉落缺少模板：%s", tostring(potion.ModelName)))
        return nil
    end

    local dropId = tostring(self._nextBossPotionDropId)
    self._nextBossPotionDropId += 1

    local runtimePotion = template:Clone()
    runtimePotion.Name = string.format("BossPotionDrop_%s_%s", tostring(potion.Id), dropId)
    stripScripts(runtimePotion)

    local parts = getBaseParts(runtimePotion)
    for _, part in ipairs(parts) do
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.Massless = true
    end

    local angle = math.random() * math.pi * 2
    local radius = 3 + (math.random() * 2)
    local bottomOffsetFromPivot = getBottomOffsetFromPivot(runtimePotion)
    local groundBottomPosition = position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
    local groundPosition = groundBottomPosition - Vector3.new(0, bottomOffsetFromPivot, 0)
    local spawnPosition = groundPosition + Vector3.new(0, math.max(1, tonumber(GameConfig.EXPERIENCE.DropFallHeight) or 4), 0)
    setInstanceCFrame(runtimePotion, CFrame.new(spawnPosition))
    runtimePotion.Parent = self._bossPotionDropFolder

    local now = os.clock()
    local fallSeconds = math.max(0.05, tonumber(GameConfig.EXPERIENCE.DropFallSeconds) or 0.35)

    local dropState = {
        Id = dropId,
        RuntimeInstance = runtimePotion,
        TargetPlayer = player,
        PotionId = potion.Id,
        Source = tostring(source or "BossDrop"),
        SpawnClock = now,
        FallEndClock = now + fallSeconds,
        ExpireClock = now + math.max(2, tonumber(GameConfig.BOSS and GameConfig.BOSS.PotionDropMaxLifetimeSeconds) or 12),
        SpawnCFrame = CFrame.new(spawnPosition),
        GroundCFrame = CFrame.new(groundPosition),
        Parts = parts,
        TouchConnections = {},
        TouchEnabled = false,
        Collected = false,
    }

    runtimePotion:SetAttribute("BossPotionDropId", dropId)
    runtimePotion:SetAttribute("PotionId", potion.Id)
    runtimePotion:SetAttribute("OwnerUserId", player.UserId)
    self._bossPotionDropsById[dropId] = dropState

    for _, part in ipairs(parts) do
        table.insert(dropState.TouchConnections, part.Touched:Connect(function(hit)
            self:_handleBossPotionDropTouched(dropId, hit)
        end))
    end

    return dropState
end

function PotionService:DropBossPotionForPlayer(position, player, source)
    if not (GameConfig.BOSS and GameConfig.BOSS.PotionDropEnabled == true) then
        return false, "Disabled"
    end
    if not (typeof(position) == "Vector3" and ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "InvalidTarget"
    end

    local potionId = chooseBossPotionId()
    local potion = potionId and PotionConfig.GetPotion(potionId) or nil
    if not potion then
        return false, "InvalidPotion"
    end

    local dropState = self:_spawnBossPotionDropVisual(position, player, potion, source or "BossDrop")
    if not dropState then
        return false, "SpawnFailed"
    end
    return true, potion.Id
end

function PotionService:BuyWithDiamonds(player, potionId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", potionId)
        return false, "DataLoading"
    end

    local potion = PotionConfig.GetPotion(potionId)
    if not potion then
        self:_fireFeedback(player, "Failed", "InvalidPotion", potionId)
        return false, "InvalidPotion"
    end

    local price = math.max(0, math.floor(tonumber(potion.DiamondPrice) or 0))
    local spent, remainingDiamonds = false, 0
    if self._playerStateService.TrySpendDiamonds then
        spent, remainingDiamonds = self._playerStateService:TrySpendDiamonds(player, price, {
            source = "potion",
            productGroup = "potion",
            itemSku = "PotionDiamondPurchase_" .. tostring(potion.Id),
        })
    else
        local state = self._playerStateService:GetState(player)
        state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0))
        if state.Diamonds >= price then
            state.Diamonds -= price
            spent = true
            remainingDiamonds = state.Diamonds
        else
            remainingDiamonds = state.Diamonds
        end
    end
    if not spent then
        self:_fireFeedback(player, "Failed", "NotEnoughDiamonds", potion.Id)
        return false, "NotEnoughDiamonds"
    end

    local success, result = self:_activatePotion(player, potion, "DiamondPurchase", "Purchased", "DiamondPurchase")
    if not success then
        self._playerStateService:AddDiamonds(player, price, {
            source = "potion_refund",
            productGroup = "potion",
            itemSku = "PotionDiamondPurchaseRefund_" .. tostring(potion.Id),
        })
        return false, result or "ActivateFailed"
    end

    return true, remainingDiamonds
end

function PotionService:GrantRobuxPotion(player, productId)
    local potion = PotionConfig.GetPotionByProductId(productId)
    if not potion then
        return false, "UnknownProduct"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end
    return self:_activatePotion(player, potion, "RobuxPurchase", "Purchased", "RobuxPurchase")
end

function PotionService:UsePotion(player, potionId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading", potionId)
        return false, "DataLoading"
    end

    local potion = PotionConfig.GetPotion(potionId)
    if not potion then
        self:_fireFeedback(player, "Failed", "InvalidPotion", potionId)
        return false, "InvalidPotion"
    end

    local state = self._playerStateService:GetState(player)
    state.Potions = state.Potions or {}
    local potionKey = getPotionKey(potion.Id)
    local currentCount = math.max(0, math.floor(tonumber(state.Potions[potionKey]) or 0))
    if currentCount <= 0 then
        self:_fireFeedback(player, "Failed", "NoPotionInInventory", potion.Id)
        return false, "NoPotionInInventory"
    end

    state.Potions[potionKey] = currentCount - 1
    if state.Potions[potionKey] <= 0 then
        state.Potions[potionKey] = nil
    end

    local success, result = self:_activatePotion(player, potion, "UsePotion", "Activated", "PotionActivated")
    if not success then
        state.Potions[potionKey] = math.max(0, math.floor(tonumber(state.Potions[potionKey]) or 0)) + 1
        self._playerStateService:PushState(player)
        return false, result or "ActivateFailed"
    end

    return true, result
end

function PotionService:HandlePotionAction(player, payload)
    if type(payload) ~= "table" then
        return false, "InvalidPayload"
    end

    local action = tostring(payload.action or payload.Action or "")
    local potionId = tonumber(payload.potionId or payload.PotionId or payload.id or payload.Id)
    if action == "BuyDiamond" then
        return self:BuyWithDiamonds(player, potionId)
    elseif action == "Use" then
        return self:UsePotion(player, potionId)
    end

    self:_fireFeedback(player, "Failed", "UnknownAction", potionId)
    return false, "UnknownAction"
end

function PotionService:_handleStudioBotCommand(player, payload)
    if not RunService:IsStudio() then
        self:_fireFeedback(player, "Failed", "StudioOnly")
        return false, "StudioOnly"
    end
    if type(payload) ~= "table" then
        return false, "InvalidPayload"
    end

    local action = tostring(payload.action or payload.Action or "")
    if action ~= "AddPotion" then
        return false, "Ignored"
    end

    local targetPlayer = getPlayerByUserId(payload.targetUserId or payload.TargetUserId) or player
    if not targetPlayer then
        return false, "TargetNotFound"
    end

    return self:AddPotion(targetPlayer, payload.potionId or payload.PotionId or payload.id or payload.Id, payload.amount or payload.Amount, "GM")
end

function PotionService:_step()
    local now = os.clock()
    if now < self._nextExpireCheckClock then
        return
    end
    self._nextExpireCheckClock = now + 0.5

    if not self._playerStateService then
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local state = self._playerStateService:GetState(player)
        if state and (state.ActivePotion or state.ActivePotions) and self._playerStateService:ClearExpiredPotions(player) then
            self._playerStateService:SyncCharacterState(player)
            self._playerStateService:PushState(player)
            self:_markDirty(player)
            self:_fireFeedback(player, "Expired", "PotionExpired")
        end
    end
end

function PotionService:_stepBossPotionDrops(deltaTime)
    local now = os.clock()
    for dropId, dropState in pairs(self._bossPotionDropsById) do
        local runtimePotion = dropState.RuntimeInstance
        if not (runtimePotion and runtimePotion.Parent) then
            self:_destroyBossPotionDrop(dropState)
            continue
        end

        if now >= dropState.ExpireClock then
            self:_destroyBossPotionDrop(dropState)
            continue
        end

        if now < dropState.FallEndClock then
            local duration = math.max(0.05, dropState.FallEndClock - dropState.SpawnClock)
            local alpha = math.clamp((now - dropState.SpawnClock) / duration, 0, 1)
            local easedAlpha = 1 - ((1 - alpha) * (1 - alpha))
            setInstanceCFrame(runtimePotion, dropState.SpawnCFrame:Lerp(dropState.GroundCFrame, easedAlpha))
            continue
        end

        self:_setBossPotionDropTouchEnabled(dropState, true)
        local bob = math.sin((now - dropState.SpawnClock) * 7) * 0.05
        setInstanceCFrame(runtimePotion, dropState.GroundCFrame + Vector3.new(0, bob, 0))
    end
end

function PotionService:BindSystems(dependencies)
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
end

function PotionService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._requestPotionActionEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestPotionAction") or nil
    self._potionFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("PotionFeedback") or nil
    self._studioBotCommandEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("StudioBotCommand") or nil
    self._nextExpireCheckClock = os.clock() + 0.5
    self._bossPotionDropFolder = self:_createBossPotionDropFolder()
    self._bossPotionDropsById = {}
    self._nextBossPotionDropId = 1
    self:_clearBossPotionDropFolder()

    disconnectConnection(self._requestPotionActionConnection)
    disconnectConnection(self._studioBotCommandConnection)
    self._requestPotionActionConnection = nil
    self._studioBotCommandConnection = nil

    if self._requestPotionActionEvent then
        self._requestPotionActionConnection = self._requestPotionActionEvent.OnServerEvent:Connect(function(player, payload)
            self:HandlePotionAction(player, payload)
        end)
    end

    if self._studioBotCommandEvent then
        self._studioBotCommandConnection = self._studioBotCommandEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleStudioBotCommand(player, payload)
        end)
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end
    self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_step()
        self:_stepBossPotionDrops(deltaTime)
    end)
end

return PotionService
