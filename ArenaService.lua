--[[
脚本名字: ArenaService
脚本文件: ArenaService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/ArenaService
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
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
        "[ArenaService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local ArenaService = {}

local PORTAL_RANGE_CHECK_INTERVAL = 0.1
local PORTAL_RANGE_PADDING = 3
local PORTAL_JOIN_GRACE_SECONDS = 8
local BATTLE_ENTRY_VERTICAL_PADDING = 12
local BATTLE_ENTRY_VERIFY_DELAY_SECONDS = 0.25
local DEFAULT_CHARACTER_COLLISION_GROUP = "IOCharacters"
local DEFAULT_MONSTER_COLLISION_GROUP = "IOMonsters"
local DEFAULT_SAFE_BARRIER_COLLISION_GROUP = "IOSafeBarriers"
local DEFAULT_SAFE_UNLOCKED_CHARACTER_COLLISION_GROUP = "IOSafeUnlockedCharacters"
local DEFAULT_SAFE_LOCKED_CHARACTER_COLLISION_GROUP = "IOSafeLockedCharacters"

ArenaService._playerStateService = nil
ArenaService._weaponService = nil
ArenaService._botService = nil
ArenaService._rebirthService = nil
ArenaService._healthService = nil
ArenaService._arenaTransitionFeedbackEvent = nil
ArenaService._portalJoinPromptEvent = nil
ArenaService._requestJoinBattleEvent = nil
ArenaService._enterDebounceByActorId = {}
ArenaService._portalPromptDebounceByActorId = {}
ArenaService._pendingPortalPromptByUserId = {}
ArenaService._portalPromptVisibleByUserId = {}
ArenaService._portalPromptSuppressedUntilExitByUserId = {}
ArenaService._hasEnteredArenaThisSessionByUserId = {}
ArenaService._firstArenaEnterPendingByUserId = {}
ArenaService._spawnLocation = nil
ArenaService._portalModel = nil
ArenaService._battlePart = nil
ArenaService._safePart = nil
ArenaService._portalTouchedConnections = {}
ArenaService._requestJoinBattleConnection = nil
ArenaService._portalRangeMonitorConnection = nil
ArenaService._safeReentryMonitorConnection = nil
ArenaService._playerRemovingConnection = nil
ArenaService._portalRangeMonitorAccumulator = 0
ArenaService._safeReentryMonitorAccumulator = 0
ArenaService._safeReentryLockedByUserId = {}
ArenaService._safeBarrierParts = {}
ArenaService._safeBarrierCollisionStateByUserId = {}

local function resetCharacterPhysics(character)
    if not character then
        return
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.AssemblyLinearVelocity = Vector3.zero
            descendant.AssemblyAngularVelocity = Vector3.zero
        end
    end
end

local function resolveSpawnLocation()
    local spawnLocation = Workspace:FindFirstChild(GameConfig.ARENA.SpawnLocationName)
    if spawnLocation and spawnLocation:IsA("SpawnLocation") then
        return spawnLocation
    end

    spawnLocation = Workspace:FindFirstChild(GameConfig.ARENA.SpawnLocationName, true)
    if spawnLocation and spawnLocation:IsA("SpawnLocation") then
        return spawnLocation
    end

    return nil
end

local function resolvePortalModel()
    local map = Workspace:FindFirstChild(GameConfig.ARENA.MapFolderName)
    if not map then
        return nil
    end

    local portals = map:FindFirstChild(GameConfig.ARENA.PortalsFolderName)
    if not portals then
        return nil
    end

    local portal = portals:FindFirstChild(GameConfig.ARENA.PortalModelName)
    if portal and portal:IsA("Model") then
        return portal
    end

    return nil
end

local function resolveBattlePart()
    local battlePart = Workspace:FindFirstChild(GameConfig.ARENA.BattlePartName)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end

    battlePart = Workspace:FindFirstChild(GameConfig.ARENA.BattlePartName, true)
    if battlePart and battlePart:IsA("BasePart") then
        return battlePart
    end

    return nil
end

local function resolveSafePart(battlePart)
    local arenaConfig = GameConfig.ARENA or {}
    local safePartName = tostring(arenaConfig.SafePartName or "Safe")
    if safePartName == "" then
        return nil
    end

    local battleMapName = tostring(arenaConfig.BattleMapName or "")
    if battleMapName ~= "" then
        local battleMap = Workspace:FindFirstChild(battleMapName)
        if battleMap then
            local safePart = battleMap:FindFirstChild(safePartName)
            if safePart and safePart:IsA("BasePart") then
                return safePart
            end
        end
    end

    if battlePart and battlePart.Parent then
        local siblingSafePart = battlePart.Parent:FindFirstChild(safePartName)
        if siblingSafePart and siblingSafePart:IsA("BasePart") then
            return siblingSafePart
        end
    end

    local safePart = Workspace:FindFirstChild(safePartName, true)
    if safePart and safePart:IsA("BasePart") then
        return safePart
    end

    return nil
end

local function ensureCollisionGroup(groupName)
    if tostring(groupName or "") == "" then
        return
    end

    local found = false
    local success, groups = pcall(function()
        return PhysicsService:GetRegisteredCollisionGroups()
    end)
    if success and type(groups) == "table" then
        for _, group in ipairs(groups) do
            if group.name == groupName or group.Name == groupName then
                found = true
                break
            end
        end
    end
    if not found then
        pcall(function()
            PhysicsService:RegisterCollisionGroup(groupName)
        end)
    end
end

local function setCollisionRule(groupA, groupB, canCollide)
    pcall(function()
        PhysicsService:CollisionGroupSetCollidable(groupA, groupB, canCollide == true)
    end)
end

local function setPartCollisionGroup(basePart, groupName)
    pcall(function()
        basePart.CollisionGroup = groupName
    end)
end

local function getCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.CharacterGroupName) or DEFAULT_CHARACTER_COLLISION_GROUP
end

local function getMonsterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.MonsterGroupName) or DEFAULT_MONSTER_COLLISION_GROUP
end

local function getSafeBarrierCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.SafeBarrierGroupName) or DEFAULT_SAFE_BARRIER_COLLISION_GROUP
end

local function getSafeUnlockedCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.SafeUnlockedCharacterGroupName) or DEFAULT_SAFE_UNLOCKED_CHARACTER_COLLISION_GROUP
end

local function getSafeLockedCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.SafeLockedCharacterGroupName) or DEFAULT_SAFE_LOCKED_CHARACTER_COLLISION_GROUP
end

local function disconnectSafeBarrierCollisionState(collisionState)
    local connection = collisionState and collisionState.Connection
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function applyCollisionGroupToCharacter(character, groupName)
    if not character then
        return
    end

    ensureCollisionGroup(groupName)
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, groupName)
        end
    end
end

function ArenaService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._botService = dependencies.BotService
    self._rebirthService = dependencies.RebirthService
    self._healthService = dependencies.HealthService
    self._gameAnalyticsService = dependencies.GameAnalyticsService
    self._arenaTransitionFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("ArenaTransitionFeedback") or nil
    self._portalJoinPromptEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("PortalJoinPrompt") or nil
    self._requestJoinBattleEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestJoinBattle") or nil
    self._enterDebounceByActorId = {}
    self._portalPromptDebounceByActorId = {}
    self._pendingPortalPromptByUserId = {}
    self._portalPromptVisibleByUserId = {}
    self._portalPromptSuppressedUntilExitByUserId = {}
    self._hasEnteredArenaThisSessionByUserId = {}
    self._firstArenaEnterPendingByUserId = {}
    self._safeReentryLockedByUserId = {}
    for _, collisionState in pairs(self._safeBarrierCollisionStateByUserId or {}) do
        disconnectSafeBarrierCollisionState(collisionState)
    end
    self._safeBarrierCollisionStateByUserId = {}
    self._safeBarrierParts = {}
    self._portalRangeMonitorAccumulator = 0
    self._safeReentryMonitorAccumulator = 0
    self._spawnLocation = resolveSpawnLocation()
    self._portalModel = resolvePortalModel()
    self._battlePart = resolveBattlePart()
    self._safePart = resolveSafePart(self._battlePart)
    self:_configureSafeBarrierCollision()

    if not self._spawnLocation then
        warn("[ArenaService] 找不到 SpawnLocation，玩家默认出生点逻辑将不可用。")
    end
    if not self._portalModel then
        warn("[ArenaService] 找不到 workspace.Map2.Portals.Portal，玩家入场弹窗逻辑将不可用。")
    end
    if not self._battlePart then
        warn("[ArenaService] 找不到 workspace.Battle，战斗区随机出生逻辑将不可用。")
    end
    if not self._safePart then
        warn("[ArenaService] 找不到 workspace.Battle01.Safe，Safe 区保护和安全区出生将不可用。")
    end

    self:_disconnectPortalTouchedConnections()
    self:_disconnectPortalRangeMonitor()
    self:_disconnectSafeReentryMonitor()

    if self._requestJoinBattleConnection then
        self._requestJoinBattleConnection:Disconnect()
        self._requestJoinBattleConnection = nil
    end
    if self._playerRemovingConnection then
        self._playerRemovingConnection:Disconnect()
        self._playerRemovingConnection = nil
    end

    if self._requestJoinBattleEvent then
        self._requestJoinBattleConnection = self._requestJoinBattleEvent.OnServerEvent:Connect(function(player, action)
            self:_onRequestJoinBattle(player, action)
        end)
    end

    self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
        self:_clearPortalPromptState(player)
        self:_clearArenaSessionState(player)
    end)

    self:_connectPortalTouched()
    self:_connectPortalRangeMonitor()
    self:_connectSafeReentryMonitor()
end

function ArenaService:GetHomeStartPart()
    return self._portalModel
end

function ArenaService:GetPortalModel()
    return self._portalModel
end

function ArenaService:GetBattlePart()
    return self._battlePart
end

function ArenaService:GetSafePart()
    return self._safePart
end

function ArenaService:GetSpawnLocation()
    return self._spawnLocation
end

function ArenaService:_getActorGroundOffset(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    local rootHalfHeight = rootPart and (rootPart.Size.Y * 0.5) or 1
    local hipHeight = humanoid and humanoid.HipHeight or 2
    return rootHalfHeight + hipHeight + 0.15
end

function ArenaService:_buildTeleportCFrame(actor, targetPosition)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not rootPart then
        return CFrame.new(targetPosition)
    end

    local planarLook = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
    if planarLook.Magnitude <= 0.001 then
        return CFrame.new(targetPosition)
    end

    return CFrame.lookAt(targetPosition, targetPosition + planarLook.Unit)
end

function ArenaService:_getPortalLookAtPosition()
    if not self._portalModel then
        return nil
    end

    local didGetPivot, pivot = pcall(function()
        return self._portalModel:GetPivot()
    end)
    if didGetPivot and pivot then
        return pivot.Position
    end

    local didGetBounds, boundsCFrame = pcall(function()
        local resolvedBoundsCFrame = self._portalModel:GetBoundingBox()
        return resolvedBoundsCFrame
    end)
    if didGetBounds and boundsCFrame then
        return boundsCFrame.Position
    end

    return nil
end

function ArenaService:_buildTeleportCFrameFacingPosition(actor, targetPosition, lookAtPosition)
    if typeof(lookAtPosition) ~= "Vector3" then
        return self:_buildTeleportCFrame(actor, targetPosition)
    end

    local flatLookAt = Vector3.new(lookAtPosition.X, targetPosition.Y, lookAtPosition.Z)
    local direction = flatLookAt - targetPosition
    if direction.Magnitude <= 0.001 then
        return self:_buildTeleportCFrame(actor, targetPosition)
    end

    return CFrame.lookAt(targetPosition, targetPosition + direction.Unit)
end

function ArenaService:_teleportActorToPosition(actor, targetPosition, lookAtPosition)
    local character = ActorUtils.GetCharacter(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not (character and rootPart and typeof(targetPosition) == "Vector3") then
        return false
    end

    character:PivotTo(self:_buildTeleportCFrameFacingPosition(actor, targetPosition, lookAtPosition))
    resetCharacterPhysics(character)
    return true
end

function ArenaService:_getPartSurfaceY(part)
    return part.Position.Y + (part.Size.Y * 0.5)
end

function ArenaService:_resolveActorFromCharacter(character)
    local player = Players:GetPlayerFromCharacter(character)
    if player then
        return player
    end

    if self._botService then
        return self._botService:GetBotFromCharacter(character)
    end

    return nil
end

function ArenaService:_fireTransitionFeedback(actor, status, spawnMode)
    if not (actor and self._arenaTransitionFeedbackEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    self._arenaTransitionFeedbackEvent:FireClient(actor, {
        status = tostring(status or "Unknown"),
        spawnMode = tostring(spawnMode or "None"),
        timestamp = os.clock(),
    })
end

function ArenaService:_disconnectPortalTouchedConnections()
    for _, connection in ipairs(self._portalTouchedConnections or {}) do
        if connection then
            connection:Disconnect()
        end
    end
    self._portalTouchedConnections = {}
end

function ArenaService:_disconnectPortalRangeMonitor()
    if self._portalRangeMonitorConnection then
        self._portalRangeMonitorConnection:Disconnect()
        self._portalRangeMonitorConnection = nil
    end
    self._portalRangeMonitorAccumulator = 0
end

function ArenaService:_disconnectSafeReentryMonitor()
    if self._safeReentryMonitorConnection then
        self._safeReentryMonitorConnection:Disconnect()
        self._safeReentryMonitorConnection = nil
    end
    self._safeReentryMonitorAccumulator = 0
end

function ArenaService:_connectPortalTouched()
    self:_disconnectPortalTouchedConnections()
    if not self._portalModel then
        return
    end

    for _, descendant in ipairs(self._portalModel:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(self._portalTouchedConnections, descendant.Touched:Connect(function(hitPart)
                self:_onPortalTouched(hitPart)
            end))
        end
    end
end

function ArenaService:_connectPortalRangeMonitor()
    self:_disconnectPortalRangeMonitor()
    if not (self._portalModel and self._portalJoinPromptEvent) then
        return
    end

    self._portalRangeMonitorConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_onPortalRangeHeartbeat(deltaTime)
    end)
end

function ArenaService:_connectSafeReentryMonitor()
    self:_disconnectSafeReentryMonitor()
    if not (self._safePart and self._playerStateService) then
        return
    end

    self._safeReentryMonitorConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_onSafeReentryHeartbeat(deltaTime)
    end)
end

function ArenaService:_getBattleMap()
    local arenaConfig = GameConfig.ARENA or {}
    local battleMapName = tostring(arenaConfig.BattleMapName or "")
    if battleMapName == "" then
        return nil
    end
    return Workspace:FindFirstChild(battleMapName)
end

function ArenaService:_collectSafeBarrierParts()
    local battleMap = self:_getBattleMap()
    if not battleMap then
        return {}
    end

    local arenaConfig = GameConfig.ARENA or {}
    local barrierPrefix = tostring(arenaConfig.SafeBarrierNamePrefix or "Safe1")
    local barrierParts = {}
    for _, descendant in ipairs(battleMap:GetDescendants()) do
        if descendant:IsA("BasePart") and barrierPrefix ~= "" and string.sub(descendant.Name, 1, #barrierPrefix) == barrierPrefix then
            table.insert(barrierParts, descendant)
        end
    end
    return barrierParts
end

function ArenaService:_configureSafeBarrierCollision()
    local characterGroup = getCharacterCollisionGroupName()
    local monsterGroup = getMonsterCollisionGroupName()
    local safeUnlockedGroup = getSafeUnlockedCharacterCollisionGroupName()
    local safeLockedGroup = getSafeLockedCharacterCollisionGroupName()
    local safeBarrierGroup = getSafeBarrierCollisionGroupName()

    ensureCollisionGroup(characterGroup)
    ensureCollisionGroup(monsterGroup)
    ensureCollisionGroup(safeUnlockedGroup)
    ensureCollisionGroup(safeLockedGroup)
    ensureCollisionGroup(safeBarrierGroup)
    setCollisionRule("Default", safeBarrierGroup, false)
    setCollisionRule(characterGroup, safeBarrierGroup, false)
    setCollisionRule(monsterGroup, safeBarrierGroup, false)
    setCollisionRule(safeUnlockedGroup, safeBarrierGroup, false)
    setCollisionRule(safeLockedGroup, safeBarrierGroup, true)
    setCollisionRule(safeUnlockedGroup, monsterGroup, false)
    setCollisionRule(safeLockedGroup, monsterGroup, false)
    setCollisionRule(safeBarrierGroup, safeBarrierGroup, true)

    self._safeBarrierParts = self:_collectSafeBarrierParts()
    for _, barrierPart in ipairs(self._safeBarrierParts) do
        if barrierPart and barrierPart.Parent then
            barrierPart.CanCollide = true
            barrierPart.CanTouch = false
            setPartCollisionGroup(barrierPart, safeBarrierGroup)
        end
    end
end

function ArenaService:_setActorSafeBarrierLocked(actor, locked)
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local userId = actor.UserId
    self._safeBarrierCollisionStateByUserId = self._safeBarrierCollisionStateByUserId or {}
    local previousState = self._safeBarrierCollisionStateByUserId[userId]
    local character = ActorUtils.GetCharacter(actor)
    if not character then
        if previousState then
            disconnectSafeBarrierCollisionState(previousState)
            self._safeBarrierCollisionStateByUserId[userId] = nil
        end
        return
    end

    local isLocked = locked == true
    local groupName = isLocked and getSafeLockedCharacterCollisionGroupName() or getCharacterCollisionGroupName()
    if isLocked
        and previousState
        and previousState.Character == character
        and previousState.Locked == true
        and previousState.GroupName == groupName
    then
        return
    end

    if previousState then
        disconnectSafeBarrierCollisionState(previousState)
        self._safeBarrierCollisionStateByUserId[userId] = nil
    end

    applyCollisionGroupToCharacter(character, groupName)

    if isLocked then
        local connection = character.DescendantAdded:Connect(function(descendant)
            if descendant:IsA("BasePart") then
                setPartCollisionGroup(descendant, groupName)
            end
        end)
        self._safeBarrierCollisionStateByUserId[userId] = {
            Character = character,
            Locked = true,
            GroupName = groupName,
            Connection = connection,
        }
    end
end

function ArenaService:_clearPortalPromptState(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end

    self._pendingPortalPromptByUserId[actor.UserId] = nil
    self._portalPromptVisibleByUserId[actor.UserId] = nil
    self._portalPromptSuppressedUntilExitByUserId[actor.UserId] = nil
end

function ArenaService:_clearPortalVisibleState(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end

    self._portalPromptVisibleByUserId[actor.UserId] = nil
end

function ArenaService:_setPortalJoinPending(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end

    self._pendingPortalPromptByUserId[actor.UserId] = {
        shownAt = os.clock(),
    }
end

function ArenaService:_hasValidPortalJoinPending(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return false
    end

    if self._portalPromptVisibleByUserId[actor.UserId] then
        return true
    end

    local pending = self._pendingPortalPromptByUserId[actor.UserId]
    if type(pending) ~= "table" then
        return false
    end

    local shownAt = tonumber(pending.shownAt) or 0
    return os.clock() - shownAt <= PORTAL_JOIN_GRACE_SECONDS
end

function ArenaService:_clearExpiredPortalJoinPending(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end

    if self._portalPromptVisibleByUserId[actor.UserId] then
        return
    end

    if self._pendingPortalPromptByUserId[actor.UserId] and not self:_hasValidPortalJoinPending(actor) then
        self._pendingPortalPromptByUserId[actor.UserId] = nil
    end
end

function ArenaService:_isPositionInsidePortalBounds(position)
    if not (self._portalModel and typeof(position) == "Vector3") then
        return false
    end

    local didGetBounds, boundsCFrame, boundsSize = pcall(function()
        return self._portalModel:GetBoundingBox()
    end)
    if not didGetBounds then
        return false
    end

    local localPosition = boundsCFrame:PointToObjectSpace(position)
    local halfSize = boundsSize * 0.5
    local padding = PORTAL_RANGE_PADDING

    return math.abs(localPosition.X) <= halfSize.X + padding
        and math.abs(localPosition.Y) <= halfSize.Y + padding
        and math.abs(localPosition.Z) <= halfSize.Z + padding
end

function ArenaService:_isActorInsidePortalBounds(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    return rootPart ~= nil and self:_isPositionInsidePortalBounds(rootPart.Position)
end

function ArenaService:_isPositionInsideBattleBounds(position)
    if not (self._battlePart and typeof(position) == "Vector3") then
        return false
    end

    local localPosition = self._battlePart.CFrame:PointToObjectSpace(position)
    local halfSize = self._battlePart.Size * 0.5

    return math.abs(localPosition.X) <= halfSize.X
        and math.abs(localPosition.Z) <= halfSize.Z
        and localPosition.Y >= -halfSize.Y - BATTLE_ENTRY_VERTICAL_PADDING
        and localPosition.Y <= halfSize.Y + BATTLE_ENTRY_VERTICAL_PADDING
end

function ArenaService:IsPositionInsideBattle(position)
    return self:_isPositionInsideBattleBounds(position)
end

function ArenaService:ClampPositionInsideBattle(position, padding)
    if not (self._battlePart and typeof(position) == "Vector3") then
        return nil
    end

    local resolvedPadding = math.max(0, tonumber(padding) or 0)
    local halfSize = self._battlePart.Size * 0.5
    local usableX = math.max(0, halfSize.X - resolvedPadding)
    local usableZ = math.max(0, halfSize.Z - resolvedPadding)
    local localPosition = self._battlePart.CFrame:PointToObjectSpace(position)
    local clampedLocalPosition = Vector3.new(
        math.clamp(localPosition.X, -usableX, usableX),
        localPosition.Y,
        math.clamp(localPosition.Z, -usableZ, usableZ)
    )
    return self._battlePart.CFrame:PointToWorldSpace(clampedLocalPosition)
end

function ArenaService:_isActorInsideBattleBounds(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    return rootPart ~= nil and self:_isPositionInsideBattleBounds(rootPart.Position)
end

function ArenaService:_getSafeZoneVerticalPadding()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(0, tonumber(arenaConfig.SafeZoneVerticalPadding) or BATTLE_ENTRY_VERTICAL_PADDING)
end

function ArenaService:IsPositionInsideSafeZone(position)
    if not (self._safePart and typeof(position) == "Vector3") then
        return false
    end

    local localPosition = self._safePart.CFrame:PointToObjectSpace(position)
    local halfSize = self._safePart.Size * 0.5
    local verticalPadding = self:_getSafeZoneVerticalPadding()

    return math.abs(localPosition.X) <= halfSize.X
        and math.abs(localPosition.Z) <= halfSize.Z
        and localPosition.Y >= -halfSize.Y - verticalPadding
        and localPosition.Y <= halfSize.Y + verticalPadding
end

function ArenaService:IsActorInsideSafeZone(actor)
    if not ActorUtils.IsPlayer(actor) then
        return false
    end

    local rootPart = ActorUtils.GetRootPart(actor)
    return rootPart ~= nil and self:IsPositionInsideSafeZone(rootPart.Position)
end

function ArenaService:_getSafeReentryLockMinLevel()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(1, math.floor(tonumber(arenaConfig.SafeReentryLockMinLevel) or 31))
end

function ArenaService:_getSafeReentryCheckInterval()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(0.05, tonumber(arenaConfig.SafeReentryCheckIntervalSeconds) or 0.15)
end

function ArenaService:_getSafeReentryPushOutDistance()
    local arenaConfig = GameConfig.ARENA or {}
    return math.max(0, tonumber(arenaConfig.SafeReentryPushOutDistance) or 8)
end

function ArenaService:_getActorLevel(actor)
    local state = self._playerStateService and self._playerStateService:GetState(actor) or nil
    return math.max(1, math.floor(tonumber(state and state.Level) or GameConfig.PLAYER.BaseLevel))
end

function ArenaService:_shouldApplySafeReentryLock(actor)
    return ActorUtils.IsPlayer(actor)
        and self:_getActorLevel(actor) >= self:_getSafeReentryLockMinLevel()
end

function ArenaService:_resetSafeReentryLock(actor)
    if ActorUtils.IsPlayer(actor) then
        local hadReentryLock = self._safeReentryLockedByUserId[actor.UserId] == true
        local hadCollisionState = self._safeBarrierCollisionStateByUserId
            and self._safeBarrierCollisionStateByUserId[actor.UserId] ~= nil
        self._safeReentryLockedByUserId[actor.UserId] = nil
        if hadReentryLock or hadCollisionState then
            self:_setActorSafeBarrierLocked(actor, false)
        end
    end
end

function ArenaService:_setSafeReentryLocked(actor)
    if ActorUtils.IsPlayer(actor) then
        self._safeReentryLockedByUserId[actor.UserId] = true
        self:_setActorSafeBarrierLocked(actor, true)
    end
end

function ArenaService:_isSafeReentryLocked(actor)
    return ActorUtils.IsPlayer(actor)
        and self._safeReentryLockedByUserId[actor.UserId] == true
end

function ArenaService:_buildSafeReentryPushOutPosition(position)
    if not (self._safePart and typeof(position) == "Vector3") then
        return nil
    end

    local localPosition = self._safePart.CFrame:PointToObjectSpace(position)
    local halfSize = self._safePart.Size * 0.5
    local pushOutDistance = self:_getSafeReentryPushOutDistance()
    local useX = true

    if halfSize.X <= 0 and halfSize.Z <= 0 then
        return nil
    elseif halfSize.X <= 0 then
        useX = false
    elseif halfSize.Z > 0 then
        useX = (math.abs(localPosition.X) / halfSize.X) >= (math.abs(localPosition.Z) / halfSize.Z)
    end

    local targetLocalPosition
    if useX then
        local sign = localPosition.X >= 0 and 1 or -1
        targetLocalPosition = Vector3.new(
            sign * (halfSize.X + pushOutDistance),
            localPosition.Y,
            math.clamp(localPosition.Z, -halfSize.Z, halfSize.Z)
        )
    else
        local sign = localPosition.Z >= 0 and 1 or -1
        targetLocalPosition = Vector3.new(
            math.clamp(localPosition.X, -halfSize.X, halfSize.X),
            localPosition.Y,
            sign * (halfSize.Z + pushOutDistance)
        )
    end

    local worldPosition = (self._safePart.CFrame * CFrame.new(targetLocalPosition)).Position
    return Vector3.new(worldPosition.X, position.Y, worldPosition.Z)
end

function ArenaService:_pushActorOutsideSafeZone(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not rootPart then
        return false
    end

    local targetPosition = self:_buildSafeReentryPushOutPosition(rootPart.Position)
    if not targetPosition then
        return false
    end

    return self:_teleportActorToPosition(actor, targetPosition)
end

function ArenaService:_onSafeReentryHeartbeat(deltaTime)
    self._safeReentryMonitorAccumulator += (deltaTime or 0)
    if self._safeReentryMonitorAccumulator < self:_getSafeReentryCheckInterval() then
        return
    end
    self._safeReentryMonitorAccumulator = 0

    if not (self._safePart and self._playerStateService) then
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local state = self._playerStateService:GetState(player)
        if not (state and state.IsInArena == true and state.Alive == true) then
            self:_resetSafeReentryLock(player)
            continue
        end

        if not self:_shouldApplySafeReentryLock(player) then
            self:_resetSafeReentryLock(player)
            continue
        end

        local rootPart = ActorUtils.GetRootPart(player)
        if not rootPart then
            continue
        end

        local isInsideSafeZone = self:IsPositionInsideSafeZone(rootPart.Position)
        if not self:_isSafeReentryLocked(player) then
            if not isInsideSafeZone then
                self:_setSafeReentryLocked(player)
            end
        else
            self:_setActorSafeBarrierLocked(player, true)
            if isInsideSafeZone and self:_pushActorOutsideSafeZone(player) then
                self:_fireTransitionFeedback(player, "Blocked", "SafeReentryLocked")
            end
        end
    end
end

function ArenaService:_rollbackFailedArenaEnter(actor, reason)
    if self._playerStateService then
        self._playerStateService:SetInArena(actor, false)
        self._playerStateService:PushState(actor)
    end
    self:_resetSafeReentryLock(actor)
    if self._weaponService and self._weaponService.ClearPlayerWeapons then
        self._weaponService:ClearPlayerWeapons(actor)
    end
    self:_fireTransitionFeedback(actor, "Blocked", reason or "TeleportFailed")
end

function ArenaService:_clearArenaSessionState(player)
    if ActorUtils.IsPlayer(player) then
        self._hasEnteredArenaThisSessionByUserId[player.UserId] = nil
        self._firstArenaEnterPendingByUserId[player.UserId] = nil
        self:_resetSafeReentryLock(player)
    end
end

function ArenaService:_getArenaEnterShieldDuration(actor, options)
    local arenaConfig = GameConfig.ARENA or {}
    local defaultDuration = math.max(0, tonumber(arenaConfig.ArenaEnterShieldDurationSeconds) or 10)
    if not ActorUtils.IsPlayer(actor) then
        return defaultDuration, false
    end

    local userId = actor.UserId
    local isRevive = type(options) == "table" and options.IsRevive == true
    local isFirstEnterThisSession = not isRevive
        and self._hasEnteredArenaThisSessionByUserId[userId] ~= true
        and self._firstArenaEnterPendingByUserId[userId] ~= true
    if isFirstEnterThisSession then
        return math.max(0, tonumber(arenaConfig.FirstArenaEnterShieldDurationSeconds) or 60), true
    end

    return defaultDuration, false
end

function ArenaService:_markArenaEntryVerified(actor, isFirstEnterThisSession)
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    if isFirstEnterThisSession == true then
        self._hasEnteredArenaThisSessionByUserId[actor.UserId] = true
        self._firstArenaEnterPendingByUserId[actor.UserId] = nil
    end
end

function ArenaService:_clearArenaEntryPending(actor, isFirstEnterThisSession)
    if ActorUtils.IsPlayer(actor) and isFirstEnterThisSession == true then
        self._firstArenaEnterPendingByUserId[actor.UserId] = nil
    end
end

function ArenaService:_scheduleArenaEntryVerification(actor, options)
    if not (ActorUtils.IsPlayer(actor) and self._playerStateService) then
        return
    end
    local isFirstEnterThisSession = type(options) == "table" and options.IsFirstEnterThisSession == true

    task.delay(BATTLE_ENTRY_VERIFY_DELAY_SECONDS, function()
        if not (actor and actor.Parent) then
            self:_clearArenaEntryPending(actor, isFirstEnterThisSession)
            return
        end

        local state = self._playerStateService:GetState(actor)
        if not (state and state.IsInArena == true and state.Alive == true) then
            self:_clearArenaEntryPending(actor, isFirstEnterThisSession)
            return
        end

        if self:_isActorInsideBattleBounds(actor) then
            self:_markArenaEntryVerified(actor, isFirstEnterThisSession)
            return
        end

        self:_clearArenaEntryPending(actor, isFirstEnterThisSession)
        self:_rollbackFailedArenaEnter(actor, "TeleportLost")
    end)
end

function ArenaService:_firePortalJoinPrompt(actor, eventType)
    if not (actor and self._portalJoinPromptEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    local normalizedEventType = tostring(eventType or "Show")
    if normalizedEventType == "Show" then
        self:_setPortalJoinPending(actor)
        self._portalPromptVisibleByUserId[actor.UserId] = true
    elseif normalizedEventType == "Hide" then
        self:_clearPortalVisibleState(actor)
    end

    self._portalJoinPromptEvent:FireClient(actor, {
        eventType = normalizedEventType,
        timestamp = os.clock(),
    })

    if normalizedEventType == "Show"
        and self._gameAnalyticsService
        and self._gameAnalyticsService.MarkOnce
        and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.PortalPromptShown")
    then
        self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 4, "PortalPromptShown", {
            source = "portal",
        })
    end
end

function ArenaService:_showPortalJoinPrompt(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end
    if self._portalPromptSuppressedUntilExitByUserId[actor.UserId] then
        return
    end
    if self._portalPromptVisibleByUserId[actor.UserId] then
        return
    end

    self:_firePortalJoinPrompt(actor, "Show")
end

function ArenaService:_hidePortalJoinPrompt(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end
    local hasPromptState = self._pendingPortalPromptByUserId[actor.UserId]
        or self._portalPromptVisibleByUserId[actor.UserId]
        or self._portalPromptSuppressedUntilExitByUserId[actor.UserId]
    if not hasPromptState then
        return
    end

    if not (self._pendingPortalPromptByUserId[actor.UserId] or self._portalPromptVisibleByUserId[actor.UserId]) then
        self:_clearPortalPromptState(actor)
        return
    end

    self:_firePortalJoinPrompt(actor, "Hide")
end

function ArenaService:_onPortalRangeHeartbeat(deltaTime)
    self._portalRangeMonitorAccumulator = self._portalRangeMonitorAccumulator + (deltaTime or 0)
    if self._portalRangeMonitorAccumulator < PORTAL_RANGE_CHECK_INTERVAL then
        return
    end
    self._portalRangeMonitorAccumulator = 0

    for _, player in ipairs(Players:GetPlayers()) do
        local hasPromptState = self._pendingPortalPromptByUserId[player.UserId]
            or self._portalPromptVisibleByUserId[player.UserId]
            or self._portalPromptSuppressedUntilExitByUserId[player.UserId]
        if hasPromptState then
            local state = self._playerStateService and self._playerStateService:GetState(player) or nil
            local isInsidePortal = self:_isActorInsidePortalBounds(player)
            if state and state.IsInArena then
                self:_clearPortalPromptState(player)
            elseif not isInsidePortal and self._portalPromptVisibleByUserId[player.UserId] then
                self:_hidePortalJoinPrompt(player)
            elseif not isInsidePortal and self._portalPromptSuppressedUntilExitByUserId[player.UserId] then
                self:_clearPortalPromptState(player)
            else
                self:_clearExpiredPortalJoinPending(player)
            end
        end
    end
end

function ArenaService:_onPortalTouched(hitPart)
    local character = hitPart and hitPart:FindFirstAncestorOfClass("Model")
    if not character then
        return
    end

    local actor = self:_resolveActorFromCharacter(character)
    if not actor then
        return
    end

    if ActorUtils.IsBot(actor) then
        self:TryEnterArena(actor)
        return
    end

    local state = self._playerStateService:GetState(actor)
    if state and state.IsInArena then
        return
    end

    local actorId = ActorUtils.GetActorId(actor)
    local now = os.clock()
    local lastClock = self._portalPromptDebounceByActorId[actorId]
    if lastClock and now - lastClock < GameConfig.ARENA.EnterDebounceSeconds then
        return
    end
    self._portalPromptDebounceByActorId[actorId] = now
    self:_showPortalJoinPrompt(actor)
end

function ArenaService:_onRequestJoinBattle(player, action)
    if not (player and player.Parent) then
        return
    end

    if action == "Cancel" then
        self:_clearPortalPromptState(player)
        self._portalPromptSuppressedUntilExitByUserId[player.UserId] = true
        if self._portalJoinPromptEvent then
            self._portalJoinPromptEvent:FireClient(player, {
                eventType = "Hide",
                timestamp = os.clock(),
            })
        end
        return
    end

    if self._gameAnalyticsService
        and self._gameAnalyticsService.MarkOnce
        and self._gameAnalyticsService:MarkOnce(player, "Onboarding.JoinBattleRequested")
    then
        self._gameAnalyticsService:TrackFunnel(player, "Onboarding", 5, "JoinBattleRequested", {
            source = "portal",
        })
    end

    if not self:_hasValidPortalJoinPending(player) then
        if self._portalPromptSuppressedUntilExitByUserId[player.UserId] or not self:_isActorInsidePortalBounds(player) then
            self:_hidePortalJoinPrompt(player)
            self:_fireTransitionFeedback(player, "Blocked", "OutsidePortal")
            return
        end

        self:_setPortalJoinPending(player)
    end

    if not self:_hasValidPortalJoinPending(player) then
        self:_hidePortalJoinPrompt(player)
        self:_fireTransitionFeedback(player, "Blocked", "OutsidePortal")
        return
    end

    local entered = self:TryEnterArena(player, { IgnoreDebounce = true })
    if entered then
        self:_hidePortalJoinPrompt(player)
        self:_clearPortalPromptState(player)
    end
end

function ArenaService:_isEnterDebounced(actor)
    local actorId = ActorUtils.GetActorId(actor)
    local now = os.clock()
    local lastClock = self._enterDebounceByActorId[actorId]
    if lastClock and now - lastClock < GameConfig.ARENA.EnterDebounceSeconds then
        return true
    end

    self._enterDebounceByActorId[actorId] = now
    return false
end

function ArenaService:TeleportActorToSpawnLocation(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not (self._spawnLocation and rootPart) then
        return false
    end

    local spawnPosition = Vector3.new(
        self._spawnLocation.Position.X,
        self:_getPartSurfaceY(self._spawnLocation) + self:_getActorGroundOffset(actor),
        self._spawnLocation.Position.Z
    )
    local lookAtPosition = ActorUtils.IsPlayer(actor) and self:_getPortalLookAtPosition() or nil
    self:_teleportActorToPosition(actor, spawnPosition, lookAtPosition)
    self:_resetSafeReentryLock(actor)
    self:_fireTransitionFeedback(actor, "ReturnHome", "SpawnLocation")
    return true
end

function ArenaService:TeleportPlayerToSpawnLocation(actor)
    return self:TeleportActorToSpawnLocation(actor)
end

function ArenaService:_samplePointInsideBattle()
    if not self._battlePart then
        return nil
    end

    local size = self._battlePart.Size
    local configuredSpawnSquareSize = tonumber(GameConfig.ARENA.BattleSpawnSquareSize) or 0
    local spawnSquareHalfSize = configuredSpawnSquareSize > 0 and (configuredSpawnSquareSize * 0.5) or math.huge

    local usableHalfX = math.max(0, math.min(size.X * 0.5, spawnSquareHalfSize))
    local usableHalfZ = math.max(0, math.min(size.Z * 0.5, spawnSquareHalfSize))

    local localX = 0
    local localZ = 0

    if usableHalfX > 0 then
        localX = (math.random() * 2 - 1) * usableHalfX
    end
    if usableHalfZ > 0 then
        localZ = (math.random() * 2 - 1) * usableHalfZ
    end

    local worldPoint = (self._battlePart.CFrame * CFrame.new(localX, 0, localZ)).Position
    return Vector3.new(worldPoint.X, self:_getPartSurfaceY(self._battlePart), worldPoint.Z)
end

function ArenaService:_samplePointInsideSafeZone()
    if not self._safePart then
        return nil
    end

    local size = self._safePart.Size
    local arenaConfig = GameConfig.ARENA or {}
    local padding = math.max(0, tonumber(arenaConfig.SafeSpawnPadding) or 0)
    local usableHalfX = math.max(0, (size.X * 0.5) - padding)
    local usableHalfZ = math.max(0, (size.Z * 0.5) - padding)

    local localX = 0
    local localZ = 0

    if usableHalfX > 0 then
        localX = (math.random() * 2 - 1) * usableHalfX
    end
    if usableHalfZ > 0 then
        localZ = (math.random() * 2 - 1) * usableHalfZ
    end

    local worldPoint = (self._safePart.CFrame * CFrame.new(localX, 0, localZ)).Position
    return Vector3.new(worldPoint.X, self:_getPartSurfaceY(self._safePart), worldPoint.Z)
end

function ArenaService:_getCandidateMinDistance(candidatePosition, enteringActor)
    local minDistance = math.huge
    local hasOtherArenaActors = false

    for _, otherActor in ipairs(self._playerStateService:GetArenaActors()) do
        if not ActorUtils.IsSameActor(otherActor, enteringActor) then
            local otherRootPart = ActorUtils.GetRootPart(otherActor)
            if otherRootPart then
                hasOtherArenaActors = true
                local distance = (candidatePosition - otherRootPart.Position).Magnitude
                if distance < minDistance then
                    minDistance = distance
                end
            end
        end
    end

    if not hasOtherArenaActors then
        return math.huge
    end

    return minDistance
end

function ArenaService:_findBestArenaSpawnPositionFromSampler(actor, sampler)
    local attempts = math.max(1, GameConfig.ARENA.SpawnCandidateAttempts)
    local minSpacing = GameConfig.ARENA.MinSpawnSpacing

    local bestCandidate = nil
    local bestCandidateMinDistance = -math.huge

    for _ = 1, attempts do
        local candidate = sampler()
        if candidate then
            candidate = Vector3.new(candidate.X, candidate.Y + self:_getActorGroundOffset(actor), candidate.Z)
            local candidateMinDistance = self:_getCandidateMinDistance(candidate, actor)
            if candidateMinDistance >= minSpacing then
                return candidate
            end

            if candidateMinDistance > bestCandidateMinDistance then
                bestCandidate = candidate
                bestCandidateMinDistance = candidateMinDistance
            end
        end
    end

    return bestCandidate
end

function ArenaService:_findBestArenaSpawnPosition(actor)
    if ActorUtils.IsPlayer(actor) and self._safePart then
        local safeCandidate = self:_findBestArenaSpawnPositionFromSampler(actor, function()
            return self:_samplePointInsideSafeZone()
        end)
        if safeCandidate then
            return safeCandidate
        end
    end

    return self:_findBestArenaSpawnPositionFromSampler(actor, function()
        return self:_samplePointInsideBattle()
    end)
end

function ArenaService:TryEnterArena(actor, options)
    if not actor then
        return false
    end
    if ActorUtils.IsPlayer(actor) and not actor.Parent then
        return false
    end
    if ActorUtils.IsPlayer(actor)
        and self._rebirthService
        and self._rebirthService.IsPlayerLoaded
        and not self._rebirthService:IsPlayerLoaded(actor)
    then
        self:_fireTransitionFeedback(actor, "Blocked", "DataLoading")
        return false
    end
    if self._playerStateService and self._playerStateService.GetState then
        local actorState = self._playerStateService:GetState(actor)
        if actorState and actorState.Alive ~= true then
            -- 死亡玩家必须走 Defeated 面板由 RespawnService 复活，不得经入场通道满状态重进战场。
            self:_fireTransitionFeedback(actor, "Blocked", "Defeated")
            return false
        end
    end
    if not self._battlePart then
        self:_fireTransitionFeedback(actor, "Blocked", "BattleUnavailable")
        return false
    end
    local ignoreDebounce = type(options) == "table" and options.IgnoreDebounce == true
    if not ignoreDebounce and self:_isEnterDebounced(actor) then
        self:_fireTransitionFeedback(actor, "Blocked", "Debounced")
        return false
    end

    local rootPart = ActorUtils.GetRootPart(actor)
    if not rootPart then
        self:_fireTransitionFeedback(actor, "Blocked", "CharacterNotReady")
        return false
    end

    local targetPosition = self:_findBestArenaSpawnPosition(actor)
    if not targetPosition then
        self:_fireTransitionFeedback(actor, "Blocked", "SpawnNotFound")
        return false
    end

    if not self:_teleportActorToPosition(actor, targetPosition) then
        self:_fireTransitionFeedback(actor, "Blocked", "TeleportFailed")
        return false
    end
    if not self:_isActorInsideBattleBounds(actor) then
        self:_fireTransitionFeedback(actor, "Blocked", "TeleportFailed")
        return false
    end

    self:_resetSafeReentryLock(actor)
    self._playerStateService:SetInArena(actor, true)
    if ActorUtils.IsPlayer(actor) and self._playerStateService.MarkGuideCompleted then
        self._playerStateService:MarkGuideCompleted(actor)
    end
    local isFirstEnterThisSession = false
    if ActorUtils.IsPlayer(actor) and self._healthService and self._healthService.GrantShield then
        local shieldDuration
        shieldDuration, isFirstEnterThisSession = self:_getArenaEnterShieldDuration(actor, options)
        if isFirstEnterThisSession then
            self._firstArenaEnterPendingByUserId[actor.UserId] = true
        end
        if shieldDuration > 0 then
            self._healthService:GrantShield(actor, shieldDuration, isFirstEnterThisSession and "FirstArenaEnter" or "ArenaEnter")
        else
            self._playerStateService:PushState(actor)
        end
    else
        self._playerStateService:PushState(actor)
    end
    if self._weaponService then
        self._weaponService:RebuildWeaponsForPlayer(actor)
    end
    self:_scheduleArenaEntryVerification(actor, {
        IsFirstEnterThisSession = isFirstEnterThisSession,
    })
    self:_fireTransitionFeedback(actor, "EnterBattle", "RandomBattleSpawn")
    if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService then
        if self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.EnteredBattle") then
            self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 6, "EnteredBattle", {
                source = "portal",
            })
        end
        self._gameAnalyticsService:TrackCustom(actor, "BattleEntered", 1, {
            source = "portal",
        })
    end
    return true
end

return ArenaService
