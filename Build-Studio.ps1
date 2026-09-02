[CmdletBinding()]
param([string]$JdkHome='')
$ErrorActionPreference='Stop'
$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Sketch=Join-Path $RepoRoot 'applications\processing\SynKinectStudio'
$LinuxApp=Join-Path $RepoRoot 'applications\binaries\linux-x64'
$WindowsApp=Join-Path $RepoRoot 'applications\binaries\windows-x64'
$Lib=Join-Path $WindowsApp 'lib'

$bin=if($JdkHome){Join-Path $JdkHome 'bin'}elseif($env:JDK_HOME){Join-Path $env:JDK_HOME 'bin'}elseif($env:JAVA_HOME){Join-Path $env:JAVA_HOME 'bin'}else{''}
$javac=if($bin){Join-Path $bin 'javac.exe'}else{(Get-Command javac.exe -ErrorAction Stop).Source}
$jar=if($bin){Join-Path $bin 'jar.exe'}else{(Get-Command jar.exe -ErrorAction Stop).Source}
if(!(Test-Path $javac)){throw 'JDK 17+ javac.exe was not found.'}
if(!(Test-Path $jar)){throw 'JDK 17+ jar.exe was not found.'}
$versionText=(& $javac -version 2>&1 | Select-Object -First 1).ToString().Trim()
if($versionText -notmatch '(\d+)(?:\.(\d+))?'){throw "Could not determine javac version: $versionText"}
$feature=if([int]$Matches[1] -eq 1 -and $Matches[2]){[int]$Matches[2]}else{[int]$Matches[1]}
if($feature -lt 17){throw "JDK 17+ required, found: $versionText"}
$work=Join-Path ([IO.Path]::GetTempPath()) ('SynKinectStudio-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'classes') -Force|Out-Null
try{
  $tabs=@(Join-Path $Sketch 'SynKinectStudio.pde') + @(Get-ChildItem $Sketch -Filter '*.pde'|Where-Object Name -ne 'SynKinectStudio.pde'|Sort-Object Name|ForEach-Object FullName)
  $imports=@('import processing.core.*;','import processing.data.*;','import processing.event.*;','import processing.opengl.*;')
  foreach($dependency in @('core-4.4.6.jar','jogl-all-2.5.0.jar','gluegen-rt-2.5.0.jar')){if(!(Test-Path (Join-Path $Lib $dependency))){throw "Missing compile dependency: $dependency"}}
  $body=New-Object System.Collections.Generic.List[string]
  foreach($tab in $tabs){foreach($line in Get-Content -LiteralPath $tab -Encoding UTF8){if($line -like 'import *'){$imports += $line}else{$body.Add($line)}}}
  $java=Join-Path $work 'SynKinectStudio.java'
  $lines=@($imports|Select-Object -Unique)+@('public class SynKinectStudio extends PApplet {')+$body+@('public static void main(String[] args){PApplet.main(SynKinectStudio.class.getName());}','}')
  [IO.File]::WriteAllLines($java,$lines,(New-Object Text.UTF8Encoding($false)))
  $cp=(Join-Path $Lib 'core-4.4.6.jar')+';'+(Join-Path $Lib 'jogl-all-2.5.0.jar')+';'+(Join-Path $Lib 'gluegen-rt-2.5.0.jar')
  & $javac --release 17 -Xlint:all -cp $cp -d (Join-Path $work 'classes') $java
  if($LASTEXITCODE -ne 0){throw "javac failed: $LASTEXITCODE"}
  Copy-Item (Join-Path $Sketch 'data\synkinect-studio-icon.png') (Join-Path $work 'classes\synkinect-studio-icon.png')
  $manifest=Join-Path $work 'MANIFEST.MF'; @('Manifest-Version: 1.0','Main-Class: SynKinectStudio','Implementation-Title: SynKinect Studio','Implementation-Version: 1.0','')|Set-Content $manifest -Encoding ASCII
  $out=Join-Path $work 'SynKinectStudio.jar'; & $jar --create --file $out --manifest $manifest --date=2026-01-01T00:00:00Z -C (Join-Path $work 'classes') .
  if($LASTEXITCODE -ne 0){throw "jar failed: $LASTEXITCODE"}
  foreach($app in @($WindowsApp,$LinuxApp)){Copy-Item $out (Join-Path $app 'lib\SynKinectStudio.jar') -Force; Remove-Item (Join-Path $app 'data') -Recurse -Force -ErrorAction SilentlyContinue; Copy-Item (Join-Path $Sketch 'data') (Join-Path $app 'data') -Recurse}
  $windowsHash=(Get-FileHash (Join-Path $WindowsApp 'lib\SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  $linuxHash=(Get-FileHash (Join-Path $LinuxApp 'lib\SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  if($windowsHash -ne $linuxHash){throw 'Release invariant violated: Windows and Linux Studio JARs differ.'}
  Write-Host "SynKinect Studio 1.0 rebuilt for both platforms. SHA-256: $windowsHash" -ForegroundColor Green
}finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
