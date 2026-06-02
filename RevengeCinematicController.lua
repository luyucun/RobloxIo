--[[
Script name: RevengeCinematicController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/RevengeCinematicController
Purpose: Locks the buyer camera onto the revenge target during the paid revenge beat.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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
        "[RevengeCinematicController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local RevengeCinematicController = {}

RevengeCinematicController._localPlayer = nil
RevengeCinematicController._connections = {}
RevengeCinematicController._activeSessionId = 0
RevengeCinematicController._cameraState = nil

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getCharacterHumanoid(player)
    local character = player and player.Character
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getRootPart(character)
    if not character then
        return nil
    end
    return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart or character:FindFirstChildWhichIsA("BasePart", true)
end

function RevengeCinematicController:_captureCameraState()
    local camera = Workspace.CurrentCamera
    if not camera then
        return nil
    end

    return {
        camera = camera,
        cameraType = camera.CameraType,
        cameraSubject = camera.CameraSubject,
        cframe = camera.CFrame,
        focus = camera.Focus,
        fieldOfView = camera.FieldOfView,
    }
end

function RevengeCinematicController:_restoreCamera()
    local state = self._cameraState
    local camera = (state and state.camera) or Workspace.CurrentCamera
    if not camera then
        return
    end

    camera.CameraType = state and state.cameraType or Enum.CameraType.Custom
    camera.CameraSubject = (state and state.cameraSubject) or getCharacterHumanoid(self._localPlayer)
    if state and state.cframe then
        camera.CFrame = state.cframe
    end
    if state and state.focus then
        camera.Focus = state.focus
    end
    if state and state.fieldOfView then
        camera.FieldOfView = state.fieldOfView
    end
    self._cameraState = nil
end

function RevengeCinematicController:_resolveTargetCharacter(payload)
    local targetCharacter = payload and payload.targetCharacter
    if targetCharacter and targetCharacter:IsA("Model") then
        return targetCharacter
    end

    local targetUserId = tonumber(payload and payload.targetUserId)
    local targetPlayer = targetUserId and Players:GetPlayerByUserId(targetUserId) or nil
    return targetPlayer and targetPlayer.Character or nil
end

function RevengeCinematicController:_updateCamera(camera, targetRoot)
    local targetPosition = targetRoot.Position
    local lookPosition = targetPosition + Vector3.new(0, 2.5, 0)
    local lookVector = targetRoot.CFrame.LookVector
    local sideVector = targetRoot.CFrame.RightVector
    local cameraPosition = targetPosition - (lookVector * 13) + (sideVector * 3) + Vector3.new(0, 7, 0)
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = CFrame.lookAt(cameraPosition, lookPosition)
    camera.Focus = CFrame.new(lookPosition)
end

function RevengeCinematicController:_playCinematic(payload)
    if type(payload) ~= "table" then
        return
    end
    if not (self._localPlayer and tonumber(payload.ownerUserId) == self._localPlayer.UserId) then
        return
    end

    local sessionId = tonumber(payload.sessionId) or (self._activeSessionId + 1)
    self._activeSessionId = sessionId

    task.spawn(function()
        self._cameraState = self:_captureCameraState()
        local camera = Workspace.CurrentCamera
        if not camera then
            return
        end

        local targetCharacter = self:_resolveTargetCharacter(payload)
        local duration = math.max(
            0.2,
            tonumber(payload.lockSeconds) or 1,
            (tonumber(payload.lockSeconds) or 1) + (tonumber(payload.effectSeconds) or 0.5) + 0.15
        )
        local endClock = os.clock() + duration

        while os.clock() < endClock do
            if sessionId ~= self._activeSessionId then
                break
            end
            if not (targetCharacter and targetCharacter.Parent) then
                targetCharacter = self:_resolveTargetCharacter(payload)
            end
            local targetRoot = getRootPart(targetCharacter)
            if targetRoot then
                self:_updateCamera(camera, targetRoot)
            end
            RunService.RenderStepped:Wait()
        end

        if sessionId == self._activeSessionId then
            self:_restoreCamera()
        end
    end)
end

function RevengeCinematicController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self._activeSessionId += 1
    self:_restoreCamera()

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEvents = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    local revengeEvent = battleEvents:WaitForChild(RemoteNames.Battle.RevengeCinematic)

    table.insert(self._connections, revengeEvent.OnClientEvent:Connect(function(payload)
        self:_playCinematic(payload)
    end))
end

return RevengeCinematicController
