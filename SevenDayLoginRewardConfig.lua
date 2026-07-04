--[[
脚本名字: SevenDayLoginRewardConfig
脚本文件: SevenDayLoginRewardConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/SevenDayLoginRewardConfig
说明: V4.4 七日登录奖励配置，来源于 IO_BaseBalanceDraft.xlsx 的“七日登录奖励”页签。
]]

local SevenDayLoginRewardConfig = {}

SevenDayLoginRewardConfig.DeveloperProductId = 3599525565
SevenDayLoginRewardConfig.RequestDebounceSeconds = 0.2
SevenDayLoginRewardConfig.RewardCount = 7

SevenDayLoginRewardConfig.Source = {
    Workbook = "IO_BaseBalanceDraft.xlsx",
    Sheet = "七日登录奖励",
    FirstCycleHeaderRow = 5,
    FirstCycleDataStartRow = 6,
    RepeatCycleHeaderRow = 19,
    RepeatCycleDataStartRow = 20,
}

-- BEGIN GENERATED SEVEN DAY LOGIN REWARD ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 七日登录奖励. Update via tools/SyncCodeConfigFromWorkbook.py.
SevenDayLoginRewardConfig.FirstCycleRewards = {
    { DayIndex = 1, RewardType = 'WheelSpins', Amount = 3, Label = 'Spin x3', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 2, RewardType = 'Skin', SkinId = 10007, Amount = 1, Label = 'Watermelon Pop', Icon = 'rbxassetid://97879805462753' },
    { DayIndex = 3, RewardType = 'Diamonds', Amount = 3000, Label = 'Diamonds x3000', Icon = 'rbxassetid://89590364394067' },
    { DayIndex = 4, RewardType = 'WheelSpins', Amount = 5, Label = 'Spin x5', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 5, RewardType = 'Diamonds', Amount = 5000, Label = 'Diamonds x5000', Icon = 'rbxassetid://89590364394067' },
    { DayIndex = 6, RewardType = 'WheelSpins', Amount = 10, Label = 'Spin x10', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 7, RewardType = 'Skin', SkinId = 10006, Amount = 1, Label = 'Abyss Sword', Icon = 'rbxassetid://107965659960902' },
}

SevenDayLoginRewardConfig.RepeatCycleRewards = {
    { DayIndex = 1, RewardType = 'WheelSpins', Amount = 3, Label = 'Spin x3', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 2, RewardType = 'Diamonds', Amount = 3000, Label = 'Diamonds x3000', Icon = 'rbxassetid://89590364394067' },
    { DayIndex = 3, RewardType = 'WheelSpins', Amount = 5, Label = 'Spin x5', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 4, RewardType = 'WheelSpins', Amount = 5, Label = 'Spin x5', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 5, RewardType = 'Diamonds', Amount = 5000, Label = 'Diamonds x5000', Icon = 'rbxassetid://89590364394067' },
    { DayIndex = 6, RewardType = 'WheelSpins', Amount = 10, Label = 'Spin x10', Icon = 'rbxassetid://77152368516350' },
    { DayIndex = 7, RewardType = 'Potion', PotionId = 1003, Amount = 10, Label = 'Rare Potion x10', Icon = 'rbxassetid://100154459165982' },
}
-- END GENERATED SEVEN DAY LOGIN REWARD ROWS

local function copyReward(reward, dayIndex)
    if type(reward) ~= "table" then
        return nil
    end

    local rewardType = tostring(reward.RewardType or reward.rewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward.Amount or reward.amount) or 1))
    local label = tostring(reward.Label or reward.label or "")
    if label == "" then
        if rewardType == "Potion" then
            label = "Potion x" .. tostring(amount)
        elseif rewardType == "WheelSpins" then
            label = "Spin x" .. tostring(amount)
        elseif rewardType == "Skin" then
            label = "Skin"
        else
            label = rewardType .. " x" .. tostring(amount)
        end
    end

    return {
        DayIndex = math.max(1, math.floor(tonumber(reward.DayIndex or reward.dayIndex or dayIndex) or dayIndex or 1)),
        RewardType = rewardType,
        PotionId = math.max(0, math.floor(tonumber(reward.PotionId or reward.potionId) or 0)),
        SkinId = math.max(0, math.floor(tonumber(reward.SkinId or reward.skinId) or 0)),
        Amount = amount,
        DurationSeconds = math.max(0, math.floor(tonumber(reward.DurationSeconds or reward.durationSeconds) or 0)),
        Icon = tostring(reward.Icon or reward.icon or ""),
        Label = label,
    }
end

function SevenDayLoginRewardConfig.GetRewardsForCycle(cycleId)
    local source = math.max(1, math.floor(tonumber(cycleId) or 1)) <= 1
        and SevenDayLoginRewardConfig.FirstCycleRewards
        or SevenDayLoginRewardConfig.RepeatCycleRewards
    local rewards = {}
    for index = 1, SevenDayLoginRewardConfig.RewardCount do
        local copied = copyReward(source and source[index], index)
        if copied then
            rewards[index] = copied
        end
    end
    return rewards
end

function SevenDayLoginRewardConfig.GetReward(cycleId, dayIndex)
    local rewards = SevenDayLoginRewardConfig.GetRewardsForCycle(cycleId)
    return rewards[math.max(1, math.floor(tonumber(dayIndex) or 1))]
end

function SevenDayLoginRewardConfig.GetRewardCount()
    return math.max(1, math.floor(tonumber(SevenDayLoginRewardConfig.RewardCount) or 7))
end

return SevenDayLoginRewardConfig
