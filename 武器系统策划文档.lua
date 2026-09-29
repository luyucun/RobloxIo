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
1.当前正式开放的可见武器档位为 T1-T40；Lv401-Lv610 使用 T40 外观下的隐藏战力 41-61。
2.可见模板统一命名为 `Weapon001` 到 `Weapon040`。
3.每档最多 10 把。
4.Lv1-Lv9 逐步增加 T1 数量，Lv10 起保持总数 10 把，跨档时逐把替换为下一档武器：
- Lv1-Lv10：T1，数量等于 `Level`，最多 10 把。
- Lv11-Lv19：逐步把 T1 替换为 T2，例如 Lv11 = 9 把 T1 + 1 把 T2，Lv19 = 1 把 T1 + 9 把 T2。
- Lv20：10 把 T2；Lv21 起逐步把 T2 替换为 T3，后续档位同理。
5.当前 `GameConfig.PLAYER.MaxSupportedLevel = 610`。Lv391-Lv610 可见外观保持 T40/10；Lv401-Lv610 每 10 级提升一档隐藏战力。
6.`WeaponTierConfig.ResolveLoadoutForLevel(level)` 是唯一等级映射函数。

三、基础武器数值
1.当前等级武器数值由 `IO_BaseBalanceDraft.xlsx / 等级武器映射` 同步到 `WeaponTierConfig`。
2.Lv1-Lv400 的可见档位伤害按 `Damage = TierIndex * 5` 递增；Lv401-Lv610 保持 T40 外观并按隐藏战力继续从 205 提升至 305。
3.武器不再配置基础血量、当前血量或环绕半径。
4.环绕速度统一读取 `GameConfig.WEAPON.OrbitSpeed`，当前为 2.8，不再按武器档位单独配置。
5.示例：
- T1 / Weapon001：伤害 5。
- T2 / Weapon002：伤害 10。
- T10 / Weapon010：伤害 50。
- T40 / Weapon040：伤害 200；Lv401-Lv410 的隐藏战力 41：伤害 205；Lv601-Lv610 的隐藏战力 61：伤害 305。
6.说明：当前武器对拼不使用武器血量扣减，胜负只看隐藏 CombatRank；客户端可见档位仍使用 TierIndex。武器运行时属性也不再写入 MaxHealth / CurrentHealth。

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
5.高 CombatRank 武器击败低 CombatRank 武器。
6.同 CombatRank 武器双败。
7.被击败武器会生成弹飞残骸，并从所属 Actor 当前武器组中移除。
8.如果所属 Actor 当前只剩 1 把有效武器，则该武器不会因武器对拼被移除。
9.最后 1 把有效武器被更高 CombatRank 武器压制时不会弹飞，只会反转绕玩家旋转的方向。
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

V6.2 等级上限与隐藏战力补充：
1.正式可见武器档维持 T1-T40，模板为 `Weapon001` 至 `Weapon040`；Lv391 起显示 `T40 / Weapon040 / Abyss Eye Blade`。
2.Lv401-Lv610 不更换武器外观、图标或可见 TierIndex，始终显示 T40 并维持 10 把武器。
3.该区间按每 10 级一档增加隐藏 CombatRank：Lv401-Lv410 为 41，至 Lv601-Lv610 为 61；对应单把基础伤害从 205 递增至 305，每档 +5。
4.武器对撞由服务端比较 CombatRank，而非可见 TierIndex：高 CombatRank 击败低 CombatRank，相同 CombatRank 双败。武器命中角色仍使用该武器的实际伤害值。
5.可见武器解锁奖励、HUD 档位、模型选择和客户端反馈仍只读取 T40 / TierIndex 40，Lv400 到 Lv401 不触发可见武器升级奖励。

V6.3 皮肤 10008：
1.皮肤 `10008` 使用 `Skin008 / Sausage`，图标为 `rbxassetid://127903390161619`，在皮肤列表中 `SortOrder = 2`。
2.该皮肤通过通行证 `1927237014` 购买；客户端展示官方实时价格，表内 `RobuxPrice = 69` 仅作价格读取失败时的回退展示。
3.模型路径为 `ReplicatedStorage.Model.Weapon.Skin008`。皮肤模型只改变可见外观，仍沿用玩家当前等级对应的武器伤害、数量和隐藏 CombatRank。

=====================================================
文档结束
=====================================================

]]
