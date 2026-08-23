#!/usr/bin/env bash
set -euo pipefail
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_ROOT="$(cd "$SOURCE_ROOT/.." && pwd)"
ARCH="$(uname -m)"
BUILD_DIR="${SOURCE_ROOT}/build-${ARCH}"
BIN_DIR="${PLATFORM_ROOT}/binaries/${ARCH}"

cmake -S "$SOURCE_ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "$@"
cmake --build "$BUILD_DIR" --parallel

rm -rf "$BIN_DIR/bin" "$BIN_DIR/libexec"
cmake --install "$BUILD_DIR" --prefix "$BIN_DIR"

mkdir -p "$BIN_DIR/support"
rm -rf "$BIN_DIR/support/udev" "$BIN_DIR/support/systemd" "$BIN_DIR/support/config" "$BIN_DIR/support/modprobe" "$BIN_DIR/support/modules-load"
cp -a "$SOURCE_ROOT/udev" "$BIN_DIR/support/"
cp -a "$SOURCE_ROOT/systemd" "$BIN_DIR/support/"
cp -a "$SOURCE_ROOT/config" "$BIN_DIR/support/"
cp -a "$SOURCE_ROOT/modprobe" "$BIN_DIR/support/"
cp -a "$SOURCE_ROOT/modules-load" "$BIN_DIR/support/"

printf 'Linux Remold binaries staged at: %s\n' "$BIN_DIR"
