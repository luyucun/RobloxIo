--[[
脚本名字: ClientEventController
脚本文件: ClientEventController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/ClientEventController
说明: 统一接收服务端下发的客户端事件，避免未监听 RemoteEvent 导致调用队列堆积。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
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
        "[ClientEventController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local GameConfig = requireSharedModule("GameConfig")

local ClientEventController = {}

ClientEventController._localPlayer = nil
ClientEventController._connections = {}
ClientEventController._renderConnection = nil
ClientEventController._latestPlayerState = nil
ClientEventController._latestLeaderboard = nil
ClientEventController._latestFeedbackByName = {}
ClientEventController._localOrbFolder = nil
ClientEventController._localOrbs = {}
ClientEventController._audioSettings = nil
ClientEventController._perfStats = nil
ClientEventController._nextPerfLogClock = 0

local LEVEL_UP_TEXT_SLIDE_OFFSET = UDim2.fromScale(0, 0.35)
local LEVEL_UP_TEXT_TWEEN_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local EXPERIENCE_FALLBACK_COLORS = {
    Color3.fromRGB(226, 61, 48),
    Color3.fromRGB(255, 214, 58),
    Color3.fromRGB(54, 126, 255),
    Color3.fromRGB(74, 205, 86),
}

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function connectEvent(connections, event, callback)
    if not (event and event:IsA("RemoteEvent")) then
        return
    end
    table.insert(connections, event.OnClientEvent:Connect(callback))
end

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function countDescendants(instance)
    if not instance then
        return 0
    end

    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    return ok and #descendants or 0
end

local function findOrCreateLocalFolder(parent, folderName)
    local folder = parent:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
end

local function resolveExperienceTemplates()
    local modelRoot = ReplicatedStorage:FindFirstChild(GameConfig.EXPERIENCE.ModelRootFolderName)
    local itemFolder = modelRoot and modelRoot:FindFirstChild(GameConfig.EXPERIENCE.ItemFolderName)
    local templateFolderName = GameConfig.EXPERIENCE.TemplateFolderName or "ExperienceBlocks"
    local templateFolder = itemFolder and itemFolder:FindFirstChild(templateFolderName)
    local templates = {}
    if templateFolder then
        for _, child in ipairs(templateFolder:GetChildren()) do
            if child:IsA("BasePart") then
                table.insert(templates, child)
            end
        end
    end
    if #templates > 0 then
        table.sort(templates, function(a, b)
            return a.Name < b.Name
        end)
        return templates
    end

    local templateName = GameConfig.EXPERIENCE.TemplateName or "ExperienceOrb"
    local template = itemFolder and itemFolder:FindFirstChild(templateName)
    if template and template:IsA("BasePart") then
        return { template }
    end
    return {}
end

local function stripScripts(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        end
    end
end

local function createFallbackOrbPart()
    local orb = Instance.new("Part")
    orb.Name = "ExperienceBlockFallback"
    orb.Shape = Enum.PartType.Block
    orb.Material = Enum.Material.SmoothPlastic
    orb.Color = EXPERIENCE_FALLBACK_COLORS[math.random(1, #EXPERIENCE_FALLBACK_COLORS)]
    orb.Size = Vector3.new(0.9, 0.9, 0.9)
    orb.Anchored = true
    orb.CanCollide = false
    orb.CanTouch = false
    orb.CanQuery = false
    orb.Massless = true
    return orb
end

local function createLocalOrbPart(template)
    local orb = template and template:Clone() or createFallbackOrbPart()
    stripScripts(orb)
    orb.Anchored = true
    orb.CanCollide = false
    orb.CanTouch = false
    orb.CanQuery = false
    orb.Massless = true
    return orb
end

local function attachOrbTrail(orb)
    if not orb or not orb:IsA("BasePart") then
        return
    end
    if GameConfig.EXPERIENCE and GameConfig.EXPERIENCE.LocalOrbTrailEnabled == false then
        return
    end

    local halfY = orb.Size.Y * 0.5
    local frontAttachment = Instance.new("Attachment")
    frontAttachment.Name = "OrbTrailFront"
    frontAttachment.Position = Vector3.new(0, halfY * 0.45, 0)
    frontAttachment.Parent = orb

    local backAttachment = Instance.new("Attachment")
    backAttachment.Name = "OrbTrailBack"
    backAttachment.Position = Vector3.new(0, -halfY * 0.45, 0)
    backAttachment.Parent = orb

    local trail = Instance.new("Trail")
    trail.Name = "OrbHomingTrail"
    trail.Attachment0 = frontAttachment
    trail.Attachment1 = backAttachment
    trail.Enabled = false
    trail.FaceCamera = true
    trail.LightEmission = 0.8
    trail.Lifetime = math.max(0.05, tonumber(GameConfig.EXPERIENCE.TrailLifetime) or 0.28)
    trail.MinLength = 0.05
    trail.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.1),
        NumberSequenceKeypoint.new(1, 1),
    })
    local width = math.max(0.05, tonumber(GameConfig.EXPERIENCE.TrailWidth) or 0.45)
    trail.WidthScale = NumberSequence.new({
        NumberSequenceKeypoint.new(0, width),
        NumberSequenceKeypoint.new(1, 0),
    })
    trail.Color = ColorSequence.new(orb.Color)
    trail.Parent = orb
end

local function getMaxLocalVisualOrbsPerDrop()
    return math.max(0, math.floor(tonumber(GameConfig.EXPERIENCE and GameConfig.EXPERIENCE.MaxLocalVisualOrbsPerDrop) or 3))
end

local function getMaxLocalActiveOrbs()
    return math.max(0, math.floor(tonumber(GameConfig.EXPERIENCE and GameConfig.EXPERIENCE.MaxLocalActiveOrbs) or 45))
end

local function getLocalOrbMaxLifetimeSeconds()
    return math.max(0.5, tonumber(GameConfig.EXPERIENCE and GameConfig.EXPERIENCE.LocalOrbMaxLifetimeSeconds) or 5)
end

local function getCharacterRoot(player)
    local character = player and player.Character
    if not character then
        return nil
    end
    return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

local function getCharacterFootY(character, rootPart)
    if not (character and rootPart) then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        return rootPart.Position.Y - humanoid.HipHeight - (rootPart.Size.Y * 0.5)
    end

    local minY = nil
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local bottomY = descendant.Position.Y - (descendant.Size.Y * 0.5)
            minY = minY and math.min(minY, bottomY) or bottomY
        end
    end
    return minY
end

local function getAudioSound(soundName, soundId)
    local audioConfig = GameConfig.AUDIO or {}
    local audioFolder = SoundService:FindFirstChild(audioConfig.FolderName or "Audio")
    local sound = audioFolder and audioFolder:FindFirstChild(soundName)
    if sound and sound:IsA("Sound") then
        if soundId and soundId ~= "" then
            sound.SoundId = soundId
        end
        return sound
    end
    return nil
end

local function findSoundByPath(root, soundPath)
    if not (root and type(soundPath) == "table" and #soundPath > 0) then
        return nil
    end

    local current = root
    for index = 1, #soundPath - 1 do
        current = current:FindFirstChild(soundPath[index])
        if not current then
            return nil
        end
    end

    local soundName = soundPath[#soundPath]
    local direct = current and current:FindFirstChild(soundName)
    if direct and direct:IsA("Sound") then
        return direct
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("Sound") and descendant.Name == soundName then
            return descendant
        end
    end

    return nil
end

function ClientEventController:_recordFeedback(eventName, payload)
    self._latestFeedbackByName[eventName] = payload
    self:_addPerfStat("FeedbackEvents")
    self:_addPerfStat(tostring(eventName or "Unknown") .. "Events")
end

function ClientEventController:GetLatestPlayerState()
    return self._latestPlayerState
end

function ClientEventController:GetLatestLeaderboard()
    return self._latestLeaderboard
end

function ClientEventController:GetLatestFeedback(eventName)
    return self._latestFeedbackByName[eventName]
end

function ClientEventController:_createLocalOrbFolder()
    local runtimeRoot = findOrCreateLocalFolder(Workspace, "Runtime")
    local folderName = GameConfig.EXPERIENCE.RuntimeFolderName .. "_Client"
    local folder = findOrCreateLocalFolder(runtimeRoot, folderName)
    folder:ClearAllChildren()
    self._localOrbFolder = folder
    table.clear(self._localOrbs)
end

function ClientEventController:_destroyLocalOrbAt(index)
    local orbState = self._localOrbs[index]
    if not orbState then
        return
    end

    local orb = orbState.Instance
    if orb then
        orb:Destroy()
    end
    table.remove(self._localOrbs, index)
end

function ClientEventController:_trimLocalOrbsToBudget()
    local maxActiveOrbs = getMaxLocalActiveOrbs()
    while maxActiveOrbs >= 0 and #self._localOrbs > maxActiveOrbs do
        self:_addPerfStat("OrbsTrimmed")
        self:_destroyLocalOrbAt(1)
    end
end

function ClientEventController:_spawnExperienceDrop(payload)
    if not (payload and typeof(payload.orbs) == "table") then
        return
    end

    if not self._localOrbFolder then
        self:_createLocalOrbFolder()
    end

    local templates = resolveExperienceTemplates()
    local now = os.clock()
    local dropId = tostring(payload.dropId or now)
    local maxVisualOrbs = getMaxLocalVisualOrbsPerDrop()
    if maxVisualOrbs <= 0 then
        return
    end

    local spawnedCount = 0
    for _, orbPayload in ipairs(payload.orbs) do
        if spawnedCount >= maxVisualOrbs then
            break
        end
        local position = orbPayload.position
        if typeof(position) == "Vector3" then
            local template = nil
            if #templates > 0 then
                template = templates[math.random(1, #templates)]
            end
            local orb = createLocalOrbPart(template)
            orb.Name = string.format("ExperienceBlock_Client_%s_%02d", dropId, tonumber(orbPayload.index) or 0)
            attachOrbTrail(orb)
            local groundPosition = position
            local spawnPosition = groundPosition + Vector3.new(
                0,
                math.max(GameConfig.EXPERIENCE.SpawnHeightOffset, tonumber(GameConfig.EXPERIENCE.DropFallHeight) or 4),
                0
            )
            orb.CFrame = CFrame.new(spawnPosition)
            orb:SetAttribute("ExperienceValue", math.max(1, math.floor(tonumber(orbPayload.value) or 1)))
            orb.Parent = self._localOrbFolder

            local fallSeconds = math.max(0.05, tonumber(GameConfig.EXPERIENCE.DropFallSeconds) or 0.35)
            local settleSeconds = math.max(0, tonumber(GameConfig.EXPERIENCE.GroundSettleSeconds) or 0.25)
            table.insert(self._localOrbs, {
                Instance = orb,
                SpawnClock = now,
                ExpireClock = now + getLocalOrbMaxLifetimeSeconds(),
                FallEndClock = now + fallSeconds,
                HomingStartClock = now + fallSeconds + settleSeconds + math.max(0, tonumber(orbPayload.homingDelaySeconds) or GameConfig.EXPERIENCE.HomingDelaySeconds),
                HomingSpeed = math.max(1, tonumber(orbPayload.homingSpeed) or GameConfig.EXPERIENCE.HomingSpeed),
                ConsumeRadius = math.max(0.5, tonumber(orbPayload.homingConsumeRadius) or GameConfig.EXPERIENCE.HomingConsumeRadius),
                SpawnPosition = spawnPosition,
                GroundPosition = groundPosition,
                Drift = Vector3.new(
                    math.sin((tonumber(orbPayload.index) or 1) * 2.17) * 0.55,
                    0.8,
                    math.cos((tonumber(orbPayload.index) or 1) * 1.73) * 0.55
                ),
            })
            spawnedCount += 1
        end
    end
    self:_addPerfStat("ExperienceDrops")
    self:_addPerfStat("OrbsSpawned", spawnedCount)
    self:_trimLocalOrbsToBudget()
end

function ClientEventController:_updateLocalExperienceOrbs(deltaTime)
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    local rootPart = getCharacterRoot(self._localPlayer)
    local now = os.clock()
    local updatedCount = 0
    local destroyedCount = 0

    for index = #self._localOrbs, 1, -1 do
        local orbState = self._localOrbs[index]
        local orb = orbState.Instance
        if not (orb and orb.Parent) then
            table.remove(self._localOrbs, index)
            continue
        end
        if now >= (orbState.ExpireClock or math.huge) then
            self:_destroyLocalOrbAt(index)
            destroyedCount += 1
            continue
        end

        if now < orbState.FallEndClock then
            local duration = math.max(0.05, orbState.FallEndClock - orbState.SpawnClock)
            local alpha = math.clamp((now - orbState.SpawnClock) / duration, 0, 1)
            local easedAlpha = 1 - ((1 - alpha) * (1 - alpha))
            local position = orbState.SpawnPosition:Lerp(orbState.GroundPosition, easedAlpha)
            orb.CFrame = CFrame.new(position)
            updatedCount += 1
            continue
        end

        if now < orbState.HomingStartClock then
            local bob = math.sin((now - orbState.SpawnClock) * 7) * 0.04
            orb.CFrame = CFrame.new(orbState.GroundPosition + Vector3.new(0, bob, 0))
            updatedCount += 1
            continue
        end

        local trail = orb:FindFirstChild("OrbHomingTrail")
        if trail and trail:IsA("Trail") then
            trail.Enabled = true
        end

        if not rootPart then
            continue
        end

        local offset = rootPart.Position - orb.Position
        local distance = offset.Magnitude
        if distance <= orbState.ConsumeRadius then
            self:_destroyLocalOrbAt(index)
            destroyedCount += 1
        elseif distance > 0 then
            local speedMultiplier = 1 + math.clamp((now - orbState.HomingStartClock) * 1.25, 0, 3)
            local stepDistance = math.min(distance, orbState.HomingSpeed * speedMultiplier * deltaTime)
            orb.CFrame = CFrame.new(orb.Position + (offset.Unit * stepDistance))
            updatedCount += 1
        end
    end

    if startedAt then
        self:_addPerfStat("RenderFrames")
        self:_addPerfStat("OrbSamples", #self._localOrbs)
        self:_addPerfStat("OrbUpdates", updatedCount)
        self:_addPerfStat("OrbsDestroyed", destroyedCount)
        self:_addPerfStat("UpdateElapsedSeconds", os.clock() - startedAt)
        self:_logPerfStats(os.clock())
    end
end

function ClientEventController:_resetPerfStats()
    self._perfStats = {
        RenderFrames = 0,
        OrbSamples = 0,
        OrbUpdates = 0,
        OrbsSpawned = 0,
        OrbsDestroyed = 0,
        OrbsTrimmed = 0,
        ExperienceDrops = 0,
        FeedbackEvents = 0,
        PlayerStateSyncEvents = 0,
        LevelUpFeedbackEvents = 0,
        ExperienceFeedbackEvents = 0,
        CombatFeedbackEvents = 0,
        UpdateElapsedSeconds = 0,
    }
end

function ClientEventController:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function ClientEventController:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats
    if stats and stats.RenderFrames and stats.RenderFrames > 0 then
        local folder = self._localOrbFolder
        print(string.format(
            "[Diag][ClientEventController] frames=%d localOrbs=%d orbFolderChildren=%d orbFolderDesc=%d orbSamples=%d orbUpdates=%d spawned=%d destroyed=%d trimmed=%d drops=%d feedback=%d playerState=%d levelUp=%d experience=%d combat=%d updateMs=%.3f",
            stats.RenderFrames,
            #self._localOrbs,
            folder and #folder:GetChildren() or 0,
            countDescendants(folder),
            stats.OrbSamples or 0,
            stats.OrbUpdates or 0,
            stats.OrbsSpawned or 0,
            stats.OrbsDestroyed or 0,
            stats.OrbsTrimmed or 0,
            stats.ExperienceDrops or 0,
            stats.FeedbackEvents or 0,
            stats.PlayerStateSyncEvents or 0,
            stats.LevelUpFeedbackEvents or 0,
            stats.ExperienceFeedbackEvents or 0,
            stats.CombatFeedbackEvents or 0,
            (stats.UpdateElapsedSeconds or 0) * 1000
        ))
    end

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function ClientEventController:_playSound(soundName, soundId)
    local sound = getAudioSound(soundName, soundId)
    if not sound then
        return
    end

    if self._audioSettings and self._audioSettings.PlaySfx then
        self._audioSettings:PlaySfx(sound, true)
        return
    end

    sound:Stop()
    sound.TimePosition = 0
    sound:Play()
end

function ClientEventController:_playSfxByPath(folderName, soundPath)
    if self._audioSettings and self._audioSettings.PlaySfxByPath then
        self._audioSettings:PlaySfxByPath(folderName, soundPath, true)
        return
    end

    local folder = SoundService:FindFirstChild(folderName) or SoundService:FindFirstChild(folderName, true)
    local sound = findSoundByPath(folder, soundPath)
    if sound then
        sound:Stop()
        sound.TimePosition = 0
        sound:Play()
    end
end

function ClientEventController:_playCombatFeedbackSound(payload)
    if type(payload) ~= "table" then
        return
    end

    local sourceUserId = tonumber(payload.sourceUserId)
    if not (self._localPlayer and sourceUserId and sourceUserId == self._localPlayer.UserId) then
        return
    end

    if payload.eventType == "WeaponHitWeapon" then
        self:_playSfxByPath("Audio", { "Sword", "Sword Hit" })
    elseif payload.eventType == "WeaponHitPlayer" then
        self:_playSfxByPath("Audio", { "Sword", "SwordHitRelease" })
    end
end

local function animateLevelUpText(effect)
    local billboard = effect:FindFirstChild("Billboard", true)
    local bg = billboard and billboard:FindFirstChild("Bg")
    local label = bg and bg:FindFirstChild("LevelUp")
    if not (label and label:IsA("TextLabel")) then
        return
    end

    local originalPosition = label.Position
    local originalTextTransparency = label.TextTransparency
    local stroke = label:FindFirstChildWhichIsA("UIStroke")
    local originalStrokeTransparency = stroke and stroke.Transparency or nil

    label.Position = UDim2.new(
        originalPosition.X.Scale + LEVEL_UP_TEXT_SLIDE_OFFSET.X.Scale,
        originalPosition.X.Offset + LEVEL_UP_TEXT_SLIDE_OFFSET.X.Offset,
        originalPosition.Y.Scale + LEVEL_UP_TEXT_SLIDE_OFFSET.Y.Scale,
        originalPosition.Y.Offset + LEVEL_UP_TEXT_SLIDE_OFFSET.Y.Offset
    )
    label.TextTransparency = 1
    if stroke then
        stroke.Transparency = 1
    end

    TweenService:Create(label, LEVEL_UP_TEXT_TWEEN_INFO, {
        Position = originalPosition,
        TextTransparency = originalTextTransparency,
    }):Play()

    if stroke then
        TweenService:Create(stroke, LEVEL_UP_TEXT_TWEEN_INFO, {
            Transparency = originalStrokeTransparency,
        }):Play()
    end
end

function ClientEventController:_spawnLevelUpEffect()
    local character = self._localPlayer and self._localPlayer.Character
    local rootPart = getCharacterRoot(self._localPlayer)
    local effectConfig = GameConfig.LEVEL_UP_EFFECT or {}
    local templateName = effectConfig.TemplateName or "LevelUp"
    local template = ReplicatedStorage:FindFirstChild(templateName)
    if not (character and rootPart and template and template:IsA("BasePart")) then
        return
    end

    local effect = template:Clone()
    effect.Name = "LevelUpEffect_Client"
    effect.Anchored = false
    effect.CanCollide = false
    effect.CanTouch = false
    effect.CanQuery = false
    effect.Massless = true
    local originalEffectCFrame = effect.CFrame
    local footY = getCharacterFootY(character, rootPart) or (rootPart.Position.Y - (rootPart.Size.Y * 0.5))
    local effectCenterY = footY + (effect.Size.Y * 0.5)
    local effectOffset = effectConfig.AttachOffset or Vector3.zero
    local targetPosition = Vector3.new(rootPart.Position.X, effectCenterY, rootPart.Position.Z) + effectOffset
    local targetEffectCFrame = CFrame.new(targetPosition) * rootPart.CFrame.Rotation
    effect.CFrame = targetEffectCFrame

    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local relativeCFrame = originalEffectCFrame:ToObjectSpace(descendant.CFrame)
            descendant.CFrame = targetEffectCFrame * relativeCFrame
            descendant.Anchored = false
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.Massless = true
            local descendantWeld = Instance.new("WeldConstraint")
            descendantWeld.Name = "LevelUpEffectPartWeld"
            descendantWeld.Part0 = effect
            descendantWeld.Part1 = descendant
            descendantWeld.Parent = descendant
        elseif descendant:IsA("ParticleEmitter") then
            descendant.Enabled = true
            local emitCount = tonumber(descendant:GetAttribute("EmitCount"))
            if emitCount and emitCount > 0 then
                descendant:Emit(emitCount)
            end
        elseif descendant:IsA("BillboardGui") then
            descendant.Enabled = true
        end
    end

    local weld = Instance.new("WeldConstraint")
    weld.Name = "LevelUpEffectWeld"
    weld.Part0 = rootPart
    weld.Part1 = effect
    weld.Parent = effect

    effect.Parent = character
    animateLevelUpText(effect)

    task.delay(math.max(0.1, tonumber(effectConfig.DurationSeconds) or 3), function()
        if effect and effect.Parent then
            effect:Destroy()
        end
    end)
end

function ClientEventController:_playLevelUpFeedback()
    local audioConfig = GameConfig.AUDIO or {}
    self:_spawnLevelUpEffect()
    self:_playSound(audioConfig.LevelUpSoundName or "LevelUp01", audioConfig.LevelUpSoundId or "rbxassetid://371274037")
end

function ClientEventController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or nil
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil
    disconnectAll(self._connections)
    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end
    self:_createLocalOrbFolder()
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()

    if self._audioSettings and self._audioSettings.BindPlayerGuiButtonClicks and self._localPlayer then
        local playerGui = self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10)
        if playerGui then
            self._audioSettings:BindPlayerGuiButtonClicks(playerGui)
        end
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local battleEventsFolder = eventsFolder:WaitForChild(RemoteNames.BattleEventsFolder)

    connectEvent(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync), function(payload)
        self._latestPlayerState = payload
    end)

    connectEvent(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.ArenaTransitionFeedback), function(payload)
        self:_recordFeedback("ArenaTransitionFeedback", payload)
    end)

    connectEvent(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.DeathFeedback), function(payload)
        self:_recordFeedback("DeathFeedback", payload)
    end)

    connectEvent(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.LevelUpFeedback), function(payload)
        self:_recordFeedback("LevelUpFeedback", payload)
        self:_playLevelUpFeedback()
    end)

    connectEvent(self._connections, systemEventsFolder:WaitForChild(RemoteNames.System.PotionFeedback), function(payload)
        self:_recordFeedback("PotionFeedback", payload)
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.PickupFeedback), function(payload)
        self:_recordFeedback("PickupFeedback", payload)
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.ExperienceFeedback), function(payload)
        self:_recordFeedback("ExperienceFeedback", payload)
        if payload and payload.eventType == "ExperienceDrop" then
            self:_spawnExperienceDrop(payload)
        end
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.CombatFeedback), function(payload)
        self:_recordFeedback("CombatFeedback", payload)
        self:_playCombatFeedbackSound(payload)
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.BuffFeedback), function(payload)
        self:_recordFeedback("BuffFeedback", payload)
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.BossFeedback), function(payload)
        self:_recordFeedback("BossFeedback", payload)
    end)

    connectEvent(self._connections, battleEventsFolder:WaitForChild(RemoteNames.Battle.LeaderboardSync), function(payload)
        self._latestLeaderboard = payload
    end)

    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        requestStateSyncEvent:FireServer()
    end

    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        self:_updateLocalExperienceOrbs(deltaTime)
    end)
end

return ClientEventController
