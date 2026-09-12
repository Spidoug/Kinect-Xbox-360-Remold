@echo off
setlocal EnableExtensions
set "REMOLD_CALLER=%REMOLD_BUILD_PARENT%"
set "REMOLD_BUILD_PARENT=1"
set "ROOT=%~dp0"
set "CHILD=%ROOT%source\BUILD.cmd"
set "RC=0"

echo ============================================================
echo  Kinect Xbox 360 Remold v1.0 - Windows build launcher
echo ============================================================
echo.

if not exist "%CHILD%" (
    echo ERROR: build script was not found:
    echo   "%CHILD%"
    echo.
    echo Extract the COMPLETE project ZIP to a normal folder before
    echo running BUILD.cmd. Do not run it from inside the ZIP preview.
    set "RC=2"
    goto :finish
)

call "%CHILD%" %*
set "RC=%ERRORLEVEL%"

:finish
echo.
if "%RC%"=="0" (
    echo ============================================================
    echo  BUILD FINISHED SUCCESSFULLY
    echo ============================================================
) else (
    echo ============================================================
    echo  BUILD FAILED - error code %RC%
    echo ============================================================
    echo The window will remain open so you can read the error.
    echo Build logs, when created, are in:
    echo   "%ROOT%source\logs"
)
echo.
if not defined REMOLD_CALLER pause
exit /b %RC%
