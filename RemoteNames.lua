--[[
脚本名字: RemoteNames
脚本文件: RemoteNames.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/RemoteNames
]]

local RemoteNames = {
    RootFolder = "Events",
    SystemEventsFolder = "SystemEvents",
    BattleEventsFolder = "BattleEvents",
    -- Ephemeral Player attributes for Studio presentation tools, not RemoteEvents.
    StudioAttributes = {
        PassUiPreview = "StudioPassUiPreview",
        LevelSkinUiPreview = "StudioLevelSkinUiPreview", -- V6.27 GM /levelskin opens the LevelWeaponSkins window.
    },
    System = {
        -- V6.14: attribute maps include FlashCooldown/FlashDistance; finalStats includes
        -- FlashCooldownSeconds/FlashDistanceStuds. RequestFlash remains intent-only.
        PlayerStateSync = "PlayerStateSync",
        RequestPlayerStateSync = "RequestPlayerStateSync",
        RequestAttributeUpgrade = "RequestAttributeUpgrade",
        AttributeUpgradeFeedback = "AttributeUpgradeFeedback",
        RequestAttributeCapUpgrade = "RequestAttributeCapUpgrade",
        AttributeCapUpgradeFeedback = "AttributeCapUpgradeFeedback",
        ArenaTransitionFeedback = "ArenaTransitionFeedback", -- V6.5: Entering/PortalReady + existing results; ReturnHome stops Auto.
        DeathFeedback = "DeathFeedback",
        KillInfoFeedback = "KillInfoFeedback",
        StudioBotCommand = "StudioBotCommand",
        LevelUpFeedback = "LevelUpFeedback",
        PortalJoinPrompt = "PortalJoinPrompt", -- V6.5 legacy registration only; no confirmation UI.
        RequestJoinBattle = "RequestJoinBattle", -- Auto/legacy Join; server checks current Portal range.
        RequestFlash = "RequestFlash",
        FlashFeedback = "FlashFeedback",
        FlashCompleted = "FlashCompleted",
        RequestRebirth = "RequestRebirth",
        RebirthFeedback = "RebirthFeedback",
        RequestDefeatedAction = "RequestDefeatedAction", -- FreeRespawn/Lobby/Close -> lobby; paid revive/revenge unchanged.
        RequestPotionAction = "RequestPotionAction",
        PotionFeedback = "PotionFeedback",
        SpecialEventSync = "SpecialEventSync",
        RequestSpecialEventSync = "RequestSpecialEventSync",
        GroupRewardPrompt = "GroupRewardPrompt",
        RequestGroupReward = "RequestGroupReward",
        GroupRewardFeedback = "GroupRewardFeedback",
        PromptGroupJoin = "PromptGroupJoin",
        PromptFavoritePlace = "PromptFavoritePlace",
        FavoritePlacePromptStarted = "FavoritePlacePromptStarted",
        FavoritePlacePromptResult = "FavoritePlacePromptResult",
        PromptActivityRsvp = "PromptActivityRsvp",
        ActivityRsvpPromptStarted = "ActivityRsvpPromptStarted",
        ActivityRsvpPromptResult = "ActivityRsvpPromptResult",
        WeaponUnlockPrompt = "WeaponUnlockPrompt",
        RequestWeaponUnlockReward = "RequestWeaponUnlockReward",
        WeaponUnlockRewardFeedback = "WeaponUnlockRewardFeedback",
        RequestWheelStateSync = "RequestWheelStateSync",
        WheelStateSync = "WheelStateSync",
        RequestWheelSpin = "RequestWheelSpin",
        -- reward may carry duplicateCompensation / awardedRewardType / awardedAmount /
        -- awardedGiftName / duplicateDiamonds; original slot and rotation remain unchanged.
        WheelSpinResult = "WheelSpinResult",
        RequestSkinStateSync = "RequestSkinStateSync",
        SkinStateSync = "SkinStateSync",
        RequestSkinPurchase = "RequestSkinPurchase",
        RequestSkinEquip = "RequestSkinEquip",
        SkinFeedback = "SkinFeedback",
        RequestSubscriptionStateSync = "RequestSubscriptionStateSync",
        SubscriptionStateSync = "SubscriptionStateSync",
        RequestSubscriptionClaim = "RequestSubscriptionClaim",
        SubscriptionFeedback = "SubscriptionFeedback",
        RequestShopStateSync = "RequestShopStateSync",
        ShopStateSync = "ShopStateSync",
        RequestShopStarterPackClaim = "RequestShopStarterPackClaim",
        RequestShopPurchaseContext = "RequestShopPurchaseContext",
        ShopRewardFeedback = "ShopRewardFeedback",
        RequestCodeRedeem = "RequestCodeRedeem",
        CodeRedeemFeedback = "CodeRedeemFeedback",
        OnlineRewardStateSync = "OnlineRewardStateSync",
        RequestOnlineRewardStateSync = "RequestOnlineRewardStateSync",
        RequestOnlineRewardClaim = "RequestOnlineRewardClaim",
        SevenDayLoginRewardStateSync = "SevenDayLoginRewardStateSync",
        RequestSevenDayLoginRewardStateSync = "RequestSevenDayLoginRewardStateSync",
        RequestSevenDayLoginRewardClaim = "RequestSevenDayLoginRewardClaim",
        RequestOptionStateSync = "RequestOptionStateSync",
        RequestOptionUpdate = "RequestOptionUpdate",
        RequestFriendsRankingStateSync = "RequestFriendsRankingStateSync",
        FriendsRankingStateSync = "FriendsRankingStateSync",
        TaskStateSync = "TaskStateSync",
        RequestTaskStateSync = "RequestTaskStateSync",
        RequestTaskClaim = "RequestTaskClaim",
        RequestInviteTaskProgress = "RequestInviteTaskProgress",
        ChestStateSync = "ChestStateSync", -- Optional openRejectedReason = NoChest on rejected opening (V6.22).
        RequestChestStateSync = "RequestChestStateSync",
        RequestChestOpen = "RequestChestOpen",
        RequestChestRewardClaim = "RequestChestRewardClaim",
        -- V6.27.2 payload {selectedTierIndex=nil|number, equippedSkinId=nil|number, autoUpgrade=boolean,
        -- highestLevelReached, maxUnlockedTierIndex, totalTierCount, timestamp}; also consumes PlayerStateSync.
        LevelWeaponSkinStateSync = "LevelWeaponSkinStateSync",
        RequestLevelWeaponSkinStateSync = "RequestLevelWeaponSkinStateSync",
        -- Equip: FireServer(tierIndex:number); reset: FireServer("UseLevelLook");
        -- auto toggle: FireServer("AutoUpgrade", enabled:boolean). Server re-validates unlock + strict bool.
        RequestLevelWeaponSkinEquip = "RequestLevelWeaponSkinEquip",
        -- eventType Equipped/Reset/AutoUpdated/Failed, reason, state = same payload as LevelWeaponSkinStateSync.
        LevelWeaponSkinFeedback = "LevelWeaponSkinFeedback",
    },
    Battle = {
        PickupFeedback = "PickupFeedback",
        ExperienceFeedback = "ExperienceFeedback",
        LocalMonsterSpawnToken = "LocalMonsterSpawnToken",
        LocalMonsterKilled = "LocalMonsterKilled",
        LocalMonsterHitPlayer = "LocalMonsterHitPlayer",
        WeaponStateSync = "WeaponStateSync",
        CombatFeedback = "CombatFeedback",
        BuffFeedback = "BuffFeedback",
        BossFeedback = "BossFeedback",
        BossHitFeedback = "BossHitFeedback",
        -- Global boards and self ranks only; native PlayerList reads leaderstats.
        LeaderboardSync = "LeaderboardSync",
        ArenaProgressSync = "ArenaProgressSync",
        -- Server -> clients: optional serverStartTime (Workspace:GetServerTimeNow)
        -- aligns visual stages; existing fields and server-owned settlement stay intact.
        NukeCinematic = "NukeCinematic",
        RevengeCinematic = "RevengeCinematic",
        NukeLocalMonsterSweep = "NukeLocalMonsterSweep",
    },
}

-- V6.17 badges are server-only. FirstBossDefeated is not a Remote or client payload field.
return RemoteNames
