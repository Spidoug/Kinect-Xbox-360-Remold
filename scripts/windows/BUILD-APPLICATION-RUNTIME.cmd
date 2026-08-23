@echo off
setlocal
set "ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Build-ApplicationRuntime.ps1" %*
exit /b %ERRORLEVEL%
