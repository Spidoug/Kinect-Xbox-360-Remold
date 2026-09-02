#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/source"
SPEC="$ROOT/packages/rpm/kinect360-remold.spec"
VERSION=1.0
NAME=kinect360-remold
command -v rpmbuild >/dev/null 2>&1 || { echo 'rpmbuild is required.' >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/BUILD" "$WORK/BUILDROOT" "$WORK/RPMS" "$WORK/SOURCES" "$WORK/SPECS" "$WORK/SRPMS"
BUNDLE="$WORK/SOURCES/$NAME-$VERSION"
mkdir -p "$BUNDLE"
cp -a "$SRC/." "$BUNDLE/"
tar -C "$WORK/SOURCES" -czf "$WORK/SOURCES/$NAME-$VERSION.tar.gz" "$NAME-$VERSION"
cp "$SPEC" "$WORK/SPECS/"
rpmbuild --define "_topdir $WORK" -bb "$WORK/SPECS/$(basename "$SPEC")"
OUT="$ROOT/packages/output"
mkdir -p "$OUT"
find "$WORK/RPMS" -type f -name '*.rpm' -exec cp -f {} "$OUT/" \;
for rpm in "$OUT"/*.rpm; do sha256sum "$rpm" > "$rpm.sha256"; done
printf 'RPM output: %s\n' "$OUT"
