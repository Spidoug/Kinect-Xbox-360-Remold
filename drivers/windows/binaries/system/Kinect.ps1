[CmdletBinding()]
param()
$ErrorActionPreference='Continue'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$Nui=Join-Path $Root 'tools\Kinect360RemoldNui.exe'
$Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
$WebcamCtl=Join-Path $Root 'webcam\Kinect360RemoldWebcam.exe'
$CameraIpCtl=Join-Path (Join-Path $env:ProgramFiles $Product.Name) 'Kinect360RemoldCameraIp.exe'
$Install=Join-Path $PSScriptRoot 'Install.ps1'
$Uninstall=Join-Path $PSScriptRoot 'Uninstall.ps1'

function Pause-Menu{Write-Host '';[void](Read-Host 'Press Enter to continue')}
function Header{
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (" {0} v{1}" -f $Product.Name,$Product.Version) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}
function Ensure-Admin{
    if(Test-IsAdministrator){return}
    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    try{Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args|Out-Null;exit 0}
    catch{Write-Host 'Administrator permission is required to open the Kinect control panel.' -ForegroundColor Yellow;Pause-Menu;exit 1}
}
function Need-Tools{
    if(!(Test-Path -LiteralPath $Nui -PathType Leaf) -or !(Test-Path -LiteralPath $Setup -PathType Leaf)){
        Write-Host 'Kinect tools were not found. Run BUILD.cmd again.' -ForegroundColor Red
        return $false
    }
    return $true
}
function Show-State([string]$Name,[bool]$Ready,[string]$Detail=''){
    $state=if($Ready){'READY'}else{'NOT READY'}
    $color=if($Ready){'Green'}else{'Yellow'}
    $suffix=if([string]::IsNullOrWhiteSpace($Detail)){''}else{" - $Detail"}
    Write-Host (("{0,-26}: {1}{2}" -f $Name,$state,$suffix)) -ForegroundColor $color
}
function Test-ServiceReady([string]$Name){
    $service=Get-Service $Name -ErrorAction SilentlyContinue
    return ($null -ne $service -and $service.Status -eq 'Running')
}
function Get-CameraIpEnabled{
    $cfg=Join-Path (Join-Path $env:ProgramData $Product.Name) 'camera-ip.ini'
    if(!(Test-Path -LiteralPath $cfg -PathType Leaf)){return [bool]$Product.CameraIpPolicy.Enabled}
    try{
        $line=Get-Content -LiteralPath $cfg -ErrorAction Stop|Where-Object{$_ -match '^\s*enabled\s*='}|Select-Object -First 1
        if($null -ne $line){return (($line -split '=',2)[1].Trim() -match '^(?i:true|1)$')}
    }catch{}
    return [bool]$Product.CameraIpPolicy.Enabled
}
function Show-Status{
    if(!(Need-Tools)){return}
    $brokerReady=Test-ServiceReady $Product.Services.Broker
    $cameraBridgeReady=Test-ServiceReady $Product.Services.CameraBridge
    $audioReady=Test-ServiceReady $Product.Services.AudioBridge
    $cameraIpEnabled=Get-CameraIpEnabled
    $cameraIpReady=Test-ServiceReady $Product.Services.CameraIp
    $cameraReady=(Test-Path -LiteralPath $WebcamCtl -PathType Leaf) -and ((Invoke-NativeCode $WebcamCtl @('status')) -eq 0)
    $systemReady=$brokerReady -and $cameraReady -and $cameraBridgeReady -and $audioReady -and (!$cameraIpEnabled -or $cameraIpReady)
    Show-State 'Kinect core system' $systemReady $(if($systemReady){'camera + scanner + raw microphone pipe active'}else{'run Install / Repair if this persists'})
    Show-State 'Virtual camera' $cameraReady 'RGB; solid-green while consumed; smart tilt only while active'
    Show-State 'Scanner transport' $cameraBridgeReady 'continuous RGB + metric Depth'
    if($cameraIpEnabled){Show-State 'IP camera runtime' $cameraIpReady (('{0}:{1}; password protected; Private network profile' -f $Product.CameraIpPolicy.Bind,$Product.CameraIpPolicy.Port))}else{Show-State 'IP camera runtime' $true 'DISABLED by user'}
    Show-State 'Raw microphone pipe' $audioReady ($Product.AudioPipeName+'; 4 x S32LE for Processing')
}
function Show-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Repair.' -ForegroundColor Yellow;return}
    [void](Invoke-NativeCode $CameraIpCtl @('status') -Show)
    Write-Host ''
    Write-Host 'HTTP Basic authentication is enabled. The generated password is stored in the protected ProgramData configuration.' -ForegroundColor DarkGray
}
function Reset-CameraIpPassword{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Repair.' -ForegroundColor Yellow;return}
    Stop-Service $Product.Services.CameraIp -Force -ErrorAction SilentlyContinue
    $code=Invoke-NativeCode $CameraIpCtl @('reset-password') -Show
    if($code -eq 0){Start-Service $Product.Services.CameraIp -ErrorAction SilentlyContinue;Start-Sleep -Milliseconds 400;Show-CameraIp}
}
function Set-CameraIpEnabled([bool]$Enabled){
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Repair.' -ForegroundColor Yellow;return}
    Stop-Service $Product.Services.CameraIp -Force -ErrorAction SilentlyContinue
    $command=if($Enabled){'enable'}else{'disable'}
    $code=Invoke-NativeCode $CameraIpCtl @($command) -Show
    if($code -ne 0){return}
    $rule=[string]$Product.CameraIpPolicy.FirewallRuleName
    if($Enabled){
        [void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','delayed-auto'))
        if(![string]::IsNullOrWhiteSpace($rule)){[void](Invoke-NativeCode 'netsh.exe' @('advfirewall','firewall','set','rule',("name={0}" -f $rule),'new','enable=yes'))}
        Start-Service $Product.Services.CameraIp -ErrorAction SilentlyContinue;Start-Sleep -Milliseconds 400;Write-Host 'IP camera enabled.' -ForegroundColor Green;Show-CameraIp
    }else{
        [void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','demand'))
        if(![string]::IsNullOrWhiteSpace($rule)){[void](Invoke-NativeCode 'netsh.exe' @('advfirewall','firewall','set','rule',("name={0}" -f $rule),'new','enable=no'))}
        Write-Host 'IP camera disabled. Service autostart and firewall exposure are disabled; no IP-camera RGB consumer or LED lease remains.' -ForegroundColor Green
    }
}
function Toggle-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Repair.' -ForegroundColor Yellow;return}
    $service=Get-Service $Product.Services.CameraIp -ErrorAction SilentlyContinue
    $running=($null -ne $service -and $service.Status -eq 'Running')
    if($running){Set-CameraIpEnabled $false}else{Set-CameraIpEnabled $true}
}
function Set-Tilt{
    if(!(Need-Tools)){return}
    $text=Read-Host ("Tilt angle in degrees ({0} to {1}; 0 is geometric center)" -f $Product.TiltMinDegrees,$Product.TiltMaxDegrees)
    $value=0
    if(![int]::TryParse($text,[ref]$value)){Write-Host 'Invalid value.' -ForegroundColor Yellow;return}
    $value=[Math]::Max($Product.TiltMinDegrees,[Math]::Min($Product.TiltMaxDegrees,$value))
    $code=Invoke-NativeCode $Nui @('tilt',[string]$value) -Show
    if($code -eq 0){Write-Host ("Tilt set to {0} degrees." -f $value) -ForegroundColor Green}
}

Ensure-Admin
while($true){
    Header
    Write-Host '1  Install / Repair'
    Write-Host '2  Status'
    Write-Host '3  Open Windows Camera (RGB only)'
    Write-Host '4  Set manual Tilt'
    Write-Host ("5  Return Tilt to startup pose ({0:+#;-#;0} degrees)" -f $Product.StartupTiltDegrees)
    Write-Host '6  Show IP camera URLs / credentials'
    Write-Host '7  Reset IP camera password'
    Write-Host '8  Enable / Disable IP camera'
    Write-Host '9  Uninstall'
    Write-Host '0  Exit'
    Write-Host ''
    $choice=(Read-Host 'Choose').Trim().ToUpperInvariant()
    switch($choice){
        '1'{Header;try{& $Install -DistributionRoot $Root -Simple}catch{Write-Host '';Write-Host 'INSTALLATION FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red;Write-Host 'The installer error was trapped by the control panel; this window will remain open.' -ForegroundColor Yellow};Pause-Menu}
        '2'{Header;Show-Status;Pause-Menu}
        '3'{Header;try{Start-Process 'microsoft.windows.camera:'}catch{Write-Host 'Could not open Windows Camera.' -ForegroundColor Yellow};Start-Sleep -Milliseconds 500}
        '4'{Header;Set-Tilt;Pause-Menu}
        '5'{Header;if(Need-Tools){$code=Invoke-NativeCode $Nui @('tilt',[string]$Product.StartupTiltDegrees) -Show;if($code -eq 0){Write-Host ("Tilt returned to the {0:+#;-#;0} degree startup pose." -f $Product.StartupTiltDegrees) -ForegroundColor Green}};Pause-Menu}
        '6'{Header;Show-CameraIp;Pause-Menu}
        '7'{Header;Reset-CameraIpPassword;Pause-Menu}
        '8'{Header;Toggle-CameraIp;Pause-Menu}
        '9'{Header;$confirm=Read-Host 'Type REMOVE to confirm';if($confirm -ceq 'REMOVE'){try{& $Uninstall -DistributionRoot $Root}catch{Write-Host '';Write-Host 'UNINSTALL FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}}else{Write-Host 'Canceled.'};Pause-Menu}
        '0'{return}
        default{Write-Host 'Invalid option.' -ForegroundColor Yellow;Start-Sleep -Milliseconds 700}
    }
}
