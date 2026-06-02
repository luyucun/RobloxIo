--[[
脚本名字: CodeService
脚本文件: CodeService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/CodeService
说明: 兑换码校验、限时/限量、单玩家领取记录与奖励发放。
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
        "[CodeService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local CodeConfig = requireSharedModule("CodeConfig")
local ShopConfig = requireSharedModule("ShopConfig")

local CodeService = {}

CodeService._playerStateService = nil
CodeService._rebirthService = nil
CodeService._potionService = nil
CodeService._requestCodeRedeemEvent = nil
CodeService._codeRedeemFeedbackEvent = nil
CodeService._shopRewardFeedbackEvent = nil
CodeService._requestConnection = nil
CodeService._codeMap = {}
CodeService._useCountsByCodeKey = {}
CodeService._redeemInProgressByUserId = {}
CodeService._useCountStore = nil

local CODE_USE_COUNT_STORE_NAME = "IO_CodeUseCounts_v1"

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

local function getUserId(player)
    return player and player.UserId or 0
end

local function getCodeKey(entry)
    if type(entry) ~= "table" then
        return ""
    end
    local codeId = math.floor(tonumber(entry.CodeId) or 0)
    if codeId > 0 then
        return tostring(codeId)
    end
    return CodeConfig.NormalizeCodeText(entry.CodeText)
end

local function isTimedCode(entry)
    local codeType = tostring(entry and entry.CodeType or "")
    return codeType == "Timed" or codeType == "时间型" or codeType == "限时" or codeType == "Time"
end

local function isLimitedCode(entry)
    local codeType = tostring(entry and entry.CodeType or "")
    return codeType == "Limited" or codeType == "次数型" or codeType == "限次" or codeType == "UseLimit"
end

function CodeService:_warnInvalidAuthorConfig(entry, message)
    warn(string.format(
        "[CodeService] 兑换码配置警告 code=%s id=%s: %s",
        tostring(entry and entry.CodeText or ""),
        tostring(entry and entry.CodeId or ""),
        tostring(message or "")
    ))
end

function CodeService:_prepareCodes()
    self._codeMap = CodeConfig.GetDefaultCodeMap()
    for _, entry in pairs(self._codeMap) do
        if isTimedCode(entry) and (tonumber(entry.ExpireAt) or 0) <= 0 then
            self:_warnInvalidAuthorConfig(entry, "限时兑换码缺少失效时间")
        end
        if isLimitedCode(entry) and (tonumber(entry.MaxUses) or 0) <= 0 then
            self:_warnInvalidAuthorConfig(entry, "限次兑换码缺少使用人数上限")
        end
        if CodeConfig.ValidateCodeEntry then
            for _, warningMessage in ipairs(CodeConfig.ValidateCodeEntry(entry)) do
                self:_warnInvalidAuthorConfig(entry, warningMessage)
            end
        end
    end
end

function CodeService:_canWriteUseCountStore()
    if not self._useCountStore then
        return false
    end
    if RunService:IsStudio() and not (GameConfig.DATASTORE and GameConfig.DATASTORE.StudioPersistenceEnabled == true) then
        return false
    end
    return true
end

function CodeService:_getUseCountStore()
    if self._useCountStore ~= nil then
        return self._useCountStore
    end

    local storeName = CODE_USE_COUNT_STORE_NAME
    if GameConfig.GetEnvironmentDataStoreName then
        storeName = GameConfig.GetEnvironmentDataStoreName(CODE_USE_COUNT_STORE_NAME, RunService:IsStudio())
    end

    local ok, storeOrError = pcall(function()
        return DataStoreService:GetDataStore(storeName)
    end)
    if not ok then
        warn("[CodeService] 获取兑换码使用次数 DataStore 失败: " .. tostring(storeOrError))
        self._useCountStore = false
        return nil
    end

    self._useCountStore = storeOrError
    return self._useCountStore
end

function CodeService:_getUseCount(codeKey)
    local key = tostring(codeKey or "")
    if key == "" then
        return 0
    end
    if self._useCountsByCodeKey[key] ~= nil then
        return math.max(0, math.floor(tonumber(self._useCountsByCodeKey[key]) or 0))
    end

    local store = self:_getUseCountStore()
    if not store or not self:_canWriteUseCountStore() then
        self._useCountsByCodeKey[key] = 0
        return 0
    end

    local ok, value = pcall(function()
        return store:GetAsync(key)
    end)
    if not ok then
        warn("[CodeService] 读取兑换码使用次数失败 key=" .. key .. " err=" .. tostring(value))
        self._useCountsByCodeKey[key] = 0
        return 0
    end

    local count = math.max(0, math.floor(tonumber(value) or 0))
    self._useCountsByCodeKey[key] = count
    return count
end

function CodeService:_incrementUseCount(codeKey, maxUses)
    local key = tostring(codeKey or "")
    if key == "" then
        return false, "InvalidCode"
    end

    local resolvedMaxUses = math.floor(tonumber(maxUses) or 0)
    local store = self:_getUseCountStore()
    if store and self:_canWriteUseCountStore() then
        local incremented = false
        local ok, newValueOrError = pcall(function()
            return store:UpdateAsync(key, function(oldValue)
                local current = math.max(0, math.floor(tonumber(oldValue) or 0))
                if resolvedMaxUses > 0 and current >= resolvedMaxUses then
                    return current
                end
                incremented = true
                return current + 1
            end)
        end)
        if not ok then
            warn("[CodeService] 更新兑换码使用次数失败 key=" .. key .. " err=" .. tostring(newValueOrError))
            return false, "UseCountUpdateFailed"
        end

        local newValue = math.max(0, math.floor(tonumber(newValueOrError) or 0))
        self._useCountsByCodeKey[key] = newValue
        if not incremented then
            return false, "UseLimitReached"
        end
        return true, "Counted"
    end

    local current = self:_getUseCount(key)
    if resolvedMaxUses > 0 and current >= resolvedMaxUses then
        return false, "UseLimitReached"
    end
    self._useCountsByCodeKey[key] = current + 1
    return true, "Counted"
end

function CodeService:_decrementUseCount(codeKey)
    local key = tostring(codeKey or "")
    if key == "" then
        return
    end

    local store = self:_getUseCountStore()
    if store and self:_canWriteUseCountStore() then
        pcall(function()
            store:UpdateAsync(key, function(oldValue)
                return math.max(0, math.floor(tonumber(oldValue) or 0) - 1)
            end)
        end)
    end

    self._useCountsByCodeKey[key] = math.max(0, math.floor(tonumber(self._useCountsByCodeKey[key]) or 0) - 1)
end

function CodeService:_fireFeedback(player, success, message)
    if not (self._codeRedeemFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._codeRedeemFeedbackEvent:FireClient(player, {
        success = success == true,
        message = tostring(message or CodeConfig.WarningMessage),
        timestamp = os.clock(),
    })
end

function CodeService:_fireRewardFeedback(player, entry, rewards)
    if not (self._shopRewardFeedbackEvent and ActorUtils.IsPlayer(player) and player.Parent) then
        return
    end

    self._shopRewardFeedbackEvent:FireClient(player, {
        eventType = "RewardGranted",
        source = "Code",
        reason = "RedeemCode",
        codeId = entry and entry.CodeId,
        codeText = entry and entry.CodeText,
        rewards = ShopConfig.CopyRewardsForClient(rewards),
        timestamp = os.clock(),
    })
end

function CodeService:_isPlayerLoaded(player)
    return not self._rebirthService or not self._rebirthService.IsPlayerLoaded or self._rebirthService:IsPlayerLoaded(player)
end

function CodeService:_isEntryUsableByTime(entry)
    local expireAt = math.floor(tonumber(entry and entry.ExpireAt) or 0)
    if expireAt <= 0 then
        return not isTimedCode(entry)
    end
    return os.time() <= expireAt
end

function CodeService:_grantRewards(player, entry)
    local grantedRewards = {}
    for _, reward in ipairs(entry.Rewards or {}) do
        local rewardType = tostring(reward.RewardType or "")
        local amount = math.max(1, math.floor(tonumber(reward.Amount) or 1))
        if rewardType == "Potion" then
            if not reward.PotionId then
                self:_warnInvalidAuthorConfig(entry, "药水奖励缺少 PotionId")
                continue
            end
            if not (self._potionService and self._potionService.AddPotion) then
                return false, "PotionServiceUnavailable"
            end
            local success, reason = self._potionService:AddPotion(player, reward.PotionId, amount, {
                source = "code",
                productGroup = "RedeemCode",
                itemSku = tostring(entry.CodeText or entry.CodeId or "Code") .. "_Potion_" .. tostring(reward.PotionId),
            })
            if not success then
                return false, reason or "PotionGrantFailed"
            end
        elseif rewardType == "WheelSpins" then
            self._playerStateService:AddWheelSpins(player, amount, {
                source = "code",
                productGroup = "RedeemCode",
                itemSku = tostring(entry.CodeText or entry.CodeId or "Code") .. "_WheelSpins",
            })
        elseif rewardType == "Diamonds" then
            self._playerStateService:AddDiamonds(player, amount, {
                source = "code",
                productGroup = "RedeemCode",
                itemSku = tostring(entry.CodeText or entry.CodeId or "Code") .. "_Diamonds",
            })
        else
            self:_warnInvalidAuthorConfig(entry, "跳过不支持的奖励类型: " .. rewardType)
            continue
        end
        table.insert(grantedRewards, reward)
    end

    if #grantedRewards <= 0 then
        return false, "NoRewardsGranted"
    end

    return true, grantedRewards
end

function CodeService:_redeem(player, rawCode)
    if not (ActorUtils.IsPlayer(player) and player.Parent and self._playerStateService) then
        return false, "InvalidPlayer"
    end
    if not self:_isPlayerLoaded(player) then
        return false, "DataLoading"
    end

    local normalizedCode = CodeConfig.NormalizeCodeText(rawCode)
    local entry = self._codeMap[normalizedCode]
    if not entry then
        return false, "InvalidCode"
    end

    local codeKey = getCodeKey(entry)
    if self._playerStateService:HasCodeClaim(player, codeKey) then
        return false, "AlreadyClaimed"
    end
    if not self:_isEntryUsableByTime(entry) then
        return false, "Expired"
    end

    local maxUses = math.floor(tonumber(entry.MaxUses) or 0)
    local counted = false
    if maxUses > 0 then
        local countOk, countReason = self:_incrementUseCount(codeKey, maxUses)
        if not countOk then
            return false, countReason or "UseLimitReached"
        end
        counted = true
    end

    local success, grantedRewardsOrReason = self:_grantRewards(player, entry)
    if not success then
        if counted then
            self:_decrementUseCount(codeKey)
        end
        return false, grantedRewardsOrReason or "GrantFailed"
    end

    if not self._playerStateService:MarkCodeClaim(player, codeKey) then
        if counted then
            self:_decrementUseCount(codeKey)
        end
        return false, "AlreadyClaimed"
    end

    if self._rebirthService and self._rebirthService.MarkDirty then
        self._rebirthService:MarkDirty(player)
    end
    self._playerStateService:PushState(player)
    self:_fireRewardFeedback(player, entry, grantedRewardsOrReason)
    return true, "Granted"
end

function CodeService:_handleRedeemRequest(player, payload)
    local userId = getUserId(player)
    if userId <= 0 or self._redeemInProgressByUserId[userId] then
        self:_fireFeedback(player, false, CodeConfig.WarningMessage)
        return
    end

    self._redeemInProgressByUserId[userId] = true
    local rawCode = type(payload) == "table" and payload.code or payload
    local success = self:_redeem(player, rawCode)
    self._redeemInProgressByUserId[userId] = nil
    self:_fireFeedback(player, success == true, success == true and "Redeemed" or CodeConfig.WarningMessage)
end

function CodeService:BindSystems(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or self._playerStateService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._potionService = dependencies and dependencies.PotionService or self._potionService
end

function CodeService:Init(dependencies)
    self._playerStateService = dependencies and dependencies.PlayerStateService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._potionService = dependencies and dependencies.PotionService or nil
    local remoteEventService = dependencies and dependencies.RemoteEventService or nil
    self._requestCodeRedeemEvent = remoteEventService and remoteEventService:GetEvent("RequestCodeRedeem") or nil
    self._codeRedeemFeedbackEvent = remoteEventService and remoteEventService:GetEvent("CodeRedeemFeedback") or nil
    self._shopRewardFeedbackEvent = remoteEventService and remoteEventService:GetEvent("ShopRewardFeedback") or nil
    self._useCountsByCodeKey = {}
    self._redeemInProgressByUserId = {}
    self:_prepareCodes()

    disconnectConnection(self._requestConnection)
    self._requestConnection = nil
    if self._requestCodeRedeemEvent then
        self._requestConnection = self._requestCodeRedeemEvent.OnServerEvent:Connect(function(player, payload)
            self:_handleRedeemRequest(player, payload)
        end)
    end
end

function CodeService:OnPlayerRemoving(player)
    self._redeemInProgressByUserId[getUserId(player)] = nil
end

return CodeService
