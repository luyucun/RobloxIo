--[[
脚本名字: OnlineRewardConfig
脚本文件: OnlineRewardConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/OnlineRewardConfig
说明: V4.3 在线奖励配置，来源于 IO_BaseBalanceDraft.xlsx 的“在线奖励”页签。
]]

local OnlineRewardConfig = {}

OnlineRewardConfig.DeveloperProductId = 3599440996
OnlineRewardConfig.RequestDebounceSeconds = 0.2
OnlineRewardConfig.ReadyText = "Ready!"
OnlineRewardConfig.DoneText = "Done!"

OnlineRewardConfig.Source = {
    Workbook = "IO_BaseBalanceDraft.xlsx",
    Sheet = "在线奖励",
    HeaderRow = 9,
    DataStartRow = 10,
    Columns = {
        Id = "ID",
        RewardType = "奖励类型",
        Label = "奖励名字",
        Amount = "奖励内容",
        Icon = "奖励图标",
        RequiredSeconds = "所需时间（秒）",
    },
}

-- BEGIN GENERATED ONLINE REWARD ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 在线奖励. Update via tools/SyncCodeConfigFromWorkbook.py.
OnlineRewardConfig.ExcelRows = {
    { Id = 1, RewardType = 'Experience', Label = '+500', Amount = 500, RequiredSeconds = 60, Icon = 'rbxassetid://85154686160328' },
    { Id = 2, RewardType = 'Diamonds', Label = '+20', Amount = 20, RequiredSeconds = 180, Icon = 'rbxassetid://89590364394067' },
    { Id = 3, RewardType = 'Experience', Label = '+1000', Amount = 1000, RequiredSeconds = 300, Icon = 'rbxassetid://85154686160328' },
    { Id = 4, RewardType = 'WheelSpins', Label = '+3', Amount = 3, RequiredSeconds = 420, Icon = 'rbxassetid://77152368516350' },
    { Id = 5, RewardType = 'Potion', PotionId = 1001, Label = '+2', Amount = 2, RequiredSeconds = 600, Icon = 'rbxassetid://111415582573034' },
    { Id = 6, RewardType = 'Experience', Label = '+2000', Amount = 2000, RequiredSeconds = 900, Icon = 'rbxassetid://85154686160328' },
    { Id = 7, RewardType = 'Diamonds', Label = '+100', Amount = 100, RequiredSeconds = 1200, Icon = 'rbxassetid://89590364394067' },
    { Id = 8, RewardType = 'Potion', PotionId = 1003, Label = '+2', Amount = 2, RequiredSeconds = 1800, Icon = 'rbxassetid://100154459165982' },
    { Id = 9, RewardType = 'Experience', Label = '+5000', Amount = 5000, RequiredSeconds = 2700, Icon = 'rbxassetid://85154686160328' },
    { Id = 10, RewardType = 'Diamonds', Label = '+200', Amount = 200, RequiredSeconds = 3600, Icon = 'rbxassetid://89590364394067' },
    { Id = 11, RewardType = 'WheelSpins', Label = '+10', Amount = 10, RequiredSeconds = 5400, Icon = 'rbxassetid://77152368516350' },
    { Id = 12, RewardType = 'Potion', PotionId = 1003, Label = '+5', Amount = 5, RequiredSeconds = 7200, Icon = 'rbxassetid://100154459165982' },
}
-- END GENERATED ONLINE REWARD ROWS

OnlineRewardConfig.Rewards = OnlineRewardConfig.ExcelRows

local function copyReward(reward, index)
    if type(reward) ~= "table" then
        return nil
    end

    local rewardType = tostring(reward.RewardType or reward.rewardType or "")
    return {
        Id = math.max(1, math.floor(tonumber(reward.Id or reward.id or index) or index or 1)),
        RewardIndex = math.max(1, math.floor(tonumber(index or reward.RewardIndex or reward.rewardIndex) or 1)),
        RewardType = rewardType,
        PotionId = math.max(0, math.floor(tonumber(reward.PotionId or reward.potionId) or 0)),
        Amount = math.max(1, math.floor(tonumber(reward.Amount or reward.amount) or 1)),
        DurationSeconds = math.max(0, math.floor(tonumber(reward.DurationSeconds or reward.durationSeconds) or 0)),
        RequiredSeconds = math.max(0, math.floor(tonumber(reward.RequiredSeconds or reward.requiredSeconds) or 0)),
        Icon = tostring(reward.Icon or reward.icon or ""),
        Label = tostring(reward.Label or reward.label or rewardType),
    }
end

function OnlineRewardConfig.GetRewards()
    local rewards = {}
    for index, reward in ipairs(OnlineRewardConfig.Rewards or {}) do
        local copied = copyReward(reward, index)
        if copied then
            table.insert(rewards, copied)
        end
    end
    return rewards
end

function OnlineRewardConfig.GetRewardCount()
    return #OnlineRewardConfig.GetRewards()
end

function OnlineRewardConfig.GetMaxRequiredSeconds()
    local maxRequiredSeconds = 0
    for _, reward in ipairs(OnlineRewardConfig.GetRewards()) do
        maxRequiredSeconds = math.max(maxRequiredSeconds, reward.RequiredSeconds)
    end
    return maxRequiredSeconds
end

return OnlineRewardConfig
