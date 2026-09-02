[CmdletBinding()]
param(
    [ValidateSet('Menu','Install','Status','OpenCamera','Tilt','StartupTilt','IpStatus','IpReset','IpToggle','OpenStudio','Uninstall')]
    [string]$Action='Menu'
)
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

function Find-StudioLauncher{
    $candidates=@(
        (Join-Path $Root 'studio\SynKinectStudio.cmd'),
        (Join-Path $Root 'SynKinectStudio\SynKinectStudio.cmd'),
        (Join-Path (Join-Path $Root '..\..\..') 'applications\binaries\windows-x64\SynKinectStudio.cmd')
    )
    foreach($candidate in $candidates){
        try{
            $full=[IO.Path]::GetFullPath($candidate)
            if(Test-Path -LiteralPath $full -PathType Leaf){return $full}
        }catch{}
    }
    return $null
}
function Start-StandardUserProcess([string]$FilePath,[string]$Arguments='',[string]$WorkingDirectory=''){
    if(!(Test-IsAdministrator)){
        $params=@{FilePath=$FilePath}
        if(![string]::IsNullOrWhiteSpace($Arguments)){$params.ArgumentList=$Arguments}
        if(![string]::IsNullOrWhiteSpace($WorkingDirectory)){$params.WorkingDirectory=$WorkingDirectory}
        Start-Process @params | Out-Null
        return
    }
    # Shell.Application is brokered by the desktop shell.  When Explorer is
    # running as the normal interactive user this deliberately drops the
    # elevated token instead of propagating administrator rights to Studio.
    $shell=New-Object -ComObject Shell.Application
    $shell.ShellExecute($FilePath,$Arguments,$WorkingDirectory,'open',1)
}
function Open-Studio{
    $studio=Find-StudioLauncher
    if([string]::IsNullOrWhiteSpace($studio)){
        Write-Host 'SynKinect Studio Windows launcher was not found in this distribution.' -ForegroundColor Yellow
        Write-Host 'Expected applications\binaries\windows-x64\SynKinectStudio.cmd or a bundled studio\SynKinectStudio.cmd.' -ForegroundColor DarkGray
        return
    }
    try{
        Start-StandardUserProcess $studio '' (Split-Path -Parent $studio)
        Write-Host ("SynKinect Studio opened as the standard desktop user: {0}" -f $studio) -ForegroundColor Green
    }catch{
        Write-Host 'Could not open SynKinect Studio as a standard user.' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
}

function Pause-Menu{Write-Host '';[void](Read-Host 'Press Enter to continue')}
function Header{
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (" {0} v{1}" -f $Product.Name,$Product.Version) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
}
function Start-ElevatedAction([string]$RequestedAction){
    if(Test-IsAdministrator){return $false}
    $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Action',$RequestedAction)
    try{
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args | Out-Null
        return $true
    }catch{
        Write-Host ("Administrator permission was not granted for {0}." -f $RequestedAction) -ForegroundColor Yellow
        return $false
    }
}
function Invoke-SelfAction([string]$RequestedAction){
    & $PSCommandPath -Action $RequestedAction
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
function Get-AudioBridgeRuntimeStatus{
    $path=Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{Ready=$false;Detail='no runtime status file'}}
    try{
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        $ageSeconds=[Math]::Max(0,([datetime]::UtcNow-$item.LastWriteTimeUtc).TotalSeconds)
        $values=@{}
        foreach($line in @(Get-Content -LiteralPath $path -ErrorAction Stop)){
            $parts=$line -split '=',2
            if($parts.Count -eq 2){$values[$parts[0].Trim()]=$parts[1].Trim()}
        }
        $stage=[string]$values['stage']
        $mode=[string]$values['capture_mode']
        $channels=0;$rate=0;$frames=0L
        [void][int]::TryParse([string]$values['capture_channels'],[ref]$channels)
        [void][int]::TryParse([string]$values['stream_sample_rate'],[ref]$rate)
        [void][long]::TryParse([string]$values['published_frames'],[ref]$frames)
        $fresh=($ageSeconds -le 5)
        $ready=($fresh -and $stage -eq 'uac-runtime-capturing' -and $channels -ge 4 -and $rate -eq 16000 -and $frames -gt 0)
        $detail=("stage={0}; mode={1}; channels={2}; stream={3} Hz; frames={4}; status-age={5:N1}s" -f $stage,$mode,$channels,$rate,$frames,$ageSeconds)
        return [pscustomobject]@{Ready=$ready;Detail=$detail}
    }catch{return [pscustomobject]@{Ready=$false;Detail=('status read failed: '+$_.Exception.Message)}}
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
    $audioServiceReady=Test-ServiceReady $Product.Services.AudioBridge
    $audioRuntime=Get-AudioBridgeRuntimeStatus
    $audioReady=($audioServiceReady -and $audioRuntime.Ready)
    $cameraIpEnabled=Get-CameraIpEnabled
    $cameraIpReady=Test-ServiceReady $Product.Services.CameraIp
    $cameraReady=(Test-Path -LiteralPath $WebcamCtl -PathType Leaf) -and ((Invoke-NativeCode $WebcamCtl @('status')) -eq 0)
    $systemReady=$brokerReady -and $cameraReady -and $cameraBridgeReady -and $audioReady -and (!$cameraIpEnabled -or $cameraIpReady)
    Show-State 'Kinect core system' $systemReady $(if($systemReady){'camera + scanner + raw microphone pipe active'}else{'run Install / Reinstall if this persists'})
    Show-State 'Virtual camera' $cameraReady 'stable 640x480/30 RGB consumer; never controls physical sensor mode'
    Show-State 'Scanner transport' $cameraBridgeReady 'continuous RGB + metric Depth'
    if($cameraIpEnabled){Show-State 'IP camera runtime' $cameraIpReady (('{0}:{1}; password protected; Private network profile' -f $Product.CameraIpPolicy.Bind,$Product.CameraIpPolicy.Port))}else{Show-State 'IP camera runtime' $true 'DISABLED by user'}
    Show-State 'Raw microphone pipe' $audioReady ($Product.AudioPipeName+'; '+$audioRuntime.Detail)
}
function Show-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Invoke-NativeCode $CameraIpCtl @('status') -Show)
    Write-Host ''
    Write-Host 'HTTP Basic authentication is enabled. The generated password is stored in the protected ProgramData configuration.' -ForegroundColor DarkGray
}
function Reset-CameraIpPassword{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    $code=Invoke-NativeCode $CameraIpCtl @('reset-password') -Show
    if($code -eq 0){[void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet);Start-Sleep -Milliseconds 400;Show-CameraIp}
}
function Set-CameraIpEnabled([bool]$Enabled){
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
    [void](Stop-ServiceBounded $Product.Services.CameraIp 4000 -ForceProcess -Quiet)
    $command=if($Enabled){'enable'}else{'disable'}
    $code=Invoke-NativeCode $CameraIpCtl @($command) -Show
    if($code -ne 0){return}
    $rule=[string]$Product.CameraIpPolicy.FirewallRuleName
    if($Enabled){
        [void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','delayed-auto'))
        if(![string]::IsNullOrWhiteSpace($rule)){[void](Invoke-NativeCode 'netsh.exe' @('advfirewall','firewall','set','rule',("name={0}" -f $rule),'new','enable=yes'))}
        [void](Start-ServiceBounded $Product.Services.CameraIp 6000 -Quiet);Start-Sleep -Milliseconds 400;Write-Host 'IP camera enabled.' -ForegroundColor Green;Show-CameraIp
    }else{
        [void](Invoke-NativeCode 'sc.exe' @('config',$Product.Services.CameraIp,'start=','demand'))
        if(![string]::IsNullOrWhiteSpace($rule)){[void](Invoke-NativeCode 'netsh.exe' @('advfirewall','firewall','set','rule',("name={0}" -f $rule),'new','enable=no'))}
        Write-Host 'IP camera disabled. Service autostart and firewall exposure are disabled; no IP-camera RGB consumer or LED lease remains.' -ForegroundColor Green
    }
}
function Toggle-CameraIp{
    if(!(Test-Path -LiteralPath $CameraIpCtl -PathType Leaf)){Write-Host 'IP-camera runtime is not installed. Run Install / Reinstall.' -ForegroundColor Yellow;return}
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

# The control panel itself is intentionally a standard-user process.  Only
# operations that mutate machine state cross the UAC boundary.
# When the Studio is launched directly from the clean source ZIP there is no
# native binary distribution yet.  Install/Reinstall owns that bootstrap:
# build the Windows runtime first, then delegate to the generated control panel
# so installation always consumes the exact artifacts that were just built.
if($Action -eq 'Install' -and (!(Test-Path -LiteralPath $Nui -PathType Leaf) -or !(Test-Path -LiteralPath $Setup -PathType Leaf))){
    $sourceBuild=Join-Path $Root 'BUILD.cmd'
    $builtControl=[IO.Path]::GetFullPath((Join-Path $Root '..\binaries\system\Kinect.ps1'))
    if(Test-Path -LiteralPath $sourceBuild -PathType Leaf){
        Header
        Write-Host 'Native driver/runtime is not built yet. Building the clean v1.0 distribution first...' -ForegroundColor Cyan
        $previousParent=$env:REMOLD_BUILD_PARENT
        try{
            $env:REMOLD_BUILD_PARENT='1'
            & cmd.exe /d /c ('"{0}"' -f $sourceBuild)
            $buildCode=$LASTEXITCODE
        }finally{
            if($null -eq $previousParent){Remove-Item Env:REMOLD_BUILD_PARENT -ErrorAction SilentlyContinue}else{$env:REMOLD_BUILD_PARENT=$previousParent}
        }
        if($buildCode -ne 0){Write-Host ("Native build failed with code {0}." -f $buildCode) -ForegroundColor Red;Pause-Menu;return}
        if(!(Test-Path -LiteralPath $builtControl -PathType Leaf)){Write-Host 'Build completed but the generated Kinect control script was not found.' -ForegroundColor Red;Pause-Menu;return}
        & $builtControl -Action Install
        return
    }
}
$PrivilegedActions=@('Install','IpReset','IpToggle','Uninstall')
if($Action -ne 'Menu' -and ($PrivilegedActions -contains $Action) -and !(Test-IsAdministrator)){
    Header
    Write-Host ("{0} changes Windows system state and will now request administrator permission." -f $Action) -ForegroundColor Cyan
    if(Start-ElevatedAction $Action){
        Write-Host 'The elevated operation was started in a separate window. This control panel remains non-administrator.' -ForegroundColor DarkGray
    }
    return
}
if($Action -ne 'Menu'){
    Header
    switch($Action){
        'Install'{try{& $Install -DistributionRoot $Root -Simple}catch{Write-Host '';Write-Host 'INSTALLATION FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}}
        'Status'{Show-Status}
        'OpenCamera'{try{Start-Process 'microsoft.windows.camera:'}catch{Write-Host 'Could not open Windows Camera.' -ForegroundColor Yellow}}
        'Tilt'{Set-Tilt}
        'StartupTilt'{if(Need-Tools){$code=Invoke-NativeCode $Nui @('tilt',[string]$Product.StartupTiltDegrees) -Show;if($code -eq 0){Write-Host ("Tilt returned to the {0:+#;-#;0} degree startup pose." -f $Product.StartupTiltDegrees) -ForegroundColor Green}}}
        'IpStatus'{Show-CameraIp}
        'IpReset'{Reset-CameraIpPassword}
        'IpToggle'{Toggle-CameraIp}
        'OpenStudio'{Open-Studio}
        'Uninstall'{$confirm=Read-Host 'Type REMOVE to confirm';if($confirm -ceq 'REMOVE'){try{& $Uninstall -DistributionRoot $Root}catch{Write-Host '';Write-Host 'UNINSTALL FAILED' -ForegroundColor Red;Write-Host $_.Exception.Message -ForegroundColor Red}}else{Write-Host 'Canceled.'}}
    }
    Write-Host '';Write-Host 'Command completed. You can close this window.' -ForegroundColor DarkGray
    Pause-Menu
    return
}
while($true){
    Header
    Write-Host '1  Install / Reinstall'
    Write-Host '2  Status'
    Write-Host '3  Open Windows Camera (RGB only)'
    Write-Host '4  Set manual Tilt'
    Write-Host ("5  Return Tilt to startup pose ({0:+#;-#;0} degrees)" -f $Product.StartupTiltDegrees)
    Write-Host '6  Show IP camera URLs / credentials'
    Write-Host '7  Reset IP camera password'
    Write-Host '8  Enable / Disable IP camera'
    Write-Host '9  Open SynKinect Studio (Windows)'
    Write-Host '10 Uninstall'
    Write-Host '0  Exit'
    Write-Host ''
    $choice=(Read-Host 'Choose').Trim().ToUpperInvariant()
    switch($choice){
        '1'{Header;Invoke-SelfAction 'Install';Pause-Menu}
        '2'{Header;Show-Status;Pause-Menu}
        '3'{Header;try{Start-Process 'microsoft.windows.camera:'}catch{Write-Host 'Could not open Windows Camera.' -ForegroundColor Yellow};Start-Sleep -Milliseconds 500}
        '4'{Header;Set-Tilt;Pause-Menu}
        '5'{Header;if(Need-Tools){$code=Invoke-NativeCode $Nui @('tilt',[string]$Product.StartupTiltDegrees) -Show;if($code -eq 0){Write-Host ("Tilt returned to the {0:+#;-#;0} degree startup pose." -f $Product.StartupTiltDegrees) -ForegroundColor Green}};Pause-Menu}
        '6'{Header;Show-CameraIp;Pause-Menu}
        '7'{Header;Invoke-SelfAction 'IpReset';Pause-Menu}
        '8'{Header;Invoke-SelfAction 'IpToggle';Pause-Menu}
        '9'{Header;Open-Studio;Start-Sleep -Milliseconds 500}
        '10'{Header;Invoke-SelfAction 'Uninstall';Pause-Menu}
        '0'{return}
        default{Write-Host 'Invalid option.' -ForegroundColor Yellow;Start-Sleep -Milliseconds 700}
    }
}
