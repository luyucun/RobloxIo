-- V6.10. Run through this project's Studio bridge after Assert-StudioProject.
-- Formal StarterGui template; reruns preserve existing authored styling.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Edit mode only")
local main = game.StarterGui:FindFirstChild("Main")
assert(main and main:IsA("ScreenGui") and main.Parent == game.StarterGui, "Expected StarterGui.Main")
local shop = main:FindFirstChild("Shop")
local shopInfo = shop and shop:FindFirstChild("Shopinfo")
local scrolling = shopInfo and shopInfo:FindFirstChild("ScrollingFrame")
local skinFrame = scrolling and scrolling:FindFirstChild("Skin")
local nameSource = skinFrame and skinFrame:FindFirstChild("Name")
assert(nameSource and nameSource:IsA("TextLabel"), "Expected existing shop skin name style")
assert(nameSource:FindFirstChild("Secret2") and nameSource:FindFirstChild("UIStroke"), "Missing shop name gradients")
local shared = game.ReplicatedStorage:FindFirstChild("Shared")
local skins = require(shared.SkinConfig)
local config = require(shared.ShopConfig)
local skin = skins.GetSkin(config.FeaturedSkinId)
assert(skin and skin.Id == 10002 and skin.GamePassId == 1830742687, "Unexpected featured skin")

local function ensure(parent, name, className, configure)
    local node = parent:FindFirstChild(name)
    if node then
        assert(node.ClassName == className and node.Parent == parent, "Unexpected type/parent: " .. name)
        return node
    end
    node = Instance.new(className)
    node.Name = name
    configure(node)
    node.Parent = parent
    return node
end

local root = ensure(main, "PhantomReaperOffer", "Frame", function(node)
    node.AnchorPoint = Vector2.new(1, 0.5)
    -- Reference StarterPack center is (0.93, 0.33); anchor the equivalent area
    -- to the right edge so breathing remains inside narrower screens as well.
    node.Position = UDim2.fromScale(0.99, 0.33)
    node.Size = UDim2.fromScale(0.22, 0.22)
    node.BackgroundTransparency = 1
    node.BorderSizePixel = 0
    node.ClipsDescendants = false
    node.Visible = true
    node.ZIndex = 2
    node:SetAttribute("StyleVersion", 1)
    node:SetAttribute("SkinId", skin.Id)
end)
ensure(root, "UIAspectRatioConstraint", "UIAspectRatioConstraint", function(node)
    node.AspectRatio = 1
    node.AspectType = Enum.AspectType.FitWithinMaxSize
end)
ensure(root, "PulseScale", "UIScale", function(node) node.Scale = 1 end)
ensure(root, "Light", "ImageLabel", function(node)
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Position = UDim2.fromScale(0.5, 0.4)
    node.Size = UDim2.fromScale(0.9, 0.9)
    node.BackgroundTransparency = 1
    node.Image = "rbxassetid://74861566895904" -- Same light as the reference StarterPack widget.
    node.ImageColor3 = Color3.fromRGB(208, 191, 255)
    node.ImageTransparency = 0.5
    node.ScaleType = Enum.ScaleType.Fit
    node.ZIndex = 2
end)
ensure(root, "Icon", "ImageLabel", function(node)
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Position = UDim2.fromScale(0.5, 0.4)
    node.Size = UDim2.fromScale(0.8, 0.8)
    node.BackgroundTransparency = 1
    node.Image = skin.IconImage
    node.ScaleType = Enum.ScaleType.Fit
    node.ZIndex = 3
end)
local label = root:FindFirstChild("Name")
if label then
    assert(label:IsA("TextLabel") and label.Parent == root, "Unexpected offer Name")
else
    label = nameSource:Clone()
    assert(not label:FindFirstChildWhichIsA("LuaSourceContainer", true), "Unexpected source script")
    label.Name = "Name"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.Position = UDim2.fromScale(0.5, 0.77)
    label.Size = UDim2.fromScale(1, 0.3)
    label.BackgroundTransparency = 1
    label.Text = skin.Name
    label.TextColor3 = Color3.new(1, 1, 1)
    label.TextScaled = true
    label.TextWrapped = true
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.ZIndex = 4
    label.Visible = true
    label.Parent = root
end
ensure(root, "Price", "TextLabel", function(node)
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Position = UDim2.fromScale(0.5, 1.02)
    node.Size = UDim2.fromScale(0.83, 0.19)
    node.BackgroundTransparency = 1
    node.FontFace = nameSource.FontFace
    node.Text = utf8.char(0xE002) .. " ..."
    node.TextColor3 = Color3.fromRGB(122, 255, 78)
    node.TextStrokeColor3 = Color3.fromRGB(16, 25, 15)
    node.TextStrokeTransparency = 0
    node.TextWrapped = false
    node.TextScaled = true
    node.ZIndex = 4
end)
ensure(root, "BuyButton", "TextButton", function(node)
    node.Position = UDim2.fromScale(0, 0)
    node.Size = UDim2.fromScale(1, 1.13)
    node.BackgroundTransparency = 1
    node.Text = ""
    node.AutoButtonColor = false
    node.ZIndex = 5
end)
return game.HttpService:JSONEncode({ path = root:GetFullName(), skinId = skin.Id,
    gamePassId = skin.GamePassId, icon = root.Icon.Image, position = tostring(root.Position),
    size = tostring(root.Size), name = label.Text, price = root.Price.Text })
