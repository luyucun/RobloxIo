--[[
脚本名字: GameConfig
脚本文件: GameConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/GameConfig
]]

local GameConfig = {}

GameConfig.VERSION = "V3.0.0"

GameConfig.SERVER = {
    MaxPlayers = 10,
}

GameConfig.COLLISION = {
    CharacterGroupName = "IOCharacters",
    MonsterGroupName = "IOMonsters",
    SafeBarrierGroupName = "IOSafeBarriers",
    SafeUnlockedCharacterGroupName = "IOSafeUnlockedCharacters",
    SafeLockedCharacterGroupName = "IOSafeLockedCharacters",
}

GameConfig.CAMERA = {
    MinZoomDistance = 15,
    DefaultZoomDistance = 20,
    MaxZoomDistance = 60,
    SpawnLookPitchDegrees = 35,
    SpawnLookFocusHeightOffset = 2,
    SpawnLookForwardOffset = 8,
}

GameConfig.AUDIO = {
    FolderName = "Audio",
    LevelUpSoundName = "LevelUp01",
    LevelUpSoundId = "rbxassetid://371274037",
    BoomSoundName = "Boom",
    BoomSoundId = "rbxassetid://77970762255205",
}

GameConfig.PLAYER = {
    BaseMaxHealth = 100,
    HealthPerLevel = 10,
    BaseMoveSpeed = 20,
    BaseLevel = 1,
    BaseExperience = 0,
    BaseWeaponTier = "T1",
    BaseWeaponCount = 1,
    MaxWeaponCount = 10,
    MaxSupportedLevel = 400,
}

GameConfig.EXPERIENCE = {
    RuntimeFolderName = "ExperienceOrbs",
    ModelRootFolderName = "Model",
    ItemFolderName = "Item",
    TemplateName = "ExperienceOrb",
    TemplateFolderName = "ExperienceBlocks",
    BaseNextLevelExperience = 15,
    LevelExperienceSegments = {
        { MinLevel = 1, MaxLevel = 1, Experience = 15 },
        { MinLevel = 2, MaxLevel = 2, Experience = 90 },
        { MinLevel = 3, MaxLevel = 10, Experience = 120 },
        { MinLevel = 11, MaxLevel = 20, Experience = 160 },
        { MinLevel = 21, MaxLevel = 40, Experience = 200 },
        { MinLevel = 41, MaxLevel = 70, Experience = 400 },
        { MinLevel = 71, MaxLevel = 100, Experience = 600 },
        { MinLevel = 101, MaxLevel = 130, Experience = 800 },
        { MinLevel = 131, MaxLevel = 170, Experience = 1200 },
        { MinLevel = 171, MaxLevel = 220, Experience = 1600 },
        { MinLevel = 221, MaxLevel = 280, Experience = 2400 },
        { MinLevel = 281, MaxLevel = 350, Experience = 3200 },
        { MinLevel = 351, MaxLevel = 400, Experience = 4000 },
    },
    OrbCollectRadius = 4,
    HomingDelaySeconds = 0.8,
    HomingSpeed = 60,
    HomingConsumeRadius = 2.5,
    TouchConsumeDebounceSeconds = 0.1,
    SpawnHeightOffset = 2,
    DropFallHeight = 4,
    DropFallSeconds = 0.35,
    GroundSettleSeconds = 0.25,
    TrailLifetime = 0.28,
    TrailWidth = 0.45,
    MaxLocalVisualOrbsPerDrop = 3,
    MaxLocalActiveOrbs = 45,
    LocalOrbMaxLifetimeSeconds = 5,
    LocalOrbTrailEnabled = true,
}

GameConfig.LEVEL_UP_EFFECT = {
    TemplateName = "LevelUp",
    DurationSeconds = 1.5,
    AttachOffset = Vector3.new(0, 3, 0),
}

GameConfig.ARENA = {
    SpawnLocationName = "SpawnLocation",
    MapFolderName = "Map2",
    PortalsFolderName = "Portals",
    PortalModelName = "Portal",
    BattleMapName = "Battle01",
    BattlePartName = "Battle",
    SafePartName = "Safe",
    SafeBarrierNamePrefix = "Safe1",

    SpawnHeightOffset = 4,
    EdgePadding = 6,
    BattleSpawnSquareSize = 360,
    SafeSpawnPadding = 6,
    SafeZoneVerticalPadding = 12,
    SafeReentryLockMinLevel = 31,
    SafeReentryCheckIntervalSeconds = 0.15,
    SafeReentryPushOutDistance = 8,
    SafeExperienceMultipliers = {
        { MinLevel = 1, MaxLevel = 10, Multiplier = 1 },
        { MinLevel = 11, MaxLevel = 20, Multiplier = 0.8 },
        { MinLevel = 21, MaxLevel = 30, Multiplier = 0.5 },
        { MinLevel = 31, MaxLevel = math.huge, Multiplier = 0 },
    },
    MinSpawnSpacing = 10,
    SpawnCandidateAttempts = 40,
    EnterDebounceSeconds = 1.0,
    FirstArenaEnterShieldDurationSeconds = 60,
    ArenaEnterShieldDurationSeconds = 10,
}

GameConfig.WEAPON = {
    RuntimeFolderName = "Weapons",
    BrokenDebrisFolderName = "WeaponDebris",
    AuraPartName = "Aura",
    OrbitHeight = 0.9,
    OrbitSpeed = 2.8,
    PositionLeadSeconds = 0,
    FallbackAuraScale = 1.15,
    FallbackAuraTransparency = 1,
    BrokenDebrisDurationSeconds = 0.9,
    BrokenDebrisHorizontalSpeed = 24,
    BrokenDebrisUpwardSpeed = 16,
    BrokenDebrisGravity = 36,
    BrokenDebrisSpinSpeedMin = 6,
    BrokenDebrisSpinSpeedMax = 12,
    BrokenDebrisFadeStart = 0.55,
}

GameConfig.WEAPON_UNLOCK = {
    RewardDiamonds = 20,
}

GameConfig.PERFORMANCE = {
    DebugEnabled = false,
    LogIntervalSeconds = 15,
}

GameConfig.ANALYTICS = {
    Enabled = true,
    StudioDebugPrint = true,
    StudioSendToRoblox = false,
    LiveDebugPrint = false,
    CustomEventSampleRate = 1,
    GameplayEconomySampleRate = 1,
    SendBudgetBasePerMinute = 24,
    SendBudgetPerPlayerPerMinute = 12,
    SendBudgetSafetyRatio = 0.7,
    HighFrequencySummaryIntervalSeconds = 45,
    EventDedupeSeconds = 2,
    AnalyticsThrottleCooldownSeconds = 60,
    AnalyticsStatsLogIntervalSeconds = 60,
    CombatSummarySampleRate = 1,
}

GameConfig.COMBAT = {
    StepIntervalSeconds = 0.066,
    WeaponVsWeaponHitCooldownSeconds = 0.25,
    WeaponVsPlayerHitCooldownSeconds = 0.35,
    PlayerBodyHitRadius = 3.5,
    WeaponHitRadiusMin = 2.5,
    ActorCullPadding = 12,
    RemoteWeaponNearDistance = 140,
    RemoteWeaponFarUpdateStride = 3,
    PlayerKnockbackSpeed = 42,
    PlayerKnockbackUpwardSpeed = 8,
}

GameConfig.HEALTH_REGEN = {
    Enabled = true,
    OutOfCombatDelaySeconds = 3,
    TickSeconds = 1,
    MaxHealthPercentPerTick = 0.01,
    EffectTemplateName = "Recover",
    EffectInstanceName = "HealthRegenRecoverEffect",
}

GameConfig.SHIELD = {
    DurationSeconds = 30,
    TickSeconds = 0.25,
    EffectTemplateName = "Shield",
    EffectInstanceName = "ActiveShieldEffect",
}

GameConfig.MONSTER = {
    RuntimeFolderName = "Monsters",
    LocalRuntimeFolderName = "Monsters_ClientLocal",
    ModelRootFolderName = "Model",
    MonsterFolderName = "Monster",
    MonsterDefinitionId = "1001",
    TemplateName = "Monster001",
    BossTemplateName = "Boss001",
    ClientOwnedNormalMonsters = true,
    ServerPopulationEnabled = false,
    MaxActiveCount = 300,
    SpawnIntervalSeconds = 0.5,
    MaxSpawnPerInterval = 16,
    PreloadSpawnIntervalSeconds = 0.1,
    PreloadMaxSpawnPerInterval = 25,
    EvenSpawnJitterRatio = 0.35,
    LocalSimulationTickSeconds = 0.066,
    LocalVisualNearDistance = 75,
    LocalVisualFarUpdateStride = 8,
    LocalFarSimulationStride = 12,
    LocalAnimationNearDistance = 70,
    LocalCombatSleepPadding = 15,
    LocalDamageNumberPoolSize = 40,
    LocalDamageNumbersPerSecond = 18,
    LocalMonsterModelPoolSize = 20,
    LocalDormantMonstersUseModels = false,
    LocalMaxMaterializedMonsters = 40,
    LocalMaxCombatActiveMonsters = 40,
    LocalSpawnTokenRequestBatchSize = 25,
    LocalSpawnTokenRequestsPerSecond = 4,
    LocalSpawnTokenTtlSeconds = 90,
    LocalKillReportsPerSecond = 8,
    LocalKillReportBatchSize = 24,
    LocalKillReportBatchIntervalSeconds = 0.15,
    LocalKillReportMaxPendingSeconds = 8,
    LocalKillBatchExperienceOrbCount = 8,
    LocalHitReportsPerSecond = 8,
    LocalDuplicateKillWindowSeconds = 10,
    ThinkIntervalSeconds = 0.2,
    AttackRange = 30,
    AggroRadius = 30,
    DisengageDistance = 30,
    LeashRadius = 120,
    ContactRadius = 4,
    AttackCooldownSeconds = 0.9,
    WeaponHitCooldownSeconds = 0.2,
    HitKnockbackDistance = 4,
    HitKnockbackInstantDistance = 3,
    HitKnockbackSeconds = 0.18,
    HitStunSeconds = 0.12,
    HitFlashSeconds = 0.12,
    AnimationPhaseJitterSeconds = 1.2,
    AnimationSpeedJitter = 0.08,
    SpawnHeightOffset = 0,
    CollisionRadius = 3.2,
    SeparationPushSpeed = 18,
    EdgePadding = 8,
    SpawnNearActorChance = 0.8,
    SpawnNearActorRadius = 34,
    Level = 1,
    MaxHealth = 20,
    AttackDamage = 4,
    MoveSpeed = 6,
    ExperienceDropCount = 3,
    ExperiencePerOrb = 5,
    KillScoreReward = 10,
}

GameConfig.BOSS = {
    Enabled = true,
    RuntimeName = "Boss",
    MonsterDefinitionId = "2001",
    TemplateName = "Boss001",
    SpawnIntervalSeconds = 120,
    InitialSpawnDelaySeconds = 90,
    MaxActiveCount = 1,
    Level = 5,
    MaxHealth = 30000,
    AttackDamage = 3,
    MoveSpeed = 3.1,
    AttackRange = 30,
    AggroRadius = 30,
    DisengageDistance = 30,
    ContactRadius = 7,
    CollisionRadius = 6.5,
    ExperienceDropCount = 10,
    ExperiencePerOrb = 300,
    MaxExperienceOrbVisualCount = 20,
    KillScoreReward = 300,
    BuffDropCount = 3,
    PotionDropEnabled = true,
    PotionDropRuntimeFolderName = "BossPotionDrops",
    PotionDropMaxLifetimeSeconds = 12,
    PotionDropWeights = {
        { PotionId = 1001, Weight = 50 },
        { PotionId = 1002, Weight = 20 },
        { PotionId = 1003, Weight = 5 },
    },
}

GameConfig.BUFF = {
    RuntimeFolderName = "Buffs",
    ModelRootFolderName = "Model",
    BuffFolderName = "Buff",
    TemplateName = "DamageBuff",
    TouchConsumeDebounceSeconds = 0.1,
    DurationSeconds = 20,
    DamageMultiplier = 1.5,
    SpawnHeightOffset = 2.2,
}

GameConfig.LEADERBOARD = {
    SyncIntervalSeconds = 5,
    GlobalSyncIntervalSeconds = 300,
    GlobalInitialSyncDelaySeconds = 60,
    GlobalWriteMinIntervalSeconds = 300,
    MaxRows = 10,
    GlobalMaxRows = 50,
    EnableDataStores = true,
    PlaytimeOrderedStoreName = "IO_GlobalPlaytime_v1",
    KillOrderedStoreName = "IO_GlobalKills_v1",
    RebirthOrderedStoreName = "IO_GlobalRebirth_v1",
}

GameConfig.ECONOMY = {
    PlayerKillDiamondReward = 5,
}

GameConfig.DATASTORE = {
    StudioPersistenceEnabled = false,
    StudioNamePrefix = "Studio_",
}

GameConfig.FAVORITE_PROMPT = {
    Enabled = true,
    DelaySeconds = 300,
}

GameConfig.MONETIZATION = {
    DoubleLevelProductId = 3587883374,
    DoubleLevelMultiplier = 2,
    NukeProductId = 3587883538,
    NukeDamage = 1000000000,
    RevengeProductId = 3587883769,
    DefeatedReviveProductId = 3595585235,
}

GameConfig.NUKE = {
    AssetFolderName = "NukeAssets",
    SourceModelName = "LittleBoy",
    LittleBoyTemplateName = "LittleBoyTemplate",
    EffectFolderName = "Effect",
    BombEffectName = "Bomb",
    TargetMapName = "Battle01",
    BombPointName = "BombPoint",
    CameraAnimatorFolderName = "MoonAnimator2Saves",
    CameraTrackName = "Fall2",
    IdleAnimationId = "rbxassetid://91372355168267",
    FallHeight = 120,
    FallSeconds = 1.5,
    ExplosionSeconds = 2,
    ExplosionCoverageRadius = 320,
    ExplosionExpandPower = 1,
    StartLeadSeconds = 1,
    NukeBannerSeconds = 2,
    WarningFlashCount = 3,
    WarningFadeInSeconds = 0.25,
    WarningHoldSeconds = 0.35,
    WarningFadeOutSeconds = 0.25,
    WarningGapSeconds = 0.1,
    PreludeZIndex = 100,
    LocalMonsterSweepOrbCount = 12,
    ServerMonsterSweepOrbCount = 12,
    MonsterRespawnPauseSeconds = 2.5,
    LocalMonsterSweepExpireSeconds = 8,
    LightingClockTime = 4,
    RestoreClockTime = 14.5,
    QueueGapSeconds = 0.25,
}

GameConfig.REBIRTH = {
    DataStoreName = "IO_PlayerRebirth_v1",
    AutoSaveIntervalSeconds = 30,
    CombatSnapshotMaxAgeSeconds = 1800,
    BaseRequiredScore = 1500,
    RequiredScoreGrowthMultiplier = 1.34,
    ExperienceBonusPerRebirth = 0.15,
    PlayerKillScoreReward = 80,
    PaidRebirthProductId = 3587883661,
}

GameConfig.GROUP_REWARD = {
    GroupId = 602157319,
    RewardPotionId = 1003,
    RewardPotionAmount = 1,
    ChestPath = "Workspace.Map2.Chests.BasicChest",
    TouchDebounceSeconds = 1,
}

GameConfig.RESPAWN = {
    DeathRecoverySeconds = 1.0,
    MonsterKillAutoReviveSeconds = 2,
    PlayerKillReviveCountdownSeconds = 15,
    DailyFreeReviveLevelMaxExclusive = 30,
    DailyFreeReviveClaimKey = "DefeatedDailyFreeRevive",
}

GameConfig.BOTS = {
    EnabledInStudioOnly = true,
    DefaultStudioCount = 0,
    MaxActiveCount = 20,
    ThinkInterval = 0.35,
    RespawnDelaySeconds = 1.25,
    StartTouchDistance = 6,
    AttackChaseDistance = 70,
    ExperienceSeekDistance = 90,
    BattleTargetReachDistance = 5,
    WanderRadius = 28,
    WanderRefreshSeconds = 2.5,
}

function GameConfig.GetMaxHealthForLevel(level)
    local normalizedLevel = math.max(1, math.floor(tonumber(level) or GameConfig.PLAYER.BaseLevel))
    return GameConfig.PLAYER.BaseMaxHealth + ((normalizedLevel - 1) * GameConfig.PLAYER.HealthPerLevel)
end

function GameConfig.GetNextLevelExperience(level)
    local normalizedLevel = math.max(1, math.floor(tonumber(level) or GameConfig.PLAYER.BaseLevel))
    local segments = GameConfig.EXPERIENCE.LevelExperienceSegments or {}
    for _, segment in ipairs(segments) do
        local minLevel = math.max(1, math.floor(tonumber(segment.MinLevel) or 1))
        local maxLevel = math.max(minLevel, math.floor(tonumber(segment.MaxLevel) or minLevel))
        if normalizedLevel >= minLevel and normalizedLevel <= maxLevel then
            return math.max(1, math.floor(tonumber(segment.Experience) or GameConfig.EXPERIENCE.BaseNextLevelExperience or 100))
        end
    end
    local fallback = segments[#segments]
    return math.max(1, math.floor(tonumber(fallback and fallback.Experience) or GameConfig.EXPERIENCE.BaseNextLevelExperience or 100))
end

function GameConfig.GetRequiredRebirthScore(rebirth)
    local normalizedRebirth = math.max(0, math.floor(tonumber(rebirth) or 0))
    local baseScore = math.max(1, tonumber(GameConfig.REBIRTH.BaseRequiredScore) or 100)
    local growthMultiplier = math.max(1, tonumber(GameConfig.REBIRTH.RequiredScoreGrowthMultiplier) or 1.5)
    return math.max(1, math.floor((baseScore * (growthMultiplier ^ normalizedRebirth)) + 0.5))
end

function GameConfig.GetRebirthExperienceBonus(rebirth)
    local normalizedRebirth = math.max(0, math.floor(tonumber(rebirth) or 0))
    return normalizedRebirth * math.max(0, tonumber(GameConfig.REBIRTH.ExperienceBonusPerRebirth) or 0)
end

function GameConfig.ShouldUsePersistentDataStores(isStudio)
    if isStudio == true then
        return GameConfig.DATASTORE.StudioPersistenceEnabled == true
    end
    return true
end

function GameConfig.GetEnvironmentDataStoreName(baseName, isStudio)
    local normalizedName = tostring(baseName or "")
    if isStudio == true and GameConfig.DATASTORE.StudioPersistenceEnabled == true then
        local prefix = tostring(GameConfig.DATASTORE.StudioNamePrefix or "")
        if prefix ~= "" and string.sub(normalizedName, 1, #prefix) ~= prefix then
            return prefix .. normalizedName
        end
    end
    return normalizedName
end

function GameConfig.ClampInteger(value, minValue, maxValue)
    local normalized = math.floor(tonumber(value) or minValue)
    if normalized < minValue then
        return minValue
    end
    if normalized > maxValue then
        return maxValue
    end
    return normalized
end

return GameConfig
