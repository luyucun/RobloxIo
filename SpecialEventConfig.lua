--[[
脚本名字: SpecialEventConfig
脚本文件: SpecialEventConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/SpecialEventConfig
说明: V2.2 特殊事件数据配置，来源于 IO_BaseBalanceDraft.xlsx 的“特殊事件”页签。
]]

local SpecialEventConfig = {}

SpecialEventConfig.SpawnIntervalSeconds = 600
SpecialEventConfig.FutureDisplayCount = 2
SpecialEventConfig.RecentRepeatBlockCount = 2
SpecialEventConfig.RuntimeCloneAttributeName = "SpecialEventRuntimeClone"

SpecialEventConfig.OrderedEventIds = {
    101,
    102,
    103,
    104,
}

SpecialEventConfig.Events = {
    [101] = {
        Id = 101,
        Name = "Hacker",
        Weight = 20,
        ScenePath = "ReplicatedStorage/EventScene/Hacker",
        TextLabelName = "HackerEvent",
        DurationSeconds = 180,
        BossDefinitionId = "2002",
        BossCount = 4,
    },
    [102] = {
        Id = 102,
        Name = "Lava",
        Weight = 20,
        ScenePath = "ReplicatedStorage/EventScene/Lava",
        TextLabelName = "LavaEvent",
        DurationSeconds = 180,
        BossDefinitionId = "2001",
        BossCount = 4,
    },
    [103] = {
        Id = 103,
        Name = "Heart",
        Weight = 20,
        ScenePath = "ReplicatedStorage/EventScene/Heart",
        TextLabelName = "HeartEvent",
        DurationSeconds = 180,
        BossDefinitionId = "2003",
        BossCount = 4,
    },
    [104] = {
        Id = 104,
        Name = "Diamond",
        Weight = 20,
        ScenePath = "ReplicatedStorage/EventScene/Diamond",
        TextLabelName = "DiamondEvent",
        DurationSeconds = 180,
        BossDefinitionId = "2004",
        BossCount = 4,
    },
}

function SpecialEventConfig.GetEvent(eventId)
    return SpecialEventConfig.Events[tonumber(eventId)]
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
