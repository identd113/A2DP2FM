#!/usr/bin/env bash
# airplay2fm.sh
# Headless AirPlay (RAOP) -> PiFmRds (FM on GPIO4) + RDS metadata + LED status
# Uses shairport-sync as the AirPlay 1 receiver with pipe audio output
# Tags: raspberry-pi, airplay, raop, fm-transmitter, rds, pi-fm-rds, shairport-sync, systemd, tts
# Usage: sudo bash airplay2fm.sh [--freq 87.9] [--name "Pi FM Radio"] [--step 0.2] [--min 87.7] [--max 107.9]

set -euo pipefail

FREQ="87.9"; STEP="0.2"; FMIN="87.7"; FMAX="107.9"; AP_NAME="Pi FM Radio"
UNINSTALL=0; DRY_RUN=0; VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift;;
    --freq)    FREQ="$2"; shift 2;;
    --step)    STEP="$2"; shift 2;;
    --min)     FMIN="$2"; shift 2;;
    --max)     FMAX="$2"; shift 2;;
    --name)    AP_NAME="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --verbose) VERBOSE=1; shift;;
    *) echo "Usage: sudo bash $0 [--freq 87.9] [--name 'Pi FM Radio'] [--step 0.2] [--min 87.7] [--max 107.9] [--dry-run] [--verbose] [--uninstall]"; exit 1;;
  esac
done

log()          { echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
vlog()         { (( VERBOSE )) && echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] [verbose] $*" || true; }
finalize_script() { local p="$1"; chmod +x "$p"; chown "${PI_USER}:${PI_USER}" "$p" || true; vlog "Installed $p"; }

if [[ $EUID -ne 0 ]]; then
  log "ERROR: Run as root: sudo bash $0"
  exit 1
fi

# ---- Path constants ----
BIN_DIR="/usr/local/bin"
SYSUNIT_DIR="/etc/systemd/system"
AIRPLAY_AUDIO_PIPE="/run/airplay_audio"
AIRPLAY_META_PIPE="/run/airplay_metadata"
RDSCTL="/run/rds_ctl"
CFG_C1="/boot/config.txt"; CFG_C2="/boot/firmware/config.txt"
SHAIRPORT_SRC_DIR="/usr/local/src/shairport-sync"
SHAIRPORT_REPO="https://github.com/mikebrady/shairport-sync.git"

declare -a INSTALL_SUMMARY=()

# ---- OS detection ----
OS_CODENAME=""
if [[ -r /etc/os-release ]]; then
  OS_CODENAME="$(awk -F= '/^VERSION_CODENAME=/{print tolower($2)}' /etc/os-release)"
fi
if [[ -n "$OS_CODENAME" ]]; then
  case "$OS_CODENAME" in
    trixie|bookworm|bullseye|buster)
      log "Detected Raspberry Pi OS/Debian codename: $OS_CODENAME" ;;
    *)
      log "Warning: Unverified OS codename ($OS_CODENAME). Script tested on Raspberry Pi OS Trixie/Bookworm/Bullseye." >&2 ;;
  esac
else
  log "Warning: Unable to detect OS codename; continuing with defaults." >&2
fi

PI_USER="${SUDO_USER:-pi}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6 2>/dev/null || true)"
[[ -z "${PI_HOME:-}" ]] && PI_HOME="/home/$PI_USER"
GIT_CLONE_CMD="${A2DP2FM_GIT_CLONE_CMD:-git}"
PIFM_DIR="$PI_HOME/PiFmRds"

validate_mhz() {
  local name="$1" val="$2"
  [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log "ERROR: $name must be a number (got: $val)"; exit 1; }
}

check_required_commands() {
  local missing=() cmd
  for cmd in git make gcc awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    log "ERROR: Missing required commands: ${missing[*]}" >&2
    log "Install them first (e.g. apt-get install build-essential git)" >&2
    exit 1
  fi
  vlog "Pre-flight check passed"
}

# ---- Board detection & antenna pin-out art ----
PI_BOARD="generic"
PI_MODEL_STRING=""

detect_pi_board() {
  PI_MODEL_STRING="${A2DP2FM_PI_MODEL:-}"
  if [[ -z "$PI_MODEL_STRING" && -r /proc/device-tree/model ]]; then
    PI_MODEL_STRING="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  fi
  case "$PI_MODEL_STRING" in
    *"Pi 400"*|*"Pi 500"*)               PI_BOARD="pi400";;
    *Zero*)                              PI_BOARD="zero";;
    *"Pi 2"*|*"Pi 3"*|*"Pi 4"*|*"Pi 5"*) PI_BOARD="fullsize";;
    *)                                   PI_BOARD="generic";;
  esac
}

show_board_art() {
  # Highlight the antenna pin in bold red on interactive terminals only;
  # piped/logged output gets the plain '#' marker with no escape codes.
  local HL="" RST=""
  if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
    HL=$'\033[1;31m'; RST=$'\033[0m'
  fi
  if [[ -n "$PI_MODEL_STRING" ]]; then
    log "Detected board: $PI_MODEL_STRING (layout: $PI_BOARD)"
  else
    log "Board model not detected; showing generic header (layout: generic)"
  fi
  case "$PI_BOARD" in
    fullsize) cat <<EOF

   Board viewed from above, GPIO header along the top edge:
   ┌──────────────────────────────────────────────────────────┐
   │  2› o o o o o o o o o o o o o o o o o o o o ‹40          │
   │  1› o o o ${HL}#${RST} o o o o o o o o o o o o o o o o ‹39          │
   │           │                                              │
   │           └── ${HL}PIN 7 (GPIO4): antenna wire here${RST}           │
   │                                                    ┌─────┤
   │ ‹SD card                                           │ USB │
   │  (underside,                                       │ USB │
   │   this end)                  ┌──────┐              ├─────┤
   │                              │ SoC  │              │ USB │
   │ [DISPLAY]                    └──────┘              │ USB │
   │                                                    ├─────┤
   │                                  [CAMERA]          │ ETH │
   │                                                    └─────┤
   │     [PWR]      [HDMI]      [A/V]                         │
   └──────────────────────────────────────────────────────────┘
EOF
      ;;
    zero) cat <<EOF

   Board viewed from above, GPIO header along the top edge:
   ┌────────────────────────────────────────────────────┐
   │ 2› o o o o o o o o o o o o o o o o o o o o ‹40     │
   │ 1› o o o ${HL}#${RST} o o o o o o o o o o o o o o o o ‹39     │
   │          │                                         │
   │          └── ${HL}PIN 7 (GPIO4): antenna wire here${RST}      │
   │ ‹SD card                                     [CAM] │
   │      [mini-HDMI]      [USB]  [PWR]                 │
   └────────────────────────────────────────────────────┘
EOF
      ;;
    pi400) cat <<EOF

   Rear panel, viewed from behind the keyboard:
   ┌──────────────────────────────────────────────────────────┐
   │ 39› o o o o o o o o o o o o o o o o ${HL}#${RST} o o o ‹1           │
   │ 40› o o o o o o o o o o o o o o o o o o o o ‹2           │
   │                                     │                    │
   │     ${HL}PIN 7 (GPIO4): antenna wire${RST} ────┘                    │
   │ [GPIO header] [SD] [HDMI][HDMI] [USB-C] [USB][USB] [ETH] │
   └──────────────────────────────────────────────────────────┘
   Note: the Pi 400/500 header is mirrored vs. a regular Pi --
   pin 1 is in the TOP row at the RIGHT end (nearest the SD slot).
EOF
      ;;
    *) cat <<EOF

   Generic 40-pin header (pin 1 is nearest the SD-card end):
      3V3  (1)  (2)  5V
    GPIO2  (3)  (4)  5V
    GPIO3  (5)  (6)  GND
    GPIO4 ${HL}›(7)‹${RST} (8)  GPIO14   ◀── ${HL}PIN 7 (GPIO4): antenna wire here${RST}
      GND  (9) (10)  GPIO15
           ... continues to (40)
EOF
      ;;
  esac
  cat <<EOF

   Antenna wire: insulated solid-core hookup wire (20-24 AWG) or a
   female-ended jumper (Dupont) wire pushed straight onto the pin --
   no soldering required. Length: 10-20 cm for room-level range
   (recommended, keeps the signal polite); ~75 cm (quarter-wave)
   maximizes range where legal. Run the wire vertically, away from
   the board, and make sure it touches no other pin. A second wire
   on any GND pin is optional but can improve signal quality.

EOF
}

check_fm_hardware_support() {
  # PiFmRds drives the FM signal through the SoC clock generator (GPCLK0)
  # via /dev/mem DMA. On the Pi 5/500 GPIO sits behind the RP1 I/O chip,
  # so this method cannot work. Upstream supports Pi 1-4, Zero, Zero 2.
  detect_pi_board
  case "$PI_MODEL_STRING" in
    *"Pi 5"*)  # also matches "Pi 500"
      log "ERROR: $PI_MODEL_STRING is not supported by PiFmRds." >&2
      log "FM transmission uses the SoC clock generator on GPIO4; on the" >&2
      log "Pi 5/500, GPIO is routed through the RP1 chip and this cannot work." >&2
      log "Supported boards: Pi 1-4, Zero, Zero W, Zero 2 W, Pi 400." >&2
      if [[ "${A2DP2FM_FORCE_INSTALL:-0}" == "1" ]]; then
        log "A2DP2FM_FORCE_INSTALL=1 set; continuing despite unsupported board" >&2
      else
        log "(Set A2DP2FM_FORCE_INSTALL=1 to install anyway.)" >&2
        exit 1
      fi
      ;;
  esac
}

perform_uninstall() {
  log "Uninstalling AirPlay -> FM setup"
  local services=(airplay2fm.service airplay-rds.service led-airplay-statusd.service)
  for svc in "${services[@]}"; do
    systemctl disable --now "$svc" 2>/dev/null || true
  done

  local unit_path
  for svc in "${services[@]}"; do
    unit_path="$SYSUNIT_DIR/$svc"
    if [[ -f "$unit_path" ]] && grep -q 'Managed by airplay2fm' "$unit_path"; then
      rm -f "$unit_path"
    fi
  done

  # Only remove shairport-sync unit if we wrote it
  unit_path="$SYSUNIT_DIR/shairport-sync.service"
  if [[ -f "$unit_path" ]] && grep -q 'Managed by airplay2fm' "$unit_path"; then
    systemctl disable --now shairport-sync.service 2>/dev/null || true
    rm -f "$unit_path"
  fi
  systemctl daemon-reload 2>/dev/null || true

  for path in \
    "$BIN_DIR/airplay2fm.sh" \
    "$BIN_DIR/airplay-rds.py" \
    "$BIN_DIR/airplay_announce.sh" \
    "$BIN_DIR/led-airplay-statusd.sh" \
    /etc/default/airplay2fm \
    /etc/tmpfiles.d/airplay2fm.conf \
    /etc/shairport-sync.conf.airplay2fm.bak \
    /run/airplay_announce.wav \
    "$AIRPLAY_AUDIO_PIPE" \
    "$AIRPLAY_META_PIPE" \
    "$RDSCTL"; do
    rm -f "$path"
  done

  if grep -q '^snd-aloop$' /etc/modules 2>/dev/null; then
    sed -i '/^snd-aloop$/d' /etc/modules || true
    log "Removed snd-aloop from /etc/modules"
  fi

  local cfg
  for cfg in "$CFG_C1" "$CFG_C2"; do
    [[ -f "$cfg" ]] || continue
    sed -i.bak '/^dtparam=act_led_trigger=none$/d' "$cfg" || true
    sed -i.bak '/^dtparam=act_led_activelow=off$/d' "$cfg" || true
    rm -f "${cfg}.bak" || true
  done

  log "Uninstall complete"
}

# ---- Validate args ----
validate_mhz "--freq" "$FREQ"
validate_mhz "--step" "$STEP"
validate_mhz "--min"  "$FMIN"
validate_mhz "--max"  "$FMAX"
[[ "$(awk -v a="$FMIN" -v b="$FMAX" 'BEGIN{print (a < b)}')" == "1" ]] || {
  log "ERROR: --min ($FMIN) must be less than --max ($FMAX)"; exit 1
}

if (( UNINSTALL )); then perform_uninstall; exit 0; fi

check_required_commands
check_fm_hardware_support

if (( DRY_RUN )); then
  log "DRY RUN: no changes will be made"
  log "Would install packages: shairport-sync avahi-daemon alsa-utils TTS build tools"
  log "Would load snd-aloop ALSA loopback kernel module (fallback if pipe backend unavailable)"
  log "Would configure shairport-sync: AirPlay name='$AP_NAME', pipe=/run/airplay_audio"
  log "Would build PiFmRds in: $PIFM_DIR"
  log "Would write /etc/default/airplay2fm  FREQ=$FREQ STEP=$STEP FMIN=$FMIN FMAX=$FMAX AP_NAME=$AP_NAME"
  log "Would deploy scripts to $BIN_DIR: airplay2fm.sh airplay-rds.py airplay_announce.sh led-airplay-statusd.sh"
  log "Would register systemd units: shairport-sync airplay2fm airplay-rds led-airplay-statusd"
  detect_pi_board
  show_board_art
  exit 0
fi

# ---- Apt install ----
log "Apt install (AirPlay, audio, PiFmRds deps, TTS, tools)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

declare -a APT_PACKAGES=(
  git build-essential autoconf automake libtool pkg-config
  libssl-dev libavahi-client-dev libasound2-dev libpopt-dev libconfig-dev
  libdaemon-dev libsystemd-dev avahi-daemon libnss-mdns
  avahi-utils alsa-utils sox jq libttspico-utils espeak-ng gawk python3
)

SHAIRPORT_FROM_APT=0
if command -v apt-cache >/dev/null 2>&1; then
  if POLICY=$(apt-cache policy shairport-sync 2>/dev/null) && \
     [[ -n "$POLICY" ]] && ! grep -q 'Candidate: (none)' <<<"$POLICY"; then
    APT_PACKAGES+=(shairport-sync)
    SHAIRPORT_FROM_APT=1
  fi
fi

apt-get install -y "${APT_PACKAGES[@]}"
INSTALL_SUMMARY+=("Apt packages installed: ${#APT_PACKAGES[@]} packages")

# ---- shairport-sync install / build ----
shairport_has_pipe_backend() {
  command -v shairport-sync >/dev/null 2>&1 || return 1
  shairport-sync --help 2>&1 | grep -qi 'pipe' || return 1
}

install_shairport_from_source() {
  log "Build shairport-sync from source (mikebrady/shairport-sync)"
  mkdir -p "$(dirname "$SHAIRPORT_SRC_DIR")"
  rm -rf "$SHAIRPORT_SRC_DIR"
  "$GIT_CLONE_CMD" clone --depth 1 "$SHAIRPORT_REPO" "$SHAIRPORT_SRC_DIR"
  pushd "$SHAIRPORT_SRC_DIR" >/dev/null
  autoreconf -fi
  ./configure \
    --sysconfdir=/etc \
    --with-alsa \
    --with-avahi \
    --with-ssl=openssl \
    --with-systemd \
    --with-metadata
  local jobs=1
  command -v nproc >/dev/null 2>&1 && jobs="$(nproc)"
  make -j"$jobs"
  make install
  popd >/dev/null
}

if (( SHAIRPORT_FROM_APT )) && shairport_has_pipe_backend; then
  log "Using apt shairport-sync (pipe backend confirmed)"
  INSTALL_SUMMARY+=("shairport-sync installed from apt")
elif ! shairport_has_pipe_backend; then
  install_shairport_from_source
  INSTALL_SUMMARY+=("shairport-sync built from source")
else
  log "shairport-sync already installed"
  INSTALL_SUMMARY+=("shairport-sync pre-existing")
fi

# ---- ALSA loopback (fallback detection, not primary path) ----
# snd-aloop is loaded only for diagnostics/compat; primary audio path is the shairport-sync pipe
log "Ensure snd-aloop is available (optional loopback fallback)"
modprobe snd-aloop 2>/dev/null || log "Warning: snd-aloop modprobe failed; continuing (pipe backend is primary)" >&2
if ! grep -q '^snd-aloop$' /etc/modules 2>/dev/null; then
  echo 'snd-aloop' >> /etc/modules
  vlog "Added snd-aloop to /etc/modules"
fi

# ---- Create FIFOs (boot-persistent via tmpfiles.d) ----
# /run is a tmpfs cleared on every boot; use tmpfiles.d so systemd recreates
# the FIFOs before any of our services start.
log "Create audio and RDS control FIFOs"
mkdir -p /run
for fifo in "$AIRPLAY_AUDIO_PIPE" "$AIRPLAY_META_PIPE" "$RDSCTL"; do
  rm -f "$fifo" || true
  mkfifo "$fifo"
  chown "$PI_USER:$PI_USER" "$fifo" || true
done
# The distro shairport-sync service runs as its own "shairport-sync" user,
# so the pipes it writes must be world-writable.
chmod 0666 "$AIRPLAY_AUDIO_PIPE" "$AIRPLAY_META_PIPE"
chmod 0660 "$RDSCTL"

cat >/etc/tmpfiles.d/airplay2fm.conf <<EOF
# Managed by airplay2fm (installer script)
# Recreate FIFOs at every boot before services start
# 0666: the distro shairport-sync service runs as its own user
p ${AIRPLAY_AUDIO_PIPE}  0666 ${PI_USER} ${PI_USER} -
p ${AIRPLAY_META_PIPE}   0666 ${PI_USER} ${PI_USER} -
p ${RDSCTL}              0660 ${PI_USER} ${PI_USER} -
EOF
INSTALL_SUMMARY+=("FIFOs: $AIRPLAY_AUDIO_PIPE  $AIRPLAY_META_PIPE  $RDSCTL (persistent via tmpfiles.d)")

# ---- shairport-sync config ----
log "Configure shairport-sync"
[[ -f /etc/shairport-sync.conf ]] && cp /etc/shairport-sync.conf /etc/shairport-sync.conf.airplay2fm.bak || true
cat >/etc/shairport-sync.conf <<EOF
// Managed by airplay2fm (installer script)
general = {
  name = "${AP_NAME}";
  output_backend = "pipe";
};

sessioncontrol = {
  // Allow a new AirPlay session to take over from an existing one
  allow_session_interruption = "yes";
  session_timeout = 120;
};

pipe = {
  // Audio is headerless raw S16_LE stereo 44100 Hz — sox wraps it in a WAV
  // container before it reaches pi_fm_rds stdin
  name = "${AIRPLAY_AUDIO_PIPE}";
};

metadata = {
  enabled = "yes";
  include_cover_art = "no";
  pipe_name = "${AIRPLAY_META_PIPE}";
  pipe_timeout = 5000;
};
EOF
INSTALL_SUMMARY+=("shairport-sync configured: name='${AP_NAME}' pipe=${AIRPLAY_AUDIO_PIPE}")

# ---- shairport-sync systemd unit ----
# Only write our own unit if one doesn't already exist from the distro package
SHSP_FRAG=""
SHSP_FRAG="$(systemctl show -p FragmentPath --value shairport-sync.service 2>/dev/null || true)"
if [[ -z "$SHSP_FRAG" || ! -f "$SHSP_FRAG" ]]; then
  cat >"$SYSUNIT_DIR/shairport-sync.service" <<'EOF'
# Managed by airplay2fm (installer script)
[Unit]
Description=ShairportSync AirPlay receiver
After=avahi-daemon.service
Wants=avahi-daemon.service

[Service]
Type=simple
ExecStart=/usr/local/bin/shairport-sync
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi
systemctl enable shairport-sync.service
systemctl restart shairport-sync.service || systemctl start shairport-sync.service || true
INSTALL_SUMMARY+=("shairport-sync.service enabled and started")

# ---- Skip boot-wait (offline-friendly) ----
log "Skip boot wait for network"
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_wait 0 || true
else
  for unit in systemd-networkd-wait-online.service NetworkManager-wait-online.service dhcpcd-wait-online.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
  done
fi

# ---- Build PiFmRds (shared with a2dp2fm if already present) ----
log "Clone & build PiFmRds"
if [[ ! -d "$PIFM_DIR" ]]; then
  sudo -u "$PI_USER" "$GIT_CLONE_CMD" clone https://github.com/ChristopheJacquet/PiFmRds.git "$PIFM_DIR"
fi
pushd "$PIFM_DIR/src" >/dev/null
sudo -u "$PI_USER" make clean || true
sudo -u "$PI_USER" make
popd >/dev/null
INSTALL_SUMMARY+=("PiFmRds built in $PIFM_DIR/src")

# ---- Runtime config ----
log "Runtime config: /etc/default/airplay2fm"
_cfg="$(mktemp)" || { log "ERROR: Failed to create temp file"; exit 1; }
cat >"$_cfg" <<EOF
FREQ=$FREQ
STEP=$STEP
FMIN=$FMIN
FMAX=$FMAX
AP_NAME="${AP_NAME}"
PI_USER="${PI_USER}"
PI_HOME="${PI_HOME}"
EOF
mv "$_cfg" /etc/default/airplay2fm
# mktemp creates 0600; the pipeline service runs as $PI_USER and sources this
chmod 644 /etc/default/airplay2fm
chown root:root /etc/default/airplay2fm || true
INSTALL_SUMMARY+=("Runtime config written to /etc/default/airplay2fm")

# ---- AirPlay -> FM pipeline script ----
log "AirPlay->FM pipeline (shairport-sync pipe -> PiFmRds stdin)"
cat >"$BIN_DIR/airplay2fm.sh" <<'APFM'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/airplay2fm

USER_NAME="${PI_USER:-$(id -un)}"
USER_HOME="${PI_HOME:-}"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 2>/dev/null || true)"
fi
[[ -z "$USER_HOME" ]] && USER_HOME="/home/$USER_NAME"

PIFM="$USER_HOME/PiFmRds/src/pi_fm_rds"
[ -x "$PIFM" ] || PIFM="$HOME/PiFmRds/src/pi_fm_rds"
AUDIO_PIPE="/run/airplay_audio"
RDSCTL="/run/rds_ctl"

[ -p "$AUDIO_PIPE" ] || mkfifo "$AUDIO_PIPE"
chmod 666 "$AUDIO_PIPE" 2>/dev/null || true  # shairport-sync runs as its own user
[ -p "$RDSCTL" ]    || mkfifo "$RDSCTL"

read_freq() { grep -E '^FREQ=' /etc/default/airplay2fm | cut -d= -f2; }

echo "Waiting for AirPlay stream on $AUDIO_PIPE ..." >&2

while true; do
  CURF="$(read_freq)"
  # cat blocks until shairport-sync opens the pipe (stream begins).
  # When the stream ends, shairport-sync closes the pipe -> cat gets EOF
  # -> pi_fm_rds gets EOF on stdin -> both exit -> loop restarts.
  # sox wraps the headerless raw PCM (S16_LE 44100 Hz stereo) from
  # shairport-sync in a WAV container so pi_fm_rds (libsndfile) can read it.
  cat "$AUDIO_PIPE" \
    | sox -t raw -r 44100 -e signed -b 16 -c 2 - -t wav - \
    | sudo "$PIFM" -freq "$CURF" -ps "AP-PI" -rt "AirPlay audio" -ctl "$RDSCTL" -audio - \
    || true
  sleep 1
done
APFM
finalize_script "$BIN_DIR/airplay2fm.sh"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay2fm.sh")

cat >"$SYSUNIT_DIR/airplay2fm.service" <<EOF
# Managed by airplay2fm (installer script)
[Unit]
Description=AirPlay -> PiFmRds (FM on GPIO4)
After=shairport-sync.service avahi-daemon.service
Wants=shairport-sync.service
[Service]
User=$PI_USER
EnvironmentFile=/etc/default/airplay2fm
ExecStart=/usr/local/bin/airplay2fm.sh
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

# ---- TTS announcer (speaks new frequency, then resumes the pipeline) ----
log "TTS announcer for frequency changes"
cat >"$BIN_DIR/airplay_announce.sh" <<'AANN'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/airplay2fm
USER_NAME="${PI_USER:-$(id -un)}"
USER_HOME="${PI_HOME:-}"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 2>/dev/null || true)"
fi
[[ -z "$USER_HOME" ]] && USER_HOME="/home/$USER_NAME"
PIFM="$USER_HOME/PiFmRds/src/pi_fm_rds"
[ -x "$PIFM" ] || PIFM="$HOME/PiFmRds/src/pi_fm_rds"
TARGET_FREQ="${1:-$FREQ}"
PREV_FREQ="${2:-}"
TMPWAV="/run/airplay_announce.wav"; mkdir -p /run
say(){ if command -v pico2wave >/dev/null; then pico2wave -l en-US -w "$TMPWAV" "$1"; else espeak-ng -v en-us -s 160 -w "$TMPWAV" "$1"; fi; }
fmt(){ awk -v f="$1" 'BEGIN{printf "%.1f", f}'; }
command -v /usr/local/bin/ledctl.sh >/dev/null 2>&1 && /usr/local/bin/ledctl.sh flash3 || true
# Stop the stream pipeline so only one pi_fm_rds owns GPIO4/DMA
systemctl stop airplay2fm.service >/dev/null 2>&1 || true
# Tell listeners on the old frequency where to go, then confirm on the new one
if [[ -n "$PREV_FREQ" && "$PREV_FREQ" != "$TARGET_FREQ" ]]; then
  say "Moving to $(fmt "$TARGET_FREQ") megahertz."
  # pi_fm_rds does not exit at end-of-file; bound the transmission
  timeout 8 sudo "$PIFM" -freq "$PREV_FREQ" -audio "$TMPWAV" || true
fi
say "Broadcasting at $(fmt "$TARGET_FREQ") megahertz."
timeout 8 sudo "$PIFM" -freq "$TARGET_FREQ" -audio "$TMPWAV" || true
sleep 0.5
systemctl start airplay2fm.service >/dev/null 2>&1 || true
AANN
finalize_script "$BIN_DIR/airplay_announce.sh"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay_announce.sh")

# ---- AirPlay metadata -> RDS + volume-key frequency daemon ----
log "AirPlay metadata -> RDS (PS/RT) + volume-key frequency daemon"
cat >"$BIN_DIR/airplay-rds.py" <<'PYAP'
#!/usr/bin/env python3
"""Read shairport-sync metadata pipe: update RDS PS/RT and shift the FM
frequency when the sender's volume keys are pressed while paused."""
import base64, logging, os, re, subprocess, threading, time, urllib.request
from xml.etree import ElementTree as ET

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

META_PIPE = "/run/airplay_metadata"
RDSCTL    = "/run/rds_ctl"
CONFIG    = "/etc/default/airplay2fm"
ANNOUNCE  = "/usr/local/bin/airplay_announce.sh"

def read_config():
    cfg = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    cfg[k] = v.strip().strip('"')
    except OSError as e:
        logger.warning(f"Config read failed: {e}")
    return cfg

def write_freq(new):
    try:
        with open(CONFIG) as f:
            lines = f.readlines()
        with open(CONFIG, "w") as f:
            for ln in lines:
                f.write(f"FREQ={new}\n" if ln.startswith("FREQ=") else ln)
    except OSError as e:
        logger.warning(f"Config write failed: {e}")

# Volume clicks are batched: rapid presses accumulate and the net change
# is applied after DEBOUNCE_S of quiet -- 3 up-clicks = +3*STEP, announced
# once. The worker thread keeps announcements off the metadata-reader loop.
DEBOUNCE_S = 3.0
_pending_lock  = threading.Lock()
_pending_steps = 0
_last_click    = 0.0

# DACP back-channel: AirPlay senders run a remote-control service we can
# command. After tuning clicks change the frequency, we snap the sender's
# volume bar back to where it was before the first click (best effort).
_dacp_id       = None   # ssnc/daid from the metadata stream
_active_remote = None   # ssnc/acre token, required header for DACP calls
_dacp_addr     = None   # cached (host, port) of the sender's control service
_vol_before    = None   # sender volume before the first click of a batch
_suppress_until = 0.0   # ignore pvol echoes of our own restore command

def dacp_discover():
    """Resolve the sender's DACP endpoint via mDNS (iTunes_Ctrl_<DACP-ID>)."""
    global _dacp_addr
    if _dacp_addr:
        return _dacp_addr
    if not _dacp_id:
        return None
    try:
        out = subprocess.run(
            ["avahi-browse", "-p", "-t", "-r", "_dacp._tcp"],
            capture_output=True, text=True, timeout=6).stdout
    except Exception as e:
        logger.warning(f"DACP discovery failed: {e}")
        return None
    want = f"itunes_ctrl_{_dacp_id}".lower()
    for line in out.splitlines():
        f = line.split(";")
        # =;<if>;IPv4;<name>;_dacp._tcp;local;<host>;<addr>;<port>;...
        if len(f) >= 9 and f[0] == "=" and f[2] == "IPv4" and f[3].lower() == want:
            _dacp_addr = (f[7], int(f[8]))
            logger.info(f"DACP endpoint: {f[7]}:{f[8]}")
            return _dacp_addr
    logger.info("DACP endpoint not advertised by sender")
    return None

def restore_sender_volume(vol):
    """Command the sender to restore its volume bar (best effort)."""
    global _suppress_until, _dacp_addr
    if vol is None or not _active_remote:
        return
    addr = dacp_discover()
    if not addr:
        return
    host, port = addr
    url = f"http://{host}:{port}/ctrl-int/1/setproperty?dmcp.device-volume={vol}"
    req = urllib.request.Request(url, headers={"Active-Remote": _active_remote})
    _suppress_until = time.time() + 3.0  # the restore echoes back as pvol
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            logger.info(f"Restored sender volume to {vol} (HTTP {r.status})")
    except Exception as e:
        _dacp_addr = None  # endpoint may be stale; rediscover next time
        logger.warning(f"Sender volume restore failed: {e}")

def queue_click(direction, prev_vol):
    global _pending_steps, _last_click, _vol_before
    with _pending_lock:
        if _pending_steps == 0:
            _vol_before = prev_vol  # sender volume before this batch began
        _pending_steps += 1 if direction == "up" else -1
        _last_click = time.time()
        pending = _pending_steps
    logger.info(f"Volume click {direction} queued (net {pending:+d})")


def apply_pending():
    """Apply the accumulated clicks once the quiet window has elapsed."""
    global _pending_steps, _vol_before
    with _pending_lock:
        if _pending_steps == 0 or (time.time() - _last_click) < DEBOUNCE_S:
            return
        steps, _pending_steps = _pending_steps, 0
        restore_vol, _vol_before = _vol_before, None
    cfg = read_config()
    try:
        cur  = float(cfg.get("FREQ", "87.9"))
        step = float(cfg.get("STEP", "0.2"))
        fmin = float(cfg.get("FMIN", "87.7"))
        fmax = float(cfg.get("FMAX", "107.9"))
    except ValueError as e:
        logger.warning(f"Bad config value: {e}")
        return
    new = round(min(max(cur + steps * step, fmin), fmax), 1)
    if new == cur:
        # Clamped to no-op: the clicks still moved the sender volume
        restore_sender_volume(restore_vol)
        return
    write_freq(new)
    logger.info(f"Frequency change: {cur} -> {new} MHz ({steps:+d} clicks)")
    if os.access(ANNOUNCE, os.X_OK):
        try:
            subprocess.run([ANNOUNCE, str(new), str(cur)], timeout=90, check=False)
        except Exception as e:
            logger.warning(f"Announce failed: {e}")
    restore_sender_volume(restore_vol)

def bump_worker():
    while True:
        time.sleep(0.25)
        apply_pending()

def decode_data(el):
    if el is None:
        return ""
    enc  = el.get("encoding", "")
    text = el.text or ""
    if enc == "base64":
        try:
            return base64.b64decode(text.strip()).decode("utf-8", errors="replace")
        except Exception:
            return ""
    return text

def hex2ascii(s):
    """shairport-sync writes <type>/<code> as 8-hex-digit-encoded ASCII."""
    s = (s or "").strip()
    try:
        return bytes.fromhex(s).decode("ascii", errors="replace")
    except ValueError:
        return s

def safe_ps(s: str) -> str:
    s = (s or "").strip()
    if not s:
        return "AP-PI"
    s = re.sub(r"[^A-Za-z0-9 -]", "", s)
    return (s[:8] or "AP-PI")

def safe_rt(title: str, artist: str, album: str) -> str:
    parts = [p for p in [artist, title] if p]
    txt   = " - ".join(parts) if parts else (title or artist or "AirPlay audio")
    if album and len(txt) < 48:
        txt += " • " + album
    txt = re.sub(r"[\r\n\t]+", " ", txt).strip()
    return txt[:64]

def write_rds(ps=None, rt=None):
    """Write PS/RT to the RDS FIFO without blocking.

    pi_fm_rds (the FIFO reader) only runs while an AirPlay stream is
    active. A plain open() blocks until a reader appears — which would
    wedge this daemon at startup and delay metadata-pipe reading until
    the first stream. Retry a non-blocking open briefly, then drop the
    update if no transmitter is listening.
    """
    data = ""
    if ps is not None:
        data += f"PS {ps}\n"
    if rt is not None:
        data += f"RT {rt}\n"
    if not data:
        return
    fd = None
    for _ in range(5):
        try:
            fd = os.open(RDSCTL, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError:
            time.sleep(0.4)  # ENXIO: no reader yet
    if fd is None:
        logger.info("RDS FIFO has no reader (transmitter idle); dropping update")
        return
    try:
        os.write(fd, data.encode())
    except OSError as e:
        logger.warning(f"RDS write failed: {e}")
    finally:
        os.close(fd)

def parse_items(pipe_file):
    """Yield parsed (itype, code, value) tuples from the shairport-sync metadata pipe."""
    buf = ""
    for raw_line in pipe_file:
        buf += raw_line
        while "</item>" in buf:
            end   = buf.index("</item>") + len("</item>")
            chunk = buf[:end].strip()
            buf   = buf[end:]
            # Find the start of the item element
            start = chunk.find("<item>")
            if start < 0:
                continue
            chunk = chunk[start:]
            try:
                root  = ET.fromstring(chunk)
                itype = root.findtext("type") or ""
                code  = root.findtext("code") or ""
                value = decode_data(root.find("data"))
                yield hex2ascii(itype), hex2ascii(code), value
            except ET.ParseError:
                pass

def main():
    global _dacp_id, _dacp_addr, _active_remote
    write_rds(ps="AP-PI", rt="AirPlay audio")
    threading.Thread(target=bump_worker, daemon=True).start()
    title = artist = album = ""
    play_state = "idle"   # volume keys only shift frequency while paused
    last_vol   = None     # baseline; first pvol after a state change sets it

    while True:
        try:
            with open(META_PIPE, "r", errors="replace") as f:
                for itype, code, value in parse_items(f):
                    if itype == "ssnc":
                        if code in ("pbeg", "prsm"):
                            logger.info("Stream started/resumed")
                            write_rds(ps="AP-PI", rt="AirPlay audio")
                            title = artist = album = ""
                            play_state = "active"
                            # pvol is an absolute dB value: keep the baseline
                            # across pause/resume so no click gets eaten;
                            # reset only at the start of a new session.
                            if code == "pbeg":
                                last_vol = None
                        elif code in ("pend", "pfls"):
                            logger.info("Stream ended/paused")
                            write_rds(ps="AP-PI", rt="AirPlay audio")
                            title = artist = album = ""
                            play_state = "paused"
                        elif code == "pvol":
                            # "airplay_volume,volume,lowest,highest"; first
                            # field is -144 (mute) or -30..0 dB attenuation
                            try:
                                vol = float(value.split(",")[0])
                            except (ValueError, IndexError):
                                continue
                            logger.debug(f"pvol {vol} (state={play_state})")
                            prev, last_vol = last_vol, vol
                            # Tuning only while paused: during playback the
                            # rocker is ordinary volume control.
                            if prev is None or vol == prev or play_state == "active":
                                continue
                            if time.time() < _suppress_until:
                                continue  # echo of our own volume restore
                            queue_click("up" if vol > prev else "down", prev)
                        elif code == "daid":
                            if value and value != _dacp_id:
                                _dacp_id, _dacp_addr = value, None
                        elif code == "acre":
                            if value:
                                _active_remote = value
                        elif code == "mden":
                            # metadata-end (ssnc type): all core track fields received
                            if title or artist:
                                write_rds(
                                    ps=safe_ps(artist or title),
                                    rt=safe_rt(title, artist, album),
                                )
                                logger.info(f"RDS updated: '{artist}' / '{title}'")
                    elif itype == "core":
                        if   code == "minm":
                            title  = value
                        elif code == "asar":
                            artist = value
                        elif code == "asal":
                            album  = value
        except OSError as e:
            logger.warning(f"Metadata pipe error ({e}); retrying in 3s")
            time.sleep(3)

if __name__ == "__main__":
    main()
PYAP
finalize_script "$BIN_DIR/airplay-rds.py"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay-rds.py")

cat >"$SYSUNIT_DIR/airplay-rds.service" <<'RDSVC'
# Managed by airplay2fm (installer script)
[Unit]
Description=Update RDS PS/RT from AirPlay track metadata
After=shairport-sync.service airplay2fm.service
Wants=shairport-sync.service
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/airplay-rds.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
RDSVC

# ---- LED helper (shared with a2dp2fm; always overwrite so fixes propagate) ----
log "Install LED control helper"
cat >"$BIN_DIR/ledctl.sh" <<'LEDCTL'
#!/usr/bin/env bash
set -euo pipefail
# The activity LED is /sys/class/leds/ACT on Raspberry Pi OS Bookworm+
# kernels and /sys/class/leds/led0 on older releases.
LED=""
for name in ACT led0; do
  [[ -d "/sys/class/leds/$name" ]] && { LED="/sys/class/leds/$name"; break; }
done
# No controllable activity LED (some boards/containers): no-op successfully.
[[ -n "$LED" ]] || exit 0
TR="$LED/trigger"; BR="$LED/brightness"
set_manual(){ [[ -w "$TR" ]] && echo none | sudo tee "$TR" >/dev/null || true; }
on(){ set_manual; echo 1 | sudo tee "$BR" >/dev/null; }
off(){ set_manual; echo 0 | sudo tee "$BR" >/dev/null; }
blink_for(){
  local d="$1" p="$2"; set_manual
  local end=$(( $(date +%s%3N)+d ))
  while (( $(date +%s%3N) < end )); do
    echo 1|sudo tee "$BR" >/dev/null; sleep "$(awk -v p="$p" 'BEGIN{printf "%.3f", p/2000}')"
    echo 0|sudo tee "$BR" >/dev/null; sleep "$(awk -v p="$p" 'BEGIN{printf "%.3f", p/2000}')"
  done
}
slow(){ blink_for 2000 1000; }
fast(){ blink_for 600 200; }
double(){ on; sleep 0.12; off; sleep 0.12; on; sleep 0.12; off; }
flash3(){ for i in 1 2 3; do blink_for 180 180; sleep 0.06; done; }
case "${1:-}" in on|off|slow|fast|double|flash3) "$@";; *) echo "Usage: ledctl.sh {on|off|slow|fast|double|flash3}";; esac
LEDCTL
chmod +x "$BIN_DIR/ledctl.sh"
chown "$PI_USER:$PI_USER" "$BIN_DIR/ledctl.sh" || true
INSTALL_SUMMARY+=("Deployed $BIN_DIR/ledctl.sh")

# ---- LED status daemon for AirPlay ----
log "AirPlay LED status daemon"
cat >"$BIN_DIR/led-airplay-statusd.sh" <<'LEDD'
#!/usr/bin/env bash
set -euo pipefail

shairport_running(){ systemctl is-active --quiet shairport-sync.service 2>/dev/null; }

# "Streaming" means airplay2fm.service is active AND pi_fm_rds is actually running
streaming(){
  systemctl is-active --quiet airplay2fm.service 2>/dev/null || return 1
  pgrep -x pi_fm_rds >/dev/null 2>&1
}

while true; do
  if streaming; then
    /usr/local/bin/ledctl.sh on; sleep 1
  elif shairport_running; then
    /usr/local/bin/ledctl.sh slow; sleep 1
  else
    /usr/local/bin/ledctl.sh off; sleep 1
  fi
done
LEDD
finalize_script "$BIN_DIR/led-airplay-statusd.sh"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/led-airplay-statusd.sh")

cat >"$SYSUNIT_DIR/led-airplay-statusd.service" <<'LEDSVC'
# Managed by airplay2fm (installer script)
[Unit]
Description=On-board LED status for AirPlay->FM (waiting/streaming)
After=shairport-sync.service
Wants=shairport-sync.service
[Service]
Type=simple
ExecStart=/usr/local/bin/led-airplay-statusd.sh
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
LEDSVC

# ---- ACT LED (software control) ----
log "Take over ACT LED for software control"
for CFG in "$CFG_C1" "$CFG_C2"; do
  [[ -f "$CFG" ]] || continue
  sed -i.bak '/^dtparam=act_led_trigger=/d' "$CFG" || true
  sed -i.bak '/^dtparam=act_led_activelow=/d' "$CFG" || true
  rm -f "${CFG}.bak" || true
  echo 'dtparam=act_led_trigger=none' >> "$CFG"
  echo 'dtparam=act_led_activelow=off' >> "$CFG"
done

# ---- Enable & start all services ----
log "Enable & start services"
systemctl daemon-reload
systemctl enable airplay2fm.service airplay-rds.service led-airplay-statusd.service
systemctl restart airplay2fm.service airplay-rds.service led-airplay-statusd.service || true
INSTALL_SUMMARY+=("Systemd services: shairport-sync airplay2fm airplay-rds led-airplay-statusd")

log "Install summary:"
for _s in "${INSTALL_SUMMARY[@]}"; do log "  * $_s"; done

cat <<DONE

================================================================================
INSTALL COMPLETE (AirPlay -> FM)

• AirPlay name:    ${AP_NAME}
  (Appears in iOS Control Center / macOS audio output selector)
• FM frequency:    ${FREQ} MHz   step: ${STEP} MHz   range: ${FMIN} - ${FMAX} MHz
• Antenna:         Connect a 10-20 cm wire to GPIO4 (pin 7) — see the board
                   diagram below.

How to use:
  1. Ensure your iPhone/Mac is on the same Wi-Fi network as the Pi.
  2. Open Control Center -> AirPlay icon -> select "${AP_NAME}".
  3. Play audio; tune a radio to ${FREQ} MHz.

RDS:    PS shows artist (8 chars), RT shows "Artist - Title * Album".
LED:    Slow blink = AirPlay ready (waiting). Solid = streaming.

Audio pipeline:
  iOS/Mac -> AirPlay (RAOP) -> shairport-sync -> /run/airplay_audio (FIFO)
          -> airplay2fm.sh -> pi_fm_rds (GPIO4 FM)

Notes:
  - FM transmits only while AirPlay audio is playing (carrier off when idle).
  - Change frequency from the sender: pause playback, then press volume
    up/down (step: ${STEP} MHz, range ${FMIN}-${FMAX}). LED flashes and the
    new frequency is announced over FM. Or edit the config directly:
      sudo sed -i 's/^FREQ=.*/FREQ=NEW_FREQ/' /etc/default/airplay2fm
      sudo systemctl restart airplay2fm.service
  - A reboot may be required for full ACT LED control.
  - If a2dp2fm (Bluetooth) is also installed, do NOT run both simultaneously
    (both use GPIO4 for the FM transmitter).
  - Services:
      sudo systemctl status shairport-sync airplay2fm airplay-rds led-airplay-statusd

Enjoy!
================================================================================
DONE

detect_pi_board
show_board_art
