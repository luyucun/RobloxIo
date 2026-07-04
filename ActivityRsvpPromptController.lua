--[[
Script: ActivityRsvpPromptController
File: ActivityRsvpPromptController.lua
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/ActivityRsvpPromptController
Purpose: Opens the Roblox system RSVP prompt for the configured Experience Event.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

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
        "[ActivityRsvpPromptController] Missing shared module %s",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local ActivityRsvpPromptController = {}

ActivityRsvpPromptController._localPlayer = nil
ActivityRsvpPromptController._promptActivityRsvpEvent = nil
ActivityRsvpPromptController._activityRsvpPromptStartedEvent = nil
ActivityRsvpPromptController._activityRsvpPromptResultEvent = nil
ActivityRsvpPromptController._activeRequestId = ""
ActivityRsvpPromptController._activeEventId = ""
ActivityRsvpPromptController._didPromptThisSession = false
ActivityRsvpPromptController._isPrompting = false
ActivityRsvpPromptController._initialized = false

local function normalizeEventId(value)
    local eventId = tostring(value or "")
    eventId = string.gsub(eventId, "%s+", "")
    return eventId
end

local function enumName(value)
    if typeof(value) == "EnumItem" then
        return value.Name
    end
    return tostring(value or "")
end

function ActivityRsvpPromptController:_bindRemoteEvents()
    local eventsRoot = ReplicatedStorage:FindFirstChild(RemoteNames.RootFolder)
        or ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    if not eventsRoot then
        warn("[ActivityRsvpPromptController] Missing ReplicatedStorage/Events; RSVP prompt disabled.")
        return false
    end

    local systemEvents = eventsRoot:FindFirstChild(RemoteNames.SystemEventsFolder)
        or eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEvents then
        warn("[ActivityRsvpPromptController] Missing ReplicatedStorage/Events/SystemEvents; RSVP prompt disabled.")
        return false
    end

    self._promptActivityRsvpEvent = systemEvents:FindFirstChild(RemoteNames.System.PromptActivityRsvp)
        or systemEvents:WaitForChild(RemoteNames.System.PromptActivityRsvp, 10)
    self._activityRsvpPromptStartedEvent = systemEvents:FindFirstChild(RemoteNames.System.ActivityRsvpPromptStarted)
        or systemEvents:WaitForChild(RemoteNames.System.ActivityRsvpPromptStarted, 10)
    self._activityRsvpPromptResultEvent = systemEvents:FindFirstChild(RemoteNames.System.ActivityRsvpPromptResult)
        or systemEvents:WaitForChild(RemoteNames.System.ActivityRsvpPromptResult, 10)

    if not (self._promptActivityRsvpEvent and self._activityRsvpPromptStartedEvent and self._activityRsvpPromptResultEvent) then
        warn("[ActivityRsvpPromptController] RSVP prompt remotes are incomplete.")
        return false
    end

    return true
end

function ActivityRsvpPromptController:_reportPromptStarted(currentStatus, statusError)
    if self._activityRsvpPromptStartedEvent and self._activeRequestId ~= "" and self._activeEventId ~= "" then
        self._activityRsvpPromptStartedEvent:FireServer({
            requestId = self._activeRequestId,
            eventId = self._activeEventId,
            currentStatus = tostring(currentStatus or ""),
            statusError = tostring(statusError or ""),
            timestamp = os.clock(),
        })
    end
end

function ActivityRsvpPromptController:_reportPromptResult(success, result, fields)
    local requestId = tostring(self._activeRequestId or "")
    local eventId = tostring(self._activeEventId or "")
    if requestId == "" or eventId == "" then
        return
    end

    local payload = {
        requestId = requestId,
        eventId = eventId,
        success = success == true,
        result = tostring(result or ""),
        timestamp = os.clock(),
    }
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            payload[key] = value
        end
    end

    if self._activityRsvpPromptResultEvent then
        self._activityRsvpPromptResultEvent:FireServer(payload)
    end
end

function ActivityRsvpPromptController:_finishPrompt()
    self._activeRequestId = ""
    self._activeEventId = ""
    self._isPrompting = false
end

function ActivityRsvpPromptController:_promptActivityRsvp(requestId, eventId)
    if self._didPromptThisSession or self._isPrompting then
        return
    end

    local resolvedRequestId = tostring(requestId or "")
    local resolvedEventId = normalizeEventId(eventId)
    if resolvedRequestId == "" or resolvedEventId == "" then
        return
    end

    self._isPrompting = true
    self._didPromptThisSession = true
    self._activeRequestId = resolvedRequestId
    self._activeEventId = resolvedEventId

    task.spawn(function()
        local statusOk, currentStatusOrError = pcall(function()
            return SocialService:GetEventRsvpStatusAsync(resolvedEventId)
        end)
        local currentStatus = statusOk and enumName(currentStatusOrError) or ""
        local statusError = statusOk and "" or tostring(currentStatusOrError or "")

        if currentStatus == "Going" then
            self:_reportPromptResult(true, "AlreadyGoing", {
                currentStatus = currentStatus,
                skipped = true,
            })
            self:_finishPrompt()
            return
        end

        self:_reportPromptStarted(currentStatus, statusError)

        local promptOk, promptResultOrError = pcall(function()
            return SocialService:PromptRsvpToEventAsync(resolvedEventId)
        end)
        if promptOk then
            self:_reportPromptResult(true, enumName(promptResultOrError), {
                previousStatus = currentStatus,
            })
        else
            self:_reportPromptResult(false, "Failed", {
                previousStatus = currentStatus,
                error = tostring(promptResultOrError or ""),
            })
            warn(string.format(
                "[ActivityRsvpPromptController] PromptRsvpToEventAsync failed eventId=%s err=%s",
                resolvedEventId,
                tostring(promptResultOrError)
            ))
        end

        self:_finishPrompt()
    end)
end

function ActivityRsvpPromptController:_handlePromptRequest(payload)
    if type(payload) ~= "table" or self._didPromptThisSession then
        return
    end

    local requestId = tostring(payload.requestId or "")
    local eventId = normalizeEventId(payload.eventId)
    if requestId == "" or eventId == "" then
        return
    end

    self:_promptActivityRsvp(requestId, eventId)
end

function ActivityRsvpPromptController:Init(dependencies)
    if self._initialized then
        return
    end
    self._initialized = true

    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._activeRequestId = ""
    self._activeEventId = ""
    self._didPromptThisSession = false
    self._isPrompting = false

    if not self:_bindRemoteEvents() then
        return
    end

    self._promptActivityRsvpEvent.OnClientEvent:Connect(function(payload)
        self:_handlePromptRequest(payload)
    end)
end

return ActivityRsvpPromptController
