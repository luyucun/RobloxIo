--[[
脚本名字: ArenaService
脚本文件: ArenaService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/ArenaService
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
        "[ArenaService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local ArenaService = {}

local PORTAL_RANGE_CHECK_INTERVAL = 0.1
local PORTAL_RANGE_PADDING = 3

ArenaService._playerStateService = nil
ArenaService._weaponService = nil
ArenaService._botService = nil
ArenaService._arenaTransitionFeedbackEvent = nil
ArenaService._portalJoinPromptEvent = nil
ArenaService._requestJoinBattleEvent = nil
ArenaService._enterDebounceByActorId = {}
ArenaService._portalPromptDebounceByActorId = {}
ArenaService._pendingPortalPromptByUserId = {}
ArenaService._portalPromptVisibleByUserId = {}
ArenaService._portalPromptSuppressedUntilExitByUserId = {}
ArenaService._spawnLocation = nil
ArenaService._portalModel = nil
ArenaService._battlePart = nil
ArenaService._portalTouchedConnections = {}
ArenaService._requestJoinBattleConnection = nil
ArenaService._portalRangeMonitorConnection = nil
ArenaService._playerRemovingConnection = nil
ArenaService._portalRangeMonitorAccumulator = 0

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

function ArenaService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._weaponService = dependencies.WeaponService
    self._botService = dependencies.BotService
    self._arenaTransitionFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("ArenaTransitionFeedback") or nil
    self._portalJoinPromptEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("PortalJoinPrompt") or nil
    self._requestJoinBattleEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestJoinBattle") or nil
    self._enterDebounceByActorId = {}
    self._portalPromptDebounceByActorId = {}
    self._pendingPortalPromptByUserId = {}
    self._portalPromptVisibleByUserId = {}
    self._portalPromptSuppressedUntilExitByUserId = {}
    self._portalRangeMonitorAccumulator = 0
    self._spawnLocation = resolveSpawnLocation()
    self._portalModel = resolvePortalModel()
    self._battlePart = resolveBattlePart()

    if not self._spawnLocation then
        warn("[ArenaService] 找不到 SpawnLocation，玩家默认出生点逻辑将不可用。")
    end
    if not self._portalModel then
        warn("[ArenaService] 找不到 workspace.Map2.Portals.Portal，玩家入场弹窗逻辑将不可用。")
    end
    if not self._battlePart then
        warn("[ArenaService] 找不到 workspace.Battle，战斗区随机出生逻辑将不可用。")
    end

    self:_disconnectPortalTouchedConnections()
    self:_disconnectPortalRangeMonitor()

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
    end)

    self:_connectPortalTouched()
    self:_connectPortalRangeMonitor()
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

function ArenaService:_teleportActorToPosition(actor, targetPosition)
    local character = ActorUtils.GetCharacter(actor)
    local rootPart = ActorUtils.GetRootPart(actor)
    if not (character and rootPart and typeof(targetPosition) == "Vector3") then
        return false
    end

    character:PivotTo(self:_buildTeleportCFrame(actor, targetPosition))
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

function ArenaService:_clearPortalPromptState(actor)
    if not (actor and ActorUtils.IsPlayer(actor)) then
        return
    end

    self._pendingPortalPromptByUserId[actor.UserId] = nil
    self._portalPromptVisibleByUserId[actor.UserId] = nil
    self._portalPromptSuppressedUntilExitByUserId[actor.UserId] = nil
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

function ArenaService:_firePortalJoinPrompt(actor, eventType)
    if not (actor and self._portalJoinPromptEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    local normalizedEventType = tostring(eventType or "Show")
    if normalizedEventType == "Show" then
        self._pendingPortalPromptByUserId[actor.UserId] = true
        self._portalPromptVisibleByUserId[actor.UserId] = true
    elseif normalizedEventType == "Hide" then
        self:_clearPortalPromptState(actor)
    end

    self._portalJoinPromptEvent:FireClient(actor, {
        eventType = normalizedEventType,
        timestamp = os.clock(),
    })
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
            if (state and state.IsInArena) or not isInsidePortal then
                self:_hidePortalJoinPrompt(player)
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
        self._portalPromptSuppressedUntilExitByUserId[player.UserId] = true
        self:_hidePortalJoinPrompt(player)
        self._portalPromptSuppressedUntilExitByUserId[player.UserId] = true
        return
    end

    if not self._pendingPortalPromptByUserId[player.UserId] then
        self:_fireTransitionFeedback(player, "Blocked", "PortalPromptRequired")
        return
    end
    if not self:_isActorInsidePortalBounds(player) then
        self:_hidePortalJoinPrompt(player)
        self:_fireTransitionFeedback(player, "Blocked", "OutsidePortal")
        return
    end

    self:_hidePortalJoinPrompt(player)
    self:TryEnterArena(player)
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
    self:_teleportActorToPosition(actor, spawnPosition)
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

function ArenaService:_findBestArenaSpawnPosition(actor)
    local attempts = math.max(1, GameConfig.ARENA.SpawnCandidateAttempts)
    local minSpacing = GameConfig.ARENA.MinSpawnSpacing

    local bestCandidate = nil
    local bestCandidateMinDistance = -math.huge

    for _ = 1, attempts do
        local candidate = self:_samplePointInsideBattle()
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

function ArenaService:TryEnterArena(actor, options)
    if not actor then
        return false
    end
    if ActorUtils.IsPlayer(actor) and not actor.Parent then
        return false
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

    self:_teleportActorToPosition(actor, targetPosition)
    self._playerStateService:SetInArena(actor, true)
    self._playerStateService:PushState(actor)
    if self._weaponService then
        self._weaponService:RebuildWeaponsForPlayer(actor)
    end
    self:_fireTransitionFeedback(actor, "EnterBattle", "RandomBattleSpawn")
    return true
end

return ArenaService
