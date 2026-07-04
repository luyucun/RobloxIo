--[[
Script: TaskService
File: TaskService.lua
Type: ModuleScript
Studio path: ServerScriptService/Services/TaskService
Purpose: V5.3 server-authoritative daily and weekly task progress, claims, and rewards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

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
        "[TaskService] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local TaskConfig = requireSharedModule("TaskConfig")
local ShopConfig = requireSharedModule("ShopConfig")

local TaskService = {}

TaskService._remoteEventService = nil
TaskService._playerStateService = nil
TaskService._rebirthService = nil
TaskService._potionService = nil
TaskService._gameAnalyticsService = nil
TaskService._taskStateSyncEvent = nil
TaskService._requestStateSyncEvent = nil
TaskService._requestClaimEvent = nil
TaskService._requestInviteTaskProgressEvent = nil
TaskService._shopRewardFeedbackEvent = nil
TaskService._connections = {}
TaskService._lastRequestClockByUserId = {}
TaskService._claimLocksByUserId = {}

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getUserId(player)
    return ActorUtils.IsPlayer(player) and player.UserId or 0
end

local function copyNumberMap(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end
    for key, value in pairs(source) do
        local normalizedKey = tostring(key or "")
        local normalizedValue = math.max(0, math.floor(tonumber(value) or 0))
        if normalizedKey ~= "" and normalizedValue > 0 then
            result[normalizedKey] = normalizedValue
        end
    end
    return result
end

local function copyBooleanMap(source)
    local result = {}
    if type(source) ~= "table" then
        return result
    end
    for key, value in pairs(source) do
        local normalizedKey = tostring(key or "")
        if normalizedKey ~= "" and value == true then
            result[normalizedKey] = true
        end
    end
    return result
end

local function normalizePeriodState(source, period, nowTimestamp)
    local normalized = {}
    local cycleKey = TaskConfig.GetCycleKey(period, nowTimestamp)
    if type(source) == "table" and tostring(source.CycleKey or source.cycleKey or "") == cycleKey then
        normalized.ProgressByTaskId = copyNumberMap(source.ProgressByTaskId or source.progressByTaskId or source.Progress or source.progress)
        normalized.ClaimedByTaskId = copyBooleanMap(source.ClaimedByTaskId or source.claimedByTaskId or source.Claimed or source.claimed)
        normalized.CompletedReportedByTaskId = copyBooleanMap(source.CompletedReportedByTaskId or source.completedReportedByTaskId)
        normalized.LoginDays = copyBooleanMap(source.LoginDays or source.loginDays)
    else
        normalized.ProgressByTaskId = {}
        normalized.ClaimedByTaskId = {}
        normalized.CompletedReportedByTaskId = {}
        normalized.LoginDays = {}
    end
    normalized.CycleKey = cycleKey
    return normalized
end

local function getPeriodForTask(task)
    local period = tostring(task and task.Period or TaskConfig.Period.Daily)
    if period == TaskConfig.Period.Weekly then
        return TaskConfig.Period.Weekly
    end
    return TaskConfig.Period.Daily
end

local function formatTaskKey(taskId)
    return tostring(math.max(0, math.floor(tonumber(taskId) or 0)))
end

local function countMapEntries(source)
    local count = 0
    if type(source) ~= "table" then
        return count
    end
    for _, value in pairs(source) do
        if value == true then
            count += 1
        end
    end
    return count
end

function TaskService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function TaskService:_markDirty(player)
    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
end

function TaskService:NormalizeState(rawState, nowTimestamp)
    local now = math.max(0, math.floor(tonumber(nowTimestamp) or os.time()))
    local source = type(rawState) == "table" and rawState or {}
    return {
        Daily = normalizePeriodState(source.Daily or source.daily, TaskConfig.Period.Daily, now),
        Weekly = normalizePeriodState(source.Weekly or source.weekly, TaskConfig.Period.Weekly, now),
    }
end

function TaskService:_getPlayerTaskState(player)
    if not (ActorUtils.IsPlayer(player) and self._playerStateService) then
        return nil
    end

    local playerState = self._playerStateService:GetState(player)
    if type(playerState) ~= "table" then
        return nil
    end

    playerState.TaskState = self:NormalizeState(playerState.TaskState, os.time())
    return playerState.TaskState
end

function TaskService:_getPeriodState(player, period)
    local taskState = self:_getPlayerTaskState(player)
    if not taskState then
        return nil
    end
    return taskState[period == TaskConfig.Period.Weekly and "Weekly" or "Daily"]
end

function TaskService:_getProgress(periodState, taskId)
    if type(periodState) ~= "table" then
        return 0
    end
    return math.max(0, math.floor(tonumber(periodState.ProgressByTaskId[formatTaskKey(taskId)]) or 0))
end

function TaskService:_setProgress(periodState, taskId, value)
    if type(periodState) ~= "table" then
        return
    end
    periodState.ProgressByTaskId[formatTaskKey(taskId)] = math.max(0, math.floor(tonumber(value) or 0))
end

function TaskService:_isClaimed(periodState, taskId)
    return type(periodState) == "table" and periodState.ClaimedByTaskId[formatTaskKey(taskId)] == true
end

function TaskService:_trackTaskEvent(player, eventName, value, fields)
    if not (self._gameAnalyticsService and self._gameAnalyticsService.TrackCustom and ActorUtils.IsPlayer(player)) then
        return
    end
    local safeFields = type(fields) == "table" and fields or {}
    safeFields.source = safeFields.source or "task"
    self._gameAnalyticsService:TrackCustom(player, eventName, value or 1, safeFields)
end

function TaskService:_buildTaskPayload(task, periodState)
    local progress = math.min(self:_getProgress(periodState, task.TaskId), task.Target)
    local isClaimed = self:_isClaimed(periodState, task.TaskId)
    local isComplete = progress >= task.Target
    local clientTask = TaskConfig.CopyTaskForClient(task)
    clientTask.progress = progress
    clientTask.isComplete = isComplete
    clientTask.isClaimed = isClaimed
    clientTask.isClaimable = isComplete and not isClaimed
    return clientTask
end

function TaskService:BuildStatePayload(player)
    local taskState = self:_getPlayerTaskState(player)
    if type(taskState) ~= "table" then
        taskState = {
            Daily = normalizePeriodState(nil, TaskConfig.Period.Daily, os.time()),
            Weekly = normalizePeriodState(nil, TaskConfig.Period.Weekly, os.time()),
        }
    end
    local nowTimestamp = os.time()
    local dailyResetAt = TaskConfig.GetResetTimestamp(TaskConfig.Period.Daily, nowTimestamp)
    local weeklyResetAt = TaskConfig.GetResetTimestamp(TaskConfig.Period.Weekly, nowTimestamp)
    local tasks = {
        daily = {},
        weekly = {},
    }
    local hasClaimableReward = false

    for _, task in ipairs(TaskConfig.GetTasks(TaskConfig.Period.Daily)) do
        local payload = self:_buildTaskPayload(task, taskState.Daily)
        if payload.isClaimable then
            hasClaimableReward = true
        end
        table.insert(tasks.daily, payload)
    end

    for _, task in ipairs(TaskConfig.GetTasks(TaskConfig.Period.Weekly)) do
        local payload = self:_buildTaskPayload(task, taskState.Weekly)
        if payload.isClaimable then
            hasClaimableReward = true
        end
        table.insert(tasks.weekly, payload)
    end

    return {
        tasks = tasks,
        dailyCycleKey = taskState.Daily.CycleKey,
        weeklyCycleKey = taskState.Weekly.CycleKey,
        dailyResetAt = dailyResetAt,
        weeklyResetAt = weeklyResetAt,
        serverTimestamp = nowTimestamp,
        hasClaimableReward = hasClaimableReward,
        weeklyLoginDays = countMapEntries(taskState.Weekly.LoginDays),
    }
end

function TaskService:PushState(player)
    if not (self._taskStateSyncEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end
    self._taskStateSyncEvent:FireClient(player, self:BuildStatePayload(player))
end

function TaskService:_canProcessRequest(player, requestKind)
    if not ActorUtils.IsPlayer(player) then
        return false
    end
    local debounceSeconds = math.max(0.05, tonumber(TaskConfig.RequestDebounceSeconds) or 0.2)
    local nowClock = os.clock()
    local requestKey = tostring(player.UserId) .. ":" .. tostring(requestKind or "default")
    local lastClock = tonumber(self._lastRequestClockByUserId[requestKey]) or 0
    if nowClock - lastClock < debounceSeconds then
        return false
    end
    self._lastRequestClockByUserId[requestKey] = nowClock
    return true
end

function TaskService:RecordProgress(player, taskType, amount, context)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self:_isPlayerLoaded(player)) then
        return false
    end

    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    if delta <= 0 then
        return false
    end

    local taskState = self:_getPlayerTaskState(player)
    if not taskState then
        return false
    end

    local didChange = false
    for _, task in ipairs(TaskConfig.GetAllTasks()) do
        if task.TaskType == taskType then
            local period = getPeriodForTask(task)
            local periodState = period == TaskConfig.Period.Weekly and taskState.Weekly or taskState.Daily
            local taskKey = formatTaskKey(task.TaskId)
            local oldProgress = self:_getProgress(periodState, task.TaskId)
            local newProgress = math.min(task.Target, oldProgress + delta)
            if newProgress ~= oldProgress then
                periodState.ProgressByTaskId[taskKey] = newProgress
                didChange = true
                self:_trackTaskEvent(player, "TaskProgressChanged", newProgress, {
                    taskId = task.TaskId,
                    taskType = task.TaskType,
                    period = period,
                    delta = newProgress - oldProgress,
                    source = type(context) == "table" and context.source or "task",
                })
                if newProgress >= task.Target and periodState.CompletedReportedByTaskId[taskKey] ~= true then
                    periodState.CompletedReportedByTaskId[taskKey] = true
                    self:_trackTaskEvent(player, "TaskCompleted", 1, {
                        taskId = task.TaskId,
                        taskType = task.TaskType,
                        period = period,
                        source = type(context) == "table" and context.source or "task",
                    })
                end
            end
        end
    end

    if didChange then
        self:_markDirty(player)
        self:PushState(player)
    end
    return didChange
end

function TaskService:RecordOnlineSeconds(player, amount)
    return self:RecordProgress(player, TaskConfig.TaskType.OnlineSeconds, amount, { source = "online_time" })
end

function TaskService:RecordPlayerKill(player, amount)
    return self:RecordProgress(player, TaskConfig.TaskType.PlayerKills, amount, { source = "player_kill" })
end

function TaskService:RecordWheelSpin(player, amount)
    return self:RecordProgress(player, TaskConfig.TaskType.WheelSpinsUsed, amount, { source = "wheel" })
end

function TaskService:RecordDiamondsEarned(player, amount, context)
    local safeContext = type(context) == "table" and context or {}
    safeContext.source = safeContext.source or "diamonds"
    return self:RecordProgress(player, TaskConfig.TaskType.DiamondsEarned, amount, safeContext)
end

function TaskService:RecordInvitePromptOpened(player, amount)
    return self:RecordProgress(player, TaskConfig.TaskType.InviteFriend, amount or 1, { source = "invite_prompt" })
end

function TaskService:RecordLoginDay(player, nowTimestamp)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self:_isPlayerLoaded(player)) then
        return false
    end

    local taskState = self:_getPlayerTaskState(player)
    if not taskState then
        return false
    end

    local utcDay = TaskConfig.GetUtcDay(nowTimestamp or os.time())
    local dayKey = tostring(utcDay)
    local weeklyState = taskState.Weekly
    weeklyState.LoginDays = copyBooleanMap(weeklyState.LoginDays)
    if weeklyState.LoginDays[dayKey] == true then
        return false
    end

    weeklyState.LoginDays[dayKey] = true
    local loginDays = countMapEntries(weeklyState.LoginDays)
    local didChange = false
    for _, task in ipairs(TaskConfig.GetTasks(TaskConfig.Period.Weekly)) do
        if task.TaskType == TaskConfig.TaskType.LoginDays then
            local oldProgress = self:_getProgress(weeklyState, task.TaskId)
            local newProgress = math.min(task.Target, loginDays)
            if newProgress ~= oldProgress then
                self:_setProgress(weeklyState, task.TaskId, newProgress)
                didChange = true
                self:_trackTaskEvent(player, "TaskProgressChanged", newProgress, {
                    taskId = task.TaskId,
                    taskType = task.TaskType,
                    period = TaskConfig.Period.Weekly,
                    delta = newProgress - oldProgress,
                    source = "login_day",
                })
                if newProgress >= task.Target and weeklyState.CompletedReportedByTaskId[formatTaskKey(task.TaskId)] ~= true then
                    weeklyState.CompletedReportedByTaskId[formatTaskKey(task.TaskId)] = true
                    self:_trackTaskEvent(player, "TaskCompleted", 1, {
                        taskId = task.TaskId,
                        taskType = task.TaskType,
                        period = TaskConfig.Period.Weekly,
                        source = "login_day",
                    })
                end
            end
        end
    end

    if didChange then
        self:_markDirty(player)
        self:PushState(player)
    end
    return didChange
end

local function getTaskRewards(task)
    local result = {}
    if type(task) ~= "table" then
        return result
    end

    if type(task.Rewards) == "table" then
        for _, reward in ipairs(task.Rewards) do
            if type(reward) == "table" and tostring(reward.RewardType or "") ~= "" then
                table.insert(result, {
                    RewardType = tostring(reward.RewardType or ""),
                    PotionId = math.max(0, math.floor(tonumber(reward.PotionId) or 0)),
                    ChestId = math.max(0, math.floor(tonumber(reward.ChestId) or 0)),
                    Amount = math.max(1, math.floor(tonumber(reward.Amount) or 1)),
                    Icon = tostring(reward.Icon or ""),
                })
            end
        end
    end

    if #result <= 0 and tostring(task.RewardType or "") ~= "" then
        table.insert(result, {
            RewardType = tostring(task.RewardType or ""),
            PotionId = math.max(0, math.floor(tonumber(task.PotionId) or 0)),
            ChestId = math.max(0, math.floor(tonumber(task.ChestId) or 0)),
            Amount = math.max(1, math.floor(tonumber(task.Amount) or 1)),
            Icon = tostring(task.Icon or ""),
        })
    end

    return result
end

function TaskService:_canGrantSingleReward(reward)
    local rewardType = tostring(reward and reward.RewardType or "")
    if rewardType == "Diamonds" or rewardType == "WheelSpins" or rewardType == "Experience" then
        return self._playerStateService ~= nil
    elseif rewardType == "Potion" then
        return math.max(0, math.floor(tonumber(reward and reward.PotionId) or 0)) > 0
            and self._potionService ~= nil
            and self._potionService.AddPotion ~= nil
    elseif rewardType == "Chest" then
        return math.max(0, math.floor(tonumber(reward and reward.ChestId) or 0)) > 0
            and self._playerStateService ~= nil
            and self._playerStateService.AddChest ~= nil
    end
    return false
end

function TaskService:_grantSingleReward(player, task, reward, rewardIndex)
    local rewardType = tostring(reward and reward.RewardType or "")
    local amount = math.max(1, math.floor(tonumber(reward and reward.Amount) or 1))
    local context = {
        source = "task",
        productGroup = "Task",
        itemSku = "Task_" .. tostring(task.TaskId) .. "_" .. tostring(math.max(1, math.floor(tonumber(rewardIndex) or 1))),
    }

    if rewardType == "Diamonds" then
        self._playerStateService:AddDiamonds(player, amount, context)
        return true
    elseif rewardType == "WheelSpins" then
        self._playerStateService:AddWheelSpins(player, amount, context)
        return true
    elseif rewardType == "Experience" then
        self._playerStateService:AddAuthorizedExperience(player, amount)
        return true
    elseif rewardType == "Potion" then
        if not (self._potionService and self._potionService.AddPotion) then
            return false, "PotionServiceUnavailable"
        end
        return self._potionService:AddPotion(player, reward.PotionId, amount, "Task")
    elseif rewardType == "Chest" then
        if not (self._playerStateService and self._playerStateService.AddChest) then
            return false, "ChestServiceUnavailable"
        end
        return self._playerStateService:AddChest(player, reward.ChestId, amount, context)
    end

    return false, "UnknownRewardType"
end

function TaskService:_grantReward(player, task)
    local rewards = getTaskRewards(task)
    if #rewards <= 0 then
        return false, "NoReward"
    end

    for _, reward in ipairs(rewards) do
        if not self:_canGrantSingleReward(reward) then
            return false, "UnknownRewardType"
        end
    end

    for index, reward in ipairs(rewards) do
        local granted, reason = self:_grantSingleReward(player, task, reward, index)
        if granted ~= true then
            return false, reason or "GrantFailed"
        end
    end

    return true
end

function TaskService:_fireRewardFeedback(player, task)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent and type(task) == "table") then
        return
    end

    local rewards = getTaskRewards(task)
    if #rewards <= 0 then
        return
    end

    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardGranted",
        source = "Task",
        reason = "TaskClaim",
        rewards = ShopConfig.CopyRewardsForClient(rewards),
        closeDelay = 0.8,
        timestamp = os.clock(),
    })
end

function TaskService:ClaimTask(player, taskId)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService and self:_isPlayerLoaded(player)) then
        return false, "DataLoading"
    end
    if not self:_canProcessRequest(player, "claim") then
        return false, "Debounced"
    end

    local task = TaskConfig.GetTask(taskId)
    if not task then
        self:PushState(player)
        return false, "InvalidTask"
    end

    local taskState = self:_getPlayerTaskState(player)
    local period = getPeriodForTask(task)
    local periodState = period == TaskConfig.Period.Weekly and taskState.Weekly or taskState.Daily
    local taskKey = formatTaskKey(task.TaskId)
    local claimLockKey = tostring(player.UserId) .. ":" .. tostring(period) .. ":" .. tostring(periodState.CycleKey or "") .. ":" .. taskKey
    if self._claimLocksByUserId[claimLockKey] == true then
        self:PushState(player)
        return false, "ClaimInProgress"
    end
    local progress = self:_getProgress(periodState, task.TaskId)
    if periodState.ClaimedByTaskId[taskKey] == true then
        self:PushState(player)
        return false, "AlreadyClaimed"
    end
    if progress < task.Target then
        self:PushState(player)
        return false, "NotComplete"
    end

    self._claimLocksByUserId[claimLockKey] = true
    periodState.ClaimedByTaskId[taskKey] = true
    self:_markDirty(player)
    self:PushState(player)

    local grantOk, granted, reason = pcall(function()
        return self:_grantReward(player, task)
    end)
    if grantOk ~= true then
        local grantError = granted
        granted = false
        reason = "GrantError"
        warn(string.format(
            "[TaskService] Failed to grant task reward taskId=%s player=%s error=%s",
            tostring(task.TaskId),
            tostring(player and player.Name or ""),
            tostring(grantError)
        ))
    end
    if granted ~= true then
        local rollbackState = self:_getPlayerTaskState(player)
        local rollbackPeriodState = rollbackState and (period == TaskConfig.Period.Weekly and rollbackState.Weekly or rollbackState.Daily)
        if rollbackPeriodState and rollbackPeriodState.ClaimedByTaskId then
            rollbackPeriodState.ClaimedByTaskId[taskKey] = nil
        end
        self._claimLocksByUserId[claimLockKey] = nil
        self:_markDirty(player)
        self:PushState(player)
        return false, reason or "GrantFailed"
    end

    local confirmedState = self:_getPlayerTaskState(player)
    local confirmedPeriodState = confirmedState and (period == TaskConfig.Period.Weekly and confirmedState.Weekly or confirmedState.Daily)
    if confirmedPeriodState and confirmedPeriodState.ClaimedByTaskId then
        confirmedPeriodState.ClaimedByTaskId[taskKey] = true
    end
    self:_markDirty(player)
    self._claimLocksByUserId[claimLockKey] = nil
    self:_trackTaskEvent(player, "TaskRewardClaimed", 1, {
        taskId = task.TaskId,
        taskType = task.TaskType,
        period = period,
        rewardType = task.RewardType,
        rewardAmount = task.Amount,
        rewardCount = #(task.Rewards or {}),
        source = "task",
    })
    self:PushState(player)
    self:_fireRewardFeedback(player, task)
    return true
end

function TaskService:AddTaskProgressForStudio(player, taskId, amount)
    if not (ActorUtils.IsPlayer(player) and self:_isPlayerLoaded(player)) then
        return false, "DataLoading"
    end
    local task = TaskConfig.GetTask(taskId)
    if not task then
        return false, "InvalidTask"
    end
    local taskState = self:_getPlayerTaskState(player)
    local period = getPeriodForTask(task)
    local periodState = period == TaskConfig.Period.Weekly and taskState.Weekly or taskState.Daily
    local oldProgress = self:_getProgress(periodState, task.TaskId)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    self:_setProgress(periodState, task.TaskId, math.min(task.Target, oldProgress + delta))
    self:_markDirty(player)
    self:PushState(player)
    return true, self:_getProgress(periodState, task.TaskId)
end

function TaskService:CompleteTaskForStudio(player, taskId)
    local task = TaskConfig.GetTask(taskId)
    if not task then
        return false, "InvalidTask"
    end
    local currentState = self:_getPeriodState(player, getPeriodForTask(task))
    if not currentState then
        return false, "InvalidPlayer"
    end
    self:_setProgress(currentState, task.TaskId, task.Target)
    self:_markDirty(player)
    self:PushState(player)
    return true, task.Target
end

function TaskService:ResetTasksForStudio(player, scope)
    if not ActorUtils.IsPlayer(player) then
        return false, "InvalidPlayer"
    end

    local taskState = self:_getPlayerTaskState(player)
    if not taskState then
        return false, "InvalidPlayer"
    end
    local normalizedScope = string.lower(tostring(scope or "all"))
    if normalizedScope == "daily" or normalizedScope == "all" then
        taskState.Daily.CycleKey = ""
    end
    if normalizedScope == "weekly" or normalizedScope == "week" or normalizedScope == "all" then
        taskState.Weekly.CycleKey = ""
    end
    local playerState = self._playerStateService:GetState(player)
    playerState.TaskState = self:NormalizeState(taskState, os.time())
    self:_markDirty(player)
    self:PushState(player)
    return true
end

function TaskService:_handleStateRequest(player)
    if not self:_canProcessRequest(player, "state") then
        return
    end
    if not self:_isPlayerLoaded(player) then
        return
    end
    self:PushState(player)
end

function TaskService:_handleInviteProgressRequest(player)
    if not self:_canProcessRequest(player, "invite") then
        return
    end
    if not self:_isPlayerLoaded(player) then
        return
    end
    self:RecordInvitePromptOpened(player, 1)
end

function TaskService:Init(dependencies)
    self._remoteEventService = dependencies and dependencies.RemoteEventService or self._remoteEventService
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
    self._taskStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("TaskStateSync") or nil
    self._requestStateSyncEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestTaskStateSync") or nil
    self._requestClaimEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestTaskClaim") or nil
    self._requestInviteTaskProgressEvent = self._remoteEventService and self._remoteEventService:GetEvent("RequestInviteTaskProgress") or nil
    self._shopRewardFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("ShopRewardFeedback") or nil

    disconnectAll(self._connections)
    self._lastRequestClockByUserId = {}
    self._claimLocksByUserId = {}

    if self._requestStateSyncEvent then
        table.insert(self._connections, self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            self:_handleStateRequest(player)
        end))
    end
    if self._requestClaimEvent then
        table.insert(self._connections, self._requestClaimEvent.OnServerEvent:Connect(function(player, payload)
            local taskId = type(payload) == "table" and (payload.taskId or payload.TaskId) or payload
            self:ClaimTask(player, taskId)
        end))
    end
    if self._requestInviteTaskProgressEvent then
        table.insert(self._connections, self._requestInviteTaskProgressEvent.OnServerEvent:Connect(function(player)
            self:_handleInviteProgressRequest(player)
        end))
    end
end

function TaskService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
end

function TaskService:OnPlayerAdded(player)
    task.spawn(function()
        local deadline = os.clock() + 15
        while player and player.Parent and not self:_isPlayerLoaded(player) and os.clock() < deadline do
            task.wait(0.25)
        end
        if not (player and player.Parent and self:_isPlayerLoaded(player)) then
            return
        end
        self:_getPlayerTaskState(player)
        self:RecordLoginDay(player)
        self:PushState(player)
    end)
end

function TaskService:OnPlayerRemoving(player)
    local userId = getUserId(player)
    if userId > 0 then
        local prefix = tostring(userId) .. ":"
        for requestKey in pairs(self._lastRequestClockByUserId) do
            if string.sub(tostring(requestKey), 1, #prefix) == prefix then
                self._lastRequestClockByUserId[requestKey] = nil
            end
        end
        for lockKey in pairs(self._claimLocksByUserId) do
            if string.sub(tostring(lockKey), 1, #prefix) == prefix then
                self._claimLocksByUserId[lockKey] = nil
            end
        end
    end
end

return TaskService
