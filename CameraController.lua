--[[
脚本名字: CameraController
脚本文件: CameraController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/CameraController
说明: 控制默认相机缩放范围和玩家进入游戏后的初始镜头高度。
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
        "[CameraController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local CameraController = {}

CameraController._localPlayer = nil
CameraController._connections = {}
CameraController._applySerial = 0
CameraController._spawnLookSerial = 0
CameraController._portalCameraBindName = "IOFacePortalCamera"
CameraController._skipNextSpawnLookUntil = 0

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

function CameraController:_getConfig()
    local cameraConfig = GameConfig.CAMERA or {}
    local minZoom = math.max(0.5, tonumber(cameraConfig.MinZoomDistance) or 15)
    local maxZoom = math.max(minZoom, tonumber(cameraConfig.MaxZoomDistance) or 60)
    local defaultZoom = math.clamp(tonumber(cameraConfig.DefaultZoomDistance) or 20, minZoom, maxZoom)
    local spawnLookPitchDegrees = math.clamp(tonumber(cameraConfig.SpawnLookPitchDegrees) or 35, 5, 80)
    local spawnLookFocusHeightOffset = tonumber(cameraConfig.SpawnLookFocusHeightOffset) or 2
    local spawnLookForwardOffset = math.max(0, tonumber(cameraConfig.SpawnLookForwardOffset) or 8)
    return minZoom, defaultZoom, maxZoom, spawnLookPitchDegrees, spawnLookFocusHeightOffset, spawnLookForwardOffset
end

local function getCharacterRoot(player)
    local character = player and player.Character
    if not character then
        return nil
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if rootPart and rootPart:IsA("BasePart") then
        return rootPart
    end

    local primaryPart = character.PrimaryPart
    if primaryPart and primaryPart:IsA("BasePart") then
        return primaryPart
    end

    return nil
end

local function resolvePortalPosition()
    local arenaConfig = GameConfig.ARENA or {}
    local map = Workspace:FindFirstChild(arenaConfig.MapFolderName or "Map2")
    local portals = map and map:FindFirstChild(arenaConfig.PortalsFolderName or "Portals")
    local portal = portals and portals:FindFirstChild(arenaConfig.PortalModelName or "Portal")
    if not portal then
        return nil
    end

    if portal:IsA("Model") then
        local didGetPivot, pivot = pcall(function()
            return portal:GetPivot()
        end)
        if didGetPivot and pivot then
            return pivot.Position
        end

        local didGetBounds, boundsCFrame = pcall(function()
            local resolvedBoundsCFrame = portal:GetBoundingBox()
            return resolvedBoundsCFrame
        end)
        if didGetBounds and boundsCFrame then
            return boundsCFrame.Position
        end
    elseif portal:IsA("BasePart") then
        return portal.Position
    end

    return nil
end

function CameraController:_faceCameraToPortal()
    local player = self._localPlayer
    local camera = Workspace.CurrentCamera
    -- A cinematic owns a Scriptable camera; respawn framing must not overwrite it.
    if camera and camera.CameraType == Enum.CameraType.Scriptable then
        return false
    end
    local rootPart = getCharacterRoot(player)
    local portalPosition = resolvePortalPosition()
    if not (camera and rootPart and portalPosition) then
        return false
    end

    local _, defaultZoom, _, spawnLookPitchDegrees, spawnLookFocusHeightOffset, spawnLookForwardOffset = self:_getConfig()
    local flatDirection = Vector3.new(
        portalPosition.X - rootPart.Position.X,
        0,
        portalPosition.Z - rootPart.Position.Z
    )
    if flatDirection.Magnitude <= 0.001 then
        return false
    end

    local forward = flatDirection.Unit
    local pitchRadians = math.rad(spawnLookPitchDegrees)
    local horizontalDistance = math.cos(pitchRadians) * defaultZoom
    local verticalDistance = math.sin(pitchRadians) * defaultZoom
    local focusPosition = rootPart.Position + Vector3.new(0, spawnLookFocusHeightOffset, 0)
    local cameraPosition = focusPosition - (forward * horizontalDistance) + Vector3.new(0, verticalDistance, 0)
    local lookTarget = focusPosition + (forward * spawnLookForwardOffset)

    camera.CameraType = Enum.CameraType.Custom
    camera.CameraSubject = player.Character and player.Character:FindFirstChildOfClass("Humanoid") or camera.CameraSubject
    camera.CFrame = CFrame.lookAt(cameraPosition, lookTarget)
    return true
end

function CameraController:_unbindPortalCameraLook()
    pcall(function()
        RunService:UnbindFromRenderStep(self._portalCameraBindName)
    end)
end

function CameraController:_scheduleFaceCameraToPortal(delaySeconds)
    self._spawnLookSerial += 1
    local spawnLookSerial = self._spawnLookSerial
    if os.clock() <= (self._skipNextSpawnLookUntil or 0) then
        self._skipNextSpawnLookUntil = 0
        self:_unbindPortalCameraLook()
        return
    end

    task.delay(math.max(0, tonumber(delaySeconds) or 0), function()
        if self._spawnLookSerial ~= spawnLookSerial then
            return
        end

        self:_unbindPortalCameraLook()
        local endClock = os.clock() + 0.45
        RunService:BindToRenderStep(self._portalCameraBindName, Enum.RenderPriority.Camera.Value + 1, function()
            if self._spawnLookSerial ~= spawnLookSerial or os.clock() >= endClock then
                self:_unbindPortalCameraLook()
                return
            end

            self:_faceCameraToPortal()
        end)
    end)
end

function CameraController:_applyZoomSettings()
    local player = self._localPlayer
    if not (player and player.Parent) then
        return
    end

    local minZoom, defaultZoom, maxZoom = self:_getConfig()
    player.CameraMode = Enum.CameraMode.Classic

    self._applySerial += 1
    local applySerial = self._applySerial

    player.CameraMinZoomDistance = defaultZoom
    player.CameraMaxZoomDistance = defaultZoom

    task.delay(0.35, function()
        if not (player and player.Parent) then
            return
        end
        if self._applySerial ~= applySerial then
            return
        end

        player.CameraMinZoomDistance = minZoom
        player.CameraMaxZoomDistance = maxZoom
    end)
end

function CameraController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._skipNextSpawnLookUntil = 0
    disconnectAll(self._connections)
    self:_unbindPortalCameraLook()

    self:_applyZoomSettings()
    self:_scheduleFaceCameraToPortal(0.45)

    if self._localPlayer then
        table.insert(self._connections, self._localPlayer.CharacterAdded:Connect(function()
            self:_applyZoomSettings()
            self:_scheduleFaceCameraToPortal(0.45)
        end))
    end

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local transitionEvent = systemEventsFolder:WaitForChild(RemoteNames.System.ArenaTransitionFeedback)
    table.insert(self._connections, transitionEvent.OnClientEvent:Connect(function(payload)
        if type(payload) ~= "table" then
            return
        end

        if payload.status == "ReturnHome" and payload.spawnMode == "SpawnLocation" then
            self:_scheduleFaceCameraToPortal(0.05)
        elseif payload.status == "SkipSpawnCameraLook" and payload.spawnMode == "ArenaRevive" then
            self._skipNextSpawnLookUntil = os.clock() + 5
            self:_unbindPortalCameraLook()
        end
    end))
end

return CameraController
