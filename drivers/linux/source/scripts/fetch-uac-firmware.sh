#!/usr/bin/env bash
set -euo pipefail
DEST="${1:-/usr/share/kinect360-remold/UACFirmware}"
URL='https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi'
KNOWN1='945806927702b2c47c32125ab9a80344'
KNOWN2='40764fe9e00911bda5095e5be777e311'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [[ -f "$(dirname "$0")/../../components/device/firmware/UACFirmware" ]]; then
  FW="$(dirname "$0")/../../components/device/firmware/UACFirmware"
else
  command -v curl >/dev/null || { echo 'curl is required' >&2; exit 2; }
  command -v msiextract >/dev/null || { echo 'msiextract (msitools) is required' >&2; exit 2; }
  curl -fL --retry 3 -o "$TMP/kinect.msi" "$URL"
  MD5="$(md5sum "$TMP/kinect.msi" | awk '{print $1}')"
  [[ "$MD5" == "$KNOWN1" || "$MD5" == "$KNOWN2" ]] || { echo "Unexpected Kinect SDK MSI MD5: $MD5" >&2; exit 3; }
  mkdir "$TMP/extract"; msiextract -C "$TMP/extract" "$TMP/kinect.msi" >/dev/null
  FW="$(find "$TMP/extract" -type f -iname 'UACFirmware*' | head -n1 || true)"
  [[ -n "$FW" ]] || { echo 'UACFirmware was not found in the pinned SDK package.' >&2; exit 4; }
fi
SIZE="$(stat -c %s "$FW")"; (( SIZE >= 65536 && SIZE <= 1048576 )) || { echo "Unexpected UACFirmware size: $SIZE" >&2; exit 5; }
install -D -m 0644 "$FW" "$DEST"
echo "Installed Microsoft Kinect UACFirmware to $DEST ($SIZE bytes)."
