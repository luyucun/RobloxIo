--[[
脚本名字: PickupService
脚本文件: PickupService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/PickupService

归档说明:
V3 新框架已下线旧三类道具和 AttackScore 成长链路。
经验来源改为小怪/Boss 死亡掉落经验块，由 ExperienceOrbService 处理。
]]

local PickupService = {}

PickupService.Deprecated = true

function PickupService:Init()
    warn("[PickupService] 已归档，不再初始化旧道具系统。请使用 ExperienceOrbService + MonsterService。")
end

function PickupService:MaintainPickupPopulation()
    return 0
end

function PickupService:GetNearestPickup()
    return nil, math.huge
end

function PickupService:GetActivePickupCount()
    return 0
end

function PickupService:TryConsumePickupForActor()
    return false
end

return PickupService
