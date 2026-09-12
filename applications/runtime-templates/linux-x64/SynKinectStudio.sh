#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -x "$0" ]] || chmod u+x "$0" 2>/dev/null || true

# Studio is a desktop/user-space application. Never let sudo/pkexec/root own its
# preferences, recordings or Java process. Administrative work is delegated to
# KINECT.sh only for explicit system-changing actions.
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  target_user="${REMOLD_CALLER_USER:-${SUDO_USER:-}}"
  if [[ -z "$target_user" && -n "${PKEXEC_UID:-}" ]] && command -v getent >/dev/null 2>&1; then
    target_user="$(getent passwd "$PKEXEC_UID" | awk -F: '$1!="root"{print $1;exit}')"
  fi
  if [[ -z "$target_user" || "$target_user" == root ]]; then
    echo 'SynKinect Studio refuses to run as root. Start it from the normal desktop user session.' >&2
    exit 1
  fi
  uid="$(id -u "$target_user")"
  runtime_dir="/run/user/$uid"
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$target_user" -- env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" bash "$0" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    exec sudo -u "$target_user" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" bash "$0" "$@"
  else
    echo 'Cannot drop root privileges because neither runuser nor sudo is available.' >&2
    exit 1
  fi
fi

cd "$HERE"
[[ -f "$HERE/lib/SynKinectStudio.jar" ]] || { echo "SynKinectStudio.jar is missing from $HERE/lib." >&2; exit 1; }

JAVA="$HERE/java/bin/java"
if [[ -d "$HERE/java" ]]; then
  # Some ZIP/extraction tools discard Unix mode bits. Repair the small set of
  # executable files produced by jlink before deciding the embedded runtime is
  # unusable.
  chmod u+x "$HERE"/java/bin/* "$HERE/java/lib/jspawnhelper" "$HERE/java/lib/jexec" 2>/dev/null || true
fi
if [[ ! -x "$JAVA" ]]; then
  JAVA="$(command -v java || true)"
fi
[[ -n "$JAVA" ]] || {
  echo 'Java 17+ was not found. Rebuild the Studio with: bash scripts/linux/BUILD-STUDIO.sh' >&2
  exit 1
}

version="$("$JAVA" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
feature="${version%%.*}"
if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
[[ "$feature" =~ ^[0-9]+$ && "$feature" -ge 17 ]] || {
  echo "Java 17 or newer is required; found: ${version:-unknown}." >&2
  exit 1
}

exec "$JAVA" -Dfile.encoding=UTF-8 -cp "$HERE/lib/SynKinectStudio.jar:$HERE/lib/*" SynKinectStudio "$@"
