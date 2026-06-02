--[[
Script: ShopConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/ShopConfig
Purpose: V3.5 shop purchase and reward presentation configuration.
]]

local ShopConfig = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[ShopConfig] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local PotionConfig = requireSharedModule("PotionConfig")

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
    Experience = {
        Image = "rbxassetid://112367399278116",
        AspectRatio = 1,
    },
    Shield = {
        Image = "",
        AspectRatio = 1,
    },
    Skin10002 = {
        Image = "rbxassetid://92172382104718",
        AspectRatio = 1,
    },
    Skin10006 = {
        Image = "rbxassetid://96177713116872",
        AspectRatio = 1,
    },
    Skin10007 = {
        Image = "rbxassetid://111501964259020",
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
        durationSeconds = reward.DurationSeconds,
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
        local potion = PotionConfig.GetPotion and PotionConfig.GetPotion(reward.PotionId) or nil
        result.label = result.label or (potion and potion.Name) or ("Potion " .. tostring(reward.PotionId))
    elseif reward.RewardType == "WheelSpins" then
        iconConfig = ShopConfig.RewardIcons.WheelSpins
        result.label = result.label or "Spin"
    elseif reward.RewardType == "Diamonds" then
        iconConfig = ShopConfig.RewardIcons.Diamonds
        result.label = result.label or "Diamonds"
    elseif reward.RewardType == "Experience" then
        iconConfig = ShopConfig.RewardIcons.Experience
        result.label = result.label or "EXP"
    elseif reward.RewardType == "Shield" then
        iconConfig = ShopConfig.RewardIcons.Shield
        result.label = result.label or "Shield"
        result.durationSeconds = math.max(1, math.floor(tonumber(result.durationSeconds or reward.Amount) or 1))
    elseif reward.RewardType == "Skin" then
        iconConfig = ShopConfig.RewardIcons["Skin" .. tostring(reward.SkinId)]
        local skinId = math.max(0, math.floor(tonumber(reward.SkinId) or 0))
        result.label = result.label or ("Skin " .. tostring(skinId > 0 and skinId or ""))
    end

    if reward.RewardType == "Potion" and not iconConfig then
        local potion = PotionConfig.GetPotion and PotionConfig.GetPotion(reward.PotionId) or nil
        result.icon = result.icon or (potion and potion.IconImage) or ""
    else
        result.icon = result.icon or (iconConfig and iconConfig.Image) or ""
    end
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
