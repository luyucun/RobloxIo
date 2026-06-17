--[[
Script: InviteTipsController
File: InviteTipsController.lua
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/InviteTipsController
Purpose: V5.2 automatic invite suggestion popup for online friends who played this experience.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

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
        "[InviteTipsController] Missing shared module %s",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local InviteTipsController = {}

InviteTipsController._localPlayer = nil
InviteTipsController._connections = {}
InviteTipsController._buttonConnections = {}
InviteTipsController._mainGui = nil
InviteTipsController._panel = nil
InviteTipsController._avatar = nil
InviteTipsController._statusLabel = nil
InviteTipsController._inviteButton = nil
InviteTipsController._inviteButtonLabel = nil
InviteTipsController._requestFriendsEvent = nil
InviteTipsController._friendsSyncEvent = nil
InviteTipsController._requestInviteTaskProgressEvent = nil
InviteTipsController._latestRows = {}
InviteTipsController._onlineByUserId = {}
InviteTipsController._shownByUserId = {}
InviteTipsController._avatarCacheByUserId = {}
InviteTipsController._avatarRequestPendingByUserId = {}
InviteTipsController._avatarFailedAtByUserId = {}
InviteTipsController._activeCandidate = nil
InviteTipsController._bindRetryQueued = false
InviteTipsController._scanSerial = 0
InviteTipsController._panelSerial = 0
InviteTipsController._isPanelOpen = false
InviteTipsController._isToastOpen = false
InviteTipsController._isRequestingRows = false
InviteTipsController._pendingScan = false
InviteTipsController._lastScanClock = 0
InviteTipsController._started = false

local FIRST_SCAN_DELAY_SECONDS = 120
local REPEAT_SCAN_SECONDS = 300
local AUTO_CLOSE_SECONDS = 5
local TOAST_SECONDS = 1.5
local AVATAR_RETRY_SECONDS = 30
local ROW_RESPONSE_TIMEOUT_SECONDS = 10
local BIND_RETRY_INTERVAL_SECONDS = 0.5
local BIND_RETRY_WARNING_SECONDS = 12

local OPEN_FROM_SCALE = 0.86
local OPEN_OVERSHOOT_SCALE = 1.05
local OPEN_OVERSHOOT_DURATION = 0.16
local OPEN_SETTLE_DURATION = 0.08
local CLOSE_TO_SCALE = 0.9
local CLOSE_DURATION = 0.12
local HOVER_SCALE = 1.06
local PRESS_SCALE = 0.92
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local DEFAULT_INVITE_TEXT = "Invite"
local STATUS_INVITE_OPENED = "Invite opened"
local STATUS_INVITE_UNAVAILABLE = "Unable to invite"
local STATUS_INVITE_FAILED = "Invite failed"

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

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value or "")
    end
end

local function setImage(imageObject, value)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(value or "")
    end
end

local function setGuiVisible(guiObject, visible)
    if guiObject and guiObject:IsA("GuiObject") then
        guiObject.Visible = visible == true
    end
end

local function normalizeUserId(value)
    local userId = math.floor(tonumber(value) or 0)
    if userId > 0 then
        return userId
    end
    return nil
end

local function cloneRows(rows)
    local result = {}
    if type(rows) ~= "table" then
        return result
    end

    for index, row in ipairs(rows) do
        local copy = {}
        if type(row) == "table" then
            for key, value in pairs(row) do
                copy[key] = value
            end
        end
        result[index] = copy
    end
    return result
end

function InviteTipsController:_cancelButtonMotion()
    disconnectAll(self._buttonConnections)
    if self._inviteButton then
        local uiScale = self._inviteButton:FindFirstChildOfClass("UIScale")
        if uiScale then
            uiScale.Scale = 1
        end
    end
end

function InviteTipsController:_bindButtonMotion()
    self:_cancelButtonMotion()
    local button = self._inviteButton
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local uiScale = ensureUiScale(button)
    if not uiScale then
        return
    end

    local isHovered = false
    local isPressed = false
    local currentTween = nil

    local function playScale(scale, tweenInfo)
        if currentTween then
            currentTween:Cancel()
            currentTween = nil
        end
        currentTween = TweenService:Create(uiScale, tweenInfo, {
            Scale = scale,
        })
        currentTween.Completed:Connect(function()
            if currentTween and math.abs(uiScale.Scale - scale) < 0.001 then
                currentTween = nil
            end
        end)
        currentTween:Play()
    end

    local function apply()
        if isPressed then
            playScale(PRESS_SCALE, PRESS_TWEEN_INFO)
        elseif isHovered then
            playScale(HOVER_SCALE, HOVER_TWEEN_INFO)
        else
            playScale(1, RESET_TWEEN_INFO)
        end
    end

    table.insert(self._buttonConnections, button.MouseEnter:Connect(function()
        isHovered = true
        apply()
    end))
    table.insert(self._buttonConnections, button.MouseLeave:Connect(function()
        isHovered = false
        isPressed = false
        apply()
    end))
    table.insert(self._buttonConnections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            isPressed = true
            apply()
        end
    end))
    table.insert(self._buttonConnections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            isPressed = false
            if inputType == Enum.UserInputType.Touch then
                isHovered = false
            end
            apply()
        end
    end))
    table.insert(self._buttonConnections, button.Activated:Connect(function()
        self:_handleInviteButton()
    end))
end

function InviteTipsController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local warningClock = os.clock() + BIND_RETRY_WARNING_SECONDS
        local warned = false
        while self._bindRetryQueued do
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end

            if not warned and os.clock() >= warningClock then
                warned = true
                warn("[InviteTipsController] Could not find PlayerGui/Main/InviteTips yet; waiting for UI.")
            end

            task.wait(BIND_RETRY_INTERVAL_SECONDS)
        end
    end)
end

function InviteTipsController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("InviteTips") or nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self._avatar = self._panel:FindFirstChild("Avatar")
    self._statusLabel = findNested(self._panel, "Status/Label")
    self._inviteButton = self._panel:FindFirstChild("InviteButton")
    self._inviteButtonLabel = self._inviteButton and self._inviteButton:FindFirstChild("Label", true) or nil

    if not (self._inviteButton and self._inviteButton:IsA("GuiButton")) then
        if not silent then
            warn("[InviteTipsController] Missing InviteTips.InviteButton.")
        end
        return false
    end

    self._panel.Visible = self._isPanelOpen == true or self._isToastOpen == true
    ensureUiScale(self._panel)
    self:_bindButtonMotion()
    return true
end

function InviteTipsController:_nextPanelSerial()
    self._panelSerial += 1
    return self._panelSerial
end

function InviteTipsController:_closePanel(immediate)
    self._isPanelOpen = false
    self._activeCandidate = nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return
    end

    local serial = self:_nextPanelSerial()
    local uiScale = ensureUiScale(self._panel)
    if immediate == true or not uiScale or self._panel.Visible ~= true then
        if uiScale then
            uiScale.Scale = 1
        end
        if not self._isToastOpen then
            self._panel.Visible = false
        end
        return
    end

    local tween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    task.spawn(function()
        tween:Play()
        tween.Completed:Wait()
        if self._panelSerial ~= serial or self._isPanelOpen or self._isToastOpen then
            return
        end
        if uiScale.Parent then
            uiScale.Scale = 1
        end
        if self._panel and self._panel.Parent then
            self._panel.Visible = false
        end
    end)
end

function InviteTipsController:_showToast(message)
    if not self:_bindUi(true) then
        self:_queueBindRetry()
        return
    end

    self._isPanelOpen = false
    self._isToastOpen = true
    self._activeCandidate = nil
    local serial = self:_nextPanelSerial()
    setText(self._statusLabel, message)
    setText(self._inviteButtonLabel, "")
    setGuiVisible(self._avatar, false)
    setGuiVisible(self._inviteButton, false)
    self._panel.Visible = true

    local uiScale = ensureUiScale(self._panel)
    if uiScale then
        uiScale.Scale = OPEN_FROM_SCALE
        local openTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = 1,
        })
        openTween:Play()
    end

    task.delay(TOAST_SECONDS, function()
        if self._panelSerial ~= serial then
            return
        end
        self._isToastOpen = false
        self:_closePanel(false)
    end)
end

function InviteTipsController:_getAvatarImage(userId)
    userId = normalizeUserId(userId)
    if not userId then
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
            if self._activeCandidate and self._activeCandidate.userId == userId and self._avatar then
                setImage(self._avatar, image)
            end
        else
            self._avatarFailedAtByUserId[userId] = os.clock()
        end
    end)

    return ""
end

function InviteTipsController:_showCandidate(candidate)
    if type(candidate) ~= "table" or not candidate.userId then
        return false
    end
    if not self:_bindUi(true) then
        self:_queueBindRetry()
        return false
    end

    self._activeCandidate = candidate
    self._isPanelOpen = true
    self._isToastOpen = false
    local serial = self:_nextPanelSerial()
    local uiScale = ensureUiScale(self._panel)

    setGuiVisible(self._avatar, true)
    setGuiVisible(self._inviteButton, true)
    setText(self._statusLabel, tostring(candidate.name or "Friend"))
    setText(self._inviteButtonLabel, DEFAULT_INVITE_TEXT)
    setImage(self._avatar, self:_getAvatarImage(candidate.userId))

    self._panel.Visible = true
    if not uiScale then
        return true
    end

    uiScale.Scale = OPEN_FROM_SCALE
    local overshootTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Scale = OPEN_OVERSHOOT_SCALE,
    })
    local settleTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = 1,
    })

    task.spawn(function()
        overshootTween:Play()
        overshootTween.Completed:Wait()
        if self._panelSerial ~= serial or not self._isPanelOpen then
            return
        end
        settleTween:Play()
    end)

    task.delay(AUTO_CLOSE_SECONDS, function()
        if self._panelSerial ~= serial or not self._isPanelOpen then
            return
        end
        self:_closePanel(false)
    end)

    return true
end

function InviteTipsController:_refreshOnlineFriends()
    table.clear(self._onlineByUserId)
    if not self._localPlayer then
        return
    end

    local success, onlineFriends = pcall(function()
        return self._localPlayer:GetFriendsOnlineAsync(200)
    end)
    if not (success and type(onlineFriends) == "table") then
        return
    end

    for _, friendInfo in ipairs(onlineFriends) do
        local userId = normalizeUserId(friendInfo.VisitorId or friendInfo.UserId or friendInfo.userId)
        if userId and friendInfo.IsOnline ~= false then
            self._onlineByUserId[userId] = true
        end
    end
end

function InviteTipsController:_selectCandidate()
    local best = nil
    for _, row in ipairs(self._latestRows or {}) do
        if type(row) == "table" then
            local userId = normalizeUserId(row.userId or row.UserId)
            if userId and self._onlineByUserId[userId] == true and self._shownByUserId[userId] ~= true then
                local candidate = {
                    userId = userId,
                    name = tostring(row.name or row.Name or "Friend"),
                    highestLevelReached = math.max(1, math.floor(tonumber(row.highestLevelReached or row.HighestLevelReached) or 1)),
                }
                if not best
                    or candidate.highestLevelReached > best.highestLevelReached
                    or (candidate.highestLevelReached == best.highestLevelReached and candidate.name < best.name)
                then
                    best = candidate
                end
            end
        end
    end
    return best
end

function InviteTipsController:_evaluateAndShow()
    self:_refreshOnlineFriends()
    local candidate = self:_selectCandidate()
    if not candidate then
        return
    end

    if self:_showCandidate(candidate) then
        self._shownByUserId[candidate.userId] = true
    end
end

function InviteTipsController:_showStudioTestCandidate(payload)
    if not RunService:IsStudio() then
        return false
    end

    local rows = payload and payload.rows
    local row = type(rows) == "table" and rows[1] or nil
    if type(row) ~= "table" then
        return false
    end

    local userId = normalizeUserId(row.userId or row.UserId)
    if not userId then
        return false
    end

    return self:_showCandidate({
        userId = userId,
        name = tostring(row.name or row.Name or "Friend"),
        highestLevelReached = math.max(1, math.floor(tonumber(row.highestLevelReached or row.HighestLevelReached) or 1)),
    })
end

function InviteTipsController:_requestFriendRowsForScan()
    if self._isRequestingRows then
        self._pendingScan = true
        return
    end
    if not self._requestFriendsEvent then
        self:_evaluateAndShow()
        return
    end

    self._isRequestingRows = true
    self._pendingScan = true
    self._requestFriendsEvent:FireServer()
    local serial = self._scanSerial
    task.delay(ROW_RESPONSE_TIMEOUT_SECONDS, function()
        if self._scanSerial ~= serial or not self._isRequestingRows then
            return
        end
        self._isRequestingRows = false
        if self._pendingScan then
            self._pendingScan = false
            self:_evaluateAndShow()
        end
    end)
end

function InviteTipsController:_runScan()
    self._scanSerial += 1
    self._lastScanClock = os.clock()
    self:_requestFriendRowsForScan()
end

function InviteTipsController:_startScanLoop()
    if self._started then
        return
    end
    self._started = true

    task.spawn(function()
        task.wait(FIRST_SCAN_DELAY_SECONDS)
        while self._localPlayer and self._localPlayer.Parent do
            self:_runScan()
            task.wait(REPEAT_SCAN_SECONDS)
        end
    end)
end

function InviteTipsController:_handleFriendsSync(payload)
    if payload and payload.throttled == true then
        self._isRequestingRows = false
        return
    end

    if payload and payload.studioInviteTipsTest == true and self:_showStudioTestCandidate(payload) then
        self._isRequestingRows = false
        self._pendingScan = false
        return
    end

    self._latestRows = cloneRows(payload and payload.rows)
    self._isRequestingRows = false
    if self._pendingScan then
        self._pendingScan = false
        self:_evaluateAndShow()
    end
end

function InviteTipsController:_promptTargetedInvite(candidate)
    if not (self._localPlayer and candidate and candidate.userId) then
        self:_showToast(STATUS_INVITE_FAILED)
        return
    end

    task.spawn(function()
        local userId = math.floor(tonumber(candidate.userId) or 0)
        local ok, canInvite = pcall(function()
            return SocialService:CanSendGameInviteAsync(self._localPlayer, userId)
        end)
        if ok and canInvite ~= true then
            self:_showToast(STATUS_INVITE_UNAVAILABLE)
            return
        end

        local promptOk = pcall(function()
            local inviteOptions = Instance.new("ExperienceInviteOptions")
            inviteOptions.InviteUser = userId
            inviteOptions.PromptMessage = "Invite this friend to join!"
            SocialService:PromptGameInvite(self._localPlayer, inviteOptions)
        end)

        if promptOk and self._requestInviteTaskProgressEvent then
            self._requestInviteTaskProgressEvent:FireServer()
        end
        self:_showToast(promptOk and STATUS_INVITE_OPENED or STATUS_INVITE_FAILED)
    end)
end

function InviteTipsController:_handleInviteButton()
    local candidate = self._activeCandidate
    self:_closePanel(true)
    self:_promptTargetedInvite(candidate)
end

function InviteTipsController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestRows = {}
    self._onlineByUserId = {}
    self._shownByUserId = {}
    self._avatarCacheByUserId = {}
    self._avatarRequestPendingByUserId = {}
    self._avatarFailedAtByUserId = {}
    self._activeCandidate = nil
    self._isPanelOpen = false
    self._isToastOpen = false
    self._isRequestingRows = false
    self._pendingScan = false
    self._started = false
    disconnectAll(self._connections)
    self:_cancelButtonMotion()

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    self._requestFriendsEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestFriendsRankingStateSync)
    self._friendsSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.FriendsRankingStateSync)
    self._requestInviteTaskProgressEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestInviteTaskProgress, 10)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, self._friendsSyncEvent.OnClientEvent:Connect(function(payload)
        self:_handleFriendsSync(payload)
    end))

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    if not self:_bindUi(true) then
                        self:_queueBindRetry()
                    end
                end)
            end
        end))
    end

    self:_startScanLoop()
end

return InviteTipsController
