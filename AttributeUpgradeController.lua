--[[
Script: AttributeUpgradeController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AttributeUpgradeController
Purpose: Bind the static in-battle attribute upgrade UI to PlayerStateSync and server requests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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

    error(string.format("[AttributeUpgradeController] Missing shared module %s", tostring(moduleName or "")))
end

local RemoteNames = requireSharedModule("RemoteNames")
local AttributeConfig = requireSharedModule("AttributeConfig")

local AttributeUpgradeController = {}

AttributeUpgradeController._localPlayer = nil
AttributeUpgradeController._modalUiController = nil
AttributeUpgradeController._connections = {}
AttributeUpgradeController._uiConnections = {}
AttributeUpgradeController._latestPayload = nil
AttributeUpgradeController._pendingByKey = {}
AttributeUpgradeController._boundMain = nil
AttributeUpgradeController._hud = nil
AttributeUpgradeController._panel = nil
AttributeUpgradeController._experienceGroup = nil
AttributeUpgradeController._upgradeEntry = nil
AttributeUpgradeController._experienceGroupScale = nil
AttributeUpgradeController._hudDefaultState = nil
AttributeUpgradeController._hudTransitionTweens = {}
AttributeUpgradeController._hudTransitionConnections = {}
AttributeUpgradeController._hudTransitionToken = 0
AttributeUpgradeController._isPanelOpen = false
AttributeUpgradeController._outsideCloseInputConnection = nil
AttributeUpgradeController._cardsByKey = {}
AttributeUpgradeController._requestEvent = nil

local UI_BIND_RETRY_COUNT = 80
local UI_BIND_RETRY_INTERVAL_SECONDS = 0.25
local PENDING_TIMEOUT_SECONDS = 1.5
local MODAL_OWNER_ID = "AttributeUpgrade"
local HUD_TRANSITION_SECONDS = 0.22
local HUD_ENTRY_OPEN_X_SCALE = 0.5
local HUD_EXPERIENCE_HIDDEN_SCALE = 0.94
local HUD_HIDE_TWEEN_INFO = TweenInfo.new(HUD_TRANSITION_SECONDS, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
local HUD_RESTORE_TWEEN_INFO = TweenInfo.new(HUD_TRANSITION_SECONDS, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local ENABLED_BUTTON_COLOR = Color3.fromRGB(73, 207, 93)
local DISABLED_BUTTON_COLOR = Color3.fromRGB(100, 105, 112)
local ENABLED_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local DISABLED_TEXT_COLOR = Color3.fromRGB(205, 210, 220)
local ACTIVE_PROGRESS_COLOR = Color3.fromRGB(255, 213, 82)
local INACTIVE_PROGRESS_COLOR = Color3.fromRGB(69, 73, 86)
local PROGRESS_SEGMENT_PREFIX = "Segment"
local PROGRESS_DEFAULT_PADDING_SCALE = 0.025
local PROGRESS_MAX_PADDING_COVERAGE = 0.35

local function disconnectAll(connections)
    for _, connection in ipairs(connections or {}) do
        if type(connection) == "function" then
            connection()
        elseif connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findDescendant(root, path)
    local current = root
    for name in string.gmatch(path or "", "[^%.]+") do
        current = current and current:FindFirstChild(name)
        if not current then
            return nil
        end
    end
    return current
end

local function ensureUiScale(guiObject, name)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local existing = guiObject:FindFirstChild(name)
    if existing and existing:IsA("UIScale") then
        return existing
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if uiScale then
        return uiScale
    end

    uiScale = Instance.new("UIScale")
    uiScale.Name = name
    uiScale.Scale = 1
    uiScale.Parent = guiObject
    return uiScale
end

local function captureTransparencyProperties(instance)
    local properties = {}
    if instance:IsA("GuiObject") then
        properties.BackgroundTransparency = instance.BackgroundTransparency
    end
    if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
        properties.TextTransparency = instance.TextTransparency
        properties.TextStrokeTransparency = instance.TextStrokeTransparency
    end
    if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
        properties.ImageTransparency = instance.ImageTransparency
    end
    if instance:IsA("UIStroke") then
        properties.Transparency = instance.Transparency
    end

    return next(properties) and properties or nil
end

local function collectTransparencySnapshots(root)
    local snapshots = {}
    local function addSnapshot(instance)
        local properties = captureTransparencyProperties(instance)
        if properties then
            table.insert(snapshots, {
                Instance = instance,
                Properties = properties,
            })
        end
    end

    if root then
        addSnapshot(root)
        for _, descendant in ipairs(root:GetDescendants()) do
            addSnapshot(descendant)
        end
    end

    return snapshots
end

local function applyProperties(instance, properties)
    if not (instance and instance.Parent and properties) then
        return
    end
    for property, value in pairs(properties) do
        pcall(function()
            instance[property] = value
        end)
    end
end

local function buildHiddenTransparencyProperties(properties)
    local hidden = {}
    for property in pairs(properties or {}) do
        hidden[property] = 1
    end
    return hidden
end

local function getInputScreenPoint(inputObject)
    local position = inputObject and inputObject.Position
    if not position then
        return nil
    end

    return Vector2.new(position.X, position.Y)
end

local function isScreenPointInsideGuiObject(guiObject, screenPoint)
    if not (guiObject and guiObject.Parent and guiObject:IsA("GuiObject") and screenPoint) then
        return false
    end

    local absolutePosition = guiObject.AbsolutePosition
    local absoluteSize = guiObject.AbsoluteSize
    return screenPoint.X >= absolutePosition.X
        and screenPoint.X <= absolutePosition.X + absoluteSize.X
        and screenPoint.Y >= absolutePosition.Y
        and screenPoint.Y <= absolutePosition.Y + absoluteSize.Y
end

local function setText(node, text)
    if node and (node:IsA("TextLabel") or node:IsA("TextButton")) then
        node.Text = tostring(text or "")
    end
end

local function setButtonEnabled(button, label, enabled)
    if button and button:IsA("GuiButton") then
        button.Active = enabled == true
        button.AutoButtonColor = enabled == true
    end
    if button and button:IsA("GuiObject") then
        button.BackgroundColor3 = enabled and ENABLED_BUTTON_COLOR or DISABLED_BUTTON_COLOR
        button.BackgroundTransparency = enabled and 0 or 0.15
    end
    if label and label:IsA("TextLabel") then
        label.TextColor3 = enabled and ENABLED_TEXT_COLOR or DISABLED_TEXT_COLOR
    end

    local gradient = button and button:FindFirstChild("ButtonGreen")
    if gradient and gradient:IsA("UIGradient") then
        gradient.Enabled = enabled == true
    end
end

local function collectProgressSegments(progress)
    local segments = {}
    if not progress then
        return segments
    end

    for _, child in ipairs(progress:GetChildren()) do
        local segmentIndex = string.match(child.Name, "^" .. PROGRESS_SEGMENT_PREFIX .. "(%d+)$")
        if segmentIndex and child:IsA("GuiObject") then
            table.insert(segments, {
                Index = tonumber(segmentIndex) or math.huge,
                LayoutOrder = child.LayoutOrder,
                Segment = child,
            })
        end
    end

    table.sort(segments, function(left, right)
        if left.Index ~= right.Index then
            return left.Index < right.Index
        end
        return left.LayoutOrder < right.LayoutOrder
    end)

    local orderedSegments = {}
    for _, segmentData in ipairs(segments) do
        table.insert(orderedSegments, segmentData.Segment)
    end
    return orderedSegments
end

local function findProgressSegmentTemplate(progress, segments)
    local template = progress and progress:FindFirstChild(PROGRESS_SEGMENT_PREFIX .. "1")
    if template and template:IsA("GuiObject") then
        return template
    end
    return segments and segments[1] or nil
end

local function getProgressBasePaddingScale(layout)
    if not layout then
        return PROGRESS_DEFAULT_PADDING_SCALE
    end

    local storedPaddingScale = layout:GetAttribute("AttributeUpgradeBasePaddingScale")
    if type(storedPaddingScale) == "number" and storedPaddingScale >= 0 then
        return storedPaddingScale
    end

    local paddingScale = layout.Padding.Scale
    if paddingScale <= 0 then
        paddingScale = PROGRESS_DEFAULT_PADDING_SCALE
    end
    layout:SetAttribute("AttributeUpgradeBasePaddingScale", paddingScale)
    return paddingScale
end

function AttributeUpgradeController:_syncProgressSegments(progress, cap, level)
    if not (progress and progress:IsA("GuiObject")) then
        return
    end

    local segmentCount = math.max(1, math.floor(tonumber(cap) or 1))
    local filledCount = math.clamp(math.floor(tonumber(level) or 0), 0, segmentCount)
    local segments = collectProgressSegments(progress)
    local template = findProgressSegmentTemplate(progress, segments)
    if not template then
        return
    end

    for index = #segments + 1, segmentCount do
        local clone = template:Clone()
        clone.Name = PROGRESS_SEGMENT_PREFIX .. index
        clone.Parent = progress
        table.insert(segments, clone)
    end

    for index = #segments, segmentCount + 1, -1 do
        local segment = segments[index]
        table.remove(segments, index)
        if segment and segment.Parent then
            segment:Destroy()
        end
    end

    local layout = progress:FindFirstChildOfClass("UIListLayout")
    local basePaddingScale = getProgressBasePaddingScale(layout)
    local paddingScale = 0
    if segmentCount > 1 then
        paddingScale = math.min(basePaddingScale, PROGRESS_MAX_PADDING_COVERAGE / (segmentCount - 1))
    end
    local segmentWidthScale = math.max(0, (1 - paddingScale * (segmentCount - 1)) / segmentCount)

    if layout then
        layout.Padding = UDim.new(paddingScale, 0)
    end

    local height = template.Size.Y
    for index, segment in ipairs(segments) do
        segment.Name = PROGRESS_SEGMENT_PREFIX .. index
        segment.LayoutOrder = index
        segment.Visible = true
        segment.Size = UDim2.new(segmentWidthScale, 0, height.Scale, height.Offset)
        segment.BackgroundColor3 = index <= filledCount and ACTIVE_PROGRESS_COLOR or INACTIVE_PROGRESS_COLOR
        segment.BackgroundTransparency = index <= filledCount and 0 or 0.25
    end
end

function AttributeUpgradeController:_bindButtonMotion(button, options)
    if not (self._modalUiController and self._modalUiController.BindButtonMotion) then
        return
    end

    local cleanup = self._modalUiController:BindButtonMotion(button, options)
    if cleanup then
        table.insert(self._uiConnections, cleanup)
    end
end

local function extractAttributeState(payload)
    local attributeState = type(payload and payload.attributeState) == "table" and payload.attributeState or {}
    return {
        skillPoints = math.max(0, math.floor(tonumber(attributeState.skillPoints or payload and payload.skillPoints) or 0)),
        attributeLevels = type(attributeState.attributeLevels) == "table" and attributeState.attributeLevels or payload and payload.attributeLevels or {},
        attributeCaps = type(attributeState.attributeCaps) == "table" and attributeState.attributeCaps or payload and payload.attributeCaps or {},
        finalStats = type(attributeState.finalStats) == "table" and attributeState.finalStats or payload and payload.attributeFinalStats or {},
    }
end

function AttributeUpgradeController:_getPlayerGui()
    local player = self._localPlayer or Players.LocalPlayer
    return player and (player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 10)) or nil
end

function AttributeUpgradeController:_isBattleReady()
    local payload = self._latestPayload
    return payload and payload.isInArena == true and payload.alive == true
end

function AttributeUpgradeController:_showMessage(message, duration)
    local footer = self._footer
    if not (footer and footer:IsA("TextLabel")) then
        return
    end

    local text = tostring(message or "")
    footer.Text = text
    if text ~= "" and duration ~= false then
        task.delay(tonumber(duration) or 2, function()
            if footer.Parent and footer.Text == text then
                footer.Text = ""
            end
        end)
    end
end

function AttributeUpgradeController:_isPanelCurrentlyOpen()
    return self._isPanelOpen == true or (self._panel and self._panel.Visible == true)
end

function AttributeUpgradeController:_disconnectOutsideCloseInput()
    if self._outsideCloseInputConnection and self._outsideCloseInputConnection.Connected then
        self._outsideCloseInputConnection:Disconnect()
    end
    self._outsideCloseInputConnection = nil
end

function AttributeUpgradeController:_connectOutsideCloseInput()
    self:_disconnectOutsideCloseInput()

    self._outsideCloseInputConnection = UserInputService.InputBegan:Connect(function(inputObject, gameProcessedEvent)
        if gameProcessedEvent or not self:_isPanelCurrentlyOpen() then
            return
        end

        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
            return
        end

        local screenPoint = getInputScreenPoint(inputObject)
        if isScreenPointInsideGuiObject(self._panel, screenPoint) or isScreenPointInsideGuiObject(self._upgradeEntry, screenPoint) then
            return
        end

        self:_closePanel()
    end)
end

function AttributeUpgradeController:_cancelHudTransitionTweens()
    self._hudTransitionToken += 1
    for _, tween in ipairs(self._hudTransitionTweens or {}) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._hudTransitionTweens)
    disconnectAll(self._hudTransitionConnections)
end

function AttributeUpgradeController:_captureLevelHudDefaults()
    if not (self._hud and self._hud.Parent) then
        self._hudDefaultState = nil
        return
    end

    self._experienceGroup = self._hud:FindFirstChild("ExperienceGroup")
    self._upgradeEntry = self._hud:FindFirstChild("UpgradeEntry")
    self._experienceGroupScale = ensureUiScale(self._experienceGroup, "AttributeUpgradeExperienceMotionScale")

    self._hudDefaultState = {
        ExperienceGroupVisible = self._experienceGroup and self._experienceGroup.Visible == true or false,
        ExperienceGroupScale = self._experienceGroupScale and self._experienceGroupScale.Scale or 1,
        ExperienceGroupTransparency = collectTransparencySnapshots(self._experienceGroup),
        UpgradeEntryPosition = self._upgradeEntry and self._upgradeEntry:IsA("GuiObject") and self._upgradeEntry.Position or nil,
    }
end

function AttributeUpgradeController:_setLevelHudUpgradeMode(enabled, immediate)
    if not self._hudDefaultState then
        self:_captureLevelHudDefaults()
    end

    local defaults = self._hudDefaultState
    if not defaults then
        return
    end

    self:_cancelHudTransitionTweens()
    local token = self._hudTransitionToken
    local tweens = self._hudTransitionTweens

    local experienceGroup = self._experienceGroup
    local experienceScale = self._experienceGroupScale
    local upgradeEntry = self._upgradeEntry
    local targetEntryPosition = defaults.UpgradeEntryPosition
    if enabled and targetEntryPosition then
        targetEntryPosition = UDim2.new(
            HUD_ENTRY_OPEN_X_SCALE,
            targetEntryPosition.X.Offset,
            targetEntryPosition.Y.Scale,
            targetEntryPosition.Y.Offset
        )
    end

    if immediate then
        if experienceGroup and experienceGroup.Parent then
            experienceGroup.Visible = not enabled and defaults.ExperienceGroupVisible or false
            if experienceScale then
                experienceScale.Scale = enabled and HUD_EXPERIENCE_HIDDEN_SCALE or defaults.ExperienceGroupScale
            end
            for _, snapshot in ipairs(defaults.ExperienceGroupTransparency or {}) do
                applyProperties(snapshot.Instance, enabled and buildHiddenTransparencyProperties(snapshot.Properties) or snapshot.Properties)
            end
        end
        if upgradeEntry and targetEntryPosition then
            upgradeEntry.Position = targetEntryPosition
        end
        return
    end

    if experienceGroup and experienceGroup.Parent then
        if enabled then
            experienceGroup.Visible = true
        elseif defaults.ExperienceGroupVisible then
            experienceGroup.Visible = true
            for _, snapshot in ipairs(defaults.ExperienceGroupTransparency or {}) do
                applyProperties(snapshot.Instance, buildHiddenTransparencyProperties(snapshot.Properties))
            end
            if experienceScale then
                experienceScale.Scale = HUD_EXPERIENCE_HIDDEN_SCALE
            end
        end

        if experienceScale then
            table.insert(tweens, TweenService:Create(experienceScale, enabled and HUD_HIDE_TWEEN_INFO or HUD_RESTORE_TWEEN_INFO, {
                Scale = enabled and HUD_EXPERIENCE_HIDDEN_SCALE or defaults.ExperienceGroupScale,
            }))
        end

        for _, snapshot in ipairs(defaults.ExperienceGroupTransparency or {}) do
            if snapshot.Instance and snapshot.Instance.Parent then
                table.insert(tweens, TweenService:Create(
                    snapshot.Instance,
                    enabled and HUD_HIDE_TWEEN_INFO or HUD_RESTORE_TWEEN_INFO,
                    enabled and buildHiddenTransparencyProperties(snapshot.Properties) or snapshot.Properties
                ))
            end
        end
    end

    if upgradeEntry and targetEntryPosition then
        table.insert(tweens, TweenService:Create(upgradeEntry, enabled and HUD_HIDE_TWEEN_INFO or HUD_RESTORE_TWEEN_INFO, {
            Position = targetEntryPosition,
        }))
    end

    local remainingTweens = #tweens
    local function finish()
        remainingTweens -= 1
        if remainingTweens > 0 or self._hudTransitionToken ~= token then
            return
        end
        disconnectAll(self._hudTransitionConnections)
        if experienceGroup and experienceGroup.Parent and enabled then
            experienceGroup.Visible = false
        end
        table.clear(tweens)
    end

    if remainingTweens <= 0 then
        if experienceGroup and experienceGroup.Parent then
            experienceGroup.Visible = enabled and false or defaults.ExperienceGroupVisible
        end
        return
    end

    for _, tween in ipairs(tweens) do
        table.insert(self._hudTransitionConnections, tween.Completed:Connect(finish))
        tween:Play()
    end
end

function AttributeUpgradeController:_closePanel()
    self._isPanelOpen = false
    self:_disconnectOutsideCloseInput()
    self:_setLevelHudUpgradeMode(false)
    if self._modalUiController and self._modalUiController.Release then
        if self._modalUiController.PlayPanelClose then
            self._modalUiController:PlayPanelClose(MODAL_OWNER_ID, self._panel)
        else
            self._modalUiController:Release(MODAL_OWNER_ID)
            if self._panel then
                self._panel.Visible = false
            end
        end
        return
    end
    if self._panel then
        self._panel.Visible = false
    end
end

function AttributeUpgradeController:_openPanel()
    if not self:_isBattleReady() then
        self:_showMessage("Enter battle to upgrade")
        return false
    end
    if not self:_bindUi(true) then
        return false
    end
    if self._panel and self._panel.Visible == true then
        self._isPanelOpen = true
        self:_connectOutsideCloseInput()
        self:_setLevelHudUpgradeMode(true)
        self:_applyState(self._latestPayload)
        return true
    end

    if self._panel then
        if self._modalUiController and self._modalUiController.PlayPanelOpen then
            self._modalUiController:PlayPanelOpen(MODAL_OWNER_ID, self._panel, {
                SuppressExclusions = { self._hud },
                SkipBlur = true,
            })
        else
            self._panel.Visible = true
            if self._modalUiController and self._modalUiController.Acquire then
                self._modalUiController:Acquire(MODAL_OWNER_ID, self._panel, {
                    SuppressExclusions = { self._hud },
                    SkipBlur = true,
                })
            end
        end
    end
    if self._modalUiController and self._modalUiController.ExcludeFromSuppression then
        self._modalUiController:ExcludeFromSuppression(MODAL_OWNER_ID, self._hud)
    end
    if self._hud then
        self._hud.Visible = true
    end
    self._isPanelOpen = true
    self:_connectOutsideCloseInput()
    self:_setLevelHudUpgradeMode(true)
    self:_applyState(self._latestPayload)
    return true
end

function AttributeUpgradeController:_requestUpgrade(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        self:_showMessage("Invalid attribute")
        return
    end
    if not self:_isBattleReady() then
        self:_showMessage("Enter battle to upgrade")
        return
    end

    local attributeState = extractAttributeState(self._latestPayload)
    local skillPoints = attributeState.skillPoints
    local levels = AttributeConfig.NormalizeLevels(attributeState.attributeLevels, attributeState.attributeCaps)
    local caps = AttributeConfig.NormalizeCaps(attributeState.attributeCaps)
    if skillPoints <= 0 then
        self:_showMessage("Not enough points")
        return
    end
    if (levels[key] or 0) >= (caps[key] or 0) then
        self:_showMessage("Max level reached")
        return
    end
    if self._pendingByKey[key] == true then
        return
    end
    if not self._requestEvent then
        self:_showMessage("Upgrade is unavailable")
        return
    end

    self._pendingByKey[key] = true
    self:_applyState(self._latestPayload)
    self._requestEvent:FireServer(key)

    task.delay(PENDING_TIMEOUT_SECONDS, function()
        if self._pendingByKey[key] ~= true then
            return
        end
        self._pendingByKey[key] = nil
        self:_showMessage("Please try again")
        self:_applyState(self._latestPayload)
    end)
end

function AttributeUpgradeController:_bindCard(statsGrid, attributeKey)
    local definition = AttributeConfig.GetDefinition(attributeKey)
    local card = definition and statsGrid and statsGrid:FindFirstChild(definition.CardName)
    if not card then
        return nil
    end

    local addButton = card:FindFirstChild("AddButton")
    local label = addButton and addButton:FindFirstChild("Label")
    if addButton and addButton:IsA("GuiButton") then
        self:_bindButtonMotion(addButton, {
            HoverScale = 1.08,
            PressScale = 0.88,
        })
        table.insert(self._uiConnections, addButton.Activated:Connect(function()
            self:_requestUpgrade(attributeKey)
        end))
    end

    return {
        Root = card,
        Name = card:FindFirstChild("Name"),
        Level = card:FindFirstChild("Level"),
        Effect = card:FindFirstChild("Effect"),
        Progress = card:FindFirstChild("Progress"),
        AddButton = addButton,
        AddButtonLabel = label,
    }
end

function AttributeUpgradeController:_connectEntryButtons()
    local connectedButtons = {}
    local entryScaleTarget = self._hud and findDescendant(self._hud, "UpgradeEntry")

    local function bindOpenButton(button)
        if not button or connectedButtons[button] then
            return
        end
        connectedButtons[button] = true

        self:_bindButtonMotion(button, {
            ScaleTarget = entryScaleTarget or button,
            HoverScale = 1.06,
            PressScale = 0.9,
            IncludeSiblingTextScale = true,
        })

        if button:IsA("GuiButton") then
            table.insert(self._uiConnections, button.Activated:Connect(function()
                if self:_isPanelCurrentlyOpen() then
                    self:_closePanel()
                else
                    self:_openPanel()
                end
            end))
        elseif button:IsA("GuiObject") then
            button.Active = true
            table.insert(self._uiConnections, button.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    if self:_isPanelCurrentlyOpen() then
                        self:_closePanel()
                    else
                        self:_openPanel()
                    end
                end
            end))
        end
    end

    bindOpenButton(self._hud and findDescendant(self._hud, "UpgradeEntry.Button"))
    bindOpenButton(self._hud and findDescendant(self._hud, "UpgradeEntry.ImageButton"))
    bindOpenButton(self._hud and findDescendant(self._hud, "UpgradeEntry.LabelButton"))
end

function AttributeUpgradeController:_bindUi(silent)
    local playerGui = self:_getPlayerGui()
    local main = playerGui and playerGui:FindFirstChild("Main")
    if not main then
        if not silent then
            warn("[AttributeUpgradeController] PlayerGui.Main is unavailable")
        end
        return false
    end

    if self._boundMain == main and self._panel and self._hud then
        return true
    end

    local previousHud = self._hud
    local previousHudDefaultState = self._hudDefaultState
    self:_cancelHudTransitionTweens()
    disconnectAll(self._uiConnections)
    self._boundMain = main
    self._hud = main:FindFirstChild("LevelUpgradeHud")
    self._panel = main:FindFirstChild("AttributeUpgrade")
    self._experienceGroup = nil
    self._upgradeEntry = nil
    self._experienceGroupScale = nil
    self._hudDefaultState = nil
    self._cardsByKey = {}

    if not (self._hud and self._panel) then
        if not silent then
            warn("[AttributeUpgradeController] LevelUpgradeHud or AttributeUpgrade is unavailable")
        end
        return false
    end

    self._experienceFill = findDescendant(self._hud, "ExperienceGroup.ExperienceBar.Fill")
    self._experienceValue = findDescendant(self._hud, "ExperienceGroup.ExperienceBar.Value")
    self._levelLabel = findDescendant(self._hud, "ExperienceGroup.LevelLabel")
    if previousHud == self._hud and previousHudDefaultState then
        self._experienceGroup = self._hud:FindFirstChild("ExperienceGroup")
        self._upgradeEntry = self._hud:FindFirstChild("UpgradeEntry")
        self._experienceGroupScale = ensureUiScale(self._experienceGroup, "AttributeUpgradeExperienceMotionScale")
        self._hudDefaultState = previousHudDefaultState
    else
        self:_captureLevelHudDefaults()
    end
    self._badge = findDescendant(self._hud, "UpgradeEntry.ImageButton.Badge")
        or findDescendant(self._hud, "UpgradeEntry.Button.Badge")
    self._badgeValue = findDescendant(self._hud, "UpgradeEntry.ImageButton.Badge.Value")
        or findDescendant(self._hud, "UpgradeEntry.Button.Badge.Value")
    self._pointsValue = findDescendant(self._panel, "Window.Content.PointsBar.Value")
    self._footer = findDescendant(self._panel, "Window.Content.Footer")

    local closeButton = findDescendant(self._panel, "Window.CloseButton")
        or findDescendant(self._panel, "Window.Header.CloseButton")
    if closeButton and closeButton:IsA("GuiButton") then
        self:_bindButtonMotion(closeButton, {
            RotationTarget = closeButton,
            HoverScale = 1.12,
            PressScale = 0.88,
            HoverRotation = 8,
        })
        table.insert(self._uiConnections, closeButton.Activated:Connect(function()
            self:_closePanel()
        end))
    end

    local labelButtonText = findDescendant(self._hud, "UpgradeEntry.LabelButton.Label")
    setText(labelButtonText, "Upgrade")

    local statsGrid = findDescendant(self._panel, "Window.Content.StatsGrid")
    for _, attributeKey in ipairs(AttributeConfig.Order) do
        local card = self:_bindCard(statsGrid, attributeKey)
        if card then
            self._cardsByKey[attributeKey] = card
        elseif not silent then
            warn(string.format("[AttributeUpgradeController] Missing card for %s", tostring(attributeKey)))
        end
    end

    self:_connectEntryButtons()
    return true
end

function AttributeUpgradeController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    self._bindRetryQueued = true
    task.spawn(function()
        for _ = 1, UI_BIND_RETRY_COUNT do
            task.wait(UI_BIND_RETRY_INTERVAL_SECONDS)
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                if self._latestPayload then
                    self:_applyState(self._latestPayload)
                end
                return
            end
        end
        self._bindRetryQueued = false
    end)
end

function AttributeUpgradeController:_applyHud(payload, attributeState)
    if self._hud then
        self._hud.Visible = payload and payload.isInArena == true and payload.alive == true
    end

    local experience = math.max(0, math.floor(tonumber(payload and payload.experience) or 0))
    local nextExperience = math.max(1, math.floor(tonumber(payload and payload.nextLevelExperience) or 1))
    local ratio = math.clamp(experience / nextExperience, 0, 1)
    if self._experienceFill and self._experienceFill:IsA("GuiObject") then
        self._experienceFill.Size = UDim2.fromScale(ratio, 1)
    end
    setText(self._experienceValue, string.format("%d/%d", experience, nextExperience))
    setText(self._levelLabel, string.format("Level %d", math.max(1, math.floor(tonumber(payload and payload.level) or 1))))

    local skillPoints = attributeState.skillPoints
    if self._badge and self._badge:IsA("GuiObject") then
        self._badge.Visible = skillPoints > 0
    end
    setText(self._badgeValue, tostring(skillPoints))
end

function AttributeUpgradeController:_applyCard(attributeKey, card, attributeState)
    local definition = AttributeConfig.GetDefinition(attributeKey)
    if not (definition and card) then
        return
    end

    local levels = AttributeConfig.NormalizeLevels(attributeState.attributeLevels, attributeState.attributeCaps)
    local caps = AttributeConfig.NormalizeCaps(attributeState.attributeCaps)
    local level = math.max(0, math.floor(tonumber(levels[attributeKey]) or 0))
    local cap = math.max(0, math.floor(tonumber(caps[attributeKey]) or 0))
    local isPending = self._pendingByKey[attributeKey] == true
    local canUpgrade = self:_isBattleReady() and attributeState.skillPoints > 0 and level < cap and not isPending

    setText(card.Name, definition.DisplayName)
    setText(card.Level, string.format("Lv.%d/%d", level, cap))
    setText(card.Effect, AttributeConfig.FormatEffect(attributeKey, level))
    setText(card.AddButtonLabel, isPending and "..." or (level >= cap and "MAX" or "+"))
    setButtonEnabled(card.AddButton, card.AddButtonLabel, canUpgrade)

    self:_syncProgressSegments(card.Progress, cap, level)
end

function AttributeUpgradeController:_applyState(payload)
    if not payload then
        return
    end
    if not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    local attributeState = extractAttributeState(payload)
    self:_applyHud(payload, attributeState)
    setText(self._pointsValue, tostring(attributeState.skillPoints))
    for _, attributeKey in ipairs(AttributeConfig.Order) do
        self:_applyCard(attributeKey, self._cardsByKey[attributeKey], attributeState)
    end
end

function AttributeUpgradeController:_onFeedback(payload)
    local attributeKey = AttributeConfig.NormalizeKey(payload and payload.attributeKey)
    if attributeKey then
        self._pendingByKey[attributeKey] = nil
    else
        table.clear(self._pendingByKey)
    end

    local message = tostring(payload and payload.message or "")
    if message ~= "" then
        self:_showMessage(message)
    end
    self:_applyState(self._latestPayload)
end

function AttributeUpgradeController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._modalUiController = dependencies and dependencies.ModalUiController or nil
    self._latestPayload = nil
    self._pendingByKey = {}
    self._boundMain = nil
    disconnectAll(self._connections)
    disconnectAll(self._uiConnections)
    self:_disconnectOutsideCloseInput()

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.AttributeUpgradeFeedback)
    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    self._requestEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestAttributeUpgrade)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestPayload = payload
        table.clear(self._pendingByKey)
        self:_applyState(payload)
    end))

    table.insert(self._connections, feedbackEvent.OnClientEvent:Connect(function(payload)
        self:_onFeedback(payload)
    end))

    local playerGui = self:_getPlayerGui()
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self._boundMain = nil
                    if self:_bindUi(true) and self._latestPayload then
                        self:_applyState(self._latestPayload)
                    end
                end)
            end
        end))
        table.insert(self._connections, playerGui.DescendantAdded:Connect(function(descendant)
            if descendant.Name == "AttributeUpgrade" or descendant.Name == "LevelUpgradeHud" or descendant.Name == "StatsGrid" then
                task.defer(function()
                    self._boundMain = nil
                    if self:_bindUi(true) and self._latestPayload then
                        self:_applyState(self._latestPayload)
                    end
                end)
            end
        end))
    end

    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        task.defer(function()
            requestStateSyncEvent:FireServer()
        end)
    end
end

return AttributeUpgradeController
