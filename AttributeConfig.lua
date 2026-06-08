--[[
Script: AttributeConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/AttributeConfig
Purpose: Shared config and helpers for in-battle attribute upgrades.
]]

local AttributeConfig = {}

AttributeConfig.SkillPointsPerLevel = 1
AttributeConfig.BaseBladeRecoverySeconds = 12
AttributeConfig.MinBladeRecoverySeconds = 6
AttributeConfig.CapUpgradeGrowthMultiplier = 1.5

AttributeConfig.Order = {
    "Damage",
    "BladeSpeed",
    "BladeRange",
    "MoveSpeed",
    "MaxHealth",
    "HealthRegen",
    "ExpGain",
    "BladeRecovery",
}

AttributeConfig.Attributes = {
    Damage = {
        DisplayName = "Weapon Damage",
        CapDisplayName = "Damage Cap",
        CardName = "WeaponDamage",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.04,
        ValueType = "Percent",
    },
    BladeSpeed = {
        DisplayName = "Blade Speed",
        CapDisplayName = "Blade Speed Cap",
        CardName = "BladeSpeed",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.03,
        ValueType = "Percent",
    },
    BladeRange = {
        DisplayName = "Blade Range",
        CapDisplayName = "Blade Range Cap",
        CardName = "BladeRange",
        InitialCap = 4,
        MaxCap = 999,
        PerLevelValue = 0.025,
        ValueType = "Percent",
    },
    MoveSpeed = {
        DisplayName = "Move Speed",
        CapDisplayName = "Move Speed Cap",
        CardName = "MoveSpeed",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.02,
        ValueType = "Percent",
    },
    MaxHealth = {
        DisplayName = "Max Health",
        CapDisplayName = "Max Health Cap",
        CardName = "MaxHealth",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.05,
        ValueType = "Percent",
    },
    HealthRegen = {
        DisplayName = "Health Regen",
        CapDisplayName = "Health Regen Cap",
        CardName = "HealthRegen",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.0025,
        ValueType = "MaxHealthPercentPerSecond",
    },
    ExpGain = {
        DisplayName = "EXP Gain",
        CapDisplayName = "EXP Gain Cap",
        CardName = "EXPGain",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = 0.03,
        ValueType = "Percent",
    },
    BladeRecovery = {
        DisplayName = "Blade Recovery",
        CapDisplayName = "Blade Recovery Cap",
        CardName = "BladeRecovery",
        InitialCap = 5,
        MaxCap = 999,
        PerLevelValue = -0.4,
        ValueType = "Seconds",
    },
}

AttributeConfig.CapUpgradeProducts = {
    Damage = {
        ProductId = 3603254310,
        Enabled = true,
    },
    BladeSpeed = {
        ProductId = 3603254362,
        Enabled = true,
    },
    BladeRange = {
        ProductId = 3603254418,
        Enabled = true,
    },
    MoveSpeed = {
        ProductId = 3603254486,
        Enabled = true,
    },
    MaxHealth = {
        ProductId = 3603254533,
        Enabled = true,
    },
    HealthRegen = {
        ProductId = 3603254583,
        Enabled = true,
    },
    ExpGain = {
        ProductId = 3603254622,
        Enabled = true,
    },
    BladeRecovery = {
        ProductId = 3603254680,
        Enabled = true,
    },
}

AttributeConfig.CapUpgradePrices = {
    Damage = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 5697, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 8546, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 12819, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 19228, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 28842, GemEnabled = true, RobuxEnabled = true },
    },
    BladeSpeed = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 5697, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 8546, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 12819, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 19228, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 28842, GemEnabled = true, RobuxEnabled = true },
    },
    BladeRange = {
        { FromCap = 4, ToCap = 5, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 5, ToCap = 6, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
    },
    MoveSpeed = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
    },
    MaxHealth = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 5697, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 8546, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 12819, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 19228, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 28842, GemEnabled = true, RobuxEnabled = true },
    },
    HealthRegen = {
        { FromCap = 5, ToCap = 6, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
    },
    ExpGain = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
    },
    BladeRecovery = {
        { FromCap = 5, ToCap = 6, GemCost = 100, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 6, ToCap = 7, GemCost = 150, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 7, ToCap = 8, GemCost = 225, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 8, ToCap = 9, GemCost = 340, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 750, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 1125, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 1688, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 2532, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 3798, GemEnabled = true, RobuxEnabled = true },
    },
}

local productIdToAttributeKey = {}

local aliasByCompactKey = {
    damage = "Damage",
    weapondamage = "Damage",
    bladespeed = "BladeSpeed",
    bladerange = "BladeRange",
    movespeed = "MoveSpeed",
    maxhealth = "MaxHealth",
    healthregen = "HealthRegen",
    expgain = "ExpGain",
    experiencegain = "ExpGain",
    bladerecovery = "BladeRecovery",
}

local function rebuildProductLookup()
    table.clear(productIdToAttributeKey)
    for key, product in pairs(AttributeConfig.CapUpgradeProducts) do
        local productId = math.floor(tonumber(product and product.ProductId) or 0)
        if productId > 0 and product.Enabled ~= false then
            productIdToAttributeKey[productId] = key
        end
    end
end

for key, definition in pairs(AttributeConfig.Attributes) do
    aliasByCompactKey[string.lower(key)] = key
    if definition.CardName then
        aliasByCompactKey[string.lower(definition.CardName)] = key
    end
end

rebuildProductLookup()

local function normalizeInteger(value, fallback)
    return math.max(0, math.floor(tonumber(value) or fallback or 0))
end

local function formatSignedPercent(value)
    local percent = (tonumber(value) or 0) * 100
    local roundedInteger = math.floor(percent + 0.5)
    if math.abs(percent - roundedInteger) < 0.001 then
        return string.format("+%d%%", roundedInteger)
    end
    return string.format("+%.1f%%", percent)
end

function AttributeConfig.NormalizeKey(attributeKey)
    local raw = tostring(attributeKey or "")
    if AttributeConfig.Attributes[raw] then
        return raw
    end

    local compact = string.lower((raw:gsub("[^%w]", "")))
    return aliasByCompactKey[compact]
end

function AttributeConfig.GetDefinition(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    return key and AttributeConfig.Attributes[key] or nil
end

function AttributeConfig.GetMaxCap(attributeKey)
    local definition = AttributeConfig.GetDefinition(attributeKey)
    if not definition then
        return 0
    end
    return math.max(
        normalizeInteger(definition.InitialCap, 0),
        normalizeInteger(definition.MaxCap, definition.InitialCap)
    )
end

function AttributeConfig.GetCapUpgradeProduct(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local product = key and AttributeConfig.CapUpgradeProducts[key] or nil
    local productId = math.floor(tonumber(product and product.ProductId) or 0)
    if not (product and product.Enabled ~= false and productId > 0) then
        return nil
    end
    return {
        AttributeKey = key,
        ProductId = productId,
        Enabled = true,
    }
end

function AttributeConfig.GetAttributeByCapUpgradeProductId(productId)
    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 then
        return nil
    end
    return productIdToAttributeKey[resolvedProductId]
end

local function getCapUpgradePriceRow(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local resolvedCurrentCap = normalizeInteger(currentCap, 0)
    local priceRows = key and AttributeConfig.CapUpgradePrices[key] or nil
    if type(priceRows) ~= "table" then
        return nil, nil
    end

    local lastRow = nil
    for _, row in ipairs(priceRows) do
        local fromCap = normalizeInteger(row and row.FromCap, 0)
        if fromCap == resolvedCurrentCap then
            return row, priceRows[#priceRows]
        end
        lastRow = row
    end

    return nil, lastRow
end

local function roundHalfUp(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

function AttributeConfig.GetCapUpgradeGemCost(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local definition = key and AttributeConfig.Attributes[key] or nil
    if not definition then
        return nil
    end

    local resolvedCurrentCap = normalizeInteger(currentCap, definition.InitialCap)
    if resolvedCurrentCap >= AttributeConfig.GetMaxCap(key) then
        return nil
    end

    local row, lastRow = getCapUpgradePriceRow(key, resolvedCurrentCap)
    if row and row.GemEnabled ~= false then
        return normalizeInteger(row.GemCost, 0)
    end

    if not lastRow then
        return nil
    end

    local lastFromCap = normalizeInteger(lastRow.FromCap, resolvedCurrentCap)
    local lastGemCost = normalizeInteger(lastRow.GemCost, 0)
    if lastGemCost <= 0 then
        return nil
    end

    local extraLevels = math.max(0, resolvedCurrentCap - lastFromCap)
    local cost = lastGemCost
    for _ = 1, extraLevels do
        cost = roundHalfUp(cost * AttributeConfig.CapUpgradeGrowthMultiplier)
    end
    return normalizeInteger(cost, 0)
end

function AttributeConfig.IsCapUpgradeGemEnabled(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false
    end

    local row = getCapUpgradePriceRow(key, normalizeInteger(currentCap, 0))
    return not row or row.GemEnabled ~= false
end

function AttributeConfig.IsCapUpgradeRobuxEnabled(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key then
        return false
    end

    if not AttributeConfig.GetCapUpgradeProduct(key) then
        return false
    end

    local row = getCapUpgradePriceRow(key, normalizeInteger(currentCap, 0))
    return not row or row.RobuxEnabled ~= false
end

function AttributeConfig.GetCapUpgradeInfo(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local definition = key and AttributeConfig.Attributes[key] or nil
    if not definition then
        return nil
    end

    local cap = math.clamp(
        normalizeInteger(currentCap, definition.InitialCap),
        normalizeInteger(definition.InitialCap, 0),
        AttributeConfig.GetMaxCap(key)
    )
    local maxCap = AttributeConfig.GetMaxCap(key)
    local product = AttributeConfig.GetCapUpgradeProduct(key)
    return {
        AttributeKey = key,
        CurrentCap = cap,
        NextCap = math.min(maxCap, cap + 1),
        MaxCap = maxCap,
        IsMax = cap >= maxCap,
        GemCost = AttributeConfig.GetCapUpgradeGemCost(key, cap),
        GemEnabled = AttributeConfig.IsCapUpgradeGemEnabled(key, cap),
        RobuxEnabled = AttributeConfig.IsCapUpgradeRobuxEnabled(key, cap),
        ProductId = product and product.ProductId or nil,
    }
end

function AttributeConfig.BuildDefaultLevels()
    local levels = {}
    for _, key in ipairs(AttributeConfig.Order) do
        levels[key] = 0
    end
    return levels
end

function AttributeConfig.BuildDefaultCaps()
    local caps = {}
    for _, key in ipairs(AttributeConfig.Order) do
        local definition = AttributeConfig.Attributes[key]
        caps[key] = normalizeInteger(definition and definition.InitialCap, 0)
    end
    return caps
end

function AttributeConfig.NormalizeCaps(caps)
    local normalized = {}
    for _, key in ipairs(AttributeConfig.Order) do
        local definition = AttributeConfig.Attributes[key]
        local initialCap = normalizeInteger(definition and definition.InitialCap, 0)
        local maxCap = math.max(initialCap, normalizeInteger(definition and definition.MaxCap, initialCap))
        local rawCap = caps and caps[key]
        normalized[key] = math.clamp(normalizeInteger(rawCap, initialCap), initialCap, maxCap)
    end
    return normalized
end

function AttributeConfig.NormalizeLevels(levels, caps)
    local normalizedCaps = AttributeConfig.NormalizeCaps(caps)
    local normalized = {}
    for _, key in ipairs(AttributeConfig.Order) do
        local cap = normalizeInteger(normalizedCaps[key], 0)
        normalized[key] = math.clamp(normalizeInteger(levels and levels[key], 0), 0, cap)
    end
    return normalized
end

function AttributeConfig.CopyNumberMap(map)
    local copy = {}
    for _, key in ipairs(AttributeConfig.Order) do
        copy[key] = normalizeInteger(map and map[key], 0)
    end
    return copy
end

function AttributeConfig.CountUsedPoints(levels)
    local usedPoints = 0
    for _, key in ipairs(AttributeConfig.Order) do
        usedPoints += normalizeInteger(levels and levels[key], 0)
    end
    return usedPoints
end

function AttributeConfig.CalculateFinalStats(levels, caps)
    local normalizedLevels = AttributeConfig.NormalizeLevels(levels, caps)
    local function levelFor(key)
        return normalizeInteger(normalizedLevels[key], 0)
    end

    local damageBonus = levelFor("Damage") * AttributeConfig.Attributes.Damage.PerLevelValue
    local bladeSpeedBonus = levelFor("BladeSpeed") * AttributeConfig.Attributes.BladeSpeed.PerLevelValue
    local bladeRangeBonus = levelFor("BladeRange") * AttributeConfig.Attributes.BladeRange.PerLevelValue
    local moveSpeedBonus = levelFor("MoveSpeed") * AttributeConfig.Attributes.MoveSpeed.PerLevelValue
    local maxHealthBonus = levelFor("MaxHealth") * AttributeConfig.Attributes.MaxHealth.PerLevelValue
    local expGainBonus = levelFor("ExpGain") * AttributeConfig.Attributes.ExpGain.PerLevelValue
    local healthRegenPercentPerSecond = levelFor("HealthRegen") * AttributeConfig.Attributes.HealthRegen.PerLevelValue
    local bladeRecoverySeconds = math.max(
        AttributeConfig.MinBladeRecoverySeconds,
        AttributeConfig.BaseBladeRecoverySeconds + (levelFor("BladeRecovery") * AttributeConfig.Attributes.BladeRecovery.PerLevelValue)
    )

    return {
        WeaponDamageMultiplier = 1 + damageBonus,
        OrbitSpeedMultiplier = 1 + bladeSpeedBonus,
        OrbitDistanceMultiplier = 1 + bladeRangeBonus,
        MoveSpeedMultiplier = 1 + moveSpeedBonus,
        MaxHealthMultiplier = 1 + maxHealthBonus,
        HealthRegenPercentPerSecond = healthRegenPercentPerSecond,
        ExpGainBonus = expGainBonus,
        BladeRecoverySeconds = bladeRecoverySeconds,
    }
end

function AttributeConfig.FormatEffect(attributeKey, level)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local definition = key and AttributeConfig.Attributes[key] or nil
    if not definition then
        return ""
    end

    local normalizedLevel = normalizeInteger(level, 0)
    if definition.ValueType == "Seconds" then
        local seconds = math.max(
            AttributeConfig.MinBladeRecoverySeconds,
            AttributeConfig.BaseBladeRecoverySeconds + (normalizedLevel * definition.PerLevelValue)
        )
        return string.format("%.1fs", seconds)
    end

    local value = normalizedLevel * (tonumber(definition.PerLevelValue) or 0)
    if definition.ValueType == "MaxHealthPercentPerSecond" then
        return formatSignedPercent(value) .. "/s"
    end
    return formatSignedPercent(value)
end

return AttributeConfig
