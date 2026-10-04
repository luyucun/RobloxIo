--[[
Script: TaskController
File: TaskController.lua
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/TaskController
Purpose: V5.8 daily and weekly task UI for Main.TaskBgNew.
V6.16: optional status chip, row progress, tab badges and open/ready/claim motion.
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

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")
local CinematicUiGate = require((script.Parent:FindFirstChild("Controllers") or script.Parent):WaitForChild("CinematicUiGate"))

local function isTaskEntryVisible()
    local entryVisibility = GameConfig.UI_ENTRY_VISIBILITY
    return type(entryVisibility) ~= "table" or entryVisibility.Tasks ~= false
end

local TaskController = {}

TaskController._localPlayer = nil
TaskController._connections = {}
TaskController._buttonBindings = {}
TaskController._rowBindings = {}
TaskController._detailBindings = {}
TaskController._rewardBindings = {}
TaskController._navigationController = nil
TaskController._generatedRows = {}
TaskController._generatedRewardRows = {}
TaskController._rowEntriesByTaskId = {}
TaskController._rewardRenderSignature = nil
TaskController._detailClaimSignature = nil
TaskController._detailClaimButton = nil
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
TaskController._taskListRoot = nil
TaskController._scrollingFrame = nil
TaskController._template = nil
TaskController._taskDetailRoot = nil
TaskController._rewardList = nil
TaskController._rewardTemplate = nil
TaskController._requestStateSyncEvent = nil
TaskController._stateSyncEvent = nil
TaskController._requestClaimEvent = nil
TaskController._state = nil
TaskController._selectedPeriod = "daily"
TaskController._selectedTaskIdByPeriod = {}
TaskController._isOpen = false
TaskController._bindRetryQueued = false
TaskController._panelTweens = {}
TaskController._panelAnimationSerial = 0
TaskController._clockToken = 0
TaskController._pendingClaimsByTaskId = {}
TaskController._panelConnections = {}
TaskController._motionTweens = {}
TaskController._ambientTweens = {}
TaskController._ambientRestores = {}
TaskController._ambientSignature = ""
TaskController._ambientSerial = 0
TaskController._detailRenderedTaskId = nil
TaskController._queuedCelebrations = {}

local GENERATED_ROW_ATTRIBUTE = "GeneratedTaskRow"
local GENERATED_REWARD_ATTRIBUTE = "GeneratedTaskReward"
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.05
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_DURATION = 0.14
local HOVER_SCALE = 1.035
local ENTRY_HOVER_SCALE = 1.1
local PRESS_SCALE = 0.97
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_PENDING_SECONDS = 1.2
local BIND_RETRY_SECONDS = 0.5
local BIND_RETRY_WARNING_SECONDS = 12
local DISABLED_TINT = Color3.fromRGB(155, 155, 155)
local SELECTED_TAB_BACKGROUND_COLOR = Color3.fromRGB(255, 170, 0)
local DEFAULT_IDLE_TAB_BACKGROUND_COLOR = Color3.fromRGB(100, 100, 100)
local SELECTED_TAB_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local IDLE_TAB_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local SELECTED_ROW_BACKGROUND_COLOR = Color3.fromRGB(0, 170, 255)
local IDLE_ROW_BACKGROUND_COLOR = Color3.fromRGB(0, 170, 255)
local SELECTED_ROW_STROKE_COLOR = Color3.fromRGB(255, 221, 37)
local IDLE_ROW_STROKE_COLOR = Color3.fromRGB(85, 255, 255)
local READY_TEXT_COLOR = Color3.fromRGB(255, 221, 37)
local CLAIMED_TEXT_COLOR = Color3.fromRGB(0, 255, 0)
local PROGRESS_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local CLAIMED_ROW_BACKGROUND_COLOR = Color3.fromRGB(96, 128, 168)
local MUTED_ROW_TEXT_COLOR = Color3.fromRGB(214, 224, 238)
local CHIP_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local TASK_STATUS_PROGRESS = "progress"
local TASK_STATUS_READY = "ready"
local TASK_STATUS_CLAIMED = "claimed"
local STATUS_STYLES = {
    [TASK_STATUS_PROGRESS] = {
        Chip = Color3.fromRGB(0, 120, 215),
        Fill = Color3.fromRGB(80, 235, 255),
        RowText = Color3.fromRGB(255, 255, 255),
    },
    [TASK_STATUS_READY] = {
        Chip = Color3.fromRGB(255, 160, 0),
        Fill = Color3.fromRGB(255, 214, 40),
        RowText = Color3.fromRGB(255, 221, 37),
    },
    [TASK_STATUS_CLAIMED] = {
        Chip = Color3.fromRGB(46, 190, 70),
        Fill = Color3.fromRGB(90, 225, 100),
        RowText = Color3.fromRGB(140, 255, 150),
    },
}
-- V6.16 motion. Every effect is visual only and stops when the panel closes.
local FILL_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ROW_ENTRANCE_FROM_SCALE = 0.8
local ROW_ENTRANCE_DURATION = 0.22
local ROW_ENTRANCE_STAGGER_SECONDS = 0.035
local ROW_ENTRANCE_MAX_STAGGER_ROWS = 8
local DETAIL_POP_FROM_SCALE = 0.96
local DETAIL_POP_TWEEN_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_TWEEN_INFO = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FLASH_TWEEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CHIP_PULSE_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local GLOW_PULSE_TWEEN_INFO = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local GLOW_SPIN_TWEEN_INFO = TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1)
local SHINE_SWEEP_SECONDS = 0.6
local SHINE_GAP_SECONDS = 1.5
local CHIP_PULSE_SCALE = 1.12
local CLAIM_STAMP_FROM_SCALE = 1.8
local CELEBRATION_SETTLE_SECONDS = 0.2

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

local function restoreDefaultSize(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return
    end

    local defaultXScale = guiObject:GetAttribute("TaskDefaultSizeXScale")
    local defaultXOffset = guiObject:GetAttribute("TaskDefaultSizeXOffset")
    local defaultYScale = guiObject:GetAttribute("TaskDefaultSizeYScale")
    local defaultYOffset = guiObject:GetAttribute("TaskDefaultSizeYOffset")
    if defaultXScale == nil or defaultXOffset == nil or defaultYScale == nil or defaultYOffset == nil then
        local size = guiObject.Size
        guiObject:SetAttribute("TaskDefaultSizeXScale", size.X.Scale)
        guiObject:SetAttribute("TaskDefaultSizeXOffset", size.X.Offset)
        guiObject:SetAttribute("TaskDefaultSizeYScale", size.Y.Scale)
        guiObject:SetAttribute("TaskDefaultSizeYOffset", size.Y.Offset)
        return
    end

    guiObject.Size = UDim2.new(defaultXScale, defaultXOffset, defaultYScale, defaultYOffset)
end

local function applyTabButtonStyle(root, selected)
    if not (root and root:IsA("GuiObject")) then
        return
    end

    root.BackgroundColor3 = selected == true and SELECTED_TAB_BACKGROUND_COLOR or DEFAULT_IDLE_TAB_BACKGROUND_COLOR
    local label = root:FindFirstChild("ButtonLabel", true)
    if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
        label.TextColor3 = selected == true and SELECTED_TAB_TEXT_COLOR or IDLE_TAB_TEXT_COLOR
    end
end

local function setButtonEnabled(button, enabled)
    if button and button:IsA("GuiButton") then
        button.Active = enabled == true
        button.AutoButtonColor = false
        button.Selectable = enabled == true
    end
end

local function hideNamedGuiChildren(root, childName)
    if not root then
        return
    end
    for _, child in ipairs(root:GetChildren()) do
        if child.Name == childName and child:IsA("GuiObject") then
            child.Visible = false
        end
    end
end

local function tintGuiTree(root, enabled)
    if not root then
        return
    end

    local tint = nil
    if enabled ~= true then
        tint = DISABLED_TINT
    end
    local nodes = { root }
    for _, descendant in ipairs(root:GetDescendants()) do
        table.insert(nodes, descendant)
    end

    for _, node in ipairs(nodes) do
        if node:IsA("ImageLabel") or node:IsA("ImageButton") then
            if node:GetAttribute("TaskBaseImageColor3") == nil then
                node:SetAttribute("TaskBaseImageColor3", node.ImageColor3)
            end
            node.ImageColor3 = tint or node:GetAttribute("TaskBaseImageColor3")
        elseif node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox") then
            if node:GetAttribute("TaskBaseTextColor3") == nil then
                node:SetAttribute("TaskBaseTextColor3", node.TextColor3)
            end
            node.TextColor3 = tint or node:GetAttribute("TaskBaseTextColor3")
        elseif node:IsA("GuiObject") then
            if node:GetAttribute("TaskBaseBackgroundColor3") == nil then
                node:SetAttribute("TaskBaseBackgroundColor3", node.BackgroundColor3)
            end
            node.BackgroundColor3 = tint or node:GetAttribute("TaskBaseBackgroundColor3")
        end
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

local function secondsToDisplayMinutes(seconds)
    local safeSeconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if safeSeconds <= 0 then
        return 0
    end
    return math.max(1, math.ceil(safeSeconds / 60))
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

local function buildTaskTitle(task)
    local shortTitle = tostring(task and task.shortTitle or "")
    if shortTitle ~= "" then
        return shortTitle
    end

    local description = tostring(task and task.description or "")
    if description ~= "" then
        return description
    end
    return buildTaskDescription(task)
end

local function buildTaskSubtitle(task)
    local shortDescription = tostring(task and task.shortDescription or "")
    if shortDescription ~= "" then
        return shortDescription
    end
    return buildTaskDescription(task)
end

local function buildProgressText(task)
    local progress = math.max(0, math.floor(tonumber(task and task.progress) or 0))
    local target = math.max(1, math.floor(tonumber(task and task.target) or 1))
    if tostring(task and task.taskType or "") == "OnlineSeconds" then
        local targetMinutes = math.max(1, secondsToDisplayMinutes(target))
        local progressMinutes = math.min(targetMinutes, secondsToDisplayMinutes(progress))
        return formatInteger(progressMinutes) .. "/" .. formatInteger(targetMinutes)
    end
    return formatInteger(progress) .. "/" .. formatInteger(target)
end

local function getTaskStatus(taskData)
    if taskData and taskData.isClaimed == true then
        return TASK_STATUS_CLAIMED
    elseif taskData and taskData.isClaimable == true then
        return TASK_STATUS_READY
    end
    return TASK_STATUS_PROGRESS
end

local function getProgressRatio(taskData)
    if not taskData then
        return 0
    end
    return math.clamp((tonumber(taskData.progress) or 0) / math.max(1, tonumber(taskData.target) or 1), 0, 1)
end

-- Rows show finished tasks as full even if a stale sync still carries old progress.
local function getRowProgressRatio(taskData, status)
    if status ~= TASK_STATUS_PROGRESS then
        return 1
    end
    return getProgressRatio(taskData)
end

local function setMutedTextColor(label, muted)
    if not (label and (label:IsA("TextLabel") or label:IsA("TextButton"))) then
        return
    end
    if label:GetAttribute("TaskBaseTextColor3") == nil then
        label:SetAttribute("TaskBaseTextColor3", label.TextColor3)
    end
    label.TextColor3 = muted == true and MUTED_ROW_TEXT_COLOR or label:GetAttribute("TaskBaseTextColor3")
end

local function applyTaskStatus(label, taskData)
    if not (label and (label:IsA("TextLabel") or label:IsA("TextButton"))) then
        return
    end
    -- V6.16 templates mark StatusText as a colored chip; older templates keep colored text.
    local isChip = label:GetAttribute("TaskStatusChip") == true
    if isChip then
        label.Visible = taskData ~= nil
    end
    if not taskData then
        label.Text = ""
        return
    end

    local status = getTaskStatus(taskData)
    if status == TASK_STATUS_CLAIMED then
        label.Text = "Claimed"
        label.TextColor3 = CLAIMED_TEXT_COLOR
    elseif status == TASK_STATUS_READY then
        label.Text = "Ready"
        label.TextColor3 = READY_TEXT_COLOR
    else
        label.Text = "In progress"
        label.TextColor3 = PROGRESS_TEXT_COLOR
    end
    if isChip then
        label.TextColor3 = CHIP_TEXT_COLOR
        label.BackgroundColor3 = STATUS_STYLES[status].Chip
    end
end

local function cloneReward(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local copied = {
        rewardType = tostring(reward.rewardType or reward.RewardType or ""),
        potionId = math.max(0, math.floor(tonumber(reward.potionId or reward.PotionId) or 0)),
        chestId = math.max(0, math.floor(tonumber(reward.chestId or reward.ChestId) or 0)),
        amount = math.max(1, math.floor(tonumber(reward.amount or reward.Amount) or 1)),
        icon = tostring(reward.icon or reward.Icon or ""),
        label = tostring(reward.label or reward.Label or ""),
    }
    if copied.rewardType == "" then
        return nil
    end
    return copied
end

local function cloneRewards(task)
    local result = {}
    local sourceRewards = type(task) == "table" and (task.rewards or task.Rewards) or nil
    if type(sourceRewards) == "table" then
        for _, reward in ipairs(sourceRewards) do
            local copied = cloneReward(reward)
            if copied then
                table.insert(result, copied)
            end
        end
    end

    if #result <= 0 and type(task) == "table" then
        local fallback = cloneReward({
            rewardType = task.rewardType or task.RewardType,
            potionId = task.potionId or task.PotionId,
            chestId = task.chestId or task.ChestId,
            amount = task.amount or task.Amount,
            icon = task.icon or task.Icon,
        })
        if fallback then
            table.insert(result, fallback)
        end
    end
    return result
end

local function cloneTask(task)
    if type(task) ~= "table" then
        return nil
    end

    return {
        taskId = math.max(0, math.floor(tonumber(task.taskId or task.TaskId) or 0)),
        period = string.lower(tostring(task.period or task.Period or "")) == "weekly" and "weekly" or "daily",
        taskType = tostring(task.taskType or task.TaskType or ""),
        target = math.max(1, math.floor(tonumber(task.target or task.Target) or 1)),
        progress = math.max(0, math.floor(tonumber(task.progress or task.Progress) or 0)),
        rewardType = tostring(task.rewardType or task.RewardType or ""),
        potionId = math.max(0, math.floor(tonumber(task.potionId or task.PotionId) or 0)),
        chestId = math.max(0, math.floor(tonumber(task.chestId or task.ChestId) or 0)),
        amount = math.max(1, math.floor(tonumber(task.amount or task.Amount) or 1)),
        description = tostring(task.description or task.Description or ""),
        shortTitle = tostring(task.shortTitle or task.ShortTitle or ""),
        shortDescription = tostring(task.shortDescription or task.ShortDescription or ""),
        icon = tostring(task.icon or task.Icon or ""),
        rewards = cloneRewards(task),
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

local function setButtonText(buttonRoot, text)
    if not buttonRoot then
        return
    end
    if buttonRoot:IsA("TextButton") or buttonRoot:IsA("TextLabel") or buttonRoot:IsA("TextBox") then
        setText(buttonRoot, text)
        return
    end
    local label = findFirstDescendantByNames(buttonRoot, { "ButtonLabel", "Label", "Text", "Title", "ButtonText" })
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
    button.AutoButtonColor = false

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
        if button.Active ~= true then
            return
        end
        binding.isHovered = true
        apply()
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        apply()
    end))
    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        if button.Active ~= true then
            return
        end
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
        if button.Active ~= true then
            return
        end
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    table.insert(targetBindings or self._buttonBindings, binding)
    return binding
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

-- One motion tween per target instance; a newer motion on the same target replaces the older one.
function TaskController:_playMotion(target, tweenInfo, goal)
    local current = self._motionTweens[target]
    if current then
        current:Cancel()
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    self._motionTweens[target] = tween
    tween.Completed:Connect(function()
        if self._motionTweens[target] == tween then
            self._motionTweens[target] = nil
        end
    end)
    tween:Play()
    return tween
end

-- Cancelled motion snaps to its final state so closing mid-animation never leaves shrunken rows or partial bars.
function TaskController:_cancelMotionTweens()
    for target, tween in pairs(self._motionTweens) do
        tween:Cancel()
        if target.Parent then
            if target:IsA("UIScale") then
                target.Scale = 1
            elseif target:GetAttribute("TaskTargetRatio") ~= nil then
                local ratio = tonumber(target:GetAttribute("TaskTargetRatio")) or 0
                target.Size = UDim2.new(ratio, 0, target.Size.Y.Scale, target.Size.Y.Offset)
                target.Visible = ratio > 0
            elseif target:IsA("GuiObject") and target.Name == "ClaimFlash" then
                target.BackgroundTransparency = 1
            end
        end
    end
    table.clear(self._motionTweens)
end

function TaskController:_setFillRatio(fill, ratio, animate, fromZero, delayTime)
    if not (fill and fill:IsA("GuiObject")) then
        return
    end

    local safeRatio = math.clamp(tonumber(ratio) or 0, 0, 1)
    local size = fill.Size
    local target = UDim2.new(safeRatio, 0, size.Y.Scale, size.Y.Offset)
    fill:SetAttribute("TaskTargetRatio", safeRatio)
    local current = self._motionTweens[fill]
    if current then
        current:Cancel()
        self._motionTweens[fill] = nil
    end

    local delaySeconds = math.max(0, tonumber(delayTime) or 0)
    if animate ~= true or not self._isOpen then
        fill.Size = target
        fill.Visible = safeRatio > 0
        return
    end
    if fromZero == true then
        fill.Size = UDim2.new(0, 0, size.Y.Scale, size.Y.Offset)
    end
    if delaySeconds <= 0 and math.abs(fill.Size.X.Scale - safeRatio) < 0.0005 then
        fill.Size = target
        fill.Visible = safeRatio > 0
        return
    end

    fill.Visible = true
    local tweenInfo = FILL_TWEEN_INFO
    if delaySeconds > 0 then
        tweenInfo = TweenInfo.new(FILL_TWEEN_INFO.Time, FILL_TWEEN_INFO.EasingStyle, FILL_TWEEN_INFO.EasingDirection, 0, false, delaySeconds)
    end
    local tween = self:_playMotion(fill, tweenInfo, { Size = target })
    tween.Completed:Connect(function(playbackState)
        if playbackState == Enum.PlaybackState.Completed and fill.Parent then
            fill.Visible = safeRatio > 0
        end
    end)
end

function TaskController:_popNode(node, fromScale)
    local popScale = node and node:FindFirstChild("PopScale")
    if not (self._isOpen and popScale and popScale:IsA("UIScale")) then
        return
    end
    popScale.Scale = fromScale
    self:_playMotion(popScale, POP_TWEEN_INFO, { Scale = 1 })
end

function TaskController:_flashRow(row)
    local flash = row and row:FindFirstChild("ClaimFlash")
    if not (self._isOpen and flash and flash:IsA("GuiObject")) then
        return
    end
    flash.BackgroundTransparency = 0.3
    self:_playMotion(flash, FLASH_TWEEN_INFO, { BackgroundTransparency = 1 })
end

function TaskController:_playDetailPop()
    local popScale = self._taskDetailRoot and self._taskDetailRoot:FindFirstChild("PopScale")
    if not (self._isOpen and popScale and popScale:IsA("UIScale")) then
        return
    end
    popScale.Scale = DETAIL_POP_FROM_SCALE
    self:_playMotion(popScale, DETAIL_POP_TWEEN_INFO, { Scale = 1 })
end

-- Rows pop in top to bottom and their progress bars fill after them.
function TaskController:_playRowEntrance()
    if not (self._isOpen and self._scrollingFrame) then
        return
    end

    local rows = {}
    for _, entry in pairs(self._rowEntriesByTaskId) do
        if entry.row.Parent == self._scrollingFrame then
            table.insert(rows, entry.row)
        end
    end
    table.sort(rows, function(left, right)
        return left.LayoutOrder < right.LayoutOrder
    end)

    for index, row in ipairs(rows) do
        local delayTime = math.min(index - 1, ROW_ENTRANCE_MAX_STAGGER_ROWS) * ROW_ENTRANCE_STAGGER_SECONDS
        local uiScale = ensureUiScale(row)
        if uiScale then
            uiScale.Scale = ROW_ENTRANCE_FROM_SCALE
            self:_playMotion(uiScale, TweenInfo.new(
                ROW_ENTRANCE_DURATION,
                Enum.EasingStyle.Back,
                Enum.EasingDirection.Out,
                0,
                false,
                delayTime
            ), { Scale = 1 })
        end
        local fill = findNested(row, "ProgressTrack/Fill")
        if fill then
            self:_setFillRatio(fill, fill:GetAttribute("TaskTargetRatio"), true, true, delayTime + 0.1)
        end
    end
end

function TaskController:_playAmbientTween(key, target, tweenInfo, goal)
    local current = self._ambientTweens[key]
    if current then
        current:Cancel()
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    self._ambientTweens[key] = tween
    tween:Play()
    return tween
end

function TaskController:_stopAmbientEffects()
    self._ambientSerial += 1
    self._ambientSignature = ""
    for _, tween in pairs(self._ambientTweens) do
        tween:Cancel()
    end
    table.clear(self._ambientTweens)
    for _, restore in ipairs(self._ambientRestores) do
        restore()
    end
    table.clear(self._ambientRestores)
end

function TaskController:_startShineLoop(key, shine, fromPosition, toPosition)
    local serial = self._ambientSerial
    shine.Position = fromPosition
    shine.Visible = true
    table.insert(self._ambientRestores, function()
        if shine.Parent then
            shine.Visible = false
            shine.Position = fromPosition
        end
    end)
    task.spawn(function()
        while self._ambientSerial == serial and shine.Parent do
            shine.Position = fromPosition
            self:_playAmbientTween(key, shine, TweenInfo.new(
                SHINE_SWEEP_SECONDS,
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.InOut
            ), { Position = toPosition })
            task.wait(SHINE_SWEEP_SECONDS + SHINE_GAP_SECONDS)
        end
    end)
end

-- Looping "ready" emphasis. Restarted only when the set of ready targets changes, so frequent
-- progress syncs do not reset the pulse.
function TaskController:_refreshAmbientEffects(tasks, selectedTask)
    if not (self._isOpen and self._panel and self._taskDetailRoot) then
        if self._ambientSignature ~= "" or #self._ambientRestores > 0 then
            self:_stopAmbientEffects()
        end
        return
    end

    local selectedReady = selectedTask ~= nil
        and getTaskStatus(selectedTask) == TASK_STATUS_READY
        and (tonumber(self._pendingClaimsByTaskId[selectedTask.taskId]) or 0) <= os.clock()
    local signatureParts = {
        selectedReady and ("detail:" .. tostring(selectedTask.taskId) .. ":" .. tostring(self._rewardRenderSignature)) or "detail:none",
    }
    for _, taskData in ipairs(tasks) do
        if getTaskStatus(taskData) == TASK_STATUS_READY then
            table.insert(signatureParts, "row:" .. tostring(taskData.taskId))
        end
    end
    local signature = table.concat(signatureParts, "|")
    if signature == self._ambientSignature then
        return
    end
    self:_stopAmbientEffects()
    self._ambientSignature = signature

    for _, taskData in ipairs(tasks) do
        local entry = getTaskStatus(taskData) == TASK_STATUS_READY and self._rowEntriesByTaskId[taskData.taskId] or nil
        local popScale = entry and findNested(entry.row, "ProgressText/PopScale")
        if popScale and popScale:IsA("UIScale") then
            popScale.Scale = 1
            self:_playAmbientTween("row:" .. tostring(taskData.taskId), popScale, CHIP_PULSE_TWEEN_INFO, {
                Scale = CHIP_PULSE_SCALE,
            })
            table.insert(self._ambientRestores, function()
                if popScale.Parent then
                    popScale.Scale = 1
                end
            end)
        end
    end
    if not selectedReady then
        return
    end

    local detail = self._taskDetailRoot
    local glow = detail:FindFirstChild("ClaimGlow")
    if glow and glow:IsA("GuiObject") then
        local baseSize = glow.Size
        local baseTransparency = glow.BackgroundTransparency
        glow.Visible = true
        self:_playAmbientTween("claimGlow", glow, GLOW_PULSE_TWEEN_INFO, {
            Size = UDim2.new(baseSize.X.Scale * 1.08, baseSize.X.Offset, baseSize.Y.Scale * 1.3, baseSize.Y.Offset),
            BackgroundTransparency = math.min(1, baseTransparency + 0.35),
        })
        table.insert(self._ambientRestores, function()
            if glow.Parent then
                glow.Visible = false
                glow.Size = baseSize
                glow.BackgroundTransparency = baseTransparency
            end
        end)
    end

    local claimShine = findNested(detail, "ClaimButton/Shine")
    if claimShine and claimShine:IsA("GuiObject") then
        self:_startShineLoop("claimShine", claimShine, UDim2.fromScale(-0.3, 0.5), UDim2.fromScale(1.3, 0.5))
    end
    local fillShine = findNested(detail, "ProgressTrack/Fill/Shine")
    if fillShine and fillShine:IsA("GuiObject") then
        self:_startShineLoop("fillShine", fillShine, UDim2.fromScale(-0.2, 0.5), UDim2.fromScale(1.2, 0.5))
    end

    for index, rewardRow in ipairs(self._generatedRewardRows) do
        local rewardGlow = rewardRow:FindFirstChild("Glow")
        if rewardGlow and rewardGlow:IsA("GuiObject") then
            rewardGlow.Rotation = 0
            rewardGlow.Visible = true
            self:_playAmbientTween("rewardGlow:" .. tostring(index), rewardGlow, GLOW_SPIN_TWEEN_INFO, {
                Rotation = 360,
            })
            table.insert(self._ambientRestores, function()
                if rewardGlow.Parent then
                    rewardGlow.Visible = false
                    rewardGlow.Rotation = 0
                end
            end)
        end
    end
end

-- Claim/ready feedback waits until the panel is actually visible: the reward popup hides it first.
function TaskController:_flushCelebrations()
    if CinematicUiGate:IsBlocked() then
        return
    end
    if not self._isOpen then
        table.clear(self._queuedCelebrations)
        return
    end
    if not (self._panel and self._panel.Visible) or next(self._queuedCelebrations) == nil then
        return
    end

    local queued = self._queuedCelebrations
    self._queuedCelebrations = {}
    local selectedTaskId = self._selectedTaskIdByPeriod[self:_getSelectedPeriodKey()]
    for taskId, status in pairs(queued) do
        local entry = self._rowEntriesByTaskId[taskId]
        if entry and entry.row.Parent then
            self:_flashRow(entry.row)
            -- Ready rows already pulse this label; a pop would cancel that loop.
            if status == TASK_STATUS_CLAIMED then
                self:_popNode(entry.row:FindFirstChild("ProgressText"), 1.6)
            end
        end
        if taskId == selectedTaskId and self._taskDetailRoot then
            self:_popNode(self._taskDetailRoot:FindFirstChild("StatusText"), 1.4)
            if status == TASK_STATUS_CLAIMED then
                self:_popNode(self._taskDetailRoot:FindFirstChild("Complete"), CLAIM_STAMP_FROM_SCALE)
            end
        end
    end
end

function TaskController:_scheduleCelebrationFlush()
    if next(self._queuedCelebrations) == nil then
        return
    end
    task.delay(CELEBRATION_SETTLE_SECONDS, function()
        self:_flushCelebrations()
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

function TaskController:_getSelectedPeriodKey()
    return self._selectedPeriod == "weekly" and "weekly" or "daily"
end

function TaskController:_getTasksForSelectedPeriod()
    local state = self:_getState()
    local key = self:_getSelectedPeriodKey()
    local tasks = cloneTasks(state.tasks and state.tasks[key])
    sortTasksForDisplay(tasks)
    return tasks
end

function TaskController:_resolveSelectedTask(tasks)
    local periodKey = self:_getSelectedPeriodKey()
    local selectedTaskId = math.max(0, math.floor(tonumber(self._selectedTaskIdByPeriod[periodKey]) or 0))
    if selectedTaskId > 0 then
        for _, taskData in ipairs(tasks) do
            if taskData.taskId == selectedTaskId then
                return taskData
            end
        end
    end

    local firstTask = tasks[1]
    self._selectedTaskIdByPeriod[periodKey] = firstTask and firstTask.taskId or nil
    return firstTask
end

function TaskController:_hasClaimableTask()
    local state = self:_getState()
    if state.hasClaimableReward == true then
        return true
    end
    for _, periodKey in ipairs({ "daily", "weekly" }) do
        for _, taskData in ipairs(state.tasks and state.tasks[periodKey] or {}) do
            if taskData.isClaimable == true and taskData.isClaimed ~= true then
                return true
            end
        end
    end
    return false
end

function TaskController:_renderEntryState()
    local entryVisible = isTaskEntryVisible()
    setVisible(self._entryRoot, entryVisible)
    setVisible(self._entryRedPoint, entryVisible and self:_hasClaimableTask())
    if self._entryButton then
        self._entryButton.Active = entryVisible
        self._entryButton.Selectable = entryVisible
    end
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
        setVisible(root:FindFirstChild("SelectedBg"), selected)
        setVisible(root:FindFirstChild("IdleBg"), not selected)
        applyTabButtonStyle(root, selected)
    end

    applyTab(self._dailyTabRoot, dailySelected)
    applyTab(self._weeklyTabRoot, weeklySelected)
    self:_renderTabBadge(self._dailyTabRoot, self:_countClaimableTasks("daily"))
    self:_renderTabBadge(self._weeklyTabRoot, self:_countClaimableTasks("weekly"))
    setText(findNested(self._panel, "TitleBg/Title"), dailySelected and "Daily Tasks" or "Weekly Tasks")
end

function TaskController:_countClaimableTasks(periodKey)
    local state = self:_getState()
    local count = 0
    for _, taskData in ipairs(state.tasks and state.tasks[periodKey] or {}) do
        if taskData.isClaimable == true and taskData.isClaimed ~= true then
            count += 1
        end
    end
    return count
end

function TaskController:_renderTabBadge(tabRoot, count)
    local badge = tabRoot and tabRoot:FindFirstChild("Badge")
    if not (badge and badge:IsA("GuiObject")) then
        return
    end
    local previousCount = tonumber(badge:GetAttribute("TaskBadgeCount")) or 0
    badge:SetAttribute("TaskBadgeCount", count)
    badge.Visible = count > 0
    setText(badge:FindFirstChild("Count"), count > 9 and "9+" or tostring(count))
    if count > previousCount then
        self:_popNode(badge, 1.5)
    end
end

function TaskController:_clearRows()
    self:_cancelMotionTweens()
    self:_disconnectBindings(self._rowBindings)
    for _, row in ipairs(self._generatedRows) do
        if row and row.Parent then
            row:Destroy()
        end
    end
    table.clear(self._generatedRows)
    table.clear(self._rowEntriesByTaskId)

    if self._scrollingFrame then
        for _, child in ipairs(self._scrollingFrame:GetChildren()) do
            if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
                child:Destroy()
            end
        end
    end
end

function TaskController:_clearRewardRows()
    self:_disconnectBindings(self._rewardBindings)
    self._rewardRenderSignature = nil
    for _, row in ipairs(self._generatedRewardRows) do
        if row and row.Parent then
            row:Destroy()
        end
    end
    table.clear(self._generatedRewardRows)

    if self._rewardList then
        for _, child in ipairs(self._rewardList:GetChildren()) do
            if child:GetAttribute(GENERATED_REWARD_ATTRIBUTE) == true then
                child:Destroy()
            end
        end
    end
end

function TaskController:_renderProgress(root, taskData, includeDescription)
    local progressBg = root and root:FindFirstChild("ProgressBg", true)
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

    local ratio = math.clamp((tonumber(taskData and taskData.progress) or 0) / math.max(1, tonumber(taskData and taskData.target) or 1), 0, 1)
    if progressFill and progressFill:IsA("GuiObject") then
        restoreDefaultSize(progressFill)
        if includeDescription ~= true then
            progressFill.Size = UDim2.new(ratio, 0, progressFill.Size.Y.Scale, progressFill.Size.Y.Offset)
        end
    end

    local progressText = buildProgressText(taskData)
    if includeDescription == true then
        progressText = buildTaskSubtitle(taskData) .. " (" .. progressText .. ")"
    end
    setText(progressLabel, progressText)
end

function TaskController:_renderRewardList(taskData)
    hideNamedGuiChildren(self._rewardList, "RewardTemplate")
    if not (self._rewardList and self._rewardTemplate and taskData) then
        self:_clearRewardRows()
        return
    end

    local signatureParts = {}
    for _, reward in ipairs(taskData.rewards or {}) do
        table.insert(signatureParts, table.concat({ tostring(reward.rewardType or ""), tostring(reward.chestId or ""), tostring(reward.icon or ""), tostring(reward.amount or 0) }, ":"))
    end
    local signature = table.concat(signatureParts, "|")
    local rowsValid = #self._generatedRewardRows == #(taskData.rewards or {})
    for _, row in ipairs(self._generatedRewardRows) do
        if row.Parent ~= self._rewardList then
            rowsValid = false
            break
        end
    end
    if self._rewardRenderSignature == signature and rowsValid then
        return
    end

    self:_clearRewardRows()
    for index, reward in ipairs(taskData.rewards or {}) do
        local rewardRow = self._rewardTemplate:Clone()
        rewardRow.Name = "Reward_" .. tostring(index)
        rewardRow.Visible = true
        rewardRow.LayoutOrder = index
        rewardRow:SetAttribute(GENERATED_REWARD_ATTRIBUTE, true)
        rewardRow.Parent = self._rewardList
        table.insert(self._generatedRewardRows, rewardRow)

        local icon = rewardRow:FindFirstChild("Rewardicon", true)
            or rewardRow:FindFirstChild("RewardIcon", true)
            or rewardRow:FindFirstChild("Icon", true)
        local amountLabel = rewardRow:FindFirstChild("RewardNum", true)
            or rewardRow:FindFirstChild("Num", true)
            or rewardRow:FindFirstChild("Number", true)
        setImage(icon, reward.icon)
        setText(amountLabel, "x" .. formatCompactInteger(reward.amount))
        if reward.rewardType == "Chest" then
            local button = resolveClickTarget(rewardRow, "RewardChestClickTarget")
            self:_bindButton(button, function()
                if self._navigationController then self._navigationController:Navigate("Tasks", "Chests") end
            end, { ScaleTarget = rewardRow }, self._rewardBindings)
        end
    end
    self._rewardRenderSignature = signature
end

function TaskController:_bindDetailClaimButton(taskData)
    local claimButton, claimRoot = findButtonByName(self._taskDetailRoot, "ClaimButton")
    local completeRoot = self._taskDetailRoot and self._taskDetailRoot:FindFirstChild("Complete", true)
    if not taskData then
        self:_disconnectBindings(self._detailBindings)
        self._detailClaimSignature = nil
        self._detailClaimButton = nil
        setVisible(claimRoot or claimButton, false)
        setVisible(completeRoot, false)
        return
    end

    local isPending = (tonumber(self._pendingClaimsByTaskId[taskData.taskId]) or 0) > os.clock()
    local canClaim = taskData.isClaimable == true and taskData.isClaimed ~= true and not isPending and self._requestClaimEvent ~= nil

    setVisible(claimRoot or claimButton, taskData.isClaimed ~= true)
    setVisible(completeRoot, taskData.isClaimed == true)
    setButtonText(claimRoot or claimButton, isPending and "Claiming" or "Claim")
    tintGuiTree(claimRoot or claimButton, not isPending)

    local signature = table.concat({
        tostring(taskData.taskId),
        tostring(canClaim),
        tostring(isPending),
        tostring(taskData.isClaimed == true),
    }, ":")
    if self._detailClaimSignature == signature and self._detailClaimButton == claimButton then
        return
    end
    self:_disconnectBindings(self._detailBindings)
    self._detailClaimSignature = signature
    self._detailClaimButton = claimButton

    if claimButton then
        self:_bindButton(claimButton, function()
            if not canClaim then
                return
            end
            self._pendingClaimsByTaskId[taskData.taskId] = os.clock() + CLAIM_PENDING_SECONDS
            self:_renderAll()
            if self._requestClaimEvent then
                self._requestClaimEvent:FireServer({
                    taskId = taskData.taskId,
                })
            end
            task.delay(CLAIM_PENDING_SECONDS, function()
                if (tonumber(self._pendingClaimsByTaskId[taskData.taskId]) or 0) <= os.clock() then
                    self._pendingClaimsByTaskId[taskData.taskId] = nil
                    self:_renderAll()
                end
            end)
        end, {
            ScaleTarget = claimRoot or claimButton,
        }, self._detailBindings)
        setButtonEnabled(claimButton, not isPending)
    end
end

function TaskController:_applyRowSelectedState(row, selected, status)
    setVisible(row and row:FindFirstChild("SelectedBg"), selected == true)
    setVisible(row and row:FindFirstChild("IdleBg"), selected ~= true)
    if row and row:IsA("GuiObject") then
        if status == TASK_STATUS_CLAIMED then
            row.BackgroundColor3 = CLAIMED_ROW_BACKGROUND_COLOR
        else
            row.BackgroundColor3 = selected == true and SELECTED_ROW_BACKGROUND_COLOR or IDLE_ROW_BACKGROUND_COLOR
        end
    end
    local stroke = row and (row:FindFirstChild("SelectionStroke") or row:FindFirstChildOfClass("UIStroke"))
    if stroke and stroke:IsA("UIStroke") then
        stroke.Enabled = true
        stroke.Color = selected == true and SELECTED_ROW_STROKE_COLOR or IDLE_ROW_STROKE_COLOR
    end
    local muted = status == TASK_STATUS_CLAIMED
    setMutedTextColor(row and row:FindFirstChild("TaskTitle"), muted)
    setMutedTextColor(row and row:FindFirstChild("TaskSubtitle"), muted)
end

-- Optional V6.16 row nodes: ProgressTrack/Fill mini bar and ProgressText status.
function TaskController:_renderRowProgress(row, taskData, status, isNewRow)
    local style = STATUS_STYLES[status]
    local fill = findNested(row, "ProgressTrack/Fill")
    if fill and fill:IsA("GuiObject") then
        fill.BackgroundColor3 = style.Fill
        self:_setFillRatio(fill, getRowProgressRatio(taskData, status), true, isNewRow == true)
    end

    local progressLabel = row:FindFirstChild("ProgressText")
    if progressLabel and progressLabel:IsA("TextLabel") then
        if status == TASK_STATUS_READY then
            progressLabel.Text = "Ready!"
        elseif status == TASK_STATUS_CLAIMED then
            progressLabel.Text = "Done"
        else
            progressLabel.Text = buildProgressText(taskData)
        end
        progressLabel.TextColor3 = style.RowText
    end
end

function TaskController:_renderRows(tasks, selectedTask)
    if not (self._scrollingFrame and self._template) then
        return
    end

    self._template.Visible = false

    local wantedTaskIds = {}
    local periodKey = self:_getSelectedPeriodKey()
    for _, taskData in ipairs(tasks) do
        wantedTaskIds[taskData.taskId] = true
    end
    for taskId, entry in pairs(self._rowEntriesByTaskId) do
        if not wantedTaskIds[taskId] or entry.period ~= periodKey or entry.row.Parent ~= self._scrollingFrame then
            if entry.binding then
                self:_disconnectBindings({ entry.binding })
                local bindingIndex = table.find(self._rowBindings, entry.binding)
                if bindingIndex then
                    table.remove(self._rowBindings, bindingIndex)
                end
            end
            local rowIndex = table.find(self._generatedRows, entry.row)
            if rowIndex then
                table.remove(self._generatedRows, rowIndex)
            end
            entry.row:Destroy()
            self._rowEntriesByTaskId[taskId] = nil
        end
    end

    local selectedTaskId = selectedTask and selectedTask.taskId or 0
    for index, taskData in ipairs(tasks) do
        local entry = self._rowEntriesByTaskId[taskData.taskId]
        local isNewRow = entry == nil
        if not entry then
            local row = self._template:Clone()
            row.Name = "Task_" .. tostring(taskData.taskId)
            row.Visible = true
            row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
            row.Parent = self._scrollingFrame
            table.insert(self._generatedRows, row)
            entry = { row = row, period = periodKey, taskId = taskData.taskId }
            self._rowEntriesByTaskId[taskData.taskId] = entry

            local clickTarget = resolveClickTarget(row, "TaskRowClickTarget")
            entry.binding = self:_bindButton(clickTarget, function()
                self:_selectTask(entry.taskId)
            end, {
                ScaleTarget = row,
                HoverScale = 1.02,
                PressScale = 0.98,
            }, self._rowBindings)
        end
        local row = entry.row
        row.LayoutOrder = index

        setText(row:FindFirstChild("PeriodTag", true), taskData.period == "weekly" and "Weekly" or "Daily")
        setText(row:FindFirstChild("TaskTitle", true), buildTaskTitle(taskData))
        setText(row:FindFirstChild("TaskSubtitle", true), buildTaskSubtitle(taskData))
        setVisible(row:FindFirstChild("RedPoint", true), taskData.isClaimable == true and taskData.isClaimed ~= true)
        local status = getTaskStatus(taskData)
        self:_applyRowSelectedState(row, taskData.taskId == selectedTaskId, status)
        self:_renderRowProgress(row, taskData, status, isNewRow)
    end
end

function TaskController:_renderDetail(taskData)
    if not self._taskDetailRoot then
        return
    end

    local titleLabel = self._taskDetailRoot:FindFirstChild("TaskTitle", true)
    local subtitleLabel = self._taskDetailRoot:FindFirstChild("TaskSubtitle", true)
        or self._taskDetailRoot:FindFirstChild("TaskDescription", true)
        or self._taskDetailRoot:FindFirstChild("Description", true)
    applyTaskStatus(self._taskDetailRoot:FindFirstChild("StatusText", true), taskData)
    setText(subtitleLabel, taskData and buildTaskSubtitle(taskData) or "")

    local renderedTaskId = taskData and taskData.taskId or nil
    local changedTask = self._detailRenderedTaskId ~= renderedTaskId
    self._detailRenderedTaskId = renderedTaskId
    local progressFill = findNested(self._taskDetailRoot, "ProgressTrack/Fill")
    if progressFill and progressFill:IsA("GuiObject") then
        local status = getTaskStatus(taskData)
        local ratio = taskData and getRowProgressRatio(taskData, status) or 0
        if taskData then
            progressFill.BackgroundColor3 = STATUS_STYLES[status].Fill
        end
        -- A newly selected task fills from empty; progress on the same task grows from its current width.
        self:_setFillRatio(progressFill, ratio, taskData ~= nil, changedTask)
        setText(findNested(self._taskDetailRoot, "ProgressTrack/Percent"), taskData and (tostring(math.floor(ratio * 100)) .. "%") or "")
    end
    if changedTask and taskData then
        self:_playDetailPop()
    end

    local progressBg = self._taskDetailRoot:FindFirstChild("ProgressBg", true)
    setVisible(progressBg, taskData ~= nil)
    if not taskData then
        setText(titleLabel, "")
        local progressLabel = progressBg and (
            progressBg:FindFirstChild("Num")
            or progressBg:FindFirstChild("Number")
            or progressBg:FindFirstChild("Label")
        )
        setText(progressLabel, "")
        self:_renderRewardList(nil)
        self:_bindDetailClaimButton(nil)
        return
    end

    setText(titleLabel, buildTaskTitle(taskData))
    self:_renderProgress(self._taskDetailRoot, taskData, true)
    self:_renderRewardList(taskData)
    self:_bindDetailClaimButton(taskData)
end

function TaskController:_renderContent()
    local tasks = self:_getTasksForSelectedPeriod()
    local selectedTask = self:_resolveSelectedTask(tasks)
    self:_renderRows(tasks, selectedTask)
    self:_renderDetail(selectedTask)
    self:_refreshAmbientEffects(tasks, selectedTask)
end

function TaskController:_renderAll()
    self:_renderEntryState()
    self:_renderCountdown()
    self:_applyTabs()
    self:_renderContent()
end

function TaskController:_applyStatePayload(payload)
    local source = type(payload) == "table" and payload or {}
    local tasks = type(source.tasks) == "table" and source.tasks or {}
    local previousStatusByTaskId = {}
    local previousState = self._state
    for _, periodKey in ipairs({ "daily", "weekly" }) do
        for _, taskData in ipairs(previousState and previousState.tasks and previousState.tasks[periodKey] or {}) do
            previousStatusByTaskId[taskData.taskId] = getTaskStatus(taskData)
        end
    end
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
    -- Only forward transitions celebrate; the first sync and cycle resets stay quiet.
    if self._isOpen then
        for _, periodKey in ipairs({ "daily", "weekly" }) do
            for _, taskData in ipairs(self._state.tasks[periodKey]) do
                local previousStatus = previousStatusByTaskId[taskData.taskId]
                local status = getTaskStatus(taskData)
                if previousStatus and previousStatus ~= status and status ~= TASK_STATUS_PROGRESS then
                    self._queuedCelebrations[taskData.taskId] = status
                end
            end
        end
    end
    self:_renderAll()
    self:_scheduleCelebrationFlush()
end

function TaskController:_requestState()
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer()
    end
end

function TaskController:_setOpen(isOpen, immediate)
    local wasOpen = self._isOpen
    self._isOpen = isOpen == true
    if not self._panel and not self:_bindUi(true) then
        if self._isOpen then self:_queueBindRetry() end
        return
    end
    if self._isOpen then
        self:_requestState()
        self:_renderAll()
        self:_playPanelOpen(immediate)
        if not wasOpen and immediate ~= true then
            self:_playRowEntrance()
        end
    else
        table.clear(self._queuedCelebrations)
        self:_stopAmbientEffects()
        self:_cancelMotionTweens()
        self:_playPanelClose(immediate)
    end
end

function TaskController:_setNavigationOpen(isOpen, immediate)
    self:_setOpen(isOpen, immediate)
end

function TaskController:_captureNavigationState()
    return {
        period = self._selectedPeriod,
        selected = table.clone(self._selectedTaskIdByPeriod),
        canvasPosition = self._scrollingFrame and self._scrollingFrame.CanvasPosition,
    }
end

function TaskController:_restoreNavigationState(context)
    self._selectedPeriod = context.period == "weekly" and "weekly" or "daily"
    self._selectedTaskIdByPeriod = table.clone(context.selected or {})
    self:_renderAll()
    if self._scrollingFrame and context.canvasPosition then self._scrollingFrame.CanvasPosition = context.canvasPosition end
end

function TaskController:Open()
    if self._navigationController then
        self._navigationController:Open("Tasks")
        return
    end
    self:_setOpen(true, false)
end

function TaskController:Close()
    if self._navigationController and self._navigationController:Close("Tasks") then return end
    self:_setOpen(false, false)
end

function TaskController:_selectPeriod(period)
    local normalized = tostring(period or "")
    local previousPeriod = self._selectedPeriod
    self._selectedPeriod = normalized == "weekly" and "weekly" or "daily"
    self:_renderAll()
    if previousPeriod ~= self._selectedPeriod then
        self:_playRowEntrance()
    end
end

function TaskController:_selectTask(taskId)
    local normalizedTaskId = math.max(0, math.floor(tonumber(taskId) or 0))
    if normalizedTaskId <= 0 then
        return
    end
    self._selectedTaskIdByPeriod[self:_getSelectedPeriodKey()] = normalizedTaskId
    self:_renderContent()
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
                warn("[TaskController] Could not find PlayerGui/Main/TaskBgNew UI; waiting.")
            end
            task.wait(BIND_RETRY_SECONDS)
        end
    end)
end

function TaskController:_bindUi(silent)
    self:_disconnectBindings(self._buttonBindings)
    self:_disconnectBindings(self._detailBindings)
    disconnectAll(self._panelConnections)
    self:_stopAmbientEffects()
    self._detailClaimSignature = nil
    self._detailClaimButton = nil
    self._detailRenderedTaskId = nil
    self:_clearRows()
    self:_clearRewardRows()

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
    self:_renderEntryState()

    self._panel = self._mainGui:FindFirstChild("TaskBgNew")
    self._tabsRoot = self._panel and self._panel:FindFirstChild("Tabs")
    self._dailyTabRoot = self._tabsRoot and self._tabsRoot:FindFirstChild("DailyTab")
    self._weeklyTabRoot = self._tabsRoot and self._tabsRoot:FindFirstChild("WeeklyTab")
    self._countdownLabel = self._panel and (
        self._panel:FindFirstChild("CountdownTime")
        or findNested(self._panel, "TitleBg/CountdownTime")
        or self._panel:FindFirstChild("CountdownTime", true)
    )
    self._closeButton = self._panel and resolveClickTarget(findNested(self._panel, "TitleBg/CloseButton"), "TaskCloseClickTarget")

    self._taskListRoot = self._panel and (
        findNested(self._panel, "Content/TaskList")
        or self._panel:FindFirstChild("TaskList", true)
    )
    self._scrollingFrame = self._taskListRoot and (
        findNested(self._taskListRoot, "ScrollingFrame")
        or self._taskListRoot:FindFirstChild("ScrollingFrame", true)
    )
    self._template = self._scrollingFrame and self._scrollingFrame:FindFirstChild("Template")

    self._taskDetailRoot = self._panel and (
        findNested(self._panel, "Content/TaskDetail")
        or self._panel:FindFirstChild("TaskDetail", true)
    )
    self._rewardList = self._taskDetailRoot and (
        findNested(self._taskDetailRoot, "RewardList")
        or self._taskDetailRoot:FindFirstChild("RewardList", true)
    )
    self._rewardTemplate = self._rewardList and self._rewardList:FindFirstChild("RewardTemplate")

    if not (self._entryRoot and self._panel and self._scrollingFrame and self._template and self._taskDetailRoot and self._rewardTemplate) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._panel.Visible = self._isOpen == true
    ensureUiScale(self._panel)
    self._template.Visible = false
    hideNamedGuiChildren(self._rewardList, "RewardTemplate")
    local panel = self._panel
    table.insert(self._panelConnections, panel:GetPropertyChangedSignal("Visible"):Connect(function()
        if panel.Visible and next(self._queuedCelebrations) ~= nil then
            self:_scheduleCelebrationFlush()
        end
    end))

    self:_bindButton(self._entryButton, function()
        if isTaskEntryVisible() then
            self:Open()
        end
    end, {
        ScaleTarget = self._entryRoot,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = 0.92,
    })

    if self._closeButton then
        self:_bindButton(self._closeButton, function()
            self:Close()
        end, {
            RotationTarget = self._closeButton,
            HoverRotation = HOVER_ROTATION,
        })
    end

    local dailyTabButton = resolveClickTarget(self._dailyTabRoot, "DailyTabClickTarget")
    local weeklyTabButton = resolveClickTarget(self._weeklyTabRoot, "WeeklyTabClickTarget")
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
    self._navigationController = dependencies and dependencies.TaskChestNavigationController or nil
    self._state = self:_newDefaultState()
    self._selectedPeriod = "daily"
    self._selectedTaskIdByPeriod = {}
    self._isOpen = false
    self._pendingClaimsByTaskId = {}
    self._detailClaimSignature = nil
    self._detailClaimButton = nil
    self._queuedCelebrations = {}

    disconnectAll(self._connections)
    table.insert(self._connections, CinematicUiGate:Subscribe(function(blocked)
        if blocked then
            self:_stopAmbientEffects()
        else
            self:_scheduleCelebrationFlush()
        end
    end))
    disconnectAll(self._panelConnections)
    self:_stopAmbientEffects()
    self:_disconnectBindings(self._buttonBindings)
    self:_disconnectBindings(self._rowBindings)
    self:_disconnectBindings(self._detailBindings)
    self:_clearRows()
    self:_clearRewardRows()
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
