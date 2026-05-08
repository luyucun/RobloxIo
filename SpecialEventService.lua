--[[
脚本名字: SpecialEventService
脚本文件: SpecialEventService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/SpecialEventService
说明: V2.2 特殊事件服务端排期与同步；本版本不生成 Boss，只同步事件表现状态。
]]

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
        "[SpecialEventService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local SpecialEventConfig = requireSharedModule("SpecialEventConfig")

local SpecialEventService = {}

SpecialEventService._specialEventSyncEvent = nil
SpecialEventService._requestSpecialEventSyncEvent = nil
SpecialEventService._requestConnection = nil
SpecialEventService._heartbeatConnection = nil
SpecialEventService._startedAtClock = 0
SpecialEventService._nextStartClock = 0
SpecialEventService._activeEvent = nil
SpecialEventService._futureEvents = {}
SpecialEventService._recentEventIds = {}
SpecialEventService._sequenceIndex = 0

local function cloneEventConfig(eventConfig, startClock)
    if not eventConfig then
        return nil
    end

    local durationSeconds = math.max(0, tonumber(eventConfig.DurationSeconds) or 0)

    return {
        id = eventConfig.Id,
        name = eventConfig.Name,
        scenePath = eventConfig.ScenePath,
        textLabelName = eventConfig.TextLabelName,
        durationSeconds = durationSeconds,
        startClock = startClock,
        endClock = startClock + durationSeconds,
    }
end

local function hasRecentEvent(recentEventIds, eventId)
    for _, recentEventId in ipairs(recentEventIds) do
        if tonumber(recentEventId) == tonumber(eventId) then
            return true
        end
    end
    return false
end

function SpecialEventService:_getSpawnIntervalSeconds()
    local interval = tonumber(SpecialEventConfig.SpawnIntervalSeconds) or 600
    return math.max(1, interval)
end

function SpecialEventService:_pickWeightedEvent()
    local allEvents = SpecialEventConfig.GetAllEvents()
    local candidates = {}

    for _, eventConfig in ipairs(allEvents) do
        local weight = math.max(0, tonumber(eventConfig.Weight) or 0)
        if weight > 0 and not hasRecentEvent(self._recentEventIds, eventConfig.Id) then
            table.insert(candidates, eventConfig)
        end
    end

    if #candidates == 0 then
        for _, eventConfig in ipairs(allEvents) do
            if math.max(0, tonumber(eventConfig.Weight) or 0) > 0 then
                table.insert(candidates, eventConfig)
            end
        end
    end

    local totalWeight = 0
    for _, eventConfig in ipairs(candidates) do
        totalWeight = totalWeight + math.max(0, tonumber(eventConfig.Weight) or 0)
    end

    if totalWeight <= 0 then
        return candidates[1]
    end

    local roll = math.random() * totalWeight
    local cumulativeWeight = 0
    for _, eventConfig in ipairs(candidates) do
        cumulativeWeight = cumulativeWeight + math.max(0, tonumber(eventConfig.Weight) or 0)
        if roll <= cumulativeWeight then
            return eventConfig
        end
    end

    return candidates[#candidates]
end

function SpecialEventService:_rememberEvent(eventId)
    table.insert(self._recentEventIds, 1, eventId)
    local maxRecentCount = math.max(0, math.floor(tonumber(SpecialEventConfig.RecentRepeatBlockCount) or 2))
    while #self._recentEventIds > maxRecentCount do
        table.remove(self._recentEventIds)
    end
end

function SpecialEventService:_buildNextScheduledEvent(startClock)
    local eventConfig = self:_pickWeightedEvent()
    if not eventConfig then
        return nil
    end

    self._sequenceIndex = self._sequenceIndex + 1
    self:_rememberEvent(eventConfig.Id)

    local scheduledEvent = cloneEventConfig(eventConfig, startClock)
    scheduledEvent.sequenceIndex = self._sequenceIndex
    return scheduledEvent
end

function SpecialEventService:_ensureFutureEvents()
    local intervalSeconds = self:_getSpawnIntervalSeconds()
    local targetCount = math.max(0, math.floor(tonumber(SpecialEventConfig.FutureDisplayCount) or 2))
    local nextStartClock = self._nextStartClock
    if self._futureEvents[#self._futureEvents] then
        nextStartClock = self._futureEvents[#self._futureEvents].startClock + intervalSeconds
    end

    while #self._futureEvents < targetCount do
        local scheduledEvent = self:_buildNextScheduledEvent(nextStartClock)
        if not scheduledEvent then
            break
        end
        table.insert(self._futureEvents, scheduledEvent)
        nextStartClock = nextStartClock + intervalSeconds
    end
end

function SpecialEventService:_startNextEvent()
    self:_ensureFutureEvents()

    local nextEvent = table.remove(self._futureEvents, 1)
    if not nextEvent then
        nextEvent = self:_buildNextScheduledEvent(os.clock())
    end

    if not nextEvent then
        return
    end

    local nowClock = os.clock()
    nextEvent.startClock = nowClock
    nextEvent.endClock = nowClock + math.max(0, tonumber(nextEvent.durationSeconds) or 0)
    self._activeEvent = nextEvent
    self._nextStartClock = nowClock + self:_getSpawnIntervalSeconds()
    self:_ensureFutureEvents()
    self:BroadcastState()
end

function SpecialEventService:_clearExpiredActiveEvent()
    if not self._activeEvent then
        return false
    end

    if os.clock() < (tonumber(self._activeEvent.endClock) or 0) then
        return false
    end

    self._activeEvent = nil
    self:BroadcastState()
    return true
end

function SpecialEventService:_step()
    if self:_clearExpiredActiveEvent() then
        return
    end
    if self._activeEvent then
        return
    end
    if os.clock() >= self._nextStartClock then
        self:_startNextEvent()
    end
end

function SpecialEventService:StartEventById(eventId)
    local eventConfig = SpecialEventConfig.GetEvent(eventId)
    if not eventConfig then
        return false, "EventNotFound"
    end

    local nowClock = os.clock()
    local activeEvent = cloneEventConfig(eventConfig, nowClock)
    if not activeEvent then
        return false, "EventInvalid"
    end

    self._sequenceIndex = self._sequenceIndex + 1
    activeEvent.sequenceIndex = self._sequenceIndex
    self._activeEvent = activeEvent
    self:_rememberEvent(eventConfig.Id)

    self._futureEvents = {}
    self._nextStartClock = nowClock + self:_getSpawnIntervalSeconds()
    self:_ensureFutureEvents()
    self:BroadcastState()
    return true, activeEvent
end

function SpecialEventService:BuildPayload()
    self:_ensureFutureEvents()

    return {
        eventType = "Sync",
        serverClock = os.clock(),
        spawnIntervalSeconds = self:_getSpawnIntervalSeconds(),
        activeEvent = self._activeEvent,
        futureEvents = self._futureEvents,
        timestamp = os.clock(),
    }
end

function SpecialEventService:PushState(player)
    if not (player and player.Parent and self._specialEventSyncEvent) then
        return
    end

    self._specialEventSyncEvent:FireClient(player, self:BuildPayload())
end

function SpecialEventService:BroadcastState()
    if not self._specialEventSyncEvent then
        return
    end

    self._specialEventSyncEvent:FireAllClients(self:BuildPayload())
end

function SpecialEventService:OnPlayerAdded(player)
    task.defer(function()
        self:PushState(player)
    end)
end

function SpecialEventService:Init(dependencies)
    self._specialEventSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("SpecialEventSync") or nil
    self._requestSpecialEventSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestSpecialEventSync") or nil
    self._startedAtClock = os.clock()
    self._nextStartClock = self._startedAtClock + self:_getSpawnIntervalSeconds()
    self._activeEvent = nil
    self._futureEvents = {}
    self._recentEventIds = {}
    self._sequenceIndex = 0
    self:_ensureFutureEvents()

    if self._requestConnection then
        self._requestConnection:Disconnect()
        self._requestConnection = nil
    end

    if self._requestSpecialEventSyncEvent then
        self._requestConnection = self._requestSpecialEventSyncEvent.OnServerEvent:Connect(function(player)
            self:PushState(player)
        end)
    end

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)

    for _, player in ipairs(Players:GetPlayers()) do
        self:OnPlayerAdded(player)
    end
end

return SpecialEventService
