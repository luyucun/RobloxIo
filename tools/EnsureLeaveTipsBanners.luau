-- Formal ESC banner template, copied from 加1陀螺's actual OfflineBannerGui properties.
-- Run through studio-mcp.ps1 after Assert-StudioProject; never changes PlayerGui.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Studio Edit required")
assert(game.PlaceId == 73988417166286, "Wrong Place")
local StarterGui = game:GetService("StarterGui")
local function unique(parent, name, class)
    local found
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == name then
            assert(not found, "Duplicate node: " .. name)
            assert(child.ClassName == class, "Unexpected class: " .. child:GetFullName())
            found = child
        end
    end
    return found
end
local main = unique(StarterGui, "Main", "ScreenGui")
local legacy = main and unique(main, "LeaveTips", "Frame")
local oldText = legacy and unique(legacy, "Text", "TextLabel")
assert(oldText and oldText.Text ~= "", "Existing LeaveTips text missing")
local textValue = oldText.Text
local gui = unique(StarterGui, "LeaveTipsGui", "ScreenGui")
local created = gui == nil
local installedVersion = gui and tonumber(gui:GetAttribute("StyleVersion")) or 0
local banners = {}
if gui then
    assert(installedVersion == 1 or installedVersion == 2, "Existing unmarked LeaveTipsGui; inspect before changing")
    for _, name in ipairs({ "TopBanner", "BottomBanner" }) do
        local banner = unique(gui, name, "Frame")
        if banner then
            local label = unique(banner, "Text", "TextLabel")
            if label then unique(label, "UIGradient", "UIGradient") end
        end
        banners[name] = banner
    end
end
if created then
    gui = Instance.new("ScreenGui")
    gui.Name = "LeaveTipsGui"
    gui.DisplayOrder = 999
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.Enabled = false
    gui:SetAttribute("StyleVersion", 2)
    gui:SetAttribute("ReferenceProject", "加1陀螺/OfflineBannerGui")
end
local function rainbow()
    local keys = {}
    for index = 0, 5 do
        table.insert(keys, ColorSequenceKeypoint.new(index / 6, Color3.fromHSV(index / 6, 0.75, 1)))
    end
    table.insert(keys, ColorSequenceKeypoint.new(1, Color3.fromHSV(0, 0.75, 1)))
    return ColorSequence.new(keys)
end
for index, name in ipairs({ "TopBanner", "BottomBanner" }) do
    local banner = banners[name]
    if not banner then
        banner = Instance.new("Frame")
        banner.Name = name
        banner.AnchorPoint = Vector2.new(0, index == 1 and 0 or 1)
        banner.Position = UDim2.fromScale(0, index == 1 and -0.11 or 1.11)
        banner.Size = UDim2.fromScale(1, 0.1)
        banner.BackgroundColor3 = Color3.new(0, 0, 0)
        banner.BackgroundTransparency = 0
        banner.BorderSizePixel = 0
        banner.Visible = true
        banner.Active = false
        banner.Selectable = false
        banner.ZIndex = 1
        banner.Parent = gui
    end
    local label = banner:FindFirstChild("Text")
    if not label then
        label = Instance.new("TextLabel")
        label.Name = "Text"
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = UDim2.fromScale(0.5, 0.5)
        label.Size = UDim2.fromScale(1, 0.7)
        label.BackgroundTransparency = 1
        label.BorderSizePixel = 0
        label.Text = textValue
        label.TextColor3 = Color3.new(1, 1, 1)
        label.Font = Enum.Font.FredokaOne
        label.TextWrapped = false
        label.TextScaled = true
        label.TextStrokeTransparency = 1
        label.Active = false
        label.Selectable = false
        label.ZIndex = 1
        label.Parent = banner
    end
    -- v1 wrote TextWrapped=false after TextScaled=true, which disables scaling in Studio.
    if installedVersion == 1 then label.TextScaled = true end
    if not label:FindFirstChild("UIGradient") then
        local gradient = Instance.new("UIGradient")
        gradient.Name = "UIGradient"
        gradient.Color = rainbow()
        gradient.Rotation = 0
        gradient.Offset = Vector2.zero
        gradient.Enabled = true
        gradient.Parent = label
    end
    banners[name] = banner
end
legacy.Visible = false
gui:SetAttribute("StyleVersion", 2)
if created then gui.Parent = StarterGui end
local described = {}
for _, name in ipairs({ "TopBanner", "BottomBanner" }) do
    local banner = banners[name]
    table.insert(described, { name=name,anchor=tostring(banner.AnchorPoint),position=tostring(banner.Position),
        size=tostring(banner.Size),text=banner.Text.Text,font=banner.Text.Font.Name,
        labelSize=tostring(banner.Text.Size),gradientStops=#banner.Text.UIGradient.Color.Keypoints,
        active=banner.Active })
end
return game:GetService("HttpService"):JSONEncode({created=created,path=gui:GetFullName(),
    enabled=gui.Enabled,order=gui.DisplayOrder,ignoreInset=gui.IgnoreGuiInset,reset=gui.ResetOnSpawn,
    zBehavior=gui.ZIndexBehavior.Name,legacyVisible=legacy.Visible,banners=described})
