--[[
Script: ModalUiController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/ModalUiController
Purpose: Shared modal UI suppression and blur handling for Main screen panels.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ModalUiController = {}

ModalUiController._owners = {}
ModalUiController._hiddenOriginalVisibleByNode = {}
ModalUiController._mainGui = nil
ModalUiController._blurEffect = nil
ModalUiController._blurOriginalEnabled = nil
ModalUiController._childAddedConnection = nil
ModalUiController._dimOverlay = nil
ModalUiController._dimOverlayTween = nil
ModalUiController._hiddenVisibleConnectionsByNode = {}
ModalUiController._dormantRootStatesByRoot = {}
ModalUiController._dormantRootConnectionsByRoot = {}
ModalUiController._dormantRootPrepared = false
ModalUiController._panelMotionStatesByPanel = setmetatable({}, { __mode = "k" })
ModalUiController._buttonMotionCleanupsByButton = setmetatable({}, { __mode = "k" })
ModalUiController._mainEntryMotionBindingsByButton = setmetatable({}, { __mode = "k" })
ModalUiController._mainEntryMotionSerial = 0

local DEFAULT_PANEL_MOTION = {
    OpenFromScale = 0.9,
    OpenOvershootScale = 1.035,
    OpenOvershootDuration = 0.17,
    OpenSettleDuration = 0.07,
    CloseLiftScale = 1.015,
    CloseLiftDuration = 0.05,
    CloseToScale = 0.94,
    CloseShrinkDuration = 0.12,
}

local DEFAULT_BUTTON_MOTION = {
    HoverScale = 1.045,
    PressScale = 0.92,
    HoverRotation = 0,
    PressRotation = 0,
    HoverDuration = 0.1,
    PressDuration = 0.06,
    ReleaseDuration = 0.12,
    HoverOvershootMultiplier = 1.035,
    HoverRotationOvershootMultiplier = 1.18,
    HoverSettleDuration = 0.08,
    ReleaseUndershootScale = 0.975,
    ReleaseRotationOvershootRatio = 0.16,
    ReleaseSettleDuration = 0.11,
}

local DIM_OVERLAY_NAME = "__ModalDimOverlay"
local DIM_OVERLAY_VISIBLE_TRANSPARENCY = 0.42
local DIM_OVERLAY_FADE_IN_DURATION = 0.14
local DIM_OVERLAY_FADE_OUT_DURATION = 0.1

local DEFAULT_DORMANT_ROOT_NAMES = {
    "Index",
    "Shop",
    "Sevendays",
    "SevendaysRepeat",
    "SevenDays",
    "Skin",
    "Upgrade",
    "RewardClaimTips",
    "SugarClub",
    "Potion",
    "WheelBg",
    "WheelClaim",
    "Rebirth",
    "GroupReward",
    "OnlineReward",
    "Option",
    "NewWeaponUnlock",
    "Defeated",
    "FriendsRanking",
}

local DORMANT_ROOT_EXCLUDED_NAMES = {
    TitleUnlock = true,
}

local function findBlurEffect()
    local blur = Lighting:FindFirstChild("Blur")
    if blur and blur:IsA("BlurEffect") then
        return blur
    end

    blur = Lighting:FindFirstChild("Blur", true)
    if blur and blur:IsA("BlurEffect") then
        return blur
    end

    return nil
end

local function findMainGuiFromPanel(panel)
    local current = panel
    while current do
        if current:IsA("ScreenGui") and current.Name == "Main" then
            return current
        end
        current = current.Parent
    end

    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    return playerGui and (playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)) or nil
end

local function normalizeOwnerId(ownerId)
    local ownerKey = tostring(ownerId or "")
    if ownerKey == "" then
        ownerKey = "Modal"
    end
    return ownerKey
end

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
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

local function getMotionNumber(options, key)
    local defaultValue = DEFAULT_PANEL_MOTION[key]
    if type(options) ~= "table" then
        return defaultValue
    end

    local value = tonumber(options[key])
    if value == nil then
        return defaultValue
    end
    return value
end

local function getButtonMotionNumber(options, key)
    local defaultValue = DEFAULT_BUTTON_MOTION[key]
    if type(options) ~= "table" then
        return defaultValue
    end

    local value = tonumber(options[key])
    if value == nil then
        return defaultValue
    end
    return value
end

local function shouldEnableButtonMotionOption(options, key)
    return type(options) == "table" and options[key] == true
end

local function collectSiblingTextScaleTargets(button, options)
    local targets = {}
    local seen = {}

    local function addTarget(target)
        if not (target and target:IsA("TextLabel") and target ~= button and not seen[target]) then
            return
        end
        seen[target] = true
        table.insert(targets, target)
    end

    if type(options) == "table" and type(options.TextScaleTargets) == "table" then
        for _, target in ipairs(options.TextScaleTargets) do
            addTarget(target)
        end
    end

    if not shouldEnableButtonMotionOption(options, "IncludeSiblingTextScale") then
        return targets
    end

    local parent = button and button.Parent
    if not parent then
        return targets
    end

    for _, sibling in ipairs(parent:GetChildren()) do
        addTarget(sibling)
    end

    return targets
end

local function findFirstGuiButton(root)
    if not root then
        return nil
    end
    if root:IsA("GuiButton") then
        return root
    end

    local directButton = root:FindFirstChildWhichIsA("GuiButton")
    if directButton then
        return directButton
    end

    return root:FindFirstChildWhichIsA("GuiButton", true)
end

local function findRotationTargetForEntry(root, button)
    if root then
        local icon = root:FindFirstChild("Icon", true)
        if icon and icon:IsA("GuiObject") then
            return icon
        end
    end
    return button
end

local function runMotionCallback(callback)
    if type(callback) ~= "function" then
        return
    end

    local ok, err = pcall(callback)
    if not ok then
        warn("[ModalUiController] Panel motion callback failed: " .. tostring(err))
    end
end

local function isGuiImageObject(instance)
    return instance and (instance:IsA("ImageLabel") or instance:IsA("ImageButton"))
end

local function collectGuiImages(root)
    local images = {}
    if isGuiImageObject(root) then
        table.insert(images, root)
    end
    if not root then
        return images
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if isGuiImageObject(descendant) then
            table.insert(images, descendant)
        end
    end
    return images
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end

    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

function ModalUiController:_hasOwners()
    return next(self._owners) ~= nil
end

function ModalUiController:_shouldApplyBlur()
    for _, ownerState in pairs(self._owners) do
        if not (ownerState and ownerState.SkipBlur == true) then
            return true
        end
    end

    return false
end

function ModalUiController:_preparePanelMotion(panel)
    local state = self._panelMotionStatesByPanel[panel]
    if not state then
        state = {
            Tweens = {},
            Serial = 0,
        }
        self._panelMotionStatesByPanel[panel] = state
    end

    state.Serial += 1
    for _, tween in ipairs(state.Tweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(state.Tweens)

    return state, state.Serial
end

function ModalUiController:_isActivePanelChild(child)
    if child == self._dimOverlay then
        return true
    end

    for _, ownerState in pairs(self._owners) do
        for excludedNode in pairs(ownerState.SuppressExclusions or {}) do
            if excludedNode and excludedNode.Parent then
                if child == excludedNode or child:IsAncestorOf(excludedNode) or excludedNode:IsAncestorOf(child) then
                    return true
                end
            else
                ownerState.SuppressExclusions[excludedNode] = nil
            end
        end

        local panel = ownerState and ownerState.Panel
        if panel and panel.Parent then
            if child == panel or child:IsAncestorOf(panel) or panel:IsAncestorOf(child) then
                return true
            end
        end
    end
    return false
end

function ModalUiController:_getOverlayZIndex()
    local minPanelZIndex = nil
    for _, ownerState in pairs(self._owners) do
        local panel = ownerState and ownerState.Panel
        if panel and panel.Parent and panel:IsA("GuiObject") then
            local zIndex = tonumber(panel.ZIndex) or 1
            minPanelZIndex = minPanelZIndex and math.min(minPanelZIndex, zIndex) or zIndex
        end
    end

    if minPanelZIndex then
        return math.max(0, minPanelZIndex - 1)
    end
    return 0
end

function ModalUiController:_cancelDimOverlayTween()
    if self._dimOverlayTween then
        self._dimOverlayTween:Cancel()
        self._dimOverlayTween = nil
    end
end

function ModalUiController:_applyDimOverlay()
    if not self._mainGui then
        return
    end

    local overlay = self._dimOverlay
    if not (overlay and overlay.Parent == self._mainGui) then
        overlay = self._mainGui:FindFirstChild(DIM_OVERLAY_NAME)
        if not (overlay and overlay:IsA("Frame")) then
            overlay = Instance.new("Frame")
            overlay.Name = DIM_OVERLAY_NAME
            overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            overlay.BackgroundTransparency = 1
            overlay.BorderSizePixel = 0
            overlay.Size = UDim2.fromScale(1, 1)
            overlay.Position = UDim2.fromScale(0, 0)
            overlay.AnchorPoint = Vector2.new(0, 0)
            overlay.Active = false
            overlay.Selectable = false
            overlay.Parent = self._mainGui
        end
        self._dimOverlay = overlay
    end

    overlay.ZIndex = self:_getOverlayZIndex()
    overlay.Visible = true
    self:_cancelDimOverlayTween()
    local fadeInTween = TweenService:Create(overlay, TweenInfo.new(
        DIM_OVERLAY_FADE_IN_DURATION,
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out
    ), {
        BackgroundTransparency = DIM_OVERLAY_VISIBLE_TRANSPARENCY,
    })
    self._dimOverlayTween = fadeInTween
    fadeInTween.Completed:Connect(function()
        if self._dimOverlayTween == fadeInTween then
            self._dimOverlayTween = nil
        end
    end)
    fadeInTween:Play()
end

function ModalUiController:_restoreDimOverlay()
    local overlay = self._dimOverlay
    self:_cancelDimOverlayTween()
    if not (overlay and overlay.Parent) then
        self._dimOverlay = nil
        return
    end

    local fadeOutTween = TweenService:Create(overlay, TweenInfo.new(
        DIM_OVERLAY_FADE_OUT_DURATION,
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.In
    ), {
        BackgroundTransparency = 1,
    })
    self._dimOverlayTween = fadeOutTween
    fadeOutTween.Completed:Connect(function()
        if self._dimOverlayTween ~= fadeOutTween or self:_hasOwners() then
            return
        end
        if overlay and overlay.Parent then
            overlay.Visible = false
        end
        if self._dimOverlay == overlay then
            self._dimOverlay = nil
        end
        self._dimOverlayTween = nil
    end)
    fadeOutTween:Play()
end

function ModalUiController:_rememberOriginalVisible(guiObject)
    if self._hiddenOriginalVisibleByNode[guiObject] == nil then
        self._hiddenOriginalVisibleByNode[guiObject] = guiObject.Visible == true
    end
end

function ModalUiController:_ensureHiddenVisibleWatcher(guiObject)
    if self._hiddenVisibleConnectionsByNode[guiObject] then
        return
    end

    self._hiddenVisibleConnectionsByNode[guiObject] = guiObject:GetPropertyChangedSignal("Visible"):Connect(function()
        if not self:_hasOwners() or not guiObject.Parent or self:_isActivePanelChild(guiObject) then
            return
        end

        if guiObject.Visible == true then
            self._hiddenOriginalVisibleByNode[guiObject] = true
            guiObject.Visible = false
        end
    end)
end

function ModalUiController:_clearHiddenVisibleWatchers()
    for guiObject, connection in pairs(self._hiddenVisibleConnectionsByNode) do
        disconnectConnection(connection)
        self._hiddenVisibleConnectionsByNode[guiObject] = nil
    end
end

function ModalUiController:_restoreSuppressedGuiObject(guiObject)
    if not (guiObject and guiObject.Parent and guiObject:IsA("GuiObject")) then
        return
    end

    local originalVisible = self._hiddenOriginalVisibleByNode[guiObject]
    if originalVisible ~= nil then
        guiObject.Visible = originalVisible == true
        self._hiddenOriginalVisibleByNode[guiObject] = nil
    end

    disconnectConnection(self._hiddenVisibleConnectionsByNode[guiObject])
    self._hiddenVisibleConnectionsByNode[guiObject] = nil
end

function ModalUiController:_suppressGuiObject(guiObject)
    self:_rememberOriginalVisible(guiObject)
    self:_ensureHiddenVisibleWatcher(guiObject)
    if guiObject.Visible ~= false then
        guiObject.Visible = false
    end
end

function ModalUiController:_applyBlur()
    if self._blurEffect and self._blurEffect.Parent then
        self._blurEffect.Enabled = true
        return
    end

    self._blurEffect = findBlurEffect()
    if self._blurEffect then
        self._blurOriginalEnabled = self._blurEffect.Enabled == true
        self._blurEffect.Enabled = true
    else
        self._blurOriginalEnabled = nil
    end
end

function ModalUiController:_restoreBlur()
    if self._blurEffect and self._blurEffect.Parent and self._blurOriginalEnabled ~= nil then
        self._blurEffect.Enabled = self._blurOriginalEnabled == true
    end
    self._blurEffect = nil
    self._blurOriginalEnabled = nil
end

function ModalUiController:_ensureChildWatcher()
    if self._childAddedConnection or not self._mainGui then
        return
    end

    self._childAddedConnection = self._mainGui.ChildAdded:Connect(function(child)
        if not self:_hasOwners() then
            return
        end
        if child and child:IsA("GuiObject") then
            task.defer(function()
                self:_applySuppression()
            end)
        end
    end)
end

function ModalUiController:_clearChildWatcher()
    disconnectConnection(self._childAddedConnection)
    self._childAddedConnection = nil
end

function ModalUiController:_getDormantRootState(root)
    if not (root and root:IsA("GuiObject")) then
        return nil
    end

    local state = self._dormantRootStatesByRoot[root]
    if state then
        return state
    end

    state = {
        ImagesByNode = {},
        Active = false,
    }
    for _, imageObject in ipairs(collectGuiImages(root)) do
        state.ImagesByNode[imageObject] = imageObject.Image
    end
    self._dormantRootStatesByRoot[root] = state
    return state
end

function ModalUiController:DeactivateDormantRoot(root)
    local state = self:_getDormantRootState(root)
    if not state or state.Active == false then
        return
    end

    for imageObject, originalImage in pairs(state.ImagesByNode) do
        if imageObject and imageObject.Parent and isGuiImageObject(imageObject) then
            imageObject.Image = originalImage or ""
        end
    end
    state.Active = false
end

function ModalUiController:ActivateDormantRoot(root)
    local state = self:_getDormantRootState(root)
    if not state or state.Active == true then
        return
    end

    for imageObject in pairs(state.ImagesByNode) do
        if imageObject and imageObject.Parent and isGuiImageObject(imageObject) then
            imageObject.Image = ""
        end
    end
    state.Active = true
end

function ModalUiController:RegisterDormantRoot(root)
    if not (root and root:IsA("GuiObject")) then
        return false
    end

    self:_getDormantRootState(root)
    if self._dormantRootConnectionsByRoot[root] then
        if root.Visible ~= true then
            self:ActivateDormantRoot(root)
        end
        return true
    end

    self._dormantRootConnectionsByRoot[root] = root:GetPropertyChangedSignal("Visible"):Connect(function()
        if root.Visible == true then
            self:DeactivateDormantRoot(root)
        else
            self:ActivateDormantRoot(root)
        end
    end)

    if root.Visible == true then
        self:DeactivateDormantRoot(root)
    else
        self:ActivateDormantRoot(root)
    end
    return true
end

function ModalUiController:RegisterDefaultDormantRoots(localPlayer)
    if self._dormantRootPrepared then
        return true
    end

    local mainGui = findMainGui(localPlayer or Players.LocalPlayer)
    if not mainGui then
        return false
    end

    self._dormantRootPrepared = true
    local registeredRoots = {}
    local function registerRoot(root)
        if not (root and root:IsA("GuiObject")) then
            return
        end
        if registeredRoots[root] then
            return
        end
        registeredRoots[root] = true
        self:RegisterDormantRoot(root)
    end

    for _, rootName in ipairs(DEFAULT_DORMANT_ROOT_NAMES) do
        local root = mainGui:FindFirstChild(rootName)
        registerRoot(root)
    end

    for _, child in ipairs(mainGui:GetChildren()) do
        if child:IsA("GuiObject") and child.Visible == false and DORMANT_ROOT_EXCLUDED_NAMES[child.Name] ~= true then
            registerRoot(child)
        end
    end
    return true
end

function ModalUiController:_bindMainEntryMotion(button, options)
    if not (button and button:IsA("GuiButton")) then
        return false
    end

    local previousCleanup = self._mainEntryMotionBindingsByButton[button]
    if previousCleanup then
        previousCleanup()
        self._mainEntryMotionBindingsByButton[button] = nil
    end

    local cleanup = self:BindButtonMotion(button, options)
    if not cleanup then
        return false
    end

    self._mainEntryMotionBindingsByButton[button] = cleanup
    return true
end

function ModalUiController:_bindEntryRootMotion(root, options)
    if not (root and root:IsA("GuiObject")) then
        return false
    end

    local button = findFirstGuiButton(root)
    if not button then
        return false
    end

    local motionOptions = type(options) == "table" and table.clone(options) or {}
    if not (motionOptions.ScaleTarget and motionOptions.ScaleTarget:IsA("GuiObject")) then
        motionOptions.ScaleTarget = root
    end
    if not (motionOptions.RotationTarget and motionOptions.RotationTarget:IsA("GuiObject")) then
        motionOptions.RotationTarget = findRotationTargetForEntry(root, button)
    end
    if motionOptions.HoverScale == nil then
        motionOptions.HoverScale = 1.1
    end
    if motionOptions.PressScale == nil then
        motionOptions.PressScale = 0.9
    end
    if motionOptions.HoverRotation == nil then
        motionOptions.HoverRotation = 20
    end
    motionOptions.IncludeSiblingTextScale = motionOptions.IncludeSiblingTextScale ~= false

    return self:_bindMainEntryMotion(button, motionOptions)
end

function ModalUiController:BindMainEntryMotions(localPlayer)
    self._mainEntryMotionSerial += 1
    local serial = self._mainEntryMotionSerial

    task.spawn(function()
        for _ = 1, 80 do
            if self._mainEntryMotionSerial ~= serial then
                return
            end

            local mainGui = findMainGui(localPlayer or Players.LocalPlayer)
            if mainGui then
                for _ = 1, 8 do
                    if self._mainEntryMotionSerial ~= serial then
                        return
                    end

                    local leftRoot = mainGui:FindFirstChild("Left")
                    if leftRoot then
                        for _, entryRoot in ipairs(leftRoot:GetChildren()) do
                            self:_bindEntryRootMotion(entryRoot)
                        end
                    end

                    local rightRoot = mainGui:FindFirstChild("Right")
                    if rightRoot then
                        for _, entryRoot in ipairs(rightRoot:GetChildren()) do
                            self:_bindEntryRootMotion(entryRoot)
                        end
                    end

                    local topRightRoot = mainGui:FindFirstChild("TopRightGui")
                    if topRightRoot then
                        for _, entryRoot in ipairs(topRightRoot:GetChildren()) do
                            self:_bindEntryRootMotion(entryRoot, {
                                HoverScale = 1.08,
                                PressScale = 0.9,
                                HoverRotation = 14,
                            })
                        end
                    end

                    local levelUpgradeHud = mainGui:FindFirstChild("LevelUpgradeHud")
                    local upgradeEntry = levelUpgradeHud and levelUpgradeHud:FindFirstChild("UpgradeEntry", true)
                    if upgradeEntry then
                        self:_bindEntryRootMotion(upgradeEntry, {
                            HoverScale = 1.06,
                            PressScale = 0.9,
                            HoverRotation = 10,
                        })
                    end

                    task.wait(0.35)
                end

                return
            end
            task.wait(0.25)
        end
    end)
end

function ModalUiController:Init(dependencies)
    local localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self:BindMainEntryMotions(localPlayer)
    if self:RegisterDefaultDormantRoots(localPlayer) then
        return
    end

    task.spawn(function()
        for _ = 1, 80 do
            task.wait(0.25)
            if self:RegisterDefaultDormantRoots(localPlayer) then
                return
            end
        end
    end)
end

function ModalUiController:_applySuppression()
    if not self._mainGui then
        return
    end

    if self:_shouldApplyBlur() then
        self:_applyBlur()
    else
        self:_restoreBlur()
    end
    self:_applyDimOverlay()
    self:_ensureChildWatcher()

    for _, child in ipairs(self._mainGui:GetChildren()) do
        if child:IsA("GuiObject") then
            if self:_isActivePanelChild(child) then
                self:_restoreSuppressedGuiObject(child)
            else
                self:_suppressGuiObject(child)
            end
        end
    end
end

function ModalUiController:_restoreSuppression()
    for guiObject, originalVisible in pairs(self._hiddenOriginalVisibleByNode) do
        if guiObject and guiObject.Parent and guiObject:IsA("GuiObject") then
            guiObject.Visible = originalVisible == true
        end
    end
    table.clear(self._hiddenOriginalVisibleByNode)
    self:_clearHiddenVisibleWatchers()
    self:_restoreDimOverlay()
    self:_restoreBlur()
    self:_clearChildWatcher()
    self._mainGui = nil
end

local function buildSuppressionExclusions(exclusions)
    local target = {}
    if typeof(exclusions) == "Instance" then
        if exclusions:IsA("GuiObject") then
            target[exclusions] = true
        end
        return target
    end

    if type(exclusions) ~= "table" then
        return target
    end

    for _, node in ipairs(exclusions) do
        if node and typeof(node) == "Instance" and node:IsA("GuiObject") then
            target[node] = true
        end
    end

    return target
end

function ModalUiController:Acquire(ownerId, panel, options)
    if not (panel and panel:IsA("GuiObject")) then
        return false
    end

    local mainGui = findMainGuiFromPanel(panel)
    if not mainGui then
        return false
    end

    local ownerKey = normalizeOwnerId(ownerId)
    self._mainGui = mainGui
    self._owners[ownerKey] = {
        Panel = panel,
        SuppressExclusions = buildSuppressionExclusions(type(options) == "table" and options.SuppressExclusions or nil),
        SkipBlur = type(options) == "table" and options.SkipBlur == true or false,
    }
    self:_applySuppression()
    return true
end

function ModalUiController:AcquireExclusive(ownerId, panel, options)
    if not (panel and panel:IsA("GuiObject")) then
        return false
    end

    local mainGui = findMainGuiFromPanel(panel)
    if not mainGui then
        return false
    end

    for _, ownerState in pairs(self._owners) do
        local ownerPanel = ownerState and ownerState.Panel
        if ownerPanel and ownerPanel ~= panel and ownerPanel.Parent and ownerPanel:IsA("GuiObject") then
            ownerPanel.Visible = false
        end
    end

    table.clear(self._owners)
    local ownerKey = normalizeOwnerId(ownerId)
    self._mainGui = mainGui
    self._owners[ownerKey] = {
        Panel = panel,
        SuppressExclusions = buildSuppressionExclusions(type(options) == "table" and options.SuppressExclusions or nil),
        SkipBlur = type(options) == "table" and options.SkipBlur == true or false,
    }
    self:_applySuppression()
    return true
end

function ModalUiController:Release(ownerId)
    local ownerKey = normalizeOwnerId(ownerId)
    self._owners[ownerKey] = nil

    if self:_hasOwners() then
        self:_applySuppression()
        return
    end

    self:_restoreSuppression()
end

function ModalUiController:PlayPanelOpen(ownerId, panel, options)
    if not (panel and panel:IsA("GuiObject")) then
        return false
    end

    local motionOptions = type(options) == "table" and options or {}
    local state, serial = self:_preparePanelMotion(panel)
    local uiScale = ensureUiScale(panel)

    if motionOptions.Acquire ~= false then
        if motionOptions.Exclusive == true then
            self:AcquireExclusive(ownerId, panel, motionOptions)
        else
            self:Acquire(ownerId, panel, motionOptions)
        end
    end

    panel.Visible = true
    if not uiScale or motionOptions.Immediate == true then
        if uiScale then
            uiScale.Scale = 1
        end
        runMotionCallback(motionOptions.OnOpened)
        return true
    end

    uiScale.Scale = getMotionNumber(motionOptions, "OpenFromScale")
    local overshoot = TweenService:Create(uiScale, TweenInfo.new(
        getMotionNumber(motionOptions, "OpenOvershootDuration"),
        Enum.EasingStyle.Back,
        Enum.EasingDirection.Out
    ), {
        Scale = getMotionNumber(motionOptions, "OpenOvershootScale"),
    })
    local settle = TweenService:Create(uiScale, TweenInfo.new(
        getMotionNumber(motionOptions, "OpenSettleDuration"),
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.Out
    ), {
        Scale = 1,
    })
    state.Tweens = { overshoot, settle }

    task.spawn(function()
        overshoot:Play()
        overshoot.Completed:Wait()
        if state.Serial ~= serial or not panel.Parent or panel.Visible ~= true then
            return
        end

        settle:Play()
        settle.Completed:Wait()
        if state.Serial ~= serial or not panel.Parent or panel.Visible ~= true then
            return
        end

        if uiScale.Parent then
            uiScale.Scale = 1
        end
        table.clear(state.Tweens)
        runMotionCallback(motionOptions.OnOpened)
    end)
    return true
end

function ModalUiController:PlayPanelClose(ownerId, panel, options)
    local motionOptions = type(options) == "table" and options or {}
    if not (panel and panel:IsA("GuiObject")) then
        if motionOptions.Release ~= false then
            self:Release(ownerId)
        end
        runMotionCallback(motionOptions.OnClosed)
        return false
    end

    local state, serial = self:_preparePanelMotion(panel)
    local uiScale = ensureUiScale(panel)
    if not uiScale or motionOptions.Immediate == true or panel.Visible ~= true then
        if uiScale then
            uiScale.Scale = 1
        end
        panel.Visible = false
        if motionOptions.Release ~= false then
            self:Release(ownerId)
        end
        runMotionCallback(motionOptions.OnClosed)
        return true
    end

    local liftDuration = getMotionNumber(motionOptions, "CloseLiftDuration")
    local liftTween = nil
    if liftDuration > 0 then
        liftTween = TweenService:Create(uiScale, TweenInfo.new(
            liftDuration,
            Enum.EasingStyle.Quad,
            Enum.EasingDirection.Out
        ), {
            Scale = getMotionNumber(motionOptions, "CloseLiftScale"),
        })
    end

    local shrinkTween = TweenService:Create(uiScale, TweenInfo.new(
        getMotionNumber(motionOptions, "CloseShrinkDuration"),
        Enum.EasingStyle.Quad,
        Enum.EasingDirection.In
    ), {
        Scale = getMotionNumber(motionOptions, "CloseToScale"),
    })

    if liftTween then
        state.Tweens = { liftTween, shrinkTween }
    else
        state.Tweens = { shrinkTween }
    end

    task.spawn(function()
        if liftTween then
            liftTween:Play()
            liftTween.Completed:Wait()
            if state.Serial ~= serial or not panel.Parent or panel.Visible ~= true then
                return
            end
        end

        shrinkTween:Play()
        shrinkTween.Completed:Wait()
        if state.Serial ~= serial or not panel.Parent then
            return
        end

        if uiScale.Parent then
            uiScale.Scale = 1
        end
        panel.Visible = false
        table.clear(state.Tweens)
        if motionOptions.Release ~= false then
            self:Release(ownerId)
        end
        runMotionCallback(motionOptions.OnClosed)
    end)
    return true
end

function ModalUiController:BindButtonMotion(button, options)
    if not (button and button:IsA("GuiObject")) then
        return nil
    end

    local previousCleanup = self._buttonMotionCleanupsByButton[button]
    if previousCleanup then
        previousCleanup()
    end

    local motionOptions = type(options) == "table" and options or {}
    local scaleTarget = motionOptions.ScaleTarget
    if not (scaleTarget and scaleTarget:IsA("GuiObject")) then
        scaleTarget = button
    end

    local rotationTarget = motionOptions.RotationTarget
    if not (rotationTarget and rotationTarget:IsA("GuiObject")) then
        rotationTarget = nil
    end

    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return nil
    end

    local scaleEntries = {
        {
            UiScale = uiScale,
            BaseScale = uiScale.Scale,
        },
    }
    if scaleTarget == button then
        for _, textTarget in ipairs(collectSiblingTextScaleTargets(button, motionOptions)) do
            local textScale = ensureUiScale(textTarget)
            if textScale then
                table.insert(scaleEntries, {
                    UiScale = textScale,
                    BaseScale = textScale.Scale,
                })
            end
        end
    end

    local binding = {
        Button = button,
        UiScale = uiScale,
        ScaleEntries = scaleEntries,
        RotationTarget = rotationTarget,
        BaseScale = uiScale.Scale,
        BaseRotation = rotationTarget and rotationTarget.Rotation or 0,
        IsHovered = false,
        IsPressed = false,
        Tweens = {},
        Connections = {},
        Alive = true,
        Serial = 0,
    }

    local function cancelTween(key)
        local tween = binding.Tweens[key]
        if tween then
            tween:Cancel()
            binding.Tweens[key] = nil
        end
    end

    local function cancelAllTweens()
        local keys = {}
        for key in pairs(binding.Tweens) do
            table.insert(keys, key)
        end
        for _, key in ipairs(keys) do
            cancelTween(key)
        end
    end

    local function playTween(key, target, tweenInfo, goal)
        if not (target and target.Parent) then
            return nil
        end
        cancelTween(key)
        local tween = TweenService:Create(target, tweenInfo, goal)
        binding.Tweens[key] = tween
        tween.Completed:Connect(function()
            if binding.Tweens[key] == tween then
                binding.Tweens[key] = nil
            end
        end)
        tween:Play()
        return tween
    end

    local function isMotionEnabled()
        return button.Parent ~= nil and button.Visible ~= false and button.Active ~= false
    end

    local function playScaleTweens(phaseKey, scaleMultiplier, tweenInfo)
        local waitTween = nil
        for index, entry in ipairs(binding.ScaleEntries) do
            local entryScale = entry.UiScale
            if entryScale and entryScale.Parent then
                local tween = playTween("Scale" .. phaseKey .. "_" .. tostring(index), entryScale, tweenInfo, {
                    Scale = entry.BaseScale * scaleMultiplier,
                })
                waitTween = waitTween or tween
            end
        end
        return waitTween
    end

    local function playRotationTween(phaseKey, targetRotation, tweenInfo)
        if not rotationTarget then
            return nil
        end
        return playTween("Rotation" .. phaseKey, rotationTarget, tweenInfo, {
            Rotation = targetRotation,
        })
    end

    local function snapToFinal(scaleMultiplier, targetRotation)
        for _, entry in ipairs(binding.ScaleEntries) do
            local entryScale = entry.UiScale
            if entryScale and entryScale.Parent then
                entryScale.Scale = entry.BaseScale * scaleMultiplier
            end
        end
        if rotationTarget and rotationTarget.Parent then
            rotationTarget.Rotation = targetRotation
        end
    end

    local function runSingleStep(scaleMultiplier, targetRotation, duration, easingStyle, easingDirection)
        binding.Serial += 1
        local serial = binding.Serial
        cancelAllTweens()
        local tweenInfo = TweenInfo.new(duration, easingStyle, easingDirection)
        local waitTween = playScaleTweens("Single", scaleMultiplier, tweenInfo)
        local rotationTween = playRotationTween("Single", targetRotation, tweenInfo)
        waitTween = waitTween or rotationTween
        if not waitTween then
            snapToFinal(scaleMultiplier, targetRotation)
            return
        end

        task.spawn(function()
            waitTween.Completed:Wait()
            if binding.Serial ~= serial or not binding.Alive or not button.Parent then
                return
            end
            snapToFinal(scaleMultiplier, targetRotation)
        end)
    end

    local function runTwoStep(firstScaleMultiplier, firstRotation, firstDuration, firstEasingStyle, firstEasingDirection, finalScaleMultiplier, finalRotation, finalDuration, finalEasingStyle, finalEasingDirection)
        binding.Serial += 1
        local serial = binding.Serial
        cancelAllTweens()

        local firstTweenInfo = TweenInfo.new(firstDuration, firstEasingStyle, firstEasingDirection)
        local firstTween = playScaleTweens("A", firstScaleMultiplier, firstTweenInfo)
        local firstRotationTween = playRotationTween("A", firstRotation, firstTweenInfo)
        firstTween = firstTween or firstRotationTween

        task.spawn(function()
            if firstTween then
                firstTween.Completed:Wait()
            else
                task.wait(firstDuration)
            end
            if binding.Serial ~= serial or not binding.Alive or not button.Parent then
                return
            end

            local finalTweenInfo = TweenInfo.new(finalDuration, finalEasingStyle, finalEasingDirection)
            local finalTween = playScaleTweens("B", finalScaleMultiplier, finalTweenInfo)
            local finalRotationTween = playRotationTween("B", finalRotation, finalTweenInfo)
            finalTween = finalTween or finalRotationTween
            if finalTween then
                finalTween.Completed:Wait()
            else
                task.wait(finalDuration)
            end
            if binding.Serial ~= serial or not binding.Alive or not button.Parent then
                return
            end

            snapToFinal(finalScaleMultiplier, finalRotation)
        end)
    end

    local function applyState()
        if not binding.Alive or not button.Parent then
            return
        end

        if not isMotionEnabled() then
            binding.IsHovered = false
            binding.IsPressed = false
        end

        local targetScale = binding.BaseScale
        local targetRotation = binding.BaseRotation
        local targetMultiplier = 1

        if binding.IsPressed then
            targetMultiplier = getButtonMotionNumber(motionOptions, "PressScale")
            targetScale = binding.BaseScale * targetMultiplier
            targetRotation = binding.BaseRotation + getButtonMotionNumber(motionOptions, "PressRotation")
            runSingleStep(
                targetMultiplier,
                targetRotation,
                getButtonMotionNumber(motionOptions, "PressDuration"),
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out
            )
        elseif binding.IsHovered then
            targetMultiplier = getButtonMotionNumber(motionOptions, "HoverScale")
            targetScale = binding.BaseScale * targetMultiplier
            local hoverRotation = getButtonMotionNumber(motionOptions, "HoverRotation")
            targetRotation = binding.BaseRotation + hoverRotation
            local overshootMultiplier = targetMultiplier * getButtonMotionNumber(motionOptions, "HoverOvershootMultiplier")
            local overshootRotation = binding.BaseRotation + hoverRotation * getButtonMotionNumber(motionOptions, "HoverRotationOvershootMultiplier")
            runTwoStep(
                overshootMultiplier,
                overshootRotation,
                getButtonMotionNumber(motionOptions, "HoverDuration"),
                Enum.EasingStyle.Back,
                Enum.EasingDirection.Out,
                targetMultiplier,
                targetRotation,
                getButtonMotionNumber(motionOptions, "HoverSettleDuration"),
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out
            )
        else
            local hoverRotation = getButtonMotionNumber(motionOptions, "HoverRotation")
            local releaseRotationRatio = getButtonMotionNumber(motionOptions, "ReleaseRotationOvershootRatio")
            local undershootRotation = binding.BaseRotation - hoverRotation * releaseRotationRatio
            runTwoStep(
                getButtonMotionNumber(motionOptions, "ReleaseUndershootScale"),
                undershootRotation,
                getButtonMotionNumber(motionOptions, "ReleaseDuration"),
                Enum.EasingStyle.Quad,
                Enum.EasingDirection.Out,
                1,
                binding.BaseRotation,
                getButtonMotionNumber(motionOptions, "ReleaseSettleDuration"),
                Enum.EasingStyle.Back,
                Enum.EasingDirection.Out
            )
        end
    end

    table.insert(binding.Connections, button.MouseEnter:Connect(function()
        if not isMotionEnabled() then
            applyState()
            return
        end
        binding.IsHovered = true
        applyState()
    end))

    table.insert(binding.Connections, button.MouseLeave:Connect(function()
        binding.IsHovered = false
        binding.IsPressed = false
        applyState()
    end))

    table.insert(binding.Connections, button.InputBegan:Connect(function(input)
        if not isMotionEnabled() then
            applyState()
            return
        end
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.IsPressed = true
            applyState()
        end
    end))

    table.insert(binding.Connections, button.InputEnded:Connect(function(input)
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.IsPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.IsHovered = false
            end
            applyState()
        end
    end))

    table.insert(binding.Connections, UserInputService.InputEnded:Connect(function(input)
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            if binding.IsPressed then
                binding.IsPressed = false
                if inputType == Enum.UserInputType.Touch then
                    binding.IsHovered = false
                end
                applyState()
            end
        end
    end))

    table.insert(binding.Connections, button:GetPropertyChangedSignal("Active"):Connect(applyState))
    table.insert(binding.Connections, button:GetPropertyChangedSignal("Visible"):Connect(applyState))

    local cleanup
    cleanup = function()
        binding.Alive = false
        for _, connection in ipairs(binding.Connections) do
            disconnectConnection(connection)
        end
        table.clear(binding.Connections)
        cancelAllTweens()
        for _, entry in ipairs(binding.ScaleEntries) do
            local entryScale = entry.UiScale
            if entryScale and entryScale.Parent then
                entryScale.Scale = entry.BaseScale
            end
        end
        if rotationTarget and rotationTarget.Parent then
            rotationTarget.Rotation = binding.BaseRotation
        end
        if ModalUiController._buttonMotionCleanupsByButton[button] == cleanup then
            ModalUiController._buttonMotionCleanupsByButton[button] = nil
        end
        if ModalUiController._mainEntryMotionBindingsByButton[button] == cleanup then
            ModalUiController._mainEntryMotionBindingsByButton[button] = nil
        end
    end

    self._buttonMotionCleanupsByButton[button] = cleanup
    return cleanup
end

function ModalUiController:BindButtonMotionConnection(button, options)
    local cleanup = self:BindButtonMotion(button, options)
    if not cleanup then
        return nil
    end

    local connection = {
        Connected = true,
    }

    function connection:Disconnect()
        if self.Connected ~= true then
            return
        end
        self.Connected = false
        cleanup()
    end

    return connection
end

function ModalUiController:IsAnyOpen()
    return self:_hasOwners()
end

function ModalUiController:SetRestoredVisible(guiObject, visible)
    if guiObject and self._hiddenOriginalVisibleByNode[guiObject] ~= nil then
        self._hiddenOriginalVisibleByNode[guiObject] = visible == true
    end
end

function ModalUiController:ExcludeFromSuppression(ownerId, guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return false
    end

    local ownerState = self._owners[normalizeOwnerId(ownerId)]
    if not ownerState then
        return false
    end

    ownerState.SuppressExclusions = ownerState.SuppressExclusions or {}
    ownerState.SuppressExclusions[guiObject] = true
    self:_restoreSuppressedGuiObject(guiObject)
    return true
end

return ModalUiController
