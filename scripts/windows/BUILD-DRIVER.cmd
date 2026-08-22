@echo off
setlocal
set "ROOT=%~dp0\..\..\drivers\windows"
call "%ROOT%\BUILD.cmd" %*
exit /b %ERRORLEVEL%
