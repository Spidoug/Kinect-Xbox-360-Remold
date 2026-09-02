#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-/usr/share/kinect360-remold/UACFirmware}"
URL='https://download.microsoft.com/download/F/9/9/F99791F2-D5BE-478A-B77A-830AD14950C3/KinectSDK-v1.0-beta2-x86.msi'
KNOWN1='945806927702b2c47c32125ab9a80344'
KNOWN2='40764fe9e00911bda5095e5be777e311'
EXPECTED_CURRENT_BYTES=21823488
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_FW="${KINECT_UAC_FIRMWARE:-}"
if [[ -z "$LOCAL_FW" ]]; then
  for candidate in \
    "$SCRIPT_DIR/../firmware/UACFirmware" \
    "$SCRIPT_DIR/../../../windows/source/components/device/firmware/UACFirmware"; do
    if [[ -f "$candidate" ]]; then
      LOCAL_FW="$candidate"
      break
    fi
  done
fi

if [[ -n "$LOCAL_FW" ]]; then
  [[ -f "$LOCAL_FW" ]] || { echo "KINECT_UAC_FIRMWARE does not point to a file: $LOCAL_FW" >&2; exit 2; }
  FW="$LOCAL_FW"
else
  command -v curl >/dev/null || { echo 'curl is required' >&2; exit 2; }
  command -v 7z >/dev/null || { echo '7z is required (Ubuntu/Arch: 7zip; Fedora: p7zip + p7zip-plugins)' >&2; exit 2; }

  curl -fL --retry 3 -o "$TMP/kinect.msi" "$URL"
  MD5="$(md5sum "$TMP/kinect.msi" | awk '{print $1}')"
  [[ "$MD5" == "$KNOWN1" || "$MD5" == "$KNOWN2" ]] || {
    echo "Unexpected Kinect SDK MSI MD5: $MD5" >&2
    exit 3
  }
  if [[ "$MD5" == "$KNOWN1" ]]; then
    BYTES="$(stat -c %s "$TMP/kinect.msi")"
    [[ "$BYTES" -eq "$EXPECTED_CURRENT_BYTES" ]] || {
      echo "Unexpected size for current Kinect SDK MSI: $BYTES" >&2
      exit 3
    }
  fi

  mkdir -p "$TMP/extract"
  # The UAC image lives in an embedded MSI cabinet. msiextract alone does not
  # reliably recurse into that cabinet; 7-Zip's recursive extraction does.
  (
    cd "$TMP/extract"
    7z e -y -r "$TMP/kinect.msi" 'UACFirmware.*' >/dev/null
  )
  FW="$(find "$TMP/extract" -maxdepth 1 -type f -iname 'UACFirmware*' -print -quit)"
  [[ -n "$FW" ]] || {
    echo 'UACFirmware was not found in the pinned SDK package after recursive MSI/CAB extraction.' >&2
    exit 4
  }
fi

SIZE="$(stat -c %s "$FW")"
(( SIZE >= 65536 && SIZE <= 1048576 )) || {
  echo "Unexpected UACFirmware size: $SIZE" >&2
  exit 5
}
install -D -m 0644 "$FW" "$DEST"
echo "Installed Microsoft Kinect UACFirmware to $DEST ($SIZE bytes)."
