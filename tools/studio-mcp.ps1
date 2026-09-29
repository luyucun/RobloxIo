# studio-mcp.ps1 — 项目 Studio MCP 桥接客户端(唯一入口)
#
# 端口与项目身份自动来自工作区根目录的 .studio-mcp.json(机器可读唯一真源)。
# 环境变量覆盖(调试用):STUDIO_MCP_URL / STUDIO_MCP_HEALTH_URL / STUDIO_MCP_CONFIG_PATH。
#
# 用法(先 dot-source):
#   . .\tools\studio-mcp.ps1
#   Test-StudioMcpHealth                 # 健康门(写入 Studio 前必过)
#   Assert-StudioProject                 # 健康门 + get_place_info 与配置三方比对(写入前必过)
#   Invoke-StudioTool get_place_info     # 任意 MCP 工具
#   Invoke-StudioTool set_script_source @{ path='...'; source='...' }
#   Invoke-StudioMcpCall <jsonrpc方法> @{ ... }   # 原始 JSON-RPC(诊断用)
#
# 规则:本文件只负责协议传输与项目身份核对;其余纪律(写入→回读逐字比对→脚本分析)
# 由调用方遵守,参见 README「脚本同步硬规则」与《多项目Studio接入方案.md》。

# ---------- 配置解析 ----------
function Get-StudioMcpConfig {
  $cfgPath = if ($env:STUDIO_MCP_CONFIG_PATH) { $env:STUDIO_MCP_CONFIG_PATH }
             else { Join-Path (Split-Path $PSScriptRoot -Parent) '.studio-mcp.json' }
  if (-not (Test-Path $cfgPath)) {
    throw "找不到 MCP 工作区配置 $cfgPath。多项目接入需要每个项目根目录有 .studio-mcp.json(见《多项目Studio接入方案.md》)。"
  }
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $cfg.port) { throw "配置缺少 port: $cfgPath" }
  return $cfg
}

$script:StudioMcpCfg = Get-StudioMcpConfig
$script:StudioMcpBase = if ($env:STUDIO_MCP_URL) { $env:STUDIO_MCP_URL }
                        else { "http://127.0.0.1:$($script:StudioMcpCfg.port)/mcp" }
$script:StudioMcpHealthUrl = if ($env:STUDIO_MCP_HEALTH_URL) { $env:STUDIO_MCP_HEALTH_URL }
                             else { "http://127.0.0.1:$($script:StudioMcpCfg.port)/health" }

function ConvertFrom-SseOrJson {
  param([string]$Content)
  $t = $Content.Trim()
  if ($t -match '^event:') {
    $t = ($t -split "`n" | Where-Object { $_ -match '^data: ' } | ForEach-Object { $_ -replace '^data: ', '' }) -join "`n"
  }
  return $t | ConvertFrom-Json
}

function Test-StudioMcpHealth {
  [CmdletBinding()]
  param()
  $h = Invoke-RestMethod -Uri $script:StudioMcpHealthUrl -TimeoutSec 5
  $ok = ($h.status -eq 'ok') -and ($h.pluginConnected -eq $true) -and ($h.mcpServerActive -eq $true)
  Write-Output ($h | ConvertTo-Json -Depth 6)
  if (-not $ok) { throw "Studio MCP 健康检查未通过(实际地址 $script:StudioMcpHealthUrl): $($h | ConvertTo-Json -Compress)" }
  return $h
}

function Assert-StudioProject {
  [CmdletBinding()]
  param()
  $h = Test-StudioMcpHealth
  $raw = Invoke-StudioTool get_place_info
  $place = $raw | ConvertFrom-Json
  $cfg = $script:StudioMcpCfg
  $mismatch = @()
  if ($cfg.gameId -and ([string]$place.gameId) -ne [string]$cfg.gameId) { $mismatch += "gameId 期望 $($cfg.gameId) 实际 $($place.gameId)" }
  if ($cfg.placeId -and ([string]$place.placeId) -ne [string]$cfg.placeId) { $mismatch += "placeId 期望 $($cfg.placeId) 实际 $($place.placeId)" }
  if ($mismatch.Count -gt 0) {
    throw "Place 与工作区配置不匹配,禁止写入(可能是连到了别的项目窗口): $($mismatch -join '; ')"
  }
  if ($cfg.placeName -and ([string]$place.placeName) -ne [string]$cfg.placeName) {
    Write-Warning "placeName 与配置不同(期望 $($cfg.placeName) 实际 $($place.placeName))——内部名会随重新打开变化,不影响身份核对。"
  }
  Write-Output ("项目核对通过: {0} gameId={1} placeId={2} (端口 {3})" -f $place.placeName, $place.gameId, $place.placeId, $cfg.port)
  return $place
}

function Invoke-StudioTool {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Name,
    [Parameter(Position = 1)][hashtable]$Arguments = @{}
  )
  $payload = @{ jsonrpc = '2.0'; id = (Get-Random -Minimum 1000 -Maximum 9999); method = 'tools/call'; params = @{ name = $Name; arguments = $Arguments } }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 16 -Compress))
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'Accept' = 'application/json, text/event-stream' }
  $resp = Invoke-WebRequest -Uri $script:StudioMcpBase -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 30 -UseBasicParsing
  $respText = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  $parsed = ConvertFrom-SseOrJson $respText
  if ($parsed.error) { throw "MCP 调用失败: $($parsed.error | ConvertTo-Json -Depth 6 -Compress)" }
  $content = $parsed.result.content
  $texts = @($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
  if ($texts.Count -eq 1) { return $texts[0] }
  return $parsed.result
}

function Invoke-StudioMcpCall {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Method,
    [Parameter(Position = 1)][hashtable]$Params = @{}
  )
  $payload = @{ jsonrpc = '2.0'; id = (Get-Random -Minimum 1000 -Maximum 9999); method = $Method; params = $Params }
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 16 -Compress))
  $headers = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'Accept' = 'application/json, text/event-stream' }
  $resp = Invoke-WebRequest -Uri $script:StudioMcpBase -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 30 -UseBasicParsing
  return ConvertFrom-SseOrJson ([System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()))
}
