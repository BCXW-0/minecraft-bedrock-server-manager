@echo off
setlocal
PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1"
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
  echo.
  echo Minecraft Bedrock Server Manager start failed with exit code %code%.
  pause
)
exit /b %code%
