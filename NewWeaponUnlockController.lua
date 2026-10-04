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
local GuiService = game:GetService("GuiService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))
local CinematicUiGate = require(script.Parent:WaitForChild("CinematicUiGate"))

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
NewWeaponUnlockController._backdrop = nil
NewWeaponUnlockController._panelAncestryConnection = nil
NewWeaponUnlockController._isClosing = false
NewWeaponUnlockController._claimSerial = 0
NewWeaponUnlockController._claimResolution = nil
NewWeaponUnlockController._acknowledgedTierIndexes = {}
NewWeaponUnlockController._pointerCandidates = {}
NewWeaponUnlockController._pointerDownKeys = {}
NewWeaponUnlockController._inputArmedAt = 0
NewWeaponUnlockController._originalPanelScale = 1
NewWeaponUnlockController._lifecycleSerial = 0

local PANEL_OFFSET = UDim2.fromOffset(0, 14)
local PANEL_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PANEL_OUT = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local POINTER_ARM_DELAY = 0.12
local POINTER_MAX_DURATION = 0.65
local POINTER_MAX_MOVEMENT = 14
local CLAIM_TIMEOUT = 6
local MODAL_OWNER_ID = "NewWeaponUnlock"
local MODAL_Z_INDEX = 12
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
        guiObject.AutoButtonColor = false
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

local function getPointerKey(inputObject)
    if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
        return "MouseButton1"
    end
    if inputObject.UserInputType == Enum.UserInputType.Touch then
        return inputObject
    end
    return nil
end

local function getPointerPosition(inputObject)
    return Vector2.new(inputObject.Position.X, inputObject.Position.Y)
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
    disconnectConnection(self._panelAncestryConnection)
    self._panelAncestryConnection = nil
end

function NewWeaponUnlockController:_ensurePanelVisibleWatcher()
    self:_disconnectPanelVisibleWatcher()
    local panel = self._panel
    if not panel then
        return
    end
    self._panelAncestryConnection = panel.AncestryChanged:Connect(function()
        if self._panel == panel and (not panel.Parent or not self._mainGui or not self._mainGui.Parent) then
            self:_releasePresentation()
            self:_queueBindRetry()
        end
    end)
end

function NewWeaponUnlockController:_clearPointers()
    table.clear(self._pointerCandidates)
    table.clear(self._pointerDownKeys)
end

function NewWeaponUnlockController:_releasePresentation()
    self._animationSerial += 1
    self:_cancelTweens()
    self:_clearPointers()
    self._isOpen = false
    self._isClosing = false
    if self._panel then
        self._panel.Visible = false
        self._panel:SetAttribute("ActiveWeaponUnlockTierIndex", nil)
        if self._originalPanelPosition then
            self._panel.Position = self._originalPanelPosition
        end
        local scale = self._panel:FindFirstChildOfClass("UIScale")
        if scale then
            scale.Scale = self._originalPanelScale
        end
    end
    if self._backdrop then
        self._backdrop.Visible = false
        setGuiEnabled(self._backdrop, false)
    end
    setGuiEnabled(self._claimButton, false)
    ModalUiController:Release(MODAL_OWNER_ID)
end

function NewWeaponUnlockController:_canInteract()
    return not CinematicUiGate:IsBlocked() and self._isOpen and not self._isClosing and not self._isClaiming
        and not GuiService.MenuIsOpen
        and self._panel and self._panel.Parent and self._panel.Visible
        and self._mainGui and self._mainGui.Enabled
        and os.clock() >= self._inputArmedAt
end

function NewWeaponUnlockController:_getPointerTarget(inputObject)
    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if not (playerGui and self._panel) then
        return nil
    end
    local position = inputObject.Position
    local objects = playerGui:GetGuiObjectsAtPosition(position.X, position.Y)
    for _, object in ipairs(objects) do
        if object.Visible then
            if self._claimButton and (object == self._claimButton or object:IsDescendantOf(self._claimButton)) then
                return "claim"
            end
            if object == self._panel or object == self._backdrop or object:IsDescendantOf(self._panel) then
                return "blank"
            end
            -- The shared dim is visual only. A different modal/control blocks dismissal.
            if object.Name ~= "__ModalDimOverlay" then
                return nil
            end
        end
    end
    return nil
end

function NewWeaponUnlockController:_handlePointerBegan(inputObject)
    local key = getPointerKey(inputObject)
    if not key or not self:_canInteract() or UserInputService:GetFocusedTextBox() then
        return
    end
    self._pointerDownKeys[key] = true
    local pointerCount = 0
    for _ in pairs(self._pointerDownKeys) do
        pointerCount += 1
    end
    if pointerCount > 1 then
        table.clear(self._pointerCandidates)
        return
    end
    local target = self:_getPointerTarget(inputObject)
    if target then
        self._pointerCandidates[key] = {
            position = getPointerPosition(inputObject),
            startedAt = os.clock(),
            serial = self._animationSerial,
            target = target,
        }
    end
end

function NewWeaponUnlockController:_handlePointerChanged(inputObject)
    local key = inputObject.UserInputType == Enum.UserInputType.MouseMovement and "MouseButton1" or getPointerKey(inputObject)
    local candidate = key and self._pointerCandidates[key]
    if candidate and (getPointerPosition(inputObject) - candidate.position).Magnitude > POINTER_MAX_MOVEMENT then
        self._pointerCandidates[key] = nil
    end
end

function NewWeaponUnlockController:_handlePointerEnded(inputObject)
    local key = getPointerKey(inputObject)
    if not key then
        return
    end
    local candidate = self._pointerCandidates[key]
    self._pointerCandidates[key] = nil
    self._pointerDownKeys[key] = nil
    if not candidate or not self:_canInteract() or UserInputService:GetFocusedTextBox() then
        return
    end
    if candidate.serial ~= self._animationSerial
        or os.clock() - candidate.startedAt > POINTER_MAX_DURATION
        or (getPointerPosition(inputObject) - candidate.position).Magnitude > POINTER_MAX_MOVEMENT
        or candidate.target ~= self:_getPointerTarget(inputObject)
    then
        return
    end
    self:_requestClaim()
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
    if CinematicUiGate:IsBlocked() then
        return false
    end
    local activeTierIndex = normalizeTierIndex(payload and payload.tierIndex)
    if not (self._panel and self._panel.Parent and activeTierIndex and activeTierIndex > 1) then
        return false
    end

    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()
    self:_clearPointers()
    self:_rememberPositions()
    self._isOpen = true
    self._isClosing = false
    self._isClaiming = false
    self._claimResolution = nil
    self._activePayload = payload
    self._activeTierKey = tostring(activeTierIndex)
    self._inputArmedAt = os.clock() + POINTER_ARM_DELAY
    self._mainGui.Enabled = true
    raiseModalRootZIndex(self._panel, MODAL_Z_INDEX)
    raiseDescendantZIndex(self._panel, MODAL_Z_INDEX)
    self._panel:SetAttribute("ActiveWeaponUnlockTierIndex", activeTierIndex)
    ModalUiController:Acquire(MODAL_OWNER_ID, self._panel, {
        SuppressExclusions = self._backdrop and { self._backdrop } or {},
    })
    if self._backdrop then
        self._backdrop.Visible = true
        setGuiEnabled(self._backdrop, true)
    end
    self._panel.Visible = true
    self:_applyPayload(payload)
    task.defer(function()
        if serial == self._animationSerial and self._isOpen and self._activePayload == payload then
            self:_applyPayload(payload)
        end
    end)

    -- Show the complete reward immediately; a single short motion keeps the existing art intact.
    for node, position in pairs(self._originalChildPositions) do
        if node.Parent then
            node.Position = position
            node.Visible = true
        end
    end
    if self._claimButton then
        local claimScale = self._claimButton:FindFirstChildOfClass("UIScale")
        if claimScale then
            claimScale.Scale = 1
        end
    end
    setGuiEnabled(self._claimButton, true)
    self._panel.Position = offsetPosition(self._originalPanelPosition, PANEL_OFFSET)
    local panelScale = ensureUiScale(self._panel)
    panelScale.Scale = self._originalPanelScale * 0.94
    table.insert(self._activeTweens, TweenService:Create(self._panel, PANEL_IN, {
        Position = self._originalPanelPosition,
    }))
    table.insert(self._activeTweens, TweenService:Create(panelScale, PANEL_IN, {
        Scale = self._originalPanelScale,
    }))
    for _, tween in ipairs(self._activeTweens) do
        tween:Play()
    end
    return true
end

function NewWeaponUnlockController:_playClose(afterClose)
    self._animationSerial += 1
    local serial = self._animationSerial
    self:_cancelTweens()
    self:_clearPointers()
    self._isOpen = false
    self._isClosing = true
    setGuiEnabled(self._claimButton, false)
    local panel = self._panel
    if not (panel and panel.Parent) then
        self:_releasePresentation()
        if afterClose then
            afterClose()
        end
        return
    end

    local closeTween = TweenService:Create(panel, PANEL_OUT, {
        Position = offsetPosition(self._originalPanelPosition, PANEL_OFFSET),
    })
    local panelScale = ensureUiScale(panel)
    local scaleTween = TweenService:Create(panelScale, PANEL_OUT, {
        Scale = self._originalPanelScale * 0.96,
    })
    table.insert(self._activeTweens, closeTween)
    table.insert(self._activeTweens, scaleTween)
    closeTween.Completed:Once(function(playbackState)
        if serial ~= self._animationSerial or playbackState ~= Enum.PlaybackState.Completed then
            return
        end
        self:_releasePresentation()
        if afterClose then
            afterClose()
        end
    end)
    closeTween:Play()
    scaleTween:Play()
end

function NewWeaponUnlockController:_finishResolvedClaim()
    if self._isClosing or self._isClaiming or not self._claimResolution then
        return
    end
    local resolution = self._claimResolution
    self._claimResolution = nil
    if resolution == "retry" then
        -- Keep the same reward pending; an in-flight request still resolves during a cinematic.
        if CinematicUiGate:IsBlocked() then
            return
        end
        if self._activePayload then
            if not (self._panel and self._panel.Parent) then
                self:_bindUi(true)
            end
            if not self._isOpen and not self:_playOpen(self._activePayload) then
                self:_queueBindRetry()
            end
        end
        return
    end

    self._activePayload = nil
    self._activeTierKey = nil
    if self._requestStateSyncEvent then
        self._requestStateSyncEvent:FireServer()
    end
    self:_showNextQueued()
end

function NewWeaponUnlockController:_showNextQueued()
    if CinematicUiGate:IsBlocked() or self._isOpen or self._isClosing or self._isClaiming or self._activePayload then
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
            self._queuedTierIndexes[tostring(normalizeTierIndex(payload.tierIndex))] = nil
        else
            self:_queueBindRetry()
        end
    end
end

function NewWeaponUnlockController:_resumeAfterCinematic()
    if CinematicUiGate:IsBlocked() or self._isClaiming or self._isClosing then
        return
    end
    if self._claimResolution then
        self:_finishResolvedClaim()
    end
    if self._isOpen then
        return
    end
    if self._activePayload then
        local tierKey = tostring(normalizeTierIndex(self._activePayload.tierIndex))
        if self._acknowledgedTierIndexes[tierKey] then
            self._activePayload = nil
            self._activeTierKey = nil
        elseif not (self._panel and self._panel.Parent) then
            self:_queueBindRetry()
            return
        else
            self:_playOpen(self._activePayload)
            return
        end
    end
    self:_showNextQueued()
end

function NewWeaponUnlockController:HasPendingRewardPresentation()
    return self._activePayload ~= nil or self._isClaiming or #self._pendingPayloads > 0
end

function NewWeaponUnlockController:_handlePrompt(payload)
    if type(payload) ~= "table" or (payload.eventType ~= nil and tostring(payload.eventType) ~= "Show") then
        return
    end
    local tierIndex = normalizeTierIndex(payload.tierIndex)
    if not tierIndex or tierIndex <= 1 then
        return
    end
    local tierKey = tostring(tierIndex)
    if self._acknowledgedTierIndexes[tierKey] or self._queuedTierIndexes[tierKey]
        or self:_getActiveTierIndex() == tierIndex
    then
        return
    end
    self._queuedTierIndexes[tierKey] = true
    table.insert(self._pendingPayloads, payload)
    table.sort(self._pendingPayloads, function(left, right)
        return (normalizeTierIndex(left.tierIndex) or 0) < (normalizeTierIndex(right.tierIndex) or 0)
    end)
    self:_showNextQueued()
end

function NewWeaponUnlockController:_resolveClaim(resolution)
    self._claimSerial += 1
    self._isClaiming = false
    self._claimResolution = resolution
    if self._isOpen and resolution ~= "retry" then
        self:_playClose(function()
            self:_finishResolvedClaim()
        end)
    else
        self:_finishResolvedClaim()
    end
end

function NewWeaponUnlockController:_onClaimTimeout(serial, tierIndex)
    if serial ~= self._claimSerial or not self._isClaiming or self:_getActiveTierIndex() ~= tierIndex then
        return
    end
    warn("[NewWeaponUnlockController] Reward response timed out; showing the same reward for retry.")
    self:_resolveClaim("retry")
end

function NewWeaponUnlockController:_requestClaim()
    local activeTierIndex = self:_getActiveTierIndex()
    if not self:_canInteract() or not activeTierIndex or not self._requestClaimEvent then
        return
    end

    self._claimSerial += 1
    local serial = self._claimSerial
    self._isClaiming = true
    self._claimResolution = nil
    -- Only the presentation closes optimistically. Ownership and diamonds remain server-authoritative.
    self:_playClose(function()
        self:_finishResolvedClaim()
    end)
    local sent, failure = pcall(function()
        self._requestClaimEvent:FireServer(activeTierIndex)
    end)
    if not sent then
        warn("[NewWeaponUnlockController] Reward request failed: " .. tostring(failure))
        self:_resolveClaim("retry")
        return
    end
    task.delay(CLAIM_TIMEOUT, function()
        self:_onClaimTimeout(serial, activeTierIndex)
    end)
end

function NewWeaponUnlockController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end
    local eventType = tostring(payload.eventType or "")
    if eventType ~= "Success" and eventType ~= "Failed" then
        return
    end
    local tierIndex = normalizeTierIndex(payload.tierIndex)
    local activeTierIndex = self:_getActiveTierIndex()
    local message = tostring(payload.message or "")
    if tierIndex and self._acknowledgedTierIndexes[tostring(tierIndex)] and eventType == "Failed" then
        return
    end
    if tierIndex and (eventType == "Success" or message == "AlreadyClaimed") then
        local key = tostring(tierIndex)
        self._acknowledgedTierIndexes[key] = true
        self._queuedTierIndexes[key] = nil
        for index = #self._pendingPayloads, 1, -1 do
            if normalizeTierIndex(self._pendingPayloads[index].tierIndex) == tierIndex then
                table.remove(self._pendingPayloads, index)
            end
        end
    end
    -- Late feedback for a previous tier must not close or re-enable the next reward.
    if not activeTierIndex or (tierIndex and tierIndex ~= activeTierIndex) then
        return
    end
    if payload.clearPending == true then
        table.clear(self._pendingPayloads)
        table.clear(self._queuedTierIndexes)
    end
    if eventType == "Success" or message == "InvalidTier" or message == "NoPendingReward" or message == "AlreadyClaimed" then
        self:_resolveClaim("complete")
    else
        warn("[NewWeaponUnlockController] Reward was not claimed: " .. message)
        self:_resolveClaim("retry")
    end
end

function NewWeaponUnlockController:_disconnectButtonBindings()
    disconnectAll(self._buttonConnections)
    self:_clearPointers()
end

function NewWeaponUnlockController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    local panel = mainGui and mainGui:FindFirstChild("NewWeaponUnlock", true) or nil
    if panel == self._panel and panel and panel.Parent and #self._buttonConnections > 0 then
        return true
    end
    self:_disconnectButtonBindings()
    self:_disconnectPanelVisibleWatcher()
    self:_releasePresentation()
    self._mainGui = mainGui
    self._panel = panel
    self._backdrop = mainGui and mainGui:FindFirstChild("NewWeaponUnlockBackdrop") or nil
    if not (panel and panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._claimButton = panel:FindFirstChild("Claim", true)
    local weaponImage = panel:FindFirstChild("Weapon")
    self._weaponImage = (weaponImage and (weaponImage:IsA("ImageLabel") or weaponImage:IsA("ImageButton"))) and weaponImage or nil
    self._nameLabel = panel:FindFirstChild("Name", true)
    local attackRoot = panel:FindFirstChild("AtkBg", true)
    self._attackLabel = attackRoot and attackRoot:FindFirstChild("Number", true) or nil
    local rewardRoot = panel:FindFirstChild("Reward", true)
    self._rewardLabel = rewardRoot and rewardRoot:FindFirstChild("Number", true) or nil
    self._originalPanelPosition = panel.Position
    self._originalPanelScale = ensureUiScale(panel).Scale
    table.clear(self._originalChildPositions)
    self:_rememberPositions()
    panel.Visible = false
    if self._backdrop then
        self._backdrop.Visible = false
        setGuiEnabled(self._backdrop, false)
    end
    setGuiEnabled(self._claimButton, false)
    raiseModalRootZIndex(panel, MODAL_Z_INDEX)
    self:_ensurePanelVisibleWatcher()

    table.insert(self._buttonConnections, UserInputService.InputBegan:Connect(function(inputObject)
        self:_handlePointerBegan(inputObject)
    end))
    table.insert(self._buttonConnections, UserInputService.InputChanged:Connect(function(inputObject)
        self:_handlePointerChanged(inputObject)
    end))
    table.insert(self._buttonConnections, UserInputService.InputEnded:Connect(function(inputObject)
        self:_handlePointerEnded(inputObject)
    end))
    if self._claimButton and self._claimButton:IsA("GuiButton") then
        table.insert(self._buttonConnections, self._claimButton.Activated:Connect(function(inputObject)
            -- Mouse/touch use the single begin/move/end path; retain controller button support.
            if inputObject and string.find(inputObject.UserInputType.Name, "Gamepad", 1, true) == 1 then
                self:_requestClaim()
            end
        end))
    end
    -- A caller draining the pending queue owns its dequeue; do not drain it recursively here.
    if self._activePayload or self._claimResolution then
        self:_resumeAfterCinematic()
    end
    return true
end

function NewWeaponUnlockController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    local lifecycleSerial = self._lifecycleSerial
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if lifecycleSerial ~= self._lifecycleSerial then
                return
            end
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
    self._lifecycleSerial += 1
    self._claimSerial += 1
    self._bindRetryQueued = false
    self:_releasePresentation()
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self:_disconnectPanelVisibleWatcher()
    self._pendingPayloads = {}
    self._queuedTierIndexes = {}
    self._activePayload = nil
    self._activeTierKey = nil
    self._isOpen = false
    self._isClosing = false
    self._isClaiming = false
    self._claimResolution = nil
    self._acknowledgedTierIndexes = {}
    self._panel = nil

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

    table.insert(self._connections, CinematicUiGate:Subscribe(function(blocked)
        if blocked then
            -- Presentation only: preserve the active payload and pending claim/timeout.
            self:_releasePresentation()
        else
            self:_resumeAfterCinematic()
        end
    end))
    if CinematicUiGate:IsBlocked() then
        self:_releasePresentation()
    end

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
