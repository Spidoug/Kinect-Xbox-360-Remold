#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKETCH="$ROOT/applications/processing/SynKinectStudio"
TEMPLATES="$ROOT/applications/runtime-templates"
LINUX_APP="$ROOT/applications/binaries/linux-x64"
WINDOWS_APP="$ROOT/applications/binaries/windows-x64"
LINUX_LIB="$LINUX_APP/lib"
WINDOWS_LIB="$WINDOWS_APP/lib"
CACHE="$ROOT/.cache/studio"

mkdir -p "$LINUX_LIB" "$WINDOWS_LIB" "$CACHE"

JAVAC="${JAVAC:-$(command -v javac || true)}"
JAR="${JAR:-$(command -v jar || true)}"
[[ -n "$JAVAC" && -n "$JAR" ]] || { echo 'JDK 17+ (javac and jar) is required.' >&2; exit 2; }

version="$($JAVAC -version 2>&1 | awk '{print $2}')"
feature="${version%%.*}"
if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
[[ "$feature" =~ ^[0-9]+$ && "$feature" -ge 17 ]] || { echo "JDK 17+ required, found: $version" >&2; exit 2; }

if command -v curl >/dev/null 2>&1; then
  downloader=curl
elif command -v wget >/dev/null 2>&1; then
  downloader=wget
else
  echo 'curl or wget is required to bootstrap pinned Studio dependencies.' >&2
  exit 2
fi

sha256_file(){ sha256sum "$1" | awk '{print $1}'; }
fetch_pinned(){
  local name="$1" url="$2" expected="$3" cached="$CACHE/$name" tmp="$CACHE/$name.download"
  if [[ -f "$cached" && "$(sha256_file "$cached")" == "$expected" ]]; then
    printf '%s\n' "$cached"; return 0
  fi
  rm -f "$cached" "$tmp"
  local attempt
  for attempt in 1 2 3 4 5; do
    echo "Downloading $name (attempt $attempt/5)..." >&2
    if [[ "$downloader" == curl ]]; then
      curl -fL --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 -o "$tmp" "$url" || true
    else
      wget --timeout=20 --tries=3 -O "$tmp" "$url" || true
    fi
    if [[ -f "$tmp" && "$(sha256_file "$tmp")" == "$expected" ]]; then
      mv "$tmp" "$cached"
      printf '%s\n' "$cached"; return 0
    fi
    rm -f "$tmp"
    sleep $((attempt*2))
  done
  echo "Could not download verified dependency: $name" >&2
  return 1
}
stage(){
  local name="$1" url="$2" sha="$3" target="$4" source
  source="$(fetch_pinned "$name" "$url" "$sha")"
  mkdir -p "$target"
  cp -f "$source" "$target/$name"
}

PROCESSING_BASE='https://repo.maven.apache.org/maven2/org/processing/core/4.4.6'
JOGL_BASE='https://jogamp.org/deployment/maven/org/jogamp/jogl/jogl-all/2.5.0'
GLUEGEN_BASE='https://jogamp.org/deployment/maven/org/jogamp/gluegen/gluegen-rt/2.5.0'

for target in "$LINUX_LIB" "$WINDOWS_LIB"; do
  stage core-4.4.6.jar "$PROCESSING_BASE/core-4.4.6.jar" e92f6f517963e2f63882c71ab92ed46c98dbfa1cbccab8b2475c1d76ceca0f86 "$target"
  stage jogl-all-2.5.0.jar "$JOGL_BASE/jogl-all-2.5.0.jar" 245717cceabca264a210a899f8839d47bd127f50f80892ead2277dd89cbcd301 "$target"
  stage gluegen-rt-2.5.0.jar "$GLUEGEN_BASE/gluegen-rt-2.5.0.jar" 3620c18536a8671fcb1c595d7448e9d31226b824117af6a4c6d45c657f4dabe3 "$target"
done
stage jogl-all-2.5.0-natives-linux-amd64.jar "$JOGL_BASE/jogl-all-2.5.0-natives-linux-amd64.jar" e97850f290d8e44ba07fa0500d7a071ff444209099f0372df3dba707cba3ddc1 "$LINUX_LIB"
stage gluegen-rt-2.5.0-natives-linux-amd64.jar "$GLUEGEN_BASE/gluegen-rt-2.5.0-natives-linux-amd64.jar" 6d998d0c1f04f103894b769049086124505063cea86a82896194bb53c88b040a "$LINUX_LIB"
stage jogl-all-2.5.0-natives-windows-amd64.jar "$JOGL_BASE/jogl-all-2.5.0-natives-windows-amd64.jar" ce0b755f6bc0eeefd386539e72d13e4d8e96e1f086ca222f8a02e11320032142 "$WINDOWS_LIB"
stage gluegen-rt-2.5.0-natives-windows-amd64.jar "$GLUEGEN_BASE/gluegen-rt-2.5.0-natives-windows-amd64.jar" a4f039e2fa9d616be9f26284ffd6afe5fae26d521d21f28126e5eaa073f8a438 "$WINDOWS_LIB"
echo 'Pinned Processing/JOGL/GlueGen dependencies: READY'

cp -f "$TEMPLATES/windows-x64/SynKinectStudio.cmd" "$WINDOWS_APP/SynKinectStudio.cmd"
cp -f "$TEMPLATES/linux-x64/SynKinectStudio.sh" "$LINUX_APP/SynKinectStudio.sh"
cp -f "$TEMPLATES/linux-x64/SynKinectStudio.desktop" "$LINUX_APP/SynKinectStudio.desktop"
cp -f "$SKETCH/data/synkinect-studio-icon.png" "$LINUX_APP/synkinect-studio-icon.png"
chmod +x "$LINUX_APP/SynKinectStudio.sh"

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

CP="$LINUX_LIB/core-4.4.6.jar:$LINUX_LIB/jogl-all-2.5.0.jar:$LINUX_LIB/gluegen-rt-2.5.0.jar"
"$JAVAC" -encoding UTF-8 --release 17 -Xlint:all -cp "$CP" -d "$WORK/classes" "$JAVA_SRC"
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
