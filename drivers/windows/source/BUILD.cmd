@echo off
setlocal
set "REMOLD_ROOT=%~dp0"
set "REMOLD_BUILD=%REMOLD_ROOT%build\Build.ps1"

if not exist "%REMOLD_BUILD%" (
    echo.
    echo Kinect Xbox 360 Remold build launcher cannot find:
    echo   %REMOLD_BUILD%
    echo.
    echo Extract the complete project folder from the ZIP before running BUILD.cmd.
    echo Running BUILD.cmd directly inside Windows Explorer's compressed-folder view only extracts the launcher and cannot provide the build tree.
    echo.
    set "RC=2"
    goto :finish
)

pushd "%REMOLD_ROOT%" >nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REMOLD_BUILD%"
set "RC=%ERRORLEVEL%"
popd >nul

:finish
echo.
if not "%RC%"=="0" echo Build failed. See logs\build-*.log when a build log was created.
if "%RC%"=="0" echo Build complete. Open ..\binaries\KINECT.cmd and choose Install / Repair after satisfying Windows driver-signing policy.
echo.
set /p "_REMOLD_CONTINUE=Press Enter to continue: "
exit /b %RC%
