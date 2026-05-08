--[[
=====================================================
武器系统策划文档（V3.0 当前实现同步版）
=====================================================

项目名称: IO项目
当前版本: V3.0
文档更新时间: 2026-04-26
同步依据: WeaponTierConfig.lua、WeaponService.lua、CombatService.lua、HealthService.lua、MonsterService.lua。

一、核心口径
1.武器由玩家或 Studio Bot 的 Level 直接驱动。
2.玩家/Bot 只有 `Alive=true` 且 `IsInArena=true` 时才拥有运行时武器。
3.AttackScore 已下线，不参与武器生成、升级、损毁或回退。
4.服务端武器是判定真值；客户端视觉仅负责本地表现。

二、等级到武器映射
1.当前共有 100 个武器档位：T1-T100。
2.模板统一命名为 `Weapon001` 到 `Weapon100`。
3.每档最多 10 把。
4.每 10 级切换下一档武器：
- Lv1-Lv10：T1，数量等于 `Level`。
- Lv11-Lv20：T2，数量等于 `Level - 10`。
- Lv91-Lv100：T10，数量等于 `Level - 90`。
5.当前 `GameConfig.PLAYER.MaxSupportedLevel = 100`，所以基础版本正式支持到 T10/10；`Weapon001` 到 `Weapon100` 仍作为完整资源模板保留，方便后续继续放开等级上限。
6.`WeaponTierConfig.ResolveLoadoutForLevel(level)` 是唯一等级映射函数。

三、基础武器数值
1.当前所有武器数值由 `WeaponTierConfig` 循环生成。
2.临时伤害线性递增：
`Damage = TierIndex * 10`
3.临时基础血量配置线性递增：
`MaxHealth = TierIndex * 20`
4.环绕半径从 6 开始，每档 +0.04，最高 10。
5.环绕速度从 2.8 开始，每档 -0.01，最低 1.6。
6.示例：
- T1 / Weapon001：伤害 10，基础血量 20，环绕半径 6，环绕速度 2.8。
- T2 / Weapon002：伤害 20，基础血量 40，环绕半径 6.04，环绕速度 2.79。
- T10 / Weapon010：伤害 100，基础血量 200，环绕半径 6.36，环绕速度 2.71。
- T50 / Weapon050：伤害 500，基础血量 1000。
- T100 / Weapon100：伤害 1000，基础血量 2000，环绕半径 9.96，环绕速度 1.81。
7.说明：当前武器对拼不使用武器血量扣减，MaxHealth 只是配置字段和同步属性，不是当前胜负公式。

四、运行时生成与表现
1.服务端运行时容器：`workspace.Runtime.Weapons`。
2.损毁残骸运行时容器：`workspace.Runtime.WeaponDebris`。
3.模板目录：`ReplicatedStorage/Model/Weapon`。
4.每个正式武器模板下应包含名为 `Aura` 的 BasePart，服务端只用这个节点做武器伤害、武器对拼和弹飞判定。
5.模板不存在时，`WeaponService` 会自动创建对应 Tier 的占位武器。
6.模板缺少 `Aura` 时，`WeaponService` 会按模型包围盒创建一个不可见 fallback Aura；正式资源仍要求美术/策划维护真实 `Aura`。
7.运行时武器所有 BasePart 均关闭碰撞、触碰和查询；命中逻辑不依赖 Roblox 物理 Touched，而由服务端每帧扫描 Aura 盒体判定。
8.武器围绕 Actor 根部水平旋转，Y 轴高度偏移为 0.9。
9.多把武器按 `360 / 当前武器数量` 均匀分布。
10.本地玩家客户端收到 `WeaponStateSync` 后，由 `WeaponFxController` 创建本地视觉武器，并隐藏自己拥有的服务端武器部件。

五、武器对玩家
1.武器的 `Aura` 盒体命中敌方玩家/Bot 本体时，对目标造成当前武器伤害。
2.玩家/Bot 本体按 `GameConfig.COMBAT.PlayerBodyHitRadius = 3.5` 作为目标半径，和 Aura 盒体做相交判定。
3.同一武器对同一目标命中冷却为 0.35 秒。
4.被击中目标会被击退：
- 水平速度：42
- 向上速度：8
5.如果攻击者拥有 DamageMultiplier Buff，`HealthService` 会按倍率放大对玩家/Bot 造成的伤害。

六、武器对武器
1.武器对武器判定优先于武器对玩家判定。
2.武器对武器使用双方 `Aura` 判定：一方 Aura 盒体与另一方 Aura 近似半径相交即视为命中。
3.Aura 近似半径下限为 `GameConfig.COMBAT.WeaponHitRadiusMin = 2.5`。
4.同一武器对组合命中冷却为 0.25 秒。
5.高 TierIndex 武器击败低 TierIndex 武器。
6.同 TierIndex 武器双败。
7.被击败武器会生成弹飞残骸，并从所属 Actor 当前武器组中移除。
8.如果所属 Actor 当前只剩 1 把有效武器，则该武器不会因武器对拼被移除。
9.最后 1 把有效武器被更高 TierIndex 武器压制时不会弹飞，只会反转绕玩家旋转的方向。
10.武器被移除后，剩余武器会重新均匀分布角度并同步给玩家客户端。

七、武器对小怪/Boss
1.玩家或 Studio Bot 的武器命中小怪/Boss 时，也使用武器 `Aura` 盒体判定。
2.小怪/Boss 目标半径使用怪物状态里的 `ContactRadius`。
3.同一武器对同一怪物命中冷却使用 `GameConfig.MONSTER.WeaponHitCooldownSeconds = 0.2`。

八、残骸表现参数
1.残骸持续时间：0.9 秒。
2.水平飞出速度：24。
3.向上速度：16。
4.重力：36。
5.旋转速度范围：6 到 12。
6.透明淡出开始时间：0.55 秒。

九、归档内容
以下内容不参与当前武器系统：
- AttackScore
- 每把武器所需攻击道具数
- WeaponCurrentHealth 扣血式武器对拼
- 武器损毁后回扣 AttackScore

=====================================================
文档结束
=====================================================
]]
