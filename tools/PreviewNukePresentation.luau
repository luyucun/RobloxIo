-- Edit-only visual sample. No Init, Remote, purchase, monster sweep or Playtest.
-- Call _G.CodexNukePreviewV618.cleanup() to restore immediately; auto-restores in 30s.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong place")
assert(not _G.CodexNukePreviewV618, "A preview is already active")

local Workspace = game:GetService("Workspace")
local Selection = game:GetService("Selection")
local savedSelection = Selection:Get()
local camera = Workspace.CurrentCamera
assert(camera, "Missing edit camera")
local saved = {
    cframe = camera.CFrame, focus = camera.Focus, fov = camera.FieldOfView,
    cameraType = camera.CameraType, subject = camera.CameraSubject,
}
local module = game.StarterPlayer.StarterPlayerScripts.Controllers.NukeCinematicController
local constructor = assert(loadstring(module.Source))
setfenv(constructor, setmetatable({script = module}, {__index = getfenv()}))
local controller = constructor()
local session = {resources = {}, tracks = {}, guis = {}, presentationFinished = true}
local preview = {session = session, emitters = {}}
local cleaned = false
function preview.cleanup()
    if cleaned then
        return
    end
    cleaned = true
    controller:_cancelSession(session)
    if camera.Parent and Workspace.CurrentCamera == camera then
        camera.CFrame = saved.cframe
        camera.Focus = saved.focus
        camera.FieldOfView = saved.fov
        camera.CameraSubject = saved.subject
        camera.CameraType = saved.cameraType
    end
    if _G.CodexNukePreviewV618 == preview then
        _G.CodexNukePreviewV618 = nil
    end
    local remaining = {}
    for _, instance in ipairs(savedSelection) do
        if instance.Parent then
            table.insert(remaining, instance)
        end
    end
    Selection:Set(remaining)
end
_G.CodexNukePreviewV618 = preview
task.delay(30, preview.cleanup)

local ok, message = xpcall(function()
    local point = Workspace.Battle01.BombPoint.Position
    local vfx = controller:_createExplosionVfx(session, point)
    preview.vfx = vfx
    Selection:Set({Workspace.Battle01.Battle})
    local distance = math.clamp(vfx.radius * 0.48, 150, 300)
    local direction = Vector3.new(0.38, 0, 1).Unit
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = CFrame.lookAt(point + direction * distance + Vector3.new(0, distance * 0.52, 0), point + Vector3.new(0, 25, 0))
    camera.Focus = CFrame.new(point)
    camera.FieldOfView = 73
    if vfx.root then
        for _, descendant in ipairs(vfx.root:GetDescendants()) do
            if descendant:IsA("ParticleEmitter") then
                table.insert(preview.emitters, descendant)
            end
        end
    end
    local started = os.clock()
    while os.clock() - started < 0.38 do
        controller:_updateExplosionVfx(vfx, os.clock() - started)
        task.wait(0.025)
    end
    controller:_updateExplosionVfx(vfx, 0.38)
    for _, emitter in ipairs(preview.emitters) do
        emitter.TimeScale = 0
    end
    function preview.advance(seconds)
        for _, emitter in ipairs(preview.emitters) do
            emitter.TimeScale = 1
        end
        task.wait(seconds)
        preview.elapsed = (preview.elapsed or 0.38) + seconds
        controller:_updateExplosionVfx(vfx, preview.elapsed)
        for _, emitter in ipairs(preview.emitters) do
            emitter.TimeScale = 0
        end
    end
end, debug.traceback)
if not ok then
    preview.cleanup()
    error(message)
end
return game:GetService("HttpService"):JSONEncode({preview = true, particleEmitters = #preview.emitters, autoCleanupSeconds = 30})
