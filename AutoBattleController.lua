--[[
Script: AutoBattleController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AutoBattleController
Purpose: Client-side auto battle movement for client-owned normal monsters.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

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
        "[AutoBattleController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")
local ModalUiController = nil

local AutoBattleController = {}

AutoBattleController._localPlayer = nil
AutoBattleController._weaponFxController = nil
AutoBattleController._localMonsterController = nil
AutoBattleController._connections = {}
AutoBattleController._uiConnections = {}
AutoBattleController._renderConnection = nil
AutoBattleController._mainGui = nil
AutoBattleController._bottomRoot = nil
AutoBattleController._autoButton = nil
AutoBattleController._latestState = nil
AutoBattleController._isAutoEnabled = false
AutoBattleController._isAutoJoining = false
AutoBattleController._resumeAutoAfterJoin = false
AutoBattleController._isAutoMoving = false
AutoBattleController._flashSuspendEndsAt = 0
AutoBattleController._bindRetryQueued = false
AutoBattleController._portalJoinPromptEvent = nil
AutoBattleController._requestJoinBattleEvent = nil
AutoBattleController._playerControls = nil
AutoBattleController._lastAutoJoinRequestClock = 0
AutoBattleController._lastMoveToClock = 0
AutoBattleController._lastMoveToPosition = nil
AutoBattleController._autoTargetId = nil
AutoBattleController._nextAutoTargetRefreshClock = 0
AutoBattleController._lastAutoTargetSwitchClock = 0
AutoBattleController._excludedAutoTargetUntilById = {}
AutoBattleController._autoPath = nil
AutoBattleController._autoPathWaypoints = nil
AutoBattleController._autoPathWaypointIndex = 0
AutoBattleController._autoPathTargetId = nil
AutoBattleController._autoPathDestination = nil
AutoBattleController._autoPathBlocked = false
AutoBattleController._autoPathBlockedConnection = nil
AutoBattleController._nextAutoPathComputeClock = 0
AutoBattleController._autoPathRecomputeAttempts = 0
AutoBattleController._lastProgressCheckClock = 0
AutoBattleController._lastProgressCheckPosition = nil
AutoBattleController._lastProgressCheckDistance = nil
AutoBattleController._lastProgressCheckTargetId = nil
AutoBattleController._autoButtonUiScale = nil
AutoBattleController._autoButtonTween = nil
AutoBattleController._autoBannerPhase = 0
AutoBattleController._autoBannerBaseColor = nil
AutoBattleController._autoBannerBaseGradient = nil
AutoBattleController._isAutoButtonHovered = false
AutoBattleController._isAutoButtonPressed = false
AutoBattleController._wantsAutoBattle = false

local MOVE_TO_REFRESH_SECONDS = 0.18
local MOVE_TO_POSITION_EPSILON = 1.5
local AUTO_TARGET_REFRESH_SECONDS = 0.25
local AUTO_TARGET_SWITCH_COOLDOWN_SECONDS = 0.18
local AUTO_STUCK_CHECK_INTERVAL_SECONDS = 0.8
local AUTO_STUCK_MIN_MOVE_DISTANCE = 1.2
local AUTO_STUCK_MIN_DISTANCE_PROGRESS = 0.75
local AUTO_BLOCKED_TARGET_COOLDOWN_SECONDS = 2.5
local AUTO_PATH_RECOMPUTE_SECONDS = 0.75
local AUTO_PATH_MAX_RECOMPUTE_ATTEMPTS = 2
local AUTO_PATH_TARGET_RECOMPUTE_DISTANCE = 8
local AUTO_PATH_WAYPOINT_REACHED_DISTANCE = 3
local AUTO_PATH_WAYPOINT_SPACING = 5
local AUTO_PATH_AGENT_RADIUS = 3
local AUTO_PATH_AGENT_HEIGHT = 6
local AUTO_JOIN_ATTRIBUTE = "AutoJoinPortalActive"
local AUTO_JOIN_TARGET_ID = "__Portal"
local AUTO_JOIN_REQUEST_INTERVAL_SECONDS = 0.35
local MANUAL_MOVE_VECTOR_EPSILON = 0.05
local AUTO_JOIN_PORTAL_BOUNDS_PADDING = 1.5
local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.92
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local AUTO_BANNER_SCROLL_SPEED = 0.45

local MANUAL_MOVEMENT_KEY_CODES = {
    [Enum.KeyCode.W] = true,
    [Enum.KeyCode.A] = true,
    [Enum.KeyCode.S] = true,
    [Enum.KeyCode.D] = true,
    [Enum.KeyCode.Up] = true,
    [Enum.KeyCode.Down] = true,
    [Enum.KeyCode.Left] = true,
    [Enum.KeyCode.Right] = true,
    [Enum.KeyCode.Space] = true,
    [Enum.KeyCode.ButtonA] = true,
    [Enum.KeyCode.DPadUp] = true,
    [Enum.KeyCode.DPadDown] = true,
    [Enum.KeyCode.DPadLeft] = true,
    [Enum.KeyCode.DPadRight] = true,
    [Enum.KeyCode.Thumbstick1] = true,
}

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

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function setEnabled(instance, enabled)
    if not instance then
        return
    end

    pcall(function()
        instance.Enabled = enabled == true
    end)
end

local function wrapUnit(value)
    local wrapped = (tonumber(value) or 0) % 1
    if wrapped < 0 then
        wrapped += 1
    end
    return wrapped
end

local function lerpColor(colorA, colorB, alpha)
    return Color3.new(
        colorA.R + ((colorB.R - colorA.R) * alpha),
        colorA.G + ((colorB.G - colorA.G) * alpha),
        colorA.B + ((colorB.B - colorA.B) * alpha)
    )
end

local function sampleColorSequence(colorSequence, time)
    local keypoints = colorSequence and colorSequence.Keypoints
    if not keypoints or #keypoints == 0 then
        return Color3.new(1, 1, 1)
    end

    local clampedTime = math.clamp(tonumber(time) or 0, 0, 1)
    if clampedTime <= keypoints[1].Time then
        return keypoints[1].Value
    end

    for index = 2, #keypoints do
        local currentKeypoint = keypoints[index]
        if clampedTime <= currentKeypoint.Time then
            local previousKeypoint = keypoints[index - 1]
            local span = currentKeypoint.Time - previousKeypoint.Time
            local alpha = span > 0 and ((clampedTime - previousKeypoint.Time) / span) or 0
            return lerpColor(previousKeypoint.Value, currentKeypoint.Value, alpha)
        end
    end

    return keypoints[#keypoints].Value
end

local function buildShiftedColorSequence(colorSequence, phase)
    local shiftedPhase = wrapUnit(phase)
    local times = { 0, 1 }
    local sourceKeypoints = colorSequence and colorSequence.Keypoints or {}
    for _, keypoint in ipairs(sourceKeypoints) do
        local shiftedTime = wrapUnit(keypoint.Time + shiftedPhase)
        if shiftedTime > 0 and shiftedTime < 1 then
            table.insert(times, shiftedTime)
        end
    end

    table.sort(times)

    local shiftedKeypoints = {}
    local previousTime = nil
    for _, time in ipairs(times) do
        if previousTime == nil or math.abs(time - previousTime) > 0.0001 then
            table.insert(shiftedKeypoints, ColorSequenceKeypoint.new(
                time,
                sampleColorSequence(colorSequence, wrapUnit(time - shiftedPhase))
            ))
            previousTime = time
        end
    end

    if #shiftedKeypoints < 2 then
        return colorSequence
    end
    return ColorSequence.new(shiftedKeypoints)
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

local function getModalUiController()
    if ModalUiController ~= nil then
        return ModalUiController
    end

    local parent = script.Parent
    local moduleScript = parent and parent:FindFirstChild("ModalUiController")
    if not (moduleScript and moduleScript:IsA("ModuleScript")) then
        return nil
    end

    local ok, controller = pcall(require, moduleScript)
    if ok then
        ModalUiController = controller
        return ModalUiController
    end

    warn(string.format("[AutoBattleController] ModalUiController load failed: %s", tostring(controller)))
    return nil
end

local function getCharacterController(localPlayer)
    local character = localPlayer and localPlayer.Character
    if not character then
        return nil, nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    if not (humanoid and rootPart and rootPart:IsA("BasePart")) then
        return nil, nil
    end
    return humanoid, rootPart
end

local function getPartCollisionReach(basePart)
    if not (basePart and basePart:IsA("BasePart")) then
        return 0
    end

    local size = basePart.Size
    return math.max(size.X, size.Y, size.Z) * 0.5
end

local function getPlanarDistance(positionA, positionB)
    if not (typeof(positionA) == "Vector3" and typeof(positionB) == "Vector3") then
        return math.huge
    end

    local deltaX = positionA.X - positionB.X
    local deltaZ = positionA.Z - positionB.Z
    return math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))
end

local function getPlanarUnitVector(positionA, positionB)
    if not (typeof(positionA) == "Vector3" and typeof(positionB) == "Vector3") then
        return nil, nil
    end

    local deltaX = positionB.X - positionA.X
    local deltaZ = positionB.Z - positionA.Z
    local magnitude = math.sqrt((deltaX * deltaX) + (deltaZ * deltaZ))
    if magnitude <= 1e-6 then
        return nil, nil
    end

    return deltaX / magnitude, deltaZ / magnitude
end

local function getActiveExcludedIds(excludedUntilById, now)
    local excludedIds = nil
    for targetId, excludedUntil in pairs(excludedUntilById) do
        if now < excludedUntil then
            excludedIds = excludedIds or {}
            excludedIds[targetId] = true
        else
            excludedUntilById[targetId] = nil
        end
    end
    return excludedIds
end

local function isManualMovementInput(inputObject)
    if not inputObject then
        return false
    end

    local inputType = inputObject.UserInputType
    if inputType == Enum.UserInputType.Keyboard then
        return MANUAL_MOVEMENT_KEY_CODES[inputObject.KeyCode] == true
    end

    if inputType == Enum.UserInputType.Gamepad1
        or inputType == Enum.UserInputType.Gamepad2
        or inputType == Enum.UserInputType.Gamepad3
        or inputType == Enum.UserInputType.Gamepad4
        or inputType == Enum.UserInputType.Gamepad5
        or inputType == Enum.UserInputType.Gamepad6
        or inputType == Enum.UserInputType.Gamepad7
        or inputType == Enum.UserInputType.Gamepad8
    then
        return MANUAL_MOVEMENT_KEY_CODES[inputObject.KeyCode] == true
    end

    return false
end

local function resolvePortalJoinTarget()
    local arenaConfig = GameConfig.ARENA or {}
    local map = Workspace:FindFirstChild(arenaConfig.MapFolderName or "Map2")
    local portals = map and map:FindFirstChild(arenaConfig.PortalsFolderName or "Portals")
    local portal = portals and portals:FindFirstChild(arenaConfig.PortalModelName or "Portal")
    if not portal then
        return nil, nil
    end

    local triggerPart = portal:FindFirstChild("PORTAL", true)
    if triggerPart and triggerPart:IsA("BasePart") then
        return triggerPart.Position, portal
    end

    if portal:IsA("Model") then
        local ok, boundsCFrame = pcall(function()
            return portal:GetBoundingBox()
        end)
        if ok and boundsCFrame then
            return boundsCFrame.Position, portal
        end
    elseif portal:IsA("BasePart") then
        return portal.Position, portal
    end

    return nil, portal
end

local function resolvePortalJoinTargetPosition()
    local position = resolvePortalJoinTarget()
    return position
end

local function isPositionInsidePortalBounds(position, portal)
    if not (typeof(position) == "Vector3" and portal) then
        return false
    end

    local ok, boundsCFrame, boundsSize = pcall(function()
        if portal:IsA("Model") then
            return portal:GetBoundingBox()
        elseif portal:IsA("BasePart") then
            return portal.CFrame, portal.Size
        end
        return nil, nil
    end)
    if not (ok and boundsCFrame and boundsSize) then
        return false
    end

    local localPosition = boundsCFrame:PointToObjectSpace(position)
    local halfSize = boundsSize * 0.5
    local padding = AUTO_JOIN_PORTAL_BOUNDS_PADDING

    return math.abs(localPosition.X) <= halfSize.X + padding
        and math.abs(localPosition.Y) <= halfSize.Y + padding
        and math.abs(localPosition.Z) <= halfSize.Z + padding
end

function AutoBattleController:_isInArena()
    return self._latestState and self._latestState.isInArena == true
end

function AutoBattleController:_isActiveInArena()
    return self._latestState and self._latestState.isInArena == true and self._latestState.alive == true
end

function AutoBattleController:_updateBottomVisibility()
    if self._bottomRoot and self._bottomRoot:IsA("GuiObject") then
        local isActiveInArena = self:_isActiveInArena() == true
        local shouldShowAuto = isActiveInArena or not self:_isInArena()
        local shouldShow = shouldShowAuto

        for _, child in ipairs(self._bottomRoot:GetChildren()) do
            if child:IsA("GuiObject") then
                child.Visible = child == self._autoButton and shouldShowAuto or isActiveInArena
            end
        end

        local modalUiController = getModalUiController()
        if modalUiController and modalUiController:IsAnyOpen() then
            modalUiController:SetRestoredVisible(self._bottomRoot, shouldShow)
            self._bottomRoot.Visible = false
            return
        end
        self._bottomRoot.Visible = shouldShow
    end
end

function AutoBattleController:_updateAutoButtonUi()
    if not self._autoButton then
        return
    end

    local isAutoActive = self._isAutoEnabled == true or self._isAutoJoining == true
    setText(self._autoButton:FindFirstChild("Name", true), isAutoActive and "Stop" or "Auto")
    local label = self._autoButton:FindFirstChild("Label", true)
    if label and label:IsA("GuiObject") then
        label.Visible = isAutoActive ~= true
    end

    local bg = self._autoButton:FindFirstChild("Bg", true)
    local bannerOn = bg and bg:FindFirstChild("BannerOn", true)
    local bannerOff = bg and bg:FindFirstChild("BannerOff", true)
    setEnabled(bannerOn, isAutoActive == true)
    setEnabled(bannerOff, isAutoActive ~= true)

    if bannerOn and bannerOn:IsA("UIGradient") and self._autoBannerBaseGradient ~= bannerOn then
        self._autoBannerBaseGradient = bannerOn
        self._autoBannerBaseColor = bannerOn.Color
    end

    if bannerOn and bannerOn:IsA("UIGradient") and isAutoActive ~= true then
        self._autoBannerPhase = 0
        if self._autoBannerBaseColor then
            bannerOn.Color = self._autoBannerBaseColor
        end
        bannerOn.Offset = Vector2.new(0, 0)
    end
end

function AutoBattleController:_stepAutoButtonBanner(deltaTime)
    if not (self._isAutoEnabled == true or self._isAutoJoining == true) or not self._autoButton then
        return
    end

    local bg = self._autoButton:FindFirstChild("Bg", true)
    local bannerOn = bg and bg:FindFirstChild("BannerOn", true)
    if not (bannerOn and bannerOn:IsA("UIGradient") and bannerOn.Enabled == true) then
        return
    end

    if self._autoBannerBaseGradient ~= bannerOn then
        self._autoBannerBaseGradient = bannerOn
        self._autoBannerBaseColor = bannerOn.Color
        self._autoBannerPhase = 0
    end

    if not self._autoBannerBaseColor then
        self._autoBannerBaseColor = bannerOn.Color
    end

    self._autoBannerPhase = wrapUnit((self._autoBannerPhase or 0) + ((tonumber(deltaTime) or 0) * AUTO_BANNER_SCROLL_SPEED))
    bannerOn.Offset = Vector2.new(0, 0)
    bannerOn.Color = buildShiftedColorSequence(self._autoBannerBaseColor, self._autoBannerPhase)
end

function AutoBattleController:_cancelAutoButtonTween()
    if self._autoButtonTween then
        self._autoButtonTween:Cancel()
        self._autoButtonTween = nil
    end
end

function AutoBattleController:_applyAutoButtonInteractionState()
    local uiScale = self._autoButtonUiScale or ensureUiScale(self._autoButton)
    if not uiScale then
        return
    end
    self._autoButtonUiScale = uiScale

    local scale = 1
    local tweenInfo = RESET_TWEEN_INFO
    if self._isAutoButtonPressed then
        scale = PRESS_SCALE
        tweenInfo = PRESS_TWEEN_INFO
    elseif self._isAutoButtonHovered then
        scale = HOVER_SCALE
        tweenInfo = HOVER_TWEEN_INFO
    end

    self:_cancelAutoButtonTween()
    local tween = TweenService:Create(uiScale, tweenInfo, {
        Scale = scale,
    })
    self._autoButtonTween = tween
    tween.Completed:Connect(function()
        if self._autoButtonTween == tween then
            self._autoButtonTween = nil
        end
    end)
    tween:Play()
end

function AutoBattleController:_resetAutoButtonInteractionState()
    self._isAutoButtonHovered = false
    self._isAutoButtonPressed = false
    self:_cancelAutoButtonTween()
    if self._autoButtonUiScale and self._autoButtonUiScale.Parent then
        self._autoButtonUiScale.Scale = 1
    end
    self._autoButtonUiScale = nil
end

function AutoBattleController:_resetAutoTargetState()
    self._autoTargetId = nil
    self._nextAutoTargetRefreshClock = 0
    self._lastAutoTargetSwitchClock = 0
    self._autoPathRecomputeAttempts = 0
    table.clear(self._excludedAutoTargetUntilById)
    self:_resetAutoPathState()
    self:_resetProgressCheckState()
end

function AutoBattleController:_clearAutoTargetSelection()
    self._autoTargetId = nil
    self._nextAutoTargetRefreshClock = 0
    self._autoPathRecomputeAttempts = 0
    self:_resetAutoPathState()
    self:_resetProgressCheckState()
end

function AutoBattleController:_setAutoTargetId(targetId, now)
    if self._autoTargetId == targetId then
        return
    end

    self._autoTargetId = targetId
    self._lastAutoTargetSwitchClock = now or os.clock()
    self._nextAutoTargetRefreshClock = (now or os.clock()) + AUTO_TARGET_REFRESH_SECONDS
    self._autoPathRecomputeAttempts = 0
    self:_resetAutoPathState()
    self:_resetProgressCheckState()
end

function AutoBattleController:_resetProgressCheckState()
    self._lastProgressCheckClock = 0
    self._lastProgressCheckPosition = nil
    self._lastProgressCheckDistance = nil
    self._lastProgressCheckTargetId = nil
end

function AutoBattleController:_disconnectAutoPathBlocked()
    if self._autoPathBlockedConnection then
        self._autoPathBlockedConnection:Disconnect()
        self._autoPathBlockedConnection = nil
    end
end

function AutoBattleController:_resetAutoPathState()
    self:_disconnectAutoPathBlocked()
    self._autoPath = nil
    self._autoPathWaypoints = nil
    self._autoPathWaypointIndex = 0
    self._autoPathTargetId = nil
    self._autoPathDestination = nil
    self._autoPathBlocked = false
    self._nextAutoPathComputeClock = 0
end

function AutoBattleController:_clearAutoPathForRetry()
    self:_disconnectAutoPathBlocked()
    self._autoPath = nil
    self._autoPathWaypoints = nil
    self._autoPathWaypointIndex = 0
    self._autoPathTargetId = nil
    self._autoPathDestination = nil
    self._autoPathBlocked = false
    self._nextAutoPathComputeClock = 0
    self._lastMoveToClock = 0
    self._lastMoveToPosition = nil
end

function AutoBattleController:_excludeCurrentAutoTarget()
    if not self._autoTargetId then
        return
    end

    self._excludedAutoTargetUntilById[self._autoTargetId] = os.clock() + AUTO_BLOCKED_TARGET_COOLDOWN_SECONDS
    self._autoPathRecomputeAttempts = 0
    self:_clearAutoTargetSelection()
end

function AutoBattleController:_stopMovement()
    local humanoid, rootPart = getCharacterController(self._localPlayer)
    if self._isAutoMoving and humanoid and rootPart then
        humanoid:Move(Vector3.zero, false)
        humanoid:MoveTo(rootPart.Position)
    end
    self._isAutoMoving = false
    self._lastMoveToClock = 0
    self._lastMoveToPosition = nil
    self._autoPathRecomputeAttempts = 0
    self:_resetAutoPathState()
    self:_resetProgressCheckState()
end

function AutoBattleController:SuspendForFlash(durationSeconds)
    if not self._isAutoEnabled then
        return false
    end

    self:_stopMovement()
    local resumeAfterSeconds = math.max(0, tonumber(durationSeconds) or 0)
    self._flashSuspendEndsAt = math.max(self._flashSuspendEndsAt or 0, os.clock() + resumeAfterSeconds)
    task.delay(resumeAfterSeconds, function()
        if self._isAutoEnabled and self:_isActiveInArena() then
            self._lastMoveToClock = 0
            self._lastMoveToPosition = nil
        end
    end)
    return true
end

function AutoBattleController:_setAutoEnabled(enabled, options)
    local preserveWanted = type(options) == "table" and options.PreserveWanted == true
    local shouldEnable = enabled == true and self:_isActiveInArena() == true
    if shouldEnable then
        self._wantsAutoBattle = true
    elseif not preserveWanted then
        self._wantsAutoBattle = false
    end

    if self._isAutoEnabled == shouldEnable then
        self:_updateAutoButtonUi()
        return
    end

    if shouldEnable and self._isAutoJoining then
        self:_setAutoJoinEnabled(false)
    end

    self._isAutoEnabled = shouldEnable
    if shouldEnable then
        self._resumeAutoAfterJoin = false
    end
    if not self._isAutoEnabled then
        self:_stopMovement()
        self:_resetAutoTargetState()
    end
    self:_updateAutoButtonUi()
end

function AutoBattleController:_setAutoJoinAttribute(enabled)
    if self._localPlayer then
        self._localPlayer:SetAttribute(AUTO_JOIN_ATTRIBUTE, enabled == true)
    end
end

function AutoBattleController:_getPlayerControls()
    if self._playerControls then
        return self._playerControls
    end

    local playerScripts = self._localPlayer and self._localPlayer:FindFirstChild("PlayerScripts")
    local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
    if not playerModule then
        return nil
    end

    local ok, module = pcall(require, playerModule)
    if not (ok and module and module.GetControls) then
        return nil
    end

    local controlsOk, controls = pcall(function()
        return module:GetControls()
    end)
    if controlsOk then
        self._playerControls = controls
    end
    return self._playerControls
end

function AutoBattleController:_hasManualMoveVector()
    local controls = self:_getPlayerControls()
    if not (controls and controls.GetMoveVector) then
        return false
    end

    local ok, moveVector = pcall(function()
        return controls:GetMoveVector()
    end)
    return ok and typeof(moveVector) == "Vector3" and moveVector.Magnitude > MANUAL_MOVE_VECTOR_EPSILON
end

function AutoBattleController:_setAutoJoinEnabled(enabled, options)
    local preserveWanted = type(options) == "table" and options.PreserveWanted == true
    local shouldEnable = enabled == true and self:_isInArena() ~= true
    if shouldEnable then
        self._wantsAutoBattle = true
    elseif not preserveWanted then
        self._wantsAutoBattle = false
    end

    if self._isAutoJoining == shouldEnable then
        self:_updateBottomVisibility()
        self:_updateAutoButtonUi()
        return
    end

    self._isAutoJoining = shouldEnable
    self:_setAutoJoinAttribute(shouldEnable)
    self._lastAutoJoinRequestClock = 0

    if shouldEnable then
        self._isAutoEnabled = false
        self._resumeAutoAfterJoin = false
        self._lastMoveToClock = 0
        self._lastMoveToPosition = nil
        self:_resetAutoTargetState()
    else
        self:_stopMovement()
    end

    self:_updateBottomVisibility()
    self:_updateAutoButtonUi()
end

function AutoBattleController:_requestAutoJoinBattle(force)
    if not self._requestJoinBattleEvent then
        return
    end

    local now = os.clock()
    if force ~= true and now - (self._lastAutoJoinRequestClock or 0) < AUTO_JOIN_REQUEST_INTERVAL_SECONDS then
        return
    end

    self._lastAutoJoinRequestClock = now
    self._requestJoinBattleEvent:FireServer("Join")
end

function AutoBattleController:_handleAutoButtonActivated()
    if self._isAutoEnabled then
        self._resumeAutoAfterJoin = false
        self:_setAutoEnabled(false)
        return
    end

    if self._isAutoJoining then
        self._resumeAutoAfterJoin = false
        self:_setAutoJoinEnabled(false)
        return
    end

    if self:_isActiveInArena() then
        self._resumeAutoAfterJoin = false
        self:_setAutoEnabled(true)
    elseif not self:_isInArena() then
        self:_setAutoJoinEnabled(true)
    end
end

function AutoBattleController:_getWeaponReach(weaponState)
    if not (weaponState and weaponState.Instance and weaponState.Instance.Parent) then
        return nil
    end

    local orbitDistance = 6
    local auraReach = math.max(0, tonumber(weaponState.AuraRadius) or 0)
    local hitPartReach = getPartCollisionReach(weaponState.HitPart)
    local collisionReach = math.max(GameConfig.COMBAT.WeaponHitRadiusMin, auraReach, hitPartReach)
    return orbitDistance + collisionReach
end

function AutoBattleController:_calculateWeaponRange()
    if not self._weaponFxController then
        return nil
    end

    local weaponRange = 0
    for _, weaponState in ipairs(self._weaponFxController:GetLocalWeaponStates()) do
        local reach = self:_getWeaponReach(weaponState)
        if reach then
            weaponRange = math.max(weaponRange, reach)
        end
    end

    if weaponRange <= 0 then
        return nil
    end

    return weaponRange
end

function AutoBattleController:_calculateAttackRange(monsterSnapshot, weaponRange)
    local resolvedWeaponRange = tonumber(weaponRange) or self:_calculateWeaponRange()
    if not resolvedWeaponRange then
        return nil
    end

    local monsterRadius = math.max(0, tonumber(monsterSnapshot and monsterSnapshot.contactRadius) or GameConfig.MONSTER.ContactRadius)
    return resolvedWeaponRange + monsterRadius
end

function AutoBattleController:_getSafeReentryLockMinLevel()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(1, math.floor(tonumber(arenaConfig.SafeReentryLockMinLevel) or 31))
end

function AutoBattleController:_shouldExcludeSafeZoneAutoTargets(rootPosition)
    if not (typeof(rootPosition) == "Vector3" and self._localMonsterController) then
        return false
    end

    local level = math.floor(tonumber(self._latestState and self._latestState.level) or 0)
    if level < self:_getSafeReentryLockMinLevel() then
        return false
    end

    if not self._localMonsterController.IsPositionInsideSafeZone then
        return false
    end

    return self._localMonsterController:IsPositionInsideSafeZone(rootPosition) ~= true
end

function AutoBattleController:_getAutoTargetFilterOptions(rootPosition)
    if self:_shouldExcludeSafeZoneAutoTargets(rootPosition) then
        return {
            ExcludeSafeZone = true,
        }
    end
    return nil
end

function AutoBattleController:_findAutoTarget(rootPosition)
    if not self._localMonsterController then
        return nil, nil
    end

    local weaponRange = self:_calculateWeaponRange()
    if not weaponRange then
        return nil, nil
    end

    local now = os.clock()
    local excludedIds = getActiveExcludedIds(self._excludedAutoTargetUntilById, now)
    local targetFilterOptions = self:_getAutoTargetFilterOptions(rootPosition)
    local target = nil
    if self._autoTargetId and not (excludedIds and excludedIds[self._autoTargetId]) and self._localMonsterController.GetAliveMonsterSnapshotById then
        target = self._localMonsterController:GetAliveMonsterSnapshotById(self._autoTargetId, targetFilterOptions)
    end

    if not target then
        target = self._localMonsterController:FindNearestAliveMonster(rootPosition, nil, excludedIds, targetFilterOptions)
        if target then
            self:_setAutoTargetId(target.id, now)
        end
    end

    if not target then
        self:_clearAutoTargetSelection()
        return nil, nil
    end

    local attackRange = self:_calculateAttackRange(target, weaponRange)
    if not attackRange then
        return nil, nil
    end

    local distance = getPlanarDistance(rootPosition, target.position)
    local canRefreshTarget = now >= (self._nextAutoTargetRefreshClock or 0)
    local canSwitchTarget = now - (self._lastAutoTargetSwitchClock or 0) >= AUTO_TARGET_SWITCH_COOLDOWN_SECONDS
    if distance <= attackRange and canRefreshTarget and canSwitchTarget then
        local nextTarget = self._localMonsterController:FindNearestAliveMonsterOutsideWeaponRange(rootPosition, weaponRange, excludedIds, targetFilterOptions)
        if nextTarget and nextTarget.id ~= target.id then
            local nextAttackRange = self:_calculateAttackRange(nextTarget, weaponRange)
            if nextAttackRange then
                self:_setAutoTargetId(nextTarget.id, now)
                return nextTarget, nextAttackRange
            end
        end
    end

    if canRefreshTarget then
        self._nextAutoTargetRefreshClock = now + AUTO_TARGET_REFRESH_SECONDS
    end

    return target, attackRange
end

function AutoBattleController:_getAutoMovePosition(rootPosition, target, attackRange, distance)
    if not (typeof(rootPosition) == "Vector3" and target and typeof(target.position) == "Vector3") then
        return nil
    end

    if (tonumber(distance) or math.huge) > (tonumber(attackRange) or 0) then
        return Vector3.new(target.position.X, rootPosition.Y, target.position.Z)
    end

    local directionX, directionZ = getPlanarUnitVector(rootPosition, target.position)
    if not directionX then
        directionX, directionZ = 1, 0
    end

    local pushDistance = math.max(8, (tonumber(attackRange) or 0) + 4)
    return Vector3.new(
        rootPosition.X + (directionX * pushDistance),
        rootPosition.Y,
        rootPosition.Z + (directionZ * pushDistance)
    )
end

function AutoBattleController:_moveTo(humanoid, targetPosition)
    local now = os.clock()
    if self._lastMoveToPosition
        and now - self._lastMoveToClock < MOVE_TO_REFRESH_SECONDS
        and getPlanarDistance(self._lastMoveToPosition, targetPosition) < MOVE_TO_POSITION_EPSILON
    then
        return
    end

    humanoid:MoveTo(targetPosition)
    self._isAutoMoving = true
    self._lastMoveToClock = now
    self._lastMoveToPosition = targetPosition
end

function AutoBattleController:_computeAutoPathToDestination(rootPosition, destination, targetId, force)
    if not (typeof(rootPosition) == "Vector3" and typeof(destination) == "Vector3") then
        return false
    end

    local now = os.clock()
    if force ~= true and now < (self._nextAutoPathComputeClock or 0) then
        return self._autoPathWaypoints ~= nil
    end

    self:_resetAutoPathState()
    self._nextAutoPathComputeClock = now + AUTO_PATH_RECOMPUTE_SECONDS

    local path = PathfindingService:CreatePath({
        AgentRadius = AUTO_PATH_AGENT_RADIUS,
        AgentHeight = AUTO_PATH_AGENT_HEIGHT,
        AgentCanJump = true,
        WaypointSpacing = AUTO_PATH_WAYPOINT_SPACING,
    })

    local ok = pcall(function()
        path:ComputeAsync(rootPosition, destination)
    end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        return false
    end

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then
        return false
    end

    self._autoPath = path
    self._autoPathWaypoints = waypoints
    self._autoPathWaypointIndex = math.min(2, #waypoints)
    self._autoPathTargetId = targetId
    self._autoPathDestination = destination
    self._autoPathBlocked = false
    self._autoPathBlockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
        if blockedWaypointIndex >= self._autoPathWaypointIndex then
            self._autoPathBlocked = true
        end
    end)
    return true
end

function AutoBattleController:_followAutoPathToDestination(humanoid, rootPart, destination, targetId)
    if not (humanoid and rootPart and typeof(destination) == "Vector3") then
        return false
    end

    if self._autoPathTargetId ~= targetId
        or self._autoPathBlocked
        or not self._autoPathWaypoints
        or (self._autoPathDestination and getPlanarDistance(self._autoPathDestination, destination) > AUTO_PATH_TARGET_RECOMPUTE_DISTANCE)
    then
        if not self:_computeAutoPathToDestination(rootPart.Position, destination, targetId, true) then
            return false
        end
    end

    local waypoints = self._autoPathWaypoints
    local waypoint = waypoints and waypoints[self._autoPathWaypointIndex]
    if not waypoint then
        self:_resetAutoPathState()
        return false
    end

    while waypoint and getPlanarDistance(rootPart.Position, waypoint.Position) <= AUTO_PATH_WAYPOINT_REACHED_DISTANCE do
        self._autoPathWaypointIndex += 1
        waypoint = waypoints[self._autoPathWaypointIndex]
    end

    if not waypoint then
        self:_resetAutoPathState()
        return false
    end

    if waypoint.Action == Enum.PathWaypointAction.Jump then
        humanoid.Jump = true
    end

    self:_moveTo(humanoid, Vector3.new(waypoint.Position.X, rootPart.Position.Y, waypoint.Position.Z))
    return true
end

function AutoBattleController:_computeAutoPath(rootPosition, target, force)
    if not (typeof(rootPosition) == "Vector3" and target and typeof(target.position) == "Vector3") then
        return false
    end

    local now = os.clock()
    if force ~= true and now < (self._nextAutoPathComputeClock or 0) then
        return self._autoPathWaypoints ~= nil
    end
    self:_resetAutoPathState()
    self._nextAutoPathComputeClock = now + AUTO_PATH_RECOMPUTE_SECONDS
    local path = PathfindingService:CreatePath({
        AgentRadius = AUTO_PATH_AGENT_RADIUS,
        AgentHeight = AUTO_PATH_AGENT_HEIGHT,
        AgentCanJump = true,
        WaypointSpacing = AUTO_PATH_WAYPOINT_SPACING,
    })

    local ok = pcall(function()
        path:ComputeAsync(rootPosition, target.position)
    end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        return false
    end

    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then
        return false
    end

    self._autoPath = path
    self._autoPathWaypoints = waypoints
    self._autoPathWaypointIndex = math.min(2, #waypoints)
    self._autoPathTargetId = target.id
    self._autoPathDestination = target.position
    self._autoPathBlocked = false
    self._autoPathBlockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
        if blockedWaypointIndex >= self._autoPathWaypointIndex then
            self._autoPathBlocked = true
        end
    end)
    return true
end

function AutoBattleController:_followAutoPath(humanoid, rootPart, target)
    if not (humanoid and rootPart and target and typeof(target.position) == "Vector3") then
        return false
    end

    if self._autoPathTargetId ~= target.id
        or self._autoPathBlocked
        or not self._autoPathWaypoints
        or (self._autoPathDestination and getPlanarDistance(self._autoPathDestination, target.position) > AUTO_PATH_TARGET_RECOMPUTE_DISTANCE)
    then
        if not self:_computeAutoPath(rootPart.Position, target, true) then
            return false
        end
    end

    local waypoints = self._autoPathWaypoints
    local waypoint = waypoints and waypoints[self._autoPathWaypointIndex]
    if not waypoint then
        self:_resetAutoPathState()
        return false
    end

    while waypoint and getPlanarDistance(rootPart.Position, waypoint.Position) <= AUTO_PATH_WAYPOINT_REACHED_DISTANCE do
        self._autoPathWaypointIndex += 1
        waypoint = waypoints[self._autoPathWaypointIndex]
    end

    if not waypoint then
        self:_resetAutoPathState()
        return false
    end

    if waypoint.Action == Enum.PathWaypointAction.Jump then
        humanoid.Jump = true
    end

    self:_moveTo(humanoid, Vector3.new(waypoint.Position.X, rootPart.Position.Y, waypoint.Position.Z))
    return true
end

function AutoBattleController:_retryAutoPath(humanoid, rootPart, target)
    if not (humanoid and rootPart and target) then
        return false
    end

    self._autoPathRecomputeAttempts += 1
    self:_clearAutoPathForRetry()
    if self._autoPathRecomputeAttempts > AUTO_PATH_MAX_RECOMPUTE_ATTEMPTS then
        return false
    end

    return self:_computeAutoPath(rootPart.Position, target, true)
        and self:_followAutoPath(humanoid, rootPart, target)
end

function AutoBattleController:_isAutoMovementStuck(rootPosition, target, distance)
    if not (target and typeof(rootPosition) == "Vector3") then
        self:_resetProgressCheckState()
        return false
    end

    local now = os.clock()
    if self._lastProgressCheckTargetId ~= target.id then
        self._lastProgressCheckTargetId = target.id
        self._lastProgressCheckClock = now
        self._lastProgressCheckPosition = rootPosition
        self._lastProgressCheckDistance = distance
        return false
    end

    if now - (self._lastProgressCheckClock or 0) < AUTO_STUCK_CHECK_INTERVAL_SECONDS then
        return false
    end

    local previousPosition = self._lastProgressCheckPosition
    local previousDistance = self._lastProgressCheckDistance
    self._lastProgressCheckClock = now
    self._lastProgressCheckPosition = rootPosition
    self._lastProgressCheckDistance = distance

    if not previousPosition or not previousDistance then
        return false
    end

    local movedDistance = getPlanarDistance(previousPosition, rootPosition)
    local distanceProgress = previousDistance - distance
    return movedDistance < AUTO_STUCK_MIN_MOVE_DISTANCE and distanceProgress < AUTO_STUCK_MIN_DISTANCE_PROGRESS
end

function AutoBattleController:_stepAutoBattle()
    if not self._isAutoEnabled then
        return
    end
    if os.clock() < (self._flashSuspendEndsAt or 0) then
        return
    end
    if not self:_isActiveInArena() then
        self:_setAutoEnabled(false, {
            PreserveWanted = self._wantsAutoBattle == true,
        })
        return
    end

    local humanoid, rootPart = getCharacterController(self._localPlayer)
    if not (humanoid and rootPart) then
        self:_stopMovement()
        return
    end
    if humanoid.Health <= 0 then
        self:_setAutoEnabled(false, {
            PreserveWanted = self._wantsAutoBattle == true,
        })
        return
    end

    local target, attackRange = self:_findAutoTarget(rootPart.Position)
    if not (target and typeof(target.position) == "Vector3" and attackRange) then
        self:_stopMovement()
        return
    end

    local distance = getPlanarDistance(rootPart.Position, target.position)
    if self._autoPathWaypoints then
        if self:_isAutoMovementStuck(rootPart.Position, target, distance) then
            if self:_retryAutoPath(humanoid, rootPart, target) then
                return
            end
            self:_excludeCurrentAutoTarget()
            return
        end

        if self:_followAutoPath(humanoid, rootPart, target) then
            return
        end
        if self:_retryAutoPath(humanoid, rootPart, target) then
            return
        end
        self:_excludeCurrentAutoTarget()
        return
    end

    if self:_isAutoMovementStuck(rootPart.Position, target, distance) then
        self._autoPathRecomputeAttempts = 0
        if self:_retryAutoPath(humanoid, rootPart, target) then
            return
        end
        self:_excludeCurrentAutoTarget()
        return
    end

    local movePosition = self:_getAutoMovePosition(rootPart.Position, target, attackRange, distance)
    if not movePosition then
        self:_stopMovement()
        return
    end

    self:_moveTo(humanoid, movePosition)
    self._autoPathRecomputeAttempts = 0
end

function AutoBattleController:_stepAutoJoin()
    if not self._isAutoJoining then
        return
    end
    if self:_isInArena() then
        self._resumeAutoAfterJoin = true
        self:_setAutoJoinEnabled(false)
        self:_setAutoEnabled(true)
        return
    end
    if self:_hasManualMoveVector() then
        self:_setAutoJoinEnabled(false)
        return
    end

    local humanoid, rootPart = getCharacterController(self._localPlayer)
    if not (humanoid and rootPart) then
        self:_stopMovement()
        return
    end
    if humanoid.Health <= 0 then
        self:_setAutoJoinEnabled(false)
        return
    end

    local destination, portal = resolvePortalJoinTarget()
    if not destination then
        self:_stopMovement()
        return
    end

    if isPositionInsidePortalBounds(rootPart.Position, portal) then
        self:_requestAutoJoinBattle(false)
        self:_stopMovement()
        return
    end

    if self._autoPathWaypoints then
        if self:_followAutoPathToDestination(humanoid, rootPart, destination, AUTO_JOIN_TARGET_ID) then
            return
        end
        self:_clearAutoPathForRetry()
    end

    if self:_computeAutoPathToDestination(rootPart.Position, destination, AUTO_JOIN_TARGET_ID, false)
        and self:_followAutoPathToDestination(humanoid, rootPart, destination, AUTO_JOIN_TARGET_ID)
    then
        return
    end

    self:_moveTo(humanoid, Vector3.new(destination.X, rootPart.Position.Y, destination.Z))
end

function AutoBattleController:_queueBindRetry()
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
        warn("[AutoBattleController] Could not find PlayerGui/Main/Bottom/Auto; auto battle UI is unavailable.")
    end)
end

function AutoBattleController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._bottomRoot = mainGui and mainGui:FindFirstChild("Bottom") or nil
    self._autoButton = self._bottomRoot and self._bottomRoot:FindFirstChild("Auto", true) or nil

    if not (self._bottomRoot and self._bottomRoot:IsA("GuiObject") and self._autoButton and self._autoButton:IsA("GuiButton")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_resetAutoButtonInteractionState()
    disconnectAll(self._uiConnections)
    self._autoButtonUiScale = ensureUiScale(self._autoButton)

    table.insert(self._uiConnections, self._autoButton.MouseEnter:Connect(function()
        self._isAutoButtonHovered = true
        self:_applyAutoButtonInteractionState()
    end))

    table.insert(self._uiConnections, self._autoButton.MouseLeave:Connect(function()
        self._isAutoButtonHovered = false
        self._isAutoButtonPressed = false
        self:_applyAutoButtonInteractionState()
    end))

    table.insert(self._uiConnections, self._autoButton.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            self._isAutoButtonPressed = true
            if inputType == Enum.UserInputType.Touch then
                self._isAutoButtonHovered = true
            end
            self:_applyAutoButtonInteractionState()
        end
    end))

    table.insert(self._uiConnections, self._autoButton.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            self._isAutoButtonPressed = false
            if inputType == Enum.UserInputType.Touch then
                self._isAutoButtonHovered = false
            end
            self:_applyAutoButtonInteractionState()
        end
    end))

    table.insert(self._uiConnections, self._autoButton.Activated:Connect(function()
        self:_handleAutoButtonActivated()
    end))

    self:_updateBottomVisibility()
    self:_updateAutoButtonUi()
    return true
end

function AutoBattleController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._weaponFxController = dependencies and dependencies.WeaponFxController or nil
    self._localMonsterController = dependencies and dependencies.LocalMonsterController or nil
    self._latestState = nil
    self._isAutoEnabled = false
    self._isAutoJoining = false
    self._resumeAutoAfterJoin = false
    self._isAutoMoving = false
    self._wantsAutoBattle = false
    self._playerControls = nil
    self._lastAutoJoinRequestClock = 0
    self._lastMoveToClock = 0
    self._lastMoveToPosition = nil
    self:_resetAutoTargetState()
    self:_setAutoJoinAttribute(false)

    disconnectAll(self._connections)
    disconnectAll(self._uiConnections)
    self:_resetAutoButtonInteractionState()
    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    self._portalJoinPromptEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PortalJoinPrompt)
    self._requestJoinBattleEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestJoinBattle)
    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestState = payload
        self:_updateBottomVisibility()
        if self:_isInArena() and self._isAutoJoining then
            self._resumeAutoAfterJoin = true
            self:_setAutoJoinEnabled(false, {
                PreserveWanted = true,
            })
            self:_setAutoEnabled(true)
        elseif self._resumeAutoAfterJoin and self:_isActiveInArena() then
            self:_setAutoEnabled(true)
        elseif self:_isActiveInArena() then
            if self._wantsAutoBattle then
                self:_setAutoEnabled(true)
            end
        elseif not self:_isInArena() then
            self._resumeAutoAfterJoin = false
            self:_setAutoEnabled(false, {
                PreserveWanted = self._wantsAutoBattle == true,
            })
            if self._wantsAutoBattle then
                self:_setAutoJoinEnabled(true, {
                    PreserveWanted = true,
                })
            end
        elseif not self:_isActiveInArena() then
            self._resumeAutoAfterJoin = false
            self:_setAutoEnabled(false, {
                PreserveWanted = self._wantsAutoBattle == true,
            })
        end
    end))

    table.insert(self._connections, self._portalJoinPromptEvent.OnClientEvent:Connect(function(payload)
        local eventType = payload and tostring(payload.eventType or "") or ""
        if self._isAutoJoining and eventType == "Show" then
            self._lastAutoJoinRequestClock = 0
        elseif self._isAutoJoining and eventType == "Hide" and not self:_isInArena() then
            self._lastAutoJoinRequestClock = 0
        end
    end))

    table.insert(self._connections, UserInputService.InputBegan:Connect(function(inputObject, gameProcessed)
        if self._isAutoJoining and not gameProcessed and isManualMovementInput(inputObject) then
            self:_setAutoJoinEnabled(false)
        end
    end))

    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        requestStateSyncEvent:FireServer()
    end

    if not self:_bindUi(true) then
        self:_queueBindRetry()
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

    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        self:_stepAutoButtonBanner(deltaTime)
        self:_stepAutoJoin()
        self:_stepAutoBattle()
    end)
end

return AutoBattleController
