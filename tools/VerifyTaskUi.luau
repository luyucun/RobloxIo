-- V6.12 / V6.16 task UI regression checks against the deployed formal template.
-- Studio Edit only; cloned GUI kept in a temporary ServerStorage folder, fresh controller clone,
-- fake player and fake claim event. Never calls Init, connects live remotes, starts Playtest,
-- or changes player data.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local results = {}
local controller = nil
local temporaryModules = nil
local detached = nil
local requestCount = 0
local requestPayloads = {}
local capturedCallbacks = {}
local verified = true

local function record(name, success, detail)
    table.insert(results, { name = name, passed = success == true, detail = detail })
    if success ~= true then
        verified = false
    end
end

local function check(name, callback)
    local ok, failure = pcall(callback)
    record(name, ok, not ok and tostring(failure) or nil)
end

local function closeColor(left, right)
    return math.abs(left.R - right.R) < 0.001
        and math.abs(left.G - right.G) < 0.001
        and math.abs(left.B - right.B) < 0.001
end

local function required(root, name)
    local found = root and root:FindFirstChild(name, true)
    assert(found, "Missing formal UI node: " .. name)
    return found
end

local function firstButton(root)
    return root:IsA("GuiButton") and root or root:FindFirstChildWhichIsA("GuiButton", true)
end

local function nested(root, path)
    local current = root
    for segment in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    assert(current, "Missing formal UI node: " .. path)
    return current
end

local function waitUntil(predicate, timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds
    while not predicate() and os.clock() < deadline do
        task.wait()
    end
    return predicate()
end

local function snapshotColors(root)
    local snapshot = {}
    local nodes = { root }
    for _, node in ipairs(root:GetDescendants()) do
        table.insert(nodes, node)
    end
    for _, node in ipairs(nodes) do
        if node:IsA("GuiObject") then
            local values = { BackgroundColor3 = node.BackgroundColor3 }
            if node:IsA("TextLabel") or node:IsA("TextButton") then
                values.TextColor3 = node.TextColor3
            elseif node:IsA("ImageLabel") or node:IsA("ImageButton") then
                values.ImageColor3 = node.ImageColor3
            end
            snapshot[node] = values
        end
    end
    return snapshot
end

local function assertColorsUnchanged(snapshot)
    for node, values in pairs(snapshot) do
        for property, color in pairs(values) do
            assert(closeColor(node[property], color), node.Name .. "." .. property .. " changed from its formal color")
        end
    end
end

local function snapshotTextStyles(row)
    local snapshot = {}
    for _, node in ipairs(row:GetDescendants()) do
        if node:IsA("TextLabel") or node:IsA("TextButton") then
            snapshot[node] = {
                FontFace = node.FontFace,
                TextSize = node.TextSize,
                TextStrokeTransparency = node.TextStrokeTransparency,
                TextStrokeColor3 = node.TextStrokeColor3,
            }
            for _, stroke in ipairs(node:GetChildren()) do
                if stroke:IsA("UIStroke") then
                    snapshot[stroke] = {
                        Enabled = stroke.Enabled,
                        Color = stroke.Color,
                        Thickness = stroke.Thickness,
                        ApplyStrokeMode = stroke.ApplyStrokeMode,
                    }
                end
            end
        end
    end
    return snapshot
end

local function assertTextStylesUnchanged(snapshot)
    for node, values in pairs(snapshot) do
        for property, value in pairs(values) do
            assert(node[property] == value, node:GetFullName() .. "." .. property .. " changed while selecting another task")
        end
    end
end

local function countGeneratedRows(root, attribute)
    local count = 0
    for _, child in ipairs(root:GetChildren()) do
        if child:GetAttribute(attribute) == true then
            count += 1
        end
    end
    return count
end

local success, failure = pcall(function()
    assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
    assert(game.PlaceId == 73988417166286, "Wrong PlaceId; expected Blade Orbit IO")
    record("Studio Edit and project identity", true)

    local mainTemplate = required(game:GetService("StarterGui"), "Main")
    local panelTemplate = mainTemplate:FindFirstChild("TaskBgNew")
    local rightTemplate = mainTemplate:FindFirstChild("Right")
    assert(panelTemplate and rightTemplate, "Formal TaskBgNew/Right templates are required")
    local controllers = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Controllers")
    local sourceModule = controllers and controllers:FindFirstChild("TaskController")
    assert(sourceModule and sourceModule:IsA("ModuleScript"), "Missing deployed TaskController")

    detached = Instance.new("Folder")
    detached.Name = "TaskUiDetachedVerification"
    local main = Instance.new("ScreenGui")
    main.Name = "Main"
    main.Parent = detached
    local panel = panelTemplate:Clone()
    panel.Parent = main
    rightTemplate:Clone().Parent = main

    temporaryModules = Instance.new("Folder")
    temporaryModules.Name = "TaskUiVerification_" .. HttpService:GenerateGUID(false)
    temporaryModules.Parent = game:GetService("ServerStorage")
    -- Keep the cloned GUI inside the DataModel so real tweens advance during the V6.16 motion checks.
    detached.Parent = temporaryModules
    controllers.CinematicUiGate:Clone().Parent = temporaryModules
    local isolatedModule = sourceModule:Clone()
    isolatedModule.Parent = temporaryModules
    controller = require(isolatedModule)

    local fakePlayerGui = {}
    function fakePlayerGui:FindFirstChild(name)
        return name == "Main" and main or nil
    end
    local fakePlayer = {}
    function fakePlayer:FindFirstChild(name)
        return name == "PlayerGui" and fakePlayerGui or nil
    end
    controller._localPlayer = fakePlayer
    controller._requestClaimEvent = {
        FireServer = function(_, payload)
            requestCount += 1
            table.insert(requestPayloads, payload)
        end,
    }
    local originalBindButton = controller._bindButton
    controller._bindButton = function(self, button, callback, options, bindings)
        if button then
            capturedCallbacks[button] = callback
        end
        return originalBindButton(self, button, callback, options, bindings)
    end
    assert(controller:_bindUi(true), "Controller cannot bind cloned formal template")
    panel.Visible = true
    local detail = controller._taskDetailRoot
    local claimRoot = required(detail, "ClaimButton")
    local claimButton = assert(firstButton(claimRoot), "ClaimButton has no GuiButton")
    local originalClaimColors = snapshotColors(claimRoot)
    local fill = required(required(detail, "ProgressTrack"), "Fill")
    local status = required(detail, "StatusText")
    local progressNum = required(required(detail, "ProgressBg"), "Num")

    local function taskData(id, period, taskType, progress, target, state)
        return {
            taskId = id,
            period = period,
            taskType = taskType,
            progress = progress,
            target = target,
            shortTitle = "Verification task " .. tostring(id),
            shortDescription = taskType == "OnlineSeconds" and "Play for 15 minutes today" or "Complete the displayed goal",
            isClaimable = state == "ready",
            isComplete = state == "ready" or state == "claimed",
            isClaimed = state == "claimed",
            rewards = { { rewardType = "Chest", amount = 1, icon = "rbxassetid://100403311120383" } },
        }
    end
    local daily = {
        taskData(101, "daily", "OnlineSeconds", 300, 900, "progress"),
        taskData(102, "daily", "PlayerKills", 5, 5, "ready"),
        taskData(103, "daily", "WheelSpinsUsed", 5, 5, "claimed"),
    }
    local weekly = { taskData(201, "weekly", "PlayerKills", 10, 50, "progress") }
    local function applyState(dailyTasks, weeklyTasks)
        controller:_applyStatePayload({
            tasks = { daily = dailyTasks, weekly = weeklyTasks },
            dailyResetAt = os.time() + 7200,
            weeklyResetAt = os.time() + 86400,
            serverTimestamp = os.time(),
        })
    end
    local function row(id)
        return required(controller._scrollingFrame, "Task_" .. tostring(id))
    end
    local function activateClaim()
        local callback = capturedCallbacks[claimButton]
        assert(type(callback) == "function", "Claim callback was not bound")
        callback()
    end
    applyState(daily, weekly)

    check("Normal Claim retains formal colors and avoids automatic button tint", function()
        assertColorsUnchanged(originalClaimColors)
        assert(claimButton.AutoButtonColor == false)
        assert(claimRoot.Visible and claimButton.Active)
    end)

    check("Ready, in-progress and claimed states match detail status and progress", function()
        controller:_selectTask(102)
        assert(status.Text == "Ready")
        assert(fill.Visible and math.abs(fill.Size.X.Scale - 1) < 0.0001)
        assert(string.find(progressNum.Text, "(5/5)", 1, true))
        controller:_selectTask(101)
        assert(status.Text == "In progress")
        assert(math.abs(fill.Size.X.Scale - 1 / 3) < 0.0001)
        assert(string.find(progressNum.Text, "(5/15)", 1, true))
        controller:_selectTask(103)
        assert(status.Text == "Claimed")
        assert(not claimRoot.Visible and required(detail, "Complete").Visible)
    end)

    check("Selection changes the row border without changing text style", function()
        controller:_selectTask(101)
        local first = row(101)
        local textStyles = snapshotTextStyles(first)
        local border = first:FindFirstChild("SelectionStroke") or first:FindFirstChildOfClass("UIStroke")
        assert(border and border:IsA("UIStroke"), "Expected a direct row selection border")
        if first:IsA("TextButton") then
            assert(border.ApplyStrokeMode == Enum.ApplyStrokeMode.Border, "A text button row outline must use Border stroke mode")
        end
        assert(border.Enabled)
        local selectedBorderColor = border.Color
        controller:_selectTask(102)
        assert(row(101) == first, "Selecting another task rebuilt the original row")
        assertTextStylesUnchanged(textStyles)
        assert(not border.Enabled or not closeColor(border.Color, selectedBorderColor), "Selected and idle row borders have no visual distinction")
    end)

    check("Progress sync reuses task rows, reward icons and button bindings", function()
        controller:_selectTask(101)
        local firstRow = row(101)
        local reward = controller._generatedRewardRows[1]
        local claimBinding = controller._detailBindings[1]
        local rowBindingCount = #controller._rowBindings
        daily[1].progress = 360
        applyState(daily, weekly)
        assert(row(101) == firstRow)
        assert(controller._generatedRewardRows[1] == reward)
        assert(controller._detailBindings[1] == claimBinding)
        assert(#controller._rowBindings == rowBindingCount and rowBindingCount == 3)
        assert(string.find(progressNum.Text, "(6/15)", 1, true))
        assert(math.abs(fill.Size.X.Scale - 0.4) < 0.0001)
        controller:_selectTask(102)
        assert(controller._generatedRewardRows[1] == reward, "Identical reward content was rebuilt when switching tasks")
    end)

    check("Daily/weekly tabs update colors and title without rewriting motion scale", function()
        local dailyTab = controller._dailyTabRoot
        local selectedDailyColor = dailyTab.BackgroundColor3
        local idleWeeklyColor = controller._weeklyTabRoot.BackgroundColor3
        local scale = dailyTab:FindFirstChildOfClass("UIScale")
        assert(scale)
        scale.Scale = 1.02
        controller:_selectPeriod("weekly")
        assert(math.abs(scale.Scale - 1.02) < 0.00001, "Tab selection rewrote the active animation scale")
        assert(required(panel:FindFirstChild("TitleBg"), "Title").Text == "Weekly Tasks")
        assert(not closeColor(dailyTab.BackgroundColor3, selectedDailyColor), "Daily tab did not change from selected to idle")
        assert(not closeColor(controller._weeklyTabRoot.BackgroundColor3, idleWeeklyColor), "Weekly tab did not change from idle to selected")
        assert(#controller._generatedRows == 1 and #controller._rowBindings == 1)
        assert(countGeneratedRows(controller._scrollingFrame, "GeneratedTaskRow") == 1)
        assert(not controller._scrollingFrame:FindFirstChild("Task_101"))
        controller:_selectPeriod("daily")
        assert(required(panel:FindFirstChild("TitleBg"), "Title").Text == "Daily Tasks")
        assert(#controller._generatedRows == 3 and #controller._rowBindings == 3)
        assert(countGeneratedRows(controller._scrollingFrame, "GeneratedTaskRow") == 3)
        assert(not controller._scrollingFrame:FindFirstChild("Task_201"))
        scale.Scale = 1
    end)

    check("Empty task data removes stale detail, rewards and bindings, then rebuilds cleanly", function()
        applyState({}, {})
        assert(#controller._generatedRows == 0 and #controller._rowBindings == 0)
        assert(#controller._generatedRewardRows == 0 and #controller._detailBindings == 0)
        assert(required(detail, "TaskTitle").Text == "" and status.Text == "")
        assert(fill.Size.X.Scale == 0 and not fill.Visible)
        assert(required(required(detail, "ProgressBg"), "Num").Text == "")
        assert(not claimRoot.Visible and not required(detail, "Complete").Visible)
        applyState(daily, weekly)
        assert(#controller._generatedRows == 3 and #controller._rowBindings == 3)
        assert(countGeneratedRows(controller._scrollingFrame, "GeneratedTaskRow") == 3)
        assert(countGeneratedRows(controller._rewardList, "GeneratedTaskReward") == 1)
    end)

    check("Incomplete Claim keeps its label and sends no request", function()
        controller:_selectTask(101)
        local before = requestCount
        activateClaim()
        assert(requestCount == before)
        assert(claimRoot.Visible and claimButton.Active)
        local label = claimRoot:IsA("TextButton") and claimRoot
            or claimRoot:FindFirstChild("ButtonLabel", true)
            or required(claimRoot, "Text")
        assert(label.Text == "Claim")
        assertColorsUnchanged(originalClaimColors)
    end)

    check("Ready Claim sends only the selected task ID, pending blocks repeat activation", function()
        controller:_selectTask(102)
        local before = requestCount
        activateClaim()
        assert(requestCount == before + 1)
        local sent = requestPayloads[#requestPayloads]
        local payloadKeyCount = 0
        for _ in pairs(sent) do
            payloadKeyCount += 1
        end
        assert(sent.taskId == 102 and payloadKeyCount == 1, "Claim payload must contain only taskId")
        assert(not claimButton.Active and not claimButton.Selectable)
        activateClaim()
        assert(requestCount == before + 1, "Pending callback sent a repeated request")
    end)

    -- The real controller schedules a 1.2 s visual timeout. Let it finish before cleanup.
    if requestCount > 0 then
        task.wait(1.35)
        check("Pending timeout restores formal Claim colors without issuing a request", function()
            assert(requestCount == 1)
            assert(claimButton.Active)
            assertColorsUnchanged(originalClaimColors)
            assert(#controller._rowBindings == 3 and #controller._detailBindings == 1)
        end)
    end

    -- V6.16 status presentation (panel still closed, so values apply without motion).
    local claimedRowColor = Color3.fromRGB(96, 128, 168)
    local mutedTextColor = Color3.fromRGB(214, 224, 238)
    check("V6.16 template nodes are installed", function()
        assert(panelTemplate:GetAttribute("TaskUiStyleVersion") == 5, "TaskUiStyleVersion is not 5")
        for _, path in ipairs({
            "Tabs/DailyTab/Badge/Count",
            "Tabs/WeeklyTab/Badge/Count",
            "CountdownPill/Label",
            "Content/TaskDetail/ClaimGlow",
            "Content/TaskDetail/ClaimButton/Shine",
            "Content/TaskDetail/ProgressTrack/Percent",
            "Content/TaskDetail/ProgressTrack/Fill/Shine",
            "Content/TaskDetail/Complete/PopScale",
            "Content/TaskDetail/PopScale",
        }) do
            nested(panel, path)
        end
        local template = controller._template
        nested(template, "ProgressTrack/Fill")
        nested(template, "ProgressText/PopScale")
        nested(template, "ClaimFlash")
        assert(status:GetAttribute("TaskStatusChip") == true)
        local rewardTemplates = 0
        for _, reward in ipairs(controller._rewardList:GetChildren()) do
            if reward.Name == "RewardTemplate" then
                rewardTemplates += 1
                nested(reward, "Glow")
            end
        end
        assert(rewardTemplates > 0)
    end)

    check("Rows show progress, ready and claimed states", function()
        applyState(daily, weekly)
        local inProgress, ready, claimed = row(101), row(102), row(103)
        assert(nested(inProgress, "ProgressText").Text == "6/15")
        assert(math.abs(nested(inProgress, "ProgressTrack/Fill").Size.X.Scale - 0.4) < 0.0001)
        assert(nested(ready, "ProgressText").Text == "Ready!")
        assert(math.abs(nested(ready, "ProgressTrack/Fill").Size.X.Scale - 1) < 0.0001)
        assert(nested(claimed, "ProgressText").Text == "Done")
        assert(closeColor(claimed.BackgroundColor3, claimedRowColor), "Claimed row is not dimmed")
        assert(not closeColor(inProgress.BackgroundColor3, claimedRowColor))
        assert(closeColor(nested(claimed, "TaskTitle").TextColor3, mutedTextColor))
        assert(not closeColor(nested(inProgress, "TaskTitle").TextColor3, mutedTextColor))
        assert(nested(ready, "RedPoint").Visible and not nested(inProgress, "RedPoint").Visible)
    end)

    check("Tab badges count only claimable tasks", function()
        local dailyBadge = nested(controller._dailyTabRoot, "Badge")
        local weeklyBadge = nested(controller._weeklyTabRoot, "Badge")
        assert(dailyBadge.Visible and nested(dailyBadge, "Count").Text == "1")
        assert(not weeklyBadge.Visible)
    end)

    check("Status chip color follows the selected task state", function()
        controller:_selectTask(102)
        assert(status.Visible and closeColor(status.BackgroundColor3, Color3.fromRGB(255, 160, 0)))
        controller:_selectTask(101)
        assert(closeColor(status.BackgroundColor3, Color3.fromRGB(0, 120, 215)))
        assert(required(required(detail, "ProgressTrack"), "Percent").Text == "40%")
        controller:_selectTask(103)
        assert(closeColor(status.BackgroundColor3, Color3.fromRGB(46, 190, 70)))
        assert(closeColor(status.TextColor3, Color3.new(1, 1, 1)))
    end)

    -- V6.16 motion with the panel open.
    local claimGlow = required(detail, "ClaimGlow")
    local claimShine = required(claimRoot, "Shine")
    local function rowScales()
        local scales = {}
        for _, entry in pairs(controller._rowEntriesByTaskId) do
            table.insert(scales, entry.row:FindFirstChildOfClass("UIScale"))
        end
        return scales
    end

    check("Opening pops rows in and settles them at full size", function()
        controller:_selectTask(101)
        controller:_setOpen(true, false)
        task.wait()
        local shrunk = false
        for _, scale in ipairs(rowScales()) do
            if scale and scale.Scale < 0.999 then
                shrunk = true
            end
        end
        assert(shrunk, "Rows did not start the entrance motion")
        assert(waitUntil(function()
            for _, scale in ipairs(rowScales()) do
                if not scale or math.abs(scale.Scale - 1) > 0.001 then
                    return false
                end
            end
            return next(controller._motionTweens) == nil
        end, 2), "Row entrance did not settle")
        assert(math.abs(nested(row(101), "ProgressTrack/Fill").Size.X.Scale - 0.4) < 0.0001)
    end)

    check("Ready selection starts claim glow, shine and reward glow; other tasks stop them", function()
        controller:_selectTask(102)
        local rewardGlow = nested(controller._generatedRewardRows[1], "Glow")
        assert(claimGlow.Visible and claimShine.Visible and rewardGlow.Visible)
        assert(controller._ambientTweens.claimGlow and controller._ambientTweens["row:102"])
        controller:_selectTask(101)
        assert(not claimGlow.Visible and not claimShine.Visible and not rewardGlow.Visible)
        assert(controller._ambientTweens["row:102"], "Ready row pulse stopped when another task was selected")
        assert(controller._ambientTweens.claimGlow == nil)
    end)

    check("Detail bar fills from empty for a newly selected task", function()
        controller:_selectTask(102)
        controller:_selectTask(101)
        assert(math.abs(fill:GetAttribute("TaskTargetRatio") - 0.4) < 0.0001)
        task.wait()
        assert(fill.Size.X.Scale < 0.39, "Detail bar did not restart from empty")
        assert(waitUntil(function()
            return math.abs(fill.Size.X.Scale - 0.4) < 0.0001
        end, 1.5), "Detail bar did not reach the task ratio")
    end)

    check("Claim celebration waits for a visible panel, then pops the stamp and flashes the row", function()
        controller:_selectTask(102)
        local claimedDaily = { daily[1], taskData(102, "daily", "PlayerKills", 5, 5, "claimed"), daily[3] }
        panel.Visible = false -- The shared reward popup hides the task panel first.
        applyState(claimedDaily, weekly)
        task.wait(0.35)
        assert(controller._queuedCelebrations[102] == "claimed", "Celebration was dropped or played while hidden")
        local complete = required(detail, "Complete")
        local stampScale = complete:FindFirstChild("PopScale")
        assert(math.abs(stampScale.Scale - 1) < 0.001)
        assert(complete.Visible and not claimRoot.Visible and not claimGlow.Visible)
        panel.Visible = true
        assert(waitUntil(function()
            return next(controller._queuedCelebrations) == nil
        end, 1), "Queued celebration did not flush after the panel reappeared")
        assert(stampScale.Scale > 1.01, "Claimed stamp did not pop")
        local flash = nested(row(102), "ClaimFlash")
        assert(flash.BackgroundTransparency < 0.99, "Claimed row did not flash")
        assert(waitUntil(function()
            return math.abs(stampScale.Scale - 1) < 0.001 and flash.BackgroundTransparency > 0.99
        end, 1.5), "Claim celebration did not settle")
        assert(not nested(controller._dailyTabRoot, "Badge").Visible)
    end)

    check("Closing stops every loop and restores effect nodes", function()
        applyState(daily, weekly)
        controller:_selectTask(102)
        assert(claimGlow.Visible)
        controller:_setOpen(false, true)
        assert(controller._ambientSignature == "" and next(controller._ambientTweens) == nil)
        assert(#controller._ambientRestores == 0 and next(controller._motionTweens) == nil)
        assert(next(controller._queuedCelebrations) == nil)
        assert(not claimGlow.Visible and not claimShine.Visible)
        assert(not nested(controller._generatedRewardRows[1], "Glow").Visible)
        for _, scale in ipairs(rowScales()) do
            assert(scale and math.abs(scale.Scale - 1) < 0.001)
        end
    end)
end)

if not success then
    record("Verification setup or execution", false, tostring(failure))
    -- Drain any visual timeout issued before an unexpected error, while its clones still exist.
    if requestCount > 0 then
        task.wait(1.35)
    end
end

local cleanupSuccess, cleanupFailure = pcall(function()
    if controller then
        controller._isOpen = false
        controller._clockToken += 1
        controller._bindRetryQueued = false
        controller._panelAnimationSerial += 1
        controller:_cancelPanelTweens()
        controller:_stopAmbientEffects()
        controller:_cancelMotionTweens()
        table.clear(controller._queuedCelebrations)
        for _, connection in ipairs(controller._panelConnections) do
            connection:Disconnect()
        end
        table.clear(controller._panelConnections)
        controller:_disconnectBindings(controller._buttonBindings)
        controller:_disconnectBindings(controller._detailBindings)
        controller:_clearRows()
        controller:_clearRewardRows()
    end
end)
-- Artifact destruction must still happen if a controller cleanup method fails.
if temporaryModules then
    temporaryModules:Destroy()
end
if detached then
    detached:Destroy()
end
record("Temporary UI, module clones and event bindings cleaned up", cleanupSuccess,
    not cleanupSuccess and tostring(cleanupFailure) or nil)

return HttpService:JSONEncode({
    verified = verified,
    results = results,
    fakeClaimRequests = requestCount,
    excluded = {
        "Unrendered cloned UI does not validate viewport layout, rendered text bounds, or CanvasPosition.",
        "Motion checks sample Studio Edit tweens; perceived smoothness and mobile frame rate need Playtest.",
    },
})
