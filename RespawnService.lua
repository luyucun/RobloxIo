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
RespawnService._freeRespawnOperationsByUserId = {}
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
            freeRespawnOperation = type(options) == "table" and options.freeRespawnOperation or nil,
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
    return true, self._arenaReviveOptionsByUserId[userId]
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
    local userId = getUserId(player)
    local reviveOptions = type(options) == "table" and options or self._arenaReviveOptionsByUserId[userId]
    if type(reviveOptions) ~= "table" then
        -- 已完成/取消的 CharacterAdded 延迟回调不能再启动一次入场。
        return false
    end
    if type(reviveOptions) == "table" and reviveOptions.freeRespawnOperation then
        return self:_completeFreeRespawnOperation(player, reviveOptions.freeRespawnOperation)
    end
    if self._freeRespawnOperationsByUserId[userId] then
        return false
    end
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
    if self._freeRespawnOperationsByUserId[getUserId(player)] then
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

function RespawnService:_isFreeRespawnOperationActive(player, operation)
    return player.Parent ~= nil
        and self._freeRespawnOperationsByUserId[getUserId(player)] == operation
        and self:GetDefeatRecord(player) == operation.defeatRecord
        and self:IsDefeatRecordForCurrentDeath(player, operation.defeatRecord)
end

function RespawnService:_reportFreeRespawnFailure(player)
    local state = self._playerStateService:GetState(player)
    state.Alive = false
    state.IsInArena = false
    if self._weaponService and self._weaponService.ClearPlayerWeapons then
        self._weaponService:ClearPlayerWeapons(player)
    end
    self._playerStateService:PushState(player)
    if self._arenaTransitionFeedbackEvent then
        self._arenaTransitionFeedbackEvent:FireClient(player, {
            status = "Blocked",
            spawnMode = "FreeRespawnFailed",
            timestamp = os.clock(),
        })
    end
end

function RespawnService:_finishFreeRespawnOperation(player, operation, succeeded)
    if operation.finished then
        return operation.succeeded == true
    end
    local isCurrent = self:_isFreeRespawnOperationActive(player, operation)
    operation.finished = true
    operation.succeeded = isCurrent and succeeded == true
    local userId = getUserId(player)
    if self._freeRespawnOperationsByUserId[userId] == operation then
        self._freeRespawnOperationsByUserId[userId] = nil
    end
    for _, requests in ipairs({ self._arenaRevivePendingByUserId, self._arenaReviveOptionsByUserId }) do
        local request = requests[userId]
        if request and request.freeRespawnOperation == operation then
            if requests ~= self._arenaRevivePendingByUserId or operation.succeeded or not isCurrent then
                requests[userId] = nil
            end
            -- 未收到 CharacterAdded 的失败请求保留取消凭据，迟到事件不能被误判为大厅出生。
            -- 新操作恢复进度前会清除旧凭据；已消费的回调由 MainServer 捕获对应 options。
        end
    end
    if not isCurrent then
        return false
    end
    if operation.succeeded then
        self:_clearDefeatRecord(player)
        trackDefeatedFunnel(self._gameAnalyticsService, player, operation.defeatRecord, "DefeatedFreeRespawn", 3, "FreeRespawnedSuccessfully", {
            source = "defeated",
        })
        return true
    end

    -- 失败仍使用同一份死亡前快照；退出存档/再次点击都只减半一次。
    self:_reportFreeRespawnFailure(player)
    return false
end

function RespawnService:_completeFreeRespawnOperation(player, operation)
    if operation.finished then
        local userId = getUserId(player)
        local pendingOptions = self._arenaReviveOptionsByUserId[userId]
        if pendingOptions and pendingOptions.freeRespawnOperation == operation then
            self._arenaReviveOptionsByUserId[userId] = nil
        end
        if not operation.succeeded and player.Parent and not self._freeRespawnOperationsByUserId[userId]
            and self:GetDefeatRecord(player) == operation.defeatRecord
            and self:IsDefeatRecordForCurrentDeath(player, operation.defeatRecord) then
            -- 迟到 CharacterAdded 会将 Alive 改回 true；只回滚仍属于同一次死亡的取消操作。
            self:_reportFreeRespawnFailure(player)
        end
        return operation.succeeded == true
    end
    if not self:_isFreeRespawnOperationActive(player, operation) then
        return self:_finishFreeRespawnOperation(player, operation, false)
    end
    if operation.completing then
        local deadline = os.clock() + 3
        repeat
            task.wait(0.05)
        until operation.finished or os.clock() >= deadline or not self:_isFreeRespawnOperationActive(player, operation)
        return operation.succeeded == true
    end
    operation.completing = true
    local didComplete, enteredArena = pcall(function()
        if not self:_waitForUsableCharacter(player, 3) or not self:_isFreeRespawnOperationActive(player, operation) then
            return false
        end
        local state = self._playerStateService:GetState(player)
        state.Alive = true
        state.IsInArena = false
        state.Buffs = {}
        -- RestoreCombatProgress / OnCharacterAdded 已合并属性与事件加成，不能再用裸等级血量覆盖。
        state.CurrentHealth = state.MaxHealth
        self._playerStateService:SyncCharacterState(player)
        self._playerStateService:UpdateOverheadHealthBar(player)
        self._playerStateService:PushState(player)
        return self._arenaService:TryEnterArena(player, {
            IgnoreDebounce = true,
            IsRevive = true,
        }) == true
    end)
    if not didComplete then
        warn("[RespawnService] 免费复活入场失败: " .. tostring(enteredArena))
    end
    return self:_finishFreeRespawnOperation(player, operation, didComplete and enteredArena)
end

function RespawnService:_tryGrantFreeRespawn(player, defeatRecord)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._arenaService and self._playerStateService
        and self:GetDefeatRecord(player) == defeatRecord and self:IsCurrentDefeatRecord(player, defeatRecord)) then
        return false
    end
    local userId = getUserId(player)
    if self._freeRespawnOperationsByUserId[userId] then
        return false
    end
    local halfLevelSnapshot = buildHalfLevelRespawnSnapshot(defeatRecord.combatSnapshot)
    if not halfLevelSnapshot then
        return false
    end
    local operation = { defeatRecord = defeatRecord, finished = false }
    self._freeRespawnOperationsByUserId[userId] = operation
    local didRevive, revived = pcall(function()
        local humanoid = ActorUtils.GetHumanoid(player)
        local rootPart = ActorUtils.GetRootPart(player)
        local needsCharacter = not (humanoid and rootPart and humanoid.Health > 0)
        -- 这里只恢复场外进度，不传送大厅；LoadCharacter yield 前已是正确半等级。
        if not self:_restoreLobbyProgress(player, halfLevelSnapshot) or not self:_isFreeRespawnOperationActive(player, operation) then
            return false
        end
        local reviveOptions = { preserveDefeatRecord = true, freeRespawnOperation = operation }
        if needsCharacter then
            self:_setArenaRevivePending(player, reviveOptions)
            self:_fireSkipSpawnCameraLook(player)
            player:LoadCharacter()
        end
        return self:CompleteArenaRevive(player, reviveOptions)
    end)
    if not didRevive then
        warn("[RespawnService] 免费复活失败: " .. tostring(revived))
    end
    return self:_finishFreeRespawnOperation(player, operation, didRevive and revived)
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
    if not (player and player.Parent) or type(action) ~= "string" then
        return
    end
    if self._freeRespawnOperationsByUserId[getUserId(player)] then
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
    if self._freeRespawnOperationsByUserId[getUserId(player)] then
        -- 不吞收据：免费复活进行中由购买服务稍后重试发货。
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
    self._freeRespawnOperationsByUserId = {}
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
    if userId > 0 then
        self._freeRespawnOperationsByUserId[userId] = nil
    end
    if self._revengeService and self._revengeService.OnPlayerRemoving then
        self._revengeService:OnPlayerRemoving(player)
    end
    self._deathSerialByActorId[getActorId(player)] = nil
end

return RespawnService
