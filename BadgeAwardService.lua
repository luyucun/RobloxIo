--[[
Script: BadgeAwardService
Type: ModuleScript
Studio path: ServerScriptService/Services/BadgeAwardService
Purpose: Official Roblox badge ownership checks and awards.
]]

local BadgeService = game:GetService("BadgeService")
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
        "[BadgeAwardService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local BadgeConfig = requireSharedModule("BadgeConfig")

local BadgeAwardService = {}

BadgeAwardService._awardInProgressByUserIdAndBadgeId = {}

local function getUserId(player)
    return player and player.UserId or 0
end

local function getAwardKey(userId, badgeId)
    return tostring(userId) .. ":" .. tostring(badgeId)
end

function BadgeAwardService:Init()
    self._awardInProgressByUserIdAndBadgeId = {}
end

function BadgeAwardService:BindSystems()
end

function BadgeAwardService:GetBadgeDefinition(badgeKeyOrId)
    return BadgeConfig.GetBadge(badgeKeyOrId)
end

function BadgeAwardService:UserHasBadge(player, badgeKeyOrId)
    if not ActorUtils.IsPlayer(player) then
        return false, "InvalidPlayer"
    end

    local badgeId = BadgeConfig.GetBadgeId(badgeKeyOrId)
    if badgeId <= 0 then
        return false, "InvalidBadge"
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return false, "InvalidPlayer"
    end

    local ok, result = pcall(function()
        return BadgeService:UserHasBadgeAsync(userId, badgeId)
    end)
    if not ok then
        warn("[BadgeAwardService] UserHasBadgeAsync failed: " .. tostring(result))
        return false, "BadgeCheckFailed"
    end

    return result == true, nil
end

function BadgeAwardService:AwardBadge(player, badgeKeyOrId, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "InvalidPlayer"
    end

    local badge = BadgeConfig.GetBadge(badgeKeyOrId)
    if not badge then
        return false, "InvalidBadge"
    end

    local badgeId = math.floor(tonumber(badge.Id) or 0)
    if badgeId <= 0 then
        return false, "InvalidBadge"
    end

    local userId = getUserId(player)
    if userId <= 0 then
        return false, "InvalidPlayer"
    end

    local awardKey = getAwardKey(userId, badgeId)
    if self._awardInProgressByUserIdAndBadgeId[awardKey] then
        return false, "Busy"
    end

    self._awardInProgressByUserIdAndBadgeId[awardKey] = true

    local hasBadge, hasReason = self:UserHasBadge(player, badgeId)
    if hasReason then
        self._awardInProgressByUserIdAndBadgeId[awardKey] = nil
        return false, hasReason
    end
    if hasBadge then
        self._awardInProgressByUserIdAndBadgeId[awardKey] = nil
        return true, "AlreadyOwned"
    end

    local ok, awardErr = pcall(function()
        BadgeService:AwardBadgeAsync(userId, badgeId)
    end)
    self._awardInProgressByUserIdAndBadgeId[awardKey] = nil

    if not ok then
        warn(string.format(
            "[BadgeAwardService] AwardBadge failed (badge=%s source=%s): %s",
            tostring(badge.Key or badgeId),
            tostring(source or ""),
            tostring(awardErr)
        ))
        return false, "AwardFailed"
    end

    return true, "Awarded"
end

function BadgeAwardService:AwardBadgeAsync(player, badgeKeyOrId, source)
    task.spawn(function()
        self:AwardBadge(player, badgeKeyOrId, source)
    end)
end

function BadgeAwardService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return
    end

    local prefix = tostring(userId) .. ":"
    for awardKey in pairs(self._awardInProgressByUserIdAndBadgeId) do
        if string.sub(awardKey, 1, #prefix) == prefix then
            self._awardInProgressByUserIdAndBadgeId[awardKey] = nil
        end
    end
end

return BadgeAwardService
