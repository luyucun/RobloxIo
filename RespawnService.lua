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
RespawnService._offlineRespawnSaveSnapshotByUserId = {}

local function getActorId(actor)
    return ActorUtils.GetActorId(actor)
end

local function getUserId(actor)
    if ActorUtils.IsPlayer(actor) then
        return actor.UserId
    end
    return 0
end

local function getHalfFreeRespawnLevel(combatSnapshot)
    local preDeathLevel = math.clamp(
        math.floor(tonumber(combatSnapshot and combatSnapshot.preDeathLevel) or GameConfig.PLAYER.BaseLevel),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
    return math.clamp(
        math.floor(preDeathLevel / 2),
        GameConfig.PLAYER.BaseLevel,
        GameConfig.PLAYER.MaxSupportedLevel
    )
end

local function buildHalfLevelRespawnSnapshot(combatSnapshot)
    if type(combatSnapshot) ~= "table" then
        return nil
    end

    return {
        preDeathLevel = getHalfFreeRespawnLevel(combatSnapshot),
        preDeathExperience = GameConfig.PLAYER.BaseExperience,
        preDeathKillCount = 0,
    }
end

local function buildOfflineRespawnSaveSnapshot(combatSnapshot)
    local halfLevelSnapshot = buildHalfLevelRespawnSnapshot(combatSnapshot)
    if not halfLevelSnapshot then
        return nil
    end

    return {
        schemaVersion = 1,
        restoreEligible = true,
        respawnMode = "DefeatedHalfLevel",
        savedAt = os.time(),
        level = halfLevelSnapshot.preDeathLevel,
        experience = halfLevelSnapshot.preDeathExperience,
    }
end

local function getDefeatedAnalyticsSessionKey(defeatRecord)
    if type(defeatRecord) ~= "table" then
        return nil
    end

    return defeatRecord.analyticsSessionKey
end

local function trackDefeatedFunnel(gameAnalyticsService, player, defeatRecord, funnelName, stepNumber, stepName, fields)
    if not gameAnalyticsService then
        return
    end

    gameAnalyticsService:TrackFunnel(player, funnelName, stepNumber, stepName, fields, {
        sessionKey = getDefeatedAnalyticsSessionKey(defeatRecord),
    })
end

local function copyOfflineRespawnSaveSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return nil
    end

    return {
        schemaVersion = math.max(1, math.floor(tonumber(snapshot.schemaVersion) or 1)),
        restoreEligible = snapshot.restoreEligible == true,
        respawnMode = tostring(snapshot.respawnMode or ""),
        savedAt = math.max(0, math.floor(tonumber(snapshot.savedAt) or os.time())),
        level = math.clamp(
            math.floor(tonumber(snapshot.level) or GameConfig.PLAYER.BaseLevel),
            GameConfig.PLAYER.BaseLevel,
            GameConfig.PLAYER.MaxSupportedLevel
        ),
        experience = math.max(0, math.floor(tonumber(snapshot.experience) or GameConfig.PLAYER.BaseExperience)),
    }
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

function RespawnService:_restoreLobbyProgress(player, halfLevelSnapshot)
    if not (ActorUtils.IsPlayer(player) and player.Parent and halfLevelSnapshot
        and self._playerStateService and self._playerStateService.RestoreCombatProgress) then
        return false
    end

    self:_clearArenaRevivePending(player)
    if self._weaponService and self._weaponService.ClearPlayerWeapons then
        self._weaponService:ClearPlayerWeapons(player)
    end

    return self._playerStateService:RestoreCombatProgress(player, halfLevelSnapshot, {
        restoreFullHealth = true,
        rebuildWeapons = false,
        restoreToLobby = true,
    }) == true
end

function RespawnService:_revivePlayerToLobby(player, defeatRecord)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService
        and self._arenaService and self:IsCurrentDefeatRecord(player, defeatRecord)) then
        return false
    end
    local halfLevelSnapshot = buildHalfLevelRespawnSnapshot(defeatRecord.combatSnapshot)
    if not halfLevelSnapshot then
        return false
    end
    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    local needsCharacter = not (humanoid and rootPart and humanoid.Health > 0)
    self._arenaService:PrepareForLobbyReturn(player)
    -- 先恢复正确的大厅进度，再进入 LoadCharacter 的 yield 窗口。
    -- CharacterAdded/退出存档看到的都是半等级，而不是死亡 ResetCombatState 的 Lv1。
    if not self:_restoreLobbyProgress(player, halfLevelSnapshot) then
        return false
    end
    local didLoad = true
    if needsCharacter then
        didLoad = pcall(function()
            player:LoadCharacter()
        end)
        if didLoad then
            didLoad = self:_waitForUsableCharacter(player, 3)
        end
    end
    if not player.Parent or self:GetDefeatRecord(player) ~= defeatRecord then
        return false
    end
    if didLoad and self._arenaService:TeleportPlayerToSpawnLocation(player) == true then
        self:_clearDefeatRecord(player)
        return true
    end
    -- 保留原死亡快照供重试，不重复减半，也不把失败计为复活成功。
    local state = self._playerStateService:GetState(player)
    state.Alive = false
    self._playerStateService:PushState(player)
    if self._arenaTransitionFeedbackEvent then
        self._arenaTransitionFeedbackEvent:FireClient(player, {
            status = "Blocked",
            spawnMode = "LobbyReviveFailed",
            timestamp = os.clock(),
        })
    end
    return false
end

function RespawnService:_tryGrantFreeRespawn(player, defeatRecord)
    if not self:_revivePlayerToLobby(player, defeatRecord) then
        return false
    end
    if self._gameAnalyticsService then
        trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedFreeRespawn", 3, "FreeRespawnedToLobby", {
            source = "defeated",
        })
    end
    return true
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
    local attributeSnapshot = self._playerStateService
        and self._playerStateService.BuildAttributeSnapshot
        and self._playerStateService:BuildAttributeSnapshot(actor)
        or nil
    return {
        deathSerial = deathSerial,
        preDeathLevel = preDeathLevel,
        preDeathExperience = math.max(0, math.floor(tonumber(state.Experience) or GameConfig.PLAYER.BaseExperience)),
        preDeathKillCount = math.max(0, math.floor(tonumber(state.KillCount) or 0)),
        attributeSnapshot = attributeSnapshot,
        capturedAt = os.clock(),
    }
end

function RespawnService:_recordPlayerDefeat(player, sourceActor, deathSerial, combatSnapshot)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    local killerUserId = ActorUtils.IsPlayer(sourceActor) and sourceActor.UserId or nil
    self._defeatRecordsByUserId[player.UserId] = {
        deathSerial = deathSerial,
        analyticsSessionKey = string.format("death_%d", math.max(0, math.floor(tonumber(deathSerial) or 0))),
        killerUserId = killerUserId,
        killerName = sourceActor and ActorUtils.GetActorName(sourceActor) or "",
        createdAt = os.clock(),
        revivePurchasePending = false,
        combatSnapshot = combatSnapshot,
        freeRespawnLevel = getHalfFreeRespawnLevel(combatSnapshot),
        revengePending = false,
        revengePromptClosed = false,
    }

    if self._gameAnalyticsService then
        trackDefeatedFunnel(self._gameAnalyticsService, player, self._defeatRecordsByUserId[player.UserId], "DefeatedRevive", 1, "DefeatedPanelShown", {
            source = "defeated",
        })
        trackDefeatedFunnel(self._gameAnalyticsService, player, self._defeatRecordsByUserId[player.UserId], "DefeatedFreeRespawn", 1, "DefeatedPanelShown", {
            source = "defeated",
        })
    end
end

function RespawnService:HandleActorDeath(actor, sourceActor)
    if not actor then
        return
    end

    local deathSerial = self:_nextDeathSerial(actor)
    if ActorUtils.IsPlayer(actor) then
        if self._playerStateService and self._playerStateService.RecordDeath then
            self._playerStateService:RecordDeath(actor)
        end
    end
    local combatSnapshot = self:_captureCombatSnapshot(actor, deathSerial)
    self._playerStateService:ResetCombatState(actor)
    if self._weaponService then
        self._weaponService:ClearPlayerWeapons(actor)
    end
    self._playerStateService:PushState(actor)

    if ActorUtils.IsBot(actor) and self._botService then
        self._botService:ScheduleRespawn(actor)
    elseif ActorUtils.IsPlayer(actor) then
        local defeatSourceActor = sourceActor
        if ActorUtils.IsSameActor(actor, defeatSourceActor) then
            defeatSourceActor = nil
        end
        self:_recordPlayerDefeat(actor, defeatSourceActor, deathSerial, combatSnapshot)
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
        return
    elseif normalizedAction == "FreeRespawn" then
        if state.Alive ~= false then
            return
        end
        if self:IsCurrentDefeatRecord(player, defeatRecord) then
            trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedFreeRespawn", 2, "FreeRespawnClicked", {
                source = "defeated",
            })
        end
        self:_tryGrantFreeRespawn(player, defeatRecord)
    elseif normalizedAction == "Lobby" or normalizedAction == "Close" then
        if state.Alive ~= false then
            return
        end
        self:_revivePlayerToLobby(player, defeatRecord)
    elseif normalizedAction == "RevivePurchase" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revivePurchasePending = true
        trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedRevive", 2, "ReviveButtonClicked", {
            source = "defeated",
        })
        trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedRevive", 3, "RevivePurchaseIntent", {
            source = "defeated",
        })
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
        if state.Alive ~= false then
            self:_clearDefeatRecord(player)
        end
    elseif normalizedAction == "Revenge" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        if math.floor(tonumber(defeatRecord.killerUserId) or 0) <= 0 then
            return
        end
        defeatRecord.revengePending = true
    elseif normalizedAction == "RevengePromptClosed" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        if math.floor(tonumber(defeatRecord.killerUserId) or 0) <= 0 then
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
    end
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
        trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedRevive", 4, "ProductReceiptGranted", {
            source = "defeated",
        })
        trackDefeatedFunnel(self._gameAnalyticsService, player, defeatRecord, "DefeatedRevive", 5, "RevivedSuccessfully", {
            source = "defeated",
        })
    end

    self:_clearDefeatRecord(player)
    return true
end

function RespawnService:GetOfflineRespawnSaveSnapshot(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and getUserId(playerOrUserId) or math.floor(tonumber(playerOrUserId) or 0)
    if userId <= 0 then
        return nil
    end

    local cachedSnapshot = copyOfflineRespawnSaveSnapshot(self._offlineRespawnSaveSnapshotByUserId[userId])
    if cachedSnapshot then
        return cachedSnapshot
    end

    local player = typeof(playerOrUserId) == "Instance" and playerOrUserId or nil
    local defeatRecord = player and self:GetDefeatRecord(player) or nil
    return copyOfflineRespawnSaveSnapshot(buildOfflineRespawnSaveSnapshot(defeatRecord and defeatRecord.combatSnapshot))
end

function RespawnService:ClearOfflineRespawnSaveSnapshot(playerOrUserId)
    local userId = typeof(playerOrUserId) == "Instance" and getUserId(playerOrUserId) or math.floor(tonumber(playerOrUserId) or 0)
    if userId > 0 then
        self._offlineRespawnSaveSnapshotByUserId[userId] = nil
    end
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
    self._offlineRespawnSaveSnapshotByUserId = {}

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
    local offlineRespawnSnapshot = self:GetOfflineRespawnSaveSnapshot(player)
    local userId = getUserId(player)
    if userId > 0 and offlineRespawnSnapshot then
        self._offlineRespawnSaveSnapshotByUserId[userId] = offlineRespawnSnapshot
    end
    self:_clearDefeatRecord(player)
    self:_clearArenaRevivePending(player)
    if self._revengeService and self._revengeService.OnPlayerRemoving then
        self._revengeService:OnPlayerRemoving(player)
    end
    self._deathSerialByActorId[getActorId(player)] = nil
end

return RespawnService
