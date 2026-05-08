--[[
脚本名字: AttackProgressionConfig
脚本文件: AttackProgressionConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/AttackProgressionConfig

归档说明:
V3 新框架已下线 AttackScore。武器成长由 PlayerStateService 的 Level
和 WeaponTierConfig.ResolveLoadoutForLevel 统一驱动。
]]

local AttackProgressionConfig = {}

AttackProgressionConfig.Deprecated = true

function AttackProgressionConfig.Resolve()
    warn("[AttackProgressionConfig] 已归档。请使用 WeaponTierConfig.ResolveLoadoutForLevel(level)。")
    return {
        Tier = "None",
        Count = 0,
        AttackScorePerWeapon = 0,
        MinAttackScore = 0,
    }
end

return AttackProgressionConfig
