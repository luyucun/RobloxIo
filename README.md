# IO项目（对剑）开发工作流

> 本仓库（`D:\RobloxGame\IO项目\Release\RobloxIo`，也是 Git 仓库）是"IO 对剑"项目的工程真源。策划配置、Luau 源码、Studio 对象登记、验证记录和开发时间线都必须在这里可追溯。
> 本工作流体系 2026-09-29 自合成陀螺项目迁移建立；多项目 Studio 接入遵循 `D:\RobloxGame\工作流模板\项目设定相关模板\多项目Studio接入方案.md`。

## 当前状态（2026-09-29）

- 主线版本 V6.3：等级 Lv610 / 武器 T1-T40（Lv401+ 隐藏战力）/ 皮肤 10008 已接入；当前实现明细见 `框架设计.md` 与 `架构设计文档.lua`。
- 全量代码审查已完成：4 个 P0 + 27 项 P1 已登记 `项目设定相关/BUG清单与解决方案.md`，修复排期见 `项目设定相关/开发顺序规划.md`，未开始修复。
- Studio MCP 接入中（端口 58747）：工作区配置与脚本已就位，待用户启动桥并读回 gameId 收尾（见 `项目设定相关/Studio操作规范.md` 第 2 节）。

## 新对话开工前

按以下顺序执行：

1. 阅读本文件与 `AGENTS.md`。
2. 阅读 `开发记录.md` 最近 2 至 3 条，不需要翻完历史。
3. 运行 `git status`（在 `Release/RobloxIo`），识别未提交、未跟踪和与本次任务无关的改动。
4. 仅当任务涉及玩法规格时，阅读 `需求文档.md` 与 `框架设计.md`；涉及数值再看 `IO_BaseBalanceDraft.xlsx` 对应工作表。
5. 仅当任务涉及架构、网络通信或数据协议时，阅读 `架构设计文档.lua` 与 `RemoteEvent当前列表.lua`。
6. 仅当任务涉及修复已知问题时，阅读 `项目设定相关/BUG清单与解决方案.md` 对应条目与 `项目设定相关/开发顺序规划.md`。
7. 任务涉及 Roblox Studio 时，先完成 `项目设定相关/Studio操作规范.md` 的健康检查，并用 `get_place_info` 确认当前连接的是正确 Place（placeId `73988417166286`）；没有确认前不做写入。

## 工作原则

1. 先读取当前状态，再判断和修改；实时 Studio 状态、当前工作区和当前文档优先于历史结论。
2. 保护已有工作：不执行 `reset --hard`、`checkout`、`revert`、批量覆盖或无关清理；遇到脏工作区只触及本次任务范围。
3. 先最小闭环，后扩展：核心玩法、核心交互或高风险假设必须优先做成可验证的最小版本。
4. 服务器权威：等级、经验、伤害、击杀、死亡、武器胜负、货币、奖励、掉落、库存、购买、持久化及所有影响公平性的结果只能由服务器计算和提交；客户端只提交意图并负责即时表现。普通小怪的客户端私有生成是性能设计，其击杀仍必须走服务端 token 校验结算。
5. 数据分层：局内临时状态留在服务器内存；跨局、跨服或长期成长数据才持久化。
6. 远程通信先登记后实现：新增或改变 RemoteEvent、请求参数或返回结构前，先更新 Remote 登记文档（见下方「RemoteEvent 同步规则」）。
7. Studio 中独立存在的 GUI、场景、Tag、Attribute、Remote 或资源变动，验证后必须记录在 `开发记录.md`。
8. 验证事实和推断分开写。没有实际验证的内容不能表述为已完成。
9. 不启动、停止或干预 Playtest，除非用户明确要求；手动测试的结果由用户或可验证日志确认。
10. 全程使用中文沟通。

## 标准实现流程（文档先行，必须遵守）

每次新增功能或修改玩法时，按以下顺序，全部完成后才能开始写代码：

1. 先补充或修改 `需求文档.md`。
2. 再修改 `架构设计文档.lua`。
3. 如果功能属于独立子系统，补对应的专项文档（如 `武器系统策划文档.lua`、`道具系统策划文档.lua`）。
4. 如果涉及数值，同步 `IO_BaseBalanceDraft.xlsx` 并用 `tools/SyncCodeConfigFromWorkbook.py` 导表。
5. 再修改 `RemoteEvent当前列表.lua`。
6. 最后开始写代码。

如果实际实现中新增或修改了 RemoteEvent，必须同步更新四处：`RemoteEvent当前列表.lua`、`架构设计文档.lua`、`RemoteNames.lua`、`RemoteEventService.lua`。

## 项目结构与场景约定

- 正式内容统一以本目录（`Release/RobloxIo`）文件为准，其他草稿文档不作为正式实现依据；文档与代码不一致时优先同步文档，不反向改代码。
- 客户端脚本统一放 `StarterPlayerScripts`（控制器在 `Controllers` 子目录）；正式 UI 模板统一放 `StarterGui`。
- 服务端核心逻辑统一收口在 `ServerScriptService/Services`；共享配置和常量统一放 `ReplicatedStorage/Shared`。
- 单 Place 玩法：不做多 Place、不做匹配队列、不做跨服流程。
- 场景约定必须严格保持一致：
  - 默认出生点：`workspace.SpawnLocation`
  - 准备区域入口：`workspace.Map2.Portals.Portal`
  - 入场确认弹框：`StarterGui.Main.JoinGame`
  - 入场弹框背景模糊：`Lighting.Blur`
  - 战斗区域范围：`workspace.Battle`
- 新增脚本文件必须在开头标注清楚：脚本名字 / 脚本文件 / 脚本类型 / Studio 放置路径。

## UI 与调试规范

- 正式 HUD / 提示 / 面板 UI 不允许在游戏运行后整棵用代码动态创建；应先放入 `StarterGui`，客户端控制器只负责绑定现成节点、更新数据和播放动画。
- 所有功能型 UI 面板打开时必须作为模态界面处理：隐藏 `PlayerGui.Main` 下除当前面板外的其他同级 `GuiObject`，启用 `Lighting.Blur`；关闭时恢复原始 `Visible` 状态和 Blur 状态。功能 UI 的打开和关闭必须有明确动效，不允许无动画瞬间切换。
- 新增 Studio 内调试工具也走正式项目结构：调试界面放 `StarterGui`，客户端热键与按钮逻辑放 `StarterPlayerScripts/Controllers`，调试指令仍通过 RemoteEvent 进入服务端，由服务端统一校验和执行。
- 所有 GM / 清档 / 发资源 / 刷等级 / 调试命令入口必须显式检查 `RunService:IsStudio()`；线上环境必须直接拒绝执行。

## Git 与提交规范

- 开始前必须确认工作区状态；不把用户原有改动混入本次任务。
- 一个提交只解决一个完整且相关的问题；工具/流程调整与玩法/数值改动应分开提交。
- 新文件需确认已被 Git 识别，不能只看 `git diff`。
- 提交前至少检查：变更文件列表、差异内容、相关语法/静态检查、文档登记是否齐全。
- 若无法安全提交，明确报告原因和保留的未提交文件；不得为追求干净状态而丢弃工作。

## Studio 操作边界

- Studio 操作前先做健康检查（dot-source `tools\studio-mcp.ps1`，运行 `Assert-StudioProject`），并确认当前 Place、实例类型、父级与目标一致；本项目专属端口 `58747`。
- 健康检查报告异常、连接对象不明确或目标 Place 不匹配时，停止写入并先诊断；不要控制未知的 Studio 或桥接进程。详细诊断与恢复流程见 `项目设定相关/Studio操作规范.md`。
- 新建脚本、GUI、Remote、Tag、Attribute 或场景对象前，先检查当前层级是否已有可复用的对象，避免重复创建。
- 对 UI、场景和资源的改动，优先检查真实节点及现有属性；用户已手调的值优先。
- 完成后读取关键结果并运行适用的分析或检查；把验证范围与结果写入 `开发记录.md`。

## Rojo Script Sync 流程

- 本项目提供 `default.project.json`，用于 VS Code 的 `Rojo - Roblox Studio Sync` / Studio Rojo 插件把本地 Lua 脚本实时同步到 Studio。
- `default.project.json` 由 `tools/BuildRojoProject.py` 根据脚本头部的 `Studio放置路径` 自动生成；新增脚本时必须写清脚本类型和 Studio 放置路径，然后运行 `py -X utf8 tools\BuildRojoProject.py` 刷新映射。
- 当前映射只接管脚本和共享配置：`ReplicatedStorage/Shared`、`ServerScriptService/MainServer`、`ServerScriptService/Services`、`StarterPlayer/StarterPlayerScripts/MainClient`、`StarterPlayer/StarterPlayerScripts/Controllers`；Studio 里的 UI 模板、场景模型和手调节点仍以 Studio 当前状态为准。
- 使用方式：在 VS Code 打开本目录，运行 Rojo 菜单/Script Sync，或在命令行运行 `rojo serve default.project.json`，再在 Roblox Studio 的 Rojo 插件中 Connect。
- 本地验证命令：`rojo sourcemap default.project.json` 和 `rojo build default.project.json --output <临时rbxlx路径>`；当前已验证可解析并构建 113+ 个脚本映射。
- Rojo 负责提高本地代码写入 Studio 的效率，但完成改动后仍要用固定 Studio MCP 做读回和 `get_script_analysis` 校验，不能只凭同步成功就认为功能已验证。

## 文档索引

- `AGENTS.md`：AI 与自动化操作必须遵循的边界。
- `开发记录.md`：每次改动、验证、风险与待办的时间线。
- `需求文档.md`：主需求真源（V1.0-V6.3 逐版追加）。
- `框架设计.md`：当前实现同步版的主线框架。
- `架构设计文档.lua`：架构基线、服务层职责、关键路径与 RemoteEvent 登记（本项目"架构与 Remote 登记"文档）。
- `RemoteEvent当前列表.lua`：RemoteEvent 清单（本项目 Remote 登记表）。
- `武器系统策划文档.lua`、`道具系统策划文档.lua`：子系统专项文档。
- `IO_BaseBalanceDraft.xlsx`：数值单一来源（导表工具 `tools/SyncCodeConfigFromWorkbook.py`）。
- `项目设定相关/核心玩法循环.md`：玩家体验、核心循环与长期目标。
- `项目设定相关/Studio操作规范.md`：固定 Studio MCP 健康检查、恢复边界、写入前后验收和禁止事项。
- `项目设定相关/验证与验收清单.md`：代码、Studio、网络、手动测试和交付前检查清单。
- `项目设定相关/项目配置清单.md`：项目、Place、固定 MCP、数据约定和发布测试边界的共享配置。
- `项目设定相关/开发顺序规划.md`：阶段目标、依赖关系和最小验证目标。
- `项目设定相关/BUG清单与解决方案.md`：已知问题清单（2026-09-29 代码审查基线）与修复方案、状态跟踪。
- `任务交接提示词模板.md`：长对话或换人后的交接格式。

## 完成标准

一次任务至少满足以下条件才可称为完成：

1. 实现范围与用户需求一致，没有自行扩展需求。
2. 改动只覆盖必要文件和必要 Studio 对象。
3. 已运行与风险相称的检查（Rojo sourcemap/build、MCP 读回、get_script_analysis、导表核对等），并给出实际结果。
4. 架构、Remote、Studio 独立变动和待人工测试项已登记（文档链 + `开发记录.md`）。
5. 明确区分"已验证""待用户验证"和"推断"。
