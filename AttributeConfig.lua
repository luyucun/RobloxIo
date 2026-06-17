--[[
Script: AttributeConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/AttributeConfig
Purpose: Shared config and helpers for in-battle attribute upgrades.
]]

local AttributeConfig = {}

AttributeConfig.SkillPointLevelInterval = 2
AttributeConfig.BaseBladeRecoverySeconds = 12
AttributeConfig.MinBladeRecoverySeconds = 6
AttributeConfig.CapUpgradeGrowthMultiplier = 1.5
AttributeConfig.DisabledProgressionAttributes = {
    Damage = true,
    MoveSpeed = true,
}

-- BEGIN GENERATED ATTRIBUTE CONFIG ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 属性养成配置 + 属性养成新的开发者商品. Update via tools/SyncCodeConfigFromWorkbook.py.
AttributeConfig.Order = {
    'Damage',
    'BladeSpeed',
    'BladeRange',
    'MoveSpeed',
    'MaxHealth',
    'HealthRegen',
    'ExpGain',
    'BladeRecovery',
}

AttributeConfig.Attributes = {
    Damage = {
        DisplayName = 'Weapon Damage',
        CapDisplayName = 'Damage Cap',
        CardName = 'WeaponDamage',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.1,
        ValueType = 'Percent',
    },
    BladeSpeed = {
        DisplayName = 'Blade Speed',
        CapDisplayName = 'Blade Speed Cap',
        CardName = 'BladeSpeed',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.05,
        ValueType = 'Percent',
    },
    BladeRange = {
        DisplayName = 'Blade Range',
        CapDisplayName = 'Blade Range Cap',
        CardName = 'BladeRange',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.1,
        ValueType = 'Percent',
    },
    MoveSpeed = {
        DisplayName = 'Move Speed',
        CapDisplayName = 'Move Speed Cap',
        CardName = 'MoveSpeed',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.03,
        ValueType = 'Percent',
    },
    MaxHealth = {
        DisplayName = 'Max Health',
        CapDisplayName = 'Max Health Cap',
        CardName = 'MaxHealth',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.1,
        ValueType = 'Percent',
    },
    HealthRegen = {
        DisplayName = 'Health Regen',
        CapDisplayName = 'Health Regen Cap',
        CardName = 'HealthRegen',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.025,
        ValueType = 'MaxHealthPercentPerSecond',
    },
    ExpGain = {
        DisplayName = 'EXP Gain',
        CapDisplayName = 'EXP Gain Cap',
        CardName = 'EXPGain',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = 0.05,
        ValueType = 'Percent',
    },
    BladeRecovery = {
        DisplayName = 'Blade Recovery',
        CapDisplayName = 'Blade Recovery Cap',
        CardName = 'BladeRecovery',
        InitialCap = 8,
        MaxCap = 40,
        PerLevelValue = -0.2,
        ValueType = 'Seconds',
    },
}

AttributeConfig.CapUpgradeProducts = {}

AttributeConfig.CapUpgradeLevelProducts = {
    [9] = 3603550266,
    [10] = 3603550309,
    [11] = 3603550350,
    [12] = 3603550381,
    [13] = 3603550436,
    [14] = 3603550468,
    [15] = 3603550533,
    [16] = 3603550568,
    [17] = 3603550625,
    [18] = 3603550668,
    [19] = 3603550668,
    [20] = 3603550668,
    [21] = 3603550668,
    [22] = 3603550668,
    [23] = 3603550668,
    [24] = 3603550668,
    [25] = 3603550668,
    [26] = 3603550668,
    [27] = 3603550668,
    [28] = 3603550668,
    [29] = 3603550668,
    [30] = 3603550668,
    [31] = 3603550668,
    [32] = 3603550668,
    [33] = 3603550668,
    [34] = 3603550668,
    [35] = 3603550668,
    [36] = 3603550668,
    [37] = 3603550668,
    [38] = 3603550668,
    [39] = 3603550668,
    [40] = 3603550668,
}

AttributeConfig.CapUpgradePrices = {
    Damage = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    BladeSpeed = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    BladeRange = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    MoveSpeed = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    MaxHealth = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    HealthRegen = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    ExpGain = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
    BladeRecovery = {
        { FromCap = 8, ToCap = 9, GemCost = 1000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 9, ToCap = 10, GemCost = 2500, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 10, ToCap = 11, GemCost = 4000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 11, ToCap = 12, GemCost = 5000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 12, ToCap = 13, GemCost = 6000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 13, ToCap = 14, GemCost = 7000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 14, ToCap = 15, GemCost = 8000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 15, ToCap = 16, GemCost = 9000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 16, ToCap = 17, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 17, ToCap = 18, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 18, ToCap = 19, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 19, ToCap = 20, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 20, ToCap = 21, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 21, ToCap = 22, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 22, ToCap = 23, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 23, ToCap = 24, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 24, ToCap = 25, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 25, ToCap = 26, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 26, ToCap = 27, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 27, ToCap = 28, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 28, ToCap = 29, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 29, ToCap = 30, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 30, ToCap = 31, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 31, ToCap = 32, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 32, ToCap = 33, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 33, ToCap = 34, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 34, ToCap = 35, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 35, ToCap = 36, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 36, ToCap = 37, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 37, ToCap = 38, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 38, ToCap = 39, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
        { FromCap = 39, ToCap = 40, GemCost = 10000, GemEnabled = true, RobuxEnabled = true },
    },
}
-- END GENERATED ATTRIBUTE CONFIG ROWS

local capUpgradeProductIds = {}

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
    table.clear(capUpgradeProductIds)
    for _, productId in pairs(AttributeConfig.CapUpgradeLevelProducts or {}) do
        local resolvedProductId = math.floor(tonumber(productId) or 0)
        if resolvedProductId > 0 then
            capUpgradeProductIds[resolvedProductId] = true
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

function AttributeConfig.GetTotalSkillPointsForLevel(level)
    local interval = math.max(1, normalizeInteger(AttributeConfig.SkillPointLevelInterval, 2))
    local resolvedLevel = math.max(1, normalizeInteger(level, 1))
    return math.max(0, math.floor(resolvedLevel / interval))
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

function AttributeConfig.IsProgressionDisabled(attributeKey)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    return key ~= nil and AttributeConfig.DisabledProgressionAttributes[key] == true
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

function AttributeConfig.GetCapUpgradeProduct(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local definition = key and AttributeConfig.Attributes[key] or nil
    if not definition or AttributeConfig.IsProgressionDisabled(key) then
        return nil
    end

    local cap = math.clamp(
        normalizeInteger(currentCap, definition.InitialCap),
        normalizeInteger(definition.InitialCap, 0),
        AttributeConfig.GetMaxCap(key)
    )
    if cap >= AttributeConfig.GetMaxCap(key) then
        return nil
    end

    local nextCap = cap + 1
    local productId = math.floor(tonumber((AttributeConfig.CapUpgradeLevelProducts or {})[nextCap]) or 0)
    if productId <= 0 then
        return nil
    end
    return {
        AttributeKey = key,
        Level = nextCap,
        ProductId = productId,
        Enabled = true,
    }
end

function AttributeConfig.IsCapUpgradeProductId(productId)
    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 then
        return false
    end
    return capUpgradeProductIds[resolvedProductId] == true
end

function AttributeConfig.GetAttributeByCapUpgradeProductId(productId, caps)
    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 then
        return nil
    end

    local matchedKey = nil
    for _, key in ipairs(AttributeConfig.Order) do
        local definition = AttributeConfig.Attributes[key]
        local currentCap = caps and caps[key] or definition and definition.InitialCap
        local product = AttributeConfig.GetCapUpgradeProduct(key, currentCap)
        if product and product.ProductId == resolvedProductId then
            if matchedKey then
                return nil
            end
            matchedKey = key
        end
    end
    return matchedKey
end

local function getCapUpgradePriceRow(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key or AttributeConfig.IsProgressionDisabled(key) then
        return nil, nil
    end

    local resolvedCurrentCap = normalizeInteger(currentCap, 0)
    local priceRows = AttributeConfig.CapUpgradePrices[key]
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
    if not definition or AttributeConfig.IsProgressionDisabled(key) then
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
    if not key or AttributeConfig.IsProgressionDisabled(key) then
        return false
    end

    local row = getCapUpgradePriceRow(key, normalizeInteger(currentCap, 0))
    return not row or row.GemEnabled ~= false
end

function AttributeConfig.IsCapUpgradeRobuxEnabled(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    if not key or AttributeConfig.IsProgressionDisabled(key) then
        return false
    end

    if not AttributeConfig.GetCapUpgradeProduct(key, currentCap) then
        return false
    end

    local row = getCapUpgradePriceRow(key, normalizeInteger(currentCap, 0))
    return not row or row.RobuxEnabled ~= false
end

function AttributeConfig.GetCapUpgradeInfo(attributeKey, currentCap)
    local key = AttributeConfig.NormalizeKey(attributeKey)
    local definition = key and AttributeConfig.Attributes[key] or nil
    if not definition or AttributeConfig.IsProgressionDisabled(key) then
        return nil
    end

    local cap = math.clamp(
        normalizeInteger(currentCap, definition.InitialCap),
        normalizeInteger(definition.InitialCap, 0),
        AttributeConfig.GetMaxCap(key)
    )
    local maxCap = AttributeConfig.GetMaxCap(key)
    local product = AttributeConfig.GetCapUpgradeProduct(key, cap)
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
        if AttributeConfig.IsProgressionDisabled(key) then
            normalized[key] = 0
        else
            normalized[key] = math.clamp(normalizeInteger(levels and levels[key], 0), 0, cap)
        end
    end
    return normalized
end

function AttributeConfig.CountDisabledProgressionPoints(levels, caps)
    local normalizedCaps = AttributeConfig.NormalizeCaps(caps)
    local usedPoints = 0
    for _, key in ipairs(AttributeConfig.Order) do
        if AttributeConfig.IsProgressionDisabled(key) then
            local cap = normalizeInteger(normalizedCaps[key], 0)
            usedPoints += math.clamp(normalizeInteger(levels and levels[key], 0), 0, cap)
        end
    end
    return usedPoints
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
        if not AttributeConfig.IsProgressionDisabled(key) then
            usedPoints += normalizeInteger(levels and levels[key], 0)
        end
    end
    return usedPoints
end

function AttributeConfig.CalculateFinalStats(levels, caps)
    local normalizedLevels = AttributeConfig.NormalizeLevels(levels, caps)
    local function levelFor(key)
        return normalizeInteger(normalizedLevels[key], 0)
    end

    local damageBonus = AttributeConfig.IsProgressionDisabled("Damage")
        and 0
        or levelFor("Damage") * AttributeConfig.Attributes.Damage.PerLevelValue
    local bladeSpeedBonus = levelFor("BladeSpeed") * AttributeConfig.Attributes.BladeSpeed.PerLevelValue
    local bladeRangeBonus = levelFor("BladeRange") * AttributeConfig.Attributes.BladeRange.PerLevelValue
    local moveSpeedBonus = AttributeConfig.IsProgressionDisabled("MoveSpeed")
        and 0
        or levelFor("MoveSpeed") * AttributeConfig.Attributes.MoveSpeed.PerLevelValue
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
