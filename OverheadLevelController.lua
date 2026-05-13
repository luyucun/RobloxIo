--[[
脚本名字: OverheadLevelController
脚本文件: OverheadLevelController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/OverheadLevelController
说明: 负责本地视角下的头顶等级渐变显示。服务端只同步 Level 文本，渐变由客户端按视角决定。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OverheadLevelController = {}

OverheadLevelController._localPlayer = nil
OverheadLevelController._connections = {}
OverheadLevelController._playerConnections = {}
OverheadLevelController._latestState = nil

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

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
        "[OverheadLevelController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local findBillboard
local parseLevelText

local function readLevelValue(value)
    local resolved = tonumber(value)
    if not resolved then
        return 0
    end
    return math.max(0, math.floor(resolved))
end

local function getLeaderstatsLevel(player)
    if not player then
        return 0
    end

    local leaderstats = player:FindFirstChild("leaderstats")
    if leaderstats then
        local levelValue = leaderstats:FindFirstChild("Level")
        if levelValue and levelValue:IsA("IntValue") then
            return readLevelValue(levelValue.Value)
        end
    end

    local character = player.Character
    local billboard = findBillboard(character)
    local root = billboard and billboard:FindFirstChild("Root")
    local levelLabel = root and root:FindFirstChild("Level")
    if levelLabel and levelLabel:IsA("TextLabel") then
        return parseLevelText(levelLabel.Text)
    end
    return 0
end

local function getOwnLevel(controller)
    local state = controller._latestState or {}
    local syncedLevel = readLevelValue(state.level)
    if syncedLevel > 0 then
        return syncedLevel
    end

    local localPlayer = controller._localPlayer
    local fallbackLevel = getLeaderstatsLevel(localPlayer)
    if fallbackLevel > 0 then
        return fallbackLevel
    end

    return 1
end

local function getActorLevel(controller, actor)
    if not actor then
        return 0
    end

    if actor == controller._localPlayer then
        return getOwnLevel(controller)
    end

    local level = getLeaderstatsLevel(actor)
    if level > 0 then
        return level
    end

    local state = actor:GetAttribute("Level")
    if state ~= nil then
        return math.max(0, math.floor(tonumber(state) or 0))
    end

    local character = actor.Character
    local billboard = findBillboard(character)
    local root = billboard and billboard:FindFirstChild("Root")
    local levelLabel = root and root:FindFirstChild("Level")
    if levelLabel and levelLabel:IsA("TextLabel") then
        local parsedLevel = parseLevelText(levelLabel.Text)
        if parsedLevel > 0 then
            return parsedLevel
        end
    end

    return 0
end

findBillboard = function(character)
    if not character then
        return nil
    end

    local head = character:FindFirstChild("Head")
    if not (head and head:IsA("BasePart")) then
        return nil
    end

    local billboard = head:FindFirstChild("OverheadHealthBar")
    if billboard and billboard:IsA("BillboardGui") then
        return billboard
    end
    return nil
end

parseLevelText = function(text)
    local content = tostring(text or "")
    local parsed = content:match("Lv%.(%d+)")
    if not parsed then
        parsed = content:match("(%d+)")
    end
    if not parsed then
        return 0
    end
    return math.max(0, math.floor(tonumber(parsed) or 0))
end

local function ensureBucket(bucket)
    bucket.connections = bucket.connections or {}
    bucket.characterConnections = bucket.characterConnections or {}
    bucket.leaderstatsConnections = bucket.leaderstatsConnections or {}
    bucket.refreshQueued = bucket.refreshQueued == true
    bucket.boundCharacter = bucket.boundCharacter or nil
    bucket.boundLeaderstats = bucket.boundLeaderstats or nil
    bucket.observedLevelLabels = bucket.observedLevelLabels or {}
    bucket.observedGradientStates = bucket.observedGradientStates or {}
    return bucket
end

local function setGradientEnabled(gradient, enabled)
    if gradient and gradient:IsA("UIGradient") then
        gradient.Enabled = enabled
    end
end

function OverheadLevelController:_bindGradient(player, gradient)
    local bucket = self._playerConnections[player]
    if not bucket or not gradient or not gradient:IsA("UIGradient") then
        return
    end

    if bucket.observedGradientStates[gradient] then
        return
    end
    bucket.observedGradientStates[gradient] = true

    table.insert(bucket.characterConnections, gradient:GetPropertyChangedSignal("Enabled"):Connect(function()
        self:_scheduleRefresh(player)
    end))
end

function OverheadLevelController:_disconnectPlayer(player)
    local bucket = self._playerConnections[player]
    if not bucket then
        return
    end

    disconnectAll(bucket.connections)
    disconnectAll(bucket.characterConnections)
    disconnectAll(bucket.leaderstatsConnections)
    self._playerConnections[player] = nil
end

function OverheadLevelController:_bindLeaderstats(player, leaderstats)
    local bucket = self._playerConnections[player]
    if not bucket then
        return
    end

    if bucket.boundLeaderstats == leaderstats then
        return
    end

    disconnectAll(bucket.leaderstatsConnections)
    bucket.boundLeaderstats = leaderstats

    if not leaderstats then
        return
    end

    local function bindLevelValue(levelValue)
        if not (levelValue and levelValue:IsA("IntValue") and levelValue.Name == "Level") then
            return
        end

        table.insert(bucket.leaderstatsConnections, levelValue:GetPropertyChangedSignal("Value"):Connect(function()
            if player == self._localPlayer then
                self:_refreshAll()
            else
                self:_scheduleRefresh(player)
            end
        end))
    end

    local levelValue = leaderstats:FindFirstChild("Level")
    if levelValue then
        bindLevelValue(levelValue)
    end

    table.insert(bucket.leaderstatsConnections, leaderstats.ChildAdded:Connect(function(child)
        if child.Name == "Level" and child:IsA("IntValue") then
            bindLevelValue(child)
            if player == self._localPlayer then
                self:_refreshAll()
            else
                self:_scheduleRefresh(player)
            end
        end
    end))
end

function OverheadLevelController:_bindLevelLabel(player, levelLabel)
    local bucket = self._playerConnections[player]
    if not bucket or not levelLabel or not levelLabel:IsA("TextLabel") then
        return
    end

    self:_bindGradient(player, levelLabel:FindFirstChild("High"))
    self:_bindGradient(player, levelLabel:FindFirstChild("Low"))

    if bucket.observedLevelLabels[levelLabel] then
        return
    end
    bucket.observedLevelLabels[levelLabel] = true

    table.insert(bucket.characterConnections, levelLabel:GetPropertyChangedSignal("Text"):Connect(function()
        self:_scheduleRefresh(player)
    end))
    table.insert(bucket.characterConnections, levelLabel:GetPropertyChangedSignal("TextColor3"):Connect(function()
        self:_scheduleRefresh(player)
    end))

end

function OverheadLevelController:_bindCharacter(player, character)
    local bucket = self._playerConnections[player]
    if not bucket then
        return
    end

    if bucket.boundCharacter == character then
        return
    end

    disconnectAll(bucket.characterConnections)
    bucket.boundCharacter = character
    bucket.observedLevelLabels = {}
    bucket.observedGradientStates = {}

    if not character then
        return
    end

    table.insert(bucket.characterConnections, character.DescendantAdded:Connect(function(descendant)
        local name = descendant and descendant.Name or ""
        if name == "OverheadHealthBar" or name == "Level" or name == "High" or name == "Low" then
            task.defer(function()
                if descendant and descendant.Name == "Level" and descendant:IsA("TextLabel") then
                    self:_bindLevelLabel(player, descendant)
                elseif descendant and descendant:IsA("UIGradient") then
                    self:_bindGradient(player, descendant)
                end
                self:_scheduleRefresh(player)
            end)
        end
    end))

    table.insert(bucket.characterConnections, character.DescendantRemoving:Connect(function(descendant)
        local name = descendant and descendant.Name or ""
        if name == "OverheadHealthBar" or name == "Level" or name == "High" or name == "Low" then
            task.defer(function()
                self:_scheduleRefresh(player)
            end)
        end
    end))

    local billboard = findBillboard(character)
    if billboard then
        local root = billboard:FindFirstChild("Root")
        local levelLabel = root and root:FindFirstChild("Level")
        if levelLabel and levelLabel:IsA("TextLabel") then
            self:_bindLevelLabel(player, levelLabel)
        end
    end

    self:_scheduleRefresh(player)
end

function OverheadLevelController:_resolveRelation(actor)
    if not actor or actor == self._localPlayer then
        return "Self"
    end

    local ownLevel = getOwnLevel(self)
    local actorLevel = getActorLevel(self, actor)
    if actorLevel <= 0 then
        return "Unknown"
    end
    if actorLevel > ownLevel then
        return "Higher"
    end
    if actorLevel < ownLevel then
        return "Lower"
    end
    return "Equal"
end

function OverheadLevelController:_applyToActor(actor)
    if not actor then
        return
    end

    local character = actor.Character
    if not character then
        return
    end

    local billboard = findBillboard(character)
    if not billboard then
        return
    end

    local root = billboard:FindFirstChild("Root")
    local levelLabel = root and root:FindFirstChild("Level")
    if not (levelLabel and levelLabel:IsA("TextLabel")) then
        return
    end

    self:_bindLevelLabel(actor, levelLabel)

    local displayedLevel = getActorLevel(self, actor)
    if displayedLevel > 0 then
        levelLabel.Text = string.format("Lv.%d", displayedLevel)
    end
    levelLabel.TextColor3 = Color3.fromRGB(255, 255, 255)

    local relation = self:_resolveRelation(actor)
    local high = levelLabel:FindFirstChild("High")
    local low = levelLabel:FindFirstChild("Low")

    if relation == "Higher" then
        setGradientEnabled(high, true)
        setGradientEnabled(low, false)
    elseif relation == "Lower" then
        setGradientEnabled(high, false)
        setGradientEnabled(low, true)
    else
        setGradientEnabled(high, false)
        setGradientEnabled(low, false)
    end
end

function OverheadLevelController:_scheduleRefresh(player)
    local bucket = self._playerConnections[player]
    if not bucket or bucket.refreshQueued then
        return
    end

    bucket.refreshQueued = true
    task.defer(function()
        local ok, err = pcall(function()
            if self._playerConnections[player] then
                self:_applyToActor(player)
            end
        end)

        local currentBucket = self._playerConnections[player]
        if currentBucket then
            currentBucket.refreshQueued = false
        end

        if not ok then
            warn(string.format("[OverheadLevelController] 刷新 %s 失败：%s", tostring(player and player.Name or ""), tostring(err)))
        end
    end)
end

function OverheadLevelController:_refreshAll()
    for _, player in ipairs(Players:GetPlayers()) do
        self:_scheduleRefresh(player)
    end
end

function OverheadLevelController:_bindPlayer(player)
    if not player or self._playerConnections[player] then
        return
    end

    local bucket = ensureBucket({})
    self._playerConnections[player] = bucket

    table.insert(bucket.connections, player.CharacterAdded:Connect(function(character)
        self:_bindCharacter(player, character)
    end))

    table.insert(bucket.connections, player.CharacterRemoving:Connect(function()
        self:_bindCharacter(player, nil)
    end))

    table.insert(bucket.connections, player.ChildAdded:Connect(function(child)
        if child.Name == "leaderstats" then
            self:_bindLeaderstats(player, child)
            if player == self._localPlayer then
                self:_refreshAll()
            else
                self:_scheduleRefresh(player)
            end
        elseif child.Name == "Character" then
            self:_scheduleRefresh(player)
        end
    end))

    table.insert(bucket.connections, player.ChildRemoved:Connect(function(child)
        if child.Name == "leaderstats" then
            self:_bindLeaderstats(player, nil)
        end
    end))

    self:_bindLeaderstats(player, player:FindFirstChild("leaderstats"))
    self:_bindCharacter(player, player.Character)
end

function OverheadLevelController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._latestState = nil

    disconnectAll(self._connections)
    local boundPlayers = {}
    for player in pairs(self._playerConnections) do
        table.insert(boundPlayers, player)
    end
    for _, player in ipairs(boundPlayers) do
        self:_disconnectPlayer(player)
    end

    local eventsRoot = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self._latestState = payload or self._latestState or {}
        self:_refreshAll()
    end))

    table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
        self:_bindPlayer(player)
        self:_scheduleRefresh(player)
    end))

    table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
        self:_disconnectPlayer(player)
    end))

    for _, player in ipairs(Players:GetPlayers()) do
        self:_bindPlayer(player)
    end

    if requestStateSyncEvent and requestStateSyncEvent:IsA("RemoteEvent") then
        task.defer(function()
            requestStateSyncEvent:FireServer()
        end)
    end

    self:_refreshAll()
end

return OverheadLevelController
