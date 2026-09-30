--[[
Script: ChestController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/ChestController
Purpose: V5.9 client binding for the chest rewards panel.
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
        "[ChestController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local ChestConfig = requireSharedModule("ChestConfig")
local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")
local ShopConfig = requireSharedModule("ShopConfig")

local function isChestEntryVisible()
    local entryVisibility = GameConfig.UI_ENTRY_VISIBILITY
    return type(entryVisibility) ~= "table" or entryVisibility.Chests ~= false
end

local ChestController = {}

ChestController.DefaultChestId = 101
ChestController._localPlayer = nil
ChestController._connections = {}
ChestController._buttonBindings = {}
ChestController._mainGui = nil
ChestController._leftEntry = nil
ChestController._leftInfo = nil
ChestController._leftInfoText = nil
ChestController._panel = nil
ChestController._countText = nil
ChestController._countdownText = nil
ChestController._dropRows = {}
ChestController._requestStateSyncEvent = nil
ChestController._stateSyncEvent = nil
ChestController._requestOpenEvent = nil
ChestController._latestState = {
    chests = {},
    chestConfigs = {},
}
ChestController._bindRetryQueued = false
ChestController._openEffect = nil
ChestController._openEffectSerial = 0
ChestController._countdownLoopSerial = 0

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CHEST_OPEN_EFFECT_NAME = "ChestOpenEffect"
local CHEST_OPEN_HALO_IMAGE = "rbxassetid://1598630577"
local FALLBACK_CHEST_IMAGE = "rbxassetid://134158624322683"
local OPEN_EFFECT_Z_INDEX = 9000
local OPEN_EFFECT_FADE_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_EFFECT_SHAKE = TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local OPEN_EFFECT_SETTLE = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local OPEN_EFFECT_FADE_OUT = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local OPEN_EFFECT_COMPLETE_DELAY = 0.08
local BEIJING_UTC_OFFSET_SECONDS = 8 * 3600
local WEEKLY_REFRESH_WEEKDAY = 7
local WEEKLY_REFRESH_HOUR = 22
local COUNTDOWN_REFRESH_INTERVAL_SECONDS = 30

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
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

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value or "")
    end
end

local function setImage(imageObject, value)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(value or "")
    end
end

local function setGuiVisible(guiObject, visible)
    if guiObject and guiObject:IsA("GuiObject") then
        guiObject.Visible = visible == true
    end
end

local function getNextWeeklyRefreshUtc(nowUtc)
    local now = math.max(0, math.floor(tonumber(nowUtc) or os.time()))
    local beijingTimestamp = now + BEIJING_UTC_OFFSET_SECONDS
    local beijingNow = os.date("!*t", beijingTimestamp)
    local currentWeekday = tonumber(beijingNow.wday) or 1
    local daysUntilRefresh = (WEEKLY_REFRESH_WEEKDAY - currentWeekday) % 7
    local beijingDayStartUtc = math.floor(beijingTimestamp / 86400) * 86400 - BEIJING_UTC_OFFSET_SECONDS
    local target = beijingDayStartUtc + (daysUntilRefresh * 86400) + (WEEKLY_REFRESH_HOUR * 3600)

    if target <= now then
        target += 7 * 24 * 3600
    end
    return target
end

local function formatWeeklyRefreshCountdown(nowUtc)
    local remainingSeconds = math.max(0, getNextWeeklyRefreshUtc(nowUtc) - math.max(0, math.floor(tonumber(nowUtc) or os.time())))
    local hours = math.floor(remainingSeconds / 3600)
    local minutes = math.floor((remainingSeconds % 3600) / 60)
    return string.format("Rewards Refresh In: %02d:%02d", hours, minutes)
end

local function safeCall(callback)
    if type(callback) ~= "function" then
        return
    end
    local ok, err = pcall(callback)
    if not ok then
        warn("[ChestController] Chest open animation callback failed: " .. tostring(err))
    end
end

local function tweenAndWait(target, tweenInfo, goal)
    if not (target and target.Parent and tweenInfo and goal) then
        return
    end
    local tween = TweenService:Create(target, tweenInfo, goal)
    tween:Play()
    tween.Completed:Wait()
end

local function setButtonInteractivity(root, enabled)
    if not (root and root:IsA("GuiObject")) then
        return
    end
    local isEnabled = enabled == true
    if root:IsA("GuiButton") then
        root.Active = isEnabled
        root.Selectable = isEnabled
        root.AutoButtonColor = isEnabled
    end
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            descendant.Active = isEnabled
            descendant.Selectable = isEnabled
            descendant.AutoButtonColor = isEnabled
        end
    end
end

local function findButton(root, name)
    if not root then
        return nil, nil
    end

    local candidates = {}
    local function addCandidate(node)
        if not node then
            return
        end
        if node:IsA("GuiButton") then
            table.insert(candidates, {
                button = node,
                scaleTarget = node,
            })
        elseif node:IsA("GuiObject") then
            local nestedButton = node:FindFirstChildWhichIsA("GuiButton", true)
            if nestedButton then
                table.insert(candidates, {
                    button = nestedButton,
                    scaleTarget = node,
                })
            end
        end
    end

    if root.Name == name then
        addCandidate(root)
    end
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant.Name == name then
            addCandidate(descendant)
        end
    end

    local fallback = candidates[1]
    for _, candidate in ipairs(candidates) do
        local button = candidate.button
        local scaleTarget = candidate.scaleTarget
        if button and button:IsA("GuiObject") and button.Visible
            and (not scaleTarget or not scaleTarget:IsA("GuiObject") or scaleTarget.Visible)
        then
            return button, scaleTarget
        end
    end

    if fallback then
        return fallback.button, fallback.scaleTarget
    end
    return nil, nil
end

local function playScaleTween(binding, tweenInfo, goal)
    if not (binding and binding.uiScale and tweenInfo and goal) then
        return
    end
    if binding.scaleTween then
        binding.scaleTween:Cancel()
        binding.scaleTween = nil
    end
    local tween = TweenService:Create(binding.uiScale, tweenInfo, goal)
    binding.scaleTween = tween
    tween.Completed:Connect(function()
        if binding.scaleTween == tween then
            binding.scaleTween = nil
        end
    end)
    tween:Play()
end

local function playRotationTween(binding, tweenInfo, goal)
    if not (binding and binding.rotationTarget and tweenInfo and goal) then
        return
    end
    if binding.rotationTween then
        binding.rotationTween:Cancel()
        binding.rotationTween = nil
    end
    local tween = TweenService:Create(binding.rotationTarget, tweenInfo, goal)
    binding.rotationTween = tween
    tween.Completed:Connect(function()
        if binding.rotationTween == tween then
            binding.rotationTween = nil
        end
    end)
    tween:Play()
end

local function trimNumber(value)
    local rounded = math.floor(((tonumber(value) or 0) * 100) + 0.5) / 100
    if math.abs(rounded - math.floor(rounded)) < 0.001 then
        return tostring(math.floor(rounded))
    end
    local text = string.format("%.2f", rounded)
    text = string.gsub(text, "0+$", "")
    text = string.gsub(text, "%.$", "")
    return text
end

local function normalizeRewardType(rewardType)
    local text = tostring(rewardType or "")
    if text == "WheelSpins" then
        return "WheelSpins"
    elseif text == "Diamonds" then
        return "Diamonds"
    elseif text == "Potion" then
        return "Potion"
    elseif text == "Trail" then
        return "Trail"
    end
    return text
end

local function copyClientRewardToServerShape(reward)
    if type(reward) ~= "table" then
        return nil
    end
    local rewardType = normalizeRewardType(reward.rewardType or reward.RewardType)
    if rewardType == "" then
        return nil
    end
    return {
        RewardType = rewardType,
        PotionId = reward.potionId or reward.PotionId,
        TrailId = reward.trailId or reward.TrailId,
        Amount = reward.amount or reward.Amount,
        Icon = reward.icon or reward.Icon,
        Label = reward.label or reward.Label,
    }
end

local function getRewardLabel(reward)
    local shaped = copyClientRewardToServerShape(reward)
    local presentation = shaped and ShopConfig.GetRewardPresentation and ShopConfig.GetRewardPresentation(shaped) or nil
    if presentation and tostring(presentation.label or "") ~= "" then
        return tostring(presentation.label)
    end
    return tostring(reward and (reward.rewardType or reward.RewardType) or "")
end

local function getRewardAmountText(reward)
    local amount = math.max(1, math.floor(tonumber(reward and (reward.amount or reward.Amount)) or 1))
    return "x" .. tostring(amount)
end

local function getRewardListText(reward, hasSeparateAmount)
    local label = getRewardLabel(reward)
    local amount = math.max(1, math.floor(tonumber(reward and (reward.amount or reward.Amount)) or 1))
    if hasSeparateAmount == true or amount <= 1 then
        return label
    end
    return label .. " " .. getRewardAmountText(reward)
end

local function getRewardIcon(reward)
    local shaped = copyClientRewardToServerShape(reward)
    local presentation = shaped and ShopConfig.GetRewardPresentation and ShopConfig.GetRewardPresentation(shaped) or nil
    return presentation and presentation.icon or tostring(reward and (reward.icon or reward.Icon) or "")
end

function ChestController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        if binding.connections then
            disconnectAll(binding.connections)
        end
        if binding.scaleTween then
            binding.scaleTween:Cancel()
        end
        if binding.rotationTween then
            binding.rotationTween:Cancel()
        end
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale
        end
        if binding.rotationTarget and binding.rotationTarget.Parent then
            binding.rotationTarget.Rotation = binding.baseRotation
        end
    end
    table.clear(self._buttonBindings)
end

function ChestController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = (type(options) == "table" and options.ScaleTarget) or button
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
        enabled = true,
        isHovered = false,
        isPressed = false,
        connections = {},
    }

    local function applyState()
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
        playScaleTween(binding, tweenInfo, { Scale = scale })
        playRotationTween(binding, tweenInfo, { Rotation = rotation })
    end

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        applyState()
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        applyState()
    end))
    table.insert(binding.connections, button.MouseButton1Down:Connect(function()
        binding.isPressed = true
        applyState()
    end))
    table.insert(binding.connections, button.MouseButton1Up:Connect(function()
        binding.isPressed = false
        applyState()
    end))
    table.insert(binding.connections, button.Activated:Connect(function()
        if binding.enabled ~= true then
            return
        end
        if type(onActivated) == "function" then
            onActivated()
        end
    end))

    table.insert(self._buttonBindings, binding)
    return binding
end

function ChestController:_setBindingEnabled(binding, enabled)
    if not binding then
        return
    end
    binding.enabled = enabled == true
    setButtonInteractivity(binding.button, true)
end

function ChestController:_getChestCount(chestId)
    local chests = self._latestState and self._latestState.chests or {}
    local key = tostring(math.floor(tonumber(chestId) or ChestController.DefaultChestId))
    return math.max(0, math.floor(tonumber(type(chests) == "table" and (chests[key] or chests[tonumber(key)]) or 0) or 0))
end

function ChestController:_getClientChestConfig(chestId)
    local normalizedChestId = math.floor(tonumber(chestId) or ChestController.DefaultChestId)
    for _, chest in ipairs(self._latestState.chestConfigs or {}) do
        if math.floor(tonumber(chest.id or chest.Id) or 0) == normalizedChestId then
            return chest
        end
    end

    local fallbackChest = ChestConfig.GetChest and ChestConfig.GetChest(normalizedChestId) or nil
    if not fallbackChest then
        return nil
    end

    local rewards = {}
    for _, reward in ipairs(ChestConfig.GetDropPoolForChest(normalizedChestId)) do
        local copied = ChestConfig.CopyRewardForClient and ChestConfig.CopyRewardForClient(reward) or nil
        if copied then
            table.insert(rewards, copied)
        end
    end
    return {
        id = fallbackChest.Id,
        icon = fallbackChest.Icon,
        rewards = rewards,
    }
end

function ChestController:_setOpen(isOpen)
    if self._panel and self._panel:IsA("GuiObject") then
        self._panel.Visible = isOpen == true
    end
    if isOpen == true then
        self:_updateCountdownText()
        self:RefreshNow()
    end
end

function ChestController:Open()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    self:_setOpen(true)
end

function ChestController:Close()
    self:_setOpen(false)
end

function ChestController:_requestOpen(mode)
    if not self._requestOpenEvent then
        return
    end
    self:_setBindingEnabled(self._openOneBinding, false)
    self:_setBindingEnabled(self._openAllBinding, false)
    task.delay(2, function()
        self:_updateUi()
    end)
    self._requestOpenEvent:FireServer({
        chestId = ChestController.DefaultChestId,
        mode = tostring(mode or "One") == "All" and "All" or "One",
    })
end

function ChestController:RefreshNow()
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer({
            chestId = ChestController.DefaultChestId,
        })
    end
end

function ChestController:_updateCountdownText()
    setText(self._countdownText, formatWeeklyRefreshCountdown(os.time()))
end

function ChestController:_startCountdownLoop()
    self._countdownLoopSerial += 1
    local serial = self._countdownLoopSerial
    task.spawn(function()
        while self._countdownLoopSerial == serial do
            self:_updateCountdownText()
            task.wait(COUNTDOWN_REFRESH_INTERVAL_SECONDS)
        end
    end)
end

function ChestController:_getOpenAnimationChestImage()
    if self._panel then
        local chestArea = self._panel:FindFirstChild("ChestArea", true)
        local icon = chestArea and chestArea:FindFirstChild("Icon")
        if icon and (icon:IsA("ImageLabel") or icon:IsA("ImageButton")) and tostring(icon.Image or "") ~= "" then
            return icon.Image
        end
    end

    local chest = self:_getClientChestConfig(ChestController.DefaultChestId)
    if chest and tostring(chest.icon or chest.Icon or "") ~= "" then
        return tostring(chest.icon or chest.Icon)
    end
    return FALLBACK_CHEST_IMAGE
end

function ChestController:_ensureOpenEffect()
    local mainGui = self._mainGui or findMainGui(self._localPlayer)
    self._mainGui = mainGui
    if not mainGui then
        return nil
    end

    local overlay = mainGui:FindFirstChild(CHEST_OPEN_EFFECT_NAME)
    if overlay and not overlay:IsA("Frame") then
        overlay:Destroy()
        overlay = nil
    end
    if not overlay then
        overlay = Instance.new("Frame")
        overlay.Name = CHEST_OPEN_EFFECT_NAME
        overlay.BackgroundTransparency = 1
        overlay.BorderSizePixel = 0
        overlay.Size = UDim2.fromScale(1, 1)
        overlay.Position = UDim2.fromScale(0, 0)
        overlay.AnchorPoint = Vector2.new(0, 0)
        overlay.Visible = false
        overlay.Active = true
        overlay.ZIndex = OPEN_EFFECT_Z_INDEX
        overlay.Parent = mainGui

        local inputBlocker = Instance.new("TextButton")
        inputBlocker.Name = "InputBlocker"
        inputBlocker.BackgroundTransparency = 1
        inputBlocker.BorderSizePixel = 0
        inputBlocker.Text = ""
        inputBlocker.TextTransparency = 1
        inputBlocker.AutoButtonColor = false
        inputBlocker.Active = true
        inputBlocker.Selectable = false
        inputBlocker.Size = UDim2.fromScale(1, 1)
        inputBlocker.Position = UDim2.fromScale(0, 0)
        inputBlocker.ZIndex = OPEN_EFFECT_Z_INDEX + 10
        inputBlocker.Parent = overlay

        local halo = Instance.new("ImageLabel")
        halo.Name = "Halo"
        halo.BackgroundTransparency = 1
        halo.BorderSizePixel = 0
        halo.AnchorPoint = Vector2.new(0.5, 0.5)
        halo.Position = UDim2.fromScale(0.5, 0.5)
        halo.Size = UDim2.fromScale(0.42, 0.42)
        halo.Image = CHEST_OPEN_HALO_IMAGE
        halo.ImageTransparency = 1
        halo.ScaleType = Enum.ScaleType.Fit
        halo.ZIndex = OPEN_EFFECT_Z_INDEX + 1
        halo.Parent = overlay
        local haloAspect = Instance.new("UIAspectRatioConstraint")
        haloAspect.AspectRatio = 1
        haloAspect.Parent = halo

        local chest = Instance.new("ImageLabel")
        chest.Name = "Chest"
        chest.BackgroundTransparency = 1
        chest.BorderSizePixel = 0
        chest.AnchorPoint = Vector2.new(0.5, 0.5)
        chest.Position = UDim2.fromScale(0.5, 0.5)
        chest.Size = UDim2.fromScale(0.24, 0.24)
        chest.ImageTransparency = 1
        chest.ScaleType = Enum.ScaleType.Fit
        chest.ZIndex = OPEN_EFFECT_Z_INDEX + 2
        chest.Parent = overlay
        local chestAspect = Instance.new("UIAspectRatioConstraint")
        chestAspect.AspectRatio = 1
        chestAspect.Parent = chest
        ensureUiScale(chest)
    end

    local inputBlocker = overlay:FindFirstChild("InputBlocker")
    if not (inputBlocker and inputBlocker:IsA("TextButton")) then
        if inputBlocker then
            inputBlocker:Destroy()
        end
        inputBlocker = Instance.new("TextButton")
        inputBlocker.Name = "InputBlocker"
        inputBlocker.Parent = overlay
    end
    inputBlocker.BackgroundTransparency = 1
    inputBlocker.BorderSizePixel = 0
    inputBlocker.Text = ""
    inputBlocker.TextTransparency = 1
    inputBlocker.AutoButtonColor = false
    inputBlocker.Active = true
    inputBlocker.Selectable = false
    inputBlocker.Size = UDim2.fromScale(1, 1)
    inputBlocker.Position = UDim2.fromScale(0, 0)
    inputBlocker.ZIndex = OPEN_EFFECT_Z_INDEX + 10

    local halo = overlay:FindFirstChild("Halo")
    local chest = overlay:FindFirstChild("Chest")
    if not (halo and halo:IsA("ImageLabel") and chest and chest:IsA("ImageLabel")) then
        overlay:Destroy()
        self._openEffect = nil
        return self:_ensureOpenEffect()
    end

    self._openEffect = overlay
    return overlay
end

function ChestController:_resetOpenEffect(overlay)
    if not (overlay and overlay.Parent) then
        return nil, nil, nil
    end
    local halo = overlay:FindFirstChild("Halo")
    local chest = overlay:FindFirstChild("Chest")
    local chestScale = chest and ensureUiScale(chest) or nil
    if halo and halo:IsA("ImageLabel") then
        halo.Image = CHEST_OPEN_HALO_IMAGE
        halo.ImageTransparency = 1
        halo.Rotation = 0
        halo.Size = UDim2.fromScale(0.44, 0.44)
        halo.Position = UDim2.fromScale(0.5, 0.5)
    end
    if chest and chest:IsA("ImageLabel") then
        chest.Image = self:_getOpenAnimationChestImage()
        chest.ImageTransparency = 1
        chest.Rotation = 0
        chest.Position = UDim2.fromScale(0.5, 0.5)
        chest.Size = UDim2.fromScale(0.3, 0.3)
    end
    if chestScale then
        chestScale.Scale = 0.68
    end
    return halo, chest, chestScale
end

function ChestController:PlayOpenAnimation(onComplete)
    if not (self._mainGui and self._panel) and not self:_bindUi(true) then
        return false
    end

    self._openEffectSerial += 1
    local serial = self._openEffectSerial
    local overlay = self:_ensureOpenEffect()
    if not overlay then
        return false
    end

    local halo, chest, chestScale = self:_resetOpenEffect(overlay)
    if not (halo and chest and chestScale) then
        return false
    end

    overlay.Visible = true
    overlay.Active = true

    task.spawn(function()
        tweenAndWait(halo, OPEN_EFFECT_FADE_IN, {
            ImageTransparency = 0.12,
            Rotation = 28,
            Size = UDim2.fromScale(0.56, 0.56),
        })
        if self._openEffectSerial ~= serial then
            return
        end

        TweenService:Create(chest, OPEN_EFFECT_FADE_IN, {
            ImageTransparency = 0,
        }):Play()
        tweenAndWait(chestScale, OPEN_EFFECT_SETTLE, {
            Scale = 1,
        })
        if self._openEffectSerial ~= serial then
            return
        end

        local shakes = {
            { rotation = -18, scale = 1.18, x = 0.482, y = 0.494 },
            { rotation = 18, scale = 1.26, x = 0.518, y = 0.486 },
            { rotation = -15, scale = 1.22, x = 0.486, y = 0.512 },
            { rotation = 15, scale = 1.3, x = 0.516, y = 0.492 },
            { rotation = -12, scale = 1.24, x = 0.49, y = 0.508 },
            { rotation = 12, scale = 1.28, x = 0.512, y = 0.496 },
            { rotation = -8, scale = 1.18, x = 0.494, y = 0.504 },
            { rotation = 8, scale = 1.2, x = 0.506, y = 0.498 },
        }
        for _, step in ipairs(shakes) do
            TweenService:Create(chestScale, OPEN_EFFECT_SHAKE, {
                Scale = step.scale,
            }):Play()
            TweenService:Create(halo, OPEN_EFFECT_SHAKE, {
                Rotation = halo.Rotation + 24,
            }):Play()
            tweenAndWait(chest, OPEN_EFFECT_SHAKE, {
                Rotation = step.rotation,
                Position = UDim2.fromScale(step.x, step.y),
            })
            if self._openEffectSerial ~= serial then
                return
            end
        end

        TweenService:Create(halo, OPEN_EFFECT_SETTLE, {
            Rotation = halo.Rotation + 36,
            Size = UDim2.fromScale(0.66, 0.66),
        }):Play()
        TweenService:Create(chestScale, OPEN_EFFECT_SETTLE, {
            Scale = 1.42,
        }):Play()
        tweenAndWait(chest, OPEN_EFFECT_SETTLE, {
            Rotation = 0,
            Position = UDim2.fromScale(0.5, 0.5),
        })
        if self._openEffectSerial ~= serial then
            return
        end

        TweenService:Create(halo, OPEN_EFFECT_FADE_OUT, {
            ImageTransparency = 1,
            Size = UDim2.fromScale(0.74, 0.74),
        }):Play()
        TweenService:Create(chestScale, OPEN_EFFECT_FADE_OUT, {
            Scale = 1.58,
        }):Play()
        tweenAndWait(chest, OPEN_EFFECT_FADE_OUT, {
            ImageTransparency = 1,
        })
        if self._openEffectSerial ~= serial then
            return
        end

        overlay.Visible = false
        task.delay(OPEN_EFFECT_COMPLETE_DELAY, function()
            if self._openEffectSerial == serial then
                safeCall(onComplete)
            end
        end)
    end)

    return true
end

function ChestController:_collectDropRows(rateList)
    local rows = {}
    if not rateList then
        return rows
    end

    for _, child in ipairs(rateList:GetDescendants()) do
        local name = tostring(child.Name or "")
        local lowerName = string.lower(name)
        if child:IsA("GuiObject")
            and not lowerName:find("template", 1, true)
            and (
                name:match("^RateItem")
                or name:match("^RewardItem")
                or name:match("^DropItem")
            )
        then
            table.insert(rows, child)
        end
    end

    table.sort(rows, function(left, right)
        local leftOrder = left.LayoutOrder
        local rightOrder = right.LayoutOrder
        if leftOrder ~= rightOrder then
            return leftOrder < rightOrder
        end
        return left.Name < right.Name
    end)
    return rows
end

function ChestController:_updateDropRow(row, reward, totalWeight)
    if not (row and row:IsA("GuiObject")) then
        return
    end

    local hasReward = type(reward) == "table"
    row.Visible = hasReward
    if not hasReward then
        return
    end

    local percent = 0
    if totalWeight > 0 then
        percent = (tonumber(reward.weight or reward.Weight) or 0) / totalWeight * 100
    end

    local amountLabel = row:FindFirstChild("Amount", true) or row:FindFirstChild("Count", true)
    local rewardText = getRewardListText(reward, amountLabel ~= nil)
    setText(row:FindFirstChild("Name", true), rewardText)
    setText(row:FindFirstChild("RewardName", true), rewardText)
    setText(row:FindFirstChild("Title", true), rewardText)
    setText(amountLabel, getRewardAmountText(reward))
    setText(row:FindFirstChild("Rate", true), trimNumber(percent) .. "%")
    setText(row:FindFirstChild("Chance", true), trimNumber(percent) .. "%")
    setText(row:FindFirstChild("Percent", true), trimNumber(percent) .. "%")
    setText(row:FindFirstChild("DropRate", true), trimNumber(percent) .. "%")

    local icon = row:FindFirstChild("Icon", true) or row:FindFirstChild("ItemIcon", true) or row:FindFirstChild("Preview", true) or row:FindFirstChild("ImageLabel", true)
    setImage(icon, getRewardIcon(reward))
end

function ChestController:_updateUi()
    local entryVisible = isChestEntryVisible()
    local count = self:_getChestCount(ChestController.DefaultChestId)
    setGuiVisible(self._leftEntry, entryVisible)
    setButtonInteractivity(self._leftEntry, entryVisible)
    setText(self._leftInfoText, tostring(count))
    setGuiVisible(self._leftInfo, entryVisible and count > 0)
    setText(self._countText, "You have: " .. tostring(count))

    self:_setBindingEnabled(self._openOneBinding, count > 0)
    self:_setBindingEnabled(self._openAllBinding, count > 0)

    local chest = self:_getClientChestConfig(ChestController.DefaultChestId)
    local rewards = chest and type(chest.rewards) == "table" and chest.rewards or {}
    local totalWeight = 0
    for _, reward in ipairs(rewards) do
        totalWeight += math.max(0, tonumber(reward.weight or reward.Weight) or 0)
    end

    for index, row in ipairs(self._dropRows) do
        self:_updateDropRow(row, rewards[index], totalWeight)
    end
end

function ChestController:_applyPayload(payload)
    if type(payload) ~= "table" then
        return
    end
    self._latestState.chests = type(payload.chests) == "table" and payload.chests or type(payload.Chests) == "table" and payload.Chests or self._latestState.chests or {}
    self._latestState.chestConfigs = type(payload.chestConfigs) == "table" and payload.chestConfigs or type(payload.ChestConfigs) == "table" and payload.ChestConfigs or self._latestState.chestConfigs or {}
    self:_updateUi()
end

function ChestController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    if not mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local left = mainGui:FindFirstChild("Left")
    local leftEntry = left and left:FindFirstChild("Box")
    local leftInfo = leftEntry and leftEntry:FindFirstChild("Info")
    local leftInfoText = leftInfo and leftInfo:FindFirstChild("Text", true)
    setGuiVisible(leftEntry, isChestEntryVisible())
    setButtonInteractivity(leftEntry, isChestEntryVisible())
    if not isChestEntryVisible() then
        setGuiVisible(leftInfo, false)
    end
    local panel = mainGui:FindFirstChild("ChestRewards")
    local countText = panel and panel:FindFirstChild("CountText", true)
    local countdownText = panel and panel:FindFirstChild("CountdownTime", true)
    local rateList = panel and (panel:FindFirstChild("RateList", true) or panel:FindFirstChild("RewardList", true) or panel:FindFirstChild("DropList", true))
    if not (leftEntry and panel and panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self._leftEntry = leftEntry
    self._leftInfo = leftInfo
    self._leftInfoText = leftInfoText
    self._panel = panel
    self._countText = countText
    self._countdownText = countdownText
    self._dropRows = self:_collectDropRows(rateList)

    if self._panel.Visible ~= false then
        self._panel.Visible = false
    end

    local leftButton = leftEntry:IsA("GuiButton") and leftEntry or leftEntry:FindFirstChildWhichIsA("GuiButton", true)
    self:_bindButton(leftButton, function()
        if isChestEntryVisible() then
            self:Open()
        end
    end, {
        ScaleTarget = leftEntry:IsA("GuiObject") and leftEntry or leftButton,
    })

    local closeButton = panel:FindFirstChild("CloseButton", true)
    self:_bindButton(closeButton, function()
        self:Close()
    end, {
        ScaleTarget = closeButton,
        RotationTarget = closeButton,
        HoverScale = 1.08,
        HoverRotation = 20,
    })

    local openOneButton, openOneScaleTarget = findButton(panel, "OpenOneButton")
    self._openOneBinding = self:_bindButton(openOneButton, function()
        self:_requestOpen("One")
    end, {
        ScaleTarget = openOneScaleTarget or openOneButton,
        HoverScale = 1.08,
    })

    local openAllButton, openAllScaleTarget = findButton(panel, "OpenAllButton")
    self._openAllBinding = self:_bindButton(openAllButton, function()
        self:_requestOpen("All")
    end, {
        ScaleTarget = openAllScaleTarget or openAllButton,
        HoverScale = 1.08,
    })

    self:_updateUi()
    self:_updateCountdownText()
    return true
end

function ChestController:_queueBindRetry()
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
        warn("[ChestController] Could not find PlayerGui/Main/ChestRewards or Left/Box UI.")
    end)
end

function ChestController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[ChestController] Missing system events folder.")
        return
    end

    self._requestStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestChestStateSync, 10)
    self._stateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.ChestStateSync, 10)
    self._requestOpenEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestChestOpen, 10)

    if self._stateSyncEvent then
        table.insert(self._connections, self._stateSyncEvent.OnClientEvent:Connect(function(payload)
            self:_applyPayload(payload)
        end))
    end
    self:RefreshNow()
end

function ChestController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestState = {
        chests = {},
        chestConfigs = {},
    }
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self._countdownLoopSerial += 1

    self:_connectRemotes()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    self:_startCountdownLoop()

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                    self:RefreshNow()
                end)
            end
        end))
    end
end

return ChestController
