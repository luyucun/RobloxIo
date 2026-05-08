--[[
脚本名字: ArenaProgressService
脚本文件: ArenaProgressService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/ArenaProgressService
说明: 广播当前战场内真实玩家的等级进度表现数据。
]]

local Players = game:GetService("Players")

local ArenaProgressService = {}

ArenaProgressService._playerStateService = nil
ArenaProgressService._arenaProgressSyncEvent = nil
ArenaProgressService._dirty = true
ArenaProgressService._broadcastQueued = false
ArenaProgressService._lastBroadcastClock = 0
ArenaProgressService._minBroadcastIntervalSeconds = 0.1

local function normalizeLevel(value)
    return math.max(1, math.floor(tonumber(value) or 1))
end

function ArenaProgressService:_buildPayload()
    local rows = {}
    local minLevel = nil
    local maxLevel = nil

    if self._playerStateService then
        for _, player in ipairs(self._playerStateService:GetArenaPlayers()) do
            if player and player.Parent then
                local state = self._playerStateService:GetState(player)
                if state and state.IsInArena == true and state.Alive == true then
                    local level = normalizeLevel(state.Level)
                    minLevel = minLevel and math.min(minLevel, level) or level
                    maxLevel = maxLevel and math.max(maxLevel, level) or level
                    table.insert(rows, {
                        userId = player.UserId,
                        name = player.Name,
                        level = level,
                    })
                end
            end
        end
    end

    table.sort(rows, function(left, right)
        if left.level == right.level then
            return tostring(left.name) < tostring(right.name)
        end
        return left.level < right.level
    end)

    return {
        players = rows,
        minLevel = minLevel or 0,
        maxLevel = maxLevel or 0,
        timestamp = os.clock(),
    }
end

function ArenaProgressService:_broadcast()
    if not self._arenaProgressSyncEvent then
        return
    end

    local payload = self:_buildPayload()
    for _, player in ipairs(Players:GetPlayers()) do
        self._arenaProgressSyncEvent:FireClient(player, payload)
    end
    self._lastBroadcastClock = os.clock()
end

function ArenaProgressService:BroadcastNow()
    self._dirty = false
    self._broadcastQueued = false
    self:_broadcast()
end

function ArenaProgressService:MarkDirty()
    self._dirty = true
    if self._broadcastQueued then
        return
    end

    self._broadcastQueued = true
    task.spawn(function()
        local elapsed = os.clock() - self._lastBroadcastClock
        local delaySeconds = self._minBroadcastIntervalSeconds - elapsed
        if delaySeconds > 0 then
            task.wait(delaySeconds)
        end

        self._broadcastQueued = false
        if self._dirty then
            self:BroadcastNow()
        end
    end)
end

function ArenaProgressService:OnPlayerAdded(player)
    self:MarkDirty()
    if self._arenaProgressSyncEvent and player and player.Parent then
        self._arenaProgressSyncEvent:FireClient(player, self:_buildPayload())
    end
end

function ArenaProgressService:OnPlayerRemoving(_player)
    self:MarkDirty()
end

function ArenaProgressService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._arenaProgressSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("ArenaProgressSync") or nil
    self._dirty = true
    self._broadcastQueued = false
    self._lastBroadcastClock = 0
    self:MarkDirty()
end

return ArenaProgressService
