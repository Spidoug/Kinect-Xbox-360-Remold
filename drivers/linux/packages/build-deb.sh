#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${1:-amd64}"
[[ "$ARCH" == amd64 ]] || { echo "Only amd64/x86_64 is supported by this V1 package recipe." >&2; exit 2; }
VERSION="${REMOLD_DEB_VERSION:-1.0-1}"
SRC="$ROOT/source"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BUILD="$WORK/build"
STAGE="$WORK/stage"
PKG="$WORK/pkg"
OUTDIR="$ROOT/packages/output"

# Source-only release rule: every package is compiled from the source tree in
# this invocation. There is no driver binary input directory.
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON
cmake --build "$BUILD" --parallel
cmake --install "$BUILD" --prefix "$STAGE/usr"

mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/libexec/kinect360-remold" \
  "$PKG/usr/lib/systemd/system" "$PKG/usr/share/kinect360-remold" \
  "$PKG/usr/share/doc/kinect360-remold" "$PKG/etc/udev/rules.d" \
  "$PKG/etc/modprobe.d" "$PKG/etc/modules-load.d" "$PKG/etc/kinect360-remold"
install -m 0755 "$STAGE/usr/bin/kinect360-remoldctl" "$PKG/usr/bin/"
for file in "$STAGE/usr/libexec/kinect360-remold"/*; do install -m 0755 "$file" "$PKG/usr/libexec/kinect360-remold/"; done
install -m 0644 "$SRC"/systemd/* "$PKG/usr/lib/systemd/system/"
install -m 0644 "$SRC/udev/60-kinect360-remold.rules" "$PKG/etc/udev/rules.d/"
install -m 0644 "$SRC/modprobe/kinect360-remold-v4l2.conf" "$PKG/etc/modprobe.d/"
install -m 0644 "$SRC/modules-load/kinect360-remold.conf" "$PKG/etc/modules-load.d/"
install -m 0644 "$SRC/config/remold.conf" "$PKG/etc/kinect360-remold/remold.conf"
install -m 0755 "$SRC/scripts/fetch-uac-firmware.sh" "$PKG/usr/share/kinect360-remold/fetch-uac-firmware.sh"
install -m 0644 "$ROOT/README.md" "$PKG/usr/share/doc/kinect360-remold/README-Linux.md"
install -m 0644 "$ROOT/../../docs/linux/DRIVER-RUNTIME.md" "$PKG/usr/share/doc/kinect360-remold/DRIVER-RUNTIME.md"
install -m 0644 "$ROOT/../../docs/linux/WINDOWS-PARITY.md" "$PKG/usr/share/doc/kinect360-remold/WINDOWS-PARITY.md"

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: kinect360-remold
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: Kinect Xbox 360 Remold Project
Depends: libc6, libstdc++6, libusb-1.0-0, libasound2t64 | libasound2, libjpeg62-turbo, systemd, udev, kmod, v4l2loopback-dkms (>= 0.15.0)
Description: Kinect Xbox 360 Remold native Linux runtime
 Direct libusb RGB/IR/depth, four-channel audio, motor/status broker,
 V4L2 virtual camera and authenticated IP-camera runtime for Kinect 1414.
CONTROL
cat > "$PKG/DEBIAN/conffiles" <<'CONFFILES'
/etc/kinect360-remold/remold.conf
CONFFILES
cat > "$PKG/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
case "${1:-configure}" in
  configure)
    CONF=/etc/kinect360-remold/remold.conf
    if [ -f "$CONF" ] && grep -q '^ip.password=$' "$CONF"; then
      PASS="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
      sed -i "s/^ip.password=.*/ip.password=$PASS/" "$CONF"
      chmod 0640 "$CONF"
      install -d -m 0755 /var/lib/kinect360-remold
      printf 'IP camera user: admin\nIP camera password: %s\n' "$PASS" > /var/lib/kinect360-remold/ip-camera-credentials.txt
      chmod 0600 /var/lib/kinect360-remold/ip-camera-credentials.txt
    fi
    install -d -m 0755 /usr/share/kinect360-remold
    if [ ! -f /usr/share/kinect360-remold/UACFirmware ]; then
      /usr/share/kinect360-remold/fetch-uac-firmware.sh /usr/share/kinect360-remold/UACFirmware || \
        echo 'Kinect UAC firmware was not downloaded during setup; camera/depth remains available and audio will retry when firmware is provided.' >&2
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl disable kinect360-remold.target >/dev/null 2>&1 || true
    udevadm control --reload-rules >/dev/null 2>&1 || true
    udevadm trigger --subsystem-match=usb >/dev/null 2>&1 || true
    modprobe v4l2loopback >/dev/null 2>&1 || true
    KINECT_PRESENT=0
    for DEV in /sys/bus/usb/devices/*; do
      [ -r "$DEV/idVendor" ] && [ -r "$DEV/idProduct" ] || continue
      [ "$(cat "$DEV/idVendor")" = "045e" ] || continue
      case "$(cat "$DEV/idProduct")" in 02b0|02c2|02ae|02ad|02bb|02c3) KINECT_PRESENT=1; break;; esac
    done
    if [ "$KINECT_PRESENT" = 1 ]; then systemctl start kinect360-remold.target >/dev/null 2>&1 || true; fi
    ;;
esac
exit 0
POSTINST
cat > "$PKG/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
if [ "${1:-}" = remove ] || [ "${1:-}" = deconfigure ]; then
  systemctl stop kinect360-remold.target >/dev/null 2>&1 || true
fi
exit 0
PRERM
cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
udevadm control --reload-rules >/dev/null 2>&1 || true
if [ "${1:-}" = purge ]; then
  rm -rf /var/lib/kinect360-remold /usr/share/kinect360-remold/UACFirmware
fi
exit 0
POSTRM
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

mkdir -p "$OUTDIR"
OUT="$OUTDIR/kinect360-remold_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKG" "$OUT" >/dev/null
(cd "$OUTDIR" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
printf '%s\n' "$OUT"
