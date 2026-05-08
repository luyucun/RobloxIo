--[[
脚本名字: GroupRewardController
脚本文件: GroupRewardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/GroupRewardController
说明: V2.3 群组奖励客户端 UI、领取请求和 Roblox 原生加群弹窗。
]]

local GroupService = game:GetService("GroupService")
local Lighting = game:GetService("Lighting")
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
GroupRewardController._groupRewardPromptEvent = nil
GroupRewardController._requestGroupRewardEvent = nil
GroupRewardController._groupRewardFeedbackEvent = nil
GroupRewardController._promptGroupJoinEvent = nil
GroupRewardController._isOpen = false
GroupRewardController._isClaiming = false
GroupRewardController._isClaimed = false
GroupRewardController._bindRetryQueued = false
GroupRewardController._hiddenUiOriginalVisibleByNode = {}
GroupRewardController._blurEffect = nil
GroupRewardController._blurOriginalEnabled = nil
GroupRewardController._isModalApplied = false
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

local function findBlurEffect()
    local blur = Lighting:FindFirstChild("Blur")
    if blur and blur:IsA("BlurEffect") then
        return blur
    end
    return nil
end

local function getConfiguredGroupId()
    return math.floor(tonumber(GameConfig.GROUP_REWARD and GameConfig.GROUP_REWARD.GroupId) or 0)
end

local function isJoinedStatus(status)
    return status == Enum.GroupMembershipStatus.AlreadyMember
        or status == Enum.GroupMembershipStatus.Joined
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

function GroupRewardController:_bindButton(button, onActivated)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local uiScale = ensureUiScale(button)
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

function GroupRewardController:_applyModalUi()
    if self._isModalApplied then
        return
    end

    table.clear(self._hiddenUiOriginalVisibleByNode)
    if self._mainGui then
        for _, child in ipairs(self._mainGui:GetChildren()) do
            if child:IsA("GuiObject")
                and child ~= self._panel
                and not child:IsAncestorOf(self._panel)
                and not self._panel:IsAncestorOf(child)
            then
                self._hiddenUiOriginalVisibleByNode[child] = child.Visible
                child.Visible = false
            end
        end
    end

    self._blurEffect = findBlurEffect()
    if self._blurEffect then
        self._blurOriginalEnabled = self._blurEffect.Enabled
        self._blurEffect.Enabled = true
    else
        self._blurOriginalEnabled = nil
    end

    self._isModalApplied = true
end

function GroupRewardController:_restoreModalUi()
    if not self._isModalApplied then
        return
    end

    for guiObject, originalVisible in pairs(self._hiddenUiOriginalVisibleByNode) do
        if guiObject and guiObject.Parent and guiObject:IsA("GuiObject") then
            guiObject.Visible = originalVisible == true
        end
    end
    table.clear(self._hiddenUiOriginalVisibleByNode)

    if self._blurEffect and self._blurEffect.Parent and self._blurOriginalEnabled ~= nil then
        self._blurEffect.Enabled = self._blurOriginalEnabled == true
    end
    self._blurEffect = nil
    self._blurOriginalEnabled = nil
    self._isModalApplied = false
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

function GroupRewardController:_setOpen(isOpen, immediate)
    if not self._panel then
        if isOpen ~= true then
            self._isOpen = false
            self:_cancelPanelTweens()
            self:_restoreModalUi()
        end
        return
    end

    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isOpen = isOpen == true
    local rootScale = ensureUiScale(self._panel)
    if self._isOpen then
        self:_applyClaimState()
        self:_applyModalUi()
        self._panel.Visible = true
        if rootScale then
            rootScale.Scale = OPEN_FROM_SCALE
            local overshoot = TweenService:Create(rootScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Scale = OPEN_OVERSHOOT_SCALE,
            })
            local settle = TweenService:Create(rootScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Scale = 1,
            })
            self._panelTweens = { overshoot, settle }
            task.spawn(function()
                overshoot:Play()
                overshoot.Completed:Wait()
                if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                    return
                end

                settle:Play()
                settle.Completed:Wait()
                if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                    return
                end

                rootScale.Scale = 1
                table.clear(self._panelTweens)
            end)
        end
        return
    end

    if not rootScale or immediate == true or not self._panel.Visible then
        if rootScale then
            rootScale.Scale = 1
        end
        self._panel.Visible = false
        self:_restoreModalUi()
        return
    end

    local overshoot = TweenService:Create(rootScale, TweenInfo.new(CLOSE_OVERSHOOT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = CLOSE_OVERSHOOT_SCALE,
    })
    local shrink = TweenService:Create(rootScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { overshoot, shrink }

    task.spawn(function()
        overshoot:Play()
        overshoot.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end

        shrink:Play()
        shrink.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end

        rootScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        self:_restoreModalUi()
    end)
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
    self:_setOpen(false, true)
    self:_applyClaimState()

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

    return true
end

function GroupRewardController:Init(dependencies)
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

    self:_bindUi(false)

    table.insert(self._connections, self._groupRewardPromptEvent.OnClientEvent:Connect(function(payload)
        if type(payload) == "table" then
            self._isClaimed = payload.claimed == true
        end
        if self:_bindUi(true) then
            self:_setOpen(true)
        else
            self:_queueBindRetry()
        end
    end))

    table.insert(self._connections, self._groupRewardFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleFeedback(payload)
    end))

    table.insert(self._connections, self._promptGroupJoinEvent.OnClientEvent:Connect(function()
        self:_promptJoinGroupOnly()
    end))
end

return GroupRewardController
