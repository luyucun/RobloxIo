--[[
脚本名字: MonsterService
脚本文件: MonsterService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/MonsterService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
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
        "[MonsterService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local MonsterService = {}

local DEFAULT_CHARACTER_COLLISION_GROUP = "IOCharacters"
local DEFAULT_MONSTER_COLLISION_GROUP = "IOMonsters"

MonsterService._playerStateService = nil
MonsterService._weaponService = nil
MonsterService._healthService = nil
MonsterService._experienceOrbService = nil
MonsterService._potionService = nil
MonsterService._bossHitFeedbackEvent = nil
MonsterService._runtimeFolder = nil
MonsterService._templateFolder = nil
MonsterService._battlePart = nil
MonsterService._monstersById = {}
MonsterService._weaponHitCooldowns = {}
MonsterService._nextMonsterId = 1
MonsterService._nextSpawnClock = 0
MonsterService._heartbeatConnection = nil

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

local function resolveBattlePart()
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

local function resolveTemplateFolder()
    local modelRoot = findOrCreateFolder(ReplicatedStorage, GameConfig.MONSTER.ModelRootFolderName)
    return findOrCreateFolder(modelRoot, GameConfig.MONSTER.MonsterFolderName)
end

local function findTemplate(folder, templateName)
    local template = folder and folder:FindFirstChild(templateName)
    if template and (template:IsA("Model") or template:IsA("BasePart")) then
        return template
    end
    return nil
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

local function setModelCFrame(instance, cframe)
    if instance:IsA("Model") then
        instance:PivotTo(cframe)
    elseif instance:IsA("BasePart") then
        instance.CFrame = cframe
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
    if instance:IsA("Model") then
        return instance:GetPivot().Position
    end
    if instance:IsA("BasePart") then
        return instance.Position
    end
    return nil
end

local function ensureCollisionGroup(groupName)
    local found = false
    local success, groups = pcall(function()
        return PhysicsService:GetRegisteredCollisionGroups()
    end)
    if success and type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group.name == groupName or group.Name == groupName then
                found = true
                break
            end
        end
    end
    if not found then
        pcall(function()
            PhysicsService:RegisterCollisionGroup(groupName)
        end)
    end
end

local function setPartCollisionGroup(basePart, groupName)
    pcall(function()
        basePart.CollisionGroup = groupName
    end)
end

local function getCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.CharacterGroupName) or DEFAULT_CHARACTER_COLLISION_GROUP
end

local function getMonsterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.MonsterGroupName) or DEFAULT_MONSTER_COLLISION_GROUP
end

local function lerpColor(colorA, colorB, alpha)
    local t = math.clamp(tonumber(alpha) or 0, 0, 1)
    return Color3.new(
        colorA.R + ((colorB.R - colorA.R) * t),
        colorA.G + ((colorB.G - colorA.G) * t),
        colorA.B + ((colorB.B - colorA.B) * t)
    )
end

local function getHealthFillColor(healthRatio)
    local ratio = math.clamp(tonumber(healthRatio) or 0, 0, 1)
    local lowColor = Color3.fromRGB(255, 92, 92)
    local midColor = Color3.fromRGB(255, 204, 92)
    local highColor = Color3.fromRGB(90, 255, 138)
    if ratio >= 0.5 then
        return lerpColor(midColor, highColor, (ratio - 0.5) / 0.5)
    end
    return lerpColor(lowColor, midColor, ratio / 0.5)
end

local function resolveOverheadHealthBarTemplate()
    local uiFolder = ReplicatedStorage:FindFirstChild("UI")
    local template = uiFolder and uiFolder:FindFirstChild("OverheadHealthBar")
    if template and template:IsA("BillboardGui") then
        return template
    end
    return nil
end

local function configureCollisionGroups()
    local characterGroup = getCharacterCollisionGroupName()
    local monsterGroup = getMonsterCollisionGroupName()
    ensureCollisionGroup(characterGroup)
    ensureCollisionGroup(monsterGroup)
    pcall(function()
        PhysicsService:CollisionGroupSetCollidable(characterGroup, monsterGroup, false)
        PhysicsService:CollisionGroupSetCollidable(monsterGroup, monsterGroup, true)
    end)
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

local function createPlaceholderTemplate(folder)
    return MonsterService.CreatePlaceholderTemplate(folder, GameConfig.MONSTER.TemplateName, false)
end

function MonsterService.CreatePlaceholderTemplate(folder, templateName, isBoss)
    local model = Instance.new("Model")
    model.Name = tostring(templateName or GameConfig.MONSTER.TemplateName)

    local body = Instance.new("Part")
    body.Name = "Body"
    body.Anchored = true
    body.CanCollide = false
    body.CanTouch = false
    body.CanQuery = false
    body.Material = Enum.Material.Neon
    body.Color = isBoss and Color3.fromRGB(255, 180, 48) or Color3.fromRGB(255, 95, 86)
    body.Shape = Enum.PartType.Ball
    body.Size = isBoss and Vector3.new(8, 8, 8) or Vector3.new(4, 4, 4)
    body.Parent = model

    model.PrimaryPart = body
    model:SetAttribute("IsPlaceholderTemplate", true)
    model.Parent = folder
    return model
end

function MonsterService:_createRuntimeFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    return findOrCreateFolder(runtimeRoot, GameConfig.MONSTER.RuntimeFolderName)
end

function MonsterService:_clearRuntimeFolder()
    if not self._runtimeFolder then
        return
    end
    for _, child in ipairs(self._runtimeFolder:GetChildren()) do
        child:Destroy()
    end
end

function MonsterService:_getBossHealthBarAdornee(monsterState)
    local instance = monsterState and monsterState.RuntimeInstance
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance
    end
    if instance:IsA("Model") then
        return instance.PrimaryPart or instance:FindFirstChild("Root", true) or instance:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

function MonsterService:_ensureBossHealthBar(monsterState)
    if not (monsterState and monsterState.IsBoss and monsterState.RuntimeInstance) then
        return nil
    end

    local adornee = self:_getBossHealthBarAdornee(monsterState)
    if not adornee then
        return nil
    end

    local billboard = monsterState.HealthBar
    if billboard and billboard.Parent then
        billboard.Adornee = adornee
        return billboard
    end

    local template = resolveOverheadHealthBarTemplate()
    if not template then
        return nil
    end

    billboard = template:Clone()
    billboard.Name = "BossOverheadHealthBar"
    billboard.Adornee = adornee
    billboard.Enabled = false

    local root = billboard:FindFirstChild("Root")
    local levelLabel = root and root:FindFirstChild("Level")
    if levelLabel and levelLabel:IsA("TextLabel") then
        levelLabel.Visible = false
        levelLabel.Text = ""
    end

    local offsetY = 8
    if monsterState.RuntimeInstance:IsA("Model") then
        local boxCFrame, boxSize = monsterState.RuntimeInstance:GetBoundingBox()
        offsetY = math.max(4, (boxCFrame.Position.Y + (boxSize.Y * 0.5)) - adornee.Position.Y + 3)
    elseif monsterState.RuntimeInstance:IsA("BasePart") then
        offsetY = math.max(4, monsterState.RuntimeInstance.Size.Y * 0.5 + 3)
    end
    billboard.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
    billboard.Parent = adornee
    monsterState.HealthBar = billboard
    return billboard
end

function MonsterService:_updateBossHealthBar(monsterState)
    if not (monsterState and monsterState.IsBoss) then
        return
    end

    local billboard = self:_ensureBossHealthBar(monsterState)
    if not billboard then
        return
    end

    local root = billboard:FindFirstChild("Root")
    local valueLabel = root and root:FindFirstChild("ValueLabel")
    local levelLabel = root and root:FindFirstChild("Level")
    local barBackground = root and root:FindFirstChild("BarBackground")
    local fill = barBackground and barBackground:FindFirstChild("Fill")
    if levelLabel and levelLabel:IsA("TextLabel") then
        levelLabel.Visible = false
        levelLabel.Text = ""
    end

    local maxHealth = math.max(1, math.floor(tonumber(monsterState.MaxHealth) or 1))
    local currentHealth = math.clamp(math.floor(tonumber(monsterState.CurrentHealth) or maxHealth), 0, maxHealth)
    local healthRatio = currentHealth / maxHealth
    if valueLabel and valueLabel:IsA("TextLabel") then
        valueLabel.Text = string.format("%d / %d", currentHealth, maxHealth)
    end
    if fill and fill:IsA("Frame") then
        fill.Size = UDim2.fromScale(healthRatio, 1)
        fill.BackgroundColor3 = getHealthFillColor(healthRatio)
    end

    billboard.Enabled = monsterState.Alive == true and currentHealth > 0 and currentHealth < maxHealth
end

function MonsterService:_samplePointInsideBattle()
    if not self._battlePart then
        return nil
    end

    local size = self._battlePart.Size
    local padding = GameConfig.MONSTER.EdgePadding
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localX = (math.random() * 2 - 1) * usableHalfX
    local localZ = (math.random() * 2 - 1) * usableHalfZ

    local arenaActors = self._playerStateService and self._playerStateService:GetArenaActors() or {}
    if #arenaActors > 0 and math.random() <= GameConfig.MONSTER.SpawnNearActorChance then
        local anchorActor = arenaActors[math.random(1, #arenaActors)]
        local anchorRoot = ActorUtils.GetRootPart(anchorActor)
        if anchorRoot then
            local anchorLocalPosition = self._battlePart.CFrame:PointToObjectSpace(anchorRoot.Position)
            local angle = math.random() * math.pi * 2
            local radius = math.random() * GameConfig.MONSTER.SpawnNearActorRadius
            localX = math.clamp(
                anchorLocalPosition.X + (math.cos(angle) * radius),
                -usableHalfX,
                usableHalfX
            )
            localZ = math.clamp(
                anchorLocalPosition.Z + (math.sin(angle) * radius),
                -usableHalfZ,
                usableHalfZ
            )
        end
    end

    local worldPoint = (self._battlePart.CFrame * CFrame.new(localX, 0, localZ)).Position
    return Vector3.new(
        worldPoint.X,
        self._battlePart.Position.Y + (size.Y * 0.5),
        worldPoint.Z
    )
end

function MonsterService:_getGroundedSpawnPosition(template, position)
    if not (self._battlePart and typeof(position) == "Vector3") then
        return position
    end

    local groundY = self._battlePart.Position.Y + (self._battlePart.Size.Y * 0.5)
    local bottomOffsetFromPivot = getBottomOffsetFromPivot(template)
    return Vector3.new(position.X, groundY - bottomOffsetFromPivot, position.Z)
end

local function resolveMonsterDefinition(monsterConfig)
    local definition = MonsterCatalog.GetDefinition(monsterConfig.MonsterDefinitionId)
    if definition then
        return definition
    end
    return MonsterCatalog.GetDefinitionByTemplateName(monsterConfig.TemplateName)
end

function MonsterService:_configureRuntimeInstance(instance, monsterId, isBoss, monsterDefinition)
    local definitionId = monsterDefinition and monsterDefinition.Id or nil
    local templateName = monsterDefinition and monsterDefinition.TemplateName or nil
    local typeName = monsterDefinition and monsterDefinition.TypeName or (isBoss and "Boss" or "Normal Monster")
    local baseParts = getBaseParts(instance)
    local primaryPart = nil
    if instance:IsA("Model") and #baseParts > 0 then
        primaryPart = instance.PrimaryPart or instance:FindFirstChild("Root", true) or baseParts[1]
        instance.PrimaryPart = primaryPart
    elseif instance:IsA("BasePart") then
        primaryPart = instance
    end

    for _, basePart in ipairs(baseParts) do
        basePart.Anchored = true
        basePart.CanCollide = basePart == primaryPart
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
        setPartCollisionGroup(basePart, getMonsterCollisionGroupName())
        basePart:SetAttribute("MonsterId", monsterId)
        basePart:SetAttribute("IsBoss", isBoss == true)
        basePart:SetAttribute("MonsterDefinitionId", definitionId)
        basePart:SetAttribute("MonsterTemplateName", templateName)
        basePart:SetAttribute("MonsterType", typeName)
    end

    instance:SetAttribute("MonsterId", monsterId)
    instance:SetAttribute("IsBoss", isBoss == true)
    instance:SetAttribute("MonsterDefinitionId", definitionId)
    instance:SetAttribute("MonsterTemplateName", templateName)
    instance:SetAttribute("MonsterType", typeName)
    instance:SetAttribute("AttackSerial", 0)
end

function MonsterService:SpawnMonster(position, overrideConfig)
    if not (self._runtimeFolder and self._templateFolder) then
        return nil
    end

    local monsterConfig = overrideConfig or GameConfig.MONSTER
    local monsterDefinition = resolveMonsterDefinition(monsterConfig)
    local templateName = (monsterDefinition and monsterDefinition.TemplateName)
        or monsterConfig.TemplateName
        or GameConfig.MONSTER.TemplateName
    local template = findTemplate(self._templateFolder, templateName)
    if not template then
        template = MonsterService.CreatePlaceholderTemplate(self._templateFolder, templateName, monsterConfig.IsBoss == true)
    end
    local spawnPosition = typeof(position) == "Vector3" and position or self:_samplePointInsideBattle()
    if not spawnPosition then
        return nil
    end
    spawnPosition = self:_getGroundedSpawnPosition(template, spawnPosition)

    local monsterId = tostring(self._nextMonsterId)
    self._nextMonsterId += 1

    local runtimeInstance = template:Clone()
    runtimeInstance.Name = (monsterConfig.RuntimeName or "Monster") .. "_" .. monsterId
    self:_configureRuntimeInstance(runtimeInstance, monsterId, monsterConfig.IsBoss == true, monsterDefinition)
    setModelCFrame(runtimeInstance, CFrame.new(spawnPosition))
    runtimeInstance.Parent = self._runtimeFolder

    local monsterState = {
        Id = monsterId,
        MonsterDefinitionId = monsterDefinition and monsterDefinition.Id or nil,
        MonsterTemplateName = templateName,
        MonsterType = monsterDefinition and monsterDefinition.TypeName or (monsterConfig.IsBoss and "Boss" or "Normal Monster"),
        RuntimeInstance = runtimeInstance,
        GroundY = spawnPosition.Y,
        Level = monsterConfig.Level or GameConfig.MONSTER.Level,
        MaxHealth = monsterConfig.MaxHealth or (monsterDefinition and monsterDefinition.MaxHealth) or GameConfig.MONSTER.MaxHealth,
        CurrentHealth = monsterConfig.MaxHealth or (monsterDefinition and monsterDefinition.MaxHealth) or GameConfig.MONSTER.MaxHealth,
        AttackDamage = monsterConfig.AttackDamage or (monsterDefinition and monsterDefinition.AttackDamage) or GameConfig.MONSTER.AttackDamage,
        MoveSpeed = monsterConfig.MoveSpeed or (monsterDefinition and monsterDefinition.MoveSpeed) or GameConfig.MONSTER.MoveSpeed,
        AttackRange = monsterConfig.AttackRange
            or monsterConfig.AggroRadius
            or (monsterDefinition and monsterDefinition.AttackRange)
            or (monsterDefinition and monsterDefinition.AggroRadius)
            or GameConfig.MONSTER.AttackRange
            or GameConfig.MONSTER.AggroRadius,
        AggroRadius = monsterConfig.AggroRadius or (monsterDefinition and monsterDefinition.AggroRadius) or GameConfig.MONSTER.AggroRadius,
        DisengageDistance = monsterConfig.DisengageDistance
            or monsterConfig.AttackRange
            or monsterConfig.AggroRadius
            or (monsterDefinition and monsterDefinition.DisengageDistance)
            or (monsterDefinition and monsterDefinition.AttackRange)
            or (monsterDefinition and monsterDefinition.AggroRadius)
            or GameConfig.MONSTER.DisengageDistance
            or GameConfig.MONSTER.AttackRange
            or GameConfig.MONSTER.AggroRadius,
        ContactRadius = monsterConfig.ContactRadius or (monsterDefinition and monsterDefinition.ContactRadius) or GameConfig.MONSTER.ContactRadius,
        CollisionRadius = monsterConfig.CollisionRadius or (monsterDefinition and monsterDefinition.CollisionRadius) or GameConfig.MONSTER.CollisionRadius,
        ExperienceDropCount = monsterConfig.ExperienceDropCount or (monsterDefinition and monsterDefinition.ExperienceDropCount) or GameConfig.MONSTER.ExperienceDropCount,
        ExperiencePerOrb = monsterConfig.ExperiencePerOrb or (monsterDefinition and monsterDefinition.ExperiencePerOrb) or GameConfig.MONSTER.ExperiencePerOrb,
        KillScoreReward = monsterConfig.KillScoreReward
            or (monsterDefinition and monsterDefinition.KillScoreReward)
            or (monsterConfig.IsBoss and GameConfig.BOSS.KillScoreReward)
            or GameConfig.MONSTER.KillScoreReward,
        BuffDropCount = monsterConfig.BuffDropCount or 0,
        IsBoss = monsterConfig.IsBoss == true,
        AttackSerial = 0,
        LastAttackClockByActorId = {},
        TargetActor = nil,
        LastDamageSourceActor = nil,
        Alive = true,
    }

    runtimeInstance:SetAttribute("Level", monsterState.Level)
    runtimeInstance:SetAttribute("MaxHealth", monsterState.MaxHealth)
    runtimeInstance:SetAttribute("CurrentHealth", monsterState.CurrentHealth)
    runtimeInstance:SetAttribute("AttackDamage", monsterState.AttackDamage)
    runtimeInstance:SetAttribute("MoveSpeed", monsterState.MoveSpeed)
    runtimeInstance:SetAttribute("AttackRange", monsterState.AttackRange)
    runtimeInstance:SetAttribute("DisengageDistance", monsterState.DisengageDistance)
    runtimeInstance:SetAttribute("CollisionRadius", monsterState.CollisionRadius)

    self._monstersById[monsterId] = monsterState
    if monsterState.IsBoss then
        self:_updateBossHealthBar(monsterState)
    end
    return monsterState
end

function MonsterService:GetActiveMonsterCount()
    local count = 0
    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and not monsterState.IsBoss then
            count += 1
        end
    end
    return count
end

function MonsterService:_getNearestTarget(position, aggroRadius)
    local nearestActor = nil
    local nearestDistance = tonumber(aggroRadius) or math.huge

    for _, actor in ipairs(self._playerStateService:GetArenaActors()) do
        local rootPart = ActorUtils.GetRootPart(actor)
        if rootPart then
            local distance = (rootPart.Position - position).Magnitude
            if distance < nearestDistance then
                nearestActor = actor
                nearestDistance = distance
            end
        end
    end

    return nearestActor, nearestDistance
end

function MonsterService:_getActorDistance(position, actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not (rootPart and typeof(position) == "Vector3") then
        return nil, nil
    end

    return (rootPart.Position - position).Magnitude, rootPart
end

function MonsterService:_resolveMonsterTarget(monsterState, position)
    local currentTarget = monsterState.TargetActor
    if currentTarget then
        local currentDistance, currentRoot = self:_getActorDistance(position, currentTarget)
        local currentState = self._playerStateService and self._playerStateService:GetState(currentTarget) or nil
        if currentRoot
            and currentState
            and currentState.Alive
            and currentState.IsInArena
            and currentDistance <= (tonumber(monsterState.DisengageDistance) or tonumber(monsterState.AttackRange) or math.huge) then
            return currentTarget, currentDistance, currentRoot
        end

        monsterState.TargetActor = nil
    end

    local nextTarget, nextDistance = self:_getNearestTarget(position, monsterState.AttackRange)
    if nextTarget then
        monsterState.TargetActor = nextTarget
        return nextTarget, nextDistance, ActorUtils.GetRootPart(nextTarget)
    end

    return nil, nil, nil
end

function MonsterService:_clampPositionInsideBattle(position, radius)
    if not (self._battlePart and typeof(position) == "Vector3") then
        return position
    end

    local size = self._battlePart.Size
    local padding = math.max(GameConfig.MONSTER.EdgePadding, tonumber(radius) or 0)
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

function MonsterService:_getMonsterSeparationOffset(monsterState, position, deltaTime)
    local radius = tonumber(monsterState.CollisionRadius) or GameConfig.MONSTER.CollisionRadius
    if radius <= 0 then
        return Vector3.zero
    end

    local separation = Vector3.zero
    for _, otherMonsterState in pairs(self._monstersById) do
        if otherMonsterState ~= monsterState
            and otherMonsterState.Alive
            and otherMonsterState.RuntimeInstance
            and otherMonsterState.RuntimeInstance.Parent then
            local otherPosition = getInstancePosition(otherMonsterState.RuntimeInstance)
            if otherPosition then
                local delta = Vector3.new(position.X - otherPosition.X, 0, position.Z - otherPosition.Z)
                local otherRadius = tonumber(otherMonsterState.CollisionRadius) or GameConfig.MONSTER.CollisionRadius
                local minDistance = radius + otherRadius
                local distance = delta.Magnitude
                if distance < minDistance then
                    local direction = nil
                    if distance > 0.001 then
                        direction = delta.Unit
                    else
                        local seed = (tonumber(monsterState.Id) or 1) * 37
                        direction = Vector3.new(math.cos(seed), 0, math.sin(seed)).Unit
                    end
                    separation += direction * (minDistance - distance)
                end
            end
        end
    end

    local maxPush = math.max(0, GameConfig.MONSTER.SeparationPushSpeed * math.max(0, deltaTime))
    if separation.Magnitude > maxPush and maxPush > 0 then
        return separation.Unit * maxPush
    end
    return separation
end

function MonsterService:_damageActor(monsterState, targetActor)
    local now = os.clock()
    local actorId = ActorUtils.GetActorId(targetActor)
    local lastClock = monsterState.LastAttackClockByActorId[actorId]
    if lastClock and now - lastClock < GameConfig.MONSTER.AttackCooldownSeconds then
        return
    end
    monsterState.LastAttackClockByActorId[actorId] = now

    monsterState.AttackSerial = (monsterState.AttackSerial or 0) + 1
    if monsterState.RuntimeInstance then
        monsterState.RuntimeInstance:SetAttribute("AttackSerial", monsterState.AttackSerial)
    end

    if self._healthService then
        self._healthService:ApplyWeaponDamage(targetActor, monsterState.AttackDamage, nil)
    end
end

function MonsterService:_stepMonster(monsterState, deltaTime)
    if not (monsterState.Alive and monsterState.RuntimeInstance and monsterState.RuntimeInstance.Parent) then
        return
    end

    local position = getInstancePosition(monsterState.RuntimeInstance)
    if not position then
        return
    end

    local movement = Vector3.zero
    local targetRoot = nil
    local targetActor, distance, resolvedTargetRoot = self:_resolveMonsterTarget(monsterState, position)
    if targetActor and distance then
        targetRoot = resolvedTargetRoot or ActorUtils.GetRootPart(targetActor)
        if targetRoot then
            if distance <= monsterState.ContactRadius then
                self:_damageActor(monsterState, targetActor)
            else
                local direction = targetRoot.Position - position
                direction = Vector3.new(direction.X, 0, direction.Z)
                if direction.Magnitude > 0 then
                    local stepDistance = math.min(distance, monsterState.MoveSpeed * deltaTime)
                    movement = direction.Unit * stepDistance
                end
            end
        end
    end

    local separation = self:_getMonsterSeparationOffset(monsterState, position, deltaTime)
    if not targetRoot then
        return
    end

    if movement.Magnitude <= 0 and separation.Magnitude <= 0 then
        return
    end

    local nextPosition = position + movement + separation
    nextPosition = Vector3.new(nextPosition.X, monsterState.GroundY or position.Y, nextPosition.Z)
    nextPosition = self:_clampPositionInsideBattle(nextPosition, monsterState.CollisionRadius)
    if targetRoot then
        setModelCFrame(monsterState.RuntimeInstance, CFrame.new(nextPosition, Vector3.new(targetRoot.Position.X, nextPosition.Y, targetRoot.Position.Z)))
    else
        local currentCFrame = getInstanceCFrame(monsterState.RuntimeInstance)
        setModelCFrame(monsterState.RuntimeInstance, currentCFrame and (currentCFrame + (nextPosition - position)) or CFrame.new(nextPosition))
    end
end

function MonsterService:_destroyMonster(monsterState)
    if not monsterState then
        return
    end
    if monsterState.HealthBar and monsterState.HealthBar.Parent then
        monsterState.HealthBar:Destroy()
        monsterState.HealthBar = nil
    end
    if monsterState.RuntimeInstance and monsterState.RuntimeInstance.Parent then
        monsterState.RuntimeInstance:Destroy()
    end
    self._monstersById[monsterState.Id] = nil
end

function MonsterService:_getBossExperienceVisualCount(monsterState)
    local configuredCount = math.max(1, math.floor(tonumber(monsterState and monsterState.ExperienceDropCount) or 1))
    local maxVisualCount = math.max(1, math.floor(tonumber(GameConfig.BOSS and GameConfig.BOSS.MaxExperienceOrbVisualCount) or configuredCount))
    return math.min(configuredCount, maxVisualCount)
end

function MonsterService:_awardMonsterRewards(monsterState, sourceActor, deathPosition, options)
    if not monsterState then
        return
    end

    local resolvedSourceActor = sourceActor
    if monsterState.IsBoss and options and options.forceSourceActor then
        resolvedSourceActor = options.forceSourceActor
    elseif monsterState.IsBoss then
        resolvedSourceActor = sourceActor or monsterState.LastDamageSourceActor
    end

    if monsterState.IsBoss and not (options and options.isNukeSweep == true)
        and ActorUtils.IsPlayer(resolvedSourceActor)
        and self._playerStateService and self._playerStateService.RecordBossDefeated then
        self._playerStateService:RecordBossDefeated(resolvedSourceActor)
    end

    if resolvedSourceActor and self._playerStateService then
        local scoreReward = monsterState.KillScoreReward
            or (monsterState.IsBoss and GameConfig.BOSS.KillScoreReward)
            or GameConfig.MONSTER.KillScoreReward
        self._playerStateService:AddRebirthScore(resolvedSourceActor, scoreReward)
    end

    if deathPosition and self._experienceOrbService then
        local totalExperience = (monsterState.ExperienceDropCount or 0) * (monsterState.ExperiencePerOrb or 0)
        local visualCount = monsterState.ExperienceDropCount
        if monsterState.IsBoss then
            visualCount = self:_getBossExperienceVisualCount(monsterState)
        end
        self._experienceOrbService:DropExperience(
            deathPosition,
            totalExperience,
            visualCount,
            resolvedSourceActor,
            {
                applyExperienceMultiplier = true,
                authorizedExperienceReward = options and options.authorizedExperienceReward == true,
            }
        )
    end

    if deathPosition and monsterState.IsBoss and self._potionService and self._potionService.DropBossPotionForPlayer and ActorUtils.IsPlayer(resolvedSourceActor) then
        self._potionService:DropBossPotionForPlayer(deathPosition, resolvedSourceActor, "BossDrop")
    end

    if deathPosition and monsterState.IsBoss and self._buffService then
        self._buffService:DropBuffs(deathPosition, monsterState.BuffDropCount)
    end
end

function MonsterService:_handleMonsterDeath(monsterState, sourceActor)
    if not monsterState.Alive then
        return
    end

    monsterState.Alive = false
    local deathPosition = getInstancePosition(monsterState.RuntimeInstance)
    self:_awardMonsterRewards(monsterState, sourceActor, deathPosition)

    self:_destroyMonster(monsterState)
end

function MonsterService:SweepForNuke(sourceActor, originPosition, compressedOrbCount)
    local totalExperience = 0
    local totalScore = 0
    local dropPosition = typeof(originPosition) == "Vector3" and originPosition or nil
    local monstersToDestroy = {}
    local bossRewardEntries = {}

    for _, monsterState in pairs(self._monstersById) do
        if monsterState.Alive and monsterState.RuntimeInstance and monsterState.RuntimeInstance.Parent then
            monsterState.Alive = false
            if monsterState.IsBoss then
                table.insert(bossRewardEntries, {
                    MonsterState = monsterState,
                    DeathPosition = getInstancePosition(monsterState.RuntimeInstance) or dropPosition,
                })
            else
                dropPosition = dropPosition or getInstancePosition(monsterState.RuntimeInstance)
                totalExperience += (monsterState.ExperienceDropCount or 0) * (monsterState.ExperiencePerOrb or 0)
                totalScore += monsterState.KillScoreReward or GameConfig.MONSTER.KillScoreReward
            end
            table.insert(monstersToDestroy, monsterState)
        end
    end

    for _, entry in ipairs(bossRewardEntries) do
        self:_awardMonsterRewards(entry.MonsterState, sourceActor, entry.DeathPosition or dropPosition, {
            forceSourceActor = sourceActor,
            isNukeSweep = true,
            authorizedExperienceReward = true,
        })
    end

    for _, monsterState in ipairs(monstersToDestroy) do
        self:_destroyMonster(monsterState)
    end

    if sourceActor and self._playerStateService and totalScore > 0 then
        self._playerStateService:AddRebirthScore(sourceActor, totalScore)
    end

    if dropPosition and self._experienceOrbService and totalExperience > 0 then
        local orbCount = math.max(1, math.floor(tonumber(compressedOrbCount) or 12))
        if self._experienceOrbService.GrantNukeSweepExperience then
            self._experienceOrbService:GrantNukeSweepExperience(
                dropPosition,
                totalExperience,
                orbCount,
                sourceActor,
                {
                    applyExperienceMultiplier = true,
                }
            )
        elseif self._experienceOrbService.GrantCompressedExperience then
            self._experienceOrbService:GrantCompressedExperience(
                dropPosition,
                totalExperience,
                orbCount,
                sourceActor,
                {
                    applyExperienceMultiplier = true,
                }
            )
        else
            self._experienceOrbService:DropExperience(
                dropPosition,
                totalExperience,
                orbCount,
                sourceActor,
                {
                    applyExperienceMultiplier = true,
                }
            )
        end
    end

    return #monstersToDestroy
end

function MonsterService:ApplyWeaponDamage(monsterState, weaponState, sourceActor)
    return self:_applyWeaponDamage(monsterState, weaponState, sourceActor, nil)
end

function MonsterService:_fireBossHitFeedback(monsterState, sourceActor, appliedDamage, hitPosition)
    if not (self._bossHitFeedbackEvent and monsterState and monsterState.IsBoss) then
        return
    end

    local bossPosition = getInstancePosition(monsterState.RuntimeInstance)
    self._bossHitFeedbackEvent:FireAllClients({
        bossId = monsterState.Id,
        damage = math.max(0, math.floor(tonumber(appliedDamage) or 0)),
        remainingHealth = math.max(0, math.floor(tonumber(monsterState.CurrentHealth) or 0)),
        maxHealth = math.max(1, math.floor(tonumber(monsterState.MaxHealth) or 1)),
        hitPosition = typeof(hitPosition) == "Vector3" and hitPosition or bossPosition,
        attackerUserId = ActorUtils.IsPlayer(sourceActor) and sourceActor.UserId or nil,
        timestamp = os.clock(),
    })
end

function MonsterService:_applyWeaponDamage(monsterState, weaponState, sourceActor, hitPosition)
    if not (monsterState and weaponState and monsterState.Alive) then
        return false
    end

    local damageMultiplier = 1
    if sourceActor and self._buffService then
        damageMultiplier = self._buffService:GetDamageMultiplier(sourceActor)
    end
    local appliedDamage = math.max(0, math.floor((weaponState.BaseDamage or 0) * damageMultiplier))
    if appliedDamage <= 0 then
        return false
    end

    monsterState.LastDamageSourceActor = sourceActor
    monsterState.CurrentHealth = math.max(0, monsterState.CurrentHealth - appliedDamage)
    if monsterState.RuntimeInstance then
        monsterState.RuntimeInstance:SetAttribute("CurrentHealth", monsterState.CurrentHealth)
    end
    if monsterState.IsBoss then
        self:_updateBossHealthBar(monsterState)
        self:_fireBossHitFeedback(monsterState, sourceActor, appliedDamage, hitPosition)
    end

    if monsterState.CurrentHealth <= 0 then
        self:_handleMonsterDeath(monsterState, sourceActor)
    end
    return true
end

function MonsterService:_stepWeaponHits()
    local now = os.clock()
    for key, expiry in pairs(self._weaponHitCooldowns) do
        if expiry <= now then
            self._weaponHitCooldowns[key] = nil
        end
    end

    for _, actor in ipairs(self._playerStateService:GetArenaActors()) do
        for _, weaponState in ipairs(self._weaponService:GetWeaponStates(actor)) do
            local weaponPosition = self._weaponService:GetWeaponHitPosition(weaponState)
            if weaponState.Alive and weaponPosition then
                for _, monsterState in pairs(self._monstersById) do
                    if monsterState.Alive and monsterState.RuntimeInstance and monsterState.RuntimeInstance.Parent then
                        local monsterPosition = getInstancePosition(monsterState.RuntimeInstance)
                        if monsterPosition and self._weaponService:IsWeaponHitPosition(weaponState, monsterPosition, monsterState.ContactRadius) then
                            local cooldownKey = tostring(weaponState.Id) .. ":" .. monsterState.Id
                            if not self._weaponHitCooldowns[cooldownKey] then
                                self._weaponHitCooldowns[cooldownKey] = now + GameConfig.MONSTER.WeaponHitCooldownSeconds
                                self:_applyWeaponDamage(monsterState, weaponState, actor, weaponPosition)
                            end
                        end
                    end
                end
            end
        end
    end
end

function MonsterService:_maintainPopulation()
    if not GameConfig.MONSTER.ServerPopulationEnabled then
        return
    end

    local now = os.clock()
    if now < self._nextSpawnClock then
        return
    end
    self._nextSpawnClock = now + GameConfig.MONSTER.SpawnIntervalSeconds

    while self:GetActiveMonsterCount() < GameConfig.MONSTER.MaxActiveCount do
        if not self:SpawnMonster() then
            break
        end
    end
end

function MonsterService:BindSystems(dependencies)
    self._buffService = dependencies and dependencies.BuffService or self._buffService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
end

function MonsterService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._healthService = dependencies.HealthService
    self._experienceOrbService = dependencies.ExperienceOrbService
    self._buffService = dependencies.BuffService
    self._potionService = dependencies.PotionService
    self._bossHitFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("BossHitFeedback") or nil
    configureCollisionGroups()
    self._battlePart = resolveBattlePart()
    self._runtimeFolder = self:_createRuntimeFolder()
    self._templateFolder = resolveTemplateFolder()
    if self._templateFolder and not findTemplate(self._templateFolder, GameConfig.MONSTER.TemplateName) then
        MonsterService.CreatePlaceholderTemplate(self._templateFolder, GameConfig.MONSTER.TemplateName, false)
    end
    if self._templateFolder and not findTemplate(self._templateFolder, GameConfig.MONSTER.BossTemplateName) then
        MonsterService.CreatePlaceholderTemplate(self._templateFolder, GameConfig.MONSTER.BossTemplateName, true)
    end
    self._monstersById = {}
    self._weaponHitCooldowns = {}
    self._nextMonsterId = 1
    self._nextSpawnClock = 0
    self:_clearRuntimeFolder()

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    if not self._battlePart then
        warn("[MonsterService] 找不到 workspace.Battle，小怪刷新逻辑未启用。")
        return
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_maintainPopulation()
        for _, monsterState in pairs(self._monstersById) do
            self:_stepMonster(monsterState, deltaTime)
        end
        self:_stepWeaponHits()
    end)
end

return MonsterService
