[CmdletBinding()]
param([string]$DistributionRoot='')
$ErrorActionPreference='Stop'
$Root=if([string]::IsNullOrWhiteSpace($DistributionRoot)){Split-Path -Parent $PSScriptRoot}else{[IO.Path]::GetFullPath($DistributionRoot)}
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$ProductName=$Product.Name

function Remove-VirtualCameraDevices{
    try{
        $devices=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{$_.PNPDeviceID -like 'SWD\VCAMDEVAPI*' -and $_.Name -eq $Product.WindowsCameraName})
        foreach($device in $devices){
            $result=Invoke-Native 'pnputil.exe' @('/remove-device',$device.PNPDeviceID)
            if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not remove virtual camera device {0}." -f $device.PNPDeviceID)}
        }
    }catch{Write-Warning ("Could not enumerate Remold virtual camera devices: {0}" -f $_.Exception.Message)}
}

function Remove-DriverStorePackages{
    $names=@($Product.DriverPackages|ForEach-Object{Split-Path $_.Inf -Leaf})
    try{
        $drivers=@(Get-WindowsDriver -Online -All -ErrorAction Stop |
            Where-Object{$_.OriginalFileName -and ((Split-Path $_.OriginalFileName -Leaf) -in $names)})
        foreach($driver in $drivers){
            if(!$driver.Driver){continue}
            Write-Host ("Removing {0}..." -f $driver.Driver) -ForegroundColor Cyan
            $result=Invoke-Native 'pnputil.exe' @('/delete-driver',$driver.Driver,'/uninstall','/force')
            if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not delete {0}." -f $driver.Driver)}
        }
    }catch{Write-Warning ("Could not enumerate driver packages: {0}" -f $_.Exception.Message)}
}

Require-Administrator 'Administrator privileges are required for driver removal.'
$Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
$Runtime=Join-Path $env:ProgramFiles $ProductName
$PackagedCtl=Join-Path $Root 'webcam\Kinect360RemoldWebcam.exe'
$RuntimeCtl=Join-Path $Runtime 'Kinect360RemoldWebcam.exe'
$Ctl=if(Test-Path -LiteralPath $PackagedCtl -PathType Leaf){$PackagedCtl}else{$RuntimeCtl}

$servicesStillRunning=New-Object System.Collections.Generic.List[string]
foreach($serviceKey in @($Product.ServiceOrder)){
    $service=$Product.Services[$serviceKey]
    if(!(Stop-ServiceBounded $service 4500 -ForceProcess)){[void]$servicesStillRunning.Add($service)}
}
if($servicesStillRunning.Count){
    Write-Warning ("Some Remold services could not be stopped and may require one Windows restart to finish file cleanup: {0}" -f ($servicesStillRunning -join ', '))
}
if($null -ne $Product.CameraIpPolicy -and ![string]::IsNullOrWhiteSpace([string]$Product.CameraIpPolicy.FirewallRuleName)){
    [void](Invoke-Native 'netsh.exe' @('advfirewall','firewall','delete','rule',("name={0}" -f $Product.CameraIpPolicy.FirewallRuleName)))
}
if(Test-Path -LiteralPath $Ctl -PathType Leaf){
    $result=Invoke-Native $Ctl @('remove')
    if($result.ExitCode -ne 0){Show-Native $result;Write-Warning 'Virtual camera removal returned an error; PnP cleanup will continue.'}
}
Remove-VirtualCameraDevices

if(Test-Path -LiteralPath $Setup -PathType Leaf){
    foreach($package in @($Product.DriverPackages|Where-Object{!([string]::IsNullOrWhiteSpace($_.RootHardwareId))})){
        $result=Invoke-Native $Setup @('remove',$package.RootHardwareId)
        if($result.ExitCode -ne 0){Show-Native $result;Write-Warning ("Could not remove root device {0}." -f $package.RootHardwareId)}
    }
}
Remove-DriverStorePackages

try{
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object{$_.Name -like ($Product.Prefix+'*')})
    foreach($service in $services){[void](Invoke-Native 'sc.exe' @('delete',$service.Name))}
}catch{Write-Warning ("Could not enumerate product services: {0}" -f $_.Exception.Message)}

if(Test-Path -LiteralPath $Runtime){
    try{Remove-Item -LiteralPath $Runtime -Recurse -Force -ErrorAction Stop}
    catch{Write-Warning ("Runtime folder remains in use: {0}" -f $Runtime)}
}
foreach($programData in @((Join-Path $env:ProgramData $ProductName),(Join-Path $env:ProgramData 'Kinect360Remold'))){
    if(Test-Path -LiteralPath $programData){
        try{Remove-Item -LiteralPath $programData -Recurse -Force -ErrorAction Stop}
        catch{Write-Warning ("Runtime configuration folder remains in use: {0}" -f $programData)}
    }
}

$DevelopmentCert=Join-Path $Root 'Kinect360RemoldDevelopment.cer'
if(Test-Path -LiteralPath $DevelopmentCert -PathType Leaf){
    try{
        $cert=Get-CertificateFromFile $DevelopmentCert
        foreach($storeName in @('TrustedPublisher','Root')){Remove-CertificateFromMachineStore $cert $storeName}
        Write-Host 'Removed Kinect Remold development trust certificate.' -ForegroundColor DarkCyan
    }catch{Write-Warning ("Could not remove development trust certificate: {0}" -f $_.Exception.Message)}
}

Write-Host ("{0} v{1} UNINSTALL COMPLETE" -f $ProductName,$Product.Version) -ForegroundColor Green
