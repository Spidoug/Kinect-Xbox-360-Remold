#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NO_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --no-deps) NO_DEPS=1 ;;
    *) echo "Unknown option: $arg" >&2; echo "Usage: sudo $0 [--no-deps]" >&2; exit 2 ;;
  esac
done

require_v4l2loopback(){
  local required="0.15.0" version="" first=""
  command -v modinfo >/dev/null 2>&1 || { echo "kmod/modinfo is required." >&2; exit 2; }
  version="$(modinfo -F version v4l2loopback 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ -n "$version" ]] || { echo "v4l2loopback is not installed. V1 requires v4l2loopback >= $required." >&2; exit 2; }
  first="$(printf '%s\n%s\n' "$required" "$version" | sort -V | head -n1)"
  [[ "$first" == "$required" ]] || { echo "v4l2loopback $version is too old. V1 requires >= $required." >&2; exit 2; }
}

install_deps(){
  (( NO_DEPS )) && return
  if command -v apt-get >/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential cmake pkg-config libusb-1.0-0-dev libasound2-dev libjpeg-dev v4l2loopback-dkms 7zip curl
  elif command -v dnf >/dev/null; then
    dnf install -y gcc-c++ cmake pkgconf-pkg-config libusb1-devel alsa-lib-devel libjpeg-turbo-devel v4l2loopback p7zip p7zip-plugins curl
  elif command -v pacman >/dev/null; then
    pacman -S --needed --noconfirm base-devel cmake pkgconf libusb alsa-lib libjpeg-turbo v4l2loopback-dkms 7zip curl
  else
    echo 'Unsupported package manager. Install CMake, libusb, ALSA, libjpeg, v4l2loopback and 7-Zip manually, then use --no-deps.' >&2
    exit 2
  fi
}

install_deps
require_v4l2loopback

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cmake -S "$ROOT" -B "$BUILD_DIR/build" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON
cmake --build "$BUILD_DIR/build" --parallel
cmake --install "$BUILD_DIR/build" --prefix /usr

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
systemctl daemon-reload
systemctl disable kinect360-remold.target >/dev/null 2>&1 || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb || true
if ! modprobe v4l2loopback; then
  echo 'v4l2loopback could not be loaded. Check DKMS status and Secure Boot module signing.' >&2
  exit 2
fi
kinect_present=0
for dev in /sys/bus/usb/devices/*; do
  [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
  [[ "$(cat "$dev/idVendor")" == "045e" ]] || continue
  case "$(cat "$dev/idProduct")" in 02b0|02c2|02ae|02ad|02bb) kinect_present=1; break;; esac
done
if (( kinect_present )); then systemctl start kinect360-remold.target; fi
USER_TO_ADD="${REMOLD_CALLER_USER:-${SUDO_USER:-}}"
if [[ -n "$USER_TO_ADD" && "$USER_TO_ADD" != root ]]; then usermod -aG video,audio "$USER_TO_ADD" || true; fi

echo 'Kinect Xbox 360 Remold Linux installed from current source. Reconnect the Kinect if needed.'
echo 'Use: kinect360-remoldctl status'
