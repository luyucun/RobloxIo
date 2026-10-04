--[[
Script: LeaveTipsController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/LeaveTipsController
Purpose: ESC banners adapted from 加1陀螺 OfflineBannerController, using this game's existing text.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CinematicUiGate = require(script.Parent:WaitForChild("CinematicUiGate"))

local LeaveTipsController = {}
LeaveTipsController._localPlayer = nil
LeaveTipsController._playerGui = nil
LeaveTipsController._connections = {}
LeaveTipsController._uiConnections = {}
LeaveTipsController._gui = nil
LeaveTipsController._topBanner = nil
LeaveTipsController._bottomBanner = nil
LeaveTipsController._gradients = {}
LeaveTipsController._activeTweens = {}
LeaveTipsController._hideThread = nil
LeaveTipsController._uiSerial = 0
LeaveTipsController._pollSerial = 0
LeaveTipsController._menuOpen = false
LeaveTipsController._effectiveOpen = nil
LeaveTipsController._lastPolledMenuOpen = false
LeaveTipsController._bannersVisible = false
LeaveTipsController._rainbowAccumulated = 0
LeaveTipsController._bindAttempts = 0

local GUI_NAME = "LeaveTipsGui"
local PARK_MARGIN = 0.01
local SLIDE_IN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local SLIDE_OUT_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
local RAINBOW_SCROLL_SPEED = 0.12
local RAINBOW_INTERVAL = 1 / 30
local MENU_POLL_SECONDS = 0.2

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then connection:Disconnect() end
    end
    table.clear(connections)
end

-- The reference derives edge/park positions from the banner's own anchor and height.
-- Include offset height too, so manually resized banners still park fully offscreen.
local function shownTop(banner)
    return UDim2.new(0, 0, banner.AnchorPoint.Y * banner.Size.Y.Scale, banner.AnchorPoint.Y * banner.Size.Y.Offset)
end

local function shownBottom(banner)
    return UDim2.new(0, 0, 1 - (1 - banner.AnchorPoint.Y) * banner.Size.Y.Scale,
        -(1 - banner.AnchorPoint.Y) * banner.Size.Y.Offset)
end

local function parkedTop(banner)
    return shownTop(banner) - UDim2.new(0, 0, banner.Size.Y.Scale + PARK_MARGIN, banner.Size.Y.Offset)
end

local function parkedBottom(banner)
    return shownBottom(banner) + UDim2.new(0, 0, banner.Size.Y.Scale + PARK_MARGIN, banner.Size.Y.Offset)
end

-- Same hue cycle and keypoints as 加1陀螺; no Offset reset or endpoint color jump.
local function applyRainbowPhase(gradient, phase)
    local keypoints = {}
    for index = 0, 5 do
        table.insert(keypoints, ColorSequenceKeypoint.new(index / 6,
            Color3.fromHSV((phase + index / 6) % 1, 0.75, 1)))
    end
    table.insert(keypoints, ColorSequenceKeypoint.new(1, Color3.fromHSV(phase % 1, 0.75, 1)))
    gradient.Color = ColorSequence.new(keypoints)
end

function LeaveTipsController:_cancelTweens()
    self._uiSerial += 1
    if self._hideThread then
        task.cancel(self._hideThread)
        self._hideThread = nil
    end
    for _, tween in ipairs(self._activeTweens) do tween:Cancel() end
    table.clear(self._activeTweens)
end

function LeaveTipsController:_unbindUi()
    disconnectAll(self._uiConnections)
    self:_cancelTweens()
    if self._gui then
        self._gui.Enabled = false
        if self._topBanner and self._topBanner.Parent then self._topBanner.Position = parkedTop(self._topBanner) end
        if self._bottomBanner and self._bottomBanner.Parent then self._bottomBanner.Position = parkedBottom(self._bottomBanner) end
    end
    self._gui = nil
    self._topBanner = nil
    self._bottomBanner = nil
    table.clear(self._gradients)
    self._effectiveOpen = nil
    self._bannersVisible = false
    self._rainbowAccumulated = 0
end

function LeaveTipsController:_slideTo(open, immediate)
    local top, bottom = self._topBanner, self._bottomBanner
    if not (top and top.Parent and bottom and bottom.Parent) then return end
    self:_cancelTweens()
    local serial = self._uiSerial
    local topPosition = open and shownTop(top) or parkedTop(top)
    local bottomPosition = open and shownBottom(bottom) or parkedBottom(bottom)
    if immediate then
        top.Position = topPosition
        bottom.Position = bottomPosition
        self._bannersVisible = open
        return
    end
    local info = open and SLIDE_IN_INFO or SLIDE_OUT_INFO
    table.insert(self._activeTweens, TweenService:Create(top, info, { Position = topPosition }))
    table.insert(self._activeTweens, TweenService:Create(bottom, info, { Position = bottomPosition }))
    for _, tween in ipairs(self._activeTweens) do tween:Play() end
    if open then
        self._bannersVisible = true
        local phase = (os.clock() * RAINBOW_SCROLL_SPEED) % 1
        for _, gradient in ipairs(self._gradients) do applyRainbowPhase(gradient, phase) end
    else
        -- Keep colors flowing through slide-out; cancel this delay if the menu reopens.
        self._hideThread = task.delay(0.35, function()
            if serial ~= self._uiSerial then return end
            self._hideThread = nil
            self._bannersVisible = false
        end)
    end
end

function LeaveTipsController:_applyMenuState()
    if not (self._gui and self._gui.Parent) then return end
    local blocked = CinematicUiGate:IsBlocked()
    local open = self._menuOpen and not blocked
    local enabled = not blocked
    if self._effectiveOpen == open and self._gui.Enabled == enabled then return end
    self._effectiveOpen = open
    self._gui.Enabled = enabled
    self:_slideTo(open, blocked)
end

function LeaveTipsController:_setMenuOpen(open)
    self._menuOpen = open == true
    self:_applyMenuState()
end

function LeaveTipsController:_hideLegacyTip()
    local main = self._playerGui and self._playerGui:FindFirstChild("Main")
    local legacy = main and main:FindFirstChild("LeaveTips")
    if legacy and legacy:IsA("GuiObject") then legacy.Visible = false end
end

function LeaveTipsController:_bindUi(silent)
    local gui = self._playerGui and self._playerGui:FindFirstChild(GUI_NAME)
    local top = gui and gui:FindFirstChild("TopBanner")
    local bottom = gui and gui:FindFirstChild("BottomBanner")
    if not (gui and gui:IsA("ScreenGui") and top and top:IsA("Frame") and bottom and bottom:IsA("Frame")) then
        if not silent then warn("[LeaveTipsController] Missing PlayerGui/LeaveTipsGui/TopBanner or BottomBanner.") end
        return false
    end
    local gradients = {}
    for _, banner in ipairs({ top, bottom }) do
        local label = banner:FindFirstChild("Text")
        local gradient = label and label:FindFirstChildOfClass("UIGradient")
        if not (label and label:IsA("TextLabel") and gradient) then
            if not silent then warn("[LeaveTipsController] Missing banner Text/UIGradient: " .. banner.Name) end
            return false
        end
        table.insert(gradients, gradient)
    end
    if self._gui == gui and self._topBanner == top and self._bottomBanner == bottom
        and self._gradients[1] == gradients[1] and self._gradients[2] == gradients[2] then return true end
    self:_unbindUi()
    self._gui, self._topBanner, self._bottomBanner = gui, top, bottom
    self._gradients = gradients
    self._bindAttempts = 0
    gui.Enabled = false
    top.Position = parkedTop(top)
    bottom.Position = parkedBottom(bottom)
    self:_hideLegacyTip()
    table.insert(self._uiConnections, gui.AncestryChanged:Connect(function()
        if not gui:IsDescendantOf(self._playerGui) and self._gui == gui then self:_unbindUi() end
    end))
    table.insert(self._uiConnections, gui.Destroying:Connect(function()
        if self._gui == gui then self:_unbindUi() end
    end))
    self:_applyMenuState()
    return true
end

-- Poll only property edges. A stale false property must never undo an earlier MenuOpened event.
function LeaveTipsController:_pollMenu()
    local open = GuiService.MenuIsOpen == true
    if open ~= self._lastPolledMenuOpen then
        self._lastPolledMenuOpen = open
        self:_setMenuOpen(open)
    end
    if not self:_bindUi(true) then
        self._bindAttempts += 1
        if self._bindAttempts == 150 then self:_bindUi(false) end
    end
end

function LeaveTipsController:_renderRainbow(deltaTime)
    if not (self._bannersVisible and self._gui and self._gui.Enabled) then return end
    self._rainbowAccumulated += deltaTime
    if self._rainbowAccumulated < RAINBOW_INTERVAL then return end
    self._rainbowAccumulated = 0
    local phase = (os.clock() * RAINBOW_SCROLL_SPEED) % 1
    for _, gradient in ipairs(self._gradients) do
        if gradient.Parent then applyRainbowPhase(gradient, phase) end
    end
end

function LeaveTipsController:Destroy()
    self._pollSerial += 1
    disconnectAll(self._connections)
    self:_unbindUi()
end

function LeaveTipsController:Init(dependencies)
    self:Destroy()
    local serial = self._pollSerial
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 5))
    if not self._playerGui then
        warn("[LeaveTipsController] Missing PlayerGui.")
        return
    end
    self._menuOpen = GuiService.MenuIsOpen == true
    self._lastPolledMenuOpen = self._menuOpen
    self._bindAttempts = 0
    self:_hideLegacyTip()
    table.insert(self._connections, GuiService.MenuOpened:Connect(function() self:_setMenuOpen(true) end))
    table.insert(self._connections, GuiService.MenuClosed:Connect(function() self:_setMenuOpen(false) end))
    table.insert(self._connections, CinematicUiGate:Subscribe(function() self:_applyMenuState() end))
    table.insert(self._connections, RunService.RenderStepped:Connect(function(deltaTime) self:_renderRainbow(deltaTime) end))
    table.insert(self._connections, self._playerGui.ChildAdded:Connect(function(child)
        if child.Name == GUI_NAME or child.Name == "Main" then
            task.defer(function()
                if serial ~= self._pollSerial then return end
                self:_hideLegacyTip()
                self:_bindUi(true)
            end)
        end
    end))
    local rootScript = dependencies and dependencies.RootScript or script
    table.insert(self._connections, rootScript.Destroying:Connect(function() self:Destroy() end))
    self:_bindUi(true)
    task.spawn(function()
        while serial == self._pollSerial do
            task.wait(MENU_POLL_SECONDS)
            if serial ~= self._pollSerial then return end
            self:_pollMenu()
        end
    end)
end

return LeaveTipsController
