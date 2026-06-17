--[[
Script: TaskController
File: TaskController.lua
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/TaskController
Purpose: V5.3 daily and weekly task UI for Main.TaskBg.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local function requireSharedModule(moduleName)
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    if sharedFolder then
        local moduleInShared = sharedFolder:FindFirstChild(moduleName)
        if moduleInShared and moduleInShared:IsA("ModuleScript") then
            return require(moduleInShared)
        end
    end

    local moduleInRoot = ReplicatedStorage:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return require(moduleInRoot)
    end

    error(string.format(
        "[TaskController] Missing shared module %s",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local TaskController = {}

TaskController._localPlayer = nil
TaskController._connections = {}
TaskController._buttonBindings = {}
TaskController._rowBindings = {}
TaskController._generatedRows = {}
TaskController._mainGui = nil
TaskController._entryRoot = nil
TaskController._entryButton = nil
TaskController._entryRedPoint = nil
TaskController._panel = nil
TaskController._closeButton = nil
TaskController._tabsRoot = nil
TaskController._dailyTabRoot = nil
TaskController._weeklyTabRoot = nil
TaskController._countdownLabel = nil
TaskController._scrollingFrame = nil
TaskController._template = nil
TaskController._requestStateSyncEvent = nil
TaskController._stateSyncEvent = nil
TaskController._requestClaimEvent = nil
TaskController._state = nil
TaskController._selectedPeriod = "daily"
TaskController._isOpen = false
TaskController._bindRetryQueued = false
TaskController._panelTweens = {}
TaskController._panelAnimationSerial = 0
TaskController._clockToken = 0
TaskController._pendingClaimsByTaskId = {}

local GENERATED_ROW_ATTRIBUTE = "GeneratedTaskRow"
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.05
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_DURATION = 0.14
local HOVER_SCALE = 1.05
local ENTRY_HOVER_SCALE = 1.1
local PRESS_SCALE = 0.92
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_PENDING_SECONDS = 1.2
local BIND_RETRY_SECONDS = 0.5
local BIND_RETRY_WARNING_SECONDS = 12
local SELECTED_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local UNSELECTED_TEXT_COLOR = Color3.fromRGB(84, 95, 112)

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function ensureUiScale(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if uiScale then
        return uiScale
    end

    uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = guiObject
    return uiScale
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function findNested(root, path)
    local current = root
    for segment in string.gmatch(tostring(path or ""), "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    return current
end

local function setVisible(instance, visible)
    if instance and instance:IsA("GuiObject") then
        instance.Visible = visible == true
    end
end

local function setText(instance, text)
    if instance and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")) then
        instance.Text = tostring(text or "")
    end
end

local function setImage(instance, image)
    if instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) then
        instance.Image = tostring(image or "")
    end
end

local function setTextColor(instance, color)
    if instance and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")) then
        instance.TextColor3 = color
    end
end

local function setButtonEnabled(button, enabled)
    if button and button:IsA("GuiButton") then
        button.Active = enabled == true
        button.AutoButtonColor = enabled == true
        button.Selectable = enabled == true
    end
end

local function findFirstDescendantByNames(root, names)
    if not (root and type(names) == "table") then
        return nil
    end

    for _, name in ipairs(names) do
        local found = root:FindFirstChild(name, true)
        if found then
            return found
        end
    end
    return nil
end

local function resolveClickTarget(root, generatedName)
    if not root then
        return nil
    end
    if root:IsA("GuiButton") then
        return root
    end

    local existingButton = root:FindFirstChildWhichIsA("GuiButton", true)
    if existingButton then
        return existingButton
    end

    if not root:IsA("GuiObject") then
        return nil
    end

    local buttonName = tostring(generatedName or "TaskClickTarget")
    local generatedButton = root:FindFirstChild(buttonName)
    if generatedButton and generatedButton:IsA("TextButton") then
        return generatedButton
    end

    generatedButton = Instance.new("TextButton")
    generatedButton.Name = buttonName
    generatedButton.BackgroundTransparency = 1
    generatedButton.BorderSizePixel = 0
    generatedButton.Text = ""
    generatedButton.TextTransparency = 1
    generatedButton.AutoButtonColor = false
    generatedButton.Size = UDim2.fromScale(1, 1)
    generatedButton.Position = UDim2.fromScale(0, 0)
    generatedButton.ZIndex = root.ZIndex + 10
    generatedButton.Parent = root
    return generatedButton
end

local function findButtonByName(root, name)
    local node = root and root:FindFirstChild(name, true)
    return resolveClickTarget(node, name .. "ClickTarget"), node
end

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function formatCompactInteger(value)
    local amount = math.max(0, math.floor(tonumber(value) or 0))
    if amount >= 1000000 then
        return string.format("%.1fM", amount / 1000000)
    elseif amount >= 1000 then
        return string.format("%.1fK", amount / 1000)
    end
    return tostring(amount)
end

local function formatDuration(seconds)
    local safeSeconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(safeSeconds / 3600)
    local minutes = math.floor((safeSeconds % 3600) / 60)
    local remainingSeconds = safeSeconds % 60
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif minutes > 0 then
        return string.format("%dm", minutes)
    end
    return string.format("%ds", remainingSeconds)
end

local function formatCountdown(seconds)
    local safeSeconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local days = math.floor(safeSeconds / 86400)
    local hours = math.floor((safeSeconds % 86400) / 3600)
    local minutes = math.floor((safeSeconds % 3600) / 60)
    local remainingSeconds = safeSeconds % 60
    if days > 0 then
        return string.format("%dd %02d:%02d:%02d", days, hours, minutes, remainingSeconds)
    end
    return string.format("%02d:%02d:%02d", hours, minutes, remainingSeconds)
end

local function pluralize(noun, amount)
    if math.max(0, math.floor(tonumber(amount) or 0)) == 1 then
        return noun
    end
    return noun .. "s"
end

local function buildTaskDescription(task)
    local taskType = tostring(task and task.taskType or "")
    local target = math.max(1, math.floor(tonumber(task and task.target) or 1))

    if taskType == "OnlineSeconds" then
        return "Stay online for " .. formatDuration(target)
    elseif taskType == "PlayerKills" then
        return "Defeat " .. formatInteger(target) .. " " .. pluralize("player", target)
    elseif taskType == "InviteFriend" then
        return "Invite " .. formatInteger(target) .. " " .. pluralize("friend", target)
    elseif taskType == "WheelSpinsUsed" then
        return "Use the wheel " .. formatInteger(target) .. " " .. pluralize("time", target)
    elseif taskType == "DiamondsEarned" then
        return "Earn " .. formatCompactInteger(target) .. " diamonds"
    elseif taskType == "LoginDays" then
        return "Log in on " .. formatInteger(target) .. " " .. pluralize("day", target) .. " this week"
    end

    local description = tostring(task and task.description or "")
    if description ~= "" then
        return description
    end
    return "Complete task"
end

local function buildProgressText(task)
    local progress = math.max(0, math.floor(tonumber(task and task.progress) or 0))
    local target = math.max(1, math.floor(tonumber(task and task.target) or 1))
    if tostring(task and task.taskType or "") == "OnlineSeconds" then
        return formatDuration(progress) .. "/" .. formatDuration(target)
    end
    return formatInteger(progress) .. "/" .. formatInteger(target)
end

local function cloneTask(task)
    if type(task) ~= "table" then
        return nil
    end
    return {
        taskId = math.max(0, math.floor(tonumber(task.taskId or task.TaskId) or 0)),
        period = tostring(task.period or task.Period or ""),
        taskType = tostring(task.taskType or task.TaskType or ""),
        target = math.max(1, math.floor(tonumber(task.target or task.Target) or 1)),
        progress = math.max(0, math.floor(tonumber(task.progress or task.Progress) or 0)),
        rewardType = tostring(task.rewardType or task.RewardType or ""),
        potionId = math.max(0, math.floor(tonumber(task.potionId or task.PotionId) or 0)),
        amount = math.max(1, math.floor(tonumber(task.amount or task.Amount) or 1)),
        description = tostring(task.description or task.Description or ""),
        icon = tostring(task.icon or task.Icon or ""),
        isComplete = task.isComplete == true or task.IsComplete == true,
        isClaimed = task.isClaimed == true or task.IsClaimed == true,
        isClaimable = task.isClaimable == true or task.IsClaimable == true,
    }
end

local function cloneTasks(tasks)
    local result = {}
    if type(tasks) ~= "table" then
        return result
    end
    for _, task in ipairs(tasks) do
        local copied = cloneTask(task)
        if copied and copied.taskId > 0 then
            table.insert(result, copied)
        end
    end
    return result
end

local function getTaskSortRank(task)
    if task.isClaimable and not task.isClaimed then
        return 0
    elseif not task.isClaimed then
        return 1
    end
    return 2
end

local function sortTasksForDisplay(tasks)
    table.sort(tasks, function(left, right)
        local leftRank = getTaskSortRank(left)
        local rightRank = getTaskSortRank(right)
        if leftRank ~= rightRank then
            return leftRank < rightRank
        end
        return (left.taskId or 0) < (right.taskId or 0)
    end)
end

local function isUnderNamedAncestor(instance, names)
    local current = instance
    while current do
        if names[current.Name] == true then
            return true
        end
        current = current.Parent
    end
    return false
end

local function setTaskDescriptionText(row, text)
    local direct = findFirstDescendantByNames(row, {
        "TaskName",
        "TaskTitle",
        "TaskDesc",
        "TaskDescription",
        "Description",
        "Desc",
        "Content",
    })
    if direct and (direct:IsA("TextLabel") or direct:IsA("TextButton") or direct:IsA("TextBox")) then
        setText(direct, text)
        return
    end

    local excludedAncestors = {
        ProgressBg = true,
        RewardBg = true,
        ClaimButton = true,
        Complete = true,
    }
    for _, descendant in ipairs(row:GetDescendants()) do
        if (descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox"))
            and not isUnderNamedAncestor(descendant, excludedAncestors)
            and descendant.Name ~= "Num"
            and descendant.Name ~= "RewardNum"
        then
            setText(descendant, text)
            return
        end
    end
end

local function setButtonText(buttonRoot, text)
    if not buttonRoot then
        return
    end
    if buttonRoot:IsA("TextButton") or buttonRoot:IsA("TextLabel") or buttonRoot:IsA("TextBox") then
        setText(buttonRoot, text)
        return
    end
    local label = findFirstDescendantByNames(buttonRoot, { "Label", "Text", "Title" })
    setText(label, text)
end

local function playTween(binding, key, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end
    local currentTween = binding.tweens[key]
    if currentTween then
        currentTween:Cancel()
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[key] = tween
    tween.Completed:Connect(function()
        if binding.tweens[key] == tween then
            binding.tweens[key] = nil
        end
    end)
    tween:Play()
end

function TaskController:_disconnectBindings(bindings)
    for _, binding in ipairs(bindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens or {}) do
            tween:Cancel()
        end
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale
        end
        if binding.rotationTarget and binding.rotationTarget.Parent then
            binding.rotationTarget.Rotation = binding.baseRotation
        end
    end
    table.clear(bindings)
end

function TaskController:_bindButton(button, onActivated, options, targetBindings)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    button.Active = true
    button.Selectable = true

    local scaleTarget = type(options) == "table" and options.ScaleTarget or button
    local rotationTarget = type(options) == "table" and options.RotationTarget or nil
    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        rotationTarget = rotationTarget,
        baseScale = uiScale.Scale,
        baseRotation = rotationTarget and rotationTarget.Rotation or 0,
        hoverScale = type(options) == "table" and tonumber(options.HoverScale) or HOVER_SCALE,
        pressScale = type(options) == "table" and tonumber(options.PressScale) or PRESS_SCALE,
        hoverRotation = type(options) == "table" and tonumber(options.HoverRotation) or 0,
        isHovered = false,
        isPressed = false,
        tweens = {},
        connections = {},
    }

    local function apply()
        local scale = binding.baseScale
        local rotation = binding.baseRotation
        local tweenInfo = RESET_TWEEN_INFO
        if binding.isPressed then
            scale = binding.baseScale * binding.pressScale
            tweenInfo = PRESS_TWEEN_INFO
        elseif binding.isHovered then
            scale = binding.baseScale * binding.hoverScale
            rotation = binding.baseRotation + binding.hoverRotation
            tweenInfo = HOVER_TWEEN_INFO
        end

        playTween(binding, "Scale", binding.uiScale, tweenInfo, { Scale = scale })
        if binding.rotationTarget then
            playTween(binding, "Rotation", binding.rotationTarget, tweenInfo, { Rotation = rotation })
        end
    end

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        apply()
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        apply()
    end))
    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            apply()
        end
    end))
    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            apply()
        end
    end))
    table.insert(binding.connections, button.Activated:Connect(function()
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    table.insert(targetBindings or self._buttonBindings, binding)
end

function TaskController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function TaskController:_playPanelOpen(immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return
    end
    self._panelAnimationSerial += 1
    local serial = self._panelAnimationSerial
    self:_cancelPanelTweens()
    self._panel.Visible = true

    local uiScale = ensureUiScale(self._panel)
    if immediate == true or not uiScale then
        if uiScale then
            uiScale.Scale = 1
        end
        return
    end

    uiScale.Scale = OPEN_FROM_SCALE
    local overshootTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Scale = OPEN_OVERSHOOT_SCALE,
    })
    local settleTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = 1,
    })
    table.insert(self._panelTweens, overshootTween)
    table.insert(self._panelTweens, settleTween)
    task.spawn(function()
        overshootTween:Play()
        overshootTween.Completed:Wait()
        if self._panelAnimationSerial ~= serial or not self._isOpen then
            return
        end
        settleTween:Play()
    end)
end

function TaskController:_playPanelClose(immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return
    end
    self._panelAnimationSerial += 1
    local serial = self._panelAnimationSerial
    self:_cancelPanelTweens()

    local uiScale = ensureUiScale(self._panel)
    if immediate == true or not uiScale or self._panel.Visible ~= true then
        if uiScale then
            uiScale.Scale = 1
        end
        self._panel.Visible = false
        return
    end

    local tween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    table.insert(self._panelTweens, tween)
    task.spawn(function()
        tween:Play()
        tween.Completed:Wait()
        if self._panelAnimationSerial ~= serial or self._isOpen then
            return
        end
        if uiScale and uiScale.Parent then
            uiScale.Scale = 1
        end
        if self._panel and self._panel.Parent then
            self._panel.Visible = false
        end
    end)
end

function TaskController:_newDefaultState()
    return {
        tasks = {
            daily = {},
            weekly = {},
        },
        dailyResetAt = 0,
        weeklyResetAt = 0,
        serverTimestamp = 0,
        localSyncClock = os.clock(),
        hasClaimableReward = false,
    }
end

function TaskController:_getState()
    if not self._state then
        self._state = self:_newDefaultState()
    end
    return self._state
end

function TaskController:_getServerNow()
    local state = self:_getState()
    local baseTimestamp = tonumber(state.serverTimestamp) or os.time()
    local localSyncClock = tonumber(state.localSyncClock) or os.clock()
    return baseTimestamp + math.max(0, os.clock() - localSyncClock)
end

function TaskController:_getTasksForSelectedPeriod()
    local state = self:_getState()
    local key = self._selectedPeriod == "weekly" and "weekly" or "daily"
    local tasks = cloneTasks(state.tasks and state.tasks[key])
    sortTasksForDisplay(tasks)
    return tasks
end

function TaskController:_hasClaimableTask()
    local state = self:_getState()
    if state.hasClaimableReward == true then
        return true
    end
    for _, periodKey in ipairs({ "daily", "weekly" }) do
        for _, task in ipairs(state.tasks and state.tasks[periodKey] or {}) do
            if task.isClaimable == true and task.isClaimed ~= true then
                return true
            end
        end
    end
    return false
end

function TaskController:_renderEntryState()
    setVisible(self._entryRedPoint, self:_hasClaimableTask())
end

function TaskController:_renderCountdown()
    local state = self:_getState()
    local resetAt = self._selectedPeriod == "weekly" and state.weeklyResetAt or state.dailyResetAt
    local remaining = math.max(0, (tonumber(resetAt) or 0) - self:_getServerNow())
    setText(self._countdownLabel, formatCountdown(remaining))
end

function TaskController:_applyTabs()
    local dailySelected = self._selectedPeriod ~= "weekly"
    local weeklySelected = not dailySelected

    local function applyTab(root, selected)
        if not root then
            return
        end
        local uiScale = ensureUiScale(root)
        if uiScale then
            uiScale.Scale = selected and 1.04 or 1
        end
        setVisible(root:FindFirstChild("SelectedBg"), selected)
        setVisible(root:FindFirstChild("IdleBg"), not selected)
        for _, descendant in ipairs(root:GetDescendants()) do
            if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
                setTextColor(descendant, selected and SELECTED_TEXT_COLOR or UNSELECTED_TEXT_COLOR)
            end
        end
        if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
            setTextColor(root, selected and SELECTED_TEXT_COLOR or UNSELECTED_TEXT_COLOR)
        end
    end

    applyTab(self._dailyTabRoot, dailySelected)
    applyTab(self._weeklyTabRoot, weeklySelected)
end

function TaskController:_clearRows()
    self:_disconnectBindings(self._rowBindings)
    for _, row in ipairs(self._generatedRows) do
        if row and row.Parent then
            row:Destroy()
        end
    end
    table.clear(self._generatedRows)

    if self._scrollingFrame then
        for _, child in ipairs(self._scrollingFrame:GetChildren()) do
            if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
                child:Destroy()
            end
        end
    end
end

function TaskController:_renderProgress(row, task)
    local progressBg = row and row:FindFirstChild("ProgressBg", true)
    local progressFill = progressBg and (
        progressBg:FindFirstChild("Progress")
        or progressBg:FindFirstChild("Fill")
        or progressBg:FindFirstChild("Bar")
    )
    local progressLabel = progressBg and (
        progressBg:FindFirstChild("Num")
        or progressBg:FindFirstChild("Number")
        or progressBg:FindFirstChild("Label")
    )

    local ratio = math.clamp((tonumber(task.progress) or 0) / math.max(1, tonumber(task.target) or 1), 0, 1)
    if progressFill and progressFill:IsA("GuiObject") then
        progressFill.Size = UDim2.new(ratio, 0, progressFill.Size.Y.Scale, progressFill.Size.Y.Offset)
    end
    setText(progressLabel, buildProgressText(task))
end

function TaskController:_renderReward(row, task)
    local rewardBg = row and row:FindFirstChild("RewardBg", true)
    local icon = rewardBg and (
        rewardBg:FindFirstChild("Rewardicon")
        or rewardBg:FindFirstChild("RewardIcon")
        or rewardBg:FindFirstChild("Icon")
    )
    local amountLabel = rewardBg and (
        rewardBg:FindFirstChild("RewardNum")
        or rewardBg:FindFirstChild("Num")
        or rewardBg:FindFirstChild("Number")
    )
    setImage(icon, task.icon)
    setText(amountLabel, "x" .. formatCompactInteger(task.amount))
end

function TaskController:_bindClaimButton(row, taskData)
    local claimButton, claimRoot = findButtonByName(row, "ClaimButton")
    local completeRoot = row and row:FindFirstChild("Complete", true)
    local isPending = (tonumber(self._pendingClaimsByTaskId[taskData.taskId]) or 0) > os.clock()
    local canClaim = taskData.isClaimable == true and taskData.isClaimed ~= true and not isPending and self._requestClaimEvent ~= nil

    setVisible(claimRoot or claimButton, taskData.isClaimed ~= true)
    setVisible(completeRoot, taskData.isClaimed == true)
    setButtonText(claimRoot or claimButton, canClaim and "Claim" or "Wait")

    if claimButton then
        self:_bindButton(claimButton, function()
            if not canClaim then
                return
            end
            self._pendingClaimsByTaskId[taskData.taskId] = os.clock() + CLAIM_PENDING_SECONDS
            self:_renderRows()
            if self._requestClaimEvent then
                self._requestClaimEvent:FireServer({
                    taskId = taskData.taskId,
                })
            end
            task.delay(CLAIM_PENDING_SECONDS, function()
                if (tonumber(self._pendingClaimsByTaskId[taskData.taskId]) or 0) <= os.clock() then
                    self._pendingClaimsByTaskId[taskData.taskId] = nil
                    self:_renderRows()
                end
            end)
        end, {
            ScaleTarget = claimRoot or claimButton,
        }, self._rowBindings)
        setButtonEnabled(claimButton, canClaim)
    end
end

function TaskController:_renderRows()
    if not (self._scrollingFrame and self._template) then
        return
    end

    self:_clearRows()
    self._template.Visible = false

    for index, taskData in ipairs(self:_getTasksForSelectedPeriod()) do
        local row = self._template:Clone()
        row.Name = "Task_" .. tostring(taskData.taskId)
        row.Visible = true
        row.LayoutOrder = index
        row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
        row.Parent = self._scrollingFrame
        table.insert(self._generatedRows, row)

        setTaskDescriptionText(row, buildTaskDescription(taskData))
        self:_renderProgress(row, taskData)
        self:_renderReward(row, taskData)
        self:_bindClaimButton(row, taskData)
    end
end

function TaskController:_renderAll()
    self:_renderEntryState()
    self:_renderCountdown()
    self:_applyTabs()
    self:_renderRows()
end

function TaskController:_applyStatePayload(payload)
    local source = type(payload) == "table" and payload or {}
    local tasks = type(source.tasks) == "table" and source.tasks or {}
    self._state = {
        tasks = {
            daily = cloneTasks(tasks.daily or tasks.Daily),
            weekly = cloneTasks(tasks.weekly or tasks.Weekly),
        },
        dailyCycleKey = tostring(source.dailyCycleKey or source.DailyCycleKey or ""),
        weeklyCycleKey = tostring(source.weeklyCycleKey or source.WeeklyCycleKey or ""),
        dailyResetAt = math.max(0, math.floor(tonumber(source.dailyResetAt or source.DailyResetAt) or 0)),
        weeklyResetAt = math.max(0, math.floor(tonumber(source.weeklyResetAt or source.WeeklyResetAt) or 0)),
        serverTimestamp = math.max(0, math.floor(tonumber(source.serverTimestamp or source.ServerTimestamp) or os.time())),
        localSyncClock = os.clock(),
        hasClaimableReward = source.hasClaimableReward == true or source.HasClaimableReward == true,
    }
    self._pendingClaimsByTaskId = {}
    self:_renderAll()
end

function TaskController:_requestState()
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer()
    end
end

function TaskController:_setOpen(isOpen, immediate)
    if not self._panel and not self:_bindUi(true) then
        return
    end

    self._isOpen = isOpen == true
    if self._isOpen then
        self:_requestState()
        self:_renderAll()
        self:_playPanelOpen(immediate)
    else
        self:_playPanelClose(immediate)
    end
end

function TaskController:Open()
    self:_setOpen(true, false)
end

function TaskController:Close()
    self:_setOpen(false, false)
end

function TaskController:_selectPeriod(period)
    local normalized = tostring(period or "")
    self._selectedPeriod = normalized == "weekly" and "weekly" or "daily"
    self:_renderAll()
end

function TaskController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local warningClock = os.clock() + BIND_RETRY_WARNING_SECONDS
        local warned = false
        while self._bindRetryQueued do
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                self:_renderAll()
                return
            end
            if not warned and os.clock() >= warningClock then
                warned = true
                warn("[TaskController] Could not find PlayerGui/Main/TaskBg UI; waiting.")
            end
            task.wait(BIND_RETRY_SECONDS)
        end
    end)
end

function TaskController:_bindUi(silent)
    self:_disconnectBindings(self._buttonBindings)
    self:_clearRows()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local right = self._mainGui:FindFirstChild("Right")
    self._entryRoot = right and right:FindFirstChild("Daily")
    self._entryButton = resolveClickTarget(self._entryRoot, "TaskEntryClickTarget")
    self._entryRedPoint = self._entryRoot and self._entryRoot:FindFirstChild("RedPoint", true)

    self._panel = self._mainGui:FindFirstChild("TaskBg")
    self._tabsRoot = self._panel and self._panel:FindFirstChild("Tabs")
    self._dailyTabRoot = self._tabsRoot and self._tabsRoot:FindFirstChild("Daily")
    self._weeklyTabRoot = self._tabsRoot and self._tabsRoot:FindFirstChild("Week")
    self._countdownLabel = self._panel and findNested(self._panel, "TitleBg/CountdownTime")
    self._scrollingFrame = self._panel and (
        findNested(self._panel, "Equipinfo/ScrollingFrame")
        or self._panel:FindFirstChild("ScrollingFrame", true)
    )
    self._template = self._scrollingFrame and self._scrollingFrame:FindFirstChild("Template")
    self._closeButton = self._panel and select(1, findButtonByName(self._panel, "CloseButton"))

    if not (self._entryRoot and self._panel and self._scrollingFrame and self._template) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._panel.Visible = self._isOpen == true
    ensureUiScale(self._panel)
    self._template.Visible = false

    self:_bindButton(self._entryButton, function()
        self:_setOpen(true, false)
    end, {
        ScaleTarget = self._entryRoot,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = PRESS_SCALE,
    })

    if self._closeButton then
        self:_bindButton(self._closeButton, function()
            self:_setOpen(false, false)
        end, {
            RotationTarget = self._closeButton,
            HoverRotation = HOVER_ROTATION,
        })
    end

    local dailyTabButton = resolveClickTarget(self._dailyTabRoot, "DailyTabClickTarget")
    local weeklyTabButton = resolveClickTarget(self._weeklyTabRoot, "WeekTabClickTarget")
    self:_bindButton(dailyTabButton, function()
        self:_selectPeriod("daily")
    end, {
        ScaleTarget = self._dailyTabRoot or dailyTabButton,
    })
    self:_bindButton(weeklyTabButton, function()
        self:_selectPeriod("weekly")
    end, {
        ScaleTarget = self._weeklyTabRoot or weeklyTabButton,
    })

    self:_renderEntryState()
    return true
end

function TaskController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[TaskController] Missing system events folder.")
        return
    end

    self._requestStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestTaskStateSync, 10)
    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.TaskStateSync, 10)
    self._requestClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestTaskClaim, 10)

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyStatePayload(payload)
        end))
    end
end

function TaskController:_startClockLoop()
    self._clockToken += 1
    local token = self._clockToken
    task.spawn(function()
        while self._clockToken == token do
            self:_renderCountdown()
            task.wait(1)
        end
    end)
end

function TaskController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._state = self:_newDefaultState()
    self._selectedPeriod = "daily"
    self._isOpen = false
    self._pendingClaimsByTaskId = {}

    disconnectAll(self._connections)
    self:_disconnectBindings(self._buttonBindings)
    self:_disconnectBindings(self._rowBindings)
    self:_clearRows()
    self:_cancelPanelTweens()
    self._clockToken += 1

    self:_connectRemotes()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    if not self:_bindUi(true) then
                        self:_queueBindRetry()
                    end
                    self:_renderAll()
                    self:_requestState()
                end)
            end
        end))
    end

    self:_startClockLoop()
    self:_requestState()
end

return TaskController
