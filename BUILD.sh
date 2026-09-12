#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo '============================================================'
echo ' Kinect Xbox 360 Remold - Linux source build'
echo '============================================================'

bash "$ROOT/scripts/linux/BUILD-STUDIO.sh"
bash "$ROOT/scripts/linux/BUILD-DRIVER.sh" --clean "$@"

echo
echo 'Build completed.'
echo "Studio: $ROOT/applications/binaries/linux-x64"
echo "Driver: $ROOT/drivers/linux/dist/$(uname -m)"
