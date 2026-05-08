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

function PotionService:_activatePotion(player, potion, source, eventType, message)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService and potion) then
        return false, "InvalidPlayer"
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

function PotionService:BuyWithDiamonds(player, potionId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end

    local potion = PotionConfig.GetPotion(potionId)
    if not potion then
        self:_fireFeedback(player, "Failed", "InvalidPotion", potionId)
        return false, "InvalidPotion"
    end

    local state = self._playerStateService:GetState(player)
    local price = math.max(0, math.floor(tonumber(potion.DiamondPrice) or 0))
    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0))
    if state.Diamonds < price then
        self:_fireFeedback(player, "Failed", "NotEnoughDiamonds", potion.Id)
        return false, "NotEnoughDiamonds"
    end

    state.Diamonds = state.Diamonds - price
    local success, result = self:_activatePotion(player, potion, "DiamondPurchase", "Purchased", "DiamondPurchase")
    if not success then
        state.Diamonds = state.Diamonds + price
        self._playerStateService:PushState(player)
        return false, result or "ActivateFailed"
    end

    return true, state.Diamonds
end

function PotionService:GrantRobuxPotion(player, productId)
    local potion = PotionConfig.GetPotionByProductId(productId)
    if not potion then
        return false, "UnknownProduct"
    end
    return self:_activatePotion(player, potion, "RobuxPurchase", "Purchased", "RobuxPurchase")
end

function PotionService:UsePotion(player, potionId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
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
    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

return PotionService
