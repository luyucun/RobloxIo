--[[
脚本名字: ArenaProgressController
脚本文件: ArenaProgressController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/ArenaProgressController
说明: 渲染战场内真实玩家的等级进度条头像。
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
        "[ArenaProgressController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local ArenaProgressController = {}

ArenaProgressController._localPlayer = nil
ArenaProgressController._connections = {}
ArenaProgressController._progressRoot = nil
ArenaProgressController._template = nil
ArenaProgressController._generatedByUserId = {}
ArenaProgressController._avatarCacheByUserId = {}
ArenaProgressController._latestPayload = nil
ArenaProgressController._latestPlayerState = nil
ArenaProgressController._bindRetryQueued = false

local GENERATED_ATTRIBUTE = "ArenaProgressGenerated"
local PLAYER_NODE_PREFIX = "Player_"

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

local function setText(root, childName, text)
    local child = root and root:FindFirstChild(childName, true)
    if child and child:IsA("TextLabel") then
        child.Text = tostring(text or "")
    end
end

local function setImage(imageLabel, image)
    if imageLabel and imageLabel:IsA("ImageLabel") then
        imageLabel.Image = tostring(image or "")
    end
end

local function normalizeLevel(value)
    return math.max(1, math.floor(tonumber(value) or 1))
end

local function getProgressRatio(level, minLevel, maxLevel)
    local resolvedLevel = normalizeLevel(level)
    local resolvedMin = normalizeLevel(minLevel)
    local resolvedMax = normalizeLevel(maxLevel)
    if resolvedMax <= resolvedMin then
        return 1
    end
    return math.clamp((resolvedLevel - resolvedMin) / (resolvedMax - resolvedMin), 0, 1)
end

function ArenaProgressController:_getAvatarImage(userId)
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
                self:_render(self._latestPayload)
            end
        end
    end)

    return ""
end

function ArenaProgressController:_clearGenerated()
    for _, node in pairs(self._generatedByUserId) do
        if node and node.Parent then
            node:Destroy()
        end
    end
    table.clear(self._generatedByUserId)

    if self._progressRoot then
        for _, child in ipairs(self._progressRoot:GetChildren()) do
            if child:GetAttribute(GENERATED_ATTRIBUTE) == true then
                child:Destroy()
            end
        end
    end
end

function ArenaProgressController:_applyVisibilityFromState()
    if not self._progressRoot then
        return
    end

    local shouldShow = self._latestPlayerState
        and self._latestPlayerState.isInArena == true
        and self._latestPlayerState.alive == true
    self._progressRoot.Visible = shouldShow == true
end

function ArenaProgressController:_getOrCreatePlayerNode(userId)
    local node = self._generatedByUserId[userId]
    if node and node.Parent then
        return node
    end

    if not (self._template and self._template:IsA("ImageLabel")) then
        return nil
    end

    node = self._template:Clone()
    node.Name = PLAYER_NODE_PREFIX .. tostring(userId)
    node:SetAttribute(GENERATED_ATTRIBUTE, true)
    node.Visible = true
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Parent = self._progressRoot
    self._generatedByUserId[userId] = node
    return node
end

function ArenaProgressController:_render(payload)
    self._latestPayload = payload
    if not (self._progressRoot and self._template) then
        return
    end

    self._template.Visible = false
    local rows = payload and payload.players
    if type(rows) ~= "table" then
        self:_clearGenerated()
        self:_applyVisibilityFromState()
        return
    end

    local minLevel = tonumber(payload.minLevel) or 0
    local maxLevel = tonumber(payload.maxLevel) or 0
    local seenByUserId = {}

    for _, row in ipairs(rows) do
        local userId = tonumber(row.userId)
        if userId and userId > 0 then
            seenByUserId[userId] = true
            local level = normalizeLevel(row.level)
            local node = self:_getOrCreatePlayerNode(userId)
            if node then
                local ratio = getProgressRatio(level, minLevel, maxLevel)
                node.Position = UDim2.new(ratio, 0, 0.5, 0)
                node.Visible = true
                node.LayoutOrder = math.floor(ratio * 10000)
                setImage(node, self:_getAvatarImage(userId))
                setText(node, "LvInfo", string.format("Lv.%d", level))
            end
        end
    end

    for userId, node in pairs(self._generatedByUserId) do
        if not seenByUserId[userId] then
            if node and node.Parent then
                node:Destroy()
            end
            self._generatedByUserId[userId] = nil
        end
    end

    self:_applyVisibilityFromState()
end

function ArenaProgressController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._progressRoot = mainGui and mainGui:FindFirstChild("Progress", true) or nil
    if not (self._progressRoot and self._progressRoot:IsA("Frame")) then
        if not silent then
            warn("[ArenaProgressController] Missing PlayerGui/Main/Progress.")
        end
        return false
    end

    self._template = self._progressRoot:FindFirstChild("Playertemplate")
    if not (self._template and self._template:IsA("ImageLabel")) then
        if not silent then
            warn("[ArenaProgressController] Missing Progress/Playertemplate.")
        end
        return false
    end

    self._template.Visible = false
    self:_applyVisibilityFromState()
    if self._latestPayload then
        self:_render(self._latestPayload)
    end
    return true
end

function ArenaProgressController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    self._bindRetryQueued = true
    task.spawn(function()
        for _ = 1, 20 do
            task.wait(0.25)
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
        end
        self._bindRetryQueued = false
        self:_bindUi(false)
    end)
end

function ArenaProgressController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestPayload = nil
    self._latestPlayerState = nil
    self._generatedByUserId = {}
    self._avatarCacheByUserId = {}
    disconnectAll(self._connections)

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local battleEventsFolder = eventsRoot:WaitForChild(RemoteNames.BattleEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local arenaProgressSyncEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.ArenaProgressSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestPlayerState = payload
        self:_applyVisibilityFromState()
    end))

    table.insert(self._connections, arenaProgressSyncEvent.OnClientEvent:Connect(function(payload)
        self:_render(payload)
    end))
end

return ArenaProgressController
