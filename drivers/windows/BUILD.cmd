@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%source\BUILD.cmd" %*
exit /b %ERRORLEVEL%
