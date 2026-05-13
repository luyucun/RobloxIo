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
RespawnService._requestDefeatedActionEvent = nil
RespawnService._requestDefeatedActionConnection = nil
RespawnService._deathSerialByActorId = {}
RespawnService._defeatRecordsByUserId = {}
RespawnService._arenaRevivePendingByUserId = {}

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
        and defeatRecord
        and tonumber(defeatRecord.deathSerial) == self:_getDeathSerial(player)
end

function RespawnService:_setArenaRevivePending(player)
    local userId = getUserId(player)
    if userId > 0 then
        self._arenaRevivePendingByUserId[userId] = true
    end
end

function RespawnService:_clearArenaRevivePending(player)
    local userId = getUserId(player)
    if userId > 0 then
        self._arenaRevivePendingByUserId[userId] = nil
    end
end

function RespawnService:ConsumeArenaReviveRequest(player)
    local userId = getUserId(player)
    if userId <= 0 or self._arenaRevivePendingByUserId[userId] ~= true then
        return false
    end

    self._arenaRevivePendingByUserId[userId] = nil
    return true
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

function RespawnService:CompleteArenaRevive(player)
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

    self:_clearDefeatRecord(player)
    local state = self._playerStateService:GetState(player)
    state.Alive = true
    state.IsInArena = false
    state.Buffs = {}
    state.MaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    state.CurrentHealth = state.MaxHealth
    self._playerStateService:SyncCharacterState(player)
    self._playerStateService:UpdateOverheadHealthBar(player)
    self._playerStateService:PushState(player)
    return self._arenaService:TryEnterArena(player, { IgnoreDebounce = true }) == true
end

function RespawnService:_revivePlayerNow(player)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._arenaService and self._playerStateService) then
        return false
    end

    self:_clearDefeatRecord(player)
    local humanoid = ActorUtils.GetHumanoid(player)
    local rootPart = ActorUtils.GetRootPart(player)
    if not (humanoid and rootPart and humanoid.Health > 0) then
        self:_setArenaRevivePending(player)
        local didLoad = pcall(function()
            player:LoadCharacter()
        end)
        if not didLoad then
            self:_clearArenaRevivePending(player)
            return false
        end
        return true
    end

    return self:CompleteArenaRevive(player)
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
        self:_revivePlayerNow(player)
    end)
end

function RespawnService:_recordPlayerDefeat(player, sourceActor, deathSerial)
    if not ActorUtils.IsPlayer(player) then
        return
    end

    local killerUserId = ActorUtils.IsPlayer(sourceActor) and sourceActor.UserId or nil
    self._defeatRecordsByUserId[player.UserId] = {
        deathSerial = deathSerial,
        killerUserId = killerUserId,
        killerName = sourceActor and ActorUtils.GetActorName(sourceActor) or "",
        createdAt = os.clock(),
        expiresAt = os.clock() + math.max(1, tonumber(GameConfig.RESPAWN.PlayerKillReviveCountdownSeconds) or 15),
    }
end

function RespawnService:HandleActorDeath(actor, sourceActor)
    if not actor then
        return
    end

    local deathSerial = self:_nextDeathSerial(actor)
    self._playerStateService:ResetCombatState(actor)
    if self._weaponService then
        self._weaponService:ClearPlayerWeapons(actor)
    end
    self._playerStateService:PushState(actor)

    if ActorUtils.IsBot(actor) and self._botService then
        self._botService:ScheduleRespawn(actor)
    elseif ActorUtils.IsPlayer(actor) then
        if ActorUtils.IsPlayer(sourceActor) and not ActorUtils.IsSameActor(actor, sourceActor) then
            self:_recordPlayerDefeat(actor, sourceActor, deathSerial)
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
    if not (state and state.Alive == false and currentDeathSerial > 0) then
        return
    end

    if normalizedAction == "Revive" or normalizedAction == "Close" then
        self:RevivePlayer(player)
    elseif normalizedAction == "Revenge" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revengePending = true
    elseif normalizedAction == "RevengeCancel" then
        if not self:IsCurrentDefeatRecord(player, defeatRecord) then
            return
        end
        defeatRecord.revengePending = false
        self:_schedulePlayerRevive(
            player,
            math.max(0, (tonumber(defeatRecord.expiresAt) or os.clock()) - os.clock()),
            defeatRecord.deathSerial
        )
    end
end

function RespawnService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._arenaService = dependencies.ArenaService
    self._botService = dependencies.BotService
    self._requestDefeatedActionEvent = dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestDefeatedAction") or nil
    self._deathSerialByActorId = {}
    self._defeatRecordsByUserId = {}
    self._arenaRevivePendingByUserId = {}

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
    self._deathSerialByActorId[getActorId(player)] = nil
end

return RespawnService
