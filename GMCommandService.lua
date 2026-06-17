--[[
脚本名字: GMCommandService
脚本文件: GMCommandService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/GMCommandService
说明: Studio-only GM 命令入口。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GMCommandService = {}

GMCommandService._specialEventService = nil
GMCommandService._remoteEventService = nil
GMCommandService._playerStateService = nil
GMCommandService._botService = nil
GMCommandService._healthService = nil
GMCommandService._revengeService = nil
GMCommandService._gameAnalyticsService = nil
GMCommandService._taskService = nil
GMCommandService._connections = {}

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
        "[GMCommandService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")
local GameConfig = requireSharedModule("GameConfig")
local TitleConfig = requireSharedModule("TitleConfig")
local AttributeConfig = requireSharedModule("AttributeConfig")

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function isAllowed(player)
    return RunService:IsStudio() and player ~= nil
end

local function parseEventCommand(message)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, argument = trimmed:match("^/(%S+)%s*(.*)$")
    if not command then
        return nil
    end

    command = string.lower(command)
    if command ~= "event" then
        return nil
    end

    local eventId = tonumber(argument:match("^(%d+)$") or "")
    if not eventId then
        return nil, "InvalidEventId"
    end

    return eventId
end

local function parseCommandName(message)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command = trimmed:match("^/(%S+)")
    return command and string.lower(command) or nil
end

local function parsePositiveAmountCommand(message, expectedCommandName)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, argument = trimmed:match("^/(%S+)%s*(.*)$")
    if not command or string.lower(command) ~= expectedCommandName then
        return nil
    end

    local amount = tonumber((argument or ""):match("^(%d+)$") or "")
    if not amount then
        return nil, "InvalidAmount"
    end

    amount = math.floor(amount)
    if amount <= 0 then
        return nil, "InvalidAmount"
    end

    return amount
end

local function parseTaskProgressCommand(message, expectedCommandName)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, taskIdText, amountText = trimmed:match("^/(%S+)%s+(%S+)%s+(%S+)%s*$")
    if not command or string.lower(command) ~= expectedCommandName then
        return nil
    end

    local taskId = math.floor(tonumber(taskIdText) or 0)
    local amount = math.floor(tonumber(amountText) or 0)
    if taskId <= 0 then
        return nil, "InvalidTaskId"
    end
    if amount <= 0 then
        return nil, "InvalidAmount"
    end
    return taskId, amount
end

local function parseTaskIdCommand(message, expectedCommandName)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, taskIdText = trimmed:match("^/(%S+)%s+(%S+)%s*$")
    if not command or string.lower(command) ~= expectedCommandName then
        return nil
    end

    local taskId = math.floor(tonumber(taskIdText) or 0)
    if taskId <= 0 then
        return nil, "InvalidTaskId"
    end
    return taskId
end

local function parseTaskResetCommand(message)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, scope = trimmed:match("^/(%S+)%s+(%S+)%s*$")
    if not command or string.lower(command) ~= "taskreset" then
        return nil
    end

    scope = string.lower(tostring(scope or ""))
    if scope ~= "daily" and scope ~= "weekly" and scope ~= "all" then
        return nil, "InvalidScope"
    end
    return scope
end

local function parseAttributeCapAmountCommand(message, expectedCommandName)
    local text = tostring(message or "")
    local trimmed = text:match("^%s*(.-)%s*$")
    local command, attributeId, amountText = trimmed:match("^/(%S+)%s+(%S+)%s+(%S+)%s*$")
    if not command or string.lower(command) ~= expectedCommandName then
        return nil
    end

    local attributeKey = AttributeConfig.NormalizeKey(attributeId)
    if not attributeKey then
        return nil, "InvalidAttribute"
    end

    local amount = tonumber(amountText)
    if not amount then
        return nil, "InvalidAmount"
    end

    amount = math.floor(amount)
    return attributeKey, amount
end

local function normalizeFriendInfo(friendInfo)
    if type(friendInfo) ~= "table" then
        return nil
    end

    local userId = math.floor(tonumber(friendInfo.Id or friendInfo.UserId or friendInfo.userId or friendInfo.VisitorId) or 0)
    if userId <= 0 then
        return nil
    end

    return {
        userId = userId,
        name = tostring(friendInfo.DisplayName or friendInfo.Username or friendInfo.Name or ("Friend " .. tostring(userId))),
    }
end

local function collectFriendsForStudioInviteTest(userId, maxCount)
    local normalizedUserId = math.floor(tonumber(userId) or 0)
    if normalizedUserId <= 0 then
        return nil, "InvalidUserId"
    end

    local success, pagesOrError = pcall(function()
        return Players:GetFriendsAsync(normalizedUserId)
    end)
    if not success or not pagesOrError then
        return nil, pagesOrError or "GetFriendsFailed"
    end

    local pages = pagesOrError
    local friends = {}
    local limit = math.max(1, math.floor(tonumber(maxCount) or 200))

    while #friends < limit do
        local pageSuccess, currentPageOrError = pcall(function()
            return pages:GetCurrentPage()
        end)
        if not pageSuccess then
            return #friends > 0 and friends or nil, currentPageOrError or "GetCurrentPageFailed"
        end

        for _, friendInfo in ipairs(currentPageOrError or {}) do
            local friend = normalizeFriendInfo(friendInfo)
            if friend then
                table.insert(friends, friend)
                if #friends >= limit then
                    break
                end
            end
        end

        if pages.IsFinished or #friends >= limit then
            break
        end

        local advanceSuccess, advanceError = pcall(function()
            pages:AdvanceToNextPageAsync()
        end)
        if not advanceSuccess then
            return #friends > 0 and friends or nil, advanceError or "AdvancePageFailed"
        end
    end

    return friends
end

local function markStateDirty(playerStateService, player)
    local rebirthService = playerStateService and playerStateService._rebirthService
    if rebirthService and rebirthService.MarkDirty then
        rebirthService:MarkDirty(player)
    end
end

local function syncSkinState(playerStateService, player)
    local skinService = playerStateService and playerStateService._skinService
    if skinService and skinService.SyncState then
        skinService:SyncState(player)
    elseif playerStateService and playerStateService.PushState then
        playerStateService:PushState(player)
    end
end

local function addDiamondsForPlayer(playerStateService, player, amount)
    if playerStateService.AddDiamonds then
        return playerStateService:AddDiamonds(player, amount, {
            source = "gm",
            productGroup = "GM_StudioOnly",
            itemSku = "GM_StudioOnly",
        })
    end
    if not playerStateService.GetState then
        return nil
    end

    local state = playerStateService:GetState(player)
    local delta = math.floor(tonumber(amount) or 0)
    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0) + delta)
    if playerStateService.PushState then
        playerStateService:PushState(player)
    end
    markStateDirty(playerStateService, player)
    return state.Diamonds
end

local function addKillsForPlayer(playerStateService, player, amount)
    if playerStateService.AddKillCount then
        playerStateService:AddKillCount(player, amount)
    elseif playerStateService.GetState then
        local state = playerStateService:GetState(player)
        local delta = math.max(0, math.floor(tonumber(amount) or 0))
        state.KillCount = math.max(0, math.floor(tonumber(state.KillCount) or 0)) + delta
        state.TotalPlayerKills = math.max(0, math.floor(tonumber(state.TotalPlayerKills) or 0)) + delta
    end

    if playerStateService.PushState then
        playerStateService:PushState(player)
    end

    if not playerStateService.GetState then
        return 0, 0
    end
    local state = playerStateService:GetState(player)
    return math.max(0, math.floor(tonumber(state.KillCount) or 0)), math.max(0, math.floor(tonumber(state.TotalPlayerKills) or 0))
end

local function buildTitleListText()
    local parts = {}
    for _, title in ipairs(TitleConfig.GetAllTitles()) do
        table.insert(parts, string.format("%d:%s", math.floor(tonumber(title.Id) or 0), tostring(title.Name or "")))
    end
    return table.concat(parts, ", ")
end

function GMCommandService:_runStudioInviteTipsTest(player)
    local syncEvent = self._remoteEventService and self._remoteEventService:GetEvent("FriendsRankingStateSync")
    if not syncEvent then
        warn("[GMCommandService] FriendsRankingStateSync event is unavailable")
        return false, "ServiceUnavailable"
    end

    local friends, errorCode = collectFriendsForStudioInviteTest(player and player.UserId, 200)
    if not friends or #friends <= 0 then
        warn(string.format("[GMCommandService] Could not find friends for /testinvite from %s: %s", player and player.Name or "nil", tostring(errorCode or "NoFriends")))
        return false, errorCode or "NoFriends"
    end

    local random = Random.new()
    local friend = friends[random:NextInteger(1, #friends)]
    local highestLevelReached = random:NextInteger(5, 250)

    syncEvent:FireClient(player, {
        studioInviteTipsTest = true,
        source = "GM_StudioOnly",
        rows = {
            {
                userId = friend.userId,
                name = friend.name,
                highestLevelReached = highestLevelReached,
                totalPlayerKills = random:NextInteger(0, 5000),
                playtimeSeconds = random:NextInteger(600, 360000),
            },
        },
        timestamp = os.clock(),
    })

    print(string.format(
        "[GMCommandService] %s triggered /testinvite with %s (%d), highestLevelReached=%d",
        player.Name,
        friend.name,
        friend.userId,
        highestLevelReached
    ))
    return true, friend
end

function GMCommandService:_handleChatCommand(player, message)
    if not isAllowed(player) then
        return false, "StudioOnly"
    end

    local commandName = parseCommandName(message)
    if commandName == "diamond" or commandName == "addgems" or commandName == "kill" then
        if not self._playerStateService then
            warn("[GMCommandService] PlayerStateService is unavailable")
            return false, "ServiceUnavailable"
        end

        local amount, errorCode = parsePositiveAmountCommand(message, commandName)
        if not amount then
            warn(string.format("[GMCommandService] Invalid /%s command from %s: %s", commandName, player.Name, tostring(message)))
            return false, errorCode or "InvalidAmount"
        end

        if commandName == "diamond" or commandName == "addgems" then
            local totalDiamonds = addDiamondsForPlayer(self._playerStateService, player, amount)
            if not totalDiamonds then
                warn("[GMCommandService] PlayerStateService cannot add diamonds")
                return false, "ServiceUnavailable"
            end
            print(string.format("[GMCommandService] %s added %d diamonds, total=%d", player.Name, amount, totalDiamonds))
            return true, totalDiamonds
        end

        local killCount, totalPlayerKills = addKillsForPlayer(self._playerStateService, player, amount)
        print(string.format("[GMCommandService] %s added %d kills, round=%d, total=%d", player.Name, amount, killCount, totalPlayerKills))
        return true, totalPlayerKills
    end

    if commandName == "setcap" or commandName == "addcap" or commandName == "setcaps" or commandName == "setallcaps" or commandName == "allcaps" or commandName == "resetcaps" or commandName == "maxcaps" then
        if not self._playerStateService then
            warn("[GMCommandService] PlayerStateService is unavailable")
            return false, "ServiceUnavailable"
        end

        if commandName == "setcap" then
            local attributeKey, amountOrError = parseAttributeCapAmountCommand(message, commandName)
            if not attributeKey then
                warn(string.format("[GMCommandService] Invalid /setcap command from %s: %s", player.Name, tostring(message)))
                return false, amountOrError or "InvalidAttribute"
            end

            local success, result, _, newCap = self._playerStateService:SetAttributeCap(player, attributeKey, amountOrError, {
                source = "gm",
            })
            print(string.format("[GMCommandService] %s set cap %s to %d: success=%s, result=%s", player.Name, attributeKey, math.floor(tonumber(newCap) or amountOrError), tostring(success), tostring(result)))
            return success == true, newCap
        end

        if commandName == "addcap" then
            local attributeKey, amountOrError = parseAttributeCapAmountCommand(message, commandName)
            if not attributeKey then
                warn(string.format("[GMCommandService] Invalid /addcap command from %s: %s", player.Name, tostring(message)))
                return false, amountOrError or "InvalidAttribute"
            end
            if amountOrError <= 0 then
                warn(string.format("[GMCommandService] Invalid /addcap amount from %s: %s", player.Name, tostring(message)))
                return false, "InvalidAmount"
            end

            local success, result, _, newCap = self._playerStateService:AddAttributeCap(player, attributeKey, amountOrError, {
                source = "gm",
            })
            print(string.format("[GMCommandService] %s added cap %s by %d: success=%s, result=%s, cap=%d", player.Name, attributeKey, amountOrError, tostring(success), tostring(result), math.floor(tonumber(newCap) or 0)))
            return success == true, newCap
        end

        if commandName == "setcaps" or commandName == "setallcaps" or commandName == "allcaps" then
            if not self._playerStateService.SetAllAttributeCaps then
                warn("[GMCommandService] PlayerStateService cannot set all attribute caps")
                return false, "ServiceUnavailable"
            end

            local amount, errorCode = parsePositiveAmountCommand(message, commandName)
            if not amount then
                warn(string.format("[GMCommandService] Invalid /%s command from %s: %s", commandName, player.Name, tostring(message)))
                return false, errorCode or "InvalidAmount"
            end

            local success, result, _, caps = self._playerStateService:SetAllAttributeCaps(player, amount, {
                source = "gm",
            })
            print(string.format("[GMCommandService] %s set all attribute caps to %d: success=%s, result=%s", player.Name, amount, tostring(success), tostring(result)))
            return success == true, caps
        end

        if commandName == "resetcaps" then
            local caps = self._playerStateService:ResetAttributeCaps(player)
            print(string.format("[GMCommandService] %s reset all attribute caps", player.Name))
            return true, caps
        end

        if commandName == "maxcaps" then
            local caps = self._playerStateService:MaxAttributeCaps(player)
            print(string.format("[GMCommandService] %s maxed all attribute caps", player.Name))
            return true, caps
        end
    end

    if commandName == "ai" then
        if not self._botService then
            warn("[GMCommandService] BotService is unavailable")
            return false, "ServiceUnavailable"
        end

        local amount, errorCode = parsePositiveAmountCommand(message, commandName)
        if not amount then
            warn(string.format("[GMCommandService] Invalid /AI command from %s: %s", player.Name, tostring(message)))
            return false, errorCode or "InvalidAmount"
        end

        local spawned = self._botService:SpawnBots(amount)
        print(string.format("[GMCommandService] %s spawned %d AI bot(s), requested=%d", player.Name, spawned, amount))
        return true, spawned
    end

    if commandName == "level" then
        if not (self._playerStateService and self._playerStateService.SetLevelForStudioCommand) then
            warn("[GMCommandService] PlayerStateService cannot set level")
            return false, "ServiceUnavailable"
        end

        local amount, errorCode = parsePositiveAmountCommand(message, commandName)
        if not amount then
            warn(string.format("[GMCommandService] Invalid /level command from %s: %s", player.Name, tostring(message)))
            return false, errorCode or "InvalidAmount"
        end

        local level, experience = self._playerStateService:SetLevelForStudioCommand(player, amount)
        print(string.format("[GMCommandService] %s set own level to %d, experience=%d", player.Name, level, experience))
        return true, level
    end

    if commandName == "titlelist" then
        print(string.format("[GMCommandService] Available titles: %s", buildTitleListText()))
        return true
    end

    if commandName == "titlecheck" then
        if not (self._playerStateService and self._playerStateService.CheckTitleUnlocks) then
            warn("[GMCommandService] PlayerStateService cannot check title unlocks")
            return false, "ServiceUnavailable"
        end

        local unlockedTitles = self._playerStateService:CheckTitleUnlocks(player)
        syncSkinState(self._playerStateService, player)
        print(string.format("[GMCommandService] %s checked title unlocks, newlyUnlocked=%d", player.Name, #unlockedTitles))
        return true, #unlockedTitles
    end

    if commandName == "titleclear" then
        if not (self._playerStateService and self._playerStateService.ClearEquippedTitle) then
            warn("[GMCommandService] PlayerStateService cannot clear title")
            return false, "ServiceUnavailable"
        end

        local success, result = self._playerStateService:ClearEquippedTitle(player)
        syncSkinState(self._playerStateService, player)
        print(string.format("[GMCommandService] %s cleared equipped title: success=%s, result=%s", player.Name, tostring(success), tostring(result)))
        return success == true, result
    end

    if commandName == "titleall" then
        if not (self._playerStateService and self._playerStateService.GrantTitle) then
            warn("[GMCommandService] PlayerStateService cannot grant titles")
            return false, "ServiceUnavailable"
        end

        local grantedCount = 0
        for _, title in ipairs(TitleConfig.GetAllTitles()) do
            if not self._playerStateService:OwnsTitle(player, title.Id) then
                local success = self._playerStateService:GrantTitle(player, title.Id, {
                    silentFeedback = true,
                    silentRedPoint = true,
                })
                if success then
                    grantedCount += 1
                end
            end
        end
        syncSkinState(self._playerStateService, player)
        print(string.format("[GMCommandService] %s granted all titles, newlyGranted=%d", player.Name, grantedCount))
        return true, grantedCount
    end

    if commandName == "titlegrant" or commandName == "titleequip" then
        if not (self._playerStateService and self._playerStateService.GrantTitle and self._playerStateService.EquipTitle) then
            warn("[GMCommandService] PlayerStateService cannot grant/equip title")
            return false, "ServiceUnavailable"
        end

        local titleId, errorCode = parsePositiveAmountCommand(message, commandName)
        if not titleId then
            warn(string.format("[GMCommandService] Invalid /%s command from %s: %s", commandName, player.Name, tostring(message)))
            return false, errorCode or "InvalidTitleId"
        end

        local title = TitleConfig.GetTitle(titleId)
        if not title then
            warn(string.format("[GMCommandService] Invalid title id %d from %s", titleId, player.Name))
            return false, "InvalidTitle"
        end

        if commandName == "titlegrant" then
            local success, result = self._playerStateService:GrantTitle(player, title.Id)
            syncSkinState(self._playerStateService, player)
            print(string.format("[GMCommandService] %s granted title %d (%s): success=%s, result=%s", player.Name, title.Id, tostring(title.Name or ""), tostring(success), tostring(result)))
            return success == true, result
        end

        if not self._playerStateService:OwnsTitle(player, title.Id) then
            self._playerStateService:GrantTitle(player, title.Id, {
                silentFeedback = true,
                silentRedPoint = true,
            })
        end
        local success, result = self._playerStateService:EquipTitle(player, title.Id)
        syncSkinState(self._playerStateService, player)
        print(string.format("[GMCommandService] %s equipped title %d (%s): success=%s, result=%s", player.Name, title.Id, tostring(title.Name or ""), tostring(success), tostring(result)))
        return success == true, result
    end

    if commandName == "shield" then
        if not (self._healthService and self._healthService.GrantShield) then
            warn("[GMCommandService] HealthService is unavailable")
            return false, "ServiceUnavailable"
        end

        local amount, errorCode = parsePositiveAmountCommand(message, commandName)
        if not amount then
            warn(string.format("[GMCommandService] Invalid /shield command from %s: %s", player.Name, tostring(message)))
            return false, errorCode or "InvalidAmount"
        end

        local baseDuration = math.max(1, tonumber(GameConfig.SHIELD and GameConfig.SHIELD.DurationSeconds) or 30)
        local duration = baseDuration * amount
        local success, result, expiresAt = self._healthService:GrantShield(player, duration, "GMCommand")
        if not success then
            warn(string.format("[GMCommandService] Failed to grant shield to %s: %s", player.Name, tostring(result)))
            return false, result
        end

        print(string.format("[GMCommandService] %s granted shield x%d, duration=%ds, expiresAt=%.2f", player.Name, amount, duration, tonumber(expiresAt) or 0))
        return true, expiresAt
    end

    if commandName == "groupjoin" then
        local promptEvent = self._remoteEventService and self._remoteEventService:GetEvent("PromptGroupJoin")
        if not promptEvent then
            warn("[GMCommandService] PromptGroupJoin event is unavailable")
            return false, "ServiceUnavailable"
        end

        promptEvent:FireClient(player, {
            eventType = "Prompt",
            source = "GM",
            timestamp = os.clock(),
        })
        print(string.format("[GMCommandService] %s prompted group join dialog", player.Name))
        return true
    end

    if commandName == "testdefeated" or commandName == "defeated" then
        if not (self._healthService and self._healthService.RunStudioDefeatedTest) then
            warn("[GMCommandService] HealthService cannot run defeated test")
            return false, "ServiceUnavailable"
        end

        local success, result, killer = self._healthService:RunStudioDefeatedTest(player)
        if success then
            local killerName = killer and killer.Name or "GM Test Killer"
            print(string.format("[GMCommandService] %s triggered defeated test, mode=%s, killer=%s", player.Name, tostring(result), tostring(killerName)))
            return true, result
        end

        warn(string.format("[GMCommandService] Failed to run defeated test for %s: %s", player.Name, tostring(result)))
        return false, result
    end

    if commandName == "testkillinfo" then
        local killInfoEvent = self._remoteEventService and self._remoteEventService:GetEvent("KillInfoFeedback")
        if not killInfoEvent then
            warn("[GMCommandService] KillInfoFeedback event is unavailable")
            return false, "ServiceUnavailable"
        end

        killInfoEvent:FireAllClients({
            eventType = "PlayerKilled",
            killerUserId = 0,
            killerName = "player01",
            victimUserId = 0,
            victimName = "player02",
            timestamp = os.clock(),
        })
        print(string.format("[GMCommandService] %s broadcast test kill info", player.Name))
        return true
    end

    if commandName == "testrevenge" then
        if not (self._revengeService and self._revengeService.RunStudioTest) then
            warn("[GMCommandService] RevengeService is unavailable")
            return false, "ServiceUnavailable"
        end

        local success, result = self._revengeService:RunStudioTest(player)
        if success then
            print(string.format("[GMCommandService] %s started test revenge cinematic", player.Name))
            return true, result
        end

        warn(string.format("[GMCommandService] Failed to start /testrevenge for %s: %s", player.Name, tostring(result)))
        return false, result
    end

    if commandName == "testinvite" or commandName == "invitetips" then
        return self:_runStudioInviteTipsTest(player)
    end

    if commandName == "taskprogress" then
        if not (self._taskService and self._taskService.AddTaskProgressForStudio) then
            warn("[GMCommandService] TaskService is unavailable")
            return false, "ServiceUnavailable"
        end

        local taskId, amountOrError = parseTaskProgressCommand(message, commandName)
        if not taskId then
            warn(string.format("[GMCommandService] Invalid /taskprogress command from %s: %s", player.Name, tostring(message)))
            return false, amountOrError or "InvalidTaskProgress"
        end

        local success, result = self._taskService:AddTaskProgressForStudio(player, taskId, amountOrError)
        print(string.format("[GMCommandService] %s added task progress taskId=%d amount=%d: success=%s, result=%s", player.Name, taskId, amountOrError, tostring(success), tostring(result)))
        return success == true, result
    end

    if commandName == "taskcomplete" then
        if not (self._taskService and self._taskService.CompleteTaskForStudio) then
            warn("[GMCommandService] TaskService is unavailable")
            return false, "ServiceUnavailable"
        end

        local taskId, errorCode = parseTaskIdCommand(message, commandName)
        if not taskId then
            warn(string.format("[GMCommandService] Invalid /taskcomplete command from %s: %s", player.Name, tostring(message)))
            return false, errorCode or "InvalidTaskId"
        end

        local success, result = self._taskService:CompleteTaskForStudio(player, taskId)
        print(string.format("[GMCommandService] %s completed task taskId=%d: success=%s, result=%s", player.Name, taskId, tostring(success), tostring(result)))
        return success == true, result
    end

    if commandName == "taskreset" then
        if not (self._taskService and self._taskService.ResetTasksForStudio) then
            warn("[GMCommandService] TaskService is unavailable")
            return false, "ServiceUnavailable"
        end

        local scope, errorCode = parseTaskResetCommand(message)
        if not scope then
            warn(string.format("[GMCommandService] Invalid /taskreset command from %s: %s", player.Name, tostring(message)))
            return false, errorCode or "InvalidScope"
        end

        local success, result = self._taskService:ResetTasksForStudio(player, scope)
        print(string.format("[GMCommandService] %s reset tasks scope=%s: success=%s, result=%s", player.Name, scope, tostring(success), tostring(result)))
        return success == true, result
    end

    local eventId, errorCode = parseEventCommand(message)
    if not eventId then
        if errorCode == "InvalidEventId" then
            warn(string.format("[GMCommandService] Invalid /event command from %s: %s", player.Name, tostring(message)))
        end
        return false, errorCode or "Ignored"
    end

    if not self._specialEventService then
        warn("[GMCommandService] SpecialEventService is unavailable")
        return false, "ServiceUnavailable"
    end

    local success, result = self._specialEventService:StartEventById(eventId)
    if success then
        print(string.format("[GMCommandService] %s started special event %d", player.Name, eventId))
        return true, result
    end

    warn(string.format("[GMCommandService] Failed to start special event %d: %s", eventId, tostring(result)))
    return false, result
end

function GMCommandService:Init(dependencies)
    self._specialEventService = dependencies and dependencies.SpecialEventService or self._specialEventService
    self._remoteEventService = dependencies and dependencies.RemoteEventService or self._remoteEventService
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._botService = dependencies and dependencies.BotService or self._botService
    self._healthService = dependencies and dependencies.HealthService or self._healthService
    self._revengeService = dependencies and dependencies.RevengeService or self._revengeService
    self._gameAnalyticsService = dependencies and dependencies.GameAnalyticsService or self._gameAnalyticsService
    self._taskService = dependencies and dependencies.TaskService or self._taskService

    disconnectAll(self._connections)

    for _, player in ipairs(Players:GetPlayers()) do
        if player and player.Chatted then
            table.insert(self._connections, player.Chatted:Connect(function(message)
                self:_handleChatCommand(player, message)
            end))
        end
    end

    table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
        table.insert(self._connections, player.Chatted:Connect(function(message)
            self:_handleChatCommand(player, message)
        end))
    end))
end

return GMCommandService
