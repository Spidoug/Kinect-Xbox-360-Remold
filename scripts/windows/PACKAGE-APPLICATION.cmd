@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Package-Application.ps1" %*
exit /b %ERRORLEVEL%
