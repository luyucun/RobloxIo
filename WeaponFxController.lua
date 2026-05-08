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
WeaponFxController._hiddenServerParts = {}
WeaponFxController._hiddenServerEffects = {}
WeaponFxController._lastWeaponSignature = nil

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

function WeaponFxController:_resolveTemplate(tierName)
    local tierConfig = WeaponTierConfig.Tiers[tostring(tierName or "")]
    if not tierConfig then
        return nil, nil
    end

    local modelRoot = findChildOfClass(ReplicatedStorage, WeaponTierConfig.ModelRootFolderName, "Folder")
    local weaponFolder = findChildOfClass(modelRoot, WeaponTierConfig.WeaponFolderName, "Folder")
    return findVisualWeaponTemplate(weaponFolder, tierConfig.TemplateName), tierConfig
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

function WeaponFxController:_clearLocalWeapons()
    for _, weaponState in ipairs(self._localWeaponStates) do
        if weaponState.Instance and weaponState.Instance.Parent then
            weaponState.Instance:Destroy()
        end
    end
    self._localWeaponStates = {}

    if self._localWeaponFolder and self._localWeaponFolder.Parent then
        for _, child in ipairs(self._localWeaponFolder:GetChildren()) do
            child:Destroy()
        end
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

function WeaponFxController:_rebuildLocalWeapons(payload)
    local tierName = tostring(payload and payload.weaponTier or "None")
    local weaponCount = math.max(0, math.floor(tonumber(payload and payload.weaponCount) or 0))
    local weaponPayload = payload and payload.weapons or {}
    local signature = string.format("%s:%d", tierName, weaponCount)
    if signature == self._lastWeaponSignature then
        for weaponIndex, weaponState in ipairs(self._localWeaponStates) do
            local weaponData = weaponPayload[weaponIndex]
            if weaponData then
                weaponState.OrbitDirection = normalizeOrbitDirection(weaponData.orbitDirection or weaponState.OrbitDirection)
                weaponState.Damage = tonumber(weaponData.damage) or weaponState.Damage
                weaponState.AuraRadius = tonumber(weaponData.auraRadius) or weaponState.AuraRadius
                weaponState.IconImage = tostring(weaponData.iconImage or weaponState.IconImage or WeaponTierConfig.GetIconImageForTier(tierName))
            end
        end
        return
    end

    local previousAngles = {}
    local previousDirections = {}
    for index, weaponState in ipairs(self._localWeaponStates) do
        previousAngles[index] = weaponState.CurrentAngle
        previousDirections[index] = weaponState.OrbitDirection
    end
    local previousLeadAngle = self._localWeaponStates[1] and self._localWeaponStates[1].CurrentAngle or 0
    local shouldRedistributeAngles = #self._localWeaponStates ~= weaponCount
    local redistributedAngles = shouldRedistributeAngles and self:_buildDistributedAngles(weaponCount, previousLeadAngle) or nil

    self._lastWeaponSignature = signature
    self:_clearLocalWeapons()

    local template, tierConfig = self:_resolveTemplate(tierName)
    if weaponCount <= 0 or not tierConfig then
        return
    end

    local folder = self:_getLocalWeaponFolder()
    if not folder then
        return
    end

    local angleStep = (math.pi * 2) / math.max(1, weaponCount)
    for weaponIndex = 1, weaponCount do
        local localWeapon = template and template:Clone() or self:_createFallbackWeapon(tierName)
        localWeapon.Name = string.format("Local_%s_%02d", tostring(tierConfig.TemplateName or tierName), weaponIndex)
        localWeapon.Parent = folder
        stripRuntimeOnlyDescendants(localWeapon)
        self:_configureLocalWeapon(localWeapon)

        table.insert(self._localWeaponStates, {
            Instance = localWeapon,
            HitPart = resolveAuraPart(localWeapon) or (localWeapon:IsA("Model") and localWeapon.PrimaryPart or nil) or (localWeapon:IsA("BasePart") and localWeapon or nil),
            CurrentAngle = redistributedAngles and redistributedAngles[weaponIndex] or previousAngles[weaponIndex] or ((weaponIndex - 1) * angleStep),
            OrbitRadius = tonumber(tierConfig.OrbitRadius) or 6,
            OrbitSpeed = tonumber(tierConfig.OrbitSpeed) or 2.8,
            OrbitDirection = normalizeOrbitDirection((weaponPayload[weaponIndex] and weaponPayload[weaponIndex].orbitDirection) or previousDirections[weaponIndex]),
            Damage = tonumber(weaponPayload[weaponIndex] and weaponPayload[weaponIndex].damage) or tonumber(tierConfig.Damage) or 0,
            IconImage = tostring((weaponPayload[weaponIndex] and weaponPayload[weaponIndex].iconImage) or tierConfig.IconImage or WeaponTierConfig.GetIconImageForTier(tierName)),
            AuraRadius = tonumber(weaponPayload[weaponIndex] and weaponPayload[weaponIndex].auraRadius) or 0,
        })
    end
end

function WeaponFxController:_calculateOrbitCenter(rootPart)
    return rootPart.Position
end

function WeaponFxController:_buildWeaponCFrame(centerPosition, weaponState)
    local offset = Vector3.new(
        math.cos(weaponState.CurrentAngle) * weaponState.OrbitRadius,
        GameConfig.WEAPON.OrbitHeight,
        math.sin(weaponState.CurrentAngle) * weaponState.OrbitRadius
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
    if #self._localWeaponStates <= 0 then
        return
    end

    local character = self._localPlayer and self._localPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        return
    end

    local centerPosition = self:_calculateOrbitCenter(rootPart)
    for _, weaponState in ipairs(self._localWeaponStates) do
        if weaponState.Instance and weaponState.Instance.Parent then
            weaponState.CurrentAngle += (weaponState.OrbitSpeed * (weaponState.OrbitDirection or 1)) * deltaTime
            setWorldCFrame(weaponState.Instance, self:_buildWeaponCFrame(centerPosition, weaponState))
        end
    end
end

function WeaponFxController:_hideOwnedServerWeapons()
    local localUserId = self._localPlayer and self._localPlayer.UserId
    if not localUserId then
        return
    end

    for basePart in pairs(self._hiddenServerParts) do
        if not basePart.Parent then
            self._hiddenServerParts[basePart] = nil
        elseif resolveOwnerUserId(basePart) ~= localUserId then
            basePart.LocalTransparencyModifier = 0
            self._hiddenServerParts[basePart] = nil
        end
    end

    for effect, previousEnabled in pairs(self._hiddenServerEffects) do
        if not effect.Parent then
            self._hiddenServerEffects[effect] = nil
        elseif resolveOwnerUserId(effect) ~= localUserId then
            effect.Enabled = previousEnabled
            self._hiddenServerEffects[effect] = nil
        end
    end

    local weaponsFolder = getRuntimeWeaponsFolder()
    if not weaponsFolder then
        return
    end

    for _, basePart in ipairs(getRuntimeWeaponParts(weaponsFolder)) do
        if not self._hiddenServerParts[basePart] and resolveOwnerUserId(basePart) == localUserId then
            self._hiddenServerParts[basePart] = true
            basePart.LocalTransparencyModifier = 1
        end
    end

    for _, effect in ipairs(getRuntimeWeaponVisualEffects(weaponsFolder)) do
        if not self._hiddenServerEffects[effect] and resolveOwnerUserId(effect) == localUserId then
            self._hiddenServerEffects[effect] = effect.Enabled
            effect.Enabled = false
        end
    end
end

function WeaponFxController:_onWeaponStateSync(payload)
    self:_rebuildLocalWeapons({
        weaponTier = tostring(payload and payload.weaponTier or "None"),
        weaponCount = math.max(0, math.floor(tonumber(payload and payload.weaponCount) or 0)),
        weaponIcon = payload and payload.weaponIcon or nil,
        weapons = payload and payload.weapons or {},
    })
end

function WeaponFxController:GetLocalWeaponStates()
    return self._localWeaponStates
end

function WeaponFxController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEventsFolder = eventsFolder:WaitForChild(RemoteNames.BattleEventsFolder)
    local weaponStateSyncEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.WeaponStateSync)

    if self._syncConnection then
        self._syncConnection:Disconnect()
        self._syncConnection = nil
    end
    self._syncConnection = weaponStateSyncEvent.OnClientEvent:Connect(function(payload)
        self:_onWeaponStateSync(payload)
    end)

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
