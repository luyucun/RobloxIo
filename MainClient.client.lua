--[[
脚本名字: MainClient
脚本文件: MainClient.client.lua
脚本类型: LocalScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/MainClient
]]

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local function findLocalModule(moduleName)
    local controllersFolder = script.Parent:FindFirstChild("Controllers")
    if controllersFolder then
        local moduleInControllers = controllersFolder:FindFirstChild(moduleName)
        if moduleInControllers and moduleInControllers:IsA("ModuleScript") then
            return moduleInControllers
        end
    end

    local moduleInRoot = script.Parent:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return moduleInRoot
    end

    return nil
end

local function requireLocalModule(moduleName)
    local moduleScript = findLocalModule(moduleName)
    if not moduleScript then
        warn(string.format(
            "[MainClient] 缺少客户端模块 %s（应放在 StarterPlayerScripts/Controllers 或 StarterPlayerScripts 根目录）",
            tostring(moduleName or "")
        ))
        return nil
    end

    local ok, result = pcall(require, moduleScript)
    if ok then
        return result
    end

    warn(string.format("[MainClient] 客户端模块 %s 加载失败：%s", tostring(moduleName or ""), tostring(result)))
    return nil
end

local function initController(controllerName, controller, dependencies)
    if not controller then
        return false
    end

    if type(controller.Init) ~= "function" then
        warn(string.format("[MainClient] 客户端模块 %s 缺少 Init 方法", tostring(controllerName or "")))
        return false
    end

    local ok, result = pcall(function()
        controller:Init(dependencies)
    end)
    if ok then
        return true
    end

    warn(string.format(
        "[MainClient] 客户端模块 %s 初始化失败：%s",
        tostring(controllerName or ""),
        tostring(result)
    ))
    return false
end

local AudioSettingsController = requireLocalModule("AudioSettingsController")
local WeaponFxController = requireLocalModule("WeaponFxController")
local ClientEventController = requireLocalModule("ClientEventController")
local GlobalLeaderboardController = requireLocalModule("GlobalLeaderboardController")
local LocalLeaderboardController = requireLocalModule("LocalLeaderboardController")
local FriendsRankingController = requireLocalModule("FriendsRankingController")
local MonsterAnimationController = requireLocalModule("MonsterAnimationController")
local LocalMonsterController = requireLocalModule("LocalMonsterController")
local AutoBattleController = requireLocalModule("AutoBattleController")
local JoinGameController = requireLocalModule("JoinGameController")
local RebirthController = requireLocalModule("RebirthController")
local WeaponIndexController = requireLocalModule("WeaponIndexController")
local PotionController = requireLocalModule("PotionController")
local ModalUiController = requireLocalModule("ModalUiController")
local LeaveTipsController = requireLocalModule("LeaveTipsController")
local InviteTipsController = requireLocalModule("InviteTipsController")
local MonetizationController = requireLocalModule("MonetizationController")
local DefeatedController = requireLocalModule("DefeatedController")
local CameraController = requireLocalModule("CameraController")
local CoreGuiController = requireLocalModule("CoreGuiController")
local NukeCinematicController = requireLocalModule("NukeCinematicController")
local RevengeCinematicController = requireLocalModule("RevengeCinematicController")
local SpecialEventController = requireLocalModule("SpecialEventController")
local GroupRewardController = requireLocalModule("GroupRewardController")
local ArenaProgressController = requireLocalModule("ArenaProgressController")
local TopStatsController = requireLocalModule("TopStatsController")
local AttributeUpgradeController = requireLocalModule("AttributeUpgradeController")
local AttributeCapUpgradeController = requireLocalModule("AttributeCapUpgradeController")
local KillTipsController = requireLocalModule("KillTipsController")
local NewWeaponUnlockController = requireLocalModule("NewWeaponUnlockController")
local OverheadLevelController = requireLocalModule("OverheadLevelController")
local WheelController = requireLocalModule("WheelController")
local SkinController = requireLocalModule("SkinController")
local TrailFxController = requireLocalModule("TrailFxController")
local SubscriptionController = requireLocalModule("SubscriptionController")
local ShopController = requireLocalModule("ShopController")
local CodeController = requireLocalModule("CodeController")
local GameNewsController = requireLocalModule("GameNewsController")
local OnlineRewardController = requireLocalModule("OnlineRewardController")
local SevenDayLoginRewardController = requireLocalModule("SevenDayLoginRewardController")
local TaskController = requireLocalModule("TaskController")
local ChestController = requireLocalModule("ChestController")
local OptionController = requireLocalModule("OptionController")
local BossHitFeedbackController = requireLocalModule("BossHitFeedbackController")
local NoobMachineController = requireLocalModule("NoobMachineController")
local GuideController = requireLocalModule("GuideController")
local FavoritePlacePromptController = requireLocalModule("FavoritePlacePromptController")
local ActivityRsvpPromptController = requireLocalModule("ActivityRsvpPromptController")

initController("AudioSettingsController", AudioSettingsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ModalUiController", ModalUiController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("LeaveTipsController", LeaveTipsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    ModalUiController = ModalUiController,
})

initController("CoreGuiController", CoreGuiController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("CameraController", CameraController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ClientEventController", ClientEventController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    AudioSettingsController = AudioSettingsController,
})

initController("TopStatsController", TopStatsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("AttributeUpgradeController", AttributeUpgradeController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    ModalUiController = ModalUiController,
    AttributeCapUpgradeController = AttributeCapUpgradeController,
})

initController("AttributeCapUpgradeController", AttributeCapUpgradeController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    ModalUiController = ModalUiController,
    ShopController = ShopController,
})

initController("KillTipsController", KillTipsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("OverheadLevelController", OverheadLevelController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("NewWeaponUnlockController", NewWeaponUnlockController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("GlobalLeaderboardController", GlobalLeaderboardController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("LocalLeaderboardController", LocalLeaderboardController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("FriendsRankingController", FriendsRankingController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("InviteTipsController", InviteTipsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("WeaponFxController", WeaponFxController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("MonsterAnimationController", MonsterAnimationController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("LocalMonsterController", LocalMonsterController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    WeaponFxController = WeaponFxController,
    AudioSettingsController = AudioSettingsController,
})

initController("AutoBattleController", AutoBattleController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    WeaponFxController = WeaponFxController,
    LocalMonsterController = LocalMonsterController,
})

initController("JoinGameController", JoinGameController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("RebirthController", RebirthController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("WeaponIndexController", WeaponIndexController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("PotionController", PotionController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("SpecialEventController", SpecialEventController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("GroupRewardController", GroupRewardController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ArenaProgressController", ArenaProgressController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("MonetizationController", MonetizationController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("WheelController", WheelController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    AudioSettingsController = AudioSettingsController,
})

initController("SubscriptionController", SubscriptionController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("OnlineRewardController", OnlineRewardController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("SevenDayLoginRewardController", SevenDayLoginRewardController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("TaskController", TaskController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ChestController", ChestController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("SkinController", SkinController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    WheelController = WheelController,
    SevenDayLoginRewardController = SevenDayLoginRewardController,
    ChestController = ChestController,
})

initController("TrailFxController", TrailFxController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ShopController", ShopController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    WheelController = WheelController,
    SubscriptionController = SubscriptionController,
    SevenDayLoginRewardController = SevenDayLoginRewardController,
    ChestController = ChestController,
    AudioSettingsController = AudioSettingsController,
})

initController("CodeController", CodeController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("GameNewsController", GameNewsController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("OptionController", OptionController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    AudioSettingsController = AudioSettingsController,
})

initController("BossHitFeedbackController", BossHitFeedbackController, {
	LocalPlayer = localPlayer,
	RootScript = script,
	AudioSettingsController = AudioSettingsController,
})

initController("NoobMachineController", NoobMachineController, {
	LocalPlayer = localPlayer,
	RootScript = script,
})

initController("GuideController", GuideController, {
	LocalPlayer = localPlayer,
	RootScript = script,
})

initController("FavoritePlacePromptController", FavoritePlacePromptController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("ActivityRsvpPromptController", ActivityRsvpPromptController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})

initController("DefeatedController", DefeatedController, {
	LocalPlayer = localPlayer,
	RootScript = script,
})

initController("NukeCinematicController", NukeCinematicController, {
    LocalPlayer = localPlayer,
    RootScript = script,
    LocalMonsterController = LocalMonsterController,
    AudioSettingsController = AudioSettingsController,
})

initController("RevengeCinematicController", RevengeCinematicController, {
    LocalPlayer = localPlayer,
    RootScript = script,
})
