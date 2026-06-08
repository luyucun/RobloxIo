--[[
Script: MonsterCatalog
File: MonsterCatalog.lua
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/MonsterCatalog
Source: IO_BaseBalanceDraft.xlsx / Monster base info draft sheet
]]

local MonsterCatalog = {}

local NORMAL_MONSTER_TYPE_NAME = "Normal Monster"

local DEFINITIONS = {
    ["1001"] = {
        Id = "1001",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster001",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster001",
        SpawnWeight = 20,
        KillScoreReward = 10,
        MaxHealth = 20,
        AttackDamage = 4,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 3,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "130131896201944",
            Run = "130131896201944",
            Attack = "130451407791109",
        },
    },
    ["1002"] = {
        Id = "1002",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster002",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster002",
        SpawnWeight = 10,
        KillScoreReward = 15,
        MaxHealth = 30,
        AttackDamage = 8,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 5,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "106579624061143",
            Run = "106579624061143",
            Attack = "106873361425395",
        },
    },
    ["1003"] = {
        Id = "1003",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster003",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster003",
        SpawnWeight = 20,
        KillScoreReward = 10,
        MaxHealth = 20,
        AttackDamage = 4,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 3,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "109792968796386",
            Run = "109792968796386",
            Attack = "126630167168022",
        },
    },
    ["1004"] = {
        Id = "1004",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster004",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster004",
        SpawnWeight = 10,
        KillScoreReward = 15,
        MaxHealth = 30,
        AttackDamage = 8,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 5,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "127126753617789",
            Run = "127126753617789",
            Attack = "71329836957775",
        },
    },
    ["1005"] = {
        Id = "1005",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster005",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster005",
        SpawnWeight = 15,
        KillScoreReward = 12,
        MaxHealth = 25,
        AttackDamage = 5,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 4,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "82576042999505",
            Run = "82576042999505",
            Attack = "80491919920914",
        },
    },
    ["1006"] = {
        Id = "1006",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster006",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster006",
        SpawnWeight = 20,
        KillScoreReward = 10,
        MaxHealth = 20,
        AttackDamage = 4,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 3,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "112307229850396",
            Run = "112307229850396",
            Attack = "102711210689227",
        },
    },
    ["1007"] = {
        Id = "1007",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster007",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster007",
        SpawnWeight = 5,
        KillScoreReward = 30,
        MaxHealth = 50,
        AttackDamage = 10,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 6,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "81912871119685",
            Run = "81912871119685",
            Attack = "129341118142843",
        },
    },
    ["1008"] = {
        Id = "1008",
        TypeName = "Normal Monster",
        IsNormal = true,
        TemplateName = "Monster008",
        ModelPath = "ReplicatedStorage/Model/Monster/Monster008",
        SpawnWeight = 2,
        KillScoreReward = 50,
        MaxHealth = 80,
        AttackDamage = 15,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 6,
        ExperienceDropCount = 8,
        ExperiencePerOrb = 5,
        Animations = {
            Idle = "121348238681071",
            Run = "121348238681071",
            Attack = "136660397686603",
        },
    },
    ["2001"] = {
        Id = "2001",
        TypeName = "Boss",
        IsBoss = true,
        TemplateName = "Boss001",
        ModelPath = "ReplicatedStorage/Model/Monster/Boss001",
        KillScoreReward = 300,
        MaxHealth = 30000,
        AttackDamage = 3,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 3.1,
        ExperienceDropCount = 10,
        ExperiencePerOrb = 300,
        Animations = {
            Idle = "106579624061143",
            Run = "106579624061143",
            Attack = "106873361425395",
        },
    },
    ["2002"] = {
        Id = "2002",
        TypeName = "Boss",
        IsBoss = true,
        TemplateName = "Boss002",
        ModelPath = "ReplicatedStorage/Model/Monster/Boss002",
        KillScoreReward = 300,
        MaxHealth = 30000,
        AttackDamage = 3,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 3.1,
        ExperienceDropCount = 10,
        ExperiencePerOrb = 300,
        Animations = {
            Idle = "106579624061143",
            Run = "106579624061143",
            Attack = "106873361425395",
        },
    },
    ["2003"] = {
        Id = "2003",
        TypeName = "Boss",
        IsBoss = true,
        TemplateName = "Boss003",
        ModelPath = "ReplicatedStorage/Model/Monster/Boss003",
        KillScoreReward = 300,
        MaxHealth = 30000,
        AttackDamage = 3,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 3.1,
        ExperienceDropCount = 10,
        ExperiencePerOrb = 300,
        Animations = {
            Idle = "106579624061143",
            Run = "106579624061143",
            Attack = "106873361425395",
        },
    },
    ["2004"] = {
        Id = "2004",
        TypeName = "Boss",
        IsBoss = true,
        TemplateName = "Boss004",
        ModelPath = "ReplicatedStorage/Model/Monster/Boss004",
        KillScoreReward = 300,
        MaxHealth = 30000,
        AttackDamage = 3,
        AttackRange = 30,
        AggroRadius = 30,
        DisengageDistance = 30,
        MoveSpeed = 3.1,
        ExperienceDropCount = 10,
        ExperiencePerOrb = 300,
        Animations = {
            Idle = "106579624061143",
            Run = "106579624061143",
            Attack = "106873361425395",
        },
    },
}

local TEMPLATE_NAME_TO_IDS = {}
local NORMAL_MONSTER_DEFINITIONS = {}

for definitionId, definition in pairs(DEFINITIONS) do
    local templateName = tostring(definition.TemplateName or "")
    if templateName ~= "" then
        local ids = TEMPLATE_NAME_TO_IDS[templateName]
        if not ids then
            ids = {}
            TEMPLATE_NAME_TO_IDS[templateName] = ids
        end
        table.insert(ids, definitionId)
    end

    if (definition.IsNormal == true or definition.TypeName == NORMAL_MONSTER_TYPE_NAME) and (tonumber(definition.SpawnWeight) or 0) > 0 then
        table.insert(NORMAL_MONSTER_DEFINITIONS, definition)
    end
end

table.sort(NORMAL_MONSTER_DEFINITIONS, function(left, right)
    return tostring(left.Id) < tostring(right.Id)
end)

function MonsterCatalog.NormalizeAnimationId(animationId)
    local text = tostring(animationId or "")
    if text == "" then
        return nil
    end
    if string.find(text, "^rbxassetid://") then
        return text
    end
    if string.find(text, "^%d+$") then
        return "rbxassetid://" .. text
    end
    return text
end

function MonsterCatalog.GetDefinition(monsterDefinitionId)
    return DEFINITIONS[tostring(monsterDefinitionId or "")]
end

function MonsterCatalog.GetDefinitionByTemplateName(templateName, preferredTypeName)
    local ids = TEMPLATE_NAME_TO_IDS[tostring(templateName or "")]
    if not ids then
        return nil
    end

    for _, definitionId in ipairs(ids) do
        local definition = DEFINITIONS[definitionId]
        if definition and (not preferredTypeName or definition.TypeName == preferredTypeName) then
            return definition
        end
    end

    return DEFINITIONS[ids[1]]
end

function MonsterCatalog.GetTemplateName(monsterDefinitionId)
    local definition = MonsterCatalog.GetDefinition(monsterDefinitionId)
    return definition and definition.TemplateName or nil
end

function MonsterCatalog.IsNormalMonsterDefinition(definition)
    return definition and (definition.IsNormal == true or definition.TypeName == NORMAL_MONSTER_TYPE_NAME)
end

function MonsterCatalog.IsBossDefinition(definition)
    return definition and definition.IsBoss == true
end

function MonsterCatalog.GetNormalMonsterDefinitions()
    return NORMAL_MONSTER_DEFINITIONS
end

function MonsterCatalog.GetRandomNormalMonsterDefinition(randomFn)
    local definitions = MonsterCatalog.GetNormalMonsterDefinitions()
    if #definitions <= 0 then
        return MonsterCatalog.GetDefinition("1001")
    end

    local totalWeight = 0
    for _, definition in ipairs(definitions) do
        totalWeight = totalWeight + math.max(0, tonumber(definition.SpawnWeight) or 0)
    end

    if totalWeight <= 0 then
        return definitions[math.random(1, #definitions)]
    end

    local roll
    if type(randomFn) == "function" then
        roll = randomFn() * totalWeight
    else
        roll = math.random() * totalWeight
    end

    local cursor = 0
    for _, definition in ipairs(definitions) do
        cursor = cursor + math.max(0, tonumber(definition.SpawnWeight) or 0)
        if roll <= cursor then
            return definition
        end
    end

    return definitions[#definitions]
end

return MonsterCatalog
