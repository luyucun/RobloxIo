--[[
脚本名字: HealthService
脚本文件: HealthService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/HealthService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[HealthService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local HealthService = {}

HealthService._playerStateService = nil
HealthService._remoteEventService = nil
HealthService._respawnService = nil
HealthService._deathFeedbackEvent = nil
HealthService._buffService = nil

local function buildKillerPayload(playerStateService, sourceActor)
    if not ActorUtils.IsPlayer(sourceActor) then
        return nil
    end

    local state = playerStateService and playerStateService:GetState(sourceActor) or nil
    return {
        userId = sourceActor.UserId,
        name = sourceActor.DisplayName ~= "" and sourceActor.DisplayName or sourceActor.Name,
        level = state and state.Level or GameConfig.PLAYER.BaseLevel,
        killCount = state and state.KillCount or 0,
    }
end

function HealthService:_fireDeathFeedback(actor, sourceActor)
    if not self._deathFeedbackEvent then
        return
    end
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local killerUserId = sourceActor and ActorUtils.GetCombatUserId(sourceActor) or nil
    self._deathFeedbackEvent:FireClient(actor, {
        reason = "WeaponDamage",
        killerUserId = killerUserId,
        killer = buildKillerPayload(self._playerStateService, sourceActor),
        timestamp = os.clock(),
    })
end

function HealthService:_handleActorKill(targetActor, sourceActor)
    if sourceActor and not ActorUtils.IsSameActor(sourceActor, targetActor) then
        if ActorUtils.IsPlayer(sourceActor) and ActorUtils.IsPlayer(targetActor) then
            self._playerStateService:AwardPlayerKillReward(sourceActor, targetActor)
            self._playerStateService:AddRebirthScore(sourceActor, GameConfig.REBIRTH.PlayerKillScoreReward)
        end
        self._playerStateService:PushState(sourceActor)
    end

    self:_fireDeathFeedback(targetActor, sourceActor)
    if self._respawnService then
        self._respawnService:HandleActorDeath(targetActor, sourceActor)
    end
end

function HealthService:ApplyWeaponDamage(targetActor, damage, sourceActor)
    if not targetActor then
        return false, false, nil
    end

    local state = self._playerStateService:GetState(targetActor)
    if not (state and state.Alive and state.IsInArena) then
        return false, false, state and state.CurrentHealth or nil
    end

    local damageMultiplier = 1
    if sourceActor and self._buffService then
        damageMultiplier = self._buffService:GetDamageMultiplier(sourceActor)
    end
    local appliedDamage = math.max(0, math.floor((tonumber(damage) or 0) * damageMultiplier))
    if appliedDamage <= 0 then
        return false, false, state.CurrentHealth
    end

    state.CurrentHealth = math.max(0, state.CurrentHealth - appliedDamage)
    local remainingHealthAfterDamage = state.CurrentHealth
    local didKill = state.CurrentHealth <= 0
    if didKill then
        state.Alive = false
    end
    self._playerStateService:SyncHumanoidHealth(targetActor)
    self._playerStateService:PushState(targetActor)

    if didKill then
        self:_handleActorKill(targetActor, sourceActor)
    end

    return true, didKill, remainingHealthAfterDamage
end

function HealthService:KillActor(targetActor, sourceActor)
    if not targetActor then
        return false, false, nil
    end

    local state = self._playerStateService:GetState(targetActor)
    if not (state and state.Alive) then
        return false, false, state and state.CurrentHealth or nil
    end

    state.CurrentHealth = 0
    state.Alive = false
    self._playerStateService:SyncHumanoidHealth(targetActor)
    self._playerStateService:PushState(targetActor)
    self:_handleActorKill(targetActor, sourceActor)
    return true, true, 0
end

function HealthService:ResetPlayerHealth(actor)
    local state = self._playerStateService:GetState(actor)
    state.MaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    state.CurrentHealth = state.MaxHealth
    self._playerStateService:SyncHumanoidHealth(actor)
    self._playerStateService:PushState(actor)
end

function HealthService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._remoteEventService = dependencies.RemoteEventService
    self._respawnService = dependencies.RespawnService
    self._buffService = dependencies.BuffService
    self._deathFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("DeathFeedback") or nil
end

return HealthService
