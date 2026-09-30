-- Author the formal template in Studio EDIT context after Assert-StudioProject.
-- Migrate the legacy text/pixel style once; keep later manual style adjustments.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Edit mode only")
local starterGui = game:GetService("StarterGui")
local template = starterGui:FindFirstChild("LocalMonsterHealthBar")
local created = false
if not template then
    template = Instance.new("BillboardGui")
    template.Name = "LocalMonsterHealthBar"
    template.Enabled = false
    template.ResetOnSpawn = false
    template.Size = UDim2.fromScale(4, 0.24)
    template.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
    template.MaxDistance = 100
    template.AlwaysOnTop = false
    template.LightInfluence = 0
    template.Active = false

    local track = Instance.new("Frame")
    track.Name = "Track"
    track.Size = UDim2.fromScale(1, 1)
    track.BackgroundColor3 = Color3.fromRGB(25, 31, 35)
    track.BackgroundTransparency = 0.12
    track.BorderSizePixel = 0
    track.ClipsDescendants = true
    track.Parent = template
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.5, 0)
    corner.Parent = track
    local outline = Instance.new("UIStroke")
    outline.Color = Color3.fromRGB(8, 13, 17)
    outline.Thickness = 1
    outline.Transparency = 0.2
    outline.Parent = track

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale(1, 1)
    fill.BackgroundColor3 = Color3.fromRGB(77, 199, 105)
    fill.BorderSizePixel = 0
    fill.Parent = track
    local fillCorner = corner:Clone()
    fillCorner.Parent = fill

    template.Parent = starterGui
    created = true
end
assert(template:IsA("BillboardGui") and template.Parent == starterGui and not template.Enabled)
assert(template.Track:IsA("Frame") and template.Track.Fill:IsA("Frame"))
if (tonumber(template:GetAttribute("StyleVersion")) or 0) < 2 then
    local percentage = template:FindFirstChild("Percentage")
    if percentage then
        assert(percentage:IsA("TextLabel"), "Unexpected Percentage class; preserve the existing object")
        percentage:Destroy()
    end
    -- Scale components are studs on a BillboardGui: perspective handles distance.
    template.Size = UDim2.fromScale(4, 0.24)
    for _, frame in ipairs({ template.Track, template.Track.Fill }) do
        local corner = frame:FindFirstChildWhichIsA("UICorner")
        if corner then corner.CornerRadius = UDim.new(0.5, 0) end
    end
    template:SetAttribute("StyleVersion", 2)
end
assert(not template:FindFirstChildWhichIsA("TextLabel", true))
return game:GetService("HttpService"):JSONEncode({
    created=created, path=template:GetFullName(), class=template.ClassName,
    enabled=template.Enabled, size=tostring(template.Size), maxDistance=template.MaxDistance,
    styleVersion=template:GetAttribute("StyleVersion"), descendants=#template:GetDescendants(),
})
