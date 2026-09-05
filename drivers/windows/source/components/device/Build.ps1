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
$Control1473DriverSpec=$Product.DriverPackages|Where-Object{$_.Key -eq 'Control1473'}|Select-Object -First 1
if(!$DeviceDriverSpec -or !$MotorDriverSpec -or !$AudioDriverSpec -or !$Control1473DriverSpec){throw 'Required driver package definition is missing from Product.psd1.'}
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
    $localFirmwarePath=Join-Path $Root 'firmware\UACFirmware-01.02.709.00'
    Write-BuildStage 'Detecting Visual Studio and WDK toolchain...'
    $Tools=& (Join-Path $ProjectRoot 'build\Toolchain.ps1')
    $developmentCert=Get-OrCreateDevelopmentCertificate $Product $SigningThumbprint

    $DevicePackage=Join-Path $Dist 'device'
    $NuiPackage=Join-Path $Dist 'nui'
    $AudioPackage=Join-Path $Dist 'audio'
    $Control1473Package=Join-Path $Dist 'control1473'
    $ToolsPackage=Join-Path $Dist 'tools'
    $FirmwareWork=Join-Path $Work 'audio-firmware'
    $DevicePolicyWork=Join-Path $Work 'device-policy'
    New-Item -ItemType Directory -Force $DevicePackage,$NuiPackage,$AudioPackage,$Control1473Package,$ToolsPackage,$FirmwareWork,$DevicePolicyWork,$Cache|Out-Null

    $devicePolicyTemplate=Join-Path $Root 'shared\Kinect360RemoldDevicePolicy.h.template'
    $devicePolicyHeader=Join-Path $DevicePolicyWork 'Kinect360RemoldDevicePolicy.h'
    Require-File $devicePolicyTemplate 'Device policy template'
    $devicePolicy=[IO.File]::ReadAllText($devicePolicyTemplate)
    $policyTokens=@{
        '__REMOLD_TILT_MIN__'=[string]$Product.TiltMinDegrees
        '__REMOLD_TILT_MAX__'=[string]$Product.TiltMaxDegrees
    }
    foreach($token in $policyTokens.Keys){$devicePolicy=$devicePolicy.Replace($token,[string]$policyTokens[$token])}
    if($devicePolicy -match '__REMOLD_[A-Z0-9_]+__'){throw 'Generated device policy contains unresolved tokens.'}
    Write-Utf8NoBom $devicePolicyHeader $devicePolicy

    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' {0} - device stack' -f $Product.Name) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ('Visible device : {0} -> {1}' -f $DeviceDriverSpec.RootHardwareId,$Product.Name)
    Write-Host ('Hidden motor   : {0} -> Microsoft WinUSB' -f $MotorDriverSpec.HardwareId)
    Write-Host ('NUI Audio boot : {0} -> Microsoft WinUSB -> Microsoft Kinect Runtime 1.8 UACFirmware 01.02.709.00' -f $AudioDriverSpec.HardwareId)
    Write-Host ('1473 control  : {0} -> existing Microsoft WinUSB or Remold WinUSB fallback' -f $Control1473DriverSpec.HardwareId)
    Write-Host 'NUI Audio run  : USB\VID_045E&PID_02BB/02C3&MI_02 -> Microsoft USB Audio class -> WASAPI'
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
    $firmware=Join-Path $FirmwareWork 'UACFirmware-01.02.709.00'
    $firmwareDependency=Get-PinnedDependency $Product 'KinectUacFirmware'
    $expectedFirmwareVersion=[string]$firmwareDependency.FirmwareVersion
    if($expectedFirmwareVersion -ne '01.02.709.00'){throw ("Unsupported pinned Kinect UACFirmware version: {0}" -f $expectedFirmwareVersion)}
    if(Test-Path -LiteralPath $localFirmwarePath -PathType Leaf){
        Copy-Item -LiteralPath $localFirmwarePath -Destination $firmware -Force
        Write-Host 'Using offline UACFirmware-01.02.709.00 supplied by the builder.' -ForegroundColor Yellow
    }else{
        $runtimeBundle=Join-Path $Cache ([string]$firmwareDependency.BundleFileName)
        if(!(Test-Path -LiteralPath $runtimeBundle -PathType Leaf)){
            Write-BuildStage 'Downloading pinned Microsoft Kinect for Windows Runtime v1.8 package...'
            Invoke-ResilientDownload @([string]$firmwareDependency.Url) $runtimeBundle
        }
        Require-File $runtimeBundle 'Microsoft Kinect for Windows Runtime v1.8 bundle'
        $runtimeItem=Get-Item -LiteralPath $runtimeBundle
        $runtimeSha=(Get-FileHash -LiteralPath $runtimeBundle -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedSha=([string]$firmwareDependency.Sha256).ToLowerInvariant()
        if([string]::IsNullOrWhiteSpace($expectedSha) -or $runtimeSha -ne $expectedSha){
            throw ("Kinect Runtime v1.8 integrity mismatch. SHA256={0}; expected {1}" -f $runtimeSha,$expectedSha)
        }
        Write-Host ("Kinect Runtime v1.8 integrity: PASS (SHA256={0}, bytes={1})" -f $runtimeSha,$runtimeItem.Length) -ForegroundColor Green

        $extractor=Join-Path $Root 'tools\Extract-KinectRuntimeUacFirmware.ps1'
        Require-File $extractor 'Kinect Runtime v1.8 UAC firmware extractor'

        # WiX v3 is consumed as an ordinary NuGet ZIP package.  This is the
        # official WiX 3.14.1 binary package and has no package dependencies, so
        # extraction does not require dotnet.exe, a .NET SDK, NuGet.exe, or an
        # installed WiX toolset.  dark.exe itself runs on the Windows .NET
        # Framework that is already present on supported Windows systems.
        $wixPackage=Join-Path $Cache ([string]$firmwareDependency.WixPortableFileName)
        if(!(Test-Path -LiteralPath $wixPackage -PathType Leaf)){
            Write-BuildStage ('Downloading portable WiX {0} bundle extractor from NuGet...' -f [string]$firmwareDependency.WixPortableVersion)
            Invoke-ResilientDownload @([string]$firmwareDependency.WixPortableUrl) $wixPackage -ZipArchive
        }
        Require-File $wixPackage 'portable WiX v3 NuGet package'
        if(!(Test-ZipArchive $wixPackage)){throw "Portable WiX package is not a valid ZIP/NuGet archive: $wixPackage"}

        $wixToolCache=Join-Path $Cache ('wix-{0}' -f [string]$firmwareDependency.WixPortableVersion)
        $darkExe=Get-ChildItem -LiteralPath $wixToolCache -Recurse -File -Filter 'dark.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if($null -eq $darkExe){
            if(Test-Path -LiteralPath $wixToolCache){Remove-Item -LiteralPath $wixToolCache -Recurse -Force}
            New-Item -ItemType Directory -Force $wixToolCache|Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [IO.Compression.ZipFile]::ExtractToDirectory($wixPackage,$wixToolCache)
            $darkExe=Get-ChildItem -LiteralPath $wixToolCache -Recurse -File -Filter 'dark.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if($null -eq $darkExe){throw "Portable WiX package did not contain dark.exe: $wixPackage"}
        Write-Host ('Portable WiX bundle extractor: PASS ({0})' -f $darkExe.FullName) -ForegroundColor Green

        Write-BuildStage 'Extracting UACFirmware 01.02.709.00 from Kinect Runtime v1.8 without installing the runtime...'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $extractor `
            -BundlePath $runtimeBundle `
            -OutputPath $firmware `
            -DriverMsiName ([string]$firmwareDependency.DriverMsiName) `
            -FirmwareFileName ([string]$firmwareDependency.FirmwareFileName) `
            -DarkExe $darkExe.FullName
        if($LASTEXITCODE){throw ("Kinect Runtime v1.8 UACFirmware extraction failed (exit {0})." -f $LASTEXITCODE)}
        Require-File $firmware 'Microsoft Kinect UACFirmware 01.02.709.00 extracted from Runtime v1.8'
    }

    Require-File $firmware 'Microsoft Kinect UACFirmware'
    [byte[]]$fw=[IO.File]::ReadAllBytes($firmware)
    if($fw.Length -lt 65536 -or $fw.Length -gt 1048576){
        throw ("UACFirmware size is outside the conservative expected range: {0} bytes." -f $fw.Length)
    }

    # UACFirmware 01.02.709.00 builds the USB descriptors in ARM code at runtime;
    # there is no literal 07 05 82 ... descriptor to byte-patch. This pinned
    # image already emits bInterval 4 for Audio ISO IN. Validate the complete
    # firmware image so an unknown executable layout is never modified blindly.
    $targetInterval=[byte]$Product.KinectUacIsoInBInterval
    if($targetInterval -ne 4){throw ("Unsupported Kinect UAC ISO IN bInterval policy: {0}" -f $targetInterval)}
    $firmwareSha=(Get-FileHash -LiteralPath $firmware -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedFirmwareSha=([string]$firmwareDependency.FirmwareSha256).ToLowerInvariant()
    if([string]::IsNullOrWhiteSpace($expectedFirmwareSha) -or $firmwareSha -ne $expectedFirmwareSha){
        throw ("UACFirmware image integrity mismatch. SHA256={0}; expected {1}" -f $firmwareSha,$expectedFirmwareSha)
    }
    Write-Host ("UACFirmware {0} validation: PASS (SHA256={1}, bytes={2}, load=0x00080000, entry=0x00080030; Audio ISO IN bInterval=4; models=1414,1473)" -f $expectedFirmwareVersion,$firmwareSha,$fw.Length) -ForegroundColor Green

    $generatedHeader=Join-Path $FirmwareWork 'Kinect360RemoldAudioFirmware.generated.h'
    $builder=New-Object Text.StringBuilder
    [void]$builder.AppendLine('#pragma once')
    [void]$builder.AppendLine('// Generated by components/device/Build.ps1 from Microsoft Kinect Runtime v1.8 UACFirmware.')
    [void]$builder.AppendLine(('static const char gRemoldAudioFirmwareVersion[] = "{0}";' -f $expectedFirmwareVersion))
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
    Write-Host '1414/1473 NUI Audio boot WinUSB + Microsoft UACFirmware 01.02.709.00 + inbox USB Audio/WASAPI + raw microphone pipe: PASS' -ForegroundColor Green

    Stage-Inf (Join-Path $Root 'driver\Kinect360Remold1473Control.inf') (Join-Path $Control1473Package 'Kinect360Remold1473Control.inf') $Product
    Build-PackageCatalog $Control1473Package 'Kinect360Remold1473Control.inf' $Tools $Product.Inf2CatOs $Product.DriverTargetPlatform
    Write-Host 'Kinect 1473 Audio Array Control WinUSB fallback package: PASS' -ForegroundColor Green

    Write-BuildStage '[4/4] Validating deterministic device packages...'
    $expected=@(
        [pscustomobject]@{Path=$DevicePackage;Files=@('Kinect360RemoldDevice.inf','Kinect360RemoldDevice.cat','Kinect360RemoldBroker.exe')},
        [pscustomobject]@{Path=$NuiPackage;Files=@('Kinect360RemoldNui.inf','Kinect360RemoldNui.cat')},
        [pscustomobject]@{Path=$AudioPackage;Files=@('Kinect360RemoldAudio.inf','Kinect360RemoldAudio.cat','Kinect360RemoldAudioBridge.exe')},
        [pscustomobject]@{Path=$Control1473Package;Files=@('Kinect360Remold1473Control.inf','Kinect360Remold1473Control.cat')},
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
