--[[
脚本名字: JoinGameController
脚本文件: JoinGameController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/JoinGameController
说明: 隐藏旧入场确认面板，复用 Portal 门牌显示直接入场反馈，不开启模态或 Blur。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RemoteNames = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RemoteNames"))

local JoinGameController = {}
JoinGameController._connections = {}
JoinGameController._panelConnection = nil
JoinGameController._portalLabel = nil
JoinGameController._portalDefaultText = nil
JoinGameController._feedbackSerial = 0

local function findPortalLabel()
    local map = Workspace:FindFirstChild("Map2")
    local portals = map and map:FindFirstChild("Portals")
    local portal = portals and portals:FindFirstChild("Portal")
    local title = portal and portal:FindFirstChild("Title")
    local billboard = title and title:FindFirstChild("Billboard")
    local background = billboard and billboard:FindFirstChild("Bg")
    local label = background and background:FindFirstChild("Text")
    if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
        return label
    end
    return nil
end

function JoinGameController:_hideLegacyPanel(playerGui)
    local main = playerGui and playerGui:FindFirstChild("Main")
    local panel = main and main:FindFirstChild("JoinGame")
    if self._panelConnection then
        self._panelConnection:Disconnect()
        self._panelConnection = nil
    end
    if panel and panel:IsA("GuiObject") then
        panel.Visible = false
        self._panelConnection = panel:GetPropertyChangedSignal("Visible"):Connect(function()
            if panel.Visible then
                panel.Visible = false
            end
        end)
    end
end

function JoinGameController:_setPortalText(text)
    local label = findPortalLabel()
    if label ~= self._portalLabel then
        self._portalLabel = label
        self._portalDefaultText = label and label.Text or nil
    end
    if label then
        label.Text = text or self._portalDefaultText or "Fight!"
    end
end

function JoinGameController:_onTransition(payload)
    if type(payload) ~= "table" then
        return
    end
    local status = payload.status
    local reason = payload.spawnMode
    if status == "Entering" then
        self._feedbackSerial += 1
        self:_setPortalText("Entering...")
    elseif status == "PortalReady" or status == "EnterBattle" or status == "ReturnHome" then
        self._feedbackSerial += 1
        self:_setPortalText(nil)
    elseif status == "Blocked" then
        if reason == "DataLoading" or reason == "CharacterNotReady" then
            self._feedbackSerial += 1
            self:_setPortalText("Preparing...")
        elseif reason == "Defeated" or reason == "OutsidePortal" then
            self._feedbackSerial += 1
            self:_setPortalText(nil)
        elseif reason ~= "Debounced" and reason ~= "LobbyReviveFailed" then
            self._feedbackSerial += 1
            local serial = self._feedbackSerial
            self:_setPortalText("Unable to enter. Retrying...")
            task.delay(4, function()
                if self._feedbackSerial == serial then
                    self:_setPortalText(nil)
                end
            end)
        end
    end
end

function JoinGameController:Init(dependencies)
    for _, connection in ipairs(self._connections) do
        connection:Disconnect()
    end
    table.clear(self._connections)
    self._feedbackSerial += 1
    self:_setPortalText(nil)
    local player = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    local playerGui = player:WaitForChild("PlayerGui")
    self:_hideLegacyPanel(playerGui)
    table.insert(self._connections, playerGui.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "Main" or descendant.Name == "JoinGame" then
            self:_hideLegacyPanel(playerGui)
        end
    end))

    local systemEvents = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder):WaitForChild(RemoteNames.SystemEventsFolder)
    table.insert(self._connections, systemEvents:WaitForChild(RemoteNames.System.ArenaTransitionFeedback).OnClientEvent:Connect(function(payload)
        self:_onTransition(payload)
    end))
    -- 兼容旧事件：不再打开面板，也不在客户端绕过服务端直接入场。
    table.insert(self._connections, systemEvents:WaitForChild(RemoteNames.System.PortalJoinPrompt).OnClientEvent:Connect(function()
        self:_hideLegacyPanel(playerGui)
    end))
end

return JoinGameController
