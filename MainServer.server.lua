--[[
脚本名字: MainServer
脚本文件: MainServer.server.lua
脚本类型: Script
Studio放置路径: ServerScriptService/MainServer
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
local RespawnService = requireServerModule("RespawnService")
local HealthService = requireServerModule("HealthService")
local CombatService = requireServerModule("CombatService")
local ExperienceOrbService = requireServerModule("ExperienceOrbService")
local LocalMonsterRewardService = requireServerModule("LocalMonsterRewardService")
local MonsterService = requireServerModule("MonsterService")
local BossService = requireServerModule("BossService")
local BuffService = requireServerModule("BuffService")
local LeaderboardService = requireServerModule("LeaderboardService")
local BotService = requireServerModule("BotService")
local NukeService = requireServerModule("NukeService")
local RebirthService = requireServerModule("RebirthService")
local PotionService = requireServerModule("PotionService")
local SpecialEventService = requireServerModule("SpecialEventService")
local GMCommandService = requireServerModule("GMCommandService")
local GroupRewardService = requireServerModule("GroupRewardService")
local WeaponUnlockRewardService = requireServerModule("WeaponUnlockRewardService")
local BadgeAwardService = requireServerModule("BadgeAwardService")
local ArenaProgressService = requireServerModule("ArenaProgressService")
local WheelService = requireServerModule("WheelService")
local SkinService = requireServerModule("SkinService")
local SubscriptionService = requireServerModule("SubscriptionService")

Players.RespawnTime = GameConfig.RESPAWN.DeathRecoverySeconds
Players.CharacterAutoLoads = false

local studioBotEnsurerStarted = false

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
PlayerStateService:Init({
    RemoteEventService = RemoteEventService,
})
RebirthService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
})
PotionService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
WheelService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    PotionService = PotionService,
    RebirthService = RebirthService,
    HealthService = HealthService,
})
SkinService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
SubscriptionService:Init({
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    BadgeAwardService = BadgeAwardService,
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
})
WeaponService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
    BotService = BotService,
})
RespawnService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    ArenaService = ArenaService,
    BotService = BotService,
    RemoteEventService = RemoteEventService,
})
BuffService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
})
HealthService:Init({
    PlayerStateService = PlayerStateService,
    RemoteEventService = RemoteEventService,
    RespawnService = RespawnService,
    BuffService = BuffService,
})
CombatService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    HealthService = HealthService,
    RemoteEventService = RemoteEventService,
})
ExperienceOrbService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    RemoteEventService = RemoteEventService,
    BotService = BotService,
})
LocalMonsterRewardService:Init({
    PlayerStateService = PlayerStateService,
    ExperienceOrbService = ExperienceOrbService,
    HealthService = HealthService,
    RemoteEventService = RemoteEventService,
    RebirthService = RebirthService,
})
MonsterService:Init({
    PlayerStateService = PlayerStateService,
    WeaponService = WeaponService,
    HealthService = HealthService,
    ExperienceOrbService = ExperienceOrbService,
    BuffService = BuffService,
    PotionService = PotionService,
})
BossService:Init({
    MonsterService = MonsterService,
    RemoteEventService = RemoteEventService,
})
LeaderboardService:Init({
    PlayerStateService = PlayerStateService,
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
SpecialEventService:Init({
    RemoteEventService = RemoteEventService,
    BossService = BossService,
})
GMCommandService:Init({
    SpecialEventService = SpecialEventService,
    RemoteEventService = RemoteEventService,
    PlayerStateService = PlayerStateService,
    BotService = BotService,
    HealthService = HealthService,
})
PlayerStateService:BindSystems({
    WeaponService = WeaponService,
    WeaponUnlockRewardService = WeaponUnlockRewardService,
    LeaderboardService = LeaderboardService,
    RebirthService = RebirthService,
    ArenaProgressService = ArenaProgressService,
    HealthService = HealthService,
    SubscriptionService = SubscriptionService,
})
RebirthService:BindSystems({
    HealthService = HealthService,
    RespawnService = RespawnService,
    NukeService = NukeService,
    PotionService = PotionService,
    WheelService = WheelService,
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
})
SkinService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
})
SubscriptionService:BindSystems({
    PlayerStateService = PlayerStateService,
    RebirthService = RebirthService,
    BadgeAwardService = BadgeAwardService,
})
BotService:BindSystems({
    ArenaService = ArenaService,
    WeaponService = WeaponService,
    RespawnService = RespawnService,
    ExperienceOrbService = ExperienceOrbService,
})
MonsterService:BindSystems({
    BuffService = BuffService,
    PotionService = PotionService,
})

local function onPlayerAdded(player)
    if #Players:GetPlayers() > GameConfig.SERVER.MaxPlayers then
        player:Kick(string.format("当前服务器最多允许 %d 名玩家。", GameConfig.SERVER.MaxPlayers))
        return
    end

    PlayerStateService:OnPlayerAdded(player)
    RebirthService:OnPlayerAdded(player)
    WheelService:OnPlayerAdded(player)
    SkinService:OnPlayerAdded(player)
    SubscriptionService:OnPlayerAdded(player)
    LeaderboardService:OnPlayerAdded(player)
    SpecialEventService:OnPlayerAdded(player)
    ArenaProgressService:OnPlayerAdded(player)

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
    WeaponUnlockRewardService:OnPlayerRemoving(player)
    GroupRewardService:OnPlayerRemoving(player)
    WheelService:OnPlayerRemoving(player)
    SkinService:OnPlayerRemoving(player)
    SubscriptionService:OnPlayerRemoving(player)
    BadgeAwardService:OnPlayerRemoving(player)
    RebirthService:OnPlayerRemoving(player)
    LeaderboardService:OnPlayerRemoving(player)
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

game:BindToClose(function()
    LeaderboardService:SaveAllPlayers()
end)
