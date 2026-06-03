--[[
Script: TitleConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/TitleConfig
Purpose: V4.6 player title catalog and unlock-condition metadata.
]]

local TitleConfig = {}

-- BEGIN GENERATED TITLE ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 称号. Update via tools/SyncCodeConfigFromWorkbook.py.
TitleConfig.Titles = {
    {
        Id = 1001,
        Name = 'Rookie Blade',
        Description = 'Reach Lv.50',
        UnlockConditionText = 'Reach Lv.50',
        IconImage = 'rbxassetid://117876237518754',
        Condition = { Type = 'HighestLevelReached', Target = 50 },
    },
    {
        Id = 1002,
        Name = 'Sword Master',
        Description = 'Reach Lv.200',
        UnlockConditionText = 'Reach Lv.200',
        IconImage = 'rbxassetid://122614305998361',
        Condition = { Type = 'HighestLevelReached', Target = 200 },
    },
    {
        Id = 1003,
        Name = 'Blade King',
        Description = 'Reach Lv.400',
        UnlockConditionText = 'Reach Lv.400',
        IconImage = 'rbxassetid://111441986688074',
        Condition = { Type = 'HighestLevelReached', Target = 400 },
    },
    {
        Id = 1004,
        Name = 'First Blood',
        Description = 'Defeat 10 players in total.',
        UnlockConditionText = 'Defeat 10 players in total.',
        IconImage = 'rbxassetid://100396005529845',
        Condition = { Type = 'TotalPlayerKills', Target = 10 },
    },
    {
        Id = 1005,
        Name = 'Arena Killer',
        Description = 'Defeat 100 players in total.',
        UnlockConditionText = 'Defeat 100 players in total.',
        IconImage = 'rbxassetid://73072779545270',
        Condition = { Type = 'TotalPlayerKills', Target = 100 },
    },
    {
        Id = 1006,
        Name = 'Executioner',
        Description = 'Defeat 500 players in total.',
        UnlockConditionText = 'Defeat 500 players in total.',
        IconImage = 'rbxassetid://121510302407569',
        Condition = { Type = 'TotalPlayerKills', Target = 500 },
    },
    {
        Id = 1007,
        Name = 'Comeback Kid',
        Description = 'Die 30 times in total.',
        UnlockConditionText = 'Die 30 times in total.',
        IconImage = 'rbxassetid://111744161308671',
        Condition = { Type = 'TotalDeaths', Target = 30 },
    },
    {
        Id = 1008,
        Name = 'Never Give Up',
        Description = 'Die 100 times in total.',
        UnlockConditionText = 'Die 100 times in total.',
        IconImage = 'rbxassetid://114762771736684',
        Condition = { Type = 'TotalDeaths', Target = 100 },
    },
    {
        Id = 1009,
        Name = 'Gem Collector',
        Description = 'Earn 1,000 gems in total.',
        UnlockConditionText = 'Earn 1,000 gems in total.',
        IconImage = 'rbxassetid://133503158361369',
        Condition = { Type = 'TotalDiamondsEarned', Target = 1000 },
    },
    {
        Id = 1010,
        Name = 'Diamond Lord',
        Description = 'Earn 10,000 gems in total.',
        UnlockConditionText = 'Earn 10,000 gems in total.',
        IconImage = 'rbxassetid://105736673011968',
        Condition = { Type = 'TotalDiamondsEarned', Target = 10000 },
    },
}
-- END GENERATED TITLE ROWS

TitleConfig.ById = {}

for index, title in ipairs(TitleConfig.Titles) do
    title.Id = math.floor(tonumber(title.Id) or 0)
    title.SortOrder = index
    title.Name = tostring(title.Name or "")
    title.Description = tostring(title.Description or "")
    title.UnlockConditionText = tostring(title.UnlockConditionText or "")
    title.IconImage = tostring(title.IconImage or "")
    title.Condition = type(title.Condition) == "table" and title.Condition or nil
    if title.Condition then
        title.Condition.Type = tostring(title.Condition.Type or "")
        title.Condition.Target = math.max(0, math.floor(tonumber(title.Condition.Target) or 0))
    end
    TitleConfig.ById[title.Id] = title
end

function TitleConfig.GetTitle(titleId)
    return TitleConfig.ById[math.floor(tonumber(titleId) or 0)]
end

function TitleConfig.GetAllTitles()
    return TitleConfig.Titles
end

function TitleConfig.IsUnlocked(title, metrics)
    if type(title) ~= "table" or type(title.Condition) ~= "table" then
        return false
    end

    local conditionType = tostring(title.Condition.Type or "")
    local target = math.max(0, math.floor(tonumber(title.Condition.Target) or 0))
    if target <= 0 then
        return false
    end

    local source = type(metrics) == "table" and metrics or {}
    if conditionType == "HighestLevelReached" then
        return math.floor(tonumber(source.highestLevelReached) or 0) >= target
    elseif conditionType == "TotalPlayerKills" then
        return math.floor(tonumber(source.totalPlayerKills) or 0) >= target
    elseif conditionType == "TotalDeaths" then
        return math.floor(tonumber(source.totalDeaths) or 0) >= target
    elseif conditionType == "TotalDiamondsEarned" then
        return math.floor(tonumber(source.totalDiamondsEarned) or 0) >= target
    elseif conditionType == "TotalOnlineHours" then
        return math.floor((tonumber(source.totalOnlineSeconds) or 0) / 3600) >= target
    end

    return false
end

function TitleConfig.CopyForClient(title)
    if type(title) ~= "table" then
        return nil
    end

    return {
        id = title.Id,
        name = title.Name,
        description = title.Description,
        unlockConditionText = title.UnlockConditionText,
        iconImage = title.IconImage,
    }
end

return TitleConfig
