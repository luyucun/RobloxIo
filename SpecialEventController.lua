--[[
脚本名字: SpecialEventController
脚本文件: SpecialEventController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/SpecialEventController
说明: V2.2 特殊事件客户端表现；本地复制事件场景并更新场景事件板倒计时。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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
        "[SpecialEventController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local SpecialEventConfig = requireSharedModule("SpecialEventConfig")
local GameConfig = requireSharedModule("GameConfig")

local SpecialEventController = {}

SpecialEventController._connections = {}
SpecialEventController._renderConnection = nil
SpecialEventController._specialEventSyncEvent = nil
SpecialEventController._requestSpecialEventSyncEvent = nil
SpecialEventController._payload = nil
SpecialEventController._serverClockOffset = 0
SpecialEventController._activeClone = nil
SpecialEventController._activeCloneEventId = nil
SpecialEventController._lightingAppliedEventId = nil
SpecialEventController._lightingDefaultFolder = nil
SpecialEventController._lightingDefaultAtmosphere = nil
SpecialEventController._lightingDefaultObbySky = nil
SpecialEventController._lightingEventFolder = nil
SpecialEventController._lightingMovedEventChildren = {}
SpecialEventController._lastBoardUpdateClock = 0
SpecialEventController._perfStats = nil
SpecialEventController._nextPerfLogClock = 0
SpecialEventController._eventDescribeRoot = nil
SpecialEventController._eventDescribeConnections = {}
SpecialEventController._eventDescribeTooltipVisible = false
SpecialEventController._lastEventStartSequenceIndex = nil
SpecialEventController._lastEventStartKey = nil
SpecialEventController._eventStartToken = 0
SpecialEventController._eventStartTween = nil
SpecialEventController._eventStartHideAtClock = 0

local EVENT_START_VISIBLE_SECONDS = 2
local EVENT_START_OPEN_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local EVENT_START_CLOSE_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local EVENT_BOARD_PATHS = {
    { "BattleSenceEventBoard" },
    { "Map2", "BattleSenceEventBoard" },
    { "HomeEventBoard" },
    { "Map2", "HomeEventBoard" },
}

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function countDescendants(instance)
    if not instance then
        return 0
    end

    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    return ok and #descendants or 0
end

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

local function stabilizeSceneInstance(root)
    if not root then
        return
    end

    if root:IsA("BasePart") then
        root.Anchored = true
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
        end
    end
end

local function findOrCreateLightingFolder(name)
    local folder = Lighting:FindFirstChild(name)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = name
    folder.Parent = Lighting
    return folder
end

local function getLightingChild(name)
    return Lighting:FindFirstChild(name)
end

local function formatCountdown(remainingSeconds)
    local totalSeconds = math.max(0, math.ceil(tonumber(remainingSeconds) or 0))
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60
    return string.format("%02d:%02d", minutes, seconds)
end

local function findBoardFrame(pathSegments)
    local current = Workspace
    for _, segment in ipairs(pathSegments) do
        current = current and current:FindFirstChild(segment) or nil
        if not current then
            return nil
        end
    end

    local surfaceGui = current:FindFirstChild("SurfaceGui", true)
    return surfaceGui and surfaceGui:FindFirstChild("Frame", true) or nil
end

local function getBoardFrames()
    local frames = {}
    local seen = {}
    for _, pathSegments in ipairs(EVENT_BOARD_PATHS) do
        local frame = findBoardFrame(pathSegments)
        if frame and not seen[frame] then
            seen[frame] = true
            table.insert(frames, frame)
        end
    end
    return frames
end

local function getMainGui()
    local localPlayer = Players.LocalPlayer
    if not localPlayer then
        return nil
    end

    local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
    return playerGui and playerGui:FindFirstChild("Main") or nil
end

local function findEventEndRoot()
    local mainGui = getMainGui()
    local eventEnd = mainGui and mainGui:FindFirstChild("EventEnd", true) or nil
    if eventEnd and eventEnd:IsA("GuiObject") then
        return eventEnd
    end
    return nil
end

local function findEventDescribeRoot()
    local mainGui = getMainGui()
    local eventDescribe = mainGui and mainGui:FindFirstChild("EventDescribe", true) or nil
    if eventDescribe and eventDescribe:IsA("GuiObject") then
        return eventDescribe
    end
    return nil
end

local function findEventStartRoot()
    local mainGui = getMainGui()
    local eventStart = mainGui and mainGui:FindFirstChild("EventStart", true) or nil
    if eventStart and eventStart:IsA("GuiObject") then
        return eventStart
    end
    return nil
end

local function findTextLabel(frame, labelName)
    local label = frame and frame:FindFirstChild(labelName, true)
    if label and (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox")) then
        return label
    end
    return nil
end

local function isTextObject(instance)
    return instance and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
end

local function setLabel(label, visible, text)
    if not label then
        return
    end

    if label:IsA("GuiObject") then
        label.Visible = visible == true
    end
    if text ~= nil and (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox")) then
        label.Text = tostring(text)
    end
end

local function setGuiVisible(guiObject, visible)
    if guiObject and guiObject:IsA("GuiObject") then
        guiObject.Visible = visible == true
    end
end

local function ensureScale(guiObject)
    if not guiObject then
        return nil
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if not uiScale then
        uiScale = Instance.new("UIScale")
        uiScale.Scale = 1
        uiScale.Parent = guiObject
    end
    return uiScale
end

local function getEventDescribeParts(eventDescribe)
    local info = eventDescribe and eventDescribe:FindFirstChild("Info", true) or nil
    local icon = info and info:FindFirstChild("Icon", true) or nil
    local timeLabel = info and info:FindFirstChild("Time", true) or nil
    local inputTarget = info and info:FindFirstChild("TextButton", true) or nil
    local buffDescription = eventDescribe and eventDescribe:FindFirstChild("EventBuffDes", true) or nil
    local buffInfo = buffDescription and buffDescription:FindFirstChild("Info", true) or nil
    return {
        info = info,
        icon = icon,
        timeLabel = timeLabel,
        inputTarget = inputTarget,
        buffDescription = buffDescription,
        buffInfo = buffInfo,
    }
end

local function getEventLabelName(activeEvent)
    return tostring(activeEvent and activeEvent.textLabelName or "")
end

local function getEventStartKey(activeEvent)
    if type(activeEvent) ~= "table" then
        return ""
    end

    local sequenceIndex = tonumber(activeEvent.sequenceIndex)
    if sequenceIndex then
        return "sequence:" .. tostring(sequenceIndex)
    end

    local eventId = tostring(activeEvent.id or activeEvent.eventId or "")
    local startClock = tonumber(activeEvent.startClock)
    local endClock = tonumber(activeEvent.endClock)
    local labelName = getEventLabelName(activeEvent)
    if eventId ~= "" or startClock or endClock or labelName ~= "" then
        return table.concat({
            "event",
            eventId,
            tostring(math.floor((startClock or 0) * 1000)),
            tostring(math.floor((endClock or 0) * 1000)),
            labelName,
        }, ":")
    end

    return ""
end

local function ensureEventStartLabel(eventStart, labelName)
    local label = findTextLabel(eventStart, labelName)
    if label then
        return label
    end

    if not eventStart or labelName == "" then
        return nil
    end

    local template = nil
    for _, descendant in ipairs(eventStart:GetDescendants()) do
        if descendant:IsA("TextLabel") then
            template = descendant
            break
        end
    end
    if not template then
        return nil
    end

    label = template:Clone()
    label.Name = labelName
    label.Visible = false
    label.Parent = template.Parent
    return label
end

local function isInputInsideGuiObject(guiObject, inputObject)
    if not (guiObject and guiObject:IsA("GuiObject") and inputObject) then
        return false
    end

    local position = inputObject.Position
    if typeof(position) ~= "Vector3" then
        return false
    end

    local absolutePosition = guiObject.AbsolutePosition
    local absoluteSize = guiObject.AbsoluteSize
    return position.X >= absolutePosition.X
        and position.X <= absolutePosition.X + absoluteSize.X
        and position.Y >= absolutePosition.Y
        and position.Y <= absolutePosition.Y + absoluteSize.Y
end

function SpecialEventController:_getServerClock()
    return os.clock() + self._serverClockOffset
end

function SpecialEventController:_clearActiveClone()
    if self._activeClone and self._activeClone.Parent then
        self._activeClone:Destroy()
        self:_addPerfStat("ClonesDestroyed")
    end

    self._activeClone = nil
    self._activeCloneEventId = nil
end

function SpecialEventController:_restoreLightingState()
    local eventFolder = self._lightingEventFolder
    if eventFolder and eventFolder.Parent == Lighting then
        for index = #self._lightingMovedEventChildren, 1, -1 do
            local child = self._lightingMovedEventChildren[index]
            if child and child.Parent == Lighting then
                child.Parent = eventFolder
            end
        end
    end

    local defaultFolder = self._lightingDefaultFolder
    if defaultFolder and defaultFolder.Parent == Lighting then
        local defaultAtmosphere = self._lightingDefaultAtmosphere
        if defaultAtmosphere and defaultAtmosphere.Parent == defaultFolder then
            defaultAtmosphere.Parent = Lighting
        end

        local defaultObbySky = self._lightingDefaultObbySky
        if defaultObbySky and defaultObbySky.Parent == defaultFolder then
            defaultObbySky.Parent = Lighting
        end
    end

    self._lightingAppliedEventId = nil
    self._lightingDefaultFolder = nil
    self._lightingDefaultAtmosphere = nil
    self._lightingDefaultObbySky = nil
    self._lightingEventFolder = nil
    table.clear(self._lightingMovedEventChildren)
end

function SpecialEventController:_applyLightingForActiveEvent(activeEvent)
    local eventId = activeEvent and tonumber(activeEvent.id) or nil
    if self._lightingAppliedEventId == eventId then
        return
    end

    if self._lightingAppliedEventId ~= nil then
        self:_restoreLightingState()
    end

    if not activeEvent then
        return
    end

    local eventName = tostring(activeEvent.name or "")
    if eventName == "" then
        return
    end

    local eventFolder = Lighting:FindFirstChild(eventName)
    if not (eventFolder and eventFolder:IsA("Folder")) then
        warn(string.format("[SpecialEventController] 找不到 Lighting/%s 事件天空文件夹", eventName))
        return
    end

    local defaultFolder = findOrCreateLightingFolder("Default")
    local defaultAtmosphere = getLightingChild("Atmosphere")
    local defaultObbySky = getLightingChild("Obby Sky")

    self._lightingAppliedEventId = eventId
    self._lightingDefaultFolder = defaultFolder
    self._lightingDefaultAtmosphere = defaultAtmosphere
    self._lightingDefaultObbySky = defaultObbySky
    self._lightingEventFolder = eventFolder
    table.clear(self._lightingMovedEventChildren)

    if defaultAtmosphere and defaultAtmosphere.Parent == Lighting then
        defaultAtmosphere.Parent = defaultFolder
    end
    if defaultObbySky and defaultObbySky.Parent == Lighting then
        defaultObbySky.Parent = defaultFolder
    end

    for _, child in ipairs(eventFolder:GetChildren()) do
        table.insert(self._lightingMovedEventChildren, child)
        child.Parent = Lighting
    end
end

function SpecialEventController:_cloneEventScene(activeEvent)
    if not activeEvent then
        self:_clearActiveClone()
        return
    end

    local eventId = tonumber(activeEvent.id)
    if self._activeClone and self._activeCloneEventId == eventId then
        return
    end

    self:_clearActiveClone()

    local template = resolvePath(activeEvent.scenePath)
    if not template then
        warn(string.format("[SpecialEventController] 找不到特殊事件场景路径：%s", tostring(activeEvent.scenePath or "")))
        return
    end

    local clone = template:Clone()
    clone.Name = "SpecialEvent_" .. tostring(activeEvent.name or eventId or "Unknown")
    stabilizeSceneInstance(clone)
    clone:SetAttribute(SpecialEventConfig.RuntimeCloneAttributeName or "SpecialEventRuntimeClone", true)
    clone:SetAttribute("SpecialEventId", eventId or 0)
    clone.Parent = Workspace
    self._activeClone = clone
    self._activeCloneEventId = eventId
    self:_addPerfStat("ClonesCreated")
end

function SpecialEventController:_applyPayload(payload)
    if type(payload) ~= "table" then
        return
    end

    local serverClock = tonumber(payload.serverClock) or tonumber(payload.timestamp)
    if serverClock then
        self._serverClockOffset = serverClock - os.clock()
    end

    self._payload = payload
    self:_addPerfStat("SyncEvents")
    self:_refreshScene()
    self:_updateBoards()
    self:_updateEventDescribe()
    self:_maybeShowEventStart()
end

function SpecialEventController:_getActiveEvent()
    local activeEvent = self._payload and self._payload.activeEvent or nil
    if type(activeEvent) ~= "table" then
        return nil
    end

    if self:_getServerClock() >= (tonumber(activeEvent.endClock) or 0) then
        return nil
    end

    return activeEvent
end

function SpecialEventController:_refreshScene()
    local activeEvent = self:_getActiveEvent()
    self:_cloneEventScene(activeEvent)
    self:_applyLightingForActiveEvent(activeEvent)
end

function SpecialEventController:_hideAllEventLabels(frame)
    if not frame then
        return
    end

    for _, child in ipairs(frame:GetDescendants()) do
        if isTextObject(child) then
            child.Visible = false
        end
    end

    for _, labelName in ipairs(SpecialEventConfig.GetEventLabelNames()) do
        setLabel(findTextLabel(frame, labelName), false)
    end
end

function SpecialEventController:_updateFrame(frame)
    if not frame then
        return
    end

    self:_hideAllEventLabels(frame)

    local nowClock = self:_getServerClock()
    local activeEvent = self:_getActiveEvent()
    if activeEvent then
        local label = findTextLabel(frame, activeEvent.textLabelName)
        setLabel(label, true, string.format(
            "%s Event Ends In: %s",
            tostring(activeEvent.name or ""),
            formatCountdown((tonumber(activeEvent.endClock) or nowClock) - nowClock)
        ))
    end

    local futureEvents = self._payload and self._payload.futureEvents or nil
    if type(futureEvents) ~= "table" then
        return
    end

    local shown = 0
    local maxFutureCount = math.max(0, math.floor(tonumber(SpecialEventConfig.FutureDisplayCount) or 2))
    for _, futureEvent in ipairs(futureEvents) do
        if shown >= maxFutureCount then
            break
        end

        if type(futureEvent) == "table" then
            local isActiveLabel = activeEvent and futureEvent.textLabelName == activeEvent.textLabelName
            if not isActiveLabel then
                local label = findTextLabel(frame, futureEvent.textLabelName)
                setLabel(label, true, string.format(
                    "%s Event in: %s",
                    tostring(futureEvent.name or ""),
                    formatCountdown((tonumber(futureEvent.startClock) or nowClock) - nowClock)
                ))
            end
            shown = shown + 1
        end
    end

end

function SpecialEventController:_updateEventEnd()
    local eventEndRoot = findEventEndRoot()
    if not eventEndRoot then
        return
    end

    self:_hideAllEventLabels(eventEndRoot)
    eventEndRoot.Visible = false
end

function SpecialEventController:_setEventBuffDescriptionVisible(visible)
    local eventDescribe = self._eventDescribeRoot or findEventDescribeRoot()
    local parts = getEventDescribeParts(eventDescribe)
    local shouldShow = visible == true and self:_getActiveEvent() ~= nil
    setGuiVisible(parts.buffDescription, shouldShow)
    self._eventDescribeTooltipVisible = shouldShow
end

function SpecialEventController:_bindEventDescribeInteractions(eventDescribe)
    if self._eventDescribeRoot == eventDescribe then
        return
    end

    disconnectAll(self._eventDescribeConnections)
    self._eventDescribeRoot = eventDescribe
    self._eventDescribeTooltipVisible = false

    local parts = getEventDescribeParts(eventDescribe)
    local inputTarget = parts.inputTarget
    if not (inputTarget and inputTarget:IsA("GuiObject")) then
        inputTarget = parts.info
    end
    if not (inputTarget and inputTarget:IsA("GuiObject")) then
        inputTarget = eventDescribe
    end
    if not (inputTarget and inputTarget:IsA("GuiObject")) then
        return
    end

    table.insert(self._eventDescribeConnections, inputTarget.MouseEnter:Connect(function()
        if not UserInputService.TouchEnabled then
            self:_setEventBuffDescriptionVisible(true)
        end
    end))

    table.insert(self._eventDescribeConnections, inputTarget.MouseLeave:Connect(function()
        if not UserInputService.TouchEnabled then
            self:_setEventBuffDescriptionVisible(false)
        end
    end))

    table.insert(self._eventDescribeConnections, inputTarget.InputBegan:Connect(function(inputObject)
        if inputObject.UserInputType == Enum.UserInputType.Touch
            or inputObject.UserInputType == Enum.UserInputType.MouseButton1
        then
            if UserInputService.TouchEnabled then
                self:_setEventBuffDescriptionVisible(not self._eventDescribeTooltipVisible)
            end
        end
    end))

    table.insert(self._eventDescribeConnections, UserInputService.InputBegan:Connect(function(inputObject, gameProcessedEvent)
        if gameProcessedEvent or not self._eventDescribeTooltipVisible or not UserInputService.TouchEnabled then
            return
        end
        if inputObject.UserInputType ~= Enum.UserInputType.Touch
            and inputObject.UserInputType ~= Enum.UserInputType.MouseButton1
        then
            return
        end
        if isInputInsideGuiObject(inputTarget, inputObject)
            or isInputInsideGuiObject(eventDescribe, inputObject)
        then
            return
        end
        self:_setEventBuffDescriptionVisible(false)
    end))
end

function SpecialEventController:_updateEventDescribe()
    local eventDescribe = findEventDescribeRoot()
    if not eventDescribe then
        self._eventDescribeRoot = nil
        return
    end

    self:_bindEventDescribeInteractions(eventDescribe)

    local parts = getEventDescribeParts(eventDescribe)
    local activeEvent = self:_getActiveEvent()
    if not activeEvent then
        eventDescribe.Visible = false
        setGuiVisible(parts.buffDescription, false)
        self._eventDescribeTooltipVisible = false
        return
    end

    eventDescribe.Visible = true

    if parts.icon and (parts.icon:IsA("ImageLabel") or parts.icon:IsA("ImageButton")) then
        parts.icon.Image = tostring(activeEvent.iconImage or "")
    end

    if parts.timeLabel and (parts.timeLabel:IsA("TextLabel") or parts.timeLabel:IsA("TextButton") or parts.timeLabel:IsA("TextBox")) then
        local nowClock = self:_getServerClock()
        parts.timeLabel.Text = formatCountdown((tonumber(activeEvent.endClock) or nowClock) - nowClock)
    end

    if parts.buffInfo and (parts.buffInfo:IsA("TextLabel") or parts.buffInfo:IsA("TextButton") or parts.buffInfo:IsA("TextBox")) then
        parts.buffInfo.Text = tostring(activeEvent.effectDescription or "")
    end

    if self._eventDescribeTooltipVisible then
        setGuiVisible(parts.buffDescription, true)
    else
        setGuiVisible(parts.buffDescription, false)
    end
end

function SpecialEventController:_hideEventStart(immediate)
    local eventStart = findEventStartRoot()
    if self._eventStartTween then
        self._eventStartTween:Cancel()
        self._eventStartTween = nil
    end
    self._eventStartHideAtClock = 0
    if not eventStart then
        return
    end

    local uiScale = ensureScale(eventStart)
    local function finishHide(expectedTween)
        if expectedTween and self._eventStartTween ~= expectedTween then
            return
        end
        eventStart.Visible = false
        self:_hideAllEventLabels(eventStart)
        if uiScale then
            uiScale.Scale = 1
        end
        if not expectedTween or self._eventStartTween == expectedTween then
            self._eventStartTween = nil
        end
    end

    if immediate == true or not eventStart.Visible then
        finishHide(nil)
        return
    end

    if uiScale then
        local closeTween = TweenService:Create(uiScale, EVENT_START_CLOSE_TWEEN_INFO, {
            Scale = 0.92,
        })
        self._eventStartTween = closeTween
        local closeConnection
        closeConnection = closeTween.Completed:Connect(function(playbackState)
            if closeConnection then
                closeConnection:Disconnect()
                closeConnection = nil
            end
            if self._eventStartTween ~= closeTween then
                return
            end
            if playbackState ~= Enum.PlaybackState.Completed then
                finishHide(closeTween)
                return
            end
            finishHide(closeTween)
        end)
        closeTween:Play()
        task.delay(EVENT_START_CLOSE_TWEEN_INFO.Time + 0.08, function()
            if self._eventStartTween == closeTween then
                closeTween:Cancel()
                finishHide(closeTween)
            end
        end)
    else
        finishHide(nil)
    end
end

function SpecialEventController:_showEventStart(activeEvent)
    local eventStart = findEventStartRoot()
    if not eventStart then
        return
    end

    if self._eventStartTween then
        self._eventStartTween:Cancel()
        self._eventStartTween = nil
    end

    self:_hideAllEventLabels(eventStart)

    local labelName = getEventLabelName(activeEvent)
    local label = ensureEventStartLabel(eventStart, labelName)
    setLabel(label, true, string.format("%s Start!", labelName))

    local uiScale = ensureScale(eventStart)
    eventStart.Visible = true
    if uiScale then
        uiScale.Scale = 0.86
        local openTween = TweenService:Create(uiScale, EVENT_START_OPEN_TWEEN_INFO, {
            Scale = 1,
        })
        self._eventStartTween = openTween
        local openConnection
        openConnection = openTween.Completed:Connect(function()
            if openConnection then
                openConnection:Disconnect()
                openConnection = nil
            end
            if self._eventStartTween ~= openTween then
                return
            end
            self._eventStartTween = nil
        end)
        openTween:Play()
    end

    self._eventStartToken += 1
    local token = self._eventStartToken
    self._eventStartHideAtClock = os.clock() + EVENT_START_VISIBLE_SECONDS
    task.delay(EVENT_START_VISIBLE_SECONDS, function()
        if token ~= self._eventStartToken then
            return
        end
        self:_hideEventStart(true)
    end)
end

function SpecialEventController:_maybeShowEventStart()
    local activeEvent = self:_getActiveEvent()
    if not activeEvent then
        self._lastEventStartSequenceIndex = nil
        self._lastEventStartKey = nil
        self:_hideEventStart(true)
        return
    end

    local eventStartKey = getEventStartKey(activeEvent)
    if eventStartKey ~= "" and self._lastEventStartKey == eventStartKey then
        return
    end

    self._lastEventStartSequenceIndex = tonumber(activeEvent.sequenceIndex)
    self._lastEventStartKey = eventStartKey
    self:_showEventStart(activeEvent)
end

function SpecialEventController:_updateEventStartAutoHide()
    local hideAtClock = tonumber(self._eventStartHideAtClock) or 0
    if hideAtClock > 0 and os.clock() >= hideAtClock then
        self:_hideEventStart(true)
    end
end

function SpecialEventController:_updateBoards()
    local nowClock = os.clock()
    if nowClock - self._lastBoardUpdateClock < 0.2 then
        return
    end
    self._lastBoardUpdateClock = nowClock

    for _, frame in ipairs(getBoardFrames()) do
        self:_updateFrame(frame)
    end

    self:_updateEventEnd()
    self:_updateEventDescribe()
end

function SpecialEventController:_resetPerfStats()
    self._perfStats = {
        RenderFrames = 0,
        SyncEvents = 0,
        ClonesCreated = 0,
        ClonesDestroyed = 0,
        BoardUpdates = 0,
    }
end

function SpecialEventController:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function SpecialEventController:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats or {}
    print(string.format(
        "[Diag][SpecialEventController] frames=%d activeEventId=%s cloneName=%s cloneDesc=%d movedLighting=%d syncEvents=%d clonesCreated=%d clonesDestroyed=%d boardUpdates=%d",
        stats.RenderFrames or 0,
        tostring(self._activeCloneEventId),
        tostring(self._activeClone and self._activeClone.Name or "nil"),
        countDescendants(self._activeClone),
        #self._lightingMovedEventChildren,
        stats.SyncEvents or 0,
        stats.ClonesCreated or 0,
        stats.ClonesDestroyed or 0,
        stats.BoardUpdates or 0
    ))

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function SpecialEventController:Init()
    disconnectAll(self._connections)
    disconnectAll(self._eventDescribeConnections)
    self:_clearActiveClone()
    self:_restoreLightingState()
    self._payload = nil
    self._serverClockOffset = 0
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()
    self._lastBoardUpdateClock = 0
    self._eventDescribeRoot = nil
    self._eventDescribeTooltipVisible = false
    self._lastEventStartSequenceIndex = nil
    self._lastEventStartKey = nil
    self._eventStartToken += 1
    self._eventStartHideAtClock = 0

    local eventDescribe = findEventDescribeRoot()
    if eventDescribe then
        eventDescribe.Visible = false
        setGuiVisible(getEventDescribeParts(eventDescribe).buffDescription, false)
    end
    local eventEndRoot = findEventEndRoot()
    if eventEndRoot then
        self:_hideAllEventLabels(eventEndRoot)
        eventEndRoot.Visible = false
    end
    local eventStartRoot = findEventStartRoot()
    if eventStartRoot then
        self:_hideAllEventLabels(eventStartRoot)
        eventStartRoot.Visible = false
    end

    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._specialEventSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.SpecialEventSync)
    self._requestSpecialEventSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestSpecialEventSync)

    table.insert(self._connections, self._specialEventSyncEvent.OnClientEvent:Connect(function(payload)
        self:_applyPayload(payload)
    end))

    table.insert(self._connections, Workspace.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "BattleSenceEventBoard" or descendant.Name == "HomeEventBoard" or descendant.Name == "Frame" then
            task.defer(function()
                self:_updateBoards()
            end)
        end
    end))

    self._renderConnection = RunService.RenderStepped:Connect(function()
        self:_addPerfStat("RenderFrames")
        self:_updateEventStartAutoHide()
        self:_refreshScene()
        self:_updateBoards()
        self:_addPerfStat("BoardUpdates")
        self:_logPerfStats(os.clock())
    end)

    if self._requestSpecialEventSyncEvent and self._requestSpecialEventSyncEvent:IsA("RemoteEvent") then
        self._requestSpecialEventSyncEvent:FireServer()
    end
end

return SpecialEventController
