--[[
=====================================================
RemoteEvent 当前列表（V3.0 当前实现同步版）
=====================================================

文档更新时间: 2026-04-26
同步依据: RemoteNames.lua、RemoteEventService.lua 和各 Service 当前调用。

一、事件树
ReplicatedStorage
- Events
  - SystemEvents
    - PlayerStateSync
    - RequestPlayerStateSync
    - ArenaTransitionFeedback
    - DeathFeedback
    - StudioBotCommand
    - LevelUpFeedback
    - PortalJoinPrompt
- RequestJoinBattle
- RequestRebirth
- RebirthFeedback
    - RequestDefeatedAction
    - RequestPotionAction
    - PotionFeedback
    - SpecialEventSync
    - RequestSpecialEventSync
    - RequestCodeRedeem
    - CodeRedeemFeedback
    - OnlineRewardStateSync
    - RequestOnlineRewardStateSync
    - RequestOnlineRewardClaim
    - RequestFriendsRankingStateSync
    - FriendsRankingStateSync
    - TaskStateSync
    - RequestTaskStateSync
    - RequestTaskClaim
    - RequestInviteTaskProgress
    - ChestStateSync
    - RequestChestStateSync
    - RequestChestOpen
    - RequestChestRewardClaim
    - PromptFavoritePlace
    - FavoritePlacePromptStarted
    - FavoritePlacePromptResult
    - PromptActivityRsvp
    - ActivityRsvpPromptStarted
    - ActivityRsvpPromptResult
  - BattleEvents
    - PickupFeedback
    - ExperienceFeedback
    - LocalMonsterSpawnToken
    - LocalMonsterKilled
    - LocalMonsterHitPlayer
    - WeaponStateSync
    - CombatFeedback
    - BuffFeedback
    - BossFeedback
    - LeaderboardSync
    - ArenaProgressSync
    - NukeCinematic
    - NukeLocalMonsterSweep

二、PlayerStateSync（S -> C）
发送方：`PlayerStateService:PushState`
触发：玩家加入、角色生成、请求同步、进出战斗区、升级、血量变化、武器状态变化、Buff 变化等。
字段：
- level
- highestLevelReached
- experience
- nextLevelExperience
- currentHealth
- maxHealth
- moveSpeed
- weaponTier
- weaponTierIndex
- weaponCount
- weaponIcon
- desiredWeaponTier
- desiredWeaponTierIndex
- desiredWeaponCount
- desiredWeaponIcon
- killCount
- totalPlayerKills
- rebirth
- rebirthScore
- nextRebirthScore
- rebirthExperienceBonus
- diamonds
- potions
- activePotion
- potionExperienceBonus
- potionMoveSpeedBonus
- chests
- trailExperienceBonus
- totalExperienceMultiplier
- isInArena
- alive
- buffs
- timestamp
说明：
- `killCount` 为局内击杀数，死亡重置战斗状态时可清零。
- `totalPlayerKills` 为 V2.5 顶部 HUD 显示的永久玩家击杀数。
- `diamonds` 为 V2.5 顶部 HUD 显示的钻石货币数量。
- `chests` 为 V5.9 宝箱持久化数量表，key 为宝箱 ID 字符串。
- `trailExperienceBonus` 为当前装备尾迹带来的额外经验加成，不装备尾迹时为 0。

三、RequestPlayerStateSync（C -> S）
接收方：`PlayerStateService:Init`
用途：客户端请求重新下发自身状态。
当前处理：服务端收到后执行 `PushState(player)`。

三-补、兑换码系统 RemoteEvent（V4.2）

RequestCodeRedeem（C -> S）
发送方：`CodeController`
接收方：`CodeService`
用途：玩家点击 `StarterGui.Main.Codes.Use` 后提交兑换码。
字段：
- code

CodeRedeemFeedback（S -> C）
发送方：`CodeService`
接收方：`CodeController`
用途：通知兑换结果。成功奖励弹框继续复用 `ShopRewardFeedback` 和 `Main.ClaimSuccessful`。
字段：
- success
- message
- timestamp

三-补2、在线奖励系统 RemoteEvent（V4.3）

OnlineRewardStateSync（S -> C）
发送方：`OnlineRewardService:PushState`
接收方：`OnlineRewardController`
用途：同步本次在线会话的奖励倒计时、可领取状态、已领取状态、UnlockAll 商品 ID 和是否可购买。
字段：
- rewards
- elapsedSeconds
- serverTimestamp
- hasClaimableReward
- allClaimed
- productId
- canUnlockAll
- claimedRewardCount

RequestOnlineRewardStateSync（C -> S）
发送方：`OnlineRewardController`
接收方：`OnlineRewardService`
用途：打开 `Main.OnlineReward` 或购买完成后请求刷新在线奖励状态。
字段：无。

RequestOnlineRewardClaim（C -> S）
发送方：`OnlineRewardController`
接收方：`OnlineRewardService`
用途：玩家点击 `OnlineReward.Bg.RewardTemplate.Claim` 克隆项领取单个在线奖励。
字段：
- rewardIndex

三-补3、好友榜系统 RemoteEvent（V4.5）

RequestFriendsRankingStateSync（C -> S）
发送方：`FriendsRankingController`
接收方：`FriendsRankingService`
用途：玩家打开 `StarterGui.Main.FriendsRanking` 时请求好友榜数据。服务端收到后由当前 `Player` 调用 `GetFriendsWhoPlayedAsync()` 取得“玩过本体验的好友”UserId 列表，不信任客户端传入好友 ID。
字段：无。

FriendsRankingStateSync（S -> C）
发送方：`FriendsRankingService`
接收方：`FriendsRankingController`、`InviteTipsController`
用途：同步好友榜列表和 TopSummary 自身数据；V5.2 好友邀请提示复用 rows 中的曾玩过本体验好友数据，不新增 RemoteEvent。
字段：
- rows：好友行数组，每项包含 userId、name、highestLevelReached、totalPlayerKills、playtimeSeconds
- self：自身信息，包含 userId、name、highestLevelReached、totalPlayerKills、friendBonusPercent
- throttled
- timestamp
说明：
- `InviteTipsController` 会在客户端结合 `LocalPlayer:GetFriendsOnlineAsync(200)` 过滤出当前在线好友，再按 `highestLevelReached` 选择本次登录未弹过的候选。
- 点击 `StarterGui.Main.InviteTips.InviteButton` 后直接使用 Roblox 官方 `SocialService:PromptGameInvite` 和 `ExperienceInviteOptions.InviteUser` 调起定向邀请；V5.3 仅在官方弹窗成功打开后额外发送 `RequestInviteTaskProgress`，用于每日邀请任务进度。
- Studio GM `/testinvite` / `/invitetips` 会随机抽取当前玩家好友，构造 `studioInviteTipsTest = true` 的单行测试 payload，经本事件发给触发者，仅用于编辑器内验证 `Main.InviteTips` 弹窗。

三-补4、每日/每周任务系统 RemoteEvent（V5.3 / V5.8）

TaskStateSync（S -> C）
发送方：`TaskService:PushState`
接收方：`TaskController`
用途：同步服务端权威的每日/每周任务进度、领取状态、短文本、多奖励、重置倒计时和红点状态。
字段：
- tasks.daily / tasks.weekly：任务数组，每项包含 taskId、period、taskType、target、progress、rewardType、potionId、amount、description、shortTitle、shortDescription、icon、rewards、isComplete、isClaimed、isClaimable；rewards 为 1 到多个奖励项数组，每项包含 rewardType、potionId、amount、icon。rewardType / potionId / amount / icon 仍保留为第一个奖励的兼容字段。
- dailyCycleKey / weeklyCycleKey
- dailyResetAt / weeklyResetAt
- serverTimestamp
- hasClaimableReward
- weeklyLoginDays

RequestTaskStateSync（C -> S）
发送方：`TaskController`
接收方：`TaskService`
用途：客户端初始化、打开 `Main.TaskBgNew` 或重建 UI 后请求任务状态刷新。
字段：无。

RequestTaskClaim（C -> S）
发送方：`TaskController`
接收方：`TaskService`
用途：玩家点击任务详情的 `ClaimButton` 后请求领奖；服务端校验任务存在、周期有效、进度达标且未领取，再逐项发放该任务的 rewards 奖励。
字段：
- taskId

RequestInviteTaskProgress（C -> S）
发送方：`InviteTipsController`
接收方：`TaskService`
用途：V5.2 邀请弹窗成功调用 Roblox 官方 `PromptGameInvite` 后，给邀请好友任务增加一次进度；服务端仍按任务目标上限截断。
字段：无。

三-补5、宝箱系统与尾迹扩展 RemoteEvent（V5.9）

ChestStateSync（S -> C）
发送方：`ChestService:PushState`
接收方：`ChestController`
用途：同步服务端权威宝箱数量、当前首版展示宝箱 ID 和宝箱掉落配置；首版客户端固定展示并开启 `101`，`102` 仅完成配置与服务端能力。
字段：
- chests：宝箱数量表，key 为宝箱 ID 字符串，value 为数量。
- selectedChestId：首版固定为 101。
- chestConfigs：客户端展示用宝箱配置数组，每项包含 id、icon、dropPoolId、rewards；rewards 每项包含 rewardType、potionId、trailId、amount、weight、isLimited。
- timestamp

RequestChestStateSync（C -> S）
发送方：`ChestController`
接收方：`ChestService`
用途：客户端初始化、打开 `Main.ChestRewards` 或重建 UI 后请求刷新宝箱数量与掉落配置。
字段：无。客户端可传 chestId，但服务端不信任该字段做状态裁剪。

RequestChestOpen（C -> S）
发送方：`ChestController`
接收方：`ChestService`
用途：玩家点击 `OpenOneButton` 或 `OpenAllButton` 后请求开宝箱；服务端只信任 `chestId` 和 `mode`，自行校验数量、抽奖、扣除宝箱并记录待领取奖励。
字段：
- chestId：首版客户端发送 101。
- mode：`One` 或 `All`。
说明：
- 开箱奖励支持 `Diamonds`、`WheelSpins`、`Potion`、`Trail`。
- 宝箱数量和开箱结果都由服务端校验并同步，不复用 Shop/Skin/Task 远程。
- 奖励展示反馈继续复用 `ShopRewardFeedback`，payload 带 `rewardClaimId` 和 `requiresClaim = true`；客户端收到 `source = "Chest"` 的成功反馈后先播放居中宝箱抖动和 `rbxassetid://1598630577` 光圈表现，再进入 `Main.ClaimSuccessful`，`closeDelay = 0.5`，且不会关闭 `Main.ChestRewards`。

RequestChestRewardClaim（C -> S）
发送方：`ShopController`
接收方：`ChestService`
用途：宝箱来源的 `Main.ClaimSuccessful` 奖励弹框被玩家点击关闭后，通知服务端发放对应待领取奖励；关闭前只展示已抽中的奖励内容，不实际增加钻石、转盘次数、药水或尾迹。
字段：
- rewardClaimId：来自 `ShopRewardFeedback.rewardClaimId`。
说明：
- 服务端按玩家和 `rewardClaimId` 校验 pending 记录，重复或错误 claim 不会重复发奖。
- 玩家离开时若仍有 pending 宝箱奖励，服务端会兜底发放一次并清理开箱锁。

SkinStateSync / PlayerStateSync 尾迹扩展（V5.9）
用途：尾迹列表与经验倍率展示扩展。
字段：
- `SkinStateSync.trails[]` 新增 `sortOrder`、`isBoxOnly`、`experienceBonus`。
- `PlayerStateSync` 新增 `chests`、`trailExperienceBonus`，并且 `totalExperienceMultiplier` 已包含当前装备尾迹的经验加成。
说明：
- 未拥有且 `isBoxOnly=true` 的尾迹隐藏钻石/Robux 购买按钮，显示 `TrailRowTemplate.BoxOpen`，点击打开 `Main.ChestRewards`。
- `RewardType = "Chest"` 可被任务、兑换码、在线奖励、七日登录奖励等通用奖励入口复用，字段为 `ChestId`、`Amount`、`Icon`、`Label`。

三补、收藏游戏系统 Prompt RemoteEvent（V5.7）
PromptFavoritePlace（S -> C）
发送方：`FavoritePlacePromptService`
接收方：`FavoritePlacePromptController`
用途：玩家进服一段时间后请求客户端调起 Roblox 系统收藏游戏弹窗。客户端会先查询 `AvatarEditorService:GetFavoriteAsync(placeId, Enum.AvatarItemType.Asset)`，已收藏时直接回传 `AlreadyFavorite`，不再打开系统弹窗。
字段：
- requestId
- placeId
- timestamp

FavoritePlacePromptStarted（C -> S）
发送方：`FavoritePlacePromptController`
接收方：`FavoritePlacePromptService`
用途：客户端成功打开收藏游戏系统弹窗后通知服务端记录本日已提示。
字段：
- requestId
- placeId
- timestamp

FavoritePlacePromptResult（C -> S）
发送方：`FavoritePlacePromptController`
接收方：`FavoritePlacePromptService`
用途：客户端回传收藏游戏系统弹窗结果；`Success` 或 `AlreadyFavorite` 会使服务端写入并立即保存 `FavoritePromptState.HasFavorited = true`。
字段：
- requestId
- placeId
- result
- timestamp

三补、活动预约系统 Prompt RemoteEvent（V5.6）
PromptActivityRsvp（S -> C）
发送方：`ActivityRsvpPromptService`
接收方：`ActivityRsvpPromptController`
用途：玩家进服一段时间后请求客户端调起 Roblox 官方 Experience Event RSVP 系统弹窗。当前活动 ID 为 `1688050057217180267`，客户端会先查询 RSVP 状态，已 `Going` 时不再弹出取消预约弹窗。
字段：
- requestId
- eventId
- timestamp

ActivityRsvpPromptStarted（C -> S）
发送方：`ActivityRsvpPromptController`
接收方：`ActivityRsvpPromptService`
用途：客户端准备调用 `SocialService:PromptRsvpToEventAsync` 前回传当前 RSVP 状态，便于埋点和排查。
字段：
- requestId
- eventId
- currentStatus
- statusError
- timestamp

ActivityRsvpPromptResult（C -> S）
发送方：`ActivityRsvpPromptController`
接收方：`ActivityRsvpPromptService`
用途：客户端调用活动预约系统弹窗后的结果回传；服务端仅记录埋点，不信任客户端发奖或改核心状态。
字段：
- requestId
- eventId
- success
- result
- previousStatus
- currentStatus
- error
- skipped
- timestamp

四、ArenaTransitionFeedback（S -> C）
发送方：`ArenaService:_fireTransitionFeedback`
用途：进入战斗区、返回出生点、进入失败等反馈。
字段：
- status
- spawnMode
- timestamp
当前 status 示例：
- EnterBattle
- ReturnHome
- Blocked
当前 spawnMode 示例：
- RandomBattleSpawn
- SpawnLocation
- BattleUnavailable
- Debounced
- CharacterNotReady
- SpawnNotFound

五、DeathFeedback（S -> C）
发送方：`HealthService:_fireDeathFeedback`
用途：玩家死亡反馈，仅发给被击杀玩家。
字段：
- reason
- killerUserId
- killer：`{ userId, name, level, killCount, totalPlayerKills }`
- victimLevel
- freeRespawnLevel
- timestamp
当前 reason 固定为 `WeaponDamage`。

六、LevelUpFeedback（S -> C）
发送方：`PlayerStateService:_fireLevelUpFeedback`
用途：玩家升级反馈。
字段：
- previousLevel
- newLevel
- maxHealth
- weaponTier
- weaponTierIndex
- weaponCount
- weaponIcon
- desiredWeaponTier
- desiredWeaponTierIndex
- desiredWeaponCount
- desiredWeaponIcon
- timestamp

七、PortalJoinPrompt（S -> C）
发送方：`ArenaService:_firePortalJoinPrompt`
触发：玩家角色与 `workspace.Map2.Portals.Portal` 模型任意 BasePart 碰撞，且玩家尚未在战斗区。
用途：通知该玩家客户端显示或关闭 `StarterGui/Main/JoinGame` 入场确认弹框。显示时客户端隐藏 `PlayerGui.Main` 下除 `JoinGame` 外的同级 UI，并开启 `Lighting.Blur`；关闭时恢复。
字段：
- eventType
- timestamp
当前 eventType：
- Show
- Hide

八、RequestJoinBattle（C -> S）
接收方：`ArenaService:_onRequestJoinBattle`
触发：玩家点击 `JoinGame.Join` 或 `JoinGame.Wait`。
用途：`Join` 请求服务端把玩家传送进 `workspace.Battle`；`Cancel` 取消本次 Portal 待确认状态。服务端只接受已经触发过 PortalJoinPrompt 且入场确认资格仍在有效期内的 Join 请求。 `Join` 只有在服务端实际进入战场成功后才会关闭弹窗。
字段：
- action：`Join` 或 `Cancel`

九、ExperienceFeedback（S -> C）
发送方：`ExperienceOrbService:_fireExperienceFeedback`
用途：服务端完成经验结算后，通知击杀者客户端播放本地经验块掉落/吸附表现，并同步最新经验状态。
字段：
- eventType
- dropId
- amount
- orbCount
- valuePerOrb
- originPosition
- orbs
- level
- experience
- nextLevelExperience
- timestamp
当前 eventType：
- ExperienceDrop
orbs 子字段：
- index
- value
- position
- offset
- homingDelaySeconds
- homingSpeed
- homingConsumeRadius

十、LocalMonsterSpawnToken（C <-> S）
接收方：`LocalMonsterRewardService:_handleSpawnTokenRequest`
触发：客户端本地怪数量不足时请求服务端授权生成。
用途：服务端为玩家生成一次性普通怪 spawn token，并指定服务端认可的怪物定义。
C -> S 字段：
- count
- timestamp
S -> C 字段：
- eventType = "Tokens" | "Denied"
- reason
- tokens
- timestamp
tokens 子字段：
- token
- monsterDefinitionId
- templateName
- typeName
- maxHealth
- attackDamage
- attackRange
- aggroRadius
- disengageDistance
- contactRadius
- attackCooldownSeconds
- moveSpeed
- expiresAt
说明：客户端只可用服务端返回的 token 生成和上报普通怪；随机伪造 token 不发奖励、不扣血。

十一、LocalMonsterKilled（C -> S）
接收方：`LocalMonsterRewardService:_handleLocalMonsterKilled`
触发：客户端私有普通小怪死亡。
用途：服务端按 token 对应的普通怪定义结算经验/重生分，并下发 `ExperienceFeedback` 播放本地经验块表现。
字段：
- token
- deathPosition
- timestamp
说明：服务端不接受客户端上传的经验、等级、血量、武器数量、伤害数值或怪物定义；token 只能消费一次，旧版无 token payload 只 warn 不发奖励。

十二、LocalMonsterHitPlayer（C -> S）
接收方：`LocalMonsterRewardService:_handleLocalMonsterHitPlayer`
触发：客户端私有普通小怪在接触半径内完成一次攻击。
用途：服务端按 token 对应的普通怪定义对该玩家扣血。
字段：
- token
- timestamp
说明：仅战斗区内 Alive 玩家有效，并按玩家限速；旧版无 token payload 只 warn 不扣血。

十三、WeaponStateSync（S -> C）
发送方：`WeaponService:_fireWeaponStateSync`
用途：广播真实玩家当前武器组表现数据；客户端按 `ownerUserId` 为所有玩家创建平滑本地视觉副本，服务端武器实例继续用于权威碰撞/伤害判定。
字段：
- ownerUserId
- weaponTier
- weaponTierIndex
- weaponCount
- weaponIcon
- weapons
- timestamp
weapons 子字段：
- id
- ownerUserId
- tier
- tierIndex
- damage
- iconImage
- orbitIndex
- orbitSpeed
- orbitDirection
- auraRadius

十四、CombatFeedback（S -> C）
发送方：`CombatService:_fireCombatFeedback`
用途：武器对武器、武器对玩家、击杀等战斗表现广播。
字段：
- eventType
- sourceUserId
- targetUserId
- damage
- remainingHealth
- timestamp
当前 eventType 示例：
- WeaponHitWeapon
- WeaponBroken
- WeaponHitPlayer
- PlayerKilled

十五、BuffFeedback（S -> C）
发送方：`BuffService:_fireBuffFeedback`
用途：玩家获得限时 Buff。
字段：
- buffType
- damageMultiplier
- durationSeconds
- expiresAt
- timestamp
当前 buffType 为 `DamageMultiplier`。

十六、BossFeedback（S -> C）
发送方：`BossService:_fireBossFeedback`
用途：Boss 刷新反馈广播。
字段：
- eventType
- bossId
- level
- maxHealth
- timestamp
当前 eventType 为 `BossSpawned`。

十七、LeaderboardSync（S -> C）
发送方：`LeaderboardService:_broadcast`
用途：同步单服和全局排行榜。
字段：
- server
- global
- timestamp
server 行字段：
- userId
- name
- level
- killCount
- totalPlayerKills
global 字段：
- playtime
- kills

十八、ArenaProgressSync（S -> C）
发送方：`ArenaProgressService:_broadcast`
用途：同步当前服务器内正在战场且存活的真实玩家等级进度表现。
字段：
- players
- minLevel
- maxLevel
- timestamp
players 行字段：
- userId
- name
- level
说明：客户端按 `(level - minLevel) / (maxLevel - minLevel)` 摆放头像；单人或全员同级时统一放到进度条终点。

十九、当前保留但主线未接入事件
1.PickupFeedback：
- `RemoteEventService` 仍会创建。
- 当前 `PickupService` 为空实现，主线资源改由 `ExperienceOrbService` 和 `BuffService` 处理。
2.StudioBotCommand：
- `RemoteEventService` 仍会创建。
- `PotionService` 在 Studio 环境监听 `{ action = "AddPotion", potionId = number, amount = number?, targetUserId = number? }`，用于 GM 发药水；非 Studio 环境拒绝。
3.RequestPotionAction：
- 接收方：`PotionService:HandlePotionAction`
- 用途：客户端请求药水钻石购买或使用。
- 字段：`action = "BuyDiamond" | "Use"`，`potionId = number`。
4.PotionFeedback：
- 发送方：`PotionService:_fireFeedback`
- 用途：返回药水添加、购买、激活、过期或失败原因。
- 字段：`eventType`、`message`、`potionId`、`diamonds`、`potions`、`activePotion`、`totalExperienceMultiplier`、`timestamp`。

5. SpecialEventSync：
- 发送方：`SpecialEventService:BroadcastState` / `PushState`
- 用途：同步特殊事件当前状态、未来两场事件和服务器时间偏移给客户端。
- 字段：`eventType`、`serverClock`、`spawnIntervalSeconds`、`activeEvent`、`futureEvents`、`timestamp`。

6. RequestSpecialEventSync：
- 接收方：`SpecialEventService:Init`
- 用途：客户端请求重新同步特殊事件状态。

7. GroupRewardPrompt：
- 发送方：`GroupRewardService:_firePrompt`
- 用途：玩家触碰 `Workspace.Map2.Chests.BasicChest` 后，通知客户端打开 `StarterGui/Main/GroupReward`。
- 字段：`eventType = "Show"`、`groupId`、`claimed`、`timestamp`。

8. RequestGroupReward：
- 接收方：`GroupRewardService:Claim`
- 用途：客户端点击 `GroupReward.Claim` 且本地确认玩家已加入群组后，请求服务端权威校验并领取群组奖励。

9. GroupRewardFeedback：
- 发送方：`GroupRewardService:_fireFeedback`
- 用途：返回群组奖励领取结果。
- 字段：`eventType = "Success" | "AlreadyClaimed" | "NotInGroup" | "Failed"`、`message`、`groupId`、`claimed`、`timestamp`。

10. PromptGroupJoin：
- 发送方：`GMCommandService` 的 Studio-only `/groupjoin` 命令。
- 用途：仅用于 Studio 测试，通知当前客户端直接调用 Roblox 官方加群系统弹窗，不发奖励、不改领取状态。

11. NukeCinematic：
- 发送方：`NukeService:_fireCinematic`
- 用途：核弹购买成功后广播客户端播放核弹表现。

12. NukeLocalMonsterSweep：
- 接收方：`NukeService:_handleLocalMonsterSweep`
- 用途：客户端核弹清除本地普通怪后，只提交当前 sessionId 和已存在 token 列表；服务端通过 `LocalMonsterRewardService:ConsumeNukeSweepTokens` 按未消费授权记录结算。
- 字段：`sessionId`、`tokens`、`timestamp`。

=====================================================
列表结束
=====================================================
]]
