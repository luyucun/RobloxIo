--[[
Script: SubscriptionController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/SubscriptionController
Purpose: V3.3 SugarClub subscription UI, purchase prompt, and daily claim request.
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
        "[SubscriptionController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local SubscriptionConfig = requireSharedModule("SubscriptionConfig")

local SubscriptionController = {}

SubscriptionController._localPlayer = nil
SubscriptionController._connections = {}
SubscriptionController._buttonBindings = {}
SubscriptionController._mainGui = nil
SubscriptionController._clubEntry = nil
SubscriptionController._clubButton = nil
SubscriptionController._clubRedPoint = nil
SubscriptionController._clubAddLabel = nil
SubscriptionController._panel = nil
SubscriptionController._startFrame = nil
SubscriptionController._claimFrame = nil
SubscriptionController._buyButton = nil
SubscriptionController._claimButton = nil
SubscriptionController._closeButton = nil
SubscriptionController._requestStateEvent = nil
SubscriptionController._stateSyncEvent = nil
SubscriptionController._requestClaimEvent = nil
SubscriptionController._feedbackEvent = nil
SubscriptionController._playerStateSyncEvent = nil
SubscriptionController._latestState = {
    isSubscribed = false,
    dailyClaimed = false,
    dailyClaimAvailable = false,
}
SubscriptionController._isOpen = false
SubscriptionController._isClaiming = false
SubscriptionController._lastRedPointVisible = false
SubscriptionController._redPointAnimationSerial = 0
SubscriptionController._bindRetryQueued = false
SubscriptionController._panelTweens = {}
SubscriptionController._panelAnimationSerial = 0

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.92
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local RED_POINT_SHAKE_DURATION = 0.055
local RED_POINT_SHAKE_OFFSET = 6
local RED_POINT_SCALE = 1.18

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

local function findButton(root, name)
    if not root then
        return nil, nil
    end

    if root.Name == name and root:IsA("GuiButton") then
        return root, root
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant.Name == name and descendant:IsA("GuiButton") then
            return descendant, descendant
        end
    end

    local node = root:FindFirstChild(name, true)
    if not node then
        return nil, nil
    end
    if node:IsA("GuiButton") then
        return node, node
    end
    if node:IsA("GuiObject") then
        local nestedButton = node:FindFirstChildWhichIsA("GuiButton", true)
        if nestedButton then
            return nestedButton, node
        end
    end
    return nil, nil
end

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function formatRobuxPrice(value)
    local price = tonumber(value)
    if not price then
        return nil
    end
    return tostring(math.max(0, math.floor(price + 0.5)))
end

local function setSubscriptionPrice(textObject, subscriptionId)
    if not textObject then
        return
    end

    local resolvedSubscriptionId = tostring(subscriptionId or "")
    if resolvedSubscriptionId == "" then
        return
    end

    local fallbackText = tostring(textObject.Text or "")
    setText(textObject, "...")
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetSubscriptionProductInfoAsync(resolvedSubscriptionId)
        end)
        if not (success and type(productInfo) == "table") then
            if fallbackText ~= "" then
                setText(textObject, fallbackText)
            end
            return
        end

        local priceText = formatRobuxPrice(productInfo.PriceInRobux)
        if priceText then
            setText(textObject, priceText)
        elseif fallbackText ~= "" then
            setText(textObject, fallbackText)
        end
    end)
end

local function getFirstChildByNames(parent, names)
    for _, name in ipairs(names) do
        local child = parent and parent:FindFirstChild(name)
        if child then
            return child
        end
    end
    for _, name in ipairs(names) do
        local descendant = parent and parent:FindFirstChild(name, true)
        if descendant then
            return descendant
        end
    end
    return nil
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

local function readColor(value, fallback)
    if typeof(value) == "Color3" then
        return value
    end
    return fallback
end

function SubscriptionController:_notify(message)
    task.spawn(function()
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "Sugar Club",
                Text = tostring(message or ""),
                Duration = 2,
            })
        end)
    end)
end

function SubscriptionController:_applyButtonState(binding)
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

function SubscriptionController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = type(options) == "table" and options.ScaleTarget or button
    local rotationTarget = type(options) == "table" and options.RotationTarget or nil
    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        rotationTarget = rotationTarget,
        baseScale = uiScale.Scale,
        baseRotation = rotationTarget and rotationTarget.Rotation or 0,
        hoverScale = type(options) == "table" and tonumber(options.HoverScale) or HOVER_SCALE,
        pressScale = type(options) == "table" and tonumber(options.PressScale) or PRESS_SCALE,
        hoverRotation = type(options) == "table" and tonumber(options.HoverRotation) or 0,
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

function SubscriptionController:_disconnectButtonBindings()
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

function SubscriptionController:_resolveClubScaleTarget()
    if not self._clubEntry then
        return nil
    end

    local icon = self._clubEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    local label = self._clubEntry:FindFirstChild("TextLabel", true)
    if label and label:IsA("GuiObject") then
        return label
    end

    return self._clubEntry
end

function SubscriptionController:_resolveClubRotationTarget()
    if not self._clubEntry then
        return nil
    end

    local icon = self._clubEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveClubScaleTarget()
end

function SubscriptionController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function SubscriptionController:_playRedPointShake()
    if not (self._clubRedPoint and self._clubRedPoint:IsA("GuiObject")) then
        return
    end

    self._redPointAnimationSerial += 1
    local animationSerial = self._redPointAnimationSerial
    local redPoint = self._clubRedPoint
    local originalPosition = redPoint.Position
    local uiScale = ensureUiScale(redPoint)
    local originalScale = uiScale and uiScale.Scale or 1

    task.spawn(function()
        local offsets = { -RED_POINT_SHAKE_OFFSET, RED_POINT_SHAKE_OFFSET, -math.floor(RED_POINT_SHAKE_OFFSET * 0.6), math.floor(RED_POINT_SHAKE_OFFSET * 0.6), 0 }
        for index, offset in ipairs(offsets) do
            if self._redPointAnimationSerial ~= animationSerial or not (redPoint and redPoint.Parent) then
                return
            end

            local targetScale = index == 1 and originalScale * RED_POINT_SCALE or originalScale
            local nextPosition = UDim2.new(
                originalPosition.X.Scale,
                originalPosition.X.Offset + offset,
                originalPosition.Y.Scale,
                originalPosition.Y.Offset
            )
            local tween = TweenService:Create(redPoint, TweenInfo.new(RED_POINT_SHAKE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = nextPosition,
            })
            local scaleTween = uiScale and TweenService:Create(uiScale, TweenInfo.new(RED_POINT_SHAKE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Scale = targetScale,
            }) or nil
            tween:Play()
            if scaleTween then
                scaleTween:Play()
            end
            tween.Completed:Wait()
        end

        if self._redPointAnimationSerial == animationSerial and redPoint and redPoint.Parent then
            redPoint.Position = originalPosition
            if uiScale and uiScale.Parent then
                uiScale.Scale = originalScale
            end
        end
    end)
end

function SubscriptionController:_setOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:PlayPanelClose("SugarClub", nil, { Immediate = true })
        end
        return
    end

    self._isOpen = isOpen == true

    if self._isOpen then
        self:_requestStateSync()
        ModalUiController:PlayPanelOpen("SugarClub", self._panel, {
            Immediate = immediate == true,
        })
        return
    end

    ModalUiController:PlayPanelClose("SugarClub", self._panel, {
        Immediate = immediate == true,
    })
end

function SubscriptionController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end

    self._latestState = {
        isSubscribed = payload.isSubscribed == true or payload.subscriptionActive == true,
        dailyClaimed = payload.dailyClaimed == true or payload.subscriptionDailyClaimed == true,
        dailyClaimAvailable = payload.dailyClaimAvailable == true or payload.subscriptionDailyClaimAvailable == true,
        reason = payload.statusReason,
        receivedAt = os.clock(),
    }
    self:_refreshUi()
end

function SubscriptionController:_refreshUi()
    local isSubscribed = self._latestState and self._latestState.isSubscribed == true
    local dailyClaimed = self._latestState and self._latestState.dailyClaimed == true
    local dailyClaimAvailable = self._latestState and self._latestState.dailyClaimAvailable == true

    if self._startFrame and self._startFrame:IsA("GuiObject") then
        self._startFrame.Visible = not isSubscribed
    end
    if self._buyButton and self._buyButton:IsA("GuiObject") then
        self._buyButton.Visible = not isSubscribed
    end
    if self._claimFrame and self._claimFrame:IsA("GuiObject") then
        self._claimFrame.Visible = isSubscribed
    end
    if self._claimButton and self._claimButton:IsA("GuiObject") then
        self._claimButton.Visible = isSubscribed
    end
    if self._claimButton and self._claimButton:IsA("GuiButton") then
        self._claimButton.Active = isSubscribed and not dailyClaimed and not self._isClaiming
        self._claimButton.AutoButtonColor = isSubscribed and not dailyClaimed and not self._isClaiming
    end

    if self._clubRedPoint and self._clubRedPoint:IsA("GuiObject") then
        self._clubRedPoint.Visible = dailyClaimAvailable
        if dailyClaimAvailable and not self._lastRedPointVisible then
            self:_playRedPointShake()
        end
        self._lastRedPointVisible = dailyClaimAvailable
    end
    if self._clubAddLabel and self._clubAddLabel:IsA("TextLabel") then
        self._clubAddLabel.Text = isSubscribed and (SubscriptionConfig.ActiveBonusText or "+100%") or (SubscriptionConfig.InactiveBonusText or "+0%")
        self._clubAddLabel.TextColor3 = isSubscribed
            and readColor(SubscriptionConfig.ActiveBonusTextColor, Color3.fromRGB(70, 255, 120))
            or readColor(SubscriptionConfig.InactiveBonusTextColor, Color3.fromRGB(255, 255, 255))
    end
end

function SubscriptionController:_requestStateSync()
    if self._requestStateEvent then
        self._requestStateEvent:FireServer()
    end
end

function SubscriptionController:_promptPurchase()
    if not (self._localPlayer and self._localPlayer.Parent) then
        return
    end

    MarketplaceService:PromptSubscriptionPurchase(self._localPlayer, SubscriptionConfig.SubscriptionId)
end

function SubscriptionController:_requestClaim()
    if self._isClaiming then
        return
    end
    if not (self._requestClaimEvent and self._latestState and self._latestState.isSubscribed == true) then
        self:_notify("Subscription required.")
        return
    end
    if self._latestState.dailyClaimed == true then
        self:_notify("Today's reward has already been claimed.")
        return
    end

    self._isClaiming = true
    self:_refreshUi()
    self._requestClaimEvent:FireServer()
end

function SubscriptionController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        self._isClaiming = false
        self:_refreshUi()
        return
    end

    if payload.state then
        self:_applyState(payload.state)
    end

    self._isClaiming = false
    self:_refreshUi()
    local eventType = tostring(payload.eventType or "")
    if eventType == "Success" then
        self:_notify("Daily reward claimed.")
    elseif payload.message and payload.message ~= "" then
        self:_notify(payload.message)
    end
end

function SubscriptionController:Open()
    if not self._panel then
        self:_bindUi(true)
    end
    self:_setOpen(true)
end

function SubscriptionController:PromptPurchase()
    self:_promptPurchase()
end

function SubscriptionController:_bindUi(silent)
    self:_disconnectButtonBindings()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            warn("[SubscriptionController] Main GUI not found")
        end
        return false
    end

    local bottomLeft = self._mainGui:FindFirstChild("BottomLeft")
    self._clubEntry = bottomLeft and bottomLeft:FindFirstChild("Club") or self._mainGui:FindFirstChild("Club", true)
    self._clubButton = nil
    if self._clubEntry then
        if self._clubEntry:IsA("GuiButton") then
            self._clubButton = self._clubEntry
        else
            self._clubButton = self._clubEntry:FindFirstChildWhichIsA("GuiButton", true)
        end
    end
    self._clubRedPoint = self._clubEntry and self._clubEntry:FindFirstChild("RedPoint", true) or nil
    self._clubAddLabel = self._clubEntry and self._clubEntry:FindFirstChild("Add", true) or nil
    if self._clubRedPoint and self._clubRedPoint:IsA("GuiObject") then
        self._clubRedPoint.Visible = false
        self._lastRedPointVisible = false
    end

    self._panel = self._mainGui:FindFirstChild("SugarClub")
    if not self._panel then
        self._panel = self._mainGui:FindFirstChild("SugarClub", true)
    end
    if self._panel and self._panel:IsA("GuiObject") then
        self._panel.Visible = false
    end

    self._startFrame = self._panel and self._panel:FindFirstChild("Start", true) or nil
    self._claimFrame = self._panel and getFirstChildByNames(self._panel, { "Claim", "CLaim" }) or nil
    self._buyButton = self._panel and select(1, findButton(self._panel, "BuyButton")) or nil
    setSubscriptionPrice(self._buyButton and self._buyButton:FindFirstChild("RMoney", true), SubscriptionConfig.SubscriptionId)
    self._claimButton = self._panel and (select(1, findButton(self._panel, "Claim")) or select(1, findButton(self._panel, "CLaim"))) or nil
    if self._claimButton and self._claimButton == self._claimFrame then
        self._claimFrame = nil
    end
    local title = self._panel and self._panel:FindFirstChild("Title", true) or nil
    self._closeButton = title and select(1, findButton(title, "CloseButton")) or (self._panel and select(1, findButton(self._panel, "CloseButton")) or nil)

    if self._clubButton then
        local clubScaleTarget = self:_resolveClubScaleTarget()
        local clubRotationTarget = self:_resolveClubRotationTarget()
        self:_bindButton(self._clubButton, function()
            self:_setOpen(true)
        end, {
            ScaleTarget = clubScaleTarget or self._clubButton,
            RotationTarget = clubRotationTarget,
            HoverScale = ENTRY_HOVER_SCALE,
            PressScale = ENTRY_PRESS_SCALE,
            HoverRotation = HOVER_ROTATION,
        })
    end
    if self._closeButton then
        self:_bindButton(self._closeButton, function()
            self:_setOpen(false)
        end)
    end
    if self._buyButton then
        self:_bindButton(self._buyButton, function()
            self:_promptPurchase()
        end)
    end
    if self._claimButton then
        self:_bindButton(self._claimButton, function()
            self:_requestClaim()
        end)
    end

    self:_refreshUi()
    return self._panel ~= nil and self._clubButton ~= nil
end

function SubscriptionController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    self._bindRetryQueued = true
    task.spawn(function()
        for _ = 1, 30 do
            task.wait(1)
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
        end
        self._bindRetryQueued = false
        warn("[SubscriptionController] Failed to bind SugarClub UI after retries")
    end)
end

function SubscriptionController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._connections = {}

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsFolder and eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if systemEventsFolder then
        self._requestStateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSubscriptionStateSync, 10)
        self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.SubscriptionStateSync, 10)
        self._requestClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSubscriptionClaim, 10)
        self._feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.SubscriptionFeedback, 10)
        self._playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)
    end

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyState(payload)
        end))
    end
    if self._feedbackEvent then
        table.insert(self._connections, self._feedbackEvent.OnClientEvent:Connect(function(payload)
            self:_handleFeedback(payload)
        end))
    end
    if self._playerStateSyncEvent then
        table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
            if type(payload) == "table" then
                self:_applyState({
                    isSubscribed = payload.subscriptionActive == true,
                    dailyClaimed = payload.subscriptionDailyClaimed == true,
                    dailyClaimAvailable = payload.subscriptionDailyClaimAvailable == true,
                })
            end
        end))
    end

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    self:_requestStateSync()
end

return SubscriptionController
