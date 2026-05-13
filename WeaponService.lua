--[[
脚本名字: WeaponService
脚本文件: WeaponService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/WeaponService
]]

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

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
        "[WeaponService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")
local SkinConfig = requireSharedModule("SkinConfig")

local WeaponService = {}

WeaponService._playerStateService = nil
WeaponService._remoteEventService = nil
WeaponService._botService = nil
WeaponService._runtimeFolder = nil
WeaponService._brokenDebrisFolder = nil
WeaponService._templateFolder = nil
WeaponService._weaponStateSyncEvent = nil
WeaponService._weaponsByCombatUserId = {}
WeaponService._weaponByPart = {}
WeaponService._brokenDebrisStates = {}
WeaponService._heartbeatConnection = nil
WeaponService._nextWeaponId = 1

local function findOrCreateFolder(parent, folderName)
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name == folderName and child:IsA("Folder") then
            return child
        end
    end

    local folder = Instance.new("Folder")
    folder.Name = folderName
    folder.Parent = parent
    return folder
end

local function createWeaponPlaceholder(parent, tierName, tierConfig)
    local tierIndex = math.max(1, tonumber(tierConfig and tierConfig.TierIndex) or WeaponTierConfig.GetTierIndex(tierName))
    local hue = ((tierIndex - 1) * 0.075) % 1
    local bladeLength = math.min(7.5, 4.2 + ((tierIndex - 1) * 0.035))

    local placeholder = Instance.new("Part")
    placeholder.Name = tierConfig.TemplateName
    placeholder.Anchored = true
    placeholder.CanCollide = false
    placeholder.CanTouch = false
    placeholder.CanQuery = false
    placeholder.Massless = true
    placeholder.Material = Enum.Material.Neon
    placeholder.Color = Color3.fromHSV(hue, 0.72, 1)
    placeholder.Size = Vector3.new(bladeLength, 0.2, 0.55)
    placeholder:SetAttribute("IsPlaceholderTemplate", true)
    placeholder.Parent = parent
    return placeholder
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

local function getCombatUserId(actor)
    return ActorUtils.GetCombatUserId(actor)
end

local function getWeaponOrbitSpeed()
    return tonumber(GameConfig.WEAPON and GameConfig.WEAPON.OrbitSpeed) or 2.8
end

local function getWeaponOrbitDistance()
    return 6
end

local function normalizeAngle(angle)
    local tau = math.pi * 2
    local normalized = (tonumber(angle) or 0) % tau
    if normalized < 0 then
        normalized += tau
    end
    return normalized
end

local function findWeaponTemplate(folder, templateName)
    for _, child in ipairs(folder:GetChildren()) do
        if child.Name == templateName and (child:IsA("BasePart") or child:IsA("Model")) then
            return child
        end
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

local function getInstanceCFrame(instance)
    if instance:IsA("Model") then
        return instance:GetPivot()
    end
    if instance:IsA("BasePart") then
        return instance.CFrame
    end
    return CFrame.identity
end

local function findFirstBasePart(instance)
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance
    end
    return instance:FindFirstChildWhichIsA("BasePart", true)
end

local function resolveAuraPart(runtimeInstance)
    local auraName = GameConfig.WEAPON.AuraPartName or "Aura"
    if runtimeInstance:IsA("BasePart") and runtimeInstance.Name == auraName then
        return runtimeInstance
    end

    local auraNode = runtimeInstance:FindFirstChild(auraName, true)
    return findFirstBasePart(auraNode)
end

local function createFallbackAuraPart(runtimeInstance)
    if runtimeInstance:IsA("BasePart") then
        return runtimeInstance
    end

    local primaryPart = nil
    local parent = runtimeInstance
    local sourceCFrame = getInstanceCFrame(runtimeInstance)
    local sourceSize = nil

    if runtimeInstance:IsA("Model") then
        primaryPart = runtimeInstance.PrimaryPart or findFirstBasePart(runtimeInstance)
        local _, boundingSize = runtimeInstance:GetBoundingBox()
        sourceSize = boundingSize
    end

    if not (primaryPart and parent and sourceCFrame and sourceSize) then
        return nil
    end

    local auraPart = Instance.new("Part")
    auraPart.Name = GameConfig.WEAPON.AuraPartName or "Aura"
    auraPart.Anchored = true
    auraPart.CanCollide = false
    auraPart.CanTouch = false
    auraPart.CanQuery = false
    auraPart.Massless = true
    auraPart.Transparency = GameConfig.WEAPON.FallbackAuraTransparency
    auraPart.Size = sourceSize * (GameConfig.WEAPON.FallbackAuraScale or 1.15)
    auraPart.CFrame = sourceCFrame
    auraPart.Parent = parent
    return auraPart
end

local function getPartCollisionReach(basePart)
    if not (basePart and basePart.Parent) then
        return 0
    end
    local size = basePart.Size
    return math.max(size.X, size.Y, size.Z) * 0.5
end

local function copyAuraShape(sourceTemplate, targetInstance, targetAuraPart)
    if not (sourceTemplate and targetInstance and targetAuraPart and targetAuraPart:IsA("BasePart")) then
        return
    end

    local sourceAuraPart = resolveAuraPart(sourceTemplate)
    if sourceAuraPart and sourceAuraPart:IsA("BasePart") then
        local sourcePivot = getInstanceCFrame(sourceTemplate)
        local targetPivot = getInstanceCFrame(targetInstance)
        targetAuraPart.Size = sourceAuraPart.Size
        targetAuraPart.CFrame = targetPivot * sourcePivot:ToObjectSpace(sourceAuraPart.CFrame)
        targetAuraPart.Transparency = math.max(targetAuraPart.Transparency, GameConfig.WEAPON.FallbackAuraTransparency or 1)
    end
end

local function applyWeaponAttributes(instance, weaponState)
    if not (instance and weaponState) then
        return
    end

    instance:SetAttribute("WeaponId", weaponState.Id)
    instance:SetAttribute("OwnerUserId", weaponState.OwnerUserId)
    instance:SetAttribute("Tier", weaponState.Tier)
    instance:SetAttribute("TierIndex", weaponState.TierIndex)
    instance:SetAttribute("Damage", weaponState.BaseDamage)
    instance:SetAttribute("IconImage", weaponState.IconImage or WeaponTierConfig.DefaultIconImage)
    instance:SetAttribute("VisualSkinId", weaponState.VisualSkinId)
    instance:SetAttribute("VisualTemplateName", weaponState.VisualTemplateName)
    instance:SetAttribute("VisualIconImage", weaponState.VisualIconImage)
    instance:SetAttribute("OrbitDirection", weaponState.OrbitDirection or 1)

    for _, basePart in ipairs(getBaseParts(instance)) do
        basePart:SetAttribute("WeaponId", weaponState.Id)
        basePart:SetAttribute("OwnerUserId", weaponState.OwnerUserId)
        basePart:SetAttribute("Tier", weaponState.Tier)
        basePart:SetAttribute("TierIndex", weaponState.TierIndex)
        basePart:SetAttribute("Damage", weaponState.BaseDamage)
        basePart:SetAttribute("IconImage", weaponState.IconImage or WeaponTierConfig.DefaultIconImage)
        basePart:SetAttribute("VisualSkinId", weaponState.VisualSkinId)
        basePart:SetAttribute("VisualTemplateName", weaponState.VisualTemplateName)
        basePart:SetAttribute("VisualIconImage", weaponState.VisualIconImage)
        basePart:SetAttribute("OrbitDirection", weaponState.OrbitDirection or 1)
    end
end

function WeaponService:_resolveTemplateFolder()
    local modelRoot = findOrCreateFolder(ReplicatedStorage, WeaponTierConfig.ModelRootFolderName)
    local weaponFolder = findOrCreateFolder(modelRoot, WeaponTierConfig.WeaponFolderName)

    for _, tierName in ipairs(WeaponTierConfig.Order) do
        local tierConfig = WeaponTierConfig.Tiers[tierName]
        if tierConfig then
            local template = findWeaponTemplate(weaponFolder, tierConfig.TemplateName)
            if not template then
                createWeaponPlaceholder(weaponFolder, tierName, tierConfig)
            end
        end
    end

    return weaponFolder
end

function WeaponService:_createRuntimeFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, WeaponTierConfig.RuntimeRootFolderName)
    return findOrCreateFolder(runtimeRoot, WeaponTierConfig.RuntimeFolderName)
end

function WeaponService:_createBrokenDebrisFolder()
    local runtimeRoot = findOrCreateFolder(Workspace, WeaponTierConfig.RuntimeRootFolderName)
    return findOrCreateFolder(runtimeRoot, GameConfig.WEAPON.BrokenDebrisFolderName)
end

function WeaponService:_clearRuntimeFolder()
    if not self._runtimeFolder then
        return
    end

    for _, child in ipairs(self._runtimeFolder:GetChildren()) do
        child:Destroy()
    end
end

function WeaponService:_clearBrokenDebrisFolder()
    if not self._brokenDebrisFolder then
        return
    end

    for _, child in ipairs(self._brokenDebrisFolder:GetChildren()) do
        child:Destroy()
    end
end

function WeaponService:_resolveActorByCombatUserId(combatUserId)
    if tonumber(combatUserId) and tonumber(combatUserId) > 0 then
        return Players:GetPlayerByUserId(tonumber(combatUserId))
    end

    if self._botService then
        return self._botService:GetActorByCombatUserId(combatUserId)
    end

    return nil
end

function WeaponService:_clearActorWeapons(combatUserId)
    local weaponStates = self._weaponsByCombatUserId[combatUserId]
    if not weaponStates then
        return
    end

    for _, weaponState in ipairs(weaponStates) do
        self:_destroyWeaponState(weaponState)
    end

    self._weaponsByCombatUserId[combatUserId] = nil
end

function WeaponService:_destroyWeaponState(weaponState)
    if not weaponState then
        return
    end

    if weaponState.HitPart then
        self._weaponByPart[weaponState.HitPart] = nil
    end
    if weaponState.AuraPart and weaponState.AuraPart ~= weaponState.HitPart then
        self._weaponByPart[weaponState.AuraPart] = nil
    end

    if weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
        weaponState.RuntimeInstance:Destroy()
    end

    weaponState.RuntimeInstance = nil
    weaponState.HitPart = nil
    weaponState.AuraPart = nil
    weaponState.Alive = false
end

function WeaponService:_buildWeaponPayload(weaponStates)
    local payload = {}
    for _, weaponState in ipairs(weaponStates) do
        table.insert(payload, {
            id = weaponState.Id,
            tier = weaponState.Tier,
            tierIndex = weaponState.TierIndex,
            damage = weaponState.BaseDamage,
            iconImage = weaponState.IconImage or WeaponTierConfig.GetIconImageForTier(weaponState.Tier),
            visualSkinId = weaponState.VisualSkinId,
            visualTemplateName = weaponState.VisualTemplateName,
            visualIconImage = weaponState.VisualIconImage,
            orbitIndex = weaponState.OrbitIndex,
            orbitSpeed = getWeaponOrbitSpeed(),
            orbitDirection = weaponState.OrbitDirection or 1,
            auraRadius = weaponState.AuraRadius or 0,
        })
    end
    return payload
end

function WeaponService:_fireWeaponStateSync(actor, tier, count, weaponStates)
    if not self._weaponStateSyncEvent then
        return
    end
    if not ActorUtils.IsPlayer(actor) then
        return
    end

    local syncTier = tostring(tier or "None")
    local syncTierIndex = WeaponTierConfig.GetTierIndex(syncTier)
    local syncCount = math.max(0, math.floor(tonumber(count) or 0))
    for _, weaponState in ipairs(weaponStates or {}) do
        local tierIndex = math.max(0, math.floor(tonumber(weaponState and weaponState.TierIndex) or 0))
        if tierIndex > syncTierIndex then
            syncTierIndex = tierIndex
            syncTier = tostring(weaponState.Tier or WeaponTierConfig.Order[tierIndex] or syncTier)
        end
    end
    if weaponStates then
        syncCount = #weaponStates
    end

    self._weaponStateSyncEvent:FireClient(actor, {
        weaponTier = syncTier,
        weaponTierIndex = syncTierIndex,
        weaponCount = syncCount,
        weaponIcon = WeaponTierConfig.GetIconImageForTier(syncTier),
        visualSkinId = weaponStates and weaponStates[1] and weaponStates[1].VisualSkinId or nil,
        visualTemplateName = weaponStates and weaponStates[1] and weaponStates[1].VisualTemplateName or nil,
        visualIconImage = weaponStates and weaponStates[1] and weaponStates[1].VisualIconImage or nil,
        weapons = self:_buildWeaponPayload(weaponStates or {}),
        timestamp = os.clock(),
    })
end

function WeaponService:GetWeaponStates(actor)
    if not actor then
        return {}
    end
    return self._weaponsByCombatUserId[getCombatUserId(actor)] or {}
end

function WeaponService:GetWeaponStateFromPart(part)
    return self._weaponByPart[part]
end

function WeaponService:_configureRuntimeInstance(runtimeInstance)
    local baseParts = getBaseParts(runtimeInstance)
    if #baseParts <= 0 then
        return nil
    end

    local primaryPart = nil
    if runtimeInstance:IsA("BasePart") then
        primaryPart = runtimeInstance
    elseif runtimeInstance:IsA("Model") then
        primaryPart = runtimeInstance.PrimaryPart or baseParts[1]
    end

    local auraPart = resolveAuraPart(runtimeInstance) or createFallbackAuraPart(runtimeInstance) or primaryPart

    for _, basePart in ipairs(baseParts) do
        basePart.Anchored = true
        basePart.CanCollide = false
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
    end

    if auraPart then
        auraPart.Anchored = true
        auraPart.CanCollide = false
        auraPart.CanTouch = false
        auraPart.CanQuery = false
        auraPart.Massless = true
        auraPart:SetAttribute("IsWeaponAura", true)
    end

    return auraPart
end

function WeaponService:GetWeaponHitPart(weaponState)
    local hitPart = weaponState and weaponState.HitPart
    if hitPart and hitPart.Parent then
        return hitPart
    end
    return nil
end

function WeaponService:GetWeaponHitPosition(weaponState)
    local hitPart = self:GetWeaponHitPart(weaponState)
    return hitPart and hitPart.Position or nil
end

function WeaponService:GetWeaponHitRadius(weaponState)
    local hitPart = self:GetWeaponHitPart(weaponState)
    return getPartCollisionReach(hitPart)
end

function WeaponService:IsWeaponHitPosition(weaponState, targetPosition, targetRadius)
    local hitPart = self:GetWeaponHitPart(weaponState)
    if not (hitPart and typeof(targetPosition) == "Vector3") then
        return false
    end

    local radius = math.max(0, tonumber(targetRadius) or 0)
    local localPosition = hitPart.CFrame:PointToObjectSpace(targetPosition)
    local halfSize = hitPart.Size * 0.5
    local dx = math.max(math.abs(localPosition.X) - halfSize.X, 0)
    local dy = math.max(math.abs(localPosition.Y) - halfSize.Y, 0)
    local dz = math.max(math.abs(localPosition.Z) - halfSize.Z, 0)
    return (dx * dx) + (dy * dy) + (dz * dz) <= radius * radius
end

function WeaponService:_setRuntimeCFrame(runtimeInstance, targetCFrame)
    if runtimeInstance:IsA("Model") then
        runtimeInstance:PivotTo(targetCFrame)
    elseif runtimeInstance:IsA("BasePart") then
        runtimeInstance.CFrame = targetCFrame
    end
end

function WeaponService:_resolveBrokenDebrisDirection(weaponState, context)
    local launchDirection = context and context.launchDirection
    if typeof(launchDirection) == "Vector3" then
        launchDirection = Vector3.new(launchDirection.X, 0, launchDirection.Z)
        if launchDirection.Magnitude > 0 then
            return launchDirection.Unit
        end
    end

    local impactPosition = context and context.impactPosition
    local hitPart = self:GetWeaponHitPart(weaponState)
    if typeof(impactPosition) == "Vector3" and hitPart then
        local fallback = hitPart.Position - impactPosition
        fallback = Vector3.new(fallback.X, 0, fallback.Z)
        if fallback.Magnitude > 0 then
            return fallback.Unit
        end
    end

    if weaponState then
        local fallback = Vector3.new(math.cos(weaponState.CurrentAngle), 0, math.sin(weaponState.CurrentAngle))
        if fallback.Magnitude > 0 then
            return fallback.Unit
        end
    end

    return Vector3.xAxis
end

function WeaponService:_configureBrokenDebrisInstance(instance)
    stripRuntimeOnlyDescendants(instance)

    local baseParts = getBaseParts(instance)
    if instance:IsA("Model") and #baseParts > 0 then
        if not instance.PrimaryPart or not instance.PrimaryPart.Parent then
            instance.PrimaryPart = baseParts[1]
        end

        local primaryPart = instance.PrimaryPart
        for _, part in ipairs(baseParts) do
            if part ~= primaryPart then
                local weld = Instance.new("WeldConstraint")
                weld.Part0 = primaryPart
                weld.Part1 = part
                weld.Parent = primaryPart
            end
        end
    end

    local originalTransparencyByPart = {}
    for _, basePart in ipairs(baseParts) do
        basePart.Anchored = true
        basePart.CanCollide = false
        basePart.CanTouch = false
        basePart.CanQuery = false
        basePart.Massless = true
        basePart:SetAttribute("WeaponId", nil)
        basePart:SetAttribute("OwnerUserId", nil)
        basePart:SetAttribute("Tier", nil)
        basePart:SetAttribute("TierIndex", nil)
        basePart:SetAttribute("Damage", nil)
        basePart:SetAttribute("IconImage", nil)
        originalTransparencyByPart[basePart] = basePart.Transparency
    end

    instance:SetAttribute("WeaponId", nil)
    instance:SetAttribute("OwnerUserId", nil)
    instance:SetAttribute("Tier", nil)
    instance:SetAttribute("TierIndex", nil)
    instance:SetAttribute("Damage", nil)
    instance:SetAttribute("IconImage", nil)

    return baseParts, originalTransparencyByPart
end

function WeaponService:_spawnBrokenWeaponDebris(weaponState, context)
    if not (self._brokenDebrisFolder and weaponState and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent) then
        return
    end

    local sourceInstance = weaponState.RuntimeInstance
    local debrisInstance = sourceInstance:Clone()
    debrisInstance.Name = string.format("Broken_%s_%s", tostring(weaponState.Tier), tostring(weaponState.Id))
    debrisInstance.Parent = self._brokenDebrisFolder

    local startCFrame = getInstanceCFrame(sourceInstance)
    self:_setRuntimeCFrame(debrisInstance, startCFrame)

    local baseParts, originalTransparencyByPart = self:_configureBrokenDebrisInstance(debrisInstance)
    if #baseParts <= 0 then
        debrisInstance:Destroy()
        return
    end

    local horizontalDirection = self:_resolveBrokenDebrisDirection(weaponState, context)
    local horizontalVelocity = horizontalDirection * GameConfig.WEAPON.BrokenDebrisHorizontalSpeed
    local verticalVelocity = GameConfig.WEAPON.BrokenDebrisUpwardSpeed
    local spinMin = GameConfig.WEAPON.BrokenDebrisSpinSpeedMin
    local spinMax = GameConfig.WEAPON.BrokenDebrisSpinSpeedMax
    local angularVelocity = Vector3.new(
        math.random(spinMin * 100, spinMax * 100) / 100,
        math.random(spinMin * 100, spinMax * 100) / 100,
        math.random(spinMin * 100, spinMax * 100) / 100
    )

    table.insert(self._brokenDebrisStates, {
        Instance = debrisInstance,
        StartCFrame = startCFrame,
        HorizontalVelocity = horizontalVelocity,
        VerticalVelocity = verticalVelocity,
        AngularVelocity = angularVelocity,
        Elapsed = 0,
        Duration = GameConfig.WEAPON.BrokenDebrisDurationSeconds,
        OriginalTransparencyByPart = originalTransparencyByPart,
        BaseParts = baseParts,
    })

    Debris:AddItem(debrisInstance, GameConfig.WEAPON.BrokenDebrisDurationSeconds + 0.25)
end

function WeaponService:_updateBrokenDebris(deltaTime)
    if #self._brokenDebrisStates <= 0 then
        return
    end

    local gravity = GameConfig.WEAPON.BrokenDebrisGravity
    local fadeStart = GameConfig.WEAPON.BrokenDebrisFadeStart

    for index = #self._brokenDebrisStates, 1, -1 do
        local debrisState = self._brokenDebrisStates[index]
        local instance = debrisState.Instance
        if not (instance and instance.Parent) then
            table.remove(self._brokenDebrisStates, index)
        else
            debrisState.Elapsed += deltaTime
            local progress = debrisState.Elapsed / debrisState.Duration
            if progress >= 1 then
                instance:Destroy()
                table.remove(self._brokenDebrisStates, index)
            else
                local t = debrisState.Elapsed
                local displacement = Vector3.new(
                    debrisState.HorizontalVelocity.X * t,
                    (debrisState.VerticalVelocity * t) - (0.5 * gravity * t * t),
                    debrisState.HorizontalVelocity.Z * t
                )
                local spinRotation = CFrame.Angles(
                    debrisState.AngularVelocity.X * t,
                    debrisState.AngularVelocity.Y * t,
                    debrisState.AngularVelocity.Z * t
                )
                local orientationOnly = debrisState.StartCFrame - debrisState.StartCFrame.Position
                local targetCFrame = CFrame.new(debrisState.StartCFrame.Position + displacement) * orientationOnly * spinRotation
                self:_setRuntimeCFrame(instance, targetCFrame)

                if progress >= fadeStart then
                    local fadeAlpha = math.clamp((progress - fadeStart) / math.max(0.001, 1 - fadeStart), 0, 1)
                    for _, basePart in ipairs(debrisState.BaseParts) do
                        if basePart and basePart.Parent then
                            local originalTransparency = debrisState.OriginalTransparencyByPart[basePart] or 0
                            basePart.Transparency = originalTransparency + ((1 - originalTransparency) * fadeAlpha)
                        end
                    end
                end
            end
        end
    end
end

function WeaponService:_buildDistributedAngles(totalCount, anchorAngle)
    local angles = {}
    if totalCount <= 0 then
        return angles
    end

    local angleStep = (math.pi * 2) / math.max(1, totalCount)
    local baseAngle = normalizeAngle(anchorAngle)
    for weaponIndex = 1, totalCount do
        angles[weaponIndex] = baseAngle + ((weaponIndex - 1) * angleStep)
    end

    return angles
end

function WeaponService:_createWeaponState(actor, tier, weaponIndex, totalCount, previousState, forcedAngle)
    local tierConfig = WeaponTierConfig.Tiers[tier]
    if not tierConfig then
        return nil
    end

    local baseTemplate = self._templateFolder and findWeaponTemplate(self._templateFolder, tierConfig.TemplateName)
    local equippedSkin = ActorUtils.IsPlayer(actor) and self._playerStateService and self._playerStateService.GetEquippedSkinConfig and self._playerStateService:GetEquippedSkinConfig(actor) or nil
    local visualTemplateName = equippedSkin and equippedSkin.TemplateName or tierConfig.TemplateName
    local visualTemplate = self._templateFolder and findWeaponTemplate(self._templateFolder, visualTemplateName)
    local template = visualTemplate or baseTemplate
    if not template then
        warn(string.format(
            "[WeaponService] 找不到武器模板 %s（路径: %s）",
            tostring(visualTemplateName),
            tostring(tierConfig.TemplatePath)
        ))
        return nil
    end

    local canReusePrevious = previousState
        and previousState.RuntimeInstance
        and previousState.RuntimeInstance.Parent
        and previousState.VisualTemplateName == visualTemplateName
    local runtimeWeapon = canReusePrevious and previousState.RuntimeInstance or template:Clone()
    if previousState and previousState.RuntimeInstance and previousState.RuntimeInstance.Parent and previousState.RuntimeInstance ~= runtimeWeapon then
        previousState.RuntimeInstance:Destroy()
    end
    runtimeWeapon.Name = string.format("%s_%s_%d", tostring(visualTemplateName), tostring(getCombatUserId(actor)), weaponIndex)
    runtimeWeapon.Parent = self._runtimeFolder
    local hitPart = self:_configureRuntimeInstance(runtimeWeapon)
    if not hitPart then
        runtimeWeapon:Destroy()
        warn(string.format("[WeaponService] 武器模板 %s 内找不到 BasePart。", tostring(tierConfig.TemplateName)))
        return nil
    end
    copyAuraShape(baseTemplate, runtimeWeapon, hitPart)

    local angleStep = (math.pi * 2) / math.max(1, totalCount)
    local ownerUserId = getCombatUserId(actor)
    local weaponState = previousState or {}
    weaponState.Id = previousState and previousState.Id or tostring(self._nextWeaponId)
    weaponState.OwnerUserId = ownerUserId
    weaponState.Tier = tier
    weaponState.TierIndex = tierConfig.TierIndex or WeaponTierConfig.GetTierIndex(tier)
    weaponState.BaseDamage = tierConfig.Damage
    weaponState.IconImage = tierConfig.IconImage or WeaponTierConfig.GetIconImageForTier(tier)
    weaponState.VisualSkinId = equippedSkin and equippedSkin.Id or nil
    weaponState.VisualTemplateName = visualTemplateName
    weaponState.VisualIconImage = equippedSkin and equippedSkin.IconImage or weaponState.IconImage
    weaponState.OrbitSpeed = getWeaponOrbitSpeed()
    weaponState.OrbitDirection = previousState and previousState.OrbitDirection or 1
    weaponState.CurrentAngle = forcedAngle or (previousState and previousState.CurrentAngle) or ((weaponIndex - 1) * angleStep)
    weaponState.OrbitIndex = weaponIndex
    weaponState.Alive = true
    weaponState.RuntimeInstance = runtimeWeapon
    weaponState.HitPart = hitPart
    weaponState.AuraPart = hitPart
    weaponState.AuraRadius = self:GetWeaponHitRadius(weaponState)
    if not previousState then
        self._nextWeaponId += 1
    end

    applyWeaponAttributes(runtimeWeapon, weaponState)

    self._weaponByPart[hitPart] = weaponState
    return weaponState
end

function WeaponService:SyncWeaponRuntimeState(weaponState)
    if not (weaponState and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent) then
        return false
    end

    applyWeaponAttributes(weaponState.RuntimeInstance, weaponState)
    return true
end

function WeaponService:_calculateOrbitCenter(rootPart)
    local planarVelocity = Vector3.new(rootPart.AssemblyLinearVelocity.X, 0, rootPart.AssemblyLinearVelocity.Z)
    return rootPart.Position + (planarVelocity * GameConfig.WEAPON.PositionLeadSeconds)
end

function WeaponService:_buildWeaponCFrame(centerPosition, weaponState)
    local orbitDistance = getWeaponOrbitDistance()
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

function WeaponService:_updateWeaponTransforms(deltaTime)
    for _, actor in ipairs(self._playerStateService:GetAllActors()) do
        local weaponStates = self:GetWeaponStates(actor)
        if #weaponStates > 0 then
            local rootPart = ActorUtils.GetRootPart(actor)
            if rootPart then
                local centerPosition = self:_calculateOrbitCenter(rootPart)
                for _, weaponState in ipairs(weaponStates) do
                    if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                        weaponState.OrbitSpeed = getWeaponOrbitSpeed()
                        weaponState.CurrentAngle += (weaponState.OrbitSpeed * (weaponState.OrbitDirection or 1)) * deltaTime
                        self:_setRuntimeCFrame(weaponState.RuntimeInstance, self:_buildWeaponCFrame(centerPosition, weaponState))
                    end
                end
            end
        end
    end
end

function WeaponService:RebuildWeaponsForActor(actor)
    if not actor then
        return
    end

    local state = self._playerStateService:GetState(actor)
    if not (state.Alive and state.IsInArena) then
        self:_clearActorWeapons(getCombatUserId(actor))
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
        return
    end

    local resolved = WeaponTierConfig.ResolveLoadoutForLevel(state.Level)
    local combatUserId = getCombatUserId(actor)
    local previousWeaponStates = self._weaponsByCombatUserId[combatUserId] or {}
    local reusableWeaponStates = {}
    local previousWeaponBySlot = {}

    for _, weaponState in ipairs(previousWeaponStates) do
        if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
            table.insert(reusableWeaponStates, weaponState)
            local slotIndex = math.max(1, math.floor(tonumber(weaponState.OrbitIndex) or #reusableWeaponStates))
            if not previousWeaponBySlot[slotIndex] then
                previousWeaponBySlot[slotIndex] = weaponState
            end
        end
    end

    local desiredWeapons = {}
    if type(resolved.Weapons) == "table" and #resolved.Weapons > 0 then
        desiredWeapons = resolved.Weapons
    elseif resolved.Count and resolved.Count > 0 and resolved.Tier ~= "None" then
        for weaponIndex = 1, resolved.Count do
            table.insert(desiredWeapons, {
                SlotIndex = weaponIndex,
                Tier = resolved.Tier,
                TierIndex = resolved.TierIndex,
            })
        end
    end

    local desiredCount = #desiredWeapons
    if desiredCount <= 0 or resolved.Tier == "None" then
        self:_clearActorWeapons(combatUserId)
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
        return
    end

    local previousLeadAngle = reusableWeaponStates[1] and reusableWeaponStates[1].CurrentAngle or 0
    local shouldRedistributeAngles = #reusableWeaponStates ~= desiredCount
    local redistributedAngles = shouldRedistributeAngles and self:_buildDistributedAngles(desiredCount, previousLeadAngle) or nil
    local usedPreviousWeaponIds = {}
    local selectedPreviousBySlot = {}

    for weaponIndex, desiredWeapon in ipairs(desiredWeapons) do
        local desiredTier = tostring(desiredWeapon.Tier or resolved.Tier or "None")
        local previousState = previousWeaponBySlot[weaponIndex]
        if previousState and previousState.Tier == desiredTier then
            selectedPreviousBySlot[weaponIndex] = previousState
            usedPreviousWeaponIds[tostring(previousState.Id)] = true
        end
    end

    local function takeReusableWeaponState(tier)
        for _, previousState in ipairs(reusableWeaponStates) do
            local previousId = tostring(previousState.Id)
            if previousState.Tier == tier and usedPreviousWeaponIds[previousId] ~= true then
                usedPreviousWeaponIds[previousId] = true
                return previousState
            end
        end
        return nil
    end

    local weaponStates = {}

    for weaponIndex, desiredWeapon in ipairs(desiredWeapons) do
        local desiredTier = tostring(desiredWeapon.Tier or resolved.Tier or "None")
        local previousState = selectedPreviousBySlot[weaponIndex] or takeReusableWeaponState(desiredTier)
        local previousSlotState = previousWeaponBySlot[weaponIndex]
        local replacementAngle = previousSlotState and previousSlotState.CurrentAngle or nil
        local weaponState = self:_createWeaponState(
            actor,
            desiredTier,
            weaponIndex,
            desiredCount,
            previousState,
            redistributedAngles and redistributedAngles[weaponIndex] or replacementAngle
        )
        if weaponState then
            table.insert(weaponStates, weaponState)
        end
    end

    for _, previousState in ipairs(previousWeaponStates) do
        local shouldKeep = false
        for _, currentState in ipairs(weaponStates) do
            if currentState.Id == previousState.Id then
                shouldKeep = true
                break
            end
        end
        if not shouldKeep then
            self:_destroyWeaponState(previousState)
        end
    end

    self._weaponsByCombatUserId[combatUserId] = weaponStates

    for _, weaponState in ipairs(weaponStates) do
        if weaponState.HitPart then
            self._weaponByPart[weaponState.HitPart] = weaponState
        end
    end

    self._playerStateService:SetWeaponState(actor, resolved.Tier, #weaponStates)
    self._playerStateService:PushState(actor)
    self:_fireWeaponStateSync(actor, resolved.Tier, #weaponStates, weaponStates)
end

function WeaponService:RebuildWeaponsForPlayer(actor)
    self:RebuildWeaponsForActor(actor)
end

function WeaponService:AdjustAttackScore(actor, delta)
    warn("[WeaponService] AdjustAttackScore 已下线。请改用 PlayerStateService:AddExperience。")
    local state = self._playerStateService:GetState(actor)
    return state.Experience
end

function WeaponService:_reverseLastWeaponOrbit(weaponState, actor)
    local currentDirection = tonumber(weaponState.OrbitDirection) or 1
    weaponState.OrbitDirection = currentDirection >= 0 and -1 or 1
    self:SyncWeaponRuntimeState(weaponState)

    local ownerUserId = weaponState.OwnerUserId
    local aliveWeaponStates = {}
    for _, currentWeaponState in ipairs(self._weaponsByCombatUserId[ownerUserId] or {}) do
        if currentWeaponState.Alive and currentWeaponState.RuntimeInstance and currentWeaponState.RuntimeInstance.Parent then
            table.insert(aliveWeaponStates, currentWeaponState)
        end
    end
    self:_fireWeaponStateSync(actor, weaponState.Tier, #aliveWeaponStates, aliveWeaponStates)
end

function WeaponService:HandleBrokenWeapon(weaponState, context)
    if not weaponState or not weaponState.Alive then
        return false
    end

    local actor = self:_resolveActorByCombatUserId(weaponState.OwnerUserId)
    if not actor then
        return false
    end

    local ownerUserId = weaponState.OwnerUserId
    local aliveWeaponCount = 0
    for _, currentWeaponState in ipairs(self._weaponsByCombatUserId[ownerUserId] or {}) do
        if currentWeaponState.Alive and currentWeaponState.RuntimeInstance and currentWeaponState.RuntimeInstance.Parent then
            aliveWeaponCount += 1
        end
    end

    if aliveWeaponCount <= 1 then
        local sourceTierIndex = tonumber(context and context.sourceTierIndex) or 0
        local targetTierIndex = tonumber(weaponState.TierIndex) or 0
        if sourceTierIndex > targetTierIndex then
            self:_reverseLastWeaponOrbit(weaponState, actor)
        end
        return false
    end

    self:_spawnBrokenWeaponDebris(weaponState, context)
    local brokenWeaponId = weaponState.Id
    weaponState.Alive = false
    self:_destroyWeaponState(weaponState)

    local remainingWeaponStates = {}
    for _, currentWeaponState in ipairs(self._weaponsByCombatUserId[ownerUserId] or {}) do
        if currentWeaponState.Id ~= brokenWeaponId and currentWeaponState.Alive and currentWeaponState.RuntimeInstance and currentWeaponState.RuntimeInstance.Parent then
            table.insert(remainingWeaponStates, currentWeaponState)
        end
    end

    local remainingCount = #remainingWeaponStates
    if remainingCount > 0 then
        local anchorAngle = remainingWeaponStates[1].CurrentAngle or 0
        local redistributedAngles = self:_buildDistributedAngles(remainingCount, anchorAngle)
        local highestTier = remainingWeaponStates[1].Tier
        local highestTierIndex = math.max(0, tonumber(remainingWeaponStates[1].TierIndex) or 0)
        for index, currentWeaponState in ipairs(remainingWeaponStates) do
            currentWeaponState.OrbitIndex = index
            currentWeaponState.CurrentAngle = redistributedAngles[index] or currentWeaponState.CurrentAngle
            local tierIndex = math.max(0, tonumber(currentWeaponState.TierIndex) or 0)
            if tierIndex > highestTierIndex then
                highestTierIndex = tierIndex
                highestTier = currentWeaponState.Tier
            end
            self:SyncWeaponRuntimeState(currentWeaponState)
        end
        self._weaponsByCombatUserId[ownerUserId] = remainingWeaponStates
        self._playerStateService:SetWeaponState(actor, highestTier, remainingCount)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, remainingWeaponStates[1].Tier, remainingCount, remainingWeaponStates)
    else
        self._weaponsByCombatUserId[ownerUserId] = {}
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
    end
    return true
end

function WeaponService:ClearPlayerWeapons(actor)
    if not actor then
        return
    end

    self:_clearActorWeapons(getCombatUserId(actor))
    self._playerStateService:SetWeaponState(actor, "None", 0)
    self._playerStateService:PushState(actor)
    self:_fireWeaponStateSync(actor, "None", 0, {})
end

function WeaponService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._remoteEventService = dependencies.RemoteEventService
    self._botService = dependencies.BotService
    self._runtimeFolder = self:_createRuntimeFolder()
    self._brokenDebrisFolder = self:_createBrokenDebrisFolder()
    self._templateFolder = self:_resolveTemplateFolder()
    self._weaponStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("WeaponStateSync") or nil
    self._weaponsByCombatUserId = {}
    self._weaponByPart = {}
    self._brokenDebrisStates = {}
    self._nextWeaponId = 1
    self:_clearRuntimeFolder()
    self:_clearBrokenDebrisFolder()

    if self._heartbeatConnection then
        self._heartbeatConnection:Disconnect()
        self._heartbeatConnection = nil
    end

    if not self._templateFolder then
        warn("[WeaponService] 找不到 ReplicatedStorage/Model/Weapon，武器逻辑未启用。")
        return
    end

    self._heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        self:_updateWeaponTransforms(deltaTime)
        self:_updateBrokenDebris(deltaTime)
    end)
end

return WeaponService
