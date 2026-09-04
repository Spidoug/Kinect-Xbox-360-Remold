@echo off
setlocal EnableExtensions
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
set "REMOLD_ROOT=%~dp0"
set "REMOLD_BUILD=%REMOLD_ROOT%build\Build.ps1"
set "RC=0"

echo ============================================================
echo  Kinect Xbox 360 Remold v1.0 - Native Windows build
echo ============================================================
echo Project: "%REMOLD_ROOT%"
echo.

if not exist "%REMOLD_BUILD%" (
    echo ERROR: required PowerShell build script was not found:
    echo   "%REMOLD_BUILD%"
    echo.
    echo Extract the COMPLETE project folder from the ZIP first.
    echo Running BUILD.cmd from Windows Explorer's compressed-folder
    echo preview does not make the complete source tree available.
    set "RC=2"
    goto :finish
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell ^(powershell.exe^) was not found.
    echo This build requires Windows PowerShell 5.1 or a compatible host.
    set "RC=3"
    goto :finish
)

pushd "%REMOLD_ROOT%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: could not enter the source directory:
    echo   "%REMOLD_ROOT%"
    set "RC=4"
    goto :finish
)

echo [preflight] Detecting/bootstrapping Visual Studio C++ + Windows SDK/WDK...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REMOLD_ROOT%build\Ensure-Toolchain.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    popd >nul 2>&1
    goto :finish
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REMOLD_BUILD%" %*
set "RC=%ERRORLEVEL%"
popd >nul 2>&1

:finish
echo.
if "%RC%"=="0" (
    echo Build complete.
    echo Open ..\binaries\KINECT.cmd and choose Install / Reinstall.
) else (
    echo BUILD FAILED with error code %RC%.
    echo Review the error above and the newest file under:
    echo   "%REMOLD_ROOT%logs"
)
echo.
echo This window will not close automatically.
if not defined REMOLD_CALLER pause
exit /b %RC%
