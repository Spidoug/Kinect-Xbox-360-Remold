[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SampleRoot,
    [Parameter(Mandatory=$true)][string]$TransportHeader,
    [Parameter(Mandatory=$true)][string]$CameraControlsHeader,
    [Parameter(Mandatory=$true)][string]$CameraKsHeader,
    [Parameter(Mandatory=$true)][string]$ControlProtocolHeader,
    [Parameter(Mandatory=$true)][string]$PlatformToolset,
    [Parameter(Mandatory=$true)][string]$WindowsSdkVersion,
    [Parameter(Mandatory=$true)][hashtable]$RuntimeLibraryPolicy,
    [Parameter(Mandatory=$true)][int]$StartupTiltDegrees,
    [Parameter(Mandatory=$true)][int]$TiltMinimum,
    [Parameter(Mandatory=$true)][int]$TiltMaximum,
    [Parameter(Mandatory=$true)][int]$FacePeriodMs,
    [Parameter(Mandatory=$true)][int]$StatusPeriodMs,
    [Parameter(Mandatory=$true)][int]$ActiveLeaseMs,
    [Parameter(Mandatory=$true)][int]$TiltCommandPeriodMs,
    [Parameter(Mandatory=$true)][int]$FaceVerticalDeadZonePixels,
    [Parameter(Mandatory=$true)][double]$FaceErrorFilterAlpha,
    [Parameter(Mandatory=$true)][double]$AccelFilterAlpha,
    [Parameter(Mandatory=$true)][double]$AccelCorrectionFilterAlpha,
    [Parameter(Mandatory=$true)][int]$MinCommandDeltaDegrees,
    [Parameter(Mandatory=$true)][int]$MotorSettleToleranceDegrees,
    [Parameter(Mandatory=$true)][int]$MotorSettleMs
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\..\..\..\build\Common.ps1')
function Require([bool]$Condition,[string]$Message){ if(!$Condition){ throw $Message } }
function Write-Utf8Bom([string]$Path,[string]$Text){ [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($true))) }
Require ($TiltMinimum -le $StartupTiltDegrees -and $StartupTiltDegrees -le $TiltMaximum) 'Startup Tilt must be inside the declared physical Tilt range.'
Require ($FacePeriodMs -ge 20 -and $FacePeriodMs -le 200) 'Face period must be between 20 and 200 ms.'
Require ($StatusPeriodMs -ge 40 -and $StatusPeriodMs -le 500) 'Status period must be between 40 and 500 ms.'
Require ($TiltCommandPeriodMs -ge 60 -and $TiltCommandPeriodMs -le 500) 'Tilt command period must protect the physical motor from command flooding.'
Require ($FaceErrorFilterAlpha -gt 0 -and $FaceErrorFilterAlpha -le 1) 'Face error filter alpha must be in (0,1].'
Require ($AccelFilterAlpha -gt 0 -and $AccelFilterAlpha -le 1) 'Accelerometer filter alpha must be in (0,1].'
Require ($AccelCorrectionFilterAlpha -gt 0 -and $AccelCorrectionFilterAlpha -le 1) 'Accelerometer correction filter alpha must be in (0,1].'

$generatorH=Join-Path $SampleRoot 'SimpleFrameGenerator.h'
$generatorCpp=Join-Path $SampleRoot 'SimpleFrameGenerator.cpp'
$streamCpp=Join-Path $SampleRoot 'SimpleMediaStream.cpp'
$sourceCpp=Join-Path $SampleRoot 'SimpleMediaSource.cpp'
$vcamH=Join-Path $SampleRoot 'VirtualCameraMediaSource.h'
$activateH=Join-Path $SampleRoot 'VirtualCameraMediaSourceActivate.h'
$activateCpp=Join-Path $SampleRoot 'VirtualCameraMediaSourceActivate.cpp'
$project=Join-Path $SampleRoot 'VirtualCameraMediaSource.vcxproj'
foreach($f in @($generatorH,$generatorCpp,$streamCpp,$sourceCpp,$vcamH,$activateH,$activateCpp,$project,$TransportHeader,$CameraControlsHeader,$CameraKsHeader,$ControlProtocolHeader)){
    Require (Test-Path -LiteralPath $f -PathType Leaf) "Required virtual-camera source was not found: $f"
}

# Pin protection: abort instead of silently adapting a structurally different sample.
$stream=[IO.File]::ReadAllText($streamCpp)
Require ($stream.Contains('const uint32_t NUM_MEDIATYPES = 2;')) 'Pinned Microsoft SimpleMediaStream layout changed (media-type count marker missing).'
Require ($stream.Contains('MFVideoFormat_NV12')) 'Pinned Microsoft sample no longer exposes NV12.'
Require ($stream.Contains('MFVideoFormat_RGB32')) 'Pinned Microsoft sample RGB32 marker missing.'

$sourceBlock=@'
        const uint32_t NUM_MEDIATYPES = 3u;
        wil::unique_cotaskmem_array_ptr<wil::com_ptr_nothrow<IMFMediaType>> mediaTypeList = wilEx::make_unique_cotaskmem_array<wil::com_ptr_nothrow<IMFMediaType>>(NUM_MEDIATYPES);

        auto addMediaType = [&](uint32_t index, const GUID& subtype, uint32_t bytesPerPixelNumerator, uint32_t bytesPerPixelDenominator) -> HRESULT {
            wil::com_ptr_nothrow<IMFMediaType> mediaType;
            RETURN_IF_FAILED(MFCreateMediaType(&mediaType));
            mediaType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
            mediaType->SetGUID(MF_MT_SUBTYPE, subtype);
            mediaType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
            mediaType->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
            MFSetAttributeSize(mediaType.get(), MF_MT_FRAME_SIZE, NUM_IMAGE_COLS, NUM_IMAGE_ROWS);
            MFSetAttributeRatio(mediaType.get(), MF_MT_FRAME_RATE, 30, 1);
            const uint64_t bitsPerSecond = static_cast<uint64_t>(NUM_IMAGE_COLS) * NUM_IMAGE_ROWS * bytesPerPixelNumerator * 8ull * 30ull / bytesPerPixelDenominator;
            mediaType->SetUINT32(MF_MT_AVG_BITRATE, static_cast<uint32_t>(bitsPerSecond));
            MFSetAttributeRatio(mediaType.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
            mediaTypeList[index] = mediaType.detach();
            return S_OK;
        };

        RETURN_IF_FAILED(addMediaType(0, MFVideoFormat_NV12, 3, 2));
        RETURN_IF_FAILED(addMediaType(1, MFVideoFormat_YUY2, 2, 1));
        RETURN_IF_FAILED(addMediaType(2, MFVideoFormat_RGB32, 4, 1));

'@
$pattern='(?s)\s*const uint32_t NUM_MEDIATYPES = 2;.*?(?=\s*RETURN_IF_FAILED\(MFCreateAttributes\(&m_spAttributes, 10\)\);)'
$matches=[regex]::Matches($stream,$pattern)
Require ($matches.Count -eq 1) "Expected exactly one SimpleMediaStream media-type block, found $($matches.Count)."
$stream=[regex]::Replace($stream,$pattern,"`r`n$sourceBlock",1)
Require ($stream -match 'const uint32_t NUM_MEDIATYPES = 3u;') 'Stable three-format virtual-camera policy was not inserted.'
Require ($stream -match 'MFVideoFormat_YUY2') 'YUY2 media type was not inserted.'
Require ($stream -match 'MFVideoFormat_RGB32') 'RGB32 media type was not inserted.'
Write-Utf8Bom $streamCpp $stream

$sourceDir=Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item -LiteralPath (Join-Path $sourceDir 'SimpleFrameGenerator.h.template') -Destination $generatorH -Force
$generatorText=[IO.File]::ReadAllText((Join-Path $sourceDir 'SimpleFrameGenerator.cpp.template'))
$cameraControlsText=[IO.File]::ReadAllText($CameraControlsHeader)
$cameraKsText=[IO.File]::ReadAllText($CameraKsHeader)
foreach($pair in @(
    [pscustomobject]@{Token='__REMOLD_STARTUP_TILT__';Value=[string]$StartupTiltDegrees},
    [pscustomobject]@{Token='__REMOLD_TILT_MIN__';Value=[string]$TiltMinimum},
    [pscustomobject]@{Token='__REMOLD_TILT_MAX__';Value=[string]$TiltMaximum},
    [pscustomobject]@{Token='__REMOLD_FACE_PERIOD_MS__';Value=[string]$FacePeriodMs},
    [pscustomobject]@{Token='__REMOLD_STATUS_PERIOD_MS__';Value=[string]$StatusPeriodMs},
    [pscustomobject]@{Token='__REMOLD_VIRTUAL_CAMERA_ACTIVE_LEASE_MS__';Value=[string]$ActiveLeaseMs},
    [pscustomobject]@{Token='__REMOLD_TILT_COMMAND_PERIOD_MS__';Value=[string]$TiltCommandPeriodMs},
    [pscustomobject]@{Token='__REMOLD_FACE_VERTICAL_DEAD_ZONE_PIXELS__';Value=[string]$FaceVerticalDeadZonePixels},
    [pscustomobject]@{Token='__REMOLD_FACE_ERROR_FILTER_ALPHA__';Value=$FaceErrorFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_ACCEL_FILTER_ALPHA__';Value=$AccelFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_ACCEL_CORRECTION_FILTER_ALPHA__';Value=$AccelCorrectionFilterAlpha.ToString([Globalization.CultureInfo]::InvariantCulture)},
    [pscustomobject]@{Token='__REMOLD_MIN_COMMAND_DELTA_DEGREES__';Value=[string]$MinCommandDeltaDegrees},
    [pscustomobject]@{Token='__REMOLD_MOTOR_SETTLE_TOLERANCE_DEGREES__';Value=[string]$MotorSettleToleranceDegrees},
    [pscustomobject]@{Token='__REMOLD_MOTOR_SETTLE_MS__';Value=[string]$MotorSettleMs}
)){
    $generatorText=$generatorText.Replace($pair.Token,$pair.Value)
    $cameraControlsText=$cameraControlsText.Replace($pair.Token,$pair.Value)
    $cameraKsText=$cameraKsText.Replace($pair.Token,$pair.Value)
}
Require ($generatorText -notmatch '__REMOLD_[A-Z_]+__') 'Virtual-camera generator contains an unresolved product token.'
Require ($cameraControlsText -notmatch '__REMOLD_[A-Z_]+__') 'Camera-control header contains an unresolved product token.'
Require ($cameraKsText -notmatch '__REMOLD_[A-Z_]+__') 'Camera KS header contains an unresolved product token.'
Write-Utf8Bom $generatorCpp $generatorText
Write-Utf8Bom (Join-Path $SampleRoot 'Kinect360RemoldCameraControls.h') $cameraControlsText
Write-Utf8Bom (Join-Path $SampleRoot 'Kinect360RemoldCameraKs.h') $cameraKsText
Copy-Item -LiteralPath $TransportHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldFrameTransport.h') -Force
Copy-Item -LiteralPath $ControlProtocolHeader -Destination (Join-Path $SampleRoot 'Kinect360RemoldControlProtocol.h') -Force

# Route standard PTZ and Remold smart-camera properties through the existing
# IKsControl implementation in the pinned Microsoft media source.  Unknown
# properties continue into the original sample handler.
$source=[IO.File]::ReadAllText($sourceCpp)
Require ($source.Contains('#include "pch.h"')) 'Pinned SimpleMediaSource include marker changed.'
$source=$source.Replace('#include "pch.h"', '#include "pch.h"' + [Environment]::NewLine + '#include "Kinect360RemoldCameraKs.h"')
$validationPattern='(?s)(if \(ulPropertyLength < sizeof\(KSPROPERTY\)\)\s*\{\s*return E_INVALIDARG;\s*\})'
$validationMatches=[regex]::Matches($source,$validationPattern)
Require ($validationMatches.Count -eq 1) "Expected one SimpleMediaSource KsProperty validation block, found $($validationMatches.Count)."
$dispatch=@'

        HRESULT remoldControlHr = Kinect360RemoldCameraControls::HandleKsProperty(
            pProperty, ulPropertyLength, pPropertyData, ulDataLength, pBytesReturned);
        if (remoldControlHr != HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND))
        {
            return remoldControlHr;
        }
'@
$validationMatch=$validationMatches[0]
$source=$source.Substring(0,$validationMatch.Index+$validationMatch.Length) + $dispatch + $source.Substring($validationMatch.Index+$validationMatch.Length)
Require ($source.Contains('Kinect360RemoldCameraControls::HandleKsProperty')) 'Smart camera IKsControl dispatch was not inserted.'
Write-Utf8Bom $sourceCpp $source

$oldGuid='7B89B92E-FE71-42D0-8A41-E137D06EA184'
$newGuid='D0C8E936-5A2B-4C0D-936F-281501A73691'
foreach($f in @($vcamH,$activateH)){
    $t=[IO.File]::ReadAllText($f)
    Require ($t.Contains($oldGuid)) "Pinned virtual-camera CLSID marker missing in $f"
    $t=$t.Replace($oldGuid,$newGuid).Replace($oldGuid.ToLowerInvariant(),$newGuid.ToLowerInvariant())
    if($f -eq $vcamH){
        $oldDefine='0x7b89b92e, 0xfe71, 0x42d0, 0x8a, 0x41, 0xe1, 0x37, 0xd0, 0x6e, 0xa1, 0x84'
        $newDefine='0xd0c8e936, 0x5a2b, 0x4c0d, 0x93, 0x6f, 0x28, 0x15, 0x01, 0xa7, 0x36, 0x91'
        Require ($t.Contains($oldDefine)) 'Pinned DEFINE_GUID body changed.'
        $t=$t.Replace($oldDefine,$newDefine)
        $t=$t.Replace('VIRTUALCAMERAMEDIASOURCE_FRIENDLYNAME = L"VirtualCameraMediaSource"','VIRTUALCAMERAMEDIASOURCE_FRIENDLYNAME = L"Kinect360RemoldCameraSource"')
    }
    Write-Utf8Bom $f $t
}
foreach($sourceFile in Get-ChildItem -LiteralPath $SampleRoot -Recurse -File -Include *.h,*.cpp,*.idl,*.vcxproj){
    $remaining=[IO.File]::ReadAllText($sourceFile.FullName)
    Require ($remaining -notmatch [regex]::Escape($oldGuid)) "Pinned Microsoft sample CLSID was not replaced in $($sourceFile.FullName)"
}

$proj=[IO.File]::ReadAllText($project)
$packagesConfig=Join-Path $SampleRoot 'packages.config'
if(Test-Path -LiteralPath $packagesConfig -PathType Leaf){
    $packagesText=[IO.File]::ReadAllText($packagesConfig)
    # The project consumes the platform projection shipped by the selected Windows SDK.
    # Remove every NuGet C++/WinRT package entry so one build cannot load two header versions.
    $packagesText=[regex]::Replace($packagesText,'(?im)^\s*<package\s+id="Microsoft\.Windows\.CppWinRT"[^>]*/>\s*\r?\n?','')
    Require ($packagesText -notmatch 'Microsoft\.Windows\.CppWinRT') 'C++/WinRT NuGet package entry was not removed.'
    Write-Utf8Bom $packagesConfig $packagesText
}

# Remove every C++/WinRT NuGet import/check from the pinned project.
# The pinned upstream vcxproj contains both 3.x and 2.x imports, and
# the package checks may use SolutionDir or project-relative paths.  Match the
# complete XML elements rather than a particular path layout so the cleanup is
# deterministic while the source remains pinned to the validated commit.
$proj=[regex]::Replace($proj,'(?is)<Import\b[^>]*Microsoft\.Windows\.CppWinRT[^>]*/>\s*','')
$proj=[regex]::Replace($proj,'(?is)<Error\b[^>]*Microsoft\.Windows\.CppWinRT[^>]*/>\s*','')
Require ($proj -notmatch 'Microsoft\.Windows\.CppWinRT') 'C++/WinRT NuGet import/check remains in the project after cleanup.'

$proj=[regex]::Replace($proj,'(?i)<WindowsTargetPlatformVersion>[^<]+</WindowsTargetPlatformVersion>',"<WindowsTargetPlatformVersion>$WindowsSdkVersion</WindowsTargetPlatformVersion>")
$proj=[regex]::Replace($proj,'(?i)<PlatformToolset>v\d+</PlatformToolset>',"<PlatformToolset>$PlatformToolset</PlatformToolset>")

# Use only the C++/WinRT headers from the exact SDK selected by Toolchain.ps1.
# Do not include GeneratedFilesDir: mixing generated NuGet base.h with SDK projections
# causes CPPWINRT_VERSION mismatches.
$projectionInclude='<AdditionalIncludeDirectories>$(RemoldSdkCppWinRTDir);%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>'
if(!$proj.Contains('$(RemoldSdkCppWinRTDir)')){
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile>'+$projectionInclude)
}
Require ($proj.Contains('$(RemoldSdkCppWinRTDir)')) 'Windows SDK C++/WinRT include was not inserted.'
Require ($proj -notmatch '\$\(GeneratedFilesDir\)') 'GeneratedFilesDir remains in the C++/WinRT include path.'
if($proj -notmatch '(?i)<LanguageStandard>'){
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile><LanguageStandard>stdcpp17</LanguageStandard>')
}else{
    $proj=[regex]::Replace($proj,'(?i)<LanguageStandard>[^<]+</LanguageStandard>','<LanguageStandard>stdcpp17</LanguageStandard>')
}
Require ($proj.Contains('<LanguageStandard>stdcpp17</LanguageStandard>')) 'C++17 language standard was not pinned.'

# windows.h exposes min/max macros unless NOMINMAX is defined before pch.h.
# The Remold generator uses std::min/std::max and must remain valid with every
# supported WDK/SDK combination, so pin NOMINMAX at the project level.
if($proj -notmatch '(?i)<PreprocessorDefinitions>[^<]*NOMINMAX') {
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile><PreprocessorDefinitions>NOMINMAX;%(PreprocessorDefinitions)</PreprocessorDefinitions>')
}
Require ($proj -match '(?i)<PreprocessorDefinitions>[^<]*NOMINMAX') 'NOMINMAX was not pinned for the virtual-camera project.'

# Only WIL remains as a NuGet build dependency. Make its import/check project-relative.
$solutionPackagePrefix='$(SolutionDir)packages\'
$projectPackagePrefix='$(MSBuildThisFileDirectory)..\packages\'
$solutionPackageCount=[regex]::Matches($proj,[regex]::Escape($solutionPackagePrefix)).Count
Require ($solutionPackageCount -ge 1) "Pinned virtual-camera WIL package reference was not found."
$proj=$proj.Replace($solutionPackagePrefix,$projectPackagePrefix)
Require ($proj -notmatch [regex]::Escape($solutionPackagePrefix)) 'SolutionDir-dependent NuGet package path remains after preparation.'
Require ($proj.Contains($projectPackagePrefix)) 'Project-relative WIL package path was not inserted.'

# VS/MSVC 14.51 schedules multiple translation units against one /Zi PDB,
# Keep /FS in the project for shared-PDB serialization.
# the remaining C1041 was caused by the PDB path itself exceeding classic
# MAX_PATH.  Anchor the activation source to this project directory; the build
# stages the pinned sample under a deliberately short work\wc path so both the
# source and PDB stay comfortably below that limit.
$activateCompileItem='<ClCompile Include="VirtualCameraMediaSourceActivate.cpp" />'
$activateCompileItemAnchored='<ClCompile Include="$(MSBuildThisFileDirectory)VirtualCameraMediaSourceActivate.cpp" />'
Require ($proj.Contains($activateCompileItem)) 'Pinned activation-source project item changed.'
$proj=$proj.Replace($activateCompileItem,$activateCompileItemAnchored)
Require ($proj.Contains($activateCompileItemAnchored)) 'Activation source was not anchored to the vcxproj directory.'
# Keep shared-PDB serialization and large C++/WinRT translation units explicit,
# but do not use RuntimeLibrary as a textual insertion anchor. Runtime policy is
# normalized semantically after all textual sample adaptations are persisted.
$fsTag='<AdditionalOptions>/FS /bigobj /await:strict %(AdditionalOptions)</AdditionalOptions>'
if($proj -notmatch '(?i)<AdditionalOptions>[^<]*/FS(?:\s|<)'){
    $compileBlocks=[regex]::Matches($proj,'(?i)<ClCompile>')
    Require ($compileBlocks.Count -gt 0) 'Pinned virtual-camera project has no ClCompile item-definition block.'
    $proj=[regex]::Replace($proj,'(?i)<ClCompile>','<ClCompile>'+$fsTag)
}
Require ($proj -match '(?i)<AdditionalOptions>[^<]*/FS[^<]*/bigobj[^<]*/await:strict') 'MSVC C++/WinRT compile options were not inserted.'
Require ($proj -notmatch '(?i)<ClCompile Include="[\\/]VirtualCameraMediaSourceActivate\.cpp"') 'Activation source acquired a rooted path.'
Write-Utf8Bom $project $proj
Set-MsBuildRuntimeLibraryPolicy $project $RuntimeLibraryPolicy

Write-Host 'Virtual camera source preparation applied: RGB-only Windows camera -> NV12 + YUY2 + RGB32, activity-gated motor Tilt, FaceTracker RGB auto-framing and smart controls.' -ForegroundColor Green
