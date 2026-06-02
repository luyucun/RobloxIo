--[[
脚本名字: CodeConfig
脚本文件: CodeConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/CodeConfig
说明: 兑换码配置、导入结构与奖励解析。
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[CodeConfig] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local ShopConfig = requireSharedModule("ShopConfig")
local PotionConfig = requireSharedModule("PotionConfig")

local CodeConfig = {}

CodeConfig.WarningMessage = "Invalid code"
CodeConfig.MaxRewardsPerCode = 3

CodeConfig.Source = {
    Workbook = "IO_BaseBalanceDraft.xlsx",
    Sheet = "兑换码",
    HeaderRow = 6,
    Columns = {
        CodeId = "兑换码ID",
        CodeText = "兑换码文本",
        CodeType = "类型",
        ExpireAt = "失效时间",
        MaxUses = "使用人数上限",
        Rewards = { "奖励内容1", "奖励内容2", "奖励内容3" },
    },
}

-- BEGIN GENERATED CODE ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 兑换码. Update via tools/SyncCodeConfigFromWorkbook.py.
CodeConfig.ExcelRows = {
    {
        Row = 7,
        ['兑换码ID'] = 1001,
        ['兑换码文本'] = 'WELCOME',
        ['类型'] = '时间型',
        ['失效时间'] = 72686,
        ['使用人数上限'] = nil,
        Rewards = {
            { RewardType = 'Potion', PotionId = 1001, Amount = 3 },
            { RewardType = 'Diamonds', Amount = 50 },
        },
    },
}
-- END GENERATED CODE ROWS

CodeConfig.DefaultCodes = CodeConfig.ExcelRows

local function isBlankLike(value)
    if value == nil then
        return true
    end
    local text = tostring(value)
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text == "" or string.lower(text) == "null" or text == "-"
end

local function parseOptionalInteger(value)
    if isBlankLike(value) then
        return nil
    end
    local numberValue = tonumber(value)
    if not numberValue then
        return nil
    end
    return math.max(1, math.floor(numberValue))
end

local function normalizeCodeType(value)
    local text = tostring(value or "")
    if text == "Timed" or text == "Time" or text == "时间型" or text == "限时" then
        return "Timed"
    end
    if text == "Limited" or text == "UseLimit" or text == "次数型" or text == "限次" or text == "限定使用次数" then
        return "Limited"
    end
    return text ~= "" and text or "Timed"
end

local function trimText(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function parseCountSuffix(text)
    local amount = text:match("[xX%*×](%d+)$")
    if not amount then
        amount = text:match("数量(%d+)$")
    end
    if not amount then
        amount = text:match("(%d+)个$")
    end
    return amount and math.max(1, math.floor(tonumber(amount) or 1)) or nil
end

local function parsePotionRewardText(compactText)
    local body = compactText:match("^药水(.+)$") or compactText:match("^Potion(.+)$")
    if not body then
        return nil
    end

    local potionIdText, amountText = body:match("^(%d+)[xX%*×](%d+)$")
    if not potionIdText and PotionConfig.OrderedPotionIds then
        local bestPotionId = nil
        local bestSuffix = nil
        local bestLength = 0
        for _, potionId in ipairs(PotionConfig.OrderedPotionIds) do
            local potionIdTextCandidate = tostring(potionId)
            if body == potionIdTextCandidate and #potionIdTextCandidate > bestLength then
                bestPotionId = potionIdTextCandidate
                bestSuffix = nil
                bestLength = #potionIdTextCandidate
            elseif body:sub(1, #potionIdTextCandidate) == potionIdTextCandidate then
                local suffix = body:sub(#potionIdTextCandidate + 1)
                if suffix ~= "" and tonumber(suffix) and (#potionIdTextCandidate > bestLength) then
                    bestPotionId = potionIdTextCandidate
                    bestSuffix = suffix
                    bestLength = #potionIdTextCandidate
                end
            end
        end
        potionIdText = bestPotionId
        amountText = bestSuffix
    end

    if not potionIdText then
        potionIdText = body:match("^(%d+)$")
    end

    if not potionIdText then
        return nil
    end

    local amount = tonumber(amountText) or parseCountSuffix(body) or 1
    return {
        RewardType = "Potion",
        PotionId = math.floor(tonumber(potionIdText) or 0),
        Amount = math.max(1, math.floor(amount)),
    }
end

local function parseRewardText(value)
    if isBlankLike(value) then
        return nil
    end

    local text = trimText(value)
    local compactText = text:gsub("%s+", "")

    local diamondAmount = compactText:match("^钻石(%d+)$")
        or compactText:match("^加钻石(%d+)$")
        or compactText:match("^Diamonds(%d+)$")
    if diamondAmount then
        return {
            RewardType = "Diamonds",
            Amount = math.max(1, math.floor(tonumber(diamondAmount) or 1)),
        }
    end

    local spinAmount = compactText:match("^转盘次数(%d+)$")
        or compactText:match("^加转盘次数(%d+)$")
        or compactText:match("^转盘(%d+)$")
        or compactText:match("^WheelSpins(%d+)$")
        or compactText:match("^Spins(%d+)$")
    if spinAmount then
        return {
            RewardType = "WheelSpins",
            Amount = math.max(1, math.floor(tonumber(spinAmount) or 1)),
        }
    end

    local potionReward = parsePotionRewardText(compactText)
    if potionReward then
        return potionReward
    end

    return nil
end

local function collectRewardRows(entry)
    local rewards = {}
    local rewardList = entry.Rewards or entry.rewards or {}
    if type(rewardList) == "table" then
        for _, reward in ipairs(rewardList) do
            if reward ~= nil then
                table.insert(rewards, reward)
            end
        end
    end

    local rewardTexts = entry.RewardTexts or entry.rewardTexts
    if type(rewardTexts) == "table" then
        for _, rewardText in ipairs(rewardTexts) do
            local parsedReward = parseRewardText(rewardText)
            if parsedReward then
                table.insert(rewards, parsedReward)
            end
        end
    end

    for index = 1, CodeConfig.MaxRewardsPerCode do
        local rewardText = entry["奖励内容" .. tostring(index)]
        if rewardText ~= nil then
            local parsedReward = parseRewardText(rewardText)
            if parsedReward then
                table.insert(rewards, parsedReward)
            end
        end
    end

    return rewards
end

local function copyReward(reward)
    if type(reward) ~= "table" then
        return nil
    end

    local rewardType = tostring(reward.RewardType or reward.rewardType or "")
    if rewardType == "" then
        return nil
    end

    local result = {
        RewardType = rewardType,
        PotionId = tonumber(reward.PotionId or reward.potionId) or nil,
        Amount = math.max(1, math.floor(tonumber(reward.Amount or reward.amount) or 1)),
        Label = reward.Label or reward.label,
        Icon = reward.Icon or reward.icon,
        AspectRatio = tonumber(reward.AspectRatio or reward.aspectRatio) or nil,
    }

    if result.RewardType == "Potion" and result.PotionId then
        local potion = PotionConfig.GetPotion and PotionConfig.GetPotion(result.PotionId) or nil
        result.Label = result.Label or ("Potion " .. tostring(result.PotionId))
        local potionIcon = ShopConfig.RewardIcons and ShopConfig.RewardIcons["Potion" .. tostring(result.PotionId)]
        result.Icon = result.Icon or (potionIcon and potionIcon.Image) or (potion and potion.IconImage) or ""
        result.AspectRatio = result.AspectRatio or (potionIcon and potionIcon.AspectRatio) or 1
    elseif result.RewardType == "Diamonds" then
        local diamondIcon = ShopConfig.RewardIcons and ShopConfig.RewardIcons.Diamonds
        result.Label = result.Label or "Diamonds"
        result.Icon = result.Icon or (diamondIcon and diamondIcon.Image) or ""
        result.AspectRatio = result.AspectRatio or (diamondIcon and diamondIcon.AspectRatio) or 1
    elseif result.RewardType == "WheelSpins" then
        local spinIcon = ShopConfig.RewardIcons and ShopConfig.RewardIcons.WheelSpins
        result.Label = result.Label or "Spin"
        result.Icon = result.Icon or (spinIcon and spinIcon.Image) or ""
        result.AspectRatio = result.AspectRatio or (spinIcon and spinIcon.AspectRatio) or 1
    end

    return result
end

local function normalizeExpireAt(value)
    if isBlankLike(value) then
        return nil
    end

    local numericValue = tonumber(value)
    if numericValue then
        if numericValue > 1000000000 then
            return math.floor(numericValue)
        end

        if numericValue >= 30000 then
            local unixSeconds = math.floor(((numericValue - 25569) * 86400) + 0.5)
            if unixSeconds > 0 then
                return unixSeconds
            end
        end
        return math.floor(numericValue)
    end

    local text = tostring(value)
    local year, month, day, hour, minute, second = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)$")
    if year then
        return os.time({
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = tonumber(hour),
            min = tonumber(minute),
            sec = tonumber(second),
        })
    end

    year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if year then
        return os.time({
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = 23,
            min = 59,
            sec = 59,
        })
    end

    return nil
end

local function copyCode(entry)
    if type(entry) ~= "table" then
        return nil
    end

    local codeText = tostring(entry.CodeText or entry.codeText or entry.Code or entry.code or entry["兑换码文本"] or "")
    if codeText == "" then
        return nil
    end

    local rewards = {}
    local rewardRows = collectRewardRows(entry)
    if type(rewardRows) == "table" then
        for _, reward in ipairs(rewardRows) do
            local copiedReward = copyReward(reward)
            if copiedReward then
                table.insert(rewards, copiedReward)
            end
        end
    end

    return {
        CodeId = math.floor(tonumber(entry.CodeId or entry.codeId or entry["兑换码ID"]) or 0),
        CodeText = codeText,
        CodeType = normalizeCodeType(entry.CodeType or entry.codeType or entry["类型"]),
        ExpireAt = normalizeExpireAt(entry.ExpireAt or entry.expireAt or entry["失效时间"]),
        MaxUses = parseOptionalInteger(entry.MaxUses or entry.maxUses or entry["使用人数上限"]),
        Rewards = rewards,
        SourceRow = entry.Row or entry.row,
    }
end

function CodeConfig.NormalizeCodeText(value)
    local text = tostring(value or "")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return string.upper(text)
end

function CodeConfig.GetDefaultCodeMap()
    local map = {}
    for _, entry in ipairs(CodeConfig.DefaultCodes) do
        local copied = copyCode(entry)
        if copied then
            map[CodeConfig.NormalizeCodeText(copied.CodeText)] = copied
        end
    end
    return map
end

function CodeConfig.CopyRewardsForClient(rewards)
    local result = {}
    if type(rewards) ~= "table" then
        return result
    end

    for _, reward in ipairs(rewards) do
        local copiedReward = copyReward(reward)
        if copiedReward then
            table.insert(result, copiedReward)
        end
    end
    return result
end

function CodeConfig.ValidateCodeEntry(entry)
    local warnings = {}
    if type(entry) ~= "table" then
        table.insert(warnings, "兑换码行不是有效表结构")
        return warnings
    end

    if type(entry.Rewards) ~= "table" or #entry.Rewards <= 0 then
        table.insert(warnings, "未配置任何奖励")
    end

    for _, reward in ipairs(entry.Rewards or {}) do
        local rewardType = tostring(reward.RewardType or "")
        if rewardType == "Potion" then
            local potionId = tonumber(reward.PotionId)
            if not potionId or not PotionConfig.GetPotion(potionId) then
                table.insert(warnings, "药水ID不存在: " .. tostring(reward.PotionId))
            end
        elseif rewardType ~= "Diamonds" and rewardType ~= "WheelSpins" then
            table.insert(warnings, "不支持的奖励类型: " .. rewardType)
        end
    end

    return warnings
end

return CodeConfig
