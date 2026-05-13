--[[
脚本名字: NewWeaponUnlockController
脚本文件: NewWeaponUnlockController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/NewWeaponUnlockController
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
        "[NewWeaponUnlockController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local NewWeaponUnlockController = {}

NewWeaponUnlockController._localPlayer = nil
NewWeaponUnlockController._connections = {}
NewWeaponUnlockController._buttonConnections = {}
NewWeaponUnlockController._mainGui = nil
NewWeaponUnlockController._panel = nil
NewWeaponUnlockController._claimButton = nil
NewWeaponUnlockController._weaponImage = nil
NewWeaponUnlockController._nameLabel = nil
NewWeaponUnlockController._attackLabel = nil
NewWeaponUnlockController._rewardLabel = nil
NewWeaponUnlockController._requestClaimEvent = nil
NewWeaponUnlockController._requestStateSyncEvent = nil
NewWeaponUnlockController._pendingPayloads = {}
NewWeaponUnlockController._queuedTierIndexes = {}
NewWeaponUnlockController._activePayload = nil
NewWeaponUnlockController._isOpen = false
NewWeaponUnlockController._isClaiming = false
NewWeaponUnlockController._bindRetryQueued = false
NewWeaponUnlockController._animationSerial = 0
NewWeaponUnlockController._activeTweens = {}
NewWeaponUnlockController._originalPanelPosition = nil
NewWeaponUnlockController._originalChildPositions = {}

local PANEL_OFFSET = UDim2.fromOffset(-180, 0)
local CHILD_OFFSET = UDim2.fromOffset(-80, 0)
local PANEL_IN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PANEL_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CHILD_IN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLAIM_IN = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local MODAL_OWNER_ID = "NewWeaponUnlock"

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

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value or "")
    end
end

local function setGuiEnabled(guiObject, enabled)
    if guiObject and guiObject:IsA("GuiButton") then
        guiObject.Active = enabled == true
        guiObject.AutoButtonColor = enabled == true
    end
end

local function offsetPosition(position, offset)
    return UDim2.new(
        position.X.Scale + offset.X.Scale,
        position.X.Offset + offset.X.Offset,
        position.Y.Scale + offset.Y.Scale,
        position.Y.Offset + offset.Y.Offset
    )
end

function NewWeaponUnlockController:_cancelTweens()
    for _, tween in ipairs(self._activeTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._activeTweens)
end

function NewWeaponUnlockController:_rememberPositions()
    if self._panel and not self._originalPanelPosition then
        self._originalPanelPosition = self._panel.Position
    end

    local nodes = {
        self._weaponImage,
        self._nameLabel,
        self._attackLabel and self._attackLabel.Parent,
        self._rewardLabel and self._rewardLabel.Parent,
        self._claimButton,
    }
    for _, node in ipairs(nodes) do
        if node and node:IsA("GuiObject") and not self._originalChildPositions[node] then
            self._originalChildPositions[node] = node.Position
        end
    end
end

function NewWeaponUnlockController:_applyPayload(payload)
    if not payload then
        return
    end

    if self._weaponImage and (self._weaponImage:IsA("ImageLabel") or self._weaponImage:IsA("ImageButton")) then
        self._weaponImage.Image = tostring(payload.weaponIcon or "")
    end
    setText(self._nameLabel, payload.weaponName or "")
    setText(self._attackLabel, math.max(0, math.floor(tonumber(payload.damage) or 0)))
    setText(self._rewardLabel, math.max(0, math.floor(tonumber(payload.rewardDiamonds) or 0)))
end

function NewWeaponUnlockController:_playOpen(payload)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        return
    end

    self:_cancelTweens()
    self:_rememberPositions()
    self._animationSerial += 1
    local serial = self._animationSerial

    self._isOpen = true
    self._isClaiming = false
    self._activePayload = payload
    self:_applyPayload(payload)

    if self._mainGui and self._mainGui:IsA("ScreenGui") then
        self._mainGui.Enabled = true
    end
    ModalUiController:Acquire(MODAL_OWNER_ID, self._panel)
    self._panel.Visible = true
    self._panel.Position = offsetPosition(self._originalPanelPosition or self._panel.Position, PANEL_OFFSET)
    local panelScale = ensureUiScale(self._panel)
    if panelScale then
        panelScale.Scale = 0.96
    end

    local childNodes = {
        self._weaponImage,
        self._nameLabel,
        self._attackLabel and self._attackLabel.Parent,
        self._rewardLabel and self._rewardLabel.Parent,
    }
    for _, node in ipairs(childNodes) do
        if node and node:IsA("GuiObject") then
            node.Visible = true
            node.Position = offsetPosition(self._originalChildPositions[node] or node.Position, CHILD_OFFSET)
        end
    end

    if self._claimButton and self._claimButton:IsA("GuiObject") then
        self._claimButton.Visible = false
        setGuiEnabled(self._claimButton, false)
    end

    local panelTween = TweenService:Create(self._panel, PANEL_IN, {
        Position = self._originalPanelPosition or self._panel.Position,
    })
    table.insert(self._activeTweens, panelTween)
    if panelScale then
        table.insert(self._activeTweens, TweenService:Create(panelScale, PANEL_IN, {
            Scale = 1,
        }))
    end

    panelTween:Play()
    if panelScale and self._activeTweens[#self._activeTweens] then
        self._activeTweens[#self._activeTweens]:Play()
    end

    task.spawn(function()
        for index, node in ipairs(childNodes) do
            task.wait(0.045)
            if serial ~= self._animationSerial or not self._isOpen then
                return
            end
            if node and node:IsA("GuiObject") then
                local tween = TweenService:Create(node, CHILD_IN, {
                    Position = self._originalChildPositions[node] or node.Position,
                })
                table.insert(self._activeTweens, tween)
                tween:Play()
            end
        end

        task.wait(0.12)
        if serial ~= self._animationSerial or not self._isOpen then
            return
        end
        if self._claimButton and self._claimButton:IsA("GuiObject") then
            self._claimButton.Visible = true
            local claimScale = ensureUiScale(self._claimButton)
            if claimScale then
                claimScale.Scale = 0.75
                local tween = TweenService:Create(claimScale, CLAIM_IN, {
                    Scale = 1,
                })
                table.insert(self._activeTweens, tween)
                tween:Play()
            end
            setGuiEnabled(self._claimButton, true)
        end
    end)
end

function NewWeaponUnlockController:_playClose(afterClose)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if afterClose then
            afterClose()
        end
        return
    end

    self:_cancelTweens()
    self._animationSerial += 1
    self._isOpen = false
    setGuiEnabled(self._claimButton, false)

    local closeTween = TweenService:Create(self._panel, PANEL_OUT, {
        Position = offsetPosition(self._originalPanelPosition or self._panel.Position, PANEL_OFFSET),
    })
    table.insert(self._activeTweens, closeTween)
    closeTween.Completed:Connect(function()
        self._panel.Visible = false
        if self._originalPanelPosition then
            self._panel.Position = self._originalPanelPosition
        end
        ModalUiController:Release(MODAL_OWNER_ID)
        if afterClose then
            afterClose()
        end
    end)
    closeTween:Play()
end

function NewWeaponUnlockController:_showNextQueued()
    if self._isOpen or self._activePayload then
        return
    end

    local payload = table.remove(self._pendingPayloads, 1)
    if payload then
        self._queuedTierIndexes[tostring(payload.tierIndex or "")] = nil
        self:_playOpen(payload)
    end
end

function NewWeaponUnlockController:_handlePrompt(payload)
    if type(payload) ~= "table" then
        return
    end
    if payload.eventType ~= nil and tostring(payload.eventType) ~= "Show" then
        return
    end

    local tierKey = tostring(payload.tierIndex or "")
    if tierKey ~= "" then
        if self._activePayload and tostring(self._activePayload.tierIndex or "") == tierKey then
            return
        end
        if self._queuedTierIndexes[tierKey] == true then
            return
        end
        self._queuedTierIndexes[tierKey] = true
    end

    table.insert(self._pendingPayloads, payload)
    self:_showNextQueued()
end

function NewWeaponUnlockController:_requestClaim()
    if self._isClaiming or not (self._activePayload and self._requestClaimEvent) then
        return
    end

    self._isClaiming = true
    setGuiEnabled(self._claimButton, false)
    self._requestClaimEvent:FireServer(self._activePayload.tierIndex)
end

function NewWeaponUnlockController:_handleFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    local eventType = tostring(payload.eventType or "")
    if eventType == "Success" then
        self:_playClose(function()
            self._activePayload = nil
            self._isClaiming = false
            if self._requestStateSyncEvent then
                self._requestStateSyncEvent:FireServer()
            end
            self:_showNextQueued()
        end)
        return
    end

    self._isClaiming = false
    setGuiEnabled(self._claimButton, true)
end

function NewWeaponUnlockController:_disconnectButtonBindings()
    disconnectAll(self._buttonConnections)
end

function NewWeaponUnlockController:_bindUi(silent)
    self._mainGui = findMainGui(self._localPlayer)
    self._panel = self._mainGui and self._mainGui:FindFirstChild("NewWeaponUnlock", true) or nil
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self._claimButton = self._panel:FindFirstChild("Claim", true)
    self._weaponImage = self._panel:FindFirstChild("Weapon", true)
    self._nameLabel = self._panel:FindFirstChild("Name", true)
    local attackRoot = self._panel:FindFirstChild("AtkBg", true)
    self._attackLabel = attackRoot and attackRoot:FindFirstChild("Number", true) or nil
    local rewardRoot = self._panel:FindFirstChild("Reward", true)
    self._rewardLabel = rewardRoot and rewardRoot:FindFirstChild("Number", true) or nil

    self._originalPanelPosition = self._panel.Position
    table.clear(self._originalChildPositions)
    self:_rememberPositions()
    self._panel.Visible = false
    setGuiEnabled(self._claimButton, false)

    if self._claimButton and self._claimButton:IsA("GuiButton") then
        table.insert(self._buttonConnections, self._claimButton.Activated:Connect(function()
            self:_requestClaim()
        end))
    end

    return true
end

function NewWeaponUnlockController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                self:_showNextQueued()
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[NewWeaponUnlockController] 找不到 PlayerGui/Main/NewWeaponUnlock，新武器解锁弹框暂不可用。")
    end)
end

function NewWeaponUnlockController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    self._pendingPayloads = {}
    self._queuedTierIndexes = {}
    self._activePayload = nil
    self._isOpen = false
    self._isClaiming = false

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local promptEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WeaponUnlockPrompt)
    self._requestClaimEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestWeaponUnlockReward)
    local feedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.WeaponUnlockRewardFeedback)
    self._requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end
    if self._requestStateSyncEvent then
        task.defer(function()
            if self._requestStateSyncEvent then
                self._requestStateSyncEvent:FireServer()
            end
        end)
    end

    table.insert(self._connections, promptEvent.OnClientEvent:Connect(function(payload)
        if not (self._panel and self._panel.Parent) then
            self:_bindUi(true)
        end
        self:_handlePrompt(payload)
    end))

    table.insert(self._connections, feedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleFeedback(payload)
    end))

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi(true)
                    self:_showNextQueued()
                end)
            end
        end))
    end
end

return NewWeaponUnlockController
