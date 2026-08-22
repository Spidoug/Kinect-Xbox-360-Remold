#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ROOT="$(cd "$ROOT/.." && pwd)"
ARCH="$(uname -m)"
NO_DEPS=0
USE_PREBUILT=0

for arg in "$@"; do
  case "$arg" in
    --no-deps) NO_DEPS=1 ;;
    --prebuilt) USE_PREBUILT=1 ;;
    *) echo "Unknown option: $arg" >&2; echo "Usage: sudo $0 [--no-deps] [--prebuilt]" >&2; exit 2 ;;
  esac
done

install_deps(){
  if (( NO_DEPS )); then return; fi
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential cmake pkg-config libusb-1.0-0-dev libasound2-dev libjpeg-dev v4l2loopback-dkms msitools curl
  elif command -v dnf >/dev/null; then
    dnf install -y gcc-c++ cmake pkgconf-pkg-config libusb1-devel alsa-lib-devel libjpeg-turbo-devel v4l2loopback msitools curl
  elif command -v pacman >/dev/null; then
    pacman -S --needed --noconfirm base-devel cmake pkgconf libusb alsa-lib libjpeg-turbo v4l2loopback-dkms msitools curl
  else
    echo 'Unsupported package manager. Install CMake, libusb, ALSA, libjpeg, v4l2loopback and msitools manually, then use --no-deps.' >&2
    exit 2
  fi
}

install_prebuilt(){
  local bin_root="$PLATFORM_ROOT/binaries/$ARCH"
  local libexec="$bin_root/libexec/kinect360-remold"
  local required=(
    "$bin_root/bin/kinect360-remoldctl"
    "$libexec/kinect360-remold-broker"
    "$libexec/kinect360-remold-camera"
    "$libexec/kinect360-remold-audio"
    "$libexec/kinect360-remold-v4l2"
    "$libexec/kinect360-remold-camera-ip"
  )
  for file in "${required[@]}"; do
    [[ -x "$file" ]] || { echo "Prebuilt binary missing: $file" >&2; return 1; }
  done
  install -D -m 0755 "$bin_root/bin/kinect360-remoldctl" /usr/bin/kinect360-remoldctl
  mkdir -p /usr/libexec/kinect360-remold
  for file in "$libexec"/*; do install -m 0755 "$file" "/usr/libexec/kinect360-remold/$(basename "$file")"; done
  echo "Installed prebuilt Remold runtime for $ARCH."
}

install_deps
if (( USE_PREBUILT )); then
  install_prebuilt
else
  "$ROOT/scripts/build.sh"
  cmake --install "$ROOT/build-$ARCH" --prefix /usr
fi

install -D -m 0644 "$ROOT/udev/60-kinect360-remold.rules" /etc/udev/rules.d/60-kinect360-remold.rules
install -D -m 0644 "$ROOT/modprobe/kinect360-remold-v4l2.conf" /etc/modprobe.d/kinect360-remold-v4l2.conf
install -D -m 0644 "$ROOT/modules-load/kinect360-remold.conf" /etc/modules-load.d/kinect360-remold.conf
mkdir -p /etc/kinect360-remold
if [[ ! -f /etc/kinect360-remold/remold.conf ]]; then
  PASS="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  sed -e 's/^ip.enabled=false/ip.enabled=true/' -e "s/^ip.password=.*/ip.password=$PASS/" "$ROOT/config/remold.conf" > /etc/kinect360-remold/remold.conf
  chmod 0640 /etc/kinect360-remold/remold.conf
  echo "IP camera credentials: admin / $PASS"
fi
for f in "$ROOT"/systemd/*; do install -D -m 0644 "$f" "/etc/systemd/system/$(basename "$f")"; done
"$ROOT/scripts/fetch-uac-firmware.sh" /usr/share/kinect360-remold/UACFirmware
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb || true
modprobe v4l2loopback || true
systemctl daemon-reload
systemctl enable kinect360-remold.target >/dev/null
systemctl restart kinect360-remold.target
USER_TO_ADD="${SUDO_USER:-}"
if [[ -n "$USER_TO_ADD" && "$USER_TO_ADD" != root ]]; then usermod -aG video,audio "$USER_TO_ADD" || true; fi

echo 'Kinect Xbox 360 Remold Linux installed. Reconnect the Kinect; the runtime will bind automatically.'
echo 'Use: kinect360-remoldctl status'
