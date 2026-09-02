@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem SynKinect Studio is always a standard-user desktop process.  If this
rem launcher was inherited from an elevated console/control action, hand it
rem back to the normal Explorer desktop token before Java starts.
set "_REMOLD_STANDARD_RELAUNCH=0"
if /I "%~1"=="--remold-standard-user" set "_REMOLD_STANDARD_RELAUNCH=1"
set "_REMOLD_IS_ADMIN=0"
for /f "usebackq delims=" %%E in (`powershell.exe -NoLogo -NoProfile -Command "$p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){'1'}else{'0'}" 2^>nul`) do set "_REMOLD_IS_ADMIN=%%E"
if "%_REMOLD_IS_ADMIN%"=="1" (
  if "%_REMOLD_STANDARD_RELAUNCH%"=="1" (
    echo SynKinect Studio refuses to run elevated. Start it from the normal desktop user session.
    exit /b 1
  )
  set "REMOLD_STUDIO_SCRIPT=%~f0"
  set "REMOLD_STUDIO_DIR=%~dp0"
  powershell.exe -NoLogo -NoProfile -Command "$sh=New-Object -ComObject Shell.Application; $sh.ShellExecute($env:REMOLD_STUDIO_SCRIPT,'--remold-standard-user',$env:REMOLD_STUDIO_DIR,'open',1)"
  if errorlevel 1 (
    echo Could not relaunch SynKinect Studio with the standard desktop token.
    exit /b 1
  )
  exit /b 0
)

cd /d "%~dp0"

set "APP_HOME=%CD%"
set "LOG_DIR=%APP_HOME%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\SynKinectStudio.log"
set "JAVA_EXE="
set "JAVA_VERSION="
set "LAST_JAVA_EXE="
set "LAST_JAVA_VERSION="

>"%LOG_FILE%" echo [%date% %time%] SynKinect Studio launcher 1.0

rem V1 rule: use one Java 17+ runtime. A bundled runtime wins when present.
call :try_java "%APP_HOME%\java\bin\java.exe"

rem Source/full-repository archives may use an installed JDK/JRE.
if not defined JAVA_EXE if defined JAVA_HOME call :try_java "%JAVA_HOME%\bin\java.exe"
if not defined JAVA_EXE if defined JDK_HOME call :try_java "%JDK_HOME%\bin\java.exe"

rem PATH candidates. "where" is safe here because java.exe itself is not executed
rem inside FOR /F; paths such as C:\Program Files\... are validated in :try_java.
if not defined JAVA_EXE for /f "delims=" %%J in ('where java.exe 2^>nul') do if not defined JAVA_EXE call :try_java "%%~fJ"

rem Common JDK/JRE vendor roots. Do not assume a vendor or exact Java version.
if not defined JAVA_EXE for %%R in ("%ProgramFiles%\Java" "%ProgramFiles%\Eclipse Adoptium" "%ProgramFiles%\Microsoft" "%ProgramFiles%\Amazon Corretto" "%ProgramFiles%\BellSoft" "%ProgramFiles%\Zulu" "%ProgramFiles%\Semeru" "%ProgramFiles%\Azul Systems") do (
  if exist "%%~R" for /d %%J in ("%%~R\*") do if not defined JAVA_EXE call :try_java "%%~fJ\bin\java.exe"
)


rem Processing 4 may bundle its own Java runtime/JDK.
if not defined JAVA_EXE for %%R in ("%LOCALAPPDATA%\Programs" "%ProgramFiles%") do (
  if exist "%%~R" for /d %%P in ("%%~R\Processing*") do (
    if not defined JAVA_EXE call :try_java "%%~fP\java\bin\java.exe"
    if not defined JAVA_EXE call :try_java "%%~fP\jdk\bin\java.exe"
  )
)

if not defined JAVA_EXE goto :java_missing

>>"%LOG_FILE%" echo Selected Java: "%JAVA_EXE%"
>>"%LOG_FILE%" echo Java version: %JAVA_VERSION%
"%JAVA_EXE%" -version >>"%LOG_FILE%" 2>&1

set "APP_CP=%APP_HOME%\lib\SynKinectStudio.jar;%APP_HOME%\lib\*"
"%JAVA_EXE%" -Dfile.encoding=UTF-8 -Dsun.java2d.uiScale=1.0 -Dsun.java2d.dpiaware=true -cp "%APP_CP%" SynKinectStudio %* >>"%LOG_FILE%" 2>&1
set "APP_EXIT=%ERRORLEVEL%"
if not "%APP_EXIT%"=="0" (
  echo SynKinect Studio exited with code %APP_EXIT%.
  echo Diagnostic log: "%LOG_FILE%"
  pause
)
exit /b %APP_EXIT%

:try_java
if defined JAVA_EXE exit /b 0
set "CANDIDATE=%~1"
if not defined CANDIDATE exit /b 0
if not exist "%CANDIDATE%" exit /b 0

set "PROBE_FILE=%TEMP%\SynKinectStudio-java-%RANDOM%-%RANDOM%.txt"
"%CANDIDATE%" -XshowSettings:properties -version >"%PROBE_FILE%" 2>&1
set "PROBE_EXIT=%ERRORLEVEL%"
if not "%PROBE_EXIT%"=="0" (
  >>"%LOG_FILE%" echo Rejected Java candidate ^(exit %PROBE_EXIT%^): "%CANDIDATE%"
  del /q "%PROBE_FILE%" >nul 2>&1
  exit /b 0
)

set "CANDIDATE_VERSION="
for /f "tokens=3" %%V in ('findstr /i /c:"version" "%PROBE_FILE%" 2^>nul') do if not defined CANDIDATE_VERSION set "CANDIDATE_VERSION=%%~V"
findstr /i /c:"sun.arch.data.model = 64" "%PROBE_FILE%" >nul 2>&1
set "CANDIDATE_IS_64=%ERRORLEVEL%"
del /q "%PROBE_FILE%" >nul 2>&1
if not "%CANDIDATE_IS_64%"=="0" (
  >>"%LOG_FILE%" echo Rejected Java candidate ^(Windows x64 runtime required^): "%CANDIDATE%"
  exit /b 0
)
if not defined CANDIDATE_VERSION (
  >>"%LOG_FILE%" echo Rejected Java candidate ^(version unreadable^): "%CANDIDATE%"
  exit /b 0
)

set "CANDIDATE_MAJOR="
for /f "tokens=1 delims=." %%M in ("%CANDIDATE_VERSION%") do set "CANDIDATE_MAJOR=%%M"
if "%CANDIDATE_MAJOR%"=="1" for /f "tokens=2 delims=." %%M in ("%CANDIDATE_VERSION%") do set "CANDIDATE_MAJOR=%%M"
set /a CANDIDATE_MAJOR_NUM=%CANDIDATE_MAJOR%+0 >nul 2>&1

set "LAST_JAVA_EXE=%CANDIDATE%"
set "LAST_JAVA_VERSION=%CANDIDATE_VERSION%"
if %CANDIDATE_MAJOR_NUM% LSS 17 (
  >>"%LOG_FILE%" echo Rejected Java candidate ^(requires 17+^): "%CANDIDATE%" version %CANDIDATE_VERSION%
  exit /b 0
)

set "JAVA_EXE=%CANDIDATE%"
set "JAVA_VERSION=%CANDIDATE_VERSION%"
exit /b 0

:java_missing
>>"%LOG_FILE%" echo No usable Java 17+ runtime was found.
if defined LAST_JAVA_EXE >>"%LOG_FILE%" echo Last Java found: "%LAST_JAVA_EXE%" version %LAST_JAVA_VERSION%
echo SynKinect Studio requires Java 17 or newer.
if defined LAST_JAVA_VERSION echo Newest/last usable candidate found was Java %LAST_JAVA_VERSION%.
echo.
echo The launcher checked the bundled runtime, JAVA_HOME, JDK_HOME, PATH,
echo common Java installations under Program Files, and Processing 4 runtimes.
echo Diagnostic log: "%LOG_FILE%"
pause
exit /b 1
