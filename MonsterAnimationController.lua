--[[
脚本名字: MonsterAnimationController
脚本文件: MonsterAnimationController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/MonsterAnimationController
说明: 客户端隐藏服务端怪物判定体，并创建本地视觉怪物做平滑跟随与动作播放。
]]

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
        "[MonsterAnimationController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local MonsterAnimationController = {}

MonsterAnimationController._monsterFolder = nil
MonsterAnimationController._visualFolder = nil
MonsterAnimationController._renderConnection = nil
MonsterAnimationController._folderConnections = {}
MonsterAnimationController._statesByInstance = {}
MonsterAnimationController._rescanClock = 0

local LOOP_FADE_SECONDS = 0.15
local ATTACK_FADE_SECONDS = 0.05
local MOVING_SPEED_THRESHOLD = 0.5
local RESCAN_INTERVAL_SECONDS = 5
local SMOOTH_FOLLOW_SPEED = 18
local SNAP_DISTANCE = 24
local ORIGINAL_TRANSPARENCY_ATTRIBUTE = "__ClientOriginalTransparency"

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findOrCreateLocalFolder(parent, folderName)
    local folder = parent:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
end

local function getMonsterCFrame(instance)
    if instance:IsA("Model") then
        return instance:GetPivot()
    end
    if instance:IsA("BasePart") then
        return instance.CFrame
    end
    return nil
end

local function setMonsterCFrame(instance, cframe)
    if instance:IsA("Model") then
        local rootPart = instance.PrimaryPart or instance:FindFirstChild("Root", true)
        if rootPart and rootPart:IsA("BasePart") then
            rootPart.CFrame = cframe
        else
            instance:PivotTo(cframe)
        end
    elseif instance:IsA("BasePart") then
        instance.CFrame = cframe
    end
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

local function setAuthorityVisibility(instance, isVisible)
    local modifier = isVisible and 0 or 1
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.LocalTransparencyModifier = modifier
        elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
            if descendant:GetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE) == nil then
                descendant:SetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE, descendant.Transparency)
            end
            if isVisible then
                descendant.Transparency = descendant:GetAttribute(ORIGINAL_TRANSPARENCY_ATTRIBUTE) or 0
            else
                descendant.Transparency = 1
            end
        end
    end
end

local function stripRuntimeOnlyDescendants(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        end
    end
end

local function configureVisualInstance(instance)
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

local function collectFaceMotors(instance)
    local motors = {}
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Motor6D")
            and descendant.Part0
            and descendant.Part1
            and descendant.Part1.Name == "AnimatedFace" then
            table.insert(motors, descendant)
        end
    end
    return motors
end

local function resolveAnimator(instance)
    local animator = instance:FindFirstChildWhichIsA("Animator", true)
    if animator then
        return animator
    end

    local humanoid = instance:FindFirstChildOfClass("Humanoid")
    if humanoid then
        animator = Instance.new("Animator")
        animator.Name = "ClientMonsterAnimator"
        animator.Parent = humanoid
        return animator
    end

    if instance:IsA("Model") then
        local animationController = instance:FindFirstChildOfClass("AnimationController")
        if not animationController then
            animationController = Instance.new("AnimationController")
            animationController.Name = "ClientAnimationController"
            animationController.Parent = instance
        end

        animator = Instance.new("Animator")
        animator.Name = "ClientMonsterAnimator"
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
            "[MonsterAnimationController] 模板内动画注册失败: template=%s animation=%s",
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
            "[MonsterAnimationController] 动画加载失败: %s (%s)",
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

function MonsterAnimationController:_createVisualFolder()
    local runtimeRoot = findOrCreateLocalFolder(Workspace, "Runtime")
    local folder = findOrCreateLocalFolder(runtimeRoot, GameConfig.MONSTER.RuntimeFolderName .. "_Client")
    folder:ClearAllChildren()
    self._visualFolder = folder
end

function MonsterAnimationController:_resolveMonsterFolder()
    local runtimeRoot = Workspace:FindFirstChild("Runtime")
    local folder = runtimeRoot and runtimeRoot:FindFirstChild(GameConfig.MONSTER.RuntimeFolderName)
    if self._monsterFolder == folder then
        return folder
    end

    disconnectAll(self._folderConnections)
    self._monsterFolder = folder

    if folder then
        table.insert(self._folderConnections, folder.ChildAdded:Connect(function(child)
            self:_trackMonster(child)
        end))
        table.insert(self._folderConnections, folder.ChildRemoved:Connect(function(child)
            self:_untrackMonster(child)
        end))
        self:_scanMonsters()
    end

    return folder
end

function MonsterAnimationController:_resolveDefinition(instance)
    local definitionId = instance:GetAttribute("MonsterDefinitionId")
    local templateName = instance:GetAttribute("MonsterTemplateName") or instance.Name
    return MonsterCatalog.GetDefinition(definitionId)
        or MonsterCatalog.GetDefinitionByTemplateName(templateName)
end

function MonsterAnimationController:_resolveTemplate(definition, authorityInstance)
    local templateName = definition and definition.TemplateName
        or authorityInstance:GetAttribute("MonsterTemplateName")
    if not templateName then
        return nil
    end

    local modelRoot = ReplicatedStorage:FindFirstChild(GameConfig.MONSTER.ModelRootFolderName)
    local monsterFolder = modelRoot and modelRoot:FindFirstChild(GameConfig.MONSTER.MonsterFolderName)
    local template = monsterFolder and monsterFolder:FindFirstChild(templateName)
    if template and (template:IsA("Model") or template:IsA("BasePart")) then
        return template
    end
    return nil
end

function MonsterAnimationController:_createVisualInstance(authorityInstance, definition)
    if not self._visualFolder then
        self:_createVisualFolder()
    end

    local template = self:_resolveTemplate(definition, authorityInstance)
    local source = template or authorityInstance
    local previousArchivable = source.Archivable
    source.Archivable = true

    local didClone, visualInstance = pcall(function()
        return source:Clone()
    end)
    source.Archivable = previousArchivable

    if not didClone or not visualInstance then
        return nil
    end

    visualInstance.Name = authorityInstance.Name .. "_ClientVisual"
    configureVisualInstance(visualInstance)

    local startCFrame = getMonsterCFrame(authorityInstance)
    if startCFrame then
        setMonsterCFrame(visualInstance, startCFrame)
    end

    visualInstance.Parent = self._visualFolder
    return visualInstance
end

function MonsterAnimationController:_loadMonsterTracks(visualInstance, definition)
    if not definition then
        return nil
    end

    local animator = resolveAnimator(visualInstance)
    if not animator then
        return nil
    end

    local animations = definition.Animations or {}
    return {
        Idle = loadTrack(animator, visualInstance, "Idle", animations.Idle, true, Enum.AnimationPriority.Idle),
        Run = loadTrack(animator, visualInstance, "Run", animations.Run, true, Enum.AnimationPriority.Movement),
        Attack = loadTrack(animator, visualInstance, "Attack", animations.Attack, false, Enum.AnimationPriority.Action),
    }
end

function MonsterAnimationController:_trackMonster(instance)
    if self._statesByInstance[instance] then
        return
    end
    if not (instance:IsA("Model") or instance:IsA("BasePart")) then
        return
    end
    if not instance:GetAttribute("MonsterId") then
        return
    end
    if instance:GetAttribute("IsClientLocalMonster") then
        return
    end

    local definition = self:_resolveDefinition(instance)
    if not definition then
        return
    end

    local visualInstance = self:_createVisualInstance(instance, definition)
    if not visualInstance then
        return
    end

    local tracks = self:_loadMonsterTracks(visualInstance, definition)
    if not tracks then
        visualInstance:Destroy()
        return
    end

    local startCFrame = getMonsterCFrame(instance)
    setAuthorityVisibility(instance, false)

    local state = {
        AuthorityInstance = instance,
        VisualInstance = visualInstance,
        Tracks = tracks,
        FaceMotors = collectFaceMotors(visualInstance),
        CurrentLoopName = nil,
        CurrentCFrame = startCFrame,
        LastVisualPosition = startCFrame and startCFrame.Position or nil,
        LastAttackSerial = tonumber(instance:GetAttribute("AttackSerial")) or 0,
        Connections = {},
    }

    table.insert(state.Connections, instance:GetAttributeChangedSignal("AttackSerial"):Connect(function()
        self:_playAttack(state)
    end))

    self._statesByInstance[instance] = state
    self:_setLoop(state, "Idle")
end

function MonsterAnimationController:_untrackMonster(instance)
    local state = self._statesByInstance[instance]
    if not state then
        return
    end

    disconnectAll(state.Connections)
    if state.AuthorityInstance and state.AuthorityInstance.Parent then
        setAuthorityVisibility(state.AuthorityInstance, true)
    end
    for _, track in pairs(state.Tracks) do
        if track then
            track:Stop(0)
            track:Destroy()
        end
    end
    if state.VisualInstance and state.VisualInstance.Parent then
        state.VisualInstance:Destroy()
    end
    self._statesByInstance[instance] = nil
end

function MonsterAnimationController:_scanMonsters()
    if not self._monsterFolder then
        return
    end

    for _, child in ipairs(self._monsterFolder:GetChildren()) do
        self:_trackMonster(child)
    end

    for instance in pairs(self._statesByInstance) do
        if instance.Parent ~= self._monsterFolder then
            self:_untrackMonster(instance)
        end
    end
end

function MonsterAnimationController:_setLoop(state, loopName)
    if state.CurrentLoopName == loopName then
        return
    end

    for name, track in pairs(state.Tracks) do
        if name ~= "Attack" and track then
            if name == loopName then
                if not track.IsPlaying then
                    track:Play(LOOP_FADE_SECONDS)
                end
            else
                track:Stop(LOOP_FADE_SECONDS)
            end
        end
    end

    state.CurrentLoopName = loopName
end

function MonsterAnimationController:_playAttack(state)
    local authorityInstance = state.AuthorityInstance
    if not authorityInstance then
        return
    end

    local attackSerial = tonumber(authorityInstance:GetAttribute("AttackSerial")) or 0
    if attackSerial <= state.LastAttackSerial then
        return
    end
    state.LastAttackSerial = attackSerial

    local attackTrack = state.Tracks.Attack
    if attackTrack then
        attackTrack:Stop(0)
        attackTrack:Play(ATTACK_FADE_SECONDS)
    end
end

function MonsterAnimationController:_syncFaceMotors(state)
    for _, motor in ipairs(state.FaceMotors or {}) do
        if motor.Part0 and motor.Part1 then
            motor.Part1.CFrame = motor.Part0.CFrame
                * motor.C0
                * motor.Transform
                * motor.C1:Inverse()
        end
    end
end

function MonsterAnimationController:_stepMonster(state, deltaTime)
    local authorityInstance = state.AuthorityInstance
    local visualInstance = state.VisualInstance
    if not (authorityInstance and authorityInstance.Parent and visualInstance and visualInstance.Parent) then
        self:_untrackMonster(authorityInstance)
        return
    end

    setAuthorityVisibility(authorityInstance, false)

    local targetCFrame = getMonsterCFrame(authorityInstance)
    if not targetCFrame then
        return
    end

    local currentCFrame = state.CurrentCFrame or targetCFrame
    local distance = (targetCFrame.Position - currentCFrame.Position).Magnitude
    if distance >= SNAP_DISTANCE then
        currentCFrame = targetCFrame
    else
        local alpha = 1 - math.exp(-SMOOTH_FOLLOW_SPEED * math.max(0, deltaTime))
        currentCFrame = currentCFrame:Lerp(targetCFrame, math.clamp(alpha, 0, 1))
    end

    state.CurrentCFrame = currentCFrame
    setMonsterCFrame(visualInstance, currentCFrame)
    self:_syncFaceMotors(state)

    local lastVisualPosition = state.LastVisualPosition or currentCFrame.Position
    local speed = 0
    if deltaTime > 0 then
        speed = (currentCFrame.Position - lastVisualPosition).Magnitude / deltaTime
    end
    state.LastVisualPosition = currentCFrame.Position

    if speed > MOVING_SPEED_THRESHOLD then
        self:_setLoop(state, "Run")
    else
        self:_setLoop(state, "Idle")
    end
end

function MonsterAnimationController:Init()
    disconnectAll(self._folderConnections)
    for instance in pairs(self._statesByInstance) do
        self:_untrackMonster(instance)
    end

    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end

    self._monsterFolder = nil
    self._rescanClock = 0
    self:_createVisualFolder()
    self:_resolveMonsterFolder()
    self._rescanClock = os.clock() + RESCAN_INTERVAL_SECONDS

    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        local now = os.clock()
        if now >= self._rescanClock then
            self._rescanClock = now + RESCAN_INTERVAL_SECONDS
            self:_resolveMonsterFolder()
            self:_scanMonsters()
        end

        for _, state in pairs(self._statesByInstance) do
            self:_stepMonster(state, deltaTime)
        end
    end)
end

return MonsterAnimationController
