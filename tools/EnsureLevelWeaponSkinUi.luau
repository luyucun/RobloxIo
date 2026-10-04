-- Static level-skin template. Run via studio-mcp.ps1 after Assert-StudioProject.
-- Reuses Main.Skin and Main.Option styles; no gameplay, requests or player data.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit required")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local function unique(parent, name, class, optional)
    local found
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == name then
            assert(not found, "Duplicate node: " .. child:GetFullName())
            assert(child.ClassName == class, "Unexpected class: " .. child:GetFullName())
            found = child
        end
    end
    assert(optional or found, "Missing node: " .. parent:GetFullName() .. "." .. name)
    return found
end
local main = unique(game.StarterGui, "Main", "ScreenGui")
local skinStyle = unique(main, "Skin", "Frame")
local tabs = unique(skinStyle, "Tabs", "Frame")
local tabStyle = unique(tabs, "SkinsTab", "Frame")
local equipinfo = unique(skinStyle, "Equipinfo", "Frame")
local scrollStyle = unique(equipinfo, "ScrollingFrame", "ScrollingFrame")
local headerStyle = unique(equipinfo, "WeaponSkinsHeader", "Frame")
local cardStyle = unique(scrollStyle, "EquipTemplate", "Frame")
local optionStyle = unique(unique(main, "Option", "Frame"), "Music", "Frame")
local left = unique(main, "Left", "Frame")
local entryStyle = unique(left, "Skin", "Frame")
local oldWindow = unique(main, "LevelWeaponSkins", "Frame", true)
local oldEntry = unique(left, "LevelWeaponSkinsButton", "Frame", true)
for _, node in ipairs({ oldWindow or false, oldEntry or false }) do
    if node then
        assert(node:GetAttribute("StaticPreview") == true and node:GetAttribute("StyleVersion") == 1,
            "Existing unmarked level-skin UI; inspect before changing")
    end
end
assert(cardStyle:FindFirstChild("Name") and cardStyle:FindFirstChild("Equiped") and cardStyle:FindFirstChild("EquipButton"), "Card style incomplete")
assert(optionStyle:FindFirstChild("Title") and optionStyle:FindFirstChild("CloseButton"), "Option style incomplete")
local configSource = game.ReplicatedStorage.Shared.WeaponTierConfig.Source
local configLoader, configError = loadstring(configSource, "LevelSkinCatalog")
assert(configLoader, configError)
local config = configLoader()
assert(#config.Order == 40, "Catalog changed: review design thresholds")
local previewHighest, previewSelected = 55, 6
local catalog = {}
for index, tier in ipairs(config.Order) do
    local entry = config.Tiers[tier]
    assert(entry and entry.TierIndex == index and entry.IconImage ~= "" and entry.DisplayName ~= "", "Invalid catalog")
    catalog[index] = { tier = tier, name = entry.DisplayName, icon = entry.IconImage, level = config.GetUnlockLevelForTierIndex(index) }
end
assert(catalog[previewSelected].level <= previewHighest and catalog[previewSelected + 1].level > previewHighest, "Preview no longer fits config")

local function disableButtons(root)
    for _, node in ipairs(root:GetDescendants()) do
        assert(not node:IsA("LuaSourceContainer"), "Unexpected script in cloned UI")
        if node:IsA("GuiButton") then
            node.Active = false
            node.Selectable = false
            node.Interactable = false
            node.AutoButtonColor = false
        end
    end
end
local function label(name, text, position, size, parent)
    local node = cardStyle:FindFirstChild("Name"):Clone()
    node.Name = name
    node.Text = text
    node.AnchorPoint = Vector2.zero
    node.Position = position
    node.Size = size
    node.TextXAlignment = Enum.TextXAlignment.Left
    node.TextYAlignment = Enum.TextYAlignment.Center
    node.TextWrapped = false
    node.TextScaled = true
    node.ZIndex = 12
    node.Parent = parent
    return node
end

-- Independent feature: clone shared styling, never put the new page in Skin/Tabs.
-- Build detached; only replace our marked nodes after a complete successful build.
local window = skinStyle:Clone()
window.Name = "LevelWeaponSkins"
window.Visible = false
window:SetAttribute("StaticPreview", true)
window:SetAttribute("StyleVersion", 1)
window:SetAttribute("Feature", "LevelWeaponSkins")
for _, name in ipairs({ "Equipinfo", "Tabs", "LeftDivider", "TrailsPage", "TitlesPage" }) do
    local node = window:FindFirstChild(name)
    if node then node:Destroy() end
end
window.Title.Title.Text = "Level Skins"
window.Title.Icon.Image = catalog[previewSelected].icon
local page = equipinfo:Clone()
page:ClearAllChildren()
page.Name = "Content"
page.Position = UDim2.fromScale(0.04, 0.15)
page.Size = UDim2.fromScale(0.92, 0.8)
page.Visible = true
page:SetAttribute("StaticPreview", true)
page:SetAttribute("StyleVersion", 1)
page:SetAttribute("PreviewHighestLevel", previewHighest)
page:SetAttribute("PreviewSelectedTierIndex", previewSelected)
local header = headerStyle:Clone()
header.Name = "LevelWeaponsHeader"
header.Position = UDim2.fromScale(0.5, 0)
header.Size = UDim2.fromScale(1, 0.11)
header.Title.Text = "Level Weapon Skins"
header.Title.Size = UDim2.fromScale(0.51, 0.62)
header.LeftLine.Size = UDim2.fromScale(0.22, header.LeftLine.Size.Y.Scale)
header.RightLine.Size = UDim2.fromScale(0.22, header.RightLine.Size.Y.Scale)
header.Parent = page
label("ProgressSummary", "Best Lv. 55 · 6/40 unlocked", UDim2.fromScale(0.025, 0.12), UDim2.fromScale(0.69, 0.055), page)
label("SelectedSkinSummary", "Chosen: " .. catalog[previewSelected].name, UDim2.fromScale(0.025, 0.185), UDim2.fromScale(0.69, 0.05), page)
local reset = cardStyle.EquipButton:Clone()
reset.Name = "UseLevelLookButton"
reset.AnchorPoint = Vector2.new(1, 0.5)
reset.Position = UDim2.fromScale(0.985, 0.18)
reset.Size = UDim2.fromScale(0.255, 0.08)
reset.Visible = true
reset.ZIndex = 12
reset:FindFirstChild("Text").Text = "Use Level Look"
reset:FindFirstChild("Text").Size = UDim2.fromScale(0.92, 0.8)
reset.Parent = page

local row = optionStyle:Clone()
row.Name = "AutoUpgradeRow"
row.AnchorPoint = Vector2.zero
row.Position = UDim2.fromScale(0.015, 0.255)
row.Size = UDim2.fromScale(0.97, 0.13)
row.ZIndex = 12
row.Title.Text = "Auto-upgrade on level up"
row.Title.AnchorPoint = Vector2.new(0, 0.5)
row.Title.Position = UDim2.fromScale(0.035, 0.5)
row.Title.Size = UDim2.fromScale(0.78, 0.65)
row.Title.TextXAlignment = Enum.TextXAlignment.Left
local checkbox = row.CloseButton
checkbox.Name = "CheckboxButton"
checkbox.AnchorPoint = Vector2.new(1, 0.5)
checkbox.Position = UDim2.fromScale(0.975, 0.5)
checkbox.Size = UDim2.fromScale(0.115, 0.8)
checkbox:SetAttribute("DefaultChecked", true)
local square = Instance.new("UIAspectRatioConstraint")
square.AspectRatio = 1
square.Parent = checkbox
checkbox.ON.Name = "Checkmark"
checkbox.Checkmark.Text = utf8.char(0x2713)
checkbox.Checkmark.Visible = true
checkbox.OFF:Destroy()
row.Parent = page
for _, node in ipairs(row:GetDescendants()) do
    if node:IsA("GuiObject") then node.ZIndex += 12 end
end
label("AutoUpgradeHint", "Turn off to keep this skin at every level.", UDim2.fromScale(0.035, 0.397), UDim2.fromScale(0.93, 0.046), page)

local scroll = scrollStyle:Clone()
for _, child in ipairs(scroll:GetChildren()) do
    if child:IsA("GuiObject") then child:Destroy() end
end
scroll.Name = "ScrollingFrame"
scroll.Position = UDim2.fromScale(0.5, 0.46)
scroll.Size = UDim2.fromScale(1, 0.48)
scroll.CanvasPosition = Vector2.zero
scroll.Parent = page
local template = cardStyle:Clone()
template.Name = "LevelWeaponTemplate"
for _, name in ipairs({ "RobuxBuyButton", "DiamondButton", "WheelButton", "Unequiped", "SevendaysButton" }) do
    local node = template:FindFirstChild(name)
    if node then node:Destroy() end
end
template.Visible = false
template.ItemTemplate.Position = UDim2.fromScale(0.5, 0.435)
template.ItemTemplate.Size = UDim2.fromScale(0.76, 0.59)
template.ItemTemplate.ItemIcon.ScaleType = Enum.ScaleType.Fit
local iconRatio = Instance.new("UIAspectRatioConstraint")
iconRatio.AspectRatio = 1
iconRatio.Parent = template.ItemTemplate.ItemIcon
template.Equiped.Name = "EquippedBadge"
template.EquippedBadge.Text = "Equipped"
local unlock = label("UnlockLevelText", "Unlock at Lv. 1", UDim2.fromScale(0.05, 0.76), UDim2.fromScale(0.9, 0.065), template)
unlock.TextXAlignment = Enum.TextXAlignment.Center
local selectedStroke = Instance.new("UIStroke")
selectedStroke.Name = "SelectionStroke"
selectedStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
selectedStroke.Color = tabStyle.SelectedBg.BackgroundColor3
selectedStroke.Thickness = 2
selectedStroke.Enabled = false
selectedStroke.Parent = template
template:SetAttribute("StaticPreview", true)
template.Parent = scroll
local unlockedCount = 0
for index, entry in ipairs(catalog) do
    local owned = entry.level <= previewHighest
    local selected = index == previewSelected
    if owned then unlockedCount += 1 end
    local card = template:Clone()
    card.Name = "LevelWeapon_T" .. index
    card.LayoutOrder = index
    card.Visible = true
    card:SetAttribute("CosmeticTierIndex", index)
    card:SetAttribute("UnlockLevel", entry.level)
    card:SetAttribute("PreviewState", selected and "Selected" or (owned and "Owned" or "Locked"))
    card:FindFirstChild("Name").Text = entry.name
    card.ItemTemplate.ItemIcon.Image = entry.icon
    card.ItemTemplate.ItemIcon.ImageColor3 = owned and cardStyle.ItemTemplate.ItemIcon.ImageColor3 or Color3.fromRGB(95, 95, 95)
    card.UnlockLevelText.Text = "Unlock at Lv. " .. entry.level
    card.EquipButton.Visible = not selected
    card.EquipButton:FindFirstChild("Text").Text = owned and "Equip" or "Locked"
    card.EquippedBadge.Visible = selected
    card.SelectionStroke.Enabled = selected
    if not owned then
        for _, gradient in ipairs(card.EquipButton.ImageLabel:GetChildren()) do
            if gradient:IsA("UIGradient") then gradient.Enabled = false end
        end
        card.EquipButton.ImageLabel.BackgroundColor3 = Color3.fromRGB(110, 110, 110)
        card.EquipButton.ImageLabel.UIStroke.Color = Color3.fromRGB(75, 75, 75)
        card.EquipButton:FindFirstChild("Text").UIStroke.Color = Color3.fromRGB(65, 65, 65)
    end
    card.Parent = scroll
end
label("CosmeticOnlyHint", "Appearance only. Weapon stats stay the same.", UDim2.fromScale(0.03, 0.961), UDim2.fromScale(0.94, 0.035), page)
page.Parent = window
disableButtons(window)
local entry = entryStyle:Clone()
entry.Name = "LevelWeaponSkinsButton"
entry.Visible = false
entry.LayoutOrder = 9
entry:SetAttribute("StaticPreview", true)
entry:SetAttribute("StyleVersion", 1)
entry:SetAttribute("Feature", "LevelWeaponSkins")
local entryLabel = entry:FindFirstChild("TextLabel", true)
assert(entryLabel and entryLabel:IsA("TextLabel"), "Existing HUD label missing")
entryLabel.Text = "Level Skins"
local entryIcon = entry:FindFirstChild("Icon", true)
if entryIcon and entryIcon:IsA("ImageLabel") then entryIcon.Image = catalog[previewSelected].icon end
local redPoint = entry:FindFirstChild("RedPoint", true)
if redPoint and redPoint:IsA("GuiObject") then redPoint.Visible = false end
disableButtons(entry)
if oldWindow then oldWindow:Destroy() end
if oldEntry then oldEntry:Destroy() end
window.Parent = main
entry.Parent = left
return game.HttpService:JSONEncode({window = window:GetFullName(), entry = entry:GetFullName(), page = page:GetFullName(), catalogCount = #catalog,
    unlocked = unlockedCount, selected = previewSelected, defaultChecked = checkbox:GetAttribute("DefaultChecked"),
    windowVisible = window.Visible, entryVisible = entry.Visible, mode = "Independent static template; runtime not wired"})
