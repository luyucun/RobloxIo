--[[
脚本名字: JoinGameController
脚本文件: JoinGameController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/JoinGameController
说明: 监听 Portal 入场弹窗事件，绑定 JoinGame 的 Join/Wait 按钮和按钮缩放反馈。
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
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
        "[JoinGameController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local JoinGameController = {}

JoinGameController._localPlayer = nil
JoinGameController._connections = {}
JoinGameController._buttonBindings = {}
JoinGameController._mainGui = nil
JoinGameController._joinGameRoot = nil
JoinGameController._portalJoinPromptEvent = nil
JoinGameController._requestJoinBattleEvent = nil
JoinGameController._isOpen = false
JoinGameController._bindRetryQueued = false
JoinGameController._hiddenUiOriginalVisibleByNode = {}
JoinGameController._blurEffect = nil
JoinGameController._blurOriginalEnabled = nil
JoinGameController._isModalApplied = false
JoinGameController._panelTweens = {}
JoinGameController._panelAnimationSerial = 0

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

function JoinGameController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function JoinGameController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function JoinGameController:_setOpen(isOpen, immediate)
    if not self._joinGameRoot then
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
    local rootScale = ensureUiScale(self._joinGameRoot)
    if self._isOpen then
        self:_applyModalUi()
        self._joinGameRoot.Visible = true
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

    if not rootScale or immediate == true or not self._joinGameRoot.Visible then
        if rootScale then
            rootScale.Scale = 1
        end
        self._joinGameRoot.Visible = false
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
        self._joinGameRoot.Visible = false
        table.clear(self._panelTweens)
        self:_restoreModalUi()
    end)
end

function JoinGameController:_applyModalUi()
    if self._isModalApplied then
        return
    end

    table.clear(self._hiddenUiOriginalVisibleByNode)
    if self._mainGui then
        for _, child in ipairs(self._mainGui:GetChildren()) do
            if child:IsA("GuiObject")
                and child ~= self._joinGameRoot
                and not child:IsAncestorOf(self._joinGameRoot)
                and not self._joinGameRoot:IsAncestorOf(child)
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

function JoinGameController:_restoreModalUi()
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

function JoinGameController:_applyButtonState(binding)
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

function JoinGameController:_bindButton(button, onActivated)
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

function JoinGameController:_disconnectButtonBindings()
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

function JoinGameController:_queueBindRetry()
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
        warn("[JoinGameController] 找不到 PlayerGui/Main/JoinGame，Portal 入场弹框暂不可用。")
    end)
end

function JoinGameController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._joinGameRoot = mainGui and mainGui:FindFirstChild("JoinGame", true) or nil
    if not (self._joinGameRoot and self._joinGameRoot:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self:_setOpen(false, true)

    local joinButton = self._joinGameRoot:FindFirstChild("Join", true)
    local waitButton = self._joinGameRoot:FindFirstChild("Wait", true)

    self:_bindButton(joinButton, function()
        self:_setOpen(false)
        if self._requestJoinBattleEvent then
            self._requestJoinBattleEvent:FireServer("Join")
        end
    end)

    self:_bindButton(waitButton, function()
        self:_setOpen(false)
        if self._requestJoinBattleEvent then
            self._requestJoinBattleEvent:FireServer("Cancel")
        end
    end)

    return true
end

function JoinGameController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._portalJoinPromptEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PortalJoinPrompt)
    self._requestJoinBattleEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestJoinBattle)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, self._portalJoinPromptEvent.OnClientEvent:Connect(function(payload)
        if payload and payload.eventType == "Show" then
            if not self._joinGameRoot and not self:_bindUi(true) then
                self:_queueBindRetry()
                return
            end
            self:_setOpen(true)
        elseif payload and payload.eventType == "Hide" then
            self:_setOpen(false)
        end
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

return JoinGameController
