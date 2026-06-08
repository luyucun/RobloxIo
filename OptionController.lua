--[[
Script: OptionController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/OptionController
Purpose: V3.6 settings panel bindings and persisted Music/Sfx toggles.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
        "[OptionController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local OptionController = {}

OptionController._localPlayer = nil
OptionController._audioSettings = nil
OptionController._connections = {}
OptionController._buttonBindings = {}
OptionController._panelTweens = {}
OptionController._mainGui = nil
OptionController._panel = nil
OptionController._entryButton = nil
OptionController._musicButton = nil
OptionController._sfxButton = nil
OptionController._playerStateSyncEvent = nil
OptionController._requestStateSyncEvent = nil
OptionController._requestOptionUpdateEvent = nil
OptionController._bindRetryQueued = false
OptionController._isOpen = false
OptionController._musicEnabled = true
OptionController._sfxEnabled = true
OptionController._panelAnimationSerial = 0

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.1
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

local function setTextValue(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function setVisibleTextNode(root, nodeName, visible, textValue)
    if not root then
        return false
    end

    local didUpdate = false
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant.Name == nodeName and (descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox")) then
            descendant.Visible = visible == true
            setTextValue(descendant, textValue)
            didUpdate = true
        end
    end
    return didUpdate
end

local function setEnabledByName(root, childName, enabled)
    if not root then
        return
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant.Name == childName and (descendant:IsA("UIGradient") or descendant:IsA("UIStroke")) then
            descendant.Enabled = enabled == true
        end
    end
end

local function applyToggleEffects(root, enabled)
    setEnabledByName(root, "BannerYellowGreen", enabled == true)
    setEnabledByName(root, "BannerRed", enabled ~= true)
    setEnabledByName(root, "UIStrokeYellowGreen", enabled == true)
    setEnabledByName(root, "UIStrokeRed", enabled ~= true)
end

local function applyToggleVisual(button, enabled)
    if not (button and button:IsA("GuiObject")) then
        return
    end

    local labelText = enabled and "on" or "off"
    setTextValue(button, labelText)
    setTextValue(button:FindFirstChild("Text"), labelText)
    for _, descendant in ipairs(button:GetDescendants()) do
        if descendant.Name == "Text" then
            setTextValue(descendant, labelText)
        end
    end
    local hasOnOffLabels = setVisibleTextNode(button, "ON", enabled == true, "on")
    hasOnOffLabels = setVisibleTextNode(button, "OFF", enabled ~= true, "off") or hasOnOffLabels
    if not hasOnOffLabels then
        setTextValue(button:FindFirstChild("ON"), labelText)
        setTextValue(button:FindFirstChild("OFF"), labelText)
    end

    applyToggleEffects(button, enabled)
    applyToggleEffects(button.Parent, enabled)
end

local function playTween(binding, key, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existing = binding.tweens[key]
    if existing then
        existing:Cancel()
        binding.tweens[key] = nil
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

function OptionController:_applyButtonState(binding)
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

    playTween(binding, "scale", binding.uiScale, tweenInfo, { Scale = scale })
    if binding.rotationTarget then
        playTween(binding, "rotation", binding.rotationTarget, tweenInfo, { Rotation = rotation })
    end
end

function OptionController:_bindButton(button, onActivated, options)
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

function OptionController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
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

function OptionController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function OptionController:_applyOptions(options)
    if type(options) ~= "table" then
        return
    end

    if type(options.musicEnabled) == "boolean" then
        self._musicEnabled = options.musicEnabled
    elseif type(options.Music) == "boolean" then
        self._musicEnabled = options.Music
    end

    if type(options.sfxEnabled) == "boolean" then
        self._sfxEnabled = options.sfxEnabled
    elseif type(options.Sfx) == "boolean" then
        self._sfxEnabled = options.Sfx
    end

    applyToggleVisual(self._musicButton, self._musicEnabled)
    applyToggleVisual(self._sfxButton, self._sfxEnabled)

    if self._audioSettings and self._audioSettings.ApplyOptions then
        self._audioSettings:ApplyOptions({
            musicEnabled = self._musicEnabled,
            sfxEnabled = self._sfxEnabled,
        })
    end
end

function OptionController:_sendOptionUpdate(optionKey, enabled)
    if not self._requestOptionUpdateEvent then
        return
    end

    if optionKey == "Music" then
        self._requestOptionUpdateEvent:FireServer({
            musicEnabled = enabled == true,
        })
    elseif optionKey == "Sfx" then
        self._requestOptionUpdateEvent:FireServer({
            sfxEnabled = enabled == true,
        })
    end
end

function OptionController:_toggleMusic()
    self._musicEnabled = not self._musicEnabled
    self:_applyOptions({
        musicEnabled = self._musicEnabled,
        sfxEnabled = self._sfxEnabled,
    })
    self:_sendOptionUpdate("Music", self._musicEnabled)
end

function OptionController:_toggleSfx()
    self._sfxEnabled = not self._sfxEnabled
    self:_applyOptions({
        musicEnabled = self._musicEnabled,
        sfxEnabled = self._sfxEnabled,
    })
    self:_sendOptionUpdate("Sfx", self._sfxEnabled)
end

function OptionController:_setOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:PlayPanelClose("Option", nil, { Immediate = true })
        end
        return
    end

    self._isOpen = isOpen == true

    if self._isOpen then
        if self._requestStateSyncEvent then
            self._requestStateSyncEvent:FireServer()
        end
        ModalUiController:PlayPanelOpen("Option", self._panel, {
            Immediate = immediate == true,
        })
        return
    end

    ModalUiController:PlayPanelClose("Option", self._panel, {
        Immediate = immediate == true,
    })
end

function OptionController:_bindUi(silent)
    self:_disconnectButtonBindings()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local topRightGui = self._mainGui:FindFirstChild("TopRightGui")
    local optionEntry = topRightGui and topRightGui:FindFirstChild("Options")
    self._entryButton = optionEntry and optionEntry:FindFirstChild("Button", true)
    self._panel = self._mainGui:FindFirstChild("Option")
    if not (self._entryButton and self._entryButton:IsA("GuiButton") and self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local title = self._panel:FindFirstChild("Title")
    local closeButton = title and title:FindFirstChild("CloseButton", true)
    local musicFrame = self._panel:FindFirstChild("Music")
    local sfxFrame = self._panel:FindFirstChild("Sfx")
    self._musicButton = musicFrame and musicFrame:FindFirstChild("CloseButton", true)
    self._sfxButton = sfxFrame and sfxFrame:FindFirstChild("CloseButton", true)
    if not (closeButton and closeButton:IsA("GuiButton") and self._musicButton and self._musicButton:IsA("GuiButton") and self._sfxButton and self._sfxButton:IsA("GuiButton")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._panel.Visible = false
    self:_applyOptions({
        musicEnabled = self._musicEnabled,
        sfxEnabled = self._sfxEnabled,
    })

    self:_bindButton(self._entryButton, function()
        self:_setOpen(true)
    end, {
        ScaleTarget = self._entryButton,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
    })

    self:_bindButton(closeButton, function()
        self:_setOpen(false)
    end, {
        ScaleTarget = closeButton,
        RotationTarget = closeButton,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindButton(self._musicButton, function()
        self:_toggleMusic()
    end, {
        ScaleTarget = self._musicButton,
    })

    self:_bindButton(self._sfxButton, function()
        self:_toggleSfx()
    end, {
        ScaleTarget = self._sfxButton,
    })

    return true
end

function OptionController:_queueBindRetry()
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
        warn("[OptionController] Could not find PlayerGui/Main/Option UI.")
    end)
end

function OptionController:_connectRemotes()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEventsFolder = eventsRoot and eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEventsFolder then
        warn("[OptionController] Missing system events folder.")
        return
    end

    self._playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync, 10)
    self._requestStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestOptionStateSync, 10)
    self._requestOptionUpdateEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestOptionUpdate, 10)

    if self._playerStateSyncEvent then
        table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
            if type(payload) == "table" then
                self:_applyOptions(payload.options)
            end
        end))
    end
end

function OptionController:Open()
    if not self._panel then
        self:_bindUi(true)
    end
    self:_setOpen(true)
end

function OptionController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_cancelPanelTweens()

    self:_connectRemotes()
    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi(true)
                    if self._requestStateSyncEvent then
                        self._requestStateSyncEvent:FireServer()
                    end
                end)
            end
        end))
    end

    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer()
    end
end

return OptionController
