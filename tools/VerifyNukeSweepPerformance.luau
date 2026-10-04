-- V6.20 nuke sweep regressions: read source, run private copies against Lua-table services.
-- No production Init, real Instance creation, RemoteEvent, DataStore, or Playtest.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local HttpService = game:GetService("HttpService")
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local controllers = game:GetService("StarterPlayer").StarterPlayerScripts.Controllers
local actualTypeof = typeof
local passed, failed, warnings = {}, {}, {}

local function forbidden() error("Sweep fixture attempted an external side effect") end
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function source(name, folder)
    return sourceOverrides and sourceOverrides[name] or folder:WaitForChild(name).Source
end
local function loadSource(code, env, name)
    local chunk, message = loadstring(code, "SweepFixture/" .. name)
    assert(chunk, message); setfenv(chunk, env); return chunk()
end

-- The two frame phases are explicit. Connected simulation callbacks are never fired.
local function scheduler()
    local s = { now = 100, frame = 0, waiters = { RenderStepped = {}, Heartbeat = {} } }
    function s:resume(thread, ...)
        if coroutine.status(thread) == "dead" then return end
        local ok, phase = coroutine.resume(thread, ...)
        assert(ok, tostring(phase))
        if coroutine.status(thread) ~= "dead" then
            assert(self.waiters[phase], "Unexpected yield: " .. tostring(phase))
            table.insert(self.waiters[phase], thread)
        end
    end
    function s:fire(phase)
        local waiting = self.waiters[phase]; self.waiters[phase] = {}
        for _, thread in ipairs(waiting) do self:resume(thread, 1 / 60) end
    end
    function s:nextFrame()
        self.frame += 1; self.now += 1 / 60
        self:fire("RenderStepped"); self:fire("Heartbeat")
    end
    function s:runAll()
        local count = 0
        while #self.waiters.RenderStepped + #self.waiters.Heartbeat > 0 do
            count += 1; assert(count <= 1000, "Retired cleanup did not terminate")
            self:nextFrame()
        end
    end
    s.task = { spawn = function(callback, ...)
        local thread = coroutine.create(callback); s:resume(thread, ...); return thread
    end, defer = forbidden, delay = forbidden, wait = forbidden, cancel = forbidden }
    return s
end
local function signal(s, phase)
    local value = { connections = {} }
    function value:Connect(callback)
        local connection = { Connected = true, callback = callback }
        function connection:Disconnect() self.Connected = false end
        table.insert(self.connections, connection); return connection
    end
    function value:Wait() assert(phase); return coroutine.yield(phase) end
    return value
end

-- All objects and folders below are Lua tables. Descendant destruction is modeled,
-- but the logs count explicit Stop/Destroy calls, matching the service's object budget.
local function instanceFactory(f)
    local methods = {}
    function methods:IsA(className)
        return className == "Instance" or self.ClassName == className
            or (className == "BasePart" and self.ClassName == "Part")
    end
    function methods:GetChildren() return table.clone(self._children) end
    function methods:FindFirstChild(name)
        for _, child in ipairs(self._children) do if child.Name == name then return child end end
        return nil
    end
    function methods:WaitForChild(name)
        local child = self:FindFirstChild(name); assert(child, "Missing fake child " .. tostring(name)); return child
    end
    function methods:IsDescendantOf(ancestor)
        local parent = self.Parent
        while parent do if parent == ancestor then return true end; parent = parent.Parent end
        return false
    end
    function methods:ClearAllChildren()
        for _, child in ipairs(self:GetChildren()) do child:Destroy() end
    end
    function methods:Stop()
        table.insert(f.stops, self)
        if self._throwStop then error("fixture track Stop failure") end
        self.Playing = false
    end
    function methods:Destroy()
        table.insert(f.destroys, { object = self, frame = f.s.frame })
        f.s.now += f.destroyCost
        if self._throwDestroy then error("fixture object Destroy failure") end
        local function dispose(object)
            for _, child in ipairs(object:GetChildren()) do dispose(child) end
            object.Parent = nil; object._destroyed = true
        end
        dispose(self)
    end
    function methods:Clone() return forbidden() end
    function methods:GetAttribute(name) return self._attributes[name] end
    function methods:SetAttribute(name, value) self._attributes[name] = value end
    local function make(className, name, parent)
        local props = { ClassName = className, Name = name or className, Parent = nil }
        local object = { _props = props, _children = {}, _attributes = {}, _fixtureInstance = true }
        setmetatable(object, {
            __index = function(value, key) return methods[key] or value._props[key] end,
            __newindex = function(value, key, newValue)
                if key == "Parent" then
                    local previous = value._props.Parent
                    if previous == newValue then return end
                    if previous then
                        local index = table.find(previous._children, value)
                        if index then table.remove(previous._children, index) end
                    end
                    value._props.Parent = newValue
                    if newValue then table.insert(newValue._children, value) end
                elseif string.sub(key, 1, 1) == "_" then rawset(value, key, newValue)
                else value._props[key] = newValue end
            end,
        })
        object.Parent = parent; return object
    end
    return make
end

local function fixture()
    local f = { s = scheduler(), stops = {}, destroys = {}, reports = {}, oldObjects = {}, destroyCost = 0 }
    f.new = instanceFactory(f)
    f.workspace = f.new("Workspace", "Workspace")
    f.runtime = f.new("Folder", "Runtime", f.workspace)
    f.replicated = f.new("ReplicatedStorage", "ReplicatedStorage")
    local sharedFolder = f.new("Folder", "Shared", f.replicated)
    for _, name in ipairs({ "GameConfig", "RemoteNames", "MonsterCatalog" }) do f.new("ModuleScript", name, sharedFolder) end
    local fakeRunService = { RenderStepped = signal(f.s, "RenderStepped"), Heartbeat = signal(f.s, "Heartbeat") }
    local services = { Players = { LocalPlayer = {} }, RunService = fakeRunService,
        ReplicatedStorage = f.replicated, Workspace = f.workspace,
        KeyframeSequenceProvider = {}, SoundService = {}, StarterGui = {}, TweenService = {}, Stats = {} }
    local env = setmetatable({ game = { GetService = function(_, name)
        assert(services[name], "Unexpected service " .. name); return services[name]
    end }, task = f.s.task, Instance = { new = function(className)
        equal(className, "Folder", "production instance request"); return f.new(className)
    end }, os = { clock = function() return f.s.now end },
    typeof = function(value) return type(value) == "table" and value._fixtureInstance and "Instance" or actualTypeof(value) end,
    warn = function(...) table.insert(warnings, table.concat({ ... }, " ")) end,
    print = forbidden }, { __index = getfenv() })
    f.config = loadSource(source("GameConfig", shared), env, "GameConfig")
    f.remoteNames = loadSource(source("RemoteNames", shared), env, "RemoteNames")
    env.require = function(module)
        if module.Name == "GameConfig" then return f.config end
        if module.Name == "RemoteNames" then return f.remoteNames end
        if module.Name == "MonsterCatalog" then return {} end
        return forbidden()
    end
    env.script = f.new("ModuleScript", "LocalMonsterController")
    f.controller = loadSource(source("LocalMonsterController", controllers), env, "LocalMonsterController")
    f.controller._monsterFolder = f.new("Folder", f.config.MONSTER.LocalRuntimeFolderName, f.runtime)
    local names = f.remoteNames
    local events = f.new("Folder", names.RootFolder, f.replicated)
    local system = f.new("Folder", names.SystemEventsFolder, events)
    local battle = f.new("Folder", names.BattleEventsFolder, events)
    f.new("RemoteEvent", names.System.PlayerStateSync, system).OnClientEvent = signal(f.s)
    for _, name in ipairs({ names.Battle.LocalMonsterSpawnToken, names.Battle.LocalMonsterKilled,
        names.Battle.LocalMonsterHitPlayer, names.Battle.NukeLocalMonsterSweep }) do
        local remote = f.new("RemoteEvent", name, battle); remote.OnClientEvent = signal(f.s)
        remote.FireServer = forbidden
        if name == names.Battle.NukeLocalMonsterSweep then
            f.nukeRemote = remote
            remote.FireServer = function(_, payload)
                table.insert(f.reports, { payload = payload, destroys = #f.destroys, stops = #f.stops })
                if f.throwRemote then error("fixture nuke report failure") end
            end
        end
    end
    f.controller._nukeLocalMonsterSweepEvent = f.nukeRemote
    function f:keep(object) table.insert(self.oldObjects, object); return object end
    function f:addMonster(id, token, alive, parent)
        local model = self:keep(self.new("Model", "Monster" .. id, parent or self.controller._monsterFolder))
        local health = self:keep(self.new("BillboardGui", "HealthBar", model))
        local track = self:keep(self.new("AnimationTrack", "Idle" .. id)); track.Playing = true
        local state = { Id = id, SpawnToken = token, Alive = alive ~= false, Instance = model,
            HealthBar = health, Tracks = { idle = track }, IsMaterialized = true,
            Position = Vector3.zero, DamageBucket = {}, HitFlash = {}, HitFlashEndClock = 101 }
        self.controller._monstersById[id] = state
        self.controller._materializedMonsterCount += 1
        return state, model, track
    end
    function f:effects()
        local pooled = self:keep(self.new("Model", "PooledMonster"))
        local pooledTrack = self:keep(self.new("AnimationTrack", "PooledIdle"))
        self.controller._monsterModelPoolByKey = { basic = { { Instance = pooled, Tracks = { idle = pooledTrack } } } }
        self.controller._monsterModelPoolCount = 1
        local anchor = self:keep(self.new("Part", "DamageActive", self.workspace))
        local damage = { Anchor = anchor }; self.controller._activeDamageNumberVisuals[damage] = true
        self.controller._damageNumberPool = { { Anchor = self:keep(self.new("Part", "DamagePooled", self.workspace)) } }
        self.controller._activeImpacts = { { Part = self:keep(self.new("Part", "ImpactActive", self.workspace)) } }
        self.controller._impactPool = { { Part = self:keep(self.new("Part", "ImpactPooled", self.workspace)) } }
        self:keep(self.new("Part", "OrphanChild", self.controller._monsterFolder))
    end
    function f:captureBatches()
        local entries = {}
        for _, batch in ipairs(self.controller._retiredNukeResourceBatches) do
            for _, entry in ipairs(batch.Resources) do table.insert(entries, entry) end
        end
        return entries
    end
    function f:assertDrained(entries)
        self.s:runAll()
        equal(#self.controller._retiredNukeResourceBatches, 0, "remaining batches")
        equal(self.controller._retiredNukeCleanupScheduled, false, "worker flag")
        for _, entry in ipairs(entries or {}) do equal(entry.Object, nil, "released captured reference") end
    end
    return f
end

local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    if ok then table.insert(passed, name) else table.insert(failed, { name = name, message = tostring(message) }) end
end

test("Sweep immediately retires combat and scene state before unchanged token report with no Destroy", function()
    local f = fixture(); local c = f.controller
    local state1 = f:addMonster(1, "alive-a"); f:addMonster(2, "alive-b")
    f:addMonster(3, "dead-token", false); f:addMonster(4, nil); f:effects()
    local oldFolder, oldMap = c._monsterFolder, c._monstersById
    f:keep(oldFolder)
    local authorizationQueue = { { token = "future-token" } }; c._spawnTokenQueue = authorizationQueue
    c._spawnTokenRequestPending = true; c._spawnTokenRequestDeadline = 123
    c._pendingKillsByRequestId.pending = {}; c._safeZoneRespawnDebt = 8
    equal(c:SweepForNuke("session-a"), 2); equal(#f.reports, 1)
    local report = f.reports[1]; equal(report.destroys, 0); equal(report.stops, 0)
    equal(report.payload.sessionId, "session-a"); equal(report.payload.timestamp, 100)
    table.sort(report.payload.tokens); equal(table.concat(report.payload.tokens, ","), "alive-a,alive-b")
    assert(oldMap ~= c._monstersById); equal(next(c._monstersById), nil)
    equal(state1.Alive, false); equal(state1.Instance, nil); equal(state1.DamageBucket, nil)
    equal(c:GetAliveMonsterSnapshotById(1), nil); equal(oldFolder.Parent, nil)
    assert(c._monsterFolder ~= oldFolder); equal(c._monsterFolder.Parent, f.runtime)
    equal(#c._monsterFolder:GetChildren(), 0); equal(c._materializedMonsterCount, 0)
    equal(c._spawnTokenQueue, authorizationQueue); equal(c._spawnTokenRequestPending, true)
    equal(c._spawnTokenRequestDeadline, 123); equal(next(c._pendingKillsByRequestId), nil)
    equal(c._safeZoneRespawnDebt, 0)
    equal(c._nextSpawnClock, 100 + math.max(0, tonumber(f.config.NUKE.MonsterRespawnPauseSeconds) or 2.5))
    f:assertDrained(f:captureBatches())
    for _, object in ipairs(f.oldObjects) do equal(object._destroyed, true, object.Name) end
end)

test("Cleanup waits for next render barrier then destroys at most 24 captured objects per heartbeat", function()
    local f = fixture(); for id = 1, 35 do f:addMonster(id, "token-" .. id) end
    local oldFolder = f.controller._monsterFolder
    f.controller:SweepForNuke("batch-budget"); local entries = f:captureBatches()
    f.s:fire("Heartbeat"); equal(#f.destroys, 0, "same-frame heartbeat")
    f.s:nextFrame(); equal(#f.destroys, 24, "first eligible heartbeat")
    f:assertDrained(entries); equal(oldFolder._destroyed, true)
    local counts = {}
    for _, item in ipairs(f.destroys) do counts[item.frame] = (counts[item.frame] or 0) + 1 end
    for _, count in pairs(counts) do assert(count <= 24, "Destroy exceeded object budget") end
    equal(#f.destroys, #entries); equal(#f.stops, 35)
end)

test("Soft 1.5ms cleanup budget stops after an expensive object and resumes all remaining resources", function()
    local f = fixture(); local resources = {}
    for index = 1, 60 do table.insert(resources, { Object = f.new("Part", "Cost" .. index) }) end
    f.controller:_queueRetiredNukeResources(resources)
    f.controller._retiredNukeResourceBatches[1].Ready = true
    local entries = f:captureBatches(); f.destroyCost = 0.001
    local started = f.s.now
    local processed, pending = f.controller:_drainRetiredNukeResourcesFrame()
    equal(processed, 2); equal(pending, true); assert(f.s.now - started < 0.0021)
    f:assertDrained(entries); equal(#f.destroys, 60)
end)

test("Consecutive sweeps never mutate same-ID new population folder pools or materialized count", function()
    local f = fixture(); f:addMonster(1, "first"); local firstFolder = f.controller._monsterFolder
    f.controller:SweepForNuke("first-session")
    local second, secondModel = f:addMonster(1, "second"); local secondFolder = f.controller._monsterFolder
    f.controller:SweepForNuke("second-session")
    local current, currentModel = f:addMonster(1, "third"); local currentFolder = f.controller._monsterFolder
    local newPool = f.new("Model", "NewPool", currentFolder)
    f.controller._monsterModelPoolByKey = { current = { { Instance = newPool } } }
    f.controller._monsterModelPoolCount = 1; f.controller._materializedMonsterCount = 7
    f:assertDrained(f:captureBatches())
    equal(firstFolder._destroyed, true); equal(secondFolder._destroyed, true)
    equal(second.Alive, false); equal(secondModel._destroyed, true)
    equal(current.Alive, true); equal(currentModel._destroyed, nil); equal(newPool._destroyed, nil)
    equal(f.controller._monstersById[1], current); equal(f.controller._monsterFolder, currentFolder)
    equal(currentFolder.Parent, f.runtime); equal(f.controller._materializedMonsterCount, 7)
    equal(f.controller._monsterModelPoolCount, 1)
    equal(f.reports[1].payload.tokens[1], "first"); equal(f.reports[2].payload.tokens[1], "second")
end)

test("An active worker cannot consume a newly queued batch before that batch's next render", function()
    local f = fixture(); for id = 1, 20 do f:addMonster(id, "old-" .. id) end
    f.controller:SweepForNuke("first"); f.s:nextFrame(); equal(#f.destroys, 24)
    local _, newerModel = f:addMonster(1, "newer")
    f.controller:SweepForNuke("second")
    f.s:fire("Heartbeat")
    equal(newerModel._destroyed, nil, "new batch skipped before render")
    local entries = f:captureBatches(); f:assertDrained(entries); equal(newerModel._destroyed, true)
end)

test("Private fake-service Init retains pending snapshots and cannot destroy later rebound same-ID resources", function()
    local f = fixture(); f:addMonster(1, "pre-init"); f:effects()
    local oldFolder = f.controller._monsterFolder
    f.controller:SweepForNuke("before-rebind"); local entries = f:captureBatches()
    local pending = f.controller._retiredNukeResourceBatches
    -- Only this fresh loadstring copy sees Init, and every service/remote/instance is fake.
    f.controller:Init({ LocalPlayer = {} })
    equal(f.controller._retiredNukeResourceBatches, pending)
    equal(f.controller._retiredNukeCleanupScheduled, true)
    local current, currentModel = f:addMonster(1, "post-init")
    local newFolder = f.controller._monsterFolder
    local pooled = f.new("Model", "PostInitPool")
    f.controller._monsterModelPoolByKey = { new = { { Instance = pooled } } }
    f.controller._monsterModelPoolCount = 3; f.controller._materializedMonsterCount = 9
    f:assertDrained(entries)
    equal(oldFolder._destroyed, true); equal(current.Alive, true); equal(currentModel._destroyed, nil)
    equal(pooled._destroyed, nil); equal(newFolder.Parent, f.runtime)
    equal(f.controller._materializedMonsterCount, 9); equal(f.controller._monsterModelPoolCount, 3)
    equal(f.controller._monstersById[1], current)
end)

test("Missing old folder detaches standalone roots immediately and still drains them without touching replacement", function()
    local f = fixture(); f.controller._monsterFolder:Destroy(); table.clear(f.destroys)
    f.controller._monsterFolder = nil
    local _, model = f:addMonster(1, "orphan", true, f.workspace)
    f:effects()
    equal(f.controller:SweepForNuke("fallback"), 1)
    equal(model.Parent, nil); equal(#f.destroys, 0); equal(#f.stops, 0)
    local replacement = f.controller._monsterFolder
    equal(replacement.Parent, f.runtime); equal(#replacement:GetChildren(), 0)
    f:assertDrained(f:captureBatches()); equal(model._destroyed, true); equal(replacement._destroyed, nil)
end)

test("Remote exception and individual Stop/Destroy exceptions cannot abandon the retired snapshot", function()
    local f = fixture(); local _, model, track = f:addMonster(1, "fault-token")
    f:effects(); track._throwStop = true; model._throwDestroy = true; f.throwRemote = true
    local ok, message = pcall(function() f.controller:SweepForNuke("faults") end)
    equal(ok, false); assert(string.find(message, "fixture nuke report failure", 1, true))
    equal(#f.destroys, 0); equal(#f.reports, 1); equal(f.controller._monsterFolder.Parent, f.runtime)
    f:assertDrained(f:captureBatches())
    equal(track._destroyed, true)
    for _, object in ipairs(f.oldObjects) do
        if object ~= model then equal(object._destroyed, true, object.Name) end
    end
    -- The old folder's final destruction also removes the one failed model root.
    equal(model._destroyed, true); equal(f.controller._materializedMonsterCount, 0)
end)

return HttpService:JSONEncode({ passed = passed, failed = failed, warnings = warnings })
