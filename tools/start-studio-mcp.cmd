@echo off
rem start-studio-mcp.cmd - start bridge for a given port. REQUIRES port argument.
rem For one-click double-click use, run start-mcp-bridge.cmd (project port hardcoded) instead.
rem Entry is the pinned fixed runtime (robloxstudio-mcp 2.6.0, SHA256-pinned in fixed-manifest.json).
rem Keep this window open to keep the bridge alive; closing it stops the bridge.
rem If a healthy bridge is already serving the port, this launcher reports it and exits.
rem Keep this file ASCII-only with CRLF line endings.
setlocal
if "%~1"=="" goto usage
set "ROBLOX_STUDIO_PORT=%~1"
set "ROBLOX_STUDIO_HOST=0.0.0.0"
set "MCP_ENTRY=C:\Users\ZhuanZ\tools\robloxstudio-mcp-fixed\robloxstudio-mcp\dist\index.js"
title Studio MCP bridge %~1

if not exist "%MCP_ENTRY%" (
  echo.
  echo ERROR: bridge entry not found: %MCP_ENTRY%
  echo Repair the pinned runtime first:
  echo   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ZhuanZ\tools\robloxstudio-mcp-fixed\scripts\Repair-RobloxStudioMcpFixed.ps1"
  echo.
  pause
  endlocal
  exit /b 1
)

powershell -NoProfile -Command "$h=Invoke-RestMethod ('http://127.0.0.1:' + $env:ROBLOX_STUDIO_PORT + '/health') -TimeoutSec 3; if ($h.status -eq 'ok') { exit 0 }; exit 1" >nul 2>&1
if not errorlevel 1 (
  echo.
  echo Bridge on port %~1 is already running and healthy.
  echo It is owned by another process, usually a logon task or another launcher window.
  echo To run a console-owned bridge from THIS window instead, stop the existing bridge first.
  echo Closing this window does NOT stop the running bridge - it keeps running in the background.
  echo.
  pause
  endlocal
  exit /b 0
)

echo Bridge starting on port %~1 with entry: %MCP_ENTRY%
echo Keep this window open to keep the bridge alive; close it to stop.
node "%MCP_ENTRY%"
echo.
echo Bridge exited (code %errorlevel%).
pause
endlocal
exit /b 0
:usage
echo Usage: start-studio-mcp.cmd ^<port^>
echo Double-click users should run start-mcp-bridge.cmd instead.
pause
endlocal
exit /b 1
