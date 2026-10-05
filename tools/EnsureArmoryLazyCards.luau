-- Script: EnsureArmoryLazyCards | Type: Studio Edit migration tool (V6.31)
-- Studio path: project MCP execute_luau after Assert-StudioProject.
-- Export the current Armory to a local .rbxm before running this one-time migration.
-- Keeps the authored window and template; the client creates and reuses catalog cards.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit required")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local window = game.StarterGui.Main:FindFirstChild("LevelWeaponSkins")
assert(window and window:IsA("Frame"), "Armory window missing")
local content = window:FindFirstChild("Content")
local scroll = content and content:FindFirstChild("ScrollingFrame")
assert(scroll and scroll:IsA("ScrollingFrame"), "Armory scroll missing")
local template = scroll:FindFirstChild("LevelWeaponTemplate")
assert(template and template:IsA("Frame"), "Armory template missing")
assert(template:FindFirstChild("EquipButton") and template.EquipButton:IsA("TextButton"))
assert(template:FindFirstChild("EquippedBadge") and template.EquippedBadge:IsA("TextLabel"))
assert(template:FindFirstChild("SelectionHighlight") and template.SelectionHighlight:IsA("Frame"))
assert(template:FindFirstChild("SelectionStroke") and template.SelectionStroke:IsA("UIStroke"))
local item = template:FindFirstChild("ItemTemplate")
local icon = item and item:FindFirstChild("ItemIcon")
assert(icon and icon:IsA("ImageLabel"), "Armory icon missing")
local cards, indices = {}, {}
for _, child in ipairs(scroll:GetChildren()) do
    local index = tonumber(child.Name:match("^LevelWeapon_T(%d+)$"))
    if index then
        assert(child:IsA("Frame") and index >= 1 and index <= 40 and not indices[index], "Unexpected catalog card")
        indices[index] = true
        table.insert(cards, child)
    end
end
if (tonumber(window:GetAttribute("LazyCardsVersion")) or 0) >= 1 then
    assert(#cards == 0, "Authored cards reintroduced into lazy template")
    return "Armory already contains only its reusable template; preserving manual edits"
end
assert(#cards == 40, "Expected 40 authored cards before migration")
assert(window:GetAttribute("SelectionStyleVersion") == 1, "Preserve the current selection style before migrating")
local removedInstances = 0
for _, card in ipairs(cards) do
    removedInstances += 1 + #card:GetDescendants()
    card:Destroy()
end
template.Visible = false
template.EquippedBadge.Visible = false
template.SelectionHighlight.Visible = false
template.SelectionStroke.Enabled = false
template:SetAttribute("PreviewState", nil)
icon.Image = ""
window:SetAttribute("LazyCardsVersion", 1)
return game.HttpService:JSONEncode({removedCards = #cards, removedInstances = removedInstances, template = template:GetFullName()})
