--[[
脚本名字: GlobalLeaderboardController
脚本文件: GlobalLeaderboardController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/GlobalLeaderboardController
说明: 渲染 Workspace.Map2.Leaderboards 下的全局击杀、转生、在线时长排行榜。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
        "[GlobalLeaderboardController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local GlobalLeaderboardController = {}

GlobalLeaderboardController._localPlayer = nil
GlobalLeaderboardController._connections = {}
GlobalLeaderboardController._leaderboardSyncEvent = nil
GlobalLeaderboardController._latestPayload = nil
GlobalLeaderboardController._avatarCacheByUserId = {}
GlobalLeaderboardController._leaderboardsRoot = nil
GlobalLeaderboardController._layoutConnectionsByScrollingFrame = {}

local GENERATED_ROW_ATTRIBUTE = "GeneratedLeaderboardRow"

local BOARD_DEFINITIONS = {
    LeaderboardKill = {
        metricKey = "kills",
        format = "integer",
    },
    LeaderboardRebirth = {
        metricKey = "rebirth",
        format = "integer",
    },
    LeaderboardTime = {
        metricKey = "playtime",
        format = "time",
    },
}

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
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

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function formatPlaytime(seconds)
    local totalMinutes = math.max(0, math.floor((tonumber(seconds) or 0) / 60))
    local days = math.floor(totalMinutes / 1440)
    local hours = math.floor((totalMinutes % 1440) / 60)
    local minutes = totalMinutes % 60
    return string.format("%d:%02d:%02d", days, hours, minutes)
end

local function formatValue(value, formatKey)
    if formatKey == "time" then
        return formatPlaytime(value)
    end
    return formatInteger(value)
end

local function getRowsForMetric(payload, metricKey)
    local global = payload and payload.global
    local metricPayload = global and global[metricKey]
    local rows = metricPayload and metricPayload.rows
    if type(rows) ~= "table" then
        return {}
    end
    return rows
end

local function getSelfForMetric(payload, metricKey)
    local selfPayload = payload and payload.self
    local metricPayload = selfPayload and selfPayload[metricKey]
    if type(metricPayload) ~= "table" then
        return nil
    end
    return metricPayload
end

local function findLeaderboardsRoot()
    local map2 = Workspace:FindFirstChild("Map2")
    return map2 and map2:FindFirstChild("Leaderboards") or nil
end

local function findBoardFrame(boardModel)
    local main = boardModel and boardModel:FindFirstChild("Main")
    local surfaceGui = main and main:FindFirstChild("SurfaceGui")
    return surfaceGui and surfaceGui:FindFirstChild("Frame") or nil
end

local function getScrollingFrame(boardFrame)
    local scrollingFrame = boardFrame and boardFrame:FindFirstChild("ScrollingFrame")
    if scrollingFrame and scrollingFrame:IsA("ScrollingFrame") then
        return scrollingFrame
    end
    return nil
end

local function getPlayerRow(boardFrame)
    local playerRow = boardFrame and boardFrame:FindFirstChild("Player")
    if playerRow and playerRow:IsA("GuiObject") then
        return playerRow
    end
    return nil
end

local function updateCanvasSize(scrollingFrame)
    if not (scrollingFrame and scrollingFrame:IsA("ScrollingFrame")) then
        return
    end

    local listLayout = scrollingFrame:FindFirstChildOfClass("UIListLayout")
    if not listLayout then
        return
    end

    scrollingFrame.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y)
end

function GlobalLeaderboardController:_getAvatarImage(userId)
    userId = tonumber(userId)
    if not userId or userId <= 0 then
        return ""
    end

    if self._avatarCacheByUserId[userId] then
        return self._avatarCacheByUserId[userId]
    end

    task.spawn(function()
        local success, image = pcall(function()
            return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
        end)
        if success and image then
            self._avatarCacheByUserId[userId] = image
            if self._latestPayload then
                self:_renderAll(self._latestPayload)
            end
        end
    end)

    return ""
end

function GlobalLeaderboardController:_clearGeneratedRows(scrollingFrame)
    for _, child in ipairs(scrollingFrame:GetChildren()) do
        if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
            child:Destroy()
        end
    end

    for index = 1, 3 do
        local row = scrollingFrame:FindFirstChild(string.format("Rank%02d", index))
        if row and row:IsA("GuiObject") then
            row.Visible = false
        end
    end

    local template = scrollingFrame:FindFirstChild("RankTemplate")
    if template and template:IsA("GuiObject") then
        template.Visible = false
    end
end

function GlobalLeaderboardController:_applyRow(row, rowData, metricDefinition)
    if not (row and row:IsA("GuiObject")) then
        return
    end

    local rank = math.max(1, math.floor(tonumber(rowData.rank) or 0))
    row.Visible = true
    setText(row, "Rank", tostring(rank))
    setText(row, "Name", tostring(rowData.name or rowData.userId or "Unknown"))
    setText(row, "Num", formatValue(rowData.value, metricDefinition.format))
    setImage(row, "Avatar", self:_getAvatarImage(rowData.userId))
end

function GlobalLeaderboardController:_renderRows(scrollingFrame, rows, metricDefinition)
    self:_clearGeneratedRows(scrollingFrame)

    local template = scrollingFrame:FindFirstChild("RankTemplate")
    local maxRows = math.min(#rows, 50)
    for index = 1, maxRows do
        local rowData = rows[index]
        rowData.rank = rowData.rank or index

        local row = scrollingFrame:FindFirstChild(string.format("Rank%02d", index))
        if index >= 4 or not row then
            if template and template:IsA("GuiObject") then
                row = template:Clone()
                row.Name = string.format("Rank%02dGenerated", index)
                row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
                row.LayoutOrder = index
                row.Parent = scrollingFrame
            end
        else
            row.LayoutOrder = index
        end

        if row then
            self:_applyRow(row, rowData, metricDefinition)
        end
    end

    updateCanvasSize(scrollingFrame)
end

function GlobalLeaderboardController:_renderPlayerRow(boardFrame, metricDefinition, selfData)
    local playerRow = getPlayerRow(boardFrame)
    if not playerRow then
        return
    end

    local rankText = "50+"
    if selfData then
        rankText = tostring(selfData.rankText or selfData.rank or "50+")
    end

    setText(playerRow, "Rank", rankText)
    setText(playerRow, "Name", self._localPlayer and self._localPlayer.Name or "Player")
    setText(playerRow, "Num", formatValue(selfData and selfData.value or 0, metricDefinition.format))
    setImage(playerRow, "Avatar", self:_getAvatarImage(self._localPlayer and self._localPlayer.UserId))
end

function GlobalLeaderboardController:_bindCanvasResize(scrollingFrame)
    if self._layoutConnectionsByScrollingFrame[scrollingFrame] then
        return
    end

    local listLayout = scrollingFrame:FindFirstChildOfClass("UIListLayout")
    if not listLayout then
        return
    end

    self._layoutConnectionsByScrollingFrame[scrollingFrame] = listLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        updateCanvasSize(scrollingFrame)
    end)
end

function GlobalLeaderboardController:_renderBoard(boardName, metricDefinition, payload)
    local root = self._leaderboardsRoot or findLeaderboardsRoot()
    self._leaderboardsRoot = root
    local boardModel = root and root:FindFirstChild(boardName)
    local boardFrame = findBoardFrame(boardModel)
    local scrollingFrame = getScrollingFrame(boardFrame)
    if not (boardFrame and scrollingFrame) then
        return
    end

    self:_bindCanvasResize(scrollingFrame)
    self:_renderRows(scrollingFrame, getRowsForMetric(payload, metricDefinition.metricKey), metricDefinition)
    self:_renderPlayerRow(boardFrame, metricDefinition, getSelfForMetric(payload, metricDefinition.metricKey))
end

function GlobalLeaderboardController:_renderAll(payload)
    for boardName, metricDefinition in pairs(BOARD_DEFINITIONS) do
        self:_renderBoard(boardName, metricDefinition, payload)
    end
end

function GlobalLeaderboardController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestPayload = nil
    self._avatarCacheByUserId = {}
    disconnectAll(self._connections)
    for scrollingFrame, connection in pairs(self._layoutConnectionsByScrollingFrame) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
        self._layoutConnectionsByScrollingFrame[scrollingFrame] = nil
    end

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEventsFolder = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    self._leaderboardSyncEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.LeaderboardSync)

    table.insert(self._connections, self._leaderboardSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestPayload = payload
        self:_renderAll(payload)
    end))
end

return GlobalLeaderboardController
