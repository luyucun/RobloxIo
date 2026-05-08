--[[
脚本名字: ExperienceOrbService
脚本文件: ExperienceOrbService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/ExperienceOrbService
说明: 服务端只负责经验奖励结算和私有表现事件；经验块实例与吸附动画由击杀者客户端生成。
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
        "[ExperienceOrbService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local ExperienceOrbService = {}

ExperienceOrbService._playerStateService = nil
ExperienceOrbService._remoteEventService = nil
ExperienceOrbService._experienceFeedbackEvent = nil
ExperienceOrbService._nextDropId = 1

local function buildOrbVisuals(position, totalValue, orbCount)
    local count = math.max(1, math.floor(tonumber(orbCount) or 1))
    local valuePerOrb = math.max(1, math.floor((tonumber(totalValue) or count) / count))
    local visuals = {}

    for index = 1, count do
        local angle = (math.pi * 2) * ((index - 1) / count)
        local radius = 2 + (index % 3)
        local offset = Vector3.new(
            math.cos(angle) * radius,
            0,
            math.sin(angle) * radius
        )

        table.insert(visuals, {
            index = index,
            value = valuePerOrb,
            position = position + offset,
            offset = offset,
            homingDelaySeconds = GameConfig.EXPERIENCE.HomingDelaySeconds,
            homingSpeed = GameConfig.EXPERIENCE.HomingSpeed,
            homingConsumeRadius = GameConfig.EXPERIENCE.HomingConsumeRadius,
        })
    end

    return visuals, count, valuePerOrb
end

function ExperienceOrbService:_fireExperienceFeedback(actor, payload)
    if not (self._experienceFeedbackEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    self._experienceFeedbackEvent:FireClient(actor, payload)
end

function ExperienceOrbService:_grantExperience(actor, amount, options)
    if not (actor and self._playerStateService) then
        return nil, 0
    end

    if options and options.authorizedExperienceReward == true and self._playerStateService.AddAuthorizedExperience then
        self._playerStateService:AddAuthorizedExperience(actor, amount)
        return self._playerStateService:GetState(actor), amount
    end

    local state = self._playerStateService:GetState(actor)
    if not (state and state.Alive and state.IsInArena) then
        return nil, 0
    end
    self._playerStateService:AddExperience(actor, amount)
    return self._playerStateService:GetState(actor), amount
end

function ExperienceOrbService:_resolveAwardAmount(targetActor, totalValue, options)
    local baseAmount = math.max(0, math.floor(tonumber(totalValue) or 0))
    if baseAmount <= 0 then
        return 0
    end

    if options and options.applyExperienceMultiplier == true and targetActor and self._playerStateService then
        local multiplier = self._playerStateService:GetExperienceMultiplier(targetActor)
        return math.max(0, math.floor(baseAmount * multiplier))
    end

    return baseAmount
end

function ExperienceOrbService:DropExperience(position, totalValue, orbCount, targetActor, options)
    if typeof(position) ~= "Vector3" then
        return 0
    end

    local totalAmount = self:_resolveAwardAmount(targetActor, totalValue, options)
    local visuals, count, valuePerOrb = buildOrbVisuals(position, totalAmount, orbCount)
    if totalAmount <= 0 then
        return 0
    end

    local targetState, awardedAmount = self:_grantExperience(targetActor, totalAmount, options)
    if targetState and ActorUtils.IsPlayer(targetActor) then
        local dropId = tostring(self._nextDropId)
        self._nextDropId += 1

        self:_fireExperienceFeedback(targetActor, {
            eventType = "ExperienceDrop",
            dropId = dropId,
            amount = awardedAmount,
            orbCount = count,
            valuePerOrb = valuePerOrb,
            originPosition = position,
            orbs = visuals,
            level = targetState.Level,
            experience = targetState.Experience,
            nextLevelExperience = targetState.NextLevelExperience,
            timestamp = os.clock(),
        })
    end

    return count
end

function ExperienceOrbService:GrantCompressedExperience(position, totalValue, orbCount, targetActor, options)
    return self:DropExperience(position, totalValue, orbCount, targetActor, options)
end

function ExperienceOrbService:GrantNukeSweepExperience(position, totalValue, orbCount, targetActor, options)
    local resolvedOptions = {}
    for key, value in pairs(options or {}) do
        resolvedOptions[key] = value
    end
    resolvedOptions.authorizedExperienceReward = true
    return self:DropExperience(position, totalValue, orbCount, targetActor, resolvedOptions)
end

function ExperienceOrbService:GetNearestOrb()
    return nil, math.huge
end

function ExperienceOrbService:Init(dependencies)
    self._playerStateService = dependencies.PlayerStateService
    self._remoteEventService = dependencies.RemoteEventService
    self._experienceFeedbackEvent = self._remoteEventService and self._remoteEventService:GetEvent("ExperienceFeedback") or nil
    self._nextDropId = 1
end

return ExperienceOrbService
