param(
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$DriverMsiName,
    [Parameter(Mandatory=$true)][string]$FirmwareFileName,
    [Parameter(Mandatory=$true)][string]$DarkExe
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

if(!(Test-Path -LiteralPath $BundlePath -PathType Leaf)){throw "Kinect Runtime bundle not found: $BundlePath"}
if(!(Test-Path -LiteralPath $DarkExe -PathType Leaf)){throw "WiX v3 dark.exe not found: $DarkExe"}
if([string]::IsNullOrWhiteSpace($DriverMsiName)){throw 'DriverMsiName is empty.'}
if([string]::IsNullOrWhiteSpace($FirmwareFileName)){throw 'FirmwareFileName is empty.'}

$outputDirectory=[IO.Path]::GetDirectoryName($OutputPath)
if([string]::IsNullOrWhiteSpace($outputDirectory)){throw "Invalid output path: $OutputPath"}
New-Item -ItemType Directory -Force $outputDirectory|Out-Null

$temp=Join-Path $outputDirectory 'runtime-v1.8-burn-extract'
if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
New-Item -ItemType Directory -Force $temp|Out-Null

# KinectRuntime-v1.8-Setup.exe is a WiX Burn bundle.  /layout only prepares an
# offline bundle cache; it does not unpack attached MSI payloads.  Use the
# portable WiX v3 dark.exe directly so this build never requires the .NET SDK
# or an installed WiX toolset.
Write-Host 'Extracting the Kinect Runtime v1.8 Burn bundle with portable WiX v3...' -ForegroundColor DarkCyan
& $DarkExe '-nologo' '-x' $temp $BundlePath | Out-Host
$darkExit=$LASTEXITCODE
if($darkExit -ne 0){throw "WiX v3 dark.exe bundle extraction failed (exit $darkExit)."}

$allMsi=@(Get-ChildItem -LiteralPath $temp -Recurse -File -Filter '*.msi' -ErrorAction SilentlyContinue)
if($allMsi.Count -eq 0){
    throw "Kinect Runtime v1.8 bundle extraction produced no MSI payloads under $temp"
}

# Prefer the exact x86 driver package because it is the historical source of
# UACFirmware.  If Burn renamed the payload, try all Kinect driver MSIs, then
# all extracted MSIs.  The native MSI/CAB extractor is the final authority: it
# succeeds only when the requested UACFirmware stream actually exists.
$candidates=New-Object System.Collections.Generic.List[System.IO.FileInfo]
$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
function Add-MsiCandidate([System.IO.FileInfo]$Item){
    if($null -ne $Item -and $seen.Add($Item.FullName)){[void]$candidates.Add($Item)}
}

foreach($item in $allMsi | Where-Object{$_.Name -ieq $DriverMsiName}){Add-MsiCandidate $item}
foreach($item in $allMsi | Where-Object{$_.Name -like 'KinectDrivers-v1.8-*.WHQL.msi'} | Sort-Object Name,FullName){Add-MsiCandidate $item}
foreach($item in $allMsi | Where-Object{$_.Name -match '(?i)kinect.*driver.*\.msi$'} | Sort-Object Name,FullName){Add-MsiCandidate $item}
foreach($item in $allMsi | Sort-Object Name,FullName){Add-MsiCandidate $item}

$msiExtractor=Join-Path $PSScriptRoot 'Extract-KinectUacFirmware.ps1'
if(!(Test-Path -LiteralPath $msiExtractor -PathType Leaf)){throw "MSI/CAB extractor not found: $msiExtractor"}

$attempts=New-Object System.Collections.Generic.List[string]
$success=$false
foreach($driverMsi in $candidates){
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    Write-Host ("Trying UACFirmware extraction from {0}..." -f $driverMsi.Name) -ForegroundColor DarkCyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $msiExtractor `
        -MsiPath $driverMsi.FullName `
        -OutputPath $OutputPath `
        -ExpectedName $FirmwareFileName
    $extractExit=$LASTEXITCODE
    [void]$attempts.Add(("{0}:exit={1}" -f $driverMsi.Name,$extractExit))
    if($extractExit -eq 0 -and (Test-Path -LiteralPath $OutputPath -PathType Leaf)){
        $success=$true
        break
    }
}

if(!$success){
    throw ("UACFirmware was not found in the extracted Kinect Runtime v1.8 MSI payloads. Attempts: {0}" -f ($attempts -join '; '))
}

$item=Get-Item -LiteralPath $OutputPath
if($item.Length -lt 65536 -or $item.Length -gt 1048576){
    throw ("Extracted UACFirmware size is outside the conservative expected range: {0} bytes." -f $item.Length)
}
Write-Host ("Kinect Runtime v1.8 UACFirmware extraction: PASS (file={0}, bytes={1}, version=01.02.709.00, tool=WiX-v3-dark)" -f $item.Name,$item.Length) -ForegroundColor Green
