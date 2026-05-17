--[[
脚本名字: BotService
脚本文件: BotService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/BotService
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
        "[BotService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local BotService = {}

BotService._remoteEventService = nil
BotService._playerStateService = nil
BotService._arenaService = nil
BotService._weaponService = nil
BotService._respawnService = nil
BotService._experienceOrbService = nil
BotService._commandEvent = nil
BotService._commandConnection = nil
BotService._heartbeatConnection = nil
BotService._runtimeFolder = nil
BotService._botsByActorId = {}
BotService._botsByCombatUserId = {}
BotService._characterToBot = {}
BotService._nextBotIndex = 1
BotService._nextCombatUserId = -1
BotService._enabled = false
BotService._lastMissingTemplateWarningClock = 0
BotService._fallbackCharacterTemplate = nil

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

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection then
            connection:Disconnect()
        end
    end
end

local function getBaseParts(instance)
    local result = {}
    if not instance then
        return result
    end

    if instance:IsA("BasePart") then
        table.insert(result, instance)
        return result
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(result, descendant)
        end
    end

    return result
end

function BotService:_createRuntimeFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    return findOrCreateFolder(runtimeRoot, "Bots")
end

function BotService:_isEnabled()
    if GameConfig.BOTS.EnabledInStudioOnly then
        return RunService:IsStudio()
    end
    return true
end

function BotService:GetBotFromCharacter(character)
    return self._characterToBot[character]
end

function BotService:GetActorByCombatUserId(combatUserId)
    return self._botsByCombatUserId[tonumber(combatUserId)]
end

function BotService:GetActiveBotCount()
    local count = 0
    for _ in pairs(self._botsByActorId) do
        count += 1
    end
    return count
end

function BotService:_resolveCharacterTemplate()
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character and character:FindFirstChild("HumanoidRootPart") and character:FindFirstChildOfClass("Humanoid") then
            character.Archivable = true
            return character
        end
    end

    if self._fallbackCharacterTemplate and self._fallbackCharacterTemplate.Parent == nil then
        return self._fallbackCharacterTemplate
    end

    return nil
end

function BotService:_createFallbackCharacterTemplate(botActor)
    if self._fallbackCharacterTemplate and self._fallbackCharacterTemplate.Parent == nil then
        return self._fallbackCharacterTemplate
    end

    local model = nil

    for _, player in ipairs(Players:GetPlayers()) do
        if player.UserId and player.UserId > 0 then
            local didLoadFromUserId, loadedModel = pcall(function()
                return Players:CreateHumanoidModelFromUserIdAsync(player.UserId)
            end)
            if didLoadFromUserId and loadedModel then
                model = loadedModel
                break
            end
        end
    end

    if not model then
        local didLoadFromDescription, loadedModel = pcall(function()
            local description = Instance.new("HumanoidDescription")
            return Players:CreateHumanoidModelFromDescriptionAsync(description, Enum.HumanoidRigType.R15)
        end)
        if didLoadFromDescription and loadedModel then
            model = loadedModel
        end
    end

    if not model then
        warn(string.format("[BotService] 无法为 %s 创建默认 AI 角色模型。", tostring(botActor and botActor.Name or "Bot")))
        return nil
    end

    model.Name = "BotFallbackTemplate"
    model.Archivable = true
    self:_stripCharacterScripts(model)
    self:_stripMotionControllers(model)
    self:_resetCharacterPhysics(model)
    self._fallbackCharacterTemplate = model
    return self._fallbackCharacterTemplate
end

function BotService:_stripCharacterScripts(character)
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("LocalScript") or descendant:IsA("Script") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        elseif descendant:IsA("Tool") then
            descendant:Destroy()
        end
    end
end

function BotService:_stripMotionControllers(character)
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BodyAngularVelocity")
            or descendant:IsA("BodyForce")
            or descendant:IsA("BodyGyro")
            or descendant:IsA("BodyPosition")
            or descendant:IsA("BodyThrust")
            or descendant:IsA("BodyVelocity")
            or descendant:IsA("LinearVelocity")
            or descendant:IsA("AngularVelocity")
            or descendant:IsA("VectorForce")
            or descendant:IsA("LineForce")
            or descendant:IsA("Torque")
            or descendant:IsA("AlignPosition")
            or descendant:IsA("AlignOrientation")
            or descendant:IsA("RocketPropulsion") then
            descendant:Destroy()
        end
    end
end

function BotService:_resetCharacterPhysics(character)
    for _, basePart in ipairs(getBaseParts(character)) do
        basePart.AssemblyLinearVelocity = Vector3.zero
        basePart.AssemblyAngularVelocity = Vector3.zero
    end
end

function BotService:_getBattleGroundY(botActor)
    local battlePart = self._arenaService and self._arenaService:GetBattlePart()
    if not battlePart then
        local rootPart = ActorUtils.GetRootPart(botActor)
        return rootPart and rootPart.Position.Y or nil
    end

    local rootPart = ActorUtils.GetRootPart(botActor)
    local humanoid = ActorUtils.GetHumanoid(botActor)
    local rootHalfHeight = rootPart and (rootPart.Size.Y * 0.5) or 1
    local hipHeight = humanoid and humanoid.HipHeight or 2
    return battlePart.Position.Y + (battlePart.Size.Y * 0.5) + rootHalfHeight + hipHeight + 0.15
end

function BotService:_groundTargetPosition(botActor, rawPosition)
    if typeof(rawPosition) ~= "Vector3" then
        return nil
    end

    local groundedY = self:_getBattleGroundY(botActor)
    if not groundedY then
        return rawPosition
    end

    return Vector3.new(rawPosition.X, groundedY, rawPosition.Z)
end

function BotService:_stabilizeBotHeight(botActor)
    local character = ActorUtils.GetCharacter(botActor)
    local rootPart = ActorUtils.GetRootPart(botActor)
    local groundedY = self:_getBattleGroundY(botActor)
    if not (character and rootPart and groundedY) then
        return
    end

    if math.abs(rootPart.Position.Y - groundedY) >= 6 then
        local planarLook = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
        local targetPosition = Vector3.new(rootPart.Position.X, groundedY, rootPart.Position.Z)
        local targetCFrame = CFrame.new(targetPosition)
        if planarLook.Magnitude > 0.001 then
            targetCFrame = CFrame.lookAt(targetPosition, targetPosition + planarLook.Unit)
        end
        character:PivotTo(targetCFrame)
        self:_resetCharacterPhysics(character)
    end
end

function BotService:_createCharacter(botActor)
    local template = self:_resolveCharacterTemplate()
    local character = nil
    if template then
        character = template:Clone()
    else
        local now = os.clock()
        if now - (self._lastMissingTemplateWarningClock or 0) >= 5 then
            self._lastMissingTemplateWarningClock = now
            warn("[BotService] 当前没有可复制的玩家角色模板，将使用默认 AI 模型。")
        end
        character = self:_createFallbackCharacterTemplate(botActor)
        if not character then
            return nil
        end
        character = character:Clone()
    end

    character.Name = botActor.Name
    character.Parent = self._runtimeFolder
    self:_stripCharacterScripts(character)
    self:_stripMotionControllers(character)

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not (humanoid and rootPart) then
        character:Destroy()
        warn("[BotService] 复制角色后缺少 Humanoid 或 HumanoidRootPart。")
        return nil
    end

    character.PrimaryPart = rootPart
    character:SetAttribute("IsStudioBot", true)
    character:SetAttribute("BotActorId", botActor.ActorId)
    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    humanoid.BreakJointsOnDeath = true
    humanoid.PlatformStand = false
    humanoid.Sit = false
    pcall(function()
        rootPart:SetNetworkOwner(nil)
    end)
    self:_resetCharacterPhysics(character)

    botActor.Character = character
    self._characterToBot[character] = botActor

    botActor.Connections = botActor.Connections or {}
    table.insert(botActor.Connections, humanoid.Died:Connect(function()
        local state = botActor.State
        if state and state.Alive and self._respawnService then
            self._respawnService:HandleActorDeath(botActor)
        end
    end))

    self._playerStateService:OnCharacterAdded(botActor)
    if self._arenaService then
        self._arenaService:TeleportActorToSpawnLocation(botActor)
        self:_resetCharacterPhysics(character)
        task.defer(function()
            self._arenaService:TryEnterArena(botActor)
            self:_stabilizeBotHeight(botActor)
        end)
    end
    return character
end

function BotService:_destroyCharacter(botActor)
    if botActor.Character then
        self._characterToBot[botActor.Character] = nil
        if botActor.Character.Parent then
            botActor.Character:Destroy()
        end
        botActor.Character = nil
    end
end

function BotService:_createBotActor()
    local index = self._nextBotIndex
    self._nextBotIndex += 1

    local combatUserId = self._nextCombatUserId
    self._nextCombatUserId -= 1

    local botActor = {
        IsBot = true,
        Name = string.format("AI_%02d", index),
        ActorId = string.format("bot:%d", index),
        UserId = combatUserId,
        Character = nil,
        State = nil,
        Connections = {},
        NextThinkClock = 0,
        NextWanderRefreshClock = 0,
        WanderTarget = nil,
        RespawnToken = 0,
    }

    self._botsByActorId[botActor.ActorId] = botActor
    self._botsByCombatUserId[botActor.UserId] = botActor
    self._playerStateService:RegisterBot(botActor)
    if not self:_createCharacter(botActor) then
        self._playerStateService:UnregisterBot(botActor)
        self._botsByActorId[botActor.ActorId] = nil
        self._botsByCombatUserId[botActor.UserId] = nil
        return nil
    end
    return botActor
end

function BotService:SpawnBots(count)
    if not self._enabled then
        return 0
    end

    local toSpawn = math.max(0, math.floor(tonumber(count) or 0))
    local spawned = 0
    while toSpawn > 0 and self:GetActiveBotCount() < GameConfig.BOTS.MaxActiveCount do
        if self:_createBotActor() then
            spawned += 1
        end
        toSpawn -= 1
    end
    return spawned
end

function BotService:_removeBot(botActor)
    if not botActor then
        return
    end

    botActor.RespawnToken += 1
    disconnectAll(botActor.Connections or {})
    botActor.Connections = {}

    if self._weaponService then
        self._weaponService:ClearPlayerWeapons(botActor)
    end

    self:_destroyCharacter(botActor)
    self._playerStateService:UnregisterBot(botActor)
    self._botsByActorId[botActor.ActorId] = nil
    self._botsByCombatUserId[botActor.UserId] = nil
end

function BotService:ClearBots()
    local bots = {}
    for _, botActor in pairs(self._botsByActorId) do
        table.insert(bots, botActor)
    end

    for _, botActor in ipairs(bots) do
        self:_removeBot(botActor)
    end
end

function BotService:ScheduleRespawn(botActor)
    if not (self._enabled and botActor) then
        return
    end

    local respawnToken = botActor.RespawnToken + 1
    botActor.RespawnToken = respawnToken

    task.delay(GameConfig.BOTS.RespawnDelaySeconds, function()
        if not self._enabled then
            return
        end
        if not self._botsByActorId[botActor.ActorId] then
            return
        end
        if botActor.RespawnToken ~= respawnToken then
            return
        end

        self:_destroyCharacter(botActor)
        self:_createCharacter(botActor)
    end)
end

function BotService:_sampleBattleWanderTarget()
    local battlePart = self._arenaService and self._arenaService:GetBattlePart()
    if not battlePart then
        return nil
    end

    local size = battlePart.Size
    local padding = GameConfig.ARENA.EdgePadding
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localX = (math.random() * 2 - 1) * usableHalfX
    local localZ = (math.random() * 2 - 1) * usableHalfZ
    local worldPoint = (battlePart.CFrame * CFrame.new(localX, 0, localZ)).Position
    return Vector3.new(worldPoint.X, battlePart.Position.Y + (battlePart.Size.Y * 0.5), worldPoint.Z)
end

function BotService:_getNearestEnemy(botActor, origin)
    local nearestActor = nil
    local nearestDistance = GameConfig.BOTS.AttackChaseDistance

    for _, actor in ipairs(self._playerStateService:GetArenaActors()) do
        if not ActorUtils.IsSameActor(actor, botActor) then
            local rootPart = ActorUtils.GetRootPart(actor)
            if rootPart then
                local distance = (rootPart.Position - origin).Magnitude
                if distance < nearestDistance then
                    nearestActor = actor
                    nearestDistance = distance
                end
            end
        end
    end

    return nearestActor, nearestDistance
end

function BotService:_getBotTargetPosition(botActor, botState)
    local rootPart = ActorUtils.GetRootPart(botActor)
    if not rootPart then
        return nil
    end

    local enemyActor = self:_getNearestEnemy(botActor, rootPart.Position)
    if enemyActor then
        local enemyRoot = ActorUtils.GetRootPart(enemyActor)
        if enemyRoot then
            return self:_groundTargetPosition(botActor, enemyRoot.Position)
        end
    end

    if self._experienceOrbService then
        local nearestOrb = self._experienceOrbService:GetNearestOrb(rootPart.Position, GameConfig.BOTS.ExperienceSeekDistance)
        if nearestOrb and nearestOrb.RuntimeInstance and nearestOrb.RuntimeInstance.Parent then
            return self:_groundTargetPosition(botActor, nearestOrb.RuntimeInstance.Position)
        end
    end

    local now = os.clock()
    if not botState.WanderTarget or now >= (botState.NextWanderRefreshClock or 0) then
        botState.WanderTarget = self:_sampleBattleWanderTarget()
        botState.NextWanderRefreshClock = now + GameConfig.BOTS.WanderRefreshSeconds
    end

    return self:_groundTargetPosition(botActor, botState.WanderTarget)
end

function BotService:_stepBot(botActor)
    local botState = self._playerStateService:GetState(botActor)
    if not (botState and botState.Alive and botState.IsInArena) then
        return
    end

    local humanoid = ActorUtils.GetHumanoid(botActor)
    local rootPart = ActorUtils.GetRootPart(botActor)
    if not (humanoid and rootPart) then
        return
    end

    self:_stabilizeBotHeight(botActor)

    local targetPosition = self:_getBotTargetPosition(botActor, botActor)
    if targetPosition then
        humanoid:MoveTo(targetPosition)
    end
end

function BotService:_onHeartbeat()
    if not self._enabled then
        return
    end

    local now = os.clock()
    for _, botActor in pairs(self._botsByActorId) do
        if now >= (botActor.NextThinkClock or 0) then
            botActor.NextThinkClock = now + GameConfig.BOTS.ThinkInterval
            self:_stepBot(botActor)
        end
    end
end

function BotService:BindSystems(dependencies)
    self._arenaService = dependencies.ArenaService
    self._weaponService = dependencies.WeaponService
    self._respawnService = dependencies.RespawnService
    self._experienceOrbService = dependencies.ExperienceOrbService
end

function BotService:Init(dependencies)
    self._remoteEventService = dependencies.RemoteEventService
    self._playerStateService = dependencies.PlayerStateService
    self._runtimeFolder = self:_createRuntimeFolder()
    self._botsByActorId = {}
    self._botsByCombatUserId = {}
    self._characterToBot = {}
    self._nextBotIndex = 1
    self._nextCombatUserId = -1
    self._enabled = self:_isEnabled()
    self._fallbackCharacterTemplate = nil

    if self._runtimeFolder then
        for _, child in ipairs(self._runtimeFolder:GetChildren()) do
            child:Destroy()
        end
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    if not self._enabled then
        return
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_onHeartbeat()
    end)
end

return BotService
