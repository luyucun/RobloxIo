--[[
Script: SkinController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/SkinController
Purpose: V3.1 weapon skin shop, ownership, and equip UI.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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
        "[SkinController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local SkinConfig = requireSharedModule("SkinConfig")
local TrailConfig = requireSharedModule("TrailConfig")
local TitleConfig = requireSharedModule("TitleConfig")

local SkinController = {}

SkinController._localPlayer = nil
SkinController._connections = {}
SkinController._buttonBindings = {}
SkinController._itemButtonBindings = {}
SkinController._itemFrames = {}
SkinController._tabButtons = {}
SkinController._pageFrames = {}
SkinController._activeTab = "Skins"
SkinController._mainGui = nil
SkinController._panel = nil
SkinController._leftEntry = nil
SkinController._scrollingFrame = nil
SkinController._template = nil
SkinController._trailScrollingFrame = nil
SkinController._trailTemplate = nil
SkinController._titleScrollingFrame = nil
SkinController._titleTemplate = nil
SkinController._titleUnlockPopup = nil
SkinController._titleUnlockOriginalPosition = nil
SkinController._titleUnlockCanClose = false
SkinController._titleUnlockSerial = 0
SkinController._titleUnlockInputConnection = nil
SkinController._requestStateEvent = nil
SkinController._stateSyncEvent = nil
SkinController._requestPurchaseEvent = nil
SkinController._requestEquipEvent = nil
SkinController._feedbackEvent = nil
SkinController._playerStateSyncEvent = nil
SkinController._latestState = { skins = {}, equippedSkinId = nil, trails = {}, equippedTrailId = nil, titles = {}, equippedTitleId = nil, hasUnseenTitleUnlock = false }
SkinController._latestStateTimestamp = 0
SkinController._pendingEquipRequest = nil
SkinController._pendingTrailEquipRequest = nil
SkinController._pendingTitleEquipRequest = nil
SkinController._bindRetryQueued = false
SkinController._panelTweens = {}
SkinController._panelAnimationSerial = 0
SkinController._isPanelOpen = false
SkinController._wheelController = nil
SkinController._sevenDayLoginRewardController = nil

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
local EQUIP_REQUEST_TIMEOUT_SECONDS = 4
local EQUIP_DUPLICATE_DEBOUNCE_SECONDS = 0.25
local TRAIL_ROW_VERTICAL_SCALE_STEP = 0.22
local TITLE_UNLOCK_CLOSE_DELAY = 1.5
local TITLE_UNLOCK_SLIDE_OFFSET_SCALE = 0.08
local TITLE_UNLOCK_OPEN_DURATION = 0.28

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
    local node = root and root:FindFirstChild(name, true)
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

local function setButtonInteractivity(root, enabled)
    if not (root and root:IsA("GuiObject")) then
        return
    end

    local isEnabled = enabled == true
    if root:IsA("GuiButton") then
        root.Active = isEnabled
        root.Selectable = isEnabled
    end
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            descendant.Active = isEnabled
            descendant.Selectable = isEnabled
        end
    end
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

local function setMarketplaceGamePassPrice(textObject, gamePassId)
    if not textObject then
        return
    end

    local resolvedGamePassId = math.floor(tonumber(gamePassId) or 0)
    if resolvedGamePassId <= 0 then
        return
    end

    local fallbackText = tostring(textObject.Text or "")
    setText(textObject, "...")
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedGamePassId, Enum.InfoType.GamePass)
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

local function setMarketplaceProductPrice(textObject, productId)
    if not textObject then
        return
    end

    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 then
        return
    end

    local fallbackText = tostring(textObject.Text or "")
    setText(textObject, "...")
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedProductId, Enum.InfoType.Product)
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

local function normalizeOptionalSkinId(value)
    local skinId = math.floor(tonumber(value) or 0)
    if skinId > 0 then
        return skinId
    end
    return nil
end

local function normalizeOptionalTrailId(value)
    local trailId = math.floor(tonumber(value) or 0)
    if trailId > 0 then
        return trailId
    end
    return nil
end

local function normalizeOptionalTitleId(value)
    local titleId = math.floor(tonumber(value) or 0)
    if titleId > 0 then
        return titleId
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

function SkinController:_notify(message)
    task.spawn(function()
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "Skin",
                Text = tostring(message or ""),
                Duration = 2,
            })
        end)
    end)
end

function SkinController:_disconnectTitleUnlockInput()
    if self._titleUnlockInputConnection and self._titleUnlockInputConnection.Connected then
        self._titleUnlockInputConnection:Disconnect()
    end
    self._titleUnlockInputConnection = nil
end

function SkinController:_setSkinRedPointVisible(visible)
    local redPoint = self._leftEntry and self._leftEntry:FindFirstChild("RedPoint", true)
    if redPoint and redPoint:IsA("GuiObject") then
        redPoint.Visible = visible == true
    end
end

function SkinController:_applyButtonState(binding)
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

function SkinController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end
    if button.Visible ~= false then
        button.Active = true
        button.Selectable = true
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

function SkinController:_disconnectButtonBindings()
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

function SkinController:_disconnectItemButtonBindings()
    for _, binding in ipairs(self._itemButtonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
        end
    end
    table.clear(self._itemButtonBindings)
end

function SkinController:_bindItemButton(button, onActivated, options)
    local beforeCount = #self._buttonBindings
    self:_bindButton(button, onActivated, options)
    for index = beforeCount + 1, #self._buttonBindings do
        table.insert(self._itemButtonBindings, self._buttonBindings[index])
    end
    for index = #self._buttonBindings, beforeCount + 1, -1 do
        table.remove(self._buttonBindings, index)
    end
end

function SkinController:_setActiveCustomizationTab(tabName)
    local normalizedTab = tabName == "Trails" and "Trails" or tabName == "Titles" and "Titles" or "Skins"
    self._activeTab = normalizedTab

    for name, page in pairs(self._pageFrames or {}) do
        if page and page:IsA("GuiObject") then
            page.Visible = name == normalizedTab
        end
    end

    for name, buttonRoot in pairs(self._tabButtons or {}) do
        if buttonRoot and buttonRoot:IsA("GuiObject") then
            local idle = buttonRoot:FindFirstChild("IdleBg")
            local selected = buttonRoot:FindFirstChild("SelectedBg")
            local label = buttonRoot:FindFirstChild("TextLabel")
            if idle then
                idle.Visible = name ~= normalizedTab
            end
            if selected then
                selected.Visible = name == normalizedTab
            end
            if label and label:IsA("TextLabel") then
                label.TextColor3 = name == normalizedTab and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(115, 83, 18)
                label.TextStrokeTransparency = name == normalizedTab and 0.35 or 0.72
            end
        end
    end
end

function SkinController:_bindCustomizationTabs(panel)
    self._tabButtons = {}
    self._pageFrames = {}

    local tabs = panel and panel:FindFirstChild("Tabs")
    local skinsTab = tabs and tabs:FindFirstChild("SkinsTab")
    local trailsTab = tabs and tabs:FindFirstChild("TrailsTab")
    local titlesTab = tabs and tabs:FindFirstChild("TitlesTab")
    local skinsPage = panel and panel:FindFirstChild("Equipinfo")
    local trailsPage = panel and panel:FindFirstChild("TrailsPage")
    local titlesPage = panel and panel:FindFirstChild("TitlesPage")

    self._tabButtons.Skins = skinsTab
    self._tabButtons.Trails = trailsTab
    self._tabButtons.Titles = titlesTab
    self._pageFrames.Skins = skinsPage
    self._pageFrames.Trails = trailsPage
    self._pageFrames.Titles = titlesPage

    local function bindTab(name, root)
        local button = root and root:FindFirstChildWhichIsA("GuiButton", true)
        if not button then
            return
        end
        self:_bindButton(button, function()
            self:_setActiveCustomizationTab(name)
        end, {
            ScaleTarget = root,
        })
    end

    bindTab("Skins", skinsTab)
    bindTab("Trails", trailsTab)
    bindTab("Titles", titlesTab)
    self:_setActiveCustomizationTab(self._activeTab or "Skins")
end

function SkinController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function SkinController:_setPanelOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isPanelOpen = false
            ModalUiController:Release("Skin")
        end
        return
    end

    local uiScale = ensureUiScale(self._panel)
    self:_cancelPanelTweens()
    self._panelAnimationSerial += 1
    local serial = self._panelAnimationSerial
    self._isPanelOpen = isOpen == true

    if self._isPanelOpen then
        ModalUiController:Acquire("Skin", self._panel)
        self._panel.Visible = true
        self:_setSkinRedPointVisible(false)
        if self._requestStateEvent then
            self._requestStateEvent:FireServer({
                intent = "SkinPanelOpened",
                source = "Skin",
            })
        end
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
            if self._panelAnimationSerial ~= serial or not self._isPanelOpen then
                return
            end
            settle:Play()
            settle.Completed:Wait()
            if self._panelAnimationSerial == serial and self._isPanelOpen and uiScale then
                uiScale.Scale = 1
            end
            table.clear(self._panelTweens)
        end)
        return
    end

    if not uiScale or immediate == true or self._panel.Visible ~= true then
        if uiScale then
            uiScale.Scale = 1
        end
        self._panel.Visible = false
        ModalUiController:Release("Skin")
        return
    end

    local shrink = TweenService:Create(uiScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { shrink }
    task.spawn(function()
        shrink:Play()
        shrink.Completed:Wait()
        if self._panelAnimationSerial ~= serial or self._isPanelOpen then
            return
        end
        uiScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release("Skin")
    end)
end

function SkinController:_closeTitleUnlockPopup()
    if not (self._titleUnlockPopup and self._titleUnlockPopup:IsA("GuiObject")) then
        return
    end
    if not self._titleUnlockCanClose then
        return
    end

    self:_disconnectTitleUnlockInput()
    self._titleUnlockCanClose = false
    self._titleUnlockSerial += 1
    self._titleUnlockPopup.Visible = false
    if self._titleUnlockOriginalPosition then
        self._titleUnlockPopup.Position = self._titleUnlockOriginalPosition
    end
    ModalUiController:Release("TitleUnlock")
end

function SkinController:_playTitleUnlockPopup(title)
    if not (self._titleUnlockPopup and self._titleUnlockPopup:IsA("GuiObject")) then
        self:_bindUi(true)
    end
    if not (self._titleUnlockPopup and self._titleUnlockPopup:IsA("GuiObject")) then
        self:_notify("Title unlocked.")
        return
    end

    self:_disconnectTitleUnlockInput()
    self._titleUnlockCanClose = false
    self._titleUnlockSerial += 1
    local serial = self._titleUnlockSerial

    setImage(self._titleUnlockPopup:FindFirstChild("Titleimage", true), title and title.iconImage)
    setText(self._titleUnlockPopup:FindFirstChild("Des", true), title and (title.description or title.unlockConditionText or title.name) or "")

    local originalPosition = self._titleUnlockOriginalPosition or self._titleUnlockPopup.Position
    self._titleUnlockOriginalPosition = originalPosition
    self._titleUnlockPopup.Position = UDim2.new(
        originalPosition.X.Scale + TITLE_UNLOCK_SLIDE_OFFSET_SCALE,
        originalPosition.X.Offset,
        originalPosition.Y.Scale,
        originalPosition.Y.Offset
    )
    ModalUiController:Acquire("TitleUnlock", self._titleUnlockPopup)
    self._titleUnlockPopup.Visible = true
    TweenService:Create(self._titleUnlockPopup, TweenInfo.new(TITLE_UNLOCK_OPEN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = originalPosition,
    }):Play()

    task.delay(TITLE_UNLOCK_CLOSE_DELAY, function()
        if self._titleUnlockSerial ~= serial or not (self._titleUnlockPopup and self._titleUnlockPopup.Parent) then
            return
        end
        self._titleUnlockCanClose = true
        self:_disconnectTitleUnlockInput()
        self._titleUnlockInputConnection = UserInputService.InputBegan:Connect(function(inputObject)
            local inputType = inputObject.UserInputType
            if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
                self:_closeTitleUnlockPopup()
            end
        end)
    end)
end

function SkinController:_clearItems()
    self:_disconnectItemButtonBindings()
    for _, frame in ipairs(self._itemFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
    end
    table.clear(self._itemFrames)
end

function SkinController:_clearTrailItems()
    for index = #self._itemFrames, 1, -1 do
        local frame = self._itemFrames[index]
        if frame and frame.Parent == self._trailScrollingFrame then
            frame:Destroy()
            table.remove(self._itemFrames, index)
        end
    end
end

function SkinController:_getSkinEntries()
    local byId = {}
    for _, entry in ipairs(self._latestState.skins or {}) do
        byId[tonumber(entry.id)] = entry
    end

    local entries = {}
    for _, skin in ipairs(SkinConfig.GetAllSkins()) do
        local stateEntry = byId[skin.Id] or {}
        table.insert(entries, {
            id = skin.Id,
            name = stateEntry.name or skin.Name,
            iconImage = stateEntry.iconImage or skin.IconImage,
            purchaseChannel = tonumber(stateEntry.purchaseChannel) or skin.PurchaseChannel,
            diamondPrice = tonumber(stateEntry.diamondPrice) or skin.DiamondPrice,
            gamePassId = tonumber(stateEntry.gamePassId) or skin.GamePassId,
            owned = stateEntry.owned == true,
            equipped = stateEntry.equipped == true or tonumber(self._latestState.equippedSkinId) == skin.Id,
        })
    end
    return entries
end

function SkinController:_getTrailEntries()
    local byId = {}
    for _, entry in ipairs(self._latestState.trails or {}) do
        byId[tonumber(entry.id)] = entry
    end

    local entries = {}
    for _, trail in ipairs(TrailConfig.GetAllTrails()) do
        local stateEntry = byId[trail.Id] or {}
        table.insert(entries, {
            id = trail.Id,
            name = stateEntry.name or trail.Name,
            iconImage = stateEntry.iconImage or trail.IconImage,
            diamondPrice = tonumber(stateEntry.diamondPrice) or trail.DiamondPrice,
            robuxPrice = tonumber(stateEntry.robuxPrice) or trail.RobuxPrice,
            productId = tonumber(stateEntry.productId) or trail.ProductId,
            owned = stateEntry.owned == true,
            equipped = stateEntry.equipped == true or tonumber(self._latestState.equippedTrailId) == trail.Id,
        })
    end
    return entries
end

function SkinController:_getTitleEntries()
    local byId = {}
    for _, entry in ipairs(self._latestState.titles or {}) do
        byId[tonumber(entry.id)] = entry
    end

    local entries = {}
    for _, title in ipairs(TitleConfig.GetAllTitles()) do
        local stateEntry = byId[title.Id] or {}
        table.insert(entries, {
            id = title.Id,
            name = stateEntry.name or title.Name,
            description = stateEntry.description or title.Description,
            unlockConditionText = stateEntry.unlockConditionText or title.UnlockConditionText,
            iconImage = stateEntry.iconImage or title.IconImage,
            owned = stateEntry.owned == true,
            equipped = stateEntry.equipped == true or tonumber(self._latestState.equippedTitleId) == title.Id,
        })
    end
    return entries
end

function SkinController:_setButtonVisible(frame, buttonName, visible)
    local buttonRoot = frame and frame:FindFirstChild(buttonName, true)
    if buttonRoot and buttonRoot:IsA("GuiObject") then
        local isVisible = visible == true
        buttonRoot.Visible = isVisible
        setButtonInteractivity(buttonRoot, isVisible)
    end
end

function SkinController:_isEquipRequestPending()
    local pending = self._pendingEquipRequest
    if not pending then
        return false
    end
    if os.clock() - (pending.startedAt or 0) > EQUIP_REQUEST_TIMEOUT_SECONDS then
        self._pendingEquipRequest = nil
        return false
    end
    return true
end

function SkinController:_setLocalEquippedSkinId(equippedSkinId)
    local normalizedEquippedSkinId = normalizeOptionalSkinId(equippedSkinId)
    self._latestState = self._latestState or { skins = {}, equippedSkinId = nil }
    self._latestState.equippedSkinId = normalizedEquippedSkinId
    for _, entry in ipairs(self._latestState.skins or {}) do
        entry.equipped = normalizedEquippedSkinId ~= nil and normalizeOptionalSkinId(entry.id) == normalizedEquippedSkinId
    end
    self:_renderList()
end

function SkinController:_setLocalEquippedTrailId(equippedTrailId)
    local normalizedEquippedTrailId = normalizeOptionalTrailId(equippedTrailId)
    self._latestState = self._latestState or { skins = {}, equippedSkinId = nil, trails = {}, equippedTrailId = nil }
    self._latestState.equippedTrailId = normalizedEquippedTrailId
    for _, entry in ipairs(self._latestState.trails or {}) do
        entry.equipped = normalizedEquippedTrailId ~= nil and normalizeOptionalTrailId(entry.id) == normalizedEquippedTrailId
    end
    self:_renderList()
end

function SkinController:_setLocalEquippedTitleId(equippedTitleId)
    local normalizedEquippedTitleId = normalizeOptionalTitleId(equippedTitleId)
    self._latestState = self._latestState or { skins = {}, equippedSkinId = nil, trails = {}, equippedTrailId = nil, titles = {}, equippedTitleId = nil }
    self._latestState.equippedTitleId = normalizedEquippedTitleId
    for _, entry in ipairs(self._latestState.titles or {}) do
        entry.equipped = normalizedEquippedTitleId ~= nil and normalizeOptionalTitleId(entry.id) == normalizedEquippedTitleId
    end
    self:_renderList()
end

function SkinController:_shouldIgnoreIncomingSkinState(equippedSkinId)
    if not self:_isEquipRequestPending() then
        return false
    end

    local pending = self._pendingEquipRequest
    local expectedEquippedSkinId = normalizeOptionalSkinId(pending and pending.expectedEquippedSkinId)
    local incomingEquippedSkinId = normalizeOptionalSkinId(equippedSkinId)
    if expectedEquippedSkinId == incomingEquippedSkinId then
        self._pendingEquipRequest = nil
        return false
    end

    return true
end

function SkinController:_shouldIgnoreIncomingTrailState(equippedTrailId)
    if not self:_isTrailEquipRequestPending() then
        return false
    end

    local pending = self._pendingTrailEquipRequest
    local expectedEquippedTrailId = normalizeOptionalTrailId(pending and pending.expectedEquippedTrailId)
    local incomingEquippedTrailId = normalizeOptionalTrailId(equippedTrailId)
    if expectedEquippedTrailId == incomingEquippedTrailId then
        self._pendingTrailEquipRequest = nil
        return false
    end

    return true
end

function SkinController:_shouldIgnoreIncomingTitleState(equippedTitleId)
    if not self:_isTitleEquipRequestPending() then
        return false
    end

    local pending = self._pendingTitleEquipRequest
    local expectedEquippedTitleId = normalizeOptionalTitleId(pending and pending.expectedEquippedTitleId)
    local incomingEquippedTitleId = normalizeOptionalTitleId(equippedTitleId)
    if expectedEquippedTitleId == incomingEquippedTitleId then
        self._pendingTitleEquipRequest = nil
        return false
    end

    return true
end

function SkinController:_isDuplicateSkinEquipRequest(skinId, action)
    local pending = self._pendingEquipRequest
    if not pending then
        return false
    end

    local elapsed = os.clock() - (pending.startedAt or 0)
    if elapsed > EQUIP_REQUEST_TIMEOUT_SECONDS then
        self._pendingEquipRequest = nil
        return false
    end

    return elapsed <= EQUIP_DUPLICATE_DEBOUNCE_SECONDS
        and normalizeOptionalSkinId(pending.skinId) == normalizeOptionalSkinId(skinId)
        and tostring(pending.action or "Equip") == tostring(action or "Equip")
end

function SkinController:_requestEquipChange(skinId, action)
    if not self._requestEquipEvent then
        return
    end

    local normalizedSkinId = normalizeOptionalSkinId(skinId)
    if not normalizedSkinId then
        return
    end

    local normalizedAction = tostring(action or "")
    local requestAction = normalizedAction == "Unequip" and "Unequip" or "Equip"
    if self:_isDuplicateSkinEquipRequest(normalizedSkinId, requestAction) then
        return
    end

    local expectedEquippedSkinId = nil
    if requestAction ~= "Unequip" then
        expectedEquippedSkinId = normalizedSkinId
    end
    self._pendingEquipRequest = {
        skinId = normalizedSkinId,
        action = requestAction,
        expectedEquippedSkinId = expectedEquippedSkinId,
        startedAt = os.clock(),
    }
    self:_setLocalEquippedSkinId(expectedEquippedSkinId)

    if requestAction == "Unequip" then
        self._requestEquipEvent:FireServer(normalizedSkinId, "Unequip")
    else
        self._requestEquipEvent:FireServer(normalizedSkinId)
    end
end

function SkinController:_isTrailEquipRequestPending()
    local pending = self._pendingTrailEquipRequest
    if not pending then
        return false
    end
    if os.clock() - (pending.startedAt or 0) > EQUIP_REQUEST_TIMEOUT_SECONDS then
        self._pendingTrailEquipRequest = nil
        return false
    end
    return true
end

function SkinController:_requestTrailEquipChange(trailId, action)
    if not self._requestEquipEvent or self:_isTrailEquipRequestPending() then
        return
    end

    local normalizedTrailId = normalizeOptionalTrailId(trailId)
    if not normalizedTrailId then
        return
    end

    local normalizedAction = tostring(action or "")
    local expectedEquippedTrailId = nil
    if normalizedAction ~= "Unequip" then
        expectedEquippedTrailId = normalizedTrailId
    end
    self._pendingTrailEquipRequest = {
        trailId = normalizedTrailId,
        action = normalizedAction == "Unequip" and "Unequip" or "Equip",
        expectedEquippedTrailId = expectedEquippedTrailId,
        startedAt = os.clock(),
    }
    self:_setLocalEquippedTrailId(expectedEquippedTrailId)

    self._requestEquipEvent:FireServer(normalizedTrailId, {
        itemType = "Trail",
        action = normalizedAction == "Unequip" and "Unequip" or "Equip",
    })
end

function SkinController:_isTitleEquipRequestPending()
    local pending = self._pendingTitleEquipRequest
    if not pending then
        return false
    end
    if os.clock() - (pending.startedAt or 0) > EQUIP_REQUEST_TIMEOUT_SECONDS then
        self._pendingTitleEquipRequest = nil
        return false
    end
    return true
end

function SkinController:_requestTitleEquipChange(titleId, action)
    if not self._requestEquipEvent or self:_isTitleEquipRequestPending() then
        return
    end

    local normalizedTitleId = normalizeOptionalTitleId(titleId)
    if not normalizedTitleId then
        return
    end

    local normalizedAction = tostring(action or "")
    local expectedEquippedTitleId = nil
    if normalizedAction ~= "Unequip" then
        expectedEquippedTitleId = normalizedTitleId
    end
    self._pendingTitleEquipRequest = {
        titleId = normalizedTitleId,
        action = normalizedAction == "Unequip" and "Unequip" or "Equip",
        expectedEquippedTitleId = expectedEquippedTitleId,
        startedAt = os.clock(),
    }
    self:_setLocalEquippedTitleId(expectedEquippedTitleId)

    self._requestEquipEvent:FireServer(normalizedTitleId, {
        itemType = "Title",
        action = normalizedAction == "Unequip" and "Unequip" or "Equip",
    })
end

function SkinController:_populateItem(frame, skin)
    setText(frame:FindFirstChild("Name"), skin.name or ("Skin " .. tostring(skin.id)))
    local itemTemplate = frame:FindFirstChild("ItemTemplate", true)
    setImage(itemTemplate and itemTemplate:FindFirstChild("ItemIcon", true), skin.iconImage)

    local owned = skin.owned == true
    local equipped = skin.equipped == true
    self:_setButtonVisible(frame, "DiamondButton", not owned and skin.purchaseChannel == SkinConfig.PurchaseChannel.Diamonds)
    self:_setButtonVisible(frame, "RobuxBuyButton", not owned and skin.purchaseChannel == SkinConfig.PurchaseChannel.GamePass)
    self:_setButtonVisible(frame, "WheelButton", not owned and skin.purchaseChannel == SkinConfig.PurchaseChannel.Wheel)
    self:_setButtonVisible(frame, "SevendaysButton", not owned and skin.purchaseChannel == SkinConfig.PurchaseChannel.SevenDayLoginReward)
    self:_setButtonVisible(frame, "EquipButton", owned and not equipped)
    self:_setButtonVisible(frame, "Equiped", false)
    self:_setButtonVisible(frame, "Unequiped", owned and equipped)

    local diamondButton, diamondScaleTarget = findButton(frame, "DiamondButton")
    if diamondButton then
        local priceLabel = diamondScaleTarget and diamondScaleTarget:FindFirstChild("RMoney", true)
        setText(priceLabel, skin.diamondPrice)
        self:_bindItemButton(diamondButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(skin.id, {
                    source = "Skin",
                    purchaseType = "Skin",
                    productGroup = "skin",
                    itemSku = tostring(skin.id),
                })
            end
        end, { ScaleTarget = diamondScaleTarget or diamondButton })
    end

    local robuxButton, robuxScaleTarget = findButton(frame, "RobuxBuyButton")
    if robuxButton then
        local priceLabel = robuxScaleTarget and robuxScaleTarget:FindFirstChild("RMoney", true)
        setText(priceLabel, "299")
        setMarketplaceGamePassPrice(priceLabel, skin.gamePassId)
        self:_bindItemButton(robuxButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(skin.id, {
                    source = "Skin",
                    purchaseType = "Skin",
                    productGroup = "GamePassSkin",
                    itemSku = tostring(skin.gamePassId),
                })
            end
            local gamePassId = math.max(0, math.floor(tonumber(skin.gamePassId) or 0))
            if gamePassId > 0 and self._localPlayer then
                MarketplaceService:PromptGamePassPurchase(self._localPlayer, gamePassId)
            end
        end, { ScaleTarget = robuxScaleTarget or robuxButton })
    end

    local wheelButton, wheelScaleTarget = findButton(frame, "WheelButton")
    if wheelButton then
        self:_bindItemButton(wheelButton, function()
            self:_setPanelOpen(false, true)
            if self._wheelController and self._wheelController.Open then
                self._wheelController:Open()
            end
        end, { ScaleTarget = wheelScaleTarget or wheelButton })
    end

    local sevenDayButton, sevenDayScaleTarget = findButton(frame, "SevendaysButton")
    if sevenDayButton then
        self:_bindItemButton(sevenDayButton, function()
            self:_setPanelOpen(false, true)
            if self._sevenDayLoginRewardController and self._sevenDayLoginRewardController.OpenSevenDayLoginReward then
                self._sevenDayLoginRewardController:OpenSevenDayLoginReward()
            end
        end, { ScaleTarget = sevenDayScaleTarget or sevenDayButton })
    end

    local equipButton, equipScaleTarget = findButton(frame, "EquipButton")
    if equipButton then
        self:_bindItemButton(equipButton, function()
            self:_requestEquipChange(skin.id)
        end, { ScaleTarget = equipScaleTarget or equipButton })
    end

    local unequipButton, unequipScaleTarget = findButton(frame, "Unequiped")
    if unequipButton then
        self:_bindItemButton(unequipButton, function()
            self:_requestEquipChange(skin.id, "Unequip")
        end, { ScaleTarget = unequipScaleTarget or unequipButton })
    end
end

function SkinController:_populateTrailItem(frame, trail)
    setText(frame:FindFirstChild("Name", true), trail.name or ("Trail " .. tostring(trail.id)))
    setImage(frame:FindFirstChild("Preview", true), trail.iconImage)

    local owned = trail.owned == true
    local equipped = trail.equipped == true
    self:_setButtonVisible(frame, "DiamondBuy", not owned)
    self:_setButtonVisible(frame, "RobuxButton", not owned)
    self:_setButtonVisible(frame, "Equip", owned and not equipped)
    self:_setButtonVisible(frame, "Unequiped", owned and equipped)

    local diamondButton, diamondScaleTarget = findButton(frame, "DiamondBuy")
    if diamondButton then
        local priceLabel = diamondScaleTarget and (diamondScaleTarget:FindFirstChild("RMoney", true) or diamondScaleTarget:FindFirstChild("Text", true) or diamondScaleTarget:FindFirstChild("Price", true))
        setText(priceLabel, trail.diamondPrice)
        self:_bindItemButton(diamondButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(trail.id, {
                    itemType = "Trail",
                    source = "Trail",
                    purchaseMethod = "Diamonds",
                    productGroup = "trail",
                    itemSku = tostring(trail.id),
                })
            end
        end, { ScaleTarget = diamondScaleTarget or diamondButton })
    end

    local robuxButton, robuxScaleTarget = findButton(frame, "RobuxButton")
    if robuxButton then
        local priceLabel = robuxScaleTarget and (robuxScaleTarget:FindFirstChild("RMoney", true) or robuxScaleTarget:FindFirstChild("Price", true))
        setText(priceLabel, trail.robuxPrice)
        setMarketplaceProductPrice(priceLabel, trail.productId)
        self:_bindItemButton(robuxButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(trail.id, {
                    itemType = "Trail",
                    source = "Trail",
                    purchaseMethod = "Robux",
                    productGroup = "trail",
                    itemSku = tostring(trail.productId),
                })
            end
            local productId = math.max(0, math.floor(tonumber(trail.productId) or 0))
            if productId > 0 and self._localPlayer then
                MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
            end
        end, { ScaleTarget = robuxScaleTarget or robuxButton })
    end

    local equipButton, equipScaleTarget = findButton(frame, "Equip")
    if equipButton then
        self:_bindItemButton(equipButton, function()
            self:_requestTrailEquipChange(trail.id)
        end, { ScaleTarget = equipScaleTarget or equipButton })
    end

    local unequipButton, unequipScaleTarget = findButton(frame, "Unequiped")
    if unequipButton then
        self:_bindItemButton(unequipButton, function()
            self:_requestTrailEquipChange(trail.id, "Unequip")
        end, { ScaleTarget = unequipScaleTarget or unequipButton })
    end
end

function SkinController:_populateTitleItem(frame, title)
    setText(frame:FindFirstChild("Name", true), title.name or ("Title " .. tostring(title.id)))
    setText(frame:FindFirstChild("Desc", true), title.description or title.unlockConditionText or "")
    setImage(frame:FindFirstChild("Preview", true), title.iconImage)

    local owned = title.owned == true
    local equipped = title.equipped == true
    self:_setButtonVisible(frame, "Locked", not owned)
    self:_setButtonVisible(frame, "Equip", owned and not equipped)
    self:_setButtonVisible(frame, "Unequiped", owned and equipped)

    local equipButton, equipScaleTarget = findButton(frame, "Equip")
    if equipButton then
        self:_bindItemButton(equipButton, function()
            self:_requestTitleEquipChange(title.id)
        end, { ScaleTarget = equipScaleTarget or equipButton })
    end

    local unequipButton, unequipScaleTarget = findButton(frame, "Unequiped")
    if unequipButton then
        self:_bindItemButton(unequipButton, function()
            self:_requestTitleEquipChange(title.id, "Unequip")
        end, { ScaleTarget = unequipScaleTarget or unequipButton })
    end
end

function SkinController:_renderList()
    if not (self._scrollingFrame and self._template) then
        return
    end

    self:_clearItems()
    self._template.Visible = false
    for _, skin in ipairs(self:_getSkinEntries()) do
        local frame = self._template:Clone()
        frame.Name = "Skin_" .. tostring(skin.id)
        frame.Visible = true
        frame.Parent = self._scrollingFrame
        table.insert(self._itemFrames, frame)
        self:_populateItem(frame, skin)
    end

    if self._trailScrollingFrame and self._trailTemplate then
        self._trailTemplate.Visible = false
        local trailEntries = self:_getTrailEntries()
        local templatePosition = self._trailTemplate.Position
        local templateSize = self._trailTemplate.Size
        local rowStepScale = math.max(
            TRAIL_ROW_VERTICAL_SCALE_STEP,
            math.abs(templateSize.Y.Scale) > 0 and templateSize.Y.Scale + 0.03 or TRAIL_ROW_VERTICAL_SCALE_STEP
        )
        for index, trail in ipairs(trailEntries) do
            local frame = self._trailTemplate:Clone()
            frame.Name = "Trail_" .. tostring(trail.id)
            frame.LayoutOrder = index
            frame.Position = UDim2.new(
                templatePosition.X.Scale,
                templatePosition.X.Offset,
                templatePosition.Y.Scale + rowStepScale * (index - 1),
                templatePosition.Y.Offset
            )
            frame.Visible = true
            frame.Parent = self._trailScrollingFrame
            table.insert(self._itemFrames, frame)
            self:_populateTrailItem(frame, trail)
        end
        local requiredCanvasScaleY = math.max(1, templatePosition.Y.Scale + rowStepScale * math.max(1, #trailEntries) + 0.05)
        self._trailScrollingFrame.CanvasSize = UDim2.new(
            self._trailScrollingFrame.CanvasSize.X.Scale,
            self._trailScrollingFrame.CanvasSize.X.Offset,
            requiredCanvasScaleY,
            self._trailScrollingFrame.CanvasSize.Y.Offset
        )
    end

    if self._titleScrollingFrame and self._titleTemplate then
        self._titleTemplate.Visible = false
        local titleEntries = self:_getTitleEntries()
        local templatePosition = self._titleTemplate.Position
        local templateSize = self._titleTemplate.Size
        local rowStepScale = math.max(
            TRAIL_ROW_VERTICAL_SCALE_STEP,
            math.abs(templateSize.Y.Scale) > 0 and templateSize.Y.Scale + 0.03 or TRAIL_ROW_VERTICAL_SCALE_STEP
        )
        for index, title in ipairs(titleEntries) do
            local frame = self._titleTemplate:Clone()
            frame.Name = "Title_" .. tostring(title.id)
            frame.LayoutOrder = index
            frame.Position = UDim2.new(
                templatePosition.X.Scale,
                templatePosition.X.Offset,
                templatePosition.Y.Scale + rowStepScale * (index - 1),
                templatePosition.Y.Offset
            )
            frame.Visible = true
            frame.Parent = self._titleScrollingFrame
            table.insert(self._itemFrames, frame)
            self:_populateTitleItem(frame, title)
        end
        local requiredCanvasScaleY = math.max(1, templatePosition.Y.Scale + rowStepScale * math.max(1, #titleEntries) + 0.05)
        self._titleScrollingFrame.CanvasSize = UDim2.new(
            self._titleScrollingFrame.CanvasSize.X.Scale,
            self._titleScrollingFrame.CanvasSize.X.Offset,
            requiredCanvasScaleY,
            self._titleScrollingFrame.CanvasSize.Y.Offset
        )
    end
end

function SkinController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end
    local timestamp = tonumber(payload.timestamp)
    if timestamp and timestamp < (self._latestStateTimestamp or 0) then
        return
    end

    local equippedSkinId = normalizeOptionalSkinId(payload.equippedSkinId)
    local equippedTrailId = normalizeOptionalTrailId(payload.equippedTrailId)
    local equippedTitleId = normalizeOptionalTitleId(payload.equippedTitleId)
    local ignoreSkinState = self:_shouldIgnoreIncomingSkinState(equippedSkinId)
    local ignoreTrailState = self:_shouldIgnoreIncomingTrailState(equippedTrailId)
    local ignoreTitleState = self:_shouldIgnoreIncomingTitleState(equippedTitleId)

    local skins = type(payload.skins) == "table" and payload.skins or {}
    local trails = type(payload.trails) == "table" and payload.trails or {}
    local titles = type(payload.titles) == "table" and payload.titles or {}
    local currentState = self._latestState or { skins = {}, trails = {}, titles = {}, equippedSkinId = nil, equippedTrailId = nil, equippedTitleId = nil }
    if ignoreSkinState then
        skins = currentState.skins or {}
        equippedSkinId = currentState.equippedSkinId
    else
        for _, entry in ipairs(skins) do
            entry.equipped = equippedSkinId ~= nil and normalizeOptionalSkinId(entry.id) == equippedSkinId
        end
    end
    if ignoreTrailState then
        trails = currentState.trails or {}
        equippedTrailId = currentState.equippedTrailId
    else
        for _, entry in ipairs(trails) do
            entry.equipped = equippedTrailId ~= nil and normalizeOptionalTrailId(entry.id) == equippedTrailId
        end
    end
    if ignoreTitleState then
        titles = currentState.titles or {}
        equippedTitleId = currentState.equippedTitleId
    else
        for _, entry in ipairs(titles) do
            entry.equipped = equippedTitleId ~= nil and normalizeOptionalTitleId(entry.id) == equippedTitleId
        end
    end

    self._latestState = {
        skins = skins,
        equippedSkinId = equippedSkinId,
        trails = trails,
        equippedTrailId = equippedTrailId,
        titles = titles,
        equippedTitleId = equippedTitleId,
        hasUnseenTitleUnlock = payload.hasUnseenTitleUnlock == true,
    }
    if timestamp then
        self._latestStateTimestamp = timestamp
    end
    self:_setSkinRedPointVisible(payload.hasUnseenTitleUnlock == true)
    self:_renderList()
end

function SkinController:_applyPlayerState(payload)
    if type(payload) ~= "table" then
        return
    end

    local equippedSkinId = tonumber(payload.equippedSkinId)
    local skins = {}
    for _, skin in ipairs(SkinConfig.GetAllSkins()) do
        table.insert(skins, {
            id = skin.Id,
            name = skin.Name,
            iconImage = skin.IconImage,
            purchaseChannel = skin.PurchaseChannel,
            diamondPrice = skin.DiamondPrice,
            gamePassId = skin.GamePassId,
            owned = type(payload.ownedSkins) == "table" and payload.ownedSkins[tostring(skin.Id)] == true,
            equipped = equippedSkinId == skin.Id,
        })
    end
    local equippedTrailId = tonumber(payload.equippedTrailId)
    local trails = {}
    for _, trail in ipairs(TrailConfig.GetAllTrails()) do
        table.insert(trails, {
            id = trail.Id,
            name = trail.Name,
            iconImage = trail.IconImage,
            diamondPrice = trail.DiamondPrice,
            robuxPrice = trail.RobuxPrice,
            productId = trail.ProductId,
            owned = type(payload.ownedTrails) == "table" and payload.ownedTrails[tostring(trail.Id)] == true,
            equipped = equippedTrailId == trail.Id,
        })
    end
    local equippedTitleId = tonumber(payload.equippedTitleId)
    local titles = {}
    for _, title in ipairs(TitleConfig.GetAllTitles()) do
        table.insert(titles, {
            id = title.Id,
            name = title.Name,
            description = title.Description,
            unlockConditionText = title.UnlockConditionText,
            iconImage = title.IconImage,
            owned = type(payload.ownedTitles) == "table" and payload.ownedTitles[tostring(title.Id)] == true,
            equipped = equippedTitleId == title.Id,
        })
    end

    self:_applyState({
        skins = skins,
        equippedSkinId = equippedSkinId,
        trails = trails,
        equippedTrailId = equippedTrailId,
        titles = titles,
        equippedTitleId = equippedTitleId,
        hasUnseenTitleUnlock = payload.hasUnseenTitleUnlock == true,
        timestamp = payload.timestamp,
    })
end

function SkinController:_shouldIgnoreSkinFeedback(payload)
    local eventType = tostring(payload and payload.eventType or "")
    if eventType ~= "Equipped" and eventType ~= "Unequipped" and eventType ~= "Failed" then
        return false
    end
    if not self:_isEquipRequestPending() then
        return false
    end

    local pending = self._pendingEquipRequest
    local pendingSkinId = normalizeOptionalSkinId(pending and pending.skinId)
    local feedbackSkinId = normalizeOptionalSkinId(payload and payload.skinId)
    if feedbackSkinId ~= nil and pendingSkinId ~= nil and feedbackSkinId ~= pendingSkinId then
        return true
    end

    local state = type(payload and payload.state) == "table" and payload.state or nil
    if state and eventType ~= "Failed" then
        local expectedEquippedSkinId = normalizeOptionalSkinId(pending and pending.expectedEquippedSkinId)
        local incomingEquippedSkinId = normalizeOptionalSkinId(state.equippedSkinId)
        if incomingEquippedSkinId ~= expectedEquippedSkinId then
            return true
        end
    end

    return false
end

function SkinController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end
    local eventType = tostring(payload.eventType or "")
    local isTrail = tostring(payload.itemType or "") == "Trail"
    local isTitle = tostring(payload.itemType or "") == "Title"
    local isSkin = not isTrail and not isTitle
    if isSkin and self:_shouldIgnoreSkinFeedback(payload) then
        return
    end
    if eventType == "Equipped" or eventType == "Unequipped" or eventType == "Failed" then
        if isTitle then
            self._pendingTitleEquipRequest = nil
        elseif isTrail then
            self._pendingTrailEquipRequest = nil
        else
            self._pendingEquipRequest = nil
        end
    end
    if payload.state then
        self:_applyState(payload.state)
    end

    local reason = tostring(payload.reason or "")
    if eventType == "Unlocked" and isTitle then
        self:_playTitleUnlockPopup(payload.title or {})
        self:_setSkinRedPointVisible(true)
    elseif eventType == "Purchased" then
        self:_notify(isTrail and "Trail unlocked." or "Skin unlocked.")
    elseif eventType == "Granted" then
        if isTitle then
            self:_playTitleUnlockPopup(payload.title or {})
            self:_setSkinRedPointVisible(true)
        else
            self:_notify(isTrail and "Trail unlocked." or "Skin unlocked.")
        end
    elseif eventType == "Equipped" then
        self:_notify(isTitle and "Title equipped." or isTrail and "Trail equipped." or "Skin equipped.")
    elseif eventType == "Unequipped" then
        self:_notify(isTitle and "Title unequipped." or isTrail and "Trail unequipped." or "Skin unequipped.")
    elseif eventType == "AlreadyOwned" then
        self:_notify("Already owned.")
    elseif eventType == "OpenWheel" then
        self:_setPanelOpen(false, true)
        if self._wheelController and self._wheelController.Open then
            self._wheelController:Open()
        end
    elseif eventType == "Failed" then
        if reason == "NotEnoughDiamonds" then
            self:_notify("Not enough diamonds.")
        elseif reason == "DataLoading" then
            self:_notify("Data is loading.")
        elseif reason == "NotOwned" then
            self:_notify(isTitle and "Title not owned." or isTrail and "Trail not owned." or "Skin not owned.")
        else
            self:_notify(isTitle and "Title unavailable." or isTrail and "Trail unavailable." or "Skin unavailable.")
        end
    end
end

function SkinController:_resolveEntryScaleTarget()
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

function SkinController:_resolveEntryRotationTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveEntryScaleTarget()
end

function SkinController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    if not mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local left = mainGui:FindFirstChild("Left")
    local leftEntry = left and left:FindFirstChild("Skin")
    local panel = mainGui:FindFirstChild("Skin")
    local equipInfo = panel and panel:FindFirstChild("Equipinfo")
    local scrollingFrame = equipInfo and equipInfo:FindFirstChild("ScrollingFrame")
    local template = scrollingFrame and scrollingFrame:FindFirstChild("EquipTemplate")
    local tabs = panel and panel:FindFirstChild("Tabs")
    local trailsPage = panel and panel:FindFirstChild("TrailsPage")
    local trailScrollingFrame = trailsPage and trailsPage:FindFirstChild("ScrollingFrame")
    local trailTemplate = trailScrollingFrame and trailScrollingFrame:FindFirstChild("TrailRowTemplate")
    local titlesPage = panel and panel:FindFirstChild("TitlesPage")
    local titleScrollingFrame = titlesPage and titlesPage:FindFirstChild("ScrollingFrame")
    local titleTemplate = titleScrollingFrame and titleScrollingFrame:FindFirstChild("TitleRowTemplate")
    local titleUnlockPopup = mainGui:FindFirstChild("TitleUnlock")
    if not (leftEntry and panel and scrollingFrame and template and tabs and trailsPage and trailScrollingFrame and trailTemplate and titlesPage and titleScrollingFrame and titleTemplate and panel:IsA("GuiObject") and template:IsA("GuiObject") and trailTemplate:IsA("GuiObject") and titleTemplate:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self:_clearItems()
    self._leftEntry = leftEntry
    self._panel = panel
    self._scrollingFrame = scrollingFrame
    self._template = template
    self._trailScrollingFrame = trailScrollingFrame
    self._trailTemplate = trailTemplate
    self._titleScrollingFrame = titleScrollingFrame
    self._titleTemplate = titleTemplate
    self._titleUnlockPopup = titleUnlockPopup
    self._titleUnlockOriginalPosition = titleUnlockPopup and titleUnlockPopup:IsA("GuiObject") and titleUnlockPopup.Position or nil
    self._template.Visible = false
    self._trailTemplate.Visible = false
    self._titleTemplate.Visible = false
    if self._titleUnlockPopup and self._titleUnlockPopup:IsA("GuiObject") then
        self._titleUnlockPopup.Visible = false
    end

    if self._panel.Visible ~= false then
        self._panel.Visible = false
    end

    local leftButton = leftEntry:FindFirstChildWhichIsA("GuiButton", true)
    local entryScaleTarget = self:_resolveEntryScaleTarget()
    local entryRotationTarget = self:_resolveEntryRotationTarget()
    self:_bindButton(leftButton, function()
        self:_setPanelOpen(true)
    end, {
        ScaleTarget = entryScaleTarget or leftButton,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        RotationTarget = entryRotationTarget,
        HoverRotation = HOVER_ROTATION,
    })

    local closeButton = panel:FindFirstChild("CloseButton", true)
    self:_bindButton(closeButton, function()
        self:_setPanelOpen(false)
    end, {
        RotationTarget = closeButton,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindCustomizationTabs(panel)
    self:_renderList()
    return true
end

function SkinController:_queueBindRetry()
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
        warn("[SkinController] Could not find PlayerGui/Main/Skin UI.")
    end)
end

function SkinController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[SkinController] Missing system events folder.")
        return
    end

    self._requestStateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSkinStateSync, 10)
    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.SkinStateSync, 10)
    self._requestPurchaseEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSkinPurchase, 10)
    self._requestEquipEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestSkinEquip, 10)
    self._feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.SkinFeedback, 10)
    self._playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)

    if self._playerStateSyncEvent then
        table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyPlayerState(payload)
        end))
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
    if self._requestStateEvent then
        self._requestStateEvent:FireServer()
    end
end

function SkinController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._wheelController = dependencies and dependencies.WheelController or nil
    self._sevenDayLoginRewardController = dependencies and dependencies.SevenDayLoginRewardController or nil
    self._activeTab = "Skins"
    self._latestStateTimestamp = 0
    self._pendingEquipRequest = nil
    self._pendingTrailEquipRequest = nil
    self._pendingTitleEquipRequest = nil
    self._titleUnlockCanClose = false
    self._titleUnlockSerial = 0
    self:_disconnectTitleUnlockInput()
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_disconnectItemButtonBindings()
    self:_clearItems()

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
end

return SkinController
