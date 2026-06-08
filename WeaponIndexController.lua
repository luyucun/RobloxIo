--[[
脚本名字: WeaponIndexController
脚本文件: WeaponIndexController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/WeaponIndexController
说明: 绑定武器图鉴入口，生成武器列表，并根据玩家历史最高等级显示解锁状态。
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
        "[WeaponIndexController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local WeaponIndexController = {}

WeaponIndexController._localPlayer = nil
WeaponIndexController._connections = {}
WeaponIndexController._buttonBindings = {}
WeaponIndexController._mainGui = nil
WeaponIndexController._panel = nil
WeaponIndexController._leftEntry = nil
WeaponIndexController._progressLabel = nil
WeaponIndexController._scrollingFrame = nil
WeaponIndexController._template = nil
WeaponIndexController._latestState = nil
WeaponIndexController._bindRetryQueued = false
WeaponIndexController._panelTweens = {}
WeaponIndexController._panelAnimationSerial = 0
WeaponIndexController._isPanelOpen = false
WeaponIndexController._generatedRowsByTier = {}
WeaponIndexController._layoutConnection = nil

local GENERATED_ROW_ATTRIBUTE = "WeaponIndexGenerated"
local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.18
local OPEN_SETTLE_DURATION = 0.12
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local UNLOCKED_ICON_COLOR = Color3.fromRGB(255, 255, 255)
local LOCKED_ICON_COLOR = Color3.fromRGB(0, 0, 0)

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

local function setText(parent, childName, value)
    local textObject = parent and parent:FindFirstChild(childName, true) or nil
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function setImage(parent, childName, image, color)
    local imageObject = parent and parent:FindFirstChild(childName, true) or nil
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(image or "")
        imageObject.ImageColor3 = color or UNLOCKED_ICON_COLOR
        imageObject.ImageTransparency = 0
    end
end

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function getLayout(scrollingFrame)
    if not scrollingFrame then
        return nil
    end
    return scrollingFrame:FindFirstChildOfClass("UIListLayout") or scrollingFrame:FindFirstChildOfClass("UIGridLayout")
end

local function updateCanvasSize(scrollingFrame)
    if not (scrollingFrame and scrollingFrame:IsA("ScrollingFrame")) then
        return
    end

    local layout = getLayout(scrollingFrame)
    if layout then
        scrollingFrame.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y)
    end
end

local function isGeneratedWeaponRow(instance)
    if not instance then
        return false
    end
    if instance:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
        return true
    end
    return string.match(tostring(instance.Name or ""), "^WeaponIndex_%d+$") ~= nil
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

local function getUnlockLevelForTierIndex(tierIndex)
    local level = 1
    local normalizedTierIndex = math.max(1, math.floor(tonumber(tierIndex) or 1))
    for index = 1, normalizedTierIndex - 1 do
        local tierName = WeaponTierConfig.Order[index]
        local tierConfig = tierName and WeaponTierConfig.Tiers[tierName] or nil
        local maxCount = math.max(1, math.floor(tonumber(tierConfig and tierConfig.MaxCount) or WeaponTierConfig.MaxCountPerTier or 10))
        level += maxCount
    end
    return level
end

local function getMaxUnlockedTierIndexForLevel(level)
    local highestLevelReached = math.max(1, math.floor(tonumber(level) or 1))
    local maxUnlockedTierIndex = 0
    for index in ipairs(WeaponTierConfig.Order) do
        if highestLevelReached >= getUnlockLevelForTierIndex(index) then
            maxUnlockedTierIndex = index
        else
            break
        end
    end
    return maxUnlockedTierIndex
end

function WeaponIndexController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function WeaponIndexController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function WeaponIndexController:_getHighestLevelReached()
    local state = self._latestState or {}
    local level = tonumber(state.highestLevelReached) or tonumber(state.level) or 1
    return math.max(1, math.floor(level))
end

function WeaponIndexController:_updateProgressLabel()
    if not (self._progressLabel and self._progressLabel.Parent) then
        return
    end

    local totalTierCount = math.max(0, math.floor(tonumber(WeaponTierConfig.TotalTierCount) or #WeaponTierConfig.Order))
    if totalTierCount <= 0 then
        self._progressLabel.Text = "0%"
        return
    end

    local unlockedTierCount = math.clamp(getMaxUnlockedTierIndexForLevel(self:_getHighestLevelReached()), 0, totalTierCount)
    local progressPercent = math.floor((unlockedTierCount / totalTierCount) * 100)
    self._progressLabel.Text = tostring(progressPercent) .. "%"
end

function WeaponIndexController:_clearGeneratedRows()
    if not self._scrollingFrame then
        table.clear(self._generatedRowsByTier)
        return
    end

    for _, child in ipairs(self._scrollingFrame:GetChildren()) do
        if isGeneratedWeaponRow(child) then
            child:Destroy()
        end
    end

    if self._template and self._template:IsA("GuiObject") then
        self._template.Visible = false
    end
    table.clear(self._generatedRowsByTier)
end

function WeaponIndexController:_updateWeaponRows()
    local highestLevelReached = self:_getHighestLevelReached()
    self:_updateProgressLabel()

    for index, tierName in ipairs(WeaponTierConfig.Order) do
        local tierConfig = WeaponTierConfig.Tiers[tierName]
        local row = self._generatedRowsByTier[tierName]
        if tierConfig and row and row.Parent then
            local tierIndex = tonumber(tierConfig.TierIndex) or index
            local unlockLevel = getUnlockLevelForTierIndex(tierIndex)
            local isUnlocked = highestLevelReached >= unlockLevel
            local iconImage = tierConfig.IconImage or WeaponTierConfig.GetIconImageForTier(tierName)

            row.Visible = true
            row.LayoutOrder = index
            setImage(row, "Icon", iconImage, isUnlocked and UNLOCKED_ICON_COLOR or LOCKED_ICON_COLOR)
            setText(row, "Atk", isUnlocked and ("ATK:" .. formatInteger(tierConfig.Damage)) or "ATK:???")
            setText(row, "Level", "Lv." .. formatInteger(unlockLevel))
        end
    end

    updateCanvasSize(self._scrollingFrame)
end

function WeaponIndexController:_buildWeaponRows()
    if not (self._scrollingFrame and self._template and self._template:IsA("GuiObject")) then
        return false
    end

    self:_clearGeneratedRows()
    self._template.Visible = false

    for index, tierName in ipairs(WeaponTierConfig.Order) do
        local tierConfig = WeaponTierConfig.Tiers[tierName]
        if tierConfig then
            local row = self._template:Clone()
            row.Name = string.format("WeaponIndex_%03d", math.max(1, math.floor(tonumber(tierConfig.TierIndex) or index)))
            row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
            row:SetAttribute("WeaponTier", tierName)
            row.LayoutOrder = index
            row.Visible = true
            row.Parent = self._scrollingFrame
            self._generatedRowsByTier[tierName] = row
        end
    end

    self:_updateWeaponRows()
    return true
end

function WeaponIndexController:_bindCanvasResize()
    if self._layoutConnection then
        self._layoutConnection:Disconnect()
        self._layoutConnection = nil
    end

    local layout = getLayout(self._scrollingFrame)
    if layout then
        self._layoutConnection = layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            updateCanvasSize(self._scrollingFrame)
        end)
    end
    updateCanvasSize(self._scrollingFrame)
end

function WeaponIndexController:_setPanelOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isPanelOpen = false
            ModalUiController:PlayPanelClose("WeaponIndex", nil, { Immediate = true })
        end
        return
    end

    self._isPanelOpen = isOpen == true

    if self._isPanelOpen then
        if not next(self._generatedRowsByTier) then
            self:_buildWeaponRows()
            self:_bindCanvasResize()
        else
            self:_updateWeaponRows()
        end
        ModalUiController:PlayPanelOpen("WeaponIndex", self._panel, {
            Immediate = immediate == true,
        })
        return
    end

    ModalUiController:PlayPanelClose("WeaponIndex", self._panel, {
        Immediate = immediate == true,
    })
end

function WeaponIndexController:_applyButtonState(binding)
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

    playTween(binding, "scale", binding.uiScale, tweenInfo, {
        Scale = scale,
    })

    if binding.rotationTarget then
        playTween(binding, "rotation", binding.rotationTarget, tweenInfo, {
            Rotation = rotation,
        })
    end
end

function WeaponIndexController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = (type(options) == "table" and options.ScaleTarget) or button
    local rotationTarget = (type(options) == "table" and options.RotationTarget) or nil
    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        scaleTarget = scaleTarget,
        rotationTarget = rotationTarget,
        baseScale = uiScale.Scale,
        baseRotation = rotationTarget and rotationTarget.Rotation or 0,
        hoverScale = (type(options) == "table" and tonumber(options.HoverScale)) or HOVER_SCALE,
        pressScale = (type(options) == "table" and tonumber(options.PressScale)) or PRESS_SCALE,
        hoverRotation = (type(options) == "table" and tonumber(options.HoverRotation)) or 0,
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

function WeaponIndexController:_disconnectButtonBindings()
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

function WeaponIndexController:_resolveEntryScaleTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    local label = self._leftEntry:FindFirstChild("TextLabel", true)
    if label and label:IsA("GuiObject") then
        return label
    end

    return self._leftEntry
end

function WeaponIndexController:_resolveEntryRotationTarget()
    if not self._leftEntry then
        return nil
    end

    local icon = self._leftEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveEntryScaleTarget()
end

function WeaponIndexController:_queueBindRetry()
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
        warn("[WeaponIndexController] 找不到 PlayerGui/Main/Index 或对应模板，武器图鉴暂不可用。")
    end)
end

function WeaponIndexController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("Index") or nil
    local leftRoot = mainGui and mainGui:FindFirstChild("Left") or nil
    self._leftEntry = leftRoot and leftRoot:FindFirstChild("Index") or nil
    self._progressLabel = self._leftEntry and self._leftEntry:FindFirstChild("Progress", true) or nil
    local indexInfo = self._panel and self._panel:FindFirstChild("Indexinfo") or nil
    self._scrollingFrame = indexInfo and indexInfo:FindFirstChild("ScrollingFrame") or nil
    self._template = self._scrollingFrame and self._scrollingFrame:FindFirstChild("Template") or nil
    table.clear(self._generatedRowsByTier)

    if not (
        self._panel and self._panel:IsA("GuiObject")
        and self._leftEntry and self._leftEntry:IsA("GuiObject")
        and self._scrollingFrame and self._scrollingFrame:IsA("ScrollingFrame")
        and self._template and self._template:IsA("GuiObject")
    ) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    if self._isPanelOpen then
        ModalUiController:PlayPanelOpen("WeaponIndex", self._panel, {
            Immediate = true,
        })
    else
        self:_setPanelOpen(false, true)
    end
    self:_buildWeaponRows()
    self:_bindCanvasResize()

    local openButton = self._leftEntry:FindFirstChild("TextButton", true)
    local closeButton = self._panel:FindFirstChild("CloseButton", true)
    local entryScaleTarget = self:_resolveEntryScaleTarget()
    local entryRotationTarget = self:_resolveEntryRotationTarget()

    self:_bindButton(openButton, function()
        self:_setPanelOpen(true)
    end, {
        ScaleTarget = entryScaleTarget or openButton,
        RotationTarget = entryRotationTarget,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        HoverRotation = HOVER_ROTATION,
    })

    self:_bindButton(closeButton, function()
        self:_setPanelOpen(false)
    end, {
        ScaleTarget = closeButton,
        RotationTarget = closeButton,
        HoverScale = 1.12,
        PressScale = 0.92,
        HoverRotation = HOVER_ROTATION,
    })

    return true
end

function WeaponIndexController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_cancelPanelTweens()
    if self._layoutConnection then
        self._layoutConnection:Disconnect()
        self._layoutConnection = nil
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestState = payload
        self:_updateWeaponRows()
    end))

    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        requestStateSyncEvent:FireServer()
    end

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

return WeaponIndexController
