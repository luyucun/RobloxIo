--[[
脚本名字: LocalMonsterController
脚本文件: LocalMonsterController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/LocalMonsterController
说明: 普通小怪由玩家客户端私有生成与控制，服务端只接收受限奖励/伤害事件。
]]

local Players = game:GetService("Players")
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

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
        "[LocalMonsterController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local LocalMonsterController = {}

LocalMonsterController._localPlayer = nil
LocalMonsterController._weaponFxController = nil
LocalMonsterController._audioSettings = nil
LocalMonsterController._monsterFolder = nil
LocalMonsterController._battlePart = nil
LocalMonsterController._connections = {}
LocalMonsterController._renderConnection = nil
LocalMonsterController._localMonsterSpawnTokenEvent = nil
LocalMonsterController._localMonsterKilledEvent = nil
LocalMonsterController._localMonsterHitPlayerEvent = nil
LocalMonsterController._latestPlayerState = nil
LocalMonsterController._monstersById = {}
LocalMonsterController._spawnTokenQueue = {}
LocalMonsterController._spawnTokenRequestPending = false
LocalMonsterController._spawnTokenRequestDeadline = 0
LocalMonsterController._nextSpawnTokenRequestClock = 0
LocalMonsterController._nextMonsterId = 1
LocalMonsterController._nextKillRequestId = 1
LocalMonsterController._nextSpawnClock = 0
LocalMonsterController._simulationAccumulator = 0
LocalMonsterController._nukeLocalMonsterSweepEvent = nil
LocalMonsterController._pendingKillsByRequestId = {}

local LOOP_FADE_SECONDS = 0.12
local ATTACK_FADE_SECONDS = 0.04
local MOVING_SPEED_THRESHOLD = 0.35
local SPATIAL_CELL_SIZE = 10
local DEFAULT_LOCAL_SIMULATION_TICK_SECONDS = 0.08
local LOCAL_DAMAGE_MERGE_SECONDS = 0.18
local LOCAL_TOKEN_EXPIRY_BUFFER_SECONDS = 3
local KILL_ACK_RETRY_SECONDS = 1.25
local VISUAL_FOLLOW_SPEED = 22
local VISUAL_SNAP_DISTANCE = 18

local function getLocalSimulationTickSeconds()
    local configuredTick = tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalSimulationTickSeconds) or 0
    if configuredTick > 0 then
        return configuredTick
    end
    return DEFAULT_LOCAL_SIMULATION_TICK_SECONDS
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
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

local function getBaseParts(instance)
    local result = {}
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

local function stripRuntimeOnlyDescendants(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        end
    end
end

local function getInstanceCFrame(instance)
    if instance:IsA("Model") then
        return instance:GetPivot()
    end
    if instance:IsA("BasePart") then
        return instance.CFrame
    end
    return nil
end

local function getInstancePosition(instance)
    local cframe = getInstanceCFrame(instance)
    return cframe and cframe.Position or nil
end

local function setInstanceCFrame(instance, cframe)
    if instance:IsA("Model") then
        instance:PivotTo(cframe)
    elseif instance:IsA("BasePart") then
        instance.CFrame = cframe
    end
end

local function getPlanarLookAtCFrame(position, lookAtPosition)
    if typeof(position) ~= "Vector3" then
        return nil
    end
    if typeof(lookAtPosition) == "Vector3" then
        local lookAt = Vector3.new(lookAtPosition.X, position.Y, lookAtPosition.Z)
        if (lookAt - position).Magnitude > 0.001 then
            return CFrame.new(position, lookAt)
        end
    end
    return CFrame.new(position)
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

local function configureMonsterInstance(instance)
    stripRuntimeOnlyDescendants(instance)
    local baseParts = getBaseParts(instance)
    if instance:IsA("Model") and #baseParts > 0 then
        instance.PrimaryPart = instance.PrimaryPart or instance:FindFirstChild("Root", true) or baseParts[1]
    end

    for _, basePart in ipairs(baseParts) do
        basePart.Anchored = instance:IsA("BasePart")
            or basePart == instance.PrimaryPart
            or basePart.Name == "Root"
        basePart.CanCollide = false
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
        basePart.LocalTransparencyModifier = 0
    end
end

local function resolveAnimator(instance)
    local animator = instance:FindFirstChildWhichIsA("Animator", true)
    if animator then
        return animator
    end

    if instance:IsA("Model") then
        local animationController = instance:FindFirstChildOfClass("AnimationController")
        if not animationController then
            animationController = Instance.new("AnimationController")
            animationController.Name = "ClientLocalMonsterAnimationController"
            animationController.Parent = instance
        end

        animator = Instance.new("Animator")
        animator.Name = "ClientLocalMonsterAnimator"
        animator.Parent = animationController
        return animator
    end
    return nil
end

local registeredKeyframeAnimationIds = {}

local function getAnimSavesKeyframeSequence(instance, animationName)
    local animSaves = instance and instance:FindFirstChild("AnimSaves")
    local keyframeSequence = animSaves and animSaves:FindFirstChild(animationName)
    if keyframeSequence and keyframeSequence:IsA("KeyframeSequence") then
        return keyframeSequence
    end
    return nil
end

local function getRegisteredKeyframeAnimationId(instance, animationName)
    local keyframeSequence = getAnimSavesKeyframeSequence(instance, animationName)
    if not keyframeSequence then
        return nil
    end

    local templateName = instance:GetAttribute("MonsterTemplateName") or instance.Name
    local cacheKey = tostring(templateName) .. ":" .. tostring(animationName)
    if registeredKeyframeAnimationIds[cacheKey] then
        return registeredKeyframeAnimationIds[cacheKey]
    end

    local didRegister, animationId = pcall(function()
        return KeyframeSequenceProvider:RegisterKeyframeSequence(keyframeSequence)
    end)
    if not didRegister or not animationId then
        warn(string.format(
            "[LocalMonsterController] 模板内动画注册失败: template=%s animation=%s",
            tostring(templateName),
            tostring(animationName)
        ))
        return nil
    end

    registeredKeyframeAnimationIds[cacheKey] = animationId
    return animationId
end

local function loadTrackFromAnimationId(animator, animationId, isLooped, priority, context)
    local normalizedAnimationId = MonsterCatalog.NormalizeAnimationId(animationId)
    if not normalizedAnimationId then
        return nil
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = normalizedAnimationId
    local didLoad, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    animation:Destroy()
    if not didLoad or not track then
        warn(string.format(
            "[LocalMonsterController] 动画加载失败: %s (%s)",
            tostring(normalizedAnimationId),
            tostring(context or "")
        ))
        return nil
    end
    track.Looped = isLooped == true
    track.Priority = priority
    return track
end

local function loadTrack(animator, instance, animationName, animationId, isLooped, priority)
    local fallbackAnimationId = getRegisteredKeyframeAnimationId(instance, animationName)
    local track = fallbackAnimationId and loadTrackFromAnimationId(
        animator,
        fallbackAnimationId,
        isLooped,
        priority,
        "AnimSaves." .. tostring(animationName)
    ) or nil
    if track then
        return track
    end

    return loadTrackFromAnimationId(
        animator,
        animationId,
        isLooped,
        priority,
        "MonsterCatalog." .. tostring(animationName)
    )
end

local function getMonsterValue(monsterState, key, fallback)
    local value = monsterState and monsterState[key]
    if value == nil then
        return fallback
    end
    return value
end

local function isSpawnAuthorizationFresh(spawnAuthorization)
    if not spawnAuthorization then
        return false
    end

    local localExpiresAt = tonumber(spawnAuthorization.localExpiresAt)
    if localExpiresAt and localExpiresAt - os.clock() <= LOCAL_TOKEN_EXPIRY_BUFFER_SECONDS then
        return false
    end

    return tostring(spawnAuthorization.token or "") ~= ""
end

local function formatDamage(amount)
    local value = math.max(0, math.floor(tonumber(amount) or 0))
    if value >= 1000000 then
        return string.format("%.1fM", value / 1000000):gsub("%.0M", "M")
    end
    if value >= 1000 then
        return string.format("%.1fK", value / 1000):gsub("%.0K", "K")
    end
    return tostring(value)
end

local function getDamageColors(amount)
    local value = math.max(0, tonumber(amount) or 0)
    if value >= 10000 then
        return Color3.fromRGB(255, 139, 47), Color3.fromRGB(76, 40, 18)
    end
    if value >= 1000 then
        return Color3.fromRGB(255, 230, 92), Color3.fromRGB(196, 88, 24)
    end
    return Color3.fromRGB(255, 255, 255), Color3.fromRGB(38, 42, 56)
end

local function setLoop(monsterState, loopName)
    if monsterState.CurrentLoopName == loopName then
        local currentTrack = monsterState.Tracks and monsterState.Tracks[loopName]
        if currentTrack and not currentTrack.IsPlaying then
            currentTrack:Play(LOOP_FADE_SECONDS)
            currentTrack:AdjustSpeed(monsterState.LoopAnimationSpeed or 1)
            if currentTrack.Length and currentTrack.Length > 0 then
                currentTrack.TimePosition = (monsterState.AnimationPhaseOffset or 0) % currentTrack.Length
            end
        end
        return
    end

    for name, track in pairs(monsterState.Tracks or {}) do
        if name ~= "Attack" and track then
            if name == loopName then
                if not track.IsPlaying then
                    track:Play(LOOP_FADE_SECONDS)
                    track:AdjustSpeed(monsterState.LoopAnimationSpeed or 1)
                    if track.Length and track.Length > 0 then
                        track.TimePosition = (monsterState.AnimationPhaseOffset or 0) % track.Length
                    end
                end
            else
                track:Stop(LOOP_FADE_SECONDS)
            end
        end
    end

    monsterState.CurrentLoopName = loopName
end

local function playAttack(monsterState)
    local attackTrack = monsterState.Tracks and monsterState.Tracks.Attack
    if attackTrack then
        attackTrack:Stop(0)
        attackTrack:Play(ATTACK_FADE_SECONDS)
        attackTrack:AdjustSpeed(monsterState.AttackAnimationSpeed or 1)
    end
end

local function getCharacterRoot(player)
    local character = player and player.Character
    return character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart) or nil
end

local function getPartCollisionReach(basePart)
    if not (basePart and basePart.Parent) then
        return 0
    end
    local size = basePart.Size
    return math.max(size.X, size.Y, size.Z) * 0.5
end

local function getMonsterHeight(instance)
    if not instance then
        return 5
    end
    if instance:IsA("Model") then
        local _, size = instance:GetBoundingBox()
        return math.max(1, size.Y)
    end
    if instance:IsA("BasePart") then
        return math.max(1, instance.Size.Y)
    end
    return 5
end

local function isWeaponHittingPosition(weaponState, targetPosition, targetRadius)
    local instance = weaponState and weaponState.Instance
    if not (instance and instance.Parent and typeof(targetPosition) == "Vector3") then
        return false
    end

    local cframe = getInstanceCFrame(instance)
    if not cframe then
        return false
    end

    local baseParts = getBaseParts(instance)
    local hitPart = weaponState.HitPart or (instance:IsA("BasePart") and instance or (instance.PrimaryPart or baseParts[1]))
    if not hitPart then
        return false
    end

    local radius = math.max(0, tonumber(targetRadius) or 0)
    local localPosition = hitPart.CFrame:PointToObjectSpace(targetPosition)
    local halfSize = hitPart.Size * 0.5
    local dx = math.max(math.abs(localPosition.X) - halfSize.X, 0)
    local dy = math.max(math.abs(localPosition.Y) - halfSize.Y, 0)
    local dz = math.max(math.abs(localPosition.Z) - halfSize.Z, 0)
    return (dx * dx) + (dy * dy) + (dz * dz) <= radius * radius
end

function LocalMonsterController:_createMonsterFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    local folder = findOrCreateFolder(runtimeRoot, GameConfig.MONSTER.LocalRuntimeFolderName or "Monsters_ClientLocal")
    folder:ClearAllChildren()
    self._monsterFolder = folder
end

function LocalMonsterController:_resolveBattlePart()
    local battlePart = Workspace:FindFirstChild(GameConfig.ARENA.BattlePartName)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end

    battlePart = Workspace:FindFirstChild(GameConfig.ARENA.BattlePartName, true)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end
    return nil
end

function LocalMonsterController:_resolveTemplate(monsterDefinition)
    local modelRoot = ReplicatedStorage:FindFirstChild(GameConfig.MONSTER.ModelRootFolderName)
    local monsterFolder = modelRoot and modelRoot:FindFirstChild(GameConfig.MONSTER.MonsterFolderName)
    local templateName = monsterDefinition and monsterDefinition.TemplateName or GameConfig.MONSTER.TemplateName
    local template = monsterFolder and monsterFolder:FindFirstChild(templateName)
    if template and (template:IsA("Model") or template:IsA("BasePart")) then
        return template
    end
    return nil
end

function LocalMonsterController:_getGroundY(template)
    if not self._battlePart then
        return 0
    end
    local groundY = self._battlePart.Position.Y + (self._battlePart.Size.Y * 0.5)
    return groundY - getBottomOffsetFromPivot(template)
end

function LocalMonsterController:_samplePointInsideBattle()
    if not self._battlePart then
        return nil
    end

    local size = self._battlePart.Size
    local padding = GameConfig.MONSTER.EdgePadding
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localX = (math.random() * 2 - 1) * usableHalfX
    local localZ = (math.random() * 2 - 1) * usableHalfZ

    local worldPoint = (self._battlePart.CFrame * CFrame.new(localX, 0, localZ)).Position
    return Vector3.new(worldPoint.X, worldPoint.Y, worldPoint.Z)
end

function LocalMonsterController:_clampPositionInsideBattle(position)
    if not (self._battlePart and typeof(position) == "Vector3") then
        return position
    end

    local size = self._battlePart.Size
    local padding = math.max(GameConfig.MONSTER.EdgePadding, GameConfig.MONSTER.CollisionRadius)
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localPosition = self._battlePart.CFrame:PointToObjectSpace(position)
    local clampedLocalPosition = Vector3.new(
        math.clamp(localPosition.X, -usableHalfX, usableHalfX),
        0,
        math.clamp(localPosition.Z, -usableHalfZ, usableHalfZ)
    )
    local worldPoint = (self._battlePart.CFrame * CFrame.new(clampedLocalPosition)).Position
    return Vector3.new(worldPoint.X, position.Y, worldPoint.Z)
end

function LocalMonsterController:_getActiveMonsterCount()
    local count = 0
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive then
            count += 1
        end
    end
    return count
end

function LocalMonsterController:_createFallbackMonster(monsterDefinition)
    local model = Instance.new("Model")
    model.Name = monsterDefinition and monsterDefinition.TemplateName or GameConfig.MONSTER.TemplateName

    local body = Instance.new("Part")
    body.Name = "Body"
    body.Anchored = true
    body.CanCollide = false
    body.CanTouch = false
    body.CanQuery = false
    body.Material = Enum.Material.Neon
    body.Color = Color3.fromRGB(255, 95, 86)
    body.Shape = Enum.PartType.Ball
    body.Size = Vector3.new(5, 5, 5)
    body.Parent = model
    model.PrimaryPart = body
    return model
end

function LocalMonsterController:_loadTracks(instance, monsterDefinition)
    local animations = monsterDefinition and monsterDefinition.Animations or {}
    local animator = resolveAnimator(instance)
    if not animator then
        return {}
    end

    return {
        Idle = loadTrack(animator, instance, "Idle", animations.Idle, true, Enum.AnimationPriority.Idle),
        Run = loadTrack(animator, instance, "Run", animations.Run, true, Enum.AnimationPriority.Movement),
        Attack = loadTrack(animator, instance, "Attack", animations.Attack, false, Enum.AnimationPriority.Action),
    }
end

function LocalMonsterController:_discardExpiredSpawnTokens()
    local freshQueue = {}
    local discardedTokens = {}
    for _, spawnAuthorization in ipairs(self._spawnTokenQueue) do
        if isSpawnAuthorizationFresh(spawnAuthorization) then
            table.insert(freshQueue, spawnAuthorization)
        elseif spawnAuthorization and spawnAuthorization.token then
            table.insert(discardedTokens, spawnAuthorization.token)
        end
    end
    self._spawnTokenQueue = freshQueue
    self:_discardSpawnTokensOnServer(discardedTokens)
end

function LocalMonsterController:_spawnMonster()
    local spawnAuthorization = nil
    repeat
        spawnAuthorization = table.remove(self._spawnTokenQueue, 1)
    until not spawnAuthorization or isSpawnAuthorizationFresh(spawnAuthorization)

    if not spawnAuthorization then
        self:_requestSpawnTokens()
        return nil
    end

    local monsterDefinition = MonsterCatalog.GetDefinition(spawnAuthorization.monsterDefinitionId)
        or MonsterCatalog.GetDefinition(GameConfig.MONSTER.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(monsterDefinition) then
        return nil
    end
    local template = self:_resolveTemplate(monsterDefinition)
    local spawnPoint = self:_samplePointInsideBattle()
    if not spawnPoint then
        return nil
    end

    local instance = template and template:Clone() or self:_createFallbackMonster(monsterDefinition)
    local monsterId = tostring(self._nextMonsterId)
    self._nextMonsterId += 1
    local monsterDefinitionId = monsterDefinition and monsterDefinition.Id or GameConfig.MONSTER.MonsterDefinitionId
    local monsterTemplateName = monsterDefinition and monsterDefinition.TemplateName or GameConfig.MONSTER.TemplateName
    local monsterTypeName = monsterDefinition and monsterDefinition.TypeName or "普通小怪"
    instance.Name = "LocalMonster_" .. monsterId
    instance:SetAttribute("MonsterId", monsterId)
    instance:SetAttribute("MonsterDefinitionId", monsterDefinitionId)
    instance:SetAttribute("MonsterTemplateName", monsterTemplateName)
    instance:SetAttribute("MonsterType", monsterTypeName)
    instance:SetAttribute("IsClientLocalMonster", true)
    configureMonsterInstance(instance)

    local groundY = self:_getGroundY(instance)
    local spawnPosition = Vector3.new(spawnPoint.X, groundY, spawnPoint.Z)
    setInstanceCFrame(instance, CFrame.new(spawnPosition))
    instance.Parent = self._monsterFolder

    local monsterState = {
        Id = monsterId,
        SpawnToken = spawnAuthorization.token,
        SpawnTokenExpiresAt = spawnAuthorization.expiresAt,
        SpawnTokenLocalExpiresAt = spawnAuthorization.localExpiresAt,
        MonsterDefinitionId = monsterDefinitionId,
        MonsterTemplateName = monsterTemplateName,
        MonsterType = monsterTypeName,
        Instance = instance,
        Alive = true,
        GroundY = groundY,
        CurrentHealth = monsterDefinition and monsterDefinition.MaxHealth or GameConfig.MONSTER.MaxHealth,
        MaxHealth = monsterDefinition and monsterDefinition.MaxHealth or GameConfig.MONSTER.MaxHealth,
        AttackDamage = monsterDefinition and monsterDefinition.AttackDamage or GameConfig.MONSTER.AttackDamage,
        AttackRange = monsterDefinition and monsterDefinition.AttackRange or GameConfig.MONSTER.AttackRange,
        AggroRadius = monsterDefinition and monsterDefinition.AggroRadius or GameConfig.MONSTER.AggroRadius,
        DisengageDistance = monsterDefinition and monsterDefinition.DisengageDistance or GameConfig.MONSTER.DisengageDistance,
        ContactRadius = monsterDefinition and monsterDefinition.ContactRadius or GameConfig.MONSTER.ContactRadius,
        AttackCooldownSeconds = monsterDefinition and monsterDefinition.AttackCooldownSeconds or GameConfig.MONSTER.AttackCooldownSeconds,
        MoveSpeed = monsterDefinition and monsterDefinition.MoveSpeed or GameConfig.MONSTER.MoveSpeed,
        Position = spawnPosition,
        LastAttackClock = 0,
        LastAttackAnimationClock = 0,
        LastWeaponHitClockByKey = {},
        KnockbackVelocity = Vector3.zero,
        KnockbackEndClock = 0,
        HitStunEndClock = 0,
        AnimationPhaseOffset = math.random() * math.max(0, tonumber(GameConfig.MONSTER.AnimationPhaseJitterSeconds) or 1.2),
        LoopAnimationSpeed = 1 + ((math.random() * 2 - 1) * math.max(0, tonumber(GameConfig.MONSTER.AnimationSpeedJitter) or 0.08)),
        AttackAnimationSpeed = 1 + ((math.random() * 2 - 1) * math.max(0, tonumber(GameConfig.MONSTER.AnimationSpeedJitter) or 0.08)),
        Tracks = self:_loadTracks(instance, monsterDefinition),
        CurrentLoopName = nil,
        LastPosition = spawnPosition,
        DisplayPosition = spawnPosition,
        DisplayLookAt = nil,
        DamageBucket = nil,
    }
    self._monstersById[monsterId] = monsterState
    self._localMonsterSpawnTokenEvent:FireServer({
        eventType = "Activate",
        token = monsterState.SpawnToken,
        timestamp = os.clock(),
    })
    setLoop(monsterState, "Idle")
    return monsterState
end

function LocalMonsterController:_destroyMonster(monsterState)
    if not monsterState then
        return
    end
    monsterState.Alive = false
    for _, track in pairs(monsterState.Tracks or {}) do
        if track then
            track:Stop(0)
            track:Destroy()
        end
    end
    if monsterState.Instance and monsterState.Instance.Parent then
        monsterState.Instance:Destroy()
    end
    self._monstersById[monsterState.Id] = nil
end

function LocalMonsterController:_discardSpawnTokensOnServer(tokens)
    if not (self._localMonsterSpawnTokenEvent and type(tokens) == "table" and #tokens > 0) then
        return
    end

    self._localMonsterSpawnTokenEvent:FireServer({
        eventType = "Discard",
        tokens = tokens,
        timestamp = os.clock(),
    })
end

function LocalMonsterController:_clearMonsters(options)
    local shouldDiscardTokens = not (type(options) == "table" and options.preserveTokens == true)
    local discardedTokens = {}
    for _, monsterState in pairs(self._monstersById) do
        if shouldDiscardTokens and monsterState and monsterState.SpawnToken and not monsterState.PendingKill then
            table.insert(discardedTokens, monsterState.SpawnToken)
        end
        self:_destroyMonster(monsterState)
    end
    if shouldDiscardTokens then
        for _, spawnAuthorization in ipairs(self._spawnTokenQueue) do
            if spawnAuthorization and spawnAuthorization.token then
                table.insert(discardedTokens, spawnAuthorization.token)
            end
        end
    end
    self._monstersById = {}
    table.clear(self._pendingKillsByRequestId)
    self:_discardSpawnTokensOnServer(discardedTokens)
    if self._monsterFolder and self._monsterFolder.Parent then
        self._monsterFolder:ClearAllChildren()
    end
end

function LocalMonsterController:_resetLocalMonsterPopulation()
    self:_clearMonsters()
    self._spawnTokenQueue = {}
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0
    self._nextSpawnTokenRequestClock = 0
    self._nextSpawnClock = 0
    self._simulationAccumulator = 0
end

function LocalMonsterController:SweepForNuke(sessionId)
    local tokens = {}
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and monsterState.SpawnToken then
            table.insert(tokens, monsterState.SpawnToken)
        end
    end

    self:_clearMonsters({
        preserveTokens = true,
    })
    self._nextSpawnClock = os.clock() + math.max(0, tonumber(GameConfig.NUKE.MonsterRespawnPauseSeconds) or 2.5)

    if self._nukeLocalMonsterSweepEvent and #tokens > 0 then
        self._nukeLocalMonsterSweepEvent:FireServer({
            sessionId = sessionId,
            tokens = tokens,
            timestamp = os.clock(),
        })
    end

    return #tokens
end

function LocalMonsterController:_maintainPopulation()
    if not (self._battlePart and self._battlePart.Parent) then
        return
    end

    local now = os.clock()
    if now < self._nextSpawnClock then
        return
    end

    local isActiveInArena = self._latestPlayerState and self._latestPlayerState.isInArena and self._latestPlayerState.alive
    local spawnInterval = isActiveInArena
        and GameConfig.MONSTER.SpawnIntervalSeconds
        or (GameConfig.MONSTER.PreloadSpawnIntervalSeconds or GameConfig.MONSTER.SpawnIntervalSeconds)
    local maxSpawnPerInterval = isActiveInArena
        and GameConfig.MONSTER.MaxSpawnPerInterval
        or (GameConfig.MONSTER.PreloadMaxSpawnPerInterval or GameConfig.MONSTER.MaxSpawnPerInterval)
    self._nextSpawnClock = now + spawnInterval

    self:_discardExpiredSpawnTokens()
    local missingCount = GameConfig.MONSTER.MaxActiveCount - self:_getActiveMonsterCount()
    local spawnCount = math.min(missingCount, maxSpawnPerInterval or missingCount)
    if #self._spawnTokenQueue < spawnCount then
        self:_requestSpawnTokens(spawnCount - #self._spawnTokenQueue)
    end
    for _ = 1, spawnCount do
        if not self:_spawnMonster() then
            break
        end
    end
end

function LocalMonsterController:_buildSpatialGrid()
    local grid = {}
    local cellSize = SPATIAL_CELL_SIZE
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive then
            local position = monsterState.Position
            if not position then
                position = getInstancePosition(monsterState.Instance)
                monsterState.Position = position
            end
            if position then
                local cellX = math.floor(position.X / cellSize)
                local cellZ = math.floor(position.Z / cellSize)
                local key = tostring(cellX) .. ":" .. tostring(cellZ)
                local bucket = grid[key]
                if not bucket then
                    bucket = {}
                    grid[key] = bucket
                end
                table.insert(bucket, monsterState)
                monsterState.CellX = cellX
                monsterState.CellZ = cellZ
            end
        end
    end
    return grid
end

function LocalMonsterController:_getSeparation(monsterState, grid, deltaTime)
    local radius = GameConfig.MONSTER.CollisionRadius
    if radius <= 0 then
        return Vector3.zero
    end

    local separation = Vector3.zero
    local position = monsterState.Position
    if not position then
        return separation
    end

    for offsetX = -1, 1 do
        for offsetZ = -1, 1 do
            local key = tostring((monsterState.CellX or 0) + offsetX) .. ":" .. tostring((monsterState.CellZ or 0) + offsetZ)
            for _, otherState in ipairs(grid[key] or {}) do
                if otherState ~= monsterState and otherState.Alive and otherState.Position then
                    local delta = Vector3.new(position.X - otherState.Position.X, 0, position.Z - otherState.Position.Z)
                    local minDistance = radius + GameConfig.MONSTER.CollisionRadius
                    local distance = delta.Magnitude
                    if distance < minDistance then
                        local direction = distance > 0.001 and delta.Unit or Vector3.new(math.cos(tonumber(monsterState.Id) or 1), 0, math.sin(tonumber(monsterState.Id) or 1)).Unit
                        separation += direction * (minDistance - distance)
                    end
                end
            end
        end
    end

    local maxPush = math.max(0, GameConfig.MONSTER.SeparationPushSpeed * deltaTime)
    if separation.Magnitude > maxPush and maxPush > 0 then
        return separation.Unit * maxPush
    end
    return separation
end

function LocalMonsterController:_reportMonsterHitPlayer(monsterState)
    if not (self._localMonsterHitPlayerEvent and monsterState and monsterState.SpawnToken) then
        return
    end
    self._localMonsterHitPlayerEvent:FireServer({
        token = monsterState.SpawnToken,
        timestamp = os.clock(),
    })
end

function LocalMonsterController:_reportMonsterKilled(monsterState)
    if not (self._localMonsterKilledEvent and monsterState and monsterState.SpawnToken) then
        return
    end

    if monsterState.PendingKill then
        return
    end

    local requestId = tostring(self._nextKillRequestId)
    self._nextKillRequestId += 1
    monsterState.PendingKill = true
    monsterState.KillRequestId = requestId
    monsterState.KillRequestClock = os.clock()
    monsterState.Alive = false
    self._pendingKillsByRequestId[requestId] = monsterState

    self._localMonsterKilledEvent:FireServer({
        requestId = requestId,
        token = monsterState.SpawnToken,
        deathPosition = monsterState.Position or getInstancePosition(monsterState.Instance),
        timestamp = os.clock(),
    })
end

function LocalMonsterController:_handleKillAck(payload)
    if type(payload) ~= "table" then
        return
    end

    local requestId = tostring(payload.requestId or payload.RequestId or "")
    if requestId == "" then
        return
    end

    local monsterState = self._pendingKillsByRequestId[requestId]
    if not monsterState then
        return
    end
    self._pendingKillsByRequestId[requestId] = nil

    local eventType = tostring(payload.eventType or "")
    if eventType == "KillAccepted" then
        self:_destroyMonster(monsterState)
        return
    end

    warn(string.format(
        "[LocalMonsterController] 本地小怪击杀未结算经验，丢弃异常怪并补刷: reason=%s token=%s",
        tostring(payload.reason or "Unknown"),
        tostring(monsterState.SpawnToken or "")
    ))
    self:_destroyMonster(monsterState)
    self._nextSpawnClock = 0
    self:_requestSpawnTokens(1)
end

function LocalMonsterController:_retryPendingKillReports()
    if not self._localMonsterKilledEvent then
        return
    end

    local now = os.clock()
    for requestId, monsterState in pairs(self._pendingKillsByRequestId) do
        if monsterState and monsterState.SpawnToken and now - (monsterState.KillRequestClock or 0) >= KILL_ACK_RETRY_SECONDS then
            monsterState.KillRequestClock = now
            self._localMonsterKilledEvent:FireServer({
                requestId = requestId,
                token = monsterState.SpawnToken,
                deathPosition = monsterState.Position or getInstancePosition(monsterState.Instance),
                timestamp = now,
            })
        end
    end
end

function LocalMonsterController:_requestSpawnTokens(count)
    if not self._localMonsterSpawnTokenEvent then
        return
    end

    local now = os.clock()
    if self._spawnTokenRequestPending then
        if now < (self._spawnTokenRequestDeadline or 0) then
            return
        end
        self._spawnTokenRequestPending = false
    end

    if now < self._nextSpawnTokenRequestClock then
        return
    end

    local batchSize = math.max(1, math.floor(tonumber(GameConfig.MONSTER.LocalSpawnTokenRequestBatchSize) or 25))
    self._spawnTokenRequestPending = true
    self._spawnTokenRequestDeadline = now + 2
    self._nextSpawnTokenRequestClock = now + 0.2
    self._localMonsterSpawnTokenEvent:FireServer({
        count = math.clamp(math.floor(tonumber(count) or batchSize), 1, batchSize),
        timestamp = now,
    })
end

function LocalMonsterController:_handleSpawnTokenPayload(payload)
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0

    if type(payload) == "table" and (payload.eventType == "KillAccepted" or payload.eventType == "KillRejected") then
        self:_handleKillAck(payload)
        return
    end

    if not (type(payload) == "table" and payload.eventType == "Tokens" and type(payload.tokens) == "table") then
        return
    end

    for _, tokenInfo in ipairs(payload.tokens) do
        if type(tokenInfo) == "table" then
            local receivedAt = os.clock()
            local serverNow = tonumber(payload.timestamp)
            local expiresAt = tonumber(tokenInfo.expiresAt)
            local localExpiresAt = expiresAt
            if expiresAt and serverNow then
                localExpiresAt = receivedAt + math.max(0, expiresAt - serverNow)
            end

            local spawnAuthorization = {
                token = tostring(tokenInfo.token),
                monsterDefinitionId = tostring(tokenInfo.monsterDefinitionId or GameConfig.MONSTER.MonsterDefinitionId),
                expiresAt = expiresAt,
                localExpiresAt = localExpiresAt,
            }
            if isSpawnAuthorizationFresh(spawnAuthorization) then
                table.insert(self._spawnTokenQueue, spawnAuthorization)
            end
        end
    end
end

function LocalMonsterController:_applyHitKnockback(monsterState, sourcePosition)
    if not (monsterState and typeof(sourcePosition) == "Vector3" and monsterState.Position) then
        return
    end

    local direction = monsterState.Position - sourcePosition
    direction = Vector3.new(direction.X, 0, direction.Z)
    if direction.Magnitude <= 0.001 then
        direction = Vector3.new(math.cos(tonumber(monsterState.Id) or 1), 0, math.sin(tonumber(monsterState.Id) or 1))
    end

    local duration = math.max(0.03, tonumber(GameConfig.MONSTER.HitKnockbackSeconds) or 0.12)
    local distance = math.max(0, tonumber(GameConfig.MONSTER.HitKnockbackDistance) or 2.5)
    local instantDistance = math.max(0, tonumber(GameConfig.MONSTER.HitKnockbackInstantDistance) or 0)
    local knockbackDirection = direction.Unit
    if instantDistance > 0 then
        local nextPosition = self:_clampPositionInsideBattle(monsterState.Position + (knockbackDirection * instantDistance))
        nextPosition = Vector3.new(nextPosition.X, monsterState.GroundY or monsterState.Position.Y, nextPosition.Z)
        monsterState.LastPosition = nextPosition
        monsterState.Position = nextPosition
        monsterState.DisplayLookAt = monsterState.DisplayLookAt or nextPosition + knockbackDirection
    end

    monsterState.KnockbackVelocity = knockbackDirection * (distance / duration)
    monsterState.KnockbackEndClock = os.clock() + duration
    monsterState.HitStunEndClock = os.clock() + math.max(0, tonumber(GameConfig.MONSTER.HitStunSeconds) or 0.12)

    if monsterState.Instance then
        local flash = Instance.new("Highlight")
        flash.Name = "HitFlash"
        flash.Adornee = monsterState.Instance
        flash.FillColor = Color3.fromRGB(255, 255, 255)
        flash.OutlineColor = Color3.fromRGB(255, 240, 120)
        flash.FillTransparency = 0.35
        flash.OutlineTransparency = 0.1
        flash.DepthMode = Enum.HighlightDepthMode.Occluded
        flash.Parent = monsterState.Instance
        task.delay(math.max(0.03, tonumber(GameConfig.MONSTER.HitFlashSeconds) or 0.12), function()
            if flash and flash.Parent then
                flash:Destroy()
            end
        end)
    end
end

function LocalMonsterController:_createDamageNumberAnchor(monsterState, snapshotPosition, snapshotHeight)
    local position = snapshotPosition
    if typeof(position) ~= "Vector3" then
        position = monsterState and monsterState.Position
    end
    if typeof(position) ~= "Vector3" then
        local instance = monsterState and monsterState.Instance
        position = instance and getInstancePosition(instance) or Vector3.zero
    end

    local height = tonumber(snapshotHeight) or getMonsterHeight(monsterState and monsterState.Instance)
    local anchor = Instance.new("Part")
    anchor.Name = "LocalMonsterDamageNumberAnchor"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanTouch = false
    anchor.CanQuery = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.2, 0.2, 0.2)
    anchor.CFrame = CFrame.new(position + Vector3.new(0, math.max(2.5, height * 0.58 + 1), 0))
    anchor.Parent = Workspace.CurrentCamera or Workspace
    return anchor
end

function LocalMonsterController:_showDamageNumber(monsterState, amount, snapshotPosition, snapshotHeight)
    local anchor = self:_createDamageNumberAnchor(monsterState, snapshotPosition, snapshotHeight)
    local gui = Instance.new("BillboardGui")
    gui.Name = "LocalMonsterDamageNumbers_Client"
    gui.Adornee = anchor
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(180, 70)
    gui.Parent = anchor

    local textColor, strokeColor = getDamageColors(amount)
    local label = Instance.new("TextLabel")
    label.Name = "DamageNumber"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromScale(0.5 + ((math.random() - 0.5) * 0.16), 0.62)
    label.Size = UDim2.fromOffset(110, 34)
    label.Font = Enum.Font.GothamBold
    label.Text = formatDamage(amount)
    label.TextColor3 = textColor
    label.TextScaled = true
    label.TextTransparency = 0
    label.Parent = gui

    local stroke = Instance.new("UIStroke")
    stroke.Color = strokeColor
    stroke.Thickness = 2.5
    stroke.Transparency = 0
    stroke.Parent = label

    TweenService:Create(label, TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromScale(label.Position.X.Scale, 0.08),
        Size = UDim2.fromOffset(138, 42),
        TextTransparency = 1,
    }):Play()
    TweenService:Create(stroke, TweenInfo.new(0.62, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Transparency = 1,
    }):Play()

    task.delay(0.72, function()
        if anchor and anchor.Parent then
            anchor:Destroy()
        end
    end)
end

function LocalMonsterController:_queueDamageNumber(monsterState, amount)
    if not (monsterState and monsterState.Alive) then
        return
    end

    local bucket = monsterState.DamageBucket
    if not bucket then
        bucket = {
            Amount = 0,
            Position = monsterState.Position,
            Height = getMonsterHeight(monsterState.Instance),
        }
        monsterState.DamageBucket = bucket

        task.delay(LOCAL_DAMAGE_MERGE_SECONDS, function()
            if monsterState.DamageBucket ~= bucket then
                return
            end

            monsterState.DamageBucket = nil
            if bucket.Amount > 0 then
                self:_showDamageNumber(monsterState, bucket.Amount, bucket.Position, bucket.Height)
            end
        end)
    end

    bucket.Amount += math.max(0, math.floor(tonumber(amount) or 0))
    bucket.Position = monsterState.Position or bucket.Position
    bucket.Height = bucket.Height or getMonsterHeight(monsterState.Instance)
end

function LocalMonsterController:_playHitFeedback(monsterState, damage)
    if self._audioSettings and self._audioSettings.PlaySfxByPath then
        self._audioSettings:PlaySfxByPath("Audio", { "Sword", "SwordHitRelease" }, true)
    end
    self:_queueDamageNumber(monsterState, damage)
end

function LocalMonsterController:_applyWeaponHits(monsterState)
    if not (self._weaponFxController and monsterState.Alive and monsterState.Position) then
        return
    end

    local now = os.clock()
    local contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius)
    for index, weaponState in ipairs(self._weaponFxController:GetLocalWeaponStates()) do
        if weaponState.Instance and weaponState.Instance.Parent then
            local cooldownKey = tostring(index)
            local lastClock = monsterState.LastWeaponHitClockByKey[cooldownKey]
            if not lastClock or now - lastClock >= GameConfig.MONSTER.WeaponHitCooldownSeconds then
                local hitPart = weaponState.HitPart
                if hitPart and not hitPart:IsA("BasePart") then
                    hitPart = nil
                end
                local radius = contactRadius + math.max(
                    GameConfig.COMBAT.WeaponHitRadiusMin,
                    weaponState.AuraRadius or getPartCollisionReach(hitPart)
                )
                local weaponPosition = hitPart and hitPart.Position or getInstancePosition(weaponState.Instance)
                if weaponPosition and (weaponPosition - monsterState.Position).Magnitude <= radius then
                    if isWeaponHittingPosition(weaponState, monsterState.Position, contactRadius) then
                        monsterState.LastWeaponHitClockByKey[cooldownKey] = now
                        self:_applyHitKnockback(monsterState, weaponPosition)
                        local damage = math.max(0, math.floor(tonumber(weaponState.Damage) or 0))
                        local previousHealth = math.max(0, math.floor(tonumber(monsterState.CurrentHealth) or 0))
                        monsterState.CurrentHealth = math.max(0, previousHealth - damage)
                        self:_playHitFeedback(monsterState, damage)
                        if monsterState.CurrentHealth <= 0 then
                            self:_reportMonsterKilled(monsterState)
                            return
                        end
                    end
                end
            end
        end
    end
end

function LocalMonsterController:_stepMonster(monsterState, grid, deltaTime)
    if not (monsterState.Alive and monsterState.Instance and monsterState.Instance.Parent) then
        return
    end

    local rootPart = getCharacterRoot(self._localPlayer)
    if not rootPart then
        return
    end

    local position = monsterState.Position or getInstancePosition(monsterState.Instance)
    if not position then
        return
    end

    local toPlayer = rootPart.Position - position
    local planar = Vector3.new(toPlayer.X, 0, toPlayer.Z)
    local distance = planar.Magnitude
    local movement = Vector3.zero
    local knockback = Vector3.zero
    local attackRange = getMonsterValue(monsterState, "AttackRange", GameConfig.MONSTER.AttackRange)
    local contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius)
    local attackCooldown = getMonsterValue(monsterState, "AttackCooldownSeconds", GameConfig.MONSTER.AttackCooldownSeconds)
    local moveSpeed = getMonsterValue(monsterState, "MoveSpeed", GameConfig.MONSTER.MoveSpeed)
    local hasTarget = distance <= attackRange

    if monsterState.KnockbackEndClock and os.clock() < monsterState.KnockbackEndClock then
        knockback = (monsterState.KnockbackVelocity or Vector3.zero) * deltaTime
    else
        monsterState.KnockbackVelocity = Vector3.zero
    end

    if not hasTarget then
        setLoop(monsterState, "Idle")
        self:_applyWeaponHits(monsterState)
        if knockback.Magnitude > 0 then
            local nextPosition = self:_clampPositionInsideBattle(position + knockback)
            nextPosition = Vector3.new(nextPosition.X, monsterState.GroundY or position.Y, nextPosition.Z)
            monsterState.LastPosition = nextPosition
            monsterState.Position = nextPosition
            monsterState.DisplayLookAt = nextPosition + knockback
        end
        return
    end

    local attackAnimationRadius = math.max(contactRadius, contactRadius + 3)
    if distance <= attackAnimationRadius then
        local now = os.clock()
        if now - (monsterState.LastAttackAnimationClock or 0) >= attackCooldown then
            monsterState.LastAttackAnimationClock = now
            playAttack(monsterState)
        end

        if distance <= contactRadius and now - monsterState.LastAttackClock >= attackCooldown then
            monsterState.LastAttackClock = now
            self:_reportMonsterHitPlayer(monsterState)
        end
    end

    local isHitStunned = monsterState.HitStunEndClock and os.clock() < monsterState.HitStunEndClock
    if not isHitStunned and distance > contactRadius and distance > 0 then
        local stepDistance = math.min(distance, moveSpeed * deltaTime)
        movement = planar.Unit * stepDistance
    end

    local separation = self:_getSeparation(monsterState, grid, deltaTime)
    if movement.Magnitude <= 0 and separation.Magnitude <= 0 and knockback.Magnitude <= 0 then
        setLoop(monsterState, "Idle")
        self:_applyWeaponHits(monsterState)
        return
    end

    local nextPosition = self:_clampPositionInsideBattle(position + movement + separation + knockback)
    nextPosition = Vector3.new(nextPosition.X, monsterState.GroundY or position.Y, nextPosition.Z)
    monsterState.DisplayLookAt = Vector3.new(rootPart.Position.X, nextPosition.Y, rootPart.Position.Z)

    local speed = (nextPosition - (monsterState.LastPosition or position)).Magnitude / math.max(deltaTime, 0.001)
    monsterState.LastPosition = nextPosition
    monsterState.Position = nextPosition
    setLoop(monsterState, speed > MOVING_SPEED_THRESHOLD and "Run" or "Idle")
    self:_applyWeaponHits(monsterState)
end

function LocalMonsterController:_updateMonsterVisual(monsterState, deltaTime)
    if not (monsterState and monsterState.Alive and monsterState.Instance and monsterState.Instance.Parent) then
        return
    end

    local targetPosition = monsterState.Position
    if typeof(targetPosition) ~= "Vector3" then
        return
    end

    local displayPosition = monsterState.DisplayPosition
    if typeof(displayPosition) ~= "Vector3" then
        displayPosition = getInstancePosition(monsterState.Instance) or targetPosition
    end

    local distance = (targetPosition - displayPosition).Magnitude
    if distance >= VISUAL_SNAP_DISTANCE then
        displayPosition = targetPosition
    else
        local alpha = 1 - math.exp(-VISUAL_FOLLOW_SPEED * math.max(0, deltaTime))
        displayPosition = displayPosition:Lerp(targetPosition, math.clamp(alpha, 0, 1))
    end

    monsterState.DisplayPosition = displayPosition
    local cframe = getPlanarLookAtCFrame(displayPosition, monsterState.DisplayLookAt)
    if cframe then
        setInstanceCFrame(monsterState.Instance, cframe)
    end
end

function LocalMonsterController:_updateVisuals(deltaTime)
    for _, monsterState in pairs(self._monstersById) do
        self:_updateMonsterVisual(monsterState, deltaTime)
    end
end

function LocalMonsterController:_step(deltaTime)
    self:_retryPendingKillReports()
    self:_maintainPopulation()
    if not (self._latestPlayerState and self._latestPlayerState.isInArena and self._latestPlayerState.alive) then
        self._simulationAccumulator = 0
        for _, monsterState in pairs(self._monstersById) do
            if monsterState.Alive then
                setLoop(monsterState, "Idle")
                monsterState.DisplayPosition = monsterState.Position or getInstancePosition(monsterState.Instance)
                monsterState.DisplayLookAt = nil
            end
        end
        return
    end

    local tickSeconds = getLocalSimulationTickSeconds()
    self._simulationAccumulator = math.min((self._simulationAccumulator or 0) + deltaTime, 0.2)
    if self._simulationAccumulator < tickSeconds then
        return
    end

    self._simulationAccumulator -= tickSeconds
    local stepDelta = math.min(tickSeconds, 0.2)
    local grid = self:_buildSpatialGrid()
    for _, monsterState in pairs(self._monstersById) do
        self:_stepMonster(monsterState, grid, stepDelta)
    end
end

function LocalMonsterController:FindNearestAliveMonster(originPosition, minimumPlanarDistance, excludedIds)
    if typeof(originPosition) ~= "Vector3" then
        return nil
    end

    local minimumDistance = math.max(0, tonumber(minimumPlanarDistance) or 0)
    local nearestMonsterState = nil
    local nearestDistanceSq = math.huge
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive
            and monsterState.Instance
            and monsterState.Instance.Parent
            and not (excludedIds and excludedIds[monsterState.Id])
        then
            local position = monsterState.Position or getInstancePosition(monsterState.Instance)
            if position then
                monsterState.Position = position
                local deltaX = position.X - originPosition.X
                local deltaZ = position.Z - originPosition.Z
                local distanceSq = (deltaX * deltaX) + (deltaZ * deltaZ)
                if distanceSq < nearestDistanceSq and distanceSq >= minimumDistance * minimumDistance then
                    nearestMonsterState = monsterState
                    nearestDistanceSq = distanceSq
                end
            end
        end
    end

    if not nearestMonsterState then
        return nil
    end

    return {
        id = nearestMonsterState.Id,
        monsterDefinitionId = nearestMonsterState.MonsterDefinitionId,
        position = nearestMonsterState.Position,
        contactRadius = getMonsterValue(nearestMonsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius),
        planarDistance = math.sqrt(nearestDistanceSq),
    }
end

function LocalMonsterController:GetAliveMonsterSnapshotById(monsterId)
    if monsterId == nil then
        return nil
    end

    local monsterState = self._monstersById[monsterId]
    if not (monsterState and monsterState.Alive and monsterState.Instance and monsterState.Instance.Parent) then
        return nil
    end

    local position = monsterState.Position or getInstancePosition(monsterState.Instance)
    if not position then
        return nil
    end

    monsterState.Position = position
    return {
        id = monsterState.Id,
        monsterDefinitionId = monsterState.MonsterDefinitionId,
        position = monsterState.Position,
        contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius),
    }
end

function LocalMonsterController:FindNearestAliveMonsterOutsideWeaponRange(originPosition, weaponRange, excludedIds)
    if typeof(originPosition) ~= "Vector3" then
        return nil
    end

    local normalizedWeaponRange = math.max(0, tonumber(weaponRange) or 0)
    local nearestMonsterState = nil
    local nearestDistanceSq = math.huge
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive
            and monsterState.Instance
            and monsterState.Instance.Parent
            and not (excludedIds and excludedIds[monsterState.Id])
        then
            local position = monsterState.Position or getInstancePosition(monsterState.Instance)
            if position then
                monsterState.Position = position
                local deltaX = position.X - originPosition.X
                local deltaZ = position.Z - originPosition.Z
                local distanceSq = (deltaX * deltaX) + (deltaZ * deltaZ)
                local contactRadius = math.max(0, tonumber(getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius)) or 0)
                local attackRange = normalizedWeaponRange + contactRadius
                if distanceSq > attackRange * attackRange and distanceSq < nearestDistanceSq then
                    nearestMonsterState = monsterState
                    nearestDistanceSq = distanceSq
                end
            end
        end
    end

    if not nearestMonsterState then
        return nil
    end

    return {
        id = nearestMonsterState.Id,
        monsterDefinitionId = nearestMonsterState.MonsterDefinitionId,
        position = nearestMonsterState.Position,
        contactRadius = getMonsterValue(nearestMonsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius),
        planarDistance = math.sqrt(nearestDistanceSq),
    }
end

function LocalMonsterController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._weaponFxController = dependencies and dependencies.WeaponFxController or nil
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    self._battlePart = self:_resolveBattlePart()
    self._monstersById = {}
    self._spawnTokenQueue = {}
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0
    self._nextSpawnTokenRequestClock = 0
    self._nextMonsterId = 1
    self._nextKillRequestId = 1
    self._nextSpawnClock = 0
    self._simulationAccumulator = 0
    self._pendingKillsByRequestId = {}
    self:_createMonsterFolder()

    disconnectAll(self._connections)
    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local battleEventsFolder = eventsFolder:WaitForChild(RemoteNames.BattleEventsFolder)
    self._localMonsterSpawnTokenEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.LocalMonsterSpawnToken)
    self._localMonsterKilledEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.LocalMonsterKilled)
    self._localMonsterHitPlayerEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.LocalMonsterHitPlayer)
    self._nukeLocalMonsterSweepEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.NukeLocalMonsterSweep)

    table.insert(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync).OnClientEvent:Connect(function(payload)
        self._latestPlayerState = payload
    end))

    table.insert(self._connections, self._localMonsterSpawnTokenEvent.OnClientEvent:Connect(function(payload)
        self:_handleSpawnTokenPayload(payload)
    end))

    table.insert(self._connections, self._localMonsterKilledEvent.OnClientEvent:Connect(function(payload)
        self:_handleKillAck(payload)
    end))

    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        requestStateSyncEvent:FireServer()
    end

    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        if not GameConfig.MONSTER.ClientOwnedNormalMonsters then
            return
        end
        if not (self._battlePart and self._battlePart.Parent) then
            self._battlePart = self:_resolveBattlePart()
        end
        self:_step(deltaTime)
        self:_updateVisuals(deltaTime)
    end)
end

return LocalMonsterController
