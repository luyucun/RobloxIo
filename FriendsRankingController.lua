--[[
脚本名字: FriendsRankingController
脚本文件: FriendsRankingController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/FriendsRankingController
说明: 绑定好友榜入口、邀请按钮、页签切换，并渲染 StarterGui/Main/FriendsRanking。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
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
        "[FriendsRankingController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local FriendsRankingController = {}

FriendsRankingController._localPlayer = nil
FriendsRankingController._connections = {}
FriendsRankingController._rowConnections = {}
FriendsRankingController._buttonBindings = {}
FriendsRankingController._mainGui = nil
FriendsRankingController._panel = nil
FriendsRankingController._entryButton = nil
FriendsRankingController._closeButton = nil
FriendsRankingController._inviteButton = nil
FriendsRankingController._topSummary = nil
FriendsRankingController._tabs = nil
FriendsRankingController._listFrame = nil
FriendsRankingController._requestEvent = nil
FriendsRankingController._syncEvent = nil
FriendsRankingController._latestRows = {}
FriendsRankingController._latestPlayerState = nil
FriendsRankingController._onlineByUserId = {}
FriendsRankingController._avatarCacheByUserId = {}
FriendsRankingController._avatarRequestPendingByUserId = {}
FriendsRankingController._avatarFailedAtByUserId = {}
FriendsRankingController._selectedTab = "BestLevel"
FriendsRankingController._bindRetryQueued = false
FriendsRankingController._renderQueued = false
FriendsRankingController._prefetchQueued = false
FriendsRankingController._prefetchCompleted = false
FriendsRankingController._isOpen = false
FriendsRankingController._panelTweens = {}
FriendsRankingController._panelAnimationSerial = 0

local GENERATED_ROW_ATTRIBUTE = "GeneratedFriendsRankingRow"
local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.18
local OPEN_SETTLE_DURATION = 0.12
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local AVATAR_RETRY_SECONDS = 30
local AVATAR_RENDER_DEBOUNCE_SECONDS = 0.25
local SELECTED_TAB_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local UNSELECTED_TAB_TEXT_COLOR = Color3.fromRGB(55, 65, 81)
local ONLINE_DOT_COLOR = Color3.fromRGB(72, 190, 72)
local ONLINE_STROKE_COLOR = Color3.fromRGB(119, 200, 95)
local ONLINE_TEXT_COLOR = Color3.fromRGB(52, 142, 52)
local OFFLINE_DOT_COLOR = Color3.fromRGB(140, 150, 165)
local OFFLINE_STROKE_COLOR = Color3.fromRGB(180, 188, 199)
local OFFLINE_TEXT_COLOR = Color3.fromRGB(87, 97, 110)

local TAB_DEFINITIONS = {
    BestLevel = {
        buttonName = "BestLevelTab",
        metric = "bestLevel",
    },
    Collection = {
        buttonName = "CollectionTab",
        metric = "totalPlayerKills",
    },
    Playtime = {
        buttonName = "PlaytimeTab",
        metric = "playtime",
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

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end
    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function findNested(root, path)
    local current = root
    for segment in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    return current
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

local function setTextColor(container, childName, color)
    local node = container and container:FindFirstChild(childName, true)
    if node and (node:IsA("TextLabel") or node:IsA("TextButton") or node:IsA("TextBox")) then
        node.TextColor3 = color
    end
end

local function playTween(binding, tweenKey, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existingTween = binding.tweens[tweenKey]
    if existingTween then
        existingTween:Cancel()
        binding.tweens[tweenKey] = nil
    end

    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[tweenKey] = tween
    tween.Completed:Connect(function()
        if binding.tweens[tweenKey] == tween then
            binding.tweens[tweenKey] = nil
        end
    end)
    tween:Play()
end

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function formatPlaytime(seconds)
    local totalMinutes = math.max(0, math.floor((tonumber(seconds) or 0) / 60))
    local days = math.floor(totalMinutes / 1440)
    local hours = math.floor((totalMinutes % 1440) / 60)
    local minutes = totalMinutes % 60
    return string.format("%dd:%02d:%02d", days, hours, minutes)
end

local function getValueForMetric(row, metricKey)
    if metricKey == "totalPlayerKills" then
        return tonumber(row.totalPlayerKills) or 0
    elseif metricKey == "playtime" then
        return tonumber(row.playtimeSeconds) or 0
    end
    return tonumber(row.highestLevelReached) or 1
end

function FriendsRankingController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function FriendsRankingController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function FriendsRankingController:_getAvatarImage(userId)
    userId = math.floor(tonumber(userId) or 0)
    if userId <= 0 then
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

function FriendsRankingController:_queueRenderRows()
    if self._renderQueued then
        return
    end
    self._renderQueued = true
    task.delay(AVATAR_RENDER_DEBOUNCE_SECONDS, function()
        self._renderQueued = false
        self:_renderRows()
    end)
end

function FriendsRankingController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    if self._buttonBindings[button] then
        disconnectAll(self._buttonBindings[button].connections)
        self._buttonBindings[button] = nil
    end

    button.Active = true
    local target = options and options.target or button
    local uiScale = ensureUiScale(target)
    if not uiScale then
        return
    end

    local binding = {
        connections = {},
        tweens = {},
        uiScale = uiScale,
        rotationTarget = options and options.rotationTarget or nil,
        baseScale = uiScale.Scale,
        baseRotation = options and options.rotationTarget and options.rotationTarget.Rotation or 0,
        hoverScale = options and options.hoverScale or HOVER_SCALE,
        pressScale = options and options.pressScale or PRESS_SCALE,
        hoverRotation = options and options.hoverRotation or 0,
        isHovered = false,
        isPressed = false,
    }
    self._buttonBindings[button] = binding

    local function applyButtonState()
        local scale = binding.baseScale
        local rotation = binding.baseRotation
        local tweenInfo = RESET_TWEEN_INFO
        if binding.isPressed then
            scale = binding.baseScale * binding.pressScale
            tweenInfo = PRESS_TWEEN_INFO
        elseif binding.isHovered then
            scale = binding.baseScale * binding.hoverScale
            rotation = binding.baseRotation + binding.hoverRotation
            tweenInfo = HOVER_TWEEN_INFO
        end

        playTween(binding, "Scale", binding.uiScale, tweenInfo, {
            Scale = scale,
        })
        if binding.rotationTarget then
            playTween(binding, "Rotation", binding.rotationTarget, tweenInfo, {
                Rotation = rotation,
            })
        end
    end

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        applyButtonState()
    end))
    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        applyButtonState()
    end))
    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            applyButtonState()
        end
    end))
    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            applyButtonState()
        end
    end))
    table.insert(binding.connections, button.Activated:Connect(function()
        if onActivated then
            onActivated()
        end
    end))
end

function FriendsRankingController:_setOpen(isOpen, immediate)
    if not self._panel then
        self._isOpen = false
        return
    end

    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isOpen = isOpen == true
    local rootScale = ensureUiScale(self._panel)
    if self._isOpen then
        ModalUiController:Acquire("FriendsRanking", self._panel)
        self._panel.Visible = true
        self._selectedTab = "BestLevel"
        self:_applyTabs()
        self:_refreshOnlineFriends()
        self:_requestFriendsRanking()
        if rootScale then
            rootScale.Scale = OPEN_FROM_SCALE
            local overshoot = TweenService:Create(rootScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                Scale = OPEN_OVERSHOOT_SCALE,
            })
            local settle = TweenService:Create(rootScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Scale = 1,
            })
            self._panelTweens = { overshoot, settle }
            task.spawn(function()
                overshoot:Play()
                overshoot.Completed:Wait()
                if self._panelAnimationSerial ~= animationSerial or not self._isOpen then
                    return
                end
                settle:Play()
                settle.Completed:Wait()
                if self._panelAnimationSerial == animationSerial and self._isOpen then
                    rootScale.Scale = 1
                    table.clear(self._panelTweens)
                end
            end)
        end
        return
    end

    if not rootScale or immediate == true or not self._panel.Visible then
        if rootScale then
            rootScale.Scale = 1
        end
        self._panel.Visible = false
        ModalUiController:Release("FriendsRanking")
        return
    end

    local overshoot = TweenService:Create(rootScale, TweenInfo.new(CLOSE_OVERSHOOT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = CLOSE_OVERSHOOT_SCALE,
    })
    local shrink = TweenService:Create(rootScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { overshoot, shrink }
    task.spawn(function()
        overshoot:Play()
        overshoot.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isOpen then
            return
        end
        shrink:Play()
        shrink.Completed:Wait()
        if self._panelAnimationSerial == animationSerial and not self._isOpen then
            rootScale.Scale = 1
            self._panel.Visible = false
            ModalUiController:Release("FriendsRanking")
            table.clear(self._panelTweens)
        end
    end)
end

function FriendsRankingController:_promptGameInvite()
    if not self._localPlayer then
        return
    end

    task.spawn(function()
        local ok, canInvite = pcall(function()
            return SocialService:CanSendGameInviteAsync(self._localPlayer)
        end)
        if ok and canInvite ~= true then
            return
        end

        pcall(function()
            SocialService:PromptGameInvite(self._localPlayer)
        end)
    end)
end

function FriendsRankingController:_refreshOnlineFriends()
    table.clear(self._onlineByUserId)
    if not self._localPlayer then
        return
    end

    task.spawn(function()
        local success, onlineFriends = pcall(function()
            return self._localPlayer:GetFriendsOnlineAsync(200)
        end)
        if success and type(onlineFriends) == "table" then
            for _, friendInfo in ipairs(onlineFriends) do
                local userId = tonumber(friendInfo.VisitorId or friendInfo.UserId or friendInfo.userId)
                if userId and userId > 0 and friendInfo.IsOnline ~= false then
                    self._onlineByUserId[math.floor(userId)] = true
                end
            end
            self:_renderRows()
        end
    end)
end

function FriendsRankingController:_requestFriendsRanking()
    if not self._requestEvent then
        return
    end

    self._requestEvent:FireServer()
end

function FriendsRankingController:_prefetchFriendsRanking()
    if self._prefetchQueued or self._prefetchCompleted or not self._requestEvent then
        return
    end

    self._prefetchQueued = true
    task.delay(4, function()
        self._prefetchQueued = false
        if self._prefetchCompleted or not self._requestEvent then
            return
        end
        self:_refreshOnlineFriends()
        self._requestEvent:FireServer()
    end)
end

function FriendsRankingController:_applyTabs()
    if not self._tabs then
        return
    end

    for key, definition in pairs(TAB_DEFINITIONS) do
        local tab = self._tabs:FindFirstChild(definition.buttonName)
        if tab and tab:IsA("GuiButton") then
            local selected = key == self._selectedTab
            local gradient = tab:FindFirstChild("UIGradient")
            if gradient and gradient:IsA("UIGradient") then
                gradient.Enabled = selected
            end
            setTextColor(tab, "Label", selected and SELECTED_TAB_TEXT_COLOR or UNSELECTED_TAB_TEXT_COLOR)
        end
    end
end

function FriendsRankingController:_applyTopSummary(payload)
    if not self._topSummary then
        return
    end

    local selfPayload = payload and payload.self or {}
    local highestLevelReached = tonumber(selfPayload.highestLevelReached)
        or tonumber(self._latestPlayerState and (self._latestPlayerState.highestLevelReached or self._latestPlayerState.level))
        or 1
    local totalPlayerKills = tonumber(selfPayload.totalPlayerKills or (self._latestPlayerState and self._latestPlayerState.totalPlayerKills)) or 0
    local friendBonusPercent = math.max(
        0,
        math.floor(tonumber(selfPayload.friendBonusPercent or (self._latestPlayerState and self._latestPlayerState.friendBonusPercent)) or 0)
    )

    setImage(self._topSummary, "Avatar", self:_getAvatarImage(self._localPlayer and self._localPlayer.UserId or 0))
    setText(findNested(self._topSummary, "YouBlock"), "Label", "You")
    setText(findNested(self._topSummary, "BestLevelBlock"), "Value", "Lv." .. formatInteger(highestLevelReached))
    setText(findNested(self._topSummary, "CollectionBlock"), "Value", formatInteger(totalPlayerKills))
    setText(findNested(self._topSummary, "FriendBonusBlock"), "Value", "+" .. formatInteger(friendBonusPercent) .. "%")
end

function FriendsRankingController:_clearGeneratedRows()
    if not self._listFrame then
        return
    end

    for _, child in ipairs(self._listFrame:GetChildren()) do
        if child:GetAttribute(GENERATED_ROW_ATTRIBUTE) == true then
            child:Destroy()
        elseif child:IsA("GuiObject") and string.match(child.Name, "^Rank%d%d$") then
            child.Visible = false
        end
    end

    local template = self._listFrame:FindFirstChild("RankTemplate")
    if template and template:IsA("GuiObject") then
        template.Visible = false
    end
end

function FriendsRankingController:_setStatus(row, userId)
    local status = row and row:FindFirstChild("Status", true)
    if not (status and status:IsA("GuiObject")) then
        return
    end

    local isOnline = self._onlineByUserId[math.floor(tonumber(userId) or 0)] == true
    local dot = status:FindFirstChild("Dot")
    if dot and dot:IsA("GuiObject") then
        dot.BackgroundColor3 = isOnline and ONLINE_DOT_COLOR or OFFLINE_DOT_COLOR
    end
    local stroke = status:FindFirstChildOfClass("UIStroke")
    if stroke then
        stroke.Color = isOnline and ONLINE_STROKE_COLOR or OFFLINE_STROKE_COLOR
    end
    setText(status, "Label", isOnline and "Online" or "Offline")
    setTextColor(status, "Label", isOnline and ONLINE_TEXT_COLOR or OFFLINE_TEXT_COLOR)
end

function FriendsRankingController:_formatRowInfo(rowData)
    if self._selectedTab == "Collection" then
        return formatInteger(rowData.totalPlayerKills)
    elseif self._selectedTab == "Playtime" then
        return formatPlaytime(rowData.playtimeSeconds)
    end
    return "Lv." .. formatInteger(rowData.highestLevelReached)
end

function FriendsRankingController:_applyRow(row, rowData, rank)
    if not (row and row:IsA("GuiObject")) then
        return
    end

    row.Visible = true
    row.LayoutOrder = rank
    setText(row, "Rank", tostring(rank))
    setText(row, "Name", tostring(rowData.name or rowData.userId or "Unknown"))
    setText(row, "Info", self:_formatRowInfo(rowData))
    setImage(row, "Avatar", self:_getAvatarImage(rowData.userId))
    self:_setStatus(row, rowData.userId)
end

function FriendsRankingController:_getSortedRows()
    local rows = {}
    for _, row in ipairs(self._latestRows or {}) do
        table.insert(rows, row)
    end

    local metricKey = TAB_DEFINITIONS[self._selectedTab] and TAB_DEFINITIONS[self._selectedTab].metric or "bestLevel"
    table.sort(rows, function(left, right)
        local leftValue = getValueForMetric(left, metricKey)
        local rightValue = getValueForMetric(right, metricKey)
        if leftValue == rightValue then
            return tostring(left.name or "") < tostring(right.name or "")
        end
        return leftValue > rightValue
    end)
    return rows
end

function FriendsRankingController:_renderRows()
    if not self._listFrame then
        return
    end

    self:_clearGeneratedRows()
    local rows = self:_getSortedRows()
    local template = self._listFrame:FindFirstChild("RankTemplate")
    for rank, rowData in ipairs(rows) do
        local row = self._listFrame:FindFirstChild(string.format("Rank%02d", rank))
        if rank >= 4 then
            row = template and template:IsA("GuiObject") and template:Clone() or nil
            if row then
                row.Name = string.format("Rank%02dGenerated", rank)
                row:SetAttribute(GENERATED_ROW_ATTRIBUTE, true)
                row.Parent = self._listFrame
            end
        end
        if row then
            self:_applyRow(row, rowData, rank)
        end
    end

    local listLayout = self._listFrame:FindFirstChildOfClass("UIListLayout")
    if listLayout then
        self._listFrame.CanvasSize = UDim2.fromOffset(0, listLayout.AbsoluteContentSize.Y)
    end
end

function FriendsRankingController:_queueBindRetry()
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
        warn("[FriendsRankingController] Could not find PlayerGui/Main/FriendsRanking.")
    end)
end

function FriendsRankingController:_bindTabs()
    if not self._tabs then
        return
    end

    for key, definition in pairs(TAB_DEFINITIONS) do
        local tab = self._tabs:FindFirstChild(definition.buttonName)
        if tab and tab:IsA("GuiButton") then
            self:_bindButton(tab, function()
                self._selectedTab = key
                self:_applyTabs()
                self:_renderRows()
            end)
        end
    end
    self:_applyTabs()
end

function FriendsRankingController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("FriendsRanking") or nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    local right = mainGui:FindFirstChild("Right")
    local friendsEntry = right and right:FindFirstChild("Friends")
    self._entryButton = friendsEntry and friendsEntry:FindFirstChild("TextButton", true) or nil
    self._closeButton = findNested(self._panel, "Title/CloseButton")
    self._inviteButton = findNested(self._panel, "FriendsRankinginfo/InviteButton")
    self._topSummary = findNested(self._panel, "FriendsRankinginfo/TopSummary")
    self._tabs = findNested(self._panel, "FriendsRankinginfo/Tabs")
    self._listFrame = findNested(self._panel, "FriendsRankinginfo/ListFrame")
    if not (self._listFrame and self._listFrame:IsA("ScrollingFrame")) then
        if not silent then
            warn("[FriendsRankingController] Missing FriendsRanking/FriendsRankinginfo/ListFrame.")
        end
        return false
    end

    self._panel.Visible = self._isOpen == true
    self:_bindButton(self._entryButton, function()
        self:_setOpen(true)
    end, {
        target = friendsEntry,
        rotationTarget = friendsEntry and friendsEntry:FindFirstChild("Icon", true) or nil,
        hoverScale = ENTRY_HOVER_SCALE,
        pressScale = ENTRY_PRESS_SCALE,
        hoverRotation = HOVER_ROTATION,
    })
    self:_bindButton(self._closeButton, function()
        self:_setOpen(false)
    end, {
        hoverRotation = HOVER_ROTATION,
    })
    self:_bindButton(self._inviteButton, function()
        self:_promptGameInvite()
    end)
    self:_bindTabs()
    self:_applyTopSummary()
    self:_renderRows()
    return true
end

function FriendsRankingController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestRows = {}
    self._latestPlayerState = nil
    self._onlineByUserId = {}
    self._selectedTab = "BestLevel"
    self._avatarCacheByUserId = {}
    self._avatarRequestPendingByUserId = {}
    self._avatarFailedAtByUserId = {}
    self._renderQueued = false
    self._prefetchQueued = false
    self._prefetchCompleted = false
    self._isOpen = false
    disconnectAll(self._connections)
    disconnectAll(self._rowConnections)

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    self._requestEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestFriendsRankingStateSync)
    self._syncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.FriendsRankingStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestPlayerState = payload
        self:_applyTopSummary()
    end))

    table.insert(self._connections, self._syncEvent.OnClientEvent:Connect(function(payload)
        if not (payload and payload.throttled == true) then
            self._latestRows = type(payload and payload.rows) == "table" and payload.rows or {}
            self._prefetchCompleted = true
        end
        self:_applyTopSummary(payload)
        self:_renderRows()
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

    self:_prefetchFriendsRanking()
end

return FriendsRankingController
