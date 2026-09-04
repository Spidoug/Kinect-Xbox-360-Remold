[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

$Toolchain=Join-Path $PSScriptRoot 'Toolchain.ps1'
$OfficialConfig=Join-Path $PSScriptRoot 'wdk-vscommunity.dsc.yaml'
$VsConfig=Join-Path $PSScriptRoot 'wdk-desktop.vsconfig'

function Test-Toolchain {
    try {
        $null=& $Toolchain
        return $true
    } catch {
        Write-Host ("Windows native toolchain not ready: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Get-WinGetPath {
    $command=Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if($command -and $command.Source){return $command.Source}

    if($env:LOCALAPPDATA){
        $alias=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if(Test-Path -LiteralPath $alias -PathType Leaf){return $alias}
    }
    return $null
}

function Invoke-WinGet {
    param(
        [string[]]$Arguments,
        [string]$Label,
        [switch]$AllowFailure
    )
    Write-Host ''
    Write-Host ("[toolchain] {0}" -f $Label) -ForegroundColor Cyan
    $previousPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try {
        & $script:WinGet @Arguments 2>&1 | ForEach-Object { Write-Host $_.ToString() }
        $code=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$previousPreference
    }
    if($code -ne 0){
        Write-Host ("WinGet exit code: {0}" -f $code) -ForegroundColor Yellow
        if(!$AllowFailure){throw ("WinGet failed while {0}." -f $Label)}
    }
    return $code
}

function Get-VisualStudioInstance {
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(!(Test-Path -LiteralPath $vswhere -PathType Leaf)){return $null}
    $path=& $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1
    if([string]::IsNullOrWhiteSpace([string]$path)){return $null}
    return ([string]$path).Trim()
}

function Invoke-VisualStudioConfigRepair {
    if(!(Test-Path -LiteralPath $VsConfig -PathType Leaf)){return $false}
    $installPath=Get-VisualStudioInstance
    if([string]::IsNullOrWhiteSpace($installPath)){return $false}

    $setup=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
    if(!(Test-Path -LiteralPath $setup -PathType Leaf)){return $false}

    Write-Host ''
    Write-Host '[toolchain] Existing Visual Studio detected; importing the official WDK desktop component set...' -ForegroundColor Cyan
    $argumentLine='modify --installPath "{0}" --config "{1}" --passive --norestart' -f $installPath,$VsConfig
    try {
        $process=Start-Process -FilePath $setup -ArgumentList $argumentLine -Verb RunAs -Wait -PassThru
        if($process.ExitCode -ne 0){
            Write-Host ("Visual Studio Installer exit code: {0}" -f $process.ExitCode) -ForegroundColor Yellow
            return $false
        }
        return $true
    } catch {
        Write-Host ("Visual Studio component repair could not run: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

if(Test-Toolchain){
    Write-Host 'Visual Studio C++ / Windows SDK / WDK toolchain: READY' -ForegroundColor Green
    exit 0
}

$script:WinGet=Get-WinGetPath
if([string]::IsNullOrWhiteSpace($script:WinGet)){
    throw 'WinGet was not found. Windows 11 normally provides it through Microsoft App Installer. Install/update App Installer from Microsoft Store and run BUILD.cmd again.'
}

if(!(Test-Path -LiteralPath $OfficialConfig -PathType Leaf)){
    throw "Official V1 WDK WinGet configuration is missing: $OfficialConfig"
}
if(!(Test-Path -LiteralPath $VsConfig -PathType Leaf)){
    throw "Official V1 Visual Studio component configuration is missing: $VsConfig"
}

$wingetVersion=& $script:WinGet --version 2>$null | Select-Object -First 1
Write-Host ("WinGet: {0}" -f $wingetVersion) -ForegroundColor DarkGray
Write-Host 'Native prerequisites are missing. WinGet may request Windows administrator approval while installing Microsoft development components.' -ForegroundColor Yellow

# First choice: Microsoft's current WDK machine configuration. It installs one
# coherent Visual Studio + desktop driver components + Windows SDK/WDK 28000
# environment and is idempotent on machines where some pieces already exist.
[void](Invoke-WinGet @(
    'configure','-f',$OfficialConfig,
    '--accept-configuration-agreements',
    '--disable-interactivity'
) 'Applying Microsoft WDK V1 development configuration' -AllowFailure)

Start-Sleep -Seconds 2
if(Test-Toolchain){
    Write-Host 'Visual Studio C++ / Windows SDK / WDK toolchain: READY' -ForegroundColor Green
    exit 0
}

# If an existing Visual Studio installation was only missing WDK/C++ components,
# import the same official .vsconfig directly into that instance before falling
# back to individual WinGet packages.
[void](Invoke-VisualStudioConfigRepair)
Start-Sleep -Seconds 2
if(Test-Toolchain){
    Write-Host 'Visual Studio C++ / Windows SDK / WDK toolchain: READY' -ForegroundColor Green
    exit 0
}

# Fallback for WinGet installations where the configuration processor cannot be
# initialized. Keep the exact same Microsoft package family and component file.
$common=@('--exact','--source','winget','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
$vsOverride='--passive --wait --norestart --config "{0}"' -f $VsConfig
[void](Invoke-WinGet (@('install','--id','Microsoft.VisualStudio.Community')+$common+@('--override',$vsOverride)) 'Installing Visual Studio Community with the WDK desktop component set' -AllowFailure)
[void](Invoke-WinGet (@('install','--id','Microsoft.WindowsSDK.10.0.28000')+$common) 'Installing Windows SDK 10.0.28000' -AllowFailure)
[void](Invoke-WinGet (@('install','--id','Microsoft.WindowsWDK.10.0.28000')+$common) 'Installing Windows Driver Kit 10.0.28000' -AllowFailure)

Start-Sleep -Seconds 3
if(Test-Toolchain){
    Write-Host 'Visual Studio C++ / Windows SDK / WDK toolchain: READY' -ForegroundColor Green
    exit 0
}

throw ('Automatic Microsoft toolchain bootstrap did not produce a usable MSBuild/SDK/WDK environment. ' +
       'Review the WinGet/Visual Studio output above. If Windows requested a restart, restart once and run BUILD.cmd again; all successfully installed components will be reused.')
