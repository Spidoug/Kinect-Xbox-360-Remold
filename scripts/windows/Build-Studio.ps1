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


function Get-JdkFeature([string]$Javac){
  if([string]::IsNullOrWhiteSpace($Javac) -or !(Test-Path -LiteralPath $Javac -PathType Leaf)){return $null}
  $oldPreference=$ErrorActionPreference
  try{
    # javac writes its version to stderr on some builds. Keep that diagnostic
    # from becoming a terminating NativeCommandError under Windows PowerShell.
    $ErrorActionPreference='Continue'
    $versionText=(& $Javac -version 2>&1 | Select-Object -First 1).ToString().Trim()
  }catch{return $null}finally{$ErrorActionPreference=$oldPreference}
  $match=[regex]::Match($versionText,'(\d+)(?:\.(\d+))?')
  if(!$match.Success){return $null}
  $first=[int]$match.Groups[1].Value
  $feature=if($first -eq 1 -and $match.Groups[2].Success){[int]$match.Groups[2].Value}else{$first}
  [pscustomobject]@{Feature=$feature;VersionText=$versionText}
}
function Test-JdkHome([string]$CandidateHome){
  if([string]::IsNullOrWhiteSpace($CandidateHome)){return $null}
  $resolved=$CandidateHome
  try{$resolved=[IO.Path]::GetFullPath($CandidateHome)}catch{return $null}
  $javac=Join-Path $resolved 'bin\javac.exe'
  $jar=Join-Path $resolved 'bin\jar.exe'
  if(!(Test-Path -LiteralPath $javac -PathType Leaf) -or !(Test-Path -LiteralPath $jar -PathType Leaf)){return $null}
  $version=Get-JdkFeature $javac
  if($null -eq $version -or $version.Feature -lt 17){return $null}
  [pscustomobject]@{Home=$resolved;Javac=$javac;Jar=$jar;Feature=$version.Feature;VersionText=$version.VersionText}
}
function Get-PublishedSha256([string]$Url,[string]$Name){
  $tmp=Join-Path $Cache ($Name+'.sha256.download')
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  $last=$null
  for($attempt=1;$attempt -le 5;$attempt++){
    try{
      Write-Host "Downloading checksum for $Name (attempt $attempt/5)..." -ForegroundColor DarkCyan
      Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $tmp -TimeoutSec 120
      $text=[IO.File]::ReadAllText($tmp)
      $match=[regex]::Match($text,'(?i)\b[0-9a-f]{64}\b')
      if(!$match.Success){throw "Published SHA-256 was not found for $Name"}
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      return $match.Value.ToLowerInvariant()
    }catch{
      $last=$_
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds ([Math]::Min(8,$attempt*2))
    }
  }
  throw "Could not obtain the published SHA-256 for $Name. $($last.Exception.Message)"
}
function Install-PortableJdk17 {
  $jdkVersion='17.0.20.1'
  $archiveName="microsoft-jdk-$jdkVersion-windows-x64.zip"
  $archiveUrl="https://aka.ms/download-jdk/$archiveName"
  $checksumUrl="$archiveUrl.sha256sum.txt"
  $jdkRoot=Join-Path $Cache 'jdk'
  $portableHome=Join-Path $jdkRoot ("microsoft-jdk-"+$jdkVersion)
  Ensure-Directory $jdkRoot

  $ready=Test-JdkHome $portableHome
  if($null -ne $ready){
    Write-Host "Portable Microsoft OpenJDK ${jdkVersion}: READY (cached)" -ForegroundColor Green
    return $ready
  }

  $expected=Get-PublishedSha256 $checksumUrl $archiveName
  $archive=Get-PinnedFile $archiveName $archiveUrl $expected
  $extractRoot=Join-Path $jdkRoot ('.extract-'+[guid]::NewGuid().ToString('N'))
  Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
  Ensure-Directory $extractRoot
  try{
    Write-Host "Extracting portable Microsoft OpenJDK $jdkVersion..." -ForegroundColor DarkCyan
    Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force
    $javacCandidate=Get-ChildItem -LiteralPath $extractRoot -Filter 'javac.exe' -File -Recurse -ErrorAction Stop |
      Where-Object{(Split-Path -Leaf $_.DirectoryName) -ieq 'bin'} | Select-Object -First 1
    if($null -eq $javacCandidate){throw "javac.exe was not found inside $archiveName"}
    $extractedHome=Split-Path -Parent $javacCandidate.DirectoryName
    Remove-Item -LiteralPath $portableHome -Recurse -Force -ErrorAction SilentlyContinue
    Ensure-Directory $portableHome
    Get-ChildItem -LiteralPath $extractedHome -Force | Copy-Item -Destination $portableHome -Recurse -Force
  }finally{
    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  $ready=Test-JdkHome $portableHome
  if($null -eq $ready){throw "Portable Microsoft OpenJDK $jdkVersion was extracted but is not usable."}
  Write-Host "Portable Microsoft OpenJDK ${jdkVersion}: READY ($($ready.VersionText))" -ForegroundColor Green
  return $ready
}
function Resolve-Jdk17([string]$RequestedHome){
  $homes=New-Object System.Collections.Generic.List[string]
  foreach($candidate in @($RequestedHome,$env:JDK_HOME,$env:JAVA_HOME)){
    if(![string]::IsNullOrWhiteSpace([string]$candidate) -and !$homes.Contains([string]$candidate)){$homes.Add([string]$candidate)}
  }
  foreach($candidateHome in $homes){
    $ready=Test-JdkHome $candidateHome
    if($null -ne $ready){
      Write-Host "JDK 17+ detected: $($ready.VersionText) [$($ready.Home)]" -ForegroundColor Green
      return $ready
    }
  }
  $pathJavac=Get-Command javac.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if($null -ne $pathJavac){
    $pathHome=Split-Path -Parent (Split-Path -Parent $pathJavac.Source)
    $ready=Test-JdkHome $pathHome
    if($null -ne $ready){
      Write-Host "JDK 17+ detected: $($ready.VersionText) [$($ready.Home)]" -ForegroundColor Green
      return $ready
    }
  }
  Write-Host 'JDK 17+ was not found; bootstrapping a verified portable Microsoft OpenJDK...' -ForegroundColor Yellow
  return (Install-PortableJdk17)
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

$jdk=Resolve-Jdk17 $JdkHome
$javac=$jdk.Javac
$jar=$jdk.Jar
$versionText=$jdk.VersionText
$feature=$jdk.Feature

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
  $oldPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    & $javac --release 17 -Xlint:all -cp $cp -d (Join-Path $work 'classes') $java
    $javacExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$oldPreference}
  if($javacExit -ne 0){throw "javac failed: $javacExit"}
  Copy-Item (Join-Path $Sketch 'data\synkinect-studio-icon.png') (Join-Path $work 'classes\synkinect-studio-icon.png')
  $manifest=Join-Path $work 'MANIFEST.MF'; @('Manifest-Version: 1.0','Main-Class: SynKinectStudio','Implementation-Title: SynKinect Studio','Implementation-Version: 1.0','')|Set-Content $manifest -Encoding ASCII
  $out=Join-Path $work 'SynKinectStudio.jar'
  $oldPreference=$ErrorActionPreference
  try{
    $ErrorActionPreference='Continue'
    & $jar --create --file $out --manifest $manifest --date=2026-01-01T00:00:00Z -C (Join-Path $work 'classes') .
    $jarExit=$LASTEXITCODE
  }finally{$ErrorActionPreference=$oldPreference}
  if($jarExit -ne 0){throw "jar failed: $jarExit"}
  foreach($app in @($WindowsApp,$LinuxApp)){
    Copy-Item $out (Join-Path $app 'lib\SynKinectStudio.jar') -Force
    Remove-Item (Join-Path $app 'data') -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $Sketch 'data') (Join-Path $app 'data') -Recurse
  }
  $windowsHash=(Get-FileHash (Join-Path $WindowsLib 'SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  $linuxHash=(Get-FileHash (Join-Path $LinuxLib 'SynKinectStudio.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
  if($windowsHash -ne $linuxHash){throw 'Release invariant violated: Windows and Linux Studio JARs differ.'}

  # One Windows V1 runtime path: after the final application JAR exists, use
  # jdeps + jlink to derive the exact Java modules required by SynKinect Studio.
  $runtimeBuilder=Join-Path $PSScriptRoot 'Build-ApplicationRuntime.ps1'
  if(!(Test-Path -LiteralPath $runtimeBuilder -PathType Leaf)){throw "Windows Java runtime builder not found: $runtimeBuilder"}
  $runtimePowerShell=Join-Path $PSHOME 'powershell.exe'
  if(!(Test-Path -LiteralPath $runtimePowerShell -PathType Leaf)){$runtimePowerShell='powershell.exe'}
  & $runtimePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runtimeBuilder -JdkHome $jdk.Home
  if($LASTEXITCODE -ne 0){throw "Windows Java runtime build failed: $LASTEXITCODE"}

  Write-Host "SynKinect Studio 1.0 rebuilt for both platforms. SHA-256: $windowsHash" -ForegroundColor Green
}finally{Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
