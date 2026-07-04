--[[
脚本名字: FavoritePlacePromptService
脚本文件: FavoritePlacePromptService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/FavoritePlacePromptService
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
        "[FavoritePlacePromptService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local FavoritePlacePromptService = {}

FavoritePlacePromptService._remoteEventService = nil
FavoritePlacePromptService._playerStateService = nil
FavoritePlacePromptService._rebirthService = nil
FavoritePlacePromptService._promptFavoritePlaceEvent = nil
FavoritePlacePromptService._favoritePlacePromptStartedEvent = nil
FavoritePlacePromptService._favoritePlacePromptResultEvent = nil
FavoritePlacePromptService._pendingRequestIdByUserId = {}
FavoritePlacePromptService._startedRequestIdByUserId = {}
FavoritePlacePromptService._scheduleSerialByUserId = {}

local function asNonNegativeInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function getUtcDayKey(timestamp)
    return math.floor(asNonNegativeInteger(timestamp) / 86400)
end

local function getPlayerUserId(player)
    return player and player.UserId or 0
end

function FavoritePlacePromptService:_getConfig()
    return GameConfig.FAVORITE_PROMPT or {}
end

function FavoritePlacePromptService:_isDebugEnabled()
    return self:_getConfig().DebugEnabled == true
end

function FavoritePlacePromptService:_debugLog(message, ...)
    if not self:_isDebugEnabled() then
        return
    end

    local ok, formatted = pcall(string.format, tostring(message or ""), ...)
    print("[FavoritePlacePromptService] " .. (ok and formatted or tostring(message or "")))
end

function FavoritePlacePromptService:_buildRequestId(player)
    return string.format(
        "FavoritePlace:%d:%d:%d",
        asNonNegativeInteger(getPlayerUserId(player)),
        asNonNegativeInteger(os.time()),
        asNonNegativeInteger(math.floor(os.clock() * 1000))
    )
end

function FavoritePlacePromptService:_getFavoritePromptState(player)
    if not (self._playerStateService and player) then
        return nil
    end

    if self._playerStateService.GetFavoritePromptState then
        return self._playerStateService:GetFavoritePromptState(player)
    end

    local state = self._playerStateService.GetState and self._playerStateService:GetState(player) or nil
    if type(state) ~= "table" then
        return nil
    end
    if type(state.FavoritePromptState) ~= "table" then
        state.FavoritePromptState = {
            HasFavorited = false,
            PromptedAt = 0,
            LastPromptUtcDay = 0,
            LastPromptResult = "",
            LastResultAt = 0,
        }
    end
    return state.FavoritePromptState
end

function FavoritePlacePromptService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function FavoritePlacePromptService:_flushPlayer(player)
    if not self._rebirthService then
        return false
    end

    local ok, saved = pcall(function()
        if self._rebirthService.SavePlayerNow then
            return self._rebirthService:SavePlayerNow(player)
        end
        if self._rebirthService.FlushPlayer then
            return self._rebirthService:FlushPlayer(player)
        end
        return false
    end)
    if not ok then
        warn("[FavoritePlacePromptService] SavePlayerNow error: " .. tostring(saved))
        return false
    end
    return saved == true
end

function FavoritePlacePromptService:_isPlayerDataReady(player)
    if not (player and player.Parent) then
        return false
    end

    if self._rebirthService and self._rebirthService.IsPlayerLoaded then
        return self._rebirthService:IsPlayerLoaded(player) == true
    end

    return true
end

function FavoritePlacePromptService:_waitForPlayerData(player)
    local deadline = os.clock() + 60
    while player and player.Parent do
        if self:_isPlayerDataReady(player) then
            return true
        end
        if os.clock() >= deadline then
            return false
        end
        task.wait(0.5)
    end
    return false
end

function FavoritePlacePromptService:_shouldPromptPlayer(player)
    if not (player and player.Parent) then
        self:_debugLog("skip prompt: player missing")
        return false
    end

    local config = self:_getConfig()
    if config.Enabled == false then
        self:_debugLog("skip prompt userId=%d reason=disabled", getPlayerUserId(player))
        return false
    end

    if asNonNegativeInteger(game.PlaceId) <= 0 then
        self:_debugLog("skip prompt userId=%d reason=invalidPlaceId placeId=%s", getPlayerUserId(player), tostring(game.PlaceId))
        return false
    end

    local favoritePromptState = self:_getFavoritePromptState(player)
    if type(favoritePromptState) ~= "table" then
        self:_debugLog("skip prompt userId=%d reason=missingState", getPlayerUserId(player))
        return false
    end

    if favoritePromptState.HasFavorited == true then
        self:_debugLog("skip prompt userId=%d reason=hasFavorited", getPlayerUserId(player))
        return false
    end

    local lastPromptUtcDay = asNonNegativeInteger(favoritePromptState.LastPromptUtcDay)
    local currentUtcDay = getUtcDayKey(os.time())
    local shouldPrompt = lastPromptUtcDay < currentUtcDay
    self:_debugLog(
        "shouldPrompt userId=%d hasFavorited=%s lastPromptUtcDay=%d currentUtcDay=%d result=%s",
        getPlayerUserId(player),
        tostring(favoritePromptState.HasFavorited == true),
        lastPromptUtcDay,
        currentUtcDay,
        tostring(shouldPrompt)
    )
    return shouldPrompt
end

function FavoritePlacePromptService:_sendPromptRequest(player)
    if not (self._promptFavoritePlaceEvent and self:_shouldPromptPlayer(player)) then
        return false
    end

    local userId = getPlayerUserId(player)
    local requestId = self:_buildRequestId(player)
    self._pendingRequestIdByUserId[userId] = requestId
    self._startedRequestIdByUserId[userId] = nil

    self:_debugLog("send prompt userId=%d requestId=%s placeId=%d", userId, requestId, asNonNegativeInteger(game.PlaceId))
    self._promptFavoritePlaceEvent:FireClient(player, {
        requestId = requestId,
        placeId = asNonNegativeInteger(game.PlaceId),
        timestamp = os.clock(),
    })
    return true
end

function FavoritePlacePromptService:_schedulePrompt(player)
    if not (player and player.Parent) then
        return
    end

    local userId = getPlayerUserId(player)
    self._scheduleSerialByUserId[userId] = asNonNegativeInteger(self._scheduleSerialByUserId[userId]) + 1
    local serial = self._scheduleSerialByUserId[userId]

    task.spawn(function()
        if not self:_waitForPlayerData(player) then
            return
        end

        if serial ~= self._scheduleSerialByUserId[userId] or not self:_shouldPromptPlayer(player) then
            return
        end

        local delaySeconds = math.max(0, tonumber(self:_getConfig().DelaySeconds) or 300)
        if delaySeconds > 0 then
            task.wait(delaySeconds)
        end

        if serial ~= self._scheduleSerialByUserId[userId] then
            return
        end
        self:_sendPromptRequest(player)
    end)
end

function FavoritePlacePromptService:_handlePromptStarted(player, payload)
    if not (player and player.Parent) then
        return
    end

    local requestId = type(payload) == "table" and tostring(payload.requestId or "") or ""
    local userId = getPlayerUserId(player)
    if requestId == "" or self._pendingRequestIdByUserId[userId] ~= requestId then
        self:_debugLog("ignore started userId=%d requestId=%s pending=%s", userId, requestId, tostring(self._pendingRequestIdByUserId[userId] or ""))
        return
    end

    local favoritePromptState = self:_getFavoritePromptState(player)
    if type(favoritePromptState) ~= "table" then
        self:_debugLog("ignore started userId=%d requestId=%s reason=missingState", userId, requestId)
        return
    end

    local nowTimestamp = asNonNegativeInteger(os.time())
    favoritePromptState.PromptedAt = nowTimestamp
    favoritePromptState.LastPromptUtcDay = getUtcDayKey(nowTimestamp)
    self._startedRequestIdByUserId[userId] = requestId
    self:_markDirty(player)
    self:_debugLog("started prompt userId=%d requestId=%s lastPromptUtcDay=%d", userId, requestId, favoritePromptState.LastPromptUtcDay)
end

function FavoritePlacePromptService:_handlePromptResult(player, payload)
    if not (player and player.Parent) then
        return
    end

    local requestId = type(payload) == "table" and tostring(payload.requestId or "") or ""
    local result = type(payload) == "table" and tostring(payload.result or "") or ""
    local userId = getPlayerUserId(player)
    local pendingRequestId = tostring(self._pendingRequestIdByUserId[userId] or "")
    local startedRequestId = tostring(self._startedRequestIdByUserId[userId] or "")
    if requestId == "" or (requestId ~= pendingRequestId and requestId ~= startedRequestId) then
        self:_debugLog(
            "ignore result userId=%d requestId=%s pending=%s started=%s result=%s",
            userId,
            requestId,
            pendingRequestId,
            startedRequestId,
            result
        )
        return
    end

    local favoritePromptState = self:_getFavoritePromptState(player)
    if type(favoritePromptState) == "table" then
        local nowTimestamp = asNonNegativeInteger(os.time())
        local previousHasFavorited = favoritePromptState.HasFavorited == true
        if favoritePromptState.PromptedAt <= 0 then
            favoritePromptState.PromptedAt = nowTimestamp
        end
        if favoritePromptState.LastPromptUtcDay <= 0 then
            favoritePromptState.LastPromptUtcDay = getUtcDayKey(nowTimestamp)
        end
        favoritePromptState.LastPromptResult = result
        favoritePromptState.LastResultAt = nowTimestamp
        if result == "Success" or result == "AlreadyFavorite" then
            favoritePromptState.HasFavorited = true
        end
        self:_markDirty(player)
        local flushSucceeded = false
        if favoritePromptState.HasFavorited == true then
            flushSucceeded = self:_flushPlayer(player)
        end
        self:_debugLog(
            "result userId=%d requestId=%s result=%s previousHasFavorited=%s hasFavorited=%s flushed=%s",
            userId,
            requestId,
            result,
            tostring(previousHasFavorited),
            tostring(favoritePromptState.HasFavorited == true),
            tostring(flushSucceeded)
        )
    else
        self:_debugLog("ignore result userId=%d requestId=%s reason=missingState", userId, requestId)
    end

    self._pendingRequestIdByUserId[userId] = nil
    self._startedRequestIdByUserId[userId] = nil
end

function FavoritePlacePromptService:OnPlayerAdded(player)
    self:_schedulePrompt(player)
end

function FavoritePlacePromptService:OnPlayerReady(player)
    self:OnPlayerAdded(player)
end

function FavoritePlacePromptService:OnPlayerRemoving(player)
    if not player then
        return
    end

    local userId = getPlayerUserId(player)
    self._pendingRequestIdByUserId[userId] = nil
    self._startedRequestIdByUserId[userId] = nil
    self._scheduleSerialByUserId[userId] = nil
end

function FavoritePlacePromptService:Init(dependencies)
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._pendingRequestIdByUserId = {}
    self._startedRequestIdByUserId = {}
    self._scheduleSerialByUserId = {}

    self._promptFavoritePlaceEvent = self._remoteEventService and self._remoteEventService:GetEvent("PromptFavoritePlace") or nil
    self._favoritePlacePromptStartedEvent = self._remoteEventService and self._remoteEventService:GetEvent("FavoritePlacePromptStarted") or nil
    self._favoritePlacePromptResultEvent = self._remoteEventService and self._remoteEventService:GetEvent("FavoritePlacePromptResult") or nil

    if self._favoritePlacePromptStartedEvent then
        self._favoritePlacePromptStartedEvent.OnServerEvent:Connect(function(player, payload)
            self:_handlePromptStarted(player, payload)
        end)
    end

    if self._favoritePlacePromptResultEvent then
        self._favoritePlacePromptResultEvent.OnServerEvent:Connect(function(player, payload)
            self:_handlePromptResult(player, payload)
        end)
    end
end

return FavoritePlacePromptService
