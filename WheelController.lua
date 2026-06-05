--[[
Script: WheelController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/WheelController
Purpose: V3.0 wheel UI, countdown, purchases, and spin animation.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
        "[WheelController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local WheelConfig = requireSharedModule("WheelConfig")

local WheelController = {}

WheelController._localPlayer = nil
WheelController._audioSettings = nil
WheelController._connections = {}
WheelController._buttonBindings = {}
WheelController._mainGui = nil
WheelController._panel = nil
WheelController._wheelEntry = nil
WheelController._wheelEntryClickButton = nil
WheelController._wheelColorBg = nil
WheelController._wheelClaim = nil
WheelController._wheelClaimTemplate = nil
WheelController._wheelClaimGiftSourceRoot = nil
WheelController._wheelClaimGeneratedItem = nil
WheelController._infoText = nil
WheelController._freeCountdownText = nil
WheelController._remainingText = nil
WheelController._warningFrame = nil
WheelController._warningText = nil
WheelController._requestStateEvent = nil
WheelController._stateSyncEvent = nil
WheelController._requestSpinEvent = nil
WheelController._spinResultEvent = nil
WheelController._requestPurchaseContextEvent = nil
WheelController._latestState = {
    wheelSpins = 0,
    nextFreeSpinInSeconds = WheelConfig.FreeSpinIntervalSeconds,
    receivedAt = os.clock(),
}
WheelController._bindRetryQueued = false
WheelController._isOpen = false
WheelController._isSpinning = false
WheelController._isDead = false
WheelController._suppressSpinResult = false
WheelController._panelTweens = {}
WheelController._panelAnimationSerial = 0
WheelController._warningToken = 0
WheelController._spinTween = nil
WheelController._spinSegmentSoundActive = false
WheelController._spinSegmentSoundStartRotation = nil
WheelController._spinSegmentSoundLastRelativeRotation = 0
WheelController._spinSegmentSoundNextThreshold = nil
WheelController._wheelClaimPopupSerial = 0
WheelController._wheelClaimTweens = {}

local HOVER_SCALE = 1.06
local PRESS_SCALE = 0.92
local ICON_HOVER_SCALE = 1.1
local ICON_PRESS_SCALE = 0.94
local CLOSE_HOVER_ROTATION = 18
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local ICON_ROTATION_SPEED = 36
local SPIN_DURATION_SECONDS = 3
local SPIN_EXTRA_TURNS = 5
local WHEEL_CLAIM_VISIBLE_SECONDS = 2
local WHEEL_CLAIM_FROM_SCALE = 0.55
local WHEEL_CLAIM_OVERSHOOT_SCALE = 1.12
local WHEEL_CLAIM_POP_DURATION = 0.18
local WHEEL_CLAIM_SETTLE_DURATION = 0.1
local WHEEL_CLAIM_MODAL_OWNER = "WheelClaim"
local WHEEL_SEGMENT_SOUND_FIRST_THRESHOLD_DEGREES = 30
local WHEEL_SEGMENT_SOUND_INTERVAL_DEGREES = 60

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
    return parent and parent:FindFirstChild(name, true) or nil
end

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function formatTime(seconds)
    local totalSeconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local minutes = math.floor(totalSeconds / 60)
    local remainingSeconds = totalSeconds % 60
    return string.format("%02d:%02d", minutes, remainingSeconds)
end

local function playTween(binding, key, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existing = binding.tweens[key]
    if existing then
        existing:Cancel()
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

function WheelController:_ensurePanelWarning()
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return nil, nil
    end

    local warning = self._panel:FindFirstChild("WheelWarning")
    if warning and not warning:IsA("TextLabel") then
        warning:Destroy()
        warning = nil
    end

    if not warning then
        warning = Instance.new("TextLabel")
        warning.Name = "WheelWarning"
        warning.AnchorPoint = Vector2.new(0.5, 0.5)
        warning.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
        warning.BackgroundTransparency = 0.15
        warning.BorderSizePixel = 0
        warning.Font = Enum.Font.GothamBold
        warning.Position = UDim2.fromScale(0.5, 0.09)
        warning.Size = UDim2.fromScale(0.52, 0.08)
        warning.Text = ""
        warning.TextColor3 = Color3.fromRGB(255, 255, 255)
        warning.TextScaled = true
        warning.Visible = false
        warning.ZIndex = 1000
        warning.Parent = self._panel

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = warning

        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(255, 92, 92)
        stroke.Thickness = 2
        stroke.Transparency = 0.15
        stroke.Parent = warning
    end

    return warning, warning
end

function WheelController:_applyButtonState(binding)
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

function WheelController:_bindButton(button, onActivated, options)
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
        scaleTarget = scaleTarget,
        rotationTarget = rotationTarget,
        uiScale = uiScale,
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
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    table.insert(self._buttonBindings, binding)
end

function WheelController:_disconnectButtonBindings()
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

function WheelController:_ensureWheelEntryClickButton()
    if not (self._wheelEntry and self._wheelEntry:IsA("GuiObject")) then
        return nil
    end

    for _, descendant in ipairs(self._wheelEntry:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            return descendant
        end
    end

    local clickButton = self._wheelEntry:FindFirstChild("WheelClickButton")
    if clickButton and clickButton:IsA("TextButton") then
        return clickButton
    end

    clickButton = Instance.new("TextButton")
    clickButton.Name = "WheelClickButton"
    clickButton.BackgroundTransparency = 1
    clickButton.BorderSizePixel = 0
    clickButton.Text = ""
    clickButton.AutoButtonColor = false
    clickButton.Size = UDim2.fromScale(1, 1)
    clickButton.Position = UDim2.fromScale(0, 0)
    clickButton.ZIndex = self._wheelEntry.ZIndex + 10
    clickButton.Parent = self._wheelEntry
    return clickButton
end

function WheelController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function WheelController:_cancelWheelClaimTweens()
    for _, tween in ipairs(self._wheelClaimTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._wheelClaimTweens)
end

function WheelController:_clearWheelClaimItem()
    if self._wheelClaimGeneratedItem and self._wheelClaimGeneratedItem.Parent then
        self._wheelClaimGeneratedItem:Destroy()
    end
    self._wheelClaimGeneratedItem = nil
end

function WheelController:_hideWheelClaim()
    self:_cancelWheelClaimTweens()
    self:_clearWheelClaimItem()
    if self._wheelClaim and self._wheelClaim.Parent then
        self._wheelClaim.Visible = false
    end
    ModalUiController:Release(WHEEL_CLAIM_MODAL_OWNER)
end

function WheelController:_findWheelClaimGiftSourceRoot()
    local uiFolder = ReplicatedStorage:FindFirstChild("UI")
    local wheelBg = uiFolder and uiFolder:FindFirstChild("WheelBg")
    return wheelBg and wheelBg:FindFirstChild("WheelColorBg", true) or nil
end

function WheelController:_resolveRewardGiftName(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local giftName = tostring(reward.giftName or reward.GiftName or "")
    if giftName ~= "" then
        return giftName
    end

    local slot = math.floor(tonumber(reward.slot or reward.Slot) or 0)
    if slot > 0 then
        return "Gift" .. tostring(slot)
    end

    return nil
end

function WheelController:_showWheelClaim(reward)
    if self._isDead then
        return
    end

    if not (self._wheelClaim and self._wheelClaim:IsA("GuiObject")) then
        self:_bindUi(true)
    end
    if not (self._wheelClaim and self._wheelClaim:IsA("GuiObject")) then
        return
    end

    local giftName = self:_resolveRewardGiftName(reward)
    if not giftName then
        return
    end

    local sourceRoot = self._wheelClaimGiftSourceRoot
    if not (sourceRoot and sourceRoot.Parent) then
        sourceRoot = self:_findWheelClaimGiftSourceRoot()
        self._wheelClaimGiftSourceRoot = sourceRoot
    end
    local source = sourceRoot and sourceRoot:FindFirstChild(giftName)
    if not (source and source:IsA("GuiObject")) then
        return
    end

    if self._audioSettings and self._audioSettings.PlaySfxByPath then
        self._audioSettings:PlaySfxByPath("UI", { "Banana collect 18" }, true)
    end

    self._wheelClaimPopupSerial += 1
    local serial = self._wheelClaimPopupSerial
    self:_cancelWheelClaimTweens()
    self:_clearWheelClaimItem()

    local item = source:Clone()
    item.Name = giftName
    item.AnchorPoint = Vector2.new(0.5, 0.5)
    item.Rotation = 0
    item.Size = UDim2.new(0.5, 0, 0.5, 0)
    item.Position = UDim2.new(0.5, 0, 0.5, 0)
    item.Visible = true
    item.Parent = self._wheelClaim
    self._wheelClaimGeneratedItem = item

    if self._wheelClaimTemplate and self._wheelClaimTemplate:IsA("GuiObject") then
        self._wheelClaimTemplate.Visible = false
    end

    self._wheelClaim.ZIndex = math.max(50, tonumber(self._wheelClaim.ZIndex) or 0)
    item.ZIndex = math.max(item.ZIndex, self._wheelClaim.ZIndex + 1)

    local uiScale = ensureUiScale(self._wheelClaim)
    ModalUiController:Acquire(WHEEL_CLAIM_MODAL_OWNER, self._wheelClaim)
    self._wheelClaim.Visible = true
    if not uiScale then
        task.delay(WHEEL_CLAIM_VISIBLE_SECONDS, function()
            if self._wheelClaimPopupSerial ~= serial then
                return
            end
            self:_hideWheelClaim()
        end)
        return
    end

    uiScale.Scale = WHEEL_CLAIM_FROM_SCALE
    local popTween = TweenService:Create(uiScale, TweenInfo.new(WHEEL_CLAIM_POP_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Scale = WHEEL_CLAIM_OVERSHOOT_SCALE,
    })
    local settleTween = TweenService:Create(uiScale, TweenInfo.new(WHEEL_CLAIM_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = 1,
    })
    self._wheelClaimTweens = { popTween, settleTween }
    task.spawn(function()
        popTween:Play()
        popTween.Completed:Wait()
        if self._wheelClaimPopupSerial ~= serial then
            return
        end

        settleTween:Play()
        settleTween.Completed:Wait()
        if self._wheelClaimPopupSerial ~= serial then
            return
        end

        uiScale.Scale = 1
        table.clear(self._wheelClaimTweens)
    end)

    task.delay(WHEEL_CLAIM_VISIBLE_SECONDS, function()
        if self._wheelClaimPopupSerial ~= serial then
            return
        end
        if uiScale and uiScale.Parent then
            uiScale.Scale = 1
        end
        self:_hideWheelClaim()
    end)
end

function WheelController:_setOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:Release("Wheel")
        end
        return
    end

    if isOpen == true and self._isDead then
        return
    end

    local uiScale = ensureUiScale(self._panel)
    self:_cancelPanelTweens()
    self._panelAnimationSerial += 1
    local animationSerial = self._panelAnimationSerial
    self._isOpen = isOpen == true

    if self._isOpen then
        ModalUiController:Acquire("Wheel", self._panel)
        self._panel.Visible = true
        if self._requestStateEvent then
            self._requestStateEvent:FireServer({
                intent = "WheelOpened",
                source = "Wheel",
            })
        end
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
            if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                return
            end

            settleTween:Play()
            settleTween.Completed:Wait()
            if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
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
        ModalUiController:Release("Wheel")
        return
    end

    local shrinkTween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { shrinkTween }
    task.spawn(function()
        shrinkTween:Play()
        shrinkTween.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end

        uiScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release("Wheel")
    end)
end

function WheelController:_getRemainingCountdown()
    local state = self._latestState or {}
    local baseSeconds = tonumber(state.nextFreeSpinInSeconds) or WheelConfig.FreeSpinIntervalSeconds or 300
    local receivedAt = tonumber(state.receivedAt) or os.clock()
    return math.max(0, baseSeconds - (os.clock() - receivedAt))
end

function WheelController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end

    self._latestState = {
        wheelSpins = math.max(0, math.floor(tonumber(payload.wheelSpins) or 0)),
        nextFreeSpinInSeconds = math.max(0, tonumber(payload.nextFreeSpinInSeconds) or WheelConfig.FreeSpinIntervalSeconds or 300),
        freeSpinIntervalSeconds = tonumber(payload.freeSpinIntervalSeconds) or WheelConfig.FreeSpinIntervalSeconds or 300,
        receivedAt = os.clock(),
    }
    self:_refreshTexts()
end

function WheelController:_refreshTexts()
    local spins = math.max(0, math.floor(tonumber(self._latestState and self._latestState.wheelSpins) or 0))
    local countdownText = formatTime(self:_getRemainingCountdown())

    if spins >= 1 then
        setText(self._infoText, tostring(spins))
    else
        setText(self._infoText, countdownText)
    end
    setText(self._freeCountdownText, countdownText)
    setText(self._remainingText, tostring(spins))
end

function WheelController:_showWarning(message)
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

function WheelController:_resetSpinSegmentSound()
    self._spinSegmentSoundActive = false
    self._spinSegmentSoundStartRotation = nil
    self._spinSegmentSoundLastRelativeRotation = 0
    self._spinSegmentSoundNextThreshold = nil
end

function WheelController:_cancelSpinTween()
    if self._spinTween then
        self._spinTween:Cancel()
        self._spinTween = nil
    end
    self:_resetSpinSegmentSound()
    self._isSpinning = false
end

function WheelController:_handlePlayerDefeated()
    self._isDead = true
    self._suppressSpinResult = true
    self._wheelClaimPopupSerial += 1
    self:_cancelSpinTween()
    self:_hideWheelClaim()
    self:_setOpen(false, true)
end

function WheelController:_beginSpinSegmentSound(startRotation)
    self._spinSegmentSoundActive = true
    self._spinSegmentSoundStartRotation = tonumber(startRotation) or 0
    self._spinSegmentSoundLastRelativeRotation = 0
    self._spinSegmentSoundNextThreshold = WHEEL_SEGMENT_SOUND_FIRST_THRESHOLD_DEGREES
end

function WheelController:_playWheelSegmentSound()
    if not self._audioSettings then
        return
    end

    if self._audioSettings.PlaySfxOneShotByPath then
        self._audioSettings:PlaySfxOneShotByPath("UI", { "wheel" })
    elseif self._audioSettings.PlaySfxByPath then
        self._audioSettings:PlaySfxByPath("UI", { "wheel" }, true)
    end
end

function WheelController:_updateSpinSegmentSound(currentRotation)
    if self._spinSegmentSoundActive ~= true then
        return
    end

    local startRotation = self._spinSegmentSoundStartRotation
    if type(startRotation) ~= "number" then
        return
    end

    local rotation = tonumber(currentRotation)
    if not rotation then
        if not (self._wheelColorBg and self._wheelColorBg.Parent) then
            return
        end
        rotation = tonumber(self._wheelColorBg.Rotation) or startRotation
    end

    local relativeRotation = rotation - startRotation
    if relativeRotation < 0 then
        return
    end

    local nextThreshold = self._spinSegmentSoundNextThreshold or WHEEL_SEGMENT_SOUND_FIRST_THRESHOLD_DEGREES
    while relativeRotation >= nextThreshold do
        self:_playWheelSegmentSound()
        nextThreshold += WHEEL_SEGMENT_SOUND_INTERVAL_DEGREES
    end

    self._spinSegmentSoundNextThreshold = nextThreshold
    self._spinSegmentSoundLastRelativeRotation = relativeRotation
end

function WheelController:_promptPurchase(productId)
    local resolvedProductId = tonumber(productId) or 0
    if resolvedProductId <= 0 then
        return
    end
    if not (self._localPlayer and self._localPlayer.Parent) then
        return
    end

    if self._requestPurchaseContextEvent then
        self._requestPurchaseContextEvent:FireServer({
            intent = "BuyClicked",
            source = "Wheel",
            purchaseType = "WheelSpins",
            productGroup = "WheelSpins",
            itemSku = tostring(resolvedProductId),
            productId = resolvedProductId,
        })
        self._requestPurchaseContextEvent:FireServer({
            intent = "PaidSpinPurchaseClicked",
            source = "Wheel",
            purchaseType = "WheelSpins",
            productGroup = "WheelSpins",
            itemSku = tostring(resolvedProductId),
            productId = resolvedProductId,
        })
        self._requestPurchaseContextEvent:FireServer({
            intent = "PurchasePromptRequested",
            source = "Wheel",
            purchaseType = "WheelSpins",
            productGroup = "WheelSpins",
            itemSku = tostring(resolvedProductId),
            productId = resolvedProductId,
        })
    end
    MarketplaceService:PromptProductPurchase(self._localPlayer, resolvedProductId)
end

function WheelController:_requestSpin()
    if self._isDead then
        return
    end

    if self._isSpinning then
        return
    end

    local spins = math.max(0, math.floor(tonumber(self._latestState and self._latestState.wheelSpins) or 0))
    if spins <= 0 then
        self:_showWarning("Not enough spins.")
        return
    end

    if not self._requestSpinEvent then
        self:_showWarning("Wheel is unavailable.")
        return
    end

    self._isSpinning = true
    self._suppressSpinResult = false
    self:_resetSpinSegmentSound()
    self._requestSpinEvent:FireServer()
end

function WheelController:_playSpinTo(targetRotation, onComplete)
    if not self._wheelColorBg then
        self:_resetSpinSegmentSound()
        if type(onComplete) == "function" then
            onComplete()
        end
        return
    end

    if self._spinTween then
        self._spinTween:Cancel()
        self._spinTween = nil
    end
    self:_resetSpinSegmentSound()

    local startRotation = tonumber(self._wheelColorBg.Rotation) or 0
    local normalizedStart = startRotation % 360
    local normalizedTarget = (tonumber(targetRotation) or 0) % 360
    local clockwiseDelta = (normalizedTarget - normalizedStart) % 360
    local finalRotation = startRotation + (SPIN_EXTRA_TURNS * 360) + clockwiseDelta

    local tween = TweenService:Create(self._wheelColorBg, TweenInfo.new(SPIN_DURATION_SECONDS, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Rotation = finalRotation,
    })
    self._spinTween = tween
    self:_beginSpinSegmentSound(startRotation)
    tween.Completed:Connect(function(playbackState)
        if self._spinTween ~= tween then
            return
        end

        if playbackState ~= Enum.PlaybackState.Completed then
            self._spinTween = nil
            self:_resetSpinSegmentSound()
            return
        end

        self:_updateSpinSegmentSound(finalRotation)
        self._spinTween = nil
        self:_resetSpinSegmentSound()
        if self._wheelColorBg and self._wheelColorBg.Parent then
            self._wheelColorBg.Rotation = normalizedTarget
        end
        if type(onComplete) == "function" then
            onComplete()
        end
    end)
    tween:Play()
end

function WheelController:_handleSpinResult(payload)
    if type(payload) ~= "table" then
        self:_resetSpinSegmentSound()
        self._isSpinning = false
        return
    end

    if payload.state then
        self:_applyState(payload.state)
    end

    if self._isDead or self._suppressSpinResult then
        self:_cancelSpinTween()
        return
    end

    if payload.ok ~= true then
        self:_resetSpinSegmentSound()
        self._isSpinning = false
        if payload.reason == "NotEnoughSpins" then
            self:_showWarning("Not enough spins.")
        elseif payload.reason == "DataLoading" then
            self:_showWarning("Data is loading.")
        else
            self:_showWarning("Wheel is unavailable.")
        end
        return
    end

    local targetRotation = payload.targetRotation
    if not targetRotation and type(payload.reward) == "table" then
        targetRotation = payload.reward.targetRotation
    end

    self:_playSpinTo(targetRotation, function()
        self._isSpinning = false
        if self._isDead or self._suppressSpinResult then
            return
        end

        if payload.state then
            self:_applyState(payload.state)
        end
        self:_showWheelClaim(payload.reward)
    end)
end

function WheelController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    if not mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local panel = mainGui:FindFirstChild("WheelBg")
    local leftRoot = mainGui:FindFirstChild("Left")
    local wheelEntry = leftRoot and leftRoot:FindFirstChild("Wheel")
    if not (panel and wheelEntry and panel:IsA("GuiObject") and wheelEntry:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self._panel = panel
    self._wheelEntry = wheelEntry
    self._wheelEntryClickButton = self:_ensureWheelEntryClickButton()
    self._wheelColorBg = panel:FindFirstChild("WheelColorBg")
    self._wheelClaim = mainGui:FindFirstChild("WheelClaim")
    self._wheelClaimTemplate = self._wheelClaim and self._wheelClaim:FindFirstChild("GiftTemplate")
    self._wheelClaimGiftSourceRoot = self:_findWheelClaimGiftSourceRoot()
    self._infoText = findDescendant(wheelEntry, "Text")
    local freeCountdownRoot = panel:FindFirstChild("FreeCountDownTime")
    local remainingRoot = panel:FindFirstChild("RemainingTime")
    self._freeCountdownText = freeCountdownRoot and freeCountdownRoot:FindFirstChild("Time")
    self._remainingText = remainingRoot and remainingRoot:FindFirstChild("Time")
    self._warningFrame, self._warningText = self:_ensurePanelWarning()
    if not self._warningFrame then
        self._warningFrame = mainGui:FindFirstChild("Warning")
        self._warningText = self._warningFrame and self._warningFrame:FindFirstChild("Text")
    end

    if self._panel.Visible ~= false then
        self._panel.Visible = false
    end
    if self._wheelClaim and self._wheelClaim:IsA("GuiObject") then
        self._wheelClaim.Visible = false
    end
    if self._wheelClaimTemplate and self._wheelClaimTemplate:IsA("GuiObject") then
        self._wheelClaimTemplate.Visible = false
    end
    local wheelIconRoot = mainGui:FindFirstChild("WheelIcon")
    if wheelIconRoot and wheelIconRoot:IsA("GuiObject") then
        wheelIconRoot.Visible = false
    end

    if self._wheelEntryClickButton then
        self:_bindButton(self._wheelEntryClickButton, function()
            self:_setOpen(true)
        end, {
            ScaleTarget = wheelEntry,
            HoverScale = ICON_HOVER_SCALE,
            PressScale = ICON_PRESS_SCALE,
        })
    end

    local closeButton = panel:FindFirstChild("CloseButton")
    self:_bindButton(closeButton, function()
        self:_setOpen(false)
    end, {
        RotationTarget = closeButton,
        HoverRotation = CLOSE_HOVER_ROTATION,
    })

    local spinButton = panel:FindFirstChild("SpinButton")
    self:_bindButton(spinButton, function()
        self:_requestSpin()
    end)

    for _, purchase in ipairs(WheelConfig.Purchases) do
        local button = panel:FindFirstChild("Spin+" .. tostring(purchase.Spins))
        self:_bindButton(button, function()
            self:_promptPurchase(purchase.ProductId)
        end)
    end

    self:_refreshTexts()
    return true
end

function WheelController:_queueBindRetry()
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
        warn("[WheelController] Could not find PlayerGui/Main/WheelBg and Left.Wheel.")
    end)
end

function WheelController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[WheelController] Missing system events folder.")
        return
    end

    self._requestStateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestWheelStateSync, 10)
    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WheelStateSync, 10)
    self._requestSpinEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestWheelSpin, 10)
    self._spinResultEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WheelSpinResult, 10)
    self._requestPurchaseContextEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestShopPurchaseContext, 10)
    local deathFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.DeathFeedback, 10)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyState(payload)
        end))
    end

    if self._spinResultEvent then
        table.insert(self._connections, self._spinResultEvent.OnClientEvent:Connect(function(payload)
            self:_handleSpinResult(payload)
        end))
    end

    if deathFeedbackEvent then
        table.insert(self._connections, deathFeedbackEvent.OnClientEvent:Connect(function()
            self:_handlePlayerDefeated()
        end))
    end

    if playerStateSyncEvent then
        table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
            if type(payload) ~= "table" then
                return
            end

            if payload.alive == false then
                self:_handlePlayerDefeated()
            elseif payload.alive == true then
                self._isDead = false
            end
        end))
    end

    if self._requestStateEvent then
        self._requestStateEvent:FireServer()
    end
end

function WheelController:Open()
    if self._isDead then
        return
    end

    if not self._panel then
        self:_bindUi(true)
    end
    self:_setOpen(true)
    if self._requestStateEvent then
        self._requestStateEvent:FireServer()
    end
end

function WheelController:Close(immediate)
    self:_setOpen(false, immediate == true)
end

function WheelController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    self._isDead = false
    self._suppressSpinResult = false
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_hideWheelClaim()

    self:_connectRemotes()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                    if self._requestStateEvent then
                        self._requestStateEvent:FireServer()
                    end
                end)
            end
        end))
    end

    table.insert(self._connections, RunService.RenderStepped:Connect(function(deltaTime)
        if self._wheelEntry and self._wheelEntry.Parent then
            self._wheelEntry.Rotation = (self._wheelEntry.Rotation + (ICON_ROTATION_SPEED * deltaTime)) % 360
        end
        self:_updateSpinSegmentSound()
        self:_refreshTexts()
    end))
end

return WheelController
