#!/usr/bin/env bash
# uninstall.sh
# Detect and remove a2dp2fm (Bluetooth) and/or airplay2fm (AirPlay) installations
# Usage: sudo bash uninstall.sh [--bt] [--airplay] [--all] [--yes]

set -euo pipefail

TARGET=""   # bt | airplay | all  (empty = interactive)
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bt)      TARGET="bt";      shift;;
    --airplay) TARGET="airplay"; shift;;
    --all)     TARGET="all";     shift;;
    --yes|-y)  YES=1;            shift;;
    --help|-h)
      cat <<'USAGE'
Usage: sudo bash uninstall.sh [--bt] [--airplay] [--all] [--yes]

  --bt        Remove Bluetooth A2DP -> FM install only
  --airplay   Remove AirPlay -> FM install only
  --all       Remove both installs
  --yes, -y   Skip confirmation prompt

  With no flags: interactive menu showing what is installed
USAGE
      exit 0;;
    *) echo "Unknown option: $1  (try --help)"; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root: sudo bash $0"
  exit 1
fi

# ---- Helpers ----
sep()  { printf '%0.s─' {1..60}; echo; }
hdr()  { echo; echo "  $*"; }
item() { printf '    %-36s %s\n' "$1" "$2"; }

cfg_get() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" 2>/dev/null | head -1 | sed "s/^${key}=//;s/^['\"]//;s/['\"]$//"
}

svc_state() {
  local s="$1"
  if ! systemctl list-unit-files "$s" 2>/dev/null | grep -q "^$s"; then
    echo "not installed"
  elif systemctl is-active --quiet "$s" 2>/dev/null; then
    echo "active"
  else
    echo "inactive"
  fi
}

file_state() { [[ -e "$1" ]] && echo "found" || echo "absent"; }

# ---- Detection ----
BT_FOUND=0
AP_FOUND=0

BT_PI_USER="pi"
BT_PI_HOME="/home/pi"
AP_PI_USER="pi"
AP_PI_HOME="/home/pi"

detect_bt() {
  [[ -f /etc/default/bt2fm || -f /usr/local/bin/bt2fm.sh ]] || return 0
  BT_FOUND=1
  if [[ -f /etc/default/bt2fm ]]; then
    local u; u="$(cfg_get /etc/default/bt2fm PI_USER)"
    [[ -n "$u" ]] && BT_PI_USER="$u"
    local h; h="$(cfg_get /etc/default/bt2fm PI_HOME)"
    [[ -n "$h" ]] && BT_PI_HOME="$h" || BT_PI_HOME="/home/$BT_PI_USER"
  fi
}

detect_airplay() {
  [[ -f /etc/default/airplay2fm || -f /usr/local/bin/airplay2fm.sh ]] || return 0
  AP_FOUND=1
  if [[ -f /etc/default/airplay2fm ]]; then
    local u; u="$(cfg_get /etc/default/airplay2fm PI_USER)"
    [[ -n "$u" ]] && AP_PI_USER="$u"
    local h; h="$(cfg_get /etc/default/airplay2fm PI_HOME)"
    [[ -n "$h" ]] && AP_PI_HOME="$h" || AP_PI_HOME="/home/$AP_PI_USER"
  fi
}

detect_bt
detect_airplay

# ---- Status display ----
show_status() {
  echo
  sep
  printf '  %-30s\n' "A2DP2FM Uninstaller — system scan"
  sep

  # ---- Bluetooth ----
  hdr "Bluetooth A2DP -> FM  (a2dp2fm)"
  if (( BT_FOUND )); then
    item "Status:" "INSTALLED"
    item "Config:" "$(file_state /etc/default/bt2fm)  /etc/default/bt2fm"
    item "bt2fm.sh:" "$(file_state /usr/local/bin/bt2fm.sh)"
    item "bt2fm.service:" "$(svc_state bt2fm.service)"
    item "bt-volume-freqd.service:" "$(svc_state bt-volume-freqd.service)"
    item "avrcp-rds.service:" "$(svc_state avrcp-rds.service)"
    item "led-statusd.service:" "$(svc_state led-statusd.service)"
    item "bluealsa.service:" "$(svc_state bluealsa.service)"
    item "BlueALSA source:" "$(file_state /usr/local/src/bluez-alsa)"
    if [[ -f /etc/default/bt2fm ]]; then
      local f; f="$(cfg_get /etc/default/bt2fm FREQ)"
      [[ -n "$f" ]] && item "Frequency:" "${f} MHz"
    fi
  else
    item "Status:" "not installed"
  fi

  echo
  sep

  # ---- AirPlay ----
  hdr "AirPlay -> FM  (airplay2fm)"
  if (( AP_FOUND )); then
    item "Status:" "INSTALLED"
    item "Config:" "$(file_state /etc/default/airplay2fm)  /etc/default/airplay2fm"
    item "airplay2fm.sh:" "$(file_state /usr/local/bin/airplay2fm.sh)"
    item "airplay2fm.service:" "$(svc_state airplay2fm.service)"
    item "airplay-rds.service:" "$(svc_state airplay-rds.service)"
    item "led-airplay-statusd.service:" "$(svc_state led-airplay-statusd.service)"
    item "shairport-sync.service:" "$(svc_state shairport-sync.service)"
    item "tmpfiles.d entry:" "$(file_state /etc/tmpfiles.d/airplay2fm.conf)"
    item "shairport-sync source:" "$(file_state /usr/local/src/shairport-sync)"
    if [[ -f /etc/default/airplay2fm ]]; then
      local f; f="$(cfg_get /etc/default/airplay2fm FREQ)"
      local n; n="$(cfg_get /etc/default/airplay2fm AP_NAME)"
      [[ -n "$f" ]] && item "Frequency:" "${f} MHz"
      [[ -n "$n" ]] && item "AirPlay name:" "$n"
    fi
  else
    item "Status:" "not installed"
  fi

  echo
  sep

  # ---- Shared resources ----
  hdr "Shared resources"
  local pifm_user="${BT_PI_USER:-${AP_PI_USER:-pi}}"
  local pifm_home="${BT_PI_HOME:-${AP_PI_HOME:-/home/pi}}"
  item "PiFmRds:" "$(file_state "${pifm_home}/PiFmRds")"
  item "ledctl.sh:" "$(file_state /usr/local/bin/ledctl.sh)"
  item "ACT LED config:" "$(grep -l 'act_led_trigger=none' /boot/config.txt /boot/firmware/config.txt 2>/dev/null | head -1 | xargs -I{} echo 'set in {}' || echo 'not set')"
  echo
  sep
  echo
}

show_status

# ---- Interactive menu (if no --flag given) ----
if [[ -z "$TARGET" ]]; then
  if (( ! BT_FOUND && ! AP_FOUND )); then
    echo "  Nothing to uninstall — no installations detected."
    echo
    exit 0
  fi

  echo "  What would you like to remove?"
  echo

  opt=0
  declare -A OPT_MAP

  if (( BT_FOUND )); then
    (( opt++ ))
    OPT_MAP[$opt]="bt"
    printf '  %d) Uninstall Bluetooth A2DP -> FM  (a2dp2fm)\n' "$opt"
  fi
  if (( AP_FOUND )); then
    (( opt++ ))
    OPT_MAP[$opt]="airplay"
    printf '  %d) Uninstall AirPlay -> FM  (airplay2fm)\n' "$opt"
  fi
  if (( BT_FOUND && AP_FOUND )); then
    (( opt++ ))
    OPT_MAP[$opt]="all"
    printf '  %d) Uninstall both\n' "$opt"
  fi
  echo "  q) Quit"
  echo

  while true; do
    read -r -p "  Choice: " choice
    case "$choice" in
      q|Q) echo; echo "  Cancelled."; echo; exit 0;;
      *)
        if [[ -n "${OPT_MAP[$choice]+x}" ]]; then
          TARGET="${OPT_MAP[$choice]}"
          break
        fi
        echo "  Invalid choice — enter a number or 'q'."
        ;;
    esac
  done
  echo
fi

# ---- Validate target against what's installed ----
case "$TARGET" in
  bt)
    if (( ! BT_FOUND )); then
      echo "  Bluetooth install not detected — nothing to remove."; echo; exit 0
    fi;;
  airplay)
    if (( ! AP_FOUND )); then
      echo "  AirPlay install not detected — nothing to remove."; echo; exit 0
    fi;;
  all)
    if (( ! BT_FOUND && ! AP_FOUND )); then
      echo "  Nothing to uninstall — no installations detected."; echo; exit 0
    fi;;
esac

# ---- Preview what will be removed ----
echo
sep
echo "  Will be removed:"
echo

REMOVE_BT=0
REMOVE_AP=0
[[ "$TARGET" == "bt"  || "$TARGET" == "all" ]] && REMOVE_BT=1
[[ "$TARGET" == "airplay" || "$TARGET" == "all" ]] && REMOVE_AP=1

# Whether shared resources should go (only when removing all, or removing the only install)
REMOVE_SHARED=0
if (( REMOVE_BT && REMOVE_AP )); then
  REMOVE_SHARED=1
elif (( REMOVE_BT && ! AP_FOUND )); then
  REMOVE_SHARED=1
elif (( REMOVE_AP && ! BT_FOUND )); then
  REMOVE_SHARED=1
fi

if (( REMOVE_BT && BT_FOUND )); then
  echo "  Bluetooth (a2dp2fm):"
  echo "    Services:  bt2fm  bt-volume-freqd  avrcp-rds  led-statusd  bt-agent  bt-setup  bluealsa"
  echo "    Scripts:   bt2fm.sh  fm_announce.sh  bt-volume-freqd.sh  avrcp_rds.py  led-statusd.sh"
  echo "    Sbins:     bt-agent-wrapper.sh  bt-setup-bluetooth.sh"
  echo "    Config:    /etc/default/bt2fm"
  echo "    Runstate:  /run/bt2fm.volume  /run/bt2fm.playstate  /run/fm_announce.wav"
  echo "    Source:    /usr/local/src/bluez-alsa"
  echo
fi

if (( REMOVE_AP && AP_FOUND )); then
  echo "  AirPlay (airplay2fm):"
  echo "    Services:  airplay2fm  airplay-rds  led-airplay-statusd"
  if [[ -f /etc/systemd/system/shairport-sync.service ]] && \
     grep -q 'Managed by airplay2fm' /etc/systemd/system/shairport-sync.service 2>/dev/null; then
    echo "               shairport-sync  (unit written by airplay2fm)"
  fi
  echo "    Scripts:   airplay2fm.sh  airplay-rds.py  led-airplay-statusd.sh"
  echo "    Config:    /etc/default/airplay2fm  /etc/tmpfiles.d/airplay2fm.conf"
  echo "    FIFOs:     /run/airplay_audio  /run/airplay_metadata"
  echo "    Module:    snd-aloop removed from /etc/modules"
  echo "    Source:    /usr/local/src/shairport-sync"
  echo
fi

if (( REMOVE_SHARED )); then
  echo "  Shared resources (removing all installs):"
  echo "    ledctl.sh  PiFmRds directory  ACT LED dtparam config  /run/rds_ctl"
  echo "    Wait-for-network re-enabled"
else
  echo "  Shared resources (kept — another install still uses them):"
  echo "    ledctl.sh  PiFmRds  /run/rds_ctl  ACT LED dtparam config"
fi
echo

# ---- Confirm ----
if (( ! YES )); then
  sep
  read -r -p "  Proceed with uninstall? [y/N] " confirm
  echo
  case "$confirm" in
    y|Y) ;;
    *) echo "  Cancelled."; echo; exit 0;;
  esac
fi

# ---- Removal functions ----
log() { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
removed=()

stop_and_remove_unit() {
  local svc="$1" marker="${2:-}"
  systemctl disable --now "$svc" 2>/dev/null || true
  local path="/etc/systemd/system/$svc"
  if [[ -f "$path" ]]; then
    if [[ -z "$marker" ]] || grep -q "$marker" "$path" 2>/dev/null; then
      rm -f "$path"
      removed+=("unit: $svc")
    fi
  fi
}

rm_file() {
  local f="$1"
  if [[ -e "$f" ]]; then
    rm -f "$f"
    removed+=("file: $f")
  fi
}

do_uninstall_bt() {
  log "Removing Bluetooth A2DP -> FM (a2dp2fm)"

  local bt_pi_user="${BT_PI_USER:-pi}"
  local bt_pi_home="${BT_PI_HOME:-/home/pi}"

  for svc in bt2fm.service bt-volume-freqd.service avrcp-rds.service \
             led-statusd.service bt-agent.service bt-setup.service; do
    stop_and_remove_unit "$svc" "Managed by a2dp2fm"
  done
  stop_and_remove_unit "bluealsa.service" "Managed by a2dp2fm"
  systemctl daemon-reload 2>/dev/null || true

  for f in \
    /usr/local/bin/bt2fm.sh \
    /usr/local/bin/bt-volume-freqd.sh \
    /usr/local/bin/avrcp_rds.py \
    /usr/local/bin/led-statusd.sh \
    /usr/local/sbin/bt-agent-wrapper.sh \
    /usr/local/sbin/bt-setup-bluetooth.sh \
    /etc/default/bt2fm \
    /run/bt2fm.volume \
    /run/bt2fm.playstate \
    /run/fm_announce.wav; do
    rm_file "$f"
  done

  # fm_announce.sh and ledctl.sh: only remove if not needed by AirPlay
  if (( REMOVE_SHARED )); then
    rm_file /usr/local/bin/fm_announce.sh
  fi

  if [[ -d /usr/local/src/bluez-alsa ]]; then
    rm -rf /usr/local/src/bluez-alsa
    removed+=("dir: /usr/local/src/bluez-alsa")
  fi

  log "Bluetooth uninstall done"
}

do_uninstall_airplay() {
  log "Removing AirPlay -> FM (airplay2fm)"

  for svc in airplay2fm.service airplay-rds.service led-airplay-statusd.service; do
    stop_and_remove_unit "$svc" "Managed by airplay2fm"
  done
  stop_and_remove_unit "shairport-sync.service" "Managed by airplay2fm"
  systemctl daemon-reload 2>/dev/null || true

  for f in \
    /usr/local/bin/airplay2fm.sh \
    /usr/local/bin/airplay-rds.py \
    /usr/local/bin/led-airplay-statusd.sh \
    /etc/default/airplay2fm \
    /etc/tmpfiles.d/airplay2fm.conf \
    /run/airplay_audio \
    /run/airplay_metadata; do
    rm_file "$f"
  done

  if grep -q '^snd-aloop$' /etc/modules 2>/dev/null; then
    sed -i '/^snd-aloop$/d' /etc/modules || true
    removed+=("module: snd-aloop removed from /etc/modules")
  fi

  if [[ -d /usr/local/src/shairport-sync ]]; then
    rm -rf /usr/local/src/shairport-sync
    removed+=("dir: /usr/local/src/shairport-sync")
  fi

  log "AirPlay uninstall done"
}

do_remove_shared() {
  log "Removing shared resources"

  local pifm_user="${BT_PI_USER:-${AP_PI_USER:-pi}}"
  local pifm_home="${BT_PI_HOME:-${AP_PI_HOME:-/home/pi}}"
  local pifm_dir="${pifm_home}/PiFmRds"

  rm_file /usr/local/bin/ledctl.sh
  rm_file /run/rds_ctl

  if [[ -d "$pifm_dir" ]]; then
    local origin=""
    origin="$(sudo -u "$pifm_user" git -C "$pifm_dir" remote get-url origin 2>/dev/null || true)"
    if [[ "$origin" == "https://github.com/ChristopheJacquet/PiFmRds.git" || -z "$origin" ]]; then
      rm -rf "$pifm_dir"
      removed+=("dir: $pifm_dir")
    else
      log "Warning: PiFmRds at $pifm_dir has unexpected remote '$origin' — skipping removal"
    fi
  fi

  local cfg
  for cfg in /boot/config.txt /boot/firmware/config.txt; do
    [[ -f "$cfg" ]] || continue
    sed -i.bak '/^dtparam=act_led_trigger=none$/d' "$cfg" || true
    sed -i.bak '/^dtparam=act_led_activelow=off$/d' "$cfg" || true
    rm -f "${cfg}.bak" || true
    removed+=("LED dtparam removed from $cfg")
  done

  # Restore wait-for-network (was masked by installer)
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_boot_wait 1 2>/dev/null || true
    removed+=("wait-for-network restored via raspi-config")
  else
    for unit in \
      systemd-networkd-wait-online.service \
      NetworkManager-wait-online.service \
      dhcpcd-wait-online.service; do
      systemctl unmask "$unit" 2>/dev/null || true
      systemctl enable "$unit" 2>/dev/null || true
    done
    removed+=("wait-for-network units unmasked")
  fi

  log "Shared resource removal done"
}

# ---- Execute ----
echo
(( REMOVE_BT && BT_FOUND ))  && do_uninstall_bt
(( REMOVE_AP && AP_FOUND ))  && do_uninstall_airplay
(( REMOVE_SHARED ))          && do_remove_shared

# ---- Summary ----
echo
sep
echo "  Uninstall complete."
echo
if (( ${#removed[@]} )); then
  echo "  Removed:"
  for item in "${removed[@]}"; do
    printf '    - %s\n' "$item"
  done
fi
echo
if (( REMOVE_SHARED )); then
  echo "  Note: A reboot is recommended to clear LED dtparam changes."
else
  echo "  Note: Shared resources (PiFmRds, ledctl.sh) were kept for the remaining install."
fi
echo
sep
echo
