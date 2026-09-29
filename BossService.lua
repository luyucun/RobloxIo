--[[
脚本名字: BossService
脚本文件: BossService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/BossService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local BossService = {}

BossService._monsterService = nil
BossService._arenaService = nil
BossService._bossSkillService = nil
BossService._battlePart = nil
BossService._bossFeedbackEvent = nil
BossService._activeBosses = {}

local function getPlanarDistance(positionA, positionB)
    local deltaX = positionA.X - positionB.X
    local deltaZ = positionA.Z - positionB.Z
    return math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))
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

function BossService:_sampleRawPointInsideBattle()
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

function BossService:_isPositionInsideSafeZone(position)
    return self._arenaService
        and self._arenaService.IsPositionInsideSafeZone
        and self._arenaService:IsPositionInsideSafeZone(position) == true
end

function BossService:_samplePointInsideBattle()
    local attempts = math.max(1, math.floor(tonumber(GameConfig.ARENA.SpawnCandidateAttempts) or 40))
    for _ = 1, attempts do
        local candidate = self:_sampleRawPointInsideBattle()
        if candidate and not self:_isPositionInsideSafeZone(candidate) then
            return candidate
        end
    end
    return nil
end

function BossService:_getMinimumPlanarDistance(position, positions)
    local minimumDistance = math.huge
    for _, otherPosition in ipairs(positions) do
        local distance = getPlanarDistance(position, otherPosition)
        if distance < minimumDistance then
            minimumDistance = distance
        end
    end
    return minimumDistance
end

function BossService:_getCurrentBossSpawnPositions()
    local positions = {}
    for index = #self._activeBosses, 1, -1 do
        local bossState = self._activeBosses[index]
        if bossState and bossState.Alive and bossState.RuntimeInstance and bossState.RuntimeInstance.Parent then
            local runtimeInstance = bossState.RuntimeInstance
            if runtimeInstance:IsA("Model") then
                table.insert(positions, runtimeInstance:GetPivot().Position)
            elseif runtimeInstance:IsA("BasePart") then
                table.insert(positions, runtimeInstance.Position)
            end
        elseif not (bossState and bossState.Alive) then
            table.remove(self._activeBosses, index)
        end
    end
    return positions
end

function BossService:_getEventBossSpawnMinSpacing(bossCount)
    local configuredSpacing = math.max(0, tonumber(GameConfig.BOSS.EventSpawnMinSpacing) or 70)
    if self._battlePart and bossCount > 1 then
        local size = self._battlePart.Size
        local spacingRatio = math.clamp(tonumber(GameConfig.BOSS.EventSpawnAreaSpacingRatio) or 0.55, 0.1, 1)
        local areaSpacing = math.min(size.X, size.Z) * spacingRatio / math.sqrt(bossCount)
        configuredSpacing = math.min(configuredSpacing, areaSpacing)
    end
    return configuredSpacing
end

function BossService:_sampleEventBossSpawnPositions(bossCount)
    local positions = {}
    if bossCount <= 0 then
        return positions
    end

    local occupiedPositions = self:_getCurrentBossSpawnPositions()
    local minSpacing = self:_getEventBossSpawnMinSpacing(bossCount + #occupiedPositions)
    local spacingFloor = math.max(0, tonumber(GameConfig.BOSS.EventSpawnMinSpacingFloor) or 24)
    local spacingDecay = math.clamp(tonumber(GameConfig.BOSS.EventSpawnMinSpacingDecay) or 0.82, 0.2, 0.98)
    local baseAttempts = math.max(1, math.floor(tonumber(GameConfig.ARENA.SpawnCandidateAttempts) or 40))
    local candidateMultiplier = math.max(1, math.floor(tonumber(GameConfig.BOSS.EventSpawnCandidateMultiplier) or 12))
    local attemptsPerBoss = math.max(baseAttempts, bossCount * candidateMultiplier)

    for _ = 1, bossCount do
        local requiredSpacing = minSpacing
        local selectedPosition = nil
        local bestPosition = nil
        local bestDistance = -math.huge

        repeat
            for _ = 1, attemptsPerBoss do
                local candidate = self:_samplePointInsideBattle()
                if candidate then
                    local comparisonPositions = {}
                    for _, position in ipairs(occupiedPositions) do
                        table.insert(comparisonPositions, position)
                    end
                    for _, position in ipairs(positions) do
                        table.insert(comparisonPositions, position)
                    end

                    local distance = #comparisonPositions > 0
                        and self:_getMinimumPlanarDistance(candidate, comparisonPositions)
                        or math.huge
                    if distance > bestDistance then
                        bestDistance = distance
                        bestPosition = candidate
                    end
                    if distance >= requiredSpacing then
                        selectedPosition = candidate
                        break
                    end
                end
            end

            if selectedPosition or requiredSpacing <= spacingFloor then
                break
            end
            requiredSpacing = math.max(spacingFloor, requiredSpacing * spacingDecay)
        until false

        selectedPosition = selectedPosition or bestPosition or self:_samplePointInsideBattle()
        if selectedPosition then
            table.insert(positions, selectedPosition)
        end
    end

    return positions
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

function BossService:_spawnBossAt(monsterDefinitionId, spawnPosition)
    if not (GameConfig.BOSS.Enabled and self._monsterService) then
        return nil
    end

    local definitionId = tostring(monsterDefinitionId or GameConfig.BOSS.MonsterDefinitionId or "")
    if definitionId == "" then
        definitionId = tostring(GameConfig.BOSS.MonsterDefinitionId or "")
    end

    local bossDefinition = MonsterCatalog.GetDefinition(definitionId)
    if not bossDefinition or (MonsterCatalog.IsBossDefinition and not MonsterCatalog.IsBossDefinition(bossDefinition)) then
        warn(string.format("[BossService] Boss 定义无效或不是首领：%s", tostring(definitionId)))
        return nil
    end

    if not spawnPosition then
        warn("[BossService] Boss spawn skipped: no non-Safe Battle spawn point found.")
        return nil
    end

    local bossState = self._monsterService:SpawnMonster(spawnPosition, {
        IsBoss = true,
        RuntimeName = GameConfig.BOSS.RuntimeName,
        MonsterDefinitionId = definitionId,
        TemplateName = bossDefinition.TemplateName or GameConfig.BOSS.TemplateName or GameConfig.MONSTER.BossTemplateName,
        Level = GameConfig.BOSS.Level,
        MaxHealth = bossDefinition.MaxHealth or GameConfig.BOSS.MaxHealth,
        AttackDamage = bossDefinition.AttackDamage or GameConfig.BOSS.AttackDamage,
        MoveSpeed = bossDefinition.MoveSpeed or GameConfig.BOSS.MoveSpeed,
        AttackRange = bossDefinition.AttackRange or bossDefinition.AggroRadius or GameConfig.BOSS.AttackRange or GameConfig.BOSS.AggroRadius,
        AggroRadius = bossDefinition.AggroRadius or GameConfig.BOSS.AggroRadius,
        DisengageDistance = bossDefinition.DisengageDistance
            or bossDefinition.AttackRange
            or bossDefinition.AggroRadius
            or GameConfig.BOSS.DisengageDistance
            or GameConfig.BOSS.AttackRange
            or GameConfig.BOSS.AggroRadius,
        ContactRadius = GameConfig.BOSS.ContactRadius,
        CollisionRadius = GameConfig.BOSS.CollisionRadius,
        ExperienceDropCount = bossDefinition.ExperienceDropCount or GameConfig.BOSS.ExperienceDropCount,
        ExperiencePerOrb = bossDefinition.ExperiencePerOrb or GameConfig.BOSS.ExperiencePerOrb,
        KillScoreReward = bossDefinition.KillScoreReward or GameConfig.BOSS.KillScoreReward,
        BuffDropCount = GameConfig.BOSS.BuffDropCount,
    })

    if bossState then
        table.insert(self._activeBosses, bossState)
        if self._bossSkillService and self._bossSkillService.RegisterBoss then
            self._bossSkillService:RegisterBoss(bossState)
        end
        self:_fireBossFeedback("BossSpawned", bossState)
    end
    return bossState
end

function BossService:SpawnBoss(monsterDefinitionId)
    return self:_spawnBossAt(monsterDefinitionId, self:_samplePointInsideBattle())
end

function BossService:SpawnBossesForEvent(eventConfig)
    if type(eventConfig) ~= "table" then
        return 0
    end

    local bossDefinitionId = eventConfig.BossDefinitionId
    local bossCount = math.max(0, math.floor(tonumber(eventConfig.BossCount) or 0))
    if bossCount <= 0 or bossDefinitionId == nil then
        return 0
    end

    local spawnedCount = 0
    local spawnPositions = self:_sampleEventBossSpawnPositions(bossCount)
    for index = 1, bossCount do
        local spawnPosition = spawnPositions[index] or self:_samplePointInsideBattle()
        if self:_spawnBossAt(bossDefinitionId, spawnPosition) then
            spawnedCount += 1
        end
    end
    return spawnedCount
end

function BossService:Init(dependencies)
    self._monsterService = dependencies.MonsterService
    self._arenaService = dependencies.ArenaService
    self._bossSkillService = dependencies.BossSkillService
    self._battlePart = resolveBattlePart()
    self._bossFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("BossFeedback") or nil
    self._activeBosses = {}

    if not self._battlePart then
        warn("[BossService] 找不到 workspace.Battle，事件 Boss 刷新逻辑未启用。")
        return
    end
end

return BossService
