#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_NAME="Kinect Xbox 360 Remold"

pause_menu(){
  printf '\nPress Enter to continue'
  IFS= read -r _ || true
}

header(){
  command -v clear >/dev/null 2>&1 && clear || true
  printf '%s\n' '============================================================'
  printf ' %s - Linux control panel\n' "$PRODUCT_NAME"
  printf '%s\n' '============================================================'
}

run_root(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    printf 'Administrator permission is required and sudo was not found.\n' >&2
    return 1
  fi
}

find_ctl(){
  local candidates=(
    "/usr/bin/kinect360-remoldctl"
    "$ROOT/binaries/$(uname -m)/bin/kinect360-remoldctl"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

show_status(){
  local ctl
  if ctl="$(find_ctl)"; then
    "$ctl" status || true
  else
    printf 'kinect360-remoldctl was not found. Install / Repair the driver first.\n'
  fi
  printf '\nServices:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --plain status kinect360-remold.target 2>/dev/null | sed -n '1,12p' || true
  else
    printf 'systemctl is not available on this system.\n'
  fi
}

set_tilt(){
  local ctl value
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  printf 'Tilt angle in degrees (-27 to 27; 0 is geometric center): '
  IFS= read -r value || return 1
  [[ "$value" =~ ^-?[0-9]+$ ]] || { printf 'Invalid value.\n'; return 1; }
  (( value < -27 )) && value=-27
  (( value > 27 )) && value=27
  "$ctl" tilt "$value"
}

find_studio(){
  local candidates=(
    "$ROOT/studio/SynKinectStudio.sh"
    "$ROOT/../../applications/binaries/linux-x64/SynKinectStudio.sh"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd)" "$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

open_studio(){
  local studio
  if ! studio="$(find_studio)"; then
    printf 'SynKinect Studio Linux launcher was not found in this distribution.\n' >&2
    printf 'Expected applications/binaries/linux-x64/SynKinectStudio.sh or studio/SynKinectStudio.sh.\n' >&2
    return 1
  fi
  chmod +x "$studio" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && command -v sudo >/dev/null 2>&1; then
    local env_args=(env "DISPLAY=${DISPLAY:-:0}")
    [[ -n "${XAUTHORITY:-}" ]] && env_args+=("XAUTHORITY=$XAUTHORITY")
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] && env_args+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
    sudo -u "$SUDO_USER" "${env_args[@]}" "$studio" >/dev/null 2>&1 &
  else
    "$studio" >/dev/null 2>&1 &
  fi
  printf 'SynKinect Studio opened: %s\n' "$studio"
}

while true; do
  header
  printf '%s\n' \
    '1  Install / Repair' \
    '2  Status' \
    '3  Show virtual camera device' \
    '4  Set manual Tilt' \
    '5  Return Tilt to startup pose (0 degrees)' \
    '6  Show IP camera configuration' \
    '7  Restart Kinect runtime' \
    '8  Stop / Start Kinect runtime' \
    '9  Uninstall' \
    '10 Open SynKinect Studio (Linux)' \
    '0  Exit'
  printf '\nChoose: '
  IFS= read -r choice || exit 0
  case "${choice//[[:space:]]/}" in
    1) header; run_root "$ROOT/INSTALL.sh" --direct || true; pause_menu ;;
    2) header; show_status; pause_menu ;;
    3) header; if [[ -e /dev/video42 ]]; then ls -l /dev/video42; else printf '/dev/video42 is not present.\n'; fi; pause_menu ;;
    4) header; set_tilt || true; pause_menu ;;
    5) header; ctl="$(find_ctl 2>/dev/null || true)"; if [[ -n "$ctl" ]]; then "$ctl" tilt 0 || true; else printf 'kinect360-remoldctl was not found.\n'; fi; pause_menu ;;
    6) header; if [[ -r /etc/kinect360-remold/remold.conf ]]; then grep -E '^(ip\.|camera\.)' /etc/kinect360-remold/remold.conf || true; else printf 'IP camera configuration is not installed or requires administrator permission.\n'; fi; pause_menu ;;
    7) header; run_root systemctl restart kinect360-remold.target || true; show_status; pause_menu ;;
    8) header; if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet kinect360-remold.target; then run_root systemctl stop kinect360-remold.target || true; else run_root systemctl start kinect360-remold.target || true; fi; pause_menu ;;
    9) header; printf 'Type REMOVE to confirm: '; IFS= read -r confirm || true; if [[ "$confirm" == 'REMOVE' ]]; then run_root "$ROOT/UNINSTALL.sh" || true; else printf 'Canceled.\n'; fi; pause_menu ;;
    10) header; open_studio || true; sleep 0.5 ;;
    0) exit 0 ;;
    *) printf 'Invalid option.\n'; sleep 0.7 ;;
  esac
done
