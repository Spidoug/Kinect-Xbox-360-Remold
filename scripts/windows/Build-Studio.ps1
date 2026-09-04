[CmdletBinding()]
param([string]$JdkHome='')
$ErrorActionPreference='Stop'

$RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Sketch=Join-Path $RepoRoot 'applications\processing\SynKinectStudio'
$Templates=Join-Path $RepoRoot 'applications\runtime-templates'
$LinuxApp=Join-Path $RepoRoot 'applications\binaries\linux-x64'
$WindowsApp=Join-Path $RepoRoot 'applications\binaries\windows-x64'
$WindowsLib=Join-Path $WindowsApp 'lib'
$LinuxLib=Join-Path $LinuxApp 'lib'
$Cache=Join-Path $RepoRoot '.cache\studio'

function Ensure-Directory([string]$Path){if(!(Test-Path -LiteralPath $Path -PathType Container)){New-Item -ItemType Directory -Path $Path -Force|Out-Null}}
function File-Sha256([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-PinnedFile([string]$Name,[string]$Url,[string]$Sha256){
  Ensure-Directory $Cache
  $cached=Join-Path $Cache $Name
  if(Test-Path -LiteralPath $cached -PathType Leaf){
    if((File-Sha256 $cached) -eq $Sha256){return $cached}
    Remove-Item -LiteralPath $cached -Force
  }
  $tmp=$cached+'.download'
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  $last=$null
  for($attempt=1;$attempt -le 5;$attempt++){
    try{
      Write-Host "Downloading $Name (attempt $attempt/5)..." -ForegroundColor DarkCyan
      Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp -TimeoutSec 120
      if((File-Sha256 $tmp) -ne $Sha256){throw "SHA-256 mismatch for $Name"}
      Move-Item -LiteralPath $tmp -Destination $cached -Force
      return $cached
    }catch{
      $last=$_
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds ([Math]::Min(8,$attempt*2))
    }
  }
  throw "Could not download verified dependency $Name from $Url. $($last.Exception.Message)"
}
function Stage-Dependency([hashtable]$Dep){
  $source=Get-PinnedFile $Dep.Name $Dep.Url $Dep.Sha256
  foreach($targetDir in $Dep.Targets){
    Ensure-Directory $targetDir
    Copy-Item -LiteralPath $source -Destination (Join-Path $targetDir $Dep.Name) -Force
  }
}

Ensure-Directory $WindowsApp
Ensure-Directory $LinuxApp
Ensure-Directory $WindowsLib
Ensure-Directory $LinuxLib

$processingBase='https://repo.maven.apache.org/maven2/org/processing/core/4.4.6'
$joglBase='https://jogamp.org/deployment/maven/org/jogamp/jogl/jogl-all/2.5.0'
$gluegenBase='https://jogamp.org/deployment/maven/org/jogamp/gluegen/gluegen-rt/2.5.0'
$dependencies=@(
  @{Name='core-4.4.6.jar';Url="$processingBase/core-4.4.6.jar";Sha256='e92f6f517963e2f63882c71ab92ed46c98dbfa1cbccab8b2475c1d76ceca0f86';Targets=@($WindowsLib,$LinuxLib)},
  @{Name='jogl-all-2.5.0.jar';Url="$joglBase/jogl-all-2.5.0.jar";Sha256='245717cceabca264a210a899f8839d47bd127f50f80892ead2277dd89cbcd301';Targets=@($WindowsLib,$LinuxLib)},
  @{Name='gluegen-rt-2.5.0.jar';Url="$gluegenBase/gluegen-rt-2.5.0.jar";Sha256='3620c18536a8671fcb1c595d7448e9d31226b824117af6a4c6d45c657f4dabe3';Targets=@($WindowsLib,$LinuxLib)},
  @{Name='jogl-all-2.5.0-natives-windows-amd64.jar';Url="$joglBase/jogl-all-2.5.0-natives-windows-amd64.jar";Sha256='ce0b755f6bc0eeefd386539e72d13e4d8e96e1f086ca222f8a02e11320032142';Targets=@($WindowsLib)},
  @{Name='gluegen-rt-2.5.0-natives-windows-amd64.jar';Url="$gluegenBase/gluegen-rt-2.5.0-natives-windows-amd64.jar";Sha256='a4f039e2fa9d616be9f26284ffd6afe5fae26d521d21f28126e5eaa073f8a438';Targets=@($WindowsLib)},
  @{Name='jogl-all-2.5.0-natives-linux-amd64.jar';Url="$joglBase/jogl-all-2.5.0-natives-linux-amd64.jar";Sha256='e97850f290d8e44ba07fa0500d7a071ff444209099f0372df3dba707cba3ddc1';Targets=@($LinuxLib)},
  @{Name='gluegen-rt-2.5.0-natives-linux-amd64.jar';Url="$gluegenBase/gluegen-rt-2.5.0-natives-linux-amd64.jar";Sha256='6d998d0c1f04f103894b769049086124505063cea86a82896194bb53c88b040a';Targets=@($LinuxLib)}
)
foreach($dep in $dependencies){Stage-Dependency $dep}
Write-Host 'Pinned Processing/JOGL/GlueGen dependencies: READY' -ForegroundColor Green

# Stage source launchers into the generated runtime tree.
Copy-Item -LiteralPath (Join-Path $Templates 'windows-x64\SynKinectStudio.cmd') -Destination (Join-Path $WindowsApp 'SynKinectStudio.cmd') -Force
Copy-Item -LiteralPath (Join-Path $Templates 'linux-x64\SynKinectStudio.sh') -Destination (Join-Path $LinuxApp 'SynKinectStudio.sh') -Force
Copy-Item -LiteralPath (Join-Path $Templates 'linux-x64\SynKinectStudio.desktop') -Destination (Join-Path $LinuxApp 'SynKinectStudio.desktop') -Force
Copy-Item -LiteralPath (Join-Path $Sketch 'data\synkinect-studio-icon.png') -Destination (Join-Path $LinuxApp 'synkinect-studio-icon.png') -Force

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
  $body=New-Object System.Collections.Generic.List[string]
  foreach($tab in $tabs){foreach($line in Get-Content -LiteralPath $tab -Encoding UTF8){if($line -like 'import *'){$imports += $line}else{$body.Add($line)}}}
  $java=Join-Path $work 'SynKinectStudio.java'
  $lines=@($imports|Select-Object -Unique)+@('public class SynKinectStudio extends PApplet {')+$body+@('public static void main(String[] args){PApplet.main(SynKinectStudio.class.getName());}','}')
  [IO.File]::WriteAllLines($java,$lines,(New-Object Text.UTF8Encoding($false)))
  $cp=(Join-Path $WindowsLib 'core-4.4.6.jar')+';'+(Join-Path $WindowsLib 'jogl-all-2.5.0.jar')+';'+(Join-Path $WindowsLib 'gluegen-rt-2.5.0.jar')
  & $javac --release 17 -Xlint:all -cp $cp -d (Join-Path $work 'classes') $java
  if($LASTEXITCODE -ne 0){throw "javac failed: $LASTEXITCODE"}
  Copy-Item (Join-Path $Sketch 'data\synkinect-studio-icon.png') (Join-Path $work 'classes\synkinect-studio-icon.png')
  $manifest=Join-Path $work 'MANIFEST.MF'; @('Manifest-Version: 1.0','Main-Class: SynKinectStudio','Implementation-Title: SynKinect Studio','Implementation-Version: 1.0','')|Set-Content $manifest -Encoding ASCII
  $out=Join-Path $work 'SynKinectStudio.jar'; & $jar --create --file $out --manifest $manifest --date=2026-01-01T00:00:00Z -C (Join-Path $work 'classes') .
  if($LASTEXITCODE -ne 0){throw "jar failed: $LASTEXITCODE"}
  foreach($app in @($WindowsApp,$LinuxApp)){
    Copy-Item $out (Join-Path $app 'lib\SynKinectStudio.jar') -Force
    Remove-Item (Join-Path $app 'data') -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $Sketch 'data') (Join-Path $app 'data') -Recurse
  }
  $windowsHash=(Get-FileHash (Join-Path $WindowsLib 'SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  $linuxHash=(Get-FileHash (Join-Path $LinuxLib 'SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  if($windowsHash -ne $linuxHash){throw 'Release invariant violated: Windows and Linux Studio JARs differ.'}
  Write-Host "SynKinect Studio 1.0 rebuilt for both platforms. SHA-256: $windowsHash" -ForegroundColor Green
}finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
