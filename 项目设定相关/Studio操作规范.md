# Studio 操作规范

> 本文件规定本项目通过 Studio MCP 连接和操作 Roblox Studio 时的固定组件、安全边界、断连恢复流程与验收标准。流程与多项目约定 copied 自合成陀螺项目已验证方案。

## 1. 当前固定 MCP 配套

- Studio 插件：`boshyxd/robloxstudio-mcp`。
- MCP 服务端：固定运行时 `C:\Users\ZhuanZ\tools\robloxstudio-mcp-fixed\robloxstudio-mcp\dist\index.js`（v2.6.0，SHA256 锁定，与其他项目共用同一份二进制）。
- Studio 插件通信：HTTP `http://localhost:58747`（本项目专属端口；端口注册表见 `D:\RobloxGame\工作流模板\项目设定相关模板\多项目Studio接入方案.md`）。
- 桥启动：用户前台运行 `tools\start-mcp-bridge.cmd`（端口 58747 已写死，一键即对）并保持窗口；随时可双击 `tools\check-studio-bridge.cmd` 查看桥与插件连接状态。
- AI 侧写 Studio 前 dot-source `tools\studio-mcp.ps1` 并运行 `Assert-StudioProject`（健康门 + `get_place_info` 与根目录 `.studio-mcp.json` 三方核对），不通过禁止写入。
- 机器可读配置：仓库根目录 `.studio-mcp.json`（port=58747、placeId=73988417166286；gameId 待首次接入读回后回填）。

Roblox 自带的 `StudioMCP v1.0.0` 使用另一套 WebSocket `13469` 协议，不能与上述 `58747` 插件混用。迁移到新版方案时必须成套更换 Studio 端和 MCP 服务端，并重新完成本文全部验收。

## 2. 首次接入收尾（一次性，当前待办）

本项目 2026-09-29 完成工作区接入（配置、脚本、文档），以下步骤待用户配合完成后才允许 Studio 写操作：

1. 用户双击 `tools\start-mcp-bridge.cmd` 启动桥并保持窗口。
2. 打开 IO项目的 Studio 窗口（Place ID `73988417166286`）。
3. 运行 `get_place_info` 读回真实 `gameId`，回填 `.studio-mcp.json` 与本文档、`项目配置清单.md`。
4. 编辑 `tools\patch-mcp-plugin.ps1` 内 `DEFAULT_MAP`，加入 `["<gameId>"] = 58747` 后运行一次（幂等，插件文件自动备份），再**重启该项目 Studio 窗口**使插件自动路由到 58747。
5. 验证：该端口 `get_place_info` 返回本项目 placeId；从别的工作区/端口指向它必须被拒（失败关闭）。
6. 在端口注册表（工作流模板/项目设定相关模板/多项目Studio接入方案.md 第 3 节）确认 58747 行状态为已接入。

## 3. 每次 Studio 操作前的健康检查

1. 确认当前任务已加载 Studio 写入工具（`get_place_info` 等），不能用配置存在代替工具发现结果。
2. 调用 `get_place_info`，核对 `placeId`（和回填后的 `gameId`）是否为本次任务的目标 Place（IO项目，placeId `73988417166286`）。
3. 读取目标对象的实际路径、`ClassName`、父级和关键状态后，才允许写入。
4. 任一步失败、超时、被取消或结果与预期不一致时，按下一节恢复；恢复前不做 Studio 写操作。

### 3.1 单主端口与握手并发约束

- `58747` 是本项目 Studio 插件固定访问的唯一专属端口（多项目隔离：每项目一个端口、禁止共用）。桥进程由用户启动后保持窗口，不得另起监听同一端口或改端口。
- 同一台机器只保留一个直接监听 `58747` 的 robloxstudio-mcp 主进程；发现多个同名 Node 进程时，必须先按 PID、命令行和监听端口核验归属，再结束确认属于本项目的旧代理。
- 插件 `/ready` 握手必须单飞：上一个请求未结束时不得重复发起；服务恢复后由插件重试，不通过堆积请求"提高成功率"。
- `GET /health` 的 `mcpServerActive=true` 只证明 MCP 服务端活跃；只有 `pluginConnected=true` 且 `instanceCount>0`，并且 `get_place_info` 实际成功，才算连接恢复。

## 4. 断连诊断与恢复流程

### 4.1 先停止写入并分类

按以下顺序检查，不跳步：

1. **写入工具未加载或工具列表为空**：确认桥窗口在运行、`http://127.0.0.1:58747/health` 返回 status=ok 且 `pluginConnected=true`；写入能力以 `tools\studio-mcp.ps1` 的 `Test-StudioMcpHealth` 与 `get_place_info` 实际成功为准。
2. **配置缺失或启动命令错误**：核对根目录 `.studio-mcp.json` 与本文件第 1 节，确认固定运行时入口存在、`tools\start-mcp-bridge.cmd` 存在。
3. **服务端未安装**：执行只读检查 `npm.cmd list -g robloxstudio-mcp --depth=0`；预期版本 `2.6.0`。缺失时才重新安装，安装属于外部环境变更，需明确记录。
4. **工具存在但调用超时**：检查 `58747` 是否存在唯一监听者，并确认监听进程属于 robloxstudio-mcp。同时由用户查看 Studio 插件是否为启用/连接状态。
5. **端口被占或漂移**：读取监听进程身份；只可停止已确认属于本项目且失去客户端的旧 MCP 代理，不停止 Roblox Studio，不处理未知进程。端口释放后由用户重新启动桥。
6. **出现 `StudioMCP v1.0.0`、WebSocket `13469` 或零缓存工具**：判定为组件混用。停止该错误代理，恢复第 1 节配套；不要通过改端口把两套协议强行连接。
7. **Studio 插件未响应**：不要控制 Studio 桌面或进程。请用户在 Studio 中确认当前处于 Edit 模式、插件已启用；必要时由用户重启 Studio。

### 4.2 可使用的只读检查

```powershell
npm.cmd list -g robloxstudio-mcp --depth=0
Invoke-WebRequest http://127.0.0.1:58747/health -TimeoutSec 3 -UseBasicParsing
Get-NetTCPConnection -LocalPort 58747 -ErrorAction SilentlyContinue
Get-Process -Name RobloxStudioBeta,node,StudioMCP -ErrorAction SilentlyContinue
```

检查进程时应同时核对路径、命令行或其他身份信息。仅看到同名进程，不足以证明它是正确运行时。

### 4.3 恢复后的验收门槛

以下条件必须全部满足，才能认定"已连接"：

1. MCP 初始化返回服务名 `robloxstudio-mcp`；当前固定版本为 `2.6.0`。
2. 写入工具清单非空并包含 `get_place_info`；不能只看配置为 enabled 或代理进程存在。
3. `get_place_info` 实际成功返回，且 Place 标识与目标一致。
4. 活动调用期间 `58747` 有正确服务端监听，并存在 Studio 插件连接（`pluginConnected=true`）。
5. 若后续要写入，再完成目标实例路径、类型、父级和关键状态检查。

## 5. 恢复边界

- 不直接关闭、重启或控制 Roblox Studio；Studio UI 操作和 Studio 重启交由用户。
- 不停止未知监听者，不根据进程名猜测身份，不用递归终止进程树清理环境。
- 只可结束路径、命令行、端口归属均已确认的孤立 MCP 代理，并在操作前后读回端口状态。
- 不擅自启动或停止 Playtest、Run 或用户正在执行的测试。
- 不用旧日志、缓存、配置存在或"进程正在运行"代替当前 `get_place_info` 成功结果。
- 失败必须保留具体错误，例如"工具未加载""端口被占用""插件超时""组件混用"或"用户取消调用"，不得报告伪成功。

## 6. Studio 写入前后要求

### 写入前

1. 明确变更属于本地文件还是 Studio 独立对象。
2. 读取目标层级、`ClassName`、父级、名称、关键属性、Tag、Attribute 和相关 Remote。
3. 优先复用现有对象和用户已调好的值，确认缺失后才新增。
4. 删除、替换或批量重建前必须获得用户明确授权。

### 写入后

1. 读回关键层级、属性、Tag、Attribute、Remote 或脚本源码。
2. 运行适用的源码分析（`get_script_analysis`）、结构检查或运行验证。
3. 在 `开发记录.md` 登记 Studio 独立变动、验证证据、风险与待人工测试项。
4. 涉及 Remote、协议、状态字段或权威边界时，先更新 `RemoteEvent当前列表.lua`、`架构设计文档.lua`、`RemoteNames.lua`、`RemoteEventService.lua` 四处（README 规则 4）。

## 7. 本项目与 Rojo 的关系

- 本项目脚本与共享配置通过 Rojo（`default.project.json`，由 `tools/BuildRojoProject.py` 生成）同步到 Studio；Rojo 负责提高写入效率。
- **完成改动后仍必须用本文件的 MCP 流程做读回与 `get_script_analysis` 校验**，不能只凭 Rojo 同步成功就认为功能已验证（README 规则 17）。
- Studio 里的 UI 模板、场景模型和手调节点以 Studio 当前状态为准；对这些对象的改动属于"Studio 独立对象"，走本文第 6 节流程并登记。
