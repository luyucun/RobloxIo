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

-- BEGIN GENERATED LEVEL WEAPON PROGRESSION
-- Source: IO_BaseBalanceDraft.xlsx / 等级武器映射. Update via tools/SyncCodeConfigFromWorkbook.py --level-progression-only.
local LEVEL_WEAPON_PROGRESSION_BANDS = {
    { CombatRank = 1, MinLevel = 1, MaxLevel = 10, Tier = 'T1', TemplateName = 'Weapon001', DisplayName = 'Starter Blade', Damage = 5, MaxCount = 10 },
    { CombatRank = 2, MinLevel = 11, MaxLevel = 20, Tier = 'T2', TemplateName = 'Weapon002', DisplayName = 'Bone Blade', Damage = 10, MaxCount = 10 },
    { CombatRank = 3, MinLevel = 21, MaxLevel = 30, Tier = 'T3', TemplateName = 'Weapon003', DisplayName = 'Wind Cutter', Damage = 15, MaxCount = 10 },
    { CombatRank = 4, MinLevel = 31, MaxLevel = 40, Tier = 'T4', TemplateName = 'Weapon004', DisplayName = 'Toxic Blade', Damage = 20, MaxCount = 10 },
    { CombatRank = 5, MinLevel = 41, MaxLevel = 50, Tier = 'T5', TemplateName = 'Weapon005', DisplayName = 'Flame Saber', Damage = 25, MaxCount = 10 },
    { CombatRank = 6, MinLevel = 51, MaxLevel = 60, Tier = 'T6', TemplateName = 'Weapon006', DisplayName = 'Thunder Blade', Damage = 30, MaxCount = 10 },
    { CombatRank = 7, MinLevel = 61, MaxLevel = 70, Tier = 'T7', TemplateName = 'Weapon007', DisplayName = 'Magic Fang', Damage = 35, MaxCount = 10 },
    { CombatRank = 8, MinLevel = 71, MaxLevel = 80, Tier = 'T8', TemplateName = 'Weapon008', DisplayName = 'Frost Dagger', Damage = 40, MaxCount = 10 },
    { CombatRank = 9, MinLevel = 81, MaxLevel = 90, Tier = 'T9', TemplateName = 'Weapon009', DisplayName = 'Golden Axe', Damage = 45, MaxCount = 10 },
    { CombatRank = 10, MinLevel = 91, MaxLevel = 100, Tier = 'T10', TemplateName = 'Weapon010', DisplayName = 'Ice Anchor', Damage = 50, MaxCount = 10 },
    { CombatRank = 11, MinLevel = 101, MaxLevel = 110, Tier = 'T11', TemplateName = 'Weapon011', DisplayName = 'Moon Sickle', Damage = 55, MaxCount = 10 },
    { CombatRank = 12, MinLevel = 111, MaxLevel = 120, Tier = 'T12', TemplateName = 'Weapon012', DisplayName = 'Star Wand', Damage = 60, MaxCount = 10 },
    { CombatRank = 13, MinLevel = 121, MaxLevel = 130, Tier = 'T13', TemplateName = 'Weapon013', DisplayName = 'Flame Axe', Damage = 65, MaxCount = 10 },
    { CombatRank = 14, MinLevel = 131, MaxLevel = 140, Tier = 'T14', TemplateName = 'Weapon014', DisplayName = 'Void Halberd', Damage = 70, MaxCount = 10 },
    { CombatRank = 15, MinLevel = 141, MaxLevel = 150, Tier = 'T15', TemplateName = 'Weapon015', DisplayName = 'Sun Scepter', Damage = 75, MaxCount = 10 },
    { CombatRank = 16, MinLevel = 151, MaxLevel = 160, Tier = 'T16', TemplateName = 'Weapon016', DisplayName = 'Venom Mace', Damage = 80, MaxCount = 10 },
    { CombatRank = 17, MinLevel = 161, MaxLevel = 170, Tier = 'T17', TemplateName = 'Weapon017', DisplayName = 'Lava Fang', Damage = 85, MaxCount = 10 },
    { CombatRank = 18, MinLevel = 171, MaxLevel = 180, Tier = 'T18', TemplateName = 'Weapon018', DisplayName = 'Demon Sword', Damage = 90, MaxCount = 10 },
    { CombatRank = 19, MinLevel = 181, MaxLevel = 190, Tier = 'T19', TemplateName = 'Weapon019', DisplayName = 'Radiant Saber', Damage = 95, MaxCount = 10 },
    { CombatRank = 20, MinLevel = 191, MaxLevel = 200, Tier = 'T20', TemplateName = 'Weapon020', DisplayName = 'Verdant Hammer', Damage = 100, MaxCount = 10 },
    { CombatRank = 21, MinLevel = 201, MaxLevel = 210, Tier = 'T21', TemplateName = 'Weapon021', DisplayName = 'Inferno Blade', Damage = 105, MaxCount = 10 },
    { CombatRank = 22, MinLevel = 211, MaxLevel = 220, Tier = 'T22', TemplateName = 'Weapon022', DisplayName = 'Crystal Trident', Damage = 110, MaxCount = 10 },
    { CombatRank = 23, MinLevel = 221, MaxLevel = 230, Tier = 'T23', TemplateName = 'Weapon023', DisplayName = 'Nature Cleaver', Damage = 115, MaxCount = 10 },
    { CombatRank = 24, MinLevel = 231, MaxLevel = 240, Tier = 'T24', TemplateName = 'Weapon024', DisplayName = 'Storm Reaper', Damage = 120, MaxCount = 10 },
    { CombatRank = 25, MinLevel = 241, MaxLevel = 250, Tier = 'T25', TemplateName = 'Weapon025', DisplayName = 'Void Staff', Damage = 125, MaxCount = 10 },
    { CombatRank = 26, MinLevel = 251, MaxLevel = 260, Tier = 'T26', TemplateName = 'Weapon026', DisplayName = 'Holy Staff', Damage = 130, MaxCount = 10 },
    { CombatRank = 27, MinLevel = 261, MaxLevel = 270, Tier = 'T27', TemplateName = 'Weapon027', DisplayName = 'Prism Staff', Damage = 135, MaxCount = 10 },
    { CombatRank = 28, MinLevel = 271, MaxLevel = 280, Tier = 'T28', TemplateName = 'Weapon028', DisplayName = 'Toxic Scythe', Damage = 140, MaxCount = 10 },
    { CombatRank = 29, MinLevel = 281, MaxLevel = 290, Tier = 'T29', TemplateName = 'Weapon029', DisplayName = 'Solar Hammer', Damage = 145, MaxCount = 10 },
    { CombatRank = 30, MinLevel = 291, MaxLevel = 300, Tier = 'T30', TemplateName = 'Weapon030', DisplayName = 'Inferno Axe', Damage = 150, MaxCount = 10 },
    { CombatRank = 31, MinLevel = 301, MaxLevel = 310, Tier = 'T31', TemplateName = 'Weapon031', DisplayName = 'Blood Scythe', Damage = 155, MaxCount = 10 },
    { CombatRank = 32, MinLevel = 311, MaxLevel = 320, Tier = 'T32', TemplateName = 'Weapon032', DisplayName = 'Storm Saber', Damage = 160, MaxCount = 10 },
    { CombatRank = 33, MinLevel = 321, MaxLevel = 330, Tier = 'T33', TemplateName = 'Weapon033', DisplayName = 'Void Blade', Damage = 165, MaxCount = 10 },
    { CombatRank = 34, MinLevel = 331, MaxLevel = 340, Tier = 'T34', TemplateName = 'Weapon034', DisplayName = 'Crimson Reaper', Damage = 170, MaxCount = 10 },
    { CombatRank = 35, MinLevel = 341, MaxLevel = 350, Tier = 'T35', TemplateName = 'Weapon035', DisplayName = 'Magma Hammer', Damage = 175, MaxCount = 10 },
    { CombatRank = 36, MinLevel = 351, MaxLevel = 360, Tier = 'T36', TemplateName = 'Weapon036', DisplayName = 'Frost Dragon Scythe', Damage = 180, MaxCount = 10 },
    { CombatRank = 37, MinLevel = 361, MaxLevel = 370, Tier = 'T37', TemplateName = 'Weapon037', DisplayName = 'Shadow Blade', Damage = 185, MaxCount = 10 },
    { CombatRank = 38, MinLevel = 371, MaxLevel = 380, Tier = 'T38', TemplateName = 'Weapon038', DisplayName = 'Verdant Blade', Damage = 190, MaxCount = 10 },
    { CombatRank = 39, MinLevel = 381, MaxLevel = 390, Tier = 'T39', TemplateName = 'Weapon039', DisplayName = 'Hellfire Sword', Damage = 195, MaxCount = 10 },
    { CombatRank = 40, MinLevel = 391, MaxLevel = 400, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 200, MaxCount = 10 },
    { CombatRank = 41, MinLevel = 401, MaxLevel = 410, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 205, MaxCount = 10 },
    { CombatRank = 42, MinLevel = 411, MaxLevel = 420, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 210, MaxCount = 10 },
    { CombatRank = 43, MinLevel = 421, MaxLevel = 430, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 215, MaxCount = 10 },
    { CombatRank = 44, MinLevel = 431, MaxLevel = 440, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 220, MaxCount = 10 },
    { CombatRank = 45, MinLevel = 441, MaxLevel = 450, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 225, MaxCount = 10 },
    { CombatRank = 46, MinLevel = 451, MaxLevel = 460, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 230, MaxCount = 10 },
    { CombatRank = 47, MinLevel = 461, MaxLevel = 470, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 235, MaxCount = 10 },
    { CombatRank = 48, MinLevel = 471, MaxLevel = 480, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 240, MaxCount = 10 },
    { CombatRank = 49, MinLevel = 481, MaxLevel = 490, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 245, MaxCount = 10 },
    { CombatRank = 50, MinLevel = 491, MaxLevel = 500, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 250, MaxCount = 10 },
    { CombatRank = 51, MinLevel = 501, MaxLevel = 510, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 255, MaxCount = 10 },
    { CombatRank = 52, MinLevel = 511, MaxLevel = 520, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 260, MaxCount = 10 },
    { CombatRank = 53, MinLevel = 521, MaxLevel = 530, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 265, MaxCount = 10 },
    { CombatRank = 54, MinLevel = 531, MaxLevel = 540, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 270, MaxCount = 10 },
    { CombatRank = 55, MinLevel = 541, MaxLevel = 550, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 275, MaxCount = 10 },
    { CombatRank = 56, MinLevel = 551, MaxLevel = 560, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 280, MaxCount = 10 },
    { CombatRank = 57, MinLevel = 561, MaxLevel = 570, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 285, MaxCount = 10 },
    { CombatRank = 58, MinLevel = 571, MaxLevel = 580, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 290, MaxCount = 10 },
    { CombatRank = 59, MinLevel = 581, MaxLevel = 590, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 295, MaxCount = 10 },
    { CombatRank = 60, MinLevel = 591, MaxLevel = 600, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 300, MaxCount = 10 },
    { CombatRank = 61, MinLevel = 601, MaxLevel = 610, Tier = 'T40', TemplateName = 'Weapon040', DisplayName = 'Abyss Eye Blade', Damage = 305, MaxCount = 10 },
}
-- END GENERATED LEVEL WEAPON PROGRESSION

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
    return string.format("Tier %d Weapon", tierIndex)
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
        CombatRank = tierIndex,
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
    local maxProgressionLevel = LEVEL_WEAPON_PROGRESSION_BANDS[#LEVEL_WEAPON_PROGRESSION_BANDS].MaxLevel
    local normalizedLevel = math.clamp(math.floor(tonumber(level) or 1), 1, maxProgressionLevel)
    local progressionBand = nil
    for _, band in ipairs(LEVEL_WEAPON_PROGRESSION_BANDS) do
        if normalizedLevel >= band.MinLevel and normalizedLevel <= band.MaxLevel then
            progressionBand = band
            break
        end
    end

    if progressionBand and progressionBand.CombatRank > WeaponTierConfig.TotalTierCount then
        local tier = progressionBand.Tier
        local tierConfig = WeaponTierConfig.Tiers[tier]
        local weapons = {}
        local tierCounts = {}
        local maxCount = getConfiguredMaxCount(tierConfig)
        for slotIndex = 1, maxCount do
            weapons[slotIndex] = {
                SlotIndex = slotIndex,
                Tier = tier,
                TierIndex = tierConfig.TierIndex,
                TemplateName = tierConfig.TemplateName,
                IconImage = WeaponTierConfig.GetIconImageForTier(tier),
                DisplayName = WeaponTierConfig.GetDisplayNameForTier(tier),
                Damage = progressionBand.Damage,
                CombatRank = progressionBand.CombatRank,
            }
        end
        tierCounts[tier] = maxCount

        return {
            Tier = tier,
            Count = #weapons,
            TierIndex = tierConfig.TierIndex,
            CombatRank = progressionBand.CombatRank,
            IconImage = WeaponTierConfig.GetIconImageForTier(tier),
            DisplayName = WeaponTierConfig.GetDisplayNameForTier(tier),
            Weapons = weapons,
            TierCounts = tierCounts,
        }
    end

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
        CombatRank = tierIndex,
        IconImage = WeaponTierConfig.GetIconImageForTier(tier),
        DisplayName = WeaponTierConfig.GetDisplayNameForTier(tier),
        Weapons = weapons,
        TierCounts = tierCounts,
    }
end

return WeaponTierConfig
