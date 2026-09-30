-- Script: EnsureFlashAttributes | Type: Studio Edit deployment tool
-- Studio path: executed by project MCP; creates formal StarterGui templates only.
assert(game.PlaceId == 73988417166286, "Wrong project")
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit required")
local main = game:GetService("StarterGui"):FindFirstChild("Main")
assert(main and main:IsA("ScreenGui"), "Missing Main ScreenGui")
local grid = main.AttributeUpgrade.Window.Content.StatsGrid
local list = main.AttributeUpgradeOut.Window.StatsList
assert(grid:IsA("Frame") and list:IsA("ScrollingFrame"), "Unexpected attribute UI")
local definitions = {
    { key = "FlashCooldown", source = "BladeRecovery", capSource = "BladeRecoveryCap", title = "Flash Cooldown", effect = "8.0s", icon = "rbxassetid://134897616151926", order = 9 },
    { key = "FlashDistance", source = "MoveSpeed", capSource = "MoveSpeedCap", title = "Flash Distance", effect = "24 studs", icon = main.Flash.Info.Icon02.Image, order = 10 },
}
-- Preflight all targets before changing any template.
for _, definition in ipairs(definitions) do
    for _, info in ipairs({{grid, definition.source, definition.key}, {list, definition.capSource, definition.key .. "Cap"}}) do
        assert(info[1][info[2]]:IsA("Frame"), "Unexpected reference row")
        local existing = info[1]:FindFirstChild(info[3])
        assert(not existing or existing:IsA("Frame"), "Unexpected target row type")
    end
end
local changed = {}
for _, definition in ipairs(definitions) do
    local card = grid:FindFirstChild(definition.key)
    if not card then
        card = grid[definition.source]:Clone()
        card.Name = definition.key
        card.Parent = grid
    end
    card.Visible = true
    card.LayoutOrder = definition.order
    if card:GetAttribute("FlashAttributeVersion") ~= 2 then
        card.Name = definition.key
        card:FindFirstChild("Name").Text = definition.title
        card.Level.Text = "Lv.0/8"
        card.Effect.Text = definition.effect
        card.Effect.Visible = true
        card.Effect.AnchorPoint = Vector2.new(0.5, 0.5)
        card.Effect.Position = UDim2.fromScale(0.70, 0.50)
        card.Effect.Size = UDim2.fromScale(0.22, 0.30)
        card.Icon.Image = definition.icon
        card.AddButton.Active = true
        card.AddButton.Selectable = true
        card.AddButton:FindFirstChild("Label").Text = "+"
        card:SetAttribute("FlashAttributeVersion", 2)
    end
    local rowName = definition.key .. "Cap"
    local row = list:FindFirstChild(rowName)
    if not row then
        row = list[definition.capSource]:Clone()
        row.Name = rowName
        row.Parent = list
    end
    row.Visible = true
    row.LayoutOrder = definition.order
    if row:GetAttribute("FlashAttributeVersion") ~= 2 then
        row:FindFirstChild("Name").Text = definition.title .. " Cap"
        row.CurrentCap.Text = "8"
        row.NextCap.Text = "9"
        row.Icon.Image = definition.icon
        row.GemUpgradeButton.Price.Text = "1K"
        row.RobuxUpgradeButton.Price.Text = "..."
        row.GemUpgradeButton.Active = true
        row.RobuxUpgradeButton.Active = true
        row:SetAttribute("FlashAttributeVersion", 2)
    end
    table.insert(changed, {key=definition.key,card=card:GetFullName(),capRow=row:GetFullName()})
end
-- The original two-column layout now contains four visible rows; keep all four
-- within StatsGrid at narrow/mobile heights without changing panel or art style.
local layout = grid:FindFirstChildOfClass("UIGridLayout")
assert(layout, "Missing attribute grid layout")
layout.CellSize = UDim2.new(layout.CellSize.X.Scale, layout.CellSize.X.Offset, 0.25, -4)
grid.Position = UDim2.new(grid.Position.X.Scale, grid.Position.X.Offset, 0.535, grid.Position.Y.Offset)
for _, name in ipairs({"WeaponDamage", "MoveSpeed"}) do grid[name].Visible = false end
for _, name in ipairs({"DamageCap", "MoveSpeedCap"}) do list[name].Visible = false end
main:SetAttribute("FlashAttributeVersion", 2)
return game:GetService("HttpService"):JSONEncode({success=true,templates=changed})
