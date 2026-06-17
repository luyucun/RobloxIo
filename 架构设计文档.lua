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
4.`OnlineRewardConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 在线奖励` 同步在线奖励定义，包含奖励类型、数量、图标和本轮所需在线秒数；当前通过 `tools/SyncCodeConfigFromWorkbook.py` 与兑换码配置一起刷新。
5.`MonsterCatalog`
- 由 `IO_BaseBalanceDraft.xlsx / 怪物基础信息草稿` 同步怪物定义，包含模板、权重、击杀积分、基础战斗数值、经验和动画配置。
- 普通小怪随机池由 `TypeName = 普通小怪` 且 `SpawnWeight > 0` 的定义组成；当前为 `Monster001`-`Monster007`。
6.`SpecialEventConfig`
- 由 `IO_BaseBalanceDraft.xlsx / 特殊事件` 同步特殊事件定义，包含事件 ID、名字、权重、客户端场景路径、事件板文本名和持续时间。
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
- `GrantShield` 只负责护盾时长叠加与表现同步，护盾时长由入场入口决定，不改动原有叠加规则。
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
- V2.2 只做事件场景与事件板表现，不生成 Boss。
17.`OnlineRewardService`
- 管理 V4.3 本次在线会话奖励计时、状态同步、领取发奖、ClaimSuccessful 奖励弹框回传，以及 UnlockAll 开发者商品 `3599440996` 的收据处理；玩家离开后在线计时重置，不写入持久化会话进度。
- 发经验奖励时走 `PlayerStateService:AddExperienceWithMultiplier`，其它奖励复用对应现有服务链路。
18.`TaskService`
- 管理 V5.3 每日/每周任务，任务配置由 `IO_BaseBalanceDraft.xlsx / 任务系统数据表` 同步生成 `TaskConfig`；每日按 UTC 0 点重置，每周按周一 UTC 0 点重置。
- 服务端权威维护 `state.TaskState` 的周期 key、progress、claimed、weekly login days 和 completed reported；监听在线时长、真实玩家击杀、转盘使用、钻石获得、登录天数、邀请弹窗打开等进度来源。
- 领奖时校验任务存在、周期有效、进度达标且未领取，再发放钻石、转盘次数、经验或药水；奖励反馈复用 `ShopRewardFeedback -> Main.ClaimSuccessful`，任务来源使用 0.8 秒后可点击关闭。
19.归档服务：
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
`SpecialEventService:_step -> 按权重生成当前事件和未来两场 -> SpecialEventSync -> SpecialEventController 本地克隆 ReplicatedStorage/EventScene/<事件> 到 Workspace -> 更新 BattleSenceEventBoard / HomeEventBoard 倒计时 -> 事件结束后客户端清理本地克隆`
13.在线奖励：
`PlayerAdded -> OnlineRewardService:OnPlayerAdded 记录 StartedAt -> OnlineRewardStateSync -> OnlineRewardController 更新 Main.Right.Online 倒计时/红点和 Main.OnlineReward 奖励列表 -> RequestOnlineRewardClaim -> OnlineRewardService 校验在线秒数和已领取状态 -> 发放奖励 -> ShopRewardFeedback -> ShopController 播放 Main.ClaimSuccessful；UnlockAll 购买成功由 RebirthService.ProcessReceipt 委托 OnlineRewardService 解锁本轮全部奖励。`
14.好友邀请提示：
`InviteTipsController -> 玩家在线 2 分钟后请求 FriendsRankingStateSync -> 客户端刷新 GetFriendsOnlineAsync -> 从“曾玩过本体验且当前在线”的好友中按 highestLevelReached 选择最高者 -> 显示 PlayerGui.Main.InviteTips 5 秒 -> 点击 InviteButton 后用 ExperienceInviteOptions.InviteUser 调起 SocialService:PromptGameInvite；本次登录已弹过的好友不再重复弹出，之后每 5 分钟继续检查剩余候选。`
15.每日/每周任务：
`TaskConfig -> TaskService 初始化并规范化 PlayerState.TaskState -> PlayerStateService/WheelService/InviteTipsController 等来源上报进度 -> TaskStateSync -> TaskController 渲染 Main.Right.Daily 红点、Main.TaskBg 列表和重置倒计时 -> RequestTaskClaim -> TaskService 校验并发奖 -> ShopRewardFeedback -> ShopController 播放 Main.ClaimSuccessful。Studio GM /taskprogress、/taskcomplete、/taskreset 仅在 RunService:IsStudio() 下可用。`

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

九、客户端约束
1.客户端不决定经验、等级、伤害、击杀、死亡、武器胜负、Buff 是否生效。
2.正式 HUD / 提示 / 面板 UI 应放在 StarterGui，客户端控制器只绑定既有节点、更新数据和播放动画。
3.功能型面板打开时统一走模态 UI：隐藏 `PlayerGui.Main` 下除当前面板外的其他同级 `GuiObject`，开启 `Lighting.Blur`，关闭动效结束后恢复原始显示状态和 Blur 状态；打开和关闭都必须播放面板动效。
4.`PlayerStateService` 负责角色头顶血条的创建和同步，只有 `Alive = true` 且 `IsInArena = true` 时显示；准备区、死亡或退出战斗状态时隐藏。
5.当前已实现客户端控制器为 `WeaponFxController`，负责隐藏真实玩家服务端武器视觉、按 `ownerUserId` 为本地和远端玩家创建本地视觉武器并按同步数据绕对应玩家旋转。
6.`JoinGameController` 负责监听 `PortalJoinPrompt(Show/Hide)`，显示/隐藏 `StarterGui/Main/JoinGame`；显示时隐藏 `PlayerGui.Main` 下除 `JoinGame` 外的同级 UI 并开启 `Lighting.Blur`，关闭时恢复；绑定 `Join` 和 `Wait` 按钮缩放反馈，并在点击 Join/Wait 时分别发送 `RequestJoinBattle(Join/Cancel)`。服务端在 `PortalJoinPrompt(Show)` 后保留 8 秒入场确认资格，避免玩家轻微离开 Portal 范围后点击 Join 被误拦截。 `Join` 只有在服务端真正传送成功后才会关闭弹窗，失败则保留当前弹窗状态。
7.`SpecialEventController` 负责监听 `SpecialEventSync`，按服务端状态在客户端本地复制/移除特殊事件场景，并同步 `Workspace.Map2.BattleSenceEventBoard` 与 `Workspace.Map2.HomeEventBoard` 的事件倒计时文本。
8.`ArenaProgressController` 负责监听 `ArenaProgressSync` 和本地 `PlayerStateSync`，只有本地玩家在战场且存活时显示 `PlayerGui.Main.Progress`，并按服务端同步的场内玩家等级区间渲染头像位置。
9.`TopStatsController` 负责监听 `PlayerStateSync`，以原始整数显示永久击杀数和钻石数，并在钻石增加时播放客户端飞入动画；客户端不决定数值增减。
10.`ShopController` 负责商店页面打开/关闭、购买入口绑定、领奖弹框表现，以及商店 Skin 商品名称上 `Secret1` / `Secret2` 渐变的首尾衔接循环流动。
11.`DefeatedController` 负责监听 `DeathFeedback` 打开 Defeated 面板，隐藏倒计时 UI，展示免费半等级复活目标等级，并通过 Marketplace 产品信息实时刷新 Revenge / Revive 的 RMoney 价格。
12.`DefeatedController` 点击 FreeRespawn、Lobby、Close、Revive、Revenge 时只发送意图或触发购买；复活等级、复仇目标、离线快照和是否允许 Revenge 均由服务端判定。
13.`LocalMonsterController` 负责普通小怪本地私有生成和显示：所有生成小怪均物化为所属客户端可见模型，Dormant 小怪保持静默可见，只有 CombatActive 小怪参与追击、攻击、动画和模拟预算。
14.`InviteTipsController` 负责 V5.2 好友邀请提示，仅绑定既有 `StarterGui/Main/InviteTips`，复用 `FriendsRankingStateSync` 的历史好友数据和客户端 `GetFriendsOnlineAsync` 在线状态，不新增 RemoteEvent、不启用模态遮罩或 Blur。
15.`TaskController` 负责 V5.3 任务面板，仅绑定既有 `StarterGui/Main/TaskBg` 和 `Main.Right.Daily`；面板打开/关闭使用本地 `UIScale + TweenService`，不走模态遮罩、不隐藏其它 HUD、不启用 Blur。任务列表按可领取、未完成、已领取排序，领取请求只发 taskId，最终发奖由服务端判定。
16.Studio-only GM `/testinvite` / `/invitetips` 由 `GMCommandService` 随机抽取当前玩家好友，经 `FriendsRankingStateSync` 发送 `studioInviteTipsTest = true` 测试 payload，客户端仅在 `RunService:IsStudio()` 下直接弹出 `Main.InviteTips`；V5.3 额外提供 `/taskprogress <taskId> <amount>`、`/taskcomplete <taskId>`、`/taskreset daily|weekly|all` 便于编辑器测试任务进度和周期重置。

=====================================================
文档结束
=====================================================
]]
