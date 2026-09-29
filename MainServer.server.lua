--[[
脚本名字: MainServer
脚本文件: MainServer.server.lua
脚本类型: Script
Studio放置路径: ServerScriptService/MainServer
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
        "[MainServer] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local function requireServerModule(moduleName)
    local servicesFolder = script.Parent:FindFirstChild("Services")
    if servicesFolder then
        local moduleInServices = servicesFolder:FindFirstChild(moduleName)
        if moduleInServices and moduleInServices:IsA("ModuleScript") then
            return require(moduleInServices)
        end
    end

    local moduleInRoot = script.Parent:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return require(moduleInRoot)
    end

    error(string.format(
        "[MainServer] 缺少服务模块 %s（应放在 ServerScriptService/Services 或 ServerScriptService 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteEventService = requireServerModule("RemoteEventService")
local PlayerStateService = requireServerModule("PlayerStateService")
local ArenaService = requireServerModule("ArenaService")
local WeaponService = requireServerModule("WeaponService")
local AttributeUpgradeService = requireServerModule("AttributeUpgradeService")
local AttributeCapUpgradeService = requireServerModule("AttributeCapUpgradeService")
local RespawnService = requireServerModule("RespawnService")
local HealthService = requireServerModule("HealthService")
local CombatService = requireServerModule("CombatService")
local ExperienceOrbService = requireServerModule("ExperienceOrbService")
local LocalMonsterRewardService = requireServerModule("LocalMonsterRewardService")
local MonsterService = requireServerModule("MonsterService")
local BossService = requireServerModule("BossService")
local BossSkillService = requireServerModule("BossSkillService")
local FlashService = requireServerModule("FlashService")
local BuffService = requireServerModule("BuffService")
local LeaderboardService = requireServerModule("LeaderboardService")
local FriendsRankingService = requireServerModule("FriendsRankingService")
local BotService = requireServerModule("BotService")
local NukeService = requireServerModule("NukeService")
local RevengeService = requireServerModule("RevengeService")
local RebirthService = requireServerModule("RebirthService")
local PotionService = requireServerModule("PotionService")
local SpecialEventService = requireServerModule("SpecialEventService")
local GMCommandService = requireServerModule("GMCommandService")
local GroupRewardService = requireServerModule("GroupRewardService")
local WeaponUnlockRewardService = requireServerModule("WeaponUnlockRewardService")
local FavoritePlacePromptService = requireServerModule("FavoritePlacePromptService")
local ActivityRsvpPromptService = requireServerModule("ActivityRsvpPromptService")
local BadgeAwardService = requireServerModule("BadgeAwardService")
local ArenaProgressService = requireServerModule("ArenaProgressService")
local WheelService = requireServerModule("WheelService")
local SkinService = requireServerModule("SkinService")
local SubscriptionService = requireServerModule("SubscriptionService")
local ShopService = requireServerModule("ShopService")
local ChestService = requireServerModule("ChestService")
local CodeService = requireServerModule("CodeService")
local OnlineRewardService = requireServerModule("OnlineRewardService")
local SevenDayLoginRewardService = requireServerModule("SevenDayLoginRewardService")
local TaskService = requireServerModule("TaskService")
local GameAnalyticsService = requireServerModule("GameAnalyticsService")

Players.RespawnTime = GameConfig.RESPAWN.DeathRecoverySeconds
Players.CharacterAutoLoads = false

local studioBotEnsurerStarted = false
local memoryTrackingSetupAttempted = false

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
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

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function getMemoryMbForTag(tagName)
    if not memoryTrackingSetupAttempted then
        memoryTrackingSetupAttempted = true
        pcall(function()
            StatsService.MemoryTrackingEnabled = true
        end)
    end

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

local function countRuntimeFolder(folderName)
    local runtimeRoot = Workspace:FindFirstChild("Runtime")
    local folder = runtimeRoot and runtimeRoot:FindFirstChild(folderName)
    return folder and #folder:GetChildren() or 0, countDescendants(folder)
end

local function startServerDiagnostics()
    if not isPerformanceDebugEnabled() then
        return
    end

    task.spawn(function()
        while true do
            task.wait(getPerformanceLogInterval())
            if not isPerformanceDebugEnabled() then
                continue
            end

            local runtimeRoot = Workspace:FindFirstChild("Runtime")
            local weaponChildren, weaponDesc = countRuntimeFolder("Weapons")
            local debrisChildren, debrisDesc = countRuntimeFolder(GameConfig.WEAPON.BrokenDebrisFolderName or "WeaponDebris")
            local monsterChildren, monsterDesc = countRuntimeFolder(GameConfig.MONSTER.RuntimeFolderName or "Monsters")
            local buffChildren, buffDesc = countRuntimeFolder((GameConfig.BUFF and GameConfig.BUFF.RuntimeFolderName) or "Buffs")
            local eventPayload = SpecialEventService.BuildPayload and SpecialEventService:BuildPayload() or nil
            local activeEvent = eventPayload and eventPayload.activeEvent or nil
            local futureEvents = eventPayload and eventPayload.futureEvents or {}

            print(string.format(
                "[Diag][Server] memTotalMb=%.2f luaHeapMb=%.2f instancesMb=%.2f animationMb=%.2f physicsPartsMb=%.2f players=%d workspaceDesc=%d runtimeDesc=%d weapons=%d/%d debris=%d/%d monsters=%d/%d buffs=%d/%d activeNormalMonsters=%d activeBosses=%d botActors=%d playerStates=%d arenaActors=%d localAuthUsers=%d localAuthTotal=%d specialActive=%s futureEvents=%d",
                getTotalMemoryMb(),
                getMemoryMbForTag("LuaHeap"),
                getMemoryMbForTag("Instances"),
                getMemoryMbForTag("Animation"),
                getMemoryMbForTag("PhysicsParts"),
                #Players:GetPlayers(),
                countDescendants(Workspace),
                countDescendants(runtimeRoot),
                weaponChildren,
                weaponDesc,
                debrisChildren,
                debrisDesc,
                monsterChildren,
                monsterDesc,
                buffChildren,
                buffDesc,
                MonsterService.GetActiveMonsterCount and MonsterService:GetActiveMonsterCount() or -1,
                BossService._activeBosses and #BossService._activeBosses or -1,
                BotService._botsById and countMapEntries(BotService._botsById) or -1,
                PlayerStateService.GetAllPlayerStates and #PlayerStateService:GetAllPlayerStates() or -1,
                PlayerStateService.GetArenaActors and #PlayerStateService:GetArenaActors() or -1,
                LocalMonsterRewardService._spawnAuthorizationsByUserId and countMapEntries(LocalMonsterRewardService._spawnAuthorizationsByUserId) or -1,
                (function()
                    local total = 0
                    for _, authorizations in pairs(LocalMonsterRewardService._spawnAuthorizationsByUserId or {}) do
                        total += countMapEntries(authorizations)
                    end
                    return total
                end)(),
                tostring(activeEvent and activeEvent.name or "nil"),
                type(futureEvents) == "table" and #futureEvents or 0
            ))
        end
    end)
end

local function ensureStudioBots()
    if not RunService:IsStudio() then
        return
    end

    if studioBotEnsurerStarted then
        return
    end
    studioBotEnsurerStarted = true

    task.spawn(function()
        while RunService:IsStudio() do
            local targetCount = math.clamp(
                math.floor(tonumber(GameConfig.BOTS.DefaultStudioCount) or 0),
                0,
                GameConfig.BOTS.MaxActiveCount
            )
            local currentCount = BotService:GetActiveBotCount()
            if currentCount < targetCount then
                local missingCount = targetCount - currentCount
                local spawned = BotService:SpawnBots(missingCount)
                if spawned > 0 then
                    print(string.format(
                        "[MainServer] Studio default bots spawned: %d (current=%d target=%d)",
                        spawned,
                        currentCount + spawned,
                        targetCount
                    ))
                end
            end
            task.wait(1)
        end
    end)
end

RemoteEventService:Init()
BadgeAwardService:Init()
GameAnalyticsService:Init({
    PlayerStateService = PlayerStateService,
})
PlayerStateService:Init({
    RemoteEventService = RemoteEventService,
    GameAnalyticsService = GameAnalyticsService,
})
RebirthService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    BadgeAwardService = BadgeAwardService,
    ShopService = ShopService,
    OnlineRewardService = OnlineRewardService,
    SevenDayLoginRewardService = SevenDayLoginRewardService,
    AttributeCapUpgradeService = AttributeCapUpgradeService,
    GameAnalyticsService = GameAnalyticsService,
    TaskService = TaskService,
})
PotionService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
TaskService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    GameAnalyticsService = GameAnalyticsService,
})
WheelService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    PotionService = PotionService,
    RebirthService = RebirthService,
    HealthService = HealthService,
    GameAnalyticsService = GameAnalyticsService,
    TaskService = TaskService,
})
SkinService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    GameAnalyticsService = GameAnalyticsService,
})
SubscriptionService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    BadgeAwardService = BadgeAwardService,
    GameAnalyticsService = GameAnalyticsService,
})
ShopService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    GameAnalyticsService = GameAnalyticsService,
})
ChestService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    SkinService = SkinService,
    GameAnalyticsService = GameAnalyticsService,
})
CodeService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
})
OnlineRewardService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    HealthService = HealthService,
})
SevenDayLoginRewardService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    SkinService = SkinService,
    HealthService = HealthService,
})
GroupRewardService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    PotionService = PotionService,
    RebirthService = RebirthService,
})
WeaponUnlockRewardService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    GameAnalyticsService = GameAnalyticsService,
})
FavoritePlacePromptService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
ActivityRsvpPromptService:Init({
    RemoteEventService = RemoteEventService,
    GameAnalyticsService = GameAnalyticsService,
})
BotService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
})
ArenaService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    RemoteEventService = RemoteEventService,
    BotService = BotService,
    RebirthService = RebirthService,
    HealthService = HealthService,
    GameAnalyticsService = GameAnalyticsService,
})
WeaponService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
    BotService = BotService,
    GameAnalyticsService = GameAnalyticsService,
})
RespawnService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    ArenaService = ArenaService,
    BotService = BotService,
    RevengeService = RevengeService,
    RemoteEventService = RemoteEventService,
    GameAnalyticsService = GameAnalyticsService,
})
BuffService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
})
HealthService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
    RespawnService = RespawnService,
    ArenaService = ArenaService,
    BuffService = BuffService,
    GameAnalyticsService = GameAnalyticsService,
})
CombatService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    HealthService = HealthService,
    ArenaService = ArenaService,
    RemoteEventService = RemoteEventService,
})
ExperienceOrbService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    RemoteEventService = RemoteEventService,
    BotService = BotService,
    ArenaService = ArenaService,
})
LocalMonsterRewardService:Init({
    PlayerStateService = PlayerStateService,
    ExperienceOrbService = ExperienceOrbService,
    HealthService = HealthService,
    RemoteEventService = RemoteEventService,
    RebirthService = RebirthService,
    GameAnalyticsService = GameAnalyticsService,
})
MonsterService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    HealthService = HealthService,
    ExperienceOrbService = ExperienceOrbService,
    BuffService = BuffService,
    PotionService = PotionService,
    RemoteEventService = RemoteEventService,
})
BossSkillService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
})
FlashService:Init({
    PlayerStateService = PlayerStateService,
    ArenaService = ArenaService,
    RemoteEventService = RemoteEventService,
})
BossService:Init({
    MonsterService = MonsterService,
    BossSkillService = BossSkillService,
    RemoteEventService = RemoteEventService,
    ArenaService = ArenaService,
})
LeaderboardService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
})
FriendsRankingService:Init({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    LeaderboardService = LeaderboardService,
    RemoteEventService = RemoteEventService,
})
ArenaProgressService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
})
NukeService:Init({
    PlayerStateService = PlayerStateService,
    HealthService = HealthService,
    ArenaService = ArenaService,
    RemoteEventService = RemoteEventService,
    MonsterService = MonsterService,
    ExperienceOrbService = ExperienceOrbService,
    LocalMonsterRewardService = LocalMonsterRewardService,
})
RevengeService:Init({
    PlayerStateService = PlayerStateService,
    HealthService = HealthService,
    RespawnService = RespawnService,
    RemoteEventService = RemoteEventService,
})
SpecialEventService:Init({
    RemoteEventService = RemoteEventService,
    BossService = BossService,
    PlayerStateService = PlayerStateService,
    HealthService = HealthService,
})
GMCommandService:Init({
    SpecialEventService = SpecialEventService,
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    BotService = BotService,
    HealthService = HealthService,
    RevengeService = RevengeService,
    GameAnalyticsService = GameAnalyticsService,
    TaskService = TaskService,
    ChestService = ChestService,
    SkinService = SkinService,
})
PlayerStateService:BindSystems({
    WeaponService = WeaponService,
    WeaponUnlockRewardService = WeaponUnlockRewardService,
    LeaderboardService = LeaderboardService,
    RebirthService = RebirthService,
    ArenaProgressService = ArenaProgressService,
    HealthService = HealthService,
    SubscriptionService = SubscriptionService,
    SkinService = SkinService,
    GameAnalyticsService = GameAnalyticsService,
    TaskService = TaskService,
    SpecialEventService = SpecialEventService,
})
AttributeUpgradeService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    HealthService = HealthService,
})
AttributeCapUpgradeService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
RebirthService:BindSystems({
    HealthService = HealthService,
    RespawnService = RespawnService,
    NukeService = NukeService,
    RevengeService = RevengeService,
    PotionService = PotionService,
    WheelService = WheelService,
    SkinService = SkinService,
    ShopService = ShopService,
    BadgeAwardService = BadgeAwardService,
    OnlineRewardService = OnlineRewardService,
    SevenDayLoginRewardService = SevenDayLoginRewardService,
    AttributeCapUpgradeService = AttributeCapUpgradeService,
    GameAnalyticsService = GameAnalyticsService,
})
AttributeCapUpgradeService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
PotionService:BindSystems({
    RebirthService = RebirthService,
})
WheelService:BindSystems({
    PlayerStateService = PlayerStateService,
    PotionService = PotionService,
    RebirthService = RebirthService,
    SkinService = SkinService,
    HealthService = HealthService,
    ShopService = ShopService,
    GameAnalyticsService = GameAnalyticsService,
    TaskService = TaskService,
})
SkinService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    ShopService = ShopService,
    GameAnalyticsService = GameAnalyticsService,
})
SubscriptionService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    BadgeAwardService = BadgeAwardService,
    GameAnalyticsService = GameAnalyticsService,
})
ShopService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    GameAnalyticsService = GameAnalyticsService,
})
ChestService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    SkinService = SkinService,
    GameAnalyticsService = GameAnalyticsService,
})
CodeService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
})
OnlineRewardService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    HealthService = HealthService,
})
SevenDayLoginRewardService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    SkinService = SkinService,
    HealthService = HealthService,
})
BotService:BindSystems({
    ArenaService = ArenaService,
    WeaponService = WeaponService,
    RespawnService = RespawnService,
    ExperienceOrbService = ExperienceOrbService,
})
RevengeService:BindSystems({
    PlayerStateService = PlayerStateService,
    RespawnService = RespawnService,
    HealthService = HealthService,
})
MonsterService:BindSystems({
    BuffService = BuffService,
    PotionService = PotionService,
})
GameAnalyticsService:BindSystems({
    PlayerStateService = PlayerStateService,
})
TaskService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    PotionService = PotionService,
    GameAnalyticsService = GameAnalyticsService,
})

local function onPlayerAdded(player)
    if #Players:GetPlayers() > GameConfig.SERVER.MaxPlayers then
        player:Kick(string.format("This server allows a maximum of %d players.", GameConfig.SERVER.MaxPlayers))
        return
    end

    GameAnalyticsService:OnPlayerAdded(player)
    PlayerStateService:OnPlayerAdded(player)
    RebirthService:OnPlayerAdded(player)
    TaskService:OnPlayerAdded(player)
    WheelService:OnPlayerAdded(player)
    SkinService:OnPlayerAdded(player)
    SubscriptionService:OnPlayerAdded(player)
    ShopService:OnPlayerAdded(player)
    SevenDayLoginRewardService:OnPlayerAdded(player)
    OnlineRewardService:OnPlayerAdded(player)
    LeaderboardService:OnPlayerAdded(player)
    SpecialEventService:OnPlayerAdded(player)
    ChestService:OnPlayerAdded(player)
    ArenaProgressService:OnPlayerAdded(player)
    FavoritePlacePromptService:OnPlayerAdded(player)
    ActivityRsvpPromptService:OnPlayerAdded(player)

    local function handleCharacterAdded()
        local shouldReviveInArena = RespawnService:ConsumeArenaReviveRequest(player)
        PlayerStateService:OnCharacterAdded(player)
        task.defer(function()
            if shouldReviveInArena then
                RespawnService:CompleteArenaRevive(player)
            else
                ArenaService:TeleportPlayerToSpawnLocation(player)
                if not RebirthService.IsPlayerLoaded or RebirthService:IsPlayerLoaded(player) then
                    PlayerStateService:PushState(player)
                end
            end
            ensureStudioBots()
        end)
    end

    player.CharacterAdded:Connect(handleCharacterAdded)

    if player.Character then
        handleCharacterAdded()
    else
        player:LoadCharacter()
    end
end

local function onPlayerRemoving(player)
    GameAnalyticsService:OnPlayerRemoving(player)
    WeaponService:ClearPlayerWeapons(player)
    if LocalMonsterRewardService.OnPlayerRemoving then
        LocalMonsterRewardService:OnPlayerRemoving(player)
    end
    if RespawnService.OnPlayerRemoving then
        RespawnService:OnPlayerRemoving(player)
    end
    if HealthService.OnPlayerRemoving then
        HealthService:OnPlayerRemoving(player)
    end
    if RevengeService.OnPlayerRemoving then
        RevengeService:OnPlayerRemoving(player)
    end
    WeaponUnlockRewardService:OnPlayerRemoving(player)
    GroupRewardService:OnPlayerRemoving(player)
    WheelService:OnPlayerRemoving(player)
    TaskService:OnPlayerRemoving(player)
    SkinService:OnPlayerRemoving(player)
    SubscriptionService:OnPlayerRemoving(player)
    ShopService:OnPlayerRemoving(player)
    ChestService:OnPlayerRemoving(player)
    SevenDayLoginRewardService:OnPlayerRemoving(player)
    OnlineRewardService:OnPlayerRemoving(player)
    FavoritePlacePromptService:OnPlayerRemoving(player)
    ActivityRsvpPromptService:OnPlayerRemoving(player)
    BadgeAwardService:OnPlayerRemoving(player)
    RebirthService:OnPlayerRemoving(player)
    LeaderboardService:OnPlayerRemoving(player)
    if FriendsRankingService.OnPlayerRemoving then
        FriendsRankingService:OnPlayerRemoving(player)
    end
    PlayerStateService:OnPlayerRemoving(player)
    ArenaProgressService:OnPlayerRemoving(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, player)
end

if RunService:IsStudio() then
    task.delay(3, ensureStudioBots)
end

startServerDiagnostics()

game:BindToClose(function()
    if RebirthService.SaveAllPlayersForShutdown then
        RebirthService:SaveAllPlayersForShutdown()
    end
    LeaderboardService:SaveAllPlayers()
end)
