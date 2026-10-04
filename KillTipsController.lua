--[[
脚本名字: KillTipsController
脚本文件: KillTipsController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/KillTipsController
说明: 展示全员玩家击杀提示队列。
]]

local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
        "[KillTipsController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local CinematicUiGate = require((script.Parent:FindFirstChild("Controllers") or script.Parent):WaitForChild("CinematicUiGate"))

local KillTipsController = {}

KillTipsController._localPlayer = nil
KillTipsController._connections = {}
KillTipsController._mainGui = nil
KillTipsController._template = nil
KillTipsController._activeTips = {}
KillTipsController._bindRetryQueued = false

local MAX_ACTIVE_TIPS = 3
local DISPLAY_SECONDS = 2
local ENTER_DURATION = 0.18
local EXIT_DURATION = 0.18
local STACK_GAP_PIXELS = 8
local ENTER_SLIDE_PIXELS = 18
local EXIT_SLIDE_PIXELS = 18
local FALLBACK_SLOT_HEIGHT_PIXELS = 44
local TEMPLATE_VISUAL_SCALE = 1.25
local KILLER_COLOR = "#FFD75A"
local VICTIM_COLOR = "#FF5A5F"
local TEXT_COLOR = "#FFFFFF"
local ENTER_TWEEN_INFO = TweenInfo.new(ENTER_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local EXIT_TWEEN_INFO = TweenInfo.new(EXIT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local SHIFT_TWEEN_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end

    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function escapeRichText(value)
    local text = tostring(value or "")
    text = string.gsub(text, "&", "&amp;")
    text = string.gsub(text, "<", "&lt;")
    text = string.gsub(text, ">", "&gt;")
    text = string.gsub(text, "\"", "&quot;")
    text = string.gsub(text, "'", "&apos;")
    return text
end

local function richColor(color, text)
    return string.format("<font color=\"%s\">%s</font>", color, escapeRichText(text))
end

local function formatKillText(payload)
    local killerName = payload and payload.killerName or "Unknown"
    local victimName = payload and payload.victimName or "Unknown"
    return string.format(
        "%s %s %s",
        richColor(KILLER_COLOR, killerName),
        richColor(TEXT_COLOR, "defeated"),
        richColor(VICTIM_COLOR, victimName)
    )
end

local function isTextObject(instance)
    return instance
        and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
end

local function captureTransparencyTargets(root)
    local targets = {}
    local instances = { root }
    for _, descendant in ipairs(root:GetDescendants()) do
        table.insert(instances, descendant)
    end

    for _, instance in ipairs(instances) do
        local target = { Instance = instance }
        local hasTarget = false
        if instance:IsA("GuiObject") then
            target.BackgroundTransparency = instance.BackgroundTransparency
            hasTarget = true
        end
        if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
            target.ImageTransparency = instance.ImageTransparency
            hasTarget = true
        end
        if isTextObject(instance) then
            target.TextTransparency = instance.TextTransparency
            target.TextStrokeTransparency = instance.TextStrokeTransparency
            hasTarget = true
        end
        if instance:IsA("UIStroke") then
            target.Transparency = instance.Transparency
            hasTarget = true
        end
        if hasTarget then
            table.insert(targets, target)
        end
    end

    return targets
end

local function tweenTransparency(targets, toHidden, tweenInfo)
    local tweens = {}
    for _, target in ipairs(targets or {}) do
        local instance = target.Instance
        if instance and instance.Parent then
            local goal = {}
            if target.BackgroundTransparency ~= nil then
                goal.BackgroundTransparency = toHidden and 1 or target.BackgroundTransparency
            end
            if target.ImageTransparency ~= nil then
                goal.ImageTransparency = toHidden and 1 or target.ImageTransparency
            end
            if target.TextTransparency ~= nil then
                goal.TextTransparency = toHidden and 1 or target.TextTransparency
            end
            if target.TextStrokeTransparency ~= nil then
                goal.TextStrokeTransparency = toHidden and 1 or target.TextStrokeTransparency
            end
            if target.Transparency ~= nil then
                goal.Transparency = toHidden and 1 or target.Transparency
            end
            if next(goal) ~= nil then
                local tween = TweenService:Create(instance, tweenInfo, goal)
                tween:Play()
                table.insert(tweens, tween)
            end
        end
    end
    return tweens
end

local function setHiddenTransparency(targets)
    for _, target in ipairs(targets or {}) do
        local instance = target.Instance
        if instance and instance.Parent then
            if target.BackgroundTransparency ~= nil then
                instance.BackgroundTransparency = 1
            end
            if target.ImageTransparency ~= nil then
                instance.ImageTransparency = 1
            end
            if target.TextTransparency ~= nil then
                instance.TextTransparency = 1
            end
            if target.TextStrokeTransparency ~= nil then
                instance.TextStrokeTransparency = 1
            end
            if target.Transparency ~= nil then
                instance.Transparency = 1
            end
        end
    end
end

local function offsetUDim2(position, offsetX, offsetY)
    return UDim2.new(
        position.X.Scale,
        position.X.Offset + offsetX,
        position.Y.Scale,
        position.Y.Offset + offsetY
    )
end

local function scaleUDim2(size, scale)
    return UDim2.new(
        size.X.Scale * scale,
        size.X.Offset * scale,
        size.Y.Scale * scale,
        size.Y.Offset * scale
    )
end

local function restoreImageVisibility(root)
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
            descendant.Visible = true
            if descendant.Image ~= "" and descendant.ImageTransparency >= 1 then
                descendant.ImageTransparency = 0
            end
        end
    end
end

local function shouldShowRevengeMarker(payload)
    return payload and (payload.isRevengeKill == true or payload.killSource == "Revenge") or false
end

local function setMarkerVisible(root, markerName, visible)
    local marker = root:FindFirstChild(markerName, true)
    if marker and marker:IsA("GuiObject") then
        marker.Visible = visible
    end
end

local function applyKillSourceMarkers(root, payload)
    local showRevengeMarker = shouldShowRevengeMarker(payload)
    setMarkerVisible(root, "Icon", showRevengeMarker)
    setMarkerVisible(root, "Revenge", showRevengeMarker)
end

local function configureTextLabel(root, text)
    local label = root:FindFirstChild("KillInfo", true)
    if not isTextObject(label) then
        return
    end

    label.RichText = true
    label.Text = text
    label.TextScaled = true
    label.TextWrapped = true
    label.TextTruncate = Enum.TextTruncate.None
end

function KillTipsController:_getSlotOffsetPixels()
    if not self._template then
        return FALLBACK_SLOT_HEIGHT_PIXELS
    end

    return math.max(FALLBACK_SLOT_HEIGHT_PIXELS, (self._template.AbsoluteSize.Y * TEMPLATE_VISUAL_SCALE) + STACK_GAP_PIXELS)
end

function KillTipsController:_getTargetPosition(index)
    local count = #self._activeTips
    local slotFromNewest = math.max(0, count - index)
    local basePosition = self._template and self._template.Position or UDim2.fromScale(0.5, 0.2)
    return offsetUDim2(basePosition, 0, -slotFromNewest * self:_getSlotOffsetPixels())
end

function KillTipsController:_cancelTipTweens(tip)
    if not tip then
        return
    end

    if tip.PositionTween then
        tip.PositionTween:Cancel()
        tip.PositionTween = nil
    end

    for _, tween in ipairs(tip.TransparencyTweens or {}) do
        if tween then
            tween:Cancel()
        end
    end
    if tip.TransparencyTweens then
        table.clear(tip.TransparencyTweens)
    end
end

function KillTipsController:_removeTipFromQueue(tip)
    for index = #self._activeTips, 1, -1 do
        if self._activeTips[index] == tip then
            table.remove(self._activeTips, index)
            return true
        end
    end
    return false
end

function KillTipsController:_updateQueuePositions(skipTip)
    for index, tip in ipairs(self._activeTips) do
        if tip ~= skipTip and tip.Gui and tip.Gui.Parent then
            if tip.PositionTween then
                tip.PositionTween:Cancel()
            end
            local tween = TweenService:Create(tip.Gui, SHIFT_TWEEN_INFO, {
                Position = self:_getTargetPosition(index),
            })
            tip.PositionTween = tween
            tween:Play()
        end
    end
end

function KillTipsController:_destroyTip(tip)
    if not tip then
        return
    end

    tip.Alive = false
    self:_cancelTipTweens(tip)
    if tip.Gui and tip.Gui.Parent then
        tip.Gui:Destroy()
    end
end

function KillTipsController:_beginTipExit(tip, immediate)
    if not (tip and tip.Alive) then
        return
    end

    self:_removeTipFromQueue(tip)
    if immediate == true then
        self:_destroyTip(tip)
        self:_updateQueuePositions()
        return
    end

    tip.Alive = false
    self:_cancelTipTweens(tip)
    self:_updateQueuePositions(tip)

    local gui = tip.Gui
    if not (gui and gui.Parent) then
        return
    end

    local positionTween = TweenService:Create(gui, EXIT_TWEEN_INFO, {
        Position = offsetUDim2(gui.Position, 0, -EXIT_SLIDE_PIXELS),
    })
    tip.PositionTween = positionTween
    positionTween:Play()
    tip.TransparencyTweens = {}
    for _, tween in ipairs(tweenTransparency(tip.TransparencyTargets, true, EXIT_TWEEN_INFO)) do
        table.insert(tip.TransparencyTweens, tween)
    end

    task.delay(EXIT_DURATION + 0.03, function()
        self:_destroyTip(tip)
    end)
end

function KillTipsController:_createTip(payload)
    if not self._template then
        return nil
    end

    local clone = self._template:Clone()
    clone.Name = "KillTipsEntry"
    clone.Visible = true
    clone.Size = scaleUDim2(self._template.Size, TEMPLATE_VISUAL_SCALE)
    clone.LayoutOrder = 0
    clone.Parent = self._template.Parent
    restoreImageVisibility(clone)
    applyKillSourceMarkers(clone, payload)
    configureTextLabel(clone, formatKillText(payload))

    local targets = captureTransparencyTargets(clone)
    setHiddenTransparency(targets)

    return {
        Gui = clone,
        TransparencyTargets = targets,
        PositionTween = nil,
        TransparencyTweens = {},
        Alive = true,
    }
end

function KillTipsController:_showTip(payload)
    if CinematicUiGate:IsBlocked() then
        local serial = self._cinematicSerial
        CinematicUiGate:Defer({}, function()
            if self._cinematicSerial == serial then
                self:_showTip(payload)
            end
        end)
        return
    end
    if not self._template and not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    while #self._activeTips >= MAX_ACTIVE_TIPS do
        self:_beginTipExit(self._activeTips[1], true)
    end

    local tip = self:_createTip(payload)
    if not tip then
        return
    end

    table.insert(self._activeTips, tip)
    local targetPosition = self:_getTargetPosition(#self._activeTips)
    tip.Gui.Position = offsetUDim2(targetPosition, 0, ENTER_SLIDE_PIXELS)
    self:_updateQueuePositions(tip)

    local positionTween = TweenService:Create(tip.Gui, ENTER_TWEEN_INFO, {
        Position = targetPosition,
    })
    tip.PositionTween = positionTween
    positionTween:Play()
    tip.TransparencyTweens = {}
    for _, tween in ipairs(tweenTransparency(tip.TransparencyTargets, false, ENTER_TWEEN_INFO)) do
        table.insert(tip.TransparencyTweens, tween)
    end

    task.delay(ENTER_DURATION + DISPLAY_SECONDS, function()
        self:_beginTipExit(tip)
    end)
end

function KillTipsController:_clearActiveTips()
    for _, tip in ipairs(self._activeTips) do
        self:_destroyTip(tip)
    end
    table.clear(self._activeTips)
end

function KillTipsController:_bindUi(silent)
    self._mainGui = findMainGui(self._localPlayer)
    self._template = self._mainGui and self._mainGui:FindFirstChild("KillTips", true) or nil
    if not (self._template and self._template:IsA("GuiObject")) then
        if not silent then
            warn("[KillTipsController] Missing PlayerGui/Main/KillTips.")
        end
        return false
    end

    self._template.Visible = false
    task.spawn(function()
        pcall(function()
            ContentProvider:PreloadAsync({ self._template })
        end)
    end)
    return true
end

function KillTipsController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[KillTipsController] Could not find PlayerGui/Main/KillTips.")
    end)
end

function KillTipsController:Init(dependencies)
    self._cinematicSerial = (self._cinematicSerial or 0) + 1
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_clearActiveTips()

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local killInfoEvent = systemEventsFolder:WaitForChild(RemoteNames.System.KillInfoFeedback)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, killInfoEvent.OnClientEvent:Connect(function(payload)
        self:_showTip(payload)
    end))

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_clearActiveTips()
                    self:_bindUi(true)
                end)
            end
        end))
    end
end

return KillTipsController
