--[[
V6.17 官方成就徽章 / 2026-10-03
数值真源：IO_BaseBalanceDraft.xlsx / 徽章；导表：tools/SyncCodeConfigFromWorkbook.py --badge-only。

Key                  English name          Server condition
NewPlayerWelcome     Welcome, Warrior!     成功加载进度并进入游戏
BladeCircle          Blade Circle          HighestLevelReached >= 10
FirstVictory         First Victory         TotalPlayerKills >= 1（击杀其他真人；Bot/自杀不计）
BossSlayer           Boss Slayer           FirstBossDefeated == true（普通战斗；核弹不计）
Reborn               Reborn                Rebirth >= 1（养成重生，含免费与付费）
Level100Warrior      Level 100 Warrior     HighestLevelReached >= 100
EyeOfTheAbyss        Eye of the Abyss      HighestLevelReached >= 391（T40 实际解锁等级）
LimitBreaker         Limit Breaker         HighestLevelReached >= 610

全部采用用户新建的 8 枚 ID；旧 NewPlayerWelcome ID 与 FirstSubscription 配置及发奖调用移除。
8 枚均为一次性成就，不附加钻石/经验/属性，不引入每日刷新或手动领取。
官方图标由用户创建时上传，英文名称已经公共接口核实；本次不再另做图标。

旧玩家：最高等级/重生/累计真人击杀从现有记录补发；Boss 事实旧版本没有存档，不能臆测。
持久化：FirstBossDefeated/firstBossDefeated 和 TotalPlayerKills/totalPlayerKills 仅由服务端更新。
发奖可靠性：拥有/发奖只在官方 true 后缓存；失败保留事实、有限重试，下一会话可补发。
部署前需核实 Universe 10133052560、徽章英文元数据、启用状态和真实 ID。ID=0 仅表示待创建。
]]
