--[[
脚本名字: NewWeaponUnlockController
脚本文件: NewWeaponUnlockController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/NewWeaponUnlockController
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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
        "[NewWeaponUnlockController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local NewWeaponUnlockController = {}

NewWeaponUnlockController._localPlayer = nil
NewWeaponUnlockController._connections = {}
NewWeaponUnlockController._buttonConnections = {}
NewWeaponUnlockController._panelVisibleConnection = nil
NewWeaponUnlockController._mainGui = nil
NewWeaponUnlockController._panel = nil
NewWeaponUnlockController._claimButton = nil
NewWeaponUnlockController._weaponImage = nil
NewWeaponUnlockController._nameLabel = nil
NewWeaponUnlockController._attackLabel = nil
NewWeaponUnlockController._rewardLabel = nil
NewWeaponUnlockController._requestClaimEvent = nil
NewWeaponUnlockController._requestStateSyncEvent = nil
NewWeaponUnlockController._pendingPayloads = {}
NewWeaponUnlockController._queuedTierIndexes = {}
NewWeaponUnlockController._activePayload = nil
NewWeaponUnlockController._activeTierKey = nil
NewWeaponUnlockController._isOpen = false
NewWeaponUnlockController._isClaiming = false
NewWeaponUnlockController._bindRetryQueued = false
NewWeaponUnlockController._animationSerial = 0
NewWeaponUnlockController._activeTweens = {}
NewWeaponUnlockController._originalPanelPosition = nil
NewWeaponUnlockController._originalChildPositions = {}

local PANEL_OFFSET = UDim2.fromOffset(-180, 0)
local CHILD_OFFSET = UDim2.fromOffset(-80, 0)
local PANEL_IN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PANEL_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CHILD_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_IN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local MODAL_OWNER_ID = "NewWeaponUnlock"
local MODAL_Z_INDEX = 10
local ORIGINAL_Z_INDEX_ATTRIBUTE = "NewWeaponUnlockOriginalZIndex"

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
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

local function setGuiEnabled(guiObject, enabled)
    if guiObject and guiObject:IsA("GuiButton") then
        guiObject.Active = enabled == true
        guiObject.AutoButtonColor = enabled == true
    end
end

local function offsetPosition(position, offset)
    return UDim2.new(
        position.X.Scale + offset.X.Scale,
        position.X.Offset + offset.X.Offset,
        position.Y.Scale + offset.Y.Scale,
        position.Y.Offset + offset.Y.Offset
    )
end

local function raiseModalRootZIndex(root, zIndex)
    if root and root:IsA("GuiObject") then
        root.ZIndex = math.max(root.ZIndex, zIndex)
    end
end

local function raiseDescendantZIndex(root, baseZIndex)
    if not root then
        return
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("GuiObject") then
            local originalZIndex = descendant:GetAttribute(ORIGINAL_Z_INDEX_ATTRIBUTE)
            if typeof(originalZIndex) ~= "number" then
                originalZIndex = descendant.ZIndex
                descendant:SetAttribute(ORIGINAL_Z_INDEX_ATTRIBUTE, originalZIndex)
            end

            descendant.ZIndex = baseZIndex + originalZIndex
        end
    end
end

local function normalizeTierIndex(value)
    local tierIndex = tonumber(value)
    if not tierIndex then
        return nil
    end
    return math.floor(tierIndex)
end

local function resolveWeaponIcon(payload)
    local tierIndex = payload and normalizeTierIndex(payload.tierIndex) or nil
    local tierName = payload and payload.tier or nil
    if (tierName == nil or tostring(tierName) == "") and tierIndex then
        tierName = WeaponTierConfig.Order[tierIndex]
    end

    if tierName then
        local iconImage = WeaponTierConfig.GetIconImageForTier(tierName)
        if iconImage and tostring(iconImage) ~= "" then
            return tostring(iconImage)
        end
    end

    return tostring(payload and payload.weaponIcon or "")
end

local function isInputInsideGuiObject(guiObject, inputObject)
    if not (guiObject and guiObject:IsA("GuiObject") and guiObject.Visible == true and inputObject) then
        return false
    end

    local inputPosition = inputObject.Position
    local pointer = Vector2.new(inputPosition.X, inputPosition.Y)
    local absolutePosition = guiObject.AbsolutePosition
    local absoluteSize = guiObject.AbsoluteSize
    return pointer.X >= absolutePosition.X
        and pointer.X <= absolutePosition.X + absoluteSize.X
        and pointer.Y >= absolutePosition.Y
        and pointer.Y <= absolutePosition.Y + absoluteSize.Y
end

function NewWeaponUnlockController:_getActiveTierIndex()
    if self._activePayload then
        local payloadTierIndex = normalizeTierIndex(self._activePayload.tierIndex)
        if payloadTierIndex then
            return payloadTierIndex
        end
    end

    local keyTierIndex = normalizeTierIndex(self._activeTierKey)
    if keyTierIndex then
        return keyTierIndex
    end

    if self._panel and self._panel:IsA("GuiObject") then
        return normalizeTierIndex(self._panel:GetAttribute("ActiveWeaponUnlockTierIndex"))
    end

    return nil
end

function NewWeaponUnlockController:_cancelTweens()
    for _, tween in ipairs(self._activeTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._activeTweens)
end

function NewWeaponUnlockController:_disconnectPanelVisibleWatcher()
    disconnectConnection(self._panelVisibleConnection)
    self._panelVisibleConnection = nil
end

function NewWeaponUnlockController:_ensurePanelVisibleWatcher()
    self:_disconnectPanelVisibleWatcher()
end

function NewWeaponUnlockController:_rememberPositions()
    if self._panel and not self._originalPanelPosition then
        self._originalPanelPosition = self._panel.Position
    end

    local nodes = {
        self._weaponImage,
        self._nameLabel,
        self._attackLabel and self._attackLabel.Parent,
        self._rewardLabel and self._rewardLabel.Parent,
        self._claimButton,
    }
    for _, node in ipairs(nodes) do
        if node and node:IsA("GuiObject") and not self._originalChildPositions[node] then
            self._originalChildPositions[node] = node.Position
        end
    end
end

function NewWeaponUnlockController:_applyPayload(payload)
    if not payload then
        return
    end

    if self._weaponImage and (self._weaponImage:IsA("ImageLabel") or self._weaponImage:IsA("ImageButton")) then
        self._weaponImage.Image = resolveWeaponIcon(payload)
    end
    setText(self._nameLabel, payload.weaponName or "")
    setText(self._attackLabel, math.max(0, math.floor(tonumber(payload.damage) or 0)))
    setText(self._rewardLabel, math.max(0, math.floor(tonumber(payload.rewardDiamonds) or 0)))
end

function NewWeaponUnlockController:_playOpen(payload)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return false
    end

    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()
    self:_rememberPositions()

    local activeTierIndex = normalizeTierIndex(payload and payload.tierIndex)
    if not activeTierIndex then
        return false
    end
    self._isOpen = true
    self._isClaiming = false
    self._activePayload = payload
    if activeTierIndex then
        self._activeTierKey = tostring(activeTierIndex)
    else
        self._activeTierKey = tostring(payload and payload.tierIndex or "")
    end
    if self._mainGui and self._mainGui:IsA("ScreenGui") then
        self._mainGui.Enabled = true
    end
    raiseModalRootZIndex(self._panel, MODAL_Z_INDEX)
    raiseDescendantZIndex(self._panel, MODAL_Z_INDEX)
    self._panel:SetAttribute("ActiveWeaponUnlockTierIndex", activeTierIndex)
    ModalUiController:Acquire(MODAL_OWNER_ID, self._panel)
    self._panel.Visible = true
    self:_applyPayload(payload)
    task.defer(function()
        if serial == self._animationSerial and self._isOpen and self._activePayload == payload then
            self:_applyPayload(payload)
        end
    end)
    self._panel.Position = offsetPosition(self._originalPanelPosition or self._panel.Position, PANEL_OFFSET)
    local panelScale = ensureUiScale(self._panel)
    if panelScale then
        panelScale.Scale = 0.96
    end

    local childNodes = {
        self._weaponImage,
        self._nameLabel,
        self._attackLabel and self._attackLabel.Parent,
        self._rewardLabel and self._rewardLabel.Parent,
    }
    for _, node in ipairs(childNodes) do
        if node and node:IsA("GuiObject") then
            node.Visible = true
            node.Position = offsetPosition(self._originalChildPositions[node] or node.Position, CHILD_OFFSET)
        end
    end

    if self._claimButton and self._claimButton:IsA("GuiObject") then
        self._claimButton.Visible = false
        setGuiEnabled(self._claimButton, false)
    end

    local panelTween = TweenService:Create(self._panel, PANEL_IN, {
        Position = self._originalPanelPosition or self._panel.Position,
    })
    table.insert(self._activeTweens, panelTween)
    if panelScale then
        table.insert(self._activeTweens, TweenService:Create(panelScale, PANEL_IN, {
            Scale = 1,
        }))
    end

    panelTween:Play()
    if panelScale and self._activeTweens[#self._activeTweens] then
        self._activeTweens[#self._activeTweens]:Play()
    end

    task.spawn(function()
        for index, node in ipairs(childNodes) do
            task.wait(0.045)
            if serial ~= self._animationSerial or not self._isOpen then
                return
            end
            if node and node:IsA("GuiObject") then
                local tween = TweenService:Create(node, CHILD_IN, {
                    Position = self._originalChildPositions[node] or node.Position,
                })
                table.insert(self._activeTweens, tween)
                tween:Play()
            end
        end

        task.wait(0.12)
        if serial ~= self._animationSerial or not self._isOpen then
            return
        end
        if self._claimButton and self._claimButton:IsA("GuiObject") then
            self._claimButton.Visible = true
            local claimScale = ensureUiScale(self._claimButton)
            if claimScale then
                claimScale.Scale = 0.75
                local tween = TweenService:Create(claimScale, CLAIM_IN, {
                    Scale = 1,
                })
                table.insert(self._activeTweens, tween)
                tween:Play()
            end
            setGuiEnabled(self._claimButton, true)
        end
    end)

    return true
end

function NewWeaponUnlockController:_playClose(afterClose)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if afterClose then
            afterClose()
        end
        return
    end

    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()
    self._isOpen = false
    setGuiEnabled(self._claimButton, false)

    local closeTween = TweenService:Create(self._panel, PANEL_OUT, {
        Position = offsetPosition(self._originalPanelPosition or self._panel.Position, PANEL_OFFSET),
    })
    table.insert(self._activeTweens, closeTween)
    closeTween.Completed:Connect(function()
        if serial ~= self._animationSerial then
            return
        end

        self._panel.Visible = false
        self._panel:SetAttribute("ActiveWeaponUnlockTierIndex", nil)
        if self._originalPanelPosition then
            self._panel.Position = self._originalPanelPosition
        end
        ModalUiController:Release(MODAL_OWNER_ID)
        if afterClose then
            afterClose()
        end
    end)
    closeTween:Play()
end

function NewWeaponUnlockController:_showNextQueued()
    if self._isOpen or self._activePayload then
        return
    end

    local payload = self._pendingPayloads[1]
    if payload then
        if not (self._panel and self._panel.Parent) then
            self:_bindUi(true)
        end
        if not (self._panel and self._panel.Parent) then
            self:_queueBindRetry()
            return
        end
        if self:_playOpen(payload) then
            table.remove(self._pendingPayloads, 1)
            self._queuedTierIndexes[tostring(payload.tierIndex or "")] = nil
        else
            self:_queueBindRetry()
        end
    end
end

function NewWeaponUnlockController:_handlePrompt(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.eventType ~= nil and tostring(payload.eventType) ~= "Show" then
        return
    end

    local tierIndex = normalizeTierIndex(payload.tierIndex)
    local tierKey
    if tierIndex then
        tierKey = tostring(tierIndex)
    else
        tierKey = tostring(payload.tierIndex or "")
    end
    local activeTierIndex = self:_getActiveTierIndex()
    local activeTierKey = ""
    if activeTierIndex then
        activeTierKey = tostring(activeTierIndex)
    end
    if tierKey ~= "" then
        if activeTierKey == tierKey then
            return
        end
        if self._queuedTierIndexes[tierKey] == true then
            return
        end
        self._queuedTierIndexes[tierKey] = true
    end

    if tierKey ~= "" then
        for _, existing in ipairs(self._pendingPayloads) do
            if tostring(existing and existing.tierIndex or "") == tierKey then
                return
            end
        end
    end

    table.insert(self._pendingPayloads, payload)
    self:_showNextQueued()
end

function NewWeaponUnlockController:_requestClaim()
    local activeTierIndex = self:_getActiveTierIndex()
    if self._isOpen and not self._activePayload and activeTierIndex then
        self._activePayload = {
            tierIndex = activeTierIndex,
        }
        self._activeTierKey = tostring(activeTierIndex)
    end

    if self._isClaiming or not self._requestClaimEvent then
        return
    end

    self._isClaiming = true
    setGuiEnabled(self._claimButton, false)
    self._requestClaimEvent:FireServer(activeTierIndex)
end

function NewWeaponUnlockController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    local eventType = tostring(payload.eventType or "")
    if payload.clearPending == true then
        table.clear(self._pendingPayloads)
        table.clear(self._queuedTierIndexes)
    end
    if eventType == "Success" then
        self:_playClose(function()
            self._activePayload = nil
            self._activeTierKey = nil
            self._isClaiming = false
            if self._requestStateSyncEvent then
                self._requestStateSyncEvent:FireServer()
            end
            self:_showNextQueued()
        end)
        return
    end

    self._isClaiming = false
    setGuiEnabled(self._claimButton, true)
    local message = tostring(payload.message or "")
    if message == "InvalidTier" or message == "NoPendingReward" or message == "AlreadyClaimed" then
        self:_playClose(function()
            self._activePayload = nil
            self._activeTierKey = nil
            if self._requestStateSyncEvent then
                self._requestStateSyncEvent:FireServer()
            end
            self:_showNextQueued()
        end)
    end
end

function NewWeaponUnlockController:_disconnectButtonBindings()
    disconnectAll(self._buttonConnections)
end

function NewWeaponUnlockController:_bindUi(silent)
    self._mainGui = findMainGui(self._localPlayer)
    self._panel = self._mainGui and self._mainGui:FindFirstChild("NewWeaponUnlock", true) or nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        self:_disconnectPanelVisibleWatcher()
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self:_ensurePanelVisibleWatcher()
    self._claimButton = self._panel:FindFirstChild("Claim", true)
    local weaponImage = self._panel:FindFirstChild("Weapon")
    self._weaponImage = (weaponImage and (weaponImage:IsA("ImageLabel") or weaponImage:IsA("ImageButton"))) and weaponImage or nil
    self._nameLabel = self._panel:FindFirstChild("Name", true)
    local attackRoot = self._panel:FindFirstChild("AtkBg", true)
    self._attackLabel = attackRoot and attackRoot:FindFirstChild("Number", true) or nil
    local rewardRoot = self._panel:FindFirstChild("Reward", true)
    self._rewardLabel = rewardRoot and rewardRoot:FindFirstChild("Number", true) or nil

    if not self._isOpen or not self._originalPanelPosition then
        self._originalPanelPosition = self._panel.Position
    end
    if not self._isOpen then
        table.clear(self._originalChildPositions)
        self:_rememberPositions()
    end
    raiseModalRootZIndex(self._panel, MODAL_Z_INDEX)
    if self._isOpen then
        self._panel.Visible = true
    else
        self._panel.Visible = false
        setGuiEnabled(self._claimButton, false)
    end

    if self._claimButton and self._claimButton:IsA("GuiButton") then
        table.insert(self._buttonConnections, self._claimButton.Activated:Connect(function()
            self:_requestClaim()
        end))
        table.insert(self._buttonConnections, self._claimButton.InputEnded:Connect(function(inputObject)
            if inputObject.UserInputType == Enum.UserInputType.MouseButton1
                or inputObject.UserInputType == Enum.UserInputType.Touch
            then
                if not UserInputService:GetFocusedTextBox() then
                    self:_requestClaim()
                end
            end
        end))
        table.insert(self._buttonConnections, UserInputService.InputEnded:Connect(function(inputObject, gameProcessed)
            if gameProcessed then
                return
            end
            if not self._isOpen or self._isClaiming then
                return
            end
            if inputObject.UserInputType ~= Enum.UserInputType.MouseButton1
                and inputObject.UserInputType ~= Enum.UserInputType.Touch
            then
                return
            end
            if isInputInsideGuiObject(self._claimButton, inputObject) and not UserInputService:GetFocusedTextBox() then
                self:_requestClaim()
            end
        end))
    end
    return true
end

function NewWeaponUnlockController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                self:_showNextQueued()
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[NewWeaponUnlockController] 找不到 PlayerGui/Main/NewWeaponUnlock，新武器解锁弹框暂不可用。")
    end)
end

function NewWeaponUnlockController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_disconnectPanelVisibleWatcher()
    self._pendingPayloads = {}
    self._queuedTierIndexes = {}
    self._activePayload = nil
    self._activeTierKey = nil
    self._isOpen = false
    self._isClaiming = false

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local promptEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WeaponUnlockPrompt)
    self._requestClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestWeaponUnlockReward)
    local feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WeaponUnlockRewardFeedback)
    self._requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    if self._requestStateSyncEvent then
        task.defer(function()
            if self._requestStateSyncEvent then
                self._requestStateSyncEvent:FireServer()
            end
        end)
    end

    table.insert(self._connections, promptEvent.OnClientEvent:Connect(function(payload)
        if not (self._panel and self._panel.Parent) then
            self:_bindUi(true)
        end
        self:_handlePrompt(payload)
    end))

    table.insert(self._connections, feedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleFeedback(payload)
    end))

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi(true)
                    self:_showNextQueued()
                end)
            end
        end))
    end
end

return NewWeaponUnlockController
