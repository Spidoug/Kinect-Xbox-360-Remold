[CmdletBinding()]
param(
    [ValidateSet('Release')][string]$Configuration='Release',
    [string]$LogPath='',
    [string]$SigningThumbprint=''
)
$ErrorActionPreference='Stop'
$Root=$PSScriptRoot
$ProjectRoot=Split-Path -Parent (Split-Path -Parent $Root)
$Product=Import-PowerShellDataFile (Join-Path $ProjectRoot 'build\Product.psd1')
$DeviceDriverSpec=$Product.DriverPackages|Where-Object{$_.Key -eq 'Device'}|Select-Object -First 1
$MotorDriverSpec=$Product.DriverPackages|Where-Object{$_.Key -eq 'Motor'}|Select-Object -First 1
$AudioDriverSpec=$Product.DriverPackages|Where-Object{$_.Key -eq 'Audio'}|Select-Object -First 1
if(!$DeviceDriverSpec -or !$MotorDriverSpec -or !$AudioDriverSpec){throw 'Required driver package definition is missing from Product.psd1.'}
$Dist=Join-Path $Root 'dist'
$Work=Join-Path $Root 'work'
$Cache=Join-Path $Root 'cache'

. (Join-Path $ProjectRoot 'build\Common.ps1')

if([string]::IsNullOrWhiteSpace($LogPath)){$LogPath=Get-DefaultLogPath $Root}
New-Item -ItemType Directory -Force (Split-Path -Parent $LogPath)|Out-Null
$failed=$false;$transcript=$false
try{
    Start-Transcript -LiteralPath $LogPath -Force|Out-Null;$transcript=$true
    Write-Host ('Build log: {0}' -f $LogPath) -ForegroundColor Yellow
    Write-BuildStage 'Cleaning generated outputs...';Remove-NativeBuildOutputs $Root @($Dist,$Work)
    $localFirmwarePath=Join-Path $Root 'firmware\UACFirmware'
    Write-BuildStage 'Detecting Visual Studio and WDK toolchain...'
    $Tools=& (Join-Path $ProjectRoot 'build\Toolchain.ps1')
    $developmentCert=Get-OrCreateDevelopmentCertificate $Product $SigningThumbprint

    $DevicePackage=Join-Path $Dist 'device'
    $NuiPackage=Join-Path $Dist 'nui'
    $AudioPackage=Join-Path $Dist 'audio'
    $ToolsPackage=Join-Path $Dist 'tools'
    $FirmwareWork=Join-Path $Work 'audio-firmware'
    $DevicePolicyWork=Join-Path $Work 'device-policy'
    New-Item -ItemType Directory -Force $DevicePackage,$NuiPackage,$AudioPackage,$ToolsPackage,$FirmwareWork,$DevicePolicyWork,$Cache|Out-Null

    $devicePolicyTemplate=Join-Path $Root 'shared\Kinect360RemoldDevicePolicy.h.template'
    $devicePolicyHeader=Join-Path $DevicePolicyWork 'Kinect360RemoldDevicePolicy.h'
    Require-File $devicePolicyTemplate 'Device policy template'
    $devicePolicy=[IO.File]::ReadAllText($devicePolicyTemplate)
    $policyTokens=@{
        '__REMOLD_TILT_MIN__'=[string]$Product.TiltMinDegrees
        '__REMOLD_TILT_MAX__'=[string]$Product.TiltMaxDegrees
        '__REMOLD_CAMERA_ACTIVITY_LEASE_MS__'=[string]$Product.CameraActivityLeaseMs
        '__REMOLD_LED_ACTIVE_REFRESH_MS__'=[string]$Product.CameraLedPolicy.ActiveRefreshMs
        '__REMOLD_LED_IDLE_REFRESH_MS__'=[string]$Product.CameraLedPolicy.IdleRefreshMs
        '__REMOLD_LED_IDLE_FLASH_MS__'=[string]$Product.CameraLedPolicy.IdleFlashMs
        '__REMOLD_LED_IDLE_OFF_MS__'=[string]$Product.CameraLedPolicy.IdleOffMs
        '__REMOLD_LED_POLL_MS__'=[string]$Product.CameraLedPolicy.PollMs
        '__REMOLD_LED_RETRY_MS__'=[string]$Product.CameraLedPolicy.RetryMs
        '__REMOLD_CHIRP_ENABLED__'=$(if($Product.ConnectionChirpPolicy.Enabled){'true'}else{'false'})
        '__REMOLD_CHIRP_STEP_HALF_DEGREES__'=[string]$Product.ConnectionChirpPolicy.StepHalfDegrees
        '__REMOLD_CHIRP_PULSE_MS__'=[string]$Product.ConnectionChirpPolicy.PulseMs
        '__REMOLD_CHIRP_CYCLES__'=[string]$Product.ConnectionChirpPolicy.Cycles
        '__REMOLD_CHIRP_COOLDOWN_MS__'=[string]$Product.ConnectionChirpPolicy.CooldownMs
    }
    foreach($token in $policyTokens.Keys){$devicePolicy=$devicePolicy.Replace($token,[string]$policyTokens[$token])}
    if($devicePolicy -match '__REMOLD_[A-Z0-9_]+__'){throw 'Generated device policy contains unresolved tokens.'}
    Write-Utf8NoBom $devicePolicyHeader $devicePolicy

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' {0} - device stack' -f $Product.Name) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('Visible device : {0} -> {1}' -f $DeviceDriverSpec.RootHardwareId,$Product.Name)
    Write-Host ('Hidden motor   : {0} -> Microsoft WinUSB' -f $MotorDriverSpec.HardwareId)
    Write-Host ('NUI Audio boot : {0} -> Microsoft WinUSB -> Microsoft Kinect SDK UACFirmware' -f $AudioDriverSpec.HardwareId)
    Write-Host 'NUI Audio run  : USB\VID_045E&PID_02BB&MI_02 -> Microsoft USB Audio class -> WASAPI'
    Write-Host ('Raw mic output : {0} -> dedicated Processing 4-channel monitor' -f $Product.AudioPipeName)
    Write-Host ''

    Write-BuildStage '[1/4] Building persistent control broker and visible device package...'
    $brokerProject=Join-Path $Root 'source\broker\Kinect360RemoldBroker.vcxproj'
    & $Tools.MSBuild $brokerProject /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:RemoldGeneratedInclude=$DevicePolicyWork"
    if($LASTEXITCODE){throw 'Kinect360RemoldBroker build failed.'}
    $broker=Get-ChildItem -LiteralPath (Join-Path $Root 'source\broker') -Recurse -File -Filter Kinect360RemoldBroker.exe|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(!$broker){throw 'Kinect360RemoldBroker.exe not found after build.'};Assert-NoExternalVcRuntime $broker.FullName $Tools
    Copy-Item -LiteralPath $broker.FullName -Destination (Join-Path $DevicePackage 'Kinect360RemoldBroker.exe') -Force
    Stage-Inf (Join-Path $Root 'driver\Kinect360RemoldDevice.inf') (Join-Path $DevicePackage 'Kinect360RemoldDevice.inf') $Product
    Build-PackageCatalog $DevicePackage 'Kinect360RemoldDevice.inf' $Tools $Product.Inf2CatOs $Product.DriverTargetPlatform
    Write-Host 'Visible Kinect device + control broker: PASS' -ForegroundColor Green

    Write-BuildStage '[2/4] Building hidden physical Motor transport...'
    & $Tools.MSBuild (Join-Path $Root 'source\nui\Kinect360RemoldNui.vcxproj') /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion)
    if($LASTEXITCODE){throw 'Kinect360RemoldNui build failed.'}
    $nuiTool=Get-ChildItem -LiteralPath (Join-Path $Root 'source\nui') -Recurse -File -Filter Kinect360RemoldNui.exe|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(!$nuiTool){throw 'Kinect360RemoldNui.exe not found after build.'};Assert-NoExternalVcRuntime $nuiTool.FullName $Tools
    Copy-Item -LiteralPath $nuiTool.FullName -Destination (Join-Path $ToolsPackage 'Kinect360RemoldNui.exe') -Force
    Stage-Inf (Join-Path $Root 'driver\Kinect360RemoldNui.inf') (Join-Path $NuiPackage 'Kinect360RemoldNui.inf') $Product
    Build-PackageCatalog $NuiPackage 'Kinect360RemoldNui.inf' $Tools $Product.Inf2CatOs $Product.DriverTargetPlatform
    Write-Host 'Physical Motor transport: PASS' -ForegroundColor Green

    Write-BuildStage '[3/4] Building WinUSB boot loader + Microsoft UAC runtime + Xbox NUI Audio bridge...'
    $firmware=Join-Path $FirmwareWork 'UACFirmware'
    if(Test-Path -LiteralPath $localFirmwarePath -PathType Leaf){
        Copy-Item -LiteralPath $localFirmwarePath -Destination $firmware -Force
        Write-Host 'Using local firmware\UACFirmware.' -ForegroundColor Yellow
    }else{
        $firmwareDependency=Get-PinnedDependency $Product 'KinectUacFirmware'
        $sdkMsi=Join-Path $Cache 'KinectSDK-v1.0-beta2-x86.msi'
        if(!(Test-Path -LiteralPath $sdkMsi -PathType Leaf)){
            Write-BuildStage 'Downloading pinned Microsoft Kinect SDK Beta 2 x86 package...'
            Invoke-ResilientDownload @([string]$firmwareDependency.Url) $sdkMsi
        }
        Require-File $sdkMsi 'Microsoft Kinect SDK Beta 2 x86 MSI'
        $sdkItem=Get-Item -LiteralPath $sdkMsi
        $sdkMd5=(Get-FileHash -LiteralPath $sdkMsi -Algorithm MD5).Hash.ToLowerInvariant()
        $knownMd5=@($firmwareDependency.KnownMd5|ForEach-Object{([string]$_).ToLowerInvariant()})
        if($knownMd5 -notcontains $sdkMd5){
            throw ("Kinect SDK MSI integrity mismatch. MD5={0}; expected one of: {1}" -f $sdkMd5,($knownMd5 -join ', '))
        }
        if($sdkMd5 -eq '945806927702b2c47c32125ab9a80344' -and
           $sdkItem.Length -ne [int64]$firmwareDependency.ExpectedBytes){
            throw ("Kinect SDK MSI size mismatch for the pinned current artifact: {0} bytes." -f $sdkItem.Length)
        }
        Write-Host ("Kinect SDK package integrity: PASS (MD5={0}, bytes={1})" -f $sdkMd5,$sdkItem.Length) -ForegroundColor Green

        $knownFirmwareName=[string]$firmwareDependency.FirmwareFileName
        if([string]::IsNullOrWhiteSpace($knownFirmwareName)){throw 'KinectUacFirmware.FirmwareFileName is required.'}
        $extractor=Join-Path $Root 'tools\Extract-KinectUacFirmware.ps1'
        Require-File $extractor 'native MSI/CAB UAC firmware extractor'
        Write-BuildStage 'Extracting Microsoft UACFirmware directly from the embedded MSI cabinet...'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $extractor -MsiPath $sdkMsi -OutputPath $firmware -ExpectedName $knownFirmwareName
        if($LASTEXITCODE){throw ("Native MSI/CAB UACFirmware extraction failed (exit {0})." -f $LASTEXITCODE)}
        Require-File $firmware 'Microsoft Kinect UACFirmware extracted from SDK MSI'
    }

    Require-File $firmware 'Microsoft Kinect UACFirmware'
    [byte[]]$fw=[IO.File]::ReadAllBytes($firmware)
    if($fw.Length -lt 65536 -or $fw.Length -gt 1048576){
        throw ("UACFirmware size is outside the conservative expected range: {0} bytes." -f $fw.Length)
    }
    Write-Host ("UACFirmware validation: PASS (raw image, bytes={0}, load=0x00080000, entry=0x00080030)" -f $fw.Length) -ForegroundColor Green

    $generatedHeader=Join-Path $FirmwareWork 'Kinect360RemoldAudioFirmware.generated.h'
    $builder=New-Object Text.StringBuilder
    [void]$builder.AppendLine('#pragma once')
    [void]$builder.AppendLine('// Generated by components/device/Build.ps1 from Microsoft Kinect SDK UACFirmware.')
    [void]$builder.AppendLine('static const unsigned char gRemoldAudioFirmware[] = {')
    for($i=0;$i -lt $fw.Length;$i+=16){
        $finish=[Math]::Min($i+16,$fw.Length)
        $items=for($j=$i;$j -lt $finish;$j++){'0x{0:X2}' -f $fw[$j]}
        [void]$builder.Append('    ');[void]$builder.Append(($items -join ', '));[void]$builder.AppendLine(',')
    }
    [void]$builder.AppendLine('};')
    [void]$builder.AppendLine(('static const unsigned long gRemoldAudioFirmwareSize = {0}UL;' -f $fw.Length))
    Write-Utf8NoBom $generatedHeader $builder.ToString()

    $audioProject=Join-Path $Root 'source\audio-bridge\Kinect360RemoldAudioBridge.vcxproj'
    & $Tools.MSBuild $audioProject /m /t:Rebuild /p:Configuration=$Configuration /p:Platform=x64 /p:RemoldPlatformToolset=$($Tools.PlatformToolset) /p:PlatformToolset=$($Tools.PlatformToolset) /p:WindowsTargetPlatformVersion=$($Tools.WdkVersion) "/p:RemoldGeneratedInclude=$FirmwareWork"
    if($LASTEXITCODE){throw 'Kinect360RemoldAudioBridge build failed.'}
    $audioBridge=Get-ChildItem -LiteralPath (Join-Path $Root 'source\audio-bridge') -Recurse -File -Filter Kinect360RemoldAudioBridge.exe|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if(!$audioBridge){throw 'Kinect360RemoldAudioBridge.exe not found after build.'}
    Assert-NoExternalVcRuntime $audioBridge.FullName $Tools
    Copy-Item -LiteralPath $audioBridge.FullName -Destination (Join-Path $AudioPackage 'Kinect360RemoldAudioBridge.exe') -Force
    Stage-Inf (Join-Path $Root 'driver\Kinect360RemoldAudio.inf') (Join-Path $AudioPackage 'Kinect360RemoldAudio.inf') $Product
    Build-PackageCatalog $AudioPackage 'Kinect360RemoldAudio.inf' $Tools $Product.Inf2CatOs $Product.DriverTargetPlatform
    Write-Host 'NUI Audio boot WinUSB + Microsoft UACFirmware + inbox USB Audio/WASAPI + raw microphone pipe: PASS' -ForegroundColor Green

    Write-BuildStage '[4/4] Validating deterministic device packages...'
    $expected=@(
        [pscustomobject]@{Path=$DevicePackage;Files=@('Kinect360RemoldDevice.inf','Kinect360RemoldDevice.cat','Kinect360RemoldBroker.exe')},
        [pscustomobject]@{Path=$NuiPackage;Files=@('Kinect360RemoldNui.inf','Kinect360RemoldNui.cat')},
        [pscustomobject]@{Path=$AudioPackage;Files=@('Kinect360RemoldAudio.inf','Kinect360RemoldAudio.cat','Kinect360RemoldAudioBridge.exe')},
        [pscustomobject]@{Path=$ToolsPackage;Files=@('Kinect360RemoldNui.exe')}
    )
    foreach($spec in $expected){Assert-PackageContents $spec.Path $spec.Files}
    Write-Host '';Write-Host 'BUILD COMPLETE' -ForegroundColor Green;Write-Host "Output: $Dist" -ForegroundColor Green
}catch{
    $failed=$true
    Write-Host '';Write-Host '============================================================' -ForegroundColor Red
    Write-Host 'BUILD FAILED' -ForegroundColor Red
    Write-Host '============================================================' -ForegroundColor Red
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("Full log: {0}" -f $LogPath) -ForegroundColor Yellow
}finally{
    if($transcript){try{Stop-Transcript|Out-Null}catch{Write-Warning ("Could not stop build transcript cleanly: {0}" -f $_.Exception.Message)}}
}
if($failed){exit 1};exit 0
