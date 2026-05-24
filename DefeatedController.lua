--[[
Script: DefeatedController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/DefeatedController
Purpose: Handles V1.6 defeated revive/revenge UI.
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
        "[DefeatedController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local DefeatedController = {}

DefeatedController._localPlayer = nil
DefeatedController._connections = {}
DefeatedController._buttonBindings = {}
DefeatedController._mainGui = nil
DefeatedController._defeatedRoot = nil
DefeatedController._requestDefeatedActionEvent = nil
DefeatedController._countdownConnection = nil
DefeatedController._isOpen = false
DefeatedController._isRevengePurchasePending = false
DefeatedController._isRevivePurchasePending = false
DefeatedController._countdownEndsAt = 0
DefeatedController._bindRetryQueued = false
DefeatedController._panelTweens = {}
DefeatedController._panelAnimationSerial = 0

local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.92
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.84
local OPEN_OVERSHOOT_SCALE = 1.05
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local DEFEATED_MODAL_OWNER = "Defeated"

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

local function setImage(imageObject, image)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(image or "")
    end
end

local function findNested(root, path)
    local current = root
    for part in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(part)
    end
    return current
end

local function getReviveCountdownDuration()
    return math.max(1, tonumber(GameConfig.RESPAWN.PlayerKillReviveCountdownSeconds) or 15)
end

function DefeatedController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function DefeatedController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function DefeatedController:_setProgress(ratio, secondsLeft)
    if not self._defeatedRoot then
        return
    end

    local progress = findNested(self._defeatedRoot, "ProgressBg/Progress")
    if progress and progress:IsA("GuiObject") then
        progress.Size = UDim2.fromScale(math.clamp(tonumber(ratio) or 0, 0, 1), 1)
    end

    setText(self._defeatedRoot:FindFirstChild("Time", true), string.format("%dS", math.max(0, math.ceil(tonumber(secondsLeft) or 0))))
end

function DefeatedController:_stopCountdown()
    if self._countdownConnection then
        self._countdownConnection:Disconnect()
        self._countdownConnection = nil
    end
end

function DefeatedController:_startCountdown(existingEndsAt)
    self:_stopCountdown()
    local duration = getReviveCountdownDuration()
    self._countdownEndsAt = tonumber(existingEndsAt) or (os.clock() + duration)
    local initialSecondsLeft = math.max(0, self._countdownEndsAt - os.clock())
    self:_setProgress(initialSecondsLeft / duration, initialSecondsLeft)

    self._countdownConnection = RunService.RenderStepped:Connect(function()
        if not self._isOpen then
            return
        end

        local secondsLeft = math.max(0, self._countdownEndsAt - os.clock())
        self:_setProgress(secondsLeft / duration, secondsLeft)
        if secondsLeft <= 0 then
            self:_closeAndRequest("Revive")
        end
    end)
end

function DefeatedController:_resumeCountdownAfterRevengeCancel()
    if not self._isOpen then
        return
    end

    if self._countdownEndsAt <= os.clock() then
        self:_closeAndRequest("Revive")
        return
    end

    self:_startCountdown(self._countdownEndsAt)
end

function DefeatedController:_resumeCountdownAfterRevivePurchaseCancel()
    if not self._isOpen then
        return
    end

    if self._countdownEndsAt <= os.clock() then
        self:_closeAndRequest("Revive")
        return
    end

    self:_startCountdown(self._countdownEndsAt)
end

function DefeatedController:_setOpen(isOpen, immediate)
    if not self._defeatedRoot then
        self._isOpen = false
        self:_cancelPanelTweens()
        ModalUiController:Release(DEFEATED_MODAL_OWNER)
        self:_stopCountdown()
        return
    end

    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isOpen = isOpen == true
    local rootScale = ensureUiScale(self._defeatedRoot)
    if self._isOpen then
        ModalUiController:AcquireExclusive(DEFEATED_MODAL_OWNER, self._defeatedRoot)
        self._defeatedRoot.Visible = true
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

    self:_stopCountdown()
    self._isRevengePurchasePending = false
    if not rootScale or immediate == true or not self._defeatedRoot.Visible then
        if rootScale then
            rootScale.Scale = 1
        end
        self._defeatedRoot.Visible = false
        ModalUiController:Release(DEFEATED_MODAL_OWNER)
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
        self._defeatedRoot.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release(DEFEATED_MODAL_OWNER)
    end)
end

function DefeatedController:_closeAndRequest(action)
    self:_setOpen(false)
    if self._requestDefeatedActionEvent then
        self._requestDefeatedActionEvent:FireServer(action)
    end
end

function DefeatedController:_promptRevenge()
    if self._isRevengePurchasePending then
        return
    end

    local productId = GameConfig.MONETIZATION and GameConfig.MONETIZATION.RevengeProductId or 0
    if not (productId and productId > 0) then
        warn("[DefeatedController] Revenge product id is not configured.")
        return
    end

    self._isRevengePurchasePending = true
    self:_stopCountdown()
    if self._requestDefeatedActionEvent then
        self._requestDefeatedActionEvent:FireServer("Revenge")
    end

    local ok, err = pcall(function()
        MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
    end)
    if not ok then
        warn("[DefeatedController] Failed to prompt revenge product purchase:", err)
        self._isRevengePurchasePending = false
        if self._requestDefeatedActionEvent then
            self._requestDefeatedActionEvent:FireServer("RevengeCancel")
        end
        self:_resumeCountdownAfterRevengeCancel()
    end
end

function DefeatedController:_promptDefeatedRevive()
    if self._isRevivePurchasePending then
        return
    end

    local productId = GameConfig.MONETIZATION and GameConfig.MONETIZATION.DefeatedReviveProductId or 0
    if not (productId and productId > 0) then
        warn("[DefeatedController] Defeated revive product id is not configured.")
        return
    end

    self._isRevivePurchasePending = true
    if self._requestDefeatedActionEvent then
        self._requestDefeatedActionEvent:FireServer("RevivePurchase")
    end

    local ok, err = pcall(function()
        MarketplaceService:PromptProductPurchase(self._localPlayer, productId)
    end)
    if not ok then
        warn("[DefeatedController] Failed to prompt defeated revive product purchase:", err)
        self._isRevivePurchasePending = false
        if self._requestDefeatedActionEvent then
            self._requestDefeatedActionEvent:FireServer("RevivePurchaseCancel")
        end
        self:_resumeCountdownAfterRevivePurchaseCancel()
    end
end

function DefeatedController:_updateKillerInfo(payload)
    if not self._defeatedRoot then
        return
    end

    local killer = payload and payload.killer or nil
    local killerName = killer and killer.name or "Unknown"
    local killerLevel = killer and killer.level or GameConfig.PLAYER.BaseLevel
    local victimLevel = math.max(1, math.floor(tonumber(payload and payload.victimLevel) or GameConfig.PLAYER.BaseLevel))
    local killerKillCount = math.max(0, math.floor(tonumber(killer and (killer.totalPlayerKills or killer.killCount)) or 0))
    setText(findNested(self._defeatedRoot, "Killer/Name"), killerName)
    setText(findNested(self._defeatedRoot, "Killer/KillNum/Num"), tostring(killerKillCount))
    setText(findNested(self._defeatedRoot, "Killer/LvInfo/Num"), string.format("LV.%d", math.max(1, math.floor(tonumber(killerLevel) or 1))))
    setText(findNested(self._defeatedRoot, "Revive/Level"), string.format("With Lv.%d", victimLevel))

    local icon = findNested(self._defeatedRoot, "Killer/Icon")
    local userId = killer and tonumber(killer.userId) or nil
    if icon and userId and userId > 0 then
        task.spawn(function()
            local ok, thumbnail = pcall(function()
                return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
            end)
            if ok and self._isOpen then
                setImage(icon, thumbnail)
            end
        end)
    end
end

function DefeatedController:_cancelBindingTween(binding)
    if binding.tween then
        binding.tween:Cancel()
        binding.tween = nil
    end
end

function DefeatedController:_applyButtonState(binding)
    local scale = binding.baseScale
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * PRESS_SCALE
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * HOVER_SCALE
        tweenInfo = HOVER_TWEEN_INFO
    end

    self:_cancelBindingTween(binding)
    local tween = TweenService:Create(binding.uiScale, tweenInfo, {
        Scale = scale,
    })
    binding.tween = tween
    tween.Completed:Connect(function()
        if binding.tween == tween then
            binding.tween = nil
        end
    end)
    tween:Play()
end

function DefeatedController:_bindClickTarget(guiObject, onActivated)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return
    end

    guiObject.Active = true
    local uiScale = ensureUiScale(guiObject)
    if not uiScale then
        return
    end

    local binding = {
        target = guiObject,
        uiScale = uiScale,
        baseScale = uiScale.Scale,
        isHovered = false,
        isPressed = false,
        tween = nil,
        connections = {},
    }

    if guiObject:IsA("GuiButton") then
        table.insert(binding.connections, guiObject.Activated:Connect(function()
            onActivated()
        end))
    end

    table.insert(binding.connections, guiObject.MouseEnter:Connect(function()
        binding.isHovered = true
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, guiObject.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, guiObject.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, guiObject.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            local wasPressed = binding.isPressed
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            self:_applyButtonState(binding)
            if wasPressed and not guiObject:IsA("GuiButton") then
                onActivated()
            end
        end
    end))

    table.insert(self._buttonBindings, binding)
end

function DefeatedController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        self:_cancelBindingTween(binding)
        disconnectAll(binding.connections)
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale or 1
        end
    end
    table.clear(self._buttonBindings)
end

function DefeatedController:_queueBindRetry()
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
        warn("[DefeatedController] Could not find PlayerGui/Main/Defeated.")
    end)
end

function DefeatedController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._defeatedRoot = mainGui and mainGui:FindFirstChild("Defeated", true) or nil
    if not (self._defeatedRoot and self._defeatedRoot:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self:_setOpen(false, true)
    self:_bindClickTarget(self._defeatedRoot:FindFirstChild("Revive", true), function()
        self:_promptDefeatedRevive()
    end)
    self:_bindClickTarget(self._defeatedRoot:FindFirstChild("Revenge", true), function()
        self:_promptRevenge()
    end)
    self:_bindClickTarget(findNested(self._defeatedRoot, "Title/CloseButton"), function()
        self:_closeAndRequest("Close")
    end)
    return true
end

function DefeatedController:_onDeathFeedback(payload)
    if not (payload and payload.killer and payload.killer.userId) then
        return
    end
    if not self._defeatedRoot and not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    self:_updateKillerInfo(payload)
    self._isRevengePurchasePending = false
    self._isRevivePurchasePending = false
    self:_setOpen(true)
    self:_startCountdown()
end

function DefeatedController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_stopCountdown()

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._requestDefeatedActionEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestDefeatedAction)
    local deathFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.DeathFeedback)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, deathFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_onDeathFeedback(payload)
    end))

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        if self._isOpen and payload and payload.alive == true and payload.isInArena == true then
            self:_setOpen(false)
        end
    end))

    table.insert(self._connections, MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
        local localUserId = self._localPlayer and self._localPlayer.UserId
        local revengeProductId = GameConfig.MONETIZATION and GameConfig.MONETIZATION.RevengeProductId or 0
        local defeatedReviveProductId = GameConfig.MONETIZATION and GameConfig.MONETIZATION.DefeatedReviveProductId or 0
        if tonumber(userId) ~= tonumber(localUserId) then
            return
        end

        if tonumber(productId) == tonumber(defeatedReviveProductId) then
            if not self._isRevivePurchasePending then
                return
            end

            self._isRevivePurchasePending = false
            if wasPurchased == true then
                self:_setOpen(false)
                return
            end

            if self._requestDefeatedActionEvent then
                self._requestDefeatedActionEvent:FireServer("RevivePurchaseCancel")
            end
            self:_resumeCountdownAfterRevivePurchaseCancel()
            return
        end

        if tonumber(productId) ~= tonumber(revengeProductId) then
            return
        end
        if not self._isRevengePurchasePending then
            return
        end

        self._isRevengePurchasePending = false
        if wasPurchased == true then
            return
        end

        if self._requestDefeatedActionEvent then
            self._requestDefeatedActionEvent:FireServer("RevengeCancel")
        end
        self:_resumeCountdownAfterRevengeCancel()
    end))

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                end)
            end
        end))
    end
end

return DefeatedController
