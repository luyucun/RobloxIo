--[[
脚本名字: LocalLeaderboardController
脚本文件: LocalLeaderboardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/LocalLeaderboardController
说明: 渲染 StarterGui/Main/Leaderboard 自定义局内等级排行榜，并保留 Roblox 内置 Tab 排行榜。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))

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
        "[LocalLeaderboardController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local LocalLeaderboardController = {}

LocalLeaderboardController._localPlayer = nil
LocalLeaderboardController._connections = {}
LocalLeaderboardController._rowConnections = {}
LocalLeaderboardController._avatarCacheByUserId = {}
LocalLeaderboardController._mainGui = nil
LocalLeaderboardController._root = nil
LocalLeaderboardController._frame = nil
LocalLeaderboardController._title = nil
LocalLeaderboardController._tag = nil
LocalLeaderboardController._hideButton = nil
LocalLeaderboardController._scrollingFrame = nil
LocalLeaderboardController._latestPayload = nil
LocalLeaderboardController._latestPlayerState = nil
LocalLeaderboardController._isCollapsed = false
LocalLeaderboardController._bindRetryQueued = false
LocalLeaderboardController._renderQueued = false
LocalLeaderboardController._avatarRequestPendingByUserId = {}
LocalLeaderboardController._avatarFailedAtByUserId = {}

local GENERATED_ROW_ATTRIBUTE = "GeneratedLocalLeaderboardRow"
local COLLAPSED_TAG_POSITION = UDim2.new(0.85, 0, 0.5, 0)
local EXPANDED_TAG_POSITION = UDim2.new(-0.05, 0, 0.5, 0)
local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.92
local HIDE_HIT_AREA_NAME = "HideHitArea"
local HIDE_HIT_AREA_SIZE = UDim2.fromOffset(44, 44)
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local AVATAR_RETRY_SECONDS = 30
local AVATAR_RENDER_DEBOUNCE_SECONDS = 0.25

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

local function findNested(root, path)
    local current = root
    for part in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(part)
    end
    return current
end

local function ensureUiScale(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if uiScale then
        return uiScale
    end

    uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = guiObject
    return uiScale
end

local function ensureHideHitArea(button)
    if not (button and button:IsA("GuiButton")) then
        return nil
    end

    local parent = button.Parent
    if not (parent and parent:IsA("GuiObject")) then
        return button
    end

    local hitArea = parent:FindFirstChild(HIDE_HIT_AREA_NAME)
    if not (hitArea and hitArea:IsA("GuiButton")) then
        if hitArea then
            hitArea:Destroy()
        end
        hitArea = Instance.new("TextButton")
        hitArea.Name = HIDE_HIT_AREA_NAME
        hitArea.Text = ""
        hitArea.BackgroundTransparency = 1
        hitArea.TextTransparency = 1
        hitArea.AutoButtonColor = false
        hitArea.Parent = parent
    end

    hitArea.Visible = true
    hitArea.Active = true
    hitArea.Selectable = button.Selectable
    hitArea.AnchorPoint = button.AnchorPoint
    hitArea.Position = button.Position
    hitArea.Size = HIDE_HIT_AREA_SIZE
    hitArea.Rotation = 0
    hitArea.ZIndex = button.ZIndex + 1
    hitArea.LayoutOrder = button.LayoutOrder
    return hitArea
end

local function setText(container, childName, text)
    local node = container and container:FindFirstChild(childName, true)
    if node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox")) then
        node.Text = tostring(text or "")
    end
end

local function setImage(container, childName, image)
    local node = container and container:FindFirstChild(childName, true)
    if node and (node:IsA("ImageLabel") or node:IsA("ImageButton")) then
        node.Image = tostring(image or "")
    end
end

local function getRows(payload)
    local rows = payload and payload.server
    if type(rows) ~= "table" then
        return {}
    end
    return rows
end

local function updateCanvasSize(scrollingFrame)
    if not (scrollingFrame and scrollingFrame:IsA("ScrollingFrame")) then
        return
    end

    local listLayout = scrollingFrame:FindFirstChildOfClass("UIListLayout")
    if listLayout then
        scrollingFrame.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y)
    end
end

function LocalLeaderboardController:_getAvatarImage(userId)
    userId = tonumber(userId)
    if not userId or userId <= 0 then
        return ""
    end

    if self._avatarCacheByUserId[userId] then
        return self._avatarCacheByUserId[userId]
    end

    local failedAt = tonumber(self._avatarFailedAtByUserId[userId]) or 0
    if failedAt > 0 and os.clock() - failedAt < AVATAR_RETRY_SECONDS then
        return ""
    end

    if self._avatarRequestPendingByUserId[userId] then
        return ""
    end

    self._avatarRequestPendingByUserId[userId] = true
    task.spawn(function()
        local success, image = pcall(function()
            return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
        end)
        self._avatarRequestPendingByUserId[userId] = nil
        if success and image then
            self._avatarFailedAtByUserId[userId] = nil
            self._avatarCacheByUserId[userId] = image
            self:_queueRenderRows()
        else
            self._avatarFailedAtByUserId[userId] = os.clock()
        end
    end)

    return ""
end

function LocalLeaderboardController:_queueRenderRows()
    if self._renderQueued then
        return
    end
    self._renderQueued = true
    task.delay(AVATAR_RENDER_DEBOUNCE_SECONDS, function()
        self._renderQueued = false
        if self._latestPayload then
            self:_renderRows(self._latestPayload)
        end
    end)
end

function LocalLeaderboardController:_clearGeneratedRows()
    if not self._scrollingFrame then
        return
    end

    for _, child in ipairs(self._scrollingFrame:GetChildren()) do
        if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
            if child:IsA("GuiObject") then
                child.Visible = false
            end
        end
    end

    for index = 1, 3 do
        local row = self._scrollingFrame:FindFirstChild(string.format("Rank%02d", index))
        if row and row:IsA("GuiObject") then
            row.Visible = false
        end
    end

    local template = self._scrollingFrame:FindFirstChild("RankTemplate")
    if template and template:IsA("GuiObject") then
        template.Visible = false
    end
end

function LocalLeaderboardController:_applyRow(row, rowData, rank)
    if not (row and row:IsA("GuiObject")) then
        return
    end

    row.Visible = true
    row.LayoutOrder = rank
    setText(row, "Rank", tostring(rank))
    setText(row, "Name", tostring(rowData.name or rowData.userId or "Unknown"))
    setText(row, "Num", string.format("Lv.%d", math.max(1, math.floor(tonumber(rowData.level) or 1))))
    setImage(row, "Avatar", self:_getAvatarImage(rowData.userId))
end

function LocalLeaderboardController:_renderRows(payload)
    self._latestPayload = payload
    if not self._scrollingFrame then
        return
    end

    self:_clearGeneratedRows()
    local rows = getRows(payload)
    local template = self._scrollingFrame:FindFirstChild("RankTemplate")
    for rank, rowData in ipairs(rows) do
        local generatedName = string.format("Rank%02dGenerated", rank)
        local row = self._scrollingFrame:FindFirstChild(string.format("Rank%02d", rank))
        if rank >= 4 then
            row = self._scrollingFrame:FindFirstChild(generatedName)
        end
        if not row then
            if template and template:IsA("GuiObject") then
                row = template:Clone()
                row.Name = generatedName
                row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
                row.Parent = self._scrollingFrame
            end
        end

        if row then
            self:_applyRow(row, rowData, rank)
        end
    end

    updateCanvasSize(self._scrollingFrame)
end

function LocalLeaderboardController:_setCollapsed(isCollapsed)
    self._isCollapsed = isCollapsed == true
    if self._frame and self._frame:IsA("GuiObject") then
        self._frame.Visible = not self._isCollapsed
    end
    if self._title and self._title:IsA("GuiObject") then
        self._title.Visible = not self._isCollapsed
    end
    if self._tag and self._tag:IsA("GuiObject") then
        self._tag.Position = self._isCollapsed and COLLAPSED_TAG_POSITION or EXPANDED_TAG_POSITION
    end
    if self._hideButton and self._hideButton:IsA("GuiObject") then
        self._hideButton.Rotation = self._isCollapsed and -90 or 90
    end
end

function LocalLeaderboardController:_applyVisibilityFromState()
    if not (self._root and self._root:IsA("GuiObject")) then
        return
    end

    local shouldShow = self._latestPlayerState and self._latestPlayerState.isInArena == true
    if ModalUiController:IsAnyOpen() then
        ModalUiController:SetRestoredVisible(self._root, shouldShow == true)
        self._root.Visible = false
        return
    end
    self._root.Visible = shouldShow == true
    if shouldShow then
        self:_setCollapsed(self._isCollapsed)
    end
end

function LocalLeaderboardController:_bindHideButton()
    disconnectAll(self._rowConnections)
    local button = self._hideButton
    if not (button and button:IsA("GuiButton")) then
        return
    end

    button.Active = true
    local inputTarget = ensureHideHitArea(button) or button
    local uiScale = ensureUiScale(button)
    if not uiScale then
        return
    end

    local baseScale = uiScale.Scale
    local isHovered = false
    local isPressed = false
    local tween = nil

    local function applyButtonState()
        local scale = baseScale
        local tweenInfo = RESET_TWEEN_INFO
        if isPressed then
            scale = baseScale * PRESS_SCALE
            tweenInfo = PRESS_TWEEN_INFO
        elseif isHovered then
            scale = baseScale * HOVER_SCALE
            tweenInfo = HOVER_TWEEN_INFO
        end
        if tween then
            tween:Cancel()
            tween = nil
        end
        tween = TweenService:Create(uiScale, tweenInfo, { Scale = scale })
        tween:Play()
    end

    table.insert(self._rowConnections, inputTarget.MouseEnter:Connect(function()
        isHovered = true
        applyButtonState()
    end))
    table.insert(self._rowConnections, inputTarget.MouseLeave:Connect(function()
        isHovered = false
        isPressed = false
        applyButtonState()
    end))
    table.insert(self._rowConnections, inputTarget.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            isPressed = true
            if inputType == Enum.UserInputType.Touch then
                isHovered = true
            end
            applyButtonState()
        end
    end))
    table.insert(self._rowConnections, inputTarget.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            isPressed = false
            if inputType == Enum.UserInputType.Touch then
                isHovered = false
            end
            applyButtonState()
        end
    end))
    table.insert(self._rowConnections, inputTarget.Activated:Connect(function()
        self:_setCollapsed(not self._isCollapsed)
    end))
end

function LocalLeaderboardController:_queueBindRetry()
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
        warn("[LocalLeaderboardController] Could not find PlayerGui/Main/Leaderboard.")
    end)
end

function LocalLeaderboardController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._root = mainGui and mainGui:FindFirstChild("Leaderboard", true) or nil
    if not (self._root and self._root:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._frame = self._root:FindFirstChild("Frame")
    self._title = self._root:FindFirstChild("Title")
    self._tag = self._root:FindFirstChild("Tag")
    self._hideButton = findNested(self._root, "Tag/Hide")
    self._scrollingFrame = findNested(self._root, "Frame/ScrollingFrame")
    if not (self._scrollingFrame and self._scrollingFrame:IsA("ScrollingFrame")) then
        if not silent then
            warn("[LocalLeaderboardController] Missing Leaderboard/Frame/ScrollingFrame.")
        end
        return false
    end

    self:_bindHideButton()
    self:_setCollapsed(self._isCollapsed)
    self:_applyVisibilityFromState()
    if self._latestPayload then
        self:_renderRows(self._latestPayload)
    else
        self:_clearGeneratedRows()
    end
    return true
end

function LocalLeaderboardController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestPayload = nil
    self._latestPlayerState = nil
    self._avatarCacheByUserId = {}
    self._avatarRequestPendingByUserId = {}
    self._avatarFailedAtByUserId = {}
    self._renderQueued = false
    self._isCollapsed = false
    disconnectAll(self._connections)
    disconnectAll(self._rowConnections)

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local battleEventsFolder = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local leaderboardSyncEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.LeaderboardSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        local wasInArena = self._latestPlayerState and self._latestPlayerState.isInArena == true
        local isInArena = payload and payload.isInArena == true
        self._latestPlayerState = payload
        if isInArena and not wasInArena then
            self:_setCollapsed(false)
        end
        self:_applyVisibilityFromState()
    end))

    table.insert(self._connections, leaderboardSyncEvent.OnClientEvent:Connect(function(payload)
        self:_renderRows(payload)
    end))

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                end)
            end
        end))
    end
end

return LocalLeaderboardController
