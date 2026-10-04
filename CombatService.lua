--[[
脚本名字: CombatService
脚本文件: CombatService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/CombatService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

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
        "[CombatService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local CombatService = {}

CombatService._playerStateService = nil
CombatService._weaponService = nil
CombatService._healthService = nil
CombatService._taskService = nil
CombatService._arenaService = nil
CombatService._remoteEventService = nil
CombatService._combatFeedbackEvent = nil
CombatService._heartbeatConnection = nil
CombatService._weaponPairCooldowns = {}
CombatService._weaponActorCooldowns = {}
CombatService._combatAccumulator = 0
CombatService._perfStats = nil
CombatService._nextPerfLogClock = 0

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 5)
end

local function getCombatStepInterval()
    return math.max(0, tonumber(GameConfig.COMBAT and GameConfig.COMBAT.StepIntervalSeconds) or 0)
end

local function getActorCullPadding()
    return math.max(0, tonumber(GameConfig.COMBAT and GameConfig.COMBAT.ActorCullPadding) or 0)
end

local function getDistanceSquared(positionA, positionB)
    local delta = positionA - positionB
    return (delta.X * delta.X) + (delta.Y * delta.Y) + (delta.Z * delta.Z)
end

local function getWeaponPosition(weaponState)
    local weaponService = CombatService._weaponService
    if weaponService then
        return weaponService:GetWeaponHitPosition(weaponState)
    end
    return nil
end

local function getWeaponCollisionReach(weaponState)
    local weaponService = CombatService._weaponService
    if weaponService then
        return weaponService:GetWeaponHitRadius(weaponState)
    end
    return 0
end

local function isWeaponHittingPosition(weaponState, targetPosition, targetRadius)
    local weaponService = CombatService._weaponService
    if not weaponService then
        return false
    end
    return weaponService:IsWeaponHitPosition(weaponState, targetPosition, targetRadius)
end

function CombatService:_makePairKey(idA, idB)
    if tostring(idA) < tostring(idB) then
        return tostring(idA) .. ":" .. tostring(idB)
    end
    return tostring(idB) .. ":" .. tostring(idA)
end

function CombatService:_pruneCooldowns(now)
    for key, expiry in pairs(self._weaponPairCooldowns) do
        if expiry <= now then
            self._weaponPairCooldowns[key] = nil
        end
    end

    for key, expiry in pairs(self._weaponActorCooldowns) do
        if expiry <= now then
            self._weaponActorCooldowns[key] = nil
        end
    end
end

function CombatService:_resetPerfStats()
    self._perfStats = {
        Steps = 0,
        ActorCount = 0,
        WeaponCount = 0,
        ActorPairChecks = 0,
        ActorPairSkippedByDistance = 0,
        ActorPairSkippedBotOnly = 0,
        WeaponPairChecks = 0,
        WeaponPairNarrowChecks = 0,
        WeaponActorChecks = 0,
        CombatFeedbackEvents = 0,
        CombatFeedbackSent = 0,
        CombatFeedbackSkipped = 0,
        ElapsedSeconds = 0,
    }
end

function CombatService:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function CombatService:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats
    if stats and stats.Steps and stats.Steps > 0 then
        local pairCooldowns = 0
        for _ in pairs(self._weaponPairCooldowns or {}) do
            pairCooldowns += 1
        end
        local actorCooldowns = 0
        for _ in pairs(self._weaponActorCooldowns or {}) do
            actorCooldowns += 1
        end
        print(string.format(
            "[Perf][CombatService] steps=%d actorsMax=%d weaponsMax=%d actorPairs=%d skippedFar=%d skippedBotOnly=%d weaponPairs=%d narrow=%d actorHits=%d feedback=%d sent=%d skipped=%d elapsedMs=%.3f pairCooldowns=%d actorCooldowns=%d",
            stats.Steps,
            stats.ActorCount or 0,
            stats.WeaponCount or 0,
            stats.ActorPairChecks or 0,
            stats.ActorPairSkippedByDistance or 0,
            stats.ActorPairSkippedBotOnly or 0,
            stats.WeaponPairChecks or 0,
            stats.WeaponPairNarrowChecks or 0,
            stats.WeaponActorChecks or 0,
            stats.CombatFeedbackEvents or 0,
            stats.CombatFeedbackSent or 0,
            stats.CombatFeedbackSkipped or 0,
            (stats.ElapsedSeconds or 0) * 1000,
            pairCooldowns,
            actorCooldowns
        ))
    end

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function CombatService:_buildActorCombatSnapshot(arenaActors)
    local snapshots = {}
    local totalWeaponCount = 0

    for _, actor in ipairs(arenaActors) do
        local state = self._playerStateService:GetState(actor)
        if state and state.Alive then
            local rootPart = ActorUtils.GetRootPart(actor)
            local rootPosition = rootPart and rootPart.Position or nil
            if rootPart and rootPosition then
                local weaponSnapshots = {}
                local maxWeaponReach = 0

                for _, weaponState in ipairs(self._weaponService:GetWeaponStates(actor)) do
                    if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                        local position = getWeaponPosition(weaponState)
                        if position then
                            local radius = math.max(GameConfig.COMBAT.WeaponHitRadiusMin, getWeaponCollisionReach(weaponState))
                            local actorReach = math.sqrt(getDistanceSquared(rootPosition, position)) + radius
                            table.insert(weaponSnapshots, {
                                State = weaponState,
                                Position = position,
                                Radius = radius,
                            })
                            maxWeaponReach = math.max(maxWeaponReach, actorReach)
                            totalWeaponCount += 1
                        end
                    end
                end

                table.insert(snapshots, {
                    Actor = actor,
                    RootPart = rootPart,
                    RootPosition = rootPosition,
                    Weapons = weaponSnapshots,
                    MaxWeaponReach = maxWeaponReach,
                    ActorId = ActorUtils.GetActorId(actor),
                    IsPlayer = ActorUtils.IsPlayer(actor),
                })
            end
        end
    end

    self:_addPerfStat("ActorCount", math.max(0, #snapshots - (self._perfStats and self._perfStats.ActorCount or 0)))
    self:_addPerfStat("WeaponCount", math.max(0, totalWeaponCount - (self._perfStats and self._perfStats.WeaponCount or 0)))
    return snapshots
end

function CombatService:_canActorSnapshotsInteract(attackerSnapshot, defenderSnapshot)
    local cullDistance = (attackerSnapshot.MaxWeaponReach or 0)
        + (defenderSnapshot.MaxWeaponReach or 0)
        + GameConfig.COMBAT.PlayerBodyHitRadius
        + getActorCullPadding()
    return getDistanceSquared(attackerSnapshot.RootPosition, defenderSnapshot.RootPosition) <= cullDistance * cullDistance
end

function CombatService:_fireCombatFeedback(eventType, sourceUserId, targetUserId, damage, remainingHealth)
    if not self._combatFeedbackEvent then
        self:_addPerfStat("CombatFeedbackSkipped")
        return
    end

    self:_addPerfStat("CombatFeedbackEvents")
    local payload = {
        eventType = eventType,
        sourceUserId = sourceUserId,
        targetUserId = targetUserId,
        damage = damage,
        remainingHealth = remainingHealth,
        timestamp = os.clock(),
    }

    local sourcePlayer = Players:GetPlayerByUserId(tonumber(sourceUserId) or 0)
    local targetPlayer = Players:GetPlayerByUserId(tonumber(targetUserId) or 0)
    local sentCount = 0

    if sourcePlayer then
        self._combatFeedbackEvent:FireClient(sourcePlayer, payload)
        sentCount += 1
    end
    if targetPlayer and targetPlayer ~= sourcePlayer then
        self._combatFeedbackEvent:FireClient(targetPlayer, payload)
        sentCount += 1
    end

    if sentCount > 0 then
        self:_addPerfStat("CombatFeedbackSent", sentCount)
    else
        self:_addPerfStat("CombatFeedbackSkipped")
    end
end

function CombatService:_isSafeZoneProtected(actor)
    return self._arenaService
        and self._arenaService.IsActorInsideSafeZone
        and self._arenaService:IsActorInsideSafeZone(actor) == true
end

function CombatService:_recordEnemyWeaponBroken(sourceActor, targetActor)
    if not (self._taskService and self._taskService.RecordEnemyWeaponBroken) then
        return
    end
    local ok, failure = pcall(self._taskService.RecordEnemyWeaponBroken, self._taskService, sourceActor, targetActor)
    if not ok then
        warn("[CombatService] Failed to record enemy weapon break: " .. tostring(failure))
    end
end

function CombatService:_applyWeaponVsWeapon(weaponStateA, weaponStateB)
    local ownerA = self._weaponService:_resolveActorByCombatUserId(weaponStateA.OwnerUserId)
    local ownerB = self._weaponService:_resolveActorByCombatUserId(weaponStateB.OwnerUserId)
    if not (ownerA and ownerB) then
        return
    end
    if self:_isSafeZoneProtected(ownerA) or self:_isSafeZoneProtected(ownerB) then
        return
    end

    local positionA = getWeaponPosition(weaponStateA)
    local positionB = getWeaponPosition(weaponStateB)
    local collisionMidpoint = nil
    if positionA and positionB then
        collisionMidpoint = (positionA + positionB) * 0.5
    end

    local combatRankA = tonumber(weaponStateA.CombatRank) or tonumber(weaponStateA.TierIndex) or 0
    local combatRankB = tonumber(weaponStateB.CombatRank) or tonumber(weaponStateB.TierIndex) or 0

    self:_fireCombatFeedback("WeaponHitWeapon", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, weaponStateB.TierIndex)
    self:_fireCombatFeedback("WeaponHitWeapon", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, weaponStateA.TierIndex)

    if combatRankA == combatRankB then
        local didBreakA = self._weaponService:HandleBrokenWeapon(weaponStateA, {
            sourceWeaponId = weaponStateB.Id,
            sourceCombatRank = combatRankB,
            impactPosition = collisionMidpoint,
            launchDirection = positionA and positionB and (positionA - positionB) or nil,
        })
        if didBreakA then
            self:_recordEnemyWeaponBroken(ownerB, ownerA)
            self:_fireCombatFeedback("WeaponBroken", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, 0)
        end

        local didBreakB = self._weaponService:HandleBrokenWeapon(weaponStateB, {
            sourceWeaponId = weaponStateA.Id,
            sourceCombatRank = combatRankA,
            impactPosition = collisionMidpoint,
            launchDirection = positionB and positionA and (positionB - positionA) or nil,
        })
        if didBreakB then
            self:_recordEnemyWeaponBroken(ownerA, ownerB)
            self:_fireCombatFeedback("WeaponBroken", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, 0)
        end
        return
    end

    if combatRankA > combatRankB then
        local didBreakB = self._weaponService:HandleBrokenWeapon(weaponStateB, {
            sourceWeaponId = weaponStateA.Id,
            sourceCombatRank = combatRankA,
            impactPosition = collisionMidpoint,
            launchDirection = positionB and positionA and (positionB - positionA) or nil,
        })
        if didBreakB then
            self:_recordEnemyWeaponBroken(ownerA, ownerB)
            self:_fireCombatFeedback("WeaponBroken", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, 0)
        end
        return
    end

    local didBreakA = self._weaponService:HandleBrokenWeapon(weaponStateA, {
        sourceWeaponId = weaponStateB.Id,
        sourceCombatRank = combatRankB,
        impactPosition = collisionMidpoint,
        launchDirection = positionA and positionB and (positionA - positionB) or nil,
    })
    if didBreakA then
        self:_recordEnemyWeaponBroken(ownerB, ownerA)
        self:_fireCombatFeedback("WeaponBroken", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, 0)
    end
end

function CombatService:_applyKnockback(targetActor, sourceActor)
    if self:_isSafeZoneProtected(targetActor) or self:_isSafeZoneProtected(sourceActor) then
        return
    end

    local targetRoot = ActorUtils.GetRootPart(targetActor)
    local sourceRoot = ActorUtils.GetRootPart(sourceActor)
    if not (targetRoot and sourceRoot) then
        return
    end

    local direction = targetRoot.Position - sourceRoot.Position
    direction = Vector3.new(direction.X, 0, direction.Z)
    if direction.Magnitude <= 0 then
        direction = targetRoot.CFrame.LookVector
        direction = Vector3.new(direction.X, 0, direction.Z)
    end
    if direction.Magnitude <= 0 then
        direction = Vector3.xAxis
    end

    local knockbackVelocity = direction.Unit * GameConfig.COMBAT.PlayerKnockbackSpeed
    targetRoot.AssemblyLinearVelocity = Vector3.new(
        knockbackVelocity.X,
        GameConfig.COMBAT.PlayerKnockbackUpwardSpeed,
        knockbackVelocity.Z
    )
end

function CombatService:_applyWeaponVsActor(weaponState, targetActor)
    local sourceActor = self._weaponService:_resolveActorByCombatUserId(weaponState.OwnerUserId)
    if not sourceActor then
        return
    end
    if self:_isSafeZoneProtected(targetActor) or self:_isSafeZoneProtected(sourceActor) then
        return
    end

    local didDamage, didKill, remainingHealth = self._healthService:ApplyWeaponDamage(targetActor, weaponState.BaseDamage, sourceActor)
    if didDamage then
        self:_applyKnockback(targetActor, sourceActor)
        self:_fireCombatFeedback("WeaponHitPlayer", weaponState.OwnerUserId, ActorUtils.GetCombatUserId(targetActor), weaponState.BaseDamage, remainingHealth)
        if didKill then
            self:_fireCombatFeedback("PlayerKilled", weaponState.OwnerUserId, ActorUtils.GetCombatUserId(targetActor), weaponState.BaseDamage, 0)
        end
    end
end

function CombatService:_stepCombat()
    local stepStartedAt = isPerformanceDebugEnabled() and os.clock() or nil
    local now = os.clock()
    self:_pruneCooldowns(now)

    local arenaActors = self._playerStateService:GetArenaActors()
    local actorSnapshots = self:_buildActorCombatSnapshot(arenaActors)

    for _, attackerSnapshot in ipairs(actorSnapshots) do
        for _, weaponSnapshot in ipairs(attackerSnapshot.Weapons) do
            local weaponState = weaponSnapshot.State
            if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                for _, defenderSnapshot in ipairs(actorSnapshots) do
                    if not weaponState.Alive then
                        break
                    end

                    if not ActorUtils.IsSameActor(defenderSnapshot.Actor, attackerSnapshot.Actor) then
                        self:_addPerfStat("ActorPairChecks")
                        if attackerSnapshot.IsPlayer ~= true and defenderSnapshot.IsPlayer ~= true then
                            self:_addPerfStat("ActorPairSkippedBotOnly")
                            continue
                        end
                        if not self:_canActorSnapshotsInteract(attackerSnapshot, defenderSnapshot) then
                            self:_addPerfStat("ActorPairSkippedByDistance")
                            continue
                        end

                        local didHitWeapon = false
                        for _, defenderWeaponSnapshot in ipairs(defenderSnapshot.Weapons) do
                            local defenderWeaponState = defenderWeaponSnapshot.State
                            if defenderWeaponState.Alive and defenderWeaponState.RuntimeInstance and defenderWeaponState.RuntimeInstance.Parent then
                                self:_addPerfStat("WeaponPairChecks")
                                local reach = weaponSnapshot.Radius + defenderWeaponSnapshot.Radius
                                if getDistanceSquared(weaponSnapshot.Position, defenderWeaponSnapshot.Position) <= reach * reach then
                                    self:_addPerfStat("WeaponPairNarrowChecks")
                                    if isWeaponHittingPosition(weaponState, defenderWeaponSnapshot.Position, defenderWeaponSnapshot.Radius)
                                        or isWeaponHittingPosition(defenderWeaponState, weaponSnapshot.Position, weaponSnapshot.Radius) then
                                        local pairKey = self:_makePairKey(weaponState.Id, defenderWeaponState.Id)
                                        if not self._weaponPairCooldowns[pairKey] then
                                            self._weaponPairCooldowns[pairKey] = now + GameConfig.COMBAT.WeaponVsWeaponHitCooldownSeconds
                                            self:_applyWeaponVsWeapon(weaponState, defenderWeaponState)
                                        end
                                        didHitWeapon = true
                                        break
                                    end
                                end
                            end
                        end

                        if not didHitWeapon then
                            self:_addPerfStat("WeaponActorChecks")
                            if isWeaponHittingPosition(weaponState, defenderSnapshot.RootPosition, GameConfig.COMBAT.PlayerBodyHitRadius) then
                                local pairKey = tostring(weaponState.Id) .. ":" .. tostring(defenderSnapshot.ActorId)
                                if not self._weaponActorCooldowns[pairKey] then
                                    self._weaponActorCooldowns[pairKey] = now + GameConfig.COMBAT.WeaponVsPlayerHitCooldownSeconds
                                    self:_applyWeaponVsActor(weaponState, defenderSnapshot.Actor)
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if stepStartedAt then
        self:_addPerfStat("Steps")
        self:_addPerfStat("ElapsedSeconds", os.clock() - stepStartedAt)
        self:_logPerfStats(os.clock())
    end
end

function CombatService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._healthService = dependencies.HealthService
    self._taskService = dependencies.TaskService
    self._arenaService = dependencies.ArenaService
    self._remoteEventService = dependencies.RemoteEventService
    self._combatFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("CombatFeedback") or nil
    self._weaponPairCooldowns = {}
    self._weaponActorCooldowns = {}
    self._combatAccumulator = 0
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        local stepInterval = getCombatStepInterval()
        if stepInterval <= 0 then
            self:_stepCombat()
            return
        end

        self._combatAccumulator = math.min((self._combatAccumulator or 0) + deltaTime, stepInterval * 2)
        if self._combatAccumulator < stepInterval then
            self:_logPerfStats(os.clock())
            return
        end

        self._combatAccumulator -= stepInterval
        self:_stepCombat()
    end)
end

return CombatService
