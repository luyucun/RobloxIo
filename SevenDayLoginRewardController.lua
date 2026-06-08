--[[
脚本名字: SevenDayLoginRewardController
脚本文件: SevenDayLoginRewardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/SevenDayLoginRewardController
说明: V4.4 七日登录奖励入口、UTC0 刷新、面板渲染和 UnlockAll 购买。
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
        "[SevenDayLoginRewardController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local SevenDayLoginRewardConfig = requireSharedModule("SevenDayLoginRewardConfig")

local SevenDayLoginRewardController = {}

SevenDayLoginRewardController._localPlayer = nil
SevenDayLoginRewardController._connections = {}
SevenDayLoginRewardController._buttonBindings = {}
SevenDayLoginRewardController._uiConnections = {}
SevenDayLoginRewardController._mainGui = nil
SevenDayLoginRewardController._topRightGui = nil
SevenDayLoginRewardController._entryRoot = nil
SevenDayLoginRewardController._entryRedPoint = nil
SevenDayLoginRewardController._openButton = nil
SevenDayLoginRewardController._root = nil
SevenDayLoginRewardController._panels = {}
SevenDayLoginRewardController._activePanelKey = "first"
SevenDayLoginRewardController._closeButton = nil
SevenDayLoginRewardController._nextRewardLabel = nil
SevenDayLoginRewardController._unlockAllButton = nil
SevenDayLoginRewardController._unlockAllPriceLabel = nil
SevenDayLoginRewardController._unlockAllPriceProductId = 0
SevenDayLoginRewardController._rewardNodes = {}
SevenDayLoginRewardController._stateSyncEvent = nil
SevenDayLoginRewardController._requestStateSyncEvent = nil
SevenDayLoginRewardController._requestClaimEvent = nil
SevenDayLoginRewardController._state = nil
SevenDayLoginRewardController._redPointShakeToken = 0
SevenDayLoginRewardController._redPointShakeThread = nil
SevenDayLoginRewardController._bindRetryQueued = false
SevenDayLoginRewardController._activePromptProductId = 0
SevenDayLoginRewardController._isPromptingUnlockAll = false
SevenDayLoginRewardController._lastObservedUtcDay = 0

local MODAL_OWNER_ID = "SevenDayLoginReward"
local FIRST_PANEL_KEY = "first"
local REPEAT_PANEL_KEY = "repeat"
local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.92
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

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

local function findButton(root, name)
    local node = root and root:FindFirstChild(name, true)
    if not node then
        return nil, nil
    end
    if node:IsA("GuiButton") then
        return node, node
    end
    if node:IsA("GuiObject") then
        local nestedButton = node:FindFirstChildWhichIsA("GuiButton", true)
        if nestedButton then
            return nestedButton, node
        end
    end
    return nil, nil
end

local function getUtcDayKey(timestamp)
    return math.floor(math.max(0, math.floor(tonumber(timestamp) or 0)) / 86400)
end

local function getNextUtcTimestamp(timestamp)
    return (getUtcDayKey(timestamp) + 1) * 86400
end

local function formatCountdown(seconds)
    local safeSeconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local hours = math.floor(safeSeconds / 3600)
    local minutes = math.floor((safeSeconds % 3600) / 60)
    return string.format("Refresh In:%02d:%02d", hours, minutes)
end

local function formatRobuxPrice(value)
    local price = tonumber(value)
    if not price then
        return nil
    end
    return tostring(math.max(0, math.floor(price + 0.5)))
end

local function getRewardCount()
    return SevenDayLoginRewardConfig.GetRewardCount()
end

local function getRewardName(reward)
    if type(reward) ~= "table" then
        return ""
    end
    local label = tostring(reward.label or "")
    if label ~= "" then
        return label
    end
    local rewardType = tostring(reward.rewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward.amount) or 1))
    if rewardType == "Potion" then
        return "Potion x" .. tostring(amount)
    elseif rewardType == "WheelSpins" then
        return "Spin x" .. tostring(amount)
    elseif rewardType == "Skin" then
        return "Skin"
    end
    return rewardType .. " x" .. tostring(amount)
end

function SevenDayLoginRewardController:_playTween(binding, key, target, tweenInfo, goal)
    if not target then
        return
    end
    local existing = binding.tweens[key]
    if existing then
        existing:Cancel()
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[key] = tween
    tween:Play()
end

function SevenDayLoginRewardController:_bindButton(button, onActivated, options)
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
        self:_playTween(binding, "scale", binding.uiScale, HOVER_TWEEN_INFO, { Scale = binding.baseScale * binding.hoverScale })
        if binding.rotationTarget then
            self:_playTween(binding, "rotation", binding.rotationTarget, HOVER_TWEEN_INFO, { Rotation = binding.baseRotation + binding.hoverRotation })
        end
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        self:_playTween(binding, "scale", binding.uiScale, RESET_TWEEN_INFO, { Scale = binding.baseScale })
        if binding.rotationTarget then
            self:_playTween(binding, "rotation", binding.rotationTarget, RESET_TWEEN_INFO, { Rotation = binding.baseRotation })
        end
    end))
    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            self:_playTween(binding, "scale", binding.uiScale, PRESS_TWEEN_INFO, { Scale = binding.baseScale * binding.pressScale })
            if binding.rotationTarget then
                self:_playTween(binding, "rotation", binding.rotationTarget, PRESS_TWEEN_INFO, { Rotation = binding.baseRotation + binding.hoverRotation })
            end
        end
    end))
    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if binding.isHovered then
                self:_playTween(binding, "scale", binding.uiScale, HOVER_TWEEN_INFO, { Scale = binding.baseScale * binding.hoverScale })
            else
                self:_playTween(binding, "scale", binding.uiScale, RESET_TWEEN_INFO, { Scale = binding.baseScale })
            end
        end
    end))
    table.insert(binding.connections, button.Activated:Connect(function()
        if type(onActivated) == "function" then
            onActivated()
        end
    end))
    table.insert(self._buttonBindings, binding)
end

function SevenDayLoginRewardController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
        end
    end
    table.clear(self._buttonBindings)
end

function SevenDayLoginRewardController:_startRedPointShakeLoop()
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

function SevenDayLoginRewardController:_stopRedPointShakeLoop()
    self._redPointShakeToken += 1
    if self._entryRedPoint then
        self._entryRedPoint.Rotation = 0
    end
end

function SevenDayLoginRewardController:_requestStateSync(reason, allowCycleReset)
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer({
            reason = tostring(reason or "Sync"),
            allowCycleReset = allowCycleReset == true,
        })
    end
end

function SevenDayLoginRewardController:_getPanelKey()
    local cycleId = math.max(1, math.floor(tonumber(self._state and self._state.cycleId) or 1))
    return cycleId <= 1 and FIRST_PANEL_KEY or REPEAT_PANEL_KEY
end

function SevenDayLoginRewardController:_getActivePanel()
    local panelKey = self:_getPanelKey()
    return self._panels and self._panels[panelKey] or nil, panelKey
end

function SevenDayLoginRewardController:_setPanelVisible(panel, visible)
    if panel and panel:IsA("GuiObject") then
        panel.Visible = visible == true
    end
end

function SevenDayLoginRewardController:_syncActivePanel()
    local activePanel, activePanelKey = self:_getActivePanel()
    local panelKeys = { FIRST_PANEL_KEY, REPEAT_PANEL_KEY }
    for _, panelKey in ipairs(panelKeys) do
        local panel = self._panels and self._panels[panelKey] or nil
        if panel and panel:IsA("GuiObject") then
            panel.Visible = panelKey == activePanelKey
        end
    end
    self._root = activePanel
    self._activePanelKey = activePanelKey
    self._closeButton = activePanel and activePanel:FindFirstChild("CloseButton", true) or nil
    self._nextRewardLabel = activePanel and activePanel:FindFirstChild("NextReward", true) or nil
    self._unlockAllButton = activePanel and activePanel:FindFirstChild("UnlockAll", true) or nil
    self._unlockAllPriceLabel = self._unlockAllButton and self._unlockAllButton:FindFirstChild("Price", true) or nil
    self._unlockAllPriceProductId = 0
    self._rewardNodes = {}
end

function SevenDayLoginRewardController:_openPanel()
    if not self._root or self._activePanelKey ~= self:_getPanelKey() then
        if not self:_bindUi(true) then
            return
        end
    end
    if not self._root then
        return
    end
    ModalUiController:PlayPanelOpen(MODAL_OWNER_ID, self._root)
    self:_requestStateSync("Open", true)
end

function SevenDayLoginRewardController:_closePanel()
    local closingRoot = self._root
    ModalUiController:PlayPanelClose(MODAL_OWNER_ID, closingRoot, {
        OnClosed = function()
            local firstPanel = self._panels and self._panels[FIRST_PANEL_KEY] or nil
            local repeatPanel = self._panels and self._panels[REPEAT_PANEL_KEY] or nil
            if firstPanel and firstPanel:IsA("GuiObject") then
                firstPanel.Visible = false
            end
            if repeatPanel and repeatPanel:IsA("GuiObject") then
                repeatPanel.Visible = false
            end
        end,
    })
end

function SevenDayLoginRewardController:OpenSevenDayLoginReward()
    if (not self._root or self._activePanelKey ~= self:_getPanelKey()) and not self:_bindUi(true) then
        return
    end
    self:_openPanel()
end

function SevenDayLoginRewardController:CloseSevenDayLoginReward()
    self:_closePanel()
end

function SevenDayLoginRewardController:_promptUnlockAll()
    local productId = math.max(0, math.floor(tonumber(self._state and self._state.productId or 0) or 0))
    if productId <= 0 or self._isPromptingUnlockAll == true then
        return
    end
    self._isPromptingUnlockAll = true
    self._activePromptProductId = productId
    local ok, err = pcall(function()
        MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
    end)
    if not ok then
        warn("[SevenDayLoginRewardController] 拉起七日登录 UnlockAll 购买失败: " .. tostring(err))
        self._isPromptingUnlockAll = false
        self._activePromptProductId = 0
    end
end

function SevenDayLoginRewardController:_setUnlockAllPrice(productId)
    if not self._unlockAllPriceLabel then
        return
    end
    local resolvedProductId = math.max(0, math.floor(tonumber(productId or self._state and self._state.productId or SevenDayLoginRewardConfig.DeveloperProductId) or 0))
    if resolvedProductId <= 0 then
        return
    end
    if self._unlockAllPriceProductId == resolvedProductId then
        return
    end
    self._unlockAllPriceProductId = resolvedProductId

    local fallbackText = tostring(self._unlockAllPriceLabel.Text or "")
    setText(self._unlockAllPriceLabel, "...")
    task.spawn(function()
        local ok, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedProductId, Enum.InfoType.Product)
        end)
        if self._unlockAllPriceProductId ~= resolvedProductId then
            return
        end
        local priceText = ok and type(productInfo) == "table" and formatRobuxPrice(productInfo.PriceInRobux) or nil
        if priceText then
            setText(self._unlockAllPriceLabel, priceText)
        elseif fallbackText ~= "" then
            setText(self._unlockAllPriceLabel, fallbackText)
        end
    end)
end

function SevenDayLoginRewardController:_bindRewardFrame(frame, dayIndex)
    if not frame then
        return nil
    end

    local rewardNode = {
        root = frame,
        bg = frame:FindFirstChild("Bg", true),
        dayNumLabel = frame:FindFirstChild("DayNum", true),
        claimButton = frame:FindFirstChild("Claim", true),
        claimedLabel = frame:FindFirstChild("Claimed", true),
        nameLabel = frame:FindFirstChild("Name", true),
        iconLabel = frame:FindFirstChild("ItemIcon", true),
        amountLabel = frame:FindFirstChild("Num", true),
    }

    local claimInteractive = rewardNode.claimButton and rewardNode.claimButton:IsA("GuiButton") and rewardNode.claimButton or rewardNode.claimButton and rewardNode.claimButton:FindFirstChildWhichIsA("GuiButton", true)
    if claimInteractive then
        self:_bindButton(claimInteractive, function()
            if self._requestClaimEvent then
                self._requestClaimEvent:FireServer({ dayIndex = dayIndex })
            end
        end, { ScaleTarget = rewardNode.claimButton or claimInteractive, HoverScale = 1.05, PressScale = 0.94 })
    end

    return rewardNode
end

function SevenDayLoginRewardController:_renderRewardFrame(dayIndex)
    local rewardNode = self._rewardNodes[dayIndex]
    if type(rewardNode) ~= "table" then
        return
    end

    local reward = self._state and self._state.rewards and self._state.rewards[dayIndex] or {}
    local isClaimed = reward.isClaimed == true
    local isClaimable = reward.isClaimable == true
    local isLocked = not isClaimed and not isClaimable

    if self._activePanelKey ~= REPEAT_PANEL_KEY then
        if rewardNode.nameLabel then
            setText(rewardNode.nameLabel, getRewardName(reward))
        end
        if rewardNode.iconLabel then
            setImage(rewardNode.iconLabel, reward.icon)
        end
        if rewardNode.amountLabel then
            setText(rewardNode.amountLabel, tostring(math.max(1, math.floor(tonumber(reward.amount) or 1))))
        end
    end

    setVisible(rewardNode.dayNumLabel, isLocked)
    setVisible(rewardNode.claimButton, isClaimable)
    setVisible(rewardNode.claimedLabel, isClaimed)
    setVisible(rewardNode.bg, isClaimed)

    local claimInteractive = rewardNode.claimButton and rewardNode.claimButton:IsA("GuiButton") and rewardNode.claimButton or rewardNode.claimButton and rewardNode.claimButton:FindFirstChildWhichIsA("GuiButton", true)
    if claimInteractive then
        claimInteractive.Active = isClaimable
        claimInteractive.AutoButtonColor = isClaimable
        claimInteractive.Selectable = isClaimable
    end
end

function SevenDayLoginRewardController:_renderAll()
    setVisible(self._entryRedPoint, self._state and self._state.hasClaimableReward == true)
    if self._state and self._state.hasClaimableReward == true then
        self:_startRedPointShakeLoop()
    else
        self:_stopRedPointShakeLoop()
    end

    if self._nextRewardLabel then
        local now = os.time()
        local nextRefreshAt = tonumber(self._state and self._state.nextRefreshAt) or getNextUtcTimestamp(now)
        setText(self._nextRewardLabel, formatCountdown(math.max(0, nextRefreshAt - now)))
    end

    local canUnlockAll = self._state and self._state.canUnlockAll == true and (self._state.productId or 0) > 0 and self._isPromptingUnlockAll ~= true
    setVisible(self._unlockAllButton, canUnlockAll)
    if self._unlockAllButton and self._unlockAllButton:IsA("GuiButton") then
        self._unlockAllButton.Active = canUnlockAll
        self._unlockAllButton.AutoButtonColor = canUnlockAll
        self._unlockAllButton.Selectable = canUnlockAll
    end

    for dayIndex = 1, getRewardCount() do
        self:_renderRewardFrame(dayIndex)
    end
end

function SevenDayLoginRewardController:_applyState(payload)
    if type(payload) ~= "table" then
        return
    end

    local rewards = {}
    if type(payload.rewards) == "table" then
        for _, reward in ipairs(payload.rewards) do
            local dayIndex = math.max(0, math.floor(tonumber(type(reward) == "table" and reward.dayIndex or 0) or 0))
            if dayIndex >= 1 and dayIndex <= getRewardCount() then
                rewards[dayIndex] = reward
            end
        end
    end

    self._state = {
        rewards = rewards,
        hasClaimableReward = payload.hasClaimableReward == true,
        canUnlockAll = payload.canUnlockAll == true,
        productId = math.max(0, math.floor(tonumber(payload.productId) or 0)),
        pendingCycleReset = payload.pendingCycleReset == true,
        nextRefreshAt = math.max(0, math.floor(tonumber(payload.nextRefreshAt) or 0)),
        cycleId = math.max(1, math.floor(tonumber(payload.cycleId) or 1)),
    }

    local desiredPanelKey = self:_getPanelKey()
    if self._root and self._activePanelKey ~= desiredPanelKey then
        local wasOpen = self._root.Visible == true
        if not self:_bindUi(true) then
            self:_queueBindRetry()
            return
        end
        if wasOpen and self._root then
            ModalUiController:PlayPanelOpen(MODAL_OWNER_ID, self._root, {
                Immediate = true,
            })
        end
        self:_setUnlockAllPrice(self._state.productId)
        self:_renderAll()
        return
    end

    self:_setUnlockAllPrice(self._state.productId)
    self:_renderAll()
end

function SevenDayLoginRewardController:_bindRemoteEvents()
    local eventsRoot = ReplicatedStorage:FindFirstChild(RemoteNames.RootFolder)
    local systemEvents = eventsRoot and eventsRoot:FindFirstChild(RemoteNames.SystemEventsFolder)
    if not systemEvents then
        return false
    end

    local stateSyncEvent = systemEvents:FindFirstChild(RemoteNames.System.SevenDayLoginRewardStateSync)
    self._requestStateSyncEvent = systemEvents:FindFirstChild(RemoteNames.System.RequestSevenDayLoginRewardStateSync)
    self._requestClaimEvent = systemEvents:FindFirstChild(RemoteNames.System.RequestSevenDayLoginRewardClaim)

    if stateSyncEvent ~= self._stateSyncEvent and stateSyncEvent and stateSyncEvent:IsA("RemoteEvent") then
        self._stateSyncEvent = stateSyncEvent
        table.insert(self._connections, stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyState(payload)
        end))
    elseif stateSyncEvent ~= self._stateSyncEvent then
        self._stateSyncEvent = stateSyncEvent
    end
    return self._stateSyncEvent ~= nil and self._requestStateSyncEvent ~= nil and self._requestClaimEvent ~= nil
end

function SevenDayLoginRewardController:_bindUi(silent)
    self:_disconnectButtonBindings()
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    if not mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._topRightGui = mainGui:FindFirstChild("TopRightGui")
    self._entryRoot = self._topRightGui and self._topRightGui:FindFirstChild("SevenDays", true) or nil
    self._entryRedPoint = self._entryRoot and self._entryRoot:FindFirstChild("RedPoint", true) or nil
    self._openButton = self._entryRoot and (self._entryRoot:FindFirstChild("Button", true) or self._entryRoot:FindFirstChildWhichIsA("GuiButton", true)) or nil
    self._panels = {
        [FIRST_PANEL_KEY] = mainGui:FindFirstChild("Sevendays", true),
        [REPEAT_PANEL_KEY] = mainGui:FindFirstChild("SevendaysRepeat", true),
    }
    self:_syncActivePanel()
    if not (self._entryRoot and self._root) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end
    disconnectAll(self._uiConnections)

    if self._openButton then
        self:_bindButton(self._openButton, function()
            self:_openPanel()
        end, {
            ScaleTarget = self._entryRoot or self._openButton,
            HoverScale = ENTRY_HOVER_SCALE,
            PressScale = ENTRY_PRESS_SCALE,
            HoverRotation = HOVER_ROTATION,
        })
    end

    local closeInteractive = self._closeButton and (self._closeButton:IsA("GuiButton") and self._closeButton or self._closeButton:FindFirstChildWhichIsA("GuiButton", true)) or nil
    if closeInteractive then
        self:_bindButton(closeInteractive, function()
            self:_closePanel()
        end, {
            ScaleTarget = self._closeButton,
            RotationTarget = self._closeButton,
            HoverRotation = HOVER_ROTATION,
        })
    end

    local unlockInteractive = self._unlockAllButton and (self._unlockAllButton:IsA("GuiButton") and self._unlockAllButton or self._unlockAllButton:FindFirstChildWhichIsA("GuiButton", true)) or nil
    if unlockInteractive then
        self:_bindButton(unlockInteractive, function()
            self:_promptUnlockAll()
        end, { ScaleTarget = self._unlockAllButton, HoverScale = HOVER_SCALE, PressScale = PRESS_SCALE })
    end

    for dayIndex = 1, getRewardCount() do
        local frame = self._root:FindFirstChild(string.format("Reward%02d", dayIndex), true)
        self._rewardNodes[dayIndex] = self:_bindRewardFrame(frame, dayIndex)
    end

    if self._root:IsA("GuiObject") then
        self._root.Visible = false
    end
    if self._panels[FIRST_PANEL_KEY] and self._panels[FIRST_PANEL_KEY] ~= self._root and self._panels[FIRST_PANEL_KEY]:IsA("GuiObject") then
        self._panels[FIRST_PANEL_KEY].Visible = false
    end
    if self._panels[REPEAT_PANEL_KEY] and self._panels[REPEAT_PANEL_KEY] ~= self._root and self._panels[REPEAT_PANEL_KEY]:IsA("GuiObject") then
        self._panels[REPEAT_PANEL_KEY].Visible = false
    end

    self:_setUnlockAllPrice()
    self:_renderAll()
    return true
end

function SevenDayLoginRewardController:_queueBindRetry()
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
    end)
end

function SevenDayLoginRewardController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self._state = {
        rewards = {},
        hasClaimableReward = false,
        canUnlockAll = false,
        productId = SevenDayLoginRewardConfig.DeveloperProductId,
        pendingCycleReset = false,
        nextRefreshAt = 0,
        cycleId = 1,
    }
    self._panels = {}
    self._activePanelKey = FIRST_PANEL_KEY
    self._activePromptProductId = 0
    self._isPromptingUnlockAll = false
    self._unlockAllPriceProductId = 0
    self._lastObservedUtcDay = getUtcDayKey(os.time())
    self:_bindRemoteEvents()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, ReplicatedStorage.DescendantAdded:Connect(function(descendant)
        if descendant and (
            descendant.Name == RemoteNames.RootFolder
            or descendant.Name == RemoteNames.SystemEventsFolder
            or descendant.Name == RemoteNames.System.SevenDayLoginRewardStateSync
            or descendant.Name == RemoteNames.System.RequestSevenDayLoginRewardStateSync
            or descendant.Name == RemoteNames.System.RequestSevenDayLoginRewardClaim
        ) then
            task.defer(function()
                self:_bindRemoteEvents()
            end)
        end
    end))

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                    self:_requestStateSync("MainGuiReady", false)
                end)
            end
        end))
    end

    table.insert(self._connections, MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
        if userId ~= self._localPlayer.UserId then
            return
        end
        if productId ~= self._activePromptProductId then
            return
        end
        self._activePromptProductId = 0
        self._isPromptingUnlockAll = false
        if isPurchased then
            task.delay(0.25, function()
                self:_requestStateSync("PurchaseFinished", false)
            end)
        end
    end))

    table.insert(self._connections, RunService.Heartbeat:Connect(function()
        local now = os.time()
        local utcDay = getUtcDayKey(now)
        if utcDay ~= self._lastObservedUtcDay then
            self._lastObservedUtcDay = utcDay
            self:_requestStateSync("UtcRefresh", false)
        end
        if self._root and self._root.Visible == true and self._nextRewardLabel then
            local nextRefreshAt = tonumber(self._state and self._state.nextRefreshAt) or 0
            if nextRefreshAt > 0 then
                setText(self._nextRewardLabel, formatCountdown(math.max(0, nextRefreshAt - now)))
            end
        end
    end))

    task.defer(function()
        self:_requestStateSync("Startup", false)
    end)
end

return SevenDayLoginRewardController
