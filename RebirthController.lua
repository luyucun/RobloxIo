--[[
脚本名字: RebirthController
脚本文件: RebirthController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/RebirthController
说明: 绑定重生界面、重生请求、付费重生和可重生红点提示。
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))

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
        "[RebirthController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local RebirthController = {}

RebirthController._localPlayer = nil
RebirthController._connections = {}
RebirthController._buttonBindings = {}
RebirthController._mainGui = nil
RebirthController._panel = nil
RebirthController._leftEntry = nil
RebirthController._requestRebirthEvent = nil
RebirthController._latestState = nil
RebirthController._bindRetryQueued = false
RebirthController._redPointShakeToken = 0
RebirthController._redPointOriginalPosition = nil
RebirthController._redPointVisible = false
RebirthController._panelTweens = {}
RebirthController._panelAnimationSerial = 0
RebirthController._isPanelOpen = false

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.18
local OPEN_SETTLE_DURATION = 0.12
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14

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

local function findDescendant(parent, name)
    if not parent then
        return nil
    end
    return parent:FindFirstChild(name, true)
end

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function trimNumber(value)
    local rounded = math.floor(((tonumber(value) or 0) * 100) + 0.5) / 100
    if math.abs(rounded - math.floor(rounded)) < 0.001 then
        return tostring(math.floor(rounded))
    end

    local text = string.format("%.2f", rounded)
    text = string.gsub(text, "0+$", "")
    text = string.gsub(text, "%.$", "")
    return text
end

local function formatMultiplier(value)
    return "x" .. trimNumber(value)
end

local function getRequiredScore(rebirth)
    return GameConfig.GetRequiredRebirthScore(rebirth)
end

local function getRebirthMultiplier(rebirth)
    return 1 + GameConfig.GetRebirthExperienceBonus(rebirth)
end

local function offsetPosition(position, offsetX)
    return UDim2.new(
        position.X.Scale,
        position.X.Offset + offsetX,
        position.Y.Scale,
        position.Y.Offset
    )
end

local function playTween(binding, tweenKey, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existingTween = binding.tweens[tweenKey]
    if existingTween then
        existingTween:Cancel()
        binding.tweens[tweenKey] = nil
    end

    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[tweenKey] = tween
    tween.Completed:Connect(function()
        if binding.tweens[tweenKey] == tween then
            binding.tweens[tweenKey] = nil
        end
    end)
    tween:Play()
end

function RebirthController:_notify(message)
    task.spawn(function()
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "Rebirth",
                Text = tostring(message or ""),
                Duration = 2,
            })
        end)
    end)
end

function RebirthController:_ensureMainGuiEnabled()
    if not self._mainGui then
        return
    end

    if self._mainGui:IsA("LayerCollector") then
        self._mainGui.Enabled = true
    end
end

function RebirthController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function RebirthController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function RebirthController:_setPanelOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isPanelOpen = false
            ModalUiController:Release("Rebirth")
        end
        return
    end

    local uiScale = ensureUiScale(self._panel)
    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isPanelOpen = isOpen == true

    if self._isPanelOpen then
        self:_ensureMainGuiEnabled()
        ModalUiController:Acquire("Rebirth", self._panel)
        self._panel.Visible = true
        if not uiScale or immediate == true then
            if uiScale then
                uiScale.Scale = 1
            end
            return
        end

        uiScale.Scale = OPEN_FROM_SCALE
        local overshootTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = OPEN_OVERSHOOT_SCALE,
        })
        local settleTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Scale = 1,
        })
        self._panelTweens = { overshootTween, settleTween }

        task.spawn(function()
            overshootTween:Play()
            overshootTween.Completed:Wait()
            if self._panelAnimationSerial ~= animationSerial or not self._isPanelOpen then
                return
            end

            settleTween:Play()
            settleTween.Completed:Wait()
            if self._panelAnimationSerial ~= animationSerial or not self._isPanelOpen then
                return
            end

            uiScale.Scale = 1
            table.clear(self._panelTweens)
        end)
        return
    end

    if not uiScale or immediate == true or not self._panel.Visible then
        if uiScale then
            uiScale.Scale = 1
        end
        self._panel.Visible = false
        ModalUiController:Release("Rebirth")
        return
    end

    local overshootTween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_OVERSHOOT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = CLOSE_OVERSHOOT_SCALE,
    })
    local shrinkTween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { overshootTween, shrinkTween }

    task.spawn(function()
        overshootTween:Play()
        overshootTween.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isPanelOpen then
            return
        end

        shrinkTween:Play()
        shrinkTween.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isPanelOpen then
            return
        end

        uiScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release("Rebirth")
    end)
end

function RebirthController:_applyButtonState(binding)
    local scale = binding.baseScale
    local rotation = binding.baseRotation
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * binding.pressScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * binding.hoverScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = HOVER_TWEEN_INFO
    end

    playTween(binding, "scale", binding.uiScale, tweenInfo, {
        Scale = scale,
    })

    if binding.rotationTarget then
        playTween(binding, "rotation", binding.rotationTarget, tweenInfo, {
            Rotation = rotation,
        })
    end
end

function RebirthController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = (type(options) == "table" and options.ScaleTarget) or button
    local rotationTarget = (type(options) == "table" and options.RotationTarget) or nil
    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        scaleTarget = scaleTarget,
        rotationTarget = rotationTarget,
        baseScale = uiScale.Scale,
        baseRotation = rotationTarget and rotationTarget.Rotation or 0,
        hoverScale = (type(options) == "table" and tonumber(options.HoverScale)) or HOVER_SCALE,
        pressScale = (type(options) == "table" and tonumber(options.PressScale)) or PRESS_SCALE,
        hoverRotation = (type(options) == "table" and tonumber(options.HoverRotation)) or 0,
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
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.Activated:Connect(function()
        onActivated()
    end))

    table.insert(self._buttonBindings, binding)
end

function RebirthController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
        end
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale
        end
        if binding.rotationTarget and binding.rotationTarget.Parent then
            binding.rotationTarget.Rotation = binding.baseRotation
        end
    end
    table.clear(self._buttonBindings)
end

function RebirthController:_resolveEntryScaleTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    local label = self._leftEntry:FindFirstChild("TextLabel", true)
    if label and label:IsA("GuiObject") then
        return label
    end

    return self._leftEntry
end

function RebirthController:_resolveEntryRotationTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveEntryScaleTarget()
end

function RebirthController:_setRedPointVisible(visible)
    local redPoint = self._leftEntry and self._leftEntry:FindFirstChild("RedPoint", true) or nil
    if not (redPoint and redPoint:IsA("GuiObject")) then
        return
    end

    local shouldShow = visible == true
    if self._redPointVisible == shouldShow then
        redPoint.Visible = shouldShow
        return
    end

    self._redPointVisible = shouldShow
    redPoint.Visible = shouldShow
    if shouldShow then
        if not self._redPointOriginalPosition then
            self._redPointOriginalPosition = redPoint.Position
        end
        self:_startRedPointShake(redPoint)
    else
        self._redPointShakeToken += 1
        if self._redPointOriginalPosition then
            redPoint.Position = self._redPointOriginalPosition
        end
    end
end

function RebirthController:_startRedPointShake(redPoint)
    if not (redPoint and redPoint:IsA("GuiObject")) then
        return
    end

    self._redPointShakeToken += 1
    local token = self._redPointShakeToken
    local originalPosition = self._redPointOriginalPosition or redPoint.Position

    task.spawn(function()
        while token == self._redPointShakeToken and redPoint.Parent and redPoint.Visible do
            redPoint.Position = originalPosition
            local rightTween = TweenService:Create(redPoint, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = offsetPosition(originalPosition, 4),
            })
            local leftTween = TweenService:Create(redPoint, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = offsetPosition(originalPosition, -4),
            })
            local resetTween = TweenService:Create(redPoint, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = originalPosition,
            })

            rightTween:Play()
            rightTween.Completed:Wait()
            if token ~= self._redPointShakeToken then
                break
            end
            leftTween:Play()
            leftTween.Completed:Wait()
            if token ~= self._redPointShakeToken then
                break
            end
            resetTween:Play()
            resetTween.Completed:Wait()
            task.wait(0.76)
        end

        if redPoint.Parent and self._redPointOriginalPosition then
            redPoint.Position = self._redPointOriginalPosition
        end
    end)
end

function RebirthController:_updateUi()
    local state = self._latestState or {}
    local rebirth = math.max(0, math.floor(tonumber(state.rebirth) or 0))
    local rebirthScore = math.max(0, math.floor(tonumber(state.rebirthScore) or 0))
    local requiredScore = math.max(1, math.floor(tonumber(state.nextRebirthScore) or getRequiredScore(rebirth)))
    local nextRebirth = rebirth + 1
    local currentRebirthMultiplier = getRebirthMultiplier(rebirth)
    local nextRebirthMultiplier = getRebirthMultiplier(nextRebirth)

    if self._leftEntry then
        setText(self._leftEntry:FindFirstChild("Time", true), "[" .. formatInteger(rebirth) .. "]")
    end

    if self._panel then
        setText(findDescendant(self._panel, "Num1"), formatInteger(rebirth))

        local reward1 = findDescendant(self._panel, "Reward1")
        if reward1 then
            setText(reward1:FindFirstChild("Num1", true), formatInteger(rebirth))
            setText(reward1:FindFirstChild("Num2", true), formatInteger(nextRebirth))
        end

        local reward2 = findDescendant(self._panel, "Reward2")
        if reward2 then
            setText(reward2:FindFirstChild("Num1", true), formatMultiplier(currentRebirthMultiplier))
            setText(reward2:FindFirstChild("Num2", true), formatMultiplier(nextRebirthMultiplier))
        end

        local progressBg = findDescendant(self._panel, "ProgressBg")
        local progress = progressBg and progressBg:FindFirstChild("Progress", true)
        if progress and progress:IsA("GuiObject") then
            local ratio = math.clamp(rebirthScore / requiredScore, 0, 1)
            progress.Size = UDim2.new(ratio, 0, progress.Size.Y.Scale, progress.Size.Y.Offset)
        end
        if progressBg then
            setText(progressBg:FindFirstChild("Num", true), formatInteger(rebirthScore) .. "/" .. formatInteger(requiredScore))
        end
    end

    self:_setRedPointVisible(rebirthScore >= requiredScore)
end

function RebirthController:_queueBindRetry()
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
        warn("[RebirthController] 找不到 PlayerGui/Main/Rebirth，重生界面暂不可用。")
    end)
end

function RebirthController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("Rebirth") or nil
    local leftRoot = mainGui and mainGui:FindFirstChild("Left") or nil
    self._leftEntry = leftRoot and leftRoot:FindFirstChild("Rebirth") or nil
    self._redPointOriginalPosition = nil
    self._redPointVisible = false

    if not (self._panel and self._panel:IsA("GuiObject") and self._leftEntry and self._leftEntry:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    if self._isPanelOpen then
        ModalUiController:Acquire("Rebirth", self._panel)
        self._panel.Visible = true
    else
        self:_setPanelOpen(false, true)
    end

    local openButton = self._leftEntry:FindFirstChild("TextButton", true)
    local closeButton = self._panel:FindFirstChild("CloseButton", true)
    local rebirthButton = self._panel:FindFirstChild("RebirthBtn", true)
    local rebirthBuyButton = self._panel:FindFirstChild("RebirthBuy", true)
    local entryScaleTarget = self:_resolveEntryScaleTarget()
    local entryRotationTarget = self:_resolveEntryRotationTarget()

    self:_bindButton(openButton, function()
        self:_setPanelOpen(true)
        self:_updateUi()
    end, {
        ScaleTarget = entryScaleTarget or openButton,
        RotationTarget = entryRotationTarget,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindButton(closeButton, function()
        self:_setPanelOpen(false)
    end, {
        ScaleTarget = closeButton,
        RotationTarget = closeButton,
        HoverScale = 1.12,
        PressScale = 0.92,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindButton(rebirthButton, function()
        if self._requestRebirthEvent then
            self._requestRebirthEvent:FireServer()
        end
    end, {
        ScaleTarget = rebirthButton,
        HoverScale = HOVER_SCALE,
        PressScale = PRESS_SCALE,
    })

    self:_bindButton(rebirthBuyButton, function()
        if self._localPlayer then
            MarketplaceService:PromptProductPurchase(self._localPlayer, GameConfig.REBIRTH.PaidRebirthProductId)
        end
    end, {
        ScaleTarget = rebirthBuyButton,
        HoverScale = HOVER_SCALE,
        PressScale = PRESS_SCALE,
    })

    self:_updateUi()
    return true
end

function RebirthController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._requestRebirthEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestRebirth)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local rebirthFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RebirthFeedback)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestState = payload
        self:_updateUi()
    end))

    table.insert(self._connections, rebirthFeedbackEvent.OnClientEvent:Connect(function(payload)
        if payload and payload.eventType == "Failed" then
            self:_notify(payload.message or "Requirement not met")
        end
        if payload then
            self._latestState = {
                rebirth = payload.rebirth,
                rebirthScore = payload.rebirthScore,
                nextRebirthScore = payload.nextRebirthScore,
            }
            self:_updateUi()
        end
    end))

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                end)
            end
        end))
    end
end

return RebirthController
