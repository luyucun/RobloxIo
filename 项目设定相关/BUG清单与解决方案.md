# BUG 清单与解决方案

> 来源：2026-09-29 全量代码审查（6 组并行审查 + 关键结论人工复核）。所有 P0 已亲自读代码复核确认。
> 状态取值：待修复 / 修复中 / 已修复待验证 / 已验证 / 不修（需注明理由）。
> 修复每个条目前按 README 标准实现流程先更新需求/架构文档；修复后在此登记状态与开发记录链接。

> V6.13（2026-09-29）：按用户要求暂藏任务/宝箱入口，原代码/库存/任务进度保留。P1-03、P1-04、P1-05、P1-12 等相关问题状态不因入口隐藏而视为修复；新武器空白领取与失败恢复已通过 20 项隔离检查，真实输入/网络/Blur 待 Play 验证。

## P0（严重：可利用漏洞 / 付费完整性）

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P0-1 | 死亡玩家可绕过 Defeated 免费满状态复活 | `ArenaService.lua:1317-1364`、`PlayerStateService.lua:3953-3963`、入口 `ArenaService.lua:1118-1165` | `TryEnterArena` 不校验 `state.Alive`，`SetInArena(true)` 隐式置 Alive=true 并回满血。Nuke 击杀全服玩家后尸体留在 Portal 范围内即可发 RequestJoinBattle 满血满级重进。方案：两处入口加 Alive 校验；复活语义收口到 RespawnService | 已修复待验证（2026-09-29，V6.4） |
| P0-2 | 小怪击杀上报不校验令牌激活，可零战斗刷经验 | `LocalMonsterRewardService.lua:465-477` | `_processLocalMonsterKill` 只查 Consumed 不查 Active。令牌签发 4次/秒×25=100个/秒，击杀限速按批次计。方案：强制 Active==true；已激活令牌总量上限；激活事件限速；激活-击杀最小时间差 | 已修复待验证（2026-09-29，V6.4 + 自检轮：击杀与核弹扫荡均强制 Active；激活令牌桶 40/s 突发 400；激活上限 400 + Active 1800s 过期；签发批量 25→10、击杀批量 24→12；最小间隔参数默认 0——自检确认正值会误拒同 tick 合法速杀） |
| P0-3 | 七日登录 UnlockAll 付费商品缺"数据已加载"守卫 | `SevenDayLoginRewardService.lua:514-551`；同构 `RebirthService.lua:909-931`（复仇/保级复活） | 读档飞行中购买写入默认状态，随后被 SetRebirthData 覆盖，已返回 PurchaseGranted 但玩家没拿到。方案：对照 `SkinService.lua:846-848` 补 `_isPlayerLoaded` / `CanWritePersistentProgress` 守卫，返回 NotProcessedYet | 已修复待验证（2026-09-29，V6.4） |
| P0-4 | Robux 发货缺 PurchaseId 台账 + 分发器无 pcall | `RebirthService.lua:945-1082、1148-1150`；`ShopService.lua:482-517` 等 | 除七日登录外所有发货路径无持久化幂等；`_processReceipt` 异常或崩溃后 Roblox 重投即双倍发货。方案：统一 ProcessedPurchaseIds 持久化台账；分发器整体 pcall，异常返回 NotProcessedYet | 已修复待验证（2026-09-29，V6.4：分发更名 _dispatchReceipt，新 _processReceipt 顶层台账查重+登记，随存档 processedPurchaseIds 持久化 60条/30天；ProcessReceipt 走 _processReceiptSafely pcall 包装） |

## P1（重要缺陷 / 明确性能问题）

### 变现与经济

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P1-01 | 兑换码全文在 Shared，客户端可枚举 | `CodeConfig.lua:3-4、55-83` | 限量码等同泄库。方案：码表移 ServerScriptService 私有模块 | 待修复 |
| P1-02 | 兑换码多奖励部分失败不回滚 | `CodeService.lua:273-330、364-377` | 首奖励已入账但整单判失败，重试重复发。方案：先全量预检再发放，或失败逆操作 | 待修复 |
| P1-03 | 宝箱扣箱落档但奖励只存内存 | `ChestService.lua:366-384、281-299` | 崩溃即"箱子没了奖励也没了"；部分失败整单丢弃。方案：pending 入档或开箱同步入账；失败保留重试 | 待修复 |
| P1-04 | 奖励弹窗 claimId 单槽被覆盖，宝箱锁死 | `ShopController.lua:1296-1302`；服务端 pending 无超时 `ChestService.lua:337、383` | 其他来源 ShopRewardFeedback 覆盖后本局无法再开箱。方案：客户端队列化；服务端 pending 超时自动发放 | 待修复 |
| P1-05 | 任务多奖励部分失败只回滚领取标记 | `TaskService.lua:508-515、590-599` | 与 P1-02 同构。方案：预检 + 已发部分逆操作或人工补发埋点 | 待修复 |

### 玩法正确性

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P1-06 | 护盾跨死亡存续且叠加续期 | `HealthService.lua:658-661、864-866` | 死亡不清 `_shieldExpiresAtByUserId`，每轮入场 +10s 叠加，可维持 ~80-90% 无敌。方案：死亡清零；GrantShield 设总时长上限 | 待修复 |
| P1-07 | "最后 1 把武器反转方向"规格未实现 | `WeaponService.lua:1544-1546`（规格：武器系统策划文档.lua:70） | 直接 return false 无表现无反馈，全文件无 OrbitDirection 翻转。方案：补规格确认后实现翻转+同步+受击反馈 | 待修复 |
| P1-08 | Flash 射线方向与位移方向不一致可穿墙 | `FlashService.lua:_getReachableTarget` | V6.14：射线和遇墙退让统一沿 Battle 边界裁剪后的方向。普通墙及斜向边界墙隔离回归通过；真实角色/墙体场景待 Play 验证。P1-14 请求限流问题仍独立保留。 | 已修复；待实机验证 |
| P1-09 | 击杀者同帧死亡时 Boss 经验整笔蒸发 | `ExperienceOrbService.lua:136-141` | 非授权路径静默 return。方案：顺延最近存活伤害贡献者或公共经验球 | 待修复 |
| P1-10 | WeaponTierConfig T35-T39 名称错位一档 | `WeaponTierConfig.lua:60 vs 105-110` | 手写表与生成表错位，Magma Hammer 从未生效；band 三字段是死数据。方案：重跑导表同步修正 | 待修复 |
| P1-11 | 回大厅复活 yield 期间退出，存档掉 Lv1 | RespawnService:_revivePlayerToLobby | V6.5 先 RestoreCombatProgress 到应保留的半等级大厅状态，再 LoadCharacter；保留原死亡快照到大厅传送成功，失败可重试且不重复减半 | 已修复待实机验证（20 项隔离回归含重建前进度和失败重试；实际退出重连待 Playtest） |
| P1-12 | 宝箱每周倒计时星期换算差一天 | `ChestController.lua:77、135-136` | Lua wday 1=周日，7=周六；实际指向周六 22:00 且与服务端任务周一口径不一致。方案：改服务端下发 resetAt | 待修复 |
| P1-13 | 任务详情固定背景曾被误列为进度条缺陷 | `TaskController:_renderProgress / _renderDetail` | V5.8 规格明确原 ProgressBg.Progress 保持默认大小；V6.12 保留该背景，额外增加独立 ProgressTrack.Fill 显示比例 | 原项按规格澄清关闭；新细条已通过隔离验证 |

### 服务端性能与 DoS

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P1-14 | RequestFlash 无限速且 Blocked 分支不进冷却 | `FlashService.lua:235-299` | 贴墙+移动可每帧 12 次 Raycast + 全服排除表重建。方案：令牌桶 + 拒绝短冷却 + 参数缓存 | 待修复 |
| P1-15 | RequestPlayerStateSync 无限流 | `PlayerStateService.lua:2032-2049` | 任意频率触发 ~90 字段大 payload。方案：每玩家 0.5-1s 冷却 + BuildStatePayload 缓存归一化 | 待修复 |
| P1-16 | 战斗热路径每次命中/格挡全量 PushState | `HealthService.lua:827-843` | 围攻时每秒多次大 payload。方案：脏标记 + 定时统一推送 | 待修复 |
| P1-17 | NukeSweep tokens 数组无界 | `NukeService.lua:300-339`、`LocalMonsterRewardService.lua:707-720` | 全无效 token 时 O(n) 完整迭代可每帧重发。方案：入口限速 + `#tokens` 截断 | 待修复 |
| P1-18 | Active 授权永不过期无上限，剪枝 O(N²) | `LocalMonsterRewardService.lua:217-235` | 内存+CPU 双重 DoS 向量。方案：硬上限 + 长 TTL + 低频定时剪枝 | 待修复 |
| P1-19 | MonsterService 两个每帧 O(N²) 热点 | `MonsterService.lua:624-661、937-964` | 命中扫描挂裸 Heartbeat 无节流；分离 O(M²)/帧。当前服务端不刷普通怪暂不痛。方案：套 CombatService 同款步进+粗筛；开启 ServerPopulation 前必须先修 | 待修复 |
| P1-20 | Buff 掉落无 TTL 无清理循环 | `BuffService.lua:212-258` | 未拾取 Buff 永久累积。方案：ExpiresAt + Debris/心跳清理 | 待修复 |

### 客户端稳定性

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P1-21 | 伤害数字池挂 CurrentCamera，重生后池污染失效 | LocalMonsterController:_showDamageNumber；同根因 WeaponFxController | V6.6 小怪伤害锚点/爆点改挂客户端 Workspace；离场清池并清待显示桶。WeaponFxController 同类风险尚未处理 | 部分修复：小怪侧隔离回归通过，实际重生待验证；武器侧待修复 |
| P1-22 | _rebuildLocalWeapons continue 留数组空洞+旧实例孤儿 | `WeaponFxController.lua:762-764` | 洞后武器冻结不环绕不参与命中。方案：紧凑数组填充或 fallback 武器 | 待修复 |
| P1-23 | 模态 UI 跨 ownerId 复用面板跳过 Release，UI 永久锁死 | `ModalUiController.lua:1017-1041` | 关闭动画期间另一 owner 重开同面板。方案：PlayPanelOpen 前先 Release 旧 owner | 待修复 |
| P1-24 | 每帧每武器无条件 GetDescendants | `WeaponFxController.lua:867`、`LocalMonsterController.lua:565` | ~1.2 万次/秒浪费。方案：可见性状态缓存 + parts 列表缓存 | 待修复 |

### 数据可靠性

| # | 标题 | 位置 | 问题与方案 | 状态 |
|---|---|---|---|---|
| P1-25 | 全局榜一次读失败禁用整会话写入 | `LeaderboardService.lua:381-397、415-419、653-654` | force 也被跳过，静默欠账。方案：延迟重读恢复 + force 用 max 合并写 | 待修复 |
| P1-26 | ODS 写失败无重试、force 与周期写并发同 key | `LeaderboardService.lua:279-291、312-348、602-618` | SetAsync 6 秒冷却被 throttle 拒绝。方案：重试队列 + per-user 互斥或 UpdateAsync | 待修复 |
| P1-27 | BindToClose 串行保存可能超时 | `RebirthService.lua:813-822`；同文件 711-715 脏标记误清 | 满服丢档窗口。方案：并行保存 + 代际号清脏 | 待修复 |

## P2（建议改进，修复优先级低）

- `ArenaService.lua:59-60、315-318` 防抖表永不清理。
- `RespawnService.lua:261-262、331` MaxHealth 裸公式忽略属性/活动加成（应走 RecalculateDerivedStats）。
- `RespawnService.lua:509-510` Defeated "Revive" 动作静默无效。
- `RespawnService.lua:526-536 + 589-592` 免费复活可吞掉付费复活回执（付费未获权益场景）。
- `HealthService.lua:766、707-715` 每帧重建回血配置表（Init 缓存）。
- `PlayerStateService.lua:927-949` 死代码 configureCharacterCollision。
- `HealthService.lua:822` ApplyWeaponDamage 缺伤害绝对上限（加固）。
- `CombatService.lua:187-233` 每步重建快照表 GC 压力（双缓冲复用）；`:305-306` WeaponHitWeapon 第 5 参数字段错位；`:376-381` 直写客户端所有权角色速度（参考 BossSkillService ApplyImpulse 做法）。
- `ExperienceOrbService.lua:165-168` 零经验仍先构建视觉数组（早退上移）。
- `MonsterService.lua:596、589` 索敌用 AttackRange 而非 AggroRadius、脱战回退 math.huge；`:711-714` 无目标白算分离且静止怪不互斥。
- `BuffService.lua:103-112、179-181` Bot 可拾取 Boss Buff。
- `WeaponService.lua:1175-1177` 环绕更新在武器循环内重复查 Actor 级属性；`:915-917` 重建销毁未清 _weaponByPart 陈旧键。
- `BossService.lua:108-119、198-205` 死亡 Boss 状态滞留、无 BossDied 广播。
- `SpecialEventService.lua:400-404` GM 切事件护盾残留；`:343、419` 事件 Boss 无清理上限；`:248、389-391` 周期钻石间隔缺省 1 秒 + 排期失败每帧重试；`:383-386` 护盾事件每秒全服 PushState。
- `NukeService.lua:230-244` 击杀无 IsInArena 过滤且先移除事件护盾（需策划确认是否有意）；`:449-453` Init 重复调用重复连接（FlashService 同）。
- `GMCommandService.lua:892-906` _connections 只增不减；`:307-321` 跨服务访问私有字段。
- `LeaderboardService.lua:116-144` 名字缓存永不清理。
- `GameAnalyticsService.lua:551-577、743-745` dedupe key 只增不减；负值 summary 被丢弃。
- `BotService.lua:316-322、271-285` 重生死连接累积；克隆活体角色继承残血。
- `FavoritePlacePromptService.lua:284-314` 客户端可控 result 未截断即持久化、"Success" 可伪造关提示。
- `RebirthService.lua:81-84` UserId<=0 共写 "0" 键；`OnlineRewardService.lua:349-365` 收据台账仅会话内存；`ShopService.lua:221-261`、`WheelService.lua:246-278`、`ChestService.lua:279` 领取锁缺 pcall 兜底。
- `LocalMonsterController.lua:950/1243/1311` 三处死代码；`:2019` 恒等表达式；`:1081-1083` 静默丢弃过期 token 不通知服务端、Activate 逐只上报突发。
- `AutoBattleController.lua:899` 无目标每帧全量扫描；`:1029、1113` RenderStepped 内 yield 的 ComputeAsync 无重入保护；`:973-1141` 两套近乎复制的寻路实现。
- `ClientEventController.lua:446` 追踪阶段每帧每球 FindFirstChild；`:351` 模板每次重解析。
- `ModalUiController.lua:550-552、650` 休眠图片清单只采集一次；入口动效固定重绑。
- `MainClient.client.lua:3126-3132`（各控制器同理）WaitForChild 无超时，单点阻塞整端初始化。
- `SkinController.lua:426-433` 生产代码遗留调试 print；`:1154-1162` 死代码；`:1389-1395` 乐观装备失步窗口；`:1693` LayoutOrder 10000 魔数。
- `ShopController.lua:918-928` 复制粘贴的重复 FireServer 分支。
- `ChestController.lua:451` 禁用态视觉恒不生效（传参恒 true）；`:512-516` 按钮恢复依赖 2 秒内状态同步；`:535-544` 倒计时循环永不停止。
- `TaskController.lua:1086` 状态同步清空防双击窗口；`:1087` 面板关闭仍全量重建列表。

## 审查中的正面结论（不需要动作，供后续审查参考）

- RemoteNames ↔ RemoteEventService ↔ 事件使用三方一致（89 个事件程序化比对）。
- GM 命令门禁单点 `RunService:IsStudio()` 无漏检分支。
- Studio 不写 OrderedDataStore 的环境隔离贯彻到位。
- 等级映射 61 段覆盖 Lv1-610 无洞无缝；伤害公式两侧一致；ResolveLoadoutForLevel 边界正确。
- TaskService 的"先占标记 + pcall + 失败回滚"是全项目领取实现标杆。
- MarketplaceService.ProcessReceipt 全项目仅注册一处，无覆盖冲突。
- 客户端四个大控制器上行仅意图，未发现本地计价直改权威的路径。

## V6.6 小怪反馈补充

- 已修复待实机验证：普通怪秒杀/伤害合并期间死亡会清掉 DamageBucket，最后一击不显示。现在回收前立即冲刷一次，延迟回调不会重复显示；奖励链路不变。

## V6.8 养成与转盘问题修复

- 已修复，35 项隔离回归通过、Studio 源码读回与截图已确认：刀刃恢复 30 级后无收益仍可升 40 → 表格最大值改 30，旧多余技能点幂等退回，历史购买上限归档。
- 已修复：免费养成重生清空超额分数 → 权威层只扣当次门槛，余分保留，保存中的同玩家请求不重复结算；付费仍不扣分。
- 已修复：转盘已拥有 Butter 仍显示皮肤且无补偿 → 自动 5,000 钻石，服务端实发与客户端金额/图标/转换说明一致，不改变概率。
- 待实机确认：手机文字尺寸、完整抽奖动画，以及正式玩家保存回登；没有启动 Playtest 或发布。

## 2026-09-29 异常移速专项排查

- **已确认缺口，待修复**：`PlayerStateService.lua:2369` 只设置权威期望 WalkSpeed，未配套服务端持续位移校验；默认客户端角色物理控制下，异常客户端可能突破正常移动速度。应结合水平位移窗口、网络容差、合法传送/复活/Flash/击退授权做记录和位置纠正，不能只反复重设 WalkSpeed。
- **本次现场原因待验证**：没有异常玩家运行数据，不能将以上缺口直接认定为作弊。当前基础移速 18–20，Hacker 事件翻倍并在结束时刷新；Flash 30 studs / 0.3 秒、冷却 5 秒；足球 Boss 存在短暂高速击退。未发现养成/事件反复叠加当前 WalkSpeed 的代码。
- **待核对的历史数据**：`PlayerStateService.lua:722` / `RebirthService.lua:439` 仍保留存档 MoveSpeedBonus，当前三个药水配置均为 0，若旧档保留加成可能个别玩家不同速，尚未读取任何异常玩家存档证实。

## V6.12 任务 UI 表现修复

- 已修复并隔离验证：tintGuiTree 的 `enabled and nil or DISABLED_TINT` 总取灰色，正常 Claim 字体无法恢复；现按明确条件恢复模板原色。
- 已修复并隔离验证：任务选择递归抓首个 UIStroke，可能改到文字描边；现只更新直属行级描边，不变字体。
- 已修复并隔离验证：页签选中 UIScale=1.04 与 hover 的基准 1 互相覆盖；选中改色，缩放仅由交互控制。
- 已修复并隔离验证：切换选择/状态同步重建整批任务行与奖励节点；现复用实例和必要绑定。窄屏周任务长描述通过条目最小高度和换行空间修正。
