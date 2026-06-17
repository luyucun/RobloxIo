--[[
Script: LeaveTipsController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/LeaveTipsController
Purpose: Shows Main.LeaveTips when the Roblox escape menu opens.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LeaveTipsController = {}

local OWNER_NAME = "LeaveTips"
local OPEN_TWEEN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local CLOSE_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SLIDE_OFFSET_SCALE = -0.16
local PRESS_SCALE = 0.96
local HOVER_SCALE = 1.02
local MAX_BIND_RETRY_ATTEMPTS = 80

LeaveTipsController._localPlayer = nil
LeaveTipsController._modalUiController = nil
LeaveTipsController._connections = {}
LeaveTipsController._textConnections = {}
LeaveTipsController._root = nil
LeaveTipsController._text = nil
LeaveTipsController._textOriginalPosition = nil
LeaveTipsController._textScale = nil
LeaveTipsController._activeTweens = {}
LeaveTipsController._motionCleanup = nil
LeaveTipsController._bindRetryQueued = false
LeaveTipsController._bindRetryAttempts = 0
LeaveTipsController._animationSerial = 0
LeaveTipsController._isPressed = false
LeaveTipsController._isHovered = false

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

local function ensureUiScale(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if uiScale then
        return uiScale
    end

    uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = guiObject
    return uiScale
end

local function offsetPosition(position, yScale)
    return UDim2.new(
        position.X.Scale,
        position.X.Offset,
        position.Y.Scale + yScale,
        position.Y.Offset
    )
end

local function isPrimaryPointer(inputObject)
    local inputType = inputObject and inputObject.UserInputType
    return inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch
end

function LeaveTipsController:_cancelTweens()
    for _, tween in ipairs(self._activeTweens) do
        tween:Cancel()
    end
    table.clear(self._activeTweens)
end

function LeaveTipsController:_playTextScale(scale, tweenInfo)
    if not (self._textScale and self._textScale.Parent) then
        return
    end

    local tween = TweenService:Create(self._textScale, tweenInfo, {
        Scale = scale,
    })
    table.insert(self._activeTweens, tween)
    tween.Completed:Connect(function()
        local index = table.find(self._activeTweens, tween)
        if index then
            table.remove(self._activeTweens, index)
        end
    end)
    tween:Play()
end

function LeaveTipsController:_applyPointerState()
    if self._isPressed then
        self:_playTextScale(PRESS_SCALE, PRESS_TWEEN_INFO)
    elseif self._isHovered then
        self:_playTextScale(HOVER_SCALE, RESET_TWEEN_INFO)
    else
        self:_playTextScale(1, RESET_TWEEN_INFO)
    end
end

function LeaveTipsController:_disconnectText()
    disconnectAll(self._textConnections)
    if self._motionCleanup then
        self._motionCleanup()
        self._motionCleanup = nil
    end
    self._isPressed = false
    self._isHovered = false
end

function LeaveTipsController:_bindTextClickTarget()
    self:_disconnectText()
    if not (self._text and self._text:IsA("GuiObject")) then
        return
    end

    self._text.Active = true
    self._text.Selectable = false
    self._textScale = ensureUiScale(self._text)
    if self._modalUiController and self._modalUiController.BindButtonMotion then
        self._motionCleanup = self._modalUiController:BindButtonMotion(self._text, {
            HoverScale = HOVER_SCALE,
            PressScale = PRESS_SCALE,
        })
    end

    table.insert(self._textConnections, self._text.MouseEnter:Connect(function()
        self._isHovered = true
        if not self._motionCleanup then
            self:_applyPointerState()
        end
    end))

    table.insert(self._textConnections, self._text.MouseLeave:Connect(function()
        self._isHovered = false
        self._isPressed = false
        if not self._motionCleanup then
            self:_applyPointerState()
        end
    end))

    table.insert(self._textConnections, self._text.InputBegan:Connect(function(inputObject)
        if not isPrimaryPointer(inputObject) then
            return
        end
        self._isPressed = true
        if inputObject.UserInputType == Enum.UserInputType.Touch then
            self._isHovered = true
        end
        if not self._motionCleanup then
            self:_applyPointerState()
        end
    end))

    table.insert(self._textConnections, self._text.InputEnded:Connect(function(inputObject)
        if not isPrimaryPointer(inputObject) then
            return
        end
        local wasPressed = self._isPressed
        self._isPressed = false
        if inputObject.UserInputType == Enum.UserInputType.Touch then
            self._isHovered = false
        end
        if not self._motionCleanup then
            self:_applyPointerState()
        end
        if wasPressed then
            self:_handleContinue()
        end
    end))
end

function LeaveTipsController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    if self._bindRetryAttempts >= MAX_BIND_RETRY_ATTEMPTS then
        warn("[LeaveTipsController] Give up binding PlayerGui/Main/LeaveTips/Text after retries.")
        return
    end
    self._bindRetryAttempts += 1
    self._bindRetryQueued = true
    task.delay(0.25, function()
        self._bindRetryQueued = false
        if not self:_bindUi(true) then
            self:_queueBindRetry()
        end
    end)
end

function LeaveTipsController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    local root = mainGui and mainGui:FindFirstChild("LeaveTips")
    local text = root and root:FindFirstChild("Text")
    if not (root and root:IsA("GuiObject") and text and text:IsA("GuiObject")) then
        if not silent then
            warn("[LeaveTipsController] Missing PlayerGui/Main/LeaveTips/Text; retrying.")
        end
        return false
    end

    if self._root == root and self._text == text then
        return true
    end

    self:_disconnectText()
    self:_cancelTweens()
    self._root = root
    self._text = text
    self._textOriginalPosition = text.Position
    self._textScale = ensureUiScale(text)
    self._root.Visible = false
    self._bindRetryAttempts = 0
    self:_bindTextClickTarget()
    return true
end

function LeaveTipsController:_show(immediate)
    if not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()

    local root = self._root
    local text = self._text
    local originalPosition = self._textOriginalPosition or text.Position
    root.Visible = true
    text.Visible = true
    text.Position = offsetPosition(originalPosition, SLIDE_OFFSET_SCALE)
    if self._textScale then
        self._textScale.Scale = 1
    end

    if immediate == true then
        text.Position = originalPosition
        return
    end

    local slideTween = TweenService:Create(text, OPEN_TWEEN_INFO, {
        Position = originalPosition,
    })
    table.insert(self._activeTweens, slideTween)
    slideTween.Completed:Connect(function()
        if self._animationSerial ~= serial then
            return
        end
        local index = table.find(self._activeTweens, slideTween)
        if index then
            table.remove(self._activeTweens, index)
        end
    end)
    slideTween:Play()
end

function LeaveTipsController:_hide(immediate)
    if not self._root then
        return
    end

    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()
    self._isPressed = false
    self._isHovered = false

    local root = self._root
    local text = self._text
    if not (root and root.Parent and text and text.Parent) then
        return
    end

    local originalPosition = self._textOriginalPosition or text.Position
    if immediate == true or root.Visible ~= true then
        text.Position = originalPosition
        if self._textScale then
            self._textScale.Scale = 1
        end
        root.Visible = false
        return
    end

    local slideTween = TweenService:Create(text, CLOSE_TWEEN_INFO, {
        Position = offsetPosition(originalPosition, SLIDE_OFFSET_SCALE),
    })
    table.insert(self._activeTweens, slideTween)
    slideTween.Completed:Connect(function()
        if self._animationSerial ~= serial then
            return
        end
        if text and text.Parent then
            text.Position = originalPosition
        end
        if self._textScale and self._textScale.Parent then
            self._textScale.Scale = 1
        end
        if root and root.Parent then
            root.Visible = false
        end
        table.clear(self._activeTweens)
    end)
    slideTween:Play()
end

function LeaveTipsController:_closeRobloxMenu()
    local ok = pcall(function()
        GuiService:SetMenuIsOpen(false)
    end)
    if ok then
        return
    end

    pcall(function()
        GuiService.MenuIsOpen = false
    end)
end

function LeaveTipsController:_handleContinue()
    self:_hide(false)
    self:_closeRobloxMenu()
end

function LeaveTipsController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._modalUiController = dependencies and dependencies.ModalUiController or nil
    self._bindRetryAttempts = 0
    disconnectAll(self._connections)
    self:_disconnectText()
    self:_cancelTweens()

    table.insert(self._connections, GuiService.MenuOpened:Connect(function()
        self:_show(false)
    end))

    table.insert(self._connections, GuiService.MenuClosed:Connect(function()
        self:_hide(false)
    end))

    self:_bindUi(true)
    if GuiService.MenuIsOpen == true then
        self:_show(true)
    end
end

return LeaveTipsController
