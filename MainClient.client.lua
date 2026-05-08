--[[
脚本名字: MainClient
脚本文件: MainClient.client.lua
脚本类型: LocalScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/MainClient
]]

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local function requireLocalModule(moduleName)
    local controllersFolder = script.Parent:FindFirstChild("Controllers")
    if controllersFolder then
        local moduleInControllers = controllersFolder:FindFirstChild(moduleName)
        if moduleInControllers and moduleInControllers:IsA("ModuleScript") then
            return require(moduleInControllers)
        end
    end

    local moduleInRoot = script.Parent:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return require(moduleInRoot)
    end

    error(string.format(
        "[MainClient] 缺少客户端模块 %s（应放在 StarterPlayerScripts/Controllers 或 StarterPlayerScripts 根目录）",
        tostring(moduleName or "")
    ))
end

local WeaponFxController = requireLocalModule("WeaponFxController")
local ClientEventController = requireLocalModule("ClientEventController")
local GlobalLeaderboardController = requireLocalModule("GlobalLeaderboardController")
local LocalLeaderboardController = requireLocalModule("LocalLeaderboardController")
local MonsterAnimationController = requireLocalModule("MonsterAnimationController")
local LocalMonsterController = requireLocalModule("LocalMonsterController")
local AutoBattleController = requireLocalModule("AutoBattleController")
local JoinGameController = requireLocalModule("JoinGameController")
local RebirthController = requireLocalModule("RebirthController")
local WeaponIndexController = requireLocalModule("WeaponIndexController")
local PotionController = requireLocalModule("PotionController")
local MonetizationController = requireLocalModule("MonetizationController")
local DefeatedController = requireLocalModule("DefeatedController")
local CameraController = requireLocalModule("CameraController")
local CoreGuiController = requireLocalModule("CoreGuiController")
local NukeCinematicController = requireLocalModule("NukeCinematicController")
local SpecialEventController = requireLocalModule("SpecialEventController")
local GroupRewardController = requireLocalModule("GroupRewardController")
local ArenaProgressController = requireLocalModule("ArenaProgressController")
local TopStatsController = requireLocalModule("TopStatsController")

CoreGuiController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

CameraController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

ClientEventController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

TopStatsController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

GlobalLeaderboardController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

LocalLeaderboardController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

WeaponFxController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

MonsterAnimationController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

LocalMonsterController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
    WeaponFxController = WeaponFxController,
})

AutoBattleController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
    WeaponFxController = WeaponFxController,
    LocalMonsterController = LocalMonsterController,
})

JoinGameController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

RebirthController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

WeaponIndexController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

PotionController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

SpecialEventController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

GroupRewardController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

ArenaProgressController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

MonetizationController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

DefeatedController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
})

NukeCinematicController:Init({
    LocalPlayer = localPlayer,
    RootScript = script,
    LocalMonsterController = LocalMonsterController,
})
