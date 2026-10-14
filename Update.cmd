@echo off
setlocal
PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update.ps1" %*
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
  echo.
  echo Minecraft Bedrock Server Manager update failed with exit code %code%.
  pause
)
exit /b %code%
