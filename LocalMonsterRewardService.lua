--[[
脚本名字: LocalMonsterRewardService
脚本文件: LocalMonsterRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/LocalMonsterRewardService
说明: 处理客户端私有普通小怪的击杀奖励和接触伤害；服务端仍权威计算玩家状态。
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
        "[LocalMonsterRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local LocalMonsterRewardService = {}

LocalMonsterRewardService._playerStateService = nil
LocalMonsterRewardService._experienceOrbService = nil
LocalMonsterRewardService._healthService = nil
LocalMonsterRewardService._localMonsterKilledEvent = nil
LocalMonsterRewardService._localMonsterHitPlayerEvent = nil
LocalMonsterRewardService._killReportWindows = {}
LocalMonsterRewardService._hitReportWindows = {}
LocalMonsterRewardService._recentKillIdsByUserId = {}

local function getUserId(player)
    return player and player.UserId or 0
end

local function isArenaPlayer(playerState)
    return playerState and playerState.Alive == true and playerState.IsInArena == true
end

local function pruneRecentKills(recentKills, now)
    local windowSeconds = math.max(1, tonumber(GameConfig.MONSTER.LocalDuplicateKillWindowSeconds) or 10)
    for monsterId, expiry in pairs(recentKills) do
        if expiry <= now then
            recentKills[monsterId] = nil
        end
    end
    return windowSeconds
end

function LocalMonsterRewardService:_consumeRateLimit(bucketByUserId, player, limitPerSecond)
    local userId = getUserId(player)
    if userId <= 0 then
        return false
    end

    local now = os.clock()
    local bucket = bucketByUserId[userId]
    if not bucket or now - bucket.WindowStart >= 1 then
        bucket = {
            WindowStart = now,
            Count = 0,
        }
        bucketByUserId[userId] = bucket
    end

    local limit = math.max(1, math.floor(tonumber(limitPerSecond) or 1))
    if bucket.Count >= limit then
        return false
    end

    bucket.Count += 1
    return true
end

function LocalMonsterRewardService:_normalizeDeathPosition(player, deathPosition)
    if typeof(deathPosition) == "Vector3" then
        return deathPosition
    end

    local rootPart = ActorUtils.GetRootPart(player)
    return rootPart and rootPart.Position or Vector3.zero
end

function LocalMonsterRewardService:_handleLocalMonsterKilled(player, payload)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent) then
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not isArenaPlayer(state) then
        return
    end

    if not self:_consumeRateLimit(self._killReportWindows, player, GameConfig.MONSTER.LocalKillReportsPerSecond) then
        return
    end

    local monsterId = tostring(payload and payload.monsterId or "")
    if monsterId == "" then
        return
    end

    local now = os.clock()
    local userId = getUserId(player)
    local recentKills = self._recentKillIdsByUserId[userId]
    if not recentKills then
        recentKills = {}
        self._recentKillIdsByUserId[userId] = recentKills
    end

    local duplicateWindowSeconds = pruneRecentKills(recentKills, now)
    if recentKills[monsterId] then
        return
    end

    local monsterDefinition = MonsterCatalog.GetDefinition(payload and payload.monsterDefinitionId)
        or MonsterCatalog.GetDefinition(GameConfig.MONSTER.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(monsterDefinition) then
        return
    end
    recentKills[monsterId] = now + duplicateWindowSeconds

    if self._playerStateService then
        self._playerStateService:AddRebirthScore(
            player,
            monsterDefinition.KillScoreReward or GameConfig.MONSTER.KillScoreReward
        )
    end

    local experienceDropCount = monsterDefinition.ExperienceDropCount or GameConfig.MONSTER.ExperienceDropCount
    local experiencePerOrb = monsterDefinition.ExperiencePerOrb or GameConfig.MONSTER.ExperiencePerOrb
    local totalExperience = experienceDropCount * experiencePerOrb
    if self._experienceOrbService then
        self._experienceOrbService:DropExperience(
            self:_normalizeDeathPosition(player, payload and payload.deathPosition),
            totalExperience,
            experienceDropCount,
            player,
            {
                applyExperienceMultiplier = true,
            }
        )
    elseif self._playerStateService then
        self._playerStateService:AddExperienceWithMultiplier(player, totalExperience)
    end
end

function LocalMonsterRewardService:_handleLocalMonsterHitPlayer(player, payload)
    if not (GameConfig.MONSTER.ClientOwnedNormalMonsters and player and player.Parent) then
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not isArenaPlayer(state) then
        return
    end

    if not self:_consumeRateLimit(self._hitReportWindows, player, GameConfig.MONSTER.LocalHitReportsPerSecond) then
        return
    end

    local monsterDefinition = MonsterCatalog.GetDefinition(payload and payload.monsterDefinitionId)
        or MonsterCatalog.GetDefinition(GameConfig.MONSTER.MonsterDefinitionId)
    if not MonsterCatalog.IsNormalMonsterDefinition(monsterDefinition) then
        return
    end

    local damage = monsterDefinition.AttackDamage or GameConfig.MONSTER.AttackDamage
    if self._healthService then
        self._healthService:ApplyWeaponDamage(player, damage, nil)
    end
end

function LocalMonsterRewardService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._experienceOrbService = dependencies.ExperienceOrbService
    self._healthService = dependencies.HealthService
    self._localMonsterKilledEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LocalMonsterKilled") or nil
    self._localMonsterHitPlayerEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LocalMonsterHitPlayer") or nil
    self._killReportWindows = {}
    self._hitReportWindows = {}
    self._recentKillIdsByUserId = {}

    if self._localMonsterKilledEvent then
        self._localMonsterKilledEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleLocalMonsterKilled(player, payload)
        end)
    end

    if self._localMonsterHitPlayerEvent then
        self._localMonsterHitPlayerEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleLocalMonsterHitPlayer(player, payload)
        end)
    end
end

return LocalMonsterRewardService
