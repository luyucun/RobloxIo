--[[
Script name: RevengeService
Type: ModuleScript
Studio path: ServerScriptService/Services/RevengeService
Purpose: Orchestrates the paid Defeated revenge cinematic and authoritative kill.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

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
        "[RevengeService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local DEFAULT_CONFIG = {
    EffectTemplateName = "Revenge",
    EffectInstanceName = "RevengeEffect",
    CameraLockSeconds = 1,
    EffectSeconds = 0.5,
    CleanupDelaySeconds = 0.15,
    PromptCloseFallbackSeconds = 8,
}

GameConfig.REVENGE = GameConfig.REVENGE or {}
for key, value in pairs(DEFAULT_CONFIG) do
    if GameConfig.REVENGE[key] == nil then
        GameConfig.REVENGE[key] = value
    end
end

local RevengeService = {}

RevengeService._playerStateService = nil
RevengeService._respawnService = nil
RevengeService._healthService = nil
RevengeService._remoteEventService = nil
RevengeService._revengeCinematicEvent = nil
RevengeService._killInfoFeedbackEvent = nil
RevengeService._sessionSerial = 0
RevengeService._activeByUserId = {}
RevengeService._pendingByUserId = {}
RevengeService._testDummies = {}

local function getActorDisplayName(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.DisplayName ~= "" and actor.DisplayName or actor.Name
    end
    return ActorUtils.GetActorName(actor)
end

local function getActorUserId(actor)
    return ActorUtils.GetCombatUserId(actor) or 0
end

local function getConfigNumber(key)
    return math.max(0, tonumber(GameConfig.REVENGE and GameConfig.REVENGE[key]) or DEFAULT_CONFIG[key] or 0)
end

local function getEffectTemplateName()
    return tostring(GameConfig.REVENGE and GameConfig.REVENGE.EffectTemplateName or DEFAULT_CONFIG.EffectTemplateName)
end

local function getEffectInstanceName()
    return tostring(GameConfig.REVENGE and GameConfig.REVENGE.EffectInstanceName or DEFAULT_CONFIG.EffectInstanceName)
end

function RevengeService:_nextSessionId()
    self._sessionSerial += 1
    return self._sessionSerial
end

function RevengeService:_clearPendingRevenge(userId)
    local resolvedUserId = tonumber(userId)
    if resolvedUserId and resolvedUserId > 0 then
        self._pendingByUserId[resolvedUserId] = nil
    end
end

function RevengeService:_setPendingRevenge(ownerPlayer, defeatRecord)
    local userId = ownerPlayer and ownerPlayer.UserId or 0
    if userId <= 0 then
        return false
    end

    local token = self:_nextSessionId()
    local fallbackSeconds = getConfigNumber("PromptCloseFallbackSeconds")

    self._pendingByUserId[userId] = {
        token = token,
        deathSerial = defeatRecord and defeatRecord.deathSerial or nil,
        requestedAt = os.clock(),
        promptCloseFallbackAt = os.clock() + fallbackSeconds,
    }

    if fallbackSeconds > 0 then
        task.delay(fallbackSeconds, function()
            local pending = self._pendingByUserId[userId]
            if not pending or pending.token ~= token or tonumber(pending.deathSerial) ~= tonumber(defeatRecord and defeatRecord.deathSerial) then
                return
            end

            local player = Players:GetPlayerByUserId(userId)
            if not player then
                return
            end

            local currentDefeatRecord = self._respawnService and self._respawnService:GetDefeatRecord(player) or nil
            if not self:_shouldStartPendingRevenge(player, currentDefeatRecord) then
                return
            end

            self:_completePendingRevenge(player)
        end)
    end

    return true
end

function RevengeService:_getPendingRevenge(player)
    local userId = player and player.UserId or 0
    if userId <= 0 then
        return nil
    end
    return self._pendingByUserId[userId]
end

function RevengeService:_hasPendingRevengeForCurrentDeath(player, defeatRecord)
    if not (player and defeatRecord) then
        return false
    end

    local pending = self:_getPendingRevenge(player)
    return pending and tonumber(pending.deathSerial) == tonumber(defeatRecord.deathSerial)
end

function RevengeService:_shouldStartPendingRevenge(player, defeatRecord)
    if not self:_hasPendingRevengeForCurrentDeath(player, defeatRecord) then
        return false
    end

    local pending = self:_getPendingRevenge(player)
    if not pending then
        return false
    end

    if defeatRecord.revengePromptClosed == true then
        return true
    end

    local fallbackAt = tonumber(pending.promptCloseFallbackAt) or 0
    return fallbackAt > 0 and os.clock() >= fallbackAt
end

function RevengeService:_completePendingRevenge(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._respawnService) then
        return false
    end

    local defeatRecord = self._respawnService:GetDefeatRecord(player)
    if not self:_shouldStartPendingRevenge(player, defeatRecord) then
        return false
    end

    self:_clearPendingRevenge(player.UserId)
    return self:RequestRevenge(player)
end

function RevengeService:MarkRevengePurchasePending(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._respawnService) then
        return false
    end

    local defeatRecord = self._respawnService:GetDefeatRecord(player)
    if not self._respawnService:IsCurrentDefeatRecord(player, defeatRecord) then
        return false
    end

    if defeatRecord.revengePending ~= true then
        defeatRecord.revengePending = true
    end

    self:_setPendingRevenge(player, defeatRecord)
    if defeatRecord.revengePromptClosed == true then
        return self:_completePendingRevenge(player)
    end
    return true
end

function RevengeService:CompletePendingRevenge(player)
    return self:_completePendingRevenge(player)
end

function RevengeService:CancelPendingRevenge(player)
    local userId = player and player.UserId or 0
    if userId <= 0 then
        return
    end
    self:_clearPendingRevenge(userId)
end

function RevengeService:_getBaseParts(root)
    local parts = {}
    if not root then
        return parts
    end
    if root:IsA("BasePart") then
        table.insert(parts, root)
    end
    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(parts, descendant)
        end
    end
    return parts
end

function RevengeService:_getPartsBounds(parts)
    local minX = math.huge
    local minY = math.huge
    local minZ = math.huge
    local maxX = -math.huge
    local maxY = -math.huge
    local maxZ = -math.huge
    local hasPart = false

    for _, part in ipairs(parts or {}) do
        if part and part:IsA("BasePart") then
            local halfSize = part.Size * 0.5
            for xSign = -1, 1, 2 do
                for ySign = -1, 1, 2 do
                    for zSign = -1, 1, 2 do
                        local corner = part.CFrame:PointToWorldSpace(Vector3.new(
                            halfSize.X * xSign,
                            halfSize.Y * ySign,
                            halfSize.Z * zSign
                        ))
                        minX = math.min(minX, corner.X)
                        minY = math.min(minY, corner.Y)
                        minZ = math.min(minZ, corner.Z)
                        maxX = math.max(maxX, corner.X)
                        maxY = math.max(maxY, corner.Y)
                        maxZ = math.max(maxZ, corner.Z)
                        hasPart = true
                    end
                end
            end
        end
    end

    if not hasPart then
        return nil, nil
    end

    local minVector = Vector3.new(minX, minY, minZ)
    local maxVector = Vector3.new(maxX, maxY, maxZ)
    return (minVector + maxVector) * 0.5, maxVector - minVector
end

function RevengeService:_getCharacterFootBottomY(character, rootPart)
    local lowestY = math.huge
    local hasPart = false
    for _, descendant in ipairs(character and character:GetDescendants() or {}) do
        if descendant:IsA("BasePart") then
            local center, size = self:_getPartsBounds({ descendant })
            if center and size then
                lowestY = math.min(lowestY, center.Y - (size.Y * 0.5))
                hasPart = true
            end
        end
    end

    if hasPart then
        return lowestY
    end

    local humanoid = character and character:FindFirstChildOfClass("Humanoid") or nil
    if rootPart then
        local hipHeight = humanoid and humanoid.HipHeight or 0
        return rootPart.Position.Y - hipHeight - (rootPart.Size.Y * 0.5)
    end
    return nil
end

function RevengeService:_positionCharacterFloorEffect(effect, rootPart, footBottomY)
    local effectParts = self:_getBaseParts(effect)
    local boundsCenter, boundsSize = self:_getPartsBounds(effectParts)
    if not (boundsCenter and boundsSize and rootPart and typeof(footBottomY) == "number") then
        return false
    end

    local effectBottomY = boundsCenter.Y - (boundsSize.Y * 0.5)
    local horizontalOffset = Vector3.new(rootPart.Position.X - boundsCenter.X, 0, rootPart.Position.Z - boundsCenter.Z)
    local verticalOffset = Vector3.new(0, footBottomY - effectBottomY, 0)
    local offset = horizontalOffset + verticalOffset
    local _, rootYaw = rootPart.CFrame:ToOrientation()
    local targetYawCFrame = CFrame.Angles(0, rootYaw, 0)
    local moveFrame = CFrame.new(offset)

    for _, part in ipairs(effectParts) do
        part.CFrame = moveFrame * part.CFrame
    end

    boundsCenter = self:_getPartsBounds(effectParts)
    if not boundsCenter then
        return true
    end

    local rotationCenter = CFrame.new(boundsCenter)
    for _, part in ipairs(effectParts) do
        local relative = rotationCenter:ToObjectSpace(part.CFrame)
        part.CFrame = CFrame.new(boundsCenter) * targetYawCFrame * relative
    end

    return true
end

function RevengeService:_attachCharacterFloorEffect(effect, rootPart, weldName)
    if not (effect and rootPart) then
        return false
    end

    local effectParts = self:_getBaseParts(effect)
    for _, part in ipairs(effectParts) do
        part.Anchored = false
        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false
        part.Massless = true
        local weld = Instance.new("WeldConstraint")
        weld.Name = tostring(weldName or "RevengeEffectWeld")
        weld.Part0 = rootPart
        weld.Part1 = part
        weld.Parent = part
    end

    return #effectParts > 0
end

function RevengeService:_emitEffectParticles(effect)
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("ParticleEmitter") then
            descendant.Enabled = true
            local emitCount = tonumber(descendant:GetAttribute("EmitCount"))
            if emitCount and emitCount > 0 then
                descendant:Emit(emitCount)
            end
        elseif descendant:IsA("Beam") or descendant:IsA("Trail") or descendant:IsA("BillboardGui") then
            descendant.Enabled = true
        end
    end
end

function RevengeService:_attachRevengeEffect(targetActor)
    local character = ActorUtils.GetCharacter(targetActor)
    local rootPart = ActorUtils.GetRootPart(targetActor)
    if not (character and rootPart) then
        return nil
    end

    local template = ReplicatedStorage:FindFirstChild(getEffectTemplateName())
    if not template then
        warn(string.format("[RevengeService] Missing ReplicatedStorage.%s effect template", getEffectTemplateName()))
        return nil
    end

    local staleEffect = character:FindFirstChild(getEffectInstanceName())
    if staleEffect then
        staleEffect:Destroy()
    end

    local effect = template:Clone()
    effect.Name = getEffectInstanceName()

    local footBottomY = self:_getCharacterFootBottomY(character, rootPart)
    if not footBottomY
        or not self:_positionCharacterFloorEffect(effect, rootPart, footBottomY)
        or not self:_attachCharacterFloorEffect(effect, rootPart, "RevengeEffectWeld")
    then
        effect:Destroy()
        return nil
    end

    effect.Parent = character
    self:_emitEffectParticles(effect)
    return effect
end

function RevengeService:_buildCinematicPayload(ownerPlayer, targetActor, sessionId)
    local character = ActorUtils.GetCharacter(targetActor)
    return {
        eventType = "Start",
        sessionId = sessionId,
        ownerUserId = ownerPlayer.UserId,
        targetUserId = getActorUserId(targetActor),
        targetName = getActorDisplayName(targetActor),
        targetCharacter = character,
        lockSeconds = getConfigNumber("CameraLockSeconds"),
        effectSeconds = getConfigNumber("EffectSeconds"),
        serverStartClock = os.clock(),
    }
end

function RevengeService:_isAliveTarget(actor)
    local state = self._playerStateService and self._playerStateService:GetState(actor) or nil
    return state and state.Alive == true
end

function RevengeService:_fireStudioKillInfo(ownerPlayer, targetActor)
    if not (RunService:IsStudio() and self._killInfoFeedbackEvent and ownerPlayer and ownerPlayer.Parent) then
        return
    end

    self._killInfoFeedbackEvent:FireClient(ownerPlayer, {
        eventType = "PlayerKilled",
        killerUserId = ownerPlayer.UserId,
        killerName = getActorDisplayName(ownerPlayer),
        victimUserId = getActorUserId(targetActor),
        victimName = getActorDisplayName(targetActor),
        killSource = "Revenge",
        isRevengeKill = true,
        timestamp = os.clock(),
    })
end

function RevengeService:_reviveOwnerAfterRevenge(ownerPlayer, defeatRecord)
    if type(defeatRecord) == "table" then
        defeatRecord.revengePending = false
    end
    if not (ownerPlayer and ownerPlayer.Parent and self._respawnService) then
        return false
    end

    local state = self._playerStateService and self._playerStateService:GetState(ownerPlayer) or nil
    if state and state.Alive == true then
        return true
    end

    local ok, result = pcall(function()
        return self._respawnService:RevivePlayer(ownerPlayer)
    end)
    if not ok then
        warn(string.format("[RevengeService] Failed to revive revenge owner %s: %s", tostring(ownerPlayer.Name), tostring(result)))
        return false
    end
    return result == true
end

function RevengeService:_resolvePlayerRevengeTarget(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._respawnService) then
        return nil, nil
    end

    local defeatRecord = self._respawnService:GetDefeatRecord(player)
    if self._respawnService.IsCurrentDefeatRecord
        and not self._respawnService:IsCurrentDefeatRecord(player, defeatRecord)
    then
        return nil, defeatRecord
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    if not (state and state.Alive == false and defeatRecord and defeatRecord.deathSerial) then
        return nil, defeatRecord
    end

    local killerUserId = tonumber(defeatRecord.killerUserId)
    if not (killerUserId and killerUserId > 0) then
        return nil, defeatRecord
    end

    local targetPlayer = Players:GetPlayerByUserId(killerUserId)
    if not (targetPlayer and targetPlayer.Parent) then
        return nil, defeatRecord
    end

    if not self:_isAliveTarget(targetPlayer) then
        return nil, defeatRecord
    end

    return targetPlayer, defeatRecord
end

function RevengeService:_runRevenge(ownerPlayer, targetActor, defeatRecord, options)
    local ownerUserId = ownerPlayer.UserId
    local token = self._activeByUserId[ownerUserId]
    local sessionId = token and token.sessionId or self:_nextSessionId()
    if not token then
        token = {
            sessionId = sessionId,
        }
        self._activeByUserId[ownerUserId] = token
    end

    task.spawn(function()
        local lockSeconds = getConfigNumber("CameraLockSeconds")
        local effectSeconds = getConfigNumber("EffectSeconds")
        local cleanupDelaySeconds = getConfigNumber("CleanupDelaySeconds")
        local didKill = false
        local effect = nil
        local ownerRevived = false
        local function cleanupEffect()
            if effect and effect.Parent then
                task.delay(cleanupDelaySeconds, function()
                    if effect and effect.Parent then
                        effect:Destroy()
                    end
                end)
            end
        end
        local function reviveOwnerOnce()
            if ownerRevived then
                return true
            end
            ownerRevived = self:_reviveOwnerAfterRevenge(ownerPlayer, defeatRecord) == true
            return ownerRevived
        end

        local ok, err = xpcall(function()
            if self._revengeCinematicEvent then
                self._revengeCinematicEvent:FireClient(ownerPlayer, self:_buildCinematicPayload(ownerPlayer, targetActor, sessionId))
            end

            task.wait(lockSeconds)

            if self._activeByUserId[ownerUserId] ~= token then
                return
            end
            if not (ownerPlayer and ownerPlayer.Parent and targetActor and self:_isAliveTarget(targetActor)) then
                reviveOwnerOnce()
                self._activeByUserId[ownerUserId] = nil
                return
            end

            effect = self:_attachRevengeEffect(targetActor)
            task.wait(effectSeconds)

            if self._activeByUserId[ownerUserId] ~= token then
                if effect and effect.Parent then
                    effect:Destroy()
                end
                return
            end

            if ownerPlayer and ownerPlayer.Parent and targetActor and self:_isAliveTarget(targetActor) and self._healthService then
                local killOk, _, killResult = pcall(function()
                    if self._healthService.KillActor then
                        return self._healthService:KillActor(targetActor, ownerPlayer, {
                            killSource = "Revenge",
                            isRevengeKill = true,
                        })
                    end
                    return self._healthService:ApplyWeaponDamage(targetActor, GameConfig.MONETIZATION.NukeDamage, ownerPlayer)
                end)
                if killOk then
                    didKill = killResult == true
                else
                    warn(string.format("[RevengeService] Failed to kill revenge target %s: %s", getActorDisplayName(targetActor), tostring(killResult)))
                end
            end

            reviveOwnerOnce()
            cleanupEffect()

            self._activeByUserId[ownerUserId] = nil
            if didKill then
                print(string.format("[RevengeService] Revenge granted to %s against %s", ownerPlayer.Name, getActorDisplayName(targetActor)))
                if options and options.fireStudioKillInfo == true then
                    self:_fireStudioKillInfo(ownerPlayer, targetActor)
                end
            end

            if options and options.cleanupTargetAfter then
                task.delay(math.max(0.2, tonumber(options.cleanupTargetAfter) or 2), function()
                    self:_cleanupTestTarget(targetActor)
                end)
            end
        end, debug.traceback)

        if not ok then
            warn(string.format("[RevengeService] Revenge sequence failed for %s: %s", tostring(ownerPlayer and ownerPlayer.Name or ownerUserId), tostring(err)))
            if effect and effect.Parent then
                effect:Destroy()
            end
            reviveOwnerOnce()
            self._activeByUserId[ownerUserId] = nil
        end
    end)

    return true
end

function RevengeService:RequestRevenge(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._respawnService) then
        return false
    end

    local targetActor, defeatRecord = self:_resolvePlayerRevengeTarget(player)
    local active = self._activeByUserId[player.UserId]
    if active and defeatRecord and active.deathSerial == defeatRecord.deathSerial then
        return true
    end
    if active then
        self._activeByUserId[player.UserId] = nil
    end

    if not targetActor then
        self:_reviveOwnerAfterRevenge(player, defeatRecord)
        return true
    end

    self._activeByUserId[player.UserId] = {
        sessionId = self:_nextSessionId(),
        deathSerial = defeatRecord and defeatRecord.deathSerial or nil,
    }
    return self:_runRevenge(player, targetActor, defeatRecord)
end

function RevengeService:_createTestDummy(player)
    local character = player and player.Character
    if not character then
        return nil
    end

    character.Archivable = true
    local dummy = character:Clone()
    dummy.Name = "RevengeTestDummy"
    dummy:SetAttribute("RevengeTestDummy", true)

    for _, descendant in ipairs(dummy:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        elseif descendant:IsA("BasePart") then
            descendant.Anchored = false
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
            descendant.Massless = true
        end
    end

    local rootPart = dummy:FindFirstChild("HumanoidRootPart")
    local humanoid = dummy:FindFirstChildOfClass("Humanoid")
    if not (rootPart and humanoid) then
        dummy:Destroy()
        return nil
    end
    dummy.PrimaryPart = rootPart
    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    humanoid.BreakJointsOnDeath = false

    local playerRoot = ActorUtils.GetRootPart(player)
    local targetCFrame = playerRoot and (playerRoot.CFrame * CFrame.new(0, 0, -18)) or CFrame.new(0, 8, 0)
    dummy:PivotTo(CFrame.lookAt(targetCFrame.Position, playerRoot and playerRoot.Position or (targetCFrame.Position + Vector3.new(0, 0, -1))))

    local runtimeRoot = Workspace:FindFirstChild("Runtime")
    if not runtimeRoot then
        runtimeRoot = Instance.new("Folder")
        runtimeRoot.Name = "Runtime"
        runtimeRoot.Parent = Workspace
    end
    local testFolder = runtimeRoot:FindFirstChild("RevengeTests")
    if not testFolder then
        testFolder = Instance.new("Folder")
        testFolder.Name = "RevengeTests"
        testFolder.Parent = runtimeRoot
    end

    dummy.Parent = testFolder

    local actor = {
        IsBot = true,
        Name = dummy.Name,
        ActorId = string.format("revenge-test:%d:%d", player.UserId, math.floor(os.clock() * 1000)),
        UserId = -100000 - player.UserId,
        Character = dummy,
        State = nil,
        Connections = {},
        NextThinkClock = 0,
        NextWanderRefreshClock = 0,
        WanderTarget = nil,
        RespawnToken = 0,
    }
    self._playerStateService:RegisterBot(actor)
    self._playerStateService:OnCharacterAdded(actor)
    local state = self._playerStateService:GetState(actor)
    state.Alive = true
    state.IsInArena = true
    state.MaxHealth = math.max(1, tonumber(state.MaxHealth) or GameConfig.GetMaxHealthForLevel(state.Level))
    state.CurrentHealth = state.MaxHealth
    self._playerStateService:SyncCharacterState(actor)
    self._playerStateService:PushState(actor)

    self._testDummies[actor.ActorId] = actor
    return actor
end

function RevengeService:_cleanupTestTarget(targetActor)
    if not (targetActor and self._testDummies[targetActor.ActorId]) then
        return
    end

    self._testDummies[targetActor.ActorId] = nil
    if targetActor.Connections then
        for _, connection in ipairs(targetActor.Connections) do
            if connection then
                connection:Disconnect()
            end
        end
    end
    if targetActor.Character and targetActor.Character.Parent then
        targetActor.Character:Destroy()
    end
    if self._playerStateService and self._playerStateService.UnregisterBot then
        self._playerStateService:UnregisterBot(targetActor)
    end
end

function RevengeService:RunStudioTest(player)
    if not (RunService:IsStudio() and ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "StudioOnly"
    end
    if not (self._playerStateService and self._healthService and self._respawnService and self._revengeCinematicEvent) then
        return false, "ServiceUnavailable"
    end
    if self._activeByUserId[player.UserId] then
        return true, "AlreadyRunning"
    end

    local targetActor = self:_createTestDummy(player)
    if not targetActor then
        return false, "MissingDummy"
    end

    self._activeByUserId[player.UserId] = {
        sessionId = self:_nextSessionId(),
        studioTest = true,
    }
    self:_runRevenge(player, targetActor, nil, {
        fireStudioKillInfo = true,
        cleanupTargetAfter = 2,
    })
    return true, "Started"
end

function RevengeService:OnPlayerRemoving(player)
    if ActorUtils.IsPlayer(player) then
        self._activeByUserId[player.UserId] = nil
    end
end

function RevengeService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._respawnService = dependencies and dependencies.RespawnService or nil
    self._healthService = dependencies and dependencies.HealthService or nil
    self._remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._revengeCinematicEvent = self._remoteEventService and self._remoteEventService:GetEvent("RevengeCinematic") or nil
    self._killInfoFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("KillInfoFeedback") or nil
    self._sessionSerial = 0
    self._activeByUserId = {}
    self._testDummies = {}
end

function RevengeService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._respawnService = dependencies and dependencies.RespawnService or self._respawnService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
end

return RevengeService
