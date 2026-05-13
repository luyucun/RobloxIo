--[[
脚本名字: GroupRewardService
脚本文件: GroupRewardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/GroupRewardService
说明: V2.3 群组奖励服务端触碰入口、群组校验与一次性发奖。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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
        "[GroupRewardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local GroupRewardService = {}

GroupRewardService._playerStateService = nil
GroupRewardService._potionService = nil
GroupRewardService._rebirthService = nil
GroupRewardService._groupRewardPromptEvent = nil
GroupRewardService._requestGroupRewardEvent = nil
GroupRewardService._groupRewardFeedbackEvent = nil
GroupRewardService._chestModel = nil
GroupRewardService._chestTouchedConnections = {}
GroupRewardService._touchDebounceByUserId = {}
GroupRewardService._claimingByUserId = {}

local function splitPath(path)
    local segments = {}
    for segment in string.gmatch(tostring(path or ""), "[^/%.]+") do
        table.insert(segments, segment)
    end
    return segments
end

local function resolvePath(path)
    local segments = splitPath(path)
    local current = game
    for index, segment in ipairs(segments) do
        if index == 1 then
            if segment == "game" then
                current = game
            elseif segment == "Workspace" or segment == "workspace" then
                current = Workspace
            elseif segment == "ReplicatedStorage" then
                current = ReplicatedStorage
            else
                current = game:FindFirstChild(segment)
            end
        else
            current = current and current:FindFirstChild(segment) or nil
        end

        if not current then
            return nil
        end
    end
    return current
end

local function getConfiguredGroupId()
    return math.floor(tonumber(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.GroupId) or 0)
end

function GroupRewardService:_isClaimed(player)
    return self._playerStateService
        and self._playerStateService.HasGroupReward
        and self._playerStateService:HasGroupReward(player, getConfiguredGroupId()) == true
end

function GroupRewardService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function GroupRewardService:_firePrompt(player)
    if not (player and player.Parent and self._groupRewardPromptEvent) then
        return
    end

    self._groupRewardPromptEvent:FireClient(player, {
        eventType = "Show",
        groupId = getConfiguredGroupId(),
        claimed = self:_isClaimed(player),
        timestamp = os.clock(),
    })
end

function GroupRewardService:_fireFeedback(player, eventType, message)
    if not (player and player.Parent and self._groupRewardFeedbackEvent) then
        return
    end

    self._groupRewardFeedbackEvent:FireClient(player, {
        eventType = eventType,
        message = message,
        groupId = getConfiguredGroupId(),
        claimed = self:_isClaimed(player),
        timestamp = os.clock(),
    })
end

function GroupRewardService:_disconnectChestTouchedConnections()
    for _, connection in ipairs(self._chestTouchedConnections or {}) do
        if connection then
            connection:Disconnect()
        end
    end
    self._chestTouchedConnections = {}
end

function GroupRewardService:_connectChestTouched()
    self:_disconnectChestTouchedConnections()
    if not self._chestModel then
        return
    end

    for _, descendant in ipairs(self._chestModel:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.CanTouch = true
            table.insert(self._chestTouchedConnections, descendant.Touched:Connect(function(hitPart)
                self:_onChestTouched(hitPart)
            end))
        end
    end
end

function GroupRewardService:_onChestTouched(hitPart)
    local character = hitPart and hitPart:FindFirstAncestorOfClass("Model")
    if not character then
        return
    end

    local player = Players:GetPlayerFromCharacter(character)
    if not (player and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    local now = os.clock()
    local debounceSeconds = math.max(0.1, tonumber(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.TouchDebounceSeconds) or 1)
    local lastClock = self._touchDebounceByUserId[player.UserId]
    if lastClock and now - lastClock < debounceSeconds then
        return
    end
    self._touchDebounceByUserId[player.UserId] = now

    self:_firePrompt(player)
end

function GroupRewardService:Claim(player)
    if not (player and player.Parent and self._playerStateService and self._potionService) then
        return false, "ServiceUnavailable"
    end
    if not self:_isPlayerLoaded(player) then
        self:_fireFeedback(player, "Failed", "DataLoading")
        return false, "DataLoading"
    end

    local groupId = getConfiguredGroupId()
    if groupId <= 0 then
        self:_fireFeedback(player, "Failed", "InvalidGroup")
        return false, "InvalidGroup"
    end

    if self:_isClaimed(player) then
        self:_fireFeedback(player, "AlreadyClaimed", "AlreadyClaimed")
        return false, "AlreadyClaimed"
    end

    if self._claimingByUserId[player.UserId] then
        return false, "Busy"
    end
    self._claimingByUserId[player.UserId] = true

    local ok, isInGroup = pcall(function()
        return player:IsInGroupAsync(groupId)
    end)
    if not ok then
        self._claimingByUserId[player.UserId] = nil
        self:_fireFeedback(player, "Failed", "GroupCheckFailed")
        return false, "GroupCheckFailed"
    end

    if isInGroup ~= true then
        self._claimingByUserId[player.UserId] = nil
        self:_fireFeedback(player, "NotInGroup", "NotInGroup")
        return false, "NotInGroup"
    end

    local rewardPotionId = GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.RewardPotionId or 1003
    local rewardAmount = GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.RewardPotionAmount or 1
    local success, result = self._potionService:AddPotion(player, rewardPotionId, rewardAmount, "GroupReward")
    if not success then
        self._claimingByUserId[player.UserId] = nil
        self:_fireFeedback(player, "Failed", tostring(result or "RewardFailed"))
        return false, result
    end

    self._playerStateService:MarkGroupReward(player, groupId)
    self._playerStateService:PushState(player)
    if self._rebirthService then
        self._rebirthService:MarkDirty(player)
    end

    self._claimingByUserId[player.UserId] = nil
    self:_fireFeedback(player, "Success", "Claimed")
    return true, result
end

function GroupRewardService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._potionService = dependencies and dependencies.PotionService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._groupRewardPromptEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("GroupRewardPrompt") or nil
    self._requestGroupRewardEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestGroupReward") or nil
    self._groupRewardFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("GroupRewardFeedback") or nil
    self._touchDebounceByUserId = {}
    self._claimingByUserId = {}

    self._chestModel = resolvePath(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.ChestPath)
    if not self._chestModel then
        warn("[GroupRewardService] 找不到群组奖励宝箱: " .. tostring(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.ChestPath))
    end
    self:_connectChestTouched()

    if self._requestGroupRewardEvent then
        self._requestGroupRewardEvent.OnServerEvent:Connect(function(player)
            self:Claim(player)
        end)
    end
end

function GroupRewardService:OnPlayerRemoving(player)
    if player then
        self._touchDebounceByUserId[player.UserId] = nil
        self._claimingByUserId[player.UserId] = nil
    end
end

return GroupRewardService
