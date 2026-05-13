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

local SkinController = {}

SkinController._localPlayer = nil
SkinController._connections = {}
SkinController._buttonBindings = {}
SkinController._itemButtonBindings = {}
SkinController._itemFrames = {}
SkinController._mainGui = nil
SkinController._panel = nil
SkinController._leftEntry = nil
SkinController._scrollingFrame = nil
SkinController._template = nil
SkinController._requestStateEvent = nil
SkinController._stateSyncEvent = nil
SkinController._requestPurchaseEvent = nil
SkinController._requestEquipEvent = nil
SkinController._feedbackEvent = nil
SkinController._playerStateSyncEvent = nil
SkinController._latestState = { skins = {}, equippedSkinId = nil }
SkinController._bindRetryQueued = false
SkinController._panelTweens = {}
SkinController._panelAnimationSerial = 0
SkinController._isPanelOpen = false
SkinController._wheelController = nil

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.92
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 18
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
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

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function setImage(imageObject, image)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(image or "")
    end
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
        if self._requestStateEvent then
            self._requestStateEvent:FireServer()
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

function SkinController:_clearItems()
    self:_disconnectItemButtonBindings()
    for _, frame in ipairs(self._itemFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
    end
    table.clear(self._itemFrames)
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

function SkinController:_setButtonVisible(frame, buttonName, visible)
    local buttonRoot = frame and frame:FindFirstChild(buttonName, true)
    if buttonRoot and buttonRoot:IsA("GuiObject") then
        buttonRoot.Visible = visible == true
    end
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
    self:_setButtonVisible(frame, "EquipButton", owned and not equipped)
    self:_setButtonVisible(frame, "Equiped", owned and equipped)

    local diamondButton, diamondScaleTarget = findButton(frame, "DiamondButton")
    if diamondButton then
        local priceLabel = diamondScaleTarget and diamondScaleTarget:FindFirstChild("RMoney", true)
        setText(priceLabel, skin.diamondPrice)
        self:_bindItemButton(diamondButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(skin.id)
            end
        end, { ScaleTarget = diamondScaleTarget or diamondButton })
    end

    local robuxButton, robuxScaleTarget = findButton(frame, "RobuxBuyButton")
    if robuxButton then
        local priceLabel = robuxScaleTarget and robuxScaleTarget:FindFirstChild("RMoney", true)
        setText(priceLabel, "299")
        self:_bindItemButton(robuxButton, function()
            if self._requestPurchaseEvent then
                self._requestPurchaseEvent:FireServer(skin.id)
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

    local equipButton, equipScaleTarget = findButton(frame, "EquipButton")
    if equipButton then
        self:_bindItemButton(equipButton, function()
            if self._requestEquipEvent then
                self._requestEquipEvent:FireServer(skin.id)
            end
        end, { ScaleTarget = equipScaleTarget or equipButton })
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
end

function SkinController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end
    self._latestState = {
        skins = type(payload.skins) == "table" and payload.skins or {},
        equippedSkinId = tonumber(payload.equippedSkinId),
    }
    self:_renderList()
end

function SkinController:_applyPlayerState(payload)
    if type(payload) ~= "table" or type(payload.ownedSkins) ~= "table" then
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
            owned = payload.ownedSkins[tostring(skin.Id)] == true,
            equipped = equippedSkinId == skin.Id,
        })
    end

    self:_applyState({
        skins = skins,
        equippedSkinId = equippedSkinId,
    })
end

function SkinController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.state then
        self:_applyState(payload.state)
    end

    local eventType = tostring(payload.eventType or "")
    local reason = tostring(payload.reason or "")
    if eventType == "Purchased" then
        self:_notify("Skin unlocked.")
    elseif eventType == "Granted" then
        self:_notify("Skin unlocked.")
    elseif eventType == "Equipped" then
        self:_notify("Skin equipped.")
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
            self:_notify("Skin not owned.")
        else
            self:_notify("Skin unavailable.")
        end
    end
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
    if not (leftEntry and panel and scrollingFrame and template and panel:IsA("GuiObject") and template:IsA("GuiObject")) then
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
    self._template.Visible = false

    if self._panel.Visible ~= false then
        self._panel.Visible = false
    end

    local leftButton = leftEntry:FindFirstChildWhichIsA("GuiButton", true)
    self:_bindButton(leftButton, function()
        self:_setPanelOpen(true)
    end, {
        ScaleTarget = leftEntry,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        RotationTarget = leftEntry,
        HoverRotation = HOVER_ROTATION,
    })

    local closeButton = panel:FindFirstChild("CloseButton", true)
    self:_bindButton(closeButton, function()
        self:_setPanelOpen(false)
    end, {
        RotationTarget = closeButton,
        HoverRotation = HOVER_ROTATION,
    })

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
