--[[
脚本名字: PickupConfig
脚本文件: PickupConfig.lua
脚本类型: ModuleScript
Studio放置路径: ReplicatedStorage/Shared/PickupConfig

归档说明:
V3 新框架不再使用 Attack/Speed/Health 三类基础道具。
当前主线资源由 MonsterService 掉落 ExperienceOrbService 经验块。
]]

local PickupConfig = {}

PickupConfig.Deprecated = true
PickupConfig.TypeOrder = {}
PickupConfig.Types = {}
PickupConfig.TotalActiveCount = 0

return PickupConfig
