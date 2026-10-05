-- V6.8: author two formal labels in Studio EDIT context after Assert-StudioProject.
-- Idempotent: preserve later manual styling on existing labels. No live PlayerGui writes.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Edit mode only")
local wheelConfig = assert(loadstring(game.ReplicatedStorage.Shared.WheelConfig.Source))()
local skinReward
for _, reward in ipairs(wheelConfig.Rewards) do
    if reward.SkinId and (tonumber(reward.DuplicateDiamonds) or 0) > 0 then
        skinReward = reward
        break
    end
end
assert(skinReward, "No configured duplicate skin compensation")
local rewardName = tostring(skinReward.Label or "Skin")
local duplicateAmount = tostring(math.floor(skinReward.DuplicateDiamonds)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
local StarterGui = game:GetService("StarterGui")
local main = StarterGui:FindFirstChild("Main")
assert(main and main:IsA("ScreenGui") and main.Parent == StarterGui, "Expected StarterGui.Main ScreenGui")
local wheelBg = main:FindFirstChild("WheelBg")
local colorBg = wheelBg and wheelBg:FindFirstChild("WheelColorBg")
local skinGift = colorBg and colorBg:FindFirstChild("Gift3")
local wheelClaim = main:FindFirstChild("WheelClaim")
assert(wheelBg and wheelBg:IsA("Frame") and wheelBg.Parent == main, "Expected Main.WheelBg Frame")
assert(colorBg and colorBg:IsA("ImageLabel") and colorBg.Parent == wheelBg, "Expected WheelBg.WheelColorBg ImageLabel")
assert(skinGift and skinGift:IsA("ImageLabel") and skinGift.Parent == colorBg, "Expected WheelColorBg.Gift3 ImageLabel")
assert(wheelClaim and wheelClaim:IsA("Frame") and wheelClaim.Parent == main, "Expected Main.WheelClaim Frame")
local styleSource = skinGift:FindFirstChild("Probality")
assert(styleSource and styleSource:IsA("TextLabel"), "Expected the existing skin probability style")

local function ensureLabel(parent, name, position, size, maxTextSize)
    local label = parent:FindFirstChild(name)
    local created = label == nil
    if label then
        assert(label:IsA("TextLabel") and label.Parent == parent, "Unexpected " .. name .. " type or parent")
    else
        label = Instance.new("TextLabel")
        label.Name = name
        label.AnchorPoint = Vector2.new(0.5, 0.5)
        label.Position = position
        label.Size = size
        label.BackgroundTransparency = 1
        label.BorderSizePixel = 0
        label.FontFace = styleSource.FontFace
        label.TextColor3 = Color3.fromRGB(220, 248, 255)
        label.TextScaled = true
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.ZIndex = math.max(2, parent.ZIndex + 1)
        local existingStroke = styleSource:FindFirstChildWhichIsA("UIStroke")
        if existingStroke then
            existingStroke:Clone().Parent = label
        else
            label.TextStrokeColor3 = Color3.fromRGB(17, 22, 35)
            label.TextStrokeTransparency = 0.2
        end
        local constraint = Instance.new("UITextSizeConstraint")
        constraint.MinTextSize = 6
        constraint.MaxTextSize = maxTextSize
        constraint.Parent = label
        label.Parent = parent
    end
    return label, created
end

local duplicateNotice, createdDuplicate = ensureLabel(
    wheelBg, "DuplicateNotice", UDim2.fromScale(0.5, 0.91), UDim2.fromScale(0.5, 0.04), 20
)
duplicateNotice.Text = rewardName .. " duplicate: +" .. duplicateAmount .. " Diamonds"
duplicateNotice.Visible = true
local resultNotice, createdResult = ensureLabel(
    wheelClaim, "ResultNotice", UDim2.fromScale(0.5, 1.15), UDim2.fromScale(1.7, 0.34), 20
)
resultNotice.Text = rewardName .. " already owned\nConverted to " .. duplicateAmount .. " Diamonds"
resultNotice.Visible = false

return game:GetService("HttpService"):JSONEncode({
    createdDuplicate = createdDuplicate,
    duplicatePath = duplicateNotice:GetFullName(),
    duplicateText = duplicateNotice.Text,
    createdResult = createdResult,
    resultPath = resultNotice:GetFullName(),
    resultText = resultNotice.Text,
    resultVisible = resultNotice.Visible,
})
