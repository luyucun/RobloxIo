--[[
Script: ShopConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/ShopConfig
Purpose: V3.5 shop purchase and reward presentation configuration.
]]

local ShopConfig = {}

ShopConfig.StarterPack = {
    ClaimKey = "StarterPack",
    GamePassId = 1838079007,
    Rewards = {
        { RewardType = "Potion", PotionId = 1002, Amount = 3 },
        { RewardType = "WheelSpins", Amount = 5 },
        { RewardType = "Diamonds", Amount = 300 },
    },
}

ShopConfig.FeaturedSkinId = 10002

ShopConfig.RewardIcons = {
    Potion1002 = {
        Image = "rbxassetid://106498508152369",
        AspectRatio = 0.8,
    },
    WheelSpins = {
        Image = "rbxassetid://77152368516350",
        AspectRatio = 1,
    },
    Diamonds = {
        Image = "rbxassetid://89590364394067",
        AspectRatio = 1.2,
    },
    Skin10002 = {
        Image = "rbxassetid://92172382104718",
        AspectRatio = 1,
    },
}

local function copyReward(reward)
    if type(reward) ~= "table" then
        return nil
    end

    return {
        rewardType = reward.RewardType,
        potionId = reward.PotionId,
        skinId = reward.SkinId,
        amount = reward.Amount,
        icon = reward.Icon,
        aspectRatio = reward.AspectRatio,
        label = reward.Label,
    }
end

function ShopConfig.GetRewardPresentation(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local result = copyReward(reward)
    if not result then
        return nil
    end

    local iconConfig = nil
    if reward.RewardType == "Potion" then
        iconConfig = ShopConfig.RewardIcons["Potion" .. tostring(reward.PotionId)]
        result.label = result.label or ("Potion " .. tostring(reward.PotionId))
    elseif reward.RewardType == "WheelSpins" then
        iconConfig = ShopConfig.RewardIcons.WheelSpins
        result.label = result.label or "Spin"
    elseif reward.RewardType == "Diamonds" then
        iconConfig = ShopConfig.RewardIcons.Diamonds
        result.label = result.label or "Diamonds"
    elseif reward.RewardType == "Skin" then
        iconConfig = ShopConfig.RewardIcons["Skin" .. tostring(reward.SkinId)]
        result.label = result.label or "Skin"
    end

    result.icon = result.icon or (iconConfig and iconConfig.Image) or ""
    result.aspectRatio = tonumber(result.aspectRatio) or tonumber(iconConfig and iconConfig.AspectRatio) or 1
    result.amount = math.max(1, math.floor(tonumber(result.amount) or 1))
    return result
end

function ShopConfig.CopyRewardsForClient(rewards)
    local result = {}
    if type(rewards) ~= "table" then
        return result
    end

    for _, reward in ipairs(rewards) do
        local presentation = ShopConfig.GetRewardPresentation(reward)
        if presentation then
            table.insert(result, presentation)
        end
    end
    return result
end

return ShopConfig
