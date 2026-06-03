--[[
脚本名字: TrailFxController
脚本文件: TrailFxController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/TrailFxController
说明: 根据服务端同步的 EquippedTrailId 属性，在每个客户端本地为所有玩家创建尾迹表现。
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
        "[TrailFxController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local TrailConfig = requireSharedModule("TrailConfig")

local TrailFxController = {}

TrailFxController._localPlayer = nil
TrailFxController._connections = {}
TrailFxController._playerConnectionsByUserId = {}
TrailFxController._activeTrailsByUserId = {}
TrailFxController._applySerialByUserId = {}

local TRAIL_ATTRIBUTE_NAME = "EquippedTrailId"
local LOCAL_TRAIL_TAG = "IOLocalTrail"
local LEGACY_SERVER_TRAIL_TAG = "IOEquippedTrail"
local FALLBACK_BODY_PART_NAMES = { "LowerTorso", "Torso", "UpperTorso", "HumanoidRootPart" }
local GENERIC_TRAIL_ATTACHMENT_NAMES = {
    Attachment = true,
    Attachment0 = true,
    Attachment1 = true,
}

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function normalizeTrailId(value)
    local trailId = math.floor(tonumber(value) or 0)
    return trailId > 0 and trailId or nil
end

local function findPathChild(root, path)
    local current = root
    for segment in string.gmatch(tostring(path or ""), "[^/%.]+") do
        if segment ~= "" and segment ~= "game" then
            if current == root and segment == "ReplicatedStorage" then
                current = ReplicatedStorage
            else
                current = current and current:FindFirstChild(segment)
            end
        end
    end
    return current
end

local function getTrailTemplate(trail)
    if type(trail) ~= "table" then
        return nil
    end

    local template = findPathChild(game, trail.TemplatePath)
    if template then
        return template
    end

    local modelFolder = ReplicatedStorage:FindFirstChild("Model")
    local trailFolder = modelFolder and modelFolder:FindFirstChild("Trail")
    return trailFolder and trailFolder:FindFirstChild(tostring(trail.TemplateName or "")) or nil
end

local function stripRuntimeOnlyDescendants(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
            descendant:Destroy()
        end
    end
end

local function prepareTrailPart(part)
    if not part:IsA("BasePart") then
        return
    end
    part.Anchored = false
    part.CanCollide = false
    part.CanTouch = false
    part.Massless = true
end

local function prepareTrailCloneParts(instance)
    if instance:IsA("BasePart") then
        prepareTrailPart(instance)
    end
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            prepareTrailPart(descendant)
        end
    end
end

local function findBodyAttachmentByName(character, attachmentName)
    if not (character and attachmentName and attachmentName ~= "") then
        return nil
    end

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("Attachment") and descendant.Name == attachmentName then
            local parent = descendant.Parent
            if parent and parent:IsA("BasePart") and parent.Parent == character then
                return descendant
            end
        end
    end

    return nil
end

local function findMatchingCharacterAttachment(character, handle)
    if not (character and handle) then
        return nil, nil
    end

    for _, handleChild in ipairs(handle:GetChildren()) do
        if handleChild:IsA("Attachment") and not GENERIC_TRAIL_ATTACHMENT_NAMES[handleChild.Name] then
            local characterAttachment = findBodyAttachmentByName(character, handleChild.Name)
            if characterAttachment then
                return characterAttachment, handleChild
            end
        end
    end

    for _, handleChild in ipairs(handle:GetChildren()) do
        if handleChild:IsA("Attachment") then
            local characterAttachment = findBodyAttachmentByName(character, handleChild.Name)
            if characterAttachment then
                return characterAttachment, handleChild
            end
        end
    end

    return nil, nil
end

local function findFallbackBodyPart(character)
    if not character then
        return nil
    end
    for _, partName in ipairs(FALLBACK_BODY_PART_NAMES) do
        local part = character:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            return part
        end
    end
    return character:FindFirstChildWhichIsA("BasePart")
end

local function weldAccessoryHandleToCharacter(accessory, character)
    local handle = accessory and accessory:FindFirstChild("Handle")
    if not (handle and handle:IsA("BasePart") and character) then
        return false, "MissingHandle"
    end

    prepareTrailPart(handle)

    local bodyAttachment, handleAttachment = findMatchingCharacterAttachment(character, handle)
    local bodyPart = bodyAttachment and bodyAttachment.Parent
    local bodyCFrame = bodyAttachment and bodyAttachment.CFrame or nil
    local handleCFrame = handleAttachment and handleAttachment.CFrame or nil
    if not (bodyPart and bodyPart:IsA("BasePart") and bodyCFrame and handleCFrame) then
        bodyPart = findFallbackBodyPart(character)
        bodyCFrame = CFrame.new(0, 0, 0.8)
        handleCFrame = CFrame.new()
    end
    if not (bodyPart and bodyPart:IsA("BasePart")) then
        return false, "MissingBodyPart"
    end

    local existingWeld = handle:FindFirstChild("AccessoryWeld")
    if existingWeld then
        existingWeld:Destroy()
    end

    accessory.Parent = character
    handle.CFrame = bodyPart.CFrame * bodyCFrame * handleCFrame:Inverse()

    local weld = Instance.new("Weld")
    weld.Name = "AccessoryWeld"
    weld.Part0 = bodyPart
    weld.Part1 = handle
    weld.C0 = bodyCFrame
    weld.C1 = handleCFrame
    weld.Parent = handle

    return true
end

function TrailFxController:_clearCharacterTrailInstances(character)
    if not character then
        return
    end

    for _, child in ipairs(character:GetChildren()) do
        if child:GetAttribute(LOCAL_TRAIL_TAG) == true or child:GetAttribute(LEGACY_SERVER_TRAIL_TAG) == true then
            child:Destroy()
        end
    end
end

function TrailFxController:_clearPlayerTrail(player)
    local userId = player and player.UserId or 0
    local activeTrail = self._activeTrailsByUserId[userId]
    if activeTrail and activeTrail.Parent then
        activeTrail:Destroy()
    end
    self._activeTrailsByUserId[userId] = nil

    if player and player.Character then
        self:_clearCharacterTrailInstances(player.Character)
    end
end

function TrailFxController:_getEquippedTrailId(player)
    if not player then
        return nil
    end

    return normalizeTrailId(player:GetAttribute(TRAIL_ATTRIBUTE_NAME))
        or normalizeTrailId(player.Character and player.Character:GetAttribute(TRAIL_ATTRIBUTE_NAME))
end

function TrailFxController:_applyTrailNow(player, serial)
    if not (player and player.Parent) then
        return
    end

    local userId = player.UserId
    if self._applySerialByUserId[userId] ~= serial then
        return
    end

    local character = player.Character
    if not character then
        self:_clearPlayerTrail(player)
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    if self._applySerialByUserId[userId] ~= serial or not (humanoid and humanoid.Parent and character.Parent) then
        return
    end

    self:_clearPlayerTrail(player)

    local trailId = self:_getEquippedTrailId(player)
    if not trailId then
        return
    end

    local trail = TrailConfig.GetTrail(trailId)
    local template = getTrailTemplate(trail)
    if not template then
        warn(string.format("[TrailFxController] 找不到尾迹模板: %s", tostring(trail and (trail.TemplatePath or trail.TemplateName) or trailId)))
        return
    end

    local clone = template:Clone()
    clone.Name = "LocalEquippedTrail_" .. tostring(trail.Id)
    clone:SetAttribute(LOCAL_TRAIL_TAG, true)
    clone:SetAttribute("TrailId", trail.Id)
    clone:SetAttribute("OwnerUserId", userId)
    stripRuntimeOnlyDescendants(clone)
    prepareTrailCloneParts(clone)

    if clone:IsA("Accessory") then
        local ok, err = weldAccessoryHandleToCharacter(clone, character)
        if not ok then
            warn("[TrailFxController] 本地焊接尾迹失败: " .. tostring(err))
            clone.Parent = character
        end
    else
        clone.Parent = character
    end

    self._activeTrailsByUserId[userId] = clone
end

function TrailFxController:_refreshPlayerTrail(player)
    if not player then
        return
    end

    local userId = player.UserId
    self._applySerialByUserId[userId] = (self._applySerialByUserId[userId] or 0) + 1
    local serial = self._applySerialByUserId[userId]

    task.spawn(function()
        self:_applyTrailNow(player, serial)
    end)
end

function TrailFxController:_bindPlayer(player)
    if not player then
        return
    end

    local userId = player.UserId
    local existingConnections = self._playerConnectionsByUserId[userId]
    if existingConnections then
        disconnectAll(existingConnections)
    end

    local connections = {}
    self._playerConnectionsByUserId[userId] = connections

    table.insert(connections, player:GetAttributeChangedSignal(TRAIL_ATTRIBUTE_NAME):Connect(function()
        self:_refreshPlayerTrail(player)
    end))

    table.insert(connections, player.CharacterAdded:Connect(function(character)
        table.insert(connections, character:GetAttributeChangedSignal(TRAIL_ATTRIBUTE_NAME):Connect(function()
            self:_refreshPlayerTrail(player)
        end))
        self:_refreshPlayerTrail(player)
    end))

    table.insert(connections, player.CharacterRemoving:Connect(function()
        self:_clearPlayerTrail(player)
    end))

    if player.Character then
        table.insert(connections, player.Character:GetAttributeChangedSignal(TRAIL_ATTRIBUTE_NAME):Connect(function()
            self:_refreshPlayerTrail(player)
        end))
    end

    self:_refreshPlayerTrail(player)
end

function TrailFxController:_unbindPlayer(player)
    local userId = player and player.UserId or 0
    local connections = self._playerConnectionsByUserId[userId]
    if connections then
        disconnectAll(connections)
    end
    self._playerConnectionsByUserId[userId] = nil
    self._applySerialByUserId[userId] = nil
    self:_clearPlayerTrail(player)
end

function TrailFxController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer

    disconnectAll(self._connections)
    for userId, connections in pairs(self._playerConnectionsByUserId) do
        disconnectAll(connections)
        self._playerConnectionsByUserId[userId] = nil
    end
    for _, player in ipairs(Players:GetPlayers()) do
        self:_clearPlayerTrail(player)
        self:_bindPlayer(player)
    end

    table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
        self:_bindPlayer(player)
    end))

    table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
        self:_unbindPlayer(player)
    end))
end

return TrailFxController
