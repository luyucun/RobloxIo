--[[
Script: BadgeAwardService
Type: ModuleScript
Studio path: ServerScriptService/Services/BadgeAwardService
Purpose: Official Roblox badge ownership checks and awards.
]]

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
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

local MAX_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 3 }
local FAILURE_COOLDOWN_SECONDS = 60
local BADGE_INFO_CACHE_SECONDS = 60

BadgeAwardService._generation = 0
BadgeAwardService._sessionsByUserId = {}
BadgeAwardService._badgeInfoById = {}
BadgeAwardService._departingPlayers = setmetatable({}, { __mode = "k" })

local function getUserId(player)
    return player and player.UserId or 0
end

local function isCurrentPlayer(player)
    if not ActorUtils.IsPlayer(player) or typeof(player) ~= "Instance" or not player:IsA("Player") then
        return false
    end
    local userId = getUserId(player)
    return userId > 0 and player.Parent == Players and Players:GetPlayerByUserId(userId) == player
end

function BadgeAwardService:Init()
    self._generation = (self._generation or 0) + 1
    self._sessionsByUserId = {}
    self._badgeInfoById = {}
    self._departingPlayers = setmetatable({}, { __mode = "k" })
end

function BadgeAwardService:BindSystems(systems)
    systems = systems or {}
    self._playerStateService = systems.PlayerStateService
    self._rebirthService = systems.RebirthService
end

function BadgeAwardService:GetBadgeDefinition(badgeKeyOrId)
    return BadgeConfig.GetBadge(badgeKeyOrId)
end

function BadgeAwardService:_isLoaded(player)
    return self._rebirthService ~= nil and self._rebirthService:IsPlayerLoaded(player) == true
end

function BadgeAwardService:_isSessionCurrent(session)
    return session ~= nil
        and session.generation == self._generation
        and self._sessionsByUserId[session.userId] == session
        and self._departingPlayers[session.player] ~= true
        and isCurrentPlayer(session.player)
        and self:_isLoaded(session.player)
end

function BadgeAwardService:_getSession(player)
    if not isCurrentPlayer(player) then
        return nil, "InvalidPlayer"
    end
    if self._departingPlayers[player] then
        return nil, "PlayerRemoving"
    end
    if not self._rebirthService then
        return nil, "SystemsNotBound"
    end
    if not self:_isLoaded(player) then
        return nil, "NotLoaded"
    end

    local userId = getUserId(player)
    local session = self._sessionsByUserId[userId]
    if not session or session.player ~= player or session.generation ~= self._generation then
        session = {
            player = player,
            userId = userId,
            generation = self._generation,
            owned = {},
            requests = {},
            retryAfter = {},
        }
        self._sessionsByUserId[userId] = session
    end
    return session, nil
end

function BadgeAwardService:_getConfiguredBadge(badgeKeyOrId)
    local badge = BadgeConfig.GetBadge(badgeKeyOrId)
    if not badge then
        return nil, "InvalidBadge"
    end
    local badgeId = tonumber(badge.Id) or 0
    if badgeId <= 0 or badgeId % 1 ~= 0 then
        return nil, "UnconfiguredBadge"
    end
    local universeId = tonumber(badge.UniverseId) or 0
    if universeId <= 0 or universeId ~= game.GameId then
        return nil, "WrongUniverse"
    end
    return badge, nil
end

function BadgeAwardService:UserHasBadge(player, badgeKeyOrId)
    local session, sessionReason = self:_getSession(player)
    if not session then
        return false, sessionReason
    end
    local badge, badgeReason = self:_getConfiguredBadge(badgeKeyOrId)
    if not badge then
        return false, badgeReason
    end
    local badgeId = badge.Id
    if session.owned[badgeId] then
        return true, nil
    end
    local ok, result = pcall(function()
        return BadgeService:UserHasBadgeAsync(session.userId, badgeId)
    end)
    if not self:_isSessionCurrent(session) then
        return false, "SessionExpired"
    end
    if not ok or type(result) ~= "boolean" then
        return false, "BadgeCheckFailed", tostring(result)
    end
    if result == true then
        session.owned[badgeId] = true
    end
    return result, nil
end

function BadgeAwardService:_getBadgeEnabled(session, badge)
    local cached = self._badgeInfoById[badge.Id]
    if cached and cached.expiresAt > os.clock() then
        if cached.enabled then
            return true, nil
        end
        return false, "BadgeDisabled"
    end
    local ok, info = pcall(function()
        return BadgeService:GetBadgeInfoAsync(badge.Id)
    end)
    if not self:_isSessionCurrent(session) then
        return false, "SessionExpired"
    end
    if not ok or type(info) ~= "table" or type(info.IsEnabled) ~= "boolean" then
        return false, "BadgeInfoFailed", tostring(info)
    end
    self._badgeInfoById[badge.Id] = { enabled = info.IsEnabled, expiresAt = os.clock() + BADGE_INFO_CACHE_SECONDS }
    if info.IsEnabled then
        return true, nil
    end
    return false, "BadgeDisabled"
end

function BadgeAwardService:_prepareRequest(player, badgeKeyOrId, respectCooldown)
    local session, sessionReason = self:_getSession(player)
    if not session then
        return nil, nil, nil, sessionReason
    end
    local badge, badgeReason = self:_getConfiguredBadge(badgeKeyOrId)
    if not badge then
        return nil, nil, nil, badgeReason
    end
    if session.owned[badge.Id] then
        return session, badge, nil, "AlreadyOwned"
    end
    if session.requests[badge.Id] then
        return session, badge, nil, "Busy"
    end
    if respectCooldown and (session.retryAfter[badge.Id] or 0) > os.clock() then
        return session, badge, nil, "Cooldown"
    end
    -- Reserve synchronously before spawning so multiple progression events share one request.
    local token = {}
    session.requests[badge.Id] = token
    return session, badge, token, nil
end

function BadgeAwardService:_releaseRequest(session, badge, token)
    if self._sessionsByUserId[session.userId] == session and session.requests[badge.Id] == token then
        session.requests[badge.Id] = nil
    end
end

function BadgeAwardService:_attemptAward(session, badge)
    if not self:_isSessionCurrent(session) then
        return false, "SessionExpired"
    end
    local hasBadge, hasReason, hasDetail = self:UserHasBadge(session.player, badge.Id)
    if hasReason then
        return false, hasReason, hasDetail
    end
    if hasBadge then
        return true, "AlreadyOwned"
    end
    local enabled, infoReason, infoDetail = self:_getBadgeEnabled(session, badge)
    if not enabled then
        return false, infoReason, infoDetail
    end
    if not self:_isSessionCurrent(session) then
        return false, "SessionExpired"
    end
    local ok, result = pcall(function()
        return BadgeService:AwardBadgeAsync(session.userId, badge.Id)
    end)
    if not self:_isSessionCurrent(session) then
        return false, "SessionExpired"
    end
    if ok and result == true then
        session.owned[badge.Id] = true
        return true, "Awarded"
    end
    -- A timeout or false result may race another award. Only official ownership true
    -- can resolve that uncertainty; failure itself never enters the positive cache.
    local owned, ownershipReason = self:UserHasBadge(session.player, badge.Id)
    if owned then
        return true, "AlreadyOwned"
    end
    if ownershipReason == "SessionExpired" then
        return false, ownershipReason
    end
    return false, "AwardFailed", tostring(result)
end

function BadgeAwardService:_safeAttempt(session, badge)
    local ok, awarded, reason, detail = pcall(function()
        return self:_attemptAward(session, badge)
    end)
    if not ok then
        return false, "AwardFailed", tostring(awarded)
    end
    return awarded, reason, detail
end

local function warnFailure(badge, source, reason, detail)
    warn(string.format("[BadgeAwardService] badge=%s source=%s reason=%s detail=%s",
        tostring(badge.Key), tostring(source or ""), tostring(reason), tostring(detail or "")))
end

function BadgeAwardService:AwardBadge(player, badgeKeyOrId, source)
    local session, badge, token, reason = self:_prepareRequest(player, badgeKeyOrId, false)
    if not token then
        return reason == "AlreadyOwned", reason
    end
    local awarded, resultReason, detail = self:_safeAttempt(session, badge)
    self:_releaseRequest(session, badge, token)
    if not awarded and resultReason ~= "SessionExpired" then
        warnFailure(badge, source, resultReason, detail)
    end
    return awarded, resultReason
end

function BadgeAwardService:AwardBadgeAsync(player, badgeKeyOrId, source)
    local session, badge, token, reason = self:_prepareRequest(player, badgeKeyOrId, true)
    if not token then
        return reason == "AlreadyOwned", reason
    end
    task.spawn(function()
        local awarded, lastReason, detail = false, nil, nil
        for attempt = 1, MAX_ATTEMPTS do
            awarded, lastReason, detail = self:_safeAttempt(session, badge)
            if awarded or lastReason == "SessionExpired" or lastReason == "BadgeDisabled" then
                break
            end
            if attempt < MAX_ATTEMPTS then
                task.wait(RETRY_DELAYS[attempt])
                if not self:_isSessionCurrent(session) then
                    lastReason = "SessionExpired"
                    break
                end
            end
        end
        if self:_isSessionCurrent(session) then
            if awarded then
                session.retryAfter[badge.Id] = nil
            else
                session.retryAfter[badge.Id] = os.clock() + FAILURE_COOLDOWN_SECONDS
                warnFailure(badge, source, lastReason, detail)
            end
        end
        self:_releaseRequest(session, badge, token)
    end)
    return true, "Queued"
end

function BadgeAwardService:CheckProgress(player, source)
    local session, reason = self:_getSession(player)
    if not session then
        return false, reason
    end
    if not self._playerStateService then
        return false, "SystemsNotBound"
    end
    local state = self._playerStateService:GetState(player)
    local queued = 0
    for _, badgeKey in ipairs(BadgeConfig.GetEligibleBadgeKeys(state)) do
        local accepted, resultReason = self:AwardBadgeAsync(player, badgeKey, source)
        if accepted and resultReason == "Queued" then
            queued = queued + 1
        end
    end
    return true, queued
end

function BadgeAwardService:OnPlayerRemoving(player)
    -- PlayerRemoving fires before Parent/GetPlayerByUserId necessarily change, and
    -- other services may yield while saving. Do not recreate a departing session.
    if ActorUtils.IsPlayer(player) then
        self._departingPlayers[player] = true
    end
    local session = self._sessionsByUserId[getUserId(player)]
    if session and session.player == player then
        self._sessionsByUserId[session.userId] = nil
    end
end

return BadgeAwardService
