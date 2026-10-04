--[[
等级武器皮肤收藏 · V6.26策划与静态UI（V6.27正式接线，2026-10-04）
日期：2026-10-04
状态：V6.26完成Figma白图与静态模板；V6.27已正式接线——服务端权威解锁/装备/自动开关/存档、
WeaponService逐槽外观解析、LevelWeaponSkinService/Controller与4个新Remote；入口暂用Studio GM /levelskin。
V6.27.1正式HUD入口为Main.Left.Armory（点击打开窗口），GM入口保留，旧静态LevelWeaponSkinsButton隐藏不接线。
依据：WeaponTierConfig、WeaponService、PlayerStateService、RebirthService、现有Skin界面。

一、玩家体验

玩家曾经通过升级解锁的武器，都成为可重复使用的免费外观。
在外观界面选一个已解锁武器，死亡后重新从1级养成，也能继续使用这个外观。
勾选“Auto-upgrade on level up”时，遇到更高档位按原来的逐把替换方式变得更好；
取消勾选时，之后升级多少级都保持自己选的外观。
每位玩家默认勾选，只有玩家手动取消才关闭，死亡/养成重生/重进不重置设置。

二、解锁口径

1. 解锁依据是服务端历史最高等级HighestLevelReached，不是当前这一条命的等级。
2. 达到现有武器档位第一次出现的等级，就获得该武器的永久外观选择权；
   不需要额外付费，也不要求点完New Weapon Unlocked奖励弹框才能获得。
3. 目录、名称、图标、模型、阈值直接复用现有WeaponTierConfig，不新建一套数值。
   当前40种可见外观：T1=Lv1、T2=Lv11、T3=Lv21……T40=Lv391。
   Lv401-Lv610的隐藏CombatRank不会重复生成新的外观卡片。
4. 最高Lv55已经获得T1-T6（Thunder Blade在Lv51解锁）。
   Lv60还是T6全部10把；Lv61才开始逐把替换为T7 Magic Fang。
5. 新玩家有T1；老玩家按已存最高等级补齐，不要求重新刷级。
   最高等级缺失时按既有合法读档回退处理，不能接受客户端自报最高等级。

三、装备与自动更换

手动选择记为“基础外观”：玩家有意选中的那一档，跨死亡和会话保存。
自动更换只影响这一条命里出现的更高档外观，不覆盖手动选择的基础外观。

模式                         表现
没有手动选择 + 自动开启       保持目前随等级逐把换武器的外观。
已手动选择 + 自动开启         每个武器槽位显示“手选档、该槽实际档”中较高的外观。
已手动选择 + 自动关闭         所有武器槽位一直显示手选外观。

例子：选T6 Thunder Blade，最高等级55。
- 死亡后Lv1：1把T6外观，仍是Lv1真实伤害和数量。
- 自动开启，成长到Lv60：10把T6外观；Lv61：9把T6外观+1把T7外观。
- Lv62：8把T6外观+2把T7外观，继续复用现有渐进换刃节奏。
- 再次死亡：回到手选的T6外观，不掉回T1，也不擅自把手选档改为T7。
- 自动关闭：Lv61或更高也全部显示T6，实际战力仍继续提升。

例子：手选较早的T3，自动开启。
- Lv1使用T3外观，直到实际武器槽位高于T3时才逐把显示更高档外观。
- 若当前已经Lv100，自动开启会立即按当前更高档展示；
  想马上所有武器都固定为T3，取消勾选即可。页面提示“Turn off to keep this skin at every level.”。

其他规则：
- 装备一个外观不替玩家取消默认勾选；勾选状态必须明确来自玩家操作。
- 开/关选项即时重算显示，不需等下一次升级；关闭时统一回到手选基础外观。
- 没有手选项却取消自动时，将当前已解锁最高档设为基础外观，保证有可固定的对象。
- 点击“Use Level Look”清除手选基础外观并开启自动，回到目前的等级换刃逻辑。
- 出战时所有生成、断刃后恢复、升级重建与重新进场，都要使用同一个外观解析规则。
- 其他玩家也应看到相同外观；服务端下发外观结果，客户端仅克隆对应视觉模型。

四、与现有皮肤、战斗的关系

1. 等级外观与商城/通行证/七日/转盘特殊皮肤互斥使用，不叠两层模型。
2. 商城特殊皮肤继续沿用OwnedSkins/EquippedSkinId，自动等级外观开关不覆盖它。
   切换回等级外观后，之前保存的自动选项继续生效。
3. 装备等级外观时清除当前特殊皮肤的装备状态，不清除其永久拥有状态；反向同理。
4. 自动更换只用于等级武器外观。特殊皮肤没有等级排序，保留现在的固定外观规则。
5. 外观不加伤害、不提前解锁战力、不增加武器数，不改变CombatRank、Aura或对拼胜负。
   继续从实际等级基础模型复制判定形状，不能让高档外观扩大低级玩家的攻击范围。
6. T40仍是当前最高可见档，隐藏战力成长不生成重复卡片。

五、界面（英文文案，沿用现有样式）

入口：独立“Level Skins”按钮与独立窗口，不加入原Skin窗口，不与Skins/Trails/Titles合并。
仅复用现有窗口边框/标题、GothamBlack文字/描边、武器图标、Equip按钮和Option选项条的视觉样式。
目录沿用横向滚动的武器卡片，按T1-T40解锁顺序排列，不重做游戏的美术风格。

页头：Level Weapon Skins
进度：Best Lv. 55 · 6/40 unlocked（实际接线后读取服务端；本轮是示例）
已选：Chosen: Thunder Blade
选项：默认打勾“Auto-upgrade on level up”
说明：Turn off to keep this skin at every level.
复原按钮：Use Level Look
页脚：Appearance only. Weapon stats stay the same.

卡片包含：武器名称、当前正式图标、Unlock at Lv. xx、状态/操作。
- 已解锁未选：Equip按钮。
- 当前选中：Equipped绿色文字与蓝色选中描边，隐藏Equip按钮。
- 未解锁：图标变暗、Locked按钮/等级要求，不发装备请求。
- 自动升级后的混合外观不改变“手动选中”卡片，避免列表选中项来回跳。

六、静态节点与后续接线

StarterGui.Main
├─ Left.LevelWeaponSkinsButton      独立HUD入口，默认隐藏，待接线后开放。
└─ LevelWeaponSkins                独立窗口，默认隐藏，编辑预览通过隔离副本展示。
   ├─ Title.CloseButton / Title.Title
   └─ Content
      ├─ LevelWeaponsHeader.Title
      ├─ ProgressSummary
      ├─ SelectedSkinSummary
      ├─ AutoUpgradeRow.CheckboxButton.Checkmark
      ├─ AutoUpgradeHint
      ├─ UseLevelLookButton
      ├─ ScrollingFrame.LevelWeaponTemplate  隐藏卡片模板。
      ├─ ScrollingFrame.LevelWeapon_T1…T40   演示卡片，真实接线时清理/替换其状态。
      └─ CosmeticOnlyHint

卡片节点：Name、ItemTemplate.ItemIcon、UnlockLevelText、EquipButton.Text、EquippedBadge、SelectionStroke。
属性：CosmeticTierIndex、UnlockLevel、PreviewState；页面PreviewHighestLevel=55、PreviewSelectedTierIndex=6。
选项DefaultChecked=true是UI模板默认；必须在读档/服务器状态到达后改成真实玩家的布尔值。
本轮所有新按钮都不接事件；目录/选中/锁定仅用于审阅，不代表当前测试玩家的真实状态。

后续数据建议（仅规划，本轮不创建Remote或改变存档）：
- SelectedLevelWeaponTierIndex：nil=默认等级外观，正整数=已解锁的手选基础外观。
- AutoUpgradeLevelWeaponSkin：boolean，缺省true；读取显式false时必须保留false。
- SkinAppearanceSource：Default/LevelWeapon/SpecialSkin，保证只选一个外观源。
- 永久解锁目录从HighestLevelReached派生，无需再存40个重复owned标志。
- 旧档迁移：有EquippedSkinId保留特殊皮肤，无则保持默认等级外观，自动选项默认true。
- 服务端校验装备档位存在/已解锁、玩家数据已加载、请求限频，拒绝越级与伪造布尔值。
- 后续新增独立LevelWeaponSkinController/LevelWeaponSkinService，并接PlayerStateService/RebirthService/
  WeaponService与WeaponStateSync。独立注册ModalUi窗口，不合并旧皮肤、尾迹、称号页面或装备请求。
  网络字段确定后按项目四处登记规则实现，本轮只提供节点契约。

七、后续功能验收

最高55解锁6种；死亡和重进不丢选择；默认true、手动false重进仍false；
T6基础外观在Lv1仍显示T6，Lv61自动9旧1新；取消勾选全T6；
未解锁拒绝、特殊皮肤互斥、其他玩家可见、实际伤害/数量/判定范围不变。
静态模板阶段只验样式、节点、演示状态和正式旧UI未受影响，不宣称业务已实现。

八、Figma交互白图（先于正式UI搭建）

文件：https://www.figma.com/design/Y0nZB26YUS3mGKVBsgHdYO
独立入口原型起点：7:2；T6自动模式起点：7:369；共16张状态白图，含15个窗口状态。
所有内容为可编辑文字、组件、卡片和布局，未将完整UI截图当交付物。
复用3组灰阶组件：按钮、勾选框、武器卡片；每个目录含现有40种武器的真实名称/阈值。
原型重点演示T3/T6装备；其他已解锁卡片只展示位置与状态，正式接线后需全量支持。
点击T6 / T7定位预览，选择T6后可切换自动开关、模拟61级、死亡、Use Level Look、关闭与重开。
原型的模拟按钮不是游戏功能；15个关闭后恢复分支已写入并读回，真实游戏存档仍待实现。
白图灰阶使用可用字体Roboto，中文注释Noto Sans SC；游戏静态模板继续使用原GothamBlack样式。
本轮验证：127条原型反应读回；文字/组件/布局可编辑、无整页截图图层；关键页面截图排版通过。
静态模板40种名字/图标/阈值通过配置核对，5未选已拥有+1已选+34未解锁，默认勾选，独立窗口/入口初始隐藏。
旧GUI393个节点关键属性前后一致；Edit隔离预览实际图标加载成功并截图，临时GUI已清理、原选择恢复。
策划不等于真实功能已生效；当前游戏HUD入口尚未开放，按钮、读档和武器模型解析尚未接线。
]]
