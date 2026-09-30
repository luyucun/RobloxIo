-- Run with Studio MCP execute_luau in EDIT mode. Isolated source, fake clock,
-- detached visual instances and silent audio doubles; no Init, Playtest or rewards.
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Edit mode only")
local sourceOverrides = nil -- The local-source runner replaces this declaration.
local controllers = game.StarterPlayer.StarterPlayerScripts.Controllers
local now = 100
local deferred = {}
local passed = {}
local detached = Instance.new("Folder")
local created = {}
local fakeWorkspace = detached
local function isolated(name, services)
    local instance = controllers[name]
    local chunk, err = loadstring(sourceOverrides and sourceOverrides[name] or instance.Source, "=" .. name)
    assert(chunk, err)
    local fakeGame = {}
    function fakeGame:GetService(serviceName)
        if services and services[serviceName] then return services[serviceName] end
        if serviceName == "Workspace" then return fakeWorkspace end
        if serviceName == "TweenService" then return { Create = function() return { Play = function() end } end } end
        return game:GetService(serviceName)
    end
    setfenv(chunk, setmetatable({
        game = fakeGame,
        script = instance,
        Instance = { new = function(className)
            local item = Instance.new(className)
            table.insert(created, item)
            return item
        end },
        os = setmetatable({ clock = function() return now end }, { __index = os }),
        task = { delay = function(_, callback) table.insert(deferred, callback) end },
    }, { __index = getfenv() }))
    return chunk()
end
local function check(name, callback)
    now += 10
    table.clear(deferred)
    callback()
    table.insert(passed, name)
end
local function flushDeferred()
    local callbacks = table.clone(deferred)
    table.clear(deferred)
    for _, callback in ipairs(callbacks) do callback() end
end
local function monsterFixture()
    return { Id = 1, Alive = true, SpawnToken = "fixture", Position = Vector3.zero, CurrentHealth = 0 }
end
local ok, failure = xpcall(function()
    check("Instant kill shows lethal damage before recycling, duplicate kill/callback stays silent", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        local shown = {}
        c._showDamageNumber = function(_, _, amount, _, _, lethal) table.insert(shown, {amount, lethal}) end
        c._queueSafeZoneRespawnIfNeeded = function() end
        c._playMonsterImpact = function() end
        c._playMonsterFeedbackSound = function() end
        c._localMonsterKilledEvent = {}
        c._destroyMonster = function(_, state)
            assert(#shown == 1 and state.DamageBucket == nil, "Killed before lethal damage was shown")
        end
        c:_playHitFeedback(m, 35)
        c:_reportMonsterKilled(m)
        c:_reportMonsterKilled(m)
        flushDeferred()
        assert(#shown == 1 and shown[1][1] == 35 and shown[1][2] == true)
        assert(c._nextKillRequestId == 2 and c._pendingKillsByRequestId["1"].Token == "fixture")
    end)
    check("Nonlethal merge and final hit preserve total damage without double display", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        local values = {}
        c._showDamageNumber = function(_, _, amount, _, _, lethal) table.insert(values, {amount, lethal}) end
        c:_queueDamageNumber(m, 10)
        c:_queueDamageNumber(m, 20)
        flushDeferred()
        c:_queueDamageNumber(m, 5)
        c:_queueDamageNumber(m, 8)
        c:_flushDamageNumber(m, true)
        flushDeferred()
        assert(#values == 2 and values[1][1] == 30 and not values[1][2])
        assert(values[2][1] == 13 and values[2][2])
    end)
    check("Leaving arena cancels pending damage and clears visuals", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        c._monstersById[1] = m
        c._setMonsterActivityState = function() end
        c._showDamageNumber = function() error("Late damage after leaving arena") end
        c:_queueDamageNumber(m, 20)
        c:_playMonsterImpact(m, true)
        c:_sleepAllLocalMonsters()
        flushDeferred()
        assert(#c._activeImpacts == 0 and #c._impactPool == 0 and c._impactCreated == 0)
    end)
    check("Hit burst reserves four death slots; pool caps at twelve and reuses instances", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        for _ = 1, 100 do c:_playMonsterImpact(m, false) end
        assert(#c._activeImpacts == 8)
        for _ = 1, 100 do c:_playMonsterImpact(m, true) end
        assert(#c._activeImpacts == 12 and c._impactCreated == 12)
        for _, visual in ipairs(c._activeImpacts) do
            assert(not visual.Part.CanCollide and not visual.Part.CanTouch and not visual.Part.CanQuery)
        end
        now += 0.31
        c:_stepMonsterImpacts()
        assert(#c._activeImpacts == 0 and #c._impactPool == 12)
        c:_playMonsterImpact(m, true)
        assert(c._impactCreated == 12 and #c._impactPool == 11)
        c:_clearMonsterImpacts()
    end)
    check("Sustained mass kills respect per-second FX budget and recover next window", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        for _ = 1, 3 do
            for _ = 1, 100 do c:_playMonsterImpact(m, true) end
            now += 0.31
            c:_stepMonsterImpacts()
        end
        assert(c._impactWindowCount == 24 and c._impactCreated == 12)
        now += 0.1
        c:_playMonsterImpact(m, true)
        assert(c._impactWindowCount == 1)
        c:_clearMonsterImpacts()
    end)
    check("Damage anchors outlive camera changes and return to a reusable pool", function()
        local c = isolated("LocalMonsterController")
        local m = monsterFixture()
        c:_showDamageNumber(m, 35, Vector3.zero, 5, true)
        local visual = next(c._activeDamageNumberVisuals)
        assert(visual and visual.Anchor.Parent == detached and visual.Label.Text == "35")
        flushDeferred()
        assert(#c._damageNumberPool == 1 and visual.Anchor.Parent == nil)
        c:_showDamageNumber(m, 10, Vector3.zero, 5, false)
        assert(c._activeDamageNumberVisuals[visual] and visual.Label.Text == "10")
        c:_clearDamageNumberVisuals()
        flushDeferred()
        assert(c._damageNumberPoolCreated == 0 and #c._damageNumberPool == 0)
    end)
    check("Every positive monster hit including lethal uses the chosen sound once", function()
        local c = isolated("LocalMonsterController")
        local count = 0
        local chosen = game:GetService("SoundService"):FindFirstChild("SFX_Hit_Sword_Medium_01")
        assert(chosen and chosen:IsA("Sound"))
        c._audioSettings = { PlaySfxOneShot = function(_, sound)
            assert(sound == chosen)
            count += 1
        end }
        c._playMonsterImpact = function() end
        local m = monsterFixture()
        for _, health in ipairs({80, 60, 0}) do
            m.CurrentHealth = health
            c:_playHitFeedback(m, 20)
        end
        c:_playHitFeedback(m, 0)
        assert(count == 3, "Valid hits were throttled or zero damage played audio")
    end)
    check("Body hits use chosen sound; sword clash and local-source filter remain unchanged", function()
        local c = isolated("ClientEventController")
        c._localPlayer = {UserId=17}
        local bodies, clashes = 0, 0
        c._audioSettings = {PlaySfxOneShot=function(_, sound)
            assert(sound == game:GetService("SoundService").SFX_Hit_Sword_Medium_01)
            bodies += 1
        end}
        c._playSfxByPath = function(_, folder, path)
            assert(folder == "Audio" and path[1] == "Sword" and path[2] == "Sword Hit")
            clashes += 1
        end
        for _ = 1, 3 do c:_playCombatFeedbackSound({sourceUserId=17,eventType="WeaponHitPlayer"}) end
        c:_playCombatFeedbackSound({sourceUserId=17,eventType="WeaponHitWeapon"})
        c:_playCombatFeedbackSound({sourceUserId=22,eventType="WeaponHitPlayer"})
        c:_playCombatFeedbackSound({sourceUserId=17,eventType="PlayerKilled"})
        assert(bodies == 3 and clashes == 1)
    end)
    local function woundedFixture()
        local c = isolated("LocalMonsterController")
        local model = Instance.new("Model")
        model.Parent = detached
        local root = Instance.new("Part")
        root.Size = Vector3.new(3, 6, 3)
        root.Parent = model
        model.PrimaryPart = root
        local m = monsterFixture()
        m.Instance = model
        m.ActivityState = "CombatActive"
        m.MaxHealth = 100
        return c, m
    end
    check("Full health and one-hit kills never create a health bar", function()
        local c, m = woundedFixture()
        m.CurrentHealth = 100
        c:_updateMonsterHealthBar(m)
        assert(not m.HealthBar)
        m.CurrentHealth = 0
        c:_updateMonsterHealthBar(m)
        assert(not m.HealthBar and not m.Instance:FindFirstChildWhichIsA("BillboardGui", true))
    end)
    check("Wounded monsters have a text-free slim world-sized bar with proportional fill", function()
        local c, m = woundedFixture()
        m.CurrentHealth = 63
        c:_updateMonsterHealthBar(m)
        local bar = m.HealthBar
        assert(bar and bar.Enabled and not bar:FindFirstChildWhichIsA("TextLabel", true))
        assert(bar.Size.X.Scale > 0 and bar.Size.Y.Scale > 0 and bar.Size.X.Offset == 0 and bar.Size.Y.Offset == 0)
        assert(bar.Size.X.Scale / bar.Size.Y.Scale >= 12)
        assert(math.abs(bar.Track.Fill.Size.X.Scale - 0.63) < 0.001)
        assert(bar.Adornee == m.Instance.PrimaryPart and bar.StudsOffsetWorldSpace.Y > 3)
        m.CurrentHealth = 0.1
        c:_updateMonsterHealthBar(m)
        assert(m.HealthBar == bar and math.abs(bar.Track.Fill.Size.X.Scale - 0.001) < 0.0001)
        m.CurrentHealth = 99.9
        c:_updateMonsterHealthBar(m)
        assert(math.abs(bar.Track.Fill.Size.X.Scale - 0.999) < 0.0001)
        m.CurrentHealth = 0
        c:_updateMonsterHealthBar(m)
        assert(not m.HealthBar and bar.Parent == nil)
    end)
    check("Health bars clear on dormancy and model recycling; wounded reactivation restores them", function()
        local c, m = woundedFixture()
        m.CurrentHealth = 40
        c._setMonsterAnimationsEnabled = function() end
        c:_updateMonsterHealthBar(m)
        local previous = m.HealthBar
        c:_setMonsterActivityState(m, "Dormant")
        assert(not m.HealthBar and previous.Parent == nil)
        c:_setMonsterActivityState(m, "CombatActive")
        assert(m.HealthBar and math.abs(m.HealthBar.Track.Fill.Size.X.Scale - 0.4) < 0.001)
        local model = m.Instance
        assert(c:_poolMonsterInstance(m))
        assert(not m.HealthBar and not model:FindFirstChildWhichIsA("BillboardGui", true))
        c:_clearMonsterModelPool()
    end)
    local function experienceFixture()
        local c = isolated("ClientEventController")
        local character = Instance.new("Model")
        character.Parent = detached
        local root = Instance.new("Part")
        root.Name = "HumanoidRootPart"
        root.Parent = character
        c._localPlayer = { Character = character }
        c._localOrbFolder = detached
        c._latestPlayerState = { alive = true, isInArena = true }
        return c, root
    end
    check("Only consumed XP balls trigger collection; simultaneous balls yield one signal", function()
        local c, root = experienceFixture()
        local soundCount = 0
        c._audioSettings = { PlaySfxOneShotByPath = function() soundCount += 1 end }
        c:_spawnExperienceDrop({dropId="test", orbs={
            {position=root.Position, value=10}, {position=root.Position, value=10},
        }})
        assert(soundCount == 0 and #c._localOrbs == 2)
        for _, orb in ipairs(c._localOrbs) do
            orb.FallEndClock = now - 1
            orb.HomingStartClock = now - 1
            orb.Instance.Position = root.Position
        end
        c:_updateLocalExperienceOrbs(0.016)
        assert(soundCount == 1 and #c._localOrbs == 0 and c._collectPulse ~= nil)
        local pulse = c._collectPulse
        now += 0.21
        c:_stepExperienceCollectPulse(root, now)
        assert(pulse.Parent == nil)
        c:_playExperienceCollectFeedback(root, now)
        assert(c._collectPulse == pulse and soundCount == 2)
        c:_clearExperienceVisuals(true)
    end)
    check("Expired XP balls do not play collection or award anything", function()
        local c, root = experienceFixture()
        c._playExperienceCollectFeedback = function() error("Expired orb was collected") end
        c:_spawnExperienceDrop({orbs={{position=root.Position, value=10}}})
        c._localOrbs[1].ExpireClock = now - 1
        c:_updateLocalExperienceOrbs(0.016)
        assert(#c._localOrbs == 0)
    end)
    check("Death clears old XP; late drops are ignored; lobby level-up stays valid", function()
        local c, root = experienceFixture()
        c:_spawnExperienceDrop({orbs={{position=root.Position, value=10}}})
        c:_playExperienceCollectFeedback(root, now)
        c._latestPlayerState = { alive = false, isInArena = false }
        c:_clearExperienceVisuals(true)
        c:_spawnExperienceDrop({orbs={{position=root.Position, value=10}}})
        assert(#c._localOrbs == 0 and c._collectPulse == nil)
        local effect = Instance.new("Part")
        effect.Parent = detached
        c._activeLevelUpEffect = effect
        c._latestPlayerState = { alive = true, isInArena = false }
        c:_updateLocalExperienceOrbs(0.016)
        assert(effect.Parent == detached, "Legitimate lobby level-up got erased")
        c:_clearExperienceVisuals(true)
        assert(c._activeLevelUpEffect == nil)
    end)
    check("Rapid multi-level rewards play one upgrade cue; subsequent rewards play again", function()
        local c = isolated("ClientEventController")
        local count = 0
        c._spawnLevelUpEffect = function() count += 1 end
        c._playSound = function() end
        for _ = 1, 100 do c:_playLevelUpFeedback() end
        assert(count == 1)
        now += 0.36
        c:_playLevelUpFeedback()
        assert(count == 2)
    end)
    check("SFX presentation adjusts clones only, keeps legacy calls and mute working", function()
        local clones = {}
        local runtime = {}
        local template = { Name="Test", Volume=0.5, PlaybackSpeed=1, IsA=function(_, class) return class=="Sound" end }
        template.Clone = function()
            local clone = {Volume=0.5, PlaybackSpeed=1, TimeLength=1, Play=function(self) self.Played=true end,
                Destroy=function(self) self.Parent=nil end}
            table.insert(clones, clone)
            return clone
        end
        local audio = {FindFirstChild=function() return template end}
        local soundService = {FindFirstChild=function(_, name) return name=="__RuntimeSfx" and runtime or audio end}
        local c = isolated("AudioSettingsController", { SoundService=soundService })
        c._sfxEnabled = true
        assert(c:PlaySfxOneShotByPath("Audio", {"Test"}, {volumeScale=0.3, playbackSpeed=1.15}))
        assert(clones[1].Volume == 0.15 and clones[1].PlaybackSpeed == 1.15 and clones[1].Played)
        assert(template.Volume == 0.5 and template.PlaybackSpeed == 1)
        assert(c:PlaySfxOneShotByPath("Audio", {"Test"}))
        assert(clones[2].Volume == 0.5 and clones[2].PlaybackSpeed == 1)
        assert(c:PlaySfxOneShot(template) and c:PlaySfxOneShot(template))
        assert(#clones == 4 and clones[3] ~= clones[4] and clones[3].Played and clones[4].Played)
        assert(not c:PlaySfxOneShot(nil))
        c._sfxEnabled = false
        assert(not c:PlaySfxOneShotByPath("Audio", {"Test"}) and not c:PlaySfxOneShot(template) and #clones == 4)
        flushDeferred()
        assert(clones[1].Parent == nil and clones[2].Parent == nil)
    end)
end, debug.traceback)
for _, instance in ipairs(created) do instance:Destroy() end
detached:Destroy()
assert(ok, failure)
return game:GetService("HttpService"):JSONEncode({passed=#passed, checks=passed, mode="isolated edit; no gameplay simulation"})
