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
local TweenService = game:GetService("TweenService")
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
        "[NukeCinematicController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

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
NukeCinematicController._cameraState = nil

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

local function makeArchivable(root)
    if not root then
        return
    end
    root.Archivable = true
    for _, descendant in ipairs(root:GetDescendants()) do
        descendant.Archivable = true
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
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
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

local function tweenGuiAlpha(state, alpha, duration)
    local tweenInfo = TweenInfo.new(math.max(0.01, duration), Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tweens = {}
    for instance, original in pairs(state) do
        if instance and instance.Parent then
            local goals = {}
            if instance:IsA("GuiObject") then
                if original.BackgroundTransparency ~= nil then
                    goals.BackgroundTransparency = original.BackgroundTransparency + ((1 - original.BackgroundTransparency) * alpha)
                end
                if original.TextTransparency ~= nil then
                    goals.TextTransparency = original.TextTransparency + ((1 - original.TextTransparency) * alpha)
                end
                if original.TextStrokeTransparency ~= nil then
                    goals.TextStrokeTransparency = original.TextStrokeTransparency + ((1 - original.TextStrokeTransparency) * alpha)
                end
                if original.ImageTransparency ~= nil then
                    goals.ImageTransparency = original.ImageTransparency + ((1 - original.ImageTransparency) * alpha)
                end
            elseif instance:IsA("UIStroke") and original.Transparency ~= nil then
                goals.Transparency = original.Transparency + ((1 - original.Transparency) * alpha)
            end
            if next(goals) then
                local tween = TweenService:Create(instance, tweenInfo, goals)
                table.insert(tweens, tween)
                tween:Play()
            end
        end
    end
    task.wait(math.max(0, duration))
    for _, tween in ipairs(tweens) do
        tween:Cancel()
    end
    applyGuiAlpha(state, alpha)
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

local function getEffectBoundsSize(effect)
    local minCorner = nil
    local maxCorner = nil

    local function includePoint(point)
        if not minCorner then
            minCorner = point
            maxCorner = point
            return
        end
        minCorner = Vector3.new(
            math.min(minCorner.X, point.X),
            math.min(minCorner.Y, point.Y),
            math.min(minCorner.Z, point.Z)
        )
        maxCorner = Vector3.new(
            math.max(maxCorner.X, point.X),
            math.max(maxCorner.Y, point.Y),
            math.max(maxCorner.Z, point.Z)
        )
    end

    local function includePart(part)
        local halfSize = part.Size * 0.5
        for _, x in ipairs({ -1, 1 }) do
            for _, y in ipairs({ -1, 1 }) do
                for _, z in ipairs({ -1, 1 }) do
                    includePoint(part.CFrame:PointToWorldSpace(Vector3.new(halfSize.X * x, halfSize.Y * y, halfSize.Z * z)))
                end
            end
        end
    end

    if effect:IsA("BasePart") then
        includePart(effect)
    end
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            includePart(descendant)
        end
    end

    return minCorner and (maxCorner - minCorner) or Vector3.one
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

local function getExplosionTargetScale(effect)
    local boundsSize = getEffectBoundsSize(effect)
    local baseDiameter = math.max(boundsSize.X, boundsSize.Z, 1)
    local fallbackRadius = tonumber(GameConfig.NUKE.ExplosionCoverageRadius) or 320
    local battlePart = getBattlePart()
    local coverageRadius = fallbackRadius
    if battlePart then
        local size = battlePart.Size
        local halfDiagonal = math.sqrt((size.X * size.X) + (size.Z * size.Z)) * 0.5
        coverageRadius = math.max(fallbackRadius, halfDiagonal + 35)
    end
    return math.max(1, (coverageRadius * 2) / baseDiameter)
end

local function startExplosionExpansion(effect, durationSeconds)
    if not (effect and effect.root and effect.scaleState) then
        return
    end

    local root = effect.root
    local targetScale = effect.targetScale or 1
    local duration = math.max(0.05, tonumber(durationSeconds) or GameConfig.NUKE.ExplosionSeconds or 2.5)
    local power = math.max(1, tonumber(GameConfig.NUKE.ExplosionExpandPower) or 2.35)

    applyEffectScale(effect.scaleState, 1)
    task.spawn(function()
        local startClock = os.clock()
        while root.Parent do
            local alpha = math.clamp((os.clock() - startClock) / duration, 0, 1)
            local easedAlpha = math.pow(alpha, power)
            local scale = 1 + ((targetScale - 1) * easedAlpha)
            applyEffectScale(effect.scaleState, scale)
            if alpha >= 1 then
                break
            end
            RunService.RenderStepped:Wait()
        end
    end)
end

local function prepareEffectInstance(effect)
    if effect:IsA("BasePart") then
        effect.Anchored = true
        effect.CanCollide = false
        effect.CanTouch = false
        effect.CanQuery = false
    end
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.Massless = true
        end
    end
end

local function createExplosionVfx(position, durationSeconds, audioSettings)
    local template = getBombEffectTemplate()
    if not template then
        warn("[NukeCinematicController] Missing ReplicatedStorage/Effect/Bomb explosion effect")
        return nil
    end

    makeArchivable(template)
    local effect = template:Clone()
    effect.Name = "NukeBombEffect"
    prepareEffectInstance(effect)
    translateEffect(effect, position)
    effect.Parent = Workspace
    local scaleState = captureEffectScaleState(effect)
    local targetScale = getExplosionTargetScale(effect)

    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("ParticleEmitter") then
            local emitCount = tonumber(descendant:GetAttribute("EmitCount"))
            local emitDelay = tonumber(descendant:GetAttribute("EmitDelay")) or 0
            if emitCount and emitCount > 0 then
                task.delay(emitDelay, function()
                    if descendant.Parent then
                        descendant:Emit(emitCount)
                    end
                end)
            end
        elseif descendant:IsA("Sound") then
            if audioSettings and audioSettings.PlaySfx then
                audioSettings:PlaySfx(descendant, false)
            else
                descendant:Play()
            end
        end
    end

    local vfx = {
        root = effect,
        scaleState = scaleState,
        targetScale = targetScale,
    }
    startExplosionExpansion(vfx, durationSeconds)
    return vfx
end

local function playAudioSound(soundName, soundId, audioSettings)
    local audioConfig = GameConfig.AUDIO or {}
    local audioFolder = game:GetService("SoundService"):FindFirstChild(audioConfig.FolderName or "Audio")
    local sound = audioFolder and audioFolder:FindFirstChild(soundName)
    if sound and sound:IsA("Sound") then
        if soundId and soundId ~= "" then
            sound.SoundId = soundId
        end
        if audioSettings and audioSettings.PlaySfx then
            audioSettings:PlaySfx(sound, true)
            return
        end
        sound:Stop()
        sound.TimePosition = 0
        sound:Play()
    end
end

local function stopExplosionVfx(effect)
    if not (effect and effect.root) then
        return
    end

    local root = effect.root
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
            descendant.Enabled = false
        elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
            descendant.Enabled = false
        elseif descendant:IsA("Sound") then
            descendant:Stop()
        end
    end
end

local function destroyExplosionVfx(effect)
    if effect and effect.root then
        effect.root:Destroy()
    end
end

function NukeCinematicController:_captureCameraState()
    local camera = Workspace.CurrentCamera
    if not camera then
        return nil
    end

    return {
        camera = camera,
        cameraType = camera.CameraType,
        cameraSubject = camera.CameraSubject,
        cframe = camera.CFrame,
        focus = camera.Focus,
        fieldOfView = camera.FieldOfView,
        lightingClockTime = Lighting.ClockTime,
    }
end

function NukeCinematicController:_restoreCameraOnly()
    local state = self._cameraState
    local camera = (state and state.camera) or Workspace.CurrentCamera
    if not camera then
        return
    end

    camera.CameraType = state and state.cameraType or Enum.CameraType.Custom
    camera.CameraSubject = (state and state.cameraSubject) or getCharacterHumanoid(self._localPlayer)
    if state and state.cframe then
        camera.CFrame = state.cframe
    end
    if state and state.focus then
        camera.Focus = state.focus
    end
    if state and state.fieldOfView then
        camera.FieldOfView = state.fieldOfView
    end
end

function NukeCinematicController:_restoreLightingOnly()
    local state = self._cameraState
    Lighting.ClockTime = (state and state.lightingClockTime) or GameConfig.NUKE.RestoreClockTime or 14.5
    self._cameraState = nil
end

function NukeCinematicController:_restoreAll()
    self:_restoreCameraOnly()
    self:_restoreLightingOnly()
end

function NukeCinematicController:_waitForSession(sessionId, durationSeconds)
    local endClock = os.clock() + math.max(0, tonumber(durationSeconds) or 0)
    while os.clock() < endClock do
        if sessionId ~= self._activeSessionId then
            return false
        end
        task.wait(math.min(0.05, math.max(0, endClock - os.clock())))
    end
    return sessionId == self._activeSessionId
end

local function getNukeCallerName(payload)
    local name = payload and (payload.ownerDisplayName or payload.ownerName)
    if type(name) ~= "string" or name == "" then
        return "Someone"
    end
    return name
end

function NukeCinematicController:_showNukeBanner(root, durationSeconds, sessionId, payload)
    if not (root and root:IsA("GuiObject")) then
        return true
    end

    local textLabel = root:FindFirstChild("Text")
    if textLabel and (textLabel:IsA("TextLabel") or textLabel:IsA("TextButton") or textLabel:IsA("TextBox")) then
        textLabel.Text = string.format("%s called in a nuke.", getNukeCallerName(payload))
    end

    local wasVisible = root.Visible
    local state = collectGuiTransparencyState(root)
    setGuiZIndex(root, state, math.max(1, math.floor(tonumber(GameConfig.NUKE.PreludeZIndex) or 100)))
    root.Visible = true
    applyGuiAlpha(state, 0)

    local completed = self:_waitForSession(sessionId, durationSeconds)
    restoreGuiState(state)
    root.Visible = wasVisible
    return completed
end

function NukeCinematicController:_flashWarning(root, sessionId, flashCount, fadeInSeconds, holdSeconds, fadeOutSeconds, gapSeconds)
    if not (root and root:IsA("GuiObject")) then
        return true
    end

    local wasVisible = root.Visible
    local state = collectGuiTransparencyState(root)
    setGuiZIndex(root, state, math.max(1, math.floor(tonumber(GameConfig.NUKE.PreludeZIndex) or 100)))
    root.Visible = true
    applyGuiAlpha(state, 1)

    local completed = true
    local normalizedFlashCount = math.max(0, math.floor(tonumber(flashCount) or 0))
    for index = 1, normalizedFlashCount do
        if sessionId ~= self._activeSessionId then
            completed = false
            break
        end
        tweenGuiAlpha(state, 0, fadeInSeconds)
        if not self:_waitForSession(sessionId, holdSeconds) then
            completed = false
            break
        end
        tweenGuiAlpha(state, 1, fadeOutSeconds)
        if index < normalizedFlashCount and not self:_waitForSession(sessionId, gapSeconds) then
            completed = false
            break
        end
    end

    restoreGuiState(state)
    root.Visible = wasVisible
    return completed
end

function NukeCinematicController:_playPrelude(payload, sessionId)
    local mainGui = getMainGui(self._localPlayer)
    if not mainGui then
        return true
    end

    local nukeBanner = mainGui:FindFirstChild("Nuke")
    local warning = mainGui:FindFirstChild("Warning")
    local bannerSeconds = math.max(0, tonumber(payload and payload.nukeBannerSeconds) or GameConfig.NUKE.NukeBannerSeconds or 2)
    local flashCount = math.max(0, math.floor(tonumber(payload and payload.warningFlashCount) or GameConfig.NUKE.WarningFlashCount or 3))
    local fadeInSeconds = math.max(0, tonumber(payload and payload.warningFadeInSeconds) or GameConfig.NUKE.WarningFadeInSeconds or 0.25)
    local holdSeconds = math.max(0, tonumber(payload and payload.warningHoldSeconds) or GameConfig.NUKE.WarningHoldSeconds or 0.35)
    local fadeOutSeconds = math.max(0, tonumber(payload and payload.warningFadeOutSeconds) or GameConfig.NUKE.WarningFadeOutSeconds or 0.25)
    local gapSeconds = math.max(0, tonumber(payload and payload.warningGapSeconds) or GameConfig.NUKE.WarningGapSeconds or 0.1)

    if bannerSeconds > 0 and not self:_showNukeBanner(nukeBanner, bannerSeconds, sessionId, payload) then
        return false
    end
    return self:_flashWarning(warning, sessionId, flashCount, fadeInSeconds, holdSeconds, fadeOutSeconds, gapSeconds)
end

function NukeCinematicController:_sweepLocalMonstersForNuke(payload)
    if not (payload and tonumber(payload.ownerUserId) == self._localPlayer.UserId) then
        return
    end
    if self._localMonsterController and self._localMonsterController.SweepForNuke then
        self._localMonsterController:SweepForNuke(payload.sessionId)
    end
end

function NukeCinematicController:_buildCameraTrack()
    local function isCameraTrack(track)
        local cameraItem = track and track:FindFirstChild("2")
        local cframeFolder = cameraItem and cameraItem:FindFirstChild("CFrame")
        return cframeFolder ~= nil
    end

    local assets = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.AssetFolderName)
        or ReplicatedStorage:WaitForChild(GameConfig.NUKE.AssetFolderName, 3)
    local cameraFolder = assets and (
        assets:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName)
        or assets:WaitForChild(GameConfig.NUKE.CameraAnimatorFolderName, 3)
    )
    if cameraFolder then
        local track = cameraFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
            or cameraFolder:WaitForChild(GameConfig.NUKE.CameraTrackName, 3)
        if isCameraTrack(track) then
            return track
        end
    end

    local replicatedCameraFolder = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName)
    local replicatedTrack = replicatedCameraFolder and replicatedCameraFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
    if isCameraTrack(replicatedTrack) then
        return replicatedTrack
    end

    local sourceModel = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    local sourceCameraFolder = sourceModel and sourceModel:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName, true)
    local sourceTrack = sourceCameraFolder and sourceCameraFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
    if isCameraTrack(sourceTrack) then
        return sourceTrack
    end

    warn("[NukeCinematicController] Missing valid MoonAnimator2 camera track for nuke fall")
    return nil
end

function NukeCinematicController:_buildLittleBoy(initialCFrame)
    local template = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    if not (template and template:IsA("Model")) then
        local assets = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.AssetFolderName)
            or ReplicatedStorage:WaitForChild(GameConfig.NUKE.AssetFolderName, 1.5)
        template = assets and (
            assets:FindFirstChild(GameConfig.NUKE.LittleBoyTemplateName)
            or assets:WaitForChild(GameConfig.NUKE.LittleBoyTemplateName, 1.5)
        )
    end
    if not (template and template:IsA("Model")) then
        return nil
    end

    makeArchivable(template)
    local clone = template:Clone()
    local rootPart = getRootPart(clone)
    if rootPart then
        clone.PrimaryPart = rootPart
    end
    setNonInteractive(clone)
    clone:SetAttribute("NukeOriginalPivotPosition", clone:GetPivot().Position)
    if initialCFrame then
        clone:PivotTo(initialCFrame)
    end
    clone.Parent = Workspace
    return clone
end

function NukeCinematicController:_playLittleBoyAnimation(littleBoy, animationId)
    local animator = ensureAnimator(littleBoy)
    if not animator then
        return nil
    end

    local animation = Instance.new("Animation")
    animation.AnimationId = tostring(animationId or GameConfig.NUKE.IdleAnimationId)

    local track = nil
    local ok = pcall(function()
        track = animator:LoadAnimation(animation)
    end)
    animation:Destroy()

    if ok and track then
        track.Looped = true
        track.Priority = Enum.AnimationPriority.Action
        track:Play(0.1)
        return track
    end
    return nil
end

function NukeCinematicController:_startFallbackSpin(littleBoy, sessionId)
    local rootPart = getRootPart(littleBoy)
    local spinMotor = rootPart and rootPart:FindFirstChild("Union1")
    if not (spinMotor and spinMotor:IsA("Motor6D")) then
        return nil
    end

    local startClock = os.clock()
    local connection
    connection = RunService.RenderStepped:Connect(function()
        if sessionId ~= self._activeSessionId or not (littleBoy and littleBoy.Parent) then
            if connection then
                connection:Disconnect()
            end
            return
        end
        local elapsed = os.clock() - startClock
        spinMotor.Transform = CFrame.Angles(0, elapsed * math.pi * 2.6, 0)
    end)
    return connection
end

function NukeCinematicController:_runFall(camera, littleBoy, battleCenter, fallHeight, durationSeconds)
    local startPosition = battleCenter + Vector3.new(0, fallHeight, 0)
    local recordedPivotPosition = littleBoy and littleBoy:GetAttribute("NukeOriginalPivotPosition") or nil
    if typeof(recordedPivotPosition) ~= "Vector3" then
        recordedPivotPosition = littleBoy and littleBoy:GetPivot().Position or startPosition
    end
    local cameraShift = CFrame.new(startPosition - recordedPivotPosition)
    local keyframes = littleBoy and readCameraKeyframes(self:_buildCameraTrack()) or nil
    local lastCameraCFrame = nil

    if littleBoy then
        littleBoy:PivotTo(CFrame.new(startPosition))
    end

    local startClock = os.clock()
    while os.clock() - startClock < durationSeconds do
        local alpha = math.clamp((os.clock() - startClock) / durationSeconds, 0, 1)
        local nukePosition = startPosition:Lerp(battleCenter, alpha)

        if littleBoy and littleBoy.Parent then
            littleBoy:PivotTo(CFrame.new(nukePosition))
        end

        camera.CameraType = Enum.CameraType.Scriptable
        local sampledCamera = sampleCameraKeyframes(keyframes, alpha)
        if sampledCamera then
            camera.CFrame = cameraShift * sampledCamera
        else
            camera.CFrame = CFrame.lookAt(nukePosition + Vector3.new(0, 20, 45), nukePosition)
        end
        lastCameraCFrame = camera.CFrame
        camera.Focus = CFrame.new(nukePosition)

        RunService.RenderStepped:Wait()
    end

    if littleBoy and littleBoy.Parent then
        littleBoy:PivotTo(CFrame.new(battleCenter))
    end
    return lastCameraCFrame or CFrame.lookAt(battleCenter + Vector3.new(0, 20, 45), battleCenter)
end

function NukeCinematicController:_holdExplosionCamera(camera, battleCenter, cameraCFrame, durationSeconds, sessionId)
    local cameraPosition = cameraCFrame and cameraCFrame.Position or (battleCenter + Vector3.new(0, 24, 54))
    local startClock = os.clock()
    while os.clock() - startClock < durationSeconds do
        if sessionId ~= self._activeSessionId then
            break
        end
        camera.CameraType = Enum.CameraType.Scriptable
        camera.CFrame = CFrame.lookAt(cameraPosition, battleCenter + Vector3.new(0, 12, 0))
        camera.Focus = CFrame.new(battleCenter)
        RunService.RenderStepped:Wait()
    end
end

function NukeCinematicController:_playCinematic(payload)
    local sessionId = tonumber(payload and payload.sessionId) or (self._activeSessionId + 1)
    self._activeSessionId = sessionId

    task.spawn(function()
        local startDelaySeconds = math.max(0, tonumber(payload and payload.startDelaySeconds) or 0)
        if startDelaySeconds > 0 then
            task.wait(startDelaySeconds)
        end
        if sessionId ~= self._activeSessionId then
            return
        end
        if not self:_playPrelude(payload, sessionId) then
            return
        end

        self._cameraState = self:_captureCameraState()
        local camera = Workspace.CurrentCamera
        if not camera then
            return
        end

        local battleCenter = parseBattleCenter(payload)
        local bombPoint = getBombPoint()
        if bombPoint then
            battleCenter = bombPoint.Position
        end
        local fallHeight = math.max(10, tonumber(payload and payload.fallHeight) or GameConfig.NUKE.FallHeight or 120)
        local fallSeconds = math.max(0.1, tonumber(payload and payload.fallSeconds) or GameConfig.NUKE.FallSeconds or 2.5)
        local explosionSeconds = math.max(0.1, tonumber(payload and payload.explosionSeconds) or GameConfig.NUKE.ExplosionSeconds or 3)

        local littleBoy = self:_buildLittleBoy(CFrame.new(battleCenter + Vector3.new(0, fallHeight, 0)))
        local animationTrack = littleBoy and self:_playLittleBoyAnimation(littleBoy, payload and payload.idleAnimationId) or nil
        local spinConnection = nil
        if littleBoy and not animationTrack then
            spinConnection = self:_startFallbackSpin(littleBoy, sessionId)
        end

        local explosionCameraCFrame = self:_runFall(camera, littleBoy, battleCenter, fallHeight, fallSeconds)

        if spinConnection then
            spinConnection:Disconnect()
        end
        if animationTrack then
            pcall(function()
                animationTrack:Stop(0.1)
                animationTrack:Destroy()
            end)
        end
        if littleBoy and littleBoy.Parent then
            littleBoy:Destroy()
        end

        Lighting.ClockTime = tonumber(payload and payload.lightingClockTime) or GameConfig.NUKE.LightingClockTime or 4
        self:_sweepLocalMonstersForNuke(payload)
        local effect = createExplosionVfx(battleCenter, explosionSeconds, self._audioSettings)
        local audioConfig = GameConfig.AUDIO or {}
        playAudioSound(audioConfig.BoomSoundName or "Boom", audioConfig.BoomSoundId or "rbxassetid://77970762255205", self._audioSettings)
        self:_holdExplosionCamera(camera, battleCenter, explosionCameraCFrame, explosionSeconds, sessionId)
        stopExplosionVfx(effect)
        task.wait(0.9)
        destroyExplosionVfx(effect)
        self:_restoreCameraOnly()
        self:_restoreLightingOnly()
    end)
end

function NukeCinematicController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._localMonsterController = dependencies and dependencies.LocalMonsterController or nil
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    disconnectAll(self._connections)

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEvents = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    local nukeEvent = battleEvents:WaitForChild(RemoteNames.Battle.NukeCinematic)

    table.insert(self._connections, nukeEvent.OnClientEvent:Connect(function(payload)
        self:_playCinematic(payload)
    end))
end

return NukeCinematicController
