--[[
脚本名字: BossSkillService
脚本文件: BossSkillService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/BossSkillService
说明: V6.0 Boss 技能服务，当前为 Boss2005 提供 FootballKick 技能。
]]

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
        "[BossSkillService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local BossSkillService = {}

BossSkillService._playerStateService = nil
BossSkillService._weaponService = nil
BossSkillService._battlePart = nil
BossSkillService._runtimeFolder = nil
BossSkillService._bossSkillsByMonsterId = {}
BossSkillService._activeProjectiles = {}
BossSkillService._heartbeatConnection = nil

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

local function resolveSkillTemplate(config)
    local path = config and config.TemplatePath
    if type(path) == "table" then
        local current = game
        for _, name in ipairs(path) do
            local childName = tostring(name)
            if current == game then
                local success, service = pcall(function()
                    return game:GetService(childName)
                end)
                current = success and service or current:FindFirstChild(childName)
            else
                current = current and current:FindFirstChild(childName)
            end
        end
        if current and (current:IsA("Model") or current:IsA("BasePart")) then
            return current
        end
    end

    local effectFolder = ReplicatedStorage:FindFirstChild("Effect")
    local template = effectFolder and effectFolder:FindFirstChild(tostring(config and config.TemplateName or "SkillMessi"))
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

local function configureProjectileInstance(instance)
    local baseParts = getBaseParts(instance)
    if instance:IsA("Model") and #baseParts > 0 then
        instance.PrimaryPart = instance.PrimaryPart or baseParts[1]
    end

    for _, basePart in ipairs(baseParts) do
        basePart.Anchored = true
        basePart.CanCollide = false
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
    end
end

local function resolveProjectileAuraPart(instance, config)
    if not instance then
        return nil
    end

    local auraName = tostring((config and config.AuraPartName) or (GameConfig.WEAPON and GameConfig.WEAPON.AuraPartName) or "Aura")
    if instance:IsA("BasePart") and (instance.Name == auraName or instance:GetAttribute("IsWeaponAura") == true) then
        return instance
    end

    local namedAura = instance:FindFirstChild(auraName, true)
    if namedAura and namedAura:IsA("BasePart") then
        return namedAura
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant:GetAttribute("IsWeaponAura") == true then
            return descendant
        end
    end

    return nil
end

local function isSphereTouchingBoxCFrame(center, radius, boxCFrame, boxSize)
    if not (typeof(center) == "Vector3" and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3") then
        return false
    end

    local localCenter = boxCFrame:PointToObjectSpace(center)
    local halfSize = boxSize * 0.5
    local closestPoint = Vector3.new(
        math.clamp(localCenter.X, -halfSize.X, halfSize.X),
        math.clamp(localCenter.Y, -halfSize.Y, halfSize.Y),
        math.clamp(localCenter.Z, -halfSize.Z, halfSize.Z)
    )

    return (localCenter - closestPoint).Magnitude <= math.max(0, tonumber(radius) or 0)
end

local function isSphereTouchingBox(center, radius, boxPart)
    if not (boxPart and boxPart:IsA("BasePart")) then
        return false
    end
    return isSphereTouchingBoxCFrame(center, radius, boxPart.CFrame, boxPart.Size)
end

local function getClosestDistanceToSegment(point, segmentStart, segmentEnd)
    if not (typeof(point) == "Vector3" and typeof(segmentStart) == "Vector3" and typeof(segmentEnd) == "Vector3") then
        return math.huge
    end

    local segment = segmentEnd - segmentStart
    local lengthSquared = segment:Dot(segment)
    if lengthSquared <= 0.0001 then
        return (point - segmentStart).Magnitude
    end

    local alpha = math.clamp((point - segmentStart):Dot(segment) / lengthSquared, 0, 1)
    local closestPoint = segmentStart + (segment * alpha)
    return (point - closestPoint).Magnitude
end

local function getPartSweepRadius(basePart, padding)
    if not (basePart and basePart:IsA("BasePart")) then
        return 0
    end

    local halfSize = basePart.Size * 0.5
    return math.max(halfSize.X, halfSize.Y, halfSize.Z) + math.max(0, tonumber(padding) or 0)
end

local function getPlanarDirection(fromPosition, toPosition)
    if not (typeof(fromPosition) == "Vector3" and typeof(toPosition) == "Vector3") then
        return nil
    end

    local delta = toPosition - fromPosition
    delta = Vector3.new(delta.X, 0, delta.Z)
    if delta.Magnitude <= 0.001 then
        return nil
    end
    return delta.Unit
end

local function smoothstep(alpha)
    local t = math.clamp(tonumber(alpha) or 0, 0, 1)
    return t * t * (3 - (2 * t))
end

function BossSkillService:_createRuntimeFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, "Runtime")
    return findOrCreateFolder(runtimeRoot, "BossSkills")
end

function BossSkillService:_clearRuntimeFolder()
    if not self._runtimeFolder then
        return
    end

    for _, child in ipairs(self._runtimeFolder:GetChildren()) do
        child:Destroy()
    end
end

function BossSkillService:_clampPositionInsideBattle(position, radius)
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
        localPosition.Y,
        math.clamp(localPosition.Z, -usableHalfZ, usableHalfZ)
    )
    return (self._battlePart.CFrame * CFrame.new(clampedLocalPosition)).Position
end

function BossSkillService:_getGroundY()
    if not self._battlePart then
        return 0
    end
    return self._battlePart.Position.Y + (self._battlePart.Size.Y * 0.5)
end

function BossSkillService:_getSkillConfig(skillName)
    local configs = GameConfig.BOSS_SKILLS and GameConfig.BOSS_SKILLS.Skills
    local config = configs and configs[tostring(skillName or "")]
    return type(config) == "table" and config or nil
end

function BossSkillService:_getBossSkillName(monsterDefinitionId)
    local bindings = GameConfig.BOSS_SKILLS and GameConfig.BOSS_SKILLS.BossBindings
    return bindings and bindings[tostring(monsterDefinitionId or "")] or nil
end

function BossSkillService:_buildInitialCooldown(config)
    local cooldownSeconds = math.max(0.1, tonumber(config and config.CooldownSeconds) or 20)
    local jitterMin = tonumber(config and config.InitialCooldownJitterMinSeconds) or -5
    local jitterMax = tonumber(config and config.InitialCooldownJitterMaxSeconds) or 5
    if jitterMax < jitterMin then
        jitterMin, jitterMax = jitterMax, jitterMin
    end

    local jitter = jitterMin + (math.random() * (jitterMax - jitterMin))
    return math.max(0.1, cooldownSeconds + jitter)
end

function BossSkillService:RegisterBoss(monsterState)
    if not (GameConfig.BOSS_SKILLS and GameConfig.BOSS_SKILLS.Enabled == true) then
        return false
    end
    if not (monsterState and monsterState.IsBoss == true) then
        return false
    end

    local skillName = self:_getBossSkillName(monsterState.MonsterDefinitionId)
    local config = self:_getSkillConfig(skillName)
    if not config then
        return false
    end

    self._bossSkillsByMonsterId[tostring(monsterState.Id)] = {
        BossState = monsterState,
        SkillName = skillName,
        NextCastAt = os.clock() + self:_buildInitialCooldown(config),
    }
    return true
end

function BossSkillService:_findNearestArenaActor(position)
    if not (self._playerStateService and typeof(position) == "Vector3") then
        return nil, nil
    end

    local nearestActor = nil
    local nearestDistance = math.huge
    for _, actor in ipairs(self._playerStateService:GetArenaActors()) do
        local state = self._playerStateService:GetState(actor)
        local rootPart = ActorUtils.GetRootPart(actor)
        if ActorUtils.IsPlayer(actor) and state and state.Alive and state.IsInArena and rootPart then
            local distance = (rootPart.Position - position).Magnitude
            if distance < nearestDistance then
                nearestActor = actor
                nearestDistance = distance
            end
        end
    end

    return nearestActor, nearestDistance
end

function BossSkillService:_getBossForwardDirection(bossState, bossPosition)
    local nearestActor = self:_findNearestArenaActor(bossPosition)
    local nearestRoot = ActorUtils.GetRootPart(nearestActor)
    return nearestRoot and getPlanarDirection(bossPosition, nearestRoot.Position) or nil
end

function BossSkillService:_spawnFootballProjectile(bossState, config)
    if not (self._runtimeFolder and bossState and bossState.RuntimeInstance and bossState.RuntimeInstance.Parent) then
        return false
    end

    local bossPosition = getInstancePosition(bossState.RuntimeInstance)
    if not bossPosition then
        return false
    end

    local direction = self:_getBossForwardDirection(bossState, bossPosition)
    if not direction then
        return false
    end

    local template = resolveSkillTemplate(config)
    if not template then
        warn("[BossSkillService] 缺少 FootballKick 模板 ReplicatedStorage.Effect.SkillMessi")
        return false
    end

    local contactRadius = tonumber(bossState.ContactRadius) or tonumber(GameConfig.BOSS.ContactRadius) or 7
    local spawnOffset = math.max(contactRadius + 2, tonumber(config.SpawnForwardOffset) or 9)
    local groundOffset = math.max(0, tonumber(config.GroundOffset) or 1.6)
    local hitRadius = tonumber(config.HitRadius) or 4
    local startPosition = bossPosition + (direction * spawnOffset)
    startPosition = Vector3.new(startPosition.X, self:_getGroundY() + groundOffset, startPosition.Z)
    startPosition = self:_clampPositionInsideBattle(startPosition, hitRadius)

    local distance = math.max(1, tonumber(config.DistanceStuds) or 100)
    local endPosition = self:_clampPositionInsideBattle(startPosition + (direction * distance), hitRadius)
    local travelDistance = (Vector3.new(endPosition.X, 0, endPosition.Z) - Vector3.new(startPosition.X, 0, startPosition.Z)).Magnitude
    if travelDistance <= 1 then
        return false
    end

    local duration = math.max(0.1, tonumber(config.TravelSeconds) or 1.35)
    local projectile = template:Clone()
    projectile.Name = string.format("BossFootballKick_%s", tostring(bossState.Id))
    configureProjectileInstance(projectile)
    local auraPart = resolveProjectileAuraPart(projectile, config)
    setInstanceCFrame(projectile, CFrame.new(startPosition, startPosition + direction))
    projectile.Parent = self._runtimeFolder

    table.insert(self._activeProjectiles, {
        Instance = projectile,
        AuraPart = auraPart,
        BossId = bossState.Id,
        Config = config,
        StartPosition = startPosition,
        EndPosition = endPosition,
        Direction = direction,
        Elapsed = 0,
        Duration = duration,
        PreviousPosition = startPosition,
        PreviousAuraCFrame = auraPart and auraPart.CFrame or nil,
        HitActorsById = {},
    })

    return true
end

function BossSkillService:_isFootballProjectileTouchingActor(projectileState, rootPart, previousPosition, position, previousAuraCFrame, currentAuraCFrame)
    local config = projectileState.Config or {}
    local auraPart = projectileState.AuraPart
    if auraPart and auraPart.Parent then
        local playerHitRadius = math.max(
            0,
            tonumber(config.PlayerHitRadius) or tonumber(GameConfig.COMBAT and GameConfig.COMBAT.PlayerBodyHitRadius) or 3.5
        )
        if isSphereTouchingBox(rootPart.Position, playerHitRadius, auraPart) then
            return true
        end
        if previousAuraCFrame and isSphereTouchingBoxCFrame(rootPart.Position, playerHitRadius, previousAuraCFrame, auraPart.Size) then
            return true
        end

        local sweepStart = previousAuraCFrame and previousAuraCFrame.Position or previousPosition
        local sweepEnd = currentAuraCFrame and currentAuraCFrame.Position or auraPart.Position
        local sweepPadding = tonumber(config.AuraSweepPadding) or 1.5
        local sweepRadius = getPartSweepRadius(auraPart, sweepPadding) + playerHitRadius
        return getClosestDistanceToSegment(rootPart.Position, sweepStart, sweepEnd) <= sweepRadius
    end

    local hitRadius = math.max(1, tonumber(config.HitRadius) or 4)
    local previous = typeof(previousPosition) == "Vector3" and previousPosition or position
    local sweepPadding = math.max(0, tonumber(config.AuraSweepPadding) or 1.5)
    return getClosestDistanceToSegment(rootPart.Position, previous, position) <= (hitRadius + sweepPadding)
end

function BossSkillService:_clearPlayerWeaponsForKnockback(actor, config)
    if not (self._weaponService and self._weaponService.ClearPlayerWeaponsForTemporaryRecovery) then
        return
    end

    self._weaponService:ClearPlayerWeaponsForTemporaryRecovery(actor, {
        source = "BossFootballKick",
        restoreDelaySeconds = config and config.WeaponRestoreDelaySeconds,
    })
end

function BossSkillService:_isRootNearGround(actor, rootPart, distance)
    if not rootPart then
        return false
    end

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local character = ActorUtils.GetCharacter(actor)
    params.FilterDescendantsInstances = character and { character } or {}

    local result = Workspace:Raycast(
        rootPart.Position,
        Vector3.new(0, -math.max(1, tonumber(distance) or 5), 0),
        params
    )
    return result ~= nil
end

function BossSkillService:_guardFootballFlyoutBounds(rootPart, config)
    local duration = math.max(0.1, tonumber(config.BoundaryGuardDurationSeconds) or 3.2)
    local interval = math.max(0.03, tonumber(config.BoundaryGuardIntervalSeconds) or 0.08)
    local damping = math.clamp(tonumber(config.BoundaryGuardVelocityDamping) or 0.35, 0, 1)
    local radius = tonumber(config.PlayerClampRadius) or 3
    local endClock = os.clock() + duration

    task.spawn(function()
        while rootPart and rootPart.Parent and os.clock() < endClock do
            local clampedPosition = self:_clampPositionInsideBattle(rootPart.Position, radius)
            if (clampedPosition - rootPart.Position).Magnitude > 0.1 then
                local lookVector = rootPart.CFrame.LookVector
                rootPart.CFrame = CFrame.new(clampedPosition, clampedPosition + lookVector)
                local velocity = rootPart.AssemblyLinearVelocity
                rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X * damping, math.min(velocity.Y, 0), velocity.Z * damping)
            end
            task.wait(interval)
        end
    end)
end

function BossSkillService:_startFootballBounceSequence(actor, rootPart, direction, config)
    local bounceCount = math.max(0, math.floor(tonumber(config.FlyoutBounceCount) or 3))
    if bounceCount <= 0 then
        return
    end

    local horizontalDamping = math.clamp(tonumber(config.FlyoutBounceHorizontalDamping) or 0.58, 0, 1)
    local upwardDecay = math.clamp(tonumber(config.FlyoutBounceUpwardDecay) or 0.62, 0, 1)
    local firstBounceUpwardSpeed = math.max(0, tonumber(config.FlyoutFirstBounceUpwardSpeed) or 58)
    local groundCheckDistance = math.max(1, tonumber(config.FlyoutGroundCheckDistance) or 5)
    local minDelay = math.max(0.05, tonumber(config.FlyoutBounceMinDelaySeconds) or 0.28)
    local timeout = math.max(minDelay, tonumber(config.FlyoutBounceTimeoutSeconds) or 1.1)
    local spinSpeed = math.max(0, tonumber(config.FlyoutSpinSpeed) or 20)

    task.spawn(function()
        for bounceIndex = 1, bounceCount do
            local waitStartedAt = os.clock()
            task.wait(minDelay)
            while rootPart and rootPart.Parent and os.clock() - waitStartedAt < timeout do
                if rootPart.AssemblyLinearVelocity.Y <= 4 and self:_isRootNearGround(actor, rootPart, groundCheckDistance) then
                    break
                end
                task.wait(0.05)
            end

            if not (rootPart and rootPart.Parent) then
                break
            end

            local upwardSpeed = firstBounceUpwardSpeed * (upwardDecay ^ (bounceIndex - 1))
            if upwardSpeed <= 2 then
                break
            end

            local currentVelocity = rootPart.AssemblyLinearVelocity
            local horizontalVelocity = Vector3.new(currentVelocity.X, 0, currentVelocity.Z) * horizontalDamping
            if horizontalVelocity.Magnitude <= 4 then
                local fallbackHorizontalSpeed = math.max(0, tonumber(config.KnockbackHorizontalSpeed) or 65)
                horizontalVelocity = direction * fallbackHorizontalSpeed * (horizontalDamping ^ bounceIndex)
            end

            local bounceVelocity = Vector3.new(horizontalVelocity.X, upwardSpeed, horizontalVelocity.Z)
            rootPart.AssemblyLinearVelocity = bounceVelocity
            rootPart.AssemblyAngularVelocity = Vector3.new(-direction.Z, 0.35, direction.X) * spinSpeed * (upwardDecay ^ (bounceIndex - 1))
            pcall(function()
                rootPart:ApplyImpulse(bounceVelocity * math.max(1, rootPart.AssemblyMass) * 0.45)
            end)
        end
    end)
end

function BossSkillService:_applyFootballKnockback(actor, projectileState)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not rootPart then
        return
    end

    local config = projectileState.Config or {}
    local direction = projectileState.Direction or Vector3.xAxis
    local horizontalSpeed = math.max(0, tonumber(config.KnockbackHorizontalSpeed) or 65)
    local upwardSpeed = math.max(0, tonumber(config.KnockbackUpwardSpeed) or 35)
    local knockbackVelocity = Vector3.new(
        direction.X * horizontalSpeed,
        upwardSpeed,
        direction.Z * horizontalSpeed
    )
    local impulseMultiplier = math.max(0, tonumber(config.KnockbackImpulseMultiplier) or 1.35)
    local flyoutControlSeconds = math.max(0.1, tonumber(config.FlyoutControlSeconds) or 3.2)
    local spinSpeed = math.max(0, tonumber(config.FlyoutSpinSpeed) or 20)

    self:_clearPlayerWeaponsForKnockback(actor, config)
    pcall(function()
        rootPart:SetNetworkOwner(nil)
    end)

    local humanoid = ActorUtils.GetHumanoid(actor)
    local previousPlatformStand = humanoid and humanoid.PlatformStand or nil
    local previousAutoRotate = humanoid and humanoid.AutoRotate or nil
    if humanoid then
        humanoid.PlatformStand = true
        humanoid.AutoRotate = false
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        end)
    end

    rootPart.AssemblyLinearVelocity = Vector3.zero
    rootPart.AssemblyAngularVelocity = Vector3.zero
    rootPart.AssemblyLinearVelocity = knockbackVelocity
    rootPart.AssemblyAngularVelocity = Vector3.new(-direction.Z, 0.35, direction.X) * spinSpeed
    pcall(function()
        rootPart:ApplyImpulse(knockbackVelocity * math.max(1, rootPart.AssemblyMass) * impulseMultiplier)
    end)

    self:_startFootballBounceSequence(actor, rootPart, direction, config)
    self:_guardFootballFlyoutBounds(rootPart, config)

    task.delay(flyoutControlSeconds, function()
        if humanoid and humanoid.Parent then
            humanoid.PlatformStand = previousPlatformStand == true
            humanoid.AutoRotate = previousAutoRotate ~= false
            pcall(function()
                humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)
        end
    end)

    local networkOwnerReleaseDelay = math.max(0.05, tonumber(config.NetworkOwnerReleaseDelaySeconds) or flyoutControlSeconds)
    task.delay(networkOwnerReleaseDelay, function()
        if rootPart and rootPart.Parent and ActorUtils.IsPlayer(actor) and actor.Parent then
            pcall(function()
                rootPart:SetNetworkOwner(actor)
            end)
        end
    end)
end

function BossSkillService:_checkProjectileHits(projectileState, previousPosition, position, previousAuraCFrame, currentAuraCFrame)
    if not (self._playerStateService and typeof(position) == "Vector3") then
        return
    end

    local config = projectileState.Config or {}
    for _, actor in ipairs(self._playerStateService:GetArenaActors()) do
        local actorId = ActorUtils.GetActorId(actor)
        if ActorUtils.IsPlayer(actor) and projectileState.HitActorsById[actorId] ~= true then
            local state = self._playerStateService:GetState(actor)
            local rootPart = ActorUtils.GetRootPart(actor)
            if state and state.Alive and state.IsInArena and rootPart then
                if self:_isFootballProjectileTouchingActor(projectileState, rootPart, previousPosition, position, previousAuraCFrame, currentAuraCFrame) then
                    projectileState.HitActorsById[actorId] = true
                    self:_applyFootballKnockback(actor, projectileState)
                end
            end
        end
    end
end

function BossSkillService:_stepProjectiles(deltaTime)
    for index = #self._activeProjectiles, 1, -1 do
        local projectileState = self._activeProjectiles[index]
        local instance = projectileState.Instance
        if not (instance and instance.Parent) then
            table.remove(self._activeProjectiles, index)
            continue
        end

        projectileState.Elapsed += math.max(0, deltaTime)
        local alpha = math.clamp(projectileState.Elapsed / projectileState.Duration, 0, 1)
        local eased = smoothstep(alpha)
        local position = projectileState.StartPosition:Lerp(projectileState.EndPosition, eased)
        local direction = projectileState.Direction or Vector3.xAxis
        local previousPosition = projectileState.PreviousPosition or position
        local previousAuraCFrame = projectileState.PreviousAuraCFrame
        setInstanceCFrame(instance, CFrame.new(position, position + direction))
        local auraPart = projectileState.AuraPart
        local currentAuraCFrame = auraPart and auraPart.Parent and auraPart.CFrame or nil
        self:_checkProjectileHits(projectileState, previousPosition, position, previousAuraCFrame, currentAuraCFrame)
        projectileState.PreviousPosition = position
        projectileState.PreviousAuraCFrame = currentAuraCFrame

        if alpha >= 1 then
            instance:Destroy()
            table.remove(self._activeProjectiles, index)
        end
    end
end

function BossSkillService:_stepBossSkills()
    local now = os.clock()
    for monsterId, skillState in pairs(self._bossSkillsByMonsterId) do
        local bossState = skillState.BossState
        if not (bossState and bossState.Alive and bossState.RuntimeInstance and bossState.RuntimeInstance.Parent) then
            self._bossSkillsByMonsterId[monsterId] = nil
            continue
        end

        if now >= (tonumber(skillState.NextCastAt) or now) then
            local config = self:_getSkillConfig(skillState.SkillName)
            if not config then
                self._bossSkillsByMonsterId[monsterId] = nil
                continue
            end

            if self:_spawnFootballProjectile(bossState, config) then
                skillState.NextCastAt = now + math.max(0.1, tonumber(config.CooldownSeconds) or 20)
            else
                skillState.NextCastAt = now + math.max(0.5, tonumber(config.RetryDelaySeconds) or 2)
            end
        end
    end
end

function BossSkillService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._battlePart = resolveBattlePart()
    self._runtimeFolder = self:_createRuntimeFolder()
    self._bossSkillsByMonsterId = {}
    self._activeProjectiles = {}
    self:_clearRuntimeFolder()

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    if not self._battlePart then
        warn("[BossSkillService] 找不到 workspace.Battle，Boss 技能逻辑未启用。")
        return
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_stepBossSkills()
        self:_stepProjectiles(deltaTime)
    end)
end

return BossSkillService
