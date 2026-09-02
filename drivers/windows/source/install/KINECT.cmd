@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0system\Kinect.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Kinect control panel exited with error %RC%.
  echo This window will remain open so the error can be read.
  set /p "_REMOLD_CONTINUE=Press Enter to continue: "
)
exit /b %RC%
