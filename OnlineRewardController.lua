--[[
脚本名字: OnlineRewardController
脚本文件: OnlineRewardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/OnlineRewardController
说明: V4.3 在线奖励入口、倒计时、奖励列表、UnlockAll 购买。
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))

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
        "[OnlineRewardController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local OnlineRewardConfig = requireSharedModule("OnlineRewardConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local OnlineRewardController = {}

OnlineRewardController._localPlayer = nil
OnlineRewardController._connections = {}
OnlineRewardController._buttonBindings = {}
OnlineRewardController._rewardNodes = {}
OnlineRewardController._generatedRewardFrames = {}
OnlineRewardController._mainGui = nil
OnlineRewardController._entryRoot = nil
OnlineRewardController._entryButton = nil
OnlineRewardController._entryTimeLabel = nil
OnlineRewardController._entryRedPoint = nil
OnlineRewardController._panel = nil
OnlineRewardController._rewardListRoot = nil
OnlineRewardController._rewardTemplate = nil
OnlineRewardController._unlockAllRoot = nil
OnlineRewardController._unlockAllButton = nil
OnlineRewardController._unlockAllPriceLabel = nil
OnlineRewardController._requestStateSyncEvent = nil
OnlineRewardController._stateSyncEvent = nil
OnlineRewardController._requestClaimEvent = nil
OnlineRewardController._state = nil
OnlineRewardController._clockConnection = nil
OnlineRewardController._redPointShakeThread = nil
OnlineRewardController._redPointShakeToken = 0
OnlineRewardController._bindRetryQueued = false
OnlineRewardController._pendingClaimIndex = 0
OnlineRewardController._pendingClaimDeadline = 0
OnlineRewardController._isPromptingUnlockAll = false
OnlineRewardController._activePromptProductId = 0

local MODAL_OWNER_ID = "OnlineReward"
local HOVER_SCALE = 1.05
local ENTRY_HOVER_SCALE = 1.1
local PRESS_SCALE = 0.92
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_PENDING_SECONDS = 1.2

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
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
    for part in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(part)
    end
    return current
end

local function resolveButton(root)
    if not root then
        return nil
    end
    if root:IsA("GuiButton") then
        return root
    end
    return root:FindFirstChildWhichIsA("GuiButton", true)
end

local function formatRemaining(seconds)
    local safeSeconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    if safeSeconds >= 3600 then
        return string.format("%d:%02d", math.floor(safeSeconds / 3600), math.floor((safeSeconds % 3600) / 60))
    end
    return string.format("%d:%02d", math.floor(safeSeconds / 60), safeSeconds % 60)
end

local function formatRobuxPrice(value)
    local price = tonumber(value)
    if not price then
        return nil
    end
    return tostring(math.max(0, math.floor(price + 0.5)))
end

local function buildDefaultRewards()
    local rewards = {}
    for _, reward in ipairs(OnlineRewardConfig.GetRewards()) do
        rewards[reward.RewardIndex] = {
            rewardIndex = reward.RewardIndex,
            id = reward.Id,
            rewardType = reward.RewardType,
            potionId = reward.PotionId,
            amount = reward.Amount,
            durationSeconds = reward.DurationSeconds,
            requiredSeconds = reward.RequiredSeconds,
            icon = reward.Icon,
            label = reward.Label,
            isClaimed = false,
            isClaimable = false,
        }
    end
    return rewards
end

function OnlineRewardController:_newDefaultState()
    return {
        rewards = buildDefaultRewards(),
        elapsedSecondsAtSync = 0,
        localSyncClock = os.clock(),
        productId = math.max(0, math.floor(tonumber(OnlineRewardConfig.DeveloperProductId) or 0)),
        canUnlockAll = false,
        hasClaimableReward = false,
    }
end

function OnlineRewardController:_playTween(binding, key, target, tweenInfo, goal)
    if not target then
        return
    end
    local currentTween = binding.tweens[key]
    if currentTween then
        currentTween:Cancel()
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[key] = tween
    tween:Play()
end

function OnlineRewardController:_applyButtonState(binding)
    local scale = binding.baseScale
    local rotation = binding.baseRotation
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * binding.pressScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * binding.hoverScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = HOVER_TWEEN_INFO
    end
    self:_playTween(binding, "scale", binding.uiScale, tweenInfo, { Scale = scale })
    if binding.rotationTarget then
        self:_playTween(binding, "rotation", binding.rotationTarget, tweenInfo, { Rotation = rotation })
    end
end

function OnlineRewardController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

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
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    table.insert(self._buttonBindings, binding)
end

function OnlineRewardController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens or {}) do
            tween:Cancel()
        end
    end
    table.clear(self._buttonBindings)
end

function OnlineRewardController:_getElapsedSeconds()
    local state = self._state or self:_newDefaultState()
    local baseElapsed = math.max(0, math.floor(tonumber(state.elapsedSecondsAtSync) or 0))
    local localSyncClock = tonumber(state.localSyncClock) or os.clock()
    return baseElapsed + math.max(0, math.floor(os.clock() - localSyncClock))
end

function OnlineRewardController:_getRewardRenderState(reward, elapsedSeconds)
    local requiredSeconds = math.max(0, math.floor(tonumber(reward and reward.requiredSeconds) or 0))
    local isClaimed = reward and reward.isClaimed == true
    local remainingSeconds = math.max(0, requiredSeconds - elapsedSeconds)
    local isClaimable = not isClaimed and remainingSeconds <= 0
    local isPending = reward and self._pendingClaimIndex == reward.rewardIndex and os.clock() < self._pendingClaimDeadline
    return {
        remainingSeconds = remainingSeconds,
        isClaimed = isClaimed,
        isClaimable = isClaimable,
        isPending = isPending,
    }
end

function OnlineRewardController:_startRedPointShakeLoop()
    if self._redPointShakeThread then
        return
    end

    self._redPointShakeToken += 1
    local token = self._redPointShakeToken
    self._redPointShakeThread = task.spawn(function()
        local baseRotation = self._entryRedPoint and self._entryRedPoint.Rotation or 0
        while token == self._redPointShakeToken do
            if self._entryRedPoint and self._entryRedPoint.Parent and self._entryRedPoint.Visible == true then
                local leftTween = TweenService:Create(self._entryRedPoint, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
                    Rotation = baseRotation - 12,
                })
                local rightTween = TweenService:Create(self._entryRedPoint, TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Rotation = baseRotation + 12,
                })
                local resetTween = TweenService:Create(self._entryRedPoint, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
                    Rotation = baseRotation,
                })
                leftTween:Play()
                leftTween.Completed:Wait()
                rightTween:Play()
                rightTween.Completed:Wait()
                resetTween:Play()
                resetTween.Completed:Wait()
            end
            task.wait(2)
        end
        self._redPointShakeThread = nil
    end)
end

function OnlineRewardController:_stopRedPointShakeLoop()
    self._redPointShakeToken += 1
    if self._entryRedPoint then
        self._entryRedPoint.Rotation = 0
    end
end

function OnlineRewardController:_renderEntryState()
    local elapsedSeconds = self:_getElapsedSeconds()
    local hasClaimableReward = false
    local hasUnclaimedReward = false
    local nextRemainingSeconds = nil

    for _, reward in ipairs((self._state and self._state.rewards) or {}) do
        local renderState = self:_getRewardRenderState(reward, elapsedSeconds)
        if not renderState.isClaimed then
            hasUnclaimedReward = true
            if renderState.isClaimable then
                hasClaimableReward = true
                break
            end
            if nextRemainingSeconds == nil or renderState.remainingSeconds < nextRemainingSeconds then
                nextRemainingSeconds = renderState.remainingSeconds
            end
        end
    end

    setVisible(self._entryRedPoint, hasClaimableReward)
    if hasClaimableReward then
        self:_startRedPointShakeLoop()
    else
        self:_stopRedPointShakeLoop()
    end

    if hasClaimableReward then
        setText(self._entryTimeLabel, OnlineRewardConfig.ReadyText or "Ready!")
    elseif hasUnclaimedReward then
        setText(self._entryTimeLabel, formatRemaining(nextRemainingSeconds or 0))
    else
        setText(self._entryTimeLabel, OnlineRewardConfig.DoneText or "Done!")
    end
end

function OnlineRewardController:_renderRewardNode(rewardNode, reward, elapsedSeconds)
    if type(rewardNode) ~= "table" then
        return
    end
    setVisible(rewardNode.root, reward ~= nil)
    if not reward then
        return
    end

    local renderState = self:_getRewardRenderState(reward, elapsedSeconds)
    local canClaim = renderState.isClaimable and not renderState.isPending and self._requestClaimEvent ~= nil

    setText(rewardNode.timeLabel, formatRemaining(renderState.remainingSeconds))
    setImage(rewardNode.iconLabel, reward.icon)
    setText(rewardNode.nameLabel, reward.label)
    setVisible(rewardNode.nameLabel, true)
    setVisible(rewardNode.timeLabel, not renderState.isClaimed and not renderState.isClaimable)
    setVisible(rewardNode.claimRoot, not renderState.isClaimed and renderState.isClaimable)
    setVisible(rewardNode.claimedRoot, renderState.isClaimed)

    local claimButton = rewardNode.claimButton
    if claimButton then
        claimButton.Active = canClaim
        claimButton.AutoButtonColor = canClaim
        claimButton.Selectable = canClaim
    end
end

function OnlineRewardController:_renderRewardList()
    local elapsedSeconds = self:_getElapsedSeconds()
    for rewardIndex, rewardNode in ipairs(self._rewardNodes) do
        self:_renderRewardNode(rewardNode, self._state and self._state.rewards[rewardIndex] or nil, elapsedSeconds)
    end
end

function OnlineRewardController:_renderUnlockAll()
    local canUnlockAll = self._state and self._state.canUnlockAll == true and (self._state.productId or 0) > 0
    setVisible(self._unlockAllRoot, canUnlockAll)
    if self._unlockAllButton then
        local enabled = canUnlockAll and not self._isPromptingUnlockAll
        self._unlockAllButton.Active = enabled
        self._unlockAllButton.AutoButtonColor = enabled
        self._unlockAllButton.Selectable = enabled
    end
end

function OnlineRewardController:_renderAll()
    if not self._state then
        self._state = self:_newDefaultState()
    end
    self:_renderEntryState()
    self:_renderRewardList()
    self:_renderUnlockAll()
end

function OnlineRewardController:_applyStatePayload(payload)
    local rewards = buildDefaultRewards()
    if type(payload) == "table" and type(payload.rewards) == "table" then
        for _, rewardPayload in ipairs(payload.rewards) do
            local rewardIndex = math.max(0, math.floor(tonumber(type(rewardPayload) == "table" and rewardPayload.rewardIndex or 0) or 0))
            if rewardIndex >= 1 and rewardIndex <= #rewards then
                local fallback = rewards[rewardIndex] or {}
                rewards[rewardIndex] = {
                    rewardIndex = rewardIndex,
                    id = math.max(1, math.floor(tonumber(rewardPayload.id or fallback.id or rewardIndex) or rewardIndex)),
                    rewardType = tostring(rewardPayload.rewardType or fallback.rewardType or ""),
                    potionId = math.max(0, math.floor(tonumber(rewardPayload.potionId or fallback.potionId or 0) or 0)),
                    amount = math.max(1, math.floor(tonumber(rewardPayload.amount or fallback.amount or 1) or 1)),
                    durationSeconds = math.max(0, math.floor(tonumber(rewardPayload.durationSeconds or fallback.durationSeconds or 0) or 0)),
                    requiredSeconds = math.max(0, math.floor(tonumber(rewardPayload.requiredSeconds or fallback.requiredSeconds or 0) or 0)),
                    icon = tostring(rewardPayload.icon or fallback.icon or ""),
                    label = tostring(rewardPayload.label or fallback.label or ""),
                    isClaimed = rewardPayload.isClaimed == true,
                    isClaimable = rewardPayload.isClaimable == true,
                }
            end
        end
    end

    self._state = {
        rewards = rewards,
        elapsedSecondsAtSync = math.max(0, math.floor(tonumber(type(payload) == "table" and payload.elapsedSeconds or 0) or 0)),
        localSyncClock = os.clock(),
        productId = math.max(0, math.floor(tonumber(type(payload) == "table" and payload.productId or OnlineRewardConfig.DeveloperProductId) or 0)),
        canUnlockAll = type(payload) == "table" and payload.canUnlockAll == true,
        hasClaimableReward = type(payload) == "table" and payload.hasClaimableReward == true,
    }
    self._pendingClaimIndex = 0
    self._pendingClaimDeadline = 0
    self._isPromptingUnlockAll = false
    self._activePromptProductId = 0
    self:_renderAll()
end

function OnlineRewardController:_requestState()
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer()
    end
end

function OnlineRewardController:_openPanel()
    if not self._panel and not self:_bindUi(true) then
        return
    end
    self:_requestState()
    ModalUiController:Acquire(MODAL_OWNER_ID, self._panel)
    self._panel.Visible = true
    self:_renderAll()
end

function OnlineRewardController:_closePanel()
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return
    end
    self._panel.Visible = false
    ModalUiController:Release(MODAL_OWNER_ID)
end

function OnlineRewardController:_promptUnlockAll()
    local productId = math.max(0, math.floor(tonumber(self._state and self._state.productId or OnlineRewardConfig.DeveloperProductId) or 0))
    if productId <= 0 or self._isPromptingUnlockAll then
        return
    end

    self._isPromptingUnlockAll = true
    self._activePromptProductId = productId
    self:_renderUnlockAll()
    local ok, err = pcall(function()
        MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
    end)
    if not ok then
        warn("[OnlineRewardController] 拉起在线奖励 UnlockAll 购买失败: " .. tostring(err))
        self._isPromptingUnlockAll = false
        self._activePromptProductId = 0
        self:_renderUnlockAll()
    end
end

function OnlineRewardController:_setUnlockAllPrice()
    if not self._unlockAllPriceLabel then
        return
    end
    local productId = math.max(0, math.floor(tonumber(OnlineRewardConfig.DeveloperProductId) or 0))
    if productId <= 0 then
        return
    end
    local fallbackText = tostring(self._unlockAllPriceLabel.Text or "")
    setText(self._unlockAllPriceLabel, "...")
    task.spawn(function()
        local ok, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product)
        end)
        local priceText = ok and type(productInfo) == "table" and formatRobuxPrice(productInfo.PriceInRobux) or nil
        if priceText then
            setText(self._unlockAllPriceLabel, priceText)
        elseif fallbackText ~= "" then
            setText(self._unlockAllPriceLabel, fallbackText)
        end
    end)
end

function OnlineRewardController:_clearGeneratedRewards()
    for _, frame in ipairs(self._generatedRewardFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
    end
    table.clear(self._generatedRewardFrames)
    table.clear(self._rewardNodes)
end

function OnlineRewardController:_createRewardNode(frame, rewardIndex)
    local claimRoot = frame:FindFirstChild("Claim", true)
    local claimButton = resolveButton(claimRoot)
    local rewardNode = {
        root = frame,
        iconLabel = findNested(frame, "Content/ItemIcon") or frame:FindFirstChild("ItemIcon", true),
        nameLabel = frame:FindFirstChild("Name", true),
        timeLabel = frame:FindFirstChild("Time", true),
        claimRoot = claimRoot,
        claimButton = claimButton,
        claimedRoot = frame:FindFirstChild("Claimed", true),
    }

    self:_bindButton(claimButton, function()
        if not self._requestClaimEvent then
            return
        end
        self._pendingClaimIndex = rewardIndex
        self._pendingClaimDeadline = os.clock() + CLAIM_PENDING_SECONDS
        self:_renderAll()
        self._requestClaimEvent:FireServer({ rewardIndex = rewardIndex })
    end, {
        ScaleTarget = claimRoot or claimButton,
    })
    return rewardNode
end

function OnlineRewardController:_buildRewardNodes()
    self:_clearGeneratedRewards()
    if not (self._rewardListRoot and self._rewardTemplate) then
        return
    end

    self._rewardTemplate.Visible = false
    local rewards = (self._state and self._state.rewards) or buildDefaultRewards()
    for rewardIndex = 1, #rewards do
        local frame = self._rewardTemplate:Clone()
        frame.Name = string.format("Reward%02d", rewardIndex)
        frame.LayoutOrder = rewardIndex
        frame.Visible = true
        frame.Parent = self._rewardListRoot
        table.insert(self._generatedRewardFrames, frame)
        self._rewardNodes[rewardIndex] = self:_createRewardNode(frame, rewardIndex)
    end
end

function OnlineRewardController:_bindUi(silent)
    self:_disconnectButtonBindings()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local right = self._mainGui:FindFirstChild("Right")
    self._entryRoot = right and right:FindFirstChild("Online") or nil
    self._entryButton = self._entryRoot and (self._entryRoot:FindFirstChild("TextButton") or self._entryRoot:FindFirstChildWhichIsA("GuiButton", true)) or nil
    self._entryTimeLabel = self._entryRoot and self._entryRoot:FindFirstChild("Time", true) or nil
    self._entryRedPoint = self._entryRoot and self._entryRoot:FindFirstChild("RedPoint", true) or nil
    self._panel = self._mainGui:FindFirstChild("OnlineReward")
    self._rewardListRoot = self._panel and self._panel:FindFirstChild("Bg", true) or nil
    self._rewardTemplate = self._rewardListRoot and self._rewardListRoot:FindFirstChild("RewardTemplate") or nil
    self._unlockAllRoot = self._panel and self._panel:FindFirstChild("UnlockAll", true) or nil
    self._unlockAllButton = resolveButton(self._unlockAllRoot)
    self._unlockAllPriceLabel = self._unlockAllRoot and self._unlockAllRoot:FindFirstChild("Price", true) or nil

    if not (self._entryRoot and self._entryButton and self._panel and self._rewardListRoot and self._rewardTemplate) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._panel.Visible = false
    setVisible(self._entryRedPoint, false)
    self:_buildRewardNodes()

    self:_bindButton(self._entryButton, function()
        self:_openPanel()
    end, {
        ScaleTarget = self._entryRoot,
        RotationTarget = self._entryRoot:FindFirstChild("Icon", true) or self._entryButton,
        HoverScale = ENTRY_HOVER_SCALE,
        HoverRotation = HOVER_ROTATION,
    })

    local closeButton = self._panel:FindFirstChild("CloseButton", true)
    self:_bindButton(resolveButton(closeButton) or closeButton, function()
        self:_closePanel()
    end, {
        ScaleTarget = closeButton,
        RotationTarget = closeButton,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindButton(self._unlockAllButton, function()
        self:_promptUnlockAll()
    end, {
        ScaleTarget = self._unlockAllRoot or self._unlockAllButton,
    })
    self:_setUnlockAllPrice()
    self:_renderAll()
    return true
end

function OnlineRewardController:_queueBindRetry()
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
        warn("[OnlineRewardController] 找不到 PlayerGui/Main/Right/Online 或 Main/OnlineReward/Bg/RewardTemplate。")
    end)
end

function OnlineRewardController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[OnlineRewardController] Missing system events folder.")
        return
    end

    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.OnlineRewardStateSync, 10)
    self._requestStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestOnlineRewardStateSync, 10)
    self._requestClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestOnlineRewardClaim, 10)

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyStatePayload(payload)
        end))
    end

    table.insert(self._connections, MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
        if not (self._localPlayer and userId == self._localPlayer.UserId) then
            return
        end
        if self._activePromptProductId <= 0 or productId ~= self._activePromptProductId then
            return
        end

        self._activePromptProductId = 0
        self._isPromptingUnlockAll = false
        self:_renderUnlockAll()
        if isPurchased then
            task.delay(0.25, function()
                self:_requestState()
            end)
        end
    end))
end

function OnlineRewardController:_startClock()
    if self._clockConnection then
        self._clockConnection:Disconnect()
    end
    self._clockConnection = RunService.RenderStepped:Connect(function()
        if not self._state then
            return
        end
        self:_renderEntryState()
        if self._panel and self._panel.Visible == true then
            self:_renderRewardList()
            self:_renderUnlockAll()
        end
    end)
end

function OnlineRewardController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_clearGeneratedRewards()
    self._state = self:_newDefaultState()
    self:_bindUi(false)
    self:_connectRemotes()
    self:_startClock()
    self:_requestState()
end

return OnlineRewardController
