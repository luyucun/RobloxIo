--[[
Script: BadgeConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/BadgeConfig
Purpose: Central badge definitions for official Roblox badge awards.
]]

local BadgeConfig = {}

-- BEGIN GENERATED BADGE ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 徽章. Update via tools/SyncCodeConfigFromWorkbook.py --badge-only.
BadgeConfig.UniverseId = 10133052560
BadgeConfig.Badges = {
    NewPlayerWelcome = {
        Id = 2925365156875899,
        Key = 'NewPlayerWelcome',
        Name = 'Welcome, Warrior!',
        Description = 'Join the experience for the first time.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'Welcome', Target = 1 },
    },
    BladeCircle = {
        Id = 3368569502848708,
        Key = 'BladeCircle',
        Name = 'Blade Circle',
        Description = 'Reach level 10 and enter the circle of blades.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'HighestLevelReached', Target = 10 },
    },
    FirstVictory = {
        Id = 814112112710205,
        Key = 'FirstVictory',
        Name = 'First Victory',
        Description = 'Defeat another player for the first time.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'TotalPlayerKills', Target = 1 },
    },
    BossSlayer = {
        Id = 2895113987032334,
        Key = 'BossSlayer',
        Name = 'Boss Slayer',
        Description = 'Defeat a Boss in combat for the first time.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'FirstBossDefeated', Target = 1 },
    },
    Reborn = {
        Id = 809507198048002,
        Key = 'Reborn',
        Name = 'Reborn',
        Description = 'Complete your first rebirth.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'Rebirth', Target = 1 },
    },
    Level100Warrior = {
        Id = 2959980991257186,
        Key = 'Level100Warrior',
        Name = 'Level 100 Warrior',
        Description = 'Reach level 100 and prove your strength.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'HighestLevelReached', Target = 100 },
    },
    EyeOfTheAbyss = {
        Id = 171794531161233,
        Key = 'EyeOfTheAbyss',
        Name = 'Eye of the Abyss',
        Description = 'Reach level 391 and unlock the Eye of the Abyss.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'HighestLevelReached', Target = 391 },
    },
    LimitBreaker = {
        Id = 1809299515115770,
        Key = 'LimitBreaker',
        Name = 'Limit Breaker',
        Description = 'Reach level 610 and break through your limits.',
        Group = 'Gameplay',
        UniverseId = 10133052560,
        Condition = { Type = 'HighestLevelReached', Target = 610 },
    },
}
BadgeConfig.ProgressBadgeKeys = {
    'NewPlayerWelcome',
    'BladeCircle',
    'FirstVictory',
    'BossSlayer',
    'Reborn',
    'Level100Warrior',
    'EyeOfTheAbyss',
    'LimitBreaker',
}
-- END GENERATED BADGE ROWS

function BadgeConfig.GetBadge(badgeKeyOrId)
    if type(badgeKeyOrId) == "table" then
        return nil
    end

    local key = tostring(badgeKeyOrId or "")
    local direct = BadgeConfig.Badges[key]
    if direct then
        return direct
    end

    local badgeId = tonumber(badgeKeyOrId)
    if badgeId and badgeId > 0 then
        for _, badge in pairs(BadgeConfig.Badges) do
            if tonumber(badge.Id) == badgeId then
                return badge
            end
        end
    end

    return nil
end

function BadgeConfig.GetBadgeId(badgeKeyOrId)
    local badge = BadgeConfig.GetBadge(badgeKeyOrId)
    return badge and math.floor(tonumber(badge.Id) or 0) or 0
end

function BadgeConfig.GetAllBadges()
    local badges = {}
    for key, badge in pairs(BadgeConfig.Badges) do
        badges[key] = {
            Id = badge.Id,
            Key = badge.Key or key,
            Name = badge.Name,
            Description = badge.Description,
            Group = badge.Group,
            UniverseId = badge.UniverseId,
            Condition = badge.Condition and { Type = badge.Condition.Type, Target = badge.Condition.Target } or nil,
        }
    end
    return badges
end

function BadgeConfig.GetEligibleBadgeKeys(state)
    if type(state) ~= "table" then
        return {}
    end

    local eligible = {}
    for _, key in ipairs(BadgeConfig.ProgressBadgeKeys) do
        local badge = BadgeConfig.Badges[key]
        local condition = badge and badge.Condition
        if condition then
            local conditionType = condition.Type
            local qualifies = false
            if conditionType == "Welcome" then
                qualifies = true
            elseif conditionType == "FirstBossDefeated" then
                qualifies = state.FirstBossDefeated == true
            elseif conditionType == "HighestLevelReached" or conditionType == "TotalPlayerKills" or conditionType == "Rebirth" then
                local progress = tonumber(state[conditionType]) or 0
                qualifies = progress >= condition.Target
            end
            if qualifies then
                eligible[#eligible + 1] = key
            end
        end
    end
    return eligible
end

return BadgeConfig
