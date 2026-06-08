--[[
Script: AttributeUpgradeController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AttributeUpgradeController
Purpose: Bind the static in-battle attribute upgrade UI to PlayerStateSync and server requests.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
AttributeUpgradeController._cardsByKey = {}
AttributeUpgradeController._requestEvent = nil

local UI_BIND_RETRY_COUNT = 80
local UI_BIND_RETRY_INTERVAL_SECONDS = 0.25
local PENDING_TIMEOUT_SECONDS = 1.5
local MODAL_OWNER_ID = "AttributeUpgrade"

local ENABLED_BUTTON_COLOR = Color3.fromRGB(73, 207, 93)
local DISABLED_BUTTON_COLOR = Color3.fromRGB(100, 105, 112)
local ENABLED_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local DISABLED_TEXT_COLOR = Color3.fromRGB(205, 210, 220)
local ACTIVE_PROGRESS_COLOR = Color3.fromRGB(255, 213, 82)
local INACTIVE_PROGRESS_COLOR = Color3.fromRGB(69, 73, 86)

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

function AttributeUpgradeController:_closePanel()
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
        self:_applyState(self._latestPayload)
        return true
    end

    if self._panel then
        if self._modalUiController and self._modalUiController.PlayPanelOpen then
            self._modalUiController:PlayPanelOpen(MODAL_OWNER_ID, self._panel)
        else
            self._panel.Visible = true
            if self._modalUiController and self._modalUiController.Acquire then
                self._modalUiController:Acquire(MODAL_OWNER_ID, self._panel)
            end
        end
    end
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
        })

        if button:IsA("GuiButton") then
            table.insert(self._uiConnections, button.Activated:Connect(function()
                self:_openPanel()
            end))
        elseif button:IsA("GuiObject") then
            button.Active = true
            table.insert(self._uiConnections, button.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    self:_openPanel()
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

    disconnectAll(self._uiConnections)
    self._boundMain = main
    self._hud = main:FindFirstChild("LevelUpgradeHud")
    self._panel = main:FindFirstChild("AttributeUpgrade")
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
    self._badge = findDescendant(self._hud, "UpgradeEntry.Button.Badge")
    self._badgeValue = findDescendant(self._hud, "UpgradeEntry.Button.Badge.Value")
    self._pointsValue = findDescendant(self._panel, "Window.Content.PointsBar.Value")
    self._footer = findDescendant(self._panel, "Window.Content.Footer")

    local closeButton = findDescendant(self._panel, "Window.Header.CloseButton")
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

    local progress = card.Progress
    if progress then
        local segments = {}
        for index = 1, 5 do
            local segment = progress:FindFirstChild("Segment" .. index)
            if segment and segment:IsA("GuiObject") then
                table.insert(segments, segment)
            end
        end
        local filledSegments = 0
        if cap > 0 and #segments > 0 then
            filledSegments = math.clamp(math.floor((level / cap) * #segments + 0.0001), 0, #segments)
            if level > 0 and filledSegments < 1 then
                filledSegments = 1
            end
        end
        for index, segment in ipairs(segments) do
            segment.BackgroundColor3 = index <= filledSegments and ACTIVE_PROGRESS_COLOR or INACTIVE_PROGRESS_COLOR
            segment.BackgroundTransparency = index <= filledSegments and 0 or 0.25
        end
    end
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
