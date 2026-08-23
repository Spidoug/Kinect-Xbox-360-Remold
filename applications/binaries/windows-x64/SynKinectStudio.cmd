@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set "APP_HOME=%CD%"
set "LOG_DIR=%APP_HOME%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\SynKinectStudio.log"
set "JAVA_EXE="

rem Portable runtime is the primary and release-supported path.
if exist "%APP_HOME%\java\bin\java.exe" set "JAVA_EXE=%APP_HOME%\java\bin\java.exe"

rem Developer/system fallbacks keep source checkouts usable, but packaged releases
rem are validated separately and must contain the portable runtime.
if not defined JAVA_EXE if defined JAVA_HOME if exist "%JAVA_HOME%\bin\java.exe" set "JAVA_EXE=%JAVA_HOME%\bin\java.exe"
if not defined JAVA_EXE if defined JDK_HOME if exist "%JDK_HOME%\bin\java.exe" set "JAVA_EXE=%JDK_HOME%\bin\java.exe"
if not defined JAVA_EXE for /f "delims=" %%J in ('where java.exe 2^>nul') do if not defined JAVA_EXE set "JAVA_EXE=%%J"

rem Search common JDK/JRE vendor roots without assuming one exact version.
if not defined JAVA_EXE for %%R in ("%ProgramFiles%\Java" "%ProgramFiles%\Eclipse Adoptium" "%ProgramFiles%\Microsoft" "%ProgramFiles%\Amazon Corretto" "%ProgramFiles%\BellSoft" "%ProgramFiles%\Zulu") do (
  if exist "%%~R" for /d %%J in ("%%~R\*") do if exist "%%~fJ\bin\java.exe" if not defined JAVA_EXE set "JAVA_EXE=%%~fJ\bin\java.exe"
)

rem Processing 4 installations often carry their own JDK. Search common install roots
rem without depending on one exact version or language-specific folder name.
if not defined JAVA_EXE for %%R in ("%LOCALAPPDATA%\Programs" "%ProgramFiles%" "%ProgramFiles(x86)%") do (
  if exist "%%~R" for /d %%P in ("%%~R\Processing*") do (
    if exist "%%~fP\java\bin\java.exe" if not defined JAVA_EXE set "JAVA_EXE=%%~fP\java\bin\java.exe"
    if exist "%%~fP\jdk\bin\java.exe" if not defined JAVA_EXE set "JAVA_EXE=%%~fP\jdk\bin\java.exe"
  )
)

if not defined JAVA_EXE (
  >"%LOG_FILE%" echo [%date% %time%] No compatible Java runtime was found.
  >>"%LOG_FILE%" echo Expected portable runtime: %APP_HOME%\java\bin\java.exe
  echo SynKinect Studio could not start because the portable Java runtime is missing.
  echo.
  echo Expected: "%APP_HOME%\java\bin\java.exe"
  echo Rebuild the release with scripts\windows\PACKAGE-APPLICATION.cmd.
  echo Diagnostic log: "%LOG_FILE%"
  pause
  exit /b 1
)

"%JAVA_EXE%" -version >>"%LOG_FILE%" 2>&1
"%JAVA_EXE%" -Dfile.encoding=UTF-8 -cp "lib\SynKinectStudio.jar;lib\*" SynKinectStudio >>"%LOG_FILE%" 2>&1
set "APP_EXIT=%ERRORLEVEL%"
if not "%APP_EXIT%"=="0" (
  echo SynKinect Studio exited with code %APP_EXIT%.
  echo Diagnostic log: "%LOG_FILE%"
  pause
)
exit /b %APP_EXIT%
