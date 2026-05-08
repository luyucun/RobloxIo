--[[
=====================================================
资源/Buff 系统策划文档（V3.0 当前实现同步版）
=====================================================

项目名称: IO项目
当前版本: V3.0
文档更新时间: 2026-04-26
同步依据: GameConfig.lua、ExperienceOrbService.lua、MonsterService.lua、BuffService.lua。

一、当前资源口径
1.当前主线资源只有客户端表现型经验块 ExperienceOrb 和 Boss 掉落的服务端公共 DamageMultiplier Buff。
2.旧 Attack / Speed / Health 三类基础道具已经下线。
3.`PickupConfig` 和 `PickupService` 仅保留兼容空实现，不参与当前主线。
4.PickupFeedback 仅保留 RemoteEvent 创建，不参与当前主线。

二、经验块 ExperienceOrb
1.服务：`ExperienceOrbService`。
2.服务端不再生成公共经验块实例；击杀者客户端本地运行时容器：`workspace.Runtime.ExperienceOrbs_Client`。
3.模板目录：`ReplicatedStorage/Model/Item`。
4.模板名：`ExperienceOrb`。
5.经验块模板位于 `ReplicatedStorage/Model/Item/ExperienceBlocks`，包含 `ExperienceBlockRed`、`ExperienceBlockYellow`、`ExperienceBlockBlue`、`ExperienceBlockGreen` 四个 SmoothPlastic 小方块；客户端生成时随机克隆其中一个。
6.经验块可由普通小怪和 Boss 死亡触发表现。
7.怪物死亡时，服务端立即给击杀者结算经验；客户端经验块只做本地视觉表现，不负责结算。
8.如果击杀者是真实玩家，服务端只向该玩家发送 `ExperienceFeedback(eventType = "ExperienceDrop")`，该玩家客户端在本地生成经验块并在 0.8 秒后向自己吸附；其他玩家不可见。
9.吸附速度：60。
10.吸附结算半径：2.5。
11.触碰拾取防抖仅保留在配置中；当前经验块不再使用服务端 Touched 结算。
12.生成高度偏移：2。

三、经验掉落数值
1.普通小怪：
- 本地表现数量：4
- 每个经验：5
- 总经验：20
- V2 成长口径：Lv1 约杀 5 只基础小怪升 1 级
2.Boss：
- 本地表现数量：10
- 每个经验：50
- 总经验：500
- V2 成长口径：前期约等于 4-5 级奖励
3.`ExperienceOrbService:DropExperience` 会按 `floor(totalValue / orbCount)` 计算客户端表现中的单个经验值，最小为 1；服务端实际结算使用传入的 totalValue。
4.经验块客户端表现：击杀者客户端私有随机克隆红/黄/蓝/绿普通小方块，从被杀死的小怪身上方下落到地面，短暂停留后飞向击杀者玩家；飞行阶段开启拖尾表现，其他玩家不可见。

四、DamageMultiplier Buff
1.服务：`BuffService`。
2.运行时容器：`workspace.Runtime.Buffs`。
3.模板目录：`ReplicatedStorage/Model/Buff`。
4.模板名：`DamageBuff`。
5.模板不存在时自动创建黄色 Neon 球形占位。
6.Boss 死亡后掉落 3 个 Buff。
7.Buff 触碰拾取防抖：0.1 秒。
8.Buff 生成高度偏移：2.2。
9.当前 Buff 类型：`DamageMultiplier`。
10.持续时间：20 秒。
11.伤害倍率：1.5。
12.倍率会影响：
- 玩家/Bot 武器打玩家/Bot 的伤害。
- 玩家/Bot 武器打小怪/Boss 的伤害。

五、归档内容
以下内容不参与当前资源系统：
- 旧三类基础道具
- AttackScore 增长
- 自然刷新旧道具池
- 旧 Item1 / Item2 / Item3 道具模板口径

=====================================================
文档结束
=====================================================
]]
