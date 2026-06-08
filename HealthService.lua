--[[
脚本名字: HealthService
脚本文件: HealthService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/HealthService
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
        "[HealthService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local HealthService = {}

HealthService._playerStateService = nil
HealthService._remoteEventService = nil
HealthService._respawnService = nil
HealthService._arenaService = nil
HealthService._deathFeedbackEvent = nil
HealthService._killInfoFeedbackEvent = nil
HealthService._buffService = nil
HealthService._lastDamageClockByUserId = {}
HealthService._recoverEffectsByUserId = {}
HealthService._shieldEffectsByUserId = {}
HealthService._shieldExpiresAtByUserId = {}
HealthService._heartbeatConnection = nil
HealthService._nextRegenClock = 0
HealthService._nextShieldClock = 0
HealthService._missingShieldTemplateWarned = false

local function buildKillerPayload(playerStateService, sourceActor)
    if ActorUtils.IsPlayer(sourceActor) then
        local state = playerStateService and playerStateService:GetState(sourceActor) or nil
        return {
            userId = sourceActor.UserId,
            name = sourceActor.DisplayName ~= "" and sourceActor.DisplayName or sourceActor.Name,
            level = state and state.Level or GameConfig.PLAYER.BaseLevel,
            killCount = state and state.KillCount or 0,
            totalPlayerKills = state and state.TotalPlayerKills or 0,
            isPlayer = true,
        }
    end

    local fallbackName = sourceActor and ActorUtils.GetActorName(sourceActor) or "Unknown"
    if fallbackName == "" then
        fallbackName = "Unknown"
    end
    return {
        userId = 0,
        name = fallbackName,
        level = GameConfig.PLAYER.BaseLevel,
        killCount = 0,
        totalPlayerKills = 0,
        isPlayer = false,
    }
end

local function getPlayerDisplayName(player)
    if not ActorUtils.IsPlayer(player) then
        return ""
    end

    return player.DisplayName ~= "" and player.DisplayName or player.Name
end

local function findStudioTestKiller(playerStateService, victim)
    local fallbackPlayer = nil
    for _, candidate in ipairs(Players:GetPlayers()) do
        if candidate ~= victim and candidate.Parent then
            fallbackPlayer = fallbackPlayer or candidate
            local state = playerStateService and playerStateService:GetState(candidate) or nil
            if state and state.Alive == true then
                return candidate
            end
        end
    end
    return fallbackPlayer
end

local function getHalfFreeRespawnLevel(victimLevel)
    return math.clamp(
        math.floor((tonumber(victimLevel) or GameConfig.PLAYER.BaseLevel) / 2),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
end

function HealthService:_fireDeathFeedback(actor, sourceActor)
    if not self._deathFeedbackEvent then
        return
    end
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local victimState = self._playerStateService and self._playerStateService:GetState(actor) or nil
    local victimLevel = math.clamp(
        math.floor(tonumber(victimState and victimState.Level) or GameConfig.PLAYER.BaseLevel),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    local killerUserId = sourceActor and ActorUtils.GetCombatUserId(sourceActor) or nil
    local freeRespawnLevel = math.clamp(
        math.floor(victimLevel / 2),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    self._deathFeedbackEvent:FireClient(actor, {
        reason = "WeaponDamage",
        killerUserId = killerUserId,
        killer = buildKillerPayload(self._playerStateService, sourceActor),
        victimLevel = victimLevel,
        freeRespawnLevel = freeRespawnLevel,
        timestamp = os.clock(),
    })

    if self._gameAnalyticsService then
        if self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.FirstDeathOrSurvived60s") then
            self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 10, "FirstDeathOrSurvived60s", {
                source = ActorUtils.IsPlayer(sourceActor) and "player" or "monster",
                level = victimState and victimState.Level or GameConfig.PLAYER.BaseLevel,
            })
        end
        self._gameAnalyticsService:TrackCustom(actor, "PlayerDied", 1, {
            source = ActorUtils.IsPlayer(sourceActor) and "player" or "monster",
        })
    end
end

function HealthService:_fireKillInfoFeedback(targetActor, sourceActor, options)
    if not self._killInfoFeedbackEvent then
        return
    end
    if not (ActorUtils.IsPlayer(sourceActor) and ActorUtils.IsPlayer(targetActor)) then
        return
    end
    if ActorUtils.IsSameActor(sourceActor, targetActor) then
        return
    end

    local isRevengeKill = options
        and (options.isRevengeKill == true or options.killSource == "Revenge")
        or false
    local payload = {
        eventType = "PlayerKilled",
        killerUserId = sourceActor.UserId,
        killerName = getPlayerDisplayName(sourceActor),
        victimUserId = targetActor.UserId,
        victimName = getPlayerDisplayName(targetActor),
        timestamp = os.clock(),
    }
    if isRevengeKill then
        payload.killSource = "Revenge"
        payload.isRevengeKill = true
    end

    self._killInfoFeedbackEvent:FireAllClients(payload)
end

function HealthService:_handleActorKill(targetActor, sourceActor, options)
    if sourceActor and not ActorUtils.IsSameActor(sourceActor, targetActor) then
        if ActorUtils.IsPlayer(sourceActor) and ActorUtils.IsPlayer(targetActor) then
            self._playerStateService:AwardPlayerKillReward(sourceActor, targetActor)
            self._playerStateService:AddRebirthScore(sourceActor, GameConfig.REBIRTH.PlayerKillScoreReward)
            self:_fireKillInfoFeedback(targetActor, sourceActor, options)
            if self._gameAnalyticsService then
                self._gameAnalyticsService:TrackCustom(sourceActor, "PlayerKilled", 1, {
                    source = "player",
                })
            end
        end
        self._playerStateService:PushState(sourceActor)
    end

    self:_fireDeathFeedback(targetActor, sourceActor)
    if self._respawnService then
        self._respawnService:HandleActorDeath(targetActor, sourceActor)
    end
end

function HealthService:_recordDamageTaken(actor)
    if ActorUtils.IsPlayer(actor) then
        self._lastDamageClockByUserId[actor.UserId] = os.clock()
    end
end

function HealthService:_isSafeZoneProtected(actor)
    return self._arenaService
        and self._arenaService.IsActorInsideSafeZone
        and self._arenaService:IsActorInsideSafeZone(actor) == true
end

function HealthService:_clearDamageTracking(actor)
    if ActorUtils.IsPlayer(actor) then
        self._lastDamageClockByUserId[actor.UserId] = nil
    end
end

function HealthService:_updateShieldOverheadUi(player)
    if self._playerStateService
        and self._playerStateService.UpdateOverheadHealthBar
        and ActorUtils.IsPlayer(player)
    then
        self._playerStateService:UpdateOverheadHealthBar(player)
    end
end

function HealthService:_getRecoverEffectConfig()
    local config = GameConfig.HEALTH_REGEN or {}
    return {
        TemplateName = tostring(config.EffectTemplateName or "Recover"),
        InstanceName = tostring(config.EffectInstanceName or "HealthRegenRecoverEffect"),
    }
end

function HealthService:_getRecoverTemplate()
    local effectConfig = self:_getRecoverEffectConfig()
    local templateName = effectConfig.TemplateName
    if templateName == "" then
        return nil
    end
    return ReplicatedStorage:FindFirstChild(templateName)
end

function HealthService:_getShieldEffectConfig()
    local config = GameConfig.SHIELD or {}
    return {
        TemplateName = tostring(config.EffectTemplateName or "Shield"),
        InstanceName = tostring(config.EffectInstanceName or "ActiveShieldEffect"),
    }
end

function HealthService:_getShieldTemplate()
    local effectConfig = self:_getShieldEffectConfig()
    local templateName = effectConfig.TemplateName
    if templateName == "" then
        return nil
    end
    return ReplicatedStorage:FindFirstChild(templateName)
end

function HealthService:_getShieldConfig()
    local config = GameConfig.SHIELD or {}
    return {
        DurationSeconds = math.max(0, tonumber(config.DurationSeconds) or 30),
        TickSeconds = math.max(0.1, tonumber(config.TickSeconds) or 0.25),
    }
end

function HealthService:_getBaseParts(root)
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

function HealthService:_getPartsBounds(parts)
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

function HealthService:_getCharacterFootBottomY(character, rootPart)
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

function HealthService:_positionCharacterFloorEffect(effect, rootPart, footBottomY)
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

function HealthService:_attachCharacterFloorEffect(effect, rootPart, weldName)
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
        weld.Name = tostring(weldName or "CharacterFloorEffectWeld")
        weld.Part0 = rootPart
        weld.Part1 = part
        weld.Parent = part
    end

    return #effectParts > 0
end

function HealthService:_removeRecoverEffect(playerOrUserId)
    local userId = nil
    local player = nil
    if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
        player = playerOrUserId
        userId = playerOrUserId.UserId
    else
        userId = tonumber(playerOrUserId)
    end
    if not userId then
        return
    end

    local record = self._recoverEffectsByUserId[userId]
    self._recoverEffectsByUserId[userId] = nil
    if record and record.Instance then
        record.Instance:Destroy()
    end

    if player then
        local character = ActorUtils.GetCharacter(player)
        local effectConfig = self:_getRecoverEffectConfig()
        local staleEffect = character and character:FindFirstChild(effectConfig.InstanceName)
        if staleEffect then
            staleEffect:Destroy()
        end
    end
end

function HealthService:_ensureRecoverEffect(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false
    end

    local character = ActorUtils.GetCharacter(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (character and rootPart) then
        self:_removeRecoverEffect(player)
        return false
    end

    local effectConfig = self:_getRecoverEffectConfig()
    local record = self._recoverEffectsByUserId[player.UserId]
    if record and record.Instance and record.Instance.Parent == character and record.Character == character then
        return true
    end

    self:_removeRecoverEffect(player)
    local staleEffect = character:FindFirstChild(effectConfig.InstanceName)
    if staleEffect then
        staleEffect:Destroy()
    end

    local template = self:_getRecoverTemplate()
    if not template then
        warn(string.format("[HealthService] 缺少回血特效模板 ReplicatedStorage.%s", effectConfig.TemplateName))
        return false
    end

    local footBottomY = self:_getCharacterFootBottomY(character, rootPart)
    if not footBottomY then
        return false
    end

    local effect = template:Clone()
    effect.Name = effectConfig.InstanceName

    if not self:_positionCharacterFloorEffect(effect, rootPart, footBottomY)
        or not self:_attachCharacterFloorEffect(effect, rootPart, "HealthRegenRecoverWeld")
    then
        effect:Destroy()
        return false
    end

    effect.Parent = character
    self._recoverEffectsByUserId[player.UserId] = {
        Instance = effect,
        Character = character,
    }
    return true
end

function HealthService:_removeShieldEffect(playerOrUserId)
    local userId = nil
    local player = nil
    if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
        player = playerOrUserId
        userId = playerOrUserId.UserId
    else
        userId = tonumber(playerOrUserId)
    end
    if not userId then
        return
    end

    local record = self._shieldEffectsByUserId[userId]
    self._shieldEffectsByUserId[userId] = nil
    if record and record.Instance then
        record.Instance:Destroy()
    end

    if player then
        local character = ActorUtils.GetCharacter(player)
        local effectConfig = self:_getShieldEffectConfig()
        local staleEffect = character and character:FindFirstChild(effectConfig.InstanceName)
        if staleEffect then
            staleEffect:Destroy()
        end
    end
end

function HealthService:_ensureShieldEffect(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false
    end

    local character = ActorUtils.GetCharacter(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (character and rootPart) then
        self:_removeShieldEffect(player)
        return false
    end

    local effectConfig = self:_getShieldEffectConfig()
    local record = self._shieldEffectsByUserId[player.UserId]
    if record and record.Instance and record.Instance.Parent == character and record.Character == character then
        return true
    end

    self:_removeShieldEffect(player)
    local staleEffect = character:FindFirstChild(effectConfig.InstanceName)
    if staleEffect then
        staleEffect:Destroy()
    end

    local template = self:_getShieldTemplate()
    if not template then
        if not self._missingShieldTemplateWarned then
            self._missingShieldTemplateWarned = true
            warn(string.format("[HealthService] 缺少护盾特效模板 ReplicatedStorage.%s", effectConfig.TemplateName))
        end
        return false
    end
    self._missingShieldTemplateWarned = false

    local footBottomY = self:_getCharacterFootBottomY(character, rootPart)
    if not footBottomY then
        return false
    end

    local effect = template:Clone()
    effect.Name = effectConfig.InstanceName

    if not self:_positionCharacterFloorEffect(effect, rootPart, footBottomY)
        or not self:_attachCharacterFloorEffect(effect, rootPart, "ActiveShieldEffectWeld")
    then
        effect:Destroy()
        return false
    end

    effect.Parent = character
    self._shieldEffectsByUserId[player.UserId] = {
        Instance = effect,
        Character = character,
    }
    return true
end

function HealthService:_clearShield(playerOrUserId, removeEffectOnly)
    local userId = nil
    if typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
        userId = playerOrUserId.UserId
    else
        userId = tonumber(playerOrUserId)
    end
    if not userId then
        return
    end

    if removeEffectOnly ~= true then
        self._shieldExpiresAtByUserId[userId] = nil
    end
    self:_removeShieldEffect(playerOrUserId)
    self:_updateShieldOverheadUi(playerOrUserId)
end

function HealthService:_getShieldExpiresAt(player)
    if not ActorUtils.IsPlayer(player) then
        return nil
    end

    local expiresAt = tonumber(self._shieldExpiresAtByUserId[player.UserId])
    if not expiresAt then
        return nil
    end

    if expiresAt <= os.clock() then
        self:_clearShield(player)
        return nil
    end
    return expiresAt
end

function HealthService:_shouldShowShieldEffect(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false
    end

    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    return state and state.Alive == true
end

function HealthService:GetShieldState(player)
    local expiresAt = self:_getShieldExpiresAt(player)
    if not expiresAt then
        return {
            shieldActive = false,
            shieldRemainingSeconds = 0,
            shieldExpiresAt = nil,
        }
    end

    return {
        shieldActive = true,
        shieldRemainingSeconds = math.max(0, math.ceil(expiresAt - os.clock())),
        shieldExpiresAt = expiresAt,
    }
end

function HealthService:IsShieldActive(actor)
    if not ActorUtils.IsPlayer(actor) then
        return false
    end
    return self:_getShieldExpiresAt(actor) ~= nil
end

function HealthService:GrantShield(player, durationSeconds, source)
    if not (ActorUtils.IsPlayer(player) and player.Parent) then
        return false, "InvalidPlayer"
    end

    local config = self:_getShieldConfig()
    local duration = math.max(0, tonumber(durationSeconds) or config.DurationSeconds)
    if duration <= 0 then
        return false, "InvalidDuration"
    end

    local now = os.clock()
    local currentExpiresAt = tonumber(self._shieldExpiresAtByUserId[player.UserId]) or 0
    local expiresAt = math.max(currentExpiresAt, now) + duration
    self._shieldExpiresAtByUserId[player.UserId] = expiresAt
    if self:_shouldShowShieldEffect(player) then
        self:_ensureShieldEffect(player)
    else
        self:_removeShieldEffect(player)
    end
    self:_updateShieldOverheadUi(player)

    if self._playerStateService then
        self._playerStateService:PushState(player)
    end

    return true, "Granted", expiresAt
end

function HealthService:_getHealthRegenConfig()
    local config = GameConfig.HEALTH_REGEN or {}
    return {
        Enabled = config.Enabled ~= false,
        OutOfCombatDelaySeconds = math.max(0, tonumber(config.OutOfCombatDelaySeconds) or 3),
        TickSeconds = math.max(0.1, tonumber(config.TickSeconds) or 1),
        MaxHealthPercentPerTick = math.max(0, tonumber(config.MaxHealthPercentPerTick) or 0.01),
    }
end

function HealthService:_tryRegeneratePlayer(player, now, config)
    if not (player and player.Parent and self._playerStateService) then
        self:_removeRecoverEffect(player)
        return false
    end

    local state = self._playerStateService:GetState(player)
    if not (state and state.Alive == true and state.IsInArena == true) then
        self:_removeRecoverEffect(player)
        return false
    end

    local maxHealth = math.max(1, math.floor(tonumber(state.MaxHealth) or 1))
    local currentHealth = math.clamp(math.floor(tonumber(state.CurrentHealth) or maxHealth), 0, maxHealth)
    if currentHealth >= maxHealth then
        self:_removeRecoverEffect(player)
        return false
    end

    local lastDamageClock = self._lastDamageClockByUserId[player.UserId]
    if lastDamageClock and now - lastDamageClock < config.OutOfCombatDelaySeconds then
        self:_removeRecoverEffect(player)
        return false
    end

    local regenPercentPerSecond = 0
    if self._playerStateService.GetHealthRegenPercentPerSecond then
        regenPercentPerSecond = self._playerStateService:GetHealthRegenPercentPerSecond(player)
    end
    if regenPercentPerSecond <= 0 then
        self:_removeRecoverEffect(player)
        return false
    end

    local healAmount = math.max(1, math.floor((maxHealth * regenPercentPerSecond * config.TickSeconds) + 0.5))
    state.CurrentHealth = math.min(maxHealth, currentHealth + healAmount)
    self:_ensureRecoverEffect(player)
    self._playerStateService:SyncHumanoidHealth(player)
    self._playerStateService:PushState(player)
    return true
end

function HealthService:_step()
    local config = self:_getHealthRegenConfig()
    local now = os.clock()
    if not config.Enabled then
        for userId in pairs(self._recoverEffectsByUserId) do
            self:_removeRecoverEffect(userId)
        end
    elseif now >= self._nextRegenClock then
        self._nextRegenClock = now + config.TickSeconds

        for _, player in ipairs(Players:GetPlayers()) do
            self:_tryRegeneratePlayer(player, now, config)
        end
    end

    if now < self._nextShieldClock then
        return
    end
    self._nextShieldClock = now + (self:_getShieldConfig()).TickSeconds

    for _, player in ipairs(Players:GetPlayers()) do
        local expiresAt = tonumber(self._shieldExpiresAtByUserId[player.UserId])
        if expiresAt then
            if expiresAt <= now then
                self:_clearShield(player)
                if self._playerStateService then
                    self._playerStateService:PushState(player)
                end
            elseif not self:_shouldShowShieldEffect(player) then
                self:_removeShieldEffect(player)
                self:_updateShieldOverheadUi(player)
            else
                self:_ensureShieldEffect(player)
                self:_updateShieldOverheadUi(player)
            end
        end
    end
end

function HealthService:ApplyWeaponDamage(targetActor, damage, sourceActor)
    if not targetActor then
        return false, false, nil
    end

    local state = self._playerStateService:GetState(targetActor)
    if not (state and state.Alive and state.IsInArena) then
        return false, false, state and state.CurrentHealth or nil
    end

    if self:_isSafeZoneProtected(targetActor) or self:_isSafeZoneProtected(sourceActor) then
        return false, false, state.CurrentHealth
    end

    local damageMultiplier = 1
    if sourceActor and self._buffService then
        damageMultiplier = self._buffService:GetDamageMultiplier(sourceActor)
    end
    local appliedDamage = math.max(0, math.floor((tonumber(damage) or 0) * damageMultiplier))
    if appliedDamage <= 0 then
        return false, false, state.CurrentHealth
    end

    if self:IsShieldActive(targetActor) then
        if self._playerStateService then
            self._playerStateService:PushState(targetActor)
        end
        return true, false, state.CurrentHealth
    end

    self:_recordDamageTaken(targetActor)
    self:_removeRecoverEffect(targetActor)
    state.CurrentHealth = math.max(0, state.CurrentHealth - appliedDamage)
    local remainingHealthAfterDamage = state.CurrentHealth
    local didKill = state.CurrentHealth <= 0
    if didKill then
        state.Alive = false
    end
    self._playerStateService:SyncHumanoidHealth(targetActor)
    self._playerStateService:PushState(targetActor)

    if didKill then
        self:_handleActorKill(targetActor, sourceActor)
    end

    return true, didKill, remainingHealthAfterDamage
end

function HealthService:KillActor(targetActor, sourceActor, options)
    if not targetActor then
        return false, false, nil
    end

    local state = self._playerStateService:GetState(targetActor)
    if not (state and state.Alive) then
        return false, false, state and state.CurrentHealth or nil
    end

    state.CurrentHealth = 0
    state.Alive = false
    self:_clearDamageTracking(targetActor)
    self:_removeRecoverEffect(targetActor)
    self:_removeShieldEffect(targetActor)
    self._playerStateService:SyncHumanoidHealth(targetActor)
    self:_updateShieldOverheadUi(targetActor)
    self._playerStateService:PushState(targetActor)
    self:_handleActorKill(targetActor, sourceActor, options)
    return true, true, 0
end

function HealthService:_runSyntheticStudioDefeatedTest(player)
    if not RunService:IsStudio() then
        return false, "StudioOnly"
    end
    if not (
        ActorUtils.IsPlayer(player)
        and player.Parent
        and self._playerStateService
        and self._respawnService
        and self._deathFeedbackEvent
        and self._respawnService._nextDeathSerial
        and self._respawnService._captureCombatSnapshot
        and self._respawnService._recordPlayerDefeat
    ) then
        return false, "ServiceUnavailable"
    end

    local state = self._playerStateService:GetState(player)
    if not (state and state.Alive == true) then
        return false, "AlreadyDead"
    end

    local victimLevel = math.clamp(
        math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    local deathSerial = self._respawnService:_nextDeathSerial(player)
    state.CurrentHealth = 0
    state.Alive = false
    self:_clearDamageTracking(player)
    self:_removeRecoverEffect(player)
    self:_removeShieldEffect(player)
    self._playerStateService:SyncHumanoidHealth(player)
    self:_updateShieldOverheadUi(player)
    self._playerStateService:PushState(player)

    if self._playerStateService.RecordDeath then
        self._playerStateService:RecordDeath(player)
    end
    local combatSnapshot = self._respawnService:_captureCombatSnapshot(player, deathSerial)
    self._playerStateService:ResetCombatState(player)
    if self._respawnService._weaponService and self._respawnService._weaponService.ClearPlayerWeapons then
        self._respawnService._weaponService:ClearPlayerWeapons(player)
    end
    self._playerStateService:PushState(player)
    self._respawnService:_recordPlayerDefeat(player, nil, deathSerial, combatSnapshot)

    self._deathFeedbackEvent:FireClient(player, {
        reason = "GMTestDefeated",
        killerUserId = 0,
        killer = {
            userId = 0,
            name = "GM Test Killer",
            level = victimLevel,
            killCount = 0,
            totalPlayerKills = 0,
        },
        victimLevel = victimLevel,
        freeRespawnLevel = getHalfFreeRespawnLevel(victimLevel),
        timestamp = os.clock(),
    })
    return true, "Synthetic"
end

function HealthService:RunStudioDefeatedTest(player)
    if not RunService:IsStudio() then
        return false, "StudioOnly"
    end
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end

    local killer = findStudioTestKiller(self._playerStateService, player)
    if killer then
        local success, didKill = self:KillActor(player, killer)
        if success and didKill then
            return true, "KilledByPlayer", killer
        end
        return false, "KillFailed", killer
    end

    return self:_runSyntheticStudioDefeatedTest(player)
end

function HealthService:ResetPlayerHealth(actor)
    self:_clearDamageTracking(actor)
    self:_removeRecoverEffect(actor)
    if self:IsShieldActive(actor) then
        self:_ensureShieldEffect(actor)
    end
    local state = self._playerStateService:GetState(actor)
    if self._playerStateService.RecalculateDerivedStats then
        state = self._playerStateService:RecalculateDerivedStats(actor, {
            restoreFullHealth = true,
        }) or state
    else
        state.MaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    end
    state.CurrentHealth = state.MaxHealth
    self._playerStateService:SyncHumanoidHealth(actor)
    self:_updateShieldOverheadUi(actor)
    self._playerStateService:PushState(actor)
end

function HealthService:OnPlayerRemoving(player)
    self:_clearDamageTracking(player)
    self:_removeRecoverEffect(player)
    self:_clearShield(player)
end

function HealthService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._remoteEventService = dependencies.RemoteEventService
    self._respawnService = dependencies.RespawnService
    self._arenaService = dependencies.ArenaService
    self._buffService = dependencies.BuffService
    self._gameAnalyticsService = dependencies.GameAnalyticsService
    self._deathFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("DeathFeedback") or nil
    self._killInfoFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("KillInfoFeedback") or nil
    self._lastDamageClockByUserId = {}
    self._recoverEffectsByUserId = {}
    self._shieldEffectsByUserId = {}
    self._shieldExpiresAtByUserId = {}
    self._missingShieldTemplateWarned = false
    self._nextRegenClock = os.clock() + (self:_getHealthRegenConfig()).TickSeconds
    self._nextShieldClock = os.clock() + (self:_getShieldConfig()).TickSeconds

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end
    self._heartbeatConnection = RunService.Heartbeat:Connect(function()
        self:_step()
    end)
end

return HealthService
