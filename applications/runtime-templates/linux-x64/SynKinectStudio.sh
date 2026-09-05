#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Studio is a desktop/user-space application. Never let sudo/pkexec/root own its
# preferences, recordings or Java process. Administrative work is delegated to
# KINECT.sh only when the user explicitly chooses a system-changing action.
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
    exec runuser -u "$target_user" -- env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" "$0" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    exec sudo -u "$target_user" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" "$0" "$@"
  else
    echo 'Cannot drop root privileges because neither runuser nor sudo is available.' >&2
    exit 1
  fi
fi

cd "$HERE"
JAVA="$HERE/java/bin/java"
if [[ ! -x "$JAVA" ]]; then JAVA="$(command -v java || true)"; fi
[[ -n "$JAVA" ]] || { echo 'Java 17 or newer was not found.' >&2; exit 1; }
version="$($JAVA -version 2>&1 | awk -F'"' '/version/ {print $2; exit}')"
feature="${version%%.*}"
if [[ "$feature" == 1 ]]; then feature="$(cut -d. -f2 <<<"$version")"; fi
[[ "$feature" =~ ^[0-9]+$ && "$feature" -ge 17 ]] || {
  echo "Java 17 or newer is required; found: ${version:-unknown}." >&2
  exit 1
}
exec "$JAVA" -Dfile.encoding=UTF-8 -cp "$HERE/lib/SynKinectStudio.jar:$HERE/lib/*" SynKinectStudio "$@"
