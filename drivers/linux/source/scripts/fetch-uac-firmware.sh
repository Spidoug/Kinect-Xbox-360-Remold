#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-/usr/share/kinect360-remold/UACFirmware}"
EXPECTED_VERSION='01.02.709.00'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_FW="${KINECT_UAC_FIRMWARE:-}"

if [[ -z "$LOCAL_FW" ]]; then
  for candidate in \
    "$SCRIPT_DIR/../firmware/UACFirmware-$EXPECTED_VERSION" \
    "$SCRIPT_DIR/../firmware/UACFirmware" \
    "$SCRIPT_DIR/../../../windows/source/components/device/firmware/UACFirmware-$EXPECTED_VERSION"; do
    if [[ -f "$candidate" ]]; then
      LOCAL_FW="$candidate"
      break
    fi
  done
fi

if [[ -z "$LOCAL_FW" ]]; then
  cat >&2 <<EOF
Kinect Xbox 360 Remold V1 requires Microsoft Kinect Runtime 1.8 UACFirmware $EXPECTED_VERSION.
No non-V1 SDK firmware package is downloaded by the V1 Linux installer.
Provide the current raw UACFirmware image with one of these methods:
  KINECT_UAC_FIRMWARE=/path/to/UACFirmware sudo -E ./drivers/linux/INSTALL.sh
or place it before packaging at:
  drivers/linux/source/firmware/UACFirmware-$EXPECTED_VERSION
The camera/depth runtime can still operate without this file; audio will retry when it is installed.
EOF
  exit 2
fi

[[ -f "$LOCAL_FW" ]] || { echo "KINECT_UAC_FIRMWARE does not point to a file: $LOCAL_FW" >&2; exit 2; }
SIZE="$(stat -c %s "$LOCAL_FW")"
(( SIZE >= 65536 && SIZE <= 1048576 )) || {
  echo "Unexpected UACFirmware size: $SIZE" >&2
  exit 5
}
install -D -m 0644 "$LOCAL_FW" "$DEST"
echo "Installed Microsoft Kinect Runtime 1.8 UACFirmware $EXPECTED_VERSION to $DEST ($SIZE bytes)."
