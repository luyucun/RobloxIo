--[[
脚本名字: FlashController
脚本文件: FlashController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/FlashController
说明: 绑定 Flash HUD、键盘 Q 与手柄 X，并仅将使用意图发给服务端。
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local function requireSharedModule(moduleName)
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    local moduleScript = sharedFolder and sharedFolder:FindFirstChild(moduleName)
    if moduleScript and moduleScript:IsA("ModuleScript") then
        return require(moduleScript)
    end
    error(string.format("[FlashController] Missing shared module %s", tostring(moduleName or "")))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local FlashController = {}

FlashController._localPlayer = nil
FlashController._modalUiController = nil
FlashController._autoBattleController = nil
FlashController._connections = {}
FlashController._uiConnections = {}
FlashController._requestFlashEvent = nil
FlashController._flashFeedbackEvent = nil
FlashController._flashCompletedEvent = nil
FlashController._playerStateSyncEvent = nil
FlashController._mainGui = nil
FlashController._info = nil
FlashController._button = nil
FlashController._mask = nil
FlashController._icon = nil
FlashController._icon02 = nil
FlashController._hintLabel = nil
FlashController._cooldownTween = nil
FlashController._cooldownEndsAt = 0
FlashController._flashRenderConnection = nil
FlashController._activeFlashRequestId = ""
FlashController._latestState = nil
FlashController._requestPending = false
FlashController._initialized = false

local ACTION_NAME = "IOFlash"
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 1
local DISABLED_ICON_COLOR = Color3.fromRGB(142, 142, 142)
local ENABLED_ICON_COLOR = Color3.fromRGB(255, 255, 255)

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    return playerGui and (playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)) or nil
end

local function getFlashConfig()
    local config = GameConfig.FLASH or {}
    return {
        Enabled = config.Enabled == true,
        CooldownSeconds = math.max(0, tonumber(config.CooldownSeconds) or 0),
        DurationSeconds = math.max(0, tonumber(config.DurationSeconds) or 0),
        MinimumMoveDirectionMagnitude = math.max(0, tonumber(config.MinimumMoveDirectionMagnitude) or 0.05),
    }
end

function FlashController:_isActiveInArena()
    return self._latestState and self._latestState.alive == true and self._latestState.isInArena == true
end

function FlashController:_isModalOpen()
    return self._modalUiController and self._modalUiController.IsAnyOpen and self._modalUiController:IsAnyOpen() == true
end

function FlashController:_isMoving()
    local character = self._localPlayer and self._localPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local config = getFlashConfig()
    return humanoid and humanoid.Health > 0 and humanoid.MoveDirection.Magnitude >= config.MinimumMoveDirectionMagnitude
end

function FlashController:_isCoolingDown()
    return os.clock() < self._cooldownEndsAt
end

function FlashController:_canRequestFlash()
    local config = getFlashConfig()
    return config.Enabled
        and self:_isActiveInArena()
        and not self:_isModalOpen()
        and not UserInputService:GetFocusedTextBox()
        and not self:_isCoolingDown()
        and self:_isMoving()
end

function FlashController:_updateVisualState()
    local isActiveInArena = self:_isActiveInArena()
    local enabled = isActiveInArena and not self:_isCoolingDown()
    if self._info and self._info:IsA("GuiObject") then
        self._info.Visible = isActiveInArena
    end
    if self._icon and self._icon:IsA("ImageLabel") then
        self._icon.ImageColor3 = enabled and ENABLED_ICON_COLOR or DISABLED_ICON_COLOR
    end
    if self._icon02 and self._icon02:IsA("ImageLabel") then
        self._icon02.ImageColor3 = enabled and ENABLED_ICON_COLOR or DISABLED_ICON_COLOR
    end
    if self._hintLabel and self._hintLabel:IsA("TextLabel") then
        self._hintLabel.Visible = not UserInputService.TouchEnabled
        self._hintLabel.TextTransparency = enabled and 0 or 0.45
    end
end

function FlashController:_cancelCooldownTween()
    if self._cooldownTween then
        self._cooldownTween:Cancel()
        self._cooldownTween = nil
    end
end

function FlashController:_cancelPredictedFlash()
    if self._flashRenderConnection then
        self._flashRenderConnection:Disconnect()
        self._flashRenderConnection = nil
    end
end

function FlashController:_playPredictedFlash(targetPosition, durationSeconds, requestId)
    if typeof(targetPosition) ~= "Vector3" then
        return
    end

    local character = self._localPlayer and self._localPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not (character and rootPart) then
        return
    end

    self:_cancelPredictedFlash()
    local startPosition = rootPart.Position
    local lookVector = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
    if lookVector.Magnitude <= 1e-4 then
        lookVector = Vector3.new(targetPosition.X - startPosition.X, 0, targetPosition.Z - startPosition.Z)
    end
    if lookVector.Magnitude <= 1e-4 then
        return
    end
    lookVector = lookVector.Unit

    local duration = math.max(0.01, tonumber(durationSeconds) or 0.3)
    local startedAt = os.clock()
    self._flashRenderConnection = RunService.RenderStepped:Connect(function()
        if not (character.Parent and rootPart.Parent) then
            self:_cancelPredictedFlash()
            return
        end

        local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
        local easedAlpha = 1 - ((1 - alpha) * (1 - alpha))
        local position = startPosition:Lerp(targetPosition, easedAlpha)
        character:PivotTo(CFrame.lookAt(position, position + lookVector))
        rootPart.AssemblyLinearVelocity = Vector3.zero
        rootPart.AssemblyAngularVelocity = Vector3.zero
        if alpha >= 1 then
            self:_cancelPredictedFlash()
            if self._flashCompletedEvent and self._activeFlashRequestId == requestId then
                self._flashCompletedEvent:FireServer({ requestId = requestId })
            end
        end
    end)
end

function FlashController:_startCooldown(seconds)
    local duration = math.max(0, tonumber(seconds) or 0)
    self._cooldownEndsAt = os.clock() + duration
    self._requestPending = false
    self:_cancelCooldownTween()

    local mask = self._mask
    if mask and mask:IsA("Frame") then
        mask.Visible = duration > 0
        mask.AnchorPoint = Vector2.new(0, 0)
        mask.Position = UDim2.fromScale(0, 0)
        mask.Size = UDim2.fromScale(1, 1)
        if duration > 0 then
            local tween = TweenService:Create(mask, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
                Size = UDim2.fromScale(1, 0),
            })
            self._cooldownTween = tween
            tween.Completed:Connect(function(playbackState)
                if self._cooldownTween ~= tween then
                    return
                end
                self._cooldownTween = nil
                if playbackState == Enum.PlaybackState.Completed and mask.Parent then
                    mask.Visible = false
                    self._cooldownEndsAt = 0
                    self:_updateVisualState()
                end
            end)
            tween:Play()
        else
            mask.Visible = false
        end
    end
    self:_updateVisualState()
end

function FlashController:_bindUi()
    disconnectAll(self._uiConnections)
    self._mainGui = getMainGui(self._localPlayer)
    local flash = self._mainGui and self._mainGui:FindFirstChild("Flash")
    local info = flash and flash:FindFirstChild("Info")
    local button = info and info:FindFirstChild("TextButton")
    if not (button and button:IsA("GuiButton")) then
        return false
    end

    self._info = info
    self._button = button
    self._mask = info:FindFirstChild("CooldownMask")
    self._icon = info:FindFirstChild("Icon")
    self._icon02 = info:FindFirstChild("Icon02")
    self._hintLabel = info:FindFirstChild("TextLabel")
    if self._hintLabel and self._hintLabel:IsA("TextLabel") then
        self._hintLabel.Text = "[Q / X]"
    end
    if self._mask and self._mask:IsA("Frame") then
        self._mask.Active = false
        self._mask.Selectable = false
    else
        warn("[FlashController] Missing StarterGui.Main.Flash.Info.CooldownMask")
    end

    table.insert(self._uiConnections, button.Activated:Connect(function()
        self:_requestFlash()
    end))
    self:_updateVisualState()
    return true
end

function FlashController:_requestFlash()
    if not self:_canRequestFlash() or self._requestPending or not self._requestFlashEvent then
        return false
    end

    self._requestPending = true
    if self._autoBattleController and self._autoBattleController.SuspendForFlash then
        local config = getFlashConfig()
        self._autoBattleController:SuspendForFlash(config.DurationSeconds + 0.05)
    end
    self._requestFlashEvent:FireServer()
    task.delay(0.75, function()
        if self._requestPending then
            self._requestPending = false
        end
    end)
    return true
end

function FlashController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    local eventType = tostring(payload.eventType or "")
    if eventType == "Started" then
        self:_startCooldown(payload.cooldownSeconds)
        self._activeFlashRequestId = tostring(payload.requestId or "")
        self:_playPredictedFlash(payload.targetPosition, payload.durationSeconds, self._activeFlashRequestId)
    elseif eventType == "Rejected" or eventType == "Interrupted" then
        self:_cancelPredictedFlash()
        self._activeFlashRequestId = ""
        self._requestPending = false
    elseif eventType == "Completed" then
        self._activeFlashRequestId = ""
        self._requestPending = false
        self:_updateVisualState()
        return
    end

    if eventType == "Rejected" or eventType == "Interrupted" then
        local remaining = math.max(0, tonumber(payload.cooldownRemainingSeconds) or 0)
        if remaining > 0 and not self:_isCoolingDown() then
            self:_startCooldown(remaining)
        else
            self:_updateVisualState()
        end
    end
end

function FlashController:_bindRemotes()
    local eventsRoot = ReplicatedStorage:FindFirstChild(RemoteNames.RootFolder) or ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    local systemEvents = eventsRoot and (eventsRoot:FindFirstChild(RemoteNames.SystemEventsFolder) or eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10))
    if not systemEvents then
        return false
    end

    self._requestFlashEvent = systemEvents:FindFirstChild(RemoteNames.System.RequestFlash) or systemEvents:WaitForChild(RemoteNames.System.RequestFlash, 10)
    self._flashFeedbackEvent = systemEvents:FindFirstChild(RemoteNames.System.FlashFeedback) or systemEvents:WaitForChild(RemoteNames.System.FlashFeedback, 10)
    self._flashCompletedEvent = systemEvents:FindFirstChild(RemoteNames.System.FlashCompleted) or systemEvents:WaitForChild(RemoteNames.System.FlashCompleted, 10)
    self._playerStateSyncEvent = systemEvents:FindFirstChild(RemoteNames.System.PlayerStateSync) or systemEvents:WaitForChild(RemoteNames.System.PlayerStateSync, 10)
    if not (self._requestFlashEvent and self._flashFeedbackEvent and self._flashCompletedEvent and self._playerStateSyncEvent) then
        return false
    end

    table.insert(self._connections, self._flashFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleFeedback(payload)
    end))
    table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        if type(payload) == "table" then
            self._latestState = payload
            self:_updateVisualState()
        end
    end))
    return true
end

function FlashController:_handleAction(_, inputState)
    if inputState ~= Enum.UserInputState.Begin then
        return Enum.ContextActionResult.Pass
    end
    if not (self:_isActiveInArena() and not self:_isModalOpen() and not UserInputService:GetFocusedTextBox()) then
        return Enum.ContextActionResult.Pass
    end

    self:_requestFlash()
    return Enum.ContextActionResult.Sink
end

function FlashController:Init(dependencies)
    if self._initialized then
        return
    end
    self._initialized = true
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._modalUiController = dependencies and dependencies.ModalUiController or nil
    self._autoBattleController = dependencies and dependencies.AutoBattleController or nil
    self._latestState = nil
    self._cooldownEndsAt = 0
    self._requestPending = false
    self._activeFlashRequestId = ""
    self:_cancelPredictedFlash()

    disconnectAll(self._connections)
    if not self:_bindRemotes() then
        warn("[FlashController] Flash remotes are unavailable.")
        return
    end

    ContextActionService:UnbindAction(ACTION_NAME)
    ContextActionService:BindActionAtPriority(
        ACTION_NAME,
        function(...)
            return self:_handleAction(...)
        end,
        false,
        ACTION_PRIORITY,
        Enum.KeyCode.Q,
        Enum.KeyCode.ButtonX
    )

    if not self:_bindUi() then
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

    local eventsRoot = ReplicatedStorage:FindFirstChild(RemoteNames.RootFolder)
    local systemEvents = eventsRoot and eventsRoot:FindFirstChild(RemoteNames.SystemEventsFolder)
    local requestStateSync = systemEvents and systemEvents:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSync and requestStateSync:IsA("RemoteEvent") then
        requestStateSync:FireServer()
    end
end

return FlashController
