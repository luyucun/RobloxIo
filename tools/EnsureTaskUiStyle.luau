-- V6.12: Refine the original task UI using existing Shop/Chest/Claim styles.
-- Run only through the project Studio health/identity gate. No runtime UI construction.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong place")
local main = game:GetService("StarterGui"):WaitForChild("Main")
local panel = main:WaitForChild("TaskBgNew")
assert(panel:IsA("Frame"))
local VERSION = 4
if panel:GetAttribute("TaskUiStyleVersion") == VERSION then
    return "Original-style task refinement already installed; preserving manual edits"
end
local row = panel.Content.TaskList.ScrollingFrame.Template
local scrollingFrame = row.Parent
local detail = panel.Content.TaskDetail
local shopHeading = main.Shop.Shopinfo.ScrollingFrame.StarterPack.Title
local claimReference = main.Idlecoin.Claim
local headerReference = main.ChestRewards.TitleBg.Title
assert(row:IsA("TextButton") and claimReference:IsA("ImageButton"))

local function ensure(parent, name, className)
    local node = parent:FindFirstChild(name)
    if node then assert(node:IsA(className)); return node end
    node = Instance.new(className)
    node.Name = name
    node.Parent = parent
    return node
end
local function styleText(node, maxSize, color, strokeColor, thickness)
    node.FontFace = shopHeading.FontFace
    node.TextColor3 = color
    node.TextStrokeTransparency = 1
    node.TextWrapped = true
    node.TextScaled = true
    node.BackgroundTransparency = 1
    node.BorderSizePixel = 0
    local stroke = node:FindFirstChildOfClass("UIStroke") or ensure(node, "TextOutline", "UIStroke")
    stroke.Enabled = true
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    stroke.Color = strokeColor
    stroke.Thickness = thickness
    stroke.Transparency = 0
    local limit = node:FindFirstChildOfClass("UITextSizeConstraint") or ensure(node, "TextSizeLimit", "UITextSizeConstraint")
    limit.MinTextSize = 8
    limit.MaxTextSize = maxSize
end
local white = Color3.new(1, 1, 1)
local dark = Color3.fromRGB(30, 30, 30)
local yellow = Color3.fromRGB(255, 221, 37)

-- Keep original window dimensions, transparency, blue banner, cards and rewards.
-- Only the title font is borrowed from the existing blue Chest Rewards header.
local title = panel.TitleBg.Title
styleText(title, 30, headerReference.TextColor3, headerReference.UIStroke.Color, headerReference.UIStroke.Thickness)
title.FontFace = headerReference.FontFace
-- Give "Weekly Tasks" room without changing the banner itself.
title.Size = UDim2.fromScale(0.63, 0.7)
for _, name in ipairs({"DailyTab", "WeeklyTab"}) do
    local tab = panel.Tabs[name]
    local text = tab.ButtonLabel
    styleText(text, 24, white, Color3.new(0, 0, 0), 2)
    text.Size = UDim2.fromScale(0.84, 0.8)
    tab.AutoButtonColor = false
    tab:SetAttribute("TaskIdleTabBackgroundColor3", Color3.fromRGB(100, 100, 100))
    local scale = tab:FindFirstChildOfClass("UIScale")
    if scale then scale.Scale = 1 end
end
styleText(panel.CountdownTime, 18, panel.CountdownTime.TextColor3, Color3.fromRGB(85, 0, 0), 1.5)

-- Preserve the original three-line blue task entry; stop large Daily tags competing with task names.
for _, name in ipairs({"StatusText", "ProgressText"}) do
    local extra = row:FindFirstChild(name)
    if extra then assert(extra:IsA("TextLabel")); extra:Destroy() end
end
row.PeriodTag.Position = UDim2.fromScale(0.055, 0.055)
row.PeriodTag.Size = UDim2.fromScale(0.75, 0.23)
row.TaskTitle.Position = UDim2.fromScale(0.055, 0.32)
row.TaskTitle.Size = UDim2.fromScale(0.89, 0.3)
row.TaskSubtitle.Position = UDim2.fromScale(0.055, 0.64)
row.TaskSubtitle.Size = UDim2.fromScale(0.89, 0.32)
-- Preserve desktop row proportions; avoid clipping wrapped descriptions on narrow screens.
local rowSizeLimit = ensure(row, "TaskRowSizeLimit", "UISizeConstraint")
rowSizeLimit.MinSize = Vector2.new(0, 64)
styleText(row.PeriodTag, 14, white, dark, 1.25)
styleText(row.TaskTitle, 19, Color3.fromRGB(170, 255, 255), dark, 1.5)
styleText(row.TaskSubtitle, 13, yellow, Color3.fromRGB(102, 51, 0), 1)
row.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
row.AutoButtonColor = false
row.Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
row.Stroke.Thickness = 2
row.Stroke.Color = Color3.fromRGB(85, 255, 255)
row.Stroke.Enabled = true
row.Visible = false
scrollingFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollingFrame.CanvasSize = UDim2.new()
scrollingFrame.ScrollBarThickness = 3

styleText(detail.TaskTitle, 27, white, dark, 2)
styleText(detail.ProgressBg.Num, 19, white, dark, 1.5)
styleText(detail.RewardTitle, 20, yellow, Color3.fromRGB(170, 0, 0), 1.5)
detail.RewardTitle.Text = "Rewards"
-- Add only a slim cyan indicator below the original description band.
local track = ensure(detail, "ProgressTrack", "Frame")
track.Position = UDim2.fromScale(0.02, 0.32)
track.Size = UDim2.fromScale(0.94, 0.016)
track.AnchorPoint = Vector2.zero
track.BackgroundColor3 = detail.ProgressBg.BackgroundColor3
track.BackgroundTransparency = 0.1
track.BorderSizePixel = 0
track.ZIndex = 33
ensure(track, "Corner", "UICorner").CornerRadius = UDim.new(0.5, 0)
local fill = ensure(track, "Fill", "Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.Position = UDim2.new()
fill.BackgroundColor3 = detail.ProgressBg.Progress.BackgroundColor3
fill.BackgroundTransparency = 0
fill.BorderSizePixel = 0
fill.ZIndex = 34
ensure(fill, "Corner", "UICorner").CornerRadius = UDim.new(0.5, 0)
local status = ensure(detail, "StatusText", "TextLabel")
status.Position = UDim2.fromScale(0.57, 0.4)
status.Size = UDim2.fromScale(0.39, 0.08)
status.AnchorPoint = Vector2.zero
status.ZIndex = 34
status.TextXAlignment = Enum.TextXAlignment.Right
status.Text = ""
styleText(status, 14, white, dark, 1)

local claim = detail.ClaimButton
claim.BackgroundColor3 = claimReference.BackgroundColor3
claim.ImageColor3 = claimReference.ImageColor3
claim.AutoButtonColor = false
claim.ZIndex = 34
claim.Size = UDim2.fromScale(0.46, 0.13)
claim.ButtonYellow.Color = claimReference.ButtonYellow.Color
claim.ButtonYellow.Rotation = claimReference.ButtonYellow.Rotation
local referenceText = claimReference.Text
styleText(claim.Text, 24, referenceText.TextColor3, referenceText.UIStroke.Color, referenceText.UIStroke.Thickness)
claim.Text.FontFace = referenceText.FontFace
claim.Text.TextStrokeColor3 = referenceText.TextStrokeColor3
claim.Text.TextStrokeTransparency = referenceText.TextStrokeTransparency
claim.Text.Size = UDim2.fromScale(0.84, 0.8)
claim.Text.ZIndex = 35
for _, o in ipairs(claim:GetDescendants()) do
    o:SetAttribute("TaskBaseTextColor3", nil)
    o:SetAttribute("TaskBaseImageColor3", nil)
    o:SetAttribute("TaskBaseBackgroundColor3", nil)
end
claim:SetAttribute("TaskBaseImageColor3", nil)
styleText(detail.Complete, 21, Color3.fromRGB(0, 255, 0), Color3.fromRGB(0, 85, 0), 2)
detail.Complete.Text = "Claimed"
for _, reward in ipairs(detail.RewardList:GetChildren()) do
    if reward.Name == "RewardTemplate" and reward:IsA("Frame") then
        styleText(reward.RewardNum, 18, white, dark, 1.5)
        reward.Visible = false
    end
end
panel:SetAttribute("TaskUiStyleVersion", VERSION)
return "Original task style refined using Shop, ChestRewards and Idlecoin.Claim references"
