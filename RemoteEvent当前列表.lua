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
  - BattleEvents
    - PickupFeedback
    - ExperienceFeedback
    - LocalMonsterKilled
    - LocalMonsterHitPlayer
    - WeaponStateSync
    - CombatFeedback
    - BuffFeedback
    - BossFeedback
    - LeaderboardSync
    - ArenaProgressSync

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
- totalExperienceMultiplier
- isInArena
- alive
- buffs
- timestamp
说明：
- `killCount` 为局内击杀数，死亡重置战斗状态时可清零。
- `totalPlayerKills` 为 V2.5 顶部 HUD 显示的永久玩家击杀数。
- `diamonds` 为 V2.5 顶部 HUD 显示的钻石货币数量。

三、RequestPlayerStateSync（C -> S）
接收方：`PlayerStateService:Init`
用途：客户端请求重新下发自身状态。
当前处理：服务端收到后执行 `PushState(player)`。

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
用途：`Join` 请求服务端把玩家传送进 `workspace.Battle`；`Cancel` 取消本次 Portal 待确认状态。服务端只接受已经触发过 PortalJoinPrompt 且仍在 Portal 范围内的 Join 请求。
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

十、LocalMonsterKilled（C -> S）
接收方：`LocalMonsterRewardService:_handleLocalMonsterKilled`
触发：客户端私有普通小怪死亡。
用途：服务端按配置给该玩家结算普通小怪固定经验，并下发 `ExperienceFeedback` 播放本地经验块表现。
字段：
- monsterDefinitionId
- monsterId
- deathPosition
- timestamp
说明：服务端不接受客户端上传的经验、等级、血量、武器数量或伤害数值；重复 monsterId 和超频请求会被忽略。

十一、LocalMonsterHitPlayer（C -> S）
接收方：`LocalMonsterRewardService:_handleLocalMonsterHitPlayer`
触发：客户端私有普通小怪在接触半径内完成一次攻击。
用途：服务端按 `GameConfig.MONSTER.AttackDamage` 对该玩家扣血。
字段：
- monsterId
- timestamp
说明：仅战斗区内 Alive 玩家有效，并按玩家限速。

十二、WeaponStateSync（S -> C）
发送方：`WeaponService:_fireWeaponStateSync`
用途：同步玩家当前武器组表现数据，仅发给对应玩家。
字段：
- weaponTier
- weaponTierIndex
- weaponCount
- weaponIcon
- weapons
- timestamp
weapons 子字段：
- id
- tier
- tierIndex
- damage
- iconImage
- orbitIndex
- orbitRadius
- orbitSpeed
- orbitDirection
- auraRadius

十三、CombatFeedback（S -> C）
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

十四、BuffFeedback（S -> C）
发送方：`BuffService:_fireBuffFeedback`
用途：玩家获得限时 Buff。
字段：
- buffType
- damageMultiplier
- durationSeconds
- expiresAt
- timestamp
当前 buffType 为 `DamageMultiplier`。

十五、BossFeedback（S -> C）
发送方：`BossService:_fireBossFeedback`
用途：Boss 刷新反馈广播。
字段：
- eventType
- bossId
- level
- maxHealth
- timestamp
当前 eventType 为 `BossSpawned`。

十六、LeaderboardSync（S -> C）
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

十七、ArenaProgressSync（S -> C）
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

十八、当前保留但主线未接入事件
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

=====================================================
列表结束
=====================================================
]]
