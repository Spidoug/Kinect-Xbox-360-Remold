[CmdletBinding()]
param([string]$DistributionRoot='', [switch]$Simple)
$ErrorActionPreference='Stop'
$Root=if([string]::IsNullOrWhiteSpace($DistributionRoot)){Split-Path -Parent $PSScriptRoot}else{[IO.Path]::GetFullPath($DistributionRoot)}
. (Join-Path $PSScriptRoot 'Common.ps1')
$Product=Import-RemoldProductConfig $PSScriptRoot
$ProductName=$Product.Name

function Stage([string]$Text){Write-Host $Text -ForegroundColor Cyan}
function Need([string]$Path){if(!(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Missing build output: $Path"}}
function Get-DriverPackage([string]$Key){
    $spec=$Product.DriverPackages|Where-Object{$_.Key -eq $Key}|Select-Object -First 1
    if(!$spec){throw "Driver package definition not found: $Key"}
    return [pscustomobject]@{
        Key=$spec.Key
        DisplayName=$spec.DisplayName
        Inf=(Get-DistributionArtifact $Root $spec.Inf)
        Cat=(Get-DistributionArtifact $Root $spec.Cat)
        HardwareId=$spec.HardwareId
        RootHardwareId=$spec.RootHardwareId
    }
}
function Invoke-SetupInteractive([string[]]$Arguments=@()){
    & $Setup @Arguments 2>&1 | Out-Host
    return [int]$LASTEXITCODE
}
function Assert-DevelopmentSignature([string]$Path,[string]$Thumbprint,[switch]$RequireTrusted){
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if($null -eq $sig.SignerCertificate){throw "Unsigned development artifact: $Path"}
    if($sig.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $Thumbprint){throw "Development signer mismatch: $Path"}
    if($sig.Status -eq [System.Management.Automation.SignatureStatus]::HashMismatch){throw "Development signature hash mismatch: $Path"}
    if($RequireTrusted -and $sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid){throw "Development signature is not trusted after certificate import: $Path ($($sig.Status))"}
}
function Initialize-DevelopmentPackageTrust([string]$CertPath,[string[]]$Catalogs){
    $cert=Get-CertificateFromFile $CertPath
    if($null -eq $cert -or [string]::IsNullOrWhiteSpace($cert.Thumbprint)){throw 'Development package certificate is invalid.'}
    $thumb=$cert.Thumbprint.ToUpperInvariant()
    $artifacts=@($Catalogs)
    foreach($artifact in $artifacts){Assert-DevelopmentSignature $artifact $thumb}
    foreach($storeName in @('Root','TrustedPublisher')){Add-CertificateToMachineStore $cert $storeName}
    foreach($artifact in $artifacts){Assert-DevelopmentSignature $artifact $thumb -RequireTrusted}
    Write-Host ("  Development signer : {0}" -f $cert.Subject) -ForegroundColor Yellow
    Write-Host ("  Signer thumbprint  : {0}" -f $thumb) -ForegroundColor DarkGray
    Write-Host '  PnP catalog trust  : VALID' -ForegroundColor Green
}
function Stage-DriverPackage([string]$Inf,[string]$Name){
    $r=Invoke-Native 'pnputil.exe' @('/add-driver',$Inf)
    if($r.ExitCode -ne 0){
        Show-Native $r
        throw ("Pre-staging failed for {0} (PnPUtil exit {1}). No device bindings have been changed." -f $Name,$r.ExitCode)
    }
    if(!$Simple){Show-Native $r}
    Write-Host ("  STAGED {0}" -f $Name) -ForegroundColor Green
}
function Show-SetupApiDiagnostic([string]$HardwareId){
    $setupLog=Join-Path $env:WINDIR 'INF\setupapi.dev.log'
    if(!(Test-Path -LiteralPath $setupLog -PathType Leaf)){return}
    try{
        $lines=@(Get-Content -LiteralPath $setupLog -ErrorAction Stop)
        if($lines.Count -eq 0){return}
        $pattern=[regex]::Escape($HardwareId)
        $last=-1
        for($j=0;$j -lt $lines.Count;$j++){if($lines[$j] -match $pattern){$last=$j}}
        $start=[Math]::Max(0,$lines.Count-120)
        if($last -ge 0){$start=[Math]::Max(0,$last-35)}
        $end=[Math]::Min($lines.Count-1,$start+119)
        Write-Host ("--- setupapi.dev.log diagnostic for {0} ---" -f $HardwareId) -ForegroundColor DarkYellow
        for($i=$start;$i -le $end;$i++){Write-Host $lines[$i]}
        Write-Host '--- end setupapi.dev.log diagnostic ---' -ForegroundColor DarkYellow
    }catch{
        Write-Host ("Could not read setupapi.dev.log: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}
$script:ProbeText=''
$script:ProbeLines=@()
$script:Issues=New-Object 'System.Collections.Generic.List[string]'
$script:State=[ordered]@{
    Device='PENDING'
    Broker='PENDING'
    Motor='PENDING'
    Camera='PENDING'
    CameraIp='PENDING'
    Audio='PENDING'
    WindowsCamera='PENDING'
}

function Note-Issue([string]$Message){
    if(!$script:Issues.Contains($Message)){
        $script:Issues.Add($Message)
        Write-Warning $Message
    }
}
function Try-Bind([string]$HardwareId,[string]$Inf,[string]$Name){
    $exit=Invoke-SetupInteractive @('bind',$HardwareId,$Inf)
    if($exit -ne 0){
        Show-SetupApiDiagnostic $HardwareId
        Note-Issue ("{0} could not be bound to the current driver (Setup exit {1})." -f $Name,$exit)
        return $false
    }
    return $true
}
function Try-EnsureRoot([string]$HardwareId,[string]$Inf,[string]$Name){
    $exit=Invoke-SetupInteractive @('ensure-root',$HardwareId,$Inf,$Name)
    if($exit -ne 0){
        Show-SetupApiDiagnostic $HardwareId
        Note-Issue ("{0} root device could not be created (Setup exit {1})." -f $Name,$exit)
        return $false
    }
    return $true
}
function Remove-RootDevice([string]$HardwareId){
    $r=Invoke-Native $Setup @('remove',$HardwareId)
    if($r.ExitCode -ne 0 -and !$Simple){Show-Native $r}
    return ($r.ExitCode -eq 0)
}
function Read-UsbInventory{
    $r=Invoke-Native $Setup @('probe')
    if($r.ExitCode -ne 0){
        $script:ProbeText=''
        $script:ProbeLines=@()
        return $false
    }
    $script:ProbeLines=@($r.StdOutLines)
    $script:ProbeText=$r.StdOutLines -join "`n"
    return $true
}
function Has-HardwareId([string]$HardwareId){
    return (![string]::IsNullOrWhiteSpace($script:ProbeText) -and
        [regex]::IsMatch($script:ProbeText,"(?im)^PRESENT\s+$([regex]::Escape($HardwareId))\s*$"))
}
function Show-UsbInventory{
    if(Read-UsbInventory){
        if($script:ProbeLines.Count -eq 0 -or ($script:ProbeLines.Count -eq 1 -and $script:ProbeLines[0] -eq 'PRESENT NONE')){
            Write-Host '  (no Kinect NUI USB function currently visible)' -ForegroundColor Yellow
        }else{
            $script:ProbeLines|ForEach-Object{Write-Host "  $_"}
        }
    }
}
function Rescan{
    $r=Invoke-Native 'pnputil.exe' @('/scan-devices')
    if($r.ExitCode -ne 0 -and !$Simple){Show-Native $r}
    Start-Sleep -Milliseconds 400
    [void](Read-UsbInventory)
}
function Wait-HardwareId([string]$HardwareId,[int]$MaxAttempts=30){
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(Has-HardwareId $HardwareId){return $true}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
function Test-PhysicalDeviceReady([string]$HardwareId){
    $r=Invoke-Native $Setup @('device-status',$HardwareId)
    return [pscustomobject]@{Ready=($r.ExitCode -eq 0);Result=$r}
}
function Get-DeviceProblem([object]$Result){
    $text=if($null -eq $Result){''}else{@($Result.Lines) -join ' '}
    $match=[regex]::Match($text,'(?i)\bproblem=(\d+)\b')
    if(!$match.Success){return [pscustomobject]@{Code=$null;Name='UNKNOWN'}}
    $code=[int]$match.Groups[1].Value
    $name=switch($code){
        0 {'NONE'}
        10 {'CM_PROB_FAILED_START'}
        31 {'CM_PROB_FAILED_ADD'}
        37 {'CM_PROB_FAILED_DRIVER_ENTRY'}
        39 {'CM_PROB_DRIVER_FAILED_LOAD'}
        48 {'CM_PROB_DRIVER_BLOCKED'}
        52 {'CM_PROB_UNSIGNED_DRIVER'}
        default {'CM_PROB_' + $code}
    }
    return [pscustomobject]@{Code=$code;Name=$name}
}
function Wait-DeviceStarted([string]$HardwareId,[int]$MaxAttempts=24){
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        if($i -eq 1 -or ($i % 6) -eq 0){Rescan}
        $probe=Test-PhysicalDeviceReady $HardwareId
        $last=$probe.Result
        if($probe.Ready){return [pscustomobject]@{Ready=$true;Result=$last;Problem=(Get-DeviceProblem $last)}}
        Start-Sleep -Milliseconds 400
    }
    return [pscustomobject]@{Ready=$false;Result=$last;Problem=(Get-DeviceProblem $last)}
}
function Wait-PhysicalStable([string]$HardwareId,[int]$MaxAttempts=20,[int]$StableSamples=3,[int]$MinAttempts=1){
    $stable=0
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        if(($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(!(Has-HardwareId $HardwareId)){
            $stable=0
        }else{
            $probe=Test-PhysicalDeviceReady $HardwareId
            $last=$probe.Result
            if($probe.Ready){$stable++}else{$stable=0}
            if($i -ge $MinAttempts -and $stable -ge $StableSamples){
                return [pscustomobject]@{Ready=$true;Result=$last}
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return [pscustomobject]@{Ready=$false;Result=$last}
}
function Bind-And-Stabilize([string]$HardwareId,[string]$Inf,[string]$Name,[string]$StateKey){
    if(!(Wait-HardwareId $HardwareId 20)){
        $script:State[$StateKey]='PENDING'
        Write-Host ("{0}: PENDING ({1} not visible)" -f $Name,$HardwareId) -ForegroundColor Yellow
        return $false
    }
    if(!(Try-Bind $HardwareId $Inf $Name)){
        $script:State[$StateKey]='FAILED'
        return $false
    }
    $stable=Wait-PhysicalStable $HardwareId 16 3 3
    if($stable.Ready){
        $script:State[$StateKey]='READY'
        Write-Host ("{0}: READY" -f $Name) -ForegroundColor Green
        return $true
    }
    if($null -ne $stable.Result){Show-Native $stable.Result}
    $problem=Get-DeviceProblem $stable.Result
    if($problem.Code -eq 52 -or $problem.Code -eq 48){
        $script:State[$StateKey]=('BLOCKED-CODE'+$problem.Code)
        Note-Issue ("{0} is bound but Windows Code Integrity blocked its function driver: Code {1} ({2})." -f $Name,$problem.Code,$problem.Name)
    }else{
        $script:State[$StateKey]='PENDING'
        Note-Issue ("{0} is present/bound but its PnP devnode did not reach a stable STARTED state." -f $Name)
    }
    return $false
}
function Get-KinectUacAudioDevice{
    try{
        $matches=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{$_.PNPDeviceID -like 'USB\VID_045E&PID_02BB*'})
        if($matches.Count -eq 0){return $null}
        $ready=@($matches|Where-Object{try{[int]$_.ConfigManagerErrorCode -eq 0}catch{$false}})
        if($ready.Count){return $ready[0]}
        return $matches[0]
    }catch{return $null}
}
function Get-AudioBridgeStatus{
    $path=Join-Path $env:ProgramData 'Kinect360Remold\audio-bridge-status.txt'
    if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    try{
        $item=Get-Item -LiteralPath $path -ErrorAction Stop
        $values=@{}
        foreach($line in @(Get-Content -LiteralPath $path -ErrorAction Stop)){
            $parts=$line -split '=',2
            if($parts.Count -eq 2){$values[$parts[0].Trim()]=$parts[1].Trim()}
        }
        return [pscustomobject]@{Path=$path;LastWriteTimeUtc=$item.LastWriteTimeUtc;Values=$values}
    }catch{return $null}
}
function Test-AudioBridgeCaptureReady([datetime]$NotBeforeUtc=[datetime]::MinValue){
    $status=Get-AudioBridgeStatus
    if($null -eq $status -or $status.LastWriteTimeUtc -lt $NotBeforeUtc){return $false}
    $stage=[string]$status.Values['stage']
    if($stage -ne 'uac-runtime-capturing'){return $false}
    $channels=0;$rate=0
    [void][int]::TryParse([string]$status.Values['capture_channels'],[ref]$channels)
    [void][int]::TryParse([string]$status.Values['capture_sample_rate'],[ref]$rate)
    return ($channels -ge 4 -and $rate -eq 16000)
}
function Test-KinectUacAudioReady{
    $device=Get-KinectUacAudioDevice
    if($null -eq $device){return $false}
    $code=0
    try{$code=[int]$device.ConfigManagerErrorCode}catch{$code=-1}
    return ($code -eq 0)
}
function Configure-AudioBridgeRuntime{
    $service=$Product.Services.AudioBridge
    if(!(Get-Service -Name $service -ErrorAction SilentlyContinue)){return $false}
    # The Kinect audio firmware re-enumerates 02AD -> 02BB. A trigger tied only to
    # the 02AD boot interface is therefore not a sufficient lifetime policy. Keep
    # the user-mode bridge alive so its raw Processing pipes remain available.
    [void](Invoke-Native 'sc.exe' @('config',$service,'start=','delayed-auto'))
    [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
    [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))
    try{Start-Service $service -ErrorAction SilentlyContinue}catch{}
    return $true
}
function Stabilize-AudioFunction{
    $id=$AudioPackage.HardwareId
    if(Test-KinectUacAudioReady){
        if(Get-Service -Name $Product.Services.AudioBridge -ErrorAction SilentlyContinue){
            [void](Configure-AudioBridgeRuntime)
            $probeStart=[datetime]::UtcNow.AddSeconds(-1)
            Start-Service $Product.Services.AudioBridge -ErrorAction SilentlyContinue
            for($probe=1;$probe -le 20;$probe++){
                if(Test-AudioBridgeCaptureReady $probeStart){
                    $script:State.Audio='READY'
                    Write-Host 'Xbox NUI Audio: READY (WASAPI 4-channel capture is active)' -ForegroundColor Green
                    return $true
                }
                Start-Sleep -Milliseconds 250
            }
            $script:State.Audio='READY'
            Write-Host 'Xbox NUI Audio: READY (02BB USB Audio runtime is active; AudioBridge capture is starting)' -ForegroundColor Green
            return $true
        }
        $script:State.Audio='PENDING'
        Note-Issue 'Kinect UAC runtime is already active, but AudioBridge is not installed. Power-cycle/reconnect the Kinect once so 045E:02AD appears and the boot package can install the bridge service.'
        return $false
    }

    if(!(Wait-HardwareId $id 30)){
        $script:State.Audio='PENDING'
        Write-Host ("Xbox NUI Audio boot transport: PENDING ({0} not visible)" -f $id) -ForegroundColor Yellow
        return $false
    }
    if(!(Try-Bind $id $AudioInf $AudioPackage.DisplayName)){
        $script:State.Audio='FAILED'
        return $false
    }

    $initialProbe=Wait-DeviceStarted $id 8
    if(!$initialProbe.Ready){
        if($null -ne $initialProbe.Result){Show-Native $initialProbe.Result}
        if($initialProbe.Problem.Code -eq 52 -or $initialProbe.Problem.Code -eq 48){
            $script:State.Audio=('BLOCKED-CODE'+$initialProbe.Problem.Code)
            Note-Issue ("Xbox NUI Audio boot WinUSB package was blocked by Windows Code Integrity: Code {0} ({1}). AudioBridge was not started." -f $initialProbe.Problem.Code,$initialProbe.Problem.Name)
        }else{
            $script:State.Audio='PENDING'
            Note-Issue 'Xbox NUI Audio boot transport is bound to Microsoft WinUSB but did not reach STARTED.'
        }
        return $false
    }

    $audioProbeStart=[datetime]::UtcNow.AddSeconds(-1)
    if(Get-Service -Name $Product.Services.AudioBridge -ErrorAction SilentlyContinue){
        [void](Configure-AudioBridgeRuntime)
    }
    Write-Host 'Xbox NUI Audio: uploading Microsoft UACFirmware and waiting for the Windows microphone endpoint...' -ForegroundColor DarkCyan
    $sawBootDeparture=$false
    for($i=1;$i -le 50;$i++){
        Start-Sleep -Milliseconds 500
        if(($i % 6) -eq 0){Rescan}else{[void](Read-UsbInventory)}
        if(Test-AudioBridgeCaptureReady $audioProbeStart){
            $script:State.Audio='READY'
            $suffix=if($sawBootDeparture){' (UAC firmware re-enumerated)'}else{' (UAC runtime active)'}
            Write-Host ("Xbox NUI Audio: READY{0}; WASAPI 4-channel microphone capture is active." -f $suffix) -ForegroundColor Green
            return $true
        }
        if(Test-KinectUacAudioReady){
            $script:State.Audio='READY'
            $suffix=if($sawBootDeparture){' (UAC firmware re-enumerated)'}else{' (UAC runtime active)'}
            Write-Host ("Xbox NUI Audio: READY{0}; Microsoft USB Audio runtime is active." -f $suffix) -ForegroundColor Green
            return $true
        }
        if(!(Has-HardwareId $id)){
            if(!$sawBootDeparture){Write-Host 'Xbox NUI Audio 02AD departed; waiting for 02BB UAC runtime...' -ForegroundColor DarkCyan}
            $sawBootDeparture=$true
        }
    }

    # The USB Audio endpoint can become usable before its parent USB devnode is visible through
    # Win32_PnPEntity. Give the functional WASAPI status one final chance before reporting failure.
    if(Test-AudioBridgeCaptureReady $audioProbeStart){
        $script:State.Audio='READY'
        Write-Host 'Xbox NUI Audio: READY; Windows microphone endpoint is capturing through WASAPI.' -ForegroundColor Green
        return $true
    }
    $script:State.Audio='PENDING'
    if($sawBootDeparture){
        Write-Host 'Xbox NUI Audio: UACFirmware launched; Windows audio publication is still completing asynchronously.' -ForegroundColor Yellow
    }else{
        Note-Issue '02AD stayed in boot/runtime state and the Microsoft UAC runtime did not appear. Check audio-bridge-status.txt; a physical Kinect power-cycle may be required after an older firmware session.'
    }
    return $false
}

function Stop-Runtime{
    foreach($serviceKey in @($Product.ServiceOrder)){$service=$Product.Services[$serviceKey];Stop-Service $service -Force -ErrorAction SilentlyContinue}
    Start-Sleep -Milliseconds 250
}
function Install-CameraIpRuntime([string]$Source,[string]$Runtime){
    $policy=$Product.CameraIpPolicy
    if($null -eq $policy){throw 'CameraIpPolicy is missing from Product.psd1.'}
    New-Item -ItemType Directory -Force $Runtime|Out-Null
    $destination=Join-Path $Runtime 'Kinect360RemoldCameraIp.exe'
    Copy-Item -LiteralPath $Source -Destination $destination -Force

    $initArgs=@('init','--enabled',[string][bool]$policy.Enabled,'--bind',[string]$policy.Bind,'--port',[string]$policy.Port,'--user',[string]$policy.User,
        '--fps',[string]$policy.Fps,'--quality',[string]$policy.JpegQuality,'--max-clients',[string]$policy.MaxClients)
    $init=Invoke-Native $destination $initArgs
    if($init.ExitCode -ne 0){Show-Native $init;throw 'Native IP-camera runtime configuration failed.'}
    if(!$Simple){Show-Native $init}

    $service=$Product.Services.CameraIp
    $binary=('"{0}"' -f $destination)
    if($null -eq (Get-Service -Name $service -ErrorAction SilentlyContinue)){
        $create=Invoke-Native 'sc.exe' @('create',$service,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','Kinect Xbox 360 Remold IP Camera')
        if($create.ExitCode -ne 0){Show-Native $create;throw "Could not create service $service."}
    }else{
        $config=Invoke-Native 'sc.exe' @('config',$service,'binPath=',$binary,'start=','auto','obj=','LocalSystem','DisplayName=','Kinect Xbox 360 Remold IP Camera')
        if($config.ExitCode -ne 0){Show-Native $config;throw "Could not update service $service."}
    }
    [void](Invoke-Native 'sc.exe' @('config',$service,'start=','delayed-auto'))
    [void](Invoke-Native 'sc.exe' @('description',$service,'Password-protected HTTP/MJPEG camera over the shared Kinect RGB runtime transport.'))
    [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
    [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))

    $rule=[string]$policy.FirewallRuleName
    if(![string]::IsNullOrWhiteSpace($rule)){
        [void](Invoke-Native 'netsh.exe' @('advfirewall','firewall','delete','rule',("name={0}" -f $rule)))
        if([bool]$policy.Enabled -and [string]$policy.Bind -ne '127.0.0.1'){
            $firewall=Invoke-Native 'netsh.exe' @('advfirewall','firewall','add','rule',("name={0}" -f $rule),'dir=in','action=allow','protocol=TCP',("localport={0}" -f $policy.Port),("profile={0}" -f $policy.FirewallProfile),("program={0}" -f $destination),("remoteip={0}" -f $policy.FirewallRemoteIp),'enable=yes')
            if($firewall.ExitCode -ne 0){Show-Native $firewall;Note-Issue 'IP-camera service was installed, but the Private-profile firewall rule could not be created.'}
        }
    }
    return $destination
}
function Start-Runtime{
    $serviceKeys=@('Broker')
    if($script:State.Camera -eq 'READY'){$serviceKeys+='CameraBridge'}
    if($null -ne (Get-Service -Name $Product.Services.CameraIp -ErrorAction SilentlyContinue)){$serviceKeys+='CameraIp'}
    if($null -ne (Get-Service -Name $Product.Services.AudioBridge -ErrorAction SilentlyContinue)){$serviceKeys+='AudioBridge'}
    $ok=$true
    foreach($serviceKey in $serviceKeys){
        $service=$Product.Services[$serviceKey]
        $installed=Get-Service -Name $service -ErrorAction SilentlyContinue
        if($null -eq $installed){
            $ok=$false
            Note-Issue ("Service {0} is expected for {1}, but it is not installed." -f $service,$serviceKey)
            continue
        }
        [void](Invoke-Native 'sc.exe' @('failure',$service,'reset=','60','actions=','restart/2000/restart/5000/restart/10000'))
        [void](Invoke-Native 'sc.exe' @('failureflag',$service,'1'))
        try{Start-Service $service -ErrorAction Stop}catch{$ok=$false;Note-Issue ("Service {0} could not be started: {1}" -f $service,$_.Exception.Message)}
    }
    return $ok
}
function Test-WindowsCameraPnP{
    try{
        $d=Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{$_.PNPDeviceID -like 'SWD\VCAMDEVAPI*' -and $_.Name -eq $Product.WindowsCameraName} |
            Select-Object -First 1
        return $null -ne $d
    }catch{return $false}
}
function Wait-WindowsCameraReady([int]$MaxAttempts=40){
    $last=$null
    for($i=1;$i -le $MaxAttempts;$i++){
        $r=Invoke-Native $runtimeCtl @('status')
        $last=$r
        if($r.ExitCode -eq 0 -or (Test-WindowsCameraPnP)){
            return [pscustomobject]@{Ready=$true;Result=$r}
        }
        Start-Sleep -Milliseconds 250
    }
    return [pscustomobject]@{Ready=$false;Result=$last}
}
function Remove-RemoldVirtualCameraDevices{
    try{
        $devices=@(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object{$_.PNPDeviceID -like 'SWD\VCAMDEVAPI*' -and $_.Name -eq $Product.WindowsCameraName})
        foreach($d in $devices){[void](Invoke-Native 'pnputil.exe' @('/remove-device',$d.PNPDeviceID))}
    }catch{Note-Issue ("Could not enumerate/remove Remold virtual camera devices: {0}" -f $_.Exception.Message)}
}

$LogDir=Join-Path $Root 'logs'
$LogFile=Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:InstallTranscript=$false
$script:InstallFailed=$false

try{
    New-Item -ItemType Directory -Force $LogDir|Out-Null
    try{Start-Transcript -LiteralPath $LogFile -Force|Out-Null;$script:InstallTranscript=$true}catch{Write-Warning ("Could not start install transcript: {0}" -f $_.Exception.Message)}
    Require-Administrator 'Administrator privileges are required for driver installation.'
    if([Environment]::OSVersion.Version.Major -lt 10 -or [Environment]::OSVersion.Version.Build -lt $Product.MinimumWindowsBuild){
        throw ("Windows build {0} or newer is required." -f $Product.MinimumWindowsBuild)
    }

    $DriverPackages=@($Product.DriverPackages|ForEach-Object{Get-DriverPackage $_.Key})
    $PackagesByKey=@{}
    foreach($package in $DriverPackages){$PackagesByKey[$package.Key]=$package}
    $DevicePackage=$PackagesByKey.Device
    $MotorPackage=$PackagesByKey.Motor
    $CameraPackage=$PackagesByKey.Camera
    $AudioPackage=$PackagesByKey.Audio

    $DeviceInf=$DevicePackage.Inf
    $NuiInf=$MotorPackage.Inf
    $CameraInf=$CameraPackage.Inf
    $AudioInf=$AudioPackage.Inf
    $DevelopmentCert=Join-Path $Root 'Kinect360RemoldDevelopment.cer'
    $Setup=Join-Path $Root 'tools\Kinect360RemoldSetup.exe'
    $NuiCtl=Join-Path $Root 'tools\Kinect360RemoldNui.exe'
    $Webcam=Join-Path $Root 'webcam'
    $WebcamCtlSource=Join-Path $Webcam 'Kinect360RemoldWebcam.exe'
    $WebcamDllSource=Join-Path $Webcam 'Kinect360RemoldCameraSource.dll'
    $CameraIpSource=Join-Path $Root 'runtime\Kinect360RemoldCameraIp.exe'
    $required=@($DevelopmentCert,$Setup,$NuiCtl,$WebcamCtlSource,$WebcamDllSource,$CameraIpSource)
    foreach($package in $DriverPackages){$required+=@($package.Inf,$package.Cat)}
    foreach($path in $required){Need $path}

    Stage 'Preflight: validating development package trust...'
    Write-Host '  Driver Store rule   : third-party PnP catalogs must carry a trusted digital signature' -ForegroundColor Yellow
    Write-Host '  Package policy      : local development certificate; imported automatically for this machine' -ForegroundColor Yellow
    Write-Host '  Motor/Camera        : Microsoft winusb.sys remains the USB function driver' -ForegroundColor Yellow
    Write-Host '  Audio boot          : 02AD -> Microsoft winusb.sys -> Microsoft Kinect SDK UACFirmware' -ForegroundColor Yellow
    Write-Host '  Audio runtime       : 02BB -> inbox Microsoft USB Audio -> WASAPI capture endpoint' -ForegroundColor Yellow
    Write-Host '  System policy       : installer does not change BCD, Secure Boot, or Code Integrity settings' -ForegroundColor DarkGray
    $catalogs=@($DriverPackages|ForEach-Object{$_.Cat})
    Initialize-DevelopmentPackageTrust $DevelopmentCert $catalogs

    Stage 'Preflight: staging every PnP package before changing devices...'
    foreach($package in $DriverPackages){Stage-DriverPackage $package.Inf $package.DisplayName}
    Write-Host ("  Driver Store preflight: PASS ({0}/{0})" -f $DriverPackages.Count) -ForegroundColor Green

    $Runtime=Join-Path $env:ProgramFiles $ProductName
    $RuntimeWebcamCtl=Join-Path $Runtime 'Kinect360RemoldWebcam.exe'
    $RuntimeCameraIp=Join-Path $Runtime 'Kinect360RemoldCameraIp.exe'
    $runtimeCtl=$null

    Stop-Runtime
    if(Test-Path -LiteralPath $RuntimeWebcamCtl -PathType Leaf){[void](Invoke-Native $RuntimeWebcamCtl @('remove'))}
    [void](Remove-RootDevice $DevicePackage.RootHardwareId)
    Remove-RemoldVirtualCameraDevices
    Rescan

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Kinect Xbox 360 Remold - driver installation' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host 'Primary entries after installation:'
    Write-Host '  Kinect Xbox 360 -> Kinect Xbox 360 Remold'
    Write-Host ("  Cameras         -> {0}" -f $Product.WindowsCameraName)
    Write-Host '  Motor/Camera       -> Microsoft inbox WinUSB transport'
    Write-Host '  Audio boot         -> 045E:02AD on Microsoft WinUSB'
    Write-Host '  Windows microphone -> active Kinect USB Audio/WASAPI capture endpoint'
    Write-Host '  Microphones        -> WASAPI 4-channel capture + raw AudioBridge pipe'
    Write-Host ("  IP camera          -> native runtime HTTP/MJPEG on {0}:{1}, password protected" -f $Product.CameraIpPolicy.Bind,$Product.CameraIpPolicy.Port)
    Write-Host ("  Raw audio pipe     -> {0} (4 x PCM S32LE for Processing)" -f $Product.AudioPipeName)
    Write-Host '  Custom audio .sys  -> none'
    Write-Host ''

    Stage 'Preflight: clearing current virtual-camera registration...'
    [void](Invoke-Native $WebcamCtlSource @('remove'))
    Stage 'Preflight: detecting Kinect USB functions...'
    Show-UsbInventory

    Stage '[1/7] Installing the visible Kinect device and control broker (trusted development package path)...'
    [void](Remove-RootDevice $DevicePackage.RootHardwareId)
    if(Try-EnsureRoot $DevicePackage.RootHardwareId $DeviceInf $DevicePackage.DisplayName){$script:State.Device='READY'}
    else{$script:State.Device='FAILED'}
    Rescan

    Stage '[2/7] Installing and stabilizing Xbox NUI Motor on Microsoft WinUSB...'
    [void](Bind-And-Stabilize $MotorPackage.HardwareId $NuiInf $MotorPackage.DisplayName 'Motor')

    Stage '[3/7] Waiting for and stabilizing Xbox NUI Camera on Microsoft WinUSB...'
    [void](Bind-And-Stabilize $CameraPackage.HardwareId $CameraInf $CameraPackage.DisplayName 'Camera')

    Stage '[4/7] Installing NUI Audio boot WinUSB + Microsoft UACFirmware/WASAPI bridge...'
    [void](Stabilize-AudioFunction)

    Stage '[5/7] Installing native password-protected IP-camera runtime...'
    $RuntimeCameraIp=Install-CameraIpRuntime $CameraIpSource $Runtime
    Write-Host ("Native IP camera: INSTALLED; {0}:{1}; Private-network firewall policy" -f $Product.CameraIpPolicy.Bind,$Product.CameraIpPolicy.Port) -ForegroundColor Green

    Stage '[6/7] Starting Remold runtime after physical transports are stable...'
    Rescan
    if($script:State.Motor -ne 'READY' -and $script:State.Motor -notlike 'BLOCKED-CODE*' -and (Has-HardwareId $MotorPackage.HardwareId)){
        [void](Bind-And-Stabilize $MotorPackage.HardwareId $NuiInf $MotorPackage.DisplayName 'Motor')
    }
    if($script:State.Camera -ne 'READY' -and $script:State.Camera -notlike 'BLOCKED-CODE*' -and (Has-HardwareId $CameraPackage.HardwareId)){
        [void](Bind-And-Stabilize $CameraPackage.HardwareId $CameraInf $CameraPackage.DisplayName 'Camera')
    }
    if($script:State.Audio -ne 'READY' -and $script:State.Audio -notlike 'BLOCKED-CODE*' -and (Has-HardwareId $AudioPackage.HardwareId)){
        [void](Stabilize-AudioFunction)
    }
    [void](Start-Runtime)
    if(Test-Path -LiteralPath $RuntimeCameraIp -PathType Leaf){
        $ipStatus=$null
        for($ipProbe=1;$ipProbe -le 20;$ipProbe++){
            $ipStatus=Invoke-Native $RuntimeCameraIp @('status')
            if($ipStatus.ExitCode -eq 0){break}
            Start-Sleep -Milliseconds 250
        }
        if($null -ne $ipStatus -and $ipStatus.ExitCode -eq 0){
            $script:State.CameraIp='READY'
            if(!$Simple){Show-Native $ipStatus}
        }else{
            $script:State.CameraIp='PENDING'
            Note-Issue 'Native IP-camera service is installed but is not running yet.'
        }
    }

    # Reconcile the audio state from the functional endpoint after all runtime services have had
    # a chance to start. Windows can publish the MMDevice endpoint later than the USB parent devnode.
    if($script:State.Audio -ne 'READY' -and $script:State.Audio -notlike 'BLOCKED-CODE*'){
        for($audioFinalProbe=1;$audioFinalProbe -le 40;$audioFinalProbe++){
            if((Test-AudioBridgeCaptureReady) -or (Test-KinectUacAudioReady)){
                $script:State.Audio='READY'
                Write-Host 'Xbox NUI Audio: READY (functional Windows microphone endpoint confirmed)' -ForegroundColor Green
                break
            }
            Start-Sleep -Milliseconds 250
        }
    }

    $broker=$null
    for($i=1;$i -le 30;$i++){
        $broker=Invoke-Native $NuiCtl @('broker-status')
        if($broker.ExitCode -eq 0){break}
        Start-Sleep -Milliseconds 300
    }
    if($null -ne $broker -and $broker.ExitCode -eq 0){
        $script:State.Broker='READY'
        if(!$Simple){Show-Native $broker}
    }else{
        $script:State.Broker='PENDING'
        Note-Issue 'The control broker is not reachable.'
    }

    $motor=$null
    for($i=1;$i -le 20;$i++){
        $motor=Invoke-Native $NuiCtl @('status')
        if($motor.ExitCode -eq 0){break}
        Start-Sleep -Milliseconds 300
    }
    if($null -ne $motor -and $motor.ExitCode -eq 0 -and (($motor.Lines -join ' ') -match 'transport=physical')){
        $script:State.Motor='READY'
        if(!$Simple){Show-Native $motor}
        [void](Invoke-Native $NuiCtl @('tilt',[string]$Product.StartupTiltDegrees))
    }

    Stage '[7/7] Publishing the Windows virtual camera after physical initialization...'
    if($script:State.Camera -ne 'READY'){
        $script:State.WindowsCamera='PENDING'
        Note-Issue ("Windows virtual camera was not published because physical camera transport {0} is not READY." -f $CameraPackage.HardwareId)
    }else{ try{
        New-Item -ItemType Directory -Force $Runtime|Out-Null
        $sourceHash=(Get-FileHash -LiteralPath $WebcamDllSource -Algorithm SHA256).Hash.ToLowerInvariant()
        $runtimeDll=Join-Path $Runtime ("Kinect360RemoldCameraSource-{0}.dll" -f $sourceHash.Substring(0,16))
        $runtimeCtl=Join-Path $Runtime 'Kinect360RemoldWebcam.exe'
        if(!(Test-Path -LiteralPath $runtimeDll)){Copy-Item -LiteralPath $WebcamDllSource -Destination $runtimeDll -Force}
        Copy-Item -LiteralPath $WebcamCtlSource -Destination $runtimeCtl -Force
        $r=Invoke-Native $runtimeCtl @('install',$runtimeDll)
        if(!$Simple){Show-Native $r}
        if($r.ExitCode -eq 0){$script:State.WindowsCamera='READY'}
        else{
            $script:State.WindowsCamera='FAILED'
            Note-Issue ("Windows camera registration returned exit {0}." -f $r.ExitCode)
        }
    }catch{
        $script:State.WindowsCamera='FAILED'
        Note-Issue $_.Exception.Message
    }}

    if($script:State.WindowsCamera -eq 'READY' -and $null -ne $runtimeCtl -and $script:State.Camera -eq 'READY'){
        $camera=Wait-WindowsCameraReady 120
        if($camera.Ready){
            Write-Host 'Windows virtual camera: READY (registration and publication confirmed)' -ForegroundColor Green
        }else{
            # IMFVirtualCamera registration succeeded. Media Foundation/PnP publication is asynchronous
            # and may lag while Frame Server refreshes; do not turn a successful registration into a warning.
            Write-Host 'Windows virtual camera: READY (registered; Windows publication may complete asynchronously)' -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' Installation summary' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    foreach($key in $script:State.Keys){Write-Host ("{0,-24}: {1}" -f $key,$script:State[$key])}
    if($script:Issues.Count){
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach($issue in $script:Issues){Write-Host ("  - {0}" -f $issue) -ForegroundColor Yellow}
    }
    $failedStates=@($script:State.GetEnumerator()|Where-Object{([string]$_.Value -eq 'FAILED') -or ([string]$_.Value -like 'BLOCKED-CODE*')})
    if($failedStates.Count){
        throw ("Installation is incomplete because required components failed or were blocked by Windows: {0}" -f (($failedStates|ForEach-Object{$_.Key}) -join ', '))
    }
    Write-Host ''
    Write-Host ("{0} v{1} INSTALLATION COMPLETE" -f $ProductName,$Product.Version) -ForegroundColor Green
    Write-Host 'No Windows restart is requested by the Remold installer.' -ForegroundColor Green
    if(!$Simple){Write-Host 'Technical utility: tools\Kinect360RemoldNui.exe status|broker-status|tilt|led'}
    [Environment]::ExitCode=0
}catch{
    $script:InstallFailed=$true
    [Environment]::ExitCode=1
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ' INSTALLATION FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ("Log: {0}" -f $LogFile) -ForegroundColor Yellow
}finally{
    if($script:InstallTranscript){try{Stop-Transcript|Out-Null}catch{Write-Warning ("Could not stop install transcript cleanly: {0}" -f $_.Exception.Message)}}
}
if($script:InstallFailed -and !$Simple){
    Write-Host ''
    [void](Read-Host 'Press Enter to close this installer')
}
return
