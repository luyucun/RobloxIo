--[[
Script: TaskConfig
File: TaskConfig.lua
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/TaskConfig
Purpose: V5.3 daily and weekly task configuration generated from IO_BaseBalanceDraft.xlsx.
]]

local TaskConfig = {}

TaskConfig.Period = {
    Daily = "Daily",
    Weekly = "Weekly",
}

TaskConfig.TaskType = {
    OnlineSeconds = "OnlineSeconds",
    PlayerKills = "PlayerKills",
    InviteFriend = "InviteFriend",
    WheelSpinsUsed = "WheelSpinsUsed",
    EnemyWeaponsBroken = "EnemyWeaponsBroken",
    DiamondsEarned = "DiamondsEarned",
    LoginDays = "LoginDays",
}

TaskConfig.RequestDebounceSeconds = 0.2

TaskConfig.Source = {
    Workbook = "IO_BaseBalanceDraft.xlsx",
    Sheet = "任务系统数据表",
    HeaderRow = 21,
    DataStartRow = 22,
}

-- BEGIN GENERATED TASK ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 任务系统数据表. Update via tools/SyncCodeConfigFromWorkbook.py.
TaskConfig.Tasks = {
    {
        TaskId = 101,
        Period = 'Daily',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 1001,
        Target = 900,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 1,
        Description = 'Play for 15 minutes today',
        ShortTitle = 'Stay Online',
        ShortDescription = 'Play for 15 minutes today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 1, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 102,
        Period = 'Daily',
        TaskType = 'PlayerKills',
        TaskTypeId = 1002,
        Target = 5,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 1,
        Description = 'Defeat 5 players today',
        ShortTitle = 'Easy Kills',
        ShortDescription = 'Defeat 5 players today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 1, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 103,
        Period = 'Daily',
        TaskType = 'WheelSpinsUsed',
        TaskTypeId = 1004,
        Target = 5,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 1,
        Description = 'Spin the wheel 5 times today',
        ShortTitle = 'Spin Party',
        ShortDescription = 'Spin the wheel 5 times today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 1, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 104,
        Period = 'Daily',
        TaskType = 'InviteFriend',
        TaskTypeId = 1003,
        Target = 1,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 3,
        Description = 'Invite 1 friend to join the game',
        ShortTitle = 'Friend Bonus',
        ShortDescription = 'Invite 1 friend to join the game',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 3, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 105,
        Period = 'Daily',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 1001,
        Target = 3600,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 3,
        Description = 'Play for 60 minutes today',
        ShortTitle = 'Play Longer',
        ShortDescription = 'Play for 60 minutes today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 3, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 106,
        Period = 'Daily',
        TaskType = 'PlayerKills',
        TaskTypeId = 1002,
        Target = 20,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 3,
        Description = 'Defeat 20 players today',
        ShortTitle = 'Kill Streak',
        ShortDescription = 'Defeat 20 players today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 3, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 107,
        Period = 'Daily',
        TaskType = 'EnemyWeaponsBroken',
        TaskTypeId = 1005,
        Target = 30,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 2,
        Description = 'Break 30 enemy weapons today',
        ShortTitle = 'Blade Breaker',
        ShortDescription = 'Break 30 enemy weapons today',
        Icon = 'rbxassetid://100403311120383',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 2, Icon = 'rbxassetid://100403311120383' },
        },
    },
    {
        TaskId = 201,
        Period = 'Weekly',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 2001,
        Target = 3600,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 5,
        Description = 'Play for 1 hour this week',
        ShortTitle = 'Weekly Play',
        ShortDescription = 'Play for 1 hour this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 5, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 202,
        Period = 'Weekly',
        TaskType = 'PlayerKills',
        TaskTypeId = 2002,
        Target = 50,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 5,
        Description = 'Defeat 50 players this week',
        ShortTitle = 'Player Hunter',
        ShortDescription = 'Defeat 50 players this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 5, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 203,
        Period = 'Weekly',
        TaskType = 'LoginDays',
        TaskTypeId = 2004,
        Target = 7,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 5,
        Description = 'Log in for 7 days',
        ShortTitle = '7-Day Login',
        ShortDescription = 'Log in for 7 days',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 5, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 204,
        Period = 'Weekly',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 2001,
        Target = 10800,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 10,
        Description = 'Play for 3 hours this week',
        ShortTitle = 'Play More',
        ShortDescription = 'Play for 3 hours this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 10, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 205,
        Period = 'Weekly',
        TaskType = 'PlayerKills',
        TaskTypeId = 2002,
        Target = 100,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 10,
        Description = 'Defeat 100 players this week',
        ShortTitle = 'Battle Master',
        ShortDescription = 'Defeat 100 players this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 10, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 206,
        Period = 'Weekly',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 2001,
        Target = 18000,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 15,
        Description = 'Play for 5 hours this week',
        ShortTitle = 'Long Play',
        ShortDescription = 'Play for 5 hours this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 15, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 207,
        Period = 'Weekly',
        TaskType = 'OnlineSeconds',
        TaskTypeId = 2001,
        Target = 36000,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 20,
        Description = 'Play for 10 hours this week',
        ShortTitle = 'Hard Grinder',
        ShortDescription = 'Play for 10 hours this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 20, Icon = 'rbxassetid://89590364394067' },
        },
    },
    {
        TaskId = 208,
        Period = 'Weekly',
        TaskType = 'PlayerKills',
        TaskTypeId = 2002,
        Target = 200,
        RewardType = 'Chest',
        ChestId = 101,
        Amount = 20,
        Description = 'Defeat 200 players this week',
        ShortTitle = 'Arena Legend',
        ShortDescription = 'Defeat 200 players this week',
        Icon = 'rbxassetid://89590364394067',
        Rewards = {
            { RewardType = 'Chest', ChestId = 101, Amount = 20, Icon = 'rbxassetid://89590364394067' },
        },
    },
}
-- END GENERATED TASK ROWS

local tasksById = nil
local tasksByPeriod = nil

local function normalizePeriod(period)
    local text = tostring(period or "")
    if text == TaskConfig.Period.Weekly or string.lower(text) == "weekly" or string.lower(text) == "week" then
        return TaskConfig.Period.Weekly
    end
    return TaskConfig.Period.Daily
end

local function copyReward(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local copied = {
        RewardType = tostring(reward.RewardType or reward.rewardType or ""),
        PotionId = math.max(0, math.floor(tonumber(reward.PotionId or reward.potionId) or 0)),
        ChestId = math.max(0, math.floor(tonumber(reward.ChestId or reward.chestId) or 0)),
        Amount = math.max(1, math.floor(tonumber(reward.Amount or reward.amount) or 1)),
        Icon = tostring(reward.Icon or reward.icon or ""),
    }
    if copied.RewardType == "" then
        return nil
    end
    return copied
end

local function buildRewards(task)
    local result = {}
    if type(task) ~= "table" then
        return result
    end

    local sourceRewards = task.Rewards or task.rewards
    if type(sourceRewards) == "table" then
        for _, reward in ipairs(sourceRewards) do
            local copied = copyReward(reward)
            if copied then
                table.insert(result, copied)
            end
        end
    end

    if #result <= 0 then
        local fallback = copyReward({
            RewardType = task.RewardType or task.rewardType,
            PotionId = task.PotionId or task.potionId,
            ChestId = task.ChestId or task.chestId,
            Amount = task.Amount or task.amount,
            Icon = task.Icon or task.icon,
        })
        if fallback then
            table.insert(result, fallback)
        end
    end

    return result
end

local function copyTask(task)
    if type(task) ~= "table" then
        return nil
    end

    local rewards = buildRewards(task)
    local primaryReward = rewards[1] or copyReward({
        RewardType = task.RewardType or task.rewardType,
        PotionId = task.PotionId or task.potionId,
        ChestId = task.ChestId or task.chestId,
        Amount = task.Amount or task.amount,
        Icon = task.Icon or task.icon,
    }) or {
        RewardType = "",
        PotionId = 0,
        ChestId = 0,
        Amount = 1,
        Icon = "",
    }

    return {
        TaskId = math.max(0, math.floor(tonumber(task.TaskId or task.taskId) or 0)),
        Period = normalizePeriod(task.Period or task.period),
        TaskType = tostring(task.TaskType or task.taskType or ""),
        TaskTypeId = math.max(0, math.floor(tonumber(task.TaskTypeId or task.taskTypeId) or 0)),
        Target = math.max(1, math.floor(tonumber(task.Target or task.target) or 1)),
        RewardType = primaryReward.RewardType,
        PotionId = primaryReward.PotionId,
        ChestId = primaryReward.ChestId,
        Amount = primaryReward.Amount,
        Description = tostring(task.Description or task.description or ""),
        ShortTitle = tostring(task.ShortTitle or task.shortTitle or ""),
        ShortDescription = tostring(task.ShortDescription or task.shortDescription or ""),
        Icon = primaryReward.Icon,
        Rewards = rewards,
    }
end

local function ensureIndexes()
    if tasksById and tasksByPeriod then
        return
    end

    tasksById = {}
    tasksByPeriod = {
        [TaskConfig.Period.Daily] = {},
        [TaskConfig.Period.Weekly] = {},
    }

    for _, task in ipairs(TaskConfig.Tasks or {}) do
        local copied = copyTask(task)
        if copied and copied.TaskId > 0 then
            tasksById[copied.TaskId] = copied
            local period = normalizePeriod(copied.Period)
            table.insert(tasksByPeriod[period], copied)
        end
    end

    for _, rows in pairs(tasksByPeriod) do
        table.sort(rows, function(left, right)
            return (left.TaskId or 0) < (right.TaskId or 0)
        end)
    end
end

function TaskConfig.GetTask(taskId)
    ensureIndexes()
    local copied = tasksById[math.floor(tonumber(taskId) or 0)]
    return copyTask(copied)
end

function TaskConfig.GetTasks(period)
    ensureIndexes()
    local result = {}
    for _, task in ipairs(tasksByPeriod[normalizePeriod(period)] or {}) do
        table.insert(result, copyTask(task))
    end
    return result
end

function TaskConfig.GetAllTasks()
    ensureIndexes()
    local result = {}
    for _, task in ipairs(TaskConfig.Tasks or {}) do
        local copied = copyTask(task)
        if copied then
            table.insert(result, copied)
        end
    end
    table.sort(result, function(left, right)
        return (left.TaskId or 0) < (right.TaskId or 0)
    end)
    return result
end

function TaskConfig.CopyTaskForClient(task)
    local copied = copyTask(task)
    if not copied then
        return nil
    end

    local rewards = {}
    for _, reward in ipairs(copied.Rewards or {}) do
        table.insert(rewards, {
            rewardType = reward.RewardType,
            potionId = reward.PotionId,
            chestId = reward.ChestId,
            amount = reward.Amount,
            icon = reward.Icon,
        })
    end

    return {
        taskId = copied.TaskId,
        period = copied.Period,
        taskType = copied.TaskType,
        taskTypeId = copied.TaskTypeId,
        target = copied.Target,
        rewardType = copied.RewardType,
        potionId = copied.PotionId,
        chestId = copied.ChestId,
        amount = copied.Amount,
        description = copied.Description,
        shortTitle = copied.ShortTitle,
        shortDescription = copied.ShortDescription,
        icon = copied.Icon,
        rewards = rewards,
    }
end

function TaskConfig.GetUtcDay(now)
    return math.floor((tonumber(now) or os.time()) / 86400)
end

function TaskConfig.GetWeekStartUtcDay(now)
    local utcDay = TaskConfig.GetUtcDay(now)
    -- 1970-01-01 was Thursday. Monday becomes offset 0.
    local dayOfWeekFromMonday = (utcDay + 3) % 7
    return utcDay - dayOfWeekFromMonday
end

function TaskConfig.GetCycleKey(period, now)
    local resolvedPeriod = normalizePeriod(period)
    if resolvedPeriod == TaskConfig.Period.Weekly then
        return "W:" .. tostring(TaskConfig.GetWeekStartUtcDay(now))
    end
    return "D:" .. tostring(TaskConfig.GetUtcDay(now))
end

function TaskConfig.GetResetTimestamp(period, now)
    local timestamp = tonumber(now) or os.time()
    local resolvedPeriod = normalizePeriod(period)
    if resolvedPeriod == TaskConfig.Period.Weekly then
        return (TaskConfig.GetWeekStartUtcDay(timestamp) + 7) * 86400
    end
    return (TaskConfig.GetUtcDay(timestamp) + 1) * 86400
end

return TaskConfig
