--[[
脚本名字: SpecialEventController
脚本文件: SpecialEventController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/SpecialEventController
说明: V2.2 特殊事件客户端表现；本地复制事件场景并更新场景事件板倒计时。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
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
        "[SpecialEventController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local SpecialEventConfig = requireSharedModule("SpecialEventConfig")

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

function SpecialEventController:_getServerClock()
    return os.clock() + self._serverClockOffset
end

function SpecialEventController:_clearActiveClone()
    if self._activeClone and self._activeClone.Parent then
        self._activeClone:Destroy()
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
    self:_refreshScene()
    self:_updateBoards()
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

function SpecialEventController:_updateBoards()
    local nowClock = os.clock()
    if nowClock - self._lastBoardUpdateClock < 0.2 then
        return
    end
    self._lastBoardUpdateClock = nowClock

    for _, frame in ipairs(getBoardFrames()) do
        self:_updateFrame(frame)
    end
end

function SpecialEventController:Init()
    disconnectAll(self._connections)
    self:_clearActiveClone()
    self:_restoreLightingState()
    self._payload = nil
    self._serverClockOffset = 0
    self._lastBoardUpdateClock = 0

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
        self:_refreshScene()
        self:_updateBoards()
    end)

    if self._requestSpecialEventSyncEvent and self._requestSpecialEventSyncEvent:IsA("RemoteEvent") then
        self._requestSpecialEventSyncEvent:FireServer()
    end
end

return SpecialEventController
