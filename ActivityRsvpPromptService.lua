--[[
Script: ActivityRsvpPromptService
File: ActivityRsvpPromptService.lua
Type: ModuleScript
Studio path: ServerScriptService/Services/ActivityRsvpPromptService
Purpose: Requests the Roblox system RSVP prompt for the configured Experience Event.
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
        "[ActivityRsvpPromptService] Missing shared module %s",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local ActivityRsvpPromptService = {}

ActivityRsvpPromptService._remoteEventService = nil
ActivityRsvpPromptService._gameAnalyticsService = nil
ActivityRsvpPromptService._promptActivityRsvpEvent = nil
ActivityRsvpPromptService._activityRsvpPromptStartedEvent = nil
ActivityRsvpPromptService._activityRsvpPromptResultEvent = nil
ActivityRsvpPromptService._pendingRequestIdByUserId = {}
ActivityRsvpPromptService._startedRequestIdByUserId = {}
ActivityRsvpPromptService._scheduleSerialByUserId = {}
ActivityRsvpPromptService._promptedThisSessionByUserId = {}

local function asNonNegativeInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function normalizeEventId(value)
    local eventId = tostring(value or "")
    eventId = string.gsub(eventId, "%s+", "")
    return eventId
end

local function getPlayerUserId(player)
    return player and player.UserId or 0
end

local function copyFields(fields)
    local result = {}
    if type(fields) ~= "table" then
        return result
    end
    for key, value in pairs(fields) do
        result[key] = value
    end
    return result
end

function ActivityRsvpPromptService:_getConfig()
    return GameConfig.ACTIVITY_RSVP_PROMPT or {}
end

function ActivityRsvpPromptService:_getEventId()
    return normalizeEventId(self:_getConfig().EventId)
end

function ActivityRsvpPromptService:_buildRequestId(player)
    return string.format(
        "ActivityRsvp:%d:%d:%d",
        asNonNegativeInteger(getPlayerUserId(player)),
        asNonNegativeInteger(os.time()),
        asNonNegativeInteger(math.floor(os.clock() * 1000))
    )
end

function ActivityRsvpPromptService:_trackCustom(player, eventName, value, fields)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackCustom and player and player.Parent) then
        return false
    end

    local analyticsFields = copyFields(fields)
    analyticsFields.source = tostring(analyticsFields.source or "activity_rsvp_prompt")
    analyticsFields.eventId = tostring(analyticsFields.eventId or self:_getEventId())
    return self._gameAnalyticsService:TrackCustom(player, eventName, value or 1, analyticsFields)
end

function ActivityRsvpPromptService:_shouldPromptPlayer(player)
    if not (player and player.Parent) then
        return false
    end

    local config = self:_getConfig()
    if config.Enabled == false then
        return false
    end

    if self:_getEventId() == "" then
        return false
    end

    local userId = getPlayerUserId(player)
    if self._promptedThisSessionByUserId[userId] == true then
        return false
    end

    return self._pendingRequestIdByUserId[userId] == nil
end

function ActivityRsvpPromptService:_sendPromptRequest(player)
    if not (self._promptActivityRsvpEvent and self:_shouldPromptPlayer(player)) then
        return false
    end

    local userId = getPlayerUserId(player)
    local requestId = self:_buildRequestId(player)
    self._pendingRequestIdByUserId[userId] = requestId
    self._startedRequestIdByUserId[userId] = nil
    self._promptedThisSessionByUserId[userId] = true

    self._promptActivityRsvpEvent:FireClient(player, {
        requestId = requestId,
        eventId = self:_getEventId(),
        timestamp = os.clock(),
    })
    return true
end

function ActivityRsvpPromptService:_schedulePrompt(player)
    if not (player and player.Parent) then
        return
    end

    local userId = getPlayerUserId(player)
    self._scheduleSerialByUserId[userId] = asNonNegativeInteger(self._scheduleSerialByUserId[userId]) + 1
    local serial = self._scheduleSerialByUserId[userId]
    local delaySeconds = math.max(0, tonumber(self:_getConfig().DelaySeconds) or 90)

    task.spawn(function()
        if delaySeconds > 0 then
            task.wait(delaySeconds)
        end

        if serial ~= self._scheduleSerialByUserId[userId] then
            return
        end
        self:_sendPromptRequest(player)
    end)
end

function ActivityRsvpPromptService:_isValidPromptPayload(player, payload)
    if not (player and player.Parent and type(payload) == "table") then
        return false, ""
    end

    local requestId = tostring(payload.requestId or "")
    if requestId == "" then
        return false, ""
    end

    local eventId = normalizeEventId(payload.eventId)
    if eventId ~= self:_getEventId() then
        return false, requestId
    end

    local userId = getPlayerUserId(player)
    local pendingRequestId = tostring(self._pendingRequestIdByUserId[userId] or "")
    local startedRequestId = tostring(self._startedRequestIdByUserId[userId] or "")
    return requestId == pendingRequestId or requestId == startedRequestId, requestId
end

function ActivityRsvpPromptService:_handlePromptStarted(player, payload)
    local isValid, requestId = self:_isValidPromptPayload(player, payload)
    if not isValid then
        return
    end

    local userId = getPlayerUserId(player)
    self._startedRequestIdByUserId[userId] = requestId
    self:_trackCustom(player, "ActivityRsvpPromptStarted", 1, {
        requestId = requestId,
        currentStatus = tostring(payload.currentStatus or ""),
        statusError = tostring(payload.statusError or ""),
    })
end

function ActivityRsvpPromptService:_handlePromptResult(player, payload)
    local isValid, requestId = self:_isValidPromptPayload(player, payload)
    if not isValid then
        return
    end

    local userId = getPlayerUserId(player)
    self._pendingRequestIdByUserId[userId] = nil
    self._startedRequestIdByUserId[userId] = nil

    local success = type(payload) == "table" and payload.success == true
    self:_trackCustom(player, "ActivityRsvpPromptResult", success and 1 or 0, {
        requestId = requestId,
        result = tostring(payload.result or ""),
        currentStatus = tostring(payload.currentStatus or ""),
        previousStatus = tostring(payload.previousStatus or ""),
        error = tostring(payload.error or ""),
        skipped = payload.skipped == true,
    })
end

function ActivityRsvpPromptService:OnPlayerAdded(player)
    self:_schedulePrompt(player)
end

function ActivityRsvpPromptService:OnPlayerRemoving(player)
    if not player then
        return
    end

    local userId = getPlayerUserId(player)
    self._pendingRequestIdByUserId[userId] = nil
    self._startedRequestIdByUserId[userId] = nil
    self._scheduleSerialByUserId[userId] = nil
    self._promptedThisSessionByUserId[userId] = nil
end

function ActivityRsvpPromptService:Init(dependencies)
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or nil
    self._pendingRequestIdByUserId = {}
    self._startedRequestIdByUserId = {}
    self._scheduleSerialByUserId = {}
    self._promptedThisSessionByUserId = {}

    self._promptActivityRsvpEvent = self._remoteEventService and self._remoteEventService:GetEvent("PromptActivityRsvp") or nil
    self._activityRsvpPromptStartedEvent = self._remoteEventService and self._remoteEventService:GetEvent("ActivityRsvpPromptStarted") or nil
    self._activityRsvpPromptResultEvent = self._remoteEventService and self._remoteEventService:GetEvent("ActivityRsvpPromptResult") or nil

    if self._activityRsvpPromptStartedEvent then
        self._activityRsvpPromptStartedEvent.OnServerEvent:Connect(function(player, payload)
            self:_handlePromptStarted(player, payload)
        end)
    end

    if self._activityRsvpPromptResultEvent then
        self._activityRsvpPromptResultEvent.OnServerEvent:Connect(function(player, payload)
            self:_handlePromptResult(player, payload)
        end)
    end
end

return ActivityRsvpPromptService
