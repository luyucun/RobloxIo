--[[
脚本名字: CombatService
脚本文件: CombatService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/CombatService
]]

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
        "[CombatService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local CombatService = {}

CombatService._playerStateService = nil
CombatService._weaponService = nil
CombatService._healthService = nil
CombatService._remoteEventService = nil
CombatService._combatFeedbackEvent = nil
CombatService._heartbeatConnection = nil
CombatService._weaponPairCooldowns = {}
CombatService._weaponActorCooldowns = {}

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

function CombatService:_fireCombatFeedback(eventType, sourceUserId, targetUserId, damage, remainingHealth)
    if not self._combatFeedbackEvent then
        return
    end

    self._combatFeedbackEvent:FireAllClients({
        eventType = eventType,
        sourceUserId = sourceUserId,
        targetUserId = targetUserId,
        damage = damage,
        remainingHealth = remainingHealth,
        timestamp = os.clock(),
    })
end

function CombatService:_applyWeaponVsWeapon(weaponStateA, weaponStateB)
    local ownerA = self._weaponService:_resolveActorByCombatUserId(weaponStateA.OwnerUserId)
    local ownerB = self._weaponService:_resolveActorByCombatUserId(weaponStateB.OwnerUserId)
    if not (ownerA and ownerB) then
        return
    end

    local positionA = getWeaponPosition(weaponStateA)
    local positionB = getWeaponPosition(weaponStateB)
    local collisionMidpoint = nil
    if positionA and positionB then
        collisionMidpoint = (positionA + positionB) * 0.5
    end

    local tierIndexA = tonumber(weaponStateA.TierIndex) or 0
    local tierIndexB = tonumber(weaponStateB.TierIndex) or 0

    self:_fireCombatFeedback("WeaponHitWeapon", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, tierIndexB)
    self:_fireCombatFeedback("WeaponHitWeapon", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, tierIndexA)

    if tierIndexA == tierIndexB then
        local didBreakA = self._weaponService:HandleBrokenWeapon(weaponStateA, {
            sourceWeaponId = weaponStateB.Id,
            sourceTierIndex = tierIndexB,
            impactPosition = collisionMidpoint,
            launchDirection = positionA and positionB and (positionA - positionB) or nil,
        })
        if didBreakA then
            self:_fireCombatFeedback("WeaponBroken", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, 0)
        end

        local didBreakB = self._weaponService:HandleBrokenWeapon(weaponStateB, {
            sourceWeaponId = weaponStateA.Id,
            sourceTierIndex = tierIndexA,
            impactPosition = collisionMidpoint,
            launchDirection = positionB and positionA and (positionB - positionA) or nil,
        })
        if didBreakB then
            self:_fireCombatFeedback("WeaponBroken", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, 0)
        end
        return
    end

    if tierIndexA > tierIndexB then
        local didBreakB = self._weaponService:HandleBrokenWeapon(weaponStateB, {
            sourceWeaponId = weaponStateA.Id,
            sourceTierIndex = tierIndexA,
            impactPosition = collisionMidpoint,
            launchDirection = positionB and positionA and (positionB - positionA) or nil,
        })
        if didBreakB then
            self:_fireCombatFeedback("WeaponBroken", weaponStateA.OwnerUserId, weaponStateB.OwnerUserId, weaponStateA.BaseDamage, 0)
        end
        return
    end

    local didBreakA = self._weaponService:HandleBrokenWeapon(weaponStateA, {
        sourceWeaponId = weaponStateB.Id,
        sourceTierIndex = tierIndexB,
        impactPosition = collisionMidpoint,
        launchDirection = positionA and positionB and (positionA - positionB) or nil,
    })
    if didBreakA then
        self:_fireCombatFeedback("WeaponBroken", weaponStateB.OwnerUserId, weaponStateA.OwnerUserId, weaponStateB.BaseDamage, 0)
    end
end

function CombatService:_applyKnockback(targetActor, sourceActor)
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
    local now = os.clock()
    self:_pruneCooldowns(now)

    local arenaActors = self._playerStateService:GetArenaActors()

    for _, attacker in ipairs(arenaActors) do
        local attackerState = self._playerStateService:GetState(attacker)
        if attackerState.Alive then
            local attackerWeapons = self._weaponService:GetWeaponStates(attacker)
            for _, weaponState in ipairs(attackerWeapons) do
                if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                    for _, defender in ipairs(arenaActors) do
                        if not weaponState.Alive then
                            break
                        end
                        if not ActorUtils.IsSameActor(defender, attacker) then
                            local defenderState = self._playerStateService:GetState(defender)
                            if defenderState.Alive then
                                local defenderWeapons = self._weaponService:GetWeaponStates(defender)
                                local didHitWeapon = false

                                for _, defenderWeaponState in ipairs(defenderWeapons) do
                                    if defenderWeaponState.Alive and defenderWeaponState.RuntimeInstance and defenderWeaponState.RuntimeInstance.Parent then
                                        local attackerPosition = getWeaponPosition(weaponState)
                                        local defenderPosition = getWeaponPosition(defenderWeaponState)
                                        if attackerPosition and defenderPosition then
                                            local attackerRadius = math.max(GameConfig.COMBAT.WeaponHitRadiusMin, getWeaponCollisionReach(weaponState))
                                            local defenderRadius = math.max(GameConfig.COMBAT.WeaponHitRadiusMin, getWeaponCollisionReach(defenderWeaponState))
                                            if isWeaponHittingPosition(weaponState, defenderPosition, defenderRadius)
                                                or isWeaponHittingPosition(defenderWeaponState, attackerPosition, attackerRadius) then
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
                                    local defenderRoot = ActorUtils.GetRootPart(defender)
                                    local attackerPosition = getWeaponPosition(weaponState)
                                    if defenderRoot and attackerPosition then
                                        if isWeaponHittingPosition(weaponState, defenderRoot.Position, GameConfig.COMBAT.PlayerBodyHitRadius) then
                                            local pairKey = tostring(weaponState.Id) .. ":" .. tostring(ActorUtils.GetActorId(defender))
                                            if not self._weaponActorCooldowns[pairKey] then
                                                self._weaponActorCooldowns[pairKey] = now + GameConfig.COMBAT.WeaponVsPlayerHitCooldownSeconds
                                                self:_applyWeaponVsActor(weaponState, defender)
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function CombatService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._healthService = dependencies.HealthService
    self._remoteEventService = dependencies.RemoteEventService
    self._combatFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("CombatFeedback") or nil
    self._weaponPairCooldowns = {}
    self._weaponActorCooldowns = {}

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_stepCombat()
    end)
end

return CombatService
