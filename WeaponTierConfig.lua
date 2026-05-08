--[[
脚本名字: WeaponTierConfig
脚本文件: WeaponTierConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/WeaponTierConfig
]]

local WeaponTierConfig = {}

WeaponTierConfig.ModelRootFolderName = "Model"
WeaponTierConfig.WeaponFolderName = "Weapon"
WeaponTierConfig.RuntimeRootFolderName = "Runtime"
WeaponTierConfig.RuntimeFolderName = "Weapons"

WeaponTierConfig.TotalTierCount = 100
WeaponTierConfig.MaxCountPerTier = 10
WeaponTierConfig.DefaultIconImage = "rbxassetid://109932376066132"

WeaponTierConfig.Order = {}
WeaponTierConfig.Tiers = {}

local BASE_DAMAGE = 10
local DAMAGE_PER_TIER = 10
local BASE_MAX_HEALTH = 20
local HEALTH_PER_TIER = 20
local BASE_ORBIT_RADIUS = 6
local ORBIT_RADIUS_STEP = 0.04
local MAX_ORBIT_RADIUS = 10
local BASE_ORBIT_SPEED = 2.8
local ORBIT_SPEED_STEP = 0.01
local MIN_ORBIT_SPEED = 1.6
local ICON_IMAGES_BY_TIER_INDEX = {
    [1] = "rbxassetid://109932376066132",
    [2] = "rbxassetid://133806558046532",
    [3] = "rbxassetid://105004480791847",
    [4] = "rbxassetid://94807555755766",
    [5] = "rbxassetid://78877244310390",
    [6] = "rbxassetid://121942502659398",
    [7] = "rbxassetid://97473931925310",
    [8] = "rbxassetid://139531081297248",
    [9] = "rbxassetid://105210669873207",
    [10] = "rbxassetid://108161728460884",
    [11] = "rbxassetid://90524959060314",
}

local function buildTierName(tierIndex)
    return "T" .. tostring(tierIndex)
end

local function buildTemplateName(tierIndex)
    return string.format("Weapon%03d", tierIndex)
end

local function resolveIconImage(tierIndex)
    local iconImage = ICON_IMAGES_BY_TIER_INDEX[tierIndex]
    if iconImage == nil or iconImage == "" then
        return WeaponTierConfig.DefaultIconImage
    end
    return iconImage
end

for tierIndex = 1, WeaponTierConfig.TotalTierCount do
    local tier = buildTierName(tierIndex)
    local templateName = buildTemplateName(tierIndex)

    table.insert(WeaponTierConfig.Order, tier)
    WeaponTierConfig.Tiers[tier] = {
        Tier = tier,
        TierIndex = tierIndex,
        DisplayName = string.format("%d级武器", tierIndex),
        TemplateName = templateName,
        TemplatePath = "ReplicatedStorage/Model/Weapon/" .. templateName,
        IconImage = resolveIconImage(tierIndex),
        Damage = BASE_DAMAGE + ((tierIndex - 1) * DAMAGE_PER_TIER),
        MaxHealth = BASE_MAX_HEALTH + ((tierIndex - 1) * HEALTH_PER_TIER),
        MaxCount = WeaponTierConfig.MaxCountPerTier,
        OrbitRadius = math.min(MAX_ORBIT_RADIUS, BASE_ORBIT_RADIUS + ((tierIndex - 1) * ORBIT_RADIUS_STEP)),
        OrbitSpeed = math.max(MIN_ORBIT_SPEED, BASE_ORBIT_SPEED - ((tierIndex - 1) * ORBIT_SPEED_STEP)),
    }
end

function WeaponTierConfig.GetTierIndex(tier)
    local config = WeaponTierConfig.Tiers[tostring(tier or "")]
    return config and config.TierIndex or 0
end

function WeaponTierConfig.GetIconImageForTier(tier)
    local config = WeaponTierConfig.Tiers[tostring(tier or "")]
    if config and config.IconImage and config.IconImage ~= "" then
        return config.IconImage
    end
    return WeaponTierConfig.DefaultIconImage
end

function WeaponTierConfig.ResolveLoadoutForLevel(level)
    local normalizedLevel = math.max(1, math.floor(tonumber(level) or 1))
    local remainingLevel = normalizedLevel
    local tierIndex = #WeaponTierConfig.Order
    local isAboveConfiguredLevels = true

    for index, tierName in ipairs(WeaponTierConfig.Order) do
        local tierConfig = WeaponTierConfig.Tiers[tierName]
        local maxCount = math.max(1, math.floor(tonumber(tierConfig and tierConfig.MaxCount) or 10))
        if remainingLevel <= maxCount then
            tierIndex = index
            isAboveConfiguredLevels = false
            break
        end
        remainingLevel -= maxCount
    end

    local tier = WeaponTierConfig.Order[tierIndex]
    local tierConfig = WeaponTierConfig.Tiers[tier]
    local maxCount = math.max(1, math.floor(tonumber(tierConfig and tierConfig.MaxCount) or 10))
    local count = math.clamp(remainingLevel, 1, maxCount)
    if isAboveConfiguredLevels then
        count = maxCount
    end

    return {
        Tier = tier,
        Count = count,
        TierIndex = tierIndex,
        IconImage = WeaponTierConfig.GetIconImageForTier(tier),
    }
end

return WeaponTierConfig
