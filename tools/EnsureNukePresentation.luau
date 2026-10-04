-- V6.18: author the formal nuke presentation template in Studio Edit mode.
-- Run only after Assert-StudioProject. This tool never touches PlayerGui.
-- StyleVersion >= 1 keeps existing manual styling; missing nodes get v1 defaults.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong place")

local StarterGui = game:GetService("StarterGui")
local VERSION = 1
local TEMPLATE_NAME = "NukeCinematicEffects"
local definitions = {
    {
        name = "TopBar",
        anchorPoint = Vector2.new(0, 0),
        position = UDim2.fromScale(0, 0),
        size = UDim2.fromScale(1, 0.055),
        color = Color3.fromRGB(0, 0, 0),
        zIndex = 1,
    },
    {
        name = "BottomBar",
        anchorPoint = Vector2.new(0, 1),
        position = UDim2.fromScale(0, 1),
        size = UDim2.fromScale(1, 0.055),
        color = Color3.fromRGB(0, 0, 0),
        zIndex = 1,
    },
    {
        name = "ImpactFlash",
        anchorPoint = Vector2.new(0, 0),
        position = UDim2.fromScale(0, 0),
        size = UDim2.fromScale(1, 1),
        color = Color3.fromRGB(255, 245, 220),
        zIndex = 2,
    },
}

local function findUniqueChild(parent, name, className)
    local found = nil
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == name then
            assert(not found, "Duplicate node: " .. parent:GetFullName() .. "." .. name)
            assert(child:IsA(className), "Unexpected node type: " .. child:GetFullName() .. " must be " .. className)
            found = child
        end
    end
    return found
end

-- Validate the entire binding contract before creating or restyling any nodes.
local template = findUniqueChild(StarterGui, TEMPLATE_NAME, "ScreenGui")
local nodes = {}
if template then
    for _, definition in ipairs(definitions) do
        nodes[definition.name] = findUniqueChild(template, definition.name, "Frame")
    end
end

local createdTemplate = template == nil
local installedVersion = template and tonumber(template:GetAttribute("StyleVersion")) or 0
local migrateStyle = createdTemplate or (installedVersion or 0) < VERSION
if createdTemplate then
    template = Instance.new("ScreenGui")
    template.Name = TEMPLATE_NAME
end
if migrateStyle then
    template.DisplayOrder = 200
    template.IgnoreGuiInset = true
    template.ResetOnSpawn = false
    template.Enabled = true
    template.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
end

local createdNodes = {}
local describedNodes = {}
for _, definition in ipairs(definitions) do
    local node = nodes[definition.name]
    local created = node == nil
    if created then
        node = Instance.new("Frame")
        node.Name = definition.name
        table.insert(createdNodes, definition.name)
    end
    if migrateStyle or created then
        node.AnchorPoint = definition.anchorPoint
        node.Position = definition.position
        node.Size = definition.size
        node.BackgroundColor3 = definition.color
        node.BackgroundTransparency = 1
        node.BorderSizePixel = 0
        node.Visible = false
        node.Active = false
        node.Selectable = false
        node.ZIndex = definition.zIndex
    end
    if created then
        node.Parent = template
    end
    table.insert(describedNodes, {
        name = node.Name,
        class = node.ClassName,
        visible = node.Visible,
        active = node.Active,
        backgroundTransparency = node.BackgroundTransparency,
        backgroundColor = {
            math.round(node.BackgroundColor3.R * 255),
            math.round(node.BackgroundColor3.G * 255),
            math.round(node.BackgroundColor3.B * 255),
        },
        anchorPoint = tostring(node.AnchorPoint),
        position = tostring(node.Position),
        size = tostring(node.Size),
        zIndex = node.ZIndex,
    })
end
if migrateStyle then
    template:SetAttribute("StyleVersion", VERSION)
end
if createdTemplate then
    template.Parent = StarterGui
end

return game:GetService("HttpService"):JSONEncode({
    path = template:GetFullName(),
    class = template.ClassName,
    createdTemplate = createdTemplate,
    createdNodes = createdNodes,
    migratedStyle = migrateStyle,
    styleVersion = template:GetAttribute("StyleVersion"),
    displayOrder = template.DisplayOrder,
    ignoreGuiInset = template.IgnoreGuiInset,
    resetOnSpawn = template.ResetOnSpawn,
    enabled = template.Enabled,
    zIndexBehavior = template.ZIndexBehavior.Name,
    nodes = describedNodes,
})
