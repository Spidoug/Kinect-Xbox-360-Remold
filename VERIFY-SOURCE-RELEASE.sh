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
  fail 'historical fixes document found in clean baseline'
fi
if find "$ROOT/drivers/windows" -type f -iname '*1473*.ps1' -print -quit | grep -q .; then
  find "$ROOT/drivers/windows" -type f -iname '*1473*.ps1' -print >&2
  fail 'version-specific 1473 recovery script found in clean baseline'
fi
pass 'version-specific recovery payloads are absent'

[[ ! -e "$ROOT/drivers/linux/INSTALL-PREBUILT.sh" ]] || fail 'removed Linux precompiled installer is present'
! grep -R -n -E 'INSTALL-PREBUILT|--prebuilt|drivers/linux/binaries' "$ROOT/drivers" "$ROOT/scripts" --include='*.sh' --include='*.cmd' --include='*.ps1' --include='*.md' --include='*.spec' --exclude='VERIFY-SOURCE-RELEASE.sh' --exclude='VERIFY-V1.sh' >/dev/null || fail 'source/build text still depends on a precompiled Linux driver payload'
pass 'builders have no precompiled driver input path'

# Retired protocol/UI contracts must not reappear.
! grep -R -n -E '/run/kinect360-remold/scanner\.sock|armed_ir|low_light_ir|recording_rgb|surveillance-motion\.mp4' "$ROOT" --exclude-dir='.git' --exclude='*.jar' --exclude='VERIFY-SOURCE-RELEASE.sh' --exclude='VERIFY-V1.sh' >/dev/null || fail 'retired V1 contract text/source found'
pass 'retired singleton/Surveillance contracts are absent'

[[ ! -d "$ROOT/drivers/windows/source/components/device/firmware/remold-audio" ]] || fail 'non-release experimental audio firmware tree is present'
[[ ! -e "$ROOT/docs/windows/CUSTOM-AUDIO-FIRMWARE.md" ]] || fail 'non-release custom audio firmware document is present'
! grep -R -n 'acoustic.echo.pending' "$ROOT/applications" --include='*.properties' >/dev/null || fail 'inactive acoustic echo UI contract is present'
pass 'V1 audio source/docs contain only the active UAC/raw-four-channel path'

! grep -R -n -E '\b(prebuilt|pre-built)\b|old per-module|previous custom|previous fixed|former standalone' \
  "$ROOT/README.md" "$ROOT/docs" "$ROOT/drivers" "$ROOT/applications" \
  --include='*.md' --include='*.txt' >/dev/null || fail 'historical/retired wording remains in public documentation'
pass 'public documentation uses current V1 terminology'

for required in \
  "$ROOT/docs/RELEASE-V1.md" \
  "$ROOT/docs/SCANNER-QUALITY.md" \
  "$ROOT/docs/BUILD-DRIVERS.md" \
  "$ROOT/PROJECT-AUDIT.md"; do
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
pass 'static architecture contracts present'

printf '\nSource release validation completed successfully.\n'
