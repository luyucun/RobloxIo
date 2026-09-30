--[[
Script: AttributeCapUpgradeController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AttributeCapUpgradeController
Purpose: Bind Main.AttributeUpgradeOut to global attribute cap upgrades.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local TouchRegionGate = require(script.Parent:WaitForChild("TouchRegionGate"))

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

    error(string.format("[AttributeCapUpgradeController] Missing shared module %s", tostring(moduleName or "")))
end

local RemoteNames = requireSharedModule("RemoteNames")
local AttributeConfig = requireSharedModule("AttributeConfig")

local AttributeCapUpgradeController = {}

AttributeCapUpgradeController._localPlayer = nil
AttributeCapUpgradeController._modalUiController = nil
AttributeCapUpgradeController._shopController = nil
AttributeCapUpgradeController._connections = {}
AttributeCapUpgradeController._uiConnections = {}
AttributeCapUpgradeController._regionGate = nil
AttributeCapUpgradeController._mainGui = nil
AttributeCapUpgradeController._panel = nil
AttributeCapUpgradeController._gemValue = nil
AttributeCapUpgradeController._rowsByKey = {}
AttributeCapUpgradeController._latestPayload = nil
AttributeCapUpgradeController._pendingGemByKey = {}
AttributeCapUpgradeController._robuxPriceByProductId = {}
AttributeCapUpgradeController._robuxPriceRequestByProductId = {}
AttributeCapUpgradeController._requestEvent = nil
AttributeCapUpgradeController._isOpen = false
AttributeCapUpgradeController._bindRetryQueued = false
AttributeCapUpgradeController._regionBindRetryQueued = false

local MODAL_OWNER_ID = "AttributeCapUpgrade"
local SUPPRESSED_ATTRIBUTE_KEYS = {
    Damage = true,
    MoveSpeed = true,
}
local REGION_WAIT_SECONDS = 30
local UI_BIND_RETRY_COUNT = 80
local UI_BIND_RETRY_INTERVAL_SECONDS = 0.25
local PENDING_TIMEOUT_SECONDS = 2

local ENABLED_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local DISABLED_TEXT_COLOR = Color3.fromRGB(190, 196, 205)
local ENABLED_IMAGE_TRANSPARENCY = 0
local DISABLED_IMAGE_TRANSPARENCY = 0.35
local BUTTON_HOVER_SCALE = 1.05
local BUTTON_PRESS_SCALE = 0.92
local ENTRY_HOVER_SCALE = 1.08
local ENTRY_PRESS_SCALE = 0.9
local CLOSE_HOVER_SCALE = 1.08
local CLOSE_PRESS_SCALE = 0.9
local CLOSE_HOVER_ROTATION = 20
local BUTTON_HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BUTTON_PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local BUTTON_RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local rowNameByKey = {
    Damage = "DamageCap",
    BladeSpeed = "BladeSpeedCap",
    BladeRange = "BladeRangeCap",
    MoveSpeed = "MoveSpeedCap",
    MaxHealth = "MaxHealthCap",
    HealthRegen = "HealthRegenCap",
    ExpGain = "EXPGainCap",
    BladeRecovery = "BladeRecoveryCap",
    FlashCooldown = "FlashCooldownCap",
    FlashDistance = "FlashDistanceCap",
}

local function disconnectAll(connections)
    for _, connection in ipairs(connections or {}) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function isAttributeUiSuppressed(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    return key ~= nil and SUPPRESSED_ATTRIBUTE_KEYS[key] == true
end

local function findDescendant(root, path)
    local current = root
    for name in string.gmatch(path or "", "[^%.]+") do
        current = current and current:FindFirstChild(name)
        if not current then
            return nil
        end
    end
    return current
end

local function findFirstDescendant(root, paths)
    for _, path in ipairs(paths or {}) do
        local descendant = findDescendant(root, path)
        if descendant then
            return descendant
        end
    end
    return nil
end

local function setText(node, text)
    if node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox")) then
        node.Text = tostring(text or "")
    end
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

local function isPrimaryPointerInput(input)
    return input
        and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch)
end

local function isButtonInteractable(button)
    return button and button:IsA("GuiButton") and button.Active ~= false and button.Visible ~= false
end

local function formatCompactNumber(value)
    local number = math.max(0, tonumber(value) or 0)
    if number < 1000 then
        return tostring(math.floor(number + 0.5))
    end
    if number >= 1e18 then
        return string.format("%.2e", number)
    end

    local suffixes = {
        { Value = 1e15, Suffix = "Qa" },
        { Value = 1e12, Suffix = "T" },
        { Value = 1e9, Suffix = "B" },
        { Value = 1e6, Suffix = "M" },
        { Value = 1e3, Suffix = "K" },
    }
    for _, suffix in ipairs(suffixes) do
        if number >= suffix.Value then
            local scaled = number / suffix.Value
            if scaled >= 100 then
                return string.format("%.0f%s", scaled, suffix.Suffix)
            elseif scaled >= 10 then
                return string.format("%.1f%s", scaled, suffix.Suffix)
            end
            return string.format("%.2f%s", scaled, suffix.Suffix)
        end
    end
    return string.format("%.2e", number)
end

local function setButtonVisual(button, priceLabel, visualEnabled, interactable)
    if button and button:IsA("GuiButton") then
        button.Active = interactable == true
        button.Selectable = interactable == true
        button.AutoButtonColor = visualEnabled == true and interactable == true
    end
    if interactable ~= true then
        local uiScale = button and button:IsA("GuiObject") and button:FindFirstChildOfClass("UIScale") or nil
        if uiScale then
            uiScale.Scale = 1
        end
    end
    if button and (button:IsA("ImageButton") or button:IsA("ImageLabel")) then
        button.ImageTransparency = visualEnabled == true and ENABLED_IMAGE_TRANSPARENCY or DISABLED_IMAGE_TRANSPARENCY
    elseif button and button:IsA("GuiObject") then
        button.BackgroundTransparency = visualEnabled == true and 0 or 0.25
    end
    if priceLabel and priceLabel:IsA("TextLabel") then
        priceLabel.TextColor3 = visualEnabled == true and ENABLED_TEXT_COLOR or DISABLED_TEXT_COLOR
    end
end

local function extractAttributeCaps(payload)
    local attributeState = type(payload and payload.attributeState) == "table" and payload.attributeState or {}
    return type(attributeState.attributeCaps) == "table" and attributeState.attributeCaps
        or type(payload and payload.attributeCaps) == "table" and payload.attributeCaps
        or {}
end

function AttributeCapUpgradeController:_getPlayerGui()
    local player = self._localPlayer or Players.LocalPlayer
    return player and (player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)) or nil
end

function AttributeCapUpgradeController:_showMessage(message)
    local text = tostring(message or "")
    if text == "" then
        return
    end
    local success = pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "Attribute Upgrade",
            Text = text,
            Duration = 2,
        })
    end)
    if not success then
        warn("[AttributeCapUpgradeController] " .. text)
    end
end

function AttributeCapUpgradeController:_setOpen(isOpen)
    if isOpen == true and not self:_bindUi(true) then
        self:_queueBindRetry()
        return false
    end

    self._isOpen = isOpen == true

    local modalUiController = self._modalUiController
    if self._isOpen then
        if modalUiController and modalUiController.PlayPanelOpen then
            modalUiController:PlayPanelOpen(MODAL_OWNER_ID, self._panel)
        else
            if self._panel then
                self._panel.Visible = true
            end
            if modalUiController and modalUiController.Acquire then
                modalUiController:Acquire(MODAL_OWNER_ID, self._panel)
            end
        end
        self:_applyState(self._latestPayload)
        return true
    end

    if modalUiController and modalUiController.PlayPanelClose then
        modalUiController:PlayPanelClose(MODAL_OWNER_ID, self._panel)
    else
        if self._panel then
            self._panel.Visible = false
        end
        if modalUiController and modalUiController.Release then
            modalUiController:Release(MODAL_OWNER_ID)
        end
    end

    return true
end

function AttributeCapUpgradeController:Open()
    return self:_setOpen(true)
end

function AttributeCapUpgradeController:Close()
    return self:_setOpen(false)
end

function AttributeCapUpgradeController:_openDiamondShop()
    self:Close()
    if self._shopController and self._shopController.OpenDiamonds then
        self._shopController:OpenDiamonds()
    end
end

function AttributeCapUpgradeController:_requestGemUpgrade(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        self:_showMessage("Invalid attribute")
        return
    end
    if self._pendingGemByKey[key] == true then
        return
    end
    if not self._requestEvent then
        self:_showMessage("Upgrade is unavailable")
        return
    end

    local caps = AttributeConfig.NormalizeCaps(extractAttributeCaps(self._latestPayload))
    local info = AttributeConfig.GetCapUpgradeInfo(key, caps[key])
    if info and info.IsMax then
        self:_showMessage("Max level reached")
        return
    end
    local gemCost = math.max(0, math.floor(tonumber(info and info.GemCost) or 0))
    local hasStateSnapshot = type(self._latestPayload) == "table"
    local diamonds = math.max(0, math.floor(tonumber(hasStateSnapshot and self._latestPayload.diamonds) or 0))
    if hasStateSnapshot and gemCost > 0 and diamonds < gemCost then
        self:_openDiamondShop()
        return
    end

    self._pendingGemByKey[key] = true
    self:_applyState(self._latestPayload)
    self._requestEvent:FireServer(key)

    task.delay(PENDING_TIMEOUT_SECONDS, function()
        if self._pendingGemByKey[key] ~= true then
            return
        end
        self._pendingGemByKey[key] = nil
        self:_showMessage("Please try again")
        self:_applyState(self._latestPayload)
    end)
end

function AttributeCapUpgradeController:_promptRobuxUpgrade(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local caps = AttributeConfig.NormalizeCaps(extractAttributeCaps(self._latestPayload))
    local info = key and AttributeConfig.GetCapUpgradeInfo(key, caps[key]) or nil
    local productId = math.floor(tonumber(info and info.ProductId) or 0)
    if not key or productId <= 0 then
        self:_showMessage("Robux purchase unavailable")
        return
    end
    if info and info.IsMax then
        self:_showMessage("Max level reached")
        return
    end
    if not self._requestEvent then
        self:_showMessage("Robux purchase unavailable")
        return
    end
    if not (self._localPlayer and self._localPlayer.Parent) then
        return
    end
    self._requestEvent:FireServer({
        intent = "RobuxPurchaseIntent",
        attributeKey = key,
        productId = productId,
    })
    MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
end

function AttributeCapUpgradeController:_fetchRobuxPrice(productId)
    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 or self._robuxPriceByProductId[resolvedProductId] or self._robuxPriceRequestByProductId[resolvedProductId] then
        return
    end
    self._robuxPriceRequestByProductId[resolvedProductId] = true
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedProductId, Enum.InfoType.Product)
        end)
        self._robuxPriceRequestByProductId[resolvedProductId] = nil
        if success and type(productInfo) == "table" and tonumber(productInfo.PriceInRobux) then
            self._robuxPriceByProductId[resolvedProductId] = math.max(0, math.floor(tonumber(productInfo.PriceInRobux) + 0.5))
            self:_applyState(self._latestPayload)
        end
    end)
end

function AttributeCapUpgradeController:_bindButtonFeedback(button, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = options and options.ScaleTarget or button
    if not (scaleTarget and scaleTarget:IsA("GuiObject")) then
        scaleTarget = button
    end
    local rotationTarget = options and options.RotationTarget or nil
    if rotationTarget and not rotationTarget:IsA("GuiObject") then
        rotationTarget = nil
    end

    local uiScale = ensureUiScale(scaleTarget)
    local normalRotation = rotationTarget and rotationTarget.Rotation or 0
    local hoverScale = tonumber(options and options.HoverScale) or BUTTON_HOVER_SCALE
    local pressScale = tonumber(options and options.PressScale) or BUTTON_PRESS_SCALE
    local hoverRotation = tonumber(options and options.HoverRotation) or 0
    local isHovering = false
    local isPressing = false
    local scaleTween = nil
    local rotationTween = nil

    local function tweenScale(scale, tweenInfo)
        if uiScale then
            if scaleTween then
                scaleTween:Cancel()
                scaleTween = nil
            end
            scaleTween = TweenService:Create(uiScale, tweenInfo, { Scale = scale })
            local activeTween = scaleTween
            activeTween.Completed:Connect(function()
                if scaleTween == activeTween then
                    scaleTween = nil
                end
            end)
            activeTween:Play()
        end
    end

    local function tweenRotation(rotation, tweenInfo)
        if rotationTarget then
            if rotationTween then
                rotationTween:Cancel()
                rotationTween = nil
            end
            rotationTween = TweenService:Create(rotationTarget, tweenInfo, { Rotation = rotation })
            local activeTween = rotationTween
            activeTween.Completed:Connect(function()
                if rotationTween == activeTween then
                    rotationTween = nil
                end
            end)
            activeTween:Play()
        end
    end

    local function reset()
        isPressing = false
        if isButtonInteractable(button) and isHovering then
            tweenScale(hoverScale, BUTTON_RESET_TWEEN_INFO)
            tweenRotation(normalRotation + hoverRotation, BUTTON_RESET_TWEEN_INFO)
        else
            tweenScale(1, BUTTON_RESET_TWEEN_INFO)
            tweenRotation(normalRotation, BUTTON_RESET_TWEEN_INFO)
        end
    end

    table.insert(self._uiConnections, button.MouseEnter:Connect(function()
        isHovering = true
        if not isButtonInteractable(button) or isPressing then
            return
        end
        tweenScale(hoverScale, BUTTON_HOVER_TWEEN_INFO)
        tweenRotation(normalRotation + hoverRotation, BUTTON_HOVER_TWEEN_INFO)
    end))

    table.insert(self._uiConnections, button.MouseLeave:Connect(function()
        isHovering = false
        reset()
    end))

    table.insert(self._uiConnections, button.InputBegan:Connect(function(input)
        if not isPrimaryPointerInput(input) or not isButtonInteractable(button) then
            return
        end
        isPressing = true
        tweenScale(pressScale, BUTTON_PRESS_TWEEN_INFO)
        tweenRotation(normalRotation, BUTTON_PRESS_TWEEN_INFO)
    end))

    table.insert(self._uiConnections, button.InputEnded:Connect(function(input)
        if isPrimaryPointerInput(input) then
            reset()
        end
    end))

    table.insert(self._uiConnections, button:GetPropertyChangedSignal("Active"):Connect(function()
        if not isButtonInteractable(button) then
            isHovering = false
            reset()
        end
    end))

    table.insert(self._uiConnections, button:GetPropertyChangedSignal("Visible"):Connect(function()
        if not isButtonInteractable(button) then
            isHovering = false
            reset()
        end
    end))
end

function AttributeCapUpgradeController:_bindRow(statsList, attributeKey)
    local isSuppressed = isAttributeUiSuppressed(attributeKey)
    local rowName = rowNameByKey[attributeKey]
    local row = rowName and statsList and statsList:FindFirstChild(rowName)
    if isSuppressed then
        if row and row:IsA("GuiObject") then
            row.Visible = false
        end
        return nil
    end
    if not row then
        return nil
    end

    local gemButton = row:FindFirstChild("GemUpgradeButton")
    local robuxButton = row:FindFirstChild("RobuxUpgradeButton")
    if gemButton and gemButton:IsA("GuiButton") then
        self:_bindButtonFeedback(gemButton)
        table.insert(self._uiConnections, gemButton.Activated:Connect(function()
            self:_requestGemUpgrade(attributeKey)
        end))
    end
    if robuxButton and robuxButton:IsA("GuiButton") then
        self:_bindButtonFeedback(robuxButton)
        table.insert(self._uiConnections, robuxButton.Activated:Connect(function()
            self:_promptRobuxUpgrade(attributeKey)
        end))
    end

    return {
        Root = row,
        Name = row:FindFirstChild("Name"),
        CurrentCap = row:FindFirstChild("CurrentCap"),
        NextCap = row:FindFirstChild("NextCap"),
        GemButton = gemButton,
        GemPrice = gemButton and gemButton:FindFirstChild("Price"),
        RobuxButton = robuxButton,
        RobuxPrice = robuxButton and robuxButton:FindFirstChild("Price"),
    }
end

function AttributeCapUpgradeController:_bindEntryButton(main)
    local capsEntry = findDescendant(main, "Left.Caps")
    local textButton = capsEntry and capsEntry:FindFirstChild("TextButton")
    if textButton and textButton:IsA("GuiButton") then
        self:_bindButtonFeedback(textButton, {
            ScaleTarget = capsEntry and capsEntry:IsA("GuiObject") and capsEntry or textButton,
            HoverScale = ENTRY_HOVER_SCALE,
            PressScale = ENTRY_PRESS_SCALE,
        })
        table.insert(self._uiConnections, textButton.Activated:Connect(function()
            self:Open()
        end))
        return true
    end

    if capsEntry and capsEntry:IsA("GuiObject") then
        capsEntry.Active = true
        table.insert(self._uiConnections, capsEntry.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                self:Open()
            end
        end))
        return true
    end

    return false
end

function AttributeCapUpgradeController:_bindUi(silent)
    local playerGui = self:_getPlayerGui()
    local main = playerGui and playerGui:FindFirstChild("Main")
    if not main then
        if not silent then
            warn("[AttributeCapUpgradeController] PlayerGui.Main is unavailable")
        end
        return false
    end

    if self._mainGui == main and self._panel then
        return true
    end

    disconnectAll(self._uiConnections)
    self._mainGui = main
    self._panel = main:FindFirstChild("AttributeUpgradeOut")
    self._rowsByKey = {}

    if not self._panel then
        if not silent then
            warn("[AttributeCapUpgradeController] Main.AttributeUpgradeOut is unavailable")
        end
        return false
    end

    self._panel.Visible = false
    if not self:_bindEntryButton(main) and not silent then
        warn("[AttributeCapUpgradeController] Main.Left.Caps entry is unavailable")
    end

    self._gemValue = findDescendant(self._panel, "Window.GemSummaryBar.GemValue")
    local buyWithRobuxButton = findDescendant(self._panel, "Window.GemSummaryBar.BuyWithRobuxButton")
    if buyWithRobuxButton and buyWithRobuxButton:IsA("GuiButton") then
        buyWithRobuxButton.Active = false
        buyWithRobuxButton.Selectable = false
        buyWithRobuxButton.AutoButtonColor = false
    end

    local closeButton = findFirstDescendant(self._panel, {
        "Title.CloseButton",
        "Window.CloseButton",
        "Window.Header.CloseButton",
        "CloseButton",
    })
    if closeButton and closeButton:IsA("GuiButton") then
        self:_bindButtonFeedback(closeButton, {
            HoverScale = CLOSE_HOVER_SCALE,
            PressScale = CLOSE_PRESS_SCALE,
            RotationTarget = closeButton,
            HoverRotation = CLOSE_HOVER_ROTATION,
        })
        table.insert(self._uiConnections, closeButton.Activated:Connect(function()
            self:Close()
        end))
    end

    local statsList = findDescendant(self._panel, "Window.StatsList")
    for _, attributeKey in ipairs(AttributeConfig.Order) do
        local row = self:_bindRow(statsList, attributeKey)
        if row then
            self._rowsByKey[attributeKey] = row
        elseif not silent and not isAttributeUiSuppressed(attributeKey) then
            warn(string.format("[AttributeCapUpgradeController] Missing cap row for %s", tostring(attributeKey)))
        end
    end

    return true
end

function AttributeCapUpgradeController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    self._bindRetryQueued = true
    task.spawn(function()
        for _ = 1, UI_BIND_RETRY_COUNT do
            task.wait(UI_BIND_RETRY_INTERVAL_SECONDS)
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                self:_applyState(self._latestPayload)
                return
            end
        end
        self._bindRetryQueued = false
    end)
end

function AttributeCapUpgradeController:_findFountainRegion()
    local map2 = Workspace:WaitForChild("Map2", REGION_WAIT_SECONDS)
    local fountain = map2 and map2:WaitForChild("Fountain", REGION_WAIT_SECONDS)
    return fountain and fountain:WaitForChild("SquareRegion", REGION_WAIT_SECONDS) or nil
end

function AttributeCapUpgradeController:_disconnectRegion()
    if self._regionGate then
        self._regionGate:Stop()
        self._regionGate = nil
    end
end

function AttributeCapUpgradeController:_connectRegion()
    self:_disconnectRegion()
    task.spawn(function()
        local region = self:_findFountainRegion()
        if not region then
            self:_queueRegionBindRetry()
            return
        end
        self._regionGate = TouchRegionGate.new({
            LocalPlayer = self._localPlayer,
            Region = region,
            Label = "AttributeCapUpgrade.Fountain",
            OnEnter = function()
                self:Open()
            end,
        })
        if not self._regionGate:Start() then
            self._regionGate = nil
            self:_queueRegionBindRetry()
        end
    end)
end

function AttributeCapUpgradeController:_queueRegionBindRetry()
    if self._regionBindRetryQueued then
        return
    end
    self._regionBindRetryQueued = true
    task.delay(2, function()
        self._regionBindRetryQueued = false
        self:_connectRegion()
    end)
end

function AttributeCapUpgradeController:_applyRow(attributeKey, row, caps, diamonds)
    local definition = AttributeConfig.GetDefinition(attributeKey)
    if not (definition and row) then
        return
    end

    local currentCap = math.max(0, math.floor(tonumber(caps and caps[attributeKey]) or tonumber(definition.InitialCap) or 0))
    local info = AttributeConfig.GetCapUpgradeInfo(attributeKey, currentCap)
    if not info then
        return
    end

    setText(row.Name, definition.CapDisplayName or (definition.DisplayName .. " Cap"))
    setText(row.CurrentCap, tostring(info.CurrentCap))
    setText(row.NextCap, info.IsMax and "MAX" or tostring(info.NextCap))

    local gemCost = math.max(0, math.floor(tonumber(info.GemCost) or 0))
    local isPending = self._pendingGemByKey[attributeKey] == true
    local canBuyGem = info.IsMax ~= true and info.GemEnabled == true and not isPending
    local hasEnoughGems = diamonds >= gemCost
    setText(row.GemPrice, info.IsMax and "MAX" or (isPending and "..." or formatCompactNumber(gemCost)))
    setButtonVisual(row.GemButton, row.GemPrice, canBuyGem and hasEnoughGems, canBuyGem)

    local productId = math.floor(tonumber(info.ProductId) or 0)
    local canBuyRobux = info.IsMax ~= true and info.RobuxEnabled == true and productId > 0
    if canBuyRobux and not self._robuxPriceByProductId[productId] then
        self:_fetchRobuxPrice(productId)
    end
    setText(row.RobuxPrice, info.IsMax and "MAX" or (self._robuxPriceByProductId[productId] and tostring(self._robuxPriceByProductId[productId]) or "..."))
    setButtonVisual(row.RobuxButton, row.RobuxPrice, canBuyRobux, canBuyRobux)
end

function AttributeCapUpgradeController:_applyState(payload)
    self._latestPayload = payload or self._latestPayload
    if not self._latestPayload then
        return
    end
    if not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    local diamonds = math.max(0, math.floor(tonumber(self._latestPayload.diamonds) or 0))
    local caps = AttributeConfig.NormalizeCaps(extractAttributeCaps(self._latestPayload))
    setText(self._gemValue, formatCompactNumber(diamonds))
    for _, attributeKey in ipairs(AttributeConfig.Order) do
        if not isAttributeUiSuppressed(attributeKey) then
            self:_applyRow(attributeKey, self._rowsByKey[attributeKey], caps, diamonds)
        end
    end
end

function AttributeCapUpgradeController:_onFeedback(payload)
    local attributeKey = AttributeConfig.NormalizeKey(payload and payload.attributeKey)
    if attributeKey then
        self._pendingGemByKey[attributeKey] = nil
    else
        table.clear(self._pendingGemByKey)
    end

    if type(payload) == "table" then
        local nextPayload = type(self._latestPayload) == "table" and self._latestPayload or {}
        local feedbackCaps = extractAttributeCaps(payload)
        if next(feedbackCaps) ~= nil then
            nextPayload.attributeCaps = feedbackCaps
            nextPayload.attributeState = type(nextPayload.attributeState) == "table" and nextPayload.attributeState or {}
            nextPayload.attributeState.attributeCaps = feedbackCaps
        end
        if tonumber(payload.diamonds) then
            nextPayload.diamonds = math.max(0, math.floor(tonumber(payload.diamonds) or 0))
        end
        self._latestPayload = nextPayload
    end

    local message = tostring(payload and payload.message or "")
    if message ~= "" then
        self:_showMessage(message)
    end
    self:_applyState(self._latestPayload)
end

function AttributeCapUpgradeController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._modalUiController = dependencies and dependencies.ModalUiController or nil
    self._shopController = dependencies and dependencies.ShopController or nil
    self._latestPayload = nil
    self._pendingGemByKey = {}
    self._mainGui = nil
    self._panel = nil
    self._isOpen = false
    disconnectAll(self._connections)
    disconnectAll(self._uiConnections)
    self:_disconnectRegion()

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[AttributeCapUpgradeController] Missing system events folder.")
        return
    end

    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)
    local feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.AttributeCapUpgradeFeedback, 10)
    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    self._requestEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestAttributeCapUpgrade, 10)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    self:_connectRegion()

    if playerStateSyncEvent then
        table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
            self._latestPayload = payload
            table.clear(self._pendingGemByKey)
            self:_applyState(payload)
        end))
    end
    if feedbackEvent then
        table.insert(self._connections, feedbackEvent.OnClientEvent:Connect(function(payload)
            self:_onFeedback(payload)
        end))
    end

    local playerGui = self:_getPlayerGui()
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self._mainGui = nil
                    if self:_bindUi(true) and self._latestPayload then
                        self:_applyState(self._latestPayload)
                    end
                end)
            end
        end))
    end

    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        task.defer(function()
            requestStateSyncEvent:FireServer()
        end)
    end
end

return AttributeCapUpgradeController
