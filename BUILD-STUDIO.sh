#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKETCH="$ROOT/applications/processing/SynKinectStudio"
LINUX_APP="$ROOT/applications/binaries/linux-x64"
WINDOWS_APP="$ROOT/applications/binaries/windows-x64"
LIB="$LINUX_APP/lib"

JAVAC="${JAVAC:-$(command -v javac || true)}"
JAR="${JAR:-$(command -v jar || true)}"
[[ -n "$JAVAC" && -n "$JAR" ]] || { echo 'JDK 17+ (javac and jar) is required.' >&2; exit 2; }

version="$($JAVAC -version 2>&1 | awk '{print $2}')"
feature="${version%%.*}"
if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
[[ "$feature" =~ ^[0-9]+$ && "$feature" -ge 17 ]] || { echo "JDK 17+ required, found: $version" >&2; exit 2; }

for dep in core-4.4.6.jar jogl-all-2.5.0.jar gluegen-rt-2.5.0.jar; do
  [[ -f "$LIB/$dep" ]] || { echo "Missing compile dependency: $LIB/$dep" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/classes"
JAVA_SRC="$WORK/SynKinectStudio.java"
{
  printf '%s\n' 'import processing.core.*;' 'import processing.data.*;' 'import processing.event.*;' 'import processing.opengl.*;'
  grep '^import ' "$SKETCH/SynKinectStudio.pde" || true
  printf '%s\n' 'public class SynKinectStudio extends PApplet {'
  sed '/^import /d' "$SKETCH/SynKinectStudio.pde"
  while IFS= read -r tab; do sed '/^import /d' "$tab"; done < <(find "$SKETCH" -maxdepth 1 -type f -name '*.pde' ! -name 'SynKinectStudio.pde' -print | sort -f)
  printf '%s\n' 'public static void main(String[] args){PApplet.main(SynKinectStudio.class.getName());}' '}'
} > "$JAVA_SRC"

CP="$LIB/core-4.4.6.jar:$LIB/jogl-all-2.5.0.jar:$LIB/gluegen-rt-2.5.0.jar"
"$JAVAC" --release 17 -Xlint:all -cp "$CP" -d "$WORK/classes" "$JAVA_SRC"
cp "$SKETCH/data/synkinect-studio-icon.png" "$WORK/classes/synkinect-studio-icon.png"
cat > "$WORK/MANIFEST.MF" <<MANIFEST
Manifest-Version: 1.0
Main-Class: SynKinectStudio
Implementation-Title: SynKinect Studio
Implementation-Version: 1.0
MANIFEST
"$JAR" --create --file "$WORK/SynKinectStudio.jar" --manifest "$WORK/MANIFEST.MF" --date=2026-01-01T00:00:00Z -C "$WORK/classes" .

for app in "$LINUX_APP" "$WINDOWS_APP"; do
  install -D -m 0644 "$WORK/SynKinectStudio.jar" "$app/lib/SynKinectStudio.jar"
  rm -rf "$app/data"
  cp -a "$SKETCH/data" "$app/data"
done
sha256sum "$LINUX_APP/lib/SynKinectStudio.jar" "$WINDOWS_APP/lib/SynKinectStudio.jar"
echo 'SynKinect Studio 1.0 rebuilt and staged for Linux x64 and Windows x64.'
