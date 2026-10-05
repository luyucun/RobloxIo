--[[
脚本名字: LevelWeaponSkinController
脚本文件: LevelWeaponSkinController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/LevelWeaponSkinController
说明: V6.31 独立等级武器外观窗口（Main.LevelWeaponSkins）。
首次显示时克隆正式卡片模板，后续复用并按服务端状态增量刷新；仅发送装备/复原/自动开关意图。
正式HUD入口：Main.Left.Armory（V6.27.1）；Studio GM /levelskin 玩家属性入口保留。
旧静态入口 Main.Left.LevelWeaponSkinsButton 保持隐藏（V6.26 模板节点，未接线）。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
        "[LevelWeaponSkinController] 缺少共享模块 %s",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local controllersRoot = script.Parent:FindFirstChild("Controllers") or script.Parent
local ModalUiController = require(controllersRoot:WaitForChild("ModalUiController"))

local LOCKED_ICON_COLOR = Color3.new(0, 0, 0)
local LOCKED_BUTTON_BG = Color3.fromRGB(110, 110, 110)
local LOCKED_BUTTON_STROKE = Color3.fromRGB(75, 75, 75)
local LOCKED_TEXT_STROKE = Color3.fromRGB(65, 65, 65)

local WINDOW_OWNER_ID = "LevelWeaponSkins"

local LevelWeaponSkinController = {}

LevelWeaponSkinController._localPlayer = nil
LevelWeaponSkinController._window = nil
LevelWeaponSkinController._armoryButton = nil
LevelWeaponSkinController._armoryButtonConnection = nil
LevelWeaponSkinController._content = nil
LevelWeaponSkinController._scroll = nil
LevelWeaponSkinController._template = nil
LevelWeaponSkinController._cardsByTierIndex = {}
LevelWeaponSkinController._cardsReady = false
LevelWeaponSkinController._renderedState = nil
LevelWeaponSkinController._styleRefs = nil
LevelWeaponSkinController._connections = {}
LevelWeaponSkinController._connectionsByWindow = {}
LevelWeaponSkinController._bindSerial = 0
LevelWeaponSkinController._isWindowOpen = false
LevelWeaponSkinController._requestStateEvent = nil
LevelWeaponSkinController._requestEquipEvent = nil
LevelWeaponSkinController._state = nil
LevelWeaponSkinController._lastStateTimestamp = nil
LevelWeaponSkinController._catalog = nil

local function buildCatalog()
    local catalog = {}
    for index = 1, WeaponTierConfig.TotalTierCount do
        local tierName = WeaponTierConfig.Order[index]
        local tierConfig = tierName and WeaponTierConfig.Tiers[tierName] or nil
        catalog[index] = tierConfig and {
            tierIndex = index,
            name = WeaponTierConfig.GetDisplayNameForTier(tierName),
            icon = WeaponTierConfig.GetIconImageForTier(tierName),
            unlockLevel = WeaponTierConfig.GetUnlockLevelForTierIndex(index),
        } or nil
    end
    return catalog
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function setGuiButtonInteractable(button, enabled)
    if not (button and button:IsA("GuiButton")) then
        return
    end
    button.Active = enabled
    button.Selectable = enabled
    button.Interactable = enabled
    button.AutoButtonColor = enabled
end

local function statesMatch(left, right)
    return left ~= nil and right ~= nil
        and left.selectedTierIndex == right.selectedTierIndex
        and left.equippedSkinId == right.equippedSkinId
        and left.autoUpgrade == right.autoUpgrade
        and left.highestLevelReached == right.highestLevelReached
        and left.maxUnlockedTierIndex == right.maxUnlockedTierIndex
end

local function isLevelLookActive(state)
    return state ~= nil and state.selectedTierIndex == nil
        and state.equippedSkinId == nil and state.autoUpgrade == true
end

function LevelWeaponSkinController:_renderLevelLookButton()
    local button = self._content and self._content:FindFirstChild("UseLevelLookButton") or nil
    if not button then
        return
    end
    local ready = self._state ~= nil and self._requestEquipEvent ~= nil
    local active = ready and isLevelLookActive(self._state)
    local textLabel = button:FindFirstChild("Text")
    local label = not ready and "Loading..." or (active and "✓ Level Look" or "Use Level Look")
    if textLabel and textLabel.Text ~= label then
        textLabel.Text = label
    end
    setGuiButtonInteractable(button, ready and not active)
    local background = button:FindFirstChild("ImageLabel")
    local green = background and background:FindFirstChild("ButtonGreen") or nil
    local yellow = background and background:FindFirstChild("ButtonYellow") or nil
    if green and green:IsA("UIGradient") then
        green.Enabled = active
    end
    if yellow and yellow:IsA("UIGradient") then
        yellow.Enabled = not active
    end
end

function LevelWeaponSkinController:_onUseLevelLookActivated()
    -- A reset is meaningful only after the server confirms a custom appearance.
    -- Avoid rebuilding weapons / dirtying the save when already using level look.
    if not self._state or not self._requestEquipEvent or isLevelLookActive(self._state) then
        return
    end
    self:_requestEquip("UseLevelLook")
end

function LevelWeaponSkinController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end
    local timestamp = tonumber(payload.timestamp)
    if timestamp and self._lastStateTimestamp and timestamp < self._lastStateTimestamp then
        return
    end
    if timestamp then
        self._lastStateTimestamp = timestamp
    end
    local equippedSkinId = tonumber(payload.equippedSkinId)
    local state = {
        selectedTierIndex = not equippedSkinId and tonumber(payload.selectedTierIndex) or nil,
        equippedSkinId = equippedSkinId,
        autoUpgrade = payload.autoUpgrade ~= false,
        highestLevelReached = math.max(1, math.floor(tonumber(payload.highestLevelReached) or 1)),
        maxUnlockedTierIndex = math.max(1, math.floor(tonumber(payload.maxUnlockedTierIndex) or 1)),
    }
    local previous = self._state
    self._state = state
    -- All three state sources share this dedupe, including the response to opening.
    -- The latest timestamp is retained even when no displayed value changed.
    if statesMatch(previous, state) then
        return
    end
    self:_render()
end

function LevelWeaponSkinController:_applyPlayerState(payload)
    if type(payload) ~= "table" or type(payload.levelWeaponSkinAutoUpgrade) ~= "boolean"
        or payload.highestLevelReached == nil then
        return
    end
    local highest = math.max(1, math.floor(tonumber(payload.highestLevelReached) or 1))
    local loadout = WeaponTierConfig.ResolveLoadoutForLevel(highest)
    -- PlayerStateSync is a complete snapshot: nil selection clears the old badge.
    -- Skip unrelated health/experience updates, but keep the latest server timestamp.
    self:_applyState({
        selectedTierIndex = payload.selectedLevelWeaponTierIndex,
        equippedSkinId = payload.equippedSkinId,
        autoUpgrade = payload.levelWeaponSkinAutoUpgrade,
        highestLevelReached = highest,
        maxUnlockedTierIndex = loadout and loadout.TierIndex or 1,
        timestamp = payload.timestamp,
    })
end

function LevelWeaponSkinController:_requestState()
    if self._requestStateEvent then
        self._requestStateEvent:FireServer()
    end
end

function LevelWeaponSkinController:_requestEquip(payload, extra)
    if self._requestEquipEvent then
        self._requestEquipEvent:FireServer(payload, extra)
    end
end

function LevelWeaponSkinController:_setOpen(isOpen)
    self._isWindowOpen = isOpen == true
    if self._isWindowOpen then
        self:_requestState()
        if self._window then
            ModalUiController:PlayPanelOpen(WINDOW_OWNER_ID, self._window)
            -- Modal may defer opening during a cinematic. Its Visible signal will
            -- flush the latest state when it actually makes the panel visible.
            self:_render()
        end
        return
    end
    if self._window then
        ModalUiController:PlayPanelClose(WINDOW_OWNER_ID, self._window)
    else
        ModalUiController:PlayPanelClose(WINDOW_OWNER_ID, nil, { Immediate = true })
    end
end

function LevelWeaponSkinController:_onArmoryActivated()
    self:_setOpen(true)
end

function LevelWeaponSkinController:_bindArmory(armory)
    local button = armory and (armory:IsA("GuiButton") and armory or armory:FindFirstChildWhichIsA("GuiButton", true)) or nil
    if not button then
        return false
    end
    if self._armoryButton == button then
        return true
    end
    if self._armoryButtonConnection then
        self._armoryButtonConnection:Disconnect()
        self._armoryButtonConnection = nil
    end
    self._armoryButton = button
    setGuiButtonInteractable(button, true)
    self._armoryButtonConnection = button.Activated:Connect(function()
        self:_onArmoryActivated()
    end)
    return true
end

function LevelWeaponSkinController:_captureTemplateStyle(template)
    local equipButton = template:FindFirstChild("EquipButton")
    local equipImage = equipButton and equipButton:FindFirstChild("ImageLabel") or nil
    local equipStroke = equipImage and equipImage:FindFirstChildWhichIsA("UIStroke") or nil
    local textLabel = equipButton and equipButton:FindFirstChild("Text") or nil
    local textStroke = textLabel and textLabel:FindFirstChildWhichIsA("UIStroke") or nil
    local gradients = {}
    if equipImage then
        for _, child in ipairs(equipImage:GetChildren()) do
            if child:IsA("UIGradient") then
                table.insert(gradients, child)
            end
        end
    end
    self._styleRefs = {
        iconColor = template.ItemTemplate.ItemIcon.ImageColor3,
        equipBg = equipImage and equipImage.BackgroundColor3 or nil,
        equipStrokeColor = equipStroke and equipStroke.Color or nil,
        textStrokeColor = textStroke and textStroke.Color or nil,
        gradients = gradients,
    }
end

function LevelWeaponSkinController:_applyEquipButtonStyle(card, owned)
    local equipButton = card:FindFirstChild("EquipButton")
    local equipImage = equipButton and equipButton:FindFirstChild("ImageLabel") or nil
    local textLabel = equipButton and equipButton:FindFirstChild("Text") or nil
    local textStroke = textLabel and textLabel:FindFirstChildWhichIsA("UIStroke") or nil
    if owned then
        if equipImage then
            for _, gradient in ipairs(equipImage:GetChildren()) do
                if gradient:IsA("UIGradient") then
                    gradient.Enabled = true
                end
            end
            equipImage.BackgroundColor3 = self._styleRefs.equipBg or equipImage.BackgroundColor3
            local equipStroke = equipImage:FindFirstChildWhichIsA("UIStroke")
            if equipStroke and self._styleRefs.equipStrokeColor then
                equipStroke.Color = self._styleRefs.equipStrokeColor
            end
        end
        if textStroke and self._styleRefs.textStrokeColor then
            textStroke.Color = self._styleRefs.textStrokeColor
        end
        return
    end
    if equipImage then
        for _, gradient in ipairs(equipImage:GetChildren()) do
            if gradient:IsA("UIGradient") then
                gradient.Enabled = false
            end
        end
        equipImage.BackgroundColor3 = LOCKED_BUTTON_BG
        local equipStroke = equipImage:FindFirstChildWhichIsA("UIStroke")
        if equipStroke then
            equipStroke.Color = LOCKED_BUTTON_STROKE
        end
    end
    if textStroke then
        textStroke.Color = LOCKED_TEXT_STROKE
    end
end

function LevelWeaponSkinController:_configureCardNode(card, entry)
    card.Name = "LevelWeapon_T" .. tostring(entry.tierIndex)
    card.LayoutOrder = entry.tierIndex
    card.Visible = true
    card:SetAttribute("CosmeticTierIndex", entry.tierIndex)
    card:SetAttribute("UnlockLevel", entry.unlockLevel)
    local nameLabel = card:FindFirstChild("Name")
    if nameLabel then
        nameLabel.Text = "???"
    end
    local icon = card:FindFirstChild("ItemTemplate") and card.ItemTemplate:FindFirstChild("ItemIcon") or nil
    if icon then
        icon.Image = entry.icon
    end
    local unlockLabel = card:FindFirstChild("UnlockLevelText")
    if unlockLabel then
        unlockLabel.Text = "Unlock at Lv. " .. tostring(entry.unlockLevel)
    end
end

function LevelWeaponSkinController:_ensureCards()
    if self._cardsReady then
        return
    end
    self._cardsByTierIndex = {}
    local bindSerial = self._bindSerial
    for index, entry in ipairs(self._catalog) do
        if entry then
            local card = self._scroll:FindFirstChild("LevelWeapon_T" .. tostring(index))
            if not card and self._template then
                card = self._template:Clone()
                card.Parent = self._scroll
            end
            if card then
                self:_configureCardNode(card, entry)
                local equipButton = card:FindFirstChild("EquipButton")
                if equipButton then
                    table.insert(self._connectionsByWindow, equipButton.Activated:Connect(function()
                        if bindSerial ~= self._bindSerial then
                            return
                        end
                        local highest = self._state and self._state.highestLevelReached or 1
                        if entry.unlockLevel <= highest then
                            self:_requestEquip(entry.tierIndex)
                        end
                    end))
                end
            end
            self._cardsByTierIndex[index] = card or nil
        end
    end
    self._cardsReady = true
end

function LevelWeaponSkinController:_renderCard(card, entry, highestLevel, selectedTierIndex)
    local owned = entry.unlockLevel <= highestLevel
    local selected = selectedTierIndex == entry.tierIndex
    card:SetAttribute("PreviewState", selected and "Selected" or (owned and "Owned" or "Locked"))
    local nameLabel = card:FindFirstChild("Name")
    local displayName = owned and entry.name or "???"
    if nameLabel and nameLabel.Text ~= displayName then
        nameLabel.Text = displayName
    end
    local icon = card:FindFirstChild("ItemTemplate") and card.ItemTemplate:FindFirstChild("ItemIcon") or nil
    if icon then
        icon.ImageColor3 = owned and (self._styleRefs and self._styleRefs.iconColor or icon.ImageColor3) or LOCKED_ICON_COLOR
    end
    local equipButton = card:FindFirstChild("EquipButton")
    local textLabel = equipButton and equipButton:FindFirstChild("Text") or nil
    if textLabel then
        textLabel.Text = owned and "Equip" or "Locked"
    end
    equipButton.Visible = not selected
    setGuiButtonInteractable(equipButton, owned and not selected)
    local badge = card:FindFirstChild("EquippedBadge")
    if badge then
        badge.Visible = selected
    end
    local highlight = card:FindFirstChild("SelectionHighlight")
    if highlight then
        highlight.Visible = selected
    end
    local stroke = card:FindFirstChild("SelectionStroke")
    if stroke then
        stroke.Enabled = selected
    end
    self:_applyEquipButtonStyle(card, owned)
end

function LevelWeaponSkinController:_render()
    if not (self._isWindowOpen and self._window and self._window.Parent and self._window.Visible
        and self._content and self._catalog) then
        return
    end
    self:_ensureCards()
    -- Readiness can change without changing the normalized appearance snapshot.
    self:_renderLevelLookButton()
    local state = self._state or {
        selectedTierIndex = nil,
        autoUpgrade = true,
        highestLevelReached = 1,
        maxUnlockedTierIndex = 1,
    }
    local previous = self._renderedState
    if statesMatch(previous, state) then
        return
    end
    local highest = state.highestLevelReached
    local dirtyCards = {}
    if not previous or previous.highestLevelReached ~= highest then
        local unlockedCount = 0
        for index, entry in ipairs(self._catalog) do
            if entry then
                local owned = entry.unlockLevel <= highest
                if owned then
                    unlockedCount += 1
                end
                if not previous or owned ~= (entry.unlockLevel <= previous.highestLevelReached) then
                    dirtyCards[index] = true
                end
            end
        end
        self._content:SetAttribute("PreviewHighestLevel", highest)
        local progress = self._content:FindFirstChild("ProgressSummary")
        if progress then
            progress.Text = string.format("Best Lv. %d · %d/%d unlocked", highest, unlockedCount, #self._catalog)
        end
    end

    if not previous or previous.selectedTierIndex ~= state.selectedTierIndex then
        self._content:SetAttribute("PreviewSelectedTierIndex", state.selectedTierIndex or 0)
        if previous and previous.selectedTierIndex then
            dirtyCards[previous.selectedTierIndex] = true
        end
        if state.selectedTierIndex then
            dirtyCards[state.selectedTierIndex] = true
        end
    end
    if not previous or previous.selectedTierIndex ~= state.selectedTierIndex
        or previous.equippedSkinId ~= state.equippedSkinId then
        local selectedSummary = self._content:FindFirstChild("SelectedSkinSummary")
        if selectedSummary then
            local selectedEntry = state.selectedTierIndex and self._catalog[state.selectedTierIndex] or nil
            selectedSummary.Text = state.equippedSkinId and "Chosen: Special Skin"
                or (selectedEntry and ("Chosen: " .. selectedEntry.name) or "Chosen: Level Look")
        end
    end
    if not previous or previous.autoUpgrade ~= state.autoUpgrade then
        local autoRow = self._content:FindFirstChild("AutoUpgradeRow")
        local checkbox = autoRow and autoRow:FindFirstChild("CheckboxButton") or nil
        local checkmark = checkbox and checkbox:FindFirstChild("Checkmark") or nil
        if checkmark then
            checkmark.Visible = state.autoUpgrade == true
        end
    end

    for index in pairs(dirtyCards) do
        local card = self._cardsByTierIndex[index]
        local entry = self._catalog[index]
        if card and entry and card.Parent then
            self:_renderCard(card, entry, highest, state.selectedTierIndex)
        end
    end
    -- _applyState replaces normalized snapshots; never mutate this after rendering.
    self._renderedState = state
end

function LevelWeaponSkinController:_bindWindow(window)
    if not (window and window:IsA("GuiObject")) then
        return
    end
    self._bindSerial += 1
    local bindSerial = self._bindSerial
    disconnectAll(self._connectionsByWindow)
    self._window = nil
    self._content = nil
    self._scroll = nil
    self._template = nil
    self._styleRefs = nil
    self._cardsByTierIndex = {}
    self._cardsReady = false
    self._renderedState = nil

    local content = window:FindFirstChild("Content")
    local scroll = content and content:FindFirstChild("ScrollingFrame") or nil
    local template = scroll and scroll:FindFirstChild("LevelWeaponTemplate") or nil
    if not (content and scroll and template) then
        warn("[LevelWeaponSkinController] 静态窗口缺少 Content/ScrollingFrame/LevelWeaponTemplate 节点")
        return
    end

    self._window = window
    self._content = content
    self._scroll = scroll
    self._template = template
    self:_captureTemplateStyle(template)
    window.Visible = false

    table.insert(self._connectionsByWindow, window:GetPropertyChangedSignal("Visible"):Connect(function()
        if bindSerial == self._bindSerial and window.Visible then
            self:_render()
        end
    end))

    local closeButton = window:FindFirstChild("Title") and window.Title:FindFirstChild("CloseButton") or nil
    setGuiButtonInteractable(closeButton, true)
    if closeButton then
        table.insert(self._connectionsByWindow, closeButton.Activated:Connect(function()
            self:_setOpen(false)
        end))
    end

    local useLevelLookButton = content:FindFirstChild("UseLevelLookButton")
    self:_renderLevelLookButton()
    if useLevelLookButton then
        table.insert(self._connectionsByWindow, useLevelLookButton.Activated:Connect(function()
            self:_onUseLevelLookActivated()
        end))
    end

    local autoRow = content:FindFirstChild("AutoUpgradeRow")
    local checkbox = autoRow and autoRow:FindFirstChild("CheckboxButton") or nil
    setGuiButtonInteractable(checkbox, true)
    if checkbox then
        table.insert(self._connectionsByWindow, checkbox.Activated:Connect(function()
            local nextEnabled = not (self._state and self._state.autoUpgrade ~= false)
            self:_requestEquip("AutoUpgrade", nextEnabled)
        end))
    end

    -- An open request (Armory click / GM attribute) may have arrived before the window
    -- existed; honor it now that the window is bound.
    if self._isWindowOpen then
        ModalUiController:PlayPanelOpen(WINDOW_OWNER_ID, window)
        self:_render()
    end
end

function LevelWeaponSkinController:_observeGui()
    local localPlayer = self._localPlayer
    if not localPlayer then
        return
    end
    task.spawn(function()
        local playerGui = localPlayer:WaitForChild("PlayerGui", 15)
        if not playerGui then
            return
        end
        local function tryBind()
            local main = playerGui:FindFirstChild("Main")
            local window = main and main:FindFirstChild("LevelWeaponSkins") or nil
            if window and window ~= self._window then
                self:_bindWindow(window)
            end
            local left = main and main:FindFirstChild("Left") or nil
            local armory = left and left:FindFirstChild("Armory") or nil
            if armory then
                self:_bindArmory(armory)
            end
        end
        tryBind()
        table.insert(self._connections, playerGui.DescendantAdded:Connect(function(node)
            if node.Name == "LevelWeaponSkins" or node.Name == "Armory" then
                task.defer(tryBind)
            end
        end))
    end)
end

function LevelWeaponSkinController:_bindGmAttribute()
    local localPlayer = self._localPlayer
    if not localPlayer then
        return
    end
    local attributeName = RemoteNames.StudioAttributes.LevelSkinUiPreview
    table.insert(self._connections, localPlayer:GetAttributeChangedSignal(attributeName):Connect(function()
        if not RunService:IsStudio() then
            return
        end
        self:_setOpen(localPlayer:GetAttribute(attributeName) == true)
    end))
    if RunService:IsStudio() and localPlayer:GetAttribute(attributeName) == true then
        self:_setOpen(true)
    end
end

function LevelWeaponSkinController:_bindRemotes()
    task.spawn(function()
        local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
        local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
        if not systemEventsFolder then
            return
        end
        local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)
        if playerStateSyncEvent then
            table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
                self:_applyPlayerState(payload)
            end))
        end
        local stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.LevelWeaponSkinStateSync, 10)
        self._requestStateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestLevelWeaponSkinStateSync, 10)
        self._requestEquipEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestLevelWeaponSkinEquip, 10)
        local feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.LevelWeaponSkinFeedback, 10)
        if stateSyncEvent then
            table.insert(self._connections, stateSyncEvent.OnClientEvent:Connect(function(payload)
                self:_applyState(payload)
            end))
        end
        if feedbackEvent then
            table.insert(self._connections, feedbackEvent.OnClientEvent:Connect(function(payload)
                if type(payload) == "table" and type(payload.state) == "table" then
                    self:_applyState(payload.state)
                end
            end))
        end
        self:_requestState()
        self:_render()
    end)
end

function LevelWeaponSkinController:Init(dependencies)
    dependencies = dependencies or {}
    self._localPlayer = dependencies.LocalPlayer or Players.LocalPlayer
    self._catalog = buildCatalog()

    self:_bindRemotes()
    self:_observeGui()
    self:_bindGmAttribute()
end

return LevelWeaponSkinController
