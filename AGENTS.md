# 项目操作规则（IO项目 / 对剑）

## 文件与工作区

- 本地仓库文件是可审查、可版本化的工程真源；任何代码改动先落到本地文件，再按项目已配置的交付方式（Studio MCP 写入 + 读回校验）进入运行环境。
- Git 仓库在 `D:\RobloxGame\IO项目\Release\RobloxIo`（外层 `IO项目` 根目录的 .git 是空壳，不是有效仓库）。
- 先运行 `git status`，再读取相关差异和当前文档。工作区已有改动属于用户，除非本次任务明确涉及，否则不得覆盖、格式化、移动或删除。
- 不使用 `git reset --hard`、`git checkout --`、`git revert` 或递归删除来整理工作区，除非用户清晰要求并已确认目标。
- 新增文件、重命名、删除和批量改动前，先确认精确目标与影响范围。

## Roblox Studio

- 所有 Studio 写操作前都必须通过项目约定的健康检查，并用 `get_place_info` 确认当前连接的 Place（placeId `73988417166286`）。
- 本项目 Studio MCP 使用专属端口 `58747`（多项目隔离：每项目一个端口、禁止共用；通用约定与端口注册表见 `D:\RobloxGame\工作流模板\项目设定相关模板\多项目Studio接入方案.md`）。端口冲突未解决前禁止开工。
- 桥由用户侧启动（`tools\start-mcp-bridge.cmd`，保持窗口）；AI 侧写 Studio 前 dot-source `tools\studio-mcp.ps1` 并运行 `Assert-StudioProject`（健康门 + `get_place_info` 与根目录 `.studio-mcp.json` 三方核对），不通过禁止写入。
- Studio MCP 未加载、断连、超时或返回空工具列表时，立即停止 Studio 写操作，并按 `项目设定相关/Studio操作规范.md` 的"断连诊断与恢复流程"处理；不得仅凭配置显示 enabled、代理进程存在或历史日志判断连接成功。
- 当前项目固定使用 `boshyxd/robloxstudio-mcp` Studio 插件与 `robloxstudio-mcp@2.6.0` 服务端这一完整配套；不得与 Roblox `StudioMCP v1.0.0` 混用。若迁移方案，必须同时更换并验证插件与服务端。
- Place、对象类型、父级、实例路径与预期任一不匹配时，不写入；先读取实际结构，必要时请用户切换到目标 Place。
- 不直接控制用户的桌面或未知 Studio 进程；Studio UI 中需要人工确认的操作交由用户处理。
- 未经用户明确请求，不启动或停止 Playtest、Run 或用户正在进行的测试。
- 非脚本 Studio 变动（GUI、场景、Tag、Attribute、Remote、资源或配置）完成后要读回关键状态，并登记到 `开发记录.md`。

## 代码与架构

- 服务端拥有所有等级、经验、伤害、击杀、死亡、武器胜负、货币、奖励、掉落、库存、购买、Buff、持久化、权限与反作弊判定；客户端只发送操作意图并播放表现。
- 普通小怪的客户端私有生成是既定性能设计：客户端生成/控制/表现，但攻击与击杀必须经服务端 token 授权、限速与 MonsterCatalog 校验后结算；不得接受客户端上传的经验、等级、武器状态或伤害数值。
- 每个客户端到服务端的请求都应进行：参数类型校验、Alive/IsInArena 等状态校验、频率或冷却限制，以及幂等或并发保护（适用时）。Robux 发货路径必须幂等（PurchaseId 台账）并有"数据已加载"守卫。
- 新增或修改网络通信、参数协议、状态字段或权威边界前，先更新 `架构设计文档.lua` 与 `RemoteEvent当前列表.lua`；实现落地时四处同步（另含 `RemoteNames.lua`、`RemoteEventService.lua`）。
- 改玩法先走文档链（需求文档 → 架构设计文档 → 专项文档 → 数值表 → RemoteEvent 列表 → 代码），见 README「标准实现流程」。
- 数值单一来源是 `IO_BaseBalanceDraft.xlsx`：改表后必须用 `tools/SyncCodeConfigFromWorkbook.py` 导表并两者一起提交，不得手改生成结果。
- 所有 GM、清档、发资源、刷等级、调试命令入口必须显式检查 `RunService:IsStudio()`；线上环境直接拒绝。
- 正式 UI 模板放 StarterGui、控制器只绑定节点，功能面板走模态规范（隐藏同级 UI + Lighting.Blur + 开关动效）；不在运行时整棵代码创建 UI。
- 不以"尚未验证"为理由制造伪成功路径；失败应保留可诊断的状态并向用户报告。

## 验证与报告

- 每次修改都要用适用的静态检查、Studio MCP 源码读回、`get_script_analysis`、导表核对或运行验证进行确认；同步成功不等于验证通过。
- 未完成的人工测试应列出具体场景、操作和预期结果。
- 结论必须标明：已验证、待验证或推断；不得把日志缺失、缓存结果或历史记录当作当前事实。
- 完成后在 `开发记录.md` 记录改动、影响范围、验证、风险和下一步；涉及已知问题时同步更新 `项目设定相关/BUG清单与解决方案.md` 的状态。
