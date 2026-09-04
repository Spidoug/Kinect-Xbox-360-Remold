#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER="$ROOT/drivers/linux"
SRC="$DRIVER/source"
REQUIRE_HARDWARE=0
[[ ${1:-} == --require-hardware-build ]] && REQUIRE_HARDWARE=1
[[ $# -le 1 ]] || { echo "Usage: $0 [--require-hardware-build]" >&2; exit 2; }

pass(){ printf 'PASS  %s\n' "$1"; }
fail(){ printf 'FAIL  %s\n' "$1" >&2; exit 1; }
info(){ printf 'INFO  %s\n' "$1"; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "required validation tool missing: $1"; }
for tool in bash cmake udevadm systemd-analyze grep find; do need "$tool"; done

# Source-release invariant: native driver binaries/packages are generated outputs,
# never repository inputs.
if find "$ROOT/drivers" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' -o -iname '*.cat' -o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.so' -o -iname '*.a' -o -iname '*.o' \) -print -quit | grep -q .; then
  find "$ROOT/drivers" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' -o -iname '*.cat' -o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.so' -o -iname '*.a' -o -iname '*.o' \) -print >&2
  fail 'native driver binary/package committed in source release'
fi
[[ ! -e "$DRIVER/INSTALL-PREBUILT.sh" ]] || fail 'precompiled Linux install entry point still exists'
! grep -R -n -E 'drivers/linux/binaries|INSTALL-PREBUILT|--prebuilt' "$DRIVER" "$ROOT/scripts/linux" --include='*.sh' --include='*.md' --include='*.spec' --exclude='VERIFY-V1.sh' --exclude='VERIFY-SOURCE-RELEASE.sh' >/dev/null || fail 'Linux build/install still references a precompiled driver payload'
pass 'Linux source release contains no native driver payload'

while IFS= read -r script; do bash -n "$script"; done < <(find "$DRIVER" "$ROOT/scripts/linux" -type f -name '*.sh' -print | sort)
pass 'all Linux shell scripts parse'

udevadm verify "$SRC/udev/60-kinect360-remold.rules" >/dev/null
pass 'udev rules accepted by udevadm'

grep -q 'SYSTEMD_WANTS.*kinect360-remold.target' "$SRC/udev/60-kinect360-remold.rules" || fail 'udev target activation rule missing'
! grep -q '^WantedBy=' "$SRC/systemd/kinect360-remold.target" || fail 'runtime target must not be boot-enabled'
grep -q 'disable kinect360-remold.target' "$SRC/scripts/install.sh" || fail 'installer must keep target disabled at boot'
pass 'single udev -> systemd lifecycle policy'

grep -q 'kDeviceManifest.*devices.tsv' "$SRC/include/remold/protocol.hpp" || fail 'device manifest contract missing'
grep -q 'kRuntimeDir.*devices/' "$SRC/src/camera_bridge.cpp" || fail 'per-device scanner sockets missing'
grep -q 'kinectusb::enumerate()' "$SRC/src/camera_bridge.cpp" || fail 'multi-Kinect enumeration missing'
! grep -R -q '/run/kinect360-remold/scanner.sock' "$SRC/src" "$SRC/include" || fail 'singleton scanner socket referenced'
grep -q 'StreamRgbHighQuality' "$SRC/include/remold/protocol.hpp" || fail 'RGB-HQ protocol bit missing'
grep -q 'BayerGrbg8' "$SRC/include/remold/protocol.hpp" || fail 'RGB-HQ Bayer pixel format missing'
grep -q 'RgbHighQuality' "$SRC/src/kinect_usb_camera.cpp" || fail 'native RGB-HQ camera mode missing'
grep -Eq 'kRgbHqWidth[[:space:]]*=[[:space:]]*1280' "$SRC/include/remold/protocol.hpp" || fail 'RGB-HQ width mismatch'
grep -Eq 'kRgbHqHeight[[:space:]]*=[[:space:]]*1024' "$SRC/include/remold/protocol.hpp" || fail 'RGB-HQ height mismatch'
pass 'multi-Kinect registry, per-device transport and RGB-HQ protocol policy'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cmake -S "$SRC" -B "$TMP/control" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=OFF >/dev/null
cmake --build "$TMP/control" --parallel >/dev/null
[[ -x "$TMP/control/kinect360-remoldctl" ]] || fail 'control-only native build did not produce kinect360-remoldctl'
pass 'native C++17 control build from source'

hardware_ready=1
command -v pkg-config >/dev/null 2>&1 || hardware_ready=0
if (( hardware_ready )); then pkg-config --exists libusb-1.0 alsa || hardware_ready=0; fi
if (( hardware_ready )); then
  if cmake -S "$SRC" -B "$TMP/hardware" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON >/dev/null 2>"$TMP/hardware-config.log" \
     && cmake --build "$TMP/hardware" --parallel >/dev/null; then
    for name in broker camera audio v4l2 camera-ip; do
      [[ -x "$TMP/hardware/kinect360-remold-$name" ]] || fail "hardware build missing kinect360-remold-$name"
    done
    pass 'full native hardware runtime builds from source'

    mkdir -p "$TMP/systemd"
    for unit in "$SRC"/systemd/*; do
      out="$TMP/systemd/$(basename "$unit")"; cp "$unit" "$out"
      case "$(basename "$unit")" in
        *-broker.service) exe="$TMP/hardware/kinect360-remold-broker" ;;
        *-camera.service) exe="$TMP/hardware/kinect360-remold-camera" ;;
        *-audio.service) exe="$TMP/hardware/kinect360-remold-audio" ;;
        *-v4l2.service) exe="$TMP/hardware/kinect360-remold-v4l2" ;;
        *-camera-ip.service) exe="$TMP/hardware/kinect360-remold-camera-ip" ;;
        *) exe='' ;;
      esac
      [[ -z "$exe" ]] || sed -i "s#^ExecStart=.*#ExecStart=$exe#" "$out"
    done
    systemd-analyze verify "$TMP/systemd"/* >/dev/null
    pass 'systemd units structurally verified against fresh executables'

    if command -v dpkg-deb >/dev/null 2>&1; then
      "$DRIVER/packages/build-deb.sh" amd64 >/dev/null
      DEB="$DRIVER/packages/output/kinect360-remold_1.0-1_amd64.deb"
      [[ -f "$DEB" ]] || fail 'Debian package was not generated from source'
      [[ "$(dpkg-deb -f "$DEB" Package)" == kinect360-remold ]] || fail 'unexpected Debian package name'
      [[ "$(dpkg-deb -f "$DEB" Version)" == 1.0-1 ]] || fail 'unexpected Debian package version'
      rm -rf "$DRIVER/packages/output"
      pass 'Debian package builder compiles and packages current source'
    else
      info 'dpkg-deb unavailable; Debian package execution test skipped'
    fi
  else
    cat "$TMP/hardware-config.log" >&2 || true
    fail 'hardware dependencies are present but full native build failed'
  fi
else
  (( REQUIRE_HARDWARE == 0 )) || fail 'full hardware build requested but libusb/ALSA development packages are unavailable'
  info 'full hardware compile/package execution skipped: libusb-1.0/ALSA development packages unavailable'
fi

grep -q '^%build' "$DRIVER/packages/rpm/kinect360-remold.spec" || fail 'RPM recipe has no source build stage'
grep -q 'cmake -S \. -B build' "$DRIVER/packages/rpm/kinect360-remold.spec" || fail 'RPM recipe does not compile source from its generated source archive'
! grep -q 'drivers/linux/binaries' "$DRIVER/packages/rpm/kinect360-remold.spec" || fail 'RPM recipe references binary input'
grep -q 'Requires:       v4l2loopback >= 0.15.0' "$DRIVER/packages/rpm/kinect360-remold.spec" || fail 'RPM recipe lacks v4l2loopback >= 0.15 requirement'
[[ -x "$DRIVER/packages/build-rpm.sh" ]] || fail 'RPM source builder missing'
grep -q 'cp -a "$SRC/."' "$DRIVER/packages/build-rpm.sh" || fail 'RPM builder does not create its source archive from current source'
pass 'RPM recipe and builder compile the current source and follow V1 runtime policy'

printf '\nLinux V1 source-build validation completed successfully.\n'
