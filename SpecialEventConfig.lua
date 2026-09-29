--[[
脚本名字: SpecialEventConfig
脚本文件: SpecialEventConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/SpecialEventConfig
说明: V5.4 特殊事件数据配置，事件基础数据来源于 IO_BaseBalanceDraft.xlsx 的“特殊事件”页签，效果配置由服务端读取。
]]

local SpecialEventConfig = {}

SpecialEventConfig.SpawnIntervalSeconds = 600
SpecialEventConfig.FutureDisplayCount = 2
SpecialEventConfig.RecentRepeatBlockCount = 2
SpecialEventConfig.RuntimeCloneAttributeName = "SpecialEventRuntimeClone"

SpecialEventConfig.EventEffects = {
    [101] = {
        MoveSpeedMultiplier = 2,
    },
    [102] = {
        ExperienceBonus = 1,
    },
    [103] = {
        BaseMaxHealthMultiplier = 2,
        BaseHealthRegenMultiplier = 2,
    },
    [104] = {
        PlayerKillDiamondMultiplier = 2,
        PeriodicDiamondAmount = 10,
        PeriodicDiamondIntervalSeconds = 5,
    },
    [105] = {
        ShieldUntilEventEnd = true,
        BattlePartTransparencyPath = { "Battle01", "Battle" },
        BattlePartActiveTransparency = 1,
        BattlePartInactiveTransparency = 0,
    },
}

-- BEGIN GENERATED SPECIAL EVENT ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 特殊事件. Update via tools/SyncCodeConfigFromWorkbook.py.
SpecialEventConfig.OrderedEventIds = {
    101,
    102,
    103,
    104,
    105,
}

SpecialEventConfig.Events = {
    [101] = {
        Id = 101,
        Name = 'Hacker',
        Weight = 20,
        ScenePath = 'ReplicatedStorage/EventScene/Hacker',
        IconImage = 'rbxassetid://122037515956872',
        EffectDescription = 'You gain 2x Move Speed during the event.',
        TextLabelName = 'HackerEvent',
        DurationSeconds = 180,
        BossDefinitionId = '2002',
        BossCount = 4,
    },
    [102] = {
        Id = 102,
        Name = 'Lava',
        Weight = 20,
        ScenePath = 'ReplicatedStorage/EventScene/Lava',
        IconImage = 'rbxassetid://136328818373147',
        EffectDescription = 'You gain 2x EXP during the event.',
        TextLabelName = 'LavaEvent',
        DurationSeconds = 180,
        BossDefinitionId = '2001',
        BossCount = 4,
    },
    [103] = {
        Id = 103,
        Name = 'Heart',
        Weight = 20,
        ScenePath = 'ReplicatedStorage/EventScene/Heart',
        IconImage = 'rbxassetid://85362931139789',
        EffectDescription = 'Max Health x2 & Regen x2!',
        TextLabelName = 'HeartEvent',
        DurationSeconds = 180,
        BossDefinitionId = '2003',
        BossCount = 4,
    },
    [104] = {
        Id = 104,
        Name = 'Diamond',
        Weight = 20,
        ScenePath = 'ReplicatedStorage/EventScene/Diamond',
        IconImage = 'rbxassetid://128766305824014',
        EffectDescription = 'Defeat Gems x2 & +10 Gems every 5s!',
        TextLabelName = 'DiamondEvent',
        DurationSeconds = 180,
        BossDefinitionId = '2004',
        BossCount = 4,
    },
    [105] = {
        Id = 105,
        Name = 'Football',
        Weight = 20,
        ScenePath = 'ReplicatedStorage/EventScene/Goal',
        IconImage = 'rbxassetid://113012295658589',
        EffectDescription = 'Stay shielded throughout the event.',
        TextLabelName = 'FootballEvent',
        DurationSeconds = 180,
        BossDefinitionId = '2005',
        BossCount = 4,
    },
}
-- END GENERATED SPECIAL EVENT ROWS

local function copyEffect(effect)
    if type(effect) ~= "table" then
        return nil
    end

    local result = {}
    for key, value in pairs(effect) do
        result[key] = value
    end
    return result
end

function SpecialEventConfig.GetEvent(eventId)
    return SpecialEventConfig.Events[tonumber(eventId)]
end

function SpecialEventConfig.GetEventEffect(eventId)
    return copyEffect(SpecialEventConfig.EventEffects[tonumber(eventId)])
end

function SpecialEventConfig.GetAllEvents()
    local events = {}
    for _, eventId in ipairs(SpecialEventConfig.OrderedEventIds) do
        local eventConfig = SpecialEventConfig.Events[eventId]
        if eventConfig then
            table.insert(events, eventConfig)
        end
    end
    return events
end

function SpecialEventConfig.GetEventLabelNames()
    local labelNames = {}
    for _, eventConfig in ipairs(SpecialEventConfig.GetAllEvents()) do
        if eventConfig.TextLabelName and eventConfig.TextLabelName ~= "" then
            table.insert(labelNames, eventConfig.TextLabelName)
        end
    end
    return labelNames
end

return SpecialEventConfig
