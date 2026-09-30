--[[
脚本名字: FlashService
脚本文件: FlashService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/FlashService
说明: 服务端权威的 Flash 突进；只接受使用意图，移动方向、距离、碰撞和冷却均由服务端判定。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local function requireSharedModule(moduleName)
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    local moduleScript = sharedFolder and sharedFolder:FindFirstChild(moduleName)
    if moduleScript and moduleScript:IsA("ModuleScript") then
        return require(moduleScript)
    end
    error(string.format("[FlashService] Missing shared module %s", tostring(moduleName or "")))
end

local GameConfig = requireSharedModule("GameConfig")
local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

local FlashService = {}

FlashService._playerStateService = nil
FlashService._arenaService = nil
FlashService._requestFlashEvent = nil
FlashService._flashFeedbackEvent = nil
FlashService._flashCompletedEvent = nil
FlashService._cooldownEndsByUserId = {}
FlashService._flashingByUserId = {}
FlashService._pendingFlashByUserId = {}
FlashService._playerRemovingConnection = nil

local MINIMUM_STEP_DISTANCE = 0.08

local function getPlanarVector(vector)
    if typeof(vector) ~= "Vector3" then
        return Vector3.zero
    end
    return Vector3.new(vector.X, 0, vector.Z)
end

local function getPlanarDistance(positionA, positionB)
    local delta = getPlanarVector(positionB - positionA)
    return delta.Magnitude
end

function FlashService:_getConfig(player)
    local config = GameConfig.FLASH or {}
    local cooldownSeconds = math.max(0, tonumber(config.CooldownSeconds) or 0)
    local distanceStuds = math.max(0, tonumber(config.DistanceStuds) or 0)
    if player and self._playerStateService then
        cooldownSeconds = self._playerStateService:GetFlashCooldownSeconds(player)
        distanceStuds = self._playerStateService:GetFlashDistanceStuds(player)
    end
    return {
        Enabled = config.Enabled == true,
        DistanceStuds = distanceStuds,
        DurationSeconds = math.max(0.01, tonumber(config.DurationSeconds) or 0.2),
        CooldownSeconds = cooldownSeconds,
        AnimationId = tostring(config.AnimationId or ""),
        MinimumMoveDirectionMagnitude = math.max(0, tonumber(config.MinimumMoveDirectionMagnitude) or 0.05),
        MinimumTravelDistance = math.max(0, tonumber(config.MinimumTravelDistance) or 1),
        CollisionPaddingStuds = math.max(0, tonumber(config.CollisionPaddingStuds) or 0.35),
    }
end

function FlashService:_fireFeedback(player, eventType, fields)
    if not (self._flashFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    local payload = {
        eventType = tostring(eventType or "Rejected"),
        timestamp = os.clock(),
    }
    for key, value in pairs(type(fields) == "table" and fields or {}) do
        payload[key] = value
    end
    self._flashFeedbackEvent:FireClient(player, payload)
end

function FlashService:_getBlockingRaycast(origin, direction, character)
    if direction.Magnitude <= 1e-4 then
        return nil
    end

    local excluded = { character }
    for _, player in ipairs(Players:GetPlayers()) do
        local playerCharacter = player.Character
        if playerCharacter and playerCharacter ~= character then
            table.insert(excluded, playerCharacter)
        end
    end
    local runtimeFolder = Workspace:FindFirstChild("Runtime")
    if runtimeFolder then
        table.insert(excluded, runtimeFolder)
    end

    for _ = 1, 12 do
        local parameters = RaycastParams.new()
        parameters.FilterType = Enum.RaycastFilterType.Exclude
        parameters.FilterDescendantsInstances = excluded
        parameters.IgnoreWater = true

        local hit = Workspace:Raycast(origin, direction, parameters)
        if not hit then
            return nil
        end

        local hitPart = hit.Instance
        if not hitPart:IsA("BasePart") or hitPart.CanCollide then
            return hit
        end
        table.insert(excluded, hitPart)
    end

    return nil
end

function FlashService:_playAnimation(humanoid, animationId, durationSeconds)
    if not (humanoid and animationId ~= "") then
        return
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = animationId
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    if not (ok and track) then
        animation:Destroy()
        return
    end

    track.Priority = Enum.AnimationPriority.Action
    track:Play(0.05, 1, 1)
    task.delay(math.max(0.45, durationSeconds + 0.25), function()
        pcall(function()
            track:Stop(0.08)
        end)
        animation:Destroy()
    end)
end

function FlashService:_getReachableTarget(startPosition, direction, character, config)
    local targetPosition = startPosition + (direction * config.DistanceStuds)
    targetPosition = self._arenaService:ClampPositionInsideBattle(targetPosition, config.CollisionPaddingStuds)
    if not targetPosition then
        return nil, 0
    end

    local targetDistance = getPlanarDistance(startPosition, targetPosition)
    if targetDistance <= MINIMUM_STEP_DISTANCE then
        return targetPosition, 0
    end

    local clampedDirection = getPlanarVector(targetPosition - startPosition).Unit
    local hit = self:_getBlockingRaycast(startPosition, clampedDirection * targetDistance, character)
    if hit then
        local safeDistance = math.max(0, hit.Distance - config.CollisionPaddingStuds)
        if safeDistance <= MINIMUM_STEP_DISTANCE then
            return startPosition, 0
        end
        targetPosition = startPosition + (clampedDirection * safeDistance)
        targetPosition = self._arenaService:ClampPositionInsideBattle(targetPosition, config.CollisionPaddingStuds)
        targetDistance = targetPosition and getPlanarDistance(startPosition, targetPosition) or 0
    end

    return targetPosition, targetDistance
end

function FlashService:_completeFlash(player, requestId)
    local pendingFlash = self._pendingFlashByUserId[player.UserId]
    if not pendingFlash or pendingFlash.RequestId ~= tostring(requestId or "") then
        return false
    end

    local remainingSeconds = pendingFlash.EarliestCompletionAt - os.clock()
    if remainingSeconds > 0 then
        if not pendingFlash.CompletionQueued then
            pendingFlash.CompletionQueued = true
            task.delay(remainingSeconds, function()
                self:_completeFlash(player, requestId)
            end)
        end
        return false
    end

    self._pendingFlashByUserId[player.UserId] = nil
    self._flashingByUserId[player.UserId] = nil

    local currentState = player.Parent and self._playerStateService:GetState(player) or nil
    local character = ActorUtils.GetCharacter(player)
    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (currentState and currentState.Alive == true and currentState.IsInArena == true and character and humanoid and rootPart and humanoid.Health > 0) then
        self:_fireFeedback(player, "Interrupted", {
            reason = "StateChanged",
            actualDistanceStuds = 0,
            cooldownRemainingSeconds = math.max(0, (self._cooldownEndsByUserId[player.UserId] or 0) - os.clock()),
        })
        return false
    end

    if not self._arenaService:IsPositionInsideBattle(pendingFlash.TargetPosition) then
        self:_fireFeedback(player, "Interrupted", {
            reason = "TargetInvalid",
            actualDistanceStuds = 0,
            cooldownRemainingSeconds = math.max(0, (self._cooldownEndsByUserId[player.UserId] or 0) - os.clock()),
        })
        return false
    end

    -- Only the server-approved endpoint is authoritative; the client never sends a position.
    character:PivotTo(CFrame.lookAt(pendingFlash.TargetPosition, pendingFlash.TargetPosition + pendingFlash.Direction))
    rootPart.AssemblyLinearVelocity = Vector3.zero
    rootPart.AssemblyAngularVelocity = Vector3.zero
    self:_fireFeedback(player, "Completed", {
        actualDistanceStuds = pendingFlash.TravelDistanceStuds,
        cooldownRemainingSeconds = math.max(0, (self._cooldownEndsByUserId[player.UserId] or 0) - os.clock()),
    })
    return true
end

function FlashService:_handleFlashCompleted(player, payload)
    if type(payload) ~= "table" then
        return
    end
    self:_completeFlash(player, payload.requestId)
end

function FlashService:_handleRequest(player)
    local config = self:_getConfig()
    if not config.Enabled then
        self:_fireFeedback(player, "Rejected", { reason = "Disabled" })
        return
    end

    local state = self._playerStateService and self._playerStateService:GetState(player)
    local character = ActorUtils.GetCharacter(player)
    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (state and state.Alive == true and state.IsInArena == true and character and humanoid and rootPart and humanoid.Health > 0) then
        self:_fireFeedback(player, "Rejected", { reason = "NotInBattle" })
        return
    end

    -- Snapshot this use: later upgrades affect the next Flash, not an active cooldown.
    config = self:_getConfig(player)

    local direction = getPlanarVector(humanoid.MoveDirection)
    if direction.Magnitude < config.MinimumMoveDirectionMagnitude then
        self:_fireFeedback(player, "Rejected", { reason = "NotMoving" })
        return
    end
    direction = direction.Unit

    local now = os.clock()
    local cooldownEndsAt = self._cooldownEndsByUserId[player.UserId] or 0
    if self._flashingByUserId[player.UserId] or now < cooldownEndsAt then
        self:_fireFeedback(player, "Rejected", {
            reason = "Cooldown",
            cooldownRemainingSeconds = math.max(0, cooldownEndsAt - now),
        })
        return
    end

    local targetPosition, reachableDistance = self:_getReachableTarget(rootPart.Position, direction, character, config)
    if not targetPosition or reachableDistance < config.MinimumTravelDistance then
        self:_fireFeedback(player, "Rejected", { reason = "Blocked" })
        return
    end

    self._cooldownEndsByUserId[player.UserId] = now + config.CooldownSeconds
    self._flashingByUserId[player.UserId] = true
    local requestId = string.format("Flash:%d:%d", player.UserId, math.floor(now * 1000))
    self._pendingFlashByUserId[player.UserId] = {
        RequestId = requestId,
        TargetPosition = targetPosition,
        Direction = direction,
        TravelDistanceStuds = reachableDistance,
        EarliestCompletionAt = now + config.DurationSeconds,
        CompletionQueued = false,
    }
    self:_playAnimation(humanoid, config.AnimationId, config.DurationSeconds)
    -- The client owns the visual motion. The server only approves this exact endpoint.
    self:_fireFeedback(player, "Started", {
        cooldownSeconds = config.CooldownSeconds,
        durationSeconds = config.DurationSeconds,
        requestedDistanceStuds = config.DistanceStuds,
        targetPosition = targetPosition,
        travelDistanceStuds = reachableDistance,
        requestId = requestId,
    })

    -- Fallback only: a lost client confirmation cannot leave Flash locked forever.
    task.delay(config.DurationSeconds + 1, function()
        self:_completeFlash(player, requestId)
    end)
end

function FlashService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._arenaService = dependencies.ArenaService
    self._requestFlashEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestFlash") or nil
    self._flashFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("FlashFeedback") or nil
    self._flashCompletedEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("FlashCompleted") or nil
    self._cooldownEndsByUserId = {}
    self._flashingByUserId = {}
    self._pendingFlashByUserId = {}

    if self._requestFlashEvent then
        self._requestFlashEvent.OnServerEvent:Connect(function(player)
            self:_handleRequest(player)
        end)
    end

    if self._flashCompletedEvent then
        self._flashCompletedEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleFlashCompleted(player, payload)
        end)
    end

    if self._playerRemovingConnection then
        self._playerRemovingConnection:Disconnect()
    end
    self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
        self._cooldownEndsByUserId[player.UserId] = nil
        self._flashingByUserId[player.UserId] = nil
        self._pendingFlashByUserId[player.UserId] = nil
    end)
end

return FlashService
