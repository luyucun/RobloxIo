-- V6.12 task UI regression checks against the deployed formal template.
-- Studio Edit only; detached GUI, fresh controller clone, fake player and fake claim event.
-- Never calls Init, connects live remotes, starts Playtest, or changes player data.
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
        controller._clockToken += 1
        controller._bindRetryQueued = false
        controller._panelAnimationSerial += 1
        controller:_cancelPanelTweens()
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
    excluded = { "Detached UI does not validate viewport layout, rendered text bounds, or CanvasPosition." },
})
