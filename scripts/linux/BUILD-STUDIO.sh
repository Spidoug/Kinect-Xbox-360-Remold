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

for tool in bash awk grep sed find sort sha256sum tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required build tool not found: $tool" >&2; exit 2; }
done

if command -v curl >/dev/null 2>&1; then
  downloader=curl
elif command -v wget >/dev/null 2>&1; then
  downloader=wget
else
  echo 'curl or wget is required to bootstrap Studio dependencies and Java.' >&2
  exit 2
fi

download_to(){
  local url="$1" out="$2" attempt
  rm -f "$out"
  for attempt in 1 2 3 4 5; do
    echo "Downloading $(basename "$out") (attempt $attempt/5)..." >&2
    if [[ "$downloader" == curl ]]; then
      curl -fL --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 -o "$out" "$url" && return 0
    else
      wget --timeout=20 --tries=3 -O "$out" "$url" && return 0
    fi
    rm -f "$out"
    sleep $((attempt*2))
  done
  echo "Could not download: $url" >&2
  return 1
}

sha256_file(){ sha256sum "$1" | awk '{print tolower($1)}'; }

fetch_pinned(){
  local name="$1" url="$2" expected="${3,,}" cached="$CACHE/$name" tmp="$CACHE/$name.download"
  if [[ -f "$cached" && "$(sha256_file "$cached")" == "$expected" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi
  rm -f "$cached" "$tmp"
  download_to "$url" "$tmp"
  local actual
  actual="$(sha256_file "$tmp")"
  [[ "$actual" == "$expected" ]] || {
    rm -f "$tmp"
    echo "SHA-256 mismatch for $name. Expected $expected, got $actual." >&2
    return 1
  }
  mv "$tmp" "$cached"
  printf '%s\n' "$cached"
}

stage(){
  local name="$1" url="$2" sha="$3" target="$4" source
  source="$(fetch_pinned "$name" "$url" "$sha")"
  mkdir -p "$target"
  install -m 0644 "$source" "$target/$name"
}

jdk_feature(){
  local home="$1" version feature
  version="$("$home/bin/javac" -version 2>&1 | awk '{print $2; exit}')"
  feature="${version%%.*}"
  if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
  [[ "$feature" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$feature"
}

valid_jdk_home(){
  local home="${1:-}" feature
  [[ -n "$home" && -x "$home/bin/java" && -x "$home/bin/javac" && -x "$home/bin/jar" && -x "$home/bin/jdeps" && -x "$home/bin/jlink" ]] || return 1
  feature="$(jdk_feature "$home")" || return 1
  (( feature >= 17 ))
}

bootstrap_jdk17(){
  local arch archive url checksum_url jdk_cache archive_path checksum_path expected actual extract javac_path extracted_home portable_home
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) archive='microsoft-jdk-17.0.20.1-linux-x64.tar.gz' ;;
    *)
      echo "SynKinect Studio Linux runtime currently targets x86-64; unsupported build architecture: $arch" >&2
      return 2
      ;;
  esac

  url="https://aka.ms/download-jdk/$archive"
  checksum_url="$url.sha256sum.txt"
  jdk_cache="$CACHE/jdk"
  archive_path="$jdk_cache/$archive"
  checksum_path="$jdk_cache/$archive.sha256sum.txt"
  portable_home="$jdk_cache/microsoft-jdk-17.0.20.1"
  mkdir -p "$jdk_cache"

  if valid_jdk_home "$portable_home"; then
    echo "Portable Microsoft OpenJDK 17.0.20.1: READY (cached)" >&2
    printf '%s\n' "$portable_home"
    return 0
  fi

  # Microsoft publishes a SHA-256 file beside the archive. Refresh the checksum,
  # then accept a cached archive only if it still matches that published value.
  download_to "$checksum_url" "$checksum_path"
  expected="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]+$/ && length($i)==64) {print tolower($i); exit}}' "$checksum_path")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "Could not parse the published SHA-256 for $archive." >&2; return 1; }

  if [[ ! -f "$archive_path" || "$(sha256_file "$archive_path")" != "$expected" ]]; then
    download_to "$url" "$archive_path.download"
    actual="$(sha256_file "$archive_path.download")"
    [[ "$actual" == "$expected" ]] || {
      rm -f "$archive_path.download"
      echo "SHA-256 mismatch for $archive. Expected $expected, got $actual." >&2
      return 1
    }
    mv "$archive_path.download" "$archive_path"
  fi

  extract="$(mktemp -d)"
  tar -xzf "$archive_path" -C "$extract"
  javac_path="$(find "$extract" -type f -path '*/bin/javac' -print -quit)"
  [[ -n "$javac_path" ]] || { echo "javac was not found inside $archive." >&2; return 1; }
  extracted_home="$(cd "$(dirname "$javac_path")/.." && pwd)"
  rm -rf "$portable_home"
  mkdir -p "$portable_home"
  cp -a "$extracted_home/." "$portable_home/"
  rm -rf "$extract"

  valid_jdk_home "$portable_home" || { echo 'Portable Microsoft OpenJDK was extracted but is not usable.' >&2; return 1; }
  echo "Portable Microsoft OpenJDK 17.0.20.1: READY" >&2
  printf '%s\n' "$portable_home"
}

resolve_jdk(){
  local candidate javac_path
  for candidate in "${JDK_HOME:-}" "${JAVA_HOME:-}"; do
    if valid_jdk_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  javac_path="$(command -v javac || true)"
  if [[ -n "$javac_path" ]]; then
    candidate="$(cd "$(dirname "$javac_path")/.." && pwd)"
    if valid_jdk_home "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    # Resolve /usr/bin alternatives/symlinks as well.
    if command -v readlink >/dev/null 2>&1; then
      javac_path="$(readlink -f "$javac_path" 2>/dev/null || printf '%s' "$javac_path")"
      candidate="$(cd "$(dirname "$javac_path")/.." && pwd)"
      if valid_jdk_home "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  fi

  echo 'JDK 17+ with javac/jar/jdeps/jlink was not found; bootstrapping verified Microsoft OpenJDK 17...' >&2
  bootstrap_jdk17
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

install -m 0644 "$TEMPLATES/windows-x64/SynKinectStudio.cmd" "$WINDOWS_APP/SynKinectStudio.cmd"
install -m 0755 "$TEMPLATES/linux-x64/SynKinectStudio.sh" "$LINUX_APP/SynKinectStudio.sh"
install -m 0644 "$TEMPLATES/linux-x64/SynKinectStudio.desktop" "$LINUX_APP/SynKinectStudio.desktop"
install -m 0644 "$SKETCH/data/synkinect-studio-icon.png" "$LINUX_APP/synkinect-studio-icon.png"

JDK_HOME_RESOLVED="$(resolve_jdk)"
JAVAC="$JDK_HOME_RESOLVED/bin/javac"
JAR="$JDK_HOME_RESOLVED/bin/jar"
JDEPS="$JDK_HOME_RESOLVED/bin/jdeps"
JLINK="$JDK_HOME_RESOLVED/bin/jlink"
feature="$(jdk_feature "$JDK_HOME_RESOLVED")"
echo "JDK $feature+: READY [$JDK_HOME_RESOLVED]"

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

linux_hash="$(sha256_file "$LINUX_APP/lib/SynKinectStudio.jar")"
windows_hash="$(sha256_file "$WINDOWS_APP/lib/SynKinectStudio.jar")"
[[ "$linux_hash" == "$windows_hash" ]] || { echo 'Release invariant violated: Windows and Linux Studio JARs differ.' >&2; exit 1; }

# Build the self-contained Linux Java runtime after the final application JAR
# exists. This removes the machine-wide Java requirement from the finished app.
jdeps_output="$("$JDEPS" --multi-release "$feature" --ignore-missing-deps --recursive --print-module-deps --class-path "$LINUX_LIB/*" "$LINUX_LIB/SynKinectStudio.jar" 2>&1)"
modules="$(printf '%s\n' "$jdeps_output" | awk '/^[A-Za-z0-9_.]+(,[A-Za-z0-9_.]+)*$/{line=$0} END{print line}')"
[[ -n "$modules" ]] || { printf '%s\n' "$jdeps_output" >&2; echo 'jdeps did not return the Java module list required by SynKinect Studio.' >&2; exit 1; }

rm -rf "$LINUX_APP/java"
if (( feature >= 21 )); then
  "$JLINK" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages --compress=zip-6 --output "$LINUX_APP/java"
else
  "$JLINK" --add-modules "$modules" --strip-debug --no-header-files --no-man-pages --compress=2 --output "$LINUX_APP/java"
fi

[[ -x "$LINUX_APP/java/bin/java" ]] || chmod 0755 "$LINUX_APP/java/bin/java" 2>/dev/null || true
[[ -x "$LINUX_APP/java/bin/java" ]] || { echo 'Linux Java runtime was generated but java/bin/java is not executable.' >&2; exit 1; }
runtime_version="$("$LINUX_APP/java/bin/java" -version 2>&1 | head -n1)"
echo "Embedded Linux Java runtime: READY ($runtime_version)"
echo "SynKinect Studio 1.0 rebuilt. SHA-256: $linux_hash"
echo "Linux runtime: $LINUX_APP"
