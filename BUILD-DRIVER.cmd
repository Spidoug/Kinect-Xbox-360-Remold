@echo off
setlocal EnableExtensions
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
set "ROOT=%~dp0\..\..\drivers\windows"
set "TARGET=%ROOT%\BUILD.cmd"
set "RC=0"

echo ============================================================
echo  Kinect Xbox 360 Remold v1.0 - Driver build shortcut
echo ============================================================
echo.
if not exist "%TARGET%" (
    echo ERROR: Windows driver BUILD.cmd was not found:
    echo   "%TARGET%"
    echo Extract the complete project before running this shortcut.
    set "RC=2"
    goto :finish
)
call "%TARGET%" %*
set "RC=%ERRORLEVEL%"

:finish
echo.
if not "%RC%"=="0" echo BUILD FAILED - error code %RC%.
if "%RC%"=="0" echo BUILD FINISHED SUCCESSFULLY.
echo.
if not defined REMOLD_CALLER pause
exit /b %RC%
