--[[
Script name: NukeCinematicController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/NukeCinematicController
Purpose: Plays the client-side LittleBoy nuclear cinematic, camera track, and explosion visuals.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ContentProvider = game:GetService("ContentProvider")

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
        "[NukeCinematicController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")
local controllersFolder = script.Parent:FindFirstChild("Controllers") or script.Parent
local CinematicUiGate = require(controllersFolder:WaitForChild("CinematicUiGate"))

local DEFAULT_NUKE_CONFIG = {
    AssetFolderName = "NukeAssets",
    SourceModelName = "LittleBoy",
    LittleBoyTemplateName = "LittleBoyTemplate",
    EffectFolderName = "Effect",
    BombEffectName = "Bomb",
    TargetMapName = "Battle01",
    BombPointName = "BombPoint",
    CameraAnimatorFolderName = "MoonAnimator2Saves",
    CameraTrackName = "Fall2",
    IdleAnimationId = "rbxassetid://91372355168267",
    FallHeight = 120,
    FallSeconds = 1.5,
    ExplosionSeconds = 2,
    ExplosionCoverageRadius = 320,
    ExplosionExpandPower = 1,
    StartLeadSeconds = 1,
    NukeBannerSeconds = 2,
    WarningFlashCount = 3,
    WarningFadeInSeconds = 0.25,
    WarningHoldSeconds = 0.35,
    WarningFadeOutSeconds = 0.25,
    WarningGapSeconds = 0.1,
    PreludeZIndex = 100,
    LocalMonsterSweepOrbCount = 12,
    ServerMonsterSweepOrbCount = 12,
    MonsterRespawnPauseSeconds = 2.5,
    LocalMonsterSweepExpireSeconds = 8,
    LightingClockTime = 4,
    RestoreClockTime = 14.5,
    QueueGapSeconds = 0.25,
}

GameConfig.NUKE = GameConfig.NUKE or {}
for key, value in pairs(DEFAULT_NUKE_CONFIG) do
    if GameConfig.NUKE[key] == nil then
        GameConfig.NUKE[key] = value
    end
end

local NukeCinematicController = {}

NukeCinematicController._localPlayer = nil
NukeCinematicController._localMonsterController = nil
NukeCinematicController._audioSettings = nil
NukeCinematicController._connections = {}
NukeCinematicController._activeSessionId = 0
NukeCinematicController._session = nil
NukeCinematicController._tails = {}
NukeCinematicController._preloadStarted = false

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getRootPart(model)
    if not model then
        return nil
    end
    if model:IsA("Model") then
        return model.PrimaryPart or model:FindFirstChild("Root", true) or model:FindFirstChildWhichIsA("BasePart", true)
    end
    if model:IsA("BasePart") then
        return model
    end
    return nil
end

local function setNonInteractive(model)
    if not model then
        return
    end
    local rootPart = getRootPart(model)
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = descendant == rootPart
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.Massless = true
        end
    end
end

local function ensureAnimator(model)
    if not model then
        return nil
    end
    local controller = model:FindFirstChildOfClass("AnimationController")
    if not controller then
        controller = Instance.new("AnimationController")
        controller.Parent = model
    end

    local animator = controller:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = controller
    end
    return animator
end

local function getCharacterHumanoid(player)
    local character = player and player.Character
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getMainGui(localPlayer)
    local playerGui = localPlayer and localPlayer:FindFirstChild("PlayerGui")
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function collectGuiTransparencyState(root)
    local state = {}

    local function capture(instance)
        if instance:IsA("GuiObject") then
            state[instance] = {
                BackgroundTransparency = instance.BackgroundTransparency,
                ZIndex = instance.ZIndex,
            }
            if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
                state[instance].TextTransparency = instance.TextTransparency
                state[instance].TextStrokeTransparency = instance.TextStrokeTransparency
            end
            if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
                state[instance].ImageTransparency = instance.ImageTransparency
            end
        elseif instance:IsA("UIStroke") then
            state[instance] = {
                Transparency = instance.Transparency,
            }
        end
    end

    capture(root)
    for _, descendant in ipairs(root:GetDescendants()) do
        capture(descendant)
    end
    return state
end

local function applyGuiAlpha(state, alpha)
    for instance, original in pairs(state) do
        if instance and instance.Parent then
            if instance:IsA("GuiObject") then
                if original.BackgroundTransparency ~= nil then
                    instance.BackgroundTransparency = original.BackgroundTransparency + ((1 - original.BackgroundTransparency) * alpha)
                end
                if original.TextTransparency ~= nil then
                    instance.TextTransparency = original.TextTransparency + ((1 - original.TextTransparency) * alpha)
                end
                if original.TextStrokeTransparency ~= nil then
                    instance.TextStrokeTransparency = original.TextStrokeTransparency + ((1 - original.TextStrokeTransparency) * alpha)
                end
                if original.ImageTransparency ~= nil then
                    instance.ImageTransparency = original.ImageTransparency + ((1 - original.ImageTransparency) * alpha)
                end
            elseif instance:IsA("UIStroke") and original.Transparency ~= nil then
                instance.Transparency = original.Transparency + ((1 - original.Transparency) * alpha)
            end
        end
    end
end

local function restoreGuiState(state)
    for instance, original in pairs(state) do
        if instance and instance.Parent then
            if instance:IsA("GuiObject") then
                if original.BackgroundTransparency ~= nil then
                    instance.BackgroundTransparency = original.BackgroundTransparency
                end
                if original.ZIndex ~= nil then
                    instance.ZIndex = original.ZIndex
                end
                if original.TextTransparency ~= nil then
                    instance.TextTransparency = original.TextTransparency
                end
                if original.TextStrokeTransparency ~= nil then
                    instance.TextStrokeTransparency = original.TextStrokeTransparency
                end
                if original.ImageTransparency ~= nil then
                    instance.ImageTransparency = original.ImageTransparency
                end
            elseif instance:IsA("UIStroke") and original.Transparency ~= nil then
                instance.Transparency = original.Transparency
            end
        end
    end
end

local function setGuiZIndex(root, state, zIndex)
    if root:IsA("GuiObject") then
        root.ZIndex = zIndex
    end
    for instance in pairs(state) do
        if instance and instance.Parent and instance:IsA("GuiObject") then
            instance.ZIndex = math.max(instance.ZIndex, zIndex)
        end
    end
end

local function parseBattleCenter(payload)
    local data = payload and payload.battleCenter or {}
    return Vector3.new(
        tonumber(data.x) or 0,
        tonumber(data.y) or 0,
        tonumber(data.z) or 0
    )
end

local function getFirstCFrameValue(frameFolder)
    local valuesFolder = frameFolder and frameFolder:FindFirstChild("Values")
    if not valuesFolder then
        return nil
    end

    for _, child in ipairs(valuesFolder:GetChildren()) do
        if child:IsA("CFrameValue") then
            return child.Value
        end
    end
    return nil
end

local function readCameraKeyframes(track)
    local cameraItem = track and track:FindFirstChild("2")
    local cframeFolder = cameraItem and cameraItem:FindFirstChild("CFrame")
    if not cframeFolder then
        return nil
    end

    local keyframes = {}
    for _, frameFolder in ipairs(cframeFolder:GetChildren()) do
        local frameNumber = tonumber(frameFolder.Name)
        local cframe = getFirstCFrameValue(frameFolder)
        if frameNumber and cframe then
            table.insert(keyframes, {
                frame = frameNumber,
                cframe = cframe,
            })
        end
    end
    table.sort(keyframes, function(a, b)
        return a.frame < b.frame
    end)

    if #keyframes <= 0 then
        return nil
    end
    return keyframes
end

local function sampleCameraKeyframes(keyframes, alpha)
    if not keyframes or #keyframes <= 0 then
        return nil
    end
    if #keyframes == 1 then
        return keyframes[1].cframe
    end

    local firstFrame = keyframes[1].frame
    local lastFrame = keyframes[#keyframes].frame
    local targetFrame = firstFrame + ((lastFrame - firstFrame) * math.clamp(alpha, 0, 1))

    for index = 1, #keyframes - 1 do
        local current = keyframes[index]
        local nextFrame = keyframes[index + 1]
        if targetFrame <= nextFrame.frame then
            local span = math.max(0.001, nextFrame.frame - current.frame)
            local localAlpha = math.clamp((targetFrame - current.frame) / span, 0, 1)
            return current.cframe:Lerp(nextFrame.cframe, localAlpha)
        end
    end

    return keyframes[#keyframes].cframe
end

local function getBombEffectTemplate()
    local effectFolder = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.EffectFolderName or "Effect")
    return effectFolder and effectFolder:FindFirstChild(GameConfig.NUKE.BombEffectName or "Bomb") or nil
end

local function getBattlePart()
    local arenaConfig = GameConfig.ARENA or {}
    local battlePartName = arenaConfig.BattlePartName or "Battle"
    local mapFolderName = arenaConfig.MapFolderName

    local mapFolder = mapFolderName and Workspace:FindFirstChild(mapFolderName)
    local battlePart = mapFolder and mapFolder:FindFirstChild(battlePartName, true)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end

    battlePart = Workspace:FindFirstChild(battlePartName, true)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end

    return nil
end

local function getBombPoint()
    local targetMapName = GameConfig.NUKE.TargetMapName or "Battle01"
    local bombPointName = GameConfig.NUKE.BombPointName or "BombPoint"
    local targetMap = Workspace:FindFirstChild(targetMapName)
    local bombPoint = targetMap and targetMap:FindFirstChild(bombPointName, true)
    if bombPoint and bombPoint:IsA("BasePart") then
        return bombPoint
    end
    return nil
end

local function getEffectPlacementPivot(effect)
    if effect:IsA("Model") then
        return effect:GetPivot()
    end
    if effect:IsA("BasePart") then
        return effect.CFrame
    end

    local sum = Vector3.zero
    local count = 0
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            sum += descendant.Position
            count += 1
        end
    end
    if count <= 0 then
        return CFrame.new()
    end
    return CFrame.new(sum / count)
end

local function translateEffect(effect, targetPosition)
    local pivot = getEffectPlacementPivot(effect)
    local offset = targetPosition - pivot.Position

    if effect:IsA("Model") then
        effect:PivotTo(CFrame.new(targetPosition) * (pivot - pivot.Position))
        return
    end

    if effect:IsA("BasePart") then
        effect.CFrame = effect.CFrame + offset
    end
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.CFrame = descendant.CFrame + offset
        end
    end
end

local function scaleNumberSequence(sequence, scale)
    local keypoints = {}
    for _, keypoint in ipairs(sequence.Keypoints) do
        table.insert(keypoints, NumberSequenceKeypoint.new(
            keypoint.Time,
            keypoint.Value * scale,
            keypoint.Envelope * scale
        ))
    end
    return NumberSequence.new(keypoints)
end

local function scaleNumberRange(range, scale)
    return NumberRange.new(range.Min * scale, range.Max * scale)
end

local function captureEffectScaleState(effect)
    local pivot = getEffectPlacementPivot(effect)
    local state = {
        pivot = pivot,
        parts = {},
        attachments = {},
        emitters = {},
        beams = {},
        trails = {},
        lights = {},
        meshes = {},
    }

    local function capturePart(part)
        table.insert(state.parts, {
            instance = part,
            size = part.Size,
            relative = pivot:ToObjectSpace(part.CFrame),
        })
    end

    if effect:IsA("BasePart") then
        capturePart(effect)
    end
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            capturePart(descendant)
        elseif descendant:IsA("Attachment") then
            table.insert(state.attachments, {
                instance = descendant,
                position = descendant.Position,
            })
        elseif descendant:IsA("ParticleEmitter") then
            table.insert(state.emitters, {
                instance = descendant,
                size = descendant.Size,
                speed = descendant.Speed,
                acceleration = descendant.Acceleration,
            })
        elseif descendant:IsA("Beam") then
            table.insert(state.beams, {
                instance = descendant,
                width0 = descendant.Width0,
                width1 = descendant.Width1,
                curveSize0 = descendant.CurveSize0,
                curveSize1 = descendant.CurveSize1,
            })
        elseif descendant:IsA("Trail") then
            table.insert(state.trails, {
                instance = descendant,
                widthScale = descendant.WidthScale,
            })
        elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
            table.insert(state.lights, {
                instance = descendant,
                range = descendant.Range,
            })
        elseif descendant:IsA("SpecialMesh") then
            table.insert(state.meshes, {
                instance = descendant,
                scale = descendant.Scale,
                offset = descendant.Offset,
            })
        end
    end

    return state
end

local function applyEffectScale(state, scale)
    local pivot = state.pivot
    for _, item in ipairs(state.parts) do
        local part = item.instance
        if part and part.Parent then
            local relative = item.relative
            part.Size = item.size * scale
            part.CFrame = pivot * CFrame.new(relative.Position * scale) * (relative - relative.Position)
        end
    end
    for _, item in ipairs(state.attachments) do
        if item.instance and item.instance.Parent then
            item.instance.Position = item.position * scale
        end
    end
    for _, item in ipairs(state.emitters) do
        local emitter = item.instance
        if emitter and emitter.Parent then
            emitter.Size = scaleNumberSequence(item.size, scale)
            emitter.Speed = scaleNumberRange(item.speed, scale)
            emitter.Acceleration = item.acceleration * scale
        end
    end
    for _, item in ipairs(state.beams) do
        local beam = item.instance
        if beam and beam.Parent then
            beam.Width0 = item.width0 * scale
            beam.Width1 = item.width1 * scale
            beam.CurveSize0 = item.curveSize0 * scale
            beam.CurveSize1 = item.curveSize1 * scale
        end
    end
    for _, item in ipairs(state.trails) do
        if item.instance and item.instance.Parent then
            item.instance.WidthScale = scaleNumberSequence(item.widthScale, scale)
        end
    end
    for _, item in ipairs(state.lights) do
        if item.instance and item.instance.Parent then
            item.instance.Range = item.range * scale
        end
    end
    for _, item in ipairs(state.meshes) do
        local mesh = item.instance
        if mesh and mesh.Parent then
            mesh.Scale = item.scale * scale
            mesh.Offset = item.offset * scale
        end
    end
end

-- Presentation-only limits. Gameplay timings/rewards remain in GameConfig.NUKE.
local PRESENTATION = {
    CoreScale = 2.2,
    ParticleBudget = 960,
    ParticleSizeLimit = 360,
    ParticleSpeedLimit = 140,
    BeamLimit = 24,
    WaveSegments = 32,
    TailSeconds = 3.1,
    ReturnSeconds = 0.32,
}

local function finiteNumber(value, fallback)
    local number = tonumber(value)
    if number and number == number and math.abs(number) < math.huge then
        return number
    end
    return fallback
end

local function duration(payload, key, configKey, fallback)
    return math.max(0, finiteNumber(payload[key], finiteNumber(GameConfig.NUKE[configKey], fallback)))
end

local function smoothstep(alpha)
    alpha = math.clamp(alpha, 0, 1)
    return alpha * alpha * (3 - 2 * alpha)
end

local function boundedSequence(sequence, scale, limit)
    local maximum = 0
    for _, keypoint in ipairs(sequence.Keypoints) do
        maximum = math.max(maximum, keypoint.Value + keypoint.Envelope)
    end
    return scaleNumberSequence(sequence, math.min(scale, limit / math.max(maximum, 0.001)))
end

local function prepareEffectInstance(effect)
    local function prepare(instance)
        if instance:IsA("BasePart") then
            instance.Anchored = true
            instance.CanCollide = false
            instance.CanTouch = false
            instance.CanQuery = false
            instance.Massless = true
        elseif instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail") then
            instance.Enabled = false
        elseif instance:IsA("Light") then
            instance.Enabled = false
        end
    end
    prepare(effect)
    for _, descendant in ipairs(effect:GetDescendants()) do
        prepare(descendant)
    end
end

function NukeCinematicController:_isCurrent(session)
    return self._session == session and not session.cancelled
end

function NukeCinematicController:_own(session, instance)
    table.insert(session.resources, instance)
    return instance
end

function NukeCinematicController:_captureCameraState()
    local camera = Workspace.CurrentCamera
    if not camera then
        return nil
    end
    local root = self._localPlayer and self._localPlayer.Character
        and self._localPlayer.Character:FindFirstChild("HumanoidRootPart")
    return {
        camera = camera,
        cameraType = camera.CameraType,
        cameraSubject = camera.CameraSubject,
        cframe = camera.CFrame,
        focus = camera.Focus,
        fieldOfView = camera.FieldOfView,
        rootPosition = root and root.Position,
    }
end

function NukeCinematicController:_returnCameraFrame(state)
    local root = self._localPlayer and self._localPlayer.Character
        and self._localPlayer.Character:FindFirstChild("HumanoidRootPart")
    local offset = root and state.rootPosition and (root.Position - state.rootPosition) or Vector3.zero
    return state.cframe + offset, state.focus + offset
end

function NukeCinematicController:_restoreCamera(session)
    local state = session.cameraState
    if not state then
        return
    end
    -- A replacement camera belongs to the respawn/camera controller, not this cinematic.
    local camera = state.camera
    if camera.Parent and Workspace.CurrentCamera == camera then
        local humanoid = getCharacterHumanoid(self._localPlayer)
        if humanoid and humanoid.Health <= 0 then
            humanoid = nil
        end
        local oldSubject = state.cameraSubject
        if oldSubject and not oldSubject.Parent then
            oldSubject = nil
        elseif oldSubject and oldSubject:IsA("Humanoid") and oldSubject.Health <= 0 then
            oldSubject = nil
        end
        local subject = oldSubject
        if (not subject or subject:IsA("Humanoid")) and humanoid then
            subject = humanoid
        end
        camera.CameraSubject = subject
        camera.CFrame, camera.Focus = self:_returnCameraFrame(state)
        camera.FieldOfView = state.fieldOfView
        camera.CameraType = state.cameraType
        if not subject and camera.CameraType ~= Enum.CameraType.Scriptable then
            camera.CameraType = Enum.CameraType.Custom
        end
    end
    session.cameraState = nil
end

function NukeCinematicController:_rememberGui(session, root)
    if not (root and root:IsA("GuiObject")) then
        return nil
    end
    local state = {root = root, visible = root.Visible, transparency = collectGuiTransparencyState(root)}
    table.insert(session.guis, state)
    setGuiZIndex(root, state.transparency, GameConfig.NUKE.PreludeZIndex or 100)
    return state
end

function NukeCinematicController:_finishPresentation(session)
    if session.presentationFinished then
        return
    end
    session.presentationFinished = true
    -- Old tasks can dispose their own instances, but cannot restore shared GUI/camera.
    if self._session == session then
        self:_restoreCamera(session)
        for _, state in ipairs(session.guis) do
            restoreGuiState(state.transparency)
            if state.root.Parent then
                state.root.Visible = state.visible
            end
        end
    end
    for _, effect in ipairs(session.postEffects or {}) do
        effect:Destroy()
    end
end

function NukeCinematicController:_cancelSession(session)
    session = session or self._session
    if not session or session.cleaned then
        return
    end
    session.cancelled = true
    self:_finishPresentation(session)
    session.cleaned = true
    for _, track in ipairs(session.tracks) do
        pcall(function()
            track:Stop(0)
            track:Destroy()
        end)
    end
    for index = #session.resources, 1, -1 do
        pcall(function()
            session.resources[index]:Destroy()
        end)
    end
    if self._session == session then
        self._session = nil
    end
    self._tails[session] = nil
    if session.gateToken then
        CinematicUiGate:Release(session.gateToken)
        session.gateToken = nil
    end
end

function NukeCinematicController:_renderUntil(session, deadline, render, allowTail)
    local function ownsResources()
        return self:_isCurrent(session) or (allowTail and self._tails[session] and not session.cancelled)
    end
    while ownsResources() and os.clock() < deadline do
        if render then
            render(os.clock())
        end
        RunService.RenderStepped:Wait()
    end
    return ownsResources() == true
end

function NukeCinematicController:_buildTimeline(payload)
    local start = os.clock()
    local serverStart = finiteNumber(payload.serverStartTime, nil)
    if serverStart then
        local ok, serverNow = pcall(function()
            return Workspace:GetServerTimeNow()
        end)
        serverNow = ok and finiteNumber(serverNow, nil) or nil
        if serverNow then
            start -= math.max(0, serverNow - serverStart)
        end
    end
    local lead = duration(payload, "startDelaySeconds", "StartLeadSeconds", 1)
    local banner = duration(payload, "nukeBannerSeconds", "NukeBannerSeconds", 2)
    local count = math.clamp(math.floor(duration(payload, "warningFlashCount", "WarningFlashCount", 3)), 0, 20)
    local fadeIn = duration(payload, "warningFadeInSeconds", "WarningFadeInSeconds", 0.25)
    local hold = duration(payload, "warningHoldSeconds", "WarningHoldSeconds", 0.35)
    local fadeOut = duration(payload, "warningFadeOutSeconds", "WarningFadeOutSeconds", 0.25)
    local gap = duration(payload, "warningGapSeconds", "WarningGapSeconds", 0.1)
    local fall = math.max(0.1, duration(payload, "fallSeconds", "FallSeconds", 1.5))
    local explosion = math.max(0.1, duration(payload, "explosionSeconds", "ExplosionSeconds", 2))
    local bannerStart = start + lead
    local warningStart = bannerStart + banner
    local fallStart = warningStart + count * (fadeIn + hold + fadeOut) + math.max(0, count - 1) * gap
    return {
        start = start, bannerStart = bannerStart, warningStart = warningStart,
        fallStart = fallStart, impact = fallStart + fall, finish = fallStart + fall + explosion,
        -- Match NukeService's existing authorization window (registered before lead).
        sweepExpires = fallStart + fall + explosion - lead + math.max(1, finiteNumber(GameConfig.NUKE.LocalMonsterSweepExpireSeconds, 8)),
        fadeIn = fadeIn, hold = hold, fadeOut = fadeOut, gap = gap, count = count,
    }
end

function NukeCinematicController:_playPrelude(session)
    local timeline = session.timeline
    local main = getMainGui(self._localPlayer)
    local banner = self:_rememberGui(session, main and main:FindFirstChild("Nuke"))
    local warning = self:_rememberGui(session, main and main:FindFirstChild("Warning"))
    local caller = session.payload.ownerDisplayName or session.payload.ownerName
    local text = banner and banner.root:FindFirstChild("Text")
    if text and (text:IsA("TextLabel") or text:IsA("TextButton")) then
        text.Text = string.format("%s called in a nuke.", type(caller) == "string" and caller ~= "" and caller or "Someone")
    end
    return self:_renderUntil(session, timeline.fallStart, function(now)
        if banner and banner.root.Parent then
            banner.root.Visible = now >= timeline.bannerStart and now < timeline.warningStart
            applyGuiAlpha(banner.transparency, 0)
        end
        if warning and warning.root.Parent then
            local elapsed = now - timeline.warningStart
            local cycle = timeline.fadeIn + timeline.hold + timeline.fadeOut + timeline.gap
            local index = cycle > 0 and math.floor(math.max(0, elapsed) / cycle) or timeline.count
            local phase = cycle > 0 and elapsed - index * cycle or 0
            local visible = elapsed >= 0 and index < timeline.count and phase < cycle - timeline.gap
            warning.root.Visible = visible
            local alpha = 1
            if visible then
                if phase < timeline.fadeIn then
                    alpha = 1 - smoothstep(phase / math.max(timeline.fadeIn, 0.001))
                elseif phase < timeline.fadeIn + timeline.hold then
                    alpha = 0
                else
                    alpha = smoothstep((phase - timeline.fadeIn - timeline.hold) / math.max(timeline.fadeOut, 0.001))
                end
            end
            applyGuiAlpha(warning.transparency, alpha)
        end
    end)
end

function NukeCinematicController:_bindPresentationGui(session)
    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    local gui = playerGui and playerGui:FindFirstChild("NukeCinematicEffects")
    session.bars = {}
    for _, name in ipairs({"TopBar", "BottomBar"}) do
        local state = self:_rememberGui(session, gui and gui:FindFirstChild(name))
        if state then
            table.insert(session.bars, state.root)
        end
    end
    local flash = self:_rememberGui(session, gui and gui:FindFirstChild("ImpactFlash"))
    session.flash = flash and flash.root
    if session.flash then
        session.flash.ZIndex = math.max(session.flash.ZIndex, (GameConfig.NUKE.PreludeZIndex or 100) + 1)
    end
end

function NukeCinematicController:_buildCameraTrack()
    -- Never wait for optional presentation assets on the authoritative timeline.
    local assets = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.AssetFolderName)
    local source = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    local folders = {
        assets and assets:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName),
        ReplicatedStorage:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName),
        source and source:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName, true),
    }
    -- pairs handles absent optional folders without terminating at the first nil.
    for _, folder in pairs(folders) do
        local track = folder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
        if readCameraKeyframes(track) then
            return track
        end
    end
    return nil
end

function NukeCinematicController:_buildLittleBoy(session, initialCFrame)
    local template = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    if not (template and template:IsA("Model")) then
        local assets = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.AssetFolderName)
        template = assets and assets:FindFirstChild(GameConfig.NUKE.LittleBoyTemplateName)
    end
    if not (template and template:IsA("Model")) then
        return nil
    end
    local clone = template:Clone()
    if not clone then
        return nil
    end
    self:_own(session, clone)
    local pivot = clone:GetPivot()
    clone:SetAttribute("NukeOriginalPivotPosition", pivot.Position)
    clone:SetAttribute("NukeOriginalRotation", pivot - pivot.Position)
    clone.PrimaryPart = getRootPart(clone)
    setNonInteractive(clone)
    clone:PivotTo(initialCFrame * (pivot - pivot.Position))
    clone.Parent = Workspace
    return clone
end

function NukeCinematicController:_playLittleBoyAnimation(session, littleBoy)
    local animator = ensureAnimator(littleBoy)
    if not animator then
        return nil
    end
    local animation = Instance.new("Animation")
    animation.AnimationId = tostring(session.payload.idleAnimationId or GameConfig.NUKE.IdleAnimationId)
    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    animation:Destroy()
    if ok and track then
        table.insert(session.tracks, track)
        track.Looped = true
        track.Priority = Enum.AnimationPriority.Action
        track:Play(0.1)
        return track
    end
    return nil
end

function NukeCinematicController:_cameraAvailable(session)
    local state = session.cameraState
    return state and state.camera.Parent and Workspace.CurrentCamera == state.camera
end

function NukeCinematicController:_runFall(session, littleBoy, center, height)
    local timeline = session.timeline
    local startPosition = center + Vector3.new(0, height, 0)
    local keyframes = readCameraKeyframes(self:_buildCameraTrack())
    -- Fall2 ends in a one-frame editorial cut. Use the preceding continuous shot.
    if keyframes and #keyframes > 1 then
        local last, previous = keyframes[#keyframes], keyframes[#keyframes - 1]
        if last.frame - previous.frame <= 1 and (last.cframe.Position - previous.cframe.Position).Magnitude > 40 then
            table.remove(keyframes)
        end
    end
    local recordedPosition = littleBoy and littleBoy:GetAttribute("NukeOriginalPivotPosition") or startPosition
    local rotation = littleBoy and littleBoy:GetAttribute("NukeOriginalRotation") or CFrame.new()
    local cameraShift = CFrame.new(startPosition - recordedPosition)
    local motor = littleBoy and getRootPart(littleBoy) and getRootPart(littleBoy):FindFirstChild("Union1")
    local lastClock = os.clock()
    return self:_renderUntil(session, timeline.impact, function(now)
        local alpha = math.clamp((now - timeline.fallStart) / (timeline.impact - timeline.fallStart), 0, 1)
        local progress = 0.12 * alpha + 0.88 * alpha * alpha
        local position = startPosition:Lerp(center, progress)
        if littleBoy and littleBoy.Parent then
            littleBoy:PivotTo(CFrame.new(position) * rotation)
            if not session.bombTrack and motor and motor:IsA("Motor6D") then
                motor.Transform = CFrame.Angles(0, (now - timeline.fallStart) * math.pi * 2.6, 0)
            end
        end
        if self:_cameraAvailable(session) then
            local camera = session.cameraState.camera
            local sample = sampleCameraKeyframes(keyframes, progress)
            local target = sample and cameraShift * sample or CFrame.lookAt(position + Vector3.new(28, 16, 48), position)
            local dt = math.clamp(now - lastClock, 1 / 240, 0.1)
            camera.CameraType = Enum.CameraType.Scriptable
            camera.CFrame = camera.CFrame:Lerp(target, 1 - math.exp(-dt * 16))
            camera.Focus = CFrame.new(position)
            camera.FieldOfView = session.cameraState.fieldOfView + 4 * progress
        end
        for _, bar in ipairs(session.bars) do
            if bar.Parent then
                bar.Visible = true
                bar.BackgroundTransparency = 1 - 0.85 * smoothstep(alpha / 0.25)
            end
        end
        lastClock = now
    end)
end

function NukeCinematicController:_coverageRadius()
    local battle = getBattlePart()
    return math.clamp(battle and Vector2.new(battle.Size.X, battle.Size.Z).Magnitude * 0.5 + 35
        or finiteNumber(GameConfig.NUKE.ExplosionCoverageRadius, 320), 160, 600)
end

function NukeCinematicController:_prepareExplosionVfx(session, center)
    local vfx = {bursts = {}, beams = {}, lights = {}, ring = {}, radius = self:_coverageRadius()}
    local template = getBombEffectTemplate()
    if template then
        local effect = template:Clone()
        if effect then
            self:_own(session, effect)
            local authoredEmission = {}
            for _, descendant in ipairs(effect:GetDescendants()) do
                if descendant:IsA("ParticleEmitter") then
                    authoredEmission[descendant] = {enabled = descendant.Enabled, rate = descendant.Rate}
                end
            end
            prepareEffectInstance(effect)
            translateEffect(effect, center)
            applyEffectScale(captureEffectScaleState(effect), PRESENTATION.CoreScale)
            local floorLayer = effect:FindFirstChild("FloorOn")
            local floorPart = floorLayer and floorLayer:FindFirstChild("Floor", true)
            local battle = getBattlePart()
            local groundY = battle and (battle.Position.Y + battle.Size.Y * 0.5) or center.Y
            if floorPart and floorPart:IsA("BasePart") then
                local pivot = getEffectPlacementPivot(effect)
                translateEffect(effect, pivot.Position + Vector3.new(0, groundY + 0.8 - floorPart.Position.Y, 0))
            end
            local budget = PRESENTATION.ParticleBudget
            local beamIndex = 0
            for _, descendant in ipairs(effect:GetDescendants()) do
                if descendant:IsA("ParticleEmitter") then
                    local path = descendant:GetFullName():lower()
                    local smoke = path:find("smoke", 1, true) or path:find("dust", 1, true) or path:find("ash", 1, true)
                    local floor = path:find("flooron", 1, true)
                    local wind = path:find("windbig", 1, true)
                    local delay = smoke and 0.22 or (floor and 0.07 or (wind and 0.12 or 0))
                    local limit = wind and 260 or PRESENTATION.ParticleSizeLimit
                    descendant.Size = boundedSequence(descendant.Size, 1, limit)
                    local speedScale = math.min(1, PRESENTATION.ParticleSpeedLimit / math.max(descendant.Speed.Max, 0.001))
                    descendant.Speed = scaleNumberRange(descendant.Speed, speedScale)
                    if descendant.Acceleration.Magnitude > 100 then
                        descendant.Acceleration = descendant.Acceleration.Unit * 100
                    end
                    descendant.Lifetime = NumberRange.new(math.min(descendant.Lifetime.Min, 2.4), math.min(descendant.Lifetime.Max, 2.4))
                    local authoredCount = finiteNumber(descendant:GetAttribute("EmitCount"), nil)
                    local original = authoredEmission[descendant]
                    -- EmitCount=0 means no *extra* burst, not that an enabled continuous layer is silent.
                    local continuousCount = original.enabled and original.rate > 0 and original.rate * 0.3 or 0
                    local rawCount = math.max(authoredCount or 0, continuousCount)
                    local count = rawCount > 0 and math.clamp(math.ceil(rawCount), 4, 48) or 0
                    count = math.min(count, budget)
                    budget -= count
                    table.insert(vfx.bursts, {emitter = descendant, count = count, delay = delay, emitted = false})
                elseif descendant:IsA("Beam") then
                    beamIndex += 1
                    if (beamIndex - 1) % 3 == 0 and #vfx.beams < PRESENTATION.BeamLimit then
                        descendant.Width0 = math.min(descendant.Width0, 8)
                        descendant.Width1 = math.min(descendant.Width1, 8)
                        table.insert(vfx.beams, descendant)
                    end
                elseif descendant:IsA("Light") then
                    descendant.Range = math.min(descendant.Range, 100)
                    descendant.Brightness = math.min(descendant.Brightness, 5)
                    table.insert(vfx.lights, {light = descendant, brightness = descendant.Brightness})
                end
            end
            vfx.root = effect
        end
    end
    -- A separate ground wave carries map coverage; it never scales the fire/smoke.
    local ring = self:_own(session, Instance.new("Folder"))
    ring.Name = "NukeGroundWave"
    vfx.ringRoot = ring
    local battle = getBattlePart()
    vfx.groundCenter = Vector3.new(center.X, battle and (battle.Position.Y + battle.Size.Y * 0.5 + 0.8) or center.Y + 0.8, center.Z)
    for index = 1, PRESENTATION.WaveSegments do
        local part = Instance.new("Part")
        part.Name = "Wave"
        part.Anchored = true
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.CastShadow = false
        part.Material = Enum.Material.Neon
        part.Color = Color3.fromRGB(255, 205, 115)
        part.Transparency = 1
        part.Size = Vector3.new(1, 0.3, 1)
        part.Parent = ring
        table.insert(vfx.ring, part)
    end
    -- Keep prepared resources detached and disabled throughout the warning/fall.
    return vfx
end

function NukeCinematicController:_activateExplosionVfx(vfx)
    if vfx.startedAt then
        return vfx
    end
    if vfx.root then
        vfx.root.Parent = Workspace
    end
    vfx.ringRoot.Parent = Workspace
    -- Start visible time on activation, never while the warning is still playing.
    vfx.startedAt = os.clock()
    self:_updateExplosionVfx(vfx, 0)
    return vfx
end

function NukeCinematicController:_createExplosionVfx(session, center)
    return self:_activateExplosionVfx(self:_prepareExplosionVfx(session, center))
end

function NukeCinematicController:_updateExplosionVfx(vfx, elapsed)
    if not vfx.burstsFinished then
        local finished = true
        for _, burst in ipairs(vfx.bursts) do
            if not burst.emitted and elapsed >= burst.delay then
                burst.emitted = true
                if burst.count > 0 and burst.emitter.Parent then
                    burst.emitter:Emit(burst.count)
                end
            end
            finished = finished and burst.emitted
        end
        vfx.burstsFinished = finished
    end
    if not vfx.beamsFinished then
        for _, beam in ipairs(vfx.beams) do
            if beam.Parent then
                beam.Enabled = elapsed < 0.22
            end
        end
        vfx.beamsFinished = elapsed >= 0.22
    end
    if not vfx.lightsFinished then
        for _, item in ipairs(vfx.lights) do
            if item.light.Parent then
                item.light.Enabled = elapsed < 0.45
                item.light.Brightness = item.brightness * math.max(0, 1 - elapsed / 0.45)
            end
        end
        vfx.lightsFinished = elapsed >= 0.45
    end
    if vfx.waveFinished then
        return
    end
    local alpha = math.clamp((elapsed - 0.05) / 0.95, 0, 1)
    local radius = 8 + (vfx.radius - 8) * (1 - (1 - alpha) ^ 2)
    for index, part in ipairs(vfx.ring) do
        if part.Parent then
            local angle = (index - 1) * 2 * math.pi / #vfx.ring
            local position = vfx.groundCenter + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
            part.CFrame = CFrame.lookAt(position, vfx.groundCenter)
            part.Size = Vector3.new(2 * radius * math.tan(math.pi / #vfx.ring) + 0.3, 0.3, 2.5)
            part.Transparency = elapsed < 0.05 and 1 or math.clamp(0.25 + alpha ^ 2 * 0.75, 0, 1)
        end
    end
    vfx.waveFinished = elapsed >= 1
end

function NukeCinematicController:_prepareBoom(session)
    if session.sound then
        return session.sound
    end
    local config = GameConfig.AUDIO or {}
    local folder = game:GetService("SoundService"):FindFirstChild(config.FolderName or "Audio")
    local original = folder and folder:FindFirstChild(config.BoomSoundName or "Boom")
    if not (original and original:IsA("Sound")) then
        return
    end
    local sound = self:_own(session, original:Clone())
    sound.Name = "NukeBoom"
    sound.Looped = false
    sound:Stop()
    sound.Parent = folder
    session.sound = sound
    return sound
end

function NukeCinematicController:_playBoom(session, elapsed)
    local sound = session.sound or self:_prepareBoom(session)
    if not sound then
        return
    end
    sound.TimePosition = 0
    if self._audioSettings and self._audioSettings.PlaySfx then
        self._audioSettings:PlaySfx(sound, true)
    else
        sound:Play()
    end
end

function NukeCinematicController:_preparePostEffects(session)
    local color = self:_own(session, Instance.new("ColorCorrectionEffect"))
    color.Name = "NukeImpactColor"
    color.Enabled = false
    local bloom = self:_own(session, Instance.new("BloomEffect"))
    bloom.Name = "NukeImpactBloom"
    bloom.Intensity = 0
    bloom.Size = 24
    bloom.Threshold = 1.4
    bloom.Enabled = false
    session.postEffects = {color, bloom}
    return color, bloom
end

function NukeCinematicController:_createPostEffects(session)
    local color, bloom
    if session.postEffects then
        color, bloom = table.unpack(session.postEffects)
    else
        color, bloom = self:_preparePostEffects(session)
    end
    color.Parent, bloom.Parent = Lighting, Lighting
    color.Enabled, bloom.Enabled = true, true
    return color, bloom
end

function NukeCinematicController:_preloadPresentationAssets()
    if self._preloadStarted then
        return
    end
    local resources = {}
    local effect = getBombEffectTemplate()
    if effect then
        table.insert(resources, effect)
    end
    local bomb = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    if not (bomb and bomb:IsA("Model")) then
        local assets = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.AssetFolderName)
        bomb = assets and assets:FindFirstChild(GameConfig.NUKE.LittleBoyTemplateName)
    end
    if bomb then
        table.insert(resources, bomb)
    end
    local config = GameConfig.AUDIO or {}
    local folder = game:GetService("SoundService"):FindFirstChild(config.FolderName or "Audio")
    local sound = folder and folder:FindFirstChild(config.BoomSoundName or "Boom")
    if sound then
        table.insert(resources, sound)
    end
    if #resources == 0 then
        return
    end
    self._preloadStarted = true
    -- Downloads are optional background work; the cinematic never awaits this task.
    task.spawn(function()
        local ok, message = pcall(function()
            ContentProvider:PreloadAsync(resources)
        end)
        if not ok then
            self._preloadStarted = false
            warn("[NukeCinematicController] Asset preloading failed: " .. tostring(message))
        end
    end)
end

function NukeCinematicController:_sweepLocalMonstersForNuke(payload, expiresAt)
    if expiresAt and os.clock() >= expiresAt then
        return
    end
    if not (self._localPlayer and tonumber(payload.ownerUserId) == self._localPlayer.UserId) then
        return
    end
    if self._localMonsterController and self._localMonsterController.SweepForNuke then
        local ok, message = pcall(function()
            self._localMonsterController:SweepForNuke(payload.sessionId)
        end)
        if not ok then
            warn("[NukeCinematicController] Local sweep failed: " .. tostring(message))
        end
    end
end

function NukeCinematicController:_holdExplosionCamera(session, center, vfx)
    local state = session.cameraState
    local opening = state and state.camera.CFrame or CFrame.lookAt(center + Vector3.new(28, 24, 54), center)
    local direction = Vector3.new(opening.Position.X - center.X, 0, opening.Position.Z - center.Z)
    direction = direction.Magnitude > 1 and direction.Unit or Vector3.new(0, 0, 1)
    local distance = math.clamp(vfx.radius * 0.48, 150, 300)
    local wide = CFrame.lookAt(center + direction * distance + Vector3.new(0, distance * 0.52, 0), center + Vector3.new(0, 25, 0))
    local color, bloom = self:_createPostEffects(session)
    local timeline = session.timeline
    session.visualFinish = vfx.startedAt + (timeline.finish - timeline.impact)
    return self:_renderUntil(session, session.visualFinish, function(now)
        local elapsed = math.max(0, now - vfx.startedAt)
        self:_updateExplosionVfx(vfx, elapsed)
        local shock = math.exp(-elapsed * 9)
        color.Brightness = 0.12 * shock
        color.Contrast = 0.1 * shock
        color.TintColor = Color3.new(1, 1 - 0.1 * shock, 1 - 0.22 * shock)
        bloom.Intensity = 0.55 * shock
        if session.flash and session.flash.Parent then
            session.flash.Visible = elapsed < 0.22
            session.flash.BackgroundTransparency = 1 - 0.72 * math.max(0, 1 - elapsed / 0.22) ^ 2
        end
        local returnAlpha = smoothstep((now - (session.visualFinish - PRESENTATION.ReturnSeconds)) / PRESENTATION.ReturnSeconds)
        for _, bar in ipairs(session.bars) do
            if bar.Parent then
                bar.BackgroundTransparency = 0.15 + 0.85 * returnAlpha
            end
        end
        if self:_cameraAvailable(session) then
            local camera = state.camera
            camera.CameraType = Enum.CameraType.Scriptable
            local base = opening:Lerp(wide, smoothstep(elapsed / 0.8))
            local returnFrame = self:_returnCameraFrame(state)
            base = base:Lerp(returnFrame, returnAlpha)
            local shake = math.exp(-elapsed * 7) * (1 - returnAlpha)
            camera.CFrame = base * CFrame.new(math.sin(elapsed * 73) * shake, math.cos(elapsed * 91) * 0.7 * shake, 0)
                * CFrame.Angles(math.sin(elapsed * 67) * 0.006 * shake, 0, math.cos(elapsed * 59) * 0.004 * shake)
            camera.Focus = CFrame.new(center):Lerp(select(2, self:_returnCameraFrame(state)), returnAlpha)
            camera.FieldOfView = state.fieldOfView + (7 * math.exp(-elapsed * 5) + 3 * (1 - math.exp(-elapsed * 4))) * (1 - returnAlpha)
        end
    end)
end

function NukeCinematicController:_playCinematic(payload)
    if type(payload) ~= "table" then
        return
    end
    local gateToken = CinematicUiGate:Acquire("Nuke")
    self:_cancelSession()
    local session = {
        payload = payload, timeline = self:_buildTimeline(payload), resources = {}, tracks = {}, guis = {},
        cancelled = false, presentationFinished = false,
        gateToken = gateToken,
    }
    self._session = session
    self._activeSessionId = tonumber(payload.sessionId) or (self._activeSessionId + 1)
    task.spawn(function()
        local ok, message = xpcall(function()
            -- Expired deliveries should not seize the player's camera or repeat an old blast.
            if os.clock() >= session.timeline.finish then
                -- The server's token window outlives the visual. Preserve a late buyer's sweep.
                self:_sweepLocalMonstersForNuke(payload, session.timeline.sweepExpires)
                return
            end
            self:_preloadPresentationAssets()
            local center = parseBattleCenter(payload)
            local bombPoint = getBombPoint()
            if bombPoint then
                center = bombPoint.Position
            end
            local vfx = self:_prepareExplosionVfx(session, center)
            self:_prepareBoom(session)
            self:_preparePostEffects(session)
            if not self:_playPrelude(session) then
                return
            end
            for _, gui in ipairs(session.guis) do
                if gui.root.Parent then
                    gui.root.Visible = false
                end
            end
            session.cameraState = self:_captureCameraState()
            self:_bindPresentationGui(session)
            local height = math.max(10, finiteNumber(payload.fallHeight, GameConfig.NUKE.FallHeight or 120))
            local bomb
            if os.clock() < session.timeline.impact then
                bomb = self:_buildLittleBoy(session, CFrame.new(center + Vector3.new(0, height, 0)))
                if bomb then
                    session.bombTrack = self:_playLittleBoyAnimation(session, bomb)
                end
                if not self:_runFall(session, bomb, center, height) then
                    return
                end
            end
            if not self:_isCurrent(session) then
                return
            end
            if session.bombTrack then
                session.bombTrack:Stop(0)
            end
            if bomb then
                bomb:Destroy()
            end
            self:_sweepLocalMonstersForNuke(payload, session.timeline.sweepExpires)
            if not self:_isCurrent(session) then
                return
            end
            self:_activateExplosionVfx(vfx)
            self:_playBoom(session, 0)
            if not self:_holdExplosionCamera(session, center, vfx) then
                return
            end
            self:_finishPresentation(session)
            if self._session == session then
                self._session = nil
                self._tails[session] = true
            end
            -- Audio and finite smoke finish after the camera has already been returned.
            local sound = session.sound
            local soundSeconds = sound and sound.TimeLength / math.max(sound.PlaybackSpeed, 0.1) + 0.12 or 0
            local tailDeadline = vfx.startedAt + math.max(PRESENTATION.TailSeconds, soundSeconds, session.timeline.finish - session.timeline.impact)
            self:_renderUntil(session, tailDeadline, function(now)
                self:_updateExplosionVfx(vfx, now - vfx.startedAt)
            end, true)
        end, debug.traceback)
        self:_cancelSession(session)
        if not ok then
            warn("[NukeCinematicController] Cinematic cleaned up after error: " .. tostring(message))
        end
    end)
end

function NukeCinematicController:Init(dependencies)
    self:_cancelSession()
    local tails = {}
    for session in pairs(self._tails) do
        table.insert(tails, session)
    end
    for _, session in ipairs(tails) do
        self:_cancelSession(session)
    end
    disconnectAll(self._connections)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._localMonsterController = dependencies and dependencies.LocalMonsterController or nil
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    self:_preloadPresentationAssets()
    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEvents = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    local nukeEvent = battleEvents:WaitForChild(RemoteNames.Battle.NukeCinematic)
    table.insert(self._connections, nukeEvent.OnClientEvent:Connect(function(payload)
        self:_playCinematic(payload)
    end))
end

return NukeCinematicController
