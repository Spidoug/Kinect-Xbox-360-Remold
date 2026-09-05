#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass(){ printf 'PASS  %s\n' "$1"; }
fail(){ printf 'FAIL  %s\n' "$1" >&2; exit 1; }

# No committed binary/artifact payloads.
if find "$ROOT/drivers" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' -o -iname '*.cat' -o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.so' -o -iname '*.a' -o -iname '*.o' -o -iname '*.pdb' \) -print -quit | grep -q .; then
  find "$ROOT/drivers" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' -o -iname '*.cat' -o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.so' -o -iname '*.a' -o -iname '*.o' -o -iname '*.pdb' \) -print >&2
  fail 'native driver binary/package found in source tree'
fi
pass 'native driver tree is source-only'

for generated in \
  "$ROOT/applications/binaries" \
  "$ROOT/drivers/windows/binaries" \
  "$ROOT/drivers/linux/binaries" \
  "$ROOT/drivers/linux/dist" \
  "$ROOT/drivers/linux/packages/output"; do
  [[ ! -e "$generated" ]] || fail "generated output present: ${generated#$ROOT/}"
done
pass 'generated output directories are absent'

[[ ! -d "$ROOT/tests" ]] || fail 'tests directory must not be present in the cleaned source release'
pass 'tests directory is absent'

if find "$ROOT/docs" -type f -name 'FIXES-*' -print -quit | grep -q .; then
  find "$ROOT/docs" -type f -name 'FIXES-*' -print >&2
  fail 'version-specific fixes document found in clean V1 baseline'
fi
if find "$ROOT/drivers/windows" -type f -iname '*1473*.ps1' -print -quit | grep -q .; then
  find "$ROOT/drivers/windows" -type f -iname '*1473*.ps1' -print >&2
  fail 'version-specific 1473 recovery script found in clean baseline'
fi
pass 'version-specific recovery payloads are absent'

[[ ! -e "$ROOT/drivers/linux/INSTALL-PREBUILT.sh" ]] || fail 'removed Linux precompiled installer is present'
! grep -R -n -E 'INSTALL-PREBUILT|--prebuilt|drivers/linux/binaries' "$ROOT/drivers" "$ROOT/scripts" --include='*.sh' --include='*.cmd' --include='*.ps1' --include='*.md' --include='*.spec' --exclude='VERIFY-SOURCE-RELEASE.sh' --exclude='VERIFY-V1.sh' >/dev/null || fail 'source/build text still depends on a precompiled Linux driver payload'
pass 'builders have no precompiled driver input path'

# Non-V1 protocol/UI contracts must not appear.
! grep -R -n -E '/run/kinect360-remold/scanner\.sock|armed_ir|low_light_ir|recording_rgb|surveillance-motion\.mp4' "$ROOT" --exclude-dir='.git' --exclude='*.jar' --exclude='VERIFY-SOURCE-RELEASE.sh' --exclude='VERIFY-V1.sh' >/dev/null || fail 'non-V1 contract text/source found'
pass 'non-V1 singleton/Surveillance contracts are absent'

[[ ! -d "$ROOT/drivers/windows/source/components/device/firmware/remold-audio" ]] || fail 'non-release experimental audio firmware tree is present'
[[ ! -e "$ROOT/docs/windows/CUSTOM-AUDIO-FIRMWARE.md" ]] || fail 'non-release custom audio firmware document is present'
! grep -R -n 'acoustic.echo.pending' "$ROOT/applications" --include='*.properties' >/dev/null || fail 'inactive acoustic echo UI contract is present'
pass 'V1 audio source/docs contain only the active UAC/raw-four-channel path'
! grep -R -n 'F99791F2-D5BE-478A-B77A-830AD14950C3' "$ROOT" --exclude-dir='.git' --exclude='VERIFY-SOURCE-RELEASE.sh' >/dev/null || fail 'non-V1 Kinect SDK firmware bootstrap remains'
! grep -R -n 'version=12' "$ROOT/drivers/linux" >/dev/null || fail 'non-V1 Linux audio diagnostics version remains'
grep -q '02bb.*02c3\|02c3.*02bb' "$ROOT/drivers/linux/source/src/audio_bridge.cpp" || fail 'Linux audio runtime does not accept both 02BB and 02C3'
grep -q '0x02bb,0x02c3' "$ROOT/drivers/linux/source/src/broker.cpp" || fail 'Linux 1473 control runtime does not accept both 02BB and 02C3'
pass 'Linux V1 audio/control runtime is aligned with 02BB/02C3 and current firmware policy'

! grep -R -n -E '\b(prebuilt|pre-built)\b|old per-module|previous custom|previous fixed|former standalone' \
  "$ROOT/README.md" "$ROOT/docs" "$ROOT/drivers" "$ROOT/applications" \
  --include='*.md' --include='*.txt' >/dev/null || fail 'non-V1 migration wording remains in public documentation'
pass 'public documentation uses V1 terminology'

for required in \
  "$ROOT/docs/RELEASE-V1.md" \
  "$ROOT/docs/SCANNER-QUALITY.md" \
  "$ROOT/docs/BUILD-DRIVERS.md" \
  "$ROOT/docs/PROJECT-AUDIT.md"; do
  [[ -s "$required" ]] || fail "required documentation missing: ${required#$ROOT/}"
done
pass 'release/build/scanner-quality/audit documentation present'
[[ "$(tr -d '\r\n' < "$ROOT/VERSION")" == '1.0' ]] || fail 'VERSION is not exactly 1.0'
pass 'release VERSION is exactly 1.0'

# Static architecture checks.
grep -q 'function Wait-HardwarePresentStable' "$ROOT/drivers/windows/source/install/Install.ps1" || fail 'installer does not debounce transient hardware presence'
grep -q 'Camera setup is independent from 1473 LED/motor acknowledgement' "$ROOT/drivers/windows/source/install/Install.ps1" || fail 'camera setup is still coupled to 1473 control acknowledgement'
grep -q "045E02AE0205.*IgnoreHWSerNum\|IgnoreHWSerNum" "$ROOT/drivers/windows/source/install/Install.ps1" || fail '1473 02AE port-identity policy missing'
grep -q 'SPDRP_LOCATION_PATHS' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'CameraBridge location-path identity missing'
grep -q 'pixelDensity(1)' "$ROOT/applications/processing/SynKinectStudio/SynKinectStudio.pde" || fail 'Studio does not pin Processing pixel density'
grep -q 'class AcousticBeamOutput' "$ROOT/applications/processing/SynKinectStudio/Acoustic.pde" || fail 'Acoustic beamformed playback output missing'
grep -q 'short\[\] beamform' "$ROOT/applications/processing/SynKinectStudio/Acoustic.pde" || fail 'Acoustic delay-and-sum beamformer missing'
grep -q 'locateNearField' "$ROOT/applications/processing/SynKinectStudio/Acoustic.pde" || fail 'Acoustic near-field TDOA localization missing'
grep -q 'button.auto' "$ROOT/applications/processing/SynKinectStudio/Acoustic.pde" || fail 'Acoustic AUTO control missing'
grep -q 'button.manual' "$ROOT/applications/processing/SynKinectStudio/Acoustic.pde" || fail 'Acoustic MANUAL control missing'
grep -q 'MODE_IR=1' "$ROOT/applications/processing/SynKinectStudio/Surveillance.pde" || fail 'Surveillance IR protocol missing'
grep -q 'night.enterLuma' "$ROOT/applications/processing/SynKinectStudio/data/surveillance.properties" || fail 'Surveillance day/night hysteresis missing'
grep -q 'setSurveillanceForeground(false)' "$ROOT/applications/processing/SynKinectStudio/Surveillance.pde" || fail 'Surveillance does not release IR on module exit'
grep -q 'FindKinectUacCaptureEndpoints' "$ROOT/drivers/windows/source/components/device/source/audio-bridge/Kinect360RemoldAudioBridge.cpp" || fail 'Windows AudioBridge does not enumerate all Kinect UAC endpoints'
grep -q 'KinectUacIsoInBInterval = 4' "$ROOT/drivers/windows/source/build/Product.psd1" || fail 'Windows UAC bInterval=4 policy missing'
grep -q "FirmwareSha256 = '4467ae36ad378c58477432729d74eed0f9d45d35213f4430a781d90f64cea3f9'" "$ROOT/drivers/windows/source/build/Product.psd1" || fail 'pinned UACFirmware image hash missing'
grep -q 'constexpr ULONG kIsoPacketsPerTransfer = 32;' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'Windows camera ISO packets-per-transfer contract missing'
grep -q 'constexpr ULONG kIsoQueueDepth = 8;' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'Windows camera ISO transfer-count contract missing'
grep -q 'i == 0 ? FALSE : TRUE' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'Windows camera initial ISO schedule is not contiguous'
grep -q 'resubmitting' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'Windows camera ISO error resubmission missing'
grep -q 'camera-bridge.log' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'persistent Windows camera diagnostics missing'
grep -q 'kMaxQueuedFramesPerClient = 6' "$ROOT/drivers/windows/source/components/camera/source/bridge/Kinect360RemoldCameraBridge.cpp" || fail 'Windows camera client queue is not latency bounded'
grep -q '^ui.fontScale=1.22$' "$ROOT/applications/processing/SynKinectStudio/data/studio.properties" || fail 'Studio readable font scale missing'
grep -q '^ui.font.family=SansSerif$' "$ROOT/applications/processing/SynKinectStudio/data/scanner.properties" || fail 'Studio Unicode logical font policy missing'
grep -q '^transport.rgbdQueueFrames=3$' "$ROOT/applications/processing/SynKinectStudio/data/scanner.properties" || fail 'Studio RGBD low-latency queue policy missing'
if LC_ALL=C grep -R -n '[^ -~]' "$ROOT/applications/processing/SynKinectStudio/data/i18n" --include='*.properties' >/dev/null; then
  fail 'Studio translation catalog contains non-portable encoded bytes'
fi
pass 'static architecture contracts present'

# PowerShell V1 build scripts must not shadow read-only/automatic variables.
! grep -R -n -E 'function[[:space:]]+[^[:space:]]+\([^)]*\$Home\b|foreach[[:space:]]*\([[:space:]]*\$home\b|^[[:space:]]*\$home[[:space:]]*=|^[[:space:]]*\$args[[:space:]]*=' \
  "$ROOT/scripts/windows" "$ROOT/drivers/windows/source" --include='*.ps1' >/dev/null || fail 'PowerShell automatic variable shadowing detected'
pass 'PowerShell automatic variables are not shadowed by V1 scripts'

[[ -s "$ROOT/drivers/windows/source/build/Ensure-Toolchain.ps1" ]] || fail 'Windows native toolchain bootstrap is missing'
[[ -s "$ROOT/drivers/windows/source/build/wdk-vscommunity.dsc.yaml" ]] || fail 'Microsoft WDK WinGet configuration snapshot is missing'
[[ -s "$ROOT/drivers/windows/source/build/wdk-desktop.vsconfig" ]] || fail 'Microsoft WDK Visual Studio component snapshot is missing'
grep -q "winget.*configure\|configure','-f" "$ROOT/drivers/windows/source/build/Ensure-Toolchain.ps1" || fail 'Windows toolchain bootstrap does not use the V1 WDK configuration path'
grep -q 'Microsoft.VisualStudio.Community' "$ROOT/drivers/windows/source/build/wdk-vscommunity.dsc.yaml" || fail 'Visual Studio Community WDK configuration missing'
grep -q 'Microsoft.WindowsSDK.10.0.28000' "$ROOT/drivers/windows/source/build/wdk-vscommunity.dsc.yaml" || fail 'Windows SDK 28000 configuration missing'
grep -q 'Microsoft.WindowsWDK.10.0.28000' "$ROOT/drivers/windows/source/build/wdk-vscommunity.dsc.yaml" || fail 'Windows WDK 28000 configuration missing'
grep -q 'Component.Microsoft.Windows.DriverKit' "$ROOT/drivers/windows/source/build/wdk-desktop.vsconfig" || fail 'Visual Studio DriverKit component missing'
! grep -R -n -E 'RequirePython|Find-Python|python3?\.exe' "$ROOT/drivers/windows/source" --include='*.ps1' --include='*.cmd' >/dev/null || fail 'non-V1 Python build dependency remains in Windows source'
grep -q 'Build-ApplicationRuntime.ps1' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio does not use the single V1 Java runtime builder'
pass 'Windows V1 build uses one Microsoft WDK toolchain configuration and has no Python prerequisite'

# Product/runtime protocol versions are V1. Third-party tool versions are excluded.
grep -q 'constexpr uint32_t kVersion = 1;' "$ROOT/drivers/windows/source/components/camera/shared/Kinect360RemoldFrameTransport.h" || fail 'Windows frame transport is not V1'
grep -q 'constexpr uint32_t kVersion = 1;' "$ROOT/drivers/windows/source/components/camera/shared/Kinect360RemoldScannerPort.h" || fail 'Windows ScannerPort is not V1'
grep -q 'constexpr uint32_t kVersion = 1;' "$ROOT/drivers/windows/source/components/device/shared/Kinect360RemoldControlProtocol.h" || fail 'Windows control protocol is not V1'
grep -q 'inline constexpr uint32_t kVersion = 1;' "$ROOT/drivers/linux/source/include/remold/protocol.hpp" || fail 'Linux protocol is not V1'
pass 'Windows/Linux runtime protocol contracts are V1'


# Clean-build and public-presentation contract.
for template in \
  "$ROOT/applications/runtime-templates/windows-x64/SynKinectStudio.cmd" \
  "$ROOT/applications/runtime-templates/linux-x64/SynKinectStudio.sh" \
  "$ROOT/applications/runtime-templates/linux-x64/SynKinectStudio.desktop"; do
  [[ -s "$template" ]] || fail "runtime template missing: ${template#$ROOT/}"
done
grep -q 'repo.maven.apache.org/maven2/org/processing/core/4.4.6' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio build does not bootstrap Processing Core'
grep -q 'jogamp.org/deployment/maven/org/jogamp/jogl/jogl-all/2.5.0' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio build does not bootstrap JOGL'
grep -q 'e92f6f517963e2f63882c71ab92ed46c98dbfa1cbccab8b2475c1d76ceca0f86' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio Processing Core hash pin missing'
grep -q 'function Install-PortableJdk17' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio portable JDK bootstrap missing'
grep -q 'javac -encoding UTF-8\|\$javac -encoding UTF-8' "$ROOT/scripts/windows/Build-Studio.ps1" || fail 'Windows Studio javac encoding is not pinned to UTF-8'
grep -q 'JAVAC.*-encoding UTF-8' "$ROOT/scripts/linux/BUILD-STUDIO.sh" || fail 'Linux Studio javac encoding is not pinned to UTF-8'
grep -q 'repo.maven.apache.org/maven2/org/processing/core/4.4.6' "$ROOT/scripts/linux/BUILD-STUDIO.sh" || fail 'Linux Studio build does not bootstrap Processing Core'
grep -q 'e97850f290d8e44ba07fa0500d7a071ff444209099f0372df3dba707cba3ddc1' "$ROOT/scripts/linux/BUILD-STUDIO.sh" || fail 'Linux JOGL native hash pin missing'
for image in \
  synkinect-studio-home.png \
  synkinect-studio-3d-scanner.png \
  synkinect-studio-acoustic-scanner.png \
  synkinect-studio-microphones.png \
  synkinect-studio-surveillance.png \
  synkinect-studio-interactivity.png; do
  [[ -s "$ROOT/docs/images/$image" ]] || fail "presentation screenshot missing: $image"
done
pass 'clean-build bootstrap and presentation assets present'

printf '\nSource release validation completed successfully.\n'
