--[[
脚本名字: RemoteEventService
脚本文件: RemoteEventService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/RemoteEventService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[RemoteEventService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local RemoteEventService = {}
RemoteEventService._events = {}
RemoteEventService._eventDefinitions = {}

local function findOrCreateFolder(parent, folderName)
    local folder = parent:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
end

local function findOrCreateRemoteEvent(parent, eventName)
    local event = parent:FindFirstChild(eventName)
    if event and event:IsA("RemoteEvent") then
        return event
    end

    event = Instance.new("RemoteEvent")
    event.Name = eventName
    event.Parent = parent
    return event
end

function RemoteEventService:_registerEvent(eventKey, parent, eventName)
    local normalizedName = tostring(eventName or "")
    if normalizedName == "" then
        return nil
    end

    self._eventDefinitions[eventKey] = {
        Parent = parent,
        EventName = normalizedName,
    }

    local event = findOrCreateRemoteEvent(parent, normalizedName)
    self._events[eventKey] = event
    return event
end

function RemoteEventService:Init()
    self._events = {}
    self._eventDefinitions = {}

    local rootFolder = findOrCreateFolder(ReplicatedStorage, RemoteNames.RootFolder)
    local systemEvents = findOrCreateFolder(rootFolder, RemoteNames.SystemEventsFolder)
    local battleEvents = findOrCreateFolder(rootFolder, RemoteNames.BattleEventsFolder)

    local eventDefinitions = {
        { Key = "PlayerStateSync", Parent = systemEvents, Name = RemoteNames.System.PlayerStateSync },
        { Key = "RequestPlayerStateSync", Parent = systemEvents, Name = RemoteNames.System.RequestPlayerStateSync },
        { Key = "ArenaTransitionFeedback", Parent = systemEvents, Name = RemoteNames.System.ArenaTransitionFeedback },
        { Key = "DeathFeedback", Parent = systemEvents, Name = RemoteNames.System.DeathFeedback },
        { Key = "StudioBotCommand", Parent = systemEvents, Name = RemoteNames.System.StudioBotCommand },
        { Key = "LevelUpFeedback", Parent = systemEvents, Name = RemoteNames.System.LevelUpFeedback },
        { Key = "PortalJoinPrompt", Parent = systemEvents, Name = RemoteNames.System.PortalJoinPrompt },
        { Key = "RequestJoinBattle", Parent = systemEvents, Name = RemoteNames.System.RequestJoinBattle },
        { Key = "RequestRebirth", Parent = systemEvents, Name = RemoteNames.System.RequestRebirth },
        { Key = "RebirthFeedback", Parent = systemEvents, Name = RemoteNames.System.RebirthFeedback },
        { Key = "RequestDefeatedAction", Parent = systemEvents, Name = RemoteNames.System.RequestDefeatedAction },
        { Key = "RequestPotionAction", Parent = systemEvents, Name = RemoteNames.System.RequestPotionAction },
        { Key = "PotionFeedback", Parent = systemEvents, Name = RemoteNames.System.PotionFeedback },
        { Key = "SpecialEventSync", Parent = systemEvents, Name = RemoteNames.System.SpecialEventSync },
        { Key = "RequestSpecialEventSync", Parent = systemEvents, Name = RemoteNames.System.RequestSpecialEventSync },
        { Key = "GroupRewardPrompt", Parent = systemEvents, Name = RemoteNames.System.GroupRewardPrompt },
        { Key = "RequestGroupReward", Parent = systemEvents, Name = RemoteNames.System.RequestGroupReward },
        { Key = "GroupRewardFeedback", Parent = systemEvents, Name = RemoteNames.System.GroupRewardFeedback },
        { Key = "PromptGroupJoin", Parent = systemEvents, Name = RemoteNames.System.PromptGroupJoin },

        { Key = "PickupFeedback", Parent = battleEvents, Name = RemoteNames.Battle.PickupFeedback },
        { Key = "ExperienceFeedback", Parent = battleEvents, Name = RemoteNames.Battle.ExperienceFeedback },
        { Key = "LocalMonsterKilled", Parent = battleEvents, Name = RemoteNames.Battle.LocalMonsterKilled },
        { Key = "LocalMonsterHitPlayer", Parent = battleEvents, Name = RemoteNames.Battle.LocalMonsterHitPlayer },
        { Key = "WeaponStateSync", Parent = battleEvents, Name = RemoteNames.Battle.WeaponStateSync },
        { Key = "CombatFeedback", Parent = battleEvents, Name = RemoteNames.Battle.CombatFeedback },
        { Key = "BuffFeedback", Parent = battleEvents, Name = RemoteNames.Battle.BuffFeedback },
        { Key = "BossFeedback", Parent = battleEvents, Name = RemoteNames.Battle.BossFeedback },
        { Key = "LeaderboardSync", Parent = battleEvents, Name = RemoteNames.Battle.LeaderboardSync },
        { Key = "ArenaProgressSync", Parent = battleEvents, Name = RemoteNames.Battle.ArenaProgressSync },
        { Key = "NukeCinematic", Parent = battleEvents, Name = RemoteNames.Battle.NukeCinematic },
        { Key = "NukeLocalMonsterSweep", Parent = battleEvents, Name = RemoteNames.Battle.NukeLocalMonsterSweep },
    }

    for _, eventDefinition in ipairs(eventDefinitions) do
        self:_registerEvent(eventDefinition.Key, eventDefinition.Parent, eventDefinition.Name)
    end
end

function RemoteEventService:GetEvent(eventKey)
    return self._events[eventKey]
end

return RemoteEventService
