--[[
脚本名字: FriendsRankingService
脚本文件: FriendsRankingService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/FriendsRankingService
说明: 服务端通过 Player:GetFriendsWhoPlayedAsync() 获取玩过本体验的好友 UserId 列表，并补齐好友榜统计数据；CollectionTab 旧节点名保留，但实际展示的是累计击杀数。
]]

local Players = game:GetService("Players")
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
        "[FriendsRankingService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local FriendsRankingService = {}

FriendsRankingService._playerStateService = nil
FriendsRankingService._rebirthService = nil
FriendsRankingService._leaderboardService = nil
FriendsRankingService._requestEvent = nil
FriendsRankingService._syncEvent = nil
FriendsRankingService._requestConnection = nil
FriendsRankingService._lastRequestClockByUserId = {}
FriendsRankingService._nameCacheByUserId = {}
FriendsRankingService._rowsCacheByUserId = {}
FriendsRankingService._refreshInProgressByUserId = {}

local REQUEST_COOLDOWN_SECONDS = 8
local MAX_FRIEND_IDS_PER_REQUEST = 200
local CACHE_REFRESH_AFTER_SECONDS = 60

local function normalizeUserId(value)
    local userId = math.floor(tonumber(value) or 0)
    if userId > 0 then
        return userId
    end
    return nil
end

local function cloneRows(rows)
    local result = {}
    for index, row in ipairs(rows or {}) do
        local copy = {}
        for key, value in pairs(row) do
            copy[key] = value
        end
        result[index] = copy
    end
    return result
end

function FriendsRankingService:_getNameForUserId(userId)
    userId = normalizeUserId(userId)
    if not userId then
        return "Unknown"
    end

    local onlinePlayer = Players:GetPlayerByUserId(userId)
    if onlinePlayer then
        self._nameCacheByUserId[userId] = onlinePlayer.Name
        return onlinePlayer.Name
    end

    if self._nameCacheByUserId[userId] then
        return self._nameCacheByUserId[userId]
    end

    local name = nil
    if self._leaderboardService and self._leaderboardService.GetNameForUserId then
        name = self._leaderboardService:GetNameForUserId(userId)
    end

    if not name or tostring(name) == "" then
        local success, playerName = pcall(function()
            return Players:GetNameFromUserIdAsync(userId)
        end)
        name = success and playerName or tostring(userId)
    end

    self._nameCacheByUserId[userId] = tostring(name)
    return self._nameCacheByUserId[userId]
end

function FriendsRankingService:_getOnlineState(userId)
    local player = Players:GetPlayerByUserId(userId)
    if not player then
        return nil
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not state then
        return nil
    end

    return {
        userId = userId,
        name = player.Name,
        highestLevelReached = math.max(1, math.floor(tonumber(state.HighestLevelReached or state.Level) or GameConfig.PLAYER.BaseLevel)),
        playtimeSeconds = self._leaderboardService and self._leaderboardService.GetPlaytimeValueForUserId and self._leaderboardService:GetPlaytimeValueForUserId(userId) or 0,
    }
end

function FriendsRankingService:_getSavedState(userId)
    local snapshot = self._rebirthService and self._rebirthService.GetSavedProgressSnapshot and self._rebirthService:GetSavedProgressSnapshot(userId) or nil
    if type(snapshot) ~= "table" then
        return nil
    end

    return {
        userId = userId,
        name = self:_getNameForUserId(userId),
        highestLevelReached = math.max(1, math.floor(tonumber(snapshot.highestLevelReached) or GameConfig.PLAYER.BaseLevel)),
        playtimeSeconds = self._leaderboardService and self._leaderboardService.GetPlaytimeValueForUserId and self._leaderboardService:GetPlaytimeValueForUserId(userId) or 0,
    }
end

function FriendsRankingService:_buildRow(userId)
    local row = self:_getOnlineState(userId) or self:_getSavedState(userId)
    if not row then
        return nil
    end

    row.name = row.name or self:_getNameForUserId(userId)
    local totalPlayerKills = 0
    if self._leaderboardService and self._leaderboardService.GetTotalPlayerKillsValueForUserId then
        totalPlayerKills = self._leaderboardService:GetTotalPlayerKillsValueForUserId(userId)
    end
    row.totalPlayerKills = math.max(0, math.floor(tonumber(totalPlayerKills) or 0))
    row.playtimeSeconds = math.max(0, math.floor(tonumber(row.playtimeSeconds) or 0))
    return row
end

function FriendsRankingService:_normalizeFriendIds(player)
    if not (player and player.Parent) then
        return {}
    end

    local success, ids = pcall(function()
        return player:GetFriendsWhoPlayedAsync()
    end)
    if not success or type(ids) ~= "table" then
        return {}
    end

    local result = {}
    local seen = {}
    local localUserId = player and player.UserId or 0
    for _, value in ipairs(ids) do
        local userId = normalizeUserId(value)
        if not userId and type(value) == "table" then
            userId = normalizeUserId(value.UserId or value.userId or value.VisitorId or value.visitorId)
        end
        if userId and userId ~= localUserId and not seen[userId] then
            seen[userId] = true
            table.insert(result, userId)
            if #result >= MAX_FRIEND_IDS_PER_REQUEST then
                break
            end
        end
    end
    return result
end

function FriendsRankingService:_buildRows(player)
    local rows = {}
    for _, userId in ipairs(self:_normalizeFriendIds(player)) do
        local row = self:_buildRow(userId)
        if row then
            table.insert(rows, row)
        end
    end
    return rows
end

function FriendsRankingService:_cacheRows(userId, rows)
    userId = normalizeUserId(userId)
    if not userId then
        return
    end
    self._rowsCacheByUserId[userId] = {
        rows = cloneRows(rows),
        clock = os.clock(),
    }
end

function FriendsRankingService:_getCachedRows(userId)
    userId = normalizeUserId(userId)
    local cached = userId and self._rowsCacheByUserId[userId] or nil
    if not cached then
        return nil, math.huge
    end
    return cloneRows(cached.rows), os.clock() - (tonumber(cached.clock) or 0)
end

function FriendsRankingService:_refreshRowsInBackground(player)
    if not (player and player.Parent) then
        return
    end

    local userId = player.UserId
    if self._refreshInProgressByUserId[userId] then
        return
    end

    self._refreshInProgressByUserId[userId] = true
    task.spawn(function()
        local rows = self:_buildRows(player)
        self:_cacheRows(userId, rows)
        self._refreshInProgressByUserId[userId] = nil
        if player and player.Parent then
            self:_send(player, rows, {
                refreshed = true,
            })
        end
    end)
end

function FriendsRankingService:_buildSelfPayload(player)
    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    local highestLevelReached = math.max(
        1,
        math.floor(tonumber(state and (state.HighestLevelReached or state.Level)) or GameConfig.PLAYER.BaseLevel)
    )
    return {
        userId = player and player.UserId or 0,
        name = player and player.Name or "",
        highestLevelReached = highestLevelReached,
        totalPlayerKills = math.max(0, math.floor(tonumber(state and state.TotalPlayerKills) or 0)),
        friendBonusPercent = math.floor(((tonumber(state and state.FriendExperienceBonus) or 0) * 100) + 0.5),
    }
end

function FriendsRankingService:_send(player, rows, options)
    if not (self._syncEvent and player and player.Parent) then
        return
    end

    self._syncEvent:FireClient(player, {
        rows = rows or {},
        self = self:_buildSelfPayload(player),
        throttled = type(options) == "table" and options.throttled == true or false,
        timestamp = os.clock(),
    })
end

function FriendsRankingService:_handleRequest(player)
    if not (player and player.Parent) then
        return
    end

    local now = os.clock()
    local cachedRows, cachedAge = self:_getCachedRows(player.UserId)
    if cachedRows then
        self:_send(player, cachedRows, {
            cached = true,
        })
        if cachedAge >= CACHE_REFRESH_AFTER_SECONDS then
            self:_refreshRowsInBackground(player)
        end
        return
    end

    local lastRequestClock = tonumber(self._lastRequestClockByUserId[player.UserId]) or 0
    if lastRequestClock > 0 and now - lastRequestClock < REQUEST_COOLDOWN_SECONDS then
        self:_send(player, {}, {
            throttled = true,
        })
        return
    end
    self._lastRequestClockByUserId[player.UserId] = now

    local rows = self:_buildRows(player)
    self:_cacheRows(player.UserId, rows)
    self:_send(player, rows)
end

function FriendsRankingService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._leaderboardService = dependencies and dependencies.LeaderboardService or nil
    self._requestEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestFriendsRankingStateSync") or nil
    self._syncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("FriendsRankingStateSync") or nil
    self._lastRequestClockByUserId = {}
    self._nameCacheByUserId = {}
    self._rowsCacheByUserId = {}
    self._refreshInProgressByUserId = {}

    if self._requestConnection then
        self._requestConnection:Disconnect()
        self._requestConnection = nil
    end

    if self._requestEvent then
        self._requestConnection = self._requestEvent.OnServerEvent:Connect(function(player)
            self:_handleRequest(player)
        end)
    end
end

function FriendsRankingService:OnPlayerRemoving(player)
    if player then
        self._lastRequestClockByUserId[player.UserId] = nil
        self._nameCacheByUserId[player.UserId] = nil
        self._rowsCacheByUserId[player.UserId] = nil
        self._refreshInProgressByUserId[player.UserId] = nil
    end
end

return FriendsRankingService
