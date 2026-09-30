--[[
Script: TaskController
File: TaskController.lua
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/TaskController
Purpose: V5.8 daily and weekly task UI for Main.TaskBgNew.
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

local function applyTaskStatus(label, taskData)
    if not (label and (label:IsA("TextLabel") or label:IsA("TextButton"))) then
        return
    end
    if not taskData then
        label.Text = ""
    elseif taskData.isClaimed == true then
        label.Text = "Claimed"
        label.TextColor3 = CLAIMED_TEXT_COLOR
    elseif taskData.isClaimable == true then
        label.Text = "Ready"
        label.TextColor3 = READY_TEXT_COLOR
    else
        label.Text = "In progress"
        label.TextColor3 = PROGRESS_TEXT_COLOR
    end
end

local function cloneReward(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local copied = {
        rewardType = tostring(reward.rewardType or reward.RewardType or ""),
        potionId = math.max(0, math.floor(tonumber(reward.potionId or reward.PotionId) or 0)),
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
    setText(findNested(self._panel, "TitleBg/Title"), dailySelected and "Daily Tasks" or "Weekly Tasks")
end

function TaskController:_clearRows()
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
        table.insert(signatureParts, tostring(reward.icon or "") .. ":" .. tostring(reward.amount or 0))
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

function TaskController:_applyRowSelectedState(row, selected)
    setVisible(row and row:FindFirstChild("SelectedBg"), selected == true)
    setVisible(row and row:FindFirstChild("IdleBg"), selected ~= true)
    if row and row:IsA("GuiObject") then
        row.BackgroundColor3 = selected == true and SELECTED_ROW_BACKGROUND_COLOR or IDLE_ROW_BACKGROUND_COLOR
    end
    local stroke = row and (row:FindFirstChild("SelectionStroke") or row:FindFirstChildOfClass("UIStroke"))
    if stroke and stroke:IsA("UIStroke") then
        stroke.Enabled = true
        stroke.Color = selected == true and SELECTED_ROW_STROKE_COLOR or IDLE_ROW_STROKE_COLOR
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
        self:_applyRowSelectedState(row, taskData.taskId == selectedTaskId)
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

    local progressFill = findNested(self._taskDetailRoot, "ProgressTrack/Fill")
    if progressFill and progressFill:IsA("GuiObject") then
        local ratio = taskData and math.clamp((tonumber(taskData.progress) or 0) / math.max(1, tonumber(taskData.target) or 1), 0, 1) or 0
        progressFill.Size = UDim2.new(ratio, 0, progressFill.Size.Y.Scale, progressFill.Size.Y.Offset)
        progressFill.Visible = ratio > 0
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
    self._detailClaimSignature = nil
    self._detailClaimButton = nil
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

    self:_bindButton(self._entryButton, function()
        if isTaskEntryVisible() then
            self:_setOpen(true, false)
        end
    end, {
        ScaleTarget = self._entryRoot,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = 0.92,
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
    self._state = self:_newDefaultState()
    self._selectedPeriod = "daily"
    self._selectedTaskIdByPeriod = {}
    self._isOpen = false
    self._pendingClaimsByTaskId = {}
    self._detailClaimSignature = nil
    self._detailClaimButton = nil

    disconnectAll(self._connections)
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
