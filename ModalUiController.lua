--[[
Script: ModalUiController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/ModalUiController
Purpose: Shared modal UI suppression and blur handling for Main screen panels.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local ModalUiController = {}

ModalUiController._owners = {}
ModalUiController._hiddenOriginalVisibleByNode = {}
ModalUiController._mainGui = nil
ModalUiController._blurEffect = nil
ModalUiController._blurOriginalEnabled = nil
ModalUiController._childAddedConnection = nil
ModalUiController._hiddenVisibleConnectionsByNode = {}

local function findBlurEffect()
    local blur = Lighting:FindFirstChild("Blur")
    if blur and blur:IsA("BlurEffect") then
        return blur
    end

    blur = Lighting:FindFirstChild("Blur", true)
    if blur and blur:IsA("BlurEffect") then
        return blur
    end

    return nil
end

local function findMainGuiFromPanel(panel)
    local current = panel
    while current do
        if current:IsA("ScreenGui") and current.Name == "Main" then
            return current
        end
        current = current.Parent
    end

    local localPlayer = Players.LocalPlayer
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    return playerGui and (playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)) or nil
end

local function normalizeOwnerId(ownerId)
    local ownerKey = tostring(ownerId or "")
    if ownerKey == "" then
        ownerKey = "Modal"
    end
    return ownerKey
end

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

function ModalUiController:_hasOwners()
    return next(self._owners) ~= nil
end

function ModalUiController:_isActivePanelChild(child)
    for _, ownerState in pairs(self._owners) do
        local panel = ownerState and ownerState.Panel
        if panel and panel.Parent then
            if child == panel or child:IsAncestorOf(panel) or panel:IsAncestorOf(child) then
                return true
            end
        end
    end
    return false
end

function ModalUiController:_rememberOriginalVisible(guiObject)
    if self._hiddenOriginalVisibleByNode[guiObject] == nil then
        self._hiddenOriginalVisibleByNode[guiObject] = guiObject.Visible == true
    end
end

function ModalUiController:_ensureHiddenVisibleWatcher(guiObject)
    if self._hiddenVisibleConnectionsByNode[guiObject] then
        return
    end

    self._hiddenVisibleConnectionsByNode[guiObject] = guiObject:GetPropertyChangedSignal("Visible"):Connect(function()
        if not self:_hasOwners() or not guiObject.Parent or self:_isActivePanelChild(guiObject) then
            return
        end

        if guiObject.Visible == true then
            self._hiddenOriginalVisibleByNode[guiObject] = true
            guiObject.Visible = false
        end
    end)
end

function ModalUiController:_clearHiddenVisibleWatchers()
    for guiObject, connection in pairs(self._hiddenVisibleConnectionsByNode) do
        disconnectConnection(connection)
        self._hiddenVisibleConnectionsByNode[guiObject] = nil
    end
end

function ModalUiController:_suppressGuiObject(guiObject)
    self:_rememberOriginalVisible(guiObject)
    self:_ensureHiddenVisibleWatcher(guiObject)
    if guiObject.Visible ~= false then
        guiObject.Visible = false
    end
end

function ModalUiController:_applyBlur()
    if self._blurEffect and self._blurEffect.Parent then
        self._blurEffect.Enabled = true
        return
    end

    self._blurEffect = findBlurEffect()
    if self._blurEffect then
        self._blurOriginalEnabled = self._blurEffect.Enabled == true
        self._blurEffect.Enabled = true
    else
        self._blurOriginalEnabled = nil
    end
end

function ModalUiController:_restoreBlur()
    if self._blurEffect and self._blurEffect.Parent and self._blurOriginalEnabled ~= nil then
        self._blurEffect.Enabled = self._blurOriginalEnabled == true
    end
    self._blurEffect = nil
    self._blurOriginalEnabled = nil
end

function ModalUiController:_ensureChildWatcher()
    if self._childAddedConnection or not self._mainGui then
        return
    end

    self._childAddedConnection = self._mainGui.ChildAdded:Connect(function(child)
        if not self:_hasOwners() then
            return
        end
        if child and child:IsA("GuiObject") then
            task.defer(function()
                self:_applySuppression()
            end)
        end
    end)
end

function ModalUiController:_clearChildWatcher()
    disconnectConnection(self._childAddedConnection)
    self._childAddedConnection = nil
end

function ModalUiController:_applySuppression()
    if not self._mainGui then
        return
    end

    self:_applyBlur()
    self:_ensureChildWatcher()

    for _, child in ipairs(self._mainGui:GetChildren()) do
        if child:IsA("GuiObject") and not self:_isActivePanelChild(child) then
            self:_suppressGuiObject(child)
        end
    end
end

function ModalUiController:_restoreSuppression()
    for guiObject, originalVisible in pairs(self._hiddenOriginalVisibleByNode) do
        if guiObject and guiObject.Parent and guiObject:IsA("GuiObject") then
            guiObject.Visible = originalVisible == true
        end
    end
    table.clear(self._hiddenOriginalVisibleByNode)
    self:_clearHiddenVisibleWatchers()
    self:_restoreBlur()
    self:_clearChildWatcher()
    self._mainGui = nil
end

function ModalUiController:Acquire(ownerId, panel)
    if not (panel and panel:IsA("GuiObject")) then
        return false
    end

    local mainGui = findMainGuiFromPanel(panel)
    if not mainGui then
        return false
    end

    local ownerKey = normalizeOwnerId(ownerId)
    self._mainGui = mainGui
    self._owners[ownerKey] = {
        Panel = panel,
    }
    self:_applySuppression()
    return true
end

function ModalUiController:Release(ownerId)
    local ownerKey = normalizeOwnerId(ownerId)
    self._owners[ownerKey] = nil

    if self:_hasOwners() then
        self:_applySuppression()
        return
    end

    self:_restoreSuppression()
end

function ModalUiController:IsAnyOpen()
    return self:_hasOwners()
end

function ModalUiController:SetRestoredVisible(guiObject, visible)
    if guiObject and self._hiddenOriginalVisibleByNode[guiObject] ~= nil then
        self._hiddenOriginalVisibleByNode[guiObject] = visible == true
    end
end

return ModalUiController
