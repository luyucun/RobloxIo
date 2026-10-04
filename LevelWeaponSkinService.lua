--[[
脚本名字: LevelWeaponSkinService
脚本文件: LevelWeaponSkinService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/LevelWeaponSkinService
说明: V6.27 服务端权威等级武器外观：状态同步、装备/复原/自动开关意图校验。
解锁目录由 HighestLevelReached 与 WeaponTierConfig 派生；视觉模板由 WeaponService 逐槽解析。
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
        "[LevelWeaponSkinService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local LevelWeaponSkinService = {}

LevelWeaponSkinService._playerStateService = nil
LevelWeaponSkinService._rebirthService = nil
LevelWeaponSkinService._remoteEventService = nil
LevelWeaponSkinService._stateSyncEvent = nil
LevelWeaponSkinService._requestStateSyncEvent = nil
LevelWeaponSkinService._requestEquipEvent = nil
LevelWeaponSkinService._feedbackEvent = nil
LevelWeaponSkinService._connections = {}
LevelWeaponSkinService._lastRequestClockByUserId = {}

local REQUEST_DEBOUNCE_SECONDS = 0.2
local PLAYER_LOADED_WAIT_SECONDS = 15

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getUserId(player)
    return player and player.UserId or 0
end

function LevelWeaponSkinService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function LevelWeaponSkinService:_canProcessRequest(player, requestKind)
    local nowClock = os.clock()
    local requestKey = tostring(getUserId(player)) .. ":" .. tostring(requestKind or "default")
    local lastClock = tonumber(self._lastRequestClockByUserId[requestKey]) or 0
    if nowClock - lastClock < REQUEST_DEBOUNCE_SECONDS then
        return false
    end
    self._lastRequestClockByUserId[requestKey] = nowClock
    return true
end

function LevelWeaponSkinService:BuildStatePayload(player)
    if not (self._playerStateService and ActorUtils.IsPlayer(player) and player.Parent) then
        return nil
    end
    local skinState = self._playerStateService:GetLevelWeaponSkinState(player)
    return {
        selectedTierIndex = skinState.selectedTierIndex,
        autoUpgrade = skinState.autoUpgrade,
        highestLevelReached = skinState.highestLevelReached,
        maxUnlockedTierIndex = skinState.maxUnlockedTierIndex,
        totalTierCount = WeaponTierConfig.TotalTierCount,
        timestamp = os.clock(),
    }
end

function LevelWeaponSkinService:PushState(player)
    if not (self._stateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    local payload = self:BuildStatePayload(player)
    if payload then
        self._stateSyncEvent:FireClient(player, payload)
    end
end

function LevelWeaponSkinService:_fireFeedback(player, eventType, reason)
    if not (self._feedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._feedbackEvent:FireClient(player, {
        eventType = tostring(eventType or ""),
        reason = tostring(reason or ""),
        state = self:BuildStatePayload(player),
        timestamp = os.clock(),
    })
end

function LevelWeaponSkinService:_handleStateRequest(player)
    if not self:_canProcessRequest(player, "StateSync") then
        return
    end
    self:PushState(player)
end

function LevelWeaponSkinService:_handleEquipRequest(player, payload, extra)
    if not self:_canProcessRequest(player, "Equip") then
        self:_fireFeedback(player, "Failed", "Debounced")
        return
    end
    if not self:_isPlayerLoaded(player) then
        self:PushState(player)
        self:_fireFeedback(player, "Failed", "DataLoading")
        return
    end

    if type(payload) == "number" then
        local tierIndex = math.floor(payload)
        if tierIndex ~= payload or tierIndex < 1 or tierIndex > WeaponTierConfig.TotalTierCount then
            self:_fireFeedback(player, "Failed", "InvalidArgument")
            return
        end
        local success, reason = self._playerStateService:EquipLevelWeaponSkin(player, tierIndex)
        if not success then
            self:PushState(player)
            self:_fireFeedback(player, "Failed", reason or "Error")
            return
        end
        self:PushState(player)
        self:_fireFeedback(player, "Equipped", reason)
        return
    end

    if payload == "UseLevelLook" then
        local success, reason = self._playerStateService:UseLevelWeaponLook(player)
        if not success then
            self:PushState(player)
            self:_fireFeedback(player, "Failed", reason or "Error")
            return
        end
        self:PushState(player)
        self:_fireFeedback(player, "Reset", reason)
        return
    end

    if payload == "AutoUpgrade" then
        if type(extra) ~= "boolean" then
            self:_fireFeedback(player, "Failed", "InvalidArgument")
            return
        end
        local success, reason = self._playerStateService:SetLevelWeaponAutoUpgrade(player, extra)
        if not success then
            self:PushState(player)
            self:_fireFeedback(player, "Failed", reason or "Error")
            return
        end
        self:PushState(player)
        self:_fireFeedback(player, "AutoUpdated", reason)
        return
    end

    self:_fireFeedback(player, "Failed", "InvalidArgument")
end

function LevelWeaponSkinService:Init(dependencies)
    dependencies = dependencies or {}
    self._playerStateService = dependencies.PlayerStateService
    self._rebirthService = dependencies.RebirthService
    self._remoteEventService = dependencies.RemoteEventService

    disconnectAll(self._connections)

    self._stateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("LevelWeaponSkinStateSync") or nil
    self._requestStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestLevelWeaponSkinStateSync") or nil
    self._requestEquipEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestLevelWeaponSkinEquip") or nil
    self._feedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("LevelWeaponSkinFeedback") or nil

    if self._requestStateSyncEvent then
        table.insert(self._connections, self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            self:_handleStateRequest(player)
        end))
    end
    if self._requestEquipEvent then
        table.insert(self._connections, self._requestEquipEvent.OnServerEvent:Connect(function(player, payload, extra)
            self:_handleEquipRequest(player, payload, extra)
        end))
    end
end

function LevelWeaponSkinService:OnPlayerAdded(player)
    task.spawn(function()
        local deadline = os.clock() + PLAYER_LOADED_WAIT_SECONDS
        while player and player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
            task.wait(0.5)
        end
        if player and player.Parent and self:_isPlayerLoaded(player) then
            self:PushState(player)
        end
    end)
end

function LevelWeaponSkinService:OnPlayerRemoving(player)
    local prefix = tostring(getUserId(player)) .. ":"
    for requestKey in pairs(self._lastRequestClockByUserId) do
        if string.sub(requestKey, 1, #prefix) == prefix then
            self._lastRequestClockByUserId[requestKey] = nil
        end
    end
end

return LevelWeaponSkinService
