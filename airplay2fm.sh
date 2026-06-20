#!/usr/bin/env bash
# airplay2fm.sh
# Headless AirPlay (RAOP) -> PiFmRds (FM on GPIO4) + RDS metadata + LED status
# Uses shairport-sync as the AirPlay 1 receiver with pipe audio output
# Tags: raspberry-pi, airplay, raop, fm-transmitter, rds, pi-fm-rds, shairport-sync, systemd, tts
# Usage: sudo bash airplay2fm.sh [--freq 87.9] [--name "Pi FM Radio"] [--step 0.2] [--min 87.7] [--max 107.9] [--vol-tune]

set -euo pipefail

FREQ="87.9"; STEP="0.2"; FMIN="87.7"; FMAX="107.9"; AP_NAME="Pi FM Radio"
VOL_TUNE=0
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
    --vol-tune) VOL_TUNE=1; shift;;
    *) echo "Usage: sudo bash $0 [--freq 87.9] [--name 'Pi FM Radio'] [--step 0.2] [--min 87.7] [--max 107.9] [--vol-tune] [--dry-run] [--verbose] [--uninstall]"; exit 1;;
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
  log "Would install packages: shairport-sync avahi-daemon sox TTS build tools"
  log "Would load snd-aloop ALSA loopback kernel module (fallback if pipe backend unavailable)"
  log "Would configure shairport-sync: AirPlay name='$AP_NAME', pipe=/run/airplay_audio"
  log "Would build PiFmRds in: $PIFM_DIR"
  log "Would write /etc/default/airplay2fm  FREQ=$FREQ STEP=$STEP FMIN=$FMIN FMAX=$FMAX AP_NAME=$AP_NAME VOL_TUNE=$VOL_TUNE"
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
  libsystemd-dev avahi-daemon libnss-mdns
  avahi-utils sox flite python3
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
else
  sudo -u "$PI_USER" git -C "$PIFM_DIR" pull --ff-only || true
fi
_pifm_binary="$PIFM_DIR/src/pi_fm_rds"
_pifm_stamp="$PIFM_DIR/src/.built_commit"
_pifm_head=$(sudo -u "$PI_USER" git -C "$PIFM_DIR" rev-parse HEAD 2>/dev/null || true)
_pifm_built=$(cat "$_pifm_stamp" 2>/dev/null || true)
if [[ -x "$_pifm_binary" && -n "$_pifm_head" && "$_pifm_head" == "$_pifm_built" ]]; then
  log "PiFmRds already up-to-date (${_pifm_head:0:7}); skipping recompile"
  INSTALL_SUMMARY+=("PiFmRds up-to-date in $PIFM_DIR/src (skipped recompile)")
else
  pushd "$PIFM_DIR/src" >/dev/null
  sudo -u "$PI_USER" make clean || true
  sudo -u "$PI_USER" make
  popd >/dev/null
  [[ -n "$_pifm_head" ]] && echo "$_pifm_head" > "$_pifm_stamp" || true
  INSTALL_SUMMARY+=("PiFmRds built in $PIFM_DIR/src")
fi

# ---- Runtime config ----
log "Runtime config: /etc/default/airplay2fm"
_cfg="$(mktemp)" || { log "ERROR: Failed to create temp file"; exit 1; }
cat >"$_cfg" <<EOF
FREQ=$FREQ
STEP=$STEP
FMIN=$FMIN
FMAX=$FMAX
AP_NAME="${AP_NAME}"
VOL_TUNE=$VOL_TUNE
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
    | tee >(python3 /usr/local/bin/airplay-level.py 2>/dev/null || true) \
    | sox -t raw -r 44100 -e signed -b 16 -c 2 - -t wav - \
    | sudo "$PIFM" -freq "$CURF" -ps "AP-PI" -rt "AirPlay audio" -ctl "$RDSCTL" -audio - \
    || true
  sleep 1
done
APFM
finalize_script "$BIN_DIR/airplay2fm.sh"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay2fm.sh")

cat >"$BIN_DIR/airplay-level.py" <<'LVLPY'
#!/usr/bin/env python3
"""Read raw S16_LE stereo 44100 Hz PCM from stdin; write RMS level to /run/airplay_level every 50 ms."""
import sys, struct, math

CHUNK = 8820   # 50 ms of 44100 Hz stereo S16_LE  (44100 * 0.05 * 2ch * 2B)
LEVEL = "/run/airplay_level"

def run():
    while True:
        try:
            data = sys.stdin.buffer.read(CHUNK)
        except Exception:
            break
        if not data:
            break
        n = len(data) // 2
        if not n:
            continue
        try:
            s   = struct.unpack_from('<' + 'h' * n, data[:n * 2])
            rms = min(1.0, math.sqrt(sum(x * x for x in s) / n) / 32768.0)
            with open(LEVEL, 'w') as f:
                f.write('%.4f' % rms)
        except Exception:
            pass

try:
    run()
finally:
    try:
        with open(LEVEL, 'w') as f:
            f.write('0.0000')
    except Exception:
        pass
LVLPY
finalize_script "$BIN_DIR/airplay-level.py"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay-level.py")

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
AUDIO_PIPE="/run/airplay_audio"
say(){ flite -t "$1" -o "$TMPWAV"; }
fmt(){ awk -v f="$1" 'BEGIN{printf "%.1f", f}'; }
command -v /usr/local/bin/ledctl.sh >/dev/null 2>&1 && /usr/local/bin/ledctl.sh flash3 || true

# Keep the FIFO drained while pi_fm_rds is offline so shairport-sync never
# loses its writer, never gets SIGPIPE, and the AirPlay session stays alive.
# Without this, iOS takes ~60 s to reconnect after the announce.
cat "$AUDIO_PIPE" >/dev/null &
DRAINER=$!
trap 'kill "$DRAINER" 2>/dev/null || true' EXIT

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

# Start the pipeline first, wait briefly for its cat to open the FIFO,
# then kill the drainer — overlap ensures shairport-sync always has a reader.
systemctl start airplay2fm.service >/dev/null 2>&1 || true
sleep 0.3
kill "$DRAINER" 2>/dev/null || true
AANN
finalize_script "$BIN_DIR/airplay_announce.sh"
INSTALL_SUMMARY+=("Deployed $BIN_DIR/airplay_announce.sh")

# ---- AirPlay metadata -> RDS + volume-key frequency daemon ----
log "AirPlay metadata -> RDS (PS/RT) + volume-key frequency daemon"
cat >"$BIN_DIR/airplay-rds.py" <<'PYAP'
#!/usr/bin/env python3
"""AirPlay metadata -> RDS PS/RT; HTTP tuner UI; optional volume-key frequency control."""
import base64, json, logging, os, re, subprocess, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from xml.etree import ElementTree as ET

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

META_PIPE  = "/run/airplay_metadata"
RDSCTL     = "/run/rds_ctl"
CONFIG     = "/etc/default/airplay2fm"
ANNOUNCE   = "/usr/local/bin/airplay_announce.sh"
LEVEL_FILE = "/run/airplay_level"

def _get_level():
    try:
        with open(LEVEL_FILE) as f:
            return min(1.0, max(0.0, float(f.read().strip())))
    except Exception:
        return 0.0

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

# ---------------------------------------------------------------------------
# Shared UI state — updated by the metadata loop, read by the HTTP handler
# ---------------------------------------------------------------------------
_ui_lock  = threading.Lock()
_ui_state = {"play_state": "idle", "title": "", "artist": "", "album": "", "volume": None}

def _set_ui(**kw):
    with _ui_lock:
        _ui_state.update(kw)

def _get_status():
    cfg = read_config()
    with _ui_lock:
        st = dict(_ui_state)
    return {
        "freq":       cfg.get("FREQ",    "87.9"),
        "step":       cfg.get("STEP",    "0.2"),
        "fmin":       cfg.get("FMIN",    "87.7"),
        "fmax":       cfg.get("FMAX",    "107.9"),
        "ap_name":    cfg.get("AP_NAME", "Pi FM Radio"),
        "play_state": st["play_state"],
        "title":      st["title"],
        "artist":     st["artist"],
        "album":      st["album"],
        "volume":     st["volume"],
    }

# ---------------------------------------------------------------------------
# HTTP tuner server
# ---------------------------------------------------------------------------
_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#0a0a0a">
<title>Pi FM</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,sans-serif;background:#0a0a0a;color:#e8e8e8;max-width:420px;margin:0 auto;padding:1.25rem 1rem 2rem;min-height:100dvh}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1.4rem}
.logo{font-size:.72rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#3a3a3a}
.live{display:flex;align-items:center;gap:.38rem;font-size:.62rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#3a3a3a}
.live .ld{width:6px;height:6px;border-radius:50%;background:#333;flex-shrink:0}
.live.on{color:#3c3}
.live.on .ld{background:#3c3;box-shadow:0 0 6px #3c3;animation:blip 1.6s ease-in-out infinite}
@keyframes blip{0%,100%{opacity:1}50%{opacity:.3}}
.fcard{background:linear-gradient(160deg,#161616,#111);border:1px solid #1e1e1e;border-radius:20px;padding:1.6rem 1rem 1.3rem;text-align:center;margin-bottom:.75rem;position:relative;overflow:hidden}
.fcard::after{content:'';position:absolute;top:0;left:50%;transform:translateX(-50%);width:55%;height:1px;background:linear-gradient(90deg,transparent,rgba(255,153,0,.5),transparent)}
.fnum{font-size:5.5rem;font-weight:800;color:#ff9900;line-height:1;letter-spacing:-.04em;font-variant-numeric:tabular-nums;text-shadow:0 0 50px rgba(255,153,0,.25)}
.funit{font-size:.75rem;font-weight:700;color:#3a3a3a;letter-spacing:.18em;text-transform:uppercase;margin-top:.45rem}
.card{background:#141414;border:1px solid #1e1e1e;border-radius:16px;padding:.9rem 1rem;margin-bottom:.75rem}
.badge{display:inline-flex;align-items:center;gap:.3rem;font-size:.6rem;font-weight:700;padding:.18rem .5rem;border-radius:999px;background:#1e1e1e;color:#444;letter-spacing:.07em;text-transform:uppercase;margin-bottom:.55rem}
.bdot{width:5px;height:5px;border-radius:50%;background:currentColor;flex-shrink:0}
.badge.playing{background:#0a320a;color:#3c3}
.badge.paused{background:#38280a;color:#b80}
.ttl{font-size:1.02rem;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-height:1.35em}
.sub{color:#484848;font-size:.83rem;margin-top:.18rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-height:1.2em}
.vcard{background:#141414;border:1px solid #1e1e1e;border-radius:16px;padding:.9rem 1rem .85rem;margin-bottom:.75rem}
.vlbl{font-size:.58rem;font-weight:700;color:#2e2e2e;letter-spacing:.1em;text-transform:uppercase;margin-bottom:.6rem;display:flex;justify-content:space-between;align-items:center}
.vlbl span{color:#3a3a3a;font-weight:600;font-size:.6rem}
.bars{display:flex;align-items:flex-end;gap:3px;height:44px;margin-bottom:.8rem}
.bar{flex:1;border-radius:2px 2px 0 0;background:#ff9900;min-height:3px;height:3px;opacity:.2;transition:height .08s ease,opacity .08s ease}
.volrow{display:flex;align-items:center;gap:.6rem}
.vt{font-size:.58rem;font-weight:700;letter-spacing:.07em;text-transform:uppercase;flex-shrink:0;width:2.2rem;color:#3a3a3a}
.vtrack{flex:1;height:5px;background:#1e1e1e;border-radius:4px;overflow:hidden}
.vfill{height:100%;border-radius:4px;background:#3c3;width:0%;transition:width .5s ease,background .5s ease}
.vfill.mid{background:#c90}
.vfill.low{background:#c33}
.vpct{font-size:.62rem;font-weight:700;color:#3a3a3a;flex-shrink:0;width:2.4rem;text-align:right;font-variant-numeric:tabular-nums}
.btns{display:grid;grid-template-columns:1fr 1fr;gap:.5rem;margin-bottom:.5rem}
.btn{padding:.88rem;font-size:.95rem;font-weight:600;background:#141414;color:#c0c0c0;border:1px solid #1e1e1e;border-radius:14px;cursor:pointer;-webkit-tap-highlight-color:transparent;transition:background .1s,transform .1s,color .1s}
.btn:active{background:#202020;transform:scale(.96)}
.bsm{font-size:.8rem;color:#444}
.setrow{display:flex;gap:.5rem}
.setrow input{flex:1;background:#141414;border:1px solid #1e1e1e;border-radius:14px;color:#e8e8e8;font-size:1rem;padding:.78rem 1rem;-moz-appearance:textfield;outline:none;transition:border-color .15s}
.setrow input:focus{border-color:#2e2e2e}
.setrow input::-webkit-outer-spin-button,.setrow input::-webkit-inner-spin-button{-webkit-appearance:none}
.setrow .btn{flex:0 0 auto;padding:.78rem 1.1rem}
.meta{text-align:center;color:#262626;font-size:.62rem;margin-top:.9rem;letter-spacing:.05em}
</style>
</head>
<body>
<div class="header">
  <div class="logo" id="apn">Pi FM</div>
  <div class="live" id="live"><span class="ld"></span><span id="lst">Idle</span></div>
</div>
<div class="fcard">
  <div class="fnum" id="freq">—</div>
  <div class="funit">MHz &middot; FM</div>
</div>
<div class="card">
  <div class="badge" id="badge"><span class="bdot"></span><span id="st">Idle</span></div>
  <div class="ttl" id="ttl">&nbsp;</div>
  <div class="sub" id="sub">&nbsp;</div>
</div>
<div class="vcard">
  <div class="vlbl">Signal &amp; Level<span id="volwarn"></span></div>
  <div class="bars" id="bars"></div>
  <div class="volrow">
    <div class="vt">Vol</div>
    <div class="vtrack"><div class="vfill" id="vf"></div></div>
    <div class="vpct" id="vpct">&mdash;</div>
  </div>
</div>
<div class="btns">
  <button class="btn" onclick="tune(-1)">&#9664; Down</button>
  <button class="btn" onclick="tune(1)">Up &#9654;</button>
</div>
<div class="btns">
  <button class="btn bsm" onclick="jumpTo(87.9)">&#9660; 87.9</button>
  <button class="btn bsm" onclick="jumpTo(107.9)">107.9 &#9650;</button>
</div>
<div class="setrow">
  <input type="number" id="nf" step="0.1" min="87.1" placeholder="MHz">
  <button class="btn" onclick="setf()">Set</button>
</div>
<div class="meta" id="meta"></div>
<script>
var N = 22;
var barsEl = document.getElementById('bars');
for (var i = 0; i < N; i++) {
  var b = document.createElement('div'); b.className = 'bar'; barsEl.appendChild(b);
}
var bars = barsEl.querySelectorAll('.bar');
var barEnv = new Array(N).fill(0);
var playing = false;
var S = {freq:'87.9',step:'0.2',fmin:'87.7',fmax:'107.9',play_state:'idle',
         title:'',artist:'',album:'',ap_name:'Pi FM',volume:null};

function updateBars(level) {
  for (var i = 0; i < bars.length; i++) {
    var target = level * (0.35 + Math.random() * 0.65) * 40;
    barEnv[i] = target > barEnv[i]
      ? barEnv[i] * 0.25 + target * 0.75   // fast attack
      : barEnv[i] * 0.78 + target * 0.22;  // slow decay
    var h = Math.max(3, barEnv[i]);
    bars[i].style.height = h + 'px';
    bars[i].style.opacity = 0.18 + (h / 44) * 0.82;
  }
}

function pollLevel() {
  if (!playing) { updateBars(0); return; }
  fetch('/api/level').then(function(r){return r.json();}).then(function(d){
    updateBars(d.level || 0);
  }).catch(function(){updateBars(0);});
}
setInterval(pollLevel, 150);

function render(d) {
  S = d;
  document.getElementById('freq').textContent = d.freq;
  document.getElementById('apn').textContent = d.ap_name || 'Pi FM';
  var active = d.play_state === 'active', paused = d.play_state === 'paused';
  var stMap = {active:'Playing', paused:'Paused', idle:'Idle'};
  document.getElementById('st').textContent = stMap[d.play_state] || 'Idle';
  document.getElementById('badge').className = 'badge' + (active ? ' playing' : paused ? ' paused' : '');
  var live = document.getElementById('live');
  document.getElementById('lst').textContent = active ? 'Live' : 'Idle';
  live.className = 'live' + (active ? ' on' : '');
  document.getElementById('ttl').textContent = d.title || (active ? 'AirPlay Stream' : ' ');
  document.getElementById('sub').textContent = [d.artist, d.album].filter(Boolean).join(' · ') || ' ';
  var nf = document.getElementById('nf'); nf.min = d.fmin; nf.max = d.fmax; nf.step = d.step;
  document.getElementById('meta').textContent = 'Step ' + d.step + ' MHz  ·  ' + d.fmin + '–' + d.fmax;
  playing = active;
  if (!active) { updateBars(0); }
  var vf = document.getElementById('vf'), vp = document.getElementById('vpct');
  var warn = document.getElementById('volwarn');
  if (d.volume !== null && d.volume !== undefined) {
    var pct = d.volume <= -144 ? 0 : Math.round(Math.max(0, Math.min(100, (d.volume + 30) / 30 * 100)));
    vf.style.width = pct + '%';
    vp.textContent = pct + '%';
    vf.className = 'vfill' + (pct < 25 ? ' low' : pct < 55 ? ' mid' : '');
    warn.textContent = pct < 25 ? '⚠ Low' : '';
    warn.style.color = pct < 25 ? '#c33' : '';
  } else {
    vf.style.width = active ? '60%' : '0%';
    vf.className = 'vfill'; vp.textContent = '—'; warn.textContent = '';
  }
}
function poll() { fetch('/api/status').then(function(r){return r.json();}).then(render).catch(function(){}); }
function tune(dir) {
  var cur = parseFloat(S.freq), step = parseFloat(S.step);
  var nv = +(Math.min(Math.max(cur + dir*step, parseFloat(S.fmin)), parseFloat(S.fmax)).toFixed(1));
  document.getElementById('freq').textContent = nv; S.freq = '' + nv;
  fetch('/api/' + (dir > 0 ? 'up' : 'down'), {method:'POST'}).then(function(){setTimeout(poll,250);});
}
function jumpTo(f) {
  document.getElementById('freq').textContent = f;
  fetch('/api/freq', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:'freq=' + encodeURIComponent(f)}).then(function(){setTimeout(poll,250);});
}
function setf() {
  var v = parseFloat(document.getElementById('nf').value); if (isNaN(v)) return;
  var nv = +(Math.min(Math.max(v, 87.1), parseFloat(S.fmax)).toFixed(1));
  document.getElementById('freq').textContent = nv;
  fetch('/api/freq', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:'freq=' + encodeURIComponent(nv)}).then(function(){setTimeout(poll,250);});
}
poll(); setInterval(poll, 3000);
</script>
</body>
</html>"""

def _do_tune(new_freq, cur_freq):
    write_freq(new_freq)
    logger.info(f"Tune {cur_freq} -> {new_freq} MHz")
    if os.access(ANNOUNCE, os.X_OK):
        threading.Thread(
            target=lambda: subprocess.run(
                [ANNOUNCE, str(new_freq), str(cur_freq)], timeout=90, check=False),
            daemon=True).start()

def _tune_steps(steps):
    cfg = read_config()
    try:
        cur  = float(cfg.get("FREQ", "87.9"))
        step = float(cfg.get("STEP", "0.2"))
        fmin = float(cfg.get("FMIN", "87.7"))
        fmax = float(cfg.get("FMAX", "107.9"))
    except ValueError:
        return
    new = round(min(max(cur + steps * step, fmin), fmax), 1)
    if new != cur:
        _do_tune(new, cur)

def _tune_absolute(freq_s):
    cfg = read_config()
    try:
        cur  = float(cfg.get("FREQ", "87.9"))
        fmax = float(cfg.get("FMAX", "107.9"))
        new  = round(min(max(float(freq_s), 87.1), fmax), 1)
    except ValueError:
        return
    if new != cur:
        _do_tune(new, cur)

class _TunerHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass  # silence per-request log

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            body = _HTML.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/status":
            body = json.dumps(_get_status()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/level":
            body = json.dumps({"level": _get_level()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        try:
            if self.path == "/api/up":
                _tune_steps(+1)
            elif self.path == "/api/down":
                _tune_steps(-1)
            elif self.path == "/api/freq":
                length = int(self.headers.get("Content-Length", 0))
                raw    = self.rfile.read(length).decode(errors="replace")
                params = urllib.parse.parse_qs(raw)
                freq_s = params.get("freq", [""])[0]
                if freq_s:
                    _tune_absolute(freq_s)
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(204)
            self.end_headers()
        except Exception as e:
            logger.warning(f"HTTP handler error: {e}")
            self.send_response(500)
            self.end_headers()

def _http_server_thread():
    cfg  = read_config()
    try:
        port = int(cfg.get("HTTP_PORT", "8750"))
    except ValueError:
        port = 8750
    try:
        srv = HTTPServer(("", port), _TunerHandler)
        logger.info(f"Tuner UI: http://0.0.0.0:{port}/")
        srv.serve_forever()
    except Exception as e:
        logger.warning(f"HTTP server failed on port {port}: {e}")

# ---------------------------------------------------------------------------
# Volume-key frequency control (disabled by default; enabled with VOL_TUNE=1)
# ---------------------------------------------------------------------------
DEBOUNCE_S = 3.0
_pending_lock  = threading.Lock()
_pending_steps = 0
_last_click    = 0.0

# DACP back-channel globals (used only when VOL_TUNE=1)
_dacp_id        = None
_active_remote  = None
_dacp_addr      = None
_vol_before     = None
_suppress_until = 0.0
_restore_target = None
_restore_at     = 0.0
_current_vol    = None

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

def defer_restore(steps, vol_before):
    """Park the undo until playback resumes — iOS accepts DACP volume
    commands while paused (HTTP 200) but does not apply them. The target
    is the volume before the EARLIEST un-restored batch."""
    global _restore_target
    if not steps or vol_before is None:
        return
    with _pending_lock:
        if _restore_target is None:
            _restore_target = vol_before
        target = _restore_target
    logger.info(f"Volume restore deferred until playback resumes (target {target})")

def maybe_restore():
    global _restore_target
    with _pending_lock:
        if _restore_target is None or _restore_at == 0.0 or time.time() < _restore_at:
            return
        target, _restore_target = _restore_target, None
    restore_sender_volume_to(target)

def restore_sender_volume_to(target):
    """Nudge the sender's volume back one click at a time, watching pvol
    echoes to confirm each step applied before sending the next.
    (setproperty with a dB value returns HTTP 200 but iOS ignores it;
    discrete volumeup/volumedown are the only commands it applies.)"""
    global _suppress_until, _dacp_addr
    if target is None or not _active_remote:
        return
    addr = dacp_discover()
    if not addr:
        return
    host, port = addr
    sent = 0
    try:
        for _ in range(24):  # iOS rocker steps are 1.875 dB; 16 spans the range
            cur = _current_vol
            if cur is None:
                break
            diff = target - cur
            if abs(diff) < 1.0:  # within half a click of the target
                break
            cmd = "volumeup" if diff > 0 else "volumedown"
            _suppress_until = time.time() + 3.0
            req = urllib.request.Request(
                f"http://{host}:{port}/ctrl-int/1/{cmd}",
                headers={"Active-Remote": _active_remote})
            with urllib.request.urlopen(req, timeout=3):
                sent += 1
            time.sleep(0.5)  # let the echo update _current_vol
        logger.info(f"Volume restore: target {target}, now {_current_vol} ({sent} commands)")
    except Exception as e:
        _dacp_addr = None  # endpoint may be stale; rediscover next time
        logger.warning(f"Volume restore failed after {sent} commands: {e}")

def queue_click(direction, prev_vol):
    global _pending_steps, _last_click, _vol_before
    with _pending_lock:
        if _pending_steps == 0:
            _vol_before = prev_vol
        _pending_steps += 1 if direction == "up" else -1
        _last_click = time.time()
        pending = _pending_steps
    logger.info(f"Volume click {direction} queued (net {pending:+d})")

def apply_pending():
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
        defer_restore(steps, restore_vol)
        return
    write_freq(new)
    logger.info(f"Frequency change: {cur} -> {new} MHz ({steps:+d} clicks)")
    if os.access(ANNOUNCE, os.X_OK):
        try:
            subprocess.run([ANNOUNCE, str(new), str(cur)], timeout=90, check=False)
        except Exception as e:
            logger.warning(f"Announce failed: {e}")
    defer_restore(steps, restore_vol)

def bump_worker():
    while True:
        time.sleep(0.25)
        apply_pending()
        maybe_restore()

# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------

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

    pi_fm_rds only runs while an AirPlay stream is active. A plain open()
    blocks until a reader appears — wedging this daemon until the first
    stream. Retry a non-blocking open briefly, then drop the update if no
    transmitter is listening.
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
    """Yield (itype, code, value) tuples from the shairport-sync metadata pipe."""
    buf = ""
    for raw_line in pipe_file:
        buf += raw_line
        while "</item>" in buf:
            end   = buf.index("</item>") + len("</item>")
            chunk = buf[:end].strip()
            buf   = buf[end:]
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
    global _dacp_id, _dacp_addr, _active_remote, _restore_target, _restore_at, _current_vol
    cfg      = read_config()
    vol_tune = cfg.get("VOL_TUNE", "0").strip() == "1"
    if vol_tune:
        logger.info("Volume-key frequency control enabled (VOL_TUNE=1)")
    else:
        logger.info("Volume-key tuning disabled; use the web UI to change frequency")

    write_rds(ps="AP-PI", rt="AirPlay audio")
    threading.Thread(target=bump_worker,        daemon=True).start()
    threading.Thread(target=_http_server_thread, daemon=True).start()

    title = artist = album = ""
    play_state = "idle"
    last_vol   = None

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
                            _set_ui(play_state="active", title="", artist="", album="")
                            if code == "pbeg":
                                last_vol = None
                                with _pending_lock:
                                    _restore_target = None
                            _restore_at = time.time() + 1.5
                        elif code in ("pend", "pfls"):
                            logger.info("Stream ended/paused")
                            write_rds(ps="AP-PI", rt="AirPlay audio")
                            title = artist = album = ""
                            play_state = "paused"
                            _set_ui(
                                play_state="idle" if code == "pend" else "paused",
                                title="", artist="", album="")
                            _restore_at = 0.0
                        elif code == "pvol":
                            try:
                                vol = float(value.split(",")[0])
                            except (ValueError, IndexError):
                                continue
                            logger.debug(f"pvol {vol} (state={play_state})")
                            _current_vol = vol
                            _set_ui(volume=vol)
                            prev, last_vol = last_vol, vol
                            if not vol_tune:
                                continue
                            if prev is None or vol == prev or play_state == "active":
                                continue
                            if time.time() < _suppress_until:
                                continue
                            queue_click("up" if vol > prev else "down", prev)
                        elif code == "daid":
                            if value and value != _dacp_id:
                                _dacp_id, _dacp_addr = value, None
                        elif code == "acre":
                            if value:
                                _active_remote = value
                        elif code == "mden":
                            if title or artist:
                                write_rds(
                                    ps=safe_ps(artist or title),
                                    rt=safe_rt(title, artist, album),
                                )
                                logger.info(f"RDS updated: '{artist}' / '{title}'")
                    elif itype == "core":
                        if   code == "minm":
                            title  = value; _set_ui(title=value)
                        elif code == "asar":
                            artist = value; _set_ui(artist=value)
                        elif code == "asal":
                            album  = value; _set_ui(album=value)
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
• Tuner web UI:    http://<pi-hostname>:8750/
• Vol-key tuning:  $([ "$VOL_TUNE" = "1" ] && echo "enabled (--vol-tune)" || echo "disabled (pass --vol-tune to enable)")
• Antenna:         Connect a 10-20 cm wire to GPIO4 (pin 7) — see the board
                   diagram below.

How to use:
  1. Ensure your iPhone/Mac is on the same Wi-Fi network as the Pi.
  2. Open Control Center -> AirPlay icon -> select "${AP_NAME}".
  3. Play audio; tune a radio to ${FREQ} MHz.

Tuner web UI (preferred):
  Open http://<pi-hostname>:8750/ in any browser on the same network.
  Shows current frequency, now playing, and play state.
  Use the Up/Down buttons (step: ${STEP} MHz) or type a frequency and tap Set.
  Frequency changes persist through restarts.

RDS:    PS shows artist (8 chars), RT shows "Artist - Title * Album".
LED:    Slow blink = AirPlay ready (waiting). Solid = streaming.

Audio pipeline:
  iOS/Mac -> AirPlay (RAOP) -> shairport-sync -> /run/airplay_audio (FIFO)
          -> airplay2fm.sh -> pi_fm_rds (GPIO4 FM)

Notes:
  - FM transmits only while AirPlay audio is playing (carrier off when idle).
  - Volume-key tuning (--vol-tune): pause playback, press volume up/down to
    shift frequency by ${STEP} MHz. Sender volume is restored on resume.
  - Tuner API: POST http://<pi>:8750/api/up|down|freq (body: freq=XX.X)
               GET  http://<pi>:8750/api/status  returns JSON
  - To override the HTTP port: add HTTP_PORT=XXXX to /etc/default/airplay2fm
    and restart airplay-rds.service.
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
