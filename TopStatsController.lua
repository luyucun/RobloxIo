--[[
脚本名字: TopStatsController
脚本文件: TopStatsController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/TopStatsController
说明: 同步顶部钻石数与永久击杀数，并播放钻石获得表现。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
        "[TopStatsController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local TopStatsController = {}

TopStatsController._localPlayer = nil
TopStatsController._connections = {}
TopStatsController._mainGui = nil
TopStatsController._topRoot = nil
TopStatsController._gemLabel = nil
TopStatsController._killLabel = nil
TopStatsController._gemIcon = nil
TopStatsController._latestDiamonds = nil
TopStatsController._latestTotalKills = nil
TopStatsController._numberTweensByLabel = {}
TopStatsController._bindRetryQueued = false
TopStatsController._effectsFolder = nil
TopStatsController._latestPayload = nil

local GEM_IMAGE = "rbxassetid://89590364394067"
local NUMBER_TWEEN_SECONDS = 0.35
local ICON_POP_SCALE = 1.18
local UI_BIND_RETRY_COUNT = 80
local UI_BIND_RETRY_INTERVAL_SECONDS = 0.25

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

local function findTextLabel(root, path)
    local current = root
    for segment in string.gmatch(path, "[^/]+") do
        current = current and current:FindFirstChild(segment)
    end
    if current and current:IsA("TextLabel") then
        return current
    end
    return nil
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

local function formatInteger(value)
    return tostring(math.max(0, math.floor(tonumber(value) or 0)))
end

local function getGuiCenter(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local position = guiObject.AbsolutePosition
    local size = guiObject.AbsoluteSize
    return position + (size * 0.5)
end

function TopStatsController:_ensureEffectsFolder()
    if self._effectsFolder and self._effectsFolder.Parent then
        return self._effectsFolder
    end
    if not self._mainGui then
        return nil
    end

    local folder = self._mainGui:FindFirstChild("TopStatEffects")
    if folder and not folder:IsA("Frame") then
        folder:Destroy()
        folder = nil
    end
    if not folder then
        folder = Instance.new("Frame")
        folder.Name = "TopStatEffects"
        folder.BackgroundTransparency = 1
        folder.BorderSizePixel = 0
        folder.Position = UDim2.fromScale(0, 0)
        folder.Size = UDim2.fromScale(1, 1)
        folder.ZIndex = 1000
        folder.Parent = self._mainGui
    end
    self._effectsFolder = folder
    return folder
end

function TopStatsController:_setNumber(label, fromValue, toValue, animate)
    if not label then
        return
    end

    local startValue = math.max(0, math.floor(tonumber(fromValue) or tonumber(label.Text) or 0))
    local endValue = math.max(0, math.floor(tonumber(toValue) or 0))
    if self._numberTweensByLabel[label] then
        self._numberTweensByLabel[label]:Cancel()
        self._numberTweensByLabel[label] = nil
    end

    if not animate or startValue == endValue then
        label.Text = formatInteger(endValue)
        return
    end

    local driver = Instance.new("NumberValue")
    driver.Value = startValue
    local changedConnection = driver:GetPropertyChangedSignal("Value"):Connect(function()
        label.Text = formatInteger(driver.Value)
    end)
    local tween = TweenService:Create(driver, TweenInfo.new(NUMBER_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Value = endValue,
    })
    self._numberTweensByLabel[label] = tween
    tween.Completed:Connect(function()
        local isCurrentTween = self._numberTweensByLabel[label] == tween
        if isCurrentTween then
            self._numberTweensByLabel[label] = nil
        end
        changedConnection:Disconnect()
        driver:Destroy()
        if isCurrentTween then
            label.Text = formatInteger(endValue)
        end
    end)
    tween:Play()
end

function TopStatsController:_popGemIcon()
    local uiScale = ensureUiScale(self._gemIcon)
    if not uiScale then
        return
    end

    local popTween = TweenService:Create(uiScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = ICON_POP_SCALE,
    })
    local settleTween = TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Scale = 1,
    })
    popTween.Completed:Connect(function()
        settleTween:Play()
    end)
    popTween:Play()
end

function TopStatsController:_spawnGemFlyIcon(startPosition, targetPosition, index)
    local folder = self:_ensureEffectsFolder()
    if not folder then
        return
    end

    local icon = Instance.new("ImageLabel")
    icon.Name = "GemFlyIcon"
    icon.AnchorPoint = Vector2.new(0.5, 0.5)
    icon.BackgroundTransparency = 1
    icon.Image = GEM_IMAGE
    icon.ImageTransparency = 0
    icon.Size = UDim2.fromOffset(34, 34)
    icon.Position = UDim2.fromOffset(startPosition.X, startPosition.Y)
    icon.ZIndex = 1000
    icon.Parent = folder

    local angle = ((index - 1) / 5) * math.pi * 2
    local radius = 34 + (index % 2) * 14
    local spreadPosition = startPosition + Vector2.new(math.cos(angle) * radius, math.sin(angle) * radius)
    local spreadTween = TweenService:Create(icon, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromOffset(spreadPosition.X, spreadPosition.Y),
        Size = UDim2.fromOffset(40, 40),
    })
    local flyTween = TweenService:Create(icon, TweenInfo.new(0.45 + (index * 0.03), Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
        Position = UDim2.fromOffset(targetPosition.X, targetPosition.Y),
        Size = UDim2.fromOffset(22, 22),
        ImageTransparency = 0.1,
    })
    spreadTween.Completed:Connect(function()
        flyTween:Play()
    end)
    flyTween.Completed:Connect(function()
        self:_popGemIcon()
        if icon and icon.Parent then
            icon:Destroy()
        end
    end)
    spreadTween:Play()
end

function TopStatsController:_playGemGainAnimation()
    local effectsLayer = self:_ensureEffectsFolder()
    local targetPosition = getGuiCenter(self._gemIcon)
    if not (effectsLayer and targetPosition) then
        return
    end

    targetPosition = targetPosition - effectsLayer.AbsolutePosition
    local startPosition = effectsLayer.AbsoluteSize * 0.5
    local count = math.random(3, 5)
    for index = 1, count do
        task.delay((index - 1) * 0.035, function()
            self:_spawnGemFlyIcon(startPosition, targetPosition, index)
        end)
    end
end

function TopStatsController:_applyState(payload)
    local diamonds = math.max(0, math.floor(tonumber(payload and payload.diamonds) or 0))
    local totalKills = math.max(0, math.floor(tonumber(payload and payload.totalPlayerKills) or 0))
    local hadPreviousState = self._latestDiamonds ~= nil
    local gainedDiamonds = hadPreviousState and diamonds > self._latestDiamonds

    self:_setNumber(self._gemLabel, self._latestDiamonds or diamonds, diamonds, hadPreviousState)
    self:_setNumber(self._killLabel, self._latestTotalKills or totalKills, totalKills, self._latestTotalKills ~= nil)

    if gainedDiamonds then
        self:_playGemGainAnimation()
    end

    self._latestDiamonds = diamonds
    self._latestTotalKills = totalKills
end

function TopStatsController:_bindUi(silent)
    self._mainGui = findMainGui(self._localPlayer)
    self._topRoot = self._mainGui and self._mainGui:FindFirstChild("Top")
    if not self._topRoot then
        if not silent then
            warn("[TopStatsController] Missing PlayerGui/Main/Top.")
        end
        return false
    end

    self._gemLabel = findTextLabel(self._topRoot, "Gem/Num1")
    self._killLabel = findTextLabel(self._topRoot, "Kill/Num1")
    local gemFrame = self._topRoot:FindFirstChild("Gem")
    self._gemIcon = gemFrame and gemFrame:FindFirstChild("Icon")

    if not (self._gemLabel and self._killLabel and self._gemIcon and self._gemIcon:IsA("ImageLabel")) then
        if not silent then
            warn("[TopStatsController] Missing Top/Gem/Num1, Top/Gem/Icon, or Top/Kill/Num1.")
        end
        return false
    end

    self._gemIcon.Image = GEM_IMAGE
    if self._latestDiamonds ~= nil then
        self._gemLabel.Text = formatInteger(self._latestDiamonds)
    end
    if self._latestTotalKills ~= nil then
        self._killLabel.Text = formatInteger(self._latestTotalKills)
    end
    return true
end

function TopStatsController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end
    self._bindRetryQueued = true
    task.spawn(function()
        for _ = 1, UI_BIND_RETRY_COUNT do
            task.wait(UI_BIND_RETRY_INTERVAL_SECONDS)
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                if self._latestPayload then
                    self:_applyState(self._latestPayload)
                end
                return
            end
        end
        self._bindRetryQueued = false
    end)
end

function TopStatsController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestDiamonds = nil
    self._latestTotalKills = nil
    self._numberTweensByLabel = {}
    self._effectsFolder = nil
    self._latestPayload = nil
    disconnectAll(self._connections)

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestPayload = payload
        if not (self._gemLabel and self._killLabel and self._gemIcon) then
            if not self:_bindUi(true) then
                self:_queueBindRetry()
                return
            end
        end
        self:_applyState(payload)
    end))

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    if self:_bindUi(true) and self._latestPayload then
                        self:_applyState(self._latestPayload)
                    end
                end)
            end
        end))
        table.insert(self._connections, playerGui.DescendantAdded:Connect(function(descendant)
            if descendant.Name == "Top" or descendant.Name == "Gem" or descendant.Name == "Kill" or descendant.Name == "Num1" then
                task.defer(function()
                    if self:_bindUi(true) and self._latestPayload then
                        self:_applyState(self._latestPayload)
                    end
                end)
            end
        end))
    end

    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        task.defer(function()
            requestStateSyncEvent:FireServer()
        end)
    end
end

return TopStatsController
