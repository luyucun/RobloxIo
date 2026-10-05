-- V6.29: emphasize direct free respawn and show the retained level on the Lobby button.
-- Edit-only migration of the formal template; runtime controllers only bind existing nodes.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong place")
local main = game:GetService("StarterGui"):WaitForChild("Main")
local panel = main:WaitForChild("Defeated")
assert(panel:IsA("Frame"))
if (tonumber(panel:GetAttribute("DefeatedActionsUiVersion")) or 0) >= 1 then
    return "Defeated action layout already installed; preserving manual edits"
end

local function required(parent, name, className)
    local node = parent:FindFirstChild(name)
    assert(node and node:IsA(className), parent:GetFullName() .. "/" .. name .. " must be " .. className)
    return node
end
local free = required(panel, "FreeRespawn", "TextButton")
local lobby = required(panel, "Lobby", "TextButton")
local freeName = required(free, "Name", "TextLabel")
local freeLevel = required(free, "Level", "TextLabel")
local lobbyName = required(lobby, "Name", "TextLabel")
local freeBackground = required(free, "ImageLabel", "ImageLabel")
local lobbyBackground = required(lobby, "ImageLabel", "ImageLabel")
local freeIcon = required(free, "Icon", "ImageLabel")
local lobbyIcon = required(lobby, "Icon", "ImageLabel")
local lobbyLevel = lobby:FindFirstChild("Level")
assert(not lobbyLevel or lobbyLevel:IsA("TextLabel"), "Lobby/Level must be a TextLabel")

if not lobbyLevel then
    lobbyLevel = freeLevel:Clone()
    lobbyLevel.Name = "Level"
    lobbyLevel.Parent = lobby
end

free.AnchorPoint = Vector2.new(0.5, 0.5)
free.Position = UDim2.fromScale(0.32, 0.84)
free.Size = UDim2.fromScale(0.54, 0.18)
lobby.AnchorPoint = Vector2.new(0.5, 0.5)
lobby.Position = UDim2.fromScale(0.80, 0.84)
lobby.Size = UDim2.fromScale(0.30, 0.15)

-- Match each colored background to its actual clickable button rectangle.
for _, background in ipairs({ freeBackground, lobbyBackground }) do
    background.AnchorPoint = Vector2.zero
    background.Position = UDim2.fromScale(0, 0)
    background.Size = UDim2.fromScale(1, 1)
end

local function label(node, text, y, height, background)
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Position = UDim2.fromScale(0.59, y)
    node.Size = UDim2.fromScale(0.74, height)
    node.Text = text
    node.TextWrapped = true
    node.TextScaled = true
    node.TextXAlignment = Enum.TextXAlignment.Center
    node.TextYAlignment = Enum.TextYAlignment.Center
    node.Visible = true
    node.Active = false
    node.ZIndex = math.max(node.ZIndex, background.ZIndex + 2)
end
label(freeName, "Free Respawn", 0.30, 0.44, freeBackground)
label(freeLevel, "With Lv.1", 0.75, 0.30, freeBackground)
label(lobbyName, "Free to Lobby", 0.30, 0.40, lobbyBackground)
label(lobbyLevel, "With Lv.1", 0.74, 0.30, lobbyBackground)
lobbyLevel.TextColor3 = lobbyName.TextColor3
lobbyLevel.TextStrokeColor3 = lobbyName.TextStrokeColor3
local lobbyTextStroke = lobbyName:FindFirstChildOfClass("UIStroke")
if lobbyTextStroke then
    for _, stroke in ipairs(lobbyLevel:GetChildren()) do
        if stroke:IsA("UIStroke") then stroke.Color = lobbyTextStroke.Color end
    end
end

freeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
freeIcon.Position = UDim2.fromScale(0.115, 0.5)
freeIcon.Size = UDim2.fromScale(0.70, 0.70)
freeIcon.ZIndex = math.max(freeIcon.ZIndex, freeBackground.ZIndex + 1)
lobbyIcon.AnchorPoint = Vector2.new(0.5, 0.5)
lobbyIcon.Position = UDim2.fromScale(0.12, 0.5)
lobbyIcon.Size = UDim2.fromScale(0.58, 0.58)
lobbyIcon.ZIndex = math.max(lobbyIcon.ZIndex, lobbyBackground.ZIndex + 1)
local dailyFree = free:FindFirstChild("DailyFree")
if dailyFree and dailyFree:IsA("GuiObject") then dailyFree.Visible = false end

panel:SetAttribute("DefeatedActionsUiVersion", 1)
return "Defeated action layout installed: larger Free Respawn, smaller Lobby with retained level"
