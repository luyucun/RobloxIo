--[[
脚本名字: BossService
脚本文件: BossService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/BossService
]]

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
        "[BossService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local BossService = {}

BossService._monsterService = nil
BossService._battlePart = nil
BossService._bossFeedbackEvent = nil
BossService._activeBosses = {}
BossService._nextSpawnClock = 0
BossService._heartbeatConnection = nil

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

function BossService:_samplePointInsideBattle()
    if not self._battlePart then
        return nil
    end

    local size = self._battlePart.Size
    local padding = GameConfig.MONSTER.EdgePadding
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)
    local localX = (math.random() * 2 - 1) * usableHalfX
    local localZ = (math.random() * 2 - 1) * usableHalfZ
    local localY = (size.Y * 0.5) + GameConfig.MONSTER.SpawnHeightOffset
    return (self._battlePart.CFrame * CFrame.new(localX, localY, localZ)).Position
end

function BossService:_getActiveBossCount()
    local count = 0
    for index = #self._activeBosses, 1, -1 do
        local bossState = self._activeBosses[index]
        if bossState and bossState.Alive then
            count += 1
        else
            table.remove(self._activeBosses, index)
        end
    end
    return count
end

function BossService:_fireBossFeedback(eventType, bossState)
    if not self._bossFeedbackEvent then
        return
    end

    self._bossFeedbackEvent:FireAllClients({
        eventType = eventType,
        bossId = bossState and bossState.Id or nil,
        level = bossState and bossState.Level or GameConfig.BOSS.Level,
        maxHealth = bossState and bossState.MaxHealth or GameConfig.BOSS.MaxHealth,
        timestamp = os.clock(),
    })
end

function BossService:SpawnBoss()
    if not (GameConfig.BOSS.Enabled and self._monsterService) then
        return nil
    end
    if self:_getActiveBossCount() >= GameConfig.BOSS.MaxActiveCount then
        return nil
    end

    local bossState = self._monsterService:SpawnMonster(self:_samplePointInsideBattle(), {
        IsBoss = true,
        RuntimeName = GameConfig.BOSS.RuntimeName,
        MonsterDefinitionId = GameConfig.BOSS.MonsterDefinitionId,
        TemplateName = GameConfig.BOSS.TemplateName or GameConfig.MONSTER.BossTemplateName,
        Level = GameConfig.BOSS.Level,
        MaxHealth = GameConfig.BOSS.MaxHealth,
        AttackDamage = GameConfig.BOSS.AttackDamage,
        MoveSpeed = GameConfig.BOSS.MoveSpeed,
        AttackRange = GameConfig.BOSS.AttackRange or GameConfig.BOSS.AggroRadius,
        AggroRadius = GameConfig.BOSS.AggroRadius,
        DisengageDistance = GameConfig.BOSS.DisengageDistance
            or GameConfig.BOSS.AttackRange
            or GameConfig.BOSS.AggroRadius,
        ContactRadius = GameConfig.BOSS.ContactRadius,
        CollisionRadius = GameConfig.BOSS.CollisionRadius,
        ExperienceDropCount = GameConfig.BOSS.ExperienceDropCount,
        ExperiencePerOrb = GameConfig.BOSS.ExperiencePerOrb,
        BuffDropCount = GameConfig.BOSS.BuffDropCount,
    })

    if bossState then
        table.insert(self._activeBosses, bossState)
        self:_fireBossFeedback("BossSpawned", bossState)
    end
    return bossState
end

function BossService:_step()
    if not GameConfig.BOSS.Enabled then
        return
    end
    if os.clock() < self._nextSpawnClock then
        return
    end

    self._nextSpawnClock = os.clock() + GameConfig.BOSS.SpawnIntervalSeconds
    self:SpawnBoss()
end

function BossService:Init(dependencies)
    self._monsterService = dependencies.MonsterService
    self._battlePart = resolveBattlePart()
    self._bossFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("BossFeedback") or nil
    self._activeBosses = {}
    self._nextSpawnClock = os.clock() + GameConfig.BOSS.InitialSpawnDelaySeconds

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    if not self._battlePart then
        warn("[BossService] 找不到 workspace.Battle，Boss 刷新逻辑未启用。")
        return
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

return BossService
