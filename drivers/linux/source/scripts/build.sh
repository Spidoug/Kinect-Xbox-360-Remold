#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
ARCH="$(uname -m)"
BUILD_DIR="${REMOLD_BUILD_DIR:-$PLATFORM_ROOT/.build/$ARCH}"
DIST_DIR="${REMOLD_DIST_DIR:-$PLATFORM_ROOT/dist/$ARCH}"
JOBS="${REMOLD_BUILD_JOBS:-}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--clean] [--build-dir PATH] [--dist-dir PATH] [--] [CMake options]

Builds the current Kinect 360 Remold Linux runtime from source and stages only
artifacts produced by this invocation. No precompiled driver payload is used.
USAGE
}

CLEAN=0
CMAKE_ARGS=()
while (($#)); do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --dist-dir) DIST_DIR="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; CMAKE_ARGS+=("$@"); break ;;
    *) CMAKE_ARGS+=("$1"); shift ;;
  esac
done

if (( CLEAN )); then
  rm -rf "$BUILD_DIR" "$DIST_DIR"
fi
mkdir -p "$BUILD_DIR"
rm -rf "$DIST_DIR"

cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DREMOLD_BUILD_HARDWARE=ON "${CMAKE_ARGS[@]}"
if [[ -n "$JOBS" ]]; then
  cmake --build "$BUILD_DIR" --parallel "$JOBS"
else
  cmake --build "$BUILD_DIR" --parallel
fi
cmake --install "$BUILD_DIR" --prefix "$DIST_DIR"

mkdir -p "$DIST_DIR/support"
for dir in udev systemd config modprobe modules-load; do
  cp -a "$SOURCE_ROOT/$dir" "$DIST_DIR/support/"
done

cat > "$DIST_DIR/BUILD-MANIFEST.txt" <<MANIFEST
Kinect Xbox 360 Remold native Linux runtime
Version: 1.0
Architecture: $ARCH
Source: drivers/linux/source
Build type: Release
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

printf 'Linux Remold runtime built from current source.\nOutput: %s\n' "$DIST_DIR"
