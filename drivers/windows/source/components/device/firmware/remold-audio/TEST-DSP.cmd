@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TEST-DSP.ps1"
exit /b %errorlevel%
