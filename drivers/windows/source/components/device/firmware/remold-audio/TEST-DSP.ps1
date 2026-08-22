[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$FirmwareRoot=$PSScriptRoot
$ProjectRoot=(Resolve-Path (Join-Path $FirmwareRoot '..\..\..\..')).Path
$Tools=& (Join-Path $ProjectRoot 'build\Toolchain.ps1')
$Project=Join-Path $FirmwareRoot 'tests\RemoldAcousticDspTests.vcxproj'
& $Tools.MSBuild $Project /m /t:Rebuild /p:Configuration=Release /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset)
if($LASTEXITCODE){exit $LASTEXITCODE}
$Exe=Get-ChildItem -LiteralPath (Join-Path $FirmwareRoot 'tests') -Recurse -File -Filter RemoldAcousticDspTests.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(!$Exe){throw 'RemoldAcousticDspTests.exe was not produced.'}
& $Exe.FullName
exit $LASTEXITCODE
