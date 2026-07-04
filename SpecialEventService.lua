--[[
脚本名字: SpecialEventService
脚本文件: SpecialEventService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/SpecialEventService
说明: V2.8 特殊事件服务端排期、同步与事件 Boss 刷新。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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
SpecialEventService._bossService = nil
SpecialEventService._playerStateService = nil
SpecialEventService._healthService = nil
SpecialEventService._activeEffect = nil
SpecialEventService._nextPeriodicDiamondClock = 0
SpecialEventService._nextShieldRefreshClock = 0

local function cloneEventConfig(eventConfig, startClock)
    if not eventConfig then
        return nil
    end

    local durationSeconds = math.max(0, tonumber(eventConfig.DurationSeconds) or 0)

    return {
        id = eventConfig.Id,
        name = eventConfig.Name,
        scenePath = eventConfig.ScenePath,
        iconImage = eventConfig.IconImage,
        effectDescription = eventConfig.EffectDescription,
        textLabelName = eventConfig.TextLabelName,
        durationSeconds = durationSeconds,
        bossSourceId = eventConfig.BossSourceId,
        bossDefinitionId = eventConfig.BossDefinitionId,
        bossCount = math.max(0, math.floor(tonumber(eventConfig.BossCount) or 0)),
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

function SpecialEventService:_spawnBossesForEvent(scheduledEvent)
    if not (self._bossService and type(self._bossService.SpawnBossesForEvent) == "function") then
        return 0
    end

    return self._bossService:SpawnBossesForEvent({
        EventId = scheduledEvent and scheduledEvent.id or nil,
        BossSourceId = scheduledEvent and scheduledEvent.bossSourceId or nil,
        BossDefinitionId = scheduledEvent and scheduledEvent.bossDefinitionId or nil,
        BossCount = scheduledEvent and scheduledEvent.bossCount or 0,
    })
end

function SpecialEventService:_getEventEffect(eventId)
    if SpecialEventConfig.GetEventEffect then
        return SpecialEventConfig.GetEventEffect(eventId)
    end
    return nil
end

function SpecialEventService:_grantEventShield(player)
    local activeEvent = self._activeEvent
    local effect = self._activeEffect
    if not (activeEvent and effect and effect.ShieldUntilEventEnd == true) then
        return false
    end
    if not (self._healthService and player and player.Parent) then
        return false
    end

    local endClock = tonumber(activeEvent.endClock) or 0
    if endClock <= os.clock() then
        return false
    end
    if self._healthService.EnsureShieldUntil then
        return self._healthService:EnsureShieldUntil(player, endClock, "SpecialEvent")
    end
    if self._healthService.GrantShield then
        return self._healthService:GrantShield(player, math.ceil(endClock - os.clock()), "SpecialEvent")
    end
    return false
end

function SpecialEventService:_grantEventShieldForAll()
    for _, player in ipairs(Players:GetPlayers()) do
        self:_grantEventShield(player)
    end
end

local function findWorkspacePath(pathSegments)
    if type(pathSegments) ~= "table" then
        return nil
    end

    local current = Workspace
    for _, segment in ipairs(pathSegments) do
        local childName = tostring(segment or "")
        if childName == "" then
            return nil
        end
        current = current and current:FindFirstChild(childName)
        if not current then
            return nil
        end
    end
    return current
end

function SpecialEventService:_setEventBattlePartTransparency(effect, isActive)
    if type(effect) ~= "table" then
        return false
    end

    local part = findWorkspacePath(effect.BattlePartTransparencyPath)
    if not (part and part:IsA("BasePart")) then
        return false
    end

    local targetTransparency = if isActive == true
        then effect.BattlePartActiveTransparency
        else effect.BattlePartInactiveTransparency
    local transparency = tonumber(targetTransparency)
    if transparency == nil then
        transparency = if isActive == true then 1 else 0
    end

    part.Transparency = math.clamp(transparency, 0, 1)
    return true
end

function SpecialEventService:_applyActiveEffect(activeEvent)
    local effect = self:_getEventEffect(activeEvent and activeEvent.id)
    self._activeEffect = effect
    local nowClock = os.clock()
    self._nextPeriodicDiamondClock = nowClock + math.max(1, math.floor(tonumber(effect and effect.PeriodicDiamondIntervalSeconds) or 0))
    self._nextShieldRefreshClock = 0
    self:_setEventBattlePartTransparency(effect, true)

    if self._playerStateService and self._playerStateService.RefreshSpecialEventEffectsForAll then
        self._playerStateService:RefreshSpecialEventEffectsForAll()
    end

    if effect and effect.ShieldUntilEventEnd == true then
        self:_grantEventShieldForAll()
        self._nextShieldRefreshClock = nowClock + 1
    end
end

function SpecialEventService:_clearActiveEffect()
    local effect = self._activeEffect
    self:_setEventBattlePartTransparency(effect, false)
    self._activeEffect = nil
    self._nextPeriodicDiamondClock = 0
    self._nextShieldRefreshClock = 0

    if self._playerStateService and self._playerStateService.RefreshSpecialEventEffectsForAll then
        self._playerStateService:RefreshSpecialEventEffectsForAll()
    end
end

function SpecialEventService:GetActiveEffect()
    if type(self._activeEffect) ~= "table" then
        return nil
    end
    local result = {}
    for key, value in pairs(self._activeEffect) do
        result[key] = value
    end
    return result
end

function SpecialEventService:GetActiveEventVisualInfo()
    local activeEvent = self._activeEvent
    if type(activeEvent) ~= "table" then
        return nil
    end

    if os.clock() >= (tonumber(activeEvent.endClock) or 0) then
        return nil
    end

    return {
        id = activeEvent.id,
        name = activeEvent.name,
        textLabelName = activeEvent.textLabelName,
        iconImage = activeEvent.iconImage,
        effectDescription = activeEvent.effectDescription,
        sequenceIndex = activeEvent.sequenceIndex,
        endClock = activeEvent.endClock,
    }
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
    self:_applyActiveEffect(nextEvent)
    self._nextStartClock = nowClock + self:_getSpawnIntervalSeconds()
    self:_ensureFutureEvents()
    self:_spawnBossesForEvent(nextEvent)
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
    self:_clearActiveEffect()
    self:BroadcastState()
    return true
end

function SpecialEventService:_step()
    if self:_clearExpiredActiveEvent() then
        return
    end
    if self._activeEvent then
        local nowClock = os.clock()
        local effect = self._activeEffect
        local diamondInterval = math.max(1, math.floor(tonumber(effect and effect.PeriodicDiamondIntervalSeconds) or 0))
        local diamondAmount = math.max(0, math.floor(tonumber(effect and effect.PeriodicDiamondAmount) or 0))
        if diamondAmount > 0 and effect and self._playerStateService and nowClock >= (self._nextPeriodicDiamondClock or 0) then
            self._nextPeriodicDiamondClock = nowClock + diamondInterval
            for _, player in ipairs(Players:GetPlayers()) do
                if player and player.Parent then
                    self._playerStateService:AddDiamonds(player, diamondAmount, {
                        source = "special_event",
                        productGroup = "special_event",
                        itemSku = "SpecialEventPeriodicDiamond",
                    })
                end
            end
        end
        if effect and effect.ShieldUntilEventEnd == true and nowClock >= (self._nextShieldRefreshClock or 0) then
            self._nextShieldRefreshClock = nowClock + 1
            self:_grantEventShieldForAll()
        end
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
    if self._activeEvent then
        self._activeEvent = nil
        self:_clearActiveEffect()
    end
    local activeEvent = cloneEventConfig(eventConfig, nowClock)
    if not activeEvent then
        return false, "EventInvalid"
    end

    self._sequenceIndex = self._sequenceIndex + 1
    activeEvent.sequenceIndex = self._sequenceIndex
    self._activeEvent = activeEvent
    self:_applyActiveEffect(activeEvent)
    self:_rememberEvent(eventConfig.Id)

    self._futureEvents = {}
    self._nextStartClock = nowClock + self:_getSpawnIntervalSeconds()
    self:_ensureFutureEvents()
    self:_spawnBossesForEvent(activeEvent)
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
        if self._playerStateService and self._playerStateService.RefreshSpecialEventEffectForPlayer then
            self._playerStateService:RefreshSpecialEventEffectForPlayer(player)
        end
        self:_grantEventShield(player)
    end)
end

function SpecialEventService:Init(dependencies)
    self._specialEventSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("SpecialEventSync") or nil
    self._requestSpecialEventSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestSpecialEventSync") or nil
    self._bossService = dependencies and dependencies.BossService or nil
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._startedAtClock = os.clock()
    self._nextStartClock = self._startedAtClock + self:_getSpawnIntervalSeconds()
    self._activeEvent = nil
    self._futureEvents = {}
    self._recentEventIds = {}
    self._sequenceIndex = 0
    self._activeEffect = nil
    self._nextPeriodicDiamondClock = 0
    self._nextShieldRefreshClock = 0
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
