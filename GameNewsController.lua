--[[
Script: GameNewsController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/GameNewsController
Purpose: Bind TopRightGui.Log to the GameNews panel.
]]

local Players = game:GetService("Players")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))

local GameNewsController = {}

GameNewsController._localPlayer = nil
GameNewsController._connections = {}
GameNewsController._uiConnections = {}
GameNewsController._entryMotionCleanup = nil
GameNewsController._closeMotionCleanup = nil
GameNewsController._mainGui = nil
GameNewsController._entryRoot = nil
GameNewsController._entryButton = nil
GameNewsController._panel = nil
GameNewsController._closeButton = nil
GameNewsController._bindRetryQueued = false
GameNewsController._isOpen = false

local OWNER_ID = "GameNews"

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function findFirstGuiButton(root)
    if not root then
        return nil
    end
    if root:IsA("GuiButton") then
        return root
    end
    return root:FindFirstChildWhichIsA("GuiButton", true)
end

function GameNewsController:_clearUiBindings()
    disconnectAll(self._uiConnections)
    if self._entryMotionCleanup then
        self._entryMotionCleanup()
        self._entryMotionCleanup = nil
    end
    if self._closeMotionCleanup then
        self._closeMotionCleanup()
        self._closeMotionCleanup = nil
    end
end

function GameNewsController:_setOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isOpen = false
            ModalUiController:PlayPanelClose(OWNER_ID, nil, { Immediate = true })
        end
        return
    end

    self._isOpen = isOpen == true
    if self._isOpen then
        ModalUiController:PlayPanelOpen(OWNER_ID, self._panel, {
            Immediate = immediate == true,
        })
        return
    end

    ModalUiController:PlayPanelClose(OWNER_ID, self._panel, {
        Immediate = immediate == true,
    })
end

function GameNewsController:Open()
    if not (self._panel and self._panel.Parent) then
        if not self:_bindUi(true) then
            self:_queueBindRetry()
            return
        end
    end
    self:_setOpen(true)
end

function GameNewsController:Close(immediate)
    self:_setOpen(false, immediate == true)
end

function GameNewsController:_bindUi(silent)
    self:_clearUiBindings()

    self._mainGui = findMainGui(self._localPlayer)
    if not self._mainGui then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local topRightGui = self._mainGui:FindFirstChild("TopRightGui")
    self._entryRoot = topRightGui and topRightGui:FindFirstChild("Log") or nil
    self._entryButton = findFirstGuiButton(self._entryRoot)
    self._panel = self._mainGui:FindFirstChild("GameNews")
    self._closeButton = self._panel and self._panel:FindFirstChild("CloseButton", true) or nil

    if not (self._entryButton and self._entryButton:IsA("GuiButton") and self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    if not self._isOpen then
        self._panel.Visible = false
    end

    table.insert(self._uiConnections, self._entryButton.Activated:Connect(function()
        self:Open()
    end))

    self._entryMotionCleanup = ModalUiController:BindButtonMotion(self._entryButton, {
        ScaleTarget = self._entryRoot,
        RotationTarget = self._entryButton,
        HoverScale = 1.08,
        PressScale = 0.9,
        HoverRotation = 14,
        IncludeSiblingTextScale = true,
    })

    if self._closeButton and self._closeButton:IsA("GuiButton") then
        table.insert(self._uiConnections, self._closeButton.Activated:Connect(function()
            self:Close()
        end))

        self._closeMotionCleanup = ModalUiController:BindButtonMotion(self._closeButton, {
            ScaleTarget = self._closeButton,
            RotationTarget = self._closeButton,
            HoverScale = 1.05,
            PressScale = 0.92,
            HoverRotation = 12,
        })
    end

    return true
end

function GameNewsController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[GameNewsController] Could not find PlayerGui/Main/TopRightGui/Log or Main/GameNews.")
    end)
end

function GameNewsController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_clearUiBindings()
    self._isOpen = false

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi(true)
                end)
            end
        end))
    end
end

return GameNewsController
