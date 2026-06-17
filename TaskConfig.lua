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
    { TaskId = 101, Period = 'Daily', TaskType = 'OnlineSeconds', TaskTypeId = 1001, Target = 900, RewardType = 'Diamonds', Amount = 1000, Description = '今日累计在线时长达到15分钟', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 102, Period = 'Daily', TaskType = 'PlayerKills', TaskTypeId = 1002, Target = 5, RewardType = 'Potion', PotionId = 1002, Amount = 2, Description = '今日累计击杀5名其他玩家', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 103, Period = 'Daily', TaskType = 'WheelSpinsUsed', TaskTypeId = 1004, Target = 5, RewardType = 'Diamonds', Amount = 1000, Description = '今日累计使用5次转盘', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 104, Period = 'Daily', TaskType = 'InviteFriend', TaskTypeId = 1003, Target = 1, RewardType = 'Potion', PotionId = 1003, Amount = 1, Description = '今日累计邀请一名好友加入游戏', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 201, Period = 'Weekly', TaskType = 'OnlineSeconds', TaskTypeId = 2001, Target = 3600, RewardType = 'Diamonds', Amount = 5000, Description = '本周累计在线达到1小时', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 202, Period = 'Weekly', TaskType = 'OnlineSeconds', TaskTypeId = 2001, Target = 10800, RewardType = 'Diamonds', Amount = 5000, Description = '本周累计在线达到3小时', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 203, Period = 'Weekly', TaskType = 'PlayerKills', TaskTypeId = 2002, Target = 50, RewardType = 'Diamonds', Amount = 5000, Description = '本周累计击杀玩家50人', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 204, Period = 'Weekly', TaskType = 'PlayerKills', TaskTypeId = 2002, Target = 100, RewardType = 'Diamonds', Amount = 5000, Description = '本周累计击杀玩家100人', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 205, Period = 'Weekly', TaskType = 'DiamondsEarned', TaskTypeId = 2003, Target = 10000, RewardType = 'Diamonds', Amount = 5000, Description = '本周累计获得钻石10000点', Icon = 'rbxassetid://124553019062246' },
    { TaskId = 206, Period = 'Weekly', TaskType = 'LoginDays', TaskTypeId = 2004, Target = 7, RewardType = 'Diamonds', Amount = 5000, Description = '累计登录7天', Icon = 'rbxassetid://124553019062246' },
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

local function copyTask(task)
    if type(task) ~= "table" then
        return nil
    end

    return {
        TaskId = math.max(0, math.floor(tonumber(task.TaskId or task.taskId) or 0)),
        Period = normalizePeriod(task.Period or task.period),
        TaskType = tostring(task.TaskType or task.taskType or ""),
        TaskTypeId = math.max(0, math.floor(tonumber(task.TaskTypeId or task.taskTypeId) or 0)),
        Target = math.max(1, math.floor(tonumber(task.Target or task.target) or 1)),
        RewardType = tostring(task.RewardType or task.rewardType or ""),
        PotionId = math.max(0, math.floor(tonumber(task.PotionId or task.potionId) or 0)),
        Amount = math.max(1, math.floor(tonumber(task.Amount or task.amount) or 1)),
        Description = tostring(task.Description or task.description or ""),
        Icon = tostring(task.Icon or task.icon or ""),
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

    return {
        taskId = copied.TaskId,
        period = copied.Period,
        taskType = copied.TaskType,
        taskTypeId = copied.TaskTypeId,
        target = copied.Target,
        rewardType = copied.RewardType,
        potionId = copied.PotionId,
        amount = copied.Amount,
        description = copied.Description,
        icon = copied.Icon,
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
