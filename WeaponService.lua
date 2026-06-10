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
WeaponService._requestStateSyncEvent = nil
WeaponService._requestStateSyncConnection = nil
WeaponService._weaponsByCombatUserId = {}
WeaponService._weaponByPart = {}
WeaponService._brokenDebrisStates = {}
WeaponService._weaponRestorationByCombatUserId = {}
WeaponService._heartbeatConnection = nil
WeaponService._nextWeaponId = 1
WeaponService._weaponTransformFrameIndex = 0
WeaponService._perfStats = nil
WeaponService._nextPerfLogClock = 0

local WEAPON_RESTORE_INTERVAL_SECONDS = 12

local function isPerformanceDebugEnabled()
    return GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 5)
end

local function getRemoteWeaponNearDistance()
    return math.max(0, tonumber(GameConfig.COMBAT and GameConfig.COMBAT.RemoteWeaponNearDistance) or 140)
end

local function getRemoteWeaponFarUpdateStride()
    return math.max(1, math.floor(tonumber(GameConfig.COMBAT and GameConfig.COMBAT.RemoteWeaponFarUpdateStride) or 1))
end

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

local function normalizeWeaponScale(scale)
    return math.max(0.1, tonumber(scale) or 1)
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

local function isAuraPart(basePart)
    if not basePart then
        return false
    end
    local auraName = GameConfig.WEAPON.AuraPartName or "Aura"
    return basePart.Name == auraName or basePart:GetAttribute("IsWeaponAura") == true
end

local function captureWeaponPartGeometry(instance, excludeAura)
    if not instance then
        return {}
    end

    local pivot = getInstanceCFrame(instance)
    local geometry = {}
    for _, basePart in ipairs(getBaseParts(instance)) do
        if not (excludeAura == true and isAuraPart(basePart)) then
            table.insert(geometry, {
                Part = basePart,
                Size = basePart.Size,
                LocalCFrame = pivot:ToObjectSpace(basePart.CFrame),
            })
        end
    end

    if excludeAura == true and #geometry <= 0 then
        return captureWeaponPartGeometry(instance, false)
    end
    return geometry
end

local function getGeometryLocalXBounds(geometry, scale)
    local normalizedScale = normalizeWeaponScale(scale)
    local minX = math.huge
    local maxX = -math.huge

    for _, item in ipairs(geometry or {}) do
        local localCFrame = item.LocalCFrame
        local size = item.Size
        if localCFrame and typeof(size) == "Vector3" then
            local scaledSize = size * normalizedScale
            local halfExtentX = (math.abs(localCFrame.RightVector.X) * scaledSize.X * 0.5)
                + (math.abs(localCFrame.UpVector.X) * scaledSize.Y * 0.5)
                + (math.abs(localCFrame.LookVector.X) * scaledSize.Z * 0.5)
            local centerX = localCFrame.Position.X * normalizedScale
            minX = math.min(minX, centerX - halfExtentX)
            maxX = math.max(maxX, centerX + halfExtentX)
        end
    end

    if minX == math.huge or maxX == -math.huge then
        return nil, nil
    end
    return minX, maxX
end

local function getAnchoredOrbitDistance(weaponState)
    local baseDistance = tonumber(weaponState and weaponState.OrbitDistance) or getWeaponOrbitDistance()
    local anchorGeometry = weaponState and (weaponState.AnchorPartGeometries or weaponState.BasePartGeometries)
    local baseMinX = nil
    local scaledMinX = nil
    baseMinX = getGeometryLocalXBounds(anchorGeometry, 1)
    scaledMinX = getGeometryLocalXBounds(anchorGeometry, weaponState and weaponState.WeaponScale or 1)
    if baseMinX == nil or scaledMinX == nil then
        return baseDistance
    end
    return math.max(0, baseDistance + baseMinX - scaledMinX)
end

local function applyWeaponStateScale(weaponState)
    if not (weaponState and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent) then
        return
    end

    local scale = normalizeWeaponScale(weaponState.WeaponScale)
    weaponState.WeaponScale = scale
    if math.abs((tonumber(weaponState.AppliedWeaponScale) or -1) - scale) <= 0.0001 then
        return
    end

    local instance = weaponState.RuntimeInstance
    if instance:IsA("Model") then
        local success = pcall(function()
            instance:ScaleTo(scale)
        end)
        if success then
            weaponState.AppliedWeaponScale = scale
            return
        end
    end

    local pivot = getInstanceCFrame(instance)
    for _, item in ipairs(weaponState.BasePartGeometries or {}) do
        local basePart = item.Part
        local baseSize = item.Size
        local localCFrame = item.LocalCFrame
        if basePart and basePart.Parent and typeof(baseSize) == "Vector3" and localCFrame then
            local rotationOnly = localCFrame - localCFrame.Position
            basePart.Size = baseSize * scale
            basePart.CFrame = pivot * CFrame.new(localCFrame.Position * scale) * rotationOnly
        end
    end
    weaponState.AppliedWeaponScale = scale
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
        self._weaponRestorationByCombatUserId[combatUserId] = nil
        return
    end

    for _, weaponState in ipairs(weaponStates) do
        self:_destroyWeaponState(weaponState)
    end

    self._weaponsByCombatUserId[combatUserId] = nil
    self._weaponRestorationByCombatUserId[combatUserId] = nil
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
        self:_addPerfStat("WeaponsDestroyed")
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
            ownerUserId = weaponState.OwnerUserId,
            tier = weaponState.Tier,
            tierIndex = weaponState.TierIndex,
            damage = weaponState.BaseDamage,
            iconImage = weaponState.IconImage or WeaponTierConfig.GetIconImageForTier(weaponState.Tier),
            visualSkinId = weaponState.VisualSkinId,
            visualTemplateName = weaponState.VisualTemplateName,
            visualIconImage = weaponState.VisualIconImage,
            orbitIndex = weaponState.OrbitIndex,
            orbitSpeed = weaponState.OrbitSpeed or getWeaponOrbitSpeed(),
            orbitDistance = weaponState.OrbitDistance or getWeaponOrbitDistance(),
            weaponScale = weaponState.WeaponScale or 1,
            orbitDirection = weaponState.OrbitDirection or 1,
            auraRadius = weaponState.AuraRadius or 0,
        })
    end
    return payload
end

function WeaponService:_buildWeaponStateSyncPayload(actor, tier, count, weaponStates)
    if not ActorUtils.IsPlayer(actor) then
        return nil
    end

    local ownerUserId = getCombatUserId(actor)
    if not (ownerUserId and ownerUserId > 0) then
        return nil
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

    return {
        ownerUserId = ownerUserId,
        weaponTier = syncTier,
        weaponTierIndex = syncTierIndex,
        weaponCount = syncCount,
        weaponIcon = WeaponTierConfig.GetIconImageForTier(syncTier),
        visualSkinId = weaponStates and weaponStates[1] and weaponStates[1].VisualSkinId or nil,
        visualTemplateName = weaponStates and weaponStates[1] and weaponStates[1].VisualTemplateName or nil,
        visualIconImage = weaponStates and weaponStates[1] and weaponStates[1].VisualIconImage or nil,
        weapons = self:_buildWeaponPayload(weaponStates or {}),
        timestamp = os.clock(),
    }
end

function WeaponService:_fireWeaponStateSync(actor, tier, count, weaponStates)
    if not self._weaponStateSyncEvent then
        return
    end

    local payload = self:_buildWeaponStateSyncPayload(actor, tier, count, weaponStates)
    if not payload then
        return
    end

    self:_addPerfStat("WeaponSyncEvents")
    self._weaponStateSyncEvent:FireAllClients(payload)
end

function WeaponService:PushAllPlayerWeaponStatesToPlayer(player)
    if not (self._weaponStateSyncEvent and player and player.Parent) then
        return
    end
    if not self._playerStateService then
        return
    end

    for _, actor in ipairs(self._playerStateService:GetArenaPlayers()) do
        local weaponStates = self:GetWeaponStates(actor)
        local payload = self:_buildWeaponStateSyncPayload(actor, nil, nil, weaponStates)
        if payload and payload.weaponCount > 0 then
            self._weaponStateSyncEvent:FireClient(player, payload)
        end
    end
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

function WeaponService:_getFinalWeaponDamage(actor, baseDamage)
    if self._playerStateService and self._playerStateService.GetFinalWeaponDamage then
        return self._playerStateService:GetFinalWeaponDamage(actor, baseDamage)
    end
    return math.max(0, math.floor((tonumber(baseDamage) or 0) + 0.5))
end

function WeaponService:_getFinalOrbitSpeed(actor)
    local baseSpeed = getWeaponOrbitSpeed()
    if self._playerStateService and self._playerStateService.GetWeaponOrbitSpeedMultiplier then
        return baseSpeed * self._playerStateService:GetWeaponOrbitSpeedMultiplier(actor)
    end
    return baseSpeed
end

function WeaponService:_getFinalOrbitDistance(actor)
    return getWeaponOrbitDistance()
end

function WeaponService:_getFinalWeaponScale(actor)
    if self._playerStateService and self._playerStateService.GetWeaponOrbitDistanceMultiplier then
        return normalizeWeaponScale(self._playerStateService:GetWeaponOrbitDistanceMultiplier(actor))
    end
    return 1
end

function WeaponService:_getWeaponRestoreInterval(actor)
    if self._playerStateService and self._playerStateService.GetBladeRecoverySeconds then
        return self._playerStateService:GetBladeRecoverySeconds(actor)
    end
    return WEAPON_RESTORE_INTERVAL_SECONDS
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
    self:_addPerfStat("BrokenDebrisSpawned")

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
            self:_addPerfStat("BrokenDebrisDestroyed")
        else
            debrisState.Elapsed += deltaTime
            local progress = debrisState.Elapsed / debrisState.Duration
            if progress >= 1 then
                instance:Destroy()
                table.remove(self._brokenDebrisStates, index)
                self:_addPerfStat("BrokenDebrisDestroyed")
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
    local hitPart = self:_configureRuntimeInstance(runtimeWeapon)
    if not hitPart then
        runtimeWeapon:Destroy()
        warn(string.format("[WeaponService] 武器模板 %s 内找不到 BasePart。", tostring(tierConfig.TemplateName)))
        return nil
    end
    local angleStep = (math.pi * 2) / math.max(1, totalCount)
    local ownerUserId = getCombatUserId(actor)
    local weaponState = previousState or {}
    if not (canReusePrevious and weaponState.BasePartGeometries) then
        copyAuraShape(baseTemplate, runtimeWeapon, hitPart)
        weaponState.BasePartGeometries = captureWeaponPartGeometry(runtimeWeapon, false)
        weaponState.AnchorPartGeometries = captureWeaponPartGeometry(runtimeWeapon, true)
        weaponState.AppliedWeaponScale = nil
    end
    weaponState.Id = previousState and previousState.Id or tostring(self._nextWeaponId)
    weaponState.OwnerUserId = ownerUserId
    weaponState.Tier = tier
    weaponState.TierIndex = tierConfig.TierIndex or WeaponTierConfig.GetTierIndex(tier)
    weaponState.TierBaseDamage = tierConfig.Damage
    weaponState.BaseDamage = self:_getFinalWeaponDamage(actor, tierConfig.Damage)
    weaponState.IconImage = tierConfig.IconImage or WeaponTierConfig.GetIconImageForTier(tier)
    weaponState.VisualSkinId = equippedSkin and equippedSkin.Id or nil
    weaponState.VisualTemplateName = visualTemplateName
    weaponState.VisualIconImage = equippedSkin and equippedSkin.IconImage or weaponState.IconImage
    weaponState.OrbitSpeed = self:_getFinalOrbitSpeed(actor)
    weaponState.OrbitDistance = self:_getFinalOrbitDistance(actor)
    weaponState.WeaponScale = self:_getFinalWeaponScale(actor)
    weaponState.OrbitDirection = previousState and previousState.OrbitDirection or 1
    weaponState.CurrentAngle = forcedAngle or (previousState and previousState.CurrentAngle) or ((weaponIndex - 1) * angleStep)
    weaponState.OrbitIndex = weaponIndex
    weaponState.Alive = true
    weaponState.RuntimeInstance = runtimeWeapon
    weaponState.HitPart = hitPart
    weaponState.AuraPart = hitPart
    applyWeaponStateScale(weaponState)
    weaponState.AuraRadius = self:GetWeaponHitRadius(weaponState)
    if not previousState then
        self._nextWeaponId += 1
    end

    applyWeaponAttributes(runtimeWeapon, weaponState)
    local rootPart = ActorUtils.GetRootPart(actor)
    if rootPart then
        self:_setRuntimeCFrame(runtimeWeapon, self:_buildWeaponCFrame(self:_calculateOrbitCenter(rootPart), weaponState))
    end
    if runtimeWeapon.Parent ~= self._runtimeFolder then
        runtimeWeapon.Parent = self._runtimeFolder
    end

    self._weaponByPart[hitPart] = weaponState
    if not previousState then
        self:_addPerfStat("WeaponsCreated")
    end
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
    local orbitDistance = getAnchoredOrbitDistance(weaponState)
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

function WeaponService:_buildArenaPlayerPositions()
    local positions = {}
    if not self._playerStateService then
        return positions
    end

    for _, player in ipairs(self._playerStateService:GetArenaPlayers()) do
        local rootPart = ActorUtils.GetRootPart(player)
        if rootPart then
            table.insert(positions, rootPart.Position)
        end
    end
    return positions
end

function WeaponService:_isNearAnyArenaPlayer(position, arenaPlayerPositions, nearDistanceSq)
    if typeof(position) ~= "Vector3" then
        return true
    end

    for _, playerPosition in ipairs(arenaPlayerPositions or {}) do
        local delta = position - playerPosition
        if (delta.X * delta.X) + (delta.Z * delta.Z) <= nearDistanceSq then
            return true
        end
    end
    return false
end

function WeaponService:_resetPerfStats()
    self._perfStats = {
        Steps = 0,
        ActorCount = 0,
        WeaponCount = 0,
        TransformCount = 0,
        WeaponSyncEvents = 0,
        Rebuilds = 0,
        WeaponsCreated = 0,
        WeaponsDestroyed = 0,
        BrokenDebrisSpawned = 0,
        BrokenDebrisDestroyed = 0,
        RestorationChecks = 0,
        RestorationRebuilds = 0,
        ElapsedSeconds = 0,
    }
end

function WeaponService:_addPerfStat(key, amount)
    if not isPerformanceDebugEnabled() then
        return
    end
    if not self._perfStats then
        self:_resetPerfStats()
    end
    self._perfStats[key] = (self._perfStats[key] or 0) + (amount or 1)
end

function WeaponService:_logPerfStats(now)
    if not isPerformanceDebugEnabled() then
        return
    end
    if now < (self._nextPerfLogClock or 0) then
        return
    end

    local stats = self._perfStats
    if stats and stats.Steps and stats.Steps > 0 then
        print(string.format(
            "[Perf][WeaponService] steps=%d actorSamples=%d weaponSamples=%d transforms=%d elapsedMs=%.3f",
            stats.Steps,
            stats.ActorCount or 0,
            stats.WeaponCount or 0,
            stats.TransformCount or 0,
            (stats.ElapsedSeconds or 0) * 1000
        ))
        local runtimeChildren = self._runtimeFolder and #self._runtimeFolder:GetChildren() or 0
        local runtimeDesc = 0
        if self._runtimeFolder then
            local ok, descendants = pcall(function()
                return self._runtimeFolder:GetDescendants()
            end)
            runtimeDesc = ok and #descendants or 0
        end
        local debrisChildren = self._brokenDebrisFolder and #self._brokenDebrisFolder:GetChildren() or 0
        local actorBuckets = 0
        local aliveWeapons = 0
        for _, weaponStates in pairs(self._weaponsByCombatUserId or {}) do
            actorBuckets += 1
            for _, weaponState in ipairs(weaponStates or {}) do
                if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                    aliveWeapons += 1
                end
            end
        end
        local restorationBuckets = 0
        for _ in pairs(self._weaponRestorationByCombatUserId or {}) do
            restorationBuckets += 1
        end
        print(string.format(
            "[Diag][WeaponService] actorBuckets=%d aliveWeapons=%d runtimeChildren=%d runtimeDesc=%d weaponByPart=%d debrisChildren=%d debrisStates=%d restorationBuckets=%d syncEvents=%d rebuilds=%d created=%d destroyed=%d debrisSpawned=%d debrisDestroyed=%d restorationChecks=%d restorationRebuilds=%d",
            actorBuckets,
            aliveWeapons,
            runtimeChildren,
            runtimeDesc,
            (function()
                local count = 0
                for _ in pairs(self._weaponByPart or {}) do
                    count += 1
                end
                return count
            end)(),
            debrisChildren,
            (function()
                local count = 0
                for _ in pairs(self._brokenDebrisStates or {}) do
                    count += 1
                end
                return count
            end)(),
            restorationBuckets,
            stats.WeaponSyncEvents or 0,
            stats.Rebuilds or 0,
            stats.WeaponsCreated or 0,
            stats.WeaponsDestroyed or 0,
            stats.BrokenDebrisSpawned or 0,
            stats.BrokenDebrisDestroyed or 0,
            stats.RestorationChecks or 0,
            stats.RestorationRebuilds or 0
        ))
    end

    self:_resetPerfStats()
    self._nextPerfLogClock = now + getPerformanceLogInterval()
end

function WeaponService:_updateWeaponTransforms(deltaTime)
    local startedAt = isPerformanceDebugEnabled() and os.clock() or nil
    local actorCount = 0
    local weaponCount = 0
    local transformCount = 0
    local farUpdateStride = getRemoteWeaponFarUpdateStride()
    self._weaponTransformFrameIndex = ((self._weaponTransformFrameIndex or 0) + 1) % farUpdateStride
    local nearDistance = getRemoteWeaponNearDistance()
    local nearDistanceSq = nearDistance * nearDistance
    local arenaPlayerPositions = self:_buildArenaPlayerPositions()

    for _, actor in ipairs(self._playerStateService:GetAllActors()) do
        local weaponStates = self:GetWeaponStates(actor)
        if #weaponStates > 0 then
            actorCount += 1
            weaponCount += #weaponStates
            local rootPart = ActorUtils.GetRootPart(actor)
            if rootPart then
                local centerPosition = self:_calculateOrbitCenter(rootPart)
                local actorIsPlayer = ActorUtils.IsPlayer(actor)
                local isNearPlayer = self:_isNearAnyArenaPlayer(centerPosition, arenaPlayerPositions, nearDistanceSq)
                local shouldUpdateTransform = isNearPlayer or farUpdateStride <= 1
                if actorIsPlayer then
                    shouldUpdateTransform = true
                end
                if not shouldUpdateTransform then
                    local combatUserId = getCombatUserId(actor)
                    shouldUpdateTransform = (math.abs(math.floor(tonumber(combatUserId) or 0)) % farUpdateStride) == self._weaponTransformFrameIndex
                end
                for _, weaponState in ipairs(weaponStates) do
                    if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
                        weaponState.OrbitSpeed = self:_getFinalOrbitSpeed(actor)
                        weaponState.OrbitDistance = self:_getFinalOrbitDistance(actor)
                        weaponState.WeaponScale = self:_getFinalWeaponScale(actor)
                        applyWeaponStateScale(weaponState)
                        weaponState.AuraRadius = self:GetWeaponHitRadius(weaponState)
                        weaponState.CurrentAngle += (weaponState.OrbitSpeed * (weaponState.OrbitDirection or 1)) * deltaTime
                        if shouldUpdateTransform then
                            self:_setRuntimeCFrame(weaponState.RuntimeInstance, self:_buildWeaponCFrame(centerPosition, weaponState))
                            transformCount += 1
                        end
                    end
                end
            end
        end
    end

    if startedAt then
        self:_addPerfStat("Steps")
        self:_addPerfStat("ActorCount", actorCount)
        self:_addPerfStat("WeaponCount", weaponCount)
        self:_addPerfStat("TransformCount", transformCount)
        self:_addPerfStat("ElapsedSeconds", os.clock() - startedAt)
        self:_logPerfStats(os.clock())
    end
end

function WeaponService:_updateWeaponRestoration(_deltaTime)
    local now = os.clock()
    for combatUserId, restorationState in pairs(self._weaponRestorationByCombatUserId) do
        self:_addPerfStat("RestorationChecks")
        local actor = self:_resolveActorByCombatUserId(combatUserId)
        if not actor then
            self._weaponRestorationByCombatUserId[combatUserId] = nil
            continue
        end

        local state = self._playerStateService:GetState(actor)
        if not (state and state.Alive and state.IsInArena) then
            self._weaponRestorationByCombatUserId[combatUserId] = nil
            continue
        end

        local resolved = WeaponTierConfig.ResolveLoadoutForLevel(state.Level)
        local desiredCount = #self:_buildDesiredWeaponList(resolved)
        local currentCount = #self:_getAliveWeaponStates(combatUserId)
        if desiredCount <= 0 or currentCount >= desiredCount then
            self._weaponRestorationByCombatUserId[combatUserId] = nil
            continue
        end

        local nextRestoreAt = tonumber(restorationState.NextRestoreAt) or now
        if now >= nextRestoreAt then
            self:_addPerfStat("RestorationRebuilds")
            self:_rebuildWeaponsForActorToCount(actor, math.min(currentCount + 1, desiredCount))
            local refreshedState = self._weaponRestorationByCombatUserId[combatUserId]
            if refreshedState then
                refreshedState.NextRestoreAt = now + self:_getWeaponRestoreInterval(actor)
            end
        end
    end
end

function WeaponService:_getAliveWeaponStates(combatUserId)
    local aliveWeaponStates = {}
    for _, weaponState in ipairs(self._weaponsByCombatUserId[combatUserId] or {}) do
        if weaponState.Alive and weaponState.RuntimeInstance and weaponState.RuntimeInstance.Parent then
            table.insert(aliveWeaponStates, weaponState)
        end
    end
    return aliveWeaponStates
end

function WeaponService:_buildDesiredWeaponList(resolved)
    local desiredWeapons = {}
    if type(resolved and resolved.Weapons) == "table" and #resolved.Weapons > 0 then
        for _, desiredWeapon in ipairs(resolved.Weapons) do
            table.insert(desiredWeapons, desiredWeapon)
        end
    elseif resolved and resolved.Count and resolved.Count > 0 and resolved.Tier ~= "None" then
        for weaponIndex = 1, resolved.Count do
            table.insert(desiredWeapons, {
                SlotIndex = weaponIndex,
                Tier = resolved.Tier,
                TierIndex = resolved.TierIndex,
            })
        end
    end
    return desiredWeapons
end

function WeaponService:_getHighestWeaponTier(weaponStates)
    local highestTier = "None"
    local highestTierIndex = 0
    for _, weaponState in ipairs(weaponStates or {}) do
        local tierIndex = math.max(0, tonumber(weaponState and weaponState.TierIndex) or 0)
        if tierIndex > highestTierIndex then
            highestTierIndex = tierIndex
            highestTier = tostring(weaponState.Tier or WeaponTierConfig.Order[tierIndex] or "None")
        end
    end
    return highestTier, highestTierIndex
end

function WeaponService:_syncActorWeaponState(actor, weaponStates)
    local previousState = self._playerStateService:GetState(actor)
    local previousTierIndex = math.max(0, tonumber(previousState and previousState.WeaponTierIndex) or 0)
    local weaponTier, weaponTierIndex = self:_getHighestWeaponTier(weaponStates)
    local weaponCount = #(weaponStates or {})
    self._playerStateService:SetWeaponState(actor, weaponTier, weaponCount)
    self._playerStateService:PushState(actor)
    self:_fireWeaponStateSync(actor, weaponTier, weaponCount, weaponStates or {})
    if ActorUtils.IsPlayer(actor) and self._gameAnalyticsService and weaponTierIndex > previousTierIndex then
        if self._gameAnalyticsService.MarkOnce and self._gameAnalyticsService:MarkOnce(actor, "Onboarding.FirstWeaponUpgrade") then
            self._gameAnalyticsService:TrackFunnel(actor, "Onboarding", 9, "FirstWeaponUpgrade", {
                source = "level",
                tierIndex = weaponTierIndex,
            })
        end
        self._gameAnalyticsService:TrackCustom(actor, "WeaponTierReached", weaponTierIndex, {
            source = "level",
            tierIndex = weaponTierIndex,
        })
    end
end

function WeaponService:_refreshWeaponRestoration(actor, currentCount, desiredCount)
    local combatUserId = getCombatUserId(actor)
    if math.max(0, tonumber(currentCount) or 0) >= math.max(0, tonumber(desiredCount) or 0) then
        self._weaponRestorationByCombatUserId[combatUserId] = nil
        return
    end

    local restorationState = self._weaponRestorationByCombatUserId[combatUserId]
    local restoreInterval = self:_getWeaponRestoreInterval(actor)
    if not restorationState then
        restorationState = {
            NextRestoreAt = os.clock() + restoreInterval,
        }
        self._weaponRestorationByCombatUserId[combatUserId] = restorationState
    else
        local remainingSeconds = math.max(0, (tonumber(restorationState.NextRestoreAt) or os.clock()) - os.clock())
        if remainingSeconds > restoreInterval then
            restorationState.NextRestoreAt = os.clock() + restoreInterval
        end
    end
    restorationState.TargetCount = math.max(0, math.floor(tonumber(desiredCount) or 0))
end

function WeaponService:_rebuildWeaponsForActorToCount(actor, targetCount)
    if not actor then
        return
    end
    self:_addPerfStat("Rebuilds")

    local combatUserId = getCombatUserId(actor)
    local state = self._playerStateService:GetState(actor)
    if not (state and state.Alive and state.IsInArena) then
        self:_clearActorWeapons(combatUserId)
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
        return
    end

    local resolved = WeaponTierConfig.ResolveLoadoutForLevel(state.Level)
    local desiredWeapons = self:_buildDesiredWeaponList(resolved)
    local desiredCount = #desiredWeapons
    if desiredCount <= 0 or resolved.Tier == "None" then
        self:_clearActorWeapons(combatUserId)
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
        return
    end

    local rebuildCount = desiredCount
    if targetCount ~= nil then
        rebuildCount = math.clamp(math.floor(tonumber(targetCount) or desiredCount), 0, desiredCount)
    end
    if rebuildCount <= 0 then
        self:_clearActorWeapons(combatUserId)
        self._playerStateService:SetWeaponState(actor, "None", 0)
        self._playerStateService:PushState(actor)
        self:_fireWeaponStateSync(actor, "None", 0, {})
        self:_refreshWeaponRestoration(actor, 0, desiredCount)
        return
    end

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

    local previousLeadAngle = reusableWeaponStates[1] and reusableWeaponStates[1].CurrentAngle or 0
    local shouldRedistributeAngles = #reusableWeaponStates ~= rebuildCount
    local redistributedAngles = shouldRedistributeAngles and self:_buildDistributedAngles(rebuildCount, previousLeadAngle) or nil
    local usedPreviousWeaponIds = {}
    local selectedPreviousBySlot = {}

    for weaponIndex = 1, rebuildCount do
        local desiredWeapon = desiredWeapons[weaponIndex]
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

    for weaponIndex = 1, rebuildCount do
        local desiredWeapon = desiredWeapons[weaponIndex]
        local desiredTier = tostring(desiredWeapon.Tier or resolved.Tier or "None")
        local previousState = selectedPreviousBySlot[weaponIndex] or takeReusableWeaponState(desiredTier)
        local previousSlotState = previousWeaponBySlot[weaponIndex]
        local replacementAngle = previousSlotState and previousSlotState.CurrentAngle or nil
        local weaponState = self:_createWeaponState(
            actor,
            desiredTier,
            weaponIndex,
            rebuildCount,
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

    self:_syncActorWeaponState(actor, weaponStates)
    self:_refreshWeaponRestoration(actor, #weaponStates, desiredCount)
    return #weaponStates, desiredCount
end

function WeaponService:RebuildWeaponsForActor(actor, options)
    if not actor then
        return
    end

    local state = self._playerStateService:GetState(actor)
    if not (state and state.Alive and state.IsInArena) then
        return self:_rebuildWeaponsForActorToCount(actor, 0)
    end

    local combatUserId = getCombatUserId(actor)
    local currentCount = #self:_getAliveWeaponStates(combatUserId)
    local resolved = WeaponTierConfig.ResolveLoadoutForLevel(state.Level)
    local desiredCount = #self:_buildDesiredWeaponList(resolved)
    local targetCount = desiredCount
    local hasExistingWeaponRecord = self._weaponsByCombatUserId[combatUserId] ~= nil
        or self._weaponRestorationByCombatUserId[combatUserId] ~= nil
    if currentCount < desiredCount and (currentCount > 0 or hasExistingWeaponRecord) then
        targetCount = currentCount
    end
    if type(options) == "table" and options.previousLevel ~= nil and currentCount < desiredCount then
        local previousResolved = WeaponTierConfig.ResolveLoadoutForLevel(options.previousLevel)
        local previousDesiredCount = #self:_buildDesiredWeaponList(previousResolved)
        local immediateLevelGainCount = math.max(0, desiredCount - previousDesiredCount)
        if immediateLevelGainCount > 0 then
            local restoredCount = math.min(desiredCount, currentCount + immediateLevelGainCount)
            if restoredCount > targetCount then
                targetCount = restoredCount
            end
        end
    end
    return self:_rebuildWeaponsForActorToCount(actor, targetCount)
end

function WeaponService:RebuildWeaponsForPlayer(actor)
    return self:_rebuildWeaponsForActorToCount(actor, nil)
end

function WeaponService:AdjustAttackScore(actor, delta)
    warn("[WeaponService] AdjustAttackScore 已下线。请改用 PlayerStateService:AddExperience。")
    local state = self._playerStateService:GetState(actor)
    return state.Experience
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
        for index, currentWeaponState in ipairs(remainingWeaponStates) do
            currentWeaponState.OrbitIndex = index
            currentWeaponState.CurrentAngle = redistributedAngles[index] or currentWeaponState.CurrentAngle
            self:SyncWeaponRuntimeState(currentWeaponState)
        end
        self._weaponsByCombatUserId[ownerUserId] = remainingWeaponStates
        self:_syncActorWeaponState(actor, remainingWeaponStates)

        local state = self._playerStateService:GetState(actor)
        local desiredCount = 0
        if state then
            desiredCount = #self:_buildDesiredWeaponList(WeaponTierConfig.ResolveLoadoutForLevel(state.Level))
        end
        self:_refreshWeaponRestoration(actor, remainingCount, desiredCount)
    else
        self._weaponsByCombatUserId[ownerUserId] = {}
        self._weaponRestorationByCombatUserId[ownerUserId] = nil
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
    self._gameAnalyticsService = dependencies.GameAnalyticsService
    self._runtimeFolder = self:_createRuntimeFolder()
    self._brokenDebrisFolder = self:_createBrokenDebrisFolder()
    self._templateFolder = self:_resolveTemplateFolder()
    self._weaponStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("WeaponStateSync") or nil
    self._requestStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestPlayerStateSync") or nil
    self._weaponsByCombatUserId = {}
    self._weaponByPart = {}
    self._brokenDebrisStates = {}
    self._weaponRestorationByCombatUserId = {}
    self._nextWeaponId = 1
    self._weaponTransformFrameIndex = 0
    self:_resetPerfStats()
    self._nextPerfLogClock = os.clock() + getPerformanceLogInterval()
    self:_clearRuntimeFolder()
    self:_clearBrokenDebrisFolder()

    if self._requestStateSyncConnection then
        self._requestStateSyncConnection:Disconnect()
        self._requestStateSyncConnection = nil
    end

    if self._requestStateSyncEvent then
        self._requestStateSyncConnection = self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            task.defer(function()
                self:PushAllPlayerWeaponStatesToPlayer(player)
            end)
        end)
    end

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
        self:_updateWeaponRestoration(deltaTime)
    end)
end

return WeaponService
