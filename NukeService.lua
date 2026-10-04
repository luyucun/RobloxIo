--[[
Script name: NukeService
Type: ModuleScript
Studio path: ServerScriptService/Services/NukeService
Purpose: Orchestrates the paid LittleBoy nuke cinematic and server-side kills.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
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
        "[NukeService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local MonsterCatalog = requireSharedModule("MonsterCatalog")

local DEFAULT_NUKE_CONFIG = {
    AssetFolderName = "NukeAssets",
    SourceModelName = "LittleBoy",
    LittleBoyTemplateName = "LittleBoyTemplate",
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

local NukeService = {}

NukeService._playerStateService = nil
NukeService._healthService = nil
NukeService._arenaService = nil
NukeService._remoteEventService = nil
NukeService._monsterService = nil
NukeService._experienceOrbService = nil
NukeService._localMonsterRewardService = nil
NukeService._nukeCinematicEvent = nil
NukeService._nukeLocalMonsterSweepEvent = nil
NukeService._queue = {}
NukeService._localSweepSessions = {}
NukeService._isRunning = false
NukeService._loading = false
NukeService._littleBoyTemplate = nil
NukeService._cameraTrackSource = nil
NukeService._nukeAssetsFolder = nil
NukeService._clockTimeBackup = nil
NukeService._defaultClockTime = nil
NukeService._playSessionId = 0

local function getBattleCenterAndSurface(arenaService)
    local targetMapName = GameConfig.NUKE.TargetMapName or "Battle01"
    local bombPointName = GameConfig.NUKE.BombPointName or "BombPoint"
    local targetMap = Workspace:FindFirstChild(targetMapName)
    local bombPoint = targetMap and targetMap:FindFirstChild(bombPointName, true)
    if bombPoint and bombPoint:IsA("BasePart") then
        local position = bombPoint.Position
        return position, position.Y
    end

    local battlePart = arenaService and arenaService:GetBattlePart() or nil
    if not battlePart then
        return Vector3.new(0, 0, 0), 0
    end

    local center = battlePart.Position
    local surfaceY = battlePart.Position.Y + (battlePart.Size.Y * 0.5)
    return Vector3.new(center.X, surfaceY, center.Z), surfaceY
end

local function getNukePreludeSeconds()
    local flashCount = math.max(0, math.floor(tonumber(GameConfig.NUKE.WarningFlashCount) or 0))
    local fadeInSeconds = math.max(0, tonumber(GameConfig.NUKE.WarningFadeInSeconds) or 0)
    local holdSeconds = math.max(0, tonumber(GameConfig.NUKE.WarningHoldSeconds) or 0)
    local fadeOutSeconds = math.max(0, tonumber(GameConfig.NUKE.WarningFadeOutSeconds) or 0)
    local gapSeconds = math.max(0, tonumber(GameConfig.NUKE.WarningGapSeconds) or 0)
    local bannerSeconds = math.max(0, tonumber(GameConfig.NUKE.NukeBannerSeconds) or 0)
    return bannerSeconds
        + (flashCount * (fadeInSeconds + holdSeconds + fadeOutSeconds))
        + (math.max(0, flashCount - 1) * gapSeconds)
end

local function cloneAnimationTemplate(source)
    if not source then
        return nil
    end
    local clone = source:Clone()
    clone.Parent = nil
    return clone
end

local function findOrCreateFolder(parent, folderName)
    local folder = parent:FindFirstChild(folderName)
    if folder and folder:IsA("Folder") then
        return folder
    end

    folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
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

function NukeService:_ensureAssets()
    if self._loading then
        return true
    end

    self._loading = true
    self._nukeAssetsFolder = findOrCreateFolder(ReplicatedStorage, GameConfig.NUKE.AssetFolderName)

    local sourceModel = ReplicatedStorage:FindFirstChild(GameConfig.NUKE.SourceModelName)
    if sourceModel and sourceModel:IsA("Model") then
        makeArchivable(sourceModel)
    end
    self._littleBoyTemplate = sourceModel or self._nukeAssetsFolder:FindFirstChild(GameConfig.NUKE.LittleBoyTemplateName)

    self._cameraTrackSource = nil
    local replicatedAnimatorFolder = findOrCreateFolder(self._nukeAssetsFolder, GameConfig.NUKE.CameraAnimatorFolderName)
    local cameraAnimatorFolder = ServerStorage:FindFirstChild(GameConfig.NUKE.CameraAnimatorFolderName)
    if cameraAnimatorFolder then
        local track = cameraAnimatorFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
        if track then
            self._cameraTrackSource = cloneAnimationTemplate(track)
        end
    end
    if not self._cameraTrackSource then
        local track = replicatedAnimatorFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
        if track then
            self._cameraTrackSource = cloneAnimationTemplate(track)
        end
    end
    if self._cameraTrackSource then
        local existingTrack = replicatedAnimatorFolder:FindFirstChild(GameConfig.NUKE.CameraTrackName)
        if existingTrack then
            existingTrack:Destroy()
        end
        self._cameraTrackSource.Parent = replicatedAnimatorFolder
    end

    self._loading = false
    return true
end

function NukeService:_queueNuke(player)
    table.insert(self._queue, {
        playerUserId = player.UserId,
        playerName = player.Name,
        timestamp = os.clock(),
    })
end

function NukeService:_setClockTime(clockTime)
    if typeof(clockTime) ~= "number" then
        return
    end
    if self._clockTimeBackup == nil then
        self._clockTimeBackup = Lighting.ClockTime
    end
    Lighting.ClockTime = clockTime
end

function NukeService:_restoreClockTime()
    if self._clockTimeBackup ~= nil then
        Lighting.ClockTime = self._clockTimeBackup
        self._clockTimeBackup = nil
        return
    end
    if self._defaultClockTime ~= nil then
        Lighting.ClockTime = self._defaultClockTime
    end
end

function NukeService:_killOtherPlayers(ownerPlayer)
    local killedCount = 0
    for _, targetPlayer in ipairs(Players:GetPlayers()) do
        if targetPlayer ~= ownerPlayer then
            local didKill = false
            if self._healthService and self._healthService.KillActor then
                didKill = select(2, self._healthService:KillActor(targetPlayer, ownerPlayer))
            end
            if didKill then
                killedCount += 1
            end
        end
    end
    return killedCount
end

function NukeService:_pruneLocalSweepSessions()
    local now = os.clock()
    for sessionKey, session in pairs(self._localSweepSessions) do
        if not session or (tonumber(session.ExpiresAt) or 0) <= now then
            self._localSweepSessions[sessionKey] = nil
        end
    end
end

function NukeService:_registerLocalSweepSession(ownerPlayer, sessionId, center)
    self:_pruneLocalSweepSessions()
    local expireSeconds = math.max(1, tonumber(GameConfig.NUKE.LocalMonsterSweepExpireSeconds) or 8)
    self._localSweepSessions[tostring(sessionId)] = {
        OwnerUserId = ownerPlayer.UserId,
        Center = center,
        ExpiresAt = os.clock()
            + getNukePreludeSeconds()
            + math.max(0, tonumber(GameConfig.NUKE.FallSeconds) or 0)
            + math.max(0, tonumber(GameConfig.NUKE.ExplosionSeconds) or 0)
            + expireSeconds,
        Consumed = false,
    }
end

function NukeService:_grantCompressedExperience(player, position, totalExperience, orbCount)
    if totalExperience <= 0 then
        return
    end

    if self._experienceOrbService and self._experienceOrbService.GrantNukeSweepExperience then
        self._experienceOrbService:GrantNukeSweepExperience(
            position,
            totalExperience,
            orbCount,
            player,
            {
                applyExperienceMultiplier = true,
            }
        )
    elseif self._experienceOrbService and self._experienceOrbService.GrantCompressedExperience then
        self._experienceOrbService:GrantCompressedExperience(
            position,
            totalExperience,
            orbCount,
            player,
            {
                applyExperienceMultiplier = true,
            }
        )
    elseif self._playerStateService and self._playerStateService.AddExperienceWithMultiplier then
        self._playerStateService:AddExperienceWithMultiplier(player, totalExperience)
    end
end

function NukeService:_handleLocalMonsterSweep(player, payload)
    if not (player and player.Parent) then
        return
    end

    self:_pruneLocalSweepSessions()
    local sessionId = tostring(payload and payload.sessionId or "")
    local session = self._localSweepSessions[sessionId]
    if not session or session.Consumed == true or session.OwnerUserId ~= player.UserId then
        return
    end

    local tokens = payload and payload.tokens
    if type(tokens) ~= "table" then
        if type(payload and payload.monsters) == "table" then
            warn("[NukeService] 拒绝旧版 local monster sweep payload，缺少 tokens")
        end
        return
    end

    local consumedCount, totalScore, totalExperience = 0, 0, 0
    if self._localMonsterRewardService and self._localMonsterRewardService.ConsumeNukeSweepTokens then
        consumedCount, totalScore, totalExperience = self._localMonsterRewardService:ConsumeNukeSweepTokens(player, tokens)
    end

    if consumedCount <= 0 and totalScore <= 0 and totalExperience <= 0 then
        return
    end
    session.Consumed = true

    if totalScore > 0 and self._playerStateService then
        self._playerStateService:AddRebirthScore(player, totalScore)
    end
    self:_grantCompressedExperience(
        player,
        session.Center or Vector3.zero,
        totalExperience,
        math.max(1, math.floor(tonumber(GameConfig.NUKE.LocalMonsterSweepOrbCount) or 12))
    )
end

function NukeService:_sweepServerMonsters(ownerPlayer, center)
    if self._monsterService and self._monsterService.SweepForNuke then
        self._monsterService:SweepForNuke(
            ownerPlayer,
            center,
            math.max(1, math.floor(tonumber(GameConfig.NUKE.ServerMonsterSweepOrbCount) or 12))
        )
    end
end

function NukeService:_buildCinematicPayload(ownerPlayer, sessionId, center, surfaceY)
    local ownerDisplayName = ownerPlayer.DisplayName
    if ownerDisplayName == nil or ownerDisplayName == "" then
        ownerDisplayName = ownerPlayer.Name
    end

    return {
        sessionId = sessionId,
        ownerUserId = ownerPlayer.UserId,
        ownerName = ownerPlayer.Name,
        ownerDisplayName = ownerDisplayName,
        battleCenter = {
            x = center.X,
            y = surfaceY,
            z = center.Z,
        },
        fallHeight = GameConfig.NUKE.FallHeight,
        fallSeconds = GameConfig.NUKE.FallSeconds,
        explosionSeconds = GameConfig.NUKE.ExplosionSeconds,
        idleAnimationId = GameConfig.NUKE.IdleAnimationId,
        lightingClockTime = GameConfig.NUKE.LightingClockTime,
        restoreClockTime = GameConfig.NUKE.RestoreClockTime,
        startDelaySeconds = GameConfig.NUKE.StartLeadSeconds,
        nukeBannerSeconds = GameConfig.NUKE.NukeBannerSeconds,
        warningFlashCount = GameConfig.NUKE.WarningFlashCount,
        warningFadeInSeconds = GameConfig.NUKE.WarningFadeInSeconds,
        warningHoldSeconds = GameConfig.NUKE.WarningHoldSeconds,
        warningFadeOutSeconds = GameConfig.NUKE.WarningFadeOutSeconds,
        warningGapSeconds = GameConfig.NUKE.WarningGapSeconds,
        serverStartClock = os.clock(),
        serverStartTime = Workspace:GetServerTimeNow(),
    }
end

function NukeService:_runQueue()
    if self._isRunning then
        return
    end

    self._isRunning = true
    task.spawn(function()
        while #self._queue > 0 do
            local entry = table.remove(self._queue, 1)
            local ownerPlayer = Players:GetPlayerByUserId(entry.playerUserId)
            if ownerPlayer and ownerPlayer.Parent then
                self:_ensureAssets()
                self._playSessionId += 1
                local sessionId = self._playSessionId
                local center, surfaceY = getBattleCenterAndSurface(self._arenaService)
                local payload = self:_buildCinematicPayload(ownerPlayer, sessionId, center, surfaceY)
                self:_registerLocalSweepSession(ownerPlayer, sessionId, center)
                self._nukeCinematicEvent:FireAllClients(payload)
                task.wait(
                    math.max(0, tonumber(GameConfig.NUKE.StartLeadSeconds) or 0)
                    + getNukePreludeSeconds()
                    + math.max(0, tonumber(GameConfig.NUKE.FallSeconds) or 2.5)
                )
                self:_setClockTime(GameConfig.NUKE.LightingClockTime)
                self:_sweepServerMonsters(ownerPlayer, center)
                self:_killOtherPlayers(ownerPlayer)
                task.wait(math.max(0.25, tonumber(GameConfig.NUKE.ExplosionSeconds) or 3))
                self:_restoreClockTime()
                task.wait(math.max(0, tonumber(GameConfig.NUKE.QueueGapSeconds) or 0.25))
            end
        end
        self._isRunning = false
    end)
end

function NukeService:RequestNuke(player)
    if not (player and player.Parent and self._nukeCinematicEvent) then
        return false
    end

    self:_queueNuke(player)
    self:_runQueue()
    return true
end

function NukeService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._arenaService = dependencies and dependencies.ArenaService or nil
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._monsterService = dependencies and dependencies.MonsterService or nil
    self._experienceOrbService = dependencies and dependencies.ExperienceOrbService or nil
    self._localMonsterRewardService = dependencies and dependencies.LocalMonsterRewardService or nil
    self._nukeCinematicEvent = self._remoteEventService and self._remoteEventService:GetEvent("NukeCinematic") or nil
    self._nukeLocalMonsterSweepEvent = self._remoteEventService and self._remoteEventService:GetEvent("NukeLocalMonsterSweep") or nil
    self._queue = {}
    self._localSweepSessions = {}
    self._isRunning = false
    self._loading = false
    self._playSessionId = 0
    self._defaultClockTime = Lighting.ClockTime
    self._clockTimeBackup = nil

    self:_ensureAssets()

    if self._nukeLocalMonsterSweepEvent then
        self._nukeLocalMonsterSweepEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleLocalMonsterSweep(player, payload)
        end)
    end
end

return NukeService
