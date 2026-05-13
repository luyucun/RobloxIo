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

local function markStateDirty(playerStateService, player)
    local rebirthService = playerStateService and playerStateService._rebirthService
    if rebirthService and rebirthService.MarkDirty then
        rebirthService:MarkDirty(player)
    end
end

local function addDiamondsForPlayer(playerStateService, player, amount)
    if playerStateService.AddDiamonds then
        return playerStateService:AddDiamonds(player, amount)
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

function GMCommandService:_handleChatCommand(player, message)
    if not isAllowed(player) then
        return false, "StudioOnly"
    end

    local commandName = parseCommandName(message)
    if commandName == "diamond" or commandName == "kill" then
        if not self._playerStateService then
            warn("[GMCommandService] PlayerStateService is unavailable")
            return false, "ServiceUnavailable"
        end

        local amount, errorCode = parsePositiveAmountCommand(message, commandName)
        if not amount then
            warn(string.format("[GMCommandService] Invalid /%s command from %s: %s", commandName, player.Name, tostring(message)))
            return false, errorCode or "InvalidAmount"
        end

        if commandName == "diamond" then
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
