[CmdletBinding()]
param([ValidateSet('Release')][string]$Configuration='Release',[string]$LogPath='')
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$Product=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Product.psd1')
$Dist=Join-Path (Split-Path -Parent $Root) 'binaries'
$CameraRoot=Join-Path $Root 'components\camera'
$DeviceRoot=Join-Path $Root 'components\device'
. (Join-Path $PSScriptRoot 'Common.ps1')
function Copy-Dir([string]$Source,[string]$Destination){if(Test-Path $Destination){Remove-Item $Destination -Recurse -Force};Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force}
if([string]::IsNullOrWhiteSpace($LogPath)){
    $logDir=Join-Path $Root 'logs';New-Item -ItemType Directory -Force $logDir|Out-Null
    $LogPath=Join-Path $logDir ("build-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Force (Split-Path -Parent $LogPath)|Out-Null
$transcript=$false;$failed=$false
try{
    Start-Transcript -LiteralPath $LogPath -Force|Out-Null;$transcript=$true
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (" {0} - v{1}" -f $Product.Name,$Product.Version) -ForegroundColor Cyan
    Write-Host (" by {0} - {1}" -f $Product.Author,$Product.Handle) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    $developmentCert=Get-OrCreateDevelopmentCertificate $Product
    Remove-Item -LiteralPath $Dist -Recurse -Force -ErrorAction SilentlyContinue

    Write-BuildStage '[1/4] Building camera and virtual webcam...'
    $cameraLog=Join-Path $Root 'logs\camera.log'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $CameraRoot 'Build.ps1') -Configuration $Configuration -LogPath $cameraLog -SigningThumbprint $developmentCert.Thumbprint
    if($LASTEXITCODE){throw "Camera build failed. See $cameraLog"}

    Write-BuildStage '[2/4] Building WinUSB Motor and WinUSB NUI Audio transport...'
    $deviceLog=Join-Path $Root 'logs\device.log'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DeviceRoot 'Build.ps1') -Configuration $Configuration -LogPath $deviceLog -SigningThumbprint $developmentCert.Thumbprint
    if($LASTEXITCODE){throw "Device build failed. See $deviceLog"}

    Write-BuildStage '[3/4] Building setup utility...'
    $Tools=& (Join-Path $PSScriptRoot 'Toolchain.ps1') -RequirePython:$false
    $setupProject=Join-Path $Root 'source\setup\Kinect360RemoldSetup.vcxproj'
    & $Tools.MSBuild $setupProject /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion)
    if($LASTEXITCODE){throw 'Kinect360RemoldSetup build failed.'}
    $setup=Get-ChildItem -LiteralPath (Split-Path -Parent $setupProject) -Recurse -File -Filter Kinect360RemoldSetup.exe|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(!$setup){throw 'Kinect360RemoldSetup.exe not found after build.'};Assert-NoExternalVcRuntime $setup.FullName $Tools

    Write-BuildStage '[4/4] Creating unified distribution...'
    New-Item -ItemType Directory -Force $Dist|Out-Null
    New-Item -ItemType Directory -Force (Join-Path $Dist 'drivers'),(Join-Path $Dist 'tools'),(Join-Path $Dist 'system'),(Join-Path $Dist 'runtime')|Out-Null
    Copy-Dir (Join-Path $CameraRoot 'dist\camera') (Join-Path $Dist 'drivers\camera')
    Copy-Dir (Join-Path $CameraRoot 'dist\webcam') (Join-Path $Dist 'webcam')
    Copy-Dir (Join-Path $CameraRoot 'dist\runtime') (Join-Path $Dist 'runtime')
    Copy-Dir (Join-Path $DeviceRoot 'dist\device') (Join-Path $Dist 'drivers\device')
    Copy-Dir (Join-Path $DeviceRoot 'dist\nui') (Join-Path $Dist 'drivers\nui')
    Copy-Dir (Join-Path $DeviceRoot 'dist\audio') (Join-Path $Dist 'drivers\audio')
    Copy-Dir (Join-Path $DeviceRoot 'dist\tools') (Join-Path $Dist 'tools')
    Copy-Item -LiteralPath $setup.FullName -Destination (Join-Path $Dist 'tools\Kinect360RemoldSetup.exe') -Force
    Copy-Item -LiteralPath (Join-Path $Root 'install\KINECT.cmd') -Destination (Join-Path $Dist 'KINECT.cmd') -Force
    foreach($file in @('Kinect.ps1','Install.ps1','Uninstall.ps1','Common.ps1')){Copy-Item -LiteralPath (Join-Path $Root "install\$file") -Destination (Join-Path $Dist "system\$file") -Force}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Product.psd1') -Destination (Join-Path $Dist 'system\Product.psd1') -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $Root) 'README.md') -Destination (Join-Path $Dist 'README.txt') -Force
    @($Product.Name,"v$($Product.Version)","by $($Product.Author)",$Product.Handle) | Set-Content -LiteralPath (Join-Path $Dist 'VERSION.txt') -Encoding ASCII

    # The development signer covers the PnP catalogs. Camera and Motor keep
    # Microsoft's inbox winusb.sys; NUI Audio uses no authored kernel binary.
    # 02AD is WinUSB only for the
    # Microsoft UACFirmware upload; 02BB MI_02 then uses inbox USB Audio/WASAPI.
    # The build/installer never mutates BCD, Secure Boot, or Code Integrity policy.
    $catalogs=@(Get-ChildItem -LiteralPath (Join-Path $Dist 'drivers') -Recurse -File -Filter '*.cat' | Sort-Object FullName | Select-Object -ExpandProperty FullName)
    if($catalogs.Count -ne $Product.DriverPackages.Count){throw "Expected $($Product.DriverPackages.Count) PnP catalogs, found $($catalogs.Count)."}
    foreach($catalog in $catalogs){Require-File $catalog 'PnP catalog';Sign-CodeArtifact $catalog $developmentCert $Tools 'PnP catalog'}
    $publicCert=Join-Path $Dist 'Kinect360RemoldDevelopment.cer'
    Export-Certificate -Cert $developmentCert -FilePath $publicCert -Type CERT -Force|Out-Null
    Require-File $publicCert 'Development public certificate'
    Write-Host ("Development package certificate: {0}" -f $developmentCert.Subject) -ForegroundColor Yellow
    Write-Host ("Development certificate thumbprint: {0}" -f $developmentCert.Thumbprint) -ForegroundColor DarkGray
    Write-Host 'PnP catalogs: DEVELOPMENT-SIGNED; Motor/Camera and NUI Audio boot use Microsoft winusb.sys; NUI Audio runtime uses inbox USB Audio/WASAPI' -ForegroundColor Green

    $expected=@{
        'drivers\camera'=@('Kinect360RemoldCamera.inf','Kinect360RemoldCamera.cat','Kinect360RemoldCameraBridge.exe');
        'webcam'=@('Kinect360RemoldCameraSource.dll','Kinect360RemoldWebcam.exe');
        'runtime'=@('Kinect360RemoldCameraIp.exe');
        'drivers\device'=@('Kinect360RemoldDevice.inf','Kinect360RemoldDevice.cat','Kinect360RemoldBroker.exe');
        'drivers\nui'=@('Kinect360RemoldNui.inf','Kinect360RemoldNui.cat');
        'drivers\audio'=@('Kinect360RemoldAudio.inf','Kinect360RemoldAudio.cat','Kinect360RemoldAudioBridge.exe');
        'tools'=@('Kinect360RemoldNui.exe','Kinect360RemoldSetup.exe');
        'system'=@('Kinect.ps1','Install.ps1','Uninstall.ps1','Common.ps1','Product.psd1');
        '.'=@('KINECT.cmd','Kinect360RemoldDevelopment.cer')
    }
    foreach($folder in $expected.Keys){foreach($file in $expected[$folder]){Require-File (Join-Path (Join-Path $Dist $folder) $file) "$folder\$file"}}
    Write-Host '';Write-Host ("{0} v{1} BUILD COMPLETE" -f $Product.Name,$Product.Version) -ForegroundColor Green
    Write-Host "Output: $Dist" -ForegroundColor Green
    Write-Host 'Open ..\binaries\KINECT.cmd and choose Install / Repair. The installer trusts the packaged development certificate before PnP staging.' -ForegroundColor Yellow
}catch{
    $failed=$true;Write-Host '';Write-Host ("{0} BUILD FAILED" -f $Product.Name) -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red;Write-Host "Full log: $LogPath" -ForegroundColor Yellow
}finally{if($transcript){try{Stop-Transcript|Out-Null}catch{Write-Warning ("Could not stop build transcript cleanly: {0}" -f $_.Exception.Message)}}}
if($failed){exit 1};exit 0
