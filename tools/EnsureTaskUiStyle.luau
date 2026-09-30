-- V6.12 / V6.16 task UI template migrations for StarterGui.Main.TaskBgNew.
-- v4 (V6.12): refine the original task UI using existing Shop/Chest/Claim styles.
-- v5 (V6.16): opaque Shop-style content cards, row progress, tab badges, status chip and effect nodes.
-- Run only through the project Studio health/identity gate. No runtime UI construction.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong place")
local main = game:GetService("StarterGui"):WaitForChild("Main")
local panel = main:WaitForChild("TaskBgNew")
assert(panel:IsA("Frame"))
local VERSION = 5
local installedVersion = tonumber(panel:GetAttribute("TaskUiStyleVersion")) or 0
if installedVersion >= VERSION then
    return "Task UI style v" .. tostring(installedVersion) .. " already installed; preserving manual edits"
end

-- V6.16 style migration (v4 -> v5). Only restyles existing nodes and adds optional effect nodes.
local function applyTaskUiV5(panel)
    local font = panel.TitleBg.Title.FontFace
    local white = Color3.new(1, 1, 1)
    local navyStroke = Color3.fromRGB(0, 38, 105)
    local rowTextStroke = Color3.fromRGB(0, 52, 115)
    local yellow = Color3.fromRGB(255, 221, 37)

    local function ensure(parent, name, className)
        local node = parent:FindFirstChild(name)
        if node then
            assert(node:IsA(className), node:GetFullName() .. " is not " .. className)
            return node
        end
        node = Instance.new(className)
        node.Name = name
        node.Parent = parent
        return node
    end
    local function corner(parent, radius)
        local c = parent:FindFirstChildOfClass("UICorner") or ensure(parent, "Corner", "UICorner")
        c.CornerRadius = radius
        return c
    end
    local function borderStroke(parent, name, color, thickness)
        local s = ensure(parent, name, "UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Color = color
        s.Thickness = thickness
        s.Transparency = 0
        s.Enabled = true
        return s
    end
    local function textStroke(label, color, thickness)
        local s = nil
        for _, child in ipairs(label:GetChildren()) do
            if child:IsA("UIStroke") and child.ApplyStrokeMode == Enum.ApplyStrokeMode.Contextual then
                s = child
                break
            end
        end
        s = s or ensure(label, "TextOutline", "UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
        s.Color = color
        s.Thickness = thickness
        s.Transparency = 0
        s.Enabled = true
        return s
    end
    local function label(parent, name, props)
        local node = ensure(parent, name, "TextLabel")
        node.BackgroundTransparency = 1
        node.BorderSizePixel = 0
        node.FontFace = font
        node.TextScaled = true
        node.TextWrapped = true
        node.TextStrokeTransparency = 1
        for key, value in pairs(props) do
            node[key] = value
        end
        return node
    end
    local function sizeLimit(node, maxSize)
        local limit = node:FindFirstChildOfClass("UITextSizeConstraint") or ensure(node, "TextSizeLimit", "UITextSizeConstraint")
        limit.MinTextSize = 7
        limit.MaxTextSize = maxSize
    end
    local function gradient(parent, name, top, bottom)
        local g = ensure(parent, name, "UIGradient")
        g.Rotation = 90
        g.Color = ColorSequence.new(top, bottom)
        g.Enabled = true
        return g
    end
    local function track(parent, name, props, fillColor)
        local bar = ensure(parent, name, "Frame")
        bar.BorderSizePixel = 0
        bar.BackgroundColor3 = Color3.fromRGB(0, 45, 105)
        bar.BackgroundTransparency = 0
        for key, value in pairs(props) do
            bar[key] = value
        end
        corner(bar, UDim.new(0.5, 0))
        local fill = ensure(bar, "Fill", "Frame")
        fill.AnchorPoint = Vector2.zero
        fill.Position = UDim2.new()
        fill.Size = UDim2.fromScale(0, 1)
        fill.BorderSizePixel = 0
        fill.BackgroundColor3 = fillColor
        fill.BackgroundTransparency = 0
        fill.ZIndex = bar.ZIndex + 1
        corner(fill, UDim.new(0.5, 0))
        gradient(fill, "Gloss", Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190))
        return bar, fill
    end

    -- Panel body stays the shared translucent white frame; content cards become opaque like Shop cards.
    local content = panel.Content
    local list = content.TaskList
    list.BackgroundColor3 = Color3.fromRGB(22, 86, 178)
    list.BackgroundTransparency = 0
    gradient(list, "CardShade", Color3.fromRGB(34, 108, 206), Color3.fromRGB(16, 70, 160))
    list.Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    list.Stroke.Color = navyStroke
    list.Stroke.Thickness = 3

    local detail = content.TaskDetail
    detail.BackgroundColor3 = Color3.fromRGB(26, 104, 204)
    detail.BackgroundTransparency = 0
    gradient(detail, "CardShade", Color3.fromRGB(44, 134, 236), Color3.fromRGB(20, 82, 176))
    detail.Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    detail.Stroke.Color = navyStroke
    detail.Stroke.Thickness = 3

    -- Tabs: keep orange/grey backgrounds, add a claimable-count badge.
    for _, tabName in ipairs({ "DailyTab", "WeeklyTab" }) do
        local tab = panel.Tabs[tabName]
        local badge = ensure(tab, "Badge", "Frame")
        badge.AnchorPoint = Vector2.new(0.5, 0.5)
        badge.Position = UDim2.fromScale(0.97, 0.1)
        badge.Size = UDim2.fromScale(0.62, 0.62)
        badge.SizeConstraint = Enum.SizeConstraint.RelativeYY
        badge.BackgroundColor3 = Color3.fromRGB(255, 30, 40)
        badge.BackgroundTransparency = 0
        badge.BorderSizePixel = 0
        badge.ZIndex = 40
        badge.Visible = false
        corner(badge, UDim.new(0.5, 0))
        borderStroke(badge, "Stroke", white, 2)
        local count = label(badge, "Count", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromScale(0.78, 0.78),
            Text = "1",
            TextColor3 = white,
            ZIndex = 41,
        })
        textStroke(count, Color3.fromRGB(110, 0, 0), 1.25)
        sizeLimit(count, 16)
        ensure(badge, "PopScale", "UIScale").Scale = 1
    end

    -- Countdown pill: "Resets in" + the unchanged CountdownTime text.
    local pill = ensure(panel, "CountdownPill", "Frame")
    pill.AnchorPoint = Vector2.new(1, 0.5)
    pill.Position = UDim2.fromScale(0.94, 0.165)
    pill.Size = UDim2.fromScale(0.31, 0.078)
    pill.BackgroundColor3 = Color3.fromRGB(10, 52, 128)
    pill.BackgroundTransparency = 0
    pill.BorderSizePixel = 0
    pill.ZIndex = 33
    corner(pill, UDim.new(0.5, 0))
    borderStroke(pill, "Stroke", white, 2)
    local resetLabel = label(pill, "Label", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0.07, 0.5),
        Size = UDim2.fromScale(0.38, 0.62),
        Text = "Resets in",
        TextColor3 = yellow,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 34,
    })
    textStroke(resetLabel, Color3.fromRGB(60, 30, 0), 1.25)
    sizeLimit(resetLabel, 14)
    local countdown = panel.CountdownTime
    countdown.AnchorPoint = Vector2.new(1, 0.5)
    countdown.Position = UDim2.fromScale(0.925, 0.165)
    countdown.Size = UDim2.fromScale(0.165, 0.056)
    countdown.TextColor3 = white
    countdown.ZIndex = 35
    textStroke(countdown, Color3.fromRGB(0, 20, 70), 1.5)
    sizeLimit(countdown, 17)

    -- Task row template: tag pill, white title, description, mini progress and status text.
    local row = list.ScrollingFrame.Template
    row.Size = UDim2.fromScale(0.97, 0.27)
    row.TaskRowSizeLimit.MinSize = Vector2.new(0, 66)
    gradient(row, "Gloss", Color3.new(1, 1, 1), Color3.fromRGB(205, 215, 230))
    local tag = row.PeriodTag
    tag.Position = UDim2.fromScale(0.045, 0.08)
    tag.Size = UDim2.fromScale(0.27, 0.18)
    tag.BackgroundColor3 = Color3.fromRGB(0, 80, 170)
    tag.BackgroundTransparency = 0.15
    tag.TextXAlignment = Enum.TextXAlignment.Center
    corner(tag, UDim.new(0.5, 0))
    sizeLimit(tag, 11)
    local title = row.TaskTitle
    title.Position = UDim2.fromScale(0.045, 0.28)
    title.Size = UDim2.fromScale(0.86, 0.27)
    title.TextColor3 = white
    textStroke(title, rowTextStroke, 1.5)
    sizeLimit(title, 18)
    local subtitle = row.TaskSubtitle
    subtitle.Position = UDim2.fromScale(0.045, 0.55)
    subtitle.Size = UDim2.fromScale(0.91, 0.2)
    sizeLimit(subtitle, 12)
    local rowTrack = track(row, "ProgressTrack", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromScale(0.045, 0.86),
        Size = UDim2.fromScale(0.6, 0.1),
        ZIndex = 35,
    }, Color3.fromRGB(80, 235, 255))
    borderStroke(rowTrack, "Stroke", Color3.fromRGB(0, 40, 95), 1)
    local rowProgress = label(row, "ProgressText", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.fromScale(0.955, 0.86),
        Size = UDim2.fromScale(0.29, 0.22),
        Text = "0/1",
        TextColor3 = white,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 36,
    })
    textStroke(rowProgress, rowTextStroke, 1.25)
    sizeLimit(rowProgress, 13)
    ensure(rowProgress, "PopScale", "UIScale").Scale = 1
    local flash = ensure(row, "ClaimFlash", "Frame")
    flash.Size = UDim2.fromScale(1, 1)
    flash.Position = UDim2.new()
    flash.AnchorPoint = Vector2.zero
    flash.BackgroundColor3 = white
    flash.BackgroundTransparency = 1
    flash.BorderSizePixel = 0
    flash.ZIndex = 45
    corner(flash, UDim.new(0, 8))
    row.RedPoint.Position = UDim2.fromScale(0.945, 0.2)

    -- Detail card layout.
    detail.TaskTitle.Position = UDim2.fromScale(0.02, 0.005)
    detail.TaskTitle.Size = UDim2.fromScale(0.62, 0.13)
    local status = detail.StatusText
    status:SetAttribute("TaskStatusChip", true)
    status.AnchorPoint = Vector2.new(1, 0)
    status.Position = UDim2.fromScale(0.98, 0.02)
    status.Size = UDim2.fromScale(0.3, 0.1)
    status.BackgroundTransparency = 0
    status.BackgroundColor3 = Color3.fromRGB(0, 120, 215)
    status.TextColor3 = white
    status.TextXAlignment = Enum.TextXAlignment.Center
    corner(status, UDim.new(0.5, 0))
    borderStroke(status, "ChipBorder", white, 2)
    local statusPadding = ensure(status, "Padding", "UIPadding")
    statusPadding.PaddingLeft = UDim.new(0.08, 0)
    statusPadding.PaddingRight = UDim.new(0.08, 0)
    statusPadding.PaddingTop = UDim.new(0.14, 0)
    statusPadding.PaddingBottom = UDim.new(0.14, 0)
    sizeLimit(status, 15)
    ensure(status, "PopScale", "UIScale").Scale = 1

    detail.ProgressBg.Position = UDim2.fromScale(0.02, 0.16)
    detail.ProgressBg.Size = UDim2.fromScale(0.96, 0.13)
    local detailTrack = detail.ProgressTrack
    detailTrack.Position = UDim2.fromScale(0.02, 0.325)
    detailTrack.Size = UDim2.fromScale(0.96, 0.075)
    detailTrack.BackgroundColor3 = Color3.fromRGB(0, 40, 100)
    detailTrack.BackgroundTransparency = 0
    borderStroke(detailTrack, "Stroke", Color3.fromRGB(0, 28, 80), 2)
    local detailFill = detailTrack.Fill
    detailFill.BackgroundColor3 = Color3.fromRGB(80, 235, 255)
    detailFill.ClipsDescendants = true
    gradient(detailFill, "Gloss", Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190))
    local fillShine = ensure(detailFill, "Shine", "Frame")
    fillShine.AnchorPoint = Vector2.new(0.5, 0.5)
    fillShine.Position = UDim2.fromScale(-0.2, 0.5)
    fillShine.Size = UDim2.fromScale(0.18, 1.6)
    fillShine.Rotation = 20
    fillShine.BackgroundColor3 = white
    fillShine.BackgroundTransparency = 0.35
    fillShine.BorderSizePixel = 0
    fillShine.ZIndex = detailFill.ZIndex + 1
    fillShine.Visible = false
    local fillShineGradient = ensure(fillShine, "Fade", "UIGradient")
    fillShineGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    local percent = label(detailTrack, "Percent", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(0.5, 0.95),
        Text = "0%",
        TextColor3 = white,
        ZIndex = detailFill.ZIndex + 3,
    })
    textStroke(percent, Color3.fromRGB(0, 30, 80), 1.5)
    sizeLimit(percent, 14)

    detail.RewardTitle.Position = UDim2.fromScale(0.02, 0.43)
    detail.RewardTitle.Size = UDim2.fromScale(0.47, 0.08)
    local rewards = detail.RewardList
    rewards.Position = UDim2.fromScale(0.02, 0.52)
    rewards.Size = UDim2.fromScale(0.96, 0.27)
    rewards.BackgroundColor3 = Color3.fromRGB(10, 48, 122)
    rewards.BackgroundTransparency = 0
    rewards.Stroke.Color = Color3.fromRGB(0, 28, 85)
    rewards.Stroke.Transparency = 0
    rewards.Layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    rewards.Layout.Padding = UDim.new(0.04, 0)
    for _, reward in ipairs(rewards:GetChildren()) do
        if reward.Name == "RewardTemplate" and reward:IsA("Frame") then
            reward.Size = UDim2.fromScale(0.2, 0.9)
            local glow = ensure(reward, "Glow", "ImageLabel")
            glow.AnchorPoint = Vector2.new(0.5, 0.5)
            glow.Position = UDim2.fromScale(0.5, 0.5)
            glow.Size = UDim2.fromScale(1.5, 1.5)
            glow.BackgroundTransparency = 1
            glow.Image = "rbxassetid://74861566895904"
            glow.ImageColor3 = Color3.fromRGB(255, 236, 140)
            glow.ImageTransparency = 0.25
            glow.ZIndex = 34
            glow.Visible = false
            local icon = reward.Rewardicon
            icon.ZIndex = 35
            reward.RewardNum.ZIndex = 36
            ensure(reward, "PopScale", "UIScale").Scale = 1
        end
    end

    local claim = detail.ClaimButton
    claim.Position = UDim2.fromScale(0.5, 0.905)
    claim.Size = UDim2.fromScale(0.46, 0.14)
    claim.ClipsDescendants = true
    local shine = ensure(claim, "Shine", "Frame")
    shine.AnchorPoint = Vector2.new(0.5, 0.5)
    shine.Position = UDim2.fromScale(-0.3, 0.5)
    shine.Size = UDim2.fromScale(0.22, 2)
    shine.Rotation = 20
    shine.BackgroundColor3 = white
    shine.BackgroundTransparency = 0.3
    shine.BorderSizePixel = 0
    shine.ZIndex = 35
    shine.Visible = false
    local shineGradient = ensure(shine, "Fade", "UIGradient")
    shineGradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    claim.Text.ZIndex = 36
    local claimGlow = ensure(detail, "ClaimGlow", "Frame")
    claimGlow.AnchorPoint = Vector2.new(0.5, 0.5)
    claimGlow.Position = claim.Position
    claimGlow.Size = UDim2.fromScale(0.5, 0.19)
    claimGlow.BackgroundColor3 = Color3.fromRGB(255, 236, 110)
    claimGlow.BackgroundTransparency = 0.25
    claimGlow.BorderSizePixel = 0
    claimGlow.ZIndex = 33
    claimGlow.Visible = false
    corner(claimGlow, UDim.new(0.3, 0))

    local complete = detail.Complete
    complete.AnchorPoint = Vector2.new(0.5, 0.5)
    complete.Position = claim.Position
    complete.Size = UDim2.fromScale(0.46, 0.14)
    complete.BackgroundTransparency = 0
    complete.BackgroundColor3 = Color3.fromRGB(46, 190, 70)
    complete.TextColor3 = white
    complete.Rotation = -3
    corner(complete, UDim.new(0, 8))
    borderStroke(complete, "BorderStroke", Color3.fromRGB(0, 95, 25), 3)
    textStroke(complete, Color3.fromRGB(0, 80, 20), 2)
    local completePadding = ensure(complete, "Padding", "UIPadding")
    completePadding.PaddingTop = UDim.new(0.14, 0)
    completePadding.PaddingBottom = UDim.new(0.14, 0)
    sizeLimit(complete, 21)
    ensure(complete, "PopScale", "UIScale").Scale = 1
    ensure(detail, "PopScale", "UIScale").Scale = 1
end

local function applyTaskUiV4()
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
end

if installedVersion < 4 then
    applyTaskUiV4()
    panel:SetAttribute("TaskUiStyleVersion", 4)
end
applyTaskUiV5(panel)
panel:SetAttribute("TaskUiStyleVersion", VERSION)
return "Task UI style migrated from v" .. tostring(installedVersion) .. " to v" .. tostring(VERSION)
