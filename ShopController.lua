--[[
Script: ShopController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/ShopController
Purpose: V3.5 shop UI bindings and shared ClaimSuccessful reward popup.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

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
        "[ShopController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local ShopConfig = requireSharedModule("ShopConfig")
local WheelConfig = requireSharedModule("WheelConfig")
local SkinConfig = requireSharedModule("SkinConfig")
local SubscriptionConfig = requireSharedModule("SubscriptionConfig")

local ShopController = {}

ShopController._localPlayer = nil
ShopController._connections = {}
ShopController._buttonBindings = {}
ShopController._marketStallConnections = {}
ShopController._popupItems = {}
ShopController._mainGui = nil
ShopController._leftEntry = nil
ShopController._panel = nil
ShopController._starterPackFrame = nil
ShopController._skinBuyButtonRoot = nil
ShopController._claimPopup = nil
ShopController._claimPopupTemplate = nil
ShopController._skinSecretGradients = {}
ShopController._skinSecretGradientState = {}
ShopController._skinSecretGradientConnection = nil
ShopController._requestStateEvent = nil
ShopController._stateSyncEvent = nil
ShopController._requestStarterPackClaimEvent = nil
ShopController._requestPurchaseContextEvent = nil
ShopController._rewardFeedbackEvent = nil
ShopController._requestSkinPurchaseEvent = nil
ShopController._wheelController = nil
ShopController._subscriptionController = nil
ShopController._sevenDayLoginRewardController = nil
ShopController._bindRetryQueued = false
ShopController._isOpen = false
ShopController._panelTweens = {}
ShopController._panelAnimationSerial = 0
ShopController._rewardPopupSerial = 0
ShopController._rewardPopupInputConnection = nil
ShopController._rewardPopupCanClose = false
ShopController._lastRewardSource = nil
ShopController._starterPackClaimed = false
ShopController._featuredSkinOwned = false
ShopController._marketStallBindRetryQueued = false
ShopController._marketStallTouchDebounceUntil = 0

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
local POPUP_SLIDE_OFFSET_SCALE = -0.22
local POPUP_OPEN_DURATION = 0.24
local POPUP_ITEM_STAGGER = 0.08
local POPUP_CLOSE_DELAY = 2
local MARKET_STALL_TOUCH_COOLDOWN = 1
local SECRET_GRADIENT_OFFSET_RANGE = 1
local SECRET_GRADIENT_ONE_WAY_DURATION = 2.4
local SECRET_GRADIENT_UPDATE_INTERVAL = 0.033

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

local function setMarketplaceRobuxPrice(textObject, itemId, infoType)
    if not textObject then
        return
    end

    local resolvedItemId = math.floor(tonumber(itemId) or 0)
    if resolvedItemId <= 0 then
        return
    end

    local fallbackText = tostring(textObject.Text or "")
    setText(textObject, "...")
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedItemId, infoType)
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

local function setSubscriptionRobuxPrice(textObject, subscriptionId)
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

local function setImage(imageObject, image)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(image or "")
    end
end

local function cloneColorSequence(colorSequence)
    if typeof(colorSequence) ~= "ColorSequence" then
        return ColorSequence.new(Color3.new(1, 1, 1))
    end
    local keypoints = {}
    for _, keypoint in ipairs(colorSequence.Keypoints) do
        table.insert(keypoints, ColorSequenceKeypoint.new(keypoint.Time, keypoint.Value))
    end
    return ColorSequence.new(keypoints)
end

local function cloneNumberSequence(numberSequence)
    if typeof(numberSequence) ~= "NumberSequence" then
        return NumberSequence.new(0)
    end
    local keypoints = {}
    for _, keypoint in ipairs(numberSequence.Keypoints) do
        table.insert(keypoints, NumberSequenceKeypoint.new(keypoint.Time, keypoint.Value, keypoint.Envelope))
    end
    return NumberSequence.new(keypoints)
end

local function modulo01(value)
    local parsed = tonumber(value) or 0
    parsed = parsed % 1
    if parsed < 0 then
        parsed = parsed + 1
    end
    return parsed
end

local function collectRotatedInteriorPositions(baseKeypoints, shift)
    local positions = {}
    for _, keypoint in ipairs(baseKeypoints) do
        local rotatedTime = modulo01((tonumber(keypoint.Time) or 0) + shift)
        if rotatedTime > 0.0001 and rotatedTime < 0.9999 then
            table.insert(positions, rotatedTime)
        end
    end

    table.sort(positions)

    local deduplicated = {}
    local lastTime = nil
    for _, timeValue in ipairs(positions) do
        if not lastTime or math.abs(timeValue - lastTime) > 0.0001 then
            table.insert(deduplicated, timeValue)
            lastTime = timeValue
        end
    end

    return deduplicated
end

local function sampleColorSequencePeriodic(baseKeypoints, timeValue)
    local count = #baseKeypoints
    if count <= 0 then
        return Color3.new(1, 1, 1)
    end

    if count == 1 then
        return baseKeypoints[1].Value
    end

    local targetTime = modulo01(timeValue)

    for index = 1, count - 1 do
        local left = baseKeypoints[index]
        local right = baseKeypoints[index + 1]
        if targetTime >= left.Time and targetTime <= right.Time then
            local span = math.max(0.000001, right.Time - left.Time)
            local alpha = math.clamp((targetTime - left.Time) / span, 0, 1)
            return left.Value:Lerp(right.Value, alpha)
        end
    end

    local last = baseKeypoints[count]
    local first = baseKeypoints[1]
    local wrappedTime = targetTime
    if wrappedTime < first.Time then
        wrappedTime = wrappedTime + 1
    end

    local span = math.max(0.000001, (first.Time + 1) - last.Time)
    local alpha = math.clamp((wrappedTime - last.Time) / span, 0, 1)
    return last.Value:Lerp(first.Value, alpha)
end

local function sampleNumberSequencePeriodic(baseKeypoints, timeValue)
    local count = #baseKeypoints
    if count <= 0 then
        return 0, 0
    end

    if count == 1 then
        return baseKeypoints[1].Value, baseKeypoints[1].Envelope
    end

    local targetTime = modulo01(timeValue)

    for index = 1, count - 1 do
        local left = baseKeypoints[index]
        local right = baseKeypoints[index + 1]
        if targetTime >= left.Time and targetTime <= right.Time then
            local span = math.max(0.000001, right.Time - left.Time)
            local alpha = math.clamp((targetTime - left.Time) / span, 0, 1)
            local value = left.Value + ((right.Value - left.Value) * alpha)
            local envelope = left.Envelope + ((right.Envelope - left.Envelope) * alpha)
            return value, envelope
        end
    end

    local last = baseKeypoints[count]
    local first = baseKeypoints[1]
    local wrappedTime = targetTime
    if wrappedTime < first.Time then
        wrappedTime = wrappedTime + 1
    end

    local span = math.max(0.000001, (first.Time + 1) - last.Time)
    local alpha = math.clamp((wrappedTime - last.Time) / span, 0, 1)
    local value = last.Value + ((first.Value - last.Value) * alpha)
    local envelope = last.Envelope + ((first.Envelope - last.Envelope) * alpha)
    return value, envelope
end

local function buildRotatedColorSequence(baseKeypoints, shift)
    local keypoints = {
        ColorSequenceKeypoint.new(0, sampleColorSequencePeriodic(baseKeypoints, -shift)),
    }

    for _, position in ipairs(collectRotatedInteriorPositions(baseKeypoints, shift)) do
        table.insert(keypoints, ColorSequenceKeypoint.new(position, sampleColorSequencePeriodic(baseKeypoints, position - shift)))
    end

    table.insert(keypoints, ColorSequenceKeypoint.new(1, sampleColorSequencePeriodic(baseKeypoints, 1 - shift)))
    return ColorSequence.new(keypoints)
end

local function buildRotatedNumberSequence(baseKeypoints, shift)
    local startValue, startEnvelope = sampleNumberSequencePeriodic(baseKeypoints, -shift)
    local keypoints = {
        NumberSequenceKeypoint.new(0, startValue, startEnvelope),
    }

    for _, position in ipairs(collectRotatedInteriorPositions(baseKeypoints, shift)) do
        local value, envelope = sampleNumberSequencePeriodic(baseKeypoints, position - shift)
        table.insert(keypoints, NumberSequenceKeypoint.new(position, value, envelope))
    end

    local endValue, endEnvelope = sampleNumberSequencePeriodic(baseKeypoints, 1 - shift)
    table.insert(keypoints, NumberSequenceKeypoint.new(1, endValue, endEnvelope))
    return NumberSequence.new(keypoints)
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

function ShopController:_applyButtonState(binding)
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

    playTween(binding, "scale", binding.uiScale, tweenInfo, { Scale = scale })
    if binding.rotationTarget then
        playTween(binding, "rotation", binding.rotationTarget, tweenInfo, { Rotation = rotation })
    end
end

function ShopController:_bindButton(button, onActivated, options)
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

function ShopController:_disconnectButtonBindings()
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

function ShopController:_disconnectMarketStallBindings()
    disconnectAll(self._marketStallConnections)
end

function ShopController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function ShopController:_stopSkinSecretGradientLoop()
    if self._skinSecretGradientConnection then
        self._skinSecretGradientConnection:Disconnect()
        self._skinSecretGradientConnection = nil
    end

    for gradient, state in pairs(self._skinSecretGradientState) do
        if gradient and gradient.Parent and state then
            gradient.Color = state.Color
            gradient.Transparency = state.Transparency
            gradient.Offset = state.Offset
            gradient.Rotation = state.Rotation
        end
    end
end

function ShopController:_startSkinSecretGradientLoop()
    if self._skinSecretGradientConnection then
        return
    end
    if #self._skinSecretGradients <= 0 then
        return
    end

    local elapsed = 0
    local elapsedSinceUpdate = SECRET_GRADIENT_UPDATE_INTERVAL
    self._skinSecretGradientConnection = RunService.RenderStepped:Connect(function(deltaTime)
        if not (self._isOpen and self._panel and self._panel.Visible) then
            return
        end

        local step = tonumber(deltaTime) or 0
        elapsed += step
        elapsedSinceUpdate += step
        if elapsedSinceUpdate < SECRET_GRADIENT_UPDATE_INTERVAL then
            return
        end
        elapsedSinceUpdate = 0

        local shift = modulo01((elapsed / SECRET_GRADIENT_ONE_WAY_DURATION) * SECRET_GRADIENT_OFFSET_RANGE)
        for _, gradient in ipairs(self._skinSecretGradients) do
            local state = self._skinSecretGradientState[gradient]
            if gradient and gradient.Parent and state then
                if type(state.ColorKeypoints) == "table" and #state.ColorKeypoints > 0 then
                    local okColor, rotatedColor = pcall(function()
                        return buildRotatedColorSequence(state.ColorKeypoints, shift)
                    end)
                    if okColor and rotatedColor then
                        gradient.Color = rotatedColor
                    end
                end

                if type(state.TransparencyKeypoints) == "table" and #state.TransparencyKeypoints > 0 then
                    local okTransparency, rotatedTransparency = pcall(function()
                        return buildRotatedNumberSequence(state.TransparencyKeypoints, shift)
                    end)
                    if okTransparency and rotatedTransparency then
                        gradient.Transparency = rotatedTransparency
                    end
                end

                gradient.Offset = state.Offset
                gradient.Rotation = state.Rotation
            end
        end
    end)
end

function ShopController:_bindSkinSecretGradients(skinFrame)
    self:_stopSkinSecretGradientLoop()
    table.clear(self._skinSecretGradients)
    table.clear(self._skinSecretGradientState)

    local nameLabel = skinFrame and skinFrame:FindFirstChild("Name")
    local secret2 = nameLabel and nameLabel:FindFirstChild("Secret2")
    local uiStroke = nameLabel and nameLabel:FindFirstChild("UIStroke")
    local secret1 = uiStroke and uiStroke:FindFirstChild("Secret1")
    local gradients = { secret1, secret2 }

    for _, gradient in ipairs(gradients) do
        if gradient and gradient:IsA("UIGradient") then
            table.insert(self._skinSecretGradients, gradient)
            self._skinSecretGradientState[gradient] = {
                Color = cloneColorSequence(gradient.Color),
                Transparency = cloneNumberSequence(gradient.Transparency),
                ColorKeypoints = gradient.Color.Keypoints,
                TransparencyKeypoints = gradient.Transparency.Keypoints,
                Offset = gradient.Offset,
                Rotation = gradient.Rotation,
            }
        end
    end

    if self._isOpen then
        self:_startSkinSecretGradientLoop()
    end
end

function ShopController:_requestShopState(autoClaim, intent)
    if self._requestStateEvent then
        self._requestStateEvent:FireServer({
            autoClaimStarterPack = autoClaim == true,
            source = "Shop",
            intent = intent,
        })
    end
end

function ShopController:_findMarketStall()
    local map2 = Workspace:FindFirstChild("Map2")
    if not map2 then
        return nil
    end

    local direct = map2:FindFirstChild("MarketStall")
    if direct then
        return direct
    end

    return map2:FindFirstChild("MarketStall", true)
end

function ShopController:_collectTouchParts(root)
    local parts = {}
    if root and root:IsA("BasePart") and root.CanTouch ~= false then
        table.insert(parts, root)
    end
    if root then
        for _, descendant in ipairs(root:GetDescendants()) do
            if descendant:IsA("BasePart") and descendant.CanTouch ~= false then
                table.insert(parts, descendant)
            end
        end
    end
    return parts
end

function ShopController:_isLocalCharacterPart(hit)
    if not (hit and self._localPlayer) then
        return false
    end

    local character = self._localPlayer.Character
    if not character then
        return false
    end

    return hit:IsDescendantOf(character)
end

function ShopController:_handleMarketStallTouched(hit)
    if not self:_isLocalCharacterPart(hit) then
        return
    end
    if self._isOpen then
        return
    end

    local now = os.clock()
    if now < self._marketStallTouchDebounceUntil then
        return
    end
    self._marketStallTouchDebounceUntil = now + MARKET_STALL_TOUCH_COOLDOWN
    self:Open()
end

function ShopController:_bindMarketStall(silent)
    self:_disconnectMarketStallBindings()

    local stall = self:_findMarketStall()
    local parts = self:_collectTouchParts(stall)
    if #parts <= 0 then
        if not silent then
            self:_queueMarketStallBindRetry()
        end
        return false
    end

    for _, part in ipairs(parts) do
        table.insert(self._marketStallConnections, part.Touched:Connect(function(hit)
            self:_handleMarketStallTouched(hit)
        end))
    end
    return true
end

function ShopController:_setOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:Release("Shop")
        end
        return
    end

    local uiScale = ensureUiScale(self._panel)
    self:_cancelPanelTweens()
    self._panelAnimationSerial += 1
    local serial = self._panelAnimationSerial
    self._isOpen = isOpen == true

    if self._isOpen then
        ModalUiController:Acquire("Shop", self._panel)
        self._panel.Visible = true
        self:_requestShopState(true, "ShopOpened")
        if not self._starterPackClaimed then
            self:_recordPurchaseContext({
                intent = "ProductViewed",
                source = "Shop",
                purchaseType = "StarterPack",
                productGroup = "StarterPack",
                itemSku = tostring(ShopConfig.StarterPack.GamePassId),
                gamePassId = ShopConfig.StarterPack.GamePassId,
            })
        end
        for _, purchase in ipairs(WheelConfig.Purchases) do
            self:_recordPurchaseContext({
                intent = "ProductViewed",
                source = "Shop",
                purchaseType = "WheelSpins",
                productGroup = "WheelSpins",
                itemSku = tostring(purchase.ProductId),
                productId = purchase.ProductId,
            })
        end
        if not self._featuredSkinOwned then
            local featuredSkin = SkinConfig.GetSkin(ShopConfig.FeaturedSkinId)
            if featuredSkin then
                self:_recordPurchaseContext({
                    intent = "ProductViewed",
                    source = "Shop",
                    purchaseType = "Skin",
                    productGroup = "GamePassSkin",
                    itemSku = tostring(featuredSkin.GamePassId),
                    skinId = featuredSkin.Id,
                    gamePassId = featuredSkin.GamePassId,
                })
            end
        end
        self:_startSkinSecretGradientLoop()
        if not uiScale or immediate == true then
            if uiScale then
                uiScale.Scale = 1
            end
            return
        end

        uiScale.Scale = OPEN_FROM_SCALE
        local overshoot = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = OPEN_OVERSHOOT_SCALE,
        })
        local settle = TweenService:Create(uiScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Scale = 1,
        })
        self._panelTweens = { overshoot, settle }
        task.spawn(function()
            overshoot:Play()
            overshoot.Completed:Wait()
            if self._panelAnimationSerial ~= serial or not self._isOpen then
                return
            end
            settle:Play()
            settle.Completed:Wait()
            if self._panelAnimationSerial == serial and self._isOpen and uiScale.Parent then
                uiScale.Scale = 1
            end
        end)
        return
    end

    if not uiScale or immediate == true or self._panel.Visible ~= true then
        if uiScale then
            uiScale.Scale = 1
        end
        self:_stopSkinSecretGradientLoop()
        self._panel.Visible = false
        ModalUiController:Release("Shop")
        return
    end

    local shrink = TweenService:Create(uiScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { shrink }
    task.spawn(function()
        shrink:Play()
        shrink.Completed:Wait()
        if self._panelAnimationSerial ~= serial or self._isOpen then
            return
        end
        if uiScale.Parent then
            uiScale.Scale = 1
        end
        if self._panel and self._panel.Parent then
            self:_stopSkinSecretGradientLoop()
            self._panel.Visible = false
        end
        ModalUiController:Release("Shop")
    end)
end

function ShopController:_recordPurchaseContext(payload)
    if self._requestPurchaseContextEvent and type(payload) == "table" then
        self._requestPurchaseContextEvent:FireServer(payload)
    end
end

function ShopController:_promptProduct(productId, source)
    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 or not (self._localPlayer and self._localPlayer.Parent) then
        return
    end

    self:_recordPurchaseContext({
        intent = "BuyClicked",
        source = source or "Shop",
        purchaseType = "WheelSpins",
        productGroup = "WheelSpins",
        itemSku = tostring(resolvedProductId),
        productId = resolvedProductId,
    })
    self:_recordPurchaseContext({
        intent = "PurchasePromptRequested",
        source = source or "Shop",
        purchaseType = "WheelSpins",
        productGroup = "WheelSpins",
        itemSku = tostring(resolvedProductId),
        productId = resolvedProductId,
    })
    MarketplaceService:PromptProductPurchase(self._localPlayer, resolvedProductId)
end

function ShopController:_promptGamePass(gamePassId, context)
    local resolvedGamePassId = math.floor(tonumber(gamePassId) or 0)
    if resolvedGamePassId <= 0 or not (self._localPlayer and self._localPlayer.Parent) then
        return
    end

    if type(context) == "table" then
        context.gamePassId = resolvedGamePassId
        if not context.intent then
            context.intent = "PurchasePromptRequested"
        end
        self:_recordPurchaseContext(context)
    end
    MarketplaceService:PromptGamePassPurchase(self._localPlayer, resolvedGamePassId)
end

function ShopController:_requestStarterPack()
    if self._starterPackClaimed then
        if self._requestStarterPackClaimEvent then
            self._requestStarterPackClaimEvent:FireServer()
        end
        return
    end

    if self._requestStarterPackClaimEvent then
        self._requestStarterPackClaimEvent:FireServer()
    end
    self:_recordPurchaseContext({
        intent = "BuyClicked",
        source = "Shop",
        purchaseType = "StarterPack",
        productGroup = "StarterPack",
        itemSku = tostring(ShopConfig.StarterPack.GamePassId),
        gamePassId = ShopConfig.StarterPack.GamePassId,
    })
    self:_promptGamePass(ShopConfig.StarterPack.GamePassId, {
        intent = "PurchasePromptRequested",
        source = "Shop",
        purchaseType = "StarterPack",
        productGroup = "StarterPack",
        itemSku = tostring(ShopConfig.StarterPack.GamePassId),
    })
end

function ShopController:_requestSkinPurchase()
    local skin = SkinConfig.GetSkin(ShopConfig.FeaturedSkinId)
    if not skin then
        return
    end

    self:_recordPurchaseContext({
        intent = "BuyClicked",
        source = "Shop",
        purchaseType = "Skin",
        productGroup = "GamePassSkin",
        itemSku = tostring(skin.GamePassId),
        skinId = skin.Id,
        gamePassId = skin.GamePassId,
    })
    if self._requestSkinPurchaseEvent then
        self._requestSkinPurchaseEvent:FireServer(skin.Id)
    end
    self:_promptGamePass(skin.GamePassId, {
        intent = "PurchasePromptRequested",
        source = "Shop",
        purchaseType = "Skin",
        productGroup = "GamePassSkin",
        itemSku = tostring(skin.GamePassId),
        skinId = skin.Id,
    })
end

function ShopController:_openSugarClubFromShop()
    self:_setOpen(false, true)
    if self._subscriptionController and self._subscriptionController.Open then
        self._subscriptionController:Open()
    end
    if self._subscriptionController and self._subscriptionController.PromptPurchase then
        self._subscriptionController:PromptPurchase()
    end
end

function ShopController:_resolveEntryScaleTarget()
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

function ShopController:_resolveEntryRotationTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveEntryScaleTarget()
end

function ShopController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end
    self._starterPackClaimed = payload.starterPackClaimed == true
    self._featuredSkinOwned = payload.featuredSkinOwned == true
    if self._starterPackFrame and self._starterPackFrame:IsA("GuiObject") then
        self._starterPackFrame.Visible = not self._starterPackClaimed
    end
    if self._skinBuyButtonRoot and self._skinBuyButtonRoot:IsA("GuiObject") then
        self._skinBuyButtonRoot.Visible = not self._featuredSkinOwned
    end
end

function ShopController:_clearPopupItems()
    for _, frame in ipairs(self._popupItems) do
        if frame and frame.Parent then
            frame:Destroy()
        end
    end
    table.clear(self._popupItems)
end

function ShopController:_disconnectPopupInput()
    if self._rewardPopupInputConnection and self._rewardPopupInputConnection.Connected then
        self._rewardPopupInputConnection:Disconnect()
    end
    self._rewardPopupInputConnection = nil
end

function ShopController:_returnToRewardSource()
    local source = tostring(self._lastRewardSource or "")
    if source == "Shop" then
        self:_setOpen(true)
    elseif source == "Wheel" and self._wheelController and self._wheelController.Open then
        self._wheelController:Open()
    elseif source == "SevenDayLoginReward" and self._sevenDayLoginRewardController and self._sevenDayLoginRewardController.OpenSevenDayLoginReward then
        self._sevenDayLoginRewardController:OpenSevenDayLoginReward()
    end
end

function ShopController:_closeRewardPopup()
    if not (self._claimPopup and self._claimPopup:IsA("GuiObject")) then
        return
    end
    if not self._rewardPopupCanClose then
        return
    end

    self:_disconnectPopupInput()
    self._rewardPopupCanClose = false
    self._rewardPopupSerial += 1
    self._claimPopup.Visible = false
    self:_clearPopupItems()
    ModalUiController:Release("ClaimSuccessful")
    self:_returnToRewardSource()
end

function ShopController:_preparePopupItem(reward, order)
    if not (self._claimPopupTemplate and self._claimPopupTemplate.Parent) then
        return nil
    end

    local frame = self._claimPopupTemplate:Clone()
    frame.Name = "Reward_" .. tostring(order)
    frame.Visible = true
    frame.Parent = self._claimPopupTemplate.Parent
    table.insert(self._popupItems, frame)

    setText(frame:FindFirstChild("Name", true), tostring(reward.label or reward.name or ""))
    setText(frame:FindFirstChild("Number", true), "*" .. tostring(math.max(1, math.floor(tonumber(reward.amount) or 1))))
    local icon = frame:FindFirstChild("Icon", true)
    setImage(icon, reward.icon)

    if icon then
        local aspect = icon:FindFirstChildOfClass("UIAspectRatioConstraint")
        if not aspect then
            aspect = Instance.new("UIAspectRatioConstraint")
            aspect.Parent = icon
        end
        aspect.AspectRatio = math.max(0.1, tonumber(reward.aspectRatio) or 1)
    end

    local uiScale = ensureUiScale(frame)
    if uiScale then
        uiScale.Scale = 0.2
    end
    frame.BackgroundTransparency = math.min(1, (tonumber(frame.BackgroundTransparency) or 0) + 0.35)
    return frame
end

function ShopController:_playRewardPopup(payload)
    if type(payload) == "table" and payload.state then
        self:_applyState(payload.state)
    end

    if not (self._claimPopup and self._claimPopup:IsA("GuiObject")) then
        self:_bindUi(true)
    end
    if not (self._claimPopup and self._claimPopup:IsA("GuiObject")) then
        return
    end

    self._lastRewardSource = tostring(payload and payload.source or "Shop")
    self:_disconnectPopupInput()
    self._rewardPopupCanClose = false
    self._rewardPopupSerial += 1
    local serial = self._rewardPopupSerial

    self:_setOpen(false, true)
    if self._lastRewardSource == "Wheel" and self._wheelController and self._wheelController.Close then
        self._wheelController:Close(true)
    end

    ModalUiController:Acquire("ClaimSuccessful", self._claimPopup)
    self._claimPopup.Visible = true
    self:_clearPopupItems()

    local uiScale = ensureUiScale(self._claimPopup)
    local originalPosition = self._claimPopup.Position
    if uiScale then
        uiScale.Scale = 1
    end
    self._claimPopup.Position = UDim2.new(
        originalPosition.X.Scale + POPUP_SLIDE_OFFSET_SCALE,
        originalPosition.X.Offset,
        originalPosition.Y.Scale,
        originalPosition.Y.Offset
    )

    local popupTween = TweenService:Create(self._claimPopup, TweenInfo.new(POPUP_OPEN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = originalPosition,
    })
    popupTween:Play()

    local rewards = type(payload and payload.rewards) == "table" and payload.rewards or {}
    for index, reward in ipairs(rewards) do
        local frame = self:_preparePopupItem(reward, index)
        if frame then
            task.delay(POPUP_ITEM_STAGGER * (index - 1), function()
                if self._rewardPopupSerial ~= serial or not (frame and frame.Parent) then
                    return
                end
                local itemScale = ensureUiScale(frame)
                if itemScale then
                    TweenService:Create(itemScale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                        Scale = 1,
                    }):Play()
                end
            end)
        end
    end

    task.delay(POPUP_CLOSE_DELAY, function()
        if self._rewardPopupSerial ~= serial or not (self._claimPopup and self._claimPopup.Parent) then
            return
        end
        self._rewardPopupCanClose = true
        self:_disconnectPopupInput()
        self._rewardPopupInputConnection = UserInputService.InputBegan:Connect(function(inputObject)
            local inputType = inputObject.UserInputType
            if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
                self:_closeRewardPopup()
            end
        end)
    end)
end

function ShopController:_bindUi(silent)
    self:_disconnectButtonBindings()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local left = self._mainGui:FindFirstChild("Left")
    self._leftEntry = left and left:FindFirstChild("Shop")
    self._panel = self._mainGui:FindFirstChild("Shop")
    self._claimPopup = self._mainGui:FindFirstChild("ClaimSuccessful")

    local shopInfo = self._panel and self._panel:FindFirstChild("Shopinfo")
    local scrollingFrame = shopInfo and shopInfo:FindFirstChild("ScrollingFrame")
    self._starterPackFrame = scrollingFrame and scrollingFrame:FindFirstChild("StarterPack")
    local sugarClubFrame = scrollingFrame and scrollingFrame:FindFirstChild("SugarClub")
    local spinFrame = scrollingFrame and scrollingFrame:FindFirstChild("Spin")
    local skinFrame = scrollingFrame and scrollingFrame:FindFirstChild("Skin")
    self._skinBuyButtonRoot = nil
    self:_bindSkinSecretGradients(skinFrame)

    local itemListFrame = self._claimPopup and self._claimPopup:FindFirstChild("ItemListFrame", true)
    self._claimPopupTemplate = itemListFrame and itemListFrame:FindFirstChild("ItemTemplate")

    if not (self._leftEntry and self._panel and scrollingFrame and self._claimPopup and self._claimPopupTemplate) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._panel.Visible = false
    self._claimPopup.Visible = false
    self._claimPopupTemplate.Visible = false

    local leftButton = self._leftEntry:FindFirstChildWhichIsA("GuiButton", true)
    local entryScaleTarget = self:_resolveEntryScaleTarget()
    local entryRotationTarget = self:_resolveEntryRotationTarget()
    self:_bindButton(leftButton, function()
        self:_setOpen(true)
    end, {
        ScaleTarget = entryScaleTarget or leftButton,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        RotationTarget = entryRotationTarget,
        HoverRotation = HOVER_ROTATION,
    })

    local closeButton = self._panel:FindFirstChild("CloseButton", true)
    self:_bindButton(closeButton, function()
        self:_setOpen(false)
    end, {
        RotationTarget = closeButton,
        HoverRotation = HOVER_ROTATION,
    })

    local starterPackButton = self._starterPackFrame and select(1, findButton(self._starterPackFrame, "BuyButton")) or nil
    setMarketplaceRobuxPrice(
        self._starterPackFrame and self._starterPackFrame:FindFirstChild("RMoney", true),
        ShopConfig.StarterPack.GamePassId,
        Enum.InfoType.GamePass
    )
    self:_bindButton(starterPackButton, function()
        self:_requestStarterPack()
    end)

    local sugarButton = sugarClubFrame and select(1, findButton(sugarClubFrame, "BuyButton")) or nil
    setSubscriptionRobuxPrice(
        sugarClubFrame and sugarClubFrame:FindFirstChild("RMoney", true),
        SubscriptionConfig.SubscriptionId
    )
    self:_bindButton(sugarButton, function()
        self:_openSugarClubFromShop()
    end)

    local content = spinFrame and spinFrame:FindFirstChild("Content")
    for _, purchase in ipairs(WheelConfig.Purchases) do
        local cashFrame = nil
        if purchase.Spins == 5 then
            cashFrame = content and content:FindFirstChild("Cash1")
        elseif purchase.Spins == 20 then
            cashFrame = content and content:FindFirstChild("Cash2")
        elseif purchase.Spins == 50 then
            cashFrame = content and content:FindFirstChild("Cash3")
        end
        local button = cashFrame and select(1, findButton(cashFrame, "BuyButton")) or nil
        setMarketplaceRobuxPrice(
            cashFrame and cashFrame:FindFirstChild("RMoney", true),
            purchase.ProductId,
            Enum.InfoType.Product
        )
        self:_bindButton(button, function()
            self:_promptProduct(purchase.ProductId, "Shop")
        end, {
            ScaleTarget = button,
        })
    end

    local skinInnerFrame = skinFrame and skinFrame:FindFirstChild("Frame")
    local skinButton, skinButtonRoot = nil, nil
    if skinInnerFrame then
        skinButton, skinButtonRoot = findButton(skinInnerFrame, "BuyButton")
    end
    if not skinButton then
        skinButton, skinButtonRoot = findButton(skinFrame, "BuyButton")
    end
    self._skinBuyButtonRoot = skinButtonRoot or skinButton
    local featuredSkin = SkinConfig.GetSkin(ShopConfig.FeaturedSkinId)
    setMarketplaceRobuxPrice(
        skinFrame and skinFrame:FindFirstChild("RMoney", true),
        featuredSkin and featuredSkin.GamePassId,
        Enum.InfoType.GamePass
    )
    self:_bindButton(skinButton, function()
        self:_requestSkinPurchase()
    end)

    self:_requestShopState(false)
    return true
end

function ShopController:_queueBindRetry()
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
        warn("[ShopController] Could not find PlayerGui/Main/Shop UI.")
    end)
end

function ShopController:_queueMarketStallBindRetry()
    if self._marketStallBindRetryQueued then
        return
    end

    self._marketStallBindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 15
        repeat
            if self:_bindMarketStall(true) then
                self._marketStallBindRetryQueued = false
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._marketStallBindRetryQueued = false
        warn("[ShopController] Could not bind Workspace.Map2.MarketStall touch entry.")
    end)
end

function ShopController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[ShopController] Missing system events folder.")
        return
    end

    self._requestStateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestShopStateSync, 10)
    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.ShopStateSync, 10)
    self._requestStarterPackClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestShopStarterPackClaim, 10)
    self._requestPurchaseContextEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestShopPurchaseContext, 10)
    self._rewardFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.ShopRewardFeedback, 10)
    self._requestSkinPurchaseEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSkinPurchase, 10)

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyState(payload)
        end))
    end
    if self._rewardFeedbackEvent then
        table.insert(self._connections, self._rewardFeedbackEvent.OnClientEvent:Connect(function(payload)
            self:_playRewardPopup(payload)
        end))
    end
end

function ShopController:Open()
    if not self._panel then
        self:_bindUi(true)
    end
    self:_setOpen(true)
end

function ShopController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._wheelController = dependencies and dependencies.WheelController or nil
    self._subscriptionController = dependencies and dependencies.SubscriptionController or nil
    self._sevenDayLoginRewardController = dependencies and dependencies.SevenDayLoginRewardController or nil
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_disconnectMarketStallBindings()
    self:_disconnectPopupInput()
    self:_stopSkinSecretGradientLoop()
    self:_clearPopupItems()

    self:_connectRemotes()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    if not self:_bindMarketStall(true) then
        self:_queueMarketStallBindRetry()
    end

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                    self:_requestShopState(false)
                end)
            end
        end))
    end
end

return ShopController
