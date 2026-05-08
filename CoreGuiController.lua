--[[
脚本名字: CoreGuiController
脚本文件: CoreGuiController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/CoreGuiController
说明: 关闭 Roblox 内置 CoreGui 中不需要显示的默认界面。
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local CoreGuiController = {}

CoreGuiController._localPlayer = nil
CoreGuiController._connections = {}
CoreGuiController._enforceToken = 0

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

function CoreGuiController:_disableHealthCoreGui()
    pcall(function()
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
    end)
end

function CoreGuiController:_startEnforcing()
    self._enforceToken += 1
    local token = self._enforceToken

    self:_disableHealthCoreGui()
    task.spawn(function()
        for _ = 1, 20 do
            if token ~= self._enforceToken then
                return
            end
            self:_disableHealthCoreGui()
            task.wait(0.25)
        end
    end)
end

function CoreGuiController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)

    self:_startEnforcing()

    if self._localPlayer then
        table.insert(self._connections, self._localPlayer.CharacterAdded:Connect(function()
            self:_startEnforcing()
        end))
    end
end

return CoreGuiController
