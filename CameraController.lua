--[[
脚本名字: CameraController
脚本文件: CameraController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/CameraController
说明: 控制默认相机缩放范围和玩家进入游戏后的初始镜头高度。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local CameraController = {}

CameraController._localPlayer = nil
CameraController._connections = {}
CameraController._applySerial = 0

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
    return minZoom, defaultZoom, maxZoom
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
    disconnectAll(self._connections)

    self:_applyZoomSettings()

    if self._localPlayer then
        table.insert(self._connections, self._localPlayer.CharacterAdded:Connect(function()
            self:_applyZoomSettings()
        end))
    end
end

return CameraController
