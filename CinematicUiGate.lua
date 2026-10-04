--[[
Script: CinematicUiGate
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/CinematicUiGate
Client presentation barrier. Reward/state authority remains in existing services.
]]
local CinematicUiGate = {}
CinematicUiGate._holds = {}
CinematicUiGate._listeners = {}
CinematicUiGate._pending = {}
CinematicUiGate._order = {}
CinematicUiGate._revision = 0
CinematicUiGate._publishedBlocked = false
CinematicUiGate._drainScheduled = false

function CinematicUiGate:IsBlocked()
    return next(self._holds) ~= nil
end

function CinematicUiGate:_publish(blocked)
    if self._publishedBlocked == blocked then
        return
    end
    self._publishedBlocked = blocked
    local listeners = {}
    for connection, callback in pairs(self._listeners) do
        table.insert(listeners, {connection, callback})
    end
    for _, entry in ipairs(listeners) do
        if entry[1].Connected and self:IsBlocked() == blocked then
            local ok, message = pcall(entry[2], blocked)
            if not ok then
                warn("[CinematicUiGate] Listener failed: " .. tostring(message))
            end
        end
    end
end

function CinematicUiGate:_scheduleDrain()
    if self._drainScheduled or self:IsBlocked() or #self._order == 0 then
        return
    end
    self._drainScheduled = true
    task.defer(function()
        self._drainScheduled = false
        if self:IsBlocked() then
            return
        end
        local key = table.remove(self._order, 1)
        local callback = key and self._pending[key]
        if key then
            self._pending[key] = nil
        end
        if callback then
            local ok, message = pcall(callback)
            if not ok then
                warn("[CinematicUiGate] Deferred presentation failed: " .. tostring(message))
            end
        end
        self:_scheduleDrain()
    end)
end

function CinematicUiGate:Acquire(owner)
    local wasBlocked = self:IsBlocked()
    local token = {owner = tostring(owner or "Cinematic")}
    self._holds[token] = true
    self._revision += 1
    if not wasBlocked then
        self:_publish(true)
    end
    return token
end

function CinematicUiGate:Release(token)
    if not self._holds[token] then
        return
    end
    self._holds[token] = nil
    self._revision += 1
    if self:IsBlocked() then
        return
    end
    local revision = self._revision
    -- A new queued cinematic may acquire in this frame. Recheck before showing UI.
    task.defer(function()
        if revision ~= self._revision or self:IsBlocked() then
            return
        end
        self:_publish(false)
        self:_scheduleDrain()
    end)
end

function CinematicUiGate:Subscribe(callback)
    assert(type(callback) == "function", "CinematicUiGate callback must be a function")
    local gate = self
    local connection = {Connected = true}
    function connection:Disconnect()
        self.Connected = false
        gate._listeners[self] = nil
    end
    self._listeners[connection] = callback
    if self:IsBlocked() then
        local ok, message = pcall(callback, true)
        if not ok then
            warn("[CinematicUiGate] Listener failed: " .. tostring(message))
        end
    end
    return connection
end

function CinematicUiGate:Defer(key, callback)
    assert(type(callback) == "function", "CinematicUiGate deferred callback must be a function")
    key = key or {}
    if not self._pending[key] then
        table.insert(self._order, key)
    end
    self._pending[key] = callback
    self:_scheduleDrain()
end

function CinematicUiGate:CancelDeferred(key)
    self._pending[key] = nil
end

return CinematicUiGate
