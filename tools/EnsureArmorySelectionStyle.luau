-- Script: EnsureArmorySelectionStyle | Type: Studio Edit migration tool (V6.30)
-- Studio path: project MCP execute_luau after Assert-StudioProject.
-- Only updates Armory selection decorations; preserves cards, layout and user content.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit required")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local window = game.StarterGui.Main:FindFirstChild("LevelWeaponSkins")
assert(window and window:IsA("Frame"), "Armory window missing")
if (tonumber(window:GetAttribute("SelectionStyleVersion")) or 0) >= 1 then
    return "Armory selection style already installed; preserving manual edits"
end
local scroll = window.Content:FindFirstChild("ScrollingFrame")
assert(scroll and scroll:IsA("ScrollingFrame"), "Armory scroll missing")
local cards = {}
for _, card in ipairs(scroll:GetChildren()) do
    if card.Name == "LevelWeaponTemplate" or card.Name:match("^LevelWeapon_T%d+$") then
        assert(card:IsA("Frame"), "Invalid card class")
        assert(card:FindFirstChild("EquippedBadge") and card.EquippedBadge:IsA("TextLabel"), "Badge missing")
        assert(card:FindFirstChild("SelectionStroke") and card.SelectionStroke:IsA("UIStroke"), "Selection stroke missing")
        assert(not card:FindFirstChild("SelectionHighlight"), "Unreviewed existing selection highlight")
        table.insert(cards, card)
    end
end
assert(#cards == 41, "Expected template and 40 weapon cards")
local function corner(parent)
    local rounded = parent:FindFirstChildOfClass("UICorner")
    if not rounded then
        rounded = Instance.new("UICorner")
        rounded.Parent = parent
    end
    rounded.CornerRadius = UDim.new(0.055, 0)
end
for _, card in ipairs(cards) do
    corner(card)
    local stroke = card.SelectionStroke
    stroke.Color = Color3.fromRGB(255, 214, 83)
    stroke.Thickness = 2
    stroke.Transparency = 0.15

    local highlight = Instance.new("Frame")
    highlight.Name = "SelectionHighlight"
    highlight.Size = UDim2.fromScale(1, 1)
    highlight.BackgroundColor3 = Color3.new(1, 1, 1)
    highlight.BackgroundTransparency = 0.2
    highlight.BorderSizePixel = 0
    highlight.ZIndex = 0
    highlight.Active = false
    highlight.Selectable = false
    highlight.Visible = card.EquippedBadge.Visible
    corner(highlight)
    local gradient = Instance.new("UIGradient")
    gradient.Rotation = 90
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 243, 181)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(238, 184, 62)),
    })
    gradient.Parent = highlight
    highlight.Parent = card

    local badge = card.EquippedBadge
    badge.Text = utf8.char(0x2713) .. " Equipped"
    badge.AnchorPoint = Vector2.new(0.5, 1)
    badge.Position = UDim2.fromScale(0.5, 0.975)
    badge.Size = UDim2.fromScale(0.88, 0.135)
    badge.BackgroundColor3 = Color3.fromRGB(28, 170, 64)
    badge.BackgroundTransparency = 0
    badge.BorderSizePixel = 0
    badge.TextColor3 = Color3.new(1, 1, 1)
    badge.TextScaled = true
    badge.TextWrapped = true
    badge.ZIndex = 13
    badge.Active = false
    badge.Selectable = false
    corner(badge)
    badge:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(0.3, 0)
    local padding = badge:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0.04, 0)
    padding.PaddingRight = UDim.new(0.04, 0)
    padding.PaddingTop = UDim.new(0.1, 0)
    padding.PaddingBottom = UDim.new(0.1, 0)
    padding.Parent = badge
    local textStroke = badge:FindFirstChildOfClass("UIStroke")
    if textStroke then
        textStroke.Color = Color3.fromRGB(14, 91, 36)
        textStroke.Thickness = 1
    end
end
window:SetAttribute("SelectionStyleVersion", 1)
return "Applied warm rounded selected card and green check badge to 40 cards plus template"
