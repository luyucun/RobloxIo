--[[
脚本名字: PotionConfig
脚本文件: PotionConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/PotionConfig
说明: V2.1 药水数据配置，来源于 IO_BaseBalanceDraft.xlsx 的“药水”页签。
]]

local PotionConfig = {}

PotionConfig.OrderedPotionIds = {
    1001,
    1002,
    1003,
}

PotionConfig.Potions = {
    [1001] = {
        Id = 1001,
        Name = "Basic Potion",
        Rarity = 1,
        IconImage = "rbxassetid://111415582573034",
        ModelName = "BasicPotion",
        DurationSeconds = 45,
        ExperienceBonus = 0.3,
        MoveSpeedBonus = 0,
        DiamondPrice = 59,
        RobuxPrice = 9,
        ProductId = 3587884072,
    },
    [1002] = {
        Id = 1002,
        Name = "Advanced Potion",
        Rarity = 2,
        IconImage = "rbxassetid://106498508152369",
        ModelName = "AdvancedPotion",
        DurationSeconds = 60,
        ExperienceBonus = 1,
        MoveSpeedBonus = 0,
        DiamondPrice = 199,
        RobuxPrice = 19,
        ProductId = 3587883973,
    },
    [1003] = {
        Id = 1003,
        Name = "Rare Potion",
        Rarity = 3,
        IconImage = "rbxassetid://100154459165982",
        ModelName = "RarePotion",
        DurationSeconds = 90,
        ExperienceBonus = 1.8,
        MoveSpeedBonus = 0,
        DiamondPrice = 399,
        RobuxPrice = 39,
        ProductId = 3587884282,
    },
}

PotionConfig.PotionIdByProductId = {}
for _, potionId in ipairs(PotionConfig.OrderedPotionIds) do
    local potion = PotionConfig.Potions[potionId]
    local productId = potion and tonumber(potion.ProductId) or 0
    if productId > 0 then
        PotionConfig.PotionIdByProductId[productId] = potionId
    end
end

function PotionConfig.GetPotion(potionId)
    return PotionConfig.Potions[tonumber(potionId)]
end

function PotionConfig.GetPotionByProductId(productId)
    local potionId = PotionConfig.PotionIdByProductId[tonumber(productId)]
    return potionId and PotionConfig.Potions[potionId] or nil
end

function PotionConfig.GetAllPotions()
    local potions = {}
    for _, potionId in ipairs(PotionConfig.OrderedPotionIds) do
        table.insert(potions, PotionConfig.Potions[potionId])
    end
    return potions
end

return PotionConfig
