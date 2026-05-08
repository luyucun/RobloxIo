--[[
脚本名字: LeaderboardService
脚本文件: LeaderboardService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/LeaderboardService
]]

local DataStoreService = game:GetService("DataStoreService")
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
        "[LeaderboardService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local LeaderboardService = {}

LeaderboardService._playerStateService = nil
LeaderboardService._leaderboardSyncEvent = nil
LeaderboardService._heartbeatConnection = nil
LeaderboardService._dirty = true
LeaderboardService._nextSyncClock = 0
LeaderboardService._nextGlobalSyncClock = 0
LeaderboardService._playtimeStore = nil
LeaderboardService._killStore = nil
LeaderboardService._rebirthStore = nil
LeaderboardService._playtimeBaseByUserId = {}
LeaderboardService._nameCacheByUserId = {}
LeaderboardService._globalRows = {
    playtime = {},
    kills = {},
    rebirth = {},
}

local function getGlobalMaxRows()
    return math.max(1, math.floor(tonumber(GameConfig.LEADERBOARD.GlobalMaxRows) or tonumber(GameConfig.LEADERBOARD.MaxRows) or 50))
end

local function safeOrderedStore(storeName)
    local success, store = pcall(function()
        return DataStoreService:GetOrderedDataStore(storeName)
    end)
    if success then
        return store
    end
    warn("[LeaderboardService] 无法初始化 OrderedDataStore: " .. tostring(storeName))
    return nil
end

local function getDataKey(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and playerOrUserId.UserId or tonumber(playerOrUserId)
    return tostring(userId or 0)
end

local function normalizeValue(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function getSessionPlaytimeSeconds(state)
    local startedAt = tonumber(state and state.SessionStartedAt) or os.time()
    return math.max(0, os.time() - startedAt)
end

function LeaderboardService:MarkDirty()
    self._dirty = true
end

function LeaderboardService:BroadcastNow()
    self._dirty = false
    self._nextSyncClock = os.clock() + math.max(1, tonumber(GameConfig.LEADERBOARD.SyncIntervalSeconds) or 1)
    self:_broadcast()
end

function LeaderboardService:_getNameForUserId(userId)
    userId = tonumber(userId)
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

    if userId <= 0 then
        local fallbackName = tostring(userId)
        self._nameCacheByUserId[userId] = fallbackName
        return fallbackName
    end

    local success, playerName = pcall(function()
        return Players:GetNameFromUserIdAsync(userId)
    end)
    local resolvedName = success and playerName or tostring(userId)
    self._nameCacheByUserId[userId] = resolvedName
    return resolvedName
end

function LeaderboardService:_buildServerRows()
    local rows = {}

    for _, state in ipairs(self._playerStateService:GetAllPlayerStates()) do
        table.insert(rows, {
            userId = state.UserId,
            name = self:_getNameForUserId(state.UserId),
            level = state.Level,
            killCount = state.KillCount,
            totalPlayerKills = state.TotalPlayerKills,
            rebirth = state.Rebirth,
            playtimeSeconds = self:_getPlaytimeValue(state),
        })
    end

    table.sort(rows, function(left, right)
        if left.level == right.level then
            return left.killCount > right.killCount
        end
        return left.level > right.level
    end)

    while #rows > GameConfig.LEADERBOARD.MaxRows do
        table.remove(rows)
    end

    return rows
end

function LeaderboardService:_getPlaytimeValue(state)
    if not state then
        return 0
    end
    local userId = tonumber(state.UserId)
    local baseSeconds = userId and self._playtimeBaseByUserId[userId] or 0
    return normalizeValue(baseSeconds) + getSessionPlaytimeSeconds(state)
end

function LeaderboardService:_readStoredValue(store, playerOrUserId)
    if not store then
        return 0
    end

    local success, value = pcall(function()
        return store:GetAsync(getDataKey(playerOrUserId))
    end)
    if not success then
        warn("[LeaderboardService] 读取 OrderedDataStore 失败: " .. tostring(playerOrUserId))
        return 0
    end
    return normalizeValue(value)
end

function LeaderboardService:_writeStoredValue(store, playerOrUserId, value)
    if not store then
        return false
    end

    local success = pcall(function()
        store:SetAsync(getDataKey(playerOrUserId), normalizeValue(value))
    end)
    if not success then
        warn("[LeaderboardService] 写入 OrderedDataStore 失败: " .. tostring(playerOrUserId))
    end
    return success
end

function LeaderboardService:_loadPlayerTotals(player)
    if not (player and player.Parent) then
        return
    end

    local userId = player.UserId
    self._nameCacheByUserId[userId] = player.Name

    if not (GameConfig.LEADERBOARD.EnableDataStores and GameConfig.ShouldUsePersistentDataStores(RunService:IsStudio())) then
        self._playtimeBaseByUserId[userId] = self._playtimeBaseByUserId[userId] or 0
        return
    end

    local playtimeSeconds = self:_readStoredValue(self._playtimeStore, player)
    local totalKills = self:_readStoredValue(self._killStore, player)
    self._playtimeBaseByUserId[userId] = playtimeSeconds

    if self._playerStateService and self._playerStateService.SetTotalPlayerKills then
        local state = self._playerStateService:GetState(player)
        self._playerStateService:SetTotalPlayerKills(player, math.max(totalKills, normalizeValue(state and state.TotalPlayerKills)))
    end
end

function LeaderboardService:_updateGlobalEntry(player, state)
    if not (player and state) then
        return
    end
    if not (GameConfig.LEADERBOARD.EnableDataStores and GameConfig.ShouldUsePersistentDataStores(RunService:IsStudio())) then
        return
    end

    self:_writeStoredValue(self._playtimeStore, player, self:_getPlaytimeValue(state))
    self:_writeStoredValue(self._killStore, player, state.TotalPlayerKills)
    self:_writeStoredValue(self._rebirthStore, player, state.Rebirth)
end

function LeaderboardService:_readOrderedStore(store)
    if not store then
        return {}
    end

    local success, pages = pcall(function()
        return store:GetSortedAsync(false, getGlobalMaxRows())
    end)
    if not success or not pages then
        return {}
    end

    local rows = {}
    for index, item in ipairs(pages:GetCurrentPage()) do
        local userId = tonumber(item.key)
        table.insert(rows, {
            rank = index,
            userId = userId,
            name = self:_getNameForUserId(userId),
            value = normalizeValue(item.value),
        })
    end
    return rows
end

function LeaderboardService:_buildMemoryGlobalRows(metricKey)
    local rows = {}
    for _, state in ipairs(self._playerStateService:GetAllPlayerStates()) do
        local value = 0
        if metricKey == "playtime" then
            value = self:_getPlaytimeValue(state)
        elseif metricKey == "kills" then
            value = normalizeValue(state.TotalPlayerKills)
        elseif metricKey == "rebirth" then
            value = normalizeValue(state.Rebirth)
        end

        table.insert(rows, {
            userId = state.UserId,
            name = self:_getNameForUserId(state.UserId),
            value = value,
        })
    end

    table.sort(rows, function(left, right)
        if left.value == right.value then
            return tostring(left.name) < tostring(right.name)
        end
        return left.value > right.value
    end)

    local maxRows = getGlobalMaxRows()
    while #rows > maxRows do
        table.remove(rows)
    end
    for index, row in ipairs(rows) do
        row.rank = index
    end
    return rows
end

function LeaderboardService:_syncGlobal()
    if not GameConfig.LEADERBOARD.EnableDataStores then
        self._globalRows = {
            playtime = {},
            kills = {},
            rebirth = {},
        }
        return
    end

    local usePersistentStores = GameConfig.ShouldUsePersistentDataStores(RunService:IsStudio())
    for _, player in ipairs(Players:GetPlayers()) do
        local state = self._playerStateService:GetState(player)
        if state then
            self:_updateGlobalEntry(player, state)
        end
    end

    if usePersistentStores then
        self._globalRows = {
            playtime = self:_readOrderedStore(self._playtimeStore),
            kills = self:_readOrderedStore(self._killStore),
            rebirth = self:_readOrderedStore(self._rebirthStore),
        }
    else
        self._globalRows = {
            playtime = self:_buildMemoryGlobalRows("playtime"),
            kills = self:_buildMemoryGlobalRows("kills"),
            rebirth = self:_buildMemoryGlobalRows("rebirth"),
        }
    end
end

function LeaderboardService:_getSelfRank(metricKey, userId)
    local rows = self._globalRows and self._globalRows[metricKey] or {}
    for _, row in ipairs(rows) do
        if tonumber(row.userId) == tonumber(userId) then
            return row.rank, row.value
        end
    end
    return nil, nil
end

function LeaderboardService:_buildSelfMetric(metricKey, state)
    local value = 0
    if state then
        if metricKey == "playtime" then
            value = self:_getPlaytimeValue(state)
        elseif metricKey == "kills" then
            value = normalizeValue(state.TotalPlayerKills)
        elseif metricKey == "rebirth" then
            value = normalizeValue(state.Rebirth)
        end
    end

    local rank, rankedValue = self:_getSelfRank(metricKey, state and state.UserId)
    return {
        rank = rank,
        rankText = rank and tostring(rank) or "50+",
        value = rankedValue or value,
    }
end

function LeaderboardService:_buildPayloadForPlayer(player)
    local state = self._playerStateService:GetState(player)
    return {
        server = self:_buildServerRows(),
        global = {
            playtime = {
                rows = self._globalRows.playtime,
            },
            kills = {
                rows = self._globalRows.kills,
            },
            rebirth = {
                rows = self._globalRows.rebirth,
            },
        },
        self = {
            playtime = self:_buildSelfMetric("playtime", state),
            kills = self:_buildSelfMetric("kills", state),
            rebirth = self:_buildSelfMetric("rebirth", state),
        },
        timestamp = os.clock(),
    }
end

function LeaderboardService:_broadcast()
    if not self._leaderboardSyncEvent then
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        self._leaderboardSyncEvent:FireClient(player, self:_buildPayloadForPlayer(player))
    end
end

function LeaderboardService:_step()
    local now = os.clock()
    if now >= self._nextGlobalSyncClock then
        self._nextGlobalSyncClock = now + math.max(5, tonumber(GameConfig.LEADERBOARD.GlobalSyncIntervalSeconds) or 180)
        self:_syncGlobal()
        self._dirty = true
    end

    if not self._dirty and now < self._nextSyncClock then
        return
    end

    self._nextSyncClock = now + math.max(1, tonumber(GameConfig.LEADERBOARD.SyncIntervalSeconds) or 1)
    self._dirty = false
    self:_broadcast()
end

function LeaderboardService:SavePlayer(player)
    if not (player and self._playerStateService) then
        return
    end
    local state = self._playerStateService:GetState(player)
    if state then
        self:_updateGlobalEntry(player, state)
    end
end

function LeaderboardService:SaveAllPlayers()
    for _, player in ipairs(Players:GetPlayers()) do
        self:SavePlayer(player)
    end
end

function LeaderboardService:OnPlayerAdded(player)
    task.spawn(function()
        self:_loadPlayerTotals(player)
        self:_syncGlobal()
        self._dirty = true
    end)
end

function LeaderboardService:OnPlayerRemoving(player)
    self:SavePlayer(player)
    self._playtimeBaseByUserId[player.UserId] = nil
    self._dirty = true
end

function LeaderboardService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._leaderboardSyncEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LeaderboardSync") or nil
    self._dirty = true
    self._nextSyncClock = 0
    self._nextGlobalSyncClock = os.clock() + 2
    self._playtimeBaseByUserId = {}
    self._nameCacheByUserId = {}
    self._globalRows = {
        playtime = {},
        kills = {},
        rebirth = {},
    }

    local isStudio = RunService:IsStudio()
    if GameConfig.LEADERBOARD.EnableDataStores and GameConfig.ShouldUsePersistentDataStores(isStudio) then
        local playtimeStoreName = GameConfig.GetEnvironmentDataStoreName(GameConfig.LEADERBOARD.PlaytimeOrderedStoreName, isStudio)
        local killStoreName = GameConfig.GetEnvironmentDataStoreName(GameConfig.LEADERBOARD.KillOrderedStoreName, isStudio)
        local rebirthStoreName = GameConfig.GetEnvironmentDataStoreName(GameConfig.LEADERBOARD.RebirthOrderedStoreName, isStudio)
        self._playtimeStore = safeOrderedStore(playtimeStoreName)
        self._killStore = safeOrderedStore(killStoreName)
        self._rebirthStore = safeOrderedStore(rebirthStoreName)
    else
        self._playtimeStore = nil
        self._killStore = nil
        self._rebirthStore = nil
        if isStudio then
            print("[LeaderboardService] Studio 调试模式使用内存排行榜；发布后会使用 OrderedDataStore。")
        end
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

return LeaderboardService
