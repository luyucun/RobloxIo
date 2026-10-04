--[[
脚本名字: GroupRewardController
脚本文件: GroupRewardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/GroupRewardController
说明: V2.3 群组奖励客户端 UI、领取请求和 Roblox 原生加群弹窗。
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))
local CinematicUiGate = require(script.Parent:WaitForChild("CinematicUiGate"))

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
        "[GroupRewardController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local GroupRewardController = {}

GroupRewardController._localPlayer = nil
GroupRewardController._connections = {}
GroupRewardController._buttonBindings = {}
GroupRewardController._mainGui = nil
GroupRewardController._panel = nil
GroupRewardController._claimButton = nil
GroupRewardController._claimedLabel = nil
GroupRewardController._topRightEntry = nil
GroupRewardController._topRightEntryButton = nil
GroupRewardController._groupRewardPromptEvent = nil
GroupRewardController._requestGroupRewardEvent = nil
GroupRewardController._groupRewardFeedbackEvent = nil
GroupRewardController._promptGroupJoinEvent = nil
GroupRewardController._playerStateSyncEvent = nil
GroupRewardController._requestStateSyncEvent = nil
GroupRewardController._isOpen = false
GroupRewardController._isClaiming = false
GroupRewardController._isClaimed = false
GroupRewardController._bindRetryQueued = false
GroupRewardController._panelTweens = {}
GroupRewardController._panelAnimationSerial = 0

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14

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

local function getConfiguredGroupId()
    return math.floor(tonumber(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.GroupId) or 0)
end

local function isJoinedStatus(status)
    return status == Enum.GroupMembershipStatus.AlreadyMember
        or status == Enum.GroupMembershipStatus.Joined
end

local function hasCurrentGroupReward(groupRewards)
    if type(groupRewards) ~= "table" then
        return false
    end

    local groupId = getConfiguredGroupId()
    if groupId <= 0 then
        return false
    end

    return groupRewards[tostring(groupId)] == true or groupRewards[groupId] == true
end

local function playTween(binding, tweenKey, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existingTween = binding.tweens[tweenKey]
    if existingTween then
        existingTween:Cancel()
        binding.tweens[tweenKey] = nil
    end

    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[tweenKey] = tween
    tween.Completed:Connect(function()
        if binding.tweens[tweenKey] == tween then
            binding.tweens[tweenKey] = nil
        end
    end)
    tween:Play()
end

function GroupRewardController:_applyButtonState(binding)
    local scale = binding.baseScale
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * PRESS_SCALE
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * HOVER_SCALE
        tweenInfo = HOVER_TWEEN_INFO
    end

    playTween(binding, "scale", binding.uiScale, tweenInfo, {
        Scale = scale,
    })
end

function GroupRewardController:_bindButton(button, onActivated, scaleTarget)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local resolvedScaleTarget = (scaleTarget and scaleTarget:IsA("GuiObject")) and scaleTarget or button
    local uiScale = ensureUiScale(resolvedScaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        baseScale = uiScale.Scale,
        isHovered = false,
        isPressed = false,
        tweens = {},
        connections = {},
    }

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.Activated:Connect(function()
        onActivated()
    end))

    table.insert(self._buttonBindings, binding)
end

function GroupRewardController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
        end
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale
        end
    end
    table.clear(self._buttonBindings)
end

function GroupRewardController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function GroupRewardController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function GroupRewardController:_applyClaimState()
    if self._claimButton and self._claimButton:IsA("GuiObject") then
        self._claimButton.Visible = self._isClaimed ~= true
        if self._claimButton:IsA("GuiButton") then
            self._claimButton.Active = self._isClaimed ~= true and self._isClaiming ~= true
        end
    end

    if self._claimedLabel and self._claimedLabel:IsA("GuiObject") then
        self._claimedLabel.Visible = self._isClaimed == true
    end
end

function GroupRewardController:_applyTopRightEntryState()
    if self._topRightEntry and self._topRightEntry:IsA("GuiObject") then
        local shouldShow = self._isClaimed ~= true
        self._topRightEntry.Visible = shouldShow
        ModalUiController:SetRestoredVisible(self._topRightEntry, shouldShow)
    end
end

function GroupRewardController:_openPanelFromEntry()
    if not (self._panel and self._panel.Parent) then
        if not self:_bindUi(true) then
            self:_queueBindRetry()
            return
        end
    end

    self:_applyClaimState()
    self:_applyTopRightEntryState()
    self:_setOpen(true)
end

function GroupRewardController:_setOpen(isOpen, immediate)
    if not self._panel then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:PlayPanelClose("GroupReward", nil, { Immediate = true })
        end
        return
    end

    self._isOpen = isOpen == true
    if self._isOpen then
        self:_applyClaimState()
        ModalUiController:PlayPanelOpen("GroupReward", self._panel, {
            Immediate = immediate == true,
        })
        return
    end

    ModalUiController:PlayPanelClose("GroupReward", self._panel, {
        Immediate = immediate == true,
    })
end

function GroupRewardController:_requestClaim()
    if not self._requestGroupRewardEvent then
        return
    end
    self._isClaiming = true
    self:_applyClaimState()
    self._requestGroupRewardEvent:FireServer()
end

function GroupRewardController:_checkMembershipAndClaim()
    local groupId = getConfiguredGroupId()
    if groupId <= 0 or not self._localPlayer then
        return
    end

    self._isClaiming = true
    self:_applyClaimState()
    task.spawn(function()
        local success, isInGroup = pcall(function()
            return self._localPlayer:IsInGroupAsync(groupId)
        end)

        if success and isInGroup == true then
            self:_requestClaim()
            return
        end

        self:_promptJoinGroup()
    end)
end

function GroupRewardController:_promptJoinGroup()
    local groupId = getConfiguredGroupId()
    if groupId <= 0 then
        self._isClaiming = false
        self:_applyClaimState()
        return
    end

    task.spawn(function()
        local success, status = pcall(function()
            return GroupService:PromptJoinAsync(groupId)
        end)

        if success and isJoinedStatus(status) then
            self:_requestClaim()
            return
        end

        self._isClaiming = false
        self:_applyClaimState()
    end)
end

function GroupRewardController:_promptJoinGroupOnly()
    local groupId = getConfiguredGroupId()
    if groupId <= 0 then
        return
    end

    task.spawn(function()
        pcall(function()
            GroupService:PromptJoinAsync(groupId)
        end)
    end)
end

function GroupRewardController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    local eventType = tostring(payload.eventType or "")
    if eventType == "Success" or eventType == "AlreadyClaimed" then
        self._isClaimed = true
        self._isClaiming = false
        self:_applyClaimState()
        self:_applyTopRightEntryState()
    elseif eventType == "NotInGroup" then
        self:_promptJoinGroup()
    else
        self._isClaiming = false
        self:_applyClaimState()
    end
end

function GroupRewardController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[GroupRewardController] 找不到 PlayerGui/Main/GroupReward，群组奖励界面暂不可用。")
    end)
end

function GroupRewardController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("GroupReward") or nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self._claimButton = self._panel:FindFirstChild("Claim")
    self._claimedLabel = self._panel:FindFirstChild("Claimed")
    local topRightGui = mainGui:FindFirstChild("TopRightGui")
    self._topRightEntry = topRightGui and topRightGui:FindFirstChild("GroupReward") or nil
    if not (self._topRightEntry and self._topRightEntry:IsA("GuiObject")) then
        self._topRightEntry = nil
        self._topRightEntryButton = nil
    else
        self._topRightEntryButton = self._topRightEntry:FindFirstChild("Button", true)
        if not (self._topRightEntryButton and self._topRightEntryButton:IsA("GuiButton")) then
            self._topRightEntryButton = nil
        end
    end

    self:_setOpen(false, true)
    self:_applyClaimState()
    self:_applyTopRightEntryState()

    local closeButton = self._panel:FindFirstChild("CloseButton", true)
    self:_bindButton(closeButton, function()
        self:_setOpen(false)
    end)

    self:_bindButton(self._claimButton, function()
        if self._isClaimed or self._isClaiming then
            return
        end
        self:_checkMembershipAndClaim()
    end)

    self:_bindButton(self._topRightEntryButton, function()
        self:_openPanelFromEntry()
    end, self._topRightEntry)

    return true
end

function GroupRewardController:_handlePlayerState(payload)
    if type(payload) ~= "table" or type(payload.groupRewards) ~= "table" then
        self:_applyTopRightEntryState()
        return
    end

    self._isClaimed = hasCurrentGroupReward(payload.groupRewards)
    self:_applyClaimState()
    self:_applyTopRightEntryState()
end

function GroupRewardController:Init(dependencies)
    self._presentationGeneration = (self._presentationGeneration or 0) + 1
    local generation = self._presentationGeneration
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self._isClaiming = false
    self._isClaimed = false

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._groupRewardPromptEvent = systemEventsFolder:WaitForChild(RemoteNames.System.GroupRewardPrompt)
    self._requestGroupRewardEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestGroupReward)
    self._groupRewardFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.GroupRewardFeedback)
    self._promptGroupJoinEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PromptGroupJoin)
    self._playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    self._requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)

    self:_bindUi(false)

    table.insert(self._connections, self._groupRewardPromptEvent.OnClientEvent:Connect(function(payload)
        if type(payload) == "table" then
            self._isClaimed = payload.claimed == true
            self:_applyClaimState()
            self:_applyTopRightEntryState()
        end
        CinematicUiGate:Defer("GroupRewardPrompt", function()
            if self._presentationGeneration ~= generation or self._isClaimed then
                return
            end
            if self:_bindUi(true) then
                self:_setOpen(true)
            else
                self:_queueBindRetry()
            end
        end)
    end))

    table.insert(self._connections, self._groupRewardFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleFeedback(payload)
    end))

    table.insert(self._connections, self._promptGroupJoinEvent.OnClientEvent:Connect(function()
        self:_promptJoinGroupOnly()
    end))

    table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self:_handlePlayerState(payload)
    end))

    if self._requestStateSyncEvent and self._requestStateSyncEvent:IsA("RemoteEvent") then
        self._requestStateSyncEvent:FireServer()
    end
end

return GroupRewardController
