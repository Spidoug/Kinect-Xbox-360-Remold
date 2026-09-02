#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_NAME="Kinect Xbox 360 Remold"
ACTION="Menu"
if [[ "${1:-}" == "--action" ]]; then
  ACTION="${2:-Menu}"
  shift 2 || true
fi

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

caller_user(){
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then id -un; return; fi
  if [[ -n "${REMOLD_CALLER_USER:-}" && "${REMOLD_CALLER_USER}" != root ]]; then printf '%s\n' "$REMOLD_CALLER_USER"; return; fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then printf '%s\n' "$SUDO_USER"; return; fi
  if [[ -n "${PKEXEC_UID:-}" ]] && command -v getent >/dev/null 2>&1; then
    getent passwd "$PKEXEC_UID" | awk -F: '$1!="root"{print $1;exit}'
  fi
}

run_root(){
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$@"
    return
  fi
  local user
  user="$(caller_user)"
  if command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]; then
    sudo env REMOLD_CALLER_USER="$user" "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec env REMOLD_CALLER_USER="$user" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo env REMOLD_CALLER_USER="$user" "$@"
  else
    printf 'Administrator permission is required for this system change; neither sudo nor pkexec is available.\n' >&2
    return 1
  fi
}

find_ctl(){
  local candidates=(
    "/usr/bin/kinect360-remoldctl"
    "$ROOT/dist/$(uname -m)/bin/kinect360-remoldctl"
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
    printf 'kinect360-remoldctl was not found. Install / Reinstall the driver first.\n'
  fi
  printf '\nServices:\n'
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --plain status kinect360-remold.target 2>/dev/null | sed -n '1,12p' || true
  else
    printf 'systemctl is not available on this system.\n'
  fi
}

show_virtual_camera(){
  if [[ -e /dev/video42 ]]; then
    ls -l /dev/video42
  else
    printf '/dev/video42 is not present.\n'
  fi
}

open_camera(){
  show_virtual_camera
  [[ -e /dev/video42 ]] || return 1
  if command -v cheese >/dev/null 2>&1; then nohup cheese --device=/dev/video42 >/dev/null 2>&1 & return 0; fi
  if command -v qv4l2 >/dev/null 2>&1; then nohup qv4l2 -d /dev/video42 >/dev/null 2>&1 & return 0; fi
  if command -v guvcview >/dev/null 2>&1; then nohup guvcview -d /dev/video42 >/dev/null 2>&1 & return 0; fi
  printf 'No desktop camera viewer (Cheese, qv4l2 or guvcview) was found; the virtual device is ready at /dev/video42.\n'
}

set_tilt(){
  local ctl value="${1:-}"
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  if [[ -z "$value" ]]; then
    printf 'Tilt angle in degrees (-27 to 27; 0 is geometric center): '
    IFS= read -r value || return 1
  fi
  [[ "$value" =~ ^-?[0-9]+$ ]] || { printf 'Invalid value.\n'; return 1; }
  (( value < -27 )) && value=-27
  (( value > 27 )) && value=27
  "$ctl" tilt "$value"
}

startup_tilt(){
  local ctl
  ctl="$(find_ctl)" || { printf 'kinect360-remoldctl was not found.\n'; return 1; }
  "$ctl" tilt 0
}

show_ip_status(){
  local cfg=/etc/kinect360-remold/remold.conf
  if [[ -r "$cfg" ]]; then
    grep -E '^(ip\.enabled|ip\.port|ip\.user|ip\.password)=' "$cfg" || true
  else
    printf 'IP camera configuration is protected from ordinary users.\n'
    printf 'Status can still be inspected without elevation:\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    printf 'camera-ip service: '
    systemctl is-active kinect360-remold-camera-ip.service 2>/dev/null || true
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '$4 ~ /:8088$/ {print "listener: "$4}' || true
  fi
}

replace_config_value(){
  local key="$1" value="$2" cfg=/etc/kinect360-remold/remold.conf tmp
  [[ -f "$cfg" ]] || { printf 'IP camera configuration is not installed.\n' >&2; return 1; }
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN{done=0}
    index($0,key"=")==1 {print key"="value;done=1;next}
    {print}
    END{if(!done)print key"="value}
  ' "$cfg" > "$tmp"
  install -o root -g root -m 0640 "$tmp" "$cfg"
  rm -f "$tmp"
}

reset_ip_password_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local pass
  pass="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  replace_config_value ip.password "$pass"
  if systemctl is-active --quiet kinect360-remold-camera-ip.service 2>/dev/null; then
    systemctl restart kinect360-remold-camera-ip.service
  fi
  printf 'IP camera credentials: admin / %s\n' "$pass"
}

ip_toggle_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'root required\n' >&2; return 1; }
  local cfg=/etc/kinect360-remold/remold.conf current=false next=true
  [[ -f "$cfg" ]] || { printf 'IP camera configuration is not installed.\n' >&2; return 1; }
  current="$(awk -F= '$1=="ip.enabled"{gsub(/[[:space:]]/,"",$2);print tolower($2);exit}' "$cfg")"
  [[ "$current" == true || "$current" == 1 ]] && next=false
  replace_config_value ip.enabled "$next"
  if [[ "$next" == true ]]; then
    systemctl restart kinect360-remold-camera-ip.service
    printf 'IP camera enabled.\n'
  else
    systemctl stop kinect360-remold-camera-ip.service 2>/dev/null || true
    printf 'IP camera disabled.\n'
  fi
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
  local studio user uid runtime_dir
  if ! studio="$(find_studio)"; then
    printf 'SynKinect Studio Linux launcher was not found in this distribution.\n' >&2
    printf 'Expected applications/binaries/linux-x64/SynKinectStudio.sh or studio/SynKinectStudio.sh.\n' >&2
    return 1
  fi
  chmod +x "$studio" 2>/dev/null || true
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    user="$(caller_user)"
    [[ -n "$user" && "$user" != root ]] || { printf 'Refusing to start SynKinect Studio as root; launch it from the desktop user session.\n' >&2; return 1; }
    uid="$(id -u "$user")"
    runtime_dir="/run/user/$uid"
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$user" -- env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" "$studio" >/dev/null 2>&1 &
    elif command -v sudo >/dev/null 2>&1; then
      sudo -u "$user" env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-}" XDG_RUNTIME_DIR="$runtime_dir" "$studio" >/dev/null 2>&1 &
    else
      printf 'Cannot drop root privileges because neither runuser nor sudo is available.\n' >&2
      return 1
    fi
  else
    "$studio" >/dev/null 2>&1 &
  fi
  printf 'SynKinect Studio opened as the standard desktop user: %s\n' "$studio"
}

run_action(){
  case "$1" in
    Install) header; printf 'Installation will request administrator permission only for the system changes.\n'; run_root "$ROOT/INSTALL.sh" --direct ;;
    Status) header; show_status ;;
    OpenCamera) header; open_camera ;;
    Tilt) header; set_tilt ;;
    StartupTilt) header; startup_tilt ;;
    IpStatus) header; show_ip_status ;;
    IpReset) header; printf 'Resetting the protected IP-camera password requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-reset ;;
    IpToggle) header; printf 'Changing the IP-camera service requires administrator permission.\n'; run_root bash "$ROOT/KINECT.sh" --root-ip-toggle ;;
    OpenStudio) header; open_studio ;;
    Uninstall) header; printf 'Type REMOVE to confirm: '; IFS= read -r confirm || true; if [[ "$confirm" == REMOVE ]]; then run_root "$ROOT/UNINSTALL.sh"; else printf 'Canceled.\n'; fi ;;
    *) printf 'Unknown action: %s\n' "$1" >&2; return 2 ;;
  esac
}

# Private root-only entry points used after sudo/pkexec. They never launch Studio.
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-reset" ]]; then reset_ip_password_root; exit $?; fi
if [[ "$ACTION" == Menu && "${1:-}" == "--root-ip-toggle" ]]; then ip_toggle_root; exit $?; fi

if [[ "$ACTION" != Menu ]]; then
  run_action "$ACTION"
  exit $?
fi

while true; do
  header
  printf '%s\n' \
    '1  Install / Reinstall' \
    '2  Status' \
    '3  Open / show virtual camera device' \
    '4  Set manual Tilt' \
    '5  Return Tilt to startup pose (0 degrees)' \
    '6  Show IP camera configuration / status' \
    '7  Restart Kinect runtime' \
    '8  Stop / Start Kinect runtime' \
    '9  Uninstall' \
    '10 Open SynKinect Studio (Linux)' \
    '11 Reset IP camera password' \
    '12 Enable / Disable IP camera' \
    '0  Exit'
  printf '\nChoose: '
  IFS= read -r choice || exit 0
  case "${choice//[[:space:]]/}" in
    1) run_action Install || true; pause_menu ;;
    2) run_action Status; pause_menu ;;
    3) run_action OpenCamera || true; pause_menu ;;
    4) run_action Tilt || true; pause_menu ;;
    5) run_action StartupTilt || true; pause_menu ;;
    6) run_action IpStatus; pause_menu ;;
    7) header; run_root systemctl restart kinect360-remold.target || true; show_status; pause_menu ;;
    8) header; if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet kinect360-remold.target; then run_root systemctl stop kinect360-remold.target || true; else run_root systemctl start kinect360-remold.target || true; fi; pause_menu ;;
    9) run_action Uninstall || true; pause_menu ;;
    10) run_action OpenStudio || true; sleep 0.5 ;;
    11) run_action IpReset || true; pause_menu ;;
    12) run_action IpToggle || true; pause_menu ;;
    0) exit 0 ;;
    *) printf 'Invalid option.\n'; sleep 0.7 ;;
  esac
done
