--[[
脚本名字: RespawnService
脚本文件: RespawnService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/RespawnService
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[RespawnService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local SubscriptionConfig = requireSharedModule("SubscriptionConfig")

local RespawnService = {}

RespawnService._playerStateService = nil
RespawnService._weaponService = nil
RespawnService._arenaService = nil
RespawnService._botService = nil
RespawnService._revengeService = nil
RespawnService._requestDefeatedActionEvent = nil
RespawnService._requestDefeatedActionConnection = nil
RespawnService._arenaTransitionFeedbackEvent = nil
RespawnService._gameAnalyticsService = nil
RespawnService._deathSerialByActorId = {}
RespawnService._defeatRecordsByUserId = {}
RespawnService._arenaRevivePendingByUserId = {}
RespawnService._arenaReviveOptionsByUserId = {}
RespawnService._hasDiedThisSessionByUserId = {}

local function getActorId(actor)
    return ActorUtils.GetActorId(actor)
end

local function getUserId(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.UserId
    end
    return 0
end

function RespawnService:_nextDeathSerial(actor)
    local actorId = getActorId(actor)
    local nextSerial = (self._deathSerialByActorId[actorId] or 0) + 1
    self._deathSerialByActorId[actorId] = nextSerial
    return nextSerial
end

function RespawnService:_getDeathSerial(actor)
    return self._deathSerialByActorId[getActorId(actor)] or 0
end

function RespawnService:_clearDefeatRecord(player)
    local userId = getUserId(player)
    if userId > 0 then
        self._defeatRecordsByUserId[userId] = nil
    end
end

function RespawnService:GetDefeatRecord(player)
    local userId = getUserId(player)
    if userId <= 0 then
        return nil
    end
    return self._defeatRecordsByUserId[userId]
end

function RespawnService:IsCurrentDefeatRecord(player, defeatRecord)
    if not ActorUtils.IsPlayer(player) then
        return false
    end
    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    return state
        and state.Alive == false
        and self:IsDefeatRecordForCurrentDeath(player, defeatRecord)
end

function RespawnService:IsDefeatRecordForCurrentDeath(player, defeatRecord)
    if not ActorUtils.IsPlayer(player) then
        return false
    end

    return defeatRecord
        and tonumber(defeatRecord.deathSerial) == self:_getDeathSerial(player)
end

function RespawnService:_getDailyFreeReviveConfig()
    local respawnConfig = GameConfig.RESPAWN or {}
    return tostring(respawnConfig.DailyFreeReviveClaimKey or "DefeatedDailyFreeRevive"),
        math.max(1, math.floor(tonumber(respawnConfig.DailyFreeReviveLevelMaxExclusive) or 30))
end

function RespawnService:_buildDailyFreeReviveStatus(player, combatSnapshot, isFirstDeathThisSession)
    if not (ActorUtils.IsPlayer(player) and self._playerStateService and type(combatSnapshot) == "table") then
        return {
            eligible = false,
        }
    end

    local claimKey, levelMaxExclusive = self:_getDailyFreeReviveConfig()
    local utcDay = SubscriptionConfig.GetCurrentUtcDay()
    local preDeathLevel = math.max(1, math.floor(tonumber(combatSnapshot.preDeathLevel) or GameConfig.PLAYER.BaseLevel))
    local alreadyClaimed = self._playerStateService.HasDailyFreeReviveClaim
        and self._playerStateService:HasDailyFreeReviveClaim(player, claimKey, utcDay) == true
        or false
    local eligible = isFirstDeathThisSession == true
        and preDeathLevel < levelMaxExclusive
        and not alreadyClaimed

    return {
        eligible = eligible,
        claimKey = claimKey,
        utcDay = utcDay,
        level = preDeathLevel,
        levelMaxExclusive = levelMaxExclusive,
        alreadyClaimed = alreadyClaimed,
    }
end

function RespawnService:PeekDailyFreeReviveStatus(player)
    if not ActorUtils.IsPlayer(player) then
        return {
            eligible = false,
        }
    end

    local userId = getUserId(player)
    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    local combatSnapshot = state and {
        preDeathLevel = state.Level,
    } or nil
    return self:_buildDailyFreeReviveStatus(player, combatSnapshot, userId > 0 and self._hasDiedThisSessionByUserId[userId] ~= true)
end

function RespawnService:_setArenaRevivePending(player, options)
    local userId = getUserId(player)
    if userId > 0 then
        self._arenaRevivePendingByUserId[userId] = {
            preserveDefeatRecord = type(options) == "table" and options.preserveDefeatRecord == true or false,
        }
    end
end

function RespawnService:_clearArenaRevivePending(player)
    local userId = getUserId(player)
    if userId > 0 then
        self._arenaRevivePendingByUserId[userId] = nil
        self._arenaReviveOptionsByUserId[userId] = nil
    end
end

function RespawnService:ConsumeArenaReviveRequest(player)
    local userId = getUserId(player)
    if userId <= 0 or self._arenaRevivePendingByUserId[userId] == nil then
        return false
    end

    self._arenaReviveOptionsByUserId[userId] = self._arenaRevivePendingByUserId[userId]
    self._arenaRevivePendingByUserId[userId] = nil
    return true
end

function RespawnService:_fireSkipSpawnCameraLook(player)
    if not (self._arenaTransitionFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._arenaTransitionFeedbackEvent:FireClient(player, {
        status = "SkipSpawnCameraLook",
        spawnMode = "ArenaRevive",
        timestamp = os.clock(),
    })
end

function RespawnService:_waitForUsableCharacter(player, timeoutSeconds)
    local deadline = os.clock() + math.max(0.2, tonumber(timeoutSeconds) or 3)
    repeat
        local humanoid = ActorUtils.GetHumanoid(player)
        local rootPart = ActorUtils.GetRootPart(player)
        if humanoid and rootPart and humanoid.Health > 0 then
            return true
        end
        task.wait(0.05)
    until os.clock() >= deadline
    return false
end

function RespawnService:CompleteArenaRevive(player, options)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._arenaService and self._playerStateService) then
        return false
    end

    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (humanoid and rootPart and humanoid.Health > 0) then
        if not self:_waitForUsableCharacter(player, 3) then
            return false
        end
    end

    local userId = getUserId(player)
    local reviveOptions = type(options) == "table" and options or self._arenaReviveOptionsByUserId[userId]
    self._arenaReviveOptionsByUserId[userId] = nil
    if not (type(reviveOptions) == "table" and reviveOptions.preserveDefeatRecord == true) then
        self:_clearDefeatRecord(player)
    end
    local state = self._playerStateService:GetState(player)
    state.Alive = true
    state.IsInArena = false
    state.Buffs = {}
    state.MaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    state.CurrentHealth = state.MaxHealth
    self._playerStateService:SyncCharacterState(player)
    self._playerStateService:UpdateOverheadHealthBar(player)
    self._playerStateService:PushState(player)
    return self._arenaService:TryEnterArena(player, {
        IgnoreDebounce = true,
        IsRevive = true,
    }) == true
end

function RespawnService:_revivePlayerNow(player, options)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._arenaService and self._playerStateService) then
        return false
    end

    local preserveDefeatRecord = type(options) == "table" and options.preserveDefeatRecord == true
    if not preserveDefeatRecord then
        self:_clearDefeatRecord(player)
    end
    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (humanoid and rootPart and humanoid.Health > 0) then
        self:_setArenaRevivePending(player, {
            preserveDefeatRecord = preserveDefeatRecord,
        })
        self:_fireSkipSpawnCameraLook(player)
        local didLoad = pcall(function()
            player:LoadCharacter()
        end)
        if not didLoad then
            self:_clearArenaRevivePending(player)
            return false
        end
        return true
    end

    return self:CompleteArenaRevive(player, {
        preserveDefeatRecord = preserveDefeatRecord,
    })
end

function RespawnService:RevivePlayer(player)
    return self:_revivePlayerNow(player)
end

function RespawnService:_schedulePlayerRevive(player, delaySeconds, deathSerial)
    task.delay(math.max(0, tonumber(delaySeconds) or 0), function()
        if not (player and player.Parent) then
            return
        end
        if self:_getDeathSerial(player) ~= deathSerial then
            return
        end

        local defeatRecord = self:GetDefeatRecord(player)
        if defeatRecord and defeatRecord.deathSerial == deathSerial and defeatRecord.revengePending == true then
            return
        end

        local state = self._playerStateService and self._playerStateService:GetState(player) or nil
        if state and state.Alive == true and state.IsInArena == true then
            return
        end
        if self._gameAnalyticsService and self:IsDefeatRecordForCurrentDeath(player, defeatRecord) then
            self._gameAnalyticsService:TrackCustom(player, "AutoRespawned", 1, {
                source = "defeated",
            })
        end
        self:_revivePlayerNow(player, {
            preserveDefeatRecord = defeatRecord and defeatRecord.revivePurchasePending == true or false,
        })
    end)
end

function RespawnService:_captureCombatSnapshot(actor, deathSerial)
    local state = self._playerStateService and self._playerStateService:GetState(actor) or nil
    if not state then
        return nil
    end

    local preDeathLevel = math.clamp(
        math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    return {
        deathSerial = deathSerial,
        preDeathLevel = preDeathLevel,
        preDeathExperience = math.max(0, math.floor(tonumber(state.Experience) or GameConfig.PLAYER.BaseExperience)),
        preDeathKillCount = math.max(0, math.floor(tonumber(state.KillCount) or 0)),
        capturedAt = os.clock(),
    }
end

function RespawnService:_recordPlayerDefeat(player, sourceActor, deathSerial, combatSnapshot)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    local killerUserId = ActorUtils.IsPlayer(sourceActor) and sourceActor.UserId or nil
    local dailyFreeReviveStatus = self:_buildDailyFreeReviveStatus(player, combatSnapshot, combatSnapshot and combatSnapshot.isFirstDeathThisSession == true)
    self._defeatRecordsByUserId[player.UserId] = {
        deathSerial = deathSerial,
        killerUserId = killerUserId,
        killerName = sourceActor and ActorUtils.GetActorName(sourceActor) or "",
        createdAt = os.clock(),
        expiresAt = os.clock() + math.max(1, tonumber(GameConfig.RESPAWN.PlayerKillReviveCountdownSeconds) or 15),
        revivePurchasePending = false,
        combatSnapshot = combatSnapshot,
        dailyFreeReviveEligible = dailyFreeReviveStatus.eligible == true,
        dailyFreeReviveClaimKey = dailyFreeReviveStatus.claimKey,
        dailyFreeReviveUtcDay = dailyFreeReviveStatus.utcDay,
        dailyFreeReviveLevel = dailyFreeReviveStatus.level,
        revengePending = false,
        revengePromptClosed = false,
    }

    if self._gameAnalyticsService then
        self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 1, "DefeatedPanelShown", {
            source = "defeated",
        })
    end
end

function RespawnService:HandleActorDeath(actor, sourceActor)
    if not actor then
        return
    end

    local deathSerial = self:_nextDeathSerial(actor)
    local wasFirstDeathThisSession = false
    if ActorUtils.IsPlayer(actor) then
        local userId = getUserId(actor)
        wasFirstDeathThisSession = userId > 0 and self._hasDiedThisSessionByUserId[userId] ~= true
        if userId > 0 then
            self._hasDiedThisSessionByUserId[userId] = true
        end
    end
    local combatSnapshot = self:_captureCombatSnapshot(actor, deathSerial)
    if combatSnapshot then
        combatSnapshot.isFirstDeathThisSession = wasFirstDeathThisSession == true
    end
    self._playerStateService:ResetCombatState(actor)
    if self._weaponService then
        self._weaponService:ClearPlayerWeapons(actor)
    end
    self._playerStateService:PushState(actor)

    if ActorUtils.IsBot(actor) and self._botService then
        self._botService:ScheduleRespawn(actor)
    elseif ActorUtils.IsPlayer(actor) then
        if ActorUtils.IsPlayer(sourceActor) and not ActorUtils.IsSameActor(actor, sourceActor) then
            self:_recordPlayerDefeat(actor, sourceActor, deathSerial, combatSnapshot)
            self:_schedulePlayerRevive(actor, GameConfig.RESPAWN.PlayerKillReviveCountdownSeconds, deathSerial)
        else
            self:_clearDefeatRecord(actor)
            self:_schedulePlayerRevive(actor, GameConfig.RESPAWN.MonsterKillAutoReviveSeconds, deathSerial)
        end
    end
end

function RespawnService:HandlePlayerDeath(actor)
    self:HandleActorDeath(actor)
end

function RespawnService:_onRequestDefeatedAction(player, action)
    if not (player and player.Parent) then
        return
    end

    local normalizedAction = tostring(action or "")
    local state = self._playerStateService and self._playerStateService:GetState(player) or nil
    local defeatRecord = self:GetDefeatRecord(player)
    local currentDeathSerial = self:_getDeathSerial(player)
    if not (state and currentDeathSerial > 0) then
        return
    end

    if normalizedAction == "Revive" then
        if state.Alive ~= false then
            return
        end
        self:_revivePlayerNow(player, {
            preserveDefeatRecord = defeatRecord and defeatRecord.revivePurchasePending == true or false,
        })
    elseif normalizedAction == "Close" then
        if state.Alive ~= false then
            return
        end
        if self:_tryGrantDailyFreeRevive(player, defeatRecord) then
            return
        end
        self:RevivePlayer(player)
    elseif normalizedAction == "RevivePurchase" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revivePurchasePending = true
        if self._gameAnalyticsService then
            self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 2, "ReviveButtonClicked", {
                source = "defeated",
            })
            self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 3, "RevivePurchaseIntent", {
                source = "defeated",
            })
        end
    elseif normalizedAction == "RevivePurchaseCancel" then
        if not self:IsDefeatRecordForCurrentDeath(player, defeatRecord) then
            return
        end
        defeatRecord.revivePurchasePending = false
        if self._gameAnalyticsService then
            self._gameAnalyticsService:TrackCustom(player, "RevivePurchaseCancel", 1, {
                source = "defeated",
            })
        end
        if state.Alive == false then
            self:_schedulePlayerRevive(
                player,
                math.max(0, (tonumber(defeatRecord.expiresAt) or os.clock()) - os.clock()),
                defeatRecord.deathSerial
            )
        else
            self:_clearDefeatRecord(player)
        end
    elseif normalizedAction == "Revenge" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revengePending = true
    elseif normalizedAction == "RevengePromptClosed" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revengePromptClosed = true
        if defeatRecord.revengePending ~= true then
            return
        end
        if self._revengeService and self._revengeService.CompletePendingRevenge then
            self._revengeService:CompletePendingRevenge(player)
        end
    elseif normalizedAction == "RevengeCancel" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revengePending = false
        defeatRecord.revengePromptClosed = false
        if self._revengeService and self._revengeService.CancelPendingRevenge then
            self._revengeService:CancelPendingRevenge(player)
        end
        self:_schedulePlayerRevive(
            player,
            math.max(0, (tonumber(defeatRecord.expiresAt) or os.clock()) - os.clock()),
            defeatRecord.deathSerial
        )
    end
end

function RespawnService:_tryGrantDailyFreeRevive(player, defeatRecord)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false
    end
    if not self:IsCurrentDefeatRecord(player, defeatRecord) then
        return false
    end
    if defeatRecord.dailyFreeReviveEligible ~= true then
        return false
    end

    local snapshot = defeatRecord.combatSnapshot
    if type(snapshot) ~= "table" then
        return false
    end

    local claimKey = tostring(defeatRecord.dailyFreeReviveClaimKey or "")
    local utcDay = tostring(defeatRecord.dailyFreeReviveUtcDay or "")
    if claimKey == "" or utcDay == "" then
        return false
    end
    if self._playerStateService.HasDailyFreeReviveClaim
        and self._playerStateService:HasDailyFreeReviveClaim(player, claimKey, utcDay) == true then
        return false
    end

    local revived = self:_revivePlayerNow(player, {
        preserveDefeatRecord = true,
    })
    if not revived then
        return false
    end

    if not self._playerStateService.RestoreCombatProgress then
        self:_clearDefeatRecord(player)
        return true
    end

    local restored = self._playerStateService:RestoreCombatProgress(player, snapshot, {
        restoreFullHealth = true,
        rebuildWeapons = true,
    })
    if not restored then
        self:_clearDefeatRecord(player)
        return true
    end

    if not (self._playerStateService.MarkDailyFreeReviveClaim and self._playerStateService:MarkDailyFreeReviveClaim(player, claimKey, utcDay)) then
        self:_clearDefeatRecord(player)
        return true
    end

    if self._gameAnalyticsService then
        self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 5, "DailyFreeRevivedSuccessfully", {
            source = "defeated",
        })
    end

    self:_clearDefeatRecord(player)
    return true
end

function RespawnService:GrantDefeatedRevivePurchase(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false
    end

    local defeatRecord = self:GetDefeatRecord(player)
    if not defeatRecord then
        return true
    end

    if not self:IsDefeatRecordForCurrentDeath(player, defeatRecord) then
        self:_clearDefeatRecord(player)
        return true
    end

    if defeatRecord.revivePurchasePending ~= true then
        if self:IsCurrentDefeatRecord(player, defeatRecord) then
            return false
        end
        self:_clearDefeatRecord(player)
        return true
    end

    local snapshot = defeatRecord.combatSnapshot
    if type(snapshot) ~= "table" then
        self:_clearDefeatRecord(player)
        return true
    end

    local state = self._playerStateService:GetState(player)
    local wasAlreadyAlive = state and state.Alive == true
    if state and state.Alive == false then
        local revived = self:_revivePlayerNow(player, {
            preserveDefeatRecord = true,
        })
        if not revived then
            return false
        end
    end

    if not self._playerStateService.RestoreCombatProgress then
        return false
    end

    local restored = self._playerStateService:RestoreCombatProgress(player, snapshot, {
        restoreFullHealth = true,
        rebuildWeapons = true,
    })
    if not restored then
        return false
    end

    if self._gameAnalyticsService then
        if wasAlreadyAlive then
            self._gameAnalyticsService:TrackCustom(player, "LatePurchaseCompensated", 1, {
                source = "defeated",
            })
        end
        self._gameAnalyticsService:TrackFunnel(player, "DefeatedRevive", 5, "RevivedSuccessfully", {
            source = "defeated",
        })
    end

    self:_clearDefeatRecord(player)
    return true
end

function RespawnService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._arenaService = dependencies.ArenaService
    self._botService = dependencies.BotService
    self._revengeService = dependencies.RevengeService or self._revengeService
    self._gameAnalyticsService = dependencies.GameAnalyticsService
    self._requestDefeatedActionEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestDefeatedAction") or nil
    self._arenaTransitionFeedbackEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("ArenaTransitionFeedback") or nil
    self._deathSerialByActorId = {}
    self._defeatRecordsByUserId = {}
    self._arenaRevivePendingByUserId = {}
    self._arenaReviveOptionsByUserId = {}
    self._hasDiedThisSessionByUserId = {}

    if self._requestDefeatedActionConnection then
        self._requestDefeatedActionConnection:Disconnect()
        self._requestDefeatedActionConnection = nil
    end
    if self._requestDefeatedActionEvent then
        self._requestDefeatedActionConnection = self._requestDefeatedActionEvent.OnServerEvent:Connect(function(player, action)
            self:_onRequestDefeatedAction(player, action)
        end)
    end
end

function RespawnService:OnPlayerRemoving(player)
    self:_clearDefeatRecord(player)
    self:_clearArenaRevivePending(player)
    if self._revengeService and self._revengeService.OnPlayerRemoving then
        self._revengeService:OnPlayerRemoving(player)
    end
    self._deathSerialByActorId[getActorId(player)] = nil
    local userId = getUserId(player)
    if userId > 0 then
        self._hasDiedThisSessionByUserId[userId] = nil
    end
end

return RespawnService
