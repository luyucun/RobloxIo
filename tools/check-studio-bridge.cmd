@echo off
rem check-studio-bridge.cmd - ONE-CLICK bridge status check for THIS project (port 58747).
rem Double-click any time to see whether the bridge is running and whether Studio is connected.
rem ASCII-only with CRLF line endings.
setlocal
title Studio MCP bridge status 58747
powershell -NoProfile -Command "try { $h = Invoke-RestMethod 'http://127.0.0.1:58747/health' -TimeoutSec 3; if ($h.status -eq 'ok') { Write-Host ('BRIDGE RUNNING on port 58747 (uptime ' + [int]($h.uptime/3600) + 'h)') ; if ($h.pluginConnected -eq $true) { Write-Host 'Studio plugin: CONNECTED - AI can read/write Studio.' -ForegroundColor Green } else { Write-Host 'Studio plugin: NOT connected - open Roblox Studio with the MCP plugin, or reopen the place.' -ForegroundColor Yellow } } else { Write-Host 'BRIDGE NOT RUNNING (unhealthy response).' -ForegroundColor Red } } catch { Write-Host 'BRIDGE NOT RUNNING - nothing is listening on port 58747.' -ForegroundColor Red; Write-Host 'To start it: double-click tools\start-mcp-bridge.cmd and KEEP THE WINDOW OPEN.' -ForegroundColor Cyan }"
echo.
pause
endlocal
exit /b 0
