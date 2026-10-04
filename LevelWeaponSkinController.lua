--[[
脚本名字: LevelWeaponSkinController
脚本文件: LevelWeaponSkinController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/LevelWeaponSkinController
说明: V6.27 独立等级武器外观窗口（Main.LevelWeaponSkins）。
绑定静态模板、按服务端 LevelWeaponSkinStateSync 渲染三态卡片；仅发送装备/复原/自动开关意图。
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

local LOCKED_ICON_COLOR = Color3.fromRGB(95, 95, 95)
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
LevelWeaponSkinController._styleRefs = nil
LevelWeaponSkinController._connections = {}
LevelWeaponSkinController._connectionsByWindow = {}
LevelWeaponSkinController._bindSerial = 0
LevelWeaponSkinController._isWindowOpen = false
LevelWeaponSkinController._requestStateEvent = nil
LevelWeaponSkinController._requestEquipEvent = nil
LevelWeaponSkinController._state = nil
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

function LevelWeaponSkinController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end
    self._state = {
        selectedTierIndex = tonumber(payload.selectedTierIndex) or nil,
        autoUpgrade = payload.autoUpgrade ~= false,
        highestLevelReached = math.max(1, math.floor(tonumber(payload.highestLevelReached) or 1)),
        maxUnlockedTierIndex = math.max(1, math.floor(tonumber(payload.maxUnlockedTierIndex) or 1)),
    }
    self:_render()
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
            self:_render()
            ModalUiController:PlayPanelOpen(WINDOW_OWNER_ID, self._window)
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
        nameLabel.Text = entry.name
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
    self._cardsByTierIndex = {}
    for index, entry in ipairs(self._catalog) do
        if entry then
            local card = self._scroll:FindFirstChild("LevelWeapon_T" .. tostring(index))
            if not card and self._template then
                card = self._template:Clone()
                self:_configureCardNode(card, entry)
                card.Parent = self._scroll
            end
            self._cardsByTierIndex[index] = card or nil
        end
    end
end

function LevelWeaponSkinController:_renderCard(card, entry, highestLevel, selectedTierIndex)
    local owned = entry.unlockLevel <= highestLevel
    local selected = selectedTierIndex == entry.tierIndex
    card:SetAttribute("PreviewState", selected and "Selected" or (owned and "Owned" or "Locked"))
    local nameLabel = card:FindFirstChild("Name")
    if nameLabel then
        nameLabel.Text = entry.name
    end
    local unlockLabel = card:FindFirstChild("UnlockLevelText")
    if unlockLabel then
        unlockLabel.Text = "Unlock at Lv. " .. tostring(entry.unlockLevel)
    end
    local icon = card:FindFirstChild("ItemTemplate") and card.ItemTemplate:FindFirstChild("ItemIcon") or nil
    if icon then
        icon.Image = entry.icon
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
    local stroke = card:FindFirstChild("SelectionStroke")
    if stroke then
        stroke.Enabled = selected
    end
    self:_applyEquipButtonStyle(card, owned)
end

function LevelWeaponSkinController:_render()
    if not (self._window and self._content and self._catalog) then
        return
    end
    local state = self._state or {
        selectedTierIndex = nil,
        autoUpgrade = true,
        highestLevelReached = 1,
    }
    local highest = state.highestLevelReached
    local unlockedCount = 0
    for _, entry in ipairs(self._catalog) do
        if entry and entry.unlockLevel <= highest then
            unlockedCount += 1
        end
    end

    self._content:SetAttribute("PreviewHighestLevel", highest)
    self._content:SetAttribute("PreviewSelectedTierIndex", state.selectedTierIndex or 0)

    local progress = self._content:FindFirstChild("ProgressSummary")
    if progress then
        progress.Text = string.format("Best Lv. %d · %d/%d unlocked", highest, unlockedCount, #self._catalog)
    end
    local selectedSummary = self._content:FindFirstChild("SelectedSkinSummary")
    if selectedSummary then
        local selectedEntry = state.selectedTierIndex and self._catalog[state.selectedTierIndex] or nil
        selectedSummary.Text = selectedEntry and ("Chosen: " .. selectedEntry.name) or "Chosen: Level Look"
    end
    local autoRow = self._content:FindFirstChild("AutoUpgradeRow")
    local checkbox = autoRow and autoRow:FindFirstChild("CheckboxButton") or nil
    local checkmark = checkbox and checkbox:FindFirstChild("Checkmark") or nil
    if checkmark then
        checkmark.Visible = state.autoUpgrade == true
    end

    for index, card in pairs(self._cardsByTierIndex) do
        local entry = self._catalog[index]
        if card and entry and card.Parent then
            self:_renderCard(card, entry, highest, state.selectedTierIndex)
        end
    end
end

function LevelWeaponSkinController:_bindWindow(window)
    if not (window and window:IsA("GuiObject")) then
        return
    end
    self._bindSerial += 1
    local bindSerial = self._bindSerial
    disconnectAll(self._connectionsByWindow)

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
    self:_ensureCards()

    local closeButton = window:FindFirstChild("Title") and window.Title:FindFirstChild("CloseButton") or nil
    setGuiButtonInteractable(closeButton, true)
    if closeButton then
        table.insert(self._connectionsByWindow, closeButton.Activated:Connect(function()
            self:_setOpen(false)
        end))
    end

    local useLevelLookButton = content:FindFirstChild("UseLevelLookButton")
    setGuiButtonInteractable(useLevelLookButton, true)
    if useLevelLookButton then
        table.insert(self._connectionsByWindow, useLevelLookButton.Activated:Connect(function()
            self:_requestEquip("UseLevelLook")
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

    for index, card in pairs(self._cardsByTierIndex) do
        local entry = self._catalog and self._catalog[index] or nil
        if card and entry then
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
    end

    window.Visible = false
    self:_render()
    -- An open request (Armory click / GM attribute) may have arrived before the window
    -- existed; honor it now that the window is bound.
    if self._isWindowOpen then
        self:_render()
        ModalUiController:PlayPanelOpen(WINDOW_OWNER_ID, window)
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
