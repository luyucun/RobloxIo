--[[
=====================================================
游戏整体架构设计文档（V3.0 当前实现同步版）
=====================================================

项目名称: IO项目
当前版本: V3.0
文档更新时间: 2026-06-05
同步依据: 当前 Release 目录代码。

一、架构定位
1.当前架构以服务端为玩法真值。
2.核心状态由 `PlayerStateService` 管理：Level、Experience、Health、WeaponTier、WeaponCount、KillCount、TotalPlayerKills、Diamonds、Buffs、IsInArena、Alive，以及订阅/商店等持久领取状态。
3.武器生成、武器碰撞、玩家伤害、小怪伤害、经验结算、Buff 生效、死亡和排行榜均由服务端判定。
4.客户端当前主要通过 `WeaponFxController` 消费 `WeaponStateSync`，为所有真实玩家创建更顺滑的武器视觉副本；服务端武器实例继续保留为碰撞和伤害真值。

二、目录与放置约定
1.服务端入口：
- `ServerScriptService/MainServer`
2.服务端服务：
- `ServerScriptService/Services`
3.共享配置：
- `ReplicatedStorage/Shared`
4.客户端入口：
- `StarterPlayer/StarterPlayerScripts/MainClient`
5.客户端控制器：
- `StarterPlayerScripts/Controllers` 或 `StarterPlayerScripts` 根目录。
6.场景约定：
- `workspace.SpawnLocation`
- `workspace.Map2.Portals.Portal`
- `workspace.Battle`
7.运行时容器由服务自动创建在 `workspace.Runtime` 下。

三、Shared 配置层
1.`GameConfig`
- 服务器人数、玩家基础值、经验曲线、场景名、战斗判定、小怪、Boss、Buff、排行榜、经济、重生和 Studio Bot 配置。
- `DATASTORE` 统一控制持久化环境隔离；Studio 默认只用内存数据，不读写线上 DataStore。
2.`WeaponTierConfig`
- T1-T43 武器配置，由正式武器表同步。
- 包含 TemplateName、TemplatePath、Damage、MaxCount；武器不再配置 MaxHealth 或环绕半径，环绕速度统一读取 `GameConfig.WEAPON.OrbitSpeed`。
- `ResolveLoadoutForLevel(level)` 负责等级到武器档位和数量的映射。
3.`RemoteNames`
- 集中声明 RemoteEvent 文件夹和事件名。
3.1.`GameConfig.ACTIVITY_RSVP_PROMPT`
- 配置 Roblox Experience Event 活动预约系统弹窗，当前 `EventId = "2372830586537640594"`（2026-10-04 更新），玩家进服 180 秒后由服务端请求客户端调起官方 RSVP Prompt；客户端会先查询 RSVP 状态，已 `Going` 的玩家不再弹出取消预约弹窗。
4.`OnlineRewardConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 在线奖励` 同步在线奖励定义，包含奖励类型、数量、图标和本轮所需在线秒数；当前通过 `tools/SyncCodeConfigFromWorkbook.py` 与兑换码配置一起刷新。
4.1.`SevenDayLoginRewardConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 七日登录奖励` 同步七日登录奖励定义；第一轮第 2 天为皮肤 `10007`，第 3 天为 `3000` 钻石，第二轮及之后继续使用重复轮配置。
4.2.`ChestConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 宝箱` 同步宝箱基础信息和掉落池；当前包含宝箱 `101`、`102`，首版客户端只展示并开启 `101`。
- 掉落池支持 `Diamonds`、`WheelSpins`、`Potion`、`Trail`，限时奖励会在玩家已拥有时从抽奖候选中排除。
4.3.`TrailConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 尾迹` 同步尾迹配置；V5.9 新增 `SortOrder`、`IsBoxOnly`、`ExperienceBonus`。
- `IsBoxOnly` 的尾迹不能通过钻石或 Robux 购买，未拥有时客户端显示 `BoxOpen` 入口；`ExperienceBonus` 只在当前装备该尾迹时计入总经验倍率。
4.4.`GameConfig.FLASH`
- 由 `IO_BaseBalanceDraft.xlsx / 技能` 同步 Flash 的距离、时长、冷却、动画资源和安全阈值；当前为 12 studs / 0.2 秒 / 5 秒。
5.`MonsterCatalog`
- 由 `IO_BaseBalanceDraft.xlsx / 怪物基础信息草稿` 同步怪物定义，包含模板、权重、击杀积分、基础战斗数值、经验和动画配置。
- 普通小怪随机池由 `TypeName = 普通小怪` 且 `SpawnWeight > 0` 的定义组成；当前为 `Monster001`-`Monster008`。
6.`SpecialEventConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 特殊事件` 同步特殊事件定义，包含事件 ID、名字、权重、客户端场景路径、事件图标、事件效果描述、事件板文本名、持续时间、BossDefinitionId 和 BossCount。
- V5.4/V5.10 特殊事件效果以 `EventEffects` 静态配置维护：Hacker 最终移速翻倍，Lava 增加 `+100%` 经验加成，Heart 翻倍基础血量/基础回血，Diamond 击杀钻石翻倍并周期发钻石，Football(105) 在事件持续期间为全员保持护盾，并将 `Workspace.Battle01.Battle.Transparency` 临时设为 `1`。
- 特殊事件按服务器运行时每 10 分钟触发一次，排除最近 2 次事件后按权重抽取。
7.兼容/归档配置：
- `AttackProgressionConfig`：保留 Deprecated 标记和警告，当前主线不使用。
- `PickupConfig`：保留空配置，当前主线不使用。

四、服务层
1.`RemoteEventService`
- 创建 `ReplicatedStorage/Events/SystemEvents` 和 `ReplicatedStorage/Events/BattleEvents`。
- 统一注册并提供 RemoteEvent 获取接口。
2.`PlayerStateService`
- 管理玩家和 Studio Bot 状态。
- 负责默认状态、经验升级、血量公式、武器期望状态、局内击杀计数、永久击杀计数、钻石、Buff 状态、客户端状态同步。
- 只向真实玩家推送 `PlayerStateSync` 和 `LevelUpFeedback`。
3.`BotService`
- 当前有效，仅 Studio 环境启用。
- 创建运行时 Bot、注册状态、进战斗区、追敌/找经验、死亡后重生。
4.`ArenaService`
- 管理 SpawnLocation、Map2.Portals.Portal、Battle。
- 处理 Portal 触碰弹出 JoinGame、离开 Portal 范围关闭 JoinGame、接收 Join/Cancel 请求、随机落点、返回出生点。
- 负责玩家本次服务器会话的首次进战场判定：首次成功进入战场发放 60 秒新手护盾，复活后再次进入战场继续发放现有 10 秒入场护盾。
- `IsPositionInsideBattle` 与 `ClampPositionInsideBattle` 为服务端能力提供 Battle 边界校验和安全落点裁剪。
4.1.`FlashService`
- 接收无参数 `RequestFlash`，只接受使用意图；读取服务端角色实际移动方向，验证 Alive/IsInArena/冷却后计算并批准终点。客户端按下发终点播放 0.3 秒突进，服务端在完成时校正落点，不接受客户端上传距离或终点。
- 请求时 Raycast 排除角色和 `Workspace.Runtime`，阻挡时沿边界裁剪后的方向停在墙前；同时裁剪到 Battle 边界。服务端播放 Action 优先级 R15 动画，`FlashFeedback` 反馈开始、拒绝、完成或中断，以及本次冷却、批准终点和实际距离。V6.14 冷却/距离读取玩家的服务端最终属性。
5.`WeaponService`
- 按等级解析武器组，创建和维护服务端武器判定实例。
- 运行时优先使用武器模板下的 `Aura` BasePart 作为命中盒体；缺少时按模型包围盒创建不可见 fallback Aura。
- 处理武器环绕、武器残骸、武器损毁、玩家武器表现状态广播；客户端用同步数据渲染玩家可见的平滑视觉副本，Bot 仍使用服务端实例表现。
6.`RespawnService`
- 处理玩家/Bot 死亡后的战斗状态重置、武器清理和 Bot 延迟重生。
- 玩家死亡后会保持死亡并等待 Defeated 面板按钮，不再按任何倒计时自动复活；非玩家来源死亡也走 Defeated，但无复仇目标。
- 处理 Defeated 免费半等级复活、付费保级复活与 Lobby 回大厅复活的服务端权威判定；免费复活和 Lobby 回大厅复活均为 `max(1, floor(死亡前等级 / 2))`，经验和局内击杀数不恢复。
- 玩家在 Defeated 死亡状态离线时，保存 `DefeatedHalfLevel` 快照；下次登录在大厅按半等级复活，该快照不受普通战场临时快照 30 分钟过期限制。
- 玩家复活后再次进战场时，会显式标记为 `IsRevive = true`，避免误走首次入场的 60 秒新手护盾分支。
7.`BuffService`
- 管理 DamageMultiplier Buff 的生成、触碰拾取、状态写入和伤害倍率查询。
8.`HealthService`
- 处理受伤、Buff 伤害倍率、死亡、击杀计数、死亡反馈和重生入口。
- 死亡反馈会附带 Defeated 免费半等级复活的目标等级展示字段；非玩家击杀来源使用 `userId = 0` 占位击杀者，客户端隐藏 Revenge，最终资格仍以 `RespawnService` 服务端判定为准。
- `GrantShield` 负责护盾时长叠加与表现同步；`EnsureShieldUntil` 可把护盾至少保持到指定绝对时间点，用于 Football 等事件持续护盾，不改动原有叠加规则。
9.`CombatService`
- 每帧扫描战斗区 Actor。
- 先判定武器对武器，再判定武器对玩家本体。
- 通过冷却表限制重复命中。
10.`ExperienceOrbService`
- 服务端管理经验奖励结算、击杀者归属和私有表现事件；经验块实例、延迟吸附和飞行表现由击杀者客户端本地生成。
11.`LocalMonsterRewardService`
- 接收客户端私有普通小怪击杀/攻击事件，做战斗区状态校验、限速、重复击杀过滤，并按 `MonsterCatalog` 校验定义与结算经验、重生积分。
12.`MonsterService`
- 当前只保留 Boss 运行体服务端逻辑。
- 普通小怪由客户端 `LocalMonsterController` 按 `MonsterCatalog` 权重随机私有生成、AI、受击和销毁；所有已生成普通小怪都在所属客户端物化为可见模型，Dormant 小怪静默但不隐藏，`LocalMaxCombatActiveMonsters` 只限制追击/攻击/模拟的活跃数量。
- Boss 仍处理目标获取、脱战待机、追击、接触伤害、受武器伤害、死亡掉落经验和 Boss 掉 Buff。
13.`BossService`
- 按时间间隔调用 `MonsterService:SpawnMonster` 生成 Boss，并广播 Boss 反馈。
- 特殊事件批量刷新 Boss 时，会在 Battle 内先批量采样非 Safe 区候选点，优先选择与现有 Boss、本批次已选 Boss 的 X/Z 平面距离最远的位置；若合法空间不足，会按 `GameConfig.BOSS.EventSpawnMinSpacing*` 配置逐步降低间距要求，最后回退到最佳候选点以保证事件仍能刷新。
13.1.`BossSkillService`
- V6.0 新增 Boss 技能运行层；当前 `GameConfig.BOSS_SKILLS` 将 `Boss2005` / `2005` 绑定到 `FootballKick`，服务端克隆 `ReplicatedStorage.Effect.SkillMessi` 到 `Workspace.Runtime.BossSkills` 并沿 Boss 前方发射。
- `FootballKick` 命中真实玩家时只执行击飞和临时清空武器，不造成伤害且不被护盾抵挡；足球移动距离当前为 100 studs，命中优先按 `SkillMessi` 模型下的 `Aura` BasePart 盒体判定，并对上一帧到当前帧的 Aura 移动路径做扫掠检测，缺少 Aura 时才使用半径兜底。清剑后复用 `WeaponService` 现有逐把恢复逻辑恢复武器，击飞瞬间由服务端短暂接管角色物理，进入 Physics/PlatformStand 失控状态，施加强上抛、水平冲量和翻滚角速度，落地后不额外弹跳，并通过 Battle 范围持续夹取避免玩家被推出战斗区。
14.`LeaderboardService`
- 读写全局 OrderedDataStore，广播全局榜及本人排名的 `LeaderboardSync`；本服玩家列表由 Roblox PlayerList/leaderstats 提供。
- 所有 DataStore / OrderedDataStore 名称必须通过 `GameConfig` 的环境隔离接口获取；线上保持正式库名，Studio 默认不持久化。
15.`ArenaProgressService`
- 构建当前战场内真实玩家等级进度数据，通过 `ArenaProgressSync` 广播给客户端。
- 只统计 `IsInArena = true` 且 `Alive = true` 的真实玩家，不统计 Studio Bot。
16.`SpecialEventService`
- 作为特殊事件服务端真值，维护当前事件、未来两场事件、最近两次事件排除列表，并通过 `SpecialEventSync` 下发给客户端。
- V5.4/V5.10 特殊事件效果只在服务端生效，不新增 RemoteEvent；事件开始、GM 强制切换、事件过期时统一通知 `PlayerStateService` 刷新玩家派生属性。
- 事件开始时按配置刷新 Boss；当前 `MonsterCatalog` 首领定义为 `Boss001`-`Boss005` / `2001`-`2005`，Football(105) 使用 `Boss005` / `2005` 且一次刷新 6 个。
- Diamond 事件期间由服务端每 5 秒给在线真实玩家发放 10 钻石，Football 事件期间通过 `HealthService:EnsureShieldUntil` 为在线玩家和事件中途加入的玩家保持护盾，并把 `Workspace.Battle01.Battle` 透明度设为 `1`；事件结束或被 GM 切换时恢复透明度为 `0`，护盾按到期逻辑自然清理。
- V5.5 同步 payload 会附带事件图标和效果描述，用于客户端 `EventDescribe`、`EventStart` 和玩家头顶事件图标表现；头顶事件图标节点为 `OverheadHealthBar.Root.BarBackground.Event`，与护盾 `Shield` 同级。
17.`OnlineRewardService`
- 管理 V4.3 本次在线会话奖励计时、状态同步、领取发奖、ClaimSuccessful 奖励弹框回传，以及 UnlockAll 开发者商品 `3599440996` 的收据处理；玩家离开后在线计时重置，不写入持久化会话进度。
- 发经验奖励时走 `PlayerStateService:AddExperienceWithMultiplier`，其它奖励复用对应现有服务链路。
18.`TaskService`
- 管理 V5.3 每日/每周任务，任务配置由 `IO_BaseBalanceDraft.xlsx / 任务系统数据表` 同步生成 `TaskConfig`；每日按 UTC 0 点重置，每周按周一 UTC 0 点重置。
- 任务领取必须由服务端做幂等保护：`RequestTaskClaim` 只携带 taskId，`TaskService` 对同玩家同周期同任务加领取锁，先写入 `ClaimedByTaskId` 再发奖；重复请求只同步状态，不重复发奖。
- 服务端权威维护 `state.TaskState` 的周期 key、progress、claimed、weekly login days 和 completed reported；监听在线时长、真实玩家击杀、转盘使用、钻石获得、登录天数、邀请弹窗打开等进度来源。
- 领奖时校验任务存在、周期有效、进度达标且未领取，再发放钻石、转盘次数、经验、药水或宝箱；奖励反馈复用 `ShopRewardFeedback -> Main.ClaimSuccessful`，任务来源使用 0.8 秒后可点击关闭。
- `TaskId` 必须在整张任务表中唯一；同步脚本会对重复 ID 输出 warning，但不会自动改表，重复 ID 会导致 `TaskConfig.GetTask`、领取状态和 GM 指令按同一个 taskId 互相覆盖。
19.`ChestService`
- 管理 V5.9 宝箱数量同步、服务器权威开箱、权重抽奖、限时奖励排除、宝箱消耗、待领取奖励记录、弹框关闭确认后发奖和领奖弹框回传。
- 宝箱数量保存在 `PlayerStateService` 的 `state.Chests`，由 `RebirthService` 保存/读取快照；通用奖励入口可通过 `RewardType = "Chest"` 发放宝箱。
- 开 1 个/开全部均由服务端校验数量；开全部时相同奖励合并显示，限时奖励在玩家已拥有或本轮已抽中后不会继续进入候选。
- Studio GM 支持 `/chestadd <chestId> <amount>`、`/addbox101 <amount>`、`/chestclear [chestId]`、`/chestopen <chestId> <one|all>`、`/skingrant <skinId>`；`/skingrant` 复用 `SkinService:GrantSkin` 校验、存档和状态同步，线上拒绝执行。
20.`ActivityRsvpPromptService`
- 管理 Experience Event 活动预约系统弹窗触发：玩家加入后按 `GameConfig.ACTIVITY_RSVP_PROMPT.DelaySeconds` 延迟发送 `PromptActivityRsvp`，客户端执行 Roblox 官方 `SocialService:PromptRsvpToEventAsync`，并通过 `ActivityRsvpPromptStarted` / `ActivityRsvpPromptResult` 回传埋点结果；本次会话每名玩家最多请求一次，不新增自定义 UI。
21.`FavoritePlacePromptService`
- 管理 Roblox 系统收藏游戏弹窗触发：服务端按 `GameConfig.FAVORITE_PROMPT.DelaySeconds` 延迟发送 `PromptFavoritePlace`；客户端在打开系统收藏弹窗前先调用 `AvatarEditorService:GetFavoriteAsync(placeId, Enum.AvatarItemType.Asset)` 查询平台真实收藏状态，已收藏时直接回传 `AlreadyFavorite` 并跳过弹窗。服务端收到 `Success` 或 `AlreadyFavorite` 后写入 `FavoritePromptState.HasFavorited = true` 并立即保存，避免旧存档状态导致已收藏玩家重复弹窗。
- `GameConfig.FAVORITE_PROMPT.DebugEnabled` 默认关闭；排查时打开可打印 `_shouldPromptPlayer` 的 `HasFavorited` / `LastPromptUtcDay` 判断、客户端结果回传和 `SavePlayerNow` 保存结果。
22.归档服务：
- `PickupService`：空实现，当前主线不初始化。

五、数据与调试安全规则
1.Studio 环境默认不读写任何正式 DataStore；开发者在 Studio 中测试、重生、刷排行榜或清数据，都只影响本次内存会话。
2.线上环境继续使用正式库名：`IO_PlayerRebirth_v1`、`IO_GlobalPlaytime_v1`、`IO_GlobalKills_v1`，避免正式数据因改名断档。
3.如果以后确实需要 Studio 跨次持久化测试，必须只打开 `GameConfig.DATASTORE.StudioPersistenceEnabled`，并写入 `Studio_` 前缀的独立 Store。
4.未来新增 GM、清档、发资源、刷等级、调试命令等功能时，入口必须显式检查 `RunService:IsStudio()`；线上环境必须直接拒绝执行。
5.当前 Studio GM 命令 `/testdefeated` 和 `/defeated` 只用于模拟当前玩家进入 Defeated 死亡状态；线上环境必须拒绝执行。

六、初始化顺序
`MainServer` 当前初始化顺序：
1.`RemoteEventService:Init`
2.`PlayerStateService:Init`
3.`BotService:Init`
4.`ArenaService:Init`
5.`WeaponService:Init`
6.`RespawnService:Init`
7.`BuffService:Init`
8.`HealthService:Init`
9.`CombatService:Init`
10.`ExperienceOrbService:Init`
11.`MonsterService:Init`
12.`BossSkillService:Init`
13.`BossService:Init`
14.`LeaderboardService:Init`
15.`ArenaProgressService:Init`
16.`NukeService:Init`
17.`SpecialEventService:Init`
18.`PlayerStateService:BindSystems`
19.`BotService:BindSystems`

七、关键路径
1.玩家入场：
`PlayerAdded -> OnCharacterAdded -> 大厅出生 -> 主动进入 Portal -> ArenaService 校验实时范围/存活/加载/防抖 -> TryEnterArena -> SetInArena(true) -> 原入场护盾 -> RebuildWeaponsForPlayer`。V6.5 无确认弹框；实际战斗节点为 Workspace.Battle01.Battle。
2.Studio Bot：
`RunService:IsStudio -> ensureStudioBots -> BotService:SpawnBots -> RegisterBot -> TryEnterArena -> WeaponService 创建武器 -> Bot 追敌/找经验`
3.经验升级：
`MonsterService:_handleMonsterDeath -> ExperienceOrbService:DropExperience -> PlayerStateService:AddExperience -> 升级 -> SyncCharacterState -> WeaponService:RebuildWeaponsForActor -> LevelUpFeedback / PlayerStateSync -> ExperienceFeedback(eventType = "ExperienceDrop") -> 击杀者客户端本地播放经验块吸附`
4.武器对战：
`CombatService:_stepCombat -> Aura 盒体命中检测 -> TierIndex 比较 -> WeaponService:HandleBrokenWeapon -> WeaponStateSync -> CombatFeedback`
5.武器打玩家：
`CombatService:_stepCombat -> Aura 盒体命中玩家半径 -> CombatService:_applyWeaponVsActor -> HealthService:ApplyWeaponDamage -> SyncHumanoidHealth -> PlayerStateSync -> 玩家击杀时 AwardPlayerKillReward 增加 TotalPlayerKills 和 Diamonds / DeathFeedback(附带免费半等级复活展示字段) / RespawnService`
6.小怪：
`LocalMonsterController:_maintainPopulation -> 请求 LocalMonsterSpawnToken -> 按 MonsterCatalog 权重本地生成普通小怪 -> 全部物化为所属客户端可见模型 -> Dormant 静默待机 / CombatActive 预算内追击攻击 -> 本地武器命中 -> LocalMonsterRewardService 校验攻击/击杀 -> 服务端结算经验 -> 击杀者客户端播放经验块表现`
7.Boss/Buff：
`BossService:_step -> MonsterService:SpawnMonster(IsBoss) -> BossSkillService:RegisterBoss -> Boss2005 FootballKick(服务端 SkillMessi 投射物/击飞/临时清剑) -> Boss 死亡 -> DropExperience + BuffService:DropBuffs -> BuffService:ApplyDamageBuff`
8.排行榜：
`PlayerStateService / AddKillCount / AddExperience 标记 dirty -> LeaderboardService 定时广播 LeaderboardSync -> 非 Studio 环境同步全局 OrderedDataStore`
9.场中进度表现：
`PlayerStateService:SetInArena / AddExperience升级 / ResetCombatState / OnPlayerRemoving 标记 dirty -> ArenaProgressService 广播 ArenaProgressSync -> ArenaProgressController 复制 StarterGui/Main/Progress/Playertemplate 显示头像和 Lv.xx，并按场内最低/最高等级区间摆放`
10.顶部击杀数与钻石数：
`PlayerStateSync(totalPlayerKills, diamonds) -> TopStatsController 更新 PlayerGui.Main.Top.Kill.Num1 和 PlayerGui.Main.Top.Gem.Num1 -> 钻石增加时本地播放钻石飞入 Gem.Icon 的表现`
11.自动战斗：
`AutoBattleController -> 只寻找客户端本地普通小怪 -> Humanoid:MoveTo 直线靠近 -> 卡住检测 -> PathfindingService 路径绕路 -> 路径失败时短暂排除当前小怪并重新寻敌`
12.特殊事件：
`SpecialEventService:_step -> 按权重生成当前事件和未来两场 -> 应用服务端 EventEffects 并刷新 PlayerStateService 派生属性与战场内头顶事件图标/事件护盾/Football Battle 透明度 -> 刷新事件 Boss -> SpecialEventSync -> SpecialEventController 本地克隆 ReplicatedStorage/EventScene/<事件> 到 Workspace -> 更新 BattleSenceEventBoard / HomeEventBoard 倒计时 -> 显示 Main.EventDescribe 图标/倒计时/效果描述并播放 Main.EventStart 开始弹窗 -> 事件结束后清除服务端效果并由客户端清理本地克隆和事件 UI`
13.在线奖励：
`PlayerAdded -> OnCharacterAdded -> 大厅出生 -> 主动进入 Portal -> ArenaService 校验实时范围/存活/加载/防抖 -> TryEnterArena -> SetInArena(true) -> 原入场护盾 -> RebuildWeaponsForPlayer`。V6.5 无确认弹框；实际战斗节点为 Workspace.Battle01.Battle。
13.1.七日登录奖励：
`PlayerAdded -> OnCharacterAdded -> 大厅出生 -> 主动进入 Portal -> ArenaService 校验实时范围/存活/加载/防抖 -> TryEnterArena -> SetInArena(true) -> 原入场护盾 -> RebuildWeaponsForPlayer`。V6.5 无确认弹框；实际战斗节点为 Workspace.Battle01.Battle。
14.好友邀请提示：
`InviteTipsController -> 玩家在线 2 分钟后请求 FriendsRankingStateSync -> 客户端刷新 GetFriendsOnlineAsync -> 从“曾玩过本体验且当前在线”的好友中按 highestLevelReached 选择最高者 -> 显示 PlayerGui.Main.InviteTips 5 秒 -> 点击 InviteButton 后用 ExperienceInviteOptions.InviteUser 调起 SocialService:PromptGameInvite；本次登录已弹过的好友不再重复弹出，之后每 5 分钟继续检查剩余候选。`
15.活动预约提示：
`PlayerAdded -> OnCharacterAdded -> 大厅出生 -> 主动进入 Portal -> ArenaService 校验实时范围/存活/加载/防抖 -> TryEnterArena -> SetInArena(true) -> 原入场护盾 -> RebuildWeaponsForPlayer`。V6.5 无确认弹框；实际战斗节点为 Workspace.Battle01.Battle。
16.每日/每周任务：
`TaskConfig -> TaskService 初始化并规范化 PlayerState.TaskState -> PlayerStateService/WheelService/InviteTipsController 等来源上报进度 -> TaskStateSync(shortTitle/shortDescription/rewards[]) -> TaskController 渲染 Main.Right.Daily 红点、Main.TaskBgNew 左侧任务列表、右侧任务详情和重置倒计时 -> RequestTaskClaim -> TaskService 校验并逐项发放奖励 -> ShopRewardFeedback -> ShopController 播放 Main.ClaimSuccessful。Studio GM /taskprogress、/taskcomplete、/taskreset 仅在 RunService:IsStudio() 下可用。`
17.宝箱与宝箱尾迹：
`RewardType=Chest 或 Studio GM -> PlayerStateService:AddChest -> PlayerStateSync(chests) / ChestStateSync -> ChestController 更新 Main.Left.Box.Info 和 Main.ChestRewards -> RequestChestOpen(chestId=101, mode=One|All) -> ChestService 校验数量、抽奖、扣除宝箱并记录 pending rewards -> ShopRewardFeedback(rewardClaimId, requiresClaim=true, closeDelay=0.5, keepSourceOpen=true) -> ChestController 播放居中宝箱抖动与光圈表现 -> ShopController 播放 Main.ClaimSuccessful -> 玩家点击关闭弹框 -> RequestChestRewardClaim -> ChestService 发放 Diamonds/WheelSpins/Potion/Trail 并推送状态；SkinController 对 isBoxOnly 尾迹显示 BoxOpen 并打开 ChestRewards。`

八、RemoteEvent
1.SystemEvents：
- PlayerStateSync
- RequestPlayerStateSync
- ArenaTransitionFeedback
- DeathFeedback
- StudioBotCommand
- LevelUpFeedback
- PortalJoinPrompt
- RequestJoinBattle
- SpecialEventSync
- RequestSpecialEventSync
- OnlineRewardStateSync
- RequestOnlineRewardStateSync
- RequestOnlineRewardClaim
- TaskStateSync
- RequestTaskStateSync
- RequestTaskClaim
- RequestInviteTaskProgress
- ChestStateSync
- RequestChestStateSync
- RequestChestOpen
- RequestChestRewardClaim
- LevelWeaponSkinStateSync
- RequestLevelWeaponSkinStateSync
- RequestLevelWeaponSkinEquip
- LevelWeaponSkinFeedback
- PromptActivityRsvp
- ActivityRsvpPromptStarted
- ActivityRsvpPromptResult
2.BattleEvents：
- PickupFeedback
- ExperienceFeedback
- WeaponStateSync
- CombatFeedback
- BuffFeedback
- BossFeedback
- LeaderboardSync
- ArenaProgressSync
3.当前保留但主线未使用：
- PickupFeedback
- StudioBotCommand
4.V5.4/V5.5/V5.10 特殊事件基础效果和 UI 表现复用既有 `SpecialEventSync` 链路，不新增 RemoteEvent；移速、经验、血量、回血、钻石奖励、Football 事件护盾和 `Battle01.Battle` 透明度均以服务端计算为准，客户端只消费事件图标、效果描述和倒计时表现。

九、客户端约束
1.客户端不决定经验、等级、伤害、击杀、死亡、武器胜负、Buff 是否生效。
2.正式 HUD / 提示 / 面板 UI 应放在 StarterGui，客户端控制器只绑定既有节点、更新数据和播放动画。
3.功能型面板打开时统一走模态 UI：隐藏 `PlayerGui.Main` 下除当前面板外的其他同级 `GuiObject`，开启 `Lighting.Blur`，关闭动效结束后恢复原始显示状态和 Blur 状态；打开和关闭都必须播放面板动效。
4.`PlayerStateService` 负责角色头顶血条的创建和同步，血条主体和特殊事件图标都只有 `Alive = true` 且 `IsInArena = true` 时显示；准备区、大厅、死亡或退出战斗状态时隐藏 `OverheadHealthBar.Root.BarBackground.Event`。
5.当前已实现客户端控制器为 `WeaponFxController`，负责隐藏真实玩家服务端武器视觉、按 `ownerUserId` 为本地和远端玩家创建本地视觉武器并按同步数据绕对应玩家旋转。
6.`JoinGameController`（V6.5）隐藏旧 JoinGame，移除 Join/Wait 与模态逻辑，监听 ArenaTransitionFeedback 并用现有 Portal 门牌显示准备/失败反馈；直接入场由 ArenaService 处理，不使用旧 8 秒待确认资格。
7.`SpecialEventController` 负责监听 `SpecialEventSync`，按服务端状态在客户端本地复制/移除特殊事件场景，同步 `Workspace.Map2.BattleSenceEventBoard` 与 `Workspace.Map2.HomeEventBoard` 的事件倒计时文本，并维护 `Main.EventDescribe`、`Main.EventStart` 和废弃隐藏的 `Main.EventEnd`。
8.`ArenaProgressController` 负责监听 `ArenaProgressSync` 和本地 `PlayerStateSync`，只有本地玩家在战场且存活时显示 `PlayerGui.Main.Progress`，并按服务端同步的场内玩家等级区间渲染头像位置。
9.`TopStatsController` 负责监听 `PlayerStateSync`，以原始整数显示永久击杀数和钻石数，并在钻石增加时播放客户端飞入动画；客户端不决定数值增减。
10.`ShopController` 负责商店页面打开/关闭、购买入口绑定、领奖弹框表现，以及商店 Skin 商品名称上 `Secret1` / `Secret2` 渐变的首尾衔接循环流动。
11.`DefeatedController` 负责监听 `DeathFeedback` 打开 Defeated 面板，隐藏倒计时 UI，展示免费半等级复活目标等级，并通过 Marketplace 产品信息实时刷新 Revenge / Revive 的 RMoney 价格。
12.`DefeatedController` 点击 FreeRespawn、Lobby、Close、Revive、Revenge 时只发送意图或触发购买；复活等级、复仇目标、离线快照和是否允许 Revenge 均由服务端判定。
13.`LocalMonsterController` 负责普通小怪本地私有生成和显示：所有生成小怪均物化为所属客户端可见模型，Dormant 小怪保持静默可见，只有 CombatActive 小怪参与追击、攻击、动画和模拟预算。
14.`InviteTipsController` 负责 V5.2 好友邀请提示，仅绑定既有 `StarterGui/Main/InviteTips`，复用 `FriendsRankingStateSync` 的历史好友数据和客户端 `GetFriendsOnlineAsync` 在线状态，不新增 RemoteEvent、不启用模态遮罩或 Blur。
15.`ActivityRsvpPromptController` 负责 Roblox 官方活动预约系统弹窗，不绑定或动态创建 `StarterGui` 节点；收到服务端 `PromptActivityRsvp` 后调用 `SocialService:GetEventRsvpStatusAsync` 和 `SocialService:PromptRsvpToEventAsync`，并将 started/result 回传给服务端。
16.`TaskController` 负责 V5.8 任务面板，仅绑定既有 `StarterGui/Main/TaskBgNew` 和 `Main.Right.Daily`；面板打开/关闭使用本地 `UIScale + TweenService`，不走模态遮罩、不隐藏其它 HUD、不启用 Blur。正式任务内容使用 `TaskBgNew.Content.TaskList.ScrollingFrame.Template` 生成左侧任务入口，并用 `TaskBgNew.Content.TaskDetail` 显示选中任务详情、进度、领取按钮、完成状态和 `RewardList.RewardTemplate` 多奖励列表；Daily/Weekly 页签切换只切换按钮背景状态，选中为黄色，未选中恢复为非黄色，不覆盖文字颜色；右侧详情 `ProgressBg.Progress` 保持 UI 默认大小，不按进度改变长度；时间类进度按分钟数量显示为 `(x/y)`，例如 `(1/15)`，不显示 `59s/15m`；未完成任务的 Claim 保持原文字和样式，点击无反应，不改成 Wait、不额外置灰。旧 `TaskBg` 不再由正式 `TaskController` 驱动。领取请求仍只发 taskId，最终进度校验和 1 到多个奖励逐项发放均由服务端判定。
17.`ChestController` 负责 V5.9 宝箱面板，仅绑定既有 `StarterGui/Main/ChestRewards` 和 `Main.Left.Box`；首版固定展示宝箱 `101`，刷新 `CountText = You have: xx`、入口数量气泡、`Window.CountdownTime` 每周六北京时间 22:00 的手动内容更新说明倒计时，以及右侧掉落列表，点击 `OpenOneButton` / `OpenAllButton` 只发送开箱意图。开箱成功反馈返回后，客户端临时创建 `Main.ChestOpenEffect` 居中展示宝箱和 `rbxassetid://1598630577` 光圈，自动抖动结束后再进入通用领奖弹框；宝箱奖励真正发放由 `ShopController` 在玩家关闭该弹框后发送 `RequestChestRewardClaim` 触发。倒计时只展示 `Rewards Refresh In: xx:yy` 文案，不触发宝箱池自动刷新。
18.`SkinController` 的尾迹页消费 `SkinStateSync.trails[]` 的 `sortOrder`、`isBoxOnly`、`experienceBonus`：按排序字段显示，`TrailRowTemplate.Add` 显示 `Exp*1.x`，未拥有的宝箱尾迹只显示 `BoxOpen` 并打开 `ChestRewards`。
19.`PotionController` 的 `LuckLabel` 继续显示服务端 `totalExperienceMultiplier`，`Tooltip.Trail` 显示 `Trail:Exp*1.x`，没有尾迹加成时显示 `Trail:Exp*1`。
20.`GameNewsController` 负责绑定 `StarterGui/Main/TopRightGui/Log` 到既有 `Main.GameNews` 面板；点击 `Log.Button` 打开公告界面，点击 `GameNews.CloseButton` 关闭，打开/关闭复用 `ModalUiController` 的模态遮罩、Blur 和面板动效，不新增 RemoteEvent。
21.Studio-only GM `/testinvite` / `/invitetips` 由 `GMCommandService` 随机抽取当前玩家好友，经 `FriendsRankingStateSync` 发送 `studioInviteTipsTest = true` 测试 payload，客户端仅在 `RunService:IsStudio()` 下直接弹出 `Main.InviteTips`；V5.3 额外提供 `/taskprogress <taskId> <amount>`、`/taskcomplete <taskId>`、`/taskreset daily|weekly|all` 便于编辑器测试任务进度和周期重置。V5.9 额外提供 `/chestadd <chestId> <amount>`、`/addbox101 <amount>`、`/chestclear [chestId]`、`/chestopen <chestId> <one|all>`；皮肤验证使用 `/skingrant <skinId>`，并由 `SkinService` 处理。
22.`FlashController` 仅绑定现有 `Main.Flash.Info.TextButton`、`Q`、`ButtonX` 和 Studio 已放置的 `CooldownMask`；仅在存活战斗区、未打开模态 UI、且有移动输入时消费键盘/手柄输入。HUD 冷却遮罩和自动战斗暂停均是客户端表现，权威移动和冷却由 `FlashService` 决定。

V6.2 等级上限与隐藏武器战力补充：
1.`GameConfig.PLAYER.MaxSupportedLevel` 由 `IO_BaseBalanceDraft.xlsx / 等级武器映射` 通过 `tools/SyncCodeConfigFromWorkbook.py --level-progression-only` 生成，当前为 `610`；同一窄同步会生成 Lv351-Lv610 的 4000 经验段。
2.`PlayerStateService` 的等级归一化、经验循环、Studio 设置等级、存档恢复、半等级复活均读取上述上限；`GameConfig.GetMaxHealthForLevel` 与 `AttributeConfig.GetTotalSkillPointsForLevel` 不对 Lv400 截断，因此 Lv401-Lv610 继续成长。
3.`WeaponTierConfig.ResolveLoadoutForLevel` 读取生成的 61 个等级武器档。Lv401-Lv610 返回可见 `T40`、`TierIndex = 40`、`Weapon040`，同时为每把运行时武器传递独立 `CombatRank` 和 `Damage`。
4.`WeaponService` 使用可见模板复用运行时实例，并把隐藏 `CombatRank` 与伤害写入服务端武器状态；`CombatService` 只在武器对撞胜负时比较 `CombatRank`，对客户端反馈继续使用可见 `TierIndex`。
5.`WeaponUnlockRewardService` 仍通过 `TierIndex` 判定可领取的可见武器解锁，因此 Lv400 升至 Lv401 不会产生额外的武器解锁奖励或弹窗。

V6.3 皮肤表排序与 10008 通行证补充：
1.`tools/SyncCodeConfigFromWorkbook.py --skin-only` 按 `皮肤表` 的表头读取 `皮肤ID`、`排序`、`获得渠道`、`钻石价格`、`罗布币价格`，再合并 `武器数值` 页的皮肤模型、名称和图标，生成 `SkinConfig.Skins`。
2.`SkinConfig` 和 `SkinStateSync.skins[]` 均携带 `sortOrder`、`robuxPrice`、`gamePassId`；`SkinController` 先按 `sortOrder`、再按皮肤 ID 排序，并以 `LayoutOrder` 驱动现有横向 `UIListLayout`。
3.皮肤 `10008` 配置为 `Skin008 / Sausage`、图标 `rbxassetid://127903390161619`、`SortOrder = 2`、`GamePassId = 1927237014`；`SkinService` 复用现有通行证校验、购买回调和授予链路。
4.皮肤配置只定义外观模板名，实际模型仍由 Studio 资产 `ReplicatedStorage.Model.Weapon.Skin008` 提供；若缺失，`WeaponService` 回退为当前等级的基础武器模板。

V6.4 服务端安全与付费完整性补充：
1.`ArenaService.TryEnterArena` 增加 `state.Alive == true` 前置校验，死亡玩家（含尸体在 Portal 范围内或 8 秒待确认窗口内）经 `RequestJoinBattle` 入场一律返回 `Blocked/Defeated`；Bot 重建角色时 `OnCharacterAdded` 先置 `Alive = true` 再入场，不受影响。复活语义收口在 `RespawnService`，`SetInArena(true)` 不再隐式充当复活途径。
2.`LocalMonsterRewardService._processLocalMonsterKill` 强制令牌 `Active == true`（未激活上报拒绝并计数 `KillsRejected`）；`GameConfig.MONSTER.LocalKillMinActiveSeconds` 默认 0（自检轮确认：客户端生成瞬间即上报 Activate、满批击杀即时冲刷，同 tick 秒杀是合法玩法，任何正的最小间隔都会误拒合法击杀，仅留作未来开关）；`ConsumeNukeSweepTokens` 消耗令牌同样要求 `Active == true`（自检轮补堵：付费核弹不得批量兑换未激活令牌）；`_handleSpawnTokenActivated` 记录 `ActivatedAt`，已激活未消费令牌超过 `LocalSpawnTokenMaxActive`（400）时丢弃新增激活，激活消耗令牌桶预算（突发 400、补充 40/秒）、Active 令牌超 `LocalSpawnTokenActiveTtlSeconds`（1800 秒）过期；令牌签发批量 25→10、击杀上报批量 24→12，持续刷取上限压至约 40 击杀/秒（与合法完美刷怪速率持平）。
3.七日登录 `UnlockAll` 收据与 `RebirthService._processRevenge` / `_processDefeatedRevive` 在档案未加载（`_isPlayerLoaded` / `CanWritePersistentProgress` 不通过）时返回未处理等待 Roblox 重投，防止写入默认状态后被 `SetRebirthData` 覆盖造成已扣款丢发。
4.`RebirthService` 统一收据幂等台账：`_processReceipt` 顶层按 `receiptInfo.PurchaseId` 查重（命中直接 `PurchaseGranted`），原分发逻辑更名 `_dispatchReceipt`；发货成功后登记台账并 MarkDirty，台账随存档字段 `processedPurchaseIds` 持久化（每玩家保留最近 60 条、30 天裁剪），玩家退出在保存之后清理内存表；`MarketplaceService.ProcessReceipt` 回调整体包 pcall（`_processReceiptSafely`），异常返回 `NotProcessedYet`。各子服务（七日登录、皮肤等）既有内部台账保持不变，作为双保险。

V6.5 直接入场与免费复活回大厅（覆盖前文旧确认链路）：
1.ArenaService 统一 Portal 触碰、范围兜底及 Auto 的 RequestJoinBattle(Join)：只接受当前在 Portal 内的存活玩家，使用既有 EnterDebounceSeconds 限频；移除旧待确认宽限。离开范围取消重试，回大厅清空请求并等待离开触发区后重新允许入场。
2.JoinGameController 隐藏旧 JoinGame，不绑定 Join/Wait 或开启模态；仅用现有 Portal.Title.Billboard.Bg.Text 显示本地准备中/失败反馈。PortalJoinPrompt 保留兼容注册，不再发送 Show。回大厅失败使用 Blocked/LobbyReviveFailed 重开 Defeated，原死亡快照保留供重试。
3.ArenaTransitionFeedback 保留 status/spawnMode/timestamp，补充 Entering/Portal、PortalReady/Portal；Blocked 保留原因。所有入场入口仍走 TryEnterArena 的存活和读档校验；漏斗第 4/5 步改为 PortalReached/DirectEntryRequested。
4.RespawnService.FreeRespawn 复用 Lobby/Close 回大厅流程；先恢复半等级和原清零规则，再 LoadCharacter，最后确认角色可用并传送大厅。GrantDefeatedRevivePurchase、RevivePlayer/复仇场内续战不变。
5.AutoBattleController 在死亡、CharacterAdded、ReturnHome 或退出战场时清除 wanted/join/resume/path；大厅主动开启 Auto 后，普通状态刷新保留新意图，成功入场后正常 Auto。
6.Remote 名称/数量不变；RequestJoinBattle 仅 Auto/兼容入口且检查实时位置；RequestDefeatedAction.FreeRespawn 目的地改大厅。无新增持久化字段或数值修改。

=====================================================
文档结束
=====================================================


V6.6 小怪反馈链路：
1.LocalMonsterController 在销毁模型前立即冲刷致命伤害桶，旧延迟回调因桶失效自动退出；独立爆点池由现有 RenderStepped 驱动，到期回收，离场/重置销毁；击杀粒子只表现预测结果，奖励仍等待服务端 token 验证。
2.ClientEventController 只消费现有 ExperienceFeedback.ExperienceDrop 生成经验球；实际吸收到当前角色才触发单例收集脉冲，不由视觉到达再次发奖励。PlayerStateSync 离场/死亡、CharacterAdded、Init 清除视觉；升级特效合并并替换旧实例。
3.AudioSettingsController.PlaySfxOneShotByPath 支持可选 presentationOptions（volumeScale/playbackSpeed），仅修改临时副本，有范围钳制，沿用 __RuntimeSfx 静音与销毁路径。原调用兼容。
4.不变更数值表与任何 Remote/状态协议；命中爆点预算和视觉时间是表现常量，不参与战斗结算。

V6.6 回收补充：LocalMonsterController 的伤害锚点与爆点直接挂客户端 Workspace，不依赖 CurrentCamera 生命周期；死亡/离场清理对象池与待显示桶。


V6.7 血条与命中音效：
1.StarterGui.LocalMonsterHealthBar 为禁用的 BillboardGui 正式模板，含 Track/Fill 和 Percentage；LocalMonsterController 只克隆/绑定模板，按 CurrentHealth/MaxHealth 更新比例与百分比。仅 Alive、CombatActive 且 0<HP<MaxHP 时显示；实例回收/休眠/死亡销毁血条引用，重新活跃可重建。
2.命中声音统一引用 SoundService.SFX_Hit_Sword_Medium_01（既有 Sound）。AudioSettingsController 增加 PlaySfxOneShot(sound, options)，复用原临时副本、静音与生命周期；PlaySfxOneShotByPath 解析后委托，保留原调用兼容。
3.LocalMonsterController 在每次正伤害命中时调用一次，不在击杀上报/重试处重复调用；移除 V6.6 小怪命中音效限频。ClientEventController 仅替换 WeaponHitPlayer 分支，WeaponHitWeapon 原分支不变。
4.无新增 Remote、服务端/持久化状态或数值表更改。MonsterState.HealthBar 为纯客户端视觉引用，不参与奖励或命中判定。


V6.7.1 血条样式：StarterGui.LocalMonsterHealthBar 删除 Percentage，控制器仅校验 Track/Fill 并更新 Fill.Size；模板 Size=UDim2.fromScale(4,0.24)，利用 BillboardGui 世界尺寸自动透视缩放，无需逐帧计算距离。模板部署工具将旧样式迁移至 StyleVersion=2，后续重复执行保留手调样式；未改通信协议、战斗数值或音频。

V6.7.2：LocalMonsterController 播放临时命中音效时传入 volumeScale=0.8，不改共享 Sound 原始音量；BGM 文件夹及子目录 10 首既有 Sound.Volume 从 0.5 改为 0.325。仅表现混音，无协议或战斗数值更改。

V6.8 养成收口：
1. IO_BaseBalanceDraft.xlsx 的属性养成配置 BladeRecovery.MaxCap=30，经导表更新 AttributeConfig；客户端沿用 GetCapUpgradeInfo 自动展示满级。共享开发者商品配置保留供其他属性使用。
2. PlayerStateService 在普通规范化与快照恢复时回收合法旧 31–40 级投入，最多 10 技能点，先计算再钳制保证幂等。legacyBladeRecoveryCap 仅服务端加载、状态、缓存及保存保留历史 31–40 上限，不发到客户端，不发补偿。
3. ApplyRebirth 在任何 yield 前验证并扣除重生前门槛，再增加 Rebirth；失败返回原因且不改状态。RebirthService 对每玩家保存中的重生事务加锁并确保异常释放，沿用既有反馈与持久化通道。
4. 属性与重生无新增 Remote 或客户端字段；转盘按下述追加授权扩展结果字段。
V6.8 转盘补偿：转盘规划新增“重复皮肤补偿钻石”列，导出每个皮肤奖励的 DuplicateDiamonds。WheelService 仅在该次转盘发皮肤返回 AlreadyOwned 时转发钻石，保持次数加载守卫和单次结算；不改全局 GrantSkin 幂等语义。结果保留原 slot/giftName/targetRotation 定位皮肤格，另附实际奖品信息用于中奖弹窗。正式模板提供补偿说明，复用已有钻石奖励模板，补偿钻石使用独立经济来源便于统计。
V6.8 WheelSpinResult.reward 扩展字段：duplicateCompensation:boolean、awardedRewardType:string、awardedAmount:number、awardedGiftName:string、duplicateDiamonds:number。重复时实际奖励 Diamonds/配置金额/Gift5；slot/giftName/targetRotation 保留原皮肤落点，客户端只展示，不发奖励。补偿前用服务端 OwnsSkin 判重以避免重复解锁提示，并兼容 GrantSkin 返回 AlreadyOwned 的并发兜底。
V6.8 正式 UI 模板：StarterGui.Main.WheelBg.DuplicateNotice 为转盘面板底部固定说明，不随盘面旋转；StarterGui.Main.WheelClaim.ResultNotice 为重复中奖转换说明，默认隐藏，控制器只绑定文本与可见性。实际钻石图标复用 ReplicatedStorage.UI.WheelBg.WheelColorBg.Gift5，数量按 awardedAmount 覆盖。部署工具 tools/EnsureWheelDuplicateNotice.luau 仅 Edit 模式创建缺失标签并保留已有样式。
V6.9：删除 StarterGui.Main.Leaderboard 和 StarterPlayer.StarterPlayerScripts.Controllers.LocalLeaderboardController；移除本地控制器文件、MainClient require/Init 及 Rojo 映射。LeaderboardService 删除 _buildServerRows 与 payload.server，LeaderboardSync 保留 global/self/timestamp，供 GlobalLeaderboardController 使用；好友榜通道不变。CoreGuiController 仅禁用默认 Health，保持默认 PlayerList 与 Tab；PlayerStateService._syncLeaderstats 持续更新 Level 和 Kills。本轮无数值表/存档字段变更。
V6.10：ShopController 绑定 StarterGui.Main.PhantomReaperOffer，复用当前 FeaturedSkinId=10002 的购买意图、GamePassId、ShopStateSync.featuredSkinOwned / SkinStateSync.skins[].owned 和服务器发放。名称克隆商城 Name/Secret1/Secret2，使用同一个可见性门控渐变循环；UIScale 呼吸、Light 旋转 Tween 隐藏即停止。价格使用 utf8.char(0xE002) 与实时 PriceInRobux 连排，失败有限重试后保留省略号。拥有状态使用 ModalUiController:SetRestoredVisible 同步模态恢复值。购买来源使用既有 source 字段的 PhantomReaperOffer 值，领奖后回到 HUD；仅客户端/正式模板变化，数值表和网络协议不变。
V6.11：GMCommandService 既有服务端聊天入口接受 /passui [on|off]，仅 Studio；通过 Player boolean Attribute StudioPassUiPreview（RemoteNames.StudioAttributes.PassUiPreview）通知本玩家客户端，缺省 false，不入档、不进入 PlayerState。ShopController/SkinController 监听属性并重算纯展示拥有状态，真实状态仍接收最新快照；GamePass 预览点击在购买意图之前返回，预览状态请求不自动补领礼包。RemoteEventService 不创建同名 Remote。当前覆盖新手礼包 1838079007、Sausage 1927237014、Phantom Reaper 1830742687；后续皮肤依据 GamePass 购买渠道自动覆盖。
V6.11.1：ShopController 的无限往返呼吸改为顺序 Tween（放大→轻摆→缩回→停顿），循环周期约 4.32 秒。用独立活动标志覆盖 Tween 间隙/停顿，序列号令隐藏/重绑后的旧任务失效；取消时恢复 UIScale 与原始 Rotation。不改价格/名称渐变/柔光/GM 预览和购买协议。
V6.12：TaskController 可选绑定详情 StatusText/ProgressTrack.Fill，任务条目保持原三行结构。正式模板沿用原尺寸、半透明底板、蓝色渐变标题、亮蓝条目与紫色奖励格；字体参考 Shop，标题参考 ChestRewards，黄色 Claim 直接使用 Idlecoin.Claim 的字体/描边/渐变。任务选择只定位行级 Stroke，页签保持橙黄/灰底白字但不再写 UIScale，正常按钮不错误置灰。按任务 ID/周期复用列表行、相同奖励复用图标节点；原 ProgressBg 固定背景、描述与分钟格式不变，新细条使用服务端下发 progress/target 显示比例。保持现有任务窗口 HUD 行为、未完成 Claim 文本/点击语义、服务端领取幂等及任务协议；不新增 Remote 或经济状态。
V6.13 入口暂藏与解锁流畅性：
1. GameConfig 提供任务/宝箱入口的共享表现开关；客户端绑定与状态重绘遵守开关，正式 StarterGui 模板同步隐藏 HUD 入口和外观宝箱跳转。保持 MainClient 初始化、所有服务端/Remote/持久化和在线奖励行为。
2. GameConfig.ACTIVITY_RSVP_PROMPT.DelaySeconds=180；FAVORITE_PROMPT.Enabled=false。二者为现有手工维护的运营提示配置，非导表战斗/经济数值。
3. NewWeaponUnlockController 统一 Claim 与空白点击为既有 RequestWeaponUnlockReward 意图；输入需在当前弹窗打开后开始且满足点击而非拖动，动画/请求拥有独立取消与去重状态。客户端只控制视觉和重试，服务端既有按队首逐档授奖与反馈协议不变。
4. 无新增 Remote、存档或奖励数值；不删除任务/宝箱代码。验证必须覆盖点击空白、Claim、重复输入、失败重试、连续解锁和模态恢复。

V6.14 冲刺属性：
1. 数值表技能行修订为 24 studs / 0.3 秒 / 8 秒；属性养成配置新增独立键 FlashCooldown、FlashDistance，InitialCap=8、MaxCap=10，PerLevelValue=-0.4/+3。导表继续是生成段唯一来源。
2. AttributeConfig 引用同级 GameConfig 计算 FlashCooldownSeconds / FlashDistanceStuds；PlayerStateService 暴露对应只读 getter。Normalize/CopyNumberMap、RebirthService 保存和快照沿用配置驱动流程，旧档默认补齐，不迁移被禁用 Damage/MoveSpeed 的权益。
3. PlayerStateSync.attributeState.finalStats / attributeFinalStats 新增上述两个服务端数值；attributeLevels/attributeCaps 支持两项新键。沿用现有加点及上限购买 Remote；FlashFeedback.cooldownSeconds/requestedDistanceStuds 使用服务端本次计算结果，字段形状不变。RemoteNames/RemoteEventService 同步协议注释，无新增事件。
4. FlashService 请求通过玩家状态检查后读取最终属性，起冲时固定冷却/距离。边界裁剪后的射线方向与安全落点一致，避免增加距离后沿旧方向退让绕过边界墙；客户端沿用批准落点和下发冷却遮罩。
5. StarterGui.Main.AttributeUpgrade.Window.Content.StatsGrid 新增两张原样式卡片；AttributeUpgradeOut.Window.StatsList 新增两行上限卡片。保留原窗口尺寸、位置、配色与按钮样式，内部网格调整为四行两列，避免遮挡点数栏和底部文字。tools/EnsureFlashAttributes.luau 在 Edit 模式幂等创建并校验，模板 FlashAttributeVersion=2。

V6.16 任务界面样式与动效：
1. 仅客户端表现 + 正式模板。TaskController 继续只绑定 StarterGui.Main.TaskBgNew 现成节点，新增节点全部可选绑定：Tabs.*Tab.Badge.Count、CountdownPill、Template.ProgressTrack.Fill / ProgressText(PopScale) / ClaimFlash、TaskDetail.StatusText(Attribute TaskStatusChip=true)、ProgressTrack.Percent / Fill.Shine、ClaimGlow、ClaimButton.Shine、RewardTemplate.Glow、Complete.PopScale、TaskDetail.PopScale；缺失时退回 V6.12 表现。模板迁移工具 tools/EnsureTaskUiStyle.luau 升至 TaskUiStyleVersion=5，仅改属性与新增上述节点，不删除原节点。
2. 状态派生统一为 progress / ready / claimed（isClaimed 优先，其次 isClaimable），只读 TaskStateSync 既有字段；页签角标数量 = 该周期 isClaimable 且未 isClaimed 的任务数。进度比例仍用服务端 progress/target，完成态显示满格；时间类文本仍按分钟。
3. 动效分两类：一次性 motion（条目弹入、进度填充、详情回弹、角标/印章弹出、行闪白）按目标实例单 Tween 管理，关闭或重绑时取消并直接落到终态；循环 ambient（可领取 Claim 光晕/扫光、进度条扫光、奖励光芒旋转、Ready! 脉冲）以就绪目标集合为签名，签名不变的状态同步不重启，面板关闭、Claiming 等待或选中非可领取任务即停止并复位。仅面板打开时播放，关闭状态下同步直接写入终值。
4. 领取反馈：_applyStatePayload 对比前后状态，仅在面板打开时对 progress/ready -> ready/claimed 的前进变化排队；延迟 0.2 秒且面板可见才播放。ShopRewardFeedback 触发的 ClaimSuccessful 经 ModalUiController 临时隐藏任务面板时继续排队，面板 Visible 恢复后播放；关闭面板清空队列。服务端 TaskService 先 PushState 再发 ShopRewardFeedback 的顺序不变。
5. 不变项：非模态 HUD 窗口行为、未完成 Claim 文本与无效点击、Claiming 1.2 秒等待、RequestTaskClaim 仅携带 taskId、服务端幂等领取与发奖、任务配置/奖励/刷新周期、Remote 协议与存档；不新增 Remote。
V6.17 官方成就徽章：
1. BadgeConfig 从 IO_BaseBalanceDraft.xlsx 的“徽章”工作表导出 8 枚名称、说明、条件、目标、官方新 ID；UniverseId 固定当前游戏 10133052560。GetEligibleBadgeKeys 为纯条件计算；旧欢迎/订阅配置和订阅发奖入口移除。
2. BadgeAwardService 绑定 PlayerStateService/RebirthService，仅成功读档的真实 Player 可检查进度；官方拥有缓存只记录 API 返回 true，异步入队去重、有限退避，并在每次 yield 后验证玩家实例与会话有效性。GetBadgeInfoAsync 检查 IsEnabled；游戏归属在后台核验，运行时核对 game.GameId。
3. PlayerStateService 在最高等级、养成重生、真人累计击杀变化后触发 CheckProgress；RebirthService 完成读档后触发补发。FirstBossDefeated 为服务端持久事实，对应存档 firstBossDefeated；MonsterService 仅普通 Boss 击杀结算记事实，SweepForNuke 不触发。TotalPlayerKills 增加全局存档 totalPlayerKills，与现有击杀榜读档取最大值，避免不同加载顺序覆盖。
4. 新字段不进入 PlayerStateSync，徽章无客户端请求或新增 Remote。服务端不接受客户端上报达成事实/徽章 ID。RemoteNames/RemoteEventService 仅登记协议边界不变。
5. API 失败不回滚达成事实，读档失败不发、不写；旧档 Boss 标记默认为 false。Welcome 内部键保留 NewPlayerWelcome、使用新 ID，所有成功加载玩家均检查补发；旧 ID 不再发放。无效 ID=0 明确跳过。
V6.18 核弹表现：
1. NukeService._buildCinematicPayload 新增可选 serverStartTime:number，来源 Workspace:GetServerTimeNow。保留原 serverStartClock 和所有时长、付费/结算流程；客户端一次换算 os.clock 起点，后续用绝对阶段界限采样，缺 GUI/资源不能跳过 7.25 秒计划爆点。
2. NukeCinematicController 用单一 session 对象管理 camera snapshot、GUI 原态、临时模型/后处理/音效及连接；每次等待/帧回调核对 owner。cancel/Init/异常 finally 幂等清理；只当前会话恢复相机，旧回调不可恢复新镜头或提交 sweep。当前角色变化后优先绑定新 Humanoid，不还原失效主体。
3. 客户端 presentation 常量只控制镜头/FOV/震动/粒子预算/缩放，不是战斗经济数值，不修改数值表或 GameConfig.NUKE 的服务端时间配置。中心效果一次静态有界缩放，burst 分阶段发射；单独地面波展示地图覆盖。世界 ClockTime 仍归服务器，客户端只创建并销毁本会话后处理。
4. 正式 StarterGui.NukeCinematicEffects（ScreenGui，ResetOnSpawn=false，IgnoreGuiInset=true）包含 TopBar/BottomBar/ImpactFlash，默认不可见、不拦截输入；部署工具 tools/EnsureNukePresentation.luau 仅 Edit 幂等创建，不覆盖已部署手调。此为被动剧情遮罩，不是功能面板，不使用 ModalUi/Blur。
5. NukeCinematic 无其他字段/权威更改，NukeLocalMonsterSweep 仍只提交服务端签发的 sessionId/tokens；客户端表现不决定伤害、范围、货币或奖励。旧徽章/任务入口未提交改动保持。
V6.19 核弹可见性与自动弹框协调 / 2026-10-03
客户端 Controllers/CinematicUiGate 单例：Acquire(owner)->token、Release(token)、IsBlocked()、
Subscribe(callback)->Disconnect连接、Defer(key,callback)。只协调表现，不持有奖励权威或延迟状态同步。
每核弹 token 先于旧会话取消取得，保留到其爆炸、镜头和尾音/烟清理全部完成；引用计数保护连发。
Shop 的完整奖励呈现 FIFO 与 WeaponUnlock 原按 tier 队列在 gate 关闭时保留数据，开放后逐项显示；
已有弹框暂停，不代替玩家 claim 宝箱。独立自动弹框同样等待，Modal 在 gate 关闭时压住 Blur/dim/面板。
有效素材原 Enabled/Rate 控制参与 burst，EmitCount=0 不能抹掉原持续发射贡献。
爆炸视觉使用准备完成后的本地起点保证完整2s，计划爆点/token授权仍用既有服务端时间轴；清怪异常不终止表现。
无网络协议/数值表变化。
V6.20 落地帧性能 / 2026-10-04
NukeCinematicController 在预告阶段准备不在 Workspace 的已禁用爆炸实例和地面波；
落地时激活并启动视觉局部时钟，不在该帧遍历缩放完整素材。必要纹理/声音异步预载，不阻塞时间轴。
LocalMonsterController 的核弹路径逻辑清场与物理销毁分离：先快照 token 和旧对象、
移出旧怪目录并切换空目录及状态，立即发送原 sweep 意图，后续帧有界销毁旧快照。
清理只处理已移交对象，不经现行怪物映射或全局池计数，重绑/连续扫荡/复刷不会被旧清理任务污染。
普通清怪路径保持；没有 Remote 参数、结算、奖励或玩法数值变化。
V6.21 Flash 输入绑定 / 2026-10-04
FlashController 始终观察 PlayerGui 内正式 Main.Flash.Info.TextButton 的到达/替换，
合并 deferred 重绑、同节点幂等，移除旧按钮连接并恢复剩余冷却遮罩。
RequestFlash 阶段不 SuspendForFlash；收到 Started 才停止自动 MoveTo 并播放已批准的突进。
拒绝/超时不主动停止自动寻路。鼠标/触屏 Activated 与 Q/X 保持同一请求守卫。
没有 Remote、服务端方向规则、数值表或存档变化。
V6.22 Blade Breaker / 2026-10-04
TaskConfig 增加 Daily/EnemyWeaponsBroken（类型1005），任务107、目标30、宝箱101 x2；
数值表任务系统数据表添加一条类型定义和一条任务，通过 task-only 导出，原14任务不变。
CombatService 持有 TaskService 依赖，四个真实碎刃成功分支按已解析的双方 Actor 记录；
不能在碎刃后反查攻击武器：同阶第一把已销毁，仍必须为第二次实际碎刃正确归属。
TaskService.RecordEnemyWeaponBroken 校验真人来源、敌方身份/存活/场内及数据已加载，
沿用 RecordProgress、TaskState、周期刷新、状态推送和幂等宝箱领取；记录异常隔离，不改变武器对拼结果。
无新增客户端上报或 Remote，现有 TaskStateSync.taskType 新增合法配置值 EnemyWeaponsBroken。
MainServer 在 CombatService:Init 注入 TaskService；Tasks/Chests=true，正式入口可交互、面板默认关闭。
TaskChestNavigationController 仅管理 Tasks/Chests 的当前页面与返回记录，由 MainClient 创建依赖注入；
两个业务控制器的 Open/Close 统一经过导航，内部 _setNavigationOpen 不递归调用公开接口。
导航保存 Task 页签、两页签各自选中任务、CanvasPosition，过渡先立即隐藏来源，再打开目标；
关闭目标时只弹出最近一次来源并恢复，嵌套往返逐层返回；同一跳转连点按当前页面守卫去重，HUD 新开清理历史。
Task 奖励行仅 Chest 绑定点击，缓存签名纳入 rewardType/chestId，并独立清理奖励按钮连接。
Chest 初次库存同步前禁用开箱，库存为 0 后保持 Open 可点击用于导航；请求冷却防连点。
成功消费到 0 只刷新数量；仅实际开箱请求被服务端 NoChest 拒绝时发送可选拒绝原因触发导航。
ChestStateSync 可选 openRejectedReason=NoChest，不新增 Remote、不改变消耗与发奖权威。
V6.23 尾迹/宝箱配置同步 / 2026-10-04
用户数值表是本轮目录真源：trail-only导出11条，chest-only导出2箱/12条掉落。
新增1011 Boneflame -> ReplicatedStorage/Model/Trail/Trail011，IsBoxOnly=true、ExperienceBonus=0.4、SortOrder=1。
掉落池1将TrailId=1010改为1011，Weight=7、IsLimited=true；池2及其余奖项按表保留。
1010 Butter为IsBoxOnly=false，DiamondPrice=59900、RobuxPrice=599、原ProductId保留、SortOrder=11；1001排序2。
SkinService/SkinController按TrailConfig动态构建目录和BoxOpen/购买/装备按钮，无固定10条限制；
ChestService发奖和已拥有排除均按具体TrailId，旧1010拥有不视为新1011拥有。
PlayerStateService的OwnedTrails/EquippedTrailId继续沿用原动态ID映射与经验加成读取，无存档迁移。
TrailFxController按TemplatePath克隆现有Trail011并焊接角色，仅使用原客户端表现链路。
Remote名字、参数和结构不变，仅现有SkinStateSync/ChestStateSync目录包含新的配置值。
V6.24 宝箱视觉提醒 / 2026-10-04
ChestController绑定Main.Left.Box.RedPoint及正式UIScale，已同步的宝箱101库存>0时显示；
持续轻摇/呼吸Tween只在祖先Visible、ScreenGui.Enabled且CinematicUiGate未阻挡时播放。
V6.24.1取消尾迹行彩虹与白底覆盖，保留正式模板原来的静态Gradient和背景。
按实际rewardType=Trail绑定奖励ImageLabel及UIScale，循环放大至1.14倍、左右轻抖后复位停顿；
仅可见图标播放，非尾迹不播放，关闭/祖先隐藏/动画门停止并复位，重绑/销毁回收Tween/任务及监听。
库存/奖励状态同步不重置正在播放的Tween；状态权威、任务返回栈、概率与Remote不变。
V6.25 ESC 横幅 / 2026-10-04
LeaveTipsController保留现有MainClient初始化入口，改绑定StarterGui.LeaveTipsGui：
ScreenGui DisplayOrder=999、IgnoreGuiInset=true、ResetOnSpawn=false、Global层序、静态Enabled=false；
TopBanner/BottomBanner黑色Frame各高10%，锚点分别(0,0)/(0,1)，Text使用当前Your level has been saved。
基于加1陀螺OfflineBannerController的实际源码与正式GUI，只读参考其滑动、锚点几何和色相渐变算法：
0.35s Sine Out滑入、0.3s Sine In滑出；7关键点首尾同色，0.12色相周期/秒、30Hz刷新。
GuiService.MenuOpened/MenuClosed即时响应；0.2s轮询只观察MenuIsOpen变化沿，不用滞后属性覆盖事件。
独立GUI不归ModalUi所有权；CinematicUiGate隐藏并复位横幅，结束用已记录菜单意图恢复。
玩家GUI到达/替换时重绑，串号取消旧定时回调；关闭停渐变，销毁/Init回收连接和Tween。
旧Main.LeaveTips保留隐藏，停止旧文字点击/缩放入口，系统菜单继续由Roblox原生交互控制。
Remote、数值表、状态保存权威与其他项目均不变。
V6.26 等级武器皮肤 / 策划与静态UI
独立功能：正式Main.LevelWeaponSkins窗口和Main.Left.LevelWeaponSkinsButton入口，默认隐藏；
不在Skin里添加页签，不合并原Skin/Trails/Titles，不改现有控制器、武器服务或存档。
先完成Figma独立交互白图，再建立静态模板。复用Skin窗口、WeaponSkinsHeader、EquipTemplate/EquipButton及Option.Music样式；
页面包含ProgressSummary/SelectedSkinSummary/AutoUpgradeRow.CheckboxButton.Checkmark/
ScrollingFrame.LevelWeaponTemplate与40条LevelWeapon_Tn演示卡片，演示最高等级55、选中T6、默认勾选。
新窗口的Content与独立HUD入口均为待接线静态节点，预览只在Edit用隔离GUI副本展示。
销毁预览不改正式页面Visible状态；未来窗口注册独立ModalUi所有权LevelWeaponSkins。
后续实现规划（本轮不落地）：从HighestLevelReached与WeaponTierConfig.Order派生永久解锁，
持久化SelectedLevelWeaponTierIndex与AutoUpgradeLevelWeaponSkin（缺省true，显式false保留）。
外观源Default/LevelWeapon/SpecialSkin互斥；等级自动模式按每个槽位max(手选档,实际可见档)解析，
固定模式按手选档解析，特殊皮肤仍沿用现有EquippedSkinId；实际伤害/数量/CombatRank/Aura不变。
未来新增独立LevelWeaponSkinService/LevelWeaponSkinController，接PlayerStateService/RebirthService/WeaponService；
等级外观的目录、请求和UI不复用旧SkinController页面或旧皮肤装备请求。实际外观源互斥由共享武器解析层处理。
协议另行四处登记。
详细规则、旧存档迁移、状态文案和接线节点见等级武器皮肤策划文档.lua。本轮无数值表或Remote变化。
V6.27 等级武器皮肤正式接线 / GM入口 / 2026-10-04
PlayerStateService新增持久化字段：SelectedLevelWeaponTierIndex（nil或1-40，读取归一化时按
HighestLevelReached校验已解锁，越界/未解锁回nil）与AutoUpgradeLevelWeaponSkin（缺省true，仅显式false为false）；
PlayerStateSync新增只读selectedLevelWeaponTierIndex/levelWeaponSkinAutoUpgrade字段。
装备互斥：EquipLevelWeaponSkin清除EquippedSkinId（不清拥有）；EquipSkin清除SelectedLevelWeaponTierIndex；
UseLevelWeaponLook清除手选+恢复自动+清除特殊皮肤装备；SetLevelWeaponAutoUpgrade(false)且无手选时
服务端把当前已解锁最高档设为基础外观。四个接口均MarkDirty+PushState+RebuildWeaponsForActor即时重算。
外观解析：WeaponService._createWeaponState在EquippedSkinId特殊皮肤优先之后，调用
PlayerStateService:GetLevelWeaponVisualConfig(actor, tierConfig)逐槽解析——自动开启时槽位实际档高于手选档
则用实际档模板（保持逐把换刃节奏），否则用手选档模板；自动关闭恒用手选档；无手选返回nil走默认档位模板。
VisualSkinId仅特殊皮肤设置；VisualTemplateName/VisualIconImage随等级外观换档；命中判定、伤害、数量、
CombatRank、Aura继续来自实际档位模板（copyAuraShape用baseTemplate），外观不扩大判定范围。
持久化：RebirthService存档payload新增selectedLevelWeaponTierIndex/autoUpgradeLevelWeaponSkin两键，
读档normalizeSavedData归一化后经SetRebirthData回填；无迁移，旧档默认无手选+自动true。
新增LevelWeaponSkinService（ServerScriptService/Services）：四个Remote（State/Sync请求/Equip意图/Feedback），
校验数据已加载、按玩家+请求类型0.2s限频、档序号1-40整数且按服务端HighestLevelReached已解锁、
autoUpgrade严格boolean；拒绝路径Feedback(Failed,reason)+回推权威状态；进服加载完成后推送状态。
新增LevelWeaponSkinController（StarterPlayerScripts/Controllers）：绑定既有Main.LevelWeaponSkins静态窗口，
重新启用模板阶段禁用的Close/Equip/UseLevelLook/Checkbox按钮，按服务端状态渲染40卡片三态、进度/已选文案
与自动勾选；目录名称/图标/解锁等级直接读ReplicatedStorage.Shared.WeaponTierConfig，不随事件下发。
窗口开关走ModalUiController所有权LevelWeaponSkins（压制同级+Blur+动效，核弹门自动挂起）。
入口（暂时）：Studio-only GM聊天/levelskin [on|off]设置玩家Attribute StudioLevelSkinUiPreview
（RemoteNames.StudioAttributes.LevelSkinUiPreview），控制器监听本玩家该属性开/关窗口；
Main.Left.LevelWeaponSkinsButton常驻HUD入口保持隐藏，后续开放再走正式按钮绑定。
远程契约详见RemoteEvent当前列表.lua三-补6；数值表无变化。
]]
