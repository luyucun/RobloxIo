--[[
Script: SubscriptionConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/SubscriptionConfig
Purpose: V3.3 official Roblox in-experience subscription configuration.
]]

local SubscriptionConfig = {}

SubscriptionConfig.SubscriptionId = "EXP-2853161122415116867"
SubscriptionConfig.DailyDiamondReward = 1000
SubscriptionConfig.DailyWheelSpinReward = 5
SubscriptionConfig.ExperienceBonus = 1
SubscriptionConfig.StateRefreshCooldownSeconds = 10
SubscriptionConfig.PaymentRefreshCooldownSeconds = 60
SubscriptionConfig.PurchaseRefreshDelaySeconds = 10
SubscriptionConfig.ActiveBonusText = "+100%"
SubscriptionConfig.InactiveBonusText = "+0%"
SubscriptionConfig.ActiveBonusTextColor = Color3.fromRGB(70, 255, 120)
SubscriptionConfig.InactiveBonusTextColor = Color3.fromRGB(255, 255, 255)

SubscriptionConfig.Messages = {
    DataLoading = "Data is still loading.",
    NotSubscribed = "Subscription required.",
    AlreadyClaimed = "Today's reward has already been claimed.",
    PaymentPending = "Subscription payment is still processing.",
    StatusCheckFailed = "Subscription status check failed.",
    PaymentHistoryCheckFailed = "Subscription payment check failed.",
    ClaimSuccess = "Daily reward claimed.",
}

function SubscriptionConfig.GetCurrentUtcDay(timestamp)
    local resolvedTimestamp = tonumber(timestamp) or os.time()
    return os.date("!%Y-%m-%d", resolvedTimestamp)
end

function SubscriptionConfig.CopyForClient()
    return {
        subscriptionId = SubscriptionConfig.SubscriptionId,
        dailyDiamonds = SubscriptionConfig.DailyDiamondReward,
        dailyWheelSpins = SubscriptionConfig.DailyWheelSpinReward,
        experienceBonus = SubscriptionConfig.ExperienceBonus,
        activeBonusText = SubscriptionConfig.ActiveBonusText,
        inactiveBonusText = SubscriptionConfig.InactiveBonusText,
        activeBonusTextColor = SubscriptionConfig.ActiveBonusTextColor,
        inactiveBonusTextColor = SubscriptionConfig.InactiveBonusTextColor,
    }
end

return SubscriptionConfig
