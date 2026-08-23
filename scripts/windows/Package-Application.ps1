[CmdletBinding()]
param(
    [string]$JdkHome = '',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AppRoot = Join-Path $RepoRoot 'applications\binaries\windows-x64'
$RuntimeBuilder = Join-Path $PSScriptRoot 'Build-ApplicationRuntime.ps1'
$RuntimeJava = Join-Path $AppRoot 'java\bin\java.exe'
if (!$Output) { $Output = Join-Path $RepoRoot 'dist\SynKinectStudio-windows-x64.zip' }

& $RuntimeBuilder -JdkHome $JdkHome
if ($LASTEXITCODE -ne 0) { throw "Portable runtime build failed with exit code $LASTEXITCODE." }
if (!(Test-Path -LiteralPath $RuntimeJava -PathType Leaf)) { throw "Release invariant violated: $RuntimeJava is missing." }

$required = @(
  'SynKinectStudio.cmd', 'lib\SynKinectStudio.jar', 'lib\core-4.4.6.jar',
  'lib\gluegen-rt-2.5.0.jar', 'lib\jogl-all-2.5.0.jar', 'data\studio.properties'
)
foreach ($relative in $required) {
  $path = Join-Path $AppRoot $relative
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release invariant violated: missing $relative" }
}

$outDir = Split-Path -Parent $Output
if (!(Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Compress-Archive -Path (Join-Path $AppRoot '*') -DestinationPath $Output -CompressionLevel Optimal
Write-Host "Portable Windows release created: $Output" -ForegroundColor Green
