--[[
Script: BadgeConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/BadgeConfig
Purpose: Central badge definitions for official Roblox badge awards.
]]

local BadgeConfig = {}

BadgeConfig.Badges = {
    NewPlayerWelcome = {
        Id = 3537031617648069,
        Key = "NewPlayerWelcome",
        Name = "New Player Welcome",
    },
    FirstSubscription = {
        Id = 666216046024364,
        Key = "FirstSubscription",
        Name = "First Subscription",
    },
}

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
    if badgeId then
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
        }
    end
    return badges
end

return BadgeConfig
