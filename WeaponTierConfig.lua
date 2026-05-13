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

WeaponTierConfig.TotalTierCount = 0
WeaponTierConfig.MaxCountPerTier = 10
WeaponTierConfig.DefaultIconImage = "rbxassetid://136643628395891"

WeaponTierConfig.Order = {}
WeaponTierConfig.Tiers = {}

local BASE_DAMAGE = 5
local DAMAGE_PER_TIER = 5

local WEAPON_STATS_BY_TIER_INDEX = {
    [1] = { DisplayName = "Starter Blade", IconImage = "rbxassetid://136643628395891", Damage = 5 },
    [2] = { DisplayName = "Bone Blade", IconImage = "rbxassetid://126475194758948", Damage = 10 },
    [3] = { DisplayName = "Wind Cutter", IconImage = "rbxassetid://129956304598949", Damage = 15 },
    [4] = { DisplayName = "Toxic Blade", IconImage = "rbxassetid://89963553350977", Damage = 20 },
    [5] = { DisplayName = "Flame Saber", IconImage = "rbxassetid://84481453527461", Damage = 25 },
    [6] = { DisplayName = "Thunder Blade", IconImage = "rbxassetid://118584980433943", Damage = 30 },
    [7] = { DisplayName = "Magic Fang", IconImage = "rbxassetid://76107440925386", Damage = 35 },
    [8] = { DisplayName = "Frost Dagger", IconImage = "rbxassetid://100323364003297", Damage = 40 },
    [9] = { DisplayName = "Golden Axe", IconImage = "rbxassetid://91433543584934", Damage = 45 },
    [10] = { DisplayName = "Ice Anchor", IconImage = "rbxassetid://89742128794713", Damage = 50 },
    [11] = { DisplayName = "Moon Sickle", IconImage = "rbxassetid://113531776856771", Damage = 55 },
    [12] = { DisplayName = "Star Wand", IconImage = "rbxassetid://122307482899416", Damage = 60 },
    [13] = { DisplayName = "Flame Axe", IconImage = "rbxassetid://139320248035231", Damage = 65 },
    [14] = { DisplayName = "Void Halberd", IconImage = "rbxassetid://135511301463451", Damage = 70 },
    [15] = { DisplayName = "Sun Scepter", IconImage = "rbxassetid://117191703860318", Damage = 75 },
    [16] = { DisplayName = "Venom Mace", IconImage = "rbxassetid://96129866370359", Damage = 80 },
    [17] = { DisplayName = "Lava Fang", IconImage = "rbxassetid://108125780267512", Damage = 85 },
    [18] = { DisplayName = "Demon Sword", IconImage = "rbxassetid://117710360357527", Damage = 90 },
    [19] = { DisplayName = "Radiant Saber", IconImage = "rbxassetid://124721245776996", Damage = 95 },
    [20] = { DisplayName = "Verdant Hammer", IconImage = "rbxassetid://127461701787596", Damage = 100 },
    [21] = { DisplayName = "Inferno Blade", IconImage = "rbxassetid://121810615217907", Damage = 105 },
    [22] = { DisplayName = "Crystal Trident", IconImage = "rbxassetid://86683818159729", Damage = 110 },
    [23] = { DisplayName = "Nature Cleaver", IconImage = "rbxassetid://105949531835539", Damage = 115 },
    [24] = { DisplayName = "Storm Reaper", IconImage = "rbxassetid://96308199551458", Damage = 120 },
    [25] = { DisplayName = "Void Staff", IconImage = "rbxassetid://91237215205347", Damage = 125 },
    [26] = { DisplayName = "Holy Staff", IconImage = "rbxassetid://136629582226811", Damage = 130 },
    [27] = { DisplayName = "Prism Staff", IconImage = "rbxassetid://81459770478224", Damage = 135 },
    [28] = { DisplayName = "Toxic Scythe", IconImage = "rbxassetid://128923243109404", Damage = 140 },
    [29] = { DisplayName = "Solar Hammer", IconImage = "rbxassetid://73053626458930", Damage = 145 },
    [30] = { DisplayName = "Inferno Axe", IconImage = "rbxassetid://93091517353986", Damage = 150 },
    [31] = { DisplayName = "Blood Scythe", IconImage = "rbxassetid://133841732459750", Damage = 155 },
    [32] = { DisplayName = "Storm Saber", IconImage = "rbxassetid://124215370892293", Damage = 160 },
    [33] = { DisplayName = "Void Blade", IconImage = "rbxassetid://105736042876322", Damage = 165 },
    [34] = { DisplayName = "Crimson Reaper", IconImage = "rbxassetid://86204792464223", Damage = 170 },
    [35] = { DisplayName = "Frost Dragon Scythe", IconImage = "rbxassetid://87603953703181", Damage = 175 },
    [36] = { DisplayName = "Shadow Blade", IconImage = "rbxassetid://71638231475719", Damage = 180 },
    [37] = { DisplayName = "Verdant Blade", IconImage = "rbxassetid://73907716879266", Damage = 185 },
    [38] = { DisplayName = "Hellfire Sword", IconImage = "rbxassetid://102712256475693", Damage = 190 },
    [39] = { DisplayName = "Radiant Glaive", IconImage = "rbxassetid://115936433663221", Damage = 195 },
    [40] = { DisplayName = "Abyss Eye Blade", IconImage = "rbxassetid://107360178350174", Damage = 200 },
}

local function resolveConfiguredTierCount()
    local maxTierIndex = 0
    for tierIndex in pairs(WEAPON_STATS_BY_TIER_INDEX) do
        local normalizedTierIndex = math.floor(tonumber(tierIndex) or 0)
        if normalizedTierIndex > maxTierIndex then
            maxTierIndex = normalizedTierIndex
        end
    end
    return math.max(1, maxTierIndex)
end

local function buildTierName(tierIndex)
    return "T" .. tostring(tierIndex)
end

local function buildTemplateName(tierIndex)
    return string.format("Weapon%03d", tierIndex)
end

local function buildFallbackDisplayName(tierIndex)
    return string.format("%d级武器", tierIndex)
end

local function resolveIconImage(tierIndex)
    local stats = WEAPON_STATS_BY_TIER_INDEX[tierIndex]
    local iconImage = stats and stats.IconImage or nil
    if iconImage == nil or iconImage == "" then
        return WeaponTierConfig.DefaultIconImage
    end
    return iconImage
end

local function resolveDisplayName(tierIndex)
    local stats = WEAPON_STATS_BY_TIER_INDEX[tierIndex]
    local displayName = stats and stats.DisplayName or nil
    if displayName == nil or tostring(displayName) == "" then
        return buildFallbackDisplayName(tierIndex)
    end
    return tostring(displayName)
end

local function resolveDamage(tierIndex)
    local stats = WEAPON_STATS_BY_TIER_INDEX[tierIndex]
    return tonumber(stats and stats.Damage) or (BASE_DAMAGE + ((tierIndex - 1) * DAMAGE_PER_TIER))
end

local function getConfiguredMaxCount(tierConfig)
    return math.max(1, math.floor(tonumber(tierConfig and tierConfig.MaxCount) or WeaponTierConfig.MaxCountPerTier or 10))
end

local function buildSymmetricOrderFromList(slotList)
    local ordered = {}

    local function fillRange(startIndex, endIndex)
        if startIndex > endIndex then
            return
        end

        table.insert(ordered, slotList[startIndex])
        if startIndex == endIndex then
            return
        end

        local remainingStart = startIndex + 1
        local remainingEnd = endIndex
        if remainingStart > remainingEnd then
            return
        end

        local remainingCount = remainingEnd - remainingStart + 1
        local middleIndex = remainingStart + math.floor((remainingCount - 1) / 2)
        table.insert(ordered, slotList[middleIndex])

        fillRange(remainingStart, middleIndex - 1)
        fillRange(middleIndex + 1, remainingEnd)
    end

    fillRange(1, #slotList)
    return ordered
end

local function buildDistributedReplacementSlots(totalCount)
    local oddSlots = {}
    local evenSlots = {}

    for slotIndex = 1, totalCount do
        if slotIndex % 2 == 1 then
            table.insert(oddSlots, slotIndex)
        else
            table.insert(evenSlots, slotIndex)
        end
    end

    local slotOrder = buildSymmetricOrderFromList(oddSlots)
    local evenOrder = buildSymmetricOrderFromList(evenSlots)
    for _, slotIndex in ipairs(evenOrder) do
        table.insert(slotOrder, slotIndex)
    end

    return slotOrder
end

local function appendWeaponEntry(weapons, tierCounts, tierIndex, slotIndex)
    local tier = WeaponTierConfig.Order[tierIndex]
    local tierConfig = tier and WeaponTierConfig.Tiers[tier] or nil
    if not tierConfig then
        return
    end

    tierCounts[tier] = (tierCounts[tier] or 0) + 1
    weapons[slotIndex] = {
        SlotIndex = slotIndex,
        Tier = tier,
        TierIndex = tierIndex,
        TemplateName = tierConfig.TemplateName,
        IconImage = WeaponTierConfig.GetIconImageForTier(tier),
        DisplayName = WeaponTierConfig.GetDisplayNameForTier(tier),
        Damage = tierConfig.Damage,
    }
end

WeaponTierConfig.TotalTierCount = resolveConfiguredTierCount()

for tierIndex = 1, WeaponTierConfig.TotalTierCount do
    local tier = buildTierName(tierIndex)
    local templateName = buildTemplateName(tierIndex)

    table.insert(WeaponTierConfig.Order, tier)
    WeaponTierConfig.Tiers[tier] = {
        Tier = tier,
        TierIndex = tierIndex,
        DisplayName = resolveDisplayName(tierIndex),
        TemplateName = templateName,
        TemplatePath = "ReplicatedStorage/Model/Weapon/" .. templateName,
        IconImage = resolveIconImage(tierIndex),
        Damage = resolveDamage(tierIndex),
        MaxCount = WeaponTierConfig.MaxCountPerTier,
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

function WeaponTierConfig.GetDisplayNameForTier(tier)
    local config = WeaponTierConfig.Tiers[tostring(tier or "")]
    if config and config.DisplayName and config.DisplayName ~= "" then
        return config.DisplayName
    end
    return buildFallbackDisplayName(WeaponTierConfig.GetTierIndex(tier))
end

function WeaponTierConfig.GetUnlockLevelForTierIndex(tierIndex)
    local level = 1
    local normalizedTierIndex = math.max(1, math.floor(tonumber(tierIndex) or 1))
    for index = 1, normalizedTierIndex - 1 do
        local tierName = WeaponTierConfig.Order[index]
        local tierConfig = tierName and WeaponTierConfig.Tiers[tierName] or nil
        local maxCount = getConfiguredMaxCount(tierConfig)
        level += maxCount
    end
    return level
end

function WeaponTierConfig.ResolveLoadoutForLevel(level)
    local normalizedLevel = math.max(1, math.floor(tonumber(level) or 1))
    local remainingLevel = normalizedLevel
    local tierIndex = #WeaponTierConfig.Order
    local isAboveConfiguredLevels = true

    for index, tierName in ipairs(WeaponTierConfig.Order) do
        local tierConfig = WeaponTierConfig.Tiers[tierName]
        local maxCount = getConfiguredMaxCount(tierConfig)
        if remainingLevel <= maxCount then
            tierIndex = index
            isAboveConfiguredLevels = false
            break
        end
        remainingLevel -= maxCount
    end

    local tier = WeaponTierConfig.Order[tierIndex]
    local tierConfig = WeaponTierConfig.Tiers[tier]
    local maxCount = getConfiguredMaxCount(tierConfig)
    local count = math.clamp(remainingLevel, 1, maxCount)
    if isAboveConfiguredLevels then
        count = maxCount
    end

    local weapons = {}
    local tierCounts = {}
    if tierIndex <= 1 then
        for slotIndex = 1, count do
            appendWeaponEntry(weapons, tierCounts, tierIndex, slotIndex)
        end
    else
        local replacementSlots = buildDistributedReplacementSlots(maxCount)
        local replacementSlotSet = {}
        for index = 1, count do
            local slotIndex = replacementSlots[index]
            if slotIndex then
                replacementSlotSet[slotIndex] = true
            end
        end

        for slotIndex = 1, maxCount do
            if replacementSlotSet[slotIndex] then
                appendWeaponEntry(weapons, tierCounts, tierIndex, slotIndex)
            else
                appendWeaponEntry(weapons, tierCounts, tierIndex - 1, slotIndex)
            end
        end
    end

    return {
        Tier = tier,
        Count = #weapons,
        TierIndex = tierIndex,
        IconImage = WeaponTierConfig.GetIconImageForTier(tier),
        DisplayName = WeaponTierConfig.GetDisplayNameForTier(tier),
        Weapons = weapons,
        TierCounts = tierCounts,
    }
end

return WeaponTierConfig
