-- V6.18-V6.20 nuke presentation regressions. Studio Edit context, isolated source only.
-- Fake services, instances and clocks prevent production Init, remotes or combat side effects.
-- A local runner may replace sourceOverrides to verify unsynced repository code.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local HttpService = game:GetService("HttpService")
local actualTypeof = typeof
local shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local controllers = game:GetService("StarterPlayer").StarterPlayerScripts.Controllers
local controllerModule = controllers:WaitForChild("NukeCinematicController")
local gateModule = controllers:FindFirstChild("CinematicUiGate")
local passed, failed, warnings = {}, {}, {}

local function forbidden()
    error("Nuke fixture attempted an external side effect")
end
local function equal(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= (tolerance or 0.04),
        (label or "value") .. ": expected near " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Each yielded frame resumes on a controlled clock; no wall-clock delay is used.
local function scheduler()
    local s = { now = 100, queue = {}, cancelled = {}, frameSeconds = 1 / 60 }
    function s:resume(thread, ...)
        if self.cancelled[thread] or coroutine.status(thread) == "dead" then return end
        local ok, marker, seconds = coroutine.resume(thread, ...)
        assert(ok, tostring(marker))
        if coroutine.status(thread) ~= "dead" and marker == "fixture-wait" then
            table.insert(self.queue, { at = self.now + seconds, thread = thread, args = { seconds } })
        end
    end
    function s:runUntil(target)
        local iterations = 0
        while #self.queue > 0 do
            table.sort(self.queue, function(left, right) return left.at < right.at end)
            if self.queue[1].at > target + 0.000001 then break end
            iterations += 1
            assert(iterations <= 10000, "Nuke fixture queue did not terminate")
            local entry = table.remove(self.queue, 1)
            local before = self.now
            self.now = math.max(self.now, entry.at)
            if self.onAdvance and self.now > before then self.onAdvance(self.now - before) end
            self:resume(entry.thread, table.unpack(entry.args or {}))
        end
        local before = self.now
        self.now = math.max(self.now, target)
        if self.onAdvance and self.now > before then self.onAdvance(self.now - before) end
    end
    function s:runAll()
        local iterations = 0
        while #self.queue > 0 do
            iterations += 1
            assert(iterations <= 10000, "Nuke fixture queue did not drain")
            table.sort(self.queue, function(left, right) return left.at < right.at end)
            self:runUntil(self.queue[1].at)
        end
    end
    s.task = {
        spawn = function(callback, ...)
            local thread = type(callback) == "thread" and callback or coroutine.create(callback)
            s:resume(thread, ...)
            return thread
        end,
        delay = function(seconds, callback, ...)
            local thread = coroutine.create(callback)
            table.insert(s.queue, { at = s.now + math.max(0, seconds), thread = thread, args = { ... } })
            return thread
        end,
        defer = function(callback, ...)
            local thread = coroutine.create(callback)
            table.insert(s.queue, { at = s.now, thread = thread, args = { ... } })
            return thread
        end,
        wait = function(seconds)
            return coroutine.yield("fixture-wait", math.max(0.001, tonumber(seconds) or s.frameSeconds))
        end,
        cancel = function(thread) s.cancelled[thread] = true end,
    }
    return s
end

local function signal(s)
    local result = { connections = {} }
    function result:Connect(callback)
        local connection = { Connected = true, callback = callback }
        function connection:Disconnect() self.Connected = false end
        table.insert(self.connections, connection)
        return connection
    end
    function result:Fire(...)
        for _, connection in ipairs(self.connections) do
            if connection.Connected then s.task.spawn(connection.callback, ...) end
        end
    end
    function result:Wait() return s.task.wait(s.frameSeconds) end
    return result
end

local baseClasses = {
    Part = { BasePart = true }, MeshPart = { BasePart = true }, UnionOperation = { BasePart = true },
    Frame = { GuiObject = true }, TextLabel = { GuiObject = true }, TextButton = { GuiObject = true },
    ImageLabel = { GuiObject = true }, ImageButton = { GuiObject = true }, CanvasGroup = { GuiObject = true },
    TextBox = { GuiObject = true },
    PointLight = { Light = true }, SpotLight = { Light = true }, SurfaceLight = { Light = true },
    ColorCorrectionEffect = { PostEffect = true }, BloomEffect = { PostEffect = true },
    BlurEffect = { PostEffect = true }, DepthOfFieldEffect = { PostEffect = true },
}

-- Every "Instance" is a Lua table. These methods never create, parent or destroy Roblox objects.
local function createInstanceFactory(f)
    local methods = {}
    function methods:IsA(className)
        return className == "Instance" or self.ClassName == className
            or (baseClasses[self.ClassName] and baseClasses[self.ClassName][className]) == true
    end
    function methods:GetChildren() return table.clone(self._children) end
    function methods:GetDescendants()
        local result = {}
        local function collect(parent)
            for _, child in ipairs(parent._children) do
                table.insert(result, child)
                collect(child)
            end
        end
        collect(self)
        return result
    end
    function methods:FindFirstChild(name, recursive)
        for _, child in ipairs(self._children) do if child.Name == name then return child end end
        if recursive then
            for _, child in ipairs(self:GetDescendants()) do if child.Name == name then return child end end
        end
        return nil
    end
    function methods:WaitForChild(name) return self:FindFirstChild(name) end
    function methods:FindFirstChildOfClass(className)
        for _, child in ipairs(self._children) do if child.ClassName == className then return child end end
        return nil
    end
    function methods:FindFirstChildWhichIsA(className, recursive)
        for _, child in ipairs(recursive and self:GetDescendants() or self._children) do
            if child:IsA(className) then return child end
        end
        return nil
    end
    function methods:IsDescendantOf(parent)
        local current = self.Parent
        while current do
            if current == parent then return true end
            current = current.Parent
        end
        return false
    end
    function methods:GetFullName()
        return self.Parent and self.Parent:GetFullName() .. "." .. self.Name or self.Name
    end
    function methods:GetAttribute(name) return self._attributes[name] end
    function methods:SetAttribute(name, value) self._attributes[name] = value end
    function methods:GetPivot()
        if self:IsA("BasePart") then return self.CFrame end
        return self._properties.Pivot or (self.PrimaryPart and self.PrimaryPart.CFrame) or CFrame.new()
    end
    function methods:PivotTo(pivot)
        if self:IsA("BasePart") then self.CFrame = pivot; return end
        local oldPivot = self:GetPivot()
        for _, child in ipairs(self:GetDescendants()) do
            if child:IsA("BasePart") then child.CFrame = pivot * oldPivot:ToObjectSpace(child.CFrame) end
        end
        self.Pivot = pivot
    end
    function methods:GetBoundingBox()
        return self:GetPivot(), self.Bounds or Vector3.new(8, 12, 8)
    end
    function methods:Destroy()
        if self.Destroyed then return end
        for _, child in ipairs(self:GetChildren()) do child:Destroy() end
        self.Parent = nil
        self.Destroyed = true
        self.DestroyCount = self.DestroyCount + 1
    end
    function methods:Clone()
        table.insert(f.clones, { name = self.Name, className = self.ClassName, at = f.scheduler.now })
        if f.onClone then f.onClone(self) end
        local cloned = f.new(self.ClassName)
        for key, value in pairs(self._properties) do
            if key ~= "Parent" and key ~= "Destroyed" and key ~= "DestroyCount" then cloned[key] = value end
        end
        cloned._attributes = table.clone(self._attributes)
        for _, child in ipairs(self._children) do
            local clonedChild = child:Clone()
            clonedChild.Parent = cloned
            if self.PrimaryPart == child then cloned.PrimaryPart = clonedChild end
        end
        return cloned
    end
    function methods:Emit(amount)
        table.insert(f.emissions, { instance = self, count = amount, at = f.scheduler.now })
    end
    function methods:Clear() self.ClearCount = (self.ClearCount or 0) + 1 end
    function methods:Play()
        self.Playing = true
        table.insert(f.soundPlays, { instance = self, at = f.scheduler.now })
    end
    function methods:Stop() self.Playing = false; self.StopCount = (self.StopCount or 0) + 1 end
    function methods:LoadAnimation()
        return { Looped = false, Play = function() end, Stop = function() end, Destroy = function() end }
    end
    local mt = {
        __index = function(self, key)
            if methods[key] then return methods[key] end
            local value = self._properties[key]
            if value ~= nil then return value end
            return methods.FindFirstChild(self, key)
        end,
        __newindex = function(self, key, value)
            if string.sub(key, 1, 1) == "_" then rawset(self, key, value); return end
            if key == "Parent" then
                local oldParent = self._properties.Parent
                if oldParent == value then return end
                if oldParent then
                    local index = table.find(oldParent._children, self)
                    if index then table.remove(oldParent._children, index) end
                end
                if value then table.insert(value._children, self) end
            end
            self._properties[key] = value
            if key == "CFrame" and methods.IsA(self, "BasePart") then
                self._properties.Position = value.Position
            elseif key == "Position" and methods.IsA(self, "BasePart") then
                local oldFrame = self._properties.CFrame
                self._properties.CFrame = CFrame.new(value) * (oldFrame - oldFrame.Position)
            end
            table.insert(self._writes, { key = key, value = value, at = f.scheduler.now })
            if f.onWrite then f.onWrite(self, key, value) end
        end,
    }
    return function(className)
        local instance = setmetatable({ _children = {}, _attributes = {}, _writes = {}, _fixture = true, _createdAt = f.scheduler.now,
            _properties = { ClassName = className, Name = className, Destroyed = false, DestroyCount = 0,
                Archivable = true, Visible = false, Enabled = false, Playing = false,
                CFrame = CFrame.new(), Focus = CFrame.new(), Position = Vector3.zero,
                Size = Vector3.new(4, 4, 4), FieldOfView = 70, CameraType = Enum.CameraType.Custom,
                BackgroundTransparency = 0, TextTransparency = 0, TextStrokeTransparency = 0.75,
                ImageTransparency = 0, GroupTransparency = 0, ZIndex = 1, Text = "Fixture text",
                Color = Color3.new(1, 1, 1), Brightness = 1, Range = 12,
                TintColor = Color3.new(1, 1, 1), Contrast = 0, Saturation = 0,
                Speed = NumberRange.new(5, 10), Acceleration = Vector3.zero,
                Lifetime = NumberRange.new(0.4, 0.8), Rate = 20,
                Width0 = 2, Width1 = 2, CurveSize0 = 0, CurveSize1 = 0,
                WidthScale = NumberSequence.new(1), Scale = Vector3.one, Offset = Vector3.zero,
                TimeLength = 4, Volume = 1, PlaybackSpeed = 1, Health = 100, Transparency = 0,
            } }, mt)
        if className == "ParticleEmitter" then instance.Size = NumberSequence.new(1) end
        if instance:IsA("PostEffect") then instance.Enabled = true end
        if className == "Sound" then instance.Ended = signal(f.scheduler) end
        if className == "Player" then
            instance.CharacterAdded = signal(f.scheduler)
            instance.CharacterRemoving = signal(f.scheduler)
        end
        table.insert(f.instances, instance)
        return instance
    end
end

local function fixture()
    local f = { scheduler = scheduler(), instances = {}, clones = {}, preloads = {}, emissions = {}, soundPlays = {}, sweeps = {}, popups = {}, serverReads = 0 }
    f.new = createInstanceFactory(f)
    f.workspace, f.lighting, f.players, f.replicated = f.new("Workspace"), f.new("Lighting"), f.new("Players"), f.new("ReplicatedStorage")
    f.soundService = f.new("SoundService")
    f.lighting.ClockTime = 14.5
    function f.workspace:GetServerTimeNow()
        f.serverReads += 1
        return 1000 + (f.scheduler.now - 100) + (f.serverOffset or 0)
    end
    f.character = f.new("Model"); f.character.Name = "FixtureCharacter"; f.character.Parent = f.workspace
    f.humanoid = f.new("Humanoid"); f.humanoid.Parent = f.character
    f.characterRoot = f.new("Part"); f.characterRoot.Name = "HumanoidRootPart"; f.characterRoot.Parent = f.character
    f.player = f.new("Player"); f.player.UserId = 17001; f.player.Name = "NukeFixture"; f.player.Parent = f.players
    f.player.Character = f.character
    f.players.LocalPlayer = f.player
    f.camera = f.new("Camera"); f.camera.Parent = f.workspace; f.camera.CameraSubject = f.humanoid
    f.camera.CFrame = CFrame.lookAt(Vector3.new(30, 12, 30), Vector3.new(0, 3, 0))
    f.camera.Focus = CFrame.new(0, 3, 0)
    f.workspace.CurrentCamera = f.camera
    f.runService = { RenderStepped = signal(f.scheduler), Heartbeat = signal(f.scheduler) }
    function f.runService:IsStudio() return true end
    function f.runService:IsRunning() return false end
    f.scheduler.onAdvance = function(seconds)
        f.runService.RenderStepped:Fire(seconds)
        f.runService.Heartbeat:Fire(seconds)
    end
    f.tweenService = {}
    function f.tweenService:Create(instance, info, goals)
        local tween = { Completed = signal(f.scheduler), cancelled = false }
        function tween:Play()
            self.thread = f.scheduler.task.delay(info.Time, function()
                if self.cancelled then return end
                for key, value in pairs(goals) do instance[key] = value end
                self.Completed:Fire(Enum.PlaybackState.Completed)
            end)
        end
        function tween:Cancel() self.cancelled = true end
        function tween:Destroy() self:Cancel() end
        return tween
    end
    f.contentProvider = {}
    function f.contentProvider:PreloadAsync(resources)
        table.insert(f.preloads, { resources = resources, at = f.scheduler.now })
        if f.onPreload then return f.onPreload(resources) end
    end
    local fakeShared = f.new("Folder"); fakeShared.Name = "Shared"; fakeShared.Parent = f.replicated
    local moduleSources, isolated = {}, {}
    for _, moduleName in ipairs({ "GameConfig", "RemoteNames" }) do
        local module = f.new("ModuleScript"); module.Name = moduleName; module.Parent = fakeShared
        moduleSources[module] = sourceOverrides and sourceOverrides[moduleName] or shared:WaitForChild(moduleName).Source
    end
    local fakeControllers = f.new("Folder"); fakeControllers.Name = "Controllers"
    local fakeControllerModule = f.new("ModuleScript"); fakeControllerModule.Name = "NukeCinematicController"; fakeControllerModule.Parent = fakeControllers
    moduleSources[fakeControllerModule] = sourceOverrides and sourceOverrides.NukeCinematicController or controllerModule.Source
    local fakeGateModule = f.new("ModuleScript"); fakeGateModule.Name = "CinematicUiGate"; fakeGateModule.Parent = fakeControllers
    local gateSource = sourceOverrides and sourceOverrides.CinematicUiGate or (gateModule and gateModule.Source)
    assert(gateSource, "CinematicUiGate source is required; deploy it or provide a local source override")
    moduleSources[fakeGateModule] = gateSource
    local fakeServices = {
        Workspace = f.workspace, Lighting = f.lighting, Players = f.players, ReplicatedStorage = f.replicated,
        RunService = f.runService, TweenService = f.tweenService, SoundService = f.soundService, ContentProvider = f.contentProvider,
    }
    local fakeGame = {}
    function fakeGame:GetService(name)
        assert(fakeServices[name], "Unexpected service in nuke fixture: " .. tostring(name))
        return fakeServices[name]
    end
    local function loadIsolated(module)
        if isolated[module] ~= nil then return isolated[module] end
        assert(moduleSources[module], "Unexpected module in nuke fixture: " .. tostring(module))
        local chunk, compileError = loadstring(moduleSources[module], "=" .. module.Name)
        assert(chunk, compileError)
        setfenv(chunk, setmetatable({
            script = module, game = fakeGame, Instance = { new = f.new }, task = f.scheduler.task,
            os = setmetatable({ clock = function() return f.scheduler.now end }, { __index = os }),
            typeof = function(value)
                if type(value) == "table" and rawget(value, "_fixture") then return "Instance" end
                return actualTypeof(value)
            end,
            require = loadIsolated,
            warn = function(message) table.insert(warnings, tostring(message)) end,
        }, { __index = getfenv() }))
        isolated[module] = chunk()
        return isolated[module]
    end
    f.controller = loadIsolated(fakeControllerModule)
    f.gate = loadIsolated(fakeGateModule)
    f.config = loadIsolated(fakeShared.GameConfig)
    f.remoteNames = loadIsolated(fakeShared.RemoteNames)
    f.controller._localPlayer = f.player
    f.controller._localMonsterController = {
        SweepForNuke = function(_, sessionId)
            table.insert(f.sweeps, { sessionId = sessionId, at = f.scheduler.now })
            if f.onSweep then return f.onSweep(sessionId) end
        end,
    }
    f.controller._audioSettings = { PlaySfx = function(_, sound) sound:Play() end }
    f.initialCamera = { cframe = f.camera.CFrame, focus = f.camera.Focus, fov = f.camera.FieldOfView }
    table.clear(f.lighting._writes)
    function f:payload(sessionId)
        return { sessionId = sessionId or 1, ownerUserId = self.player.UserId, callerName = "NukeFixture",
            battleCenter = { x = 0, y = 0, z = 0 }, startDelaySeconds = 1,
            serverStartTime = 1000 + (self.scheduler.now - 100) + (self.serverOffset or 0) }
    end
    function f:clockWrites()
        local result = 0
        for _, write in ipairs(self.lighting._writes) do if write.key == "ClockTime" then result += 1 end end
        return result
    end
    function f:spend(seconds)
        -- Models synchronous Clone/scale/clear work: os.clock advances without yielding.
        self.scheduler.now += seconds
    end
    function f:queueReward(key)
        self.gate:Defer(key or "FixtureReward", function()
            table.insert(self.popups, { at = self.scheduler.now, blocked = self.gate:IsBlocked(), liveEffects = #self:liveEffects() })
        end)
    end
    function f:liveEffects()
        local result = {}
        for _, instance in ipairs(self.instances) do
            if not instance.Destroyed and ((instance:IsA("PostEffect") and instance.Parent == self.lighting and instance.Enabled)
                or (instance.Name == "NukeBoom" and instance.Playing) or (instance.Name == "NukeGroundWave" and instance.Parent == self.workspace)
                or (instance:IsA("Model") and instance.Parent == self.workspace
                    and instance ~= self.character)) then
                table.insert(result, instance)
            end
        end
        return result
    end
    return f
end

local function addGui(f)
    local playerGui = f.new("PlayerGui"); playerGui.Name = "PlayerGui"; playerGui.Parent = f.player
    local main = f.new("ScreenGui"); main.Name = "Main"; main.Parent = playerGui
    local banner = f.new("Frame"); banner.Name = "Nuke"; banner.Parent = main; banner.ZIndex = 7
    local text = f.new("TextLabel"); text.Name = "Text"; text.Parent = banner; text.TextTransparency = 0.2; text.ZIndex = 8
    local warning = f.new("ImageLabel"); warning.Name = "Warning"; warning.Parent = main
    warning.ImageTransparency = 0.3; warning.BackgroundTransparency = 0.65; warning.ZIndex = 9
    local stroke = f.new("UIStroke"); stroke.Transparency = 0.4; stroke.Parent = warning
    local overlay = f.new("ScreenGui"); overlay.Name = "NukeCinematicEffects"; overlay.Parent = playerGui
    local top, bottom, flash
    for _, name in ipairs({ "TopBar", "BottomBar", "ImpactFlash" }) do
        local node = f.new("Frame"); node.Name = name; node.Parent = overlay; node.BackgroundTransparency = 0.7; node.ZIndex = 4
        if name == "TopBar" then top = node elseif name == "BottomBar" then bottom = node else flash = node end
    end
    return { banner = banner, text = text, warning = warning, stroke = stroke, top = top, bottom = bottom, flash = flash }
end

local function addBomb(f)
    local bomb = f.new("Model"); bomb.Name = "LittleBoy"; bomb.Parent = f.replicated
    local root = f.new("Part"); root.Name = "Root"; root.Parent = bomb
    root.CFrame = CFrame.new(5, 7, 9) * CFrame.Angles(0.1, 0.4, 0.2)
    bomb.PrimaryPart = root
    return bomb
end

local function addEffect(f, emitterCount)
    local folder = f.new("Folder"); folder.Name = "Effect"; folder.Parent = f.replicated
    local effect = f.new("Model"); effect.Name = "Bomb"; effect.Parent = folder
    local part = f.new("Part"); part.Name = "Carrier"; part.Parent = effect; part.Size = Vector3.new(16, 10, 16)
    effect.PrimaryPart = part
    local attachment = f.new("Attachment"); attachment.Position = Vector3.new(0, 6, 0); attachment.Parent = part
    for index = 1, emitterCount or 80 do
        local emitter = f.new("ParticleEmitter"); emitter.Name = (index % 2 == 0 and "Smoke" or "Fire") .. tostring(index)
        emitter.Enabled = true; emitter.Rate = 10000; emitter:SetAttribute("EmitCount", 500)
        emitter.Speed = NumberRange.new(300, 600); emitter.Acceleration = Vector3.new(0, 500, 0)
        emitter.Lifetime = NumberRange.new(4, 7); emitter.Size = NumberSequence.new(400); emitter.Parent = attachment
    end
    for index = 1, 80 do
        local beam = f.new("Beam"); beam.Name = "Beam" .. tostring(index); beam.Width0 = 80; beam.Width1 = 120
        beam.Enabled = true; beam.Parent = attachment
    end
    local light = f.new("PointLight"); light.Range = 500; light.Brightness = 50; light.Enabled = true; light.Parent = part
    local trail = f.new("Trail"); trail.Enabled = true; trail.Parent = attachment
    return effect
end

local function addBoom(f)
    local folder = f.new("Folder"); folder.Name = (f.config.AUDIO or {}).FolderName or "Audio"; folder.Parent = f.soundService
    local sound = f.new("Sound"); sound.Name = (f.config.AUDIO or {}).BoomSoundName or "Boom"; sound.Parent = folder
    sound.Volume = 0.6
    return sound
end

local function newSession(f)
    local payload = f:payload()
    local session = { payload = payload, timeline = f.controller:_buildTimeline(payload), resources = {}, tracks = {}, guis = {},
        bars = {}, cancelled = false, presentationFinished = false }
    f.controller._session = session
    return session
end

local function assertDisposed(session)
    equal(session.cleaned, true, "session cleaned")
    equal(session.gateToken, nil, "session gate token released")
    for _, resource in ipairs(session.resources) do equal(resource.Destroyed, true, "resource destroyed") end
end

local function assertCameraRestored(f)
    equal(f.camera.CameraType, Enum.CameraType.Custom, "camera type")
    equal(f.camera.FieldOfView, f.initialCamera.fov, "camera FOV")
    near((f.camera.CFrame.Position - f.initialCamera.cframe.Position).Magnitude, 0, 0.001, "camera position")
    equal(f:clockWrites(), 0, "client ClockTime writes")
end

local function test(name, callback)
    local ok, failure = pcall(callback)
    if ok then table.insert(passed, name)
    else table.insert(failed, { name = name, error = tostring(failure) }) end
end

test("Default timeline keeps impact at 7.25 seconds and explosion at 2 seconds", function()
    local f = fixture()
    local timeline = f.controller:_buildTimeline(f:payload())
    near(timeline.start, 100); near(timeline.bannerStart, 101); near(timeline.warningStart, 103)
    near(timeline.fallStart, 105.75); near(timeline.impact, 107.25); near(timeline.finish, 109.25)
    near(timeline.sweepExpires, 116.25)
    equal(f.serverReads, 1, "one server clock conversion")
end)

test("Server delivery delay is converted once without using later server clock changes", function()
    local f = fixture()
    f.scheduler.now = 103
    local payload = f:payload(); payload.serverStartTime = 1000
    local timeline = f.controller:_buildTimeline(payload)
    near(timeline.start, 100); near(timeline.impact, 107.25)
    f.serverOffset = 9000
    near(timeline.impact, 107.25); equal(f.serverReads, 1)
end)

test("Legacy or unavailable server clocks preserve the local default schedule", function()
    local f = fixture()
    local payload = f:payload(); payload.serverStartTime = nil
    near(f.controller:_buildTimeline(payload).impact, 107.25)
    f.workspace.GetServerTimeNow = function() error("fixture unavailable clock") end
    payload.serverStartTime = 1000
    near(f.controller:_buildTimeline(payload).impact, 107.25)
    payload.serverStartTime = 0 / 0; payload.fallSeconds = math.huge; payload.warningFlashCount = -3
    local timeline = f.controller:_buildTimeline(payload)
    equal(timeline.count, 0); near(timeline.impact, 104.5)
end)

test("Missing GUI and bomb assets retain the impact time and create no runtime GUI", function()
    local f = fixture()
    f.controller:_playCinematic(f:payload())
    local session = f.controller._session
    f.scheduler:runUntil(107.20); equal(#f.sweeps, 0)
    f.scheduler:runUntil(107.30); equal(#f.sweeps, 1); near(f.sweeps[1].at, 107.25)
    equal(f.camera.CameraType, Enum.CameraType.Scriptable)
    for _, instance in ipairs(f.instances) do equal(instance:IsA("GuiObject"), false, "runtime GUI creation") end
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
    equal(f.controller._session, nil); equal(#f:liveEffects(), 0)
end)

test("Cancelling during prelude restores exact GUI state and prevents impact", function()
    local f = fixture(); local gui = addGui(f)
    f.controller:_playCinematic(f:payload())
    f:queueReward()
    local session = f.controller._session
    f.scheduler:runUntil(103.20); equal(gui.warning.Visible, true)
    f.controller:_cancelSession(); f.controller:_cancelSession(session)
    equal(gui.banner.Visible, false); equal(gui.warning.Visible, false)
    equal(gui.banner.ZIndex, 7); equal(gui.text.ZIndex, 8); equal(gui.text.TextTransparency, 0.2)
    equal(gui.warning.ImageTransparency, 0.3); equal(gui.warning.BackgroundTransparency, 0.65); equal(gui.stroke.Transparency, 0.4)
    f.scheduler:runAll(); equal(#f.sweeps, 0); assertDisposed(session); assertCameraRestored(f)
    equal(f.gate:IsBlocked(), false); equal(#f.popups, 1)
end)

test("Cancel during falling destroys bomb and restores camera idempotently", function()
    local f = fixture(); addBomb(f); addGui(f)
    f.controller:_playCinematic(f:payload())
    local session = f.controller._session
    f.scheduler:runUntil(106.25); equal(f.camera.CameraType, Enum.CameraType.Scriptable)
    assert(#session.resources > 0, "bomb resource was not registered")
    f.controller:_cancelSession(session); f.controller:_cancelSession(session)
    local cameraWrites = #f.camera._writes
    f.scheduler:runAll(); equal(#f.camera._writes, cameraWrites, "cancelled coroutine camera writes")
    equal(#f.sweeps, 0); assertDisposed(session); assertCameraRestored(f)
end)

test("Replacement session during fall owns camera and old completion cannot restore it", function()
    local f = fixture(); addGui(f); addBomb(f)
    local transitions = {}; f.gate:Subscribe(function(blocked) table.insert(transitions, blocked) end)
    f.controller:_playCinematic(f:payload(1)); local old = f.controller._session
    f:queueReward()
    f.scheduler:runUntil(106.40)
    f.controller:_playCinematic(f:payload(2)); local current = f.controller._session
    assertDisposed(old); assert(old ~= current)
    equal(f.gate:IsBlocked(), true); equal(#f.popups, 0); equal(#transitions, 1)
    f.scheduler:runUntil(current.timeline.fallStart + 0.3)
    equal(f.camera.CameraType, Enum.CameraType.Scriptable)
    local cframe = f.camera.CFrame
    f.controller:_cancelSession(old); equal(f.controller._session, current); equal(f.camera.CFrame, cframe)
    f.scheduler:runAll(); assertDisposed(current); equal(#f.sweeps, 1); equal(f.sweeps[1].sessionId, 2)
    assertCameraRestored(f)
    equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0); equal(#transitions, 2); equal(transitions[2], false)
end)

test("Camera replacement is left untouched by an old cinematic and cleanup", function()
    local f = fixture()
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(106.3)
    local camera = f.new("Camera"); camera.Parent = f.workspace; camera.FieldOfView = 82
    camera.CFrame = CFrame.new(200, 50, 300); camera.CameraSubject = f.humanoid
    f.workspace.CurrentCamera = camera; table.clear(camera._writes)
    f.scheduler:runAll(); assertDisposed(session)
    equal(#camera._writes, 0, "replacement camera writes"); equal(camera.CameraType, Enum.CameraType.Custom)
    equal(camera.FieldOfView, 82); equal(camera.CFrame, CFrame.new(200, 50, 300))
end)

test("Respawn while falling restores to the new living humanoid", function()
    local f = fixture()
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(106.3)
    f.humanoid.Health = 0; f.character.Parent = nil
    local character = f.new("Model"); character.Parent = f.workspace
    local humanoid = f.new("Humanoid"); humanoid.Parent = character; humanoid.Health = 100
    f.player.Character = character
    f.controller:_cancelSession(session); f.scheduler:runAll()
    equal(f.camera.CameraSubject, humanoid); assertCameraRestored(f); assertDisposed(session)
end)

test("Dead current humanoid is not reassigned as a restored camera subject", function()
    local f = fixture()
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(106.3); f.humanoid.Health = 0
    f.controller:_cancelSession(session)
    equal(f.camera.CameraSubject, nil); equal(f.camera.CameraType, Enum.CameraType.Custom)
end)

test("Camera return follows character movement without resetting the previous FOV", function()
    local f = fixture()
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(106.3)
    f.characterRoot.Position = Vector3.new(18, 0, -12)
    f.controller:_cancelSession(session)
    near((f.camera.CFrame.Position - (f.initialCamera.cframe.Position + Vector3.new(18, 0, -12))).Magnitude, 0, 0.001)
    equal(f.camera.FieldOfView, 70); equal(f.camera.CameraType, Enum.CameraType.Custom)
end)

test("VFX errors clean the session and restore GUI and camera", function()
    local f = fixture(); local gui = addGui(f); addBomb(f)
    local prepare = f.controller._prepareExplosionVfx
    f.controller._prepareExplosionVfx = function(self, session, center)
        f.failedSession = session
        prepare(self, session, center); self:_preparePostEffects(session)
        error("fixture explosion failure after allocation")
    end
    f.controller:_playCinematic(f:payload()); local session = f.failedSession
    f:queueReward()
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
    equal(f.controller._session, nil); equal(#f:liveEffects(), 0)
    equal(gui.warning.Visible, false); equal(gui.top.Visible, false); equal(gui.top.BackgroundTransparency, 0.7)
    equal(f.gate:IsBlocked(), false); equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0)
end)

test("Actual VFX has a bounded particle budget, beams and independent noninteractive wave", function()
    local f = fixture(); local original = addEffect(f, 80); local session = newSession(f)
    local vfx = f.controller:_createExplosionVfx(session, Vector3.new(12, 0, 20))
    equal(#vfx.ring, 32); equal(#vfx.beams, 24); equal(original.PrimaryPart.Size, Vector3.new(16, 10, 16))
    local budget = 0
    for _, burst in ipairs(vfx.bursts) do
        budget += burst.count
        local emitter = burst.emitter
        equal(emitter.Enabled, false)
        assert(emitter.Speed.Max <= 140.001, "particle speed limit")
        assert(emitter.Acceleration.Magnitude <= 100.001, "particle acceleration limit")
        assert(emitter.Lifetime.Max <= 2.4001)
        for _, keypoint in ipairs(emitter.Size.Keypoints) do assert(keypoint.Value + keypoint.Envelope <= 360.001) end
    end
    assert(budget > 0 and budget <= 960, "particle budget")
    for _, descendant in ipairs(vfx.root:GetDescendants()) do
        if descendant:IsA("BasePart") then
            equal(descendant.Anchored, true); equal(descendant.CanCollide, false); equal(descendant.CanTouch, false); equal(descendant.CanQuery, false)
        elseif descendant:IsA("Trail") then equal(descendant.Enabled, false) end
    end
    for _, beam in ipairs(vfx.beams) do assert(beam.Width0 <= 8 and beam.Width1 <= 8) end
    equal(vfx.beams[1].Name, "Beam1"); equal(vfx.beams[#vfx.beams].Name, "Beam70")
    for _, item in ipairs(vfx.lights) do assert(item.light.Range <= 100 and item.light.Brightness <= 5) end
    f.controller:_updateExplosionVfx(vfx, 1.2)
    near((vfx.ring[1].Position - vfx.groundCenter).Magnitude, vfx.radius, 0.001)
    f.controller:_cancelSession(session); assertDisposed(session)
end)

test("Live bursts are staged once and a delayed first render still emits the pending layers", function()
    local f = fixture(); addEffect(f, 4); local session = newSession(f)
    local vfx = f.controller:_createExplosionVfx(session, Vector3.zero)
    f.controller:_updateExplosionVfx(vfx, 0); equal(#f.emissions, 2, "core bursts")
    f.controller:_updateExplosionVfx(vfx, 0.10); equal(#f.emissions, 2)
    f.controller:_updateExplosionVfx(vfx, 0.24); equal(#f.emissions, 4, "smoke bursts")
    f.controller:_updateExplosionVfx(vfx, 0.25); equal(#f.emissions, 4, "duplicate bursts")
    f.controller:_cancelSession(session)
    local later = newSession(f); local lateVfx = f.controller:_createExplosionVfx(later, Vector3.zero)
    f.controller:_updateExplosionVfx(lateVfx, 1); equal(#f.emissions, 8, "live delayed emissions")
    f.controller:_updateExplosionVfx(lateVfx, 1.1); equal(#f.emissions, 8, "no duplicate delayed emissions")
    f.controller:_cancelSession(later)
end)

test("Cancellation at impact stops delayed smoke emissions and all following camera writes", function()
    local f = fixture(); addEffect(f, 4)
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(107.30); equal(#f.emissions, 2)
    f.controller:_cancelSession(session); local writes = #f.camera._writes
    f.scheduler:runAll(); equal(#f.emissions, 2); equal(#f.camera._writes, writes)
    assertDisposed(session); assertCameraRestored(f)
end)

test("Explosion finish returns the camera while Boom and smoke retain their finite tail", function()
    local f = fixture(); local original = addBoom(f); local gui = addGui(f)
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f:queueReward()
    f.scheduler:runUntil(109.30)
    equal(session.presentationFinished, true); equal(session.cleaned, nil); assertCameraRestored(f)
    equal(gui.top.Visible, false); equal(gui.flash.Visible, false); equal(gui.top.BackgroundTransparency, 0.7)
    equal(#f.soundPlays, 1); local boom = f.soundPlays[1].instance
    equal(boom.Name, "NukeBoom"); equal(boom.Destroyed, false); equal(boom.Playing, true)
    equal(original.Playing, false); equal(original.Destroyed, false); equal(original.Volume, 0.6)
    equal(f.gate:IsBlocked(), true, "tail retains popup barrier"); equal(#f.popups, 0)
    f.scheduler:runAll(); assertDisposed(session); equal(boom.Destroyed, true)
    near(f.scheduler.now, 111.37); equal(#f:liveEffects(), 0)
    equal(f.gate:IsBlocked(), false); equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0)
    near(f.popups[1].at, 111.37)
end)

test("Delivery after impact plays a complete fresh explosion and Boom from zero", function()
    local f = fixture(); addBoom(f); f.scheduler.now = 108
    local payload = f:payload(); payload.serverStartTime = 1000
    f.controller:_playCinematic(payload); local session = f.controller._session
    equal(#f.sweeps, 1); equal(f.camera.CameraType, Enum.CameraType.Scriptable)
    equal(#f.soundPlays, 1); equal(f.soundPlays[1].instance.TimePosition, 0)
    near(session.timeline.finish, 109.25)
    near(session.visualFinish, 110, 0.04, "full explosion after delivery")
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
end)

test("Expired delivery skips presentation but forwards one owner sweep token", function()
    local f = fixture(); f.scheduler.now = 110
    local payload = f:payload(); payload.serverStartTime = 1000
    local cameraWrites = #f.camera._writes
    f.controller:_playCinematic(payload); f.scheduler:runAll()
    equal(f.controller._session, nil); equal(#f.sweeps, 1); equal(#f:liveEffects(), 0)
    equal(#f.camera._writes, cameraWrites); assertCameraRestored(f)
end)

test("Expired sweep authorization is honored until its exact deadline and never afterwards", function()
    for _, item in ipairs({ { now = 116.24, sweeps = 1 }, { now = 116.25, sweeps = 0 }, { now = 130, sweeps = 0 } }) do
        local f = fixture(); f.scheduler.now = item.now
        local payload = f:payload(); payload.serverStartTime = 1000
        f.controller:_playCinematic(payload); f.scheduler:runAll()
        equal(#f.sweeps, item.sweeps, "authorization deadline"); equal(#f:liveEffects(), 0)
    end
end)

test("Spectators never forward another player's local sweep token", function()
    local f = fixture(); local payload = f:payload(); payload.ownerUserId = f.player.UserId + 1
    f.controller:_playCinematic(payload); f.scheduler:runAll()
    equal(#f.sweeps, 0); assertCameraRestored(f)
end)

test("A cinematic without CurrentCamera still cleans its VFX on schedule", function()
    local f = fixture(); f.workspace.CurrentCamera = nil
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runAll(); assertDisposed(session); equal(#f.sweeps, 1); equal(#f:liveEffects(), 0)
    equal(f:clockWrites(), 0)
end)

test("Queued replacement preserves old audio tail and old cleanup cannot restore new GUI or camera", function()
    local f = fixture(); local original = addBoom(f); original.TimeLength = 10
    local gui = addGui(f)
    f.controller:_playCinematic(f:payload(1)); local old = f.controller._session
    local transitions = {}; f.gate:Subscribe(function(blocked) table.insert(transitions, blocked) end)
    f:queueReward()
    f.scheduler:runUntil(109.35); equal(old.presentationFinished, true)
    equal(f.controller._session, nil); equal(f.controller._tails[old], true)
    local boom = f.soundPlays[1].instance
    f.controller:_playCinematic(f:payload(2)); local current = f.controller._session
    equal(old.cleaned, nil); equal(boom.Destroyed, false); equal(boom.Playing, true)
    equal(current.presentationFinished, false)
    -- A long authored clip overlaps the next ordinary timeline's fall and explosion.
    f.scheduler:runUntil(117.4)
    assertDisposed(old); equal(f.controller._tails[old], nil); equal(f.controller._session, current)
    equal(f.camera.CameraType, Enum.CameraType.Scriptable, "old tail did not restore camera")
    equal(gui.top.Visible, true, "old tail did not restore shared bars")
    equal(f.gate:IsBlocked(), true); equal(#f.popups, 0); equal(#transitions, 1)
    f.scheduler:runAll(); assertDisposed(current); equal(#f.sweeps, 2); assertCameraRestored(f)
    equal(f.gate:IsBlocked(), false); equal(#f.popups, 1); equal(transitions[2], false)
    equal(f.popups[1].liveEffects, 0)
end)

test("Zero extra burst preserves an enabled continuous layer while zero rate and count remain silent", function()
    local f = fixture(); local template = addEffect(f, 2)
    for _, instance in ipairs(template:GetDescendants()) do
        if instance:IsA("ParticleEmitter") then
            instance:SetAttribute("EmitCount", 0)
            if instance.Name == "Fire1" then instance.Rate = 30 else instance.Rate = 0 end
        end
    end
    local session = newSession(f); local vfx = f.controller:_createExplosionVfx(session, Vector3.zero)
    f.controller:_updateExplosionVfx(vfx, 0); f.controller:_updateExplosionVfx(vfx, 0.24)
    equal(#f.emissions, 1); equal(f.emissions[1].count, 9); f.controller:_cancelSession(session)
end)

test("Authored floor emitter and separate ground wave align to the arena surface", function()
    local f = fixture(); local template = addEffect(f, 2)
    local layer = f.new("Folder"); layer.Name = "FloorOn"; layer.Parent = template
    local floor = f.new("Part"); floor.Name = "Floor"; floor.CFrame = CFrame.new(0, -3, 0); floor.Parent = layer
    local battle = f.new("Part"); battle.Name = (f.config.ARENA or {}).BattlePartName or "Battle"
    battle.Size = Vector3.new(200, 6, 200); battle.Position = Vector3.new(0, 4, 0); battle.Parent = f.workspace
    local session = newSession(f); local vfx = f.controller:_createExplosionVfx(session, Vector3.new(15, -5, 20))
    near(vfx.root.FloorOn.Floor.Position.Y, 7.8, 0.001); near(vfx.groundCenter.Y, 7.8, 0.001)
    f.controller:_cancelSession(session)
end)

test("Reinitializing the isolated controller cancels its session and connects only fake remotes", function()
    local f = fixture(); addBomb(f)
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    f.scheduler:runUntil(106.3)
    local root = f.new("Folder"); root.Name = f.remoteNames.RootFolder; root.Parent = f.replicated
    local battle = f.new("Folder"); battle.Name = f.remoteNames.BattleEventsFolder; battle.Parent = root
    local remote = f.new("RemoteEvent"); remote.Name = f.remoteNames.Battle.NukeCinematic; remote.Parent = battle
    remote.OnClientEvent = signal(f.scheduler); remote.FireServer = forbidden
    f.controller:Init({ LocalPlayer = f.player })
    equal(#f.controller._connections, 1); equal(f.controller._session, nil)
    f.scheduler:runAll(); assertDisposed(session); equal(#f.sweeps, 0); assertCameraRestored(f)
end)

test("Isolated Init clears background audio tails as well as an active prelude", function()
    local f = fixture(); addBoom(f)
    f.controller:_playCinematic(f:payload(1)); local tail = f.controller._session
    f:queueReward()
    f.scheduler:runUntil(109.35); equal(f.controller._tails[tail], true)
    f.controller:_playCinematic(f:payload(2)); local active = f.controller._session
    local root = f.new("Folder"); root.Name = f.remoteNames.RootFolder; root.Parent = f.replicated
    local battle = f.new("Folder"); battle.Name = f.remoteNames.BattleEventsFolder; battle.Parent = root
    local remote = f.new("RemoteEvent"); remote.Name = f.remoteNames.Battle.NukeCinematic; remote.Parent = battle
    remote.OnClientEvent = signal(f.scheduler); remote.FireServer = forbidden
    f.controller:Init({ LocalPlayer = f.player }); f.scheduler:runAll()
    assertDisposed(tail); assertDisposed(active); equal(next(f.controller._tails), nil); equal(f.controller._session, nil)
    equal(#f:liveEffects(), 0); assertCameraRestored(f)
    equal(f.gate:IsBlocked(), false); equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0)
end)

test("Sparse enabled emitters retain a minimum visible burst even when extra EmitCount is zero", function()
    local f = fixture(); local template = addEffect(f, 3)
    for _, instance in ipairs(template:GetDescendants()) do
        if instance:IsA("ParticleEmitter") then
            instance.Enabled = true; instance.Rate = 1; instance:SetAttribute("EmitCount", 0)
        end
    end
    local session = newSession(f); local vfx = f.controller:_createExplosionVfx(session, Vector3.zero)
    f.controller:_updateExplosionVfx(vfx, 0.24)
    local visibleCount = 0
    for _, emission in ipairs(f.emissions) do visibleCount += emission.count end
    equal(#f.emissions, 3); equal(visibleCount, 12, "minimum authored layer burst")
    f.controller:_cancelSession(session)
end)

test("Early setup CPU cost stays before impact and retains a complete two-second explosion", function()
    local f = fixture(); addEffect(f, 4); addBoom(f)
    local prepare = f.controller._prepareExplosionVfx
    f.controller._prepareExplosionVfx = function(self, session, center)
        local vfx = prepare(self, session, center); f.vfx = vfx; return vfx
    end
    f.onClone = function(instance)
        if instance.Name == "Bomb" then f:spend(1.1) end
    end
    f.controller:_playCinematic(f:payload()); local session = f.controller._session; f:queueReward()
    assert(f.vfx, "prepared explosion missing")
    equal(f.vfx.startedAt, nil); equal(#f.emissions, 0); near(f.scheduler.now, 101.1)
    f.scheduler:runUntil(107.30)
    near(f.vfx.startedAt, 107.25); near(session.visualFinish, f.vfx.startedAt + 2)
    equal(#f.emissions, 2); equal(#f.soundPlays, 1); equal(f.soundPlays[1].instance.TimePosition, 0)
    f.scheduler:runUntil(f.vfx.startedAt + 0.25); equal(#f.emissions, 4)
    f.scheduler:runUntil(109.10); equal(session.presentationFinished, false)
    equal(f.camera.CameraType, Enum.CameraType.Scriptable); equal(f.gate:IsBlocked(), true); equal(#f.popups, 0)
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
    equal(#f.popups, 1); near(f.popups[1].at, f.vfx.startedAt + 4.12); equal(f.popups[1].liveEffects, 0)
end)

test("Slow local sweep still gives the prepared explosion its complete duration and tail barrier", function()
    local f = fixture(); addEffect(f, 4); addBoom(f)
    f.onSweep = function() f:spend(0.75) end
    f.controller:_playCinematic(f:payload()); local session = f.controller._session; f:queueReward()
    f.scheduler:runUntil(107.30)
    near(session.visualFinish, 110); equal(#f.emissions, 2); equal(#f.soundPlays, 1)
    f.scheduler:runUntil(108.3); equal(#f.emissions, 4)
    f.scheduler:runUntil(109.3); equal(session.presentationFinished, false); equal(#f.popups, 0)
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
    equal(#f.popups, 1); near(f.popups[1].at, 112.12); equal(f.popups[1].liveEffects, 0)
end)

test("A failing local sweep cannot abort the explosion or leave a reward permanently gated", function()
    local f = fixture(); addEffect(f, 4); addBoom(f)
    f.onSweep = function() error("fixture local sweep failure") end
    f.controller:_playCinematic(f:payload()); local session = f.controller._session; f:queueReward()
    f.scheduler:runUntil(107.3); equal(#f.emissions, 2); equal(#f.soundPlays, 1)
    equal(f.camera.CameraType, Enum.CameraType.Scriptable); equal(f.gate:IsBlocked(), true)
    f.scheduler:runAll(); equal(#f.emissions, 4); assertDisposed(session); assertCameraRestored(f)
    equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0); equal(f.gate:IsBlocked(), false)
end)

test("A replaced session resuming from a yielding sweep cannot allocate orphan effects or release the new gate", function()
    local f = fixture(); addEffect(f, 4); addBoom(f)
    f.onSweep = function(sessionId)
        if sessionId == 1 then f.scheduler.task.wait(1) end
    end
    f.controller:_playCinematic(f:payload(1)); local old = f.controller._session; f:queueReward()
    f.scheduler:runUntil(107.3); equal(#f.sweeps, 1); equal(#f.emissions, 0)
    f.controller:_playCinematic(f:payload(2)); local current = f.controller._session
    assertDisposed(old)
    f.scheduler:runUntil(108.3)
    equal(#f.emissions, 0); equal(#f.soundPlays, 0); equal(#f:liveEffects(), 0)
    equal(f.controller._session, current); equal(f.gate:IsBlocked(), true); equal(#f.popups, 0)
    f.scheduler:runAll(); assertDisposed(current); assertCameraRestored(f)
    equal(#f.soundPlays, 1); equal(#f.popups, 1); equal(f.popups[1].liveEffects, 0)
end)

test("Cinematic preparation is detached and silent until impact and activation allocates nothing", function()
    local f = fixture(); addEffect(f, 4); addBoom(f); addBomb(f)
    local prepare = f.controller._prepareExplosionVfx
    f.controller._prepareExplosionVfx = function(self, session, center)
        local vfx = prepare(self, session, center); f.vfx = vfx; return vfx
    end
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    equal(f.vfx.startedAt, nil); equal(f.vfx.root.Parent, nil); equal(f.vfx.ringRoot.Parent, nil)
    equal(#f.emissions, 0); equal(#f.soundPlays, 0); equal(session.sound.Playing, false)
    for _, effect in ipairs(session.postEffects) do equal(effect.Parent, nil); equal(effect.Enabled, false) end
    f.scheduler:runUntil(session.timeline.impact - 0.04)
    equal(f.vfx.root.Parent, nil); equal(f.vfx.ringRoot.Parent, nil); equal(#f.emissions, 0)
    f.scheduler:runUntil(session.timeline.impact + 0.04)
    equal(f.vfx.root.Parent, f.workspace); equal(f.vfx.ringRoot.Parent, f.workspace)
    equal(#f.emissions, 2); equal(#f.soundPlays, 1); near(f.vfx.startedAt, session.timeline.impact)
    for _, clone in ipairs(f.clones) do assert(clone.at < session.timeline.impact, "impact cloned " .. clone.name) end
    for _, instance in ipairs(f.instances) do assert(instance._createdAt < session.timeline.impact, "impact allocated " .. instance.ClassName) end
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f)
end)

test("Cancelling before activation destroys every detached prepared resource without touching templates", function()
    local f = fixture(); local template = addEffect(f, 4); local boom = addBoom(f)
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    assert(#session.resources >= 5, "prepared owned resources missing")
    f.controller:_cancelSession(session); f.scheduler:runAll()
    assertDisposed(session); equal(#f.emissions, 0); equal(#f.soundPlays, 0); equal(#f:liveEffects(), 0)
    equal(template.Destroyed, false); equal(boom.Destroyed, false); equal(f.gate:IsBlocked(), false)
end)

test("A permanently yielding preload never delays impact or blocks cinematic cleanup", function()
    local f = fixture(); addEffect(f, 4); addBoom(f); addBomb(f)
    f.onPreload = function()
        f.heldPreload = coroutine.running(); coroutine.yield("fixture-held-preload")
    end
    f.controller:_playCinematic(f:payload()); local session = f.controller._session
    equal(#f.preloads, 1); assert(f.heldPreload)
    f.scheduler:runUntil(107.30); equal(#f.emissions, 2); equal(#f.soundPlays, 1); near(f.sweeps[1].at, 107.25)
    f.scheduler:runAll(); assertDisposed(session); assertCameraRestored(f); equal(f.gate:IsBlocked(), false)
    f.scheduler:resume(f.heldPreload); equal(#f:liveEffects(), 0)
end)

test("A preload failure remains optional and a later cinematic may retry it", function()
    local f = fixture(); addEffect(f, 4); addBoom(f)
    f.onPreload = function() if #f.preloads == 1 then error("fixture preload failure") end end
    f.controller:_playCinematic(f:payload(1)); local first = f.controller._session
    f.scheduler:runAll(); assertDisposed(first); equal(#f.soundPlays, 1)
    f.controller:_playCinematic(f:payload(2)); local second = f.controller._session
    f.scheduler:runAll(); assertDisposed(second); equal(#f.preloads, 2); equal(#f.soundPlays, 2)
    assertCameraRestored(f)
end)

test("Explosion activation is idempotent and preserves its original visible clock", function()
    local f = fixture(); addEffect(f, 4); local session = newSession(f)
    local vfx = f.controller:_prepareExplosionVfx(session, Vector3.zero)
    equal(vfx.startedAt, nil); equal(#f.emissions, 0)
    f.controller:_activateExplosionVfx(vfx); equal(#f.emissions, 2); equal(vfx.startedAt, 100)
    f.scheduler.now = 101; f.controller:_activateExplosionVfx(vfx)
    equal(#f.emissions, 2); equal(vfx.startedAt, 100)
    f.controller:_cancelSession(session); assertDisposed(session)
end)

test("Finished bursts wave beams and lights stop repeating per-frame property writes", function()
    local f = fixture(); addEffect(f, 4); local session = newSession(f)
    local vfx = f.controller:_createExplosionVfx(session, Vector3.zero)
    f.controller:_updateExplosionVfx(vfx, 1.2)
    local writes = {}
    for _, part in ipairs(vfx.ring) do writes[part] = #part._writes end
    for _, beam in ipairs(vfx.beams) do writes[beam] = #beam._writes end
    for _, item in ipairs(vfx.lights) do writes[item.light] = #item.light._writes end
    local emissions = #f.emissions
    for _, elapsed in ipairs({ 1.6, 2.8, 5 }) do f.controller:_updateExplosionVfx(vfx, elapsed) end
    for instance, previous in pairs(writes) do equal(#instance._writes, previous, "finished VFX writes") end
    equal(#f.emissions, emissions); f.controller:_cancelSession(session)
end)

return HttpService:JSONEncode({ passed = passed, failed = failed, warnings = warnings })
