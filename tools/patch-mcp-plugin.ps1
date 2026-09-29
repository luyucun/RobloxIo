# patch-mcp-plugin.ps1 — 给 MCPPlugin.rbxmx 打「多项目自动路由」补丁(幂等,支持 v1->v2 升级)
#
# v2 变更:本机 Studio 插件设置跨重启不持久(实测 MCP_INSTANCE_ID 读回 nil),
# 因此端口映射 DEFAULT_MAP 内嵌进插件文件;插件设置 MCP_PORT_MAP(JSON)仅作运行时覆盖。
# 新增项目 = 更新 DEFAULT_MAP 常量 + 重启该项目窗口(一次性,见《多项目Studio接入方案.md》)。
#
# 流程:备份(仅首次)→ 替换自动激活块 → 写回 UTF-8 → XML 校验 → 读回打印。
# 用法:pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\patch-mcp-plugin.ps1

$ErrorActionPreference = 'Stop'
$pluginPath = Join-Path $env:LOCALAPPDATA 'Roblox\Plugins\MCPPlugin.rbxmx'
if (-not (Test-Path $pluginPath)) { throw "找不到插件文件: $pluginPath" }

$content = [System.IO.File]::ReadAllText($pluginPath, [System.Text.Encoding]::UTF8)

$bakPath = "$pluginPath.bak-20260814-multiroute"
if (-not (Test-Path $bakPath)) {
  Copy-Item $pluginPath $bakPath -Force
  Write-Host "已备份: $bakPath"
} else {
  Write-Host "备份已存在,复用: $bakPath"
}

# 补丁块 v2(内嵌 DEFAULT_MAP;设置仅覆盖)
$newBlock = @'
task.defer(function()
	if RunService:IsEdit() then
		-- MCP-PATCH-BEGIN: multi-project auto-routing (gameId -> port)
		-- DEFAULT_MAP 内嵌于插件文件:本机 Studio 插件设置跨重启不持久,不能依赖 GetSetting。
		-- 新增项目:更新 DEFAULT_MAP 后重启该项目窗口(流程见项目文档《多项目Studio接入方案.md》)。
		local HttpService = game:GetService("HttpService")
		local DEFAULT_MAP = { ["10760471685"] = 58741, ["10639368398"] = 58742, ["9971501998"] = 58743, ["10765643160"] = 58744, ["8904241985"] = 58745, ["10768438294"] = 58746, ["10133052560"] = 58747 }
		local targetPort = DEFAULT_MAP[tostring(game.GameId)]
		local okRaw, raw = pcall(function() return plugin:GetSetting("MCP_PORT_MAP") end)
		if okRaw and raw and raw ~= "" then
			local okJson, map = pcall(function() return HttpService:JSONDecode(raw) end)
			if okJson and type(map) == "table" and map[tostring(game.GameId)] then
				targetPort = map[tostring(game.GameId)]
			end
		end
		if targetPort and type(targetPort) == "number" then
			local foundIndex = nil
			for i, c in ipairs(State.getConnections()) do
				if c.port == targetPort then
					foundIndex = i - 1
					break
				end
			end
			if foundIndex ~= nil then
				State.setActiveTabIndex(foundIndex)
			else
				local newIndex = State.addConnection(targetPort)
				if newIndex ~= nil then
					State.setActiveTabIndex(newIndex)
				end
			end
			-- v3:activatePlugin 会用 urlInput.Text 覆盖当前标签连接的 serverUrl,
			-- 必须先把 UI 输入框同步成目标端口,否则路由被覆盖回默认值。
			local ui = UI.getElements()
			if ui and ui.urlInput then
				ui.urlInput.Text = "http://localhost:" .. tostring(targetPort)
			end
		end
		-- MCP-PATCH-END
		Communication.activatePlugin(State.getActiveTabIndex(), true)
	end
end)
'@

$script:matchCount = 0
if ($content -match 'MCP-PATCH-BEGIN') {
  Write-Host '检测到已有补丁,升级为最新版(内嵌 DEFAULT_MAP + UI 同步)...'
  $v2 = $newBlock
  $s = $v2.IndexOf('-- MCP-PATCH-BEGIN')
  $e = $v2.IndexOf('-- MCP-PATCH-END') + '-- MCP-PATCH-END'.Length
  $markerRegion = $v2.Substring($s, $e - $s)
  $new = [regex]::Replace($content, '-- MCP-PATCH-BEGIN:[\s\S]*?-- MCP-PATCH-END', {
    param($m)
    $script:matchCount++
    return $markerRegion
  })
} else {
  Write-Host '未检测到补丁,首次安装 v2...'
  if ($content -notmatch 'task\.defer\(function\(\)') { throw '未找到 task.defer 自动激活块,插件版本可能已变化,停止打补丁。' }
  $pattern = 'task\.defer\(function\(\)[\r\n\t ]*if RunService:IsEdit\(\) then[\r\n\t ]*Communication\.activatePlugin\(State\.getActiveTabIndex\(\), true\)[\r\n\t ]*end[\r\n\t ]*end\)'
  $new = [regex]::Replace($content, $pattern, {
    param($m)
    $script:matchCount++
    return $newBlock
  })
}
if ($script:matchCount -ne 1) { throw "匹配次数异常: $($script:matchCount)(期望 1),停止打补丁。" }

[System.IO.File]::WriteAllText($pluginPath, $new, [System.Text.UTF8Encoding]::new($false))

$verify = [System.IO.File]::ReadAllText($pluginPath, [System.Text.Encoding]::UTF8)
if ($verify -notmatch 'MCP-PATCH-BEGIN' -or $verify -notmatch 'DEFAULT_MAP') { throw '写回后校验失败:补丁标记缺失。' }
try { [xml]$null = $verify } catch { throw "XML 校验失败: $($_.Exception.Message)" }

Write-Host '补丁 v2 已写入并通过 XML 校验。'
$idx = $verify.IndexOf('DEFAULT_MAP')
$start = [Math]::Max(0, $idx - 60)
$len = [Math]::Min(700, $verify.Length - $start)
$verify.Substring($start, $len)
Write-Host '--- 完成 ---'
