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
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local StatsService = game:GetService("Stats")

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
LocalMonsterController._safePart = nil
LocalMonsterController._connections = {}
LocalMonsterController._renderConnection = nil
LocalMonsterController._localMonsterSpawnTokenEvent = nil
LocalMonsterController._localMonsterKilledEvent = nil
LocalMonsterController._localMonsterHitPlayerEvent = nil
LocalMonsterController._latestPlayerState = nil
LocalMonsterController._wasActiveInArena = false
LocalMonsterController._monstersById = {}
LocalMonsterController._spawnTokenQueue = {}
LocalMonsterController._spawnTokenRequestPending = false
LocalMonsterController._spawnTokenRequestDeadline = 0
LocalMonsterController._nextSpawnTokenRequestClock = 0
LocalMonsterController._safeZoneRespawnDebt = 0
LocalMonsterController._nextMonsterId = 1
LocalMonsterController._nextKillRequestId = 1
LocalMonsterController._nextSpawnClock = 0
LocalMonsterController._simulationAccumulator = 0
LocalMonsterController._nukeLocalMonsterSweepEvent = nil
LocalMonsterController._pendingKillsByRequestId = {}
LocalMonsterController._pendingKillReportFlushClock = 0
LocalMonsterController._visualFrameIndex = 0
LocalMonsterController._simulationFrameIndex = 0
LocalMonsterController._localWeaponHitSnapshots = {}
LocalMonsterController._perfStats = nil
LocalMonsterController._nextPerfLogClock = 0
LocalMonsterController._monsterModelPoolByKey = {}
LocalMonsterController._monsterModelPoolCount = 0
LocalMonsterController._materializedMonsterCount = 0
LocalMonsterController._damageNumberPool = {}
LocalMonsterController._activeDamageNumberVisuals = {}
LocalMonsterController._damageNumberPoolCreated = 0
LocalMonsterController._activeDamageNumberCount = 0
LocalMonsterController._damageNumberWindowClock = 0
LocalMonsterController._damageNumberWindowCount = 0

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
local HIT_FLASH_REFRESH_SECONDS = 0.08
local GUI_DIAGNOSTIC_TOP_LIMIT = 8
local GUI_DIAGNOSTIC_IMAGE_LIMIT = 8
local GUI_DIAGNOSTIC_CLASS_NAMES = {
    "ScreenGui",
    "Frame",
    "CanvasGroup",
    "ScrollingFrame",
    "TextLabel",
    "TextButton",
    "ImageLabel",
    "ImageButton",
    "TextBox",
    "UIStroke",
    "UIGradient",
    "UICorner",
    "UIScale",
    "BillboardGui",
    "ViewportFrame",
}
local memoryTrackingSetupAttempted = false

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 5)
end

local function getLocalSimulationTickSeconds()
    local configuredTick = tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalSimulationTickSeconds) or 0
    if configuredTick > 0 then
        return configuredTick
    end
    return DEFAULT_LOCAL_SIMULATION_TICK_SECONDS
end

local function getLocalVisualNearDistance()
    return math.max(0, tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalVisualNearDistance) or 75)
end

local function getLocalVisualFarUpdateStride()
    return math.max(1, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalVisualFarUpdateStride) or 1))
end

local function getLocalFarSimulationStride()
    return math.max(1, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalFarSimulationStride) or 1))
end

local function getLocalAnimationNearDistance()
    return math.max(0, tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalAnimationNearDistance) or getLocalVisualNearDistance())
end

local function getLocalCombatSleepPadding()
    return math.max(0, tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalCombatSleepPadding) or 15)
end

local function getLocalDamageNumberPoolSize()
    return math.max(0, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalDamageNumberPoolSize) or 40))
end

local function getLocalDamageNumbersPerSecond()
    return math.max(0, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalDamageNumbersPerSecond) or 18))
end

local function getLocalMonsterModelPoolSize()
    return math.max(0, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalMonsterModelPoolSize) or 80))
end

local function getLocalMaxVisibleMonsters()
    local maxActiveCount = tonumber(GameConfig.MONSTER and GameConfig.MONSTER.MaxActiveCount) or 0
    if maxActiveCount > 0 then
        return math.max(1, math.floor(maxActiveCount))
    end
    return 300
end

local function getLocalMaxCombatActiveMonsters()
    return math.max(1, math.floor(
        tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalMaxCombatActiveMonsters)
        or tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalMaxMaterializedMonsters)
        or 40
    ))
end

local function getLocalKillReportBatchSize()
    return math.max(1, math.floor(tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalKillReportBatchSize) or 16))
end

local function getLocalKillReportBatchIntervalSeconds()
    return math.max(0.03, tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalKillReportBatchIntervalSeconds) or 0.12)
end

local function getLocalKillReportMaxPendingSeconds()
    return math.max(2, tonumber(GameConfig.MONSTER and GameConfig.MONSTER.LocalKillReportMaxPendingSeconds) or 8)
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
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Animator") or descendant:IsA("AnimationController") then
            descendant:Destroy()
        end
    end

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

local function clearTransientMonsterVisuals(instance)
    if not instance then
        return
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant.Name == "HitFlash" and descendant:IsA("Highlight") then
            descendant:Destroy()
        end
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
local failedKeyframeAnimationRegistrations = {}

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
    if failedKeyframeAnimationRegistrations[cacheKey] then
        return nil
    end

    local didRegister, animationId = pcall(function()
        return KeyframeSequenceProvider:RegisterKeyframeSequence(keyframeSequence)
    end)
    if not didRegister or not animationId then
        failedKeyframeAnimationRegistrations[cacheKey] = true
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
    local track = loadTrackFromAnimationId(
        animator,
        animationId,
        isLooped,
        priority,
        "MonsterCatalog." .. tostring(animationName)
    )
    if track then
        return track
    end

    local fallbackAnimationId = getRegisteredKeyframeAnimationId(instance, animationName)
    return fallbackAnimationId and loadTrackFromAnimationId(
        animator,
        fallbackAnimationId,
        isLooped,
        priority,
        "AnimSaves." .. tostring(animationName)
    ) or nil
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
    if monsterState.AnimationsEnabled == false then
        return
    end

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
    if monsterState.AnimationsEnabled == false then
        return
    end

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

function LocalMonsterController:_resolveSafePart()
    local arenaConfig = GameConfig.ARENA or {}
    local safePartName = tostring(arenaConfig.SafePartName or "Safe")
    if safePartName == "" then
        return nil
    end

    local battleMapName = tostring(arenaConfig.BattleMapName or "")
    if battleMapName ~= "" then
        local battleMap = Workspace:FindFirstChild(battleMapName)
        if battleMap then
            local safePart = battleMap:FindFirstChild(safePartName)
            if safePart and safePart:IsA("BasePart") then
                return safePart
            end
        end
    end

    if self._battlePart and self._battlePart.Parent then
        local siblingSafePart = self._battlePart.Parent:FindFirstChild(safePartName)
        if siblingSafePart and siblingSafePart:IsA("BasePart") then
            return siblingSafePart
        end
    end

    local safePart = Workspace:FindFirstChild(safePartName, true)
    if safePart and safePart:IsA("BasePart") then
        return safePart
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
    if not template then
        return groundY
    end
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

function LocalMonsterController:GetSafePart()
    if not (self._safePart and self._safePart.Parent) then
        self._safePart = self:_resolveSafePart()
    end
    return self._safePart
end

function LocalMonsterController:_getSafeZoneVerticalPadding()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(0, tonumber(arenaConfig.SafeZoneVerticalPadding) or 12)
end

function LocalMonsterController:_buildSafeZoneCheckContext()
    local safePart = self:GetSafePart()
    if not safePart then
        return nil
    end

    return {
        SafePart = safePart,
        CFrame = safePart.CFrame,
        HalfSize = safePart.Size * 0.5,
        VerticalPadding = self:_getSafeZoneVerticalPadding(),
    }
end

function LocalMonsterController:_isPositionInsideSafeZoneWithContext(position, context)
    if not (context and typeof(position) == "Vector3") then
        return false
    end

    local localPosition = context.CFrame:PointToObjectSpace(position)
    local halfSize = context.HalfSize
    local verticalPadding = context.VerticalPadding
    return math.abs(localPosition.X) <= halfSize.X
        and math.abs(localPosition.Z) <= halfSize.Z
        and localPosition.Y >= -halfSize.Y - verticalPadding
        and localPosition.Y <= halfSize.Y + verticalPadding
end

function LocalMonsterController:IsPositionInsideSafeZone(position)
    return self:_isPositionInsideSafeZoneWithContext(position, self:_buildSafeZoneCheckContext())
end

function LocalMonsterController:_samplePointInsideSafeZone()
    local safePart = self:GetSafePart()
    if not safePart then
        return nil
    end

    local arenaConfig = GameConfig.ARENA or {}
    local size = safePart.Size
    local padding = math.max(0, tonumber(arenaConfig.SafeSpawnPadding) or 0)
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localX = 0
    local localZ = 0

    if usableHalfX > 0 then
        localX = (math.random() * 2 - 1) * usableHalfX
    end
    if usableHalfZ > 0 then
        localZ = (math.random() * 2 - 1) * usableHalfZ
    end

    local worldPoint = (safePart.CFrame * CFrame.new(localX, 0, localZ)).Position
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
    if not (instance and instance.Parent) then
        return {}
    end

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

local function hasMonsterAnimationTracks(tracks)
    return tracks and (tracks.Idle ~= nil or tracks.Run ~= nil or tracks.Attack ~= nil)
end

function LocalMonsterController:_ensureMonsterTracks(monsterState)
    if not (monsterState and monsterState.Instance and monsterState.Instance.Parent) then
        return false
    end

    local tracks = monsterState.Tracks
    if hasMonsterAnimationTracks(tracks) then
        monsterState.TracksLoadAttempted = true
        monsterState.TracksLoadFailed = false
        return true
    end
    if monsterState.TracksLoadFailed == true then
        return false
    end
    if monsterState.TracksLoadAttempted == true then
        return false
    end

    monsterState.TracksLoadAttempted = true
    monsterState.Tracks = self:_loadTracks(
        monsterState.Instance,
        MonsterCatalog.GetDefinition(monsterState.MonsterDefinitionId)
    )
    tracks = monsterState.Tracks
    if hasMonsterAnimationTracks(tracks) then
        monsterState.TracksLoadFailed = false
        return true
    end
    monsterState.TracksLoadFailed = true
    return false
end

function LocalMonsterController:_getModelPoolKey(monsterDefinitionId, monsterTemplateName)
    return tostring(monsterDefinitionId or "") .. ":" .. tostring(monsterTemplateName or "")
end

function LocalMonsterController:_takePooledMonsterInstance(monsterDefinitionId, monsterTemplateName)
    local key = self:_getModelPoolKey(monsterDefinitionId, monsterTemplateName)
    local pool = self._monsterModelPoolByKey and self._monsterModelPoolByKey[key]
    local entry = pool and table.remove(pool)
    if not entry then
        return nil, nil
    end

    self._monsterModelPoolCount = math.max(0, (self._monsterModelPoolCount or 0) - 1)
    self:_addPerfStat("PoolTakes")
    local instance = entry.Instance
    if not (instance and instance.Parent == nil) then
        return nil, nil
    end

    return instance, entry.Tracks or {}
end

function LocalMonsterController:_markMonsterMaterialized(monsterState)
    if not monsterState or monsterState.IsMaterialized then
        return
    end
    monsterState.IsMaterialized = true
    self._materializedMonsterCount = (self._materializedMonsterCount or 0) + 1
end

function LocalMonsterController:_markMonsterDematerialized(monsterState)
    if not monsterState or not monsterState.IsMaterialized then
        return
    end
    monsterState.IsMaterialized = false
    self._materializedMonsterCount = math.max(0, (self._materializedMonsterCount or 0) - 1)
end

function LocalMonsterController:_clearMonsterModelPool()
    for _, pool in pairs(self._monsterModelPoolByKey or {}) do
        for _, entry in ipairs(pool) do
            self:_destroyMonsterTracks(entry)
            if entry.Instance then
                entry.Instance:Destroy()
            end
        end
    end
    self._monsterModelPoolByKey = {}
    self._monsterModelPoolCount = 0
end

function LocalMonsterController:_createMaterializedMonsterInstance(monsterState)
    if not monsterState then
        return nil, nil
    end
    if typeof(monsterState.Position) ~= "Vector3" then
        return nil, nil
    end

    local instance, tracks = self:_takePooledMonsterInstance(monsterState.MonsterDefinitionId, monsterState.MonsterTemplateName)
    if not instance then
        local monsterDefinition = MonsterCatalog.GetDefinition(monsterState.MonsterDefinitionId)
            or MonsterCatalog.GetDefinition(GameConfig.MONSTER.MonsterDefinitionId)
        local template = self:_resolveTemplate(monsterDefinition)
        instance = template and template:Clone() or self:_createFallbackMonster(monsterDefinition)
        tracks = nil
        configureMonsterInstance(instance)
    end

    monsterState.GroundY = self:_getGroundY(instance)
    monsterState.Position = Vector3.new(monsterState.Position.X, monsterState.GroundY or monsterState.Position.Y, monsterState.Position.Z)
    monsterState.DisplayPosition = monsterState.Position
    instance.Name = "LocalMonster_" .. tostring(monsterState.Id)
    instance:SetAttribute("MonsterId", monsterState.Id)
    instance:SetAttribute("MonsterDefinitionId", monsterState.MonsterDefinitionId)
    instance:SetAttribute("MonsterTemplateName", monsterState.MonsterTemplateName)
    instance:SetAttribute("MonsterType", monsterState.MonsterType)
    instance:SetAttribute("IsClientLocalMonster", true)
    setInstanceCFrame(instance, getPlanarLookAtCFrame(monsterState.Position, monsterState.DisplayLookAt) or CFrame.new(monsterState.Position))
    instance.Parent = self._monsterFolder

    monsterState.Instance = instance
    monsterState.Tracks = tracks or {}
    monsterState.TracksLoadAttempted = hasMonsterAnimationTracks(monsterState.Tracks)
    monsterState.TracksLoadFailed = false
    self:_markMonsterMaterialized(monsterState)
    return instance, monsterState.Tracks
end

function LocalMonsterController:_materializeMonster(monsterState)
    self:_addPerfStat("MaterializeRequests")
    if not (monsterState and monsterState.Alive) then
        return false
    end
    if monsterState.Instance and monsterState.Instance.Parent then
        self:_markMonsterMaterialized(monsterState)
        self:_addPerfStat("MaterializeSucceeded")
        return true
    end
    if (self._materializedMonsterCount or 0) >= getLocalMaxVisibleMonsters() then
        return false
    end
    local didMaterialize = self:_createMaterializedMonsterInstance(monsterState) ~= nil
    if didMaterialize then
        self:_addPerfStat("MaterializeSucceeded")
    end
    return didMaterialize
end

function LocalMonsterController:_dematerializeMonster(monsterState)
    self:_addPerfStat("DematerializeRequests")
    if not (monsterState and monsterState.Instance) then
        return
    end
    self:_setMonsterAnimationsEnabled(monsterState, false)
    if not self:_poolMonsterInstance(monsterState) then
        self:_destroyMonsterTracks(monsterState)
        if monsterState.Instance then
            monsterState.Instance:Destroy()
        end
        monsterState.Instance = nil
        self:_markMonsterDematerialized(monsterState)
    end
end

function LocalMonsterController:_poolMonsterInstance(monsterState)
    if not (monsterState and monsterState.Instance) then
        return false
    end

    local poolSize = getLocalMonsterModelPoolSize()
    if poolSize <= 0 or (self._monsterModelPoolCount or 0) >= poolSize then
        return false
    end

    local instance = monsterState.Instance
    if not instance.Parent then
        return false
    end

    self:_stopMonsterTracks(monsterState, 0)
    clearTransientMonsterVisuals(instance)
    instance.Parent = nil
    local key = self:_getModelPoolKey(monsterState.MonsterDefinitionId, monsterState.MonsterTemplateName)
    local pool = self._monsterModelPoolByKey[key]
    if not pool then
        pool = {}
        self._monsterModelPoolByKey[key] = pool
    end

    table.insert(pool, {
        Instance = instance,
        Tracks = monsterState.Tracks or {},
    })
    self._monsterModelPoolCount = (self._monsterModelPoolCount or 0) + 1
    self:_addPerfStat("PoolStores")
    self:_markMonsterDematerialized(monsterState)
    monsterState.Instance = nil
    monsterState.Tracks = {}
    monsterState.TracksLoadAttempted = false
    monsterState.TracksLoadFailed = false
    return true
end

function LocalMonsterController:_stopMonsterTracks(monsterState, fadeTime)
    for _, track in pairs(monsterState and monsterState.Tracks or {}) do
        if track then
            track:Stop(fadeTime or 0)
        end
    end
end

function LocalMonsterController:_destroyMonsterTracks(monsterState)
    for _, track in pairs(monsterState and monsterState.Tracks or {}) do
        if track then
            track:Stop(0)
            track:Destroy()
        end
    end
    if monsterState then
        monsterState.Tracks = {}
        monsterState.TracksLoadAttempted = false
        monsterState.TracksLoadFailed = false
    end
end

function LocalMonsterController:_setMonsterAnimationsEnabled(monsterState, enabled)
    if not monsterState then
        return
    end

    enabled = enabled == true
    if monsterState.AnimationsEnabled == enabled then
        return
    end

    if enabled and not self:_ensureMonsterTracks(monsterState) then
        enabled = false
    end

    monsterState.AnimationsEnabled = enabled
    if enabled then
        monsterState.CurrentLoopName = nil
    else
        self:_stopMonsterTracks(monsterState, LOOP_FADE_SECONDS)
        monsterState.CurrentLoopName = nil
    end
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

function LocalMonsterController:_queueSafeZoneRespawnIfNeeded(position)
    if self:IsPositionInsideSafeZone(position) then
        self._safeZoneRespawnDebt = math.max(0, math.floor(tonumber(self._safeZoneRespawnDebt) or 0)) + 1
    end
end

function LocalMonsterController:_shouldForceSafeZoneRespawn()
    return math.max(0, math.floor(tonumber(self._safeZoneRespawnDebt) or 0)) > 0
end

function LocalMonsterController:_consumeSafeZoneRespawnDebt()
    self._safeZoneRespawnDebt = math.max(0, math.floor(tonumber(self._safeZoneRespawnDebt) or 0) - 1)
end

function LocalMonsterController:_spawnMonster()
    self:_addPerfStat("SpawnAttempts")
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
    local monsterId = tostring(self._nextMonsterId)
    self._nextMonsterId += 1
    local monsterDefinitionId = monsterDefinition and monsterDefinition.Id or GameConfig.MONSTER.MonsterDefinitionId
    local monsterTemplateName = monsterDefinition and monsterDefinition.TemplateName or GameConfig.MONSTER.TemplateName
    local monsterTypeName = monsterDefinition and monsterDefinition.TypeName or "Normal Monster"
    local forceSafeZoneRespawn = self:_shouldForceSafeZoneRespawn()
    local spawnPoint = forceSafeZoneRespawn and self:_samplePointInsideSafeZone() or self:_samplePointInsideBattle()
    if not spawnPoint then
        if forceSafeZoneRespawn then
            table.insert(self._spawnTokenQueue, 1, spawnAuthorization)
        end
        return nil
    end

    local groundY = self:_getGroundY(nil)
    local spawnPosition = Vector3.new(spawnPoint.X, groundY, spawnPoint.Z)
    if forceSafeZoneRespawn then
        self:_consumeSafeZoneRespawnDebt()
    end
    local safeZoneCheckContext = self:_buildSafeZoneCheckContext()
    local isSpawnInsideSafeZone = self:_isPositionInsideSafeZoneWithContext(spawnPosition, safeZoneCheckContext)

    local monsterState = {
        Id = monsterId,
        SpawnToken = spawnAuthorization.token,
        SpawnTokenExpiresAt = spawnAuthorization.expiresAt,
        SpawnTokenLocalExpiresAt = spawnAuthorization.localExpiresAt,
        MonsterDefinitionId = monsterDefinitionId,
        MonsterTemplateName = monsterTemplateName,
        MonsterType = monsterTypeName,
        Instance = nil,
        IsMaterialized = false,
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
        Tracks = {},
        TracksLoadAttempted = false,
        TracksLoadFailed = false,
        AnimationsEnabled = false,
        CurrentLoopName = nil,
        LastPosition = spawnPosition,
        DisplayPosition = spawnPosition,
        DisplayLookAt = nil,
        DamageBucket = nil,
        HitFlash = nil,
        HitFlashEndClock = 0,
        ActivityState = "Dormant",
        SafeZoneCachePosition = spawnPosition,
        SafeZoneCacheValue = isSpawnInsideSafeZone,
        VisualBucket = self._nextMonsterId % getLocalVisualFarUpdateStride(),
        SimulationBucket = self._nextMonsterId % getLocalFarSimulationStride(),
    }
    self:_materializeMonster(monsterState)
    self._monstersById[monsterId] = monsterState
    self._localMonsterSpawnTokenEvent:FireServer({
        eventType = "Activate",
        token = monsterState.SpawnToken,
        timestamp = os.clock(),
    })
    self:_addPerfStat("SpawnSucceeded")
    return monsterState
end

function LocalMonsterController:_destroyMonster(monsterState, options)
    if not monsterState then
        return
    end
    options = type(options) == "table" and options or {}
    monsterState.Alive = false
    monsterState.DamageBucket = nil
    monsterState.HitFlash = nil
    monsterState.HitFlashEndClock = 0

    local didPool = false
    if options.allowPool == true and monsterState.Instance then
        didPool = self:_poolMonsterInstance(monsterState)
    end

    if not didPool then
        self:_destroyMonsterTracks(monsterState)
        if monsterState.Instance then
            monsterState.Instance:Destroy()
        end
        self:_markMonsterDematerialized(monsterState)
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
    self._pendingKillReportFlushClock = 0
    self._safeZoneRespawnDebt = 0
    self:_discardSpawnTokensOnServer(discardedTokens)
    if self._monsterFolder and self._monsterFolder.Parent then
        self._monsterFolder:ClearAllChildren()
    end
    self._materializedMonsterCount = 0
    self:_clearMonsterModelPool()
    self:_clearDamageNumberVisuals()
end

function LocalMonsterController:_resetLocalMonsterPopulation()
    self:_clearMonsters()
    self._spawnTokenQueue = {}
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0
    self._nextSpawnTokenRequestClock = 0
    self._nextSpawnClock = 0
    self._simulationAccumulator = 0
    self._pendingKillReportFlushClock = 0
    self._safeZoneRespawnDebt = 0
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
            if not position and monsterState.Instance then
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
    local deathPosition = monsterState.Position or (monsterState.Instance and getInstancePosition(monsterState.Instance))
    self:_queueSafeZoneRespawnIfNeeded(deathPosition)
    self._pendingKillsByRequestId[requestId] = {
        RequestId = requestId,
        Token = monsterState.SpawnToken,
        DeathPosition = deathPosition,
        CreatedClock = monsterState.KillRequestClock,
        NextSendClock = monsterState.KillRequestClock,
        SendCount = 0,
    }

    self:_destroyMonster(monsterState, {
        allowPool = true,
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

    local pendingKill = self._pendingKillsByRequestId[requestId]
    if not pendingKill then
        return
    end

    local eventType = tostring(payload.eventType or "")
    if eventType == "KillAccepted" then
        self._pendingKillsByRequestId[requestId] = nil
        return
    end

    local reason = tostring(payload.reason or "Unknown")
    if reason == "RateLimited" then
        pendingKill.NextSendClock = os.clock() + KILL_ACK_RETRY_SECONDS
        return
    end

    self._pendingKillsByRequestId[requestId] = nil
    warn(string.format(
        "[LocalMonsterController] 本地小怪击杀未结算经验，丢弃异常怪并补刷: reason=%s token=%s",
        reason,
        tostring(pendingKill.Token or pendingKill.SpawnToken or "")
    ))
    self._nextSpawnClock = 0
    self:_requestSpawnTokens(1)
end

function LocalMonsterController:_handleKillBatchAck(payload)
    if type(payload) ~= "table" then
        return
    end

    local acceptedRequestIds = payload.acceptedRequestIds or payload.accepted or {}
    if type(acceptedRequestIds) == "table" then
        self:_addPerfStat("KillBatchAcksAccepted", #acceptedRequestIds)
        for _, rawRequestId in ipairs(acceptedRequestIds) do
            local requestId = tostring(rawRequestId or "")
            if requestId ~= "" then
                self._pendingKillsByRequestId[requestId] = nil
            end
        end
    end

    local rejected = payload.rejected or payload.rejectedRequests or {}
    if type(rejected) == "table" then
        self:_addPerfStat("KillBatchAcksRejected", #rejected)
        for _, entry in ipairs(rejected) do
            local requestId = tostring(type(entry) == "table" and (entry.requestId or entry.RequestId) or entry or "")
            local pending = self._pendingKillsByRequestId[requestId]
            if requestId ~= "" and pending then
                local reason = tostring(type(entry) == "table" and (entry.reason or entry.Reason) or "Unknown")
                if reason == "RateLimited" then
                    pending.NextSendClock = os.clock() + KILL_ACK_RETRY_SECONDS
                    continue
                end

                self._pendingKillsByRequestId[requestId] = nil
                warn(string.format(
                    "[LocalMonsterController] 本地小怪击杀未结算经验，丢弃异常怪并补刷: reason=%s token=%s",
                    reason,
                    tostring(type(entry) == "table" and (entry.token or entry.Token) or pending.Token or "")
                ))
                self._nextSpawnClock = 0
                self:_requestSpawnTokens(1)
            end
        end
    end
end

function LocalMonsterController:_retryPendingKillReports()
    if not self._localMonsterKilledEvent then
        return
    end

    local now = os.clock()
    if now < (self._pendingKillReportFlushClock or 0) then
        return
    end

    local batch = {}
    local batchSize = getLocalKillReportBatchSize()
    local maxPendingSeconds = getLocalKillReportMaxPendingSeconds()
    local expiredCount = 0

    for requestId, pending in pairs(self._pendingKillsByRequestId) do
        if not (pending and pending.Token) then
            self._pendingKillsByRequestId[requestId] = nil
        elseif now - (pending.CreatedClock or now) > maxPendingSeconds then
            self._pendingKillsByRequestId[requestId] = nil
            expiredCount += 1
        elseif now >= (pending.NextSendClock or 0) then
            pending.NextSendClock = now + KILL_ACK_RETRY_SECONDS
            pending.SendCount = (pending.SendCount or 0) + 1
            table.insert(batch, {
                requestId = requestId,
                token = pending.Token,
                deathPosition = pending.DeathPosition,
                timestamp = now,
            })
            if #batch >= batchSize then
                break
            end
        end
    end

    if expiredCount > 0 then
        warn(string.format("[LocalMonsterController] 已丢弃 %d 个超时本地小怪击杀确认。", expiredCount))
    end

    if #batch <= 0 then
        return
    end

    self._pendingKillReportFlushClock = now + getLocalKillReportBatchIntervalSeconds()
    self:_addPerfStat("KillBatchReportsSent")
    self._localMonsterKilledEvent:FireServer({
        eventType = "Batch",
        kills = batch,
        timestamp = now,
    })
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
    local requestCount = math.clamp(math.floor(tonumber(count) or batchSize), 1, batchSize)
    self:_addPerfStat("SpawnTokenRequests")
    self:_addPerfStat("SpawnTokensRequested", requestCount)
    self._localMonsterSpawnTokenEvent:FireServer({
        count = requestCount,
        timestamp = now,
    })
end

function LocalMonsterController:_handleSpawnTokenPayload(payload)
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0

    if type(payload) == "table" and payload.eventType == "KillBatchResult" then
        self:_handleKillBatchAck(payload)
        return
    end

    if type(payload) == "table" and (payload.eventType == "KillAccepted" or payload.eventType == "KillRejected") then
        self:_handleKillAck(payload)
        return
    end

    if not (type(payload) == "table" and payload.eventType == "Tokens" and type(payload.tokens) == "table") then
        if type(payload) == "table" and payload.eventType == "Denied" then
            self:_addPerfStat("SpawnTokenDenied")
        end
        return
    end

    self:_addPerfStat("SpawnTokensReceived", #payload.tokens)
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

end

function LocalMonsterController:_updateHitFlash(monsterState)
    local instance = monsterState and monsterState.Instance
    if not (instance and instance.Parent) then
        return
    end

    local now = os.clock()
    local flash = monsterState.HitFlash
    if not (flash and flash.Parent) then
        flash = instance:FindFirstChild("HitFlash")
        if not (flash and flash:IsA("Highlight")) then
            flash = Instance.new("Highlight")
            flash.Name = "HitFlash"
            flash.Adornee = instance
            flash.FillColor = Color3.fromRGB(255, 255, 255)
            flash.OutlineColor = Color3.fromRGB(255, 240, 120)
            flash.DepthMode = Enum.HighlightDepthMode.Occluded
            flash.Parent = instance
        end
        monsterState.HitFlash = flash
    end

    if now < (monsterState.HitFlashEndClock or 0) - HIT_FLASH_REFRESH_SECONDS then
        return
    end

    flash.FillTransparency = 0.35
    flash.OutlineTransparency = 0.1
    monsterState.HitFlashEndClock = now + math.max(0.03, tonumber(GameConfig.MONSTER.HitFlashSeconds) or 0.12)
end

function LocalMonsterController:_stepHitFlash(monsterState)
    if not monsterState then
        return
    end

    local flash = monsterState and monsterState.HitFlash
    if not (flash and flash.Parent) then
        monsterState.HitFlash = nil
        monsterState.HitFlashEndClock = 0
        return
    end

    local now = os.clock()
    local endClock = monsterState.HitFlashEndClock or 0
    if endClock <= 0 then
        flash.FillTransparency = 1
        flash.OutlineTransparency = 1
        return
    end

    local remaining = endClock - now
    if remaining <= 0 then
        flash.FillTransparency = 1
        flash.OutlineTransparency = 1
        monsterState.HitFlashEndClock = 0
        return
    end

    local duration = math.max(0.03, tonumber(GameConfig.MONSTER.HitFlashSeconds) or 0.12)
    local alpha = math.clamp(remaining / duration, 0, 1)
    flash.FillTransparency = 1 - (0.65 * alpha)
    flash.OutlineTransparency = 1 - (0.9 * alpha)
end

function LocalMonsterController:_resolveDamageNumberCFrame(monsterState, snapshotPosition, snapshotHeight)
    local position = snapshotPosition
    if typeof(position) ~= "Vector3" then
        position = monsterState and monsterState.Position
    end
    if typeof(position) ~= "Vector3" then
        local instance = monsterState and monsterState.Instance
        position = instance and getInstancePosition(instance) or Vector3.zero
    end

    local height = tonumber(snapshotHeight) or getMonsterHeight(monsterState and monsterState.Instance)
    return CFrame.new(position + Vector3.new(0, math.max(2.5, height * 0.58 + 1), 0))
end

function LocalMonsterController:_createDamageNumberVisual()
    local anchor = Instance.new("Part")
    anchor.Name = "LocalMonsterDamageNumberAnchor"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanTouch = false
    anchor.CanQuery = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(0.2, 0.2, 0.2)

    local gui = Instance.new("BillboardGui")
    gui.Name = "LocalMonsterDamageNumbers_Client"
    gui.Adornee = anchor
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(180, 70)
    gui.Parent = anchor

    local label = Instance.new("TextLabel")
    label.Name = "DamageNumber"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextScaled = true
    label.Parent = gui

    local stroke = Instance.new("UIStroke")
    stroke.Thickness = 2.5
    stroke.Parent = label

    return {
        Anchor = anchor,
        Gui = gui,
        Label = label,
        Stroke = stroke,
    }
end

function LocalMonsterController:_acquireDamageNumberVisual()
    local perSecondLimit = getLocalDamageNumbersPerSecond()
    local poolSize = getLocalDamageNumberPoolSize()
    if perSecondLimit <= 0 or poolSize <= 0 then
        return nil
    end

    local now = os.clock()
    if now - (self._damageNumberWindowClock or 0) >= 1 then
        self._damageNumberWindowClock = now
        self._damageNumberWindowCount = 0
    end
    if (self._damageNumberWindowCount or 0) >= perSecondLimit then
        return nil
    end

    local visual = table.remove(self._damageNumberPool)
    if not visual and (self._damageNumberPoolCreated or 0) < poolSize then
        visual = self:_createDamageNumberVisual()
        self._damageNumberPoolCreated = (self._damageNumberPoolCreated or 0) + 1
    end
    if not visual then
        return nil
    end

    self._damageNumberWindowCount = (self._damageNumberWindowCount or 0) + 1
    self._activeDamageNumberCount = (self._activeDamageNumberCount or 0) + 1
    self._activeDamageNumberVisuals[visual] = true
    return visual
end

function LocalMonsterController:_releaseDamageNumberVisual(visual)
    if not visual then
        return
    end

    if self._activeDamageNumberVisuals[visual] then
        self._activeDamageNumberVisuals[visual] = nil
        self._activeDamageNumberCount = math.max(0, (self._activeDamageNumberCount or 0) - 1)
    end

    if visual.Anchor then
        visual.Anchor.Parent = nil
    end
    table.insert(self._damageNumberPool, visual)
end

function LocalMonsterController:_clearDamageNumberVisuals()
    for visual in pairs(self._activeDamageNumberVisuals or {}) do
        if visual.Anchor then
            visual.Anchor:Destroy()
        end
    end
    for _, visual in ipairs(self._damageNumberPool or {}) do
        if visual.Anchor then
            visual.Anchor:Destroy()
        end
    end

    self._damageNumberPool = {}
    self._activeDamageNumberVisuals = {}
    self._damageNumberPoolCreated = 0
    self._activeDamageNumberCount = 0
    self._damageNumberWindowClock = 0
    self._damageNumberWindowCount = 0
end

function LocalMonsterController:_showDamageNumber(monsterState, amount, snapshotPosition, snapshotHeight)
    local visual = self:_acquireDamageNumberVisual()
    if not visual then
        return
    end
    self:_addPerfStat("DamageNumbersShown")

    local anchor = visual.Anchor
    local label = visual.Label
    local stroke = visual.Stroke
    local textColor, strokeColor = getDamageColors(amount)
    anchor.CFrame = self:_resolveDamageNumberCFrame(monsterState, snapshotPosition, snapshotHeight)
    anchor.Parent = Workspace.CurrentCamera or Workspace

    label.Position = UDim2.fromScale(0.5 + ((math.random() - 0.5) * 0.16), 0.62)
    label.Size = UDim2.fromOffset(110, 34)
    label.Text = formatDamage(amount)
    label.TextColor3 = textColor
    label.TextTransparency = 0
    stroke.Color = strokeColor
    stroke.Transparency = 0

    TweenService:Create(label, TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromScale(label.Position.X.Scale, 0.08),
        Size = UDim2.fromOffset(138, 42),
        TextTransparency = 1,
    }):Play()
    TweenService:Create(stroke, TweenInfo.new(0.62, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Transparency = 1,
    }):Play()

    task.delay(0.72, function()
        if self._activeDamageNumberVisuals and self._activeDamageNumberVisuals[visual] then
            self:_releaseDamageNumberVisual(visual)
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
    self:_queueDamageNumber(monsterState, damage)
end

function LocalMonsterController:_refreshLocalWeaponHitSnapshots()
    table.clear(self._localWeaponHitSnapshots)
    if not self._weaponFxController then
        return
    end

    for index, weaponState in ipairs(self._weaponFxController:GetLocalWeaponStates()) do
        if weaponState.Instance and weaponState.Instance.Parent then
            local hitPart = weaponState.HitPart
            if hitPart and not hitPart:IsA("BasePart") then
                hitPart = nil
            end

            local weaponPosition = hitPart and hitPart.Position or getInstancePosition(weaponState.Instance)
            if weaponPosition then
                table.insert(self._localWeaponHitSnapshots, {
                    Index = index,
                    State = weaponState,
                    Position = weaponPosition,
                    Reach = math.max(
                        GameConfig.COMBAT.WeaponHitRadiusMin,
                        weaponState.AuraRadius or getPartCollisionReach(hitPart)
                    ),
                })
            end
        end
    end
end

function LocalMonsterController:_applyWeaponHits(monsterState)
    if not (self._weaponFxController and monsterState.Alive and monsterState.Position) then
        return
    end

    local now = os.clock()
    local contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius)
    for _, weaponSnapshot in ipairs(self._localWeaponHitSnapshots) do
        local weaponState = weaponSnapshot.State
        if weaponState and weaponState.Instance and weaponState.Instance.Parent then
            local cooldownKey = tostring(weaponSnapshot.Index)
            local lastClock = monsterState.LastWeaponHitClockByKey[cooldownKey]
            if not lastClock or now - lastClock >= GameConfig.MONSTER.WeaponHitCooldownSeconds then
                local weaponPosition = weaponSnapshot.Position
                local radius = contactRadius + math.max(0, tonumber(weaponSnapshot.Reach) or 0)
                local delta = weaponPosition - monsterState.Position
                if (delta.X * delta.X) + (delta.Y * delta.Y) + (delta.Z * delta.Z) <= radius * radius then
                    if isWeaponHittingPosition(weaponState, monsterState.Position, contactRadius) then
                        monsterState.LastWeaponHitClockByKey[cooldownKey] = now
                        self:_applyHitKnockback(monsterState, weaponPosition)
                        self:_updateHitFlash(monsterState)
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
    if not (monsterState and monsterState.Alive and monsterState.Instance and monsterState.Instance.Parent) then
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

function LocalMonsterController:_getMonsterWakeDistance(monsterState)
    local attackRange = getMonsterValue(monsterState, "AttackRange", GameConfig.MONSTER.AttackRange)
    local aggroRadius = getMonsterValue(monsterState, "AggroRadius", GameConfig.MONSTER.AggroRadius)
    attackRange = tonumber(attackRange) or 0
    if attackRange > 0 then
        return attackRange
    end
    return math.max(0, tonumber(aggroRadius) or 0)
end

function LocalMonsterController:_getMonsterPlayerAttackDistanceSq(monsterState)
    if not (monsterState and typeof(monsterState.Position) == "Vector3") then
        return nil
    end

    local contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius)
    for _, weaponSnapshot in ipairs(self._localWeaponHitSnapshots or {}) do
        local weaponPosition = weaponSnapshot.Position
        if typeof(weaponPosition) == "Vector3" then
            local reach = math.max(0, tonumber(weaponSnapshot.Reach) or 0) + contactRadius
            local delta = monsterState.Position - weaponPosition
            local distanceSq = (delta.X * delta.X) + (delta.Z * delta.Z)
            if distanceSq <= reach * reach then
                return distanceSq
            end
        end
    end

    return nil
end

function LocalMonsterController:_setMonsterActivityState(monsterState, activityState)
    if not monsterState then
        return
    end

    activityState = activityState == "CombatActive" and "CombatActive" or "Dormant"
    if not (monsterState.Instance and monsterState.Instance.Parent) then
        self:_materializeMonster(monsterState)
    end

    if monsterState.ActivityState == activityState then
        if activityState == "CombatActive" and not (monsterState.Instance and monsterState.Instance.Parent) then
            monsterState.ActivityState = "Dormant"
        end
        return
    end

    monsterState.ActivityState = activityState
    if activityState == "CombatActive" then
        if not self:_materializeMonster(monsterState) then
            monsterState.ActivityState = "Dormant"
            return
        end
    else
        self:_setMonsterAnimationsEnabled(monsterState, false)
        monsterState.DisplayPosition = monsterState.Position or (monsterState.Instance and getInstancePosition(monsterState.Instance))
        monsterState.DisplayLookAt = nil
        monsterState.KnockbackVelocity = Vector3.zero
        monsterState.KnockbackEndClock = 0
        monsterState.HitStunEndClock = 0
    end
end

function LocalMonsterController:_isMonsterCombatActive(monsterState)
    return monsterState and monsterState.ActivityState == "CombatActive"
end

function LocalMonsterController:_refreshMonsterActivityStates(rootPosition)
    if typeof(rootPosition) ~= "Vector3" then
        return 0
    end

    local combatActiveBudget = getLocalMaxCombatActiveMonsters()
    local sleepPadding = getLocalCombatSleepPadding()
    local candidates = {}
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and typeof(monsterState.Position) == "Vector3" then
            local delta = monsterState.Position - rootPosition
            local distanceSq = (delta.X * delta.X) + (delta.Z * delta.Z)
            local wakeDistance = self:_getMonsterWakeDistance(monsterState)
            local weaponDistanceSq = self:_getMonsterPlayerAttackDistanceSq(monsterState)
            local sleepDistance = wakeDistance + sleepPadding
            local isActive = self:_isMonsterCombatActive(monsterState)
            if isActive then
                if not (monsterState.Instance and monsterState.Instance.Parent) then
                    self:_setMonsterActivityState(monsterState, "CombatActive")
                    isActive = self:_isMonsterCombatActive(monsterState)
                end
                local sleepRangeSq = sleepDistance * sleepDistance
                if distanceSq > sleepRangeSq and not weaponDistanceSq then
                    self:_setMonsterActivityState(monsterState, "Dormant")
                    isActive = false
                else
                    table.insert(candidates, {
                        MonsterState = monsterState,
                        DistanceSq = weaponDistanceSq or distanceSq,
                        Sticky = true,
                    })
                end
            elseif distanceSq <= wakeDistance * wakeDistance or weaponDistanceSq then
                table.insert(candidates, {
                    MonsterState = monsterState,
                    DistanceSq = weaponDistanceSq or distanceSq,
                    Sticky = false,
                })
            end
        else
            self:_setMonsterActivityState(monsterState, "Dormant")
        end
    end

    table.sort(candidates, function(left, right)
        if left.DistanceSq == right.DistanceSq then
            if left.Sticky ~= right.Sticky then
                return left.Sticky == true
            end
            return tostring(left.MonsterState and left.MonsterState.Id or "") < tostring(right.MonsterState and right.MonsterState.Id or "")
        end
        return left.DistanceSq < right.DistanceSq
    end)

    local activeCount = 0
    for _, candidate in ipairs(candidates) do
        local monsterState = candidate.MonsterState
        if activeCount < combatActiveBudget then
            if not self:_isMonsterCombatActive(monsterState) then
                self:_setMonsterActivityState(monsterState, "CombatActive")
            end
            if self:_isMonsterCombatActive(monsterState) then
                activeCount += 1
            end
        elseif self:_isMonsterCombatActive(monsterState) then
            self:_setMonsterActivityState(monsterState, "Dormant")
        end
    end

    return activeCount
end

function LocalMonsterController:_buildCombatActiveSpatialGrid()
    local grid = {}
    local cellSize = SPATIAL_CELL_SIZE
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and self:_isMonsterCombatActive(monsterState) then
            local position = monsterState.Position
            if not position and monsterState.Instance then
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
            end
        end
    end
    return grid
end

function LocalMonsterController:_sleepAllLocalMonsters()
    for _, monsterState in pairs(self._monstersById) do
        self:_setMonsterActivityState(monsterState, "Dormant")
    end
end

function LocalMonsterController:_updateMonsterAnimationLod(monsterState, rootPosition)
    local isActiveInArena = self._latestPlayerState and self._latestPlayerState.isInArena and self._latestPlayerState.alive
    if not (
        isActiveInArena
        and self:_isMonsterCombatActive(monsterState)
        and monsterState
        and monsterState.Alive
        and rootPosition
        and typeof(monsterState.Position) == "Vector3"
    ) then
        self:_setMonsterAnimationsEnabled(monsterState, false)
        return false
    end
    if not (monsterState.Instance and monsterState.Instance.Parent) then
        self:_setMonsterAnimationsEnabled(monsterState, false)
        return false
    end

    local nearDistance = getLocalAnimationNearDistance()
    local delta = monsterState.Position - rootPosition
    local isNear = ((delta.X * delta.X) + (delta.Z * delta.Z)) <= nearDistance * nearDistance
    if not isNear then
        self:_setMonsterAnimationsEnabled(monsterState, false)
        return false
    end
    if not self:_ensureMonsterTracks(monsterState) then
        self:_setMonsterAnimationsEnabled(monsterState, false)
        return false
    end

    self:_setMonsterAnimationsEnabled(monsterState, isNear)
    return isNear
end

function LocalMonsterController:_resetPerfStats()
    self._perfStats = {
        RenderFrames = 0,
        SimulationSteps = 0,
        ActiveMonsterSamples = 0,
        SimulatedMonsterSamples = 0,
        VisibleMonsterSamples = 0,
        AnimationEnabledSamples = 0,
        VisualCandidates = 0,
        VisualUpdates = 0,
        VisualSkippedFar = 0,
        SpawnAttempts = 0,
        SpawnSucceeded = 0,
        SpawnTokenRequests = 0,
        SpawnTokensRequested = 0,
        SpawnTokensReceived = 0,
        SpawnTokenDenied = 0,
        MaterializeRequests = 0,
        MaterializeSucceeded = 0,
        DematerializeRequests = 0,
        PoolStores = 0,
        PoolTakes = 0,
        DamageNumbersShown = 0,
        KillBatchReportsSent = 0,
        KillBatchAcksAccepted = 0,
        KillBatchAcksRejected = 0,
        StepElapsedSeconds = 0,
        VisualElapsedSeconds = 0,
    }
end

function LocalMonsterController:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function countDescendants(instance)
    if not instance then
        return 0
    end

    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    return ok and #descendants or 0
end

local function countDescendantsOfClass(instance, className)
    if not instance then
        return 0
    end

    local count = 0
    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    if not ok then
        return 0
    end

    for _, descendant in ipairs(descendants) do
        if descendant:IsA(className) then
            count += 1
        end
    end
    return count
end

local function tryEnableMemoryTracking()
    if memoryTrackingSetupAttempted then
        return
    end
    memoryTrackingSetupAttempted = true

    pcall(function()
        StatsService.MemoryTrackingEnabled = true
    end)
end

local function getMemoryMbForTag(tagName)
    tryEnableMemoryTracking()

    local okEnabled, memoryTrackingEnabled = pcall(function()
        return StatsService.MemoryTrackingEnabled
    end)
    if not okEnabled or memoryTrackingEnabled ~= true then
        return -1
    end

    local developerMemoryTag = Enum.DeveloperMemoryTag[tagName]
    if not developerMemoryTag then
        return -1
    end

    local ok, value = pcall(function()
        return StatsService:GetMemoryUsageMbForTag(developerMemoryTag)
    end)
    return ok and tonumber(value) or -1
end

local function getTotalMemoryMb()
    local ok, value = pcall(function()
        return StatsService:GetTotalMemoryUsageMb()
    end)
    return ok and tonumber(value) or -1
end

local function getCollectGarbageMemoryMb()
    local ok, value = pcall(function()
        return gcinfo()
    end)
    return ok and ((tonumber(value) or 0) / 1024) or -1
end

local function countDirectChildren(instance)
    if not instance then
        return 0
    end

    local ok, children = pcall(function()
        return instance:GetChildren()
    end)
    return ok and #children or 0
end

local function isImageGui(instance)
    return instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton"))
end

local function isEffectivelyVisible(guiObject)
    local current = guiObject
    while current do
        if current:IsA("GuiObject") and current.Visible ~= true then
            return false
        end
        current = current.Parent
    end
    return true
end

local function getGuiImageId(instance)
    if not isImageGui(instance) then
        return ""
    end

    local ok, image = pcall(function()
        return instance.Image
    end)
    if ok and type(image) == "string" then
        return image
    end
    return ""
end

local function bumpCount(map, key, amount)
    local resolvedKey = tostring(key or "")
    if resolvedKey == "" then
        resolvedKey = "<empty>"
    end
    map[resolvedKey] = (map[resolvedKey] or 0) + (amount or 1)
end

local function getSortedCountEntries(map, limit)
    local entries = {}
    for key, count in pairs(map or {}) do
        table.insert(entries, {
            Key = key,
            Count = count,
        })
    end
    table.sort(entries, function(left, right)
        if left.Count == right.Count then
            return left.Key < right.Key
        end
        return left.Count > right.Count
    end)

    local capped = {}
    local maxEntries = math.max(0, math.floor(tonumber(limit) or 0))
    for index = 1, math.min(maxEntries, #entries) do
        table.insert(capped, string.format("%s:%d", entries[index].Key, entries[index].Count))
    end
    return table.concat(capped, ",")
end

local function formatTopGuiEntry(entry)
    if not entry then
        return ""
    end
    return string.format(
        "%s(%s)=%d/%d",
        tostring(entry.Name or "?"),
        tostring(entry.ClassName or "?"),
        tonumber(entry.Children) or 0,
        tonumber(entry.Descendants) or 0
    )
end

local function getSortedTopGuiEntries(playerGui)
    local entries = {}
    if not playerGui then
        return entries
    end

    local ok, children = pcall(function()
        return playerGui:GetChildren()
    end)
    if not ok then
        return entries
    end

    for _, child in ipairs(children) do
        table.insert(entries, {
            Name = child.Name,
            ClassName = child.ClassName,
            Children = countDirectChildren(child),
            Descendants = countDescendants(child),
        })
    end

    table.sort(entries, function(left, right)
        if left.Descendants == right.Descendants then
            return left.Name < right.Name
        end
        return left.Descendants > right.Descendants
    end)
    return entries
end

local function collectGuiDiagnostics(localPlayer)
    local playerGui = localPlayer and localPlayer:FindFirstChild("PlayerGui") or nil
    local mainGui = playerGui and (playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)) or nil
    local classCounts = {}
    local imageCounts = {}
    local visibleImages = 0
    local invisibleImages = 0
    local effectivelyVisibleImages = 0
    local totalImageCharacters = 0
    local blankImages = 0
    local topEntries = getSortedTopGuiEntries(playerGui)
    local mainTopEntries = getSortedTopGuiEntries(mainGui)

    for _, className in ipairs(GUI_DIAGNOSTIC_CLASS_NAMES) do
        classCounts[className] = 0
    end

    local descendants = {}
    if playerGui then
        local ok, result = pcall(function()
            return playerGui:GetDescendants()
        end)
        if ok and type(result) == "table" then
            descendants = result
        end
    end

    for _, descendant in ipairs(descendants) do
        if classCounts[descendant.ClassName] ~= nil then
            classCounts[descendant.ClassName] += 1
        end

        if isImageGui(descendant) then
            local image = getGuiImageId(descendant)
            if image == "" then
                blankImages += 1
            else
                bumpCount(imageCounts, image, 1)
                totalImageCharacters += #image
            end
            if descendant.Visible == true then
                visibleImages += 1
            else
                invisibleImages += 1
            end
            if isEffectivelyVisible(descendant) then
                effectivelyVisibleImages += 1
            end
        end
    end

    local topParts = {}
    for index = 1, math.min(GUI_DIAGNOSTIC_TOP_LIMIT, #topEntries) do
        table.insert(topParts, formatTopGuiEntry(topEntries[index]))
    end

    local mainTopParts = {}
    for index = 1, math.min(GUI_DIAGNOSTIC_TOP_LIMIT, #mainTopEntries) do
        table.insert(mainTopParts, formatTopGuiEntry(mainTopEntries[index]))
    end

    return {
        PlayerGuiChildren = countDirectChildren(playerGui),
        PlayerGuiDescendants = #descendants,
        MainChildren = countDirectChildren(mainGui),
        MainDescendants = countDescendants(mainGui),
        MainTop = table.concat(mainTopParts, "|"),
        SoundServiceDescendants = countDescendants(SoundService),
        RuntimeSfxDescendants = countDescendants(SoundService:FindFirstChild("__RuntimeSfx")),
        ClassCounts = classCounts,
        VisibleImages = visibleImages,
        InvisibleImages = invisibleImages,
        EffectivelyVisibleImages = effectivelyVisibleImages,
        BlankImages = blankImages,
        UniqueImages = countMapEntries(imageCounts),
        TotalImageCharacters = totalImageCharacters,
        TopGui = table.concat(topParts, "|"),
        TopImages = getSortedCountEntries(imageCounts, GUI_DIAGNOSTIC_IMAGE_LIMIT),
    }
end

function LocalMonsterController:_buildDiagnosticSnapshot()
    local aliveCount = 0
    local dormantCount = 0
    local combatActiveCount = 0
    local materializedStateCount = 0
    local pendingDamageBuckets = 0

    for _, monsterState in pairs(self._monstersById or {}) do
        if monsterState.Alive then
            aliveCount += 1
            if monsterState.ActivityState == "CombatActive" then
                combatActiveCount += 1
            else
                dormantCount += 1
            end
            if monsterState.IsMaterialized then
                materializedStateCount += 1
            end
            if monsterState.DamageBucket then
                pendingDamageBuckets += 1
            end
        end
    end

    local monsterFolder = self._monsterFolder
    return {
        InArena = self._latestPlayerState and self._latestPlayerState.isInArena == true,
        PlayerAlive = self._latestPlayerState and self._latestPlayerState.alive == true,
        Alive = aliveCount,
        Dormant = dormantCount,
        CombatActive = combatActiveCount,
        Visible = materializedStateCount,
        VisibleCounter = self._materializedMonsterCount or 0,
        FolderChildren = monsterFolder and #monsterFolder:GetChildren() or 0,
        FolderDescendants = countDescendants(monsterFolder),
        Animators = countDescendantsOfClass(monsterFolder, "Animator"),
        AnimationControllers = countDescendantsOfClass(monsterFolder, "AnimationController"),
        ModelPool = self._monsterModelPoolCount or 0,
        SpawnQueue = #self._spawnTokenQueue,
        SpawnPending = self._spawnTokenRequestPending == true,
        PendingKills = countMapEntries(self._pendingKillsByRequestId),
        DamagePool = #self._damageNumberPool,
        DamageActive = self._activeDamageNumberCount or 0,
        DamageCreated = self._damageNumberPoolCreated or 0,
        PendingDamageBuckets = pendingDamageBuckets,
        TotalMemoryMb = getTotalMemoryMb(),
        LuaGcMb = getCollectGarbageMemoryMb(),
        LuaHeapMb = getMemoryMbForTag("LuaHeap"),
        InstancesMb = getMemoryMbForTag("Instances"),
        AnimationMb = getMemoryMbForTag("Animation"),
        GuiMb = getMemoryMbForTag("Gui"),
        GraphicsMeshPartsMb = getMemoryMbForTag("GraphicsMeshParts"),
        GraphicsTextureMb = getMemoryMbForTag("GraphicsTexture"),
        PhysicsPartsMb = getMemoryMbForTag("PhysicsParts"),
    }
end

function LocalMonsterController:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats
    if stats and stats.RenderFrames and stats.RenderFrames > 0 then
        print(string.format(
            "[Perf][LocalMonsterController] frames=%d simSteps=%d activeSamples=%d simulatedSamples=%d visible=%d animEnabled=%d visualCandidates=%d visualUpdates=%d skippedFar=%d stepMs=%.3f visualMs=%.3f",
            stats.RenderFrames,
            stats.SimulationSteps or 0,
            stats.ActiveMonsterSamples or 0,
            stats.SimulatedMonsterSamples or 0,
            stats.VisibleMonsterSamples or 0,
            stats.AnimationEnabledSamples or 0,
            stats.VisualCandidates or 0,
            stats.VisualUpdates or 0,
            stats.VisualSkippedFar or 0,
            (stats.StepElapsedSeconds or 0) * 1000,
            (stats.VisualElapsedSeconds or 0) * 1000
        ))

        local diag = self:_buildDiagnosticSnapshot()
        print(string.format(
            "[Diag][LocalMonsterController] memTotalMb=%.2f luaGcMb=%.2f luaHeapMb=%.2f instancesMb=%.2f animationMb=%.2f guiMb=%.2f meshMb=%.2f textureMb=%.2f physicsPartsMb=%.2f inArena=%s playerAlive=%s alive=%d visible=%d dormant=%d combatActive=%d animEnabled=%d visibleCounter=%d folderChildren=%d folderDesc=%d animators=%d animControllers=%d pool=%d spawnQueue=%d spawnPending=%s pendingKills=%d damagePool=%d damageActive=%d damageCreated=%d pendingDamageBuckets=%d spawnReq=%d spawnTokensReq=%d spawnTokensRecv=%d spawnDenied=%d spawnAttempts=%d spawnOk=%d materializeReq=%d materializeOk=%d dematerializeReq=%d poolStores=%d poolTakes=%d damageShown=%d killBatchSent=%d killBatchAccepted=%d killBatchRejected=%d",
            diag.TotalMemoryMb,
            diag.LuaGcMb,
            diag.LuaHeapMb,
            diag.InstancesMb,
            diag.AnimationMb,
            diag.GuiMb,
            diag.GraphicsMeshPartsMb,
            diag.GraphicsTextureMb,
            diag.PhysicsPartsMb,
            tostring(diag.InArena),
            tostring(diag.PlayerAlive),
            diag.Alive,
            diag.Visible,
            diag.Dormant,
            diag.CombatActive,
            stats.AnimationEnabledSamples or 0,
            diag.VisibleCounter,
            diag.FolderChildren,
            diag.FolderDescendants,
            diag.Animators,
            diag.AnimationControllers,
            diag.ModelPool,
            diag.SpawnQueue,
            tostring(diag.SpawnPending),
            diag.PendingKills,
            diag.DamagePool,
            diag.DamageActive,
            diag.DamageCreated,
            diag.PendingDamageBuckets,
            stats.SpawnTokenRequests or 0,
            stats.SpawnTokensRequested or 0,
            stats.SpawnTokensReceived or 0,
            stats.SpawnTokenDenied or 0,
            stats.SpawnAttempts or 0,
            stats.SpawnSucceeded or 0,
            stats.MaterializeRequests or 0,
            stats.MaterializeSucceeded or 0,
            stats.DematerializeRequests or 0,
            stats.PoolStores or 0,
            stats.PoolTakes or 0,
            stats.DamageNumbersShown or 0,
            stats.KillBatchReportsSent or 0,
            stats.KillBatchAcksAccepted or 0,
            stats.KillBatchAcksRejected or 0
        ))

        local guiDiag = collectGuiDiagnostics(self._localPlayer)
        print(string.format(
            "[Diag][ClientGui] playerGuiChildren=%d playerGuiDesc=%d mainChildren=%d mainDesc=%d screenGui=%d frame=%d canvasGroup=%d scrollingFrame=%d textLabel=%d textButton=%d imageLabel=%d imageButton=%d textBox=%d uiStroke=%d uiGradient=%d uiCorner=%d uiScale=%d billboardGui=%d viewportFrame=%d visibleImages=%d invisibleImages=%d effectiveVisibleImages=%d blankImages=%d uniqueImages=%d imageChars=%d soundDesc=%d runtimeSfxDesc=%d topGui=%s mainTop=%s topImages=%s",
            guiDiag.PlayerGuiChildren,
            guiDiag.PlayerGuiDescendants,
            guiDiag.MainChildren,
            guiDiag.MainDescendants,
            guiDiag.ClassCounts.ScreenGui or 0,
            guiDiag.ClassCounts.Frame or 0,
            guiDiag.ClassCounts.CanvasGroup or 0,
            guiDiag.ClassCounts.ScrollingFrame or 0,
            guiDiag.ClassCounts.TextLabel or 0,
            guiDiag.ClassCounts.TextButton or 0,
            guiDiag.ClassCounts.ImageLabel or 0,
            guiDiag.ClassCounts.ImageButton or 0,
            guiDiag.ClassCounts.TextBox or 0,
            guiDiag.ClassCounts.UIStroke or 0,
            guiDiag.ClassCounts.UIGradient or 0,
            guiDiag.ClassCounts.UICorner or 0,
            guiDiag.ClassCounts.UIScale or 0,
            guiDiag.ClassCounts.BillboardGui or 0,
            guiDiag.ClassCounts.ViewportFrame or 0,
            guiDiag.VisibleImages,
            guiDiag.InvisibleImages,
            guiDiag.EffectivelyVisibleImages,
            guiDiag.BlankImages,
            guiDiag.UniqueImages,
            guiDiag.TotalImageCharacters,
            guiDiag.SoundServiceDescendants,
            guiDiag.RuntimeSfxDescendants,
            guiDiag.TopGui ~= "" and guiDiag.TopGui or "-",
            guiDiag.MainTop ~= "" and guiDiag.MainTop or "-",
            guiDiag.TopImages ~= "" and guiDiag.TopImages or "-"
        ))
    end

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function LocalMonsterController:_updateVisuals(deltaTime)
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    if not (self._latestPlayerState and self._latestPlayerState.isInArena and self._latestPlayerState.alive) then
        if startedAt then
            self:_addPerfStat("VisualElapsedSeconds", os.clock() - startedAt)
        end
        return
    end

    local rootPart = getCharacterRoot(self._localPlayer)
    local rootPosition = rootPart and rootPart.Position or nil
    if typeof(rootPosition) ~= "Vector3" then
        return
    end

    local nearDistance = getLocalVisualNearDistance()
    local nearDistanceSq = nearDistance * nearDistance
    local farStride = getLocalVisualFarUpdateStride()
    self._visualFrameIndex = ((self._visualFrameIndex or 0) + 1) % farStride

    local candidates = 0
    local updates = 0
    local skippedFar = 0
    local animationEnabledCount = 0

    for _, monsterState in pairs(self._monstersById) do
        if not self:_isMonsterCombatActive(monsterState) then
            continue
        end
        if not (monsterState.Instance and monsterState.Instance.Parent) then
            continue
        end
        candidates += 1
        if self:_updateMonsterAnimationLod(monsterState, rootPosition) then
            animationEnabledCount += 1
        end
        local shouldUpdate = true
        local visualDeltaTime = deltaTime
        if farStride > 1 and rootPosition and monsterState and typeof(monsterState.Position) == "Vector3" then
            local delta = monsterState.Position - rootPosition
            local distanceSq = (delta.X * delta.X) + (delta.Z * delta.Z)
            if distanceSq > nearDistanceSq then
                local bucket = tonumber(monsterState.VisualBucket) or 0
                shouldUpdate = bucket == self._visualFrameIndex
                visualDeltaTime = deltaTime * farStride
            end
        end

        if shouldUpdate then
            self:_updateMonsterVisual(monsterState, visualDeltaTime)
            updates += 1
        else
            skippedFar += 1
        end
    end

    if startedAt then
        self:_addPerfStat("VisualCandidates", candidates)
        self:_addPerfStat("VisualUpdates", updates)
        self:_addPerfStat("VisualSkippedFar", skippedFar)
        self:_addPerfStat("AnimationEnabledSamples", animationEnabledCount)
        self:_addPerfStat("VisualElapsedSeconds", os.clock() - startedAt)
    end
end

function LocalMonsterController:_step(deltaTime)
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    self:_retryPendingKillReports()
    self:_maintainPopulation()
    local isActiveInArena = self._latestPlayerState and self._latestPlayerState.isInArena and self._latestPlayerState.alive
    if not isActiveInArena then
        self._simulationAccumulator = 0
        if self._wasActiveInArena then
            self:_sleepAllLocalMonsters()
        end
        self._wasActiveInArena = false
        if startedAt then
            self:_addPerfStat("StepElapsedSeconds", os.clock() - startedAt)
        end
        return
    end
    self._wasActiveInArena = true

    local tickSeconds = getLocalSimulationTickSeconds()
    self._simulationAccumulator = math.min((self._simulationAccumulator or 0) + deltaTime, 0.2)
    if self._simulationAccumulator < tickSeconds then
        if startedAt then
            self:_addPerfStat("StepElapsedSeconds", os.clock() - startedAt)
        end
        return
    end

    self._simulationAccumulator -= tickSeconds
    local stepDelta = math.min(tickSeconds, 0.2)
    local rootPart = getCharacterRoot(self._localPlayer)
    local rootPosition = rootPart and rootPart.Position or nil
    if typeof(rootPosition) ~= "Vector3" then
        return
    end

    self:_refreshLocalWeaponHitSnapshots()
    local activeCount = self:_refreshMonsterActivityStates(rootPosition)
    if activeCount <= 0 then
        if startedAt then
            self:_addPerfStat("SimulationSteps")
            self:_addPerfStat("ActiveMonsterSamples", 0)
            self:_addPerfStat("SimulatedMonsterSamples", 0)
            self:_addPerfStat("VisibleMonsterSamples", self._materializedMonsterCount or 0)
            self:_addPerfStat("StepElapsedSeconds", os.clock() - startedAt)
        end
        return
    end

    local grid = self:_buildCombatActiveSpatialGrid()
    local nearDistance = getLocalVisualNearDistance()
    local nearDistanceSq = nearDistance * nearDistance
    local farSimulationStride = getLocalFarSimulationStride()
    self._simulationFrameIndex = ((self._simulationFrameIndex or 0) + 1) % farSimulationStride

    local simulatedCount = 0
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and self:_isMonsterCombatActive(monsterState) then
            local shouldSimulate = true
            local monsterPosition = monsterState.Position
            if farSimulationStride > 1 and rootPosition and typeof(monsterPosition) == "Vector3" then
                local delta = monsterPosition - rootPosition
                local distanceSq = (delta.X * delta.X) + (delta.Z * delta.Z)
                if distanceSq > nearDistanceSq then
                    local bucket = tonumber(monsterState.SimulationBucket) or 0
                    shouldSimulate = bucket == self._simulationFrameIndex
                end
            end
            if shouldSimulate then
                simulatedCount += 1
                self:_stepMonster(monsterState, grid, stepDelta)
            end
            self:_stepHitFlash(monsterState)
        end
    end
    if startedAt then
        self:_addPerfStat("SimulationSteps")
        self:_addPerfStat("ActiveMonsterSamples", activeCount)
        self:_addPerfStat("SimulatedMonsterSamples", simulatedCount)
        self:_addPerfStat("VisibleMonsterSamples", self._materializedMonsterCount or 0)
        self:_addPerfStat("StepElapsedSeconds", os.clock() - startedAt)
    end
end

function LocalMonsterController:_getMonsterSafeZoneCachedValue(monsterState, position, context)
    if not (monsterState and typeof(position) == "Vector3") then
        return false
    end
    if not context then
        return false
    end

    if monsterState.SafeZoneCachePosition == position then
        return monsterState.SafeZoneCacheValue == true
    end

    local isInsideSafeZone = self:_isPositionInsideSafeZoneWithContext(position, context)
    monsterState.SafeZoneCachePosition = position
    monsterState.SafeZoneCacheValue = isInsideSafeZone
    return isInsideSafeZone
end

function LocalMonsterController:_prepareMonsterTargetFilter(filterOptions)
    if type(filterOptions) ~= "table" or filterOptions.ExcludeSafeZone ~= true then
        return nil
    end

    return {
        ExcludeSafeZone = true,
        SafeZoneContext = self:_buildSafeZoneCheckContext(),
    }
end

function LocalMonsterController:_isMonsterTargetFiltered(monsterState, position, filterContext)
    if type(filterContext) ~= "table" then
        return false
    end
    if filterContext.ExcludeSafeZone == true
        and self:_getMonsterSafeZoneCachedValue(monsterState, position, filterContext.SafeZoneContext)
    then
        return true
    end
    return false
end

function LocalMonsterController:FindNearestAliveMonster(originPosition, minimumPlanarDistance, excludedIds, filterOptions)
    if typeof(originPosition) ~= "Vector3" then
        return nil
    end

    local minimumDistance = math.max(0, tonumber(minimumPlanarDistance) or 0)
    local nearestMonsterState = nil
    local nearestDistanceSq = math.huge
    local filterContext = self:_prepareMonsterTargetFilter(filterOptions)
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive
            and not (excludedIds and excludedIds[monsterState.Id])
        then
            local position = monsterState.Position or (monsterState.Instance and getInstancePosition(monsterState.Instance))
            if position then
                monsterState.Position = position
                if self:_isMonsterTargetFiltered(monsterState, position, filterContext) then
                    continue
                end
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

function LocalMonsterController:GetAliveMonsterSnapshotById(monsterId, filterOptions)
    if monsterId == nil then
        return nil
    end

    local monsterState = self._monstersById[monsterId]
    if not (monsterState and monsterState.Alive) then
        return nil
    end

    local position = monsterState.Position or (monsterState.Instance and getInstancePosition(monsterState.Instance))
    if not position then
        return nil
    end

    monsterState.Position = position
    if self:_isMonsterTargetFiltered(monsterState, position, self:_prepareMonsterTargetFilter(filterOptions)) then
        return nil
    end

    return {
        id = monsterState.Id,
        monsterDefinitionId = monsterState.MonsterDefinitionId,
        position = monsterState.Position,
        contactRadius = getMonsterValue(monsterState, "ContactRadius", GameConfig.MONSTER.ContactRadius),
    }
end

function LocalMonsterController:FindNearestAliveMonsterOutsideWeaponRange(originPosition, weaponRange, excludedIds, filterOptions)
    if typeof(originPosition) ~= "Vector3" then
        return nil
    end

    local normalizedWeaponRange = math.max(0, tonumber(weaponRange) or 0)
    local nearestMonsterState = nil
    local nearestDistanceSq = math.huge
    local filterContext = self:_prepareMonsterTargetFilter(filterOptions)
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive
            and not (excludedIds and excludedIds[monsterState.Id])
        then
            local position = monsterState.Position or (monsterState.Instance and getInstancePosition(monsterState.Instance))
            if position then
                monsterState.Position = position
                if self:_isMonsterTargetFiltered(monsterState, position, filterContext) then
                    continue
                end
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
    self._safePart = self:_resolveSafePart()
    self._monstersById = {}
    self._spawnTokenQueue = {}
    self._spawnTokenRequestPending = false
    self._spawnTokenRequestDeadline = 0
    self._nextSpawnTokenRequestClock = 0
    self._safeZoneRespawnDebt = 0
    self._nextMonsterId = 1
    self._nextKillRequestId = 1
    self._nextSpawnClock = 0
    self._simulationAccumulator = 0
    self._wasActiveInArena = false
    self._visualFrameIndex = 0
    self._simulationFrameIndex = 0
    self._pendingKillsByRequestId = {}
    self._pendingKillReportFlushClock = 0
    self._materializedMonsterCount = 0
    self:_clearMonsterModelPool()
    self:_clearDamageNumberVisuals()
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()
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
        if not (payload and payload.isInArena and payload.alive) and self._wasActiveInArena then
            self:_sleepAllLocalMonsters()
            self._wasActiveInArena = false
        end
    end))

    table.insert(self._connections, self._localMonsterSpawnTokenEvent.OnClientEvent:Connect(function(payload)
        self:_handleSpawnTokenPayload(payload)
    end))

    table.insert(self._connections, self._localMonsterKilledEvent.OnClientEvent:Connect(function(payload)
        if type(payload) == "table" and payload.eventType == "KillBatchResult" then
            self:_handleKillBatchAck(payload)
        else
            self:_handleKillAck(payload)
        end
    end))

    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        requestStateSyncEvent:FireServer()
    end

    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        if not GameConfig.MONSTER.ClientOwnedNormalMonsters then
            return
        end
        self:_addPerfStat("RenderFrames")
        if not (self._battlePart and self._battlePart.Parent) then
            self._battlePart = self:_resolveBattlePart()
        end
        if not (self._safePart and self._safePart.Parent) then
            self._safePart = self:_resolveSafePart()
        end
        self:_step(deltaTime)
        self:_updateVisuals(deltaTime)
        self:_logPerfStats(os.clock())
    end)
end

return LocalMonsterController
