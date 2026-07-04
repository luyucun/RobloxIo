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
- 配置 Roblox Experience Event 活动预约系统弹窗，当前 `EventId = "1688050057217180267"`，玩家进服 90 秒后由服务端请求客户端调起官方 RSVP Prompt；客户端会先查询 RSVP 状态，已 `Going` 的玩家不再弹出取消预约弹窗。
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
14.`LeaderboardService`
- 构建单服排行榜，读写全局 OrderedDataStore，广播 `LeaderboardSync`。
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
- Studio GM 支持 `/chestadd <chestId> <amount>`、`/addbox101 <amount>`、`/chestclear [chestId]`、`/chestopen <chestId> <one|all>`，线上拒绝执行。
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
12.`BossService:Init`
13.`LeaderboardService:Init`
14.`ArenaProgressService:Init`
15.`NukeService:Init`
16.`SpecialEventService:Init`
17.`PlayerStateService:BindSystems`
18.`BotService:BindSystems`

七、关键路径
1.玩家入场：
`PlayerAdded -> PlayerStateService:OnPlayerAdded -> CharacterAdded -> ArenaService:TeleportPlayerToSpawnLocation -> 触碰 Map2.Portals.Portal -> PortalJoinPrompt(Show) -> JoinGameController 显示 StarterGui/Main/JoinGame、隐藏其它 Main UI、开启 Lighting.Blur -> 点击 Join -> RequestJoinBattle(Join) -> ArenaService 校验已触发 Portal 弹窗且入场确认资格仍在 8 秒有效期内 -> TryEnterArena -> PlayerStateService:SetInArena(true) -> 首次成功进战场发 60 秒护盾、复活进战场发 10 秒护盾 -> WeaponService:RebuildWeaponsForPlayer`
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
`BossService:_step -> MonsterService:SpawnMonster(IsBoss) -> Boss 死亡 -> DropExperience + BuffService:DropBuffs -> BuffService:ApplyDamageBuff`
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
`PlayerAdded -> OnlineRewardService:OnPlayerAdded 记录 StartedAt -> OnlineRewardStateSync -> OnlineRewardController 更新 Main.Right.Online 倒计时/红点和 Main.OnlineReward 奖励列表 -> RequestOnlineRewardClaim -> OnlineRewardService 校验在线秒数和已领取状态 -> 发放奖励 -> ShopRewardFeedback -> ShopController 播放 Main.ClaimSuccessful；UnlockAll 购买成功由 RebirthService.ProcessReceipt 委托 OnlineRewardService 解锁本轮全部奖励。`
13.1.七日登录奖励：
`PlayerAdded -> SevenDayLoginRewardService:OnPlayerAdded 等待玩家数据加载 -> SevenDayLoginRewardStateSync(hasClaimableReward) -> SevenDayLoginRewardController 显示 TopRight.SevenDays 红点，并在本次会话内对新的 cycleId/dayIndex 可领奖励自动打开 Main.Sevendays 或 Main.SevendaysRepeat 一次 -> RequestSevenDayLoginRewardClaim -> SevenDayLoginRewardService 服务端校验并发奖。`
14.好友邀请提示：
`InviteTipsController -> 玩家在线 2 分钟后请求 FriendsRankingStateSync -> 客户端刷新 GetFriendsOnlineAsync -> 从“曾玩过本体验且当前在线”的好友中按 highestLevelReached 选择最高者 -> 显示 PlayerGui.Main.InviteTips 5 秒 -> 点击 InviteButton 后用 ExperienceInviteOptions.InviteUser 调起 SocialService:PromptGameInvite；本次登录已弹过的好友不再重复弹出，之后每 5 分钟继续检查剩余候选。`
15.活动预约提示：
`PlayerAdded -> ActivityRsvpPromptService 延迟 90 秒 -> PromptActivityRsvp -> ActivityRsvpPromptController 查询 SocialService:GetEventRsvpStatusAsync("1688050057217180267") -> 未 Going 时调用 SocialService:PromptRsvpToEventAsync -> ActivityRsvpPromptStarted / ActivityRsvpPromptResult 回传服务端埋点；已 Going 时直接回传 AlreadyGoing 且不弹系统取消预约弹窗。`
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
6.`JoinGameController` 负责监听 `PortalJoinPrompt(Show/Hide)`，显示/隐藏 `StarterGui/Main/JoinGame`；显示时隐藏 `PlayerGui.Main` 下除 `JoinGame` 外的同级 UI 并开启 `Lighting.Blur`，关闭时恢复；绑定 `Join` 和 `Wait` 按钮缩放反馈，并在点击 Join/Wait 时分别发送 `RequestJoinBattle(Join/Cancel)`。服务端在 `PortalJoinPrompt(Show)` 后保留 8 秒入场确认资格，避免玩家轻微离开 Portal 范围后点击 Join 被误拦截。 `Join` 只有在服务端真正传送成功后才会关闭弹窗，失败则保留当前弹窗状态。
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
17.`ChestController` 负责 V5.9 宝箱面板，仅绑定既有 `StarterGui/Main/ChestRewards` 和 `Main.Left.Box`；首版固定展示宝箱 `101`，刷新 `CountText = You have: xx`、入口数量气泡、`Window.CountdownTime` 每周六北京时间 20:00 的手动内容更新说明倒计时，以及右侧掉落列表，点击 `OpenOneButton` / `OpenAllButton` 只发送开箱意图。开箱成功反馈返回后，客户端临时创建 `Main.ChestOpenEffect` 居中展示宝箱和 `rbxassetid://1598630577` 光圈，自动抖动结束后再进入通用领奖弹框；宝箱奖励真正发放由 `ShopController` 在玩家关闭该弹框后发送 `RequestChestRewardClaim` 触发。倒计时只展示 `Rewards Refresh In: xx:yy` 文案，不触发宝箱池自动刷新。
18.`SkinController` 的尾迹页消费 `SkinStateSync.trails[]` 的 `sortOrder`、`isBoxOnly`、`experienceBonus`：按排序字段显示，`TrailRowTemplate.Add` 显示 `Exp*1.x`，未拥有的宝箱尾迹只显示 `BoxOpen` 并打开 `ChestRewards`。
19.`PotionController` 的 `LuckLabel` 继续显示服务端 `totalExperienceMultiplier`，`Tooltip.Trail` 显示 `Trail:Exp*1.x`，没有尾迹加成时显示 `Trail:Exp*1`。
20.`GameNewsController` 负责绑定 `StarterGui/Main/TopRightGui/Log` 到既有 `Main.GameNews` 面板；点击 `Log.Button` 打开公告界面，点击 `GameNews.CloseButton` 关闭，打开/关闭复用 `ModalUiController` 的模态遮罩、Blur 和面板动效，不新增 RemoteEvent。
21.Studio-only GM `/testinvite` / `/invitetips` 由 `GMCommandService` 随机抽取当前玩家好友，经 `FriendsRankingStateSync` 发送 `studioInviteTipsTest = true` 测试 payload，客户端仅在 `RunService:IsStudio()` 下直接弹出 `Main.InviteTips`；V5.3 额外提供 `/taskprogress <taskId> <amount>`、`/taskcomplete <taskId>`、`/taskreset daily|weekly|all` 便于编辑器测试任务进度和周期重置。V5.9 额外提供 `/chestadd <chestId> <amount>`、`/addbox101 <amount>`、`/chestclear [chestId]`、`/chestopen <chestId> <one|all>`。

=====================================================
文档结束
=====================================================
]]
