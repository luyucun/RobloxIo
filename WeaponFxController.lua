--[[
脚本名字: WeaponFxController
脚本文件: WeaponFxController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/WeaponFxController
说明: 只保留本地 3D 武器视觉同步，不再包含任何屏幕面板逻辑。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
        "[WeaponFxController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local GameConfig = requireSharedModule("GameConfig")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")

local WeaponFxController = {}

WeaponFxController._localPlayer = nil
WeaponFxController._syncConnection = nil
WeaponFxController._renderConnection = nil
WeaponFxController._localWeaponFolder = nil
WeaponFxController._localWeaponStates = {}
WeaponFxController._weaponStatesByOwnerUserId = {}
WeaponFxController._ownerWeaponFolders = {}
WeaponFxController._hiddenServerParts = {}
WeaponFxController._hiddenServerEffects = {}
WeaponFxController._lastWeaponSignature = nil
WeaponFxController._runtimeWeaponsFolder = nil
WeaponFxController._runtimeWeaponFolderConnections = {}
WeaponFxController._runtimeWeaponInstanceConnections = {}
WeaponFxController._serverWeaponVisibilityDirty = true
WeaponFxController._nextServerWeaponVisibilityRefreshClock = 0
WeaponFxController._playerRemovingConnection = nil
WeaponFxController._localCharacterAddedConnection = nil
WeaponFxController._requestStateSyncEvent = nil
WeaponFxController._perfStats = nil
WeaponFxController._nextPerfLogClock = 0

local TIER_COLORS = {
    T1 = Color3.fromRGB(214, 255, 77),
    T2 = Color3.fromRGB(100, 255, 226),
    T3 = Color3.fromRGB(255, 158, 74),
}

local function getTierColor(tierName)
    local tierIndex = WeaponTierConfig.GetTierIndex(tierName)
    if tierIndex <= 0 then
        return TIER_COLORS[tierName] or Color3.fromRGB(220, 220, 220)
    end

    local hue = ((tierIndex - 1) * 0.075) % 1
    return Color3.fromHSV(hue, 0.72, 1)
end

local function getBaseParts(instance)
    local result = {}
    if instance:IsA("BasePart") then
        table.insert(result, instance)
        return result
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(result, descendant)
        end
    end

    return result
end

local function setWorldCFrame(instance, targetCFrame)
    if instance:IsA("Model") then
        instance:PivotTo(targetCFrame)
    elseif instance:IsA("BasePart") then
        instance.CFrame = targetCFrame
    end
end

local function findChildOfClass(parent, childName, className)
    if not parent then
        return nil
    end

    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == childName and child:IsA(className) then
            return child
        end
    end

    return nil
end

local function findVisualWeaponTemplate(folder, templateName)
    if not folder then
        return nil
    end

    for _, child in ipairs(folder:GetChildren()) do
        if child.Name == templateName and (child:IsA("BasePart") or child:IsA("Model")) then
            return child
        end
    end

    return nil
end

local function resolveVisualTemplateName(weaponData, tierConfig)
    local visualTemplateName = weaponData and weaponData.visualTemplateName
    if visualTemplateName and tostring(visualTemplateName) ~= "" then
        return tostring(visualTemplateName)
    end
    return tierConfig and tierConfig.TemplateName or nil
end

local function resolveAuraPart(instance)
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") and instance.Name == GameConfig.WEAPON.AuraPartName then
        return instance
    end
    local auraPart = instance:FindFirstChild(GameConfig.WEAPON.AuraPartName, true)
    if auraPart and auraPart:IsA("BasePart") then
        return auraPart
    end
    return nil
end

local function resolveHitPart(instance)
    local auraPart = resolveAuraPart(instance)
    if auraPart then
        return auraPart
    end
    if instance:IsA("Model") then
        return instance.PrimaryPart
    end
    if instance:IsA("BasePart") then
        return instance
    end
    return nil
end

local function stripRuntimeOnlyDescendants(instance)
    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") or descendant:IsA("Tool") then
            descendant:Destroy()
        end
    end
end

local function resolveOwnerUserId(basePart)
    local current = basePart
    while current and current ~= Workspace do
        local ownerUserId = current:GetAttribute("OwnerUserId")
        if ownerUserId ~= nil then
            return tonumber(ownerUserId)
        end
        current = current.Parent
    end
    return nil
end

local function getRuntimeWeaponsFolder()
    local runtimeRoot = findChildOfClass(Workspace, WeaponTierConfig.RuntimeRootFolderName, "Folder")
    if not runtimeRoot then
        return nil
    end
    return findChildOfClass(runtimeRoot, WeaponTierConfig.RuntimeFolderName, "Folder")
end

local function getWeaponOrbitSpeed()
    return tonumber(GameConfig.WEAPON and GameConfig.WEAPON.OrbitSpeed) or 2.8
end

local function getWeaponOrbitDistance()
    return 6
end

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function countDescendants(instance)
    if not instance then
        return 0
    end

    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    return ok and #descendants or 0
end

local function getRuntimeWeaponParts(weaponsFolder)
    local result = {}
    for _, child in ipairs(weaponsFolder:GetChildren()) do
        if child:IsA("BasePart") then
            table.insert(result, child)
        end
        for _, descendant in ipairs(child:GetDescendants()) do
            if descendant:IsA("BasePart") then
                table.insert(result, descendant)
            end
        end
    end
    return result
end

local function getRuntimeWeaponVisualEffects(weaponsFolder)
    local result = {}
    for _, child in ipairs(weaponsFolder:GetChildren()) do
        if child:IsA("Trail") or child:IsA("Beam") or child:IsA("ParticleEmitter") then
            table.insert(result, child)
        end
        for _, descendant in ipairs(child:GetDescendants()) do
            if descendant:IsA("Trail") or descendant:IsA("Beam") or descendant:IsA("ParticleEmitter") then
                table.insert(result, descendant)
            end
        end
    end
    return result
end

local function normalizeAngle(angle)
    local tau = math.pi * 2
    local normalized = (tonumber(angle) or 0) % tau
    if normalized < 0 then
        normalized += tau
    end
    return normalized
end

local function normalizeOrbitDirection(direction)
    return (tonumber(direction) or 1) < 0 and -1 or 1
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local SERVER_WEAPON_VISIBILITY_REFRESH_SECONDS = 1

function WeaponFxController:_getLocalWeaponFolder()
    if self._localWeaponFolder and self._localWeaponFolder.Parent then
        return self._localWeaponFolder
    end

    local camera = Workspace.CurrentCamera
    if not camera then
        return nil
    end

    local folder = findChildOfClass(camera, "LocalOrbitWeapons", "Folder")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "LocalOrbitWeapons"
        folder.Parent = camera
    end

    self._localWeaponFolder = folder
    return folder
end

function WeaponFxController:_getOwnerWeaponFolder(ownerUserId)
    local normalizedOwnerUserId = math.floor(tonumber(ownerUserId) or 0)
    if normalizedOwnerUserId <= 0 then
        return nil
    end

    local existingFolder = self._ownerWeaponFolders[normalizedOwnerUserId]
    if existingFolder and existingFolder.Parent then
        return existingFolder
    end

    local rootFolder = self:_getLocalWeaponFolder()
    if not rootFolder then
        return nil
    end

    local folderName = string.format("Owner_%d", normalizedOwnerUserId)
    local ownerFolder = findChildOfClass(rootFolder, folderName, "Folder")
    if not ownerFolder then
        ownerFolder = Instance.new("Folder")
        ownerFolder.Name = folderName
        ownerFolder.Parent = rootFolder
    end

    self._ownerWeaponFolders[normalizedOwnerUserId] = ownerFolder
    return ownerFolder
end

function WeaponFxController:_markServerWeaponVisibilityDirty()
    self._serverWeaponVisibilityDirty = true
    self._nextServerWeaponVisibilityRefreshClock = 0
end

function WeaponFxController:_bindRuntimeWeaponInstance(instance)
    if not instance or self._runtimeWeaponInstanceConnections[instance] then
        return
    end

    local connections = {}
    self._runtimeWeaponInstanceConnections[instance] = connections
    self:_addPerfStat("RuntimeInstanceBinds")

    table.insert(connections, instance:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
        self:_markServerWeaponVisibilityDirty()
    end))

    for _, descendant in ipairs(instance:GetDescendants()) do
        if descendant:IsA("BasePart") then
            table.insert(connections, descendant:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
                self:_markServerWeaponVisibilityDirty()
            end))
        end
    end

    table.insert(connections, instance.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            self:_markServerWeaponVisibilityDirty()
            table.insert(connections, descendant:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
                self:_markServerWeaponVisibilityDirty()
            end))
        end
    end))
end

function WeaponFxController:_unbindRuntimeWeaponInstance(instance)
    local connections = self._runtimeWeaponInstanceConnections[instance]
    if not connections then
        return
    end

    disconnectAll(connections)
    self._runtimeWeaponInstanceConnections[instance] = nil
    self:_addPerfStat("RuntimeInstanceUnbinds")
end

function WeaponFxController:_clearRuntimeWeaponInstanceConnections()
    for instance in pairs(self._runtimeWeaponInstanceConnections) do
        self:_unbindRuntimeWeaponInstance(instance)
    end
end

function WeaponFxController:_resolveRuntimeWeaponsFolder()
    local weaponsFolder = getRuntimeWeaponsFolder()
    if weaponsFolder ~= self._runtimeWeaponsFolder then
        disconnectAll(self._runtimeWeaponFolderConnections)
        self:_clearRuntimeWeaponInstanceConnections()
        self._runtimeWeaponsFolder = weaponsFolder
        self:_markServerWeaponVisibilityDirty()

        if weaponsFolder then
            for _, child in ipairs(weaponsFolder:GetChildren()) do
                self:_bindRuntimeWeaponInstance(child)
            end
            table.insert(self._runtimeWeaponFolderConnections, weaponsFolder.ChildAdded:Connect(function(child)
                self:_bindRuntimeWeaponInstance(child)
                self:_markServerWeaponVisibilityDirty()
            end))
            table.insert(self._runtimeWeaponFolderConnections, weaponsFolder.ChildRemoved:Connect(function(child)
                self:_unbindRuntimeWeaponInstance(child)
                self:_markServerWeaponVisibilityDirty()
            end))
        end
    elseif weaponsFolder and #self._runtimeWeaponFolderConnections <= 0 then
        self:_markServerWeaponVisibilityDirty()
        for _, child in ipairs(weaponsFolder:GetChildren()) do
            self:_bindRuntimeWeaponInstance(child)
        end
        table.insert(self._runtimeWeaponFolderConnections, weaponsFolder.ChildAdded:Connect(function(child)
            self:_bindRuntimeWeaponInstance(child)
            self:_markServerWeaponVisibilityDirty()
        end))
        table.insert(self._runtimeWeaponFolderConnections, weaponsFolder.ChildRemoved:Connect(function(child)
            self:_unbindRuntimeWeaponInstance(child)
            self:_markServerWeaponVisibilityDirty()
        end))
    end

    return self._runtimeWeaponsFolder
end

function WeaponFxController:_resolveTemplate(tierName, visualTemplateName)
    local tierConfig = WeaponTierConfig.Tiers[tostring(tierName or "")]
    if not tierConfig then
        return nil, nil
    end

    local modelRoot = findChildOfClass(ReplicatedStorage, WeaponTierConfig.ModelRootFolderName, "Folder")
    local weaponFolder = findChildOfClass(modelRoot, WeaponTierConfig.WeaponFolderName, "Folder")
    local resolvedTemplateName = tostring(visualTemplateName or tierConfig.TemplateName)
    return findVisualWeaponTemplate(weaponFolder, resolvedTemplateName) or findVisualWeaponTemplate(weaponFolder, tierConfig.TemplateName), tierConfig
end

function WeaponFxController:_configureLocalWeapon(instance)
    for _, basePart in ipairs(getBaseParts(instance)) do
        basePart.Anchored = true
        basePart.CanCollide = false
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
        basePart.LocalTransparencyModifier = 0
    end
end

function WeaponFxController:_tagLocalWeaponOwner(instance, ownerUserId)
    local normalizedOwnerUserId = math.floor(tonumber(ownerUserId) or 0)
    instance:SetAttribute("OwnerUserId", normalizedOwnerUserId)
    for _, basePart in ipairs(getBaseParts(instance)) do
        basePart:SetAttribute("OwnerUserId", normalizedOwnerUserId)
    end
end

function WeaponFxController:_createFallbackWeapon(tierName)
    local model = Instance.new("Model")
    model.Name = "LocalFallbackWeapon_" .. tostring(tierName)

    local blade = Instance.new("Part")
    blade.Name = "Blade"
    blade.Anchored = true
    blade.CanCollide = false
    blade.CanTouch = false
    blade.CanQuery = false
    blade.Material = Enum.Material.Neon
    blade.Color = getTierColor(tierName)
    blade.Size = Vector3.new(4.4, 0.18, 0.45)
    blade.Parent = model

    local handle = Instance.new("Part")
    handle.Name = "Handle"
    handle.Anchored = true
    handle.CanCollide = false
    handle.CanTouch = false
    handle.CanQuery = false
    handle.Material = Enum.Material.Metal
    handle.Color = Color3.fromRGB(28, 34, 38)
    handle.Size = Vector3.new(0.75, 0.32, 0.6)
    handle.CFrame = blade.CFrame * CFrame.new(-2.1, 0, 0)
    handle.Parent = model

    model.PrimaryPart = blade
    return model
end

function WeaponFxController:_clearOwnerWeapons(ownerUserId)
    local normalizedOwnerUserId = math.floor(tonumber(ownerUserId) or 0)
    local weaponStates = self._weaponStatesByOwnerUserId[normalizedOwnerUserId] or {}
    for _, weaponState in ipairs(weaponStates) do
        self:_destroyLocalWeaponState(weaponState)
    end
    self._weaponStatesByOwnerUserId[normalizedOwnerUserId] = nil
    if self._localPlayer and normalizedOwnerUserId == self._localPlayer.UserId then
        self._localWeaponStates = {}
    end

    local ownerFolder = self._ownerWeaponFolders[normalizedOwnerUserId]
    if ownerFolder and ownerFolder.Parent then
        ownerFolder:Destroy()
    end
    self._ownerWeaponFolders[normalizedOwnerUserId] = nil
end

function WeaponFxController:_clearLocalWeapons()
    local ownerUserIds = {}
    for ownerUserId in pairs(self._weaponStatesByOwnerUserId) do
        table.insert(ownerUserIds, ownerUserId)
    end
    for _, ownerUserId in ipairs(ownerUserIds) do
        self:_clearOwnerWeapons(ownerUserId)
    end
    self._localWeaponStates = {}

    if self._localWeaponFolder and self._localWeaponFolder.Parent then
        for _, child in ipairs(self._localWeaponFolder:GetChildren()) do
            child:Destroy()
        end
    end
    table.clear(self._ownerWeaponFolders)
end

function WeaponFxController:_destroyLocalWeaponState(weaponState)
    if weaponState and weaponState.Instance and weaponState.Instance.Parent then
        weaponState.Instance:Destroy()
    end
end

function WeaponFxController:_setLocalWeaponStateVisible(weaponState, visible)
    local instance = weaponState and weaponState.Instance
    if not instance then
        return
    end

    for _, basePart in ipairs(getBaseParts(instance)) do
        basePart.LocalTransparencyModifier = visible == true and 0 or 1
    end
end

function WeaponFxController:_buildDistributedAngles(weaponCount, anchorAngle)
    local angles = {}
    if weaponCount <= 0 then
        return angles
    end

    local angleStep = (math.pi * 2) / math.max(1, weaponCount)
    local baseAngle = normalizeAngle(anchorAngle)
    for weaponIndex = 1, weaponCount do
        angles[weaponIndex] = baseAngle + ((weaponIndex - 1) * angleStep)
    end

    return angles
end

function WeaponFxController:_buildVisualIdentity(weaponTier, templateName)
    return tostring(weaponTier or "None") .. ":" .. tostring(templateName or "")
end

function WeaponFxController:_updateLocalWeaponState(weaponState, weaponIndex, weaponTier, templateName, visualIdentity, weaponData, tierConfig, currentAngle)
    weaponState.SlotIndex = weaponIndex
    weaponState.Tier = weaponTier
    weaponState.TemplateName = templateName
    weaponState.VisualIdentity = visualIdentity
    weaponState.CurrentAngle = currentAngle or weaponState.CurrentAngle or 0
    weaponState.OrbitSpeed = tonumber(weaponData and weaponData.orbitSpeed) or getWeaponOrbitSpeed()
    weaponState.OrbitDistance = tonumber(weaponData and weaponData.orbitDistance) or getWeaponOrbitDistance()
    weaponState.OrbitDirection = normalizeOrbitDirection((weaponData and weaponData.orbitDirection) or weaponState.OrbitDirection)
    weaponState.Damage = tonumber(weaponData and weaponData.damage) or tonumber(tierConfig and tierConfig.Damage) or weaponState.Damage or 0
    weaponState.IconImage = tostring((weaponData and weaponData.visualIconImage) or (weaponData and weaponData.iconImage) or weaponState.IconImage or (tierConfig and tierConfig.IconImage) or WeaponTierConfig.GetIconImageForTier(weaponTier))
    weaponState.AuraRadius = tonumber(weaponData and weaponData.auraRadius) or weaponState.AuraRadius or 0
end

function WeaponFxController:_createLocalWeaponState(ownerUserId, weaponIndex, weaponTier, templateName, visualIdentity, weaponData, tierConfig, currentAngle, previousDirection)
    local template
    template, tierConfig = self:_resolveTemplate(weaponTier, templateName)
    if not tierConfig then
        return nil
    end

    local localWeapon = template and template:Clone() or self:_createFallbackWeapon(weaponTier)
    localWeapon.Name = string.format("Local_%d_%s_%02d", math.floor(tonumber(ownerUserId) or 0), tostring(templateName or tierConfig.TemplateName or weaponTier), weaponIndex)
    localWeapon.Parent = self:_getOwnerWeaponFolder(ownerUserId)
    stripRuntimeOnlyDescendants(localWeapon)
    self:_configureLocalWeapon(localWeapon)
    self:_tagLocalWeaponOwner(localWeapon, ownerUserId)

    local weaponState = {
        OwnerUserId = math.floor(tonumber(ownerUserId) or 0),
        Instance = localWeapon,
        HitPart = resolveHitPart(localWeapon),
        OrbitDirection = previousDirection,
    }
    self:_updateLocalWeaponState(weaponState, weaponIndex, weaponTier, templateName, visualIdentity, weaponData, tierConfig, currentAngle)
    self:_addPerfStat("LocalWeaponsCreated")
    return weaponState
end

function WeaponFxController:_rebuildLocalWeapons(payload)
    local ownerUserId = math.floor(tonumber(payload and payload.ownerUserId) or (self._localPlayer and self._localPlayer.UserId) or 0)
    if ownerUserId <= 0 then
        return
    end

    local tierName = tostring(payload and payload.weaponTier or "None")
    local weaponCount = math.max(0, math.floor(tonumber(payload and payload.weaponCount) or 0))
    local weaponPayload = payload and payload.weapons or {}
    local previousWeaponStates = self._weaponStatesByOwnerUserId[ownerUserId] or {}

    local previousAngles = {}
    local previousDirections = {}
    for index, weaponState in ipairs(previousWeaponStates) do
        previousAngles[index] = weaponState.CurrentAngle
        previousDirections[index] = weaponState.OrbitDirection
    end
    local previousLeadAngle = previousWeaponStates[1] and previousWeaponStates[1].CurrentAngle or 0
    local shouldRedistributeAngles = #previousWeaponStates ~= weaponCount
    local redistributedAngles = shouldRedistributeAngles and self:_buildDistributedAngles(weaponCount, previousLeadAngle) or nil

    if weaponCount <= 0 then
        self._lastWeaponSignature = nil
        self:_clearOwnerWeapons(ownerUserId)
        return
    end

    local folder = self:_getOwnerWeaponFolder(ownerUserId)
    if not folder then
        return
    end

    local angleStep = (math.pi * 2) / math.max(1, weaponCount)
    local nextWeaponStates = {}
    for weaponIndex = 1, weaponCount do
        local weaponData = weaponPayload[weaponIndex]
        local weaponTier = tostring((weaponData and weaponData.tier) or tierName)
        local tierConfig = WeaponTierConfig.Tiers[weaponTier]
        local templateName = resolveVisualTemplateName(weaponData, tierConfig)
        local visualIdentity = self:_buildVisualIdentity(weaponTier, templateName)
        local previousState = previousWeaponStates[weaponIndex]
        local currentAngle = redistributedAngles and redistributedAngles[weaponIndex] or previousAngles[weaponIndex] or ((weaponIndex - 1) * angleStep)

        if not tierConfig then
            continue
        end

        if previousState
            and previousState.Instance
            and previousState.Instance.Parent
            and previousState.VisualIdentity == visualIdentity
        then
            self:_updateLocalWeaponState(previousState, weaponIndex, weaponTier, templateName, visualIdentity, weaponData, tierConfig, currentAngle)
            nextWeaponStates[weaponIndex] = previousState
        else
            self:_destroyLocalWeaponState(previousState)
            nextWeaponStates[weaponIndex] = self:_createLocalWeaponState(
                ownerUserId,
                weaponIndex,
                weaponTier,
                templateName,
                visualIdentity,
                weaponData,
                tierConfig,
                currentAngle,
                previousDirections[weaponIndex]
            )
        end
    end

    for index = weaponCount + 1, #previousWeaponStates do
        self:_destroyLocalWeaponState(previousWeaponStates[index])
    end

    self._weaponStatesByOwnerUserId[ownerUserId] = nextWeaponStates
    if self._localPlayer and ownerUserId == self._localPlayer.UserId then
        self._localWeaponStates = nextWeaponStates
    end
end

function WeaponFxController:_calculateOrbitCenter(rootPart)
    return rootPart.Position
end

function WeaponFxController:_getOwnerRootPart(ownerUserId)
    local player = Players:GetPlayerByUserId(math.floor(tonumber(ownerUserId) or 0))
    local character = player and player.Character
    return character and character:FindFirstChild("HumanoidRootPart") or nil
end

function WeaponFxController:_hasOwnerPlayer(ownerUserId)
    return Players:GetPlayerByUserId(math.floor(tonumber(ownerUserId) or 0)) ~= nil
end

function WeaponFxController:_buildWeaponCFrame(centerPosition, weaponState)
    local orbitDistance = tonumber(weaponState and weaponState.OrbitDistance) or getWeaponOrbitDistance()
    local offset = Vector3.new(
        math.cos(weaponState.CurrentAngle) * orbitDistance,
        GameConfig.WEAPON.OrbitHeight,
        math.sin(weaponState.CurrentAngle) * orbitDistance
    )
    local position = centerPosition + offset
    local outward = Vector3.new(offset.X, 0, offset.Z)
    if outward.Magnitude <= 0 then
        outward = Vector3.xAxis
    else
        outward = outward.Unit
    end

    return CFrame.fromMatrix(position, outward, Vector3.yAxis, outward:Cross(Vector3.yAxis))
end

function WeaponFxController:_updateLocalWeaponTransforms(deltaTime)
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    local hasWeaponStates = false
    for _, weaponStates in pairs(self._weaponStatesByOwnerUserId) do
        if #weaponStates > 0 then
            hasWeaponStates = true
            break
        end
    end

    if not hasWeaponStates then
        if startedAt then
            self:_addPerfStat("RenderFrames")
            self:_logPerfStats(os.clock())
        end
        return
    end

    local updatedCount = 0
    local sampleCount = 0
    local ownersToClear = {}
    for ownerUserId, weaponStates in pairs(self._weaponStatesByOwnerUserId) do
        local rootPart = self:_getOwnerRootPart(ownerUserId)
        if not rootPart then
            if self:_hasOwnerPlayer(ownerUserId) then
                for _, weaponState in ipairs(weaponStates) do
                    self:_setLocalWeaponStateVisible(weaponState, false)
                end
            else
                table.insert(ownersToClear, ownerUserId)
            end
            continue
        end

        local centerPosition = self:_calculateOrbitCenter(rootPart)
        sampleCount += #weaponStates
        for _, weaponState in ipairs(weaponStates) do
            if weaponState.Instance and weaponState.Instance.Parent then
                self:_setLocalWeaponStateVisible(weaponState, true)
                weaponState.OrbitSpeed = tonumber(weaponState.OrbitSpeed) or getWeaponOrbitSpeed()
                weaponState.OrbitDistance = tonumber(weaponState.OrbitDistance) or getWeaponOrbitDistance()
                weaponState.CurrentAngle += (weaponState.OrbitSpeed * (weaponState.OrbitDirection or 1)) * deltaTime
                setWorldCFrame(weaponState.Instance, self:_buildWeaponCFrame(centerPosition, weaponState))
                updatedCount += 1
            end
        end
    end
    for _, ownerUserId in ipairs(ownersToClear) do
        self:_clearOwnerWeapons(ownerUserId)
    end

    if startedAt then
        self:_addPerfStat("RenderFrames")
        self:_addPerfStat("LocalWeaponSamples", sampleCount)
        self:_addPerfStat("LocalWeaponUpdates", updatedCount)
        self:_addPerfStat("TransformElapsedSeconds", os.clock() - startedAt)
        self:_logPerfStats(os.clock())
    end
end

function WeaponFxController:_hideOwnedServerWeapons()
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil

    local now = os.clock()
    if not self._serverWeaponVisibilityDirty and now < self._nextServerWeaponVisibilityRefreshClock then
        return
    end
    self._serverWeaponVisibilityDirty = false
    self._nextServerWeaponVisibilityRefreshClock = now + SERVER_WEAPON_VISIBILITY_REFRESH_SECONDS

    local weaponsFolder = self:_resolveRuntimeWeaponsFolder()

    for basePart in pairs(self._hiddenServerParts) do
        if not basePart.Parent then
            self._hiddenServerParts[basePart] = nil
        elseif math.max(0, tonumber(resolveOwnerUserId(basePart)) or 0) <= 0 then
            basePart.LocalTransparencyModifier = 0
            self._hiddenServerParts[basePart] = nil
        end
    end

    for effect, previousEnabled in pairs(self._hiddenServerEffects) do
        if not effect.Parent then
            self._hiddenServerEffects[effect] = nil
        elseif math.max(0, tonumber(resolveOwnerUserId(effect)) or 0) <= 0 then
            effect.Enabled = previousEnabled
            self._hiddenServerEffects[effect] = nil
        end
    end

    if not weaponsFolder then
        return
    end

    for _, basePart in ipairs(getRuntimeWeaponParts(weaponsFolder)) do
        if not self._hiddenServerParts[basePart] and math.max(0, tonumber(resolveOwnerUserId(basePart)) or 0) > 0 then
            self._hiddenServerParts[basePart] = true
            basePart.LocalTransparencyModifier = 1
            self:_addPerfStat("ServerPartsHidden")
        end
    end

    for _, effect in ipairs(getRuntimeWeaponVisualEffects(weaponsFolder)) do
        if not self._hiddenServerEffects[effect] and math.max(0, tonumber(resolveOwnerUserId(effect)) or 0) > 0 then
            self._hiddenServerEffects[effect] = effect.Enabled
            effect.Enabled = false
            self:_addPerfStat("ServerEffectsHidden")
        end
    end

    if startedAt then
        self:_addPerfStat("VisibilityRefreshes")
        self:_addPerfStat("VisibilityElapsedSeconds", os.clock() - startedAt)
    end
end

function WeaponFxController:_onWeaponStateSync(payload)
    self:_addPerfStat("WeaponStateSyncEvents")
    self:_markServerWeaponVisibilityDirty()
    local ownerUserId = math.floor(tonumber(payload and payload.ownerUserId) or (self._localPlayer and self._localPlayer.UserId) or 0)
    if ownerUserId <= 0 then
        return
    end
    self:_rebuildLocalWeapons({
        ownerUserId = ownerUserId,
        weaponTier = tostring(payload and payload.weaponTier or "None"),
        weaponCount = math.max(0, math.floor(tonumber(payload and payload.weaponCount) or 0)),
        weaponIcon = payload and payload.weaponIcon or nil,
        weapons = payload and payload.weapons or {},
    })
end

function WeaponFxController:GetLocalWeaponStates()
    return self._localWeaponStates
end

function WeaponFxController:_resetPerfStats()
    self._perfStats = {
        RenderFrames = 0,
        LocalWeaponSamples = 0,
        LocalWeaponUpdates = 0,
        LocalWeaponsCreated = 0,
        WeaponStateSyncEvents = 0,
        RuntimeInstanceBinds = 0,
        RuntimeInstanceUnbinds = 0,
        VisibilityRefreshes = 0,
        ServerPartsHidden = 0,
        ServerEffectsHidden = 0,
        TransformElapsedSeconds = 0,
        VisibilityElapsedSeconds = 0,
    }
end

function WeaponFxController:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function WeaponFxController:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats
    if stats and stats.RenderFrames and stats.RenderFrames > 0 then
        local localFolder = self._localWeaponFolder
        local runtimeFolder = self._runtimeWeaponsFolder
        print(string.format(
            "[Diag][WeaponFxController] frames=%d localWeapons=%d visualOwners=%d localFolderChildren=%d localFolderDesc=%d runtimeChildren=%d runtimeDesc=%d runtimeBinds=%d hiddenParts=%d hiddenEffects=%d weaponSync=%d created=%d updates=%d visibilityRefreshes=%d partsHidden=%d effectsHidden=%d transformMs=%.3f visibilityMs=%.3f",
            stats.RenderFrames,
            #self._localWeaponStates,
            countMapEntries(self._weaponStatesByOwnerUserId),
            localFolder and #localFolder:GetChildren() or 0,
            countDescendants(localFolder),
            runtimeFolder and #runtimeFolder:GetChildren() or 0,
            countDescendants(runtimeFolder),
            countMapEntries(self._runtimeWeaponInstanceConnections),
            countMapEntries(self._hiddenServerParts),
            countMapEntries(self._hiddenServerEffects),
            stats.WeaponStateSyncEvents or 0,
            stats.LocalWeaponsCreated or 0,
            stats.LocalWeaponUpdates or 0,
            stats.VisibilityRefreshes or 0,
            stats.ServerPartsHidden or 0,
            stats.ServerEffectsHidden or 0,
            (stats.TransformElapsedSeconds or 0) * 1000,
            (stats.VisibilityElapsedSeconds or 0) * 1000
        ))
    end

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function WeaponFxController:_requestStateSync()
    if self._requestStateSyncEvent and self._requestStateSyncEvent.Parent then
        self._requestStateSyncEvent:FireServer()
    end
end

function WeaponFxController:_waitForLocalRootAndRequestStateSync(character)
    if not character then
        return
    end

    task.spawn(function()
        local rootPart = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
        if rootPart and rootPart.Parent and character.Parent then
            self:_requestStateSync()
        end
    end)
end

function WeaponFxController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._runtimeWeaponFolderConnections)
    self:_clearRuntimeWeaponInstanceConnections()
    self:_clearLocalWeapons()
    self._runtimeWeaponsFolder = nil
    self._serverWeaponVisibilityDirty = true
    self._nextServerWeaponVisibilityRefreshClock = 0
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEventsFolder = eventsFolder:WaitForChild(RemoteNames.BattleEventsFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    local weaponStateSyncEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.WeaponStateSync)

    if self._syncConnection then
        self._syncConnection:Disconnect()
        self._syncConnection = nil
    end
    self._syncConnection = weaponStateSyncEvent.OnClientEvent:Connect(function(payload)
        self:_onWeaponStateSync(payload)
    end)
    self._requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    if self._requestStateSyncEvent and self._requestStateSyncEvent:IsA("RemoteEvent") then
        task.defer(function()
            self:_requestStateSync()
        end)
    else
        self._requestStateSyncEvent = nil
    end

    if self._playerRemovingConnection then
        self._playerRemovingConnection:Disconnect()
        self._playerRemovingConnection = nil
    end
    self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
        self:_clearOwnerWeapons(player.UserId)
    end)

    if self._localCharacterAddedConnection then
        self._localCharacterAddedConnection:Disconnect()
        self._localCharacterAddedConnection = nil
    end
    if self._localPlayer then
        self._localCharacterAddedConnection = self._localPlayer.CharacterAdded:Connect(function(character)
            self:_waitForLocalRootAndRequestStateSync(character)
        end)
        if self._localPlayer.Character then
            self:_waitForLocalRootAndRequestStateSync(self._localPlayer.Character)
        end
    end

    if self._renderConnection then
        self._renderConnection:Disconnect()
        self._renderConnection = nil
    end
    self._renderConnection = RunService.RenderStepped:Connect(function(deltaTime)
        self:_hideOwnedServerWeapons()
        self:_updateLocalWeaponTransforms(deltaTime)
    end)
end

return WeaponFxController
