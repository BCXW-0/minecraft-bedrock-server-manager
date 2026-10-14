@echo off
setlocal
PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Admin.ps1" %*
exit /b %ERRORLEVEL%
