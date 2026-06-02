--[[
脚本名字: CodeController
脚本文件: CodeController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/CodeController
说明: 兑换码面板绑定、提交、失败提示与奖励反馈。
]]

local Players = game:GetService("Players")
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
        "[CodeController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))
local CodeConfig = requireSharedModule("CodeConfig")

local CodeController = {}

CodeController._localPlayer = nil
CodeController._connections = {}
CodeController._buttonBindings = {}
CodeController._mainGui = nil
CodeController._panel = nil
CodeController._entryButtonRoot = nil
CodeController._entryButton = nil
CodeController._closeButton = nil
CodeController._useButton = nil
CodeController._textBox = nil
CodeController._requestRedeemEvent = nil
CodeController._redeemFeedbackEvent = nil
CodeController._panelTweens = {}
CodeController._panelAnimationSerial = 0
CodeController._isOpen = false
CodeController._bindRetryQueued = false
CodeController._warningFrame = nil
CodeController._warningText = nil
CodeController._warningToken = 0

local ENTRY_HOVER_SCALE = 1.05
local ENTRY_PRESS_SCALE = 0.93
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PANEL_OPEN_FROM_SCALE = 0.82
local PANEL_OPEN_OVERSHOOT_SCALE = 1.06
local PANEL_CLOSE_TO_SCALE = 0.78
local PANEL_OPEN_OVERSHOOT_DURATION = 0.16
local PANEL_OPEN_SETTLE_DURATION = 0.1
local PANEL_CLOSE_OVERSHOOT_DURATION = 0.1
local PANEL_CLOSE_SHRINK_DURATION = 0.14

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
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

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function setText(node, value)
    if node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox")) then
        node.Text = tostring(value or "")
    end
end

function CodeController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function CodeController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function CodeController:_showWarning(message)
    local text = tostring(message or "")
    if text == "" then
        return
    end
    self._warningToken += 1
    local token = self._warningToken
    if self._warningText then
        self._warningText.Text = text
    end
    if self._warningFrame then
        self._warningFrame.Visible = true
    end
    task.delay(2, function()
        if self._warningToken ~= token then
            return
        end
        if self._warningFrame and self._warningFrame.Parent then
            self._warningFrame.Visible = false
        end
    end)
end

function CodeController:_setOpen(isOpen, immediate)
    if not self._panel then
        if isOpen ~= true then
            self._isOpen = false
            self:_cancelPanelTweens()
            ModalUiController:Release("CodeRedeem")
        end
        return
    end

    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isOpen = isOpen == true
    local rootScale = ensureUiScale(self._panel)
    if self._isOpen then
        ModalUiController:Acquire("CodeRedeem", self._panel)
        self._panel.Visible = true
        if rootScale then
            rootScale.Scale = PANEL_OPEN_FROM_SCALE
            local overshoot = TweenService:Create(rootScale, TweenInfo.new(PANEL_OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Scale = PANEL_OPEN_OVERSHOOT_SCALE,
            })
            local settle = TweenService:Create(rootScale, TweenInfo.new(PANEL_OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Scale = 1,
            })
            self._panelTweens = { overshoot, settle }
            task.spawn(function()
                overshoot:Play()
                overshoot.Completed:Wait()
                if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                    return
                end
                settle:Play()
                settle.Completed:Wait()
                if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                    return
                end
                rootScale.Scale = 1
                table.clear(self._panelTweens)
            end)
        end
        return
    end

    if not rootScale or immediate == true or not self._panel.Visible then
        if rootScale then
            rootScale.Scale = 1
        end
        self._panel.Visible = false
        ModalUiController:Release("CodeRedeem")
        return
    end

    local overshoot = TweenService:Create(rootScale, TweenInfo.new(PANEL_CLOSE_OVERSHOOT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = 1.04,
    })
    local shrink = TweenService:Create(rootScale, TweenInfo.new(PANEL_CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = PANEL_CLOSE_TO_SCALE,
    })
    self._panelTweens = { overshoot, shrink }
    task.spawn(function()
        overshoot:Play()
        overshoot.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end
        shrink:Play()
        shrink.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end
        rootScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release("CodeRedeem")
    end)
end

local function playTween(binding, key, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existingTween = binding.tweens[key]
    if existingTween then
        existingTween:Cancel()
        binding.tweens[key] = nil
    end

    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[key] = tween
    tween.Completed:Connect(function()
        if binding.tweens[key] == tween then
            binding.tweens[key] = nil
        end
    end)
    tween:Play()
end

function CodeController:_applyButtonState(binding)
    local scale = binding.baseScale
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * ENTRY_PRESS_SCALE
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * ENTRY_HOVER_SCALE
        tweenInfo = HOVER_TWEEN_INFO
    end

    playTween(binding, "scale", binding.uiScale, tweenInfo, { Scale = scale })
end

function CodeController:_bindButton(button, onActivated)
    if not (button and button:IsA("GuiButton")) then
        return
    end
    local uiScale = ensureUiScale(button)
    if not uiScale then
        return
    end

    local binding = {
        uiScale = uiScale,
        baseScale = uiScale.Scale,
        isHovered = false,
        isPressed = false,
        tweens = {},
        connections = {},
    }

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        self:_applyButtonState(binding)
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        self:_applyButtonState(binding)
    end))
    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            self:_applyButtonState(binding)
        end
    end))
    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            self:_applyButtonState(binding)
        end
    end))
    table.insert(binding.connections, button.Activated:Connect(function()
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    for _, connection in ipairs(binding.connections) do
        table.insert(self._connections, connection)
    end
    table.insert(self._buttonBindings, binding)
end

function CodeController:_requestRedeem()
    local code = self._textBox and self._textBox.Text or ""
    if not self._requestRedeemEvent then
        self:_showWarning(CodeConfig.WarningMessage)
        return
    end
    self._requestRedeemEvent:FireServer({ code = code })
end

function CodeController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        return
    end

    self._requestRedeemEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestCodeRedeem, 10)
    self._redeemFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.CodeRedeemFeedback, 10)

    if self._redeemFeedbackEvent then
        table.insert(self._connections, self._redeemFeedbackEvent.OnClientEvent:Connect(function(payload)
            if type(payload) ~= "table" then
                return
            end
            if payload.success == true then
                self:_setOpen(false)
            else
                self:_showWarning(payload.message or CodeConfig.WarningMessage)
            end
        end))
    end
end

function CodeController:_bindUi(silent)
    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        return false
    end

    local topRightGui = self._mainGui:FindFirstChild("TopRightGui")
    self._entryButtonRoot = topRightGui and topRightGui:FindFirstChild("Codes")
    self._panel = self._mainGui:FindFirstChild("Codes")
    self._warningFrame = self._mainGui:FindFirstChild("Warning")
    self._warningText = self._warningFrame and self._warningFrame:FindFirstChild("Text", true) or self._warningFrame and self._warningFrame:FindFirstChildWhichIsA("TextLabel", true)

    if not (self._entryButtonRoot and self._panel) then
        return false
    end

    self._entryButton = self._entryButtonRoot:FindFirstChildWhichIsA("GuiButton", true)
    self._closeButton = self._panel:FindFirstChild("CloseButton", true)
    self._useButton = self._panel:FindFirstChild("Use", true)
    self._textBox = self._panel:FindFirstChild("TextBox", true)

    self._panel.Visible = false

    self:_bindButton(self._entryButton, function()
        self:_setOpen(true)
    end)
    self:_bindButton(self._closeButton, function()
        self:_setOpen(false)
    end)
    self:_bindButton(self._useButton, function()
        self:_requestRedeem()
    end)

    if self._textBox and self._textBox:IsA("TextBox") then
        table.insert(self._connections, self._textBox.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                self:_requestRedeem()
            end
        end))
    end

    return true
end

function CodeController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    table.clear(self._buttonBindings)
    self:_connectRemotes()
    if not self:_bindUi(true) then
        task.spawn(function()
            for _ = 1, 60 do
                task.wait(0.25)
                if self:_bindUi(true) then
                    return
                end
            end
            warn("[CodeController] Could not find PlayerGui/Main/Codes UI.")
        end)
    end
end

return CodeController
