README:

注意：以下是本项目开发时的注意事项：

1.本项目的正式内容统一以 `D:\RobloxGame\IO项目\Release` 目录下的文件为准，其他草稿文档不作为正式实现依据
2.项目开始开发前，必须先看：
   - `需求文档.lua`
   - `架构设计文档.lua`
   - `RemoteEvent当前列表.lua`
   - `道具系统策划文档.lua`
   - `武器系统策划文档.lua`
   - `框架设计.md`
   - `IO_BaseBalanceDraft.xlsx`
3.每次新增功能或修改玩法时，必须先更新需求文档，再更新架构设计文档和 RemoteEvent 列表，然后才能开始正式开发
4.如果后续实际实现中新增或修改了 RemoteEvent，必须同步更新：
   - `RemoteEvent当前列表.lua`
   - `架构设计文档.lua`
   - `RemoteNames.lua`
   - `RemoteEventService.lua`
5.如果你要新增脚本文件，要在开头标注清楚脚本名字 / 脚本文件 / 脚本类型 / Studio 放置路径
6.客户端脚本尽量统一放在 `StarterPlayerScripts`，正式 UI 模板统一放在 `StarterGui`
7.服务端核心逻辑统一收口在 `ServerScriptService/Services`
8.共享配置和常量统一放在 `ReplicatedStorage/Shared`
9.本项目当前是单 Place 玩法，不做多 Place、不做匹配队列、不做跨服流程
10.当前场景约定必须严格保持一致：
    - 默认出生点：`SpawnLocation`
    - 准备区域入口：`workspace.Map2.Portals.Portal`
    - 入场确认弹框：`StarterGui.Main.JoinGame`
    - 入场弹框背景模糊：`Lighting.Blur`
    - 战斗区域范围：`workspace.Battle`
11.当前标准实现流程：
   1）先补充或修改 `需求文档.lua`
   2）再修改 `架构设计文档.lua`
   3）如果功能属于独立子系统，要补对应的专项文档，比如 `道具系统策划文档.lua`、`武器系统策划文档.lua`
   4）如果涉及数值，必须同步 `IO_BaseBalanceDraft.xlsx`
   5）再修改 `RemoteEvent当前列表.lua`
   6）最后再开始写代码
12.全程使用中文沟通
13.正式项目中的 HUD / 提示 / 面板 UI，不允许在游戏运行后整棵用代码动态创建；应先放入 `StarterGui`，客户端控制器只负责绑定现成节点、更新数据和播放动画
14.所有功能型 UI 面板打开时必须作为模态界面处理：隐藏 `PlayerGui.Main` 下除当前面板外的其他同级 `GuiObject`，启用 `Lighting.Blur`；关闭时恢复原始 `Visible` 状态和 Blur 状态。功能 UI 的打开和关闭必须有明确动效，不允许无动画瞬间切换
15.如果新增 Studio 内调试工具，也要走正式项目结构：
    - 调试界面放 `StarterGui`
    - 客户端热键与按钮逻辑放 `StarterPlayerScripts/Controllers`
    - 调试指令仍通过 `RemoteEvent` 进入服务端，由服务端统一校验和执行
16.当前文档必须以 Release 目录代码为准；发现规划、架构、数值表与代码不一致时，优先同步文档，不反向改代码

17.Rojo Script Sync 流程：
   - 本项目已提供 `default.project.json`，用于 VS Code 的 `Rojo - Roblox Studio Sync` / Studio Rojo 插件把本地 Lua 脚本实时同步到 Studio。
   - `default.project.json` 由 `tools/BuildRojoProject.py` 根据脚本头部的 `Studio放置路径` 或 `Studio path` 自动生成；新增脚本时必须写清脚本类型和 Studio 放置路径，然后运行 `py -X utf8 tools\BuildRojoProject.py` 刷新映射。
   - 当前映射只接管脚本和共享配置：`ReplicatedStorage/Shared`、`ServerScriptService/MainServer`、`ServerScriptService/Services`、`StarterPlayer/StarterPlayerScripts/MainClient`、`StarterPlayer/StarterPlayerScripts/Controllers`；Studio 里的 UI 模板、场景模型和手调节点仍以 Studio 当前状态为准。
   - 使用方式：在 VS Code 打开本目录，运行 Rojo 菜单/Script Sync，或在命令行运行 `rojo serve default.project.json`，再在 Roblox Studio 的 Rojo 插件中 Connect。
   - 本地验证命令：`rojo sourcemap default.project.json` 和 `rojo build default.project.json --output <临时rbxlx路径>`；当前已验证可解析并构建 113 个脚本映射。
   - Rojo 负责提高本地代码写入 Studio 的效率，但完成改动后仍要用固定 Studio MCP 做读回和 `get_script_analysis` 校验，不能只凭同步成功就认为功能已验证。
