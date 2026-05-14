--[[
Script: WheelConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/WheelConfig
Purpose: V3.0 wheel reward, timing, and Developer Product configuration.
]]

local WheelConfig = {}

WheelConfig.FreeSpinIntervalSeconds = 300
WheelConfig.StateSyncIntervalSeconds = 1

WheelConfig.Purchases = {
    { ProductId = 3590501585, Spins = 5 },
    { ProductId = 3590501793, Spins = 20 },
    { ProductId = 3590502023, Spins = 50 },
}

WheelConfig.PurchaseByProductId = {}
for _, purchase in ipairs(WheelConfig.Purchases) do
    WheelConfig.PurchaseByProductId[tonumber(purchase.ProductId)] = purchase
end

WheelConfig.Rewards = {
    {
        Slot = 1,
        Id = "Shield30",
        RewardType = "Shield",
        Label = "30s Shield",
        Weight = 15,
        GiftName = "Gift1",
        TargetRotation = 270,
        DurationSeconds = 30,
    },
    {
        Slot = 2,
        Id = "AdvancedPotion",
        RewardType = "Potion",
        Label = "Advanced Potion +1",
        Weight = 4,
        GiftName = "Gift2",
        TargetRotation = 90,
        PotionId = 1002,
        Amount = 1,
    },
    {
        Slot = 3,
        Id = "WeaponSkin10003",
        RewardType = "PendingWeaponSkin",
        Label = "Special Weapon Skin 10003",
        Weight = 0.5,
        GiftName = "Gift3",
        TargetRotation = 30,
        SkinId = 10003,
        Pending = true,
    },
    {
        Slot = 4,
        Id = "WheelSpins2",
        RewardType = "WheelSpins",
        Label = "Wheel Spins +2",
        Weight = 8.5,
        GiftName = "Gift4",
        TargetRotation = 330,
        Amount = 2,
    },
    {
        Slot = 5,
        Id = "Diamonds30",
        RewardType = "Diamonds",
        Label = "Diamonds +30",
        Weight = 42,
        GiftName = "Gift5",
        TargetRotation = 210,
        Amount = 30,
    },
    {
        Slot = 6,
        Id = "BasicPotion",
        RewardType = "Potion",
        Label = "Basic Potion +1",
        Weight = 30,
        GiftName = "Gift6",
        TargetRotation = 150,
        PotionId = 1001,
        Amount = 1,
    },
}

WheelConfig.RewardBySlot = {}
WheelConfig.TotalWeight = 0
for _, reward in ipairs(WheelConfig.Rewards) do
    reward.Weight = math.max(0, tonumber(reward.Weight) or 0)
    WheelConfig.TotalWeight += reward.Weight
    WheelConfig.RewardBySlot[reward.Slot] = reward
end

function WheelConfig.GetPurchaseByProductId(productId)
    return WheelConfig.PurchaseByProductId[tonumber(productId)]
end

function WheelConfig.GetRewardBySlot(slot)
    return WheelConfig.RewardBySlot[tonumber(slot)]
end

function WheelConfig.RollReward(random)
    local totalWeight = math.max(0, tonumber(WheelConfig.TotalWeight) or 0)
    if totalWeight <= 0 then
        return WheelConfig.Rewards[1]
    end

    local roll
    if random and typeof(random) == "Random" then
        roll = random:NextNumber(0, totalWeight)
    else
        roll = math.random() * totalWeight
    end

    local cumulative = 0
    for _, reward in ipairs(WheelConfig.Rewards) do
        cumulative += math.max(0, tonumber(reward.Weight) or 0)
        if roll <= cumulative then
            return reward
        end
    end

    return WheelConfig.Rewards[#WheelConfig.Rewards]
end

return WheelConfig
