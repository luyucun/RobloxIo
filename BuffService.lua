--[[
脚本名字: BuffService
脚本文件: BuffService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/BuffService
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
        "[BuffService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local BuffService = {}

BuffService._playerStateService = nil
BuffService._remoteEventService = nil
BuffService._botService = nil
BuffService._runtimeFolder = nil
BuffService._templateFolder = nil
BuffService._buffFeedbackEvent = nil
BuffService._buffsById = {}
BuffService._nextBuffId = 1

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

local function resolveTemplateFolder()
    local modelRoot = findOrCreateFolder(ReplicatedStorage, GameConfig.BUFF.ModelRootFolderName)
    return findOrCreateFolder(modelRoot, GameConfig.BUFF.BuffFolderName)
end

local function findTemplate(folder)
    local template = folder and folder:FindFirstChild(GameConfig.BUFF.TemplateName)
    if template and template:IsA("BasePart") then
        return template
    end
    return nil
end

local function createPlaceholderTemplate(folder)
    local template = Instance.new("Part")
    template.Name = GameConfig.BUFF.TemplateName
    template.Anchored = true
    template.CanCollide = false
    template.CanTouch = true
    template.CanQuery = false
    template.Massless = true
    template.Material = Enum.Material.Neon
    template.Color = Color3.fromRGB(255, 214, 64)
    template.Shape = Enum.PartType.Ball
    template.Size = Vector3.new(2, 2, 2)
    template:SetAttribute("IsPlaceholderTemplate", true)
    template.Parent = folder
    return template
end

function BuffService:_createRuntimeFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    return findOrCreateFolder(runtimeRoot, GameConfig.BUFF.RuntimeFolderName)
end

function BuffService:_clearRuntimeFolder()
    if not self._runtimeFolder then
        return
    end
    for _, child in ipairs(self._runtimeFolder:GetChildren()) do
        child:Destroy()
    end
end

function BuffService:_resolveActorFromCharacter(character)
    local player = Players:GetPlayerFromCharacter(character)
    if player then
        return player
    end
    if self._botService then
        return self._botService:GetBotFromCharacter(character)
    end
    return nil
end

function BuffService:_fireBuffFeedback(actor, buffType, expiresAt)
    if not (self._buffFeedbackEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    self._buffFeedbackEvent:FireClient(actor, {
        buffType = buffType,
        damageMultiplier = GameConfig.BUFF.DamageMultiplier,
        durationSeconds = GameConfig.BUFF.DurationSeconds,
        expiresAt = expiresAt,
        timestamp = os.clock(),
    })
end

function BuffService:_destroyBuff(buffState)
    if not buffState then
        return
    end
    if buffState.TouchedConnection then
        buffState.TouchedConnection:Disconnect()
        buffState.TouchedConnection = nil
    end
    if buffState.RuntimeInstance and buffState.RuntimeInstance.Parent then
        buffState.RuntimeInstance:Destroy()
    end
    self._buffsById[buffState.Id] = nil
end

function BuffService:ApplyDamageBuff(actor)
    local state = self._playerStateService:GetState(actor)
    local expiresAt = os.clock() + GameConfig.BUFF.DurationSeconds
    state.Buffs = state.Buffs or {}
    state.Buffs.DamageMultiplier = {
        Multiplier = GameConfig.BUFF.DamageMultiplier,
        ExpiresAt = expiresAt,
    }
    self._playerStateService:PushState(actor)
    self:_fireBuffFeedback(actor, "DamageMultiplier", expiresAt)
end

function BuffService:GetDamageMultiplier(actor)
    if not actor then
        return 1
    end

    local state = self._playerStateService:GetState(actor)
    local buff = state.Buffs and state.Buffs.DamageMultiplier
    if not buff then
        return 1
    end

    if tonumber(buff.ExpiresAt) and buff.ExpiresAt > os.clock() then
        return math.max(0, tonumber(buff.Multiplier) or 1)
    end

    state.Buffs.DamageMultiplier = nil
    self._playerStateService:PushState(actor)
    return 1
end

function BuffService:_consumeBuff(buffState, actor)
    if not (buffState and actor and not buffState.Consumed) then
        return false
    end

    local state = self._playerStateService:GetState(actor)
    if not (state and state.Alive and state.IsInArena) then
        return false
    end

    buffState.Consumed = true
    self:_destroyBuff(buffState)
    self:ApplyDamageBuff(actor)
    return true
end

function BuffService:_tryConsumeBuff(buffState, hitPart)
    if not buffState or buffState.Consumed then
        return
    end

    local now = os.clock()
    if buffState.LastConsumeClock and now - buffState.LastConsumeClock < GameConfig.BUFF.TouchConsumeDebounceSeconds then
        return
    end
    buffState.LastConsumeClock = now

    local character = hitPart and hitPart:FindFirstAncestorOfClass("Model")
    if not character then
        return
    end

    local actor = self:_resolveActorFromCharacter(character)
    if actor then
        self:_consumeBuff(buffState, actor)
    end
end

function BuffService:DropBuffs(position, count)
    if not (self._runtimeFolder and self._templateFolder and typeof(position) == "Vector3") then
        return 0
    end

    local template = findTemplate(self._templateFolder) or createPlaceholderTemplate(self._templateFolder)
    local buffCount = math.max(1, math.floor(tonumber(count) or 1))
    local spawned = 0

    for index = 1, buffCount do
        local angle = (math.pi * 2) * ((index - 1) / buffCount)
        local offset = Vector3.new(math.cos(angle) * 5, GameConfig.BUFF.SpawnHeightOffset, math.sin(angle) * 5)
        local buffId = tostring(self._nextBuffId)
        self._nextBuffId += 1

        local runtimeBuff = template:Clone()
        runtimeBuff.Name = "DamageBuff_" .. buffId
        runtimeBuff.Anchored = true
        runtimeBuff.CanCollide = false
        runtimeBuff.CanTouch = true
        runtimeBuff.CanQuery = false
        runtimeBuff.Massless = true
        runtimeBuff.CFrame = CFrame.new(position + offset)
        runtimeBuff.Parent = self._runtimeFolder

        local buffState = {
            Id = buffId,
            RuntimeInstance = runtimeBuff,
            Consumed = false,
            LastConsumeClock = nil,
            TouchedConnection = nil,
        }

        runtimeBuff:SetAttribute("BuffId", buffId)
        runtimeBuff:SetAttribute("BuffType", "DamageMultiplier")
        runtimeBuff:SetAttribute("DamageMultiplier", GameConfig.BUFF.DamageMultiplier)

        buffState.TouchedConnection = runtimeBuff.Touched:Connect(function(hitPart)
            self:_tryConsumeBuff(buffState, hitPart)
        end)

        self._buffsById[buffId] = buffState
        spawned += 1
    end

    return spawned
end

function BuffService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._remoteEventService = dependencies.RemoteEventService
    self._botService = dependencies.BotService
    self._runtimeFolder = self:_createRuntimeFolder()
    self._templateFolder = resolveTemplateFolder()
    if self._templateFolder and not findTemplate(self._templateFolder) then
        createPlaceholderTemplate(self._templateFolder)
    end
    self._buffFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("BuffFeedback") or nil
    self._buffsById = {}
    self._nextBuffId = 1
    self:_clearRuntimeFolder()
end

return BuffService
