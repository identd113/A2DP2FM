#!/usr/bin/env bash
# install_bt_fm_rds_with_led.sh
# Headless Bluetooth A2DP -> PiFmRds (FM on GPIO4) + Volume-key freq control + TTS announce + AVRCP->RDS + LED status
# Tags: raspberry-pi, bluetooth, a2dp, fm-transmitter, rds, pi-fm-rds, headless-install, systemd, tts
# Usage: sudo bash install_bt_fm_rds_with_led.sh [--freq 87.9] [--step 0.2] [--min 87.7] [--max 107.9]

set -euo pipefail

# ---- Defaults (override with flags) ----
FREQ="87.9"; STEP="0.2"; FMIN="87.7"; FMAX="107.9"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --freq) FREQ="$2"; shift 2;;
    --step) STEP="$2"; shift 2;;
    --min)  FMIN="$2"; shift 2;;
    --max)  FMAX="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

PI_USER="${SUDO_USER:-pi}"
PI_HOME="$(getent passwd "$PI_USER" | cut -d: -f6 2>/dev/null || true)"
if [[ -z "${PI_HOME:-}" ]]; then
  PI_HOME="/home/$PI_USER"
fi
PIFM_DIR="$PI_HOME/PiFmRds"
RDSCTL="/run/rds_ctl"

echo "==> Apt install (Bluetooth, audio, PiFmRds deps, TTS, tools)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git build-essential libsndfile1-dev python3-dbus python3-gi dbus \
                   bluez bluez-tools bluez-alsa alsa-utils sox jq libttspico-utils espeak-ng gawk

echo "==> Skip boot wait for network (offline-friendly)"
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_boot_wait 0 || true
else
  systemctl disable --now systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true
  systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true
  systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
  systemctl disable --now dhcpcd-wait-online.service 2>/dev/null || true
  systemctl mask dhcpcd-wait-online.service 2>/dev/null || true
fi

echo "==> Headless BT setup (discoverable + pairable on boot)"
cat >/etc/systemd/system/bt-setup.service <<'EOF'
[Unit]
Description=Bluetooth adapter headless setup (power on, agent, discoverable)
After=bluetooth.service
Requires=bluetooth.service
[Service]
Type=oneshot
ExecStart=/usr/bin/bash -lc 'bluetoothctl <<BCTL
agent on
default-agent
power on
discoverable on
pairable on
BCTL'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable bt-setup.service
systemctl start bt-setup.service || true

echo "==> Clone & build PiFmRds"
if [[ ! -d "$PIFM_DIR" ]]; then
  sudo -u "$PI_USER" git clone https://github.com/ChristopheJacquet/PiFmRds.git "$PIFM_DIR"
fi
pushd "$PIFM_DIR/src" >/dev/null
sudo -u "$PI_USER" make clean || true
sudo -u "$PI_USER" make
popd >/dev/null

echo "==> Runtime config: /etc/default/bt2fm"
cat >/etc/default/bt2fm <<EOF
FREQ=$FREQ
STEP=$STEP
FMIN=$FMIN
FMAX=$FMAX
PI_USER="$PI_USER"
PI_HOME="$PI_HOME"
EOF

echo "==> Prepare RDS control FIFO: $RDSCTL"
mkdir -p /run
rm -f "$RDSCTL" || true
mkfifo "$RDSCTL"
chown "$PI_USER":"$PI_USER" "$RDSCTL" || true

echo "==> Bluetooth->FM pipeline (PiFmRds, stdin audio, RDS FIFO)"
cat >/usr/local/bin/bt2fm.sh <<'BTFM'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/bt2fm
USER_NAME="${PI_USER:-$(id -un)}"
USER_HOME="${PI_HOME:-${HOME:-}}"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 2>/dev/null || true)"
fi
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="/home/$USER_NAME"
fi
PIFM="$USER_HOME/PiFmRds/src/pi_fm_rds"
[ -x "$PIFM" ] || PIFM="$HOME/PiFmRds/src/pi_fm_rds"
RDSCTL="/run/rds_ctl"; [ -p "$RDSCTL" ] || mkfifo "$RDSCTL"
# Wait for A2DP capture device (BlueALSA)
for i in {1..120}; do arecord -L | grep -q bluealsa && break; sleep 2; done
arecord -L | grep -q bluealsa || exit 0
CURF="$(grep -E '^FREQ=' /etc/default/bt2fm | cut -d= -f2)"
PSDEF="BT-PI"; RTDEF="Bluetooth audio"
arecord -D bluealsa:PROFILE=a2dp -f S16_LE -r 44100 -c 2 \
  | sudo "$PIFM" -freq "$CURF" -ps "$PSDEF" -rt "$RTDEF" -ctl "$RDSCTL" -audio -
BTFM
chmod +x /usr/local/bin/bt2fm.sh
chown "$PI_USER":"$PI_USER" /usr/local/bin/bt2fm.sh

cat >/etc/systemd/system/bt2fm.service <<EOF
[Unit]
Description=Bluetooth A2DP -> PiFmRds (FM on GPIO4)
After=bluetooth.service bt-setup.service
Wants=bluetooth.service
[Service]
User=$PI_USER
EnvironmentFile=/etc/default/bt2fm
ExecStart=/usr/local/bin/bt2fm.sh
Restart=always
RestartSec=2
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

echo "==> TTS announcer (speaks station, then resumes stream)"
cat >/usr/local/bin/fm_announce.sh <<'FANN'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/bt2fm
USER_NAME="${PI_USER:-$(id -un)}"
USER_HOME="${PI_HOME:-${HOME:-}}"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6 2>/dev/null || true)"
fi
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="/home/$USER_NAME"
fi
PIFM="$USER_HOME/PiFmRds/src/pi_fm_rds"
[ -x "$PIFM" ] || PIFM="$HOME/PiFmRds/src/pi_fm_rds"
TARGET_FREQ="${1:-$FREQ}"
TMPWAV="/run/fm_announce.wav"; mkdir -p /run
say(){ if command -v pico2wave >/dev/null; then pico2wave -l en-US -w "$TMPWAV" "$1"; else espeak-ng -v en-us -s 160 -w "$TMPWAV" "$1"; fi; }
fmt(){ awk -v f="$1" 'BEGIN{printf "%.1f", f}'; }
# LED flash before announcement (if ledctl exists)
command -v /usr/local/bin/ledctl.sh >/dev/null 2>&1 && /usr/local/bin/ledctl.sh flash3 || true
MSG="Broadcasting at $(fmt "$TARGET_FREQ") megahertz."; say "$MSG"
systemctl stop bt2fm.service >/dev/null 2>&1 || true
sudo "$PIFM" -freq "$TARGET_FREQ" -audio "$TMPWAV"
sleep 0.5
systemctl start bt2fm.service >/dev/null 2>&1 || true
FANN
chmod +x /usr/local/bin/fm_announce.sh
chown "$PI_USER":"$PI_USER" /usr/local/bin/fm_announce.sh

echo "==> Volume-key frequency daemon"
cat >/usr/local/bin/bt-volume-freqd.sh <<'BVOLD'
#!/usr/bin/env bash
set -euo pipefail
source /etc/default/bt2fm
STATE="/run/bt2fm.volume"; PLAYSTATE="/run/bt2fm.playstate"
mkdir -p /run
echo "-1" > "$STATE"
echo "idle" > "$PLAYSTATE"
read_current_freq(){ grep -E '^FREQ=' /etc/default/bt2fm | cut -d= -f2; }
write_freq(){ sed -i "s/^FREQ=.*/FREQ=$1/" /etc/default/bt2fm; }
clamp(){ awk -v v="$1" -v lo="$FMIN" -v hi="$FMAX" 'BEGIN{ if(v<lo)v=lo; if(v>hi)v=hi; printf "%.1f", v }'; }
bump(){
  local dir="$1" cur new; cur="$(read_current_freq)"
  if [[ "$dir" == up ]]; then new=$(awk -v f="$cur" -v s="$STEP" 'BEGIN{printf "%.3f", f+s}'); else new=$(awk -v f="$cur" -v s="$STEP" 'BEGIN{printf "%.3f", f-s}'); fi
  new="$(clamp "$new")"
  if [[ "$new" != "$cur" ]]; then
    write_freq "$new"
    # Flash LED right away if available
    command -v /usr/local/bin/ledctl.sh >/dev/null 2>&1 && /usr/local/bin/ledctl.sh flash3 || true
    /usr/local/bin/fm_announce.sh "$new"
  fi
}
dbus-monitor --system "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'" \
| gawk '
  /string "org.bluez.MediaTransport1"/ { in_t=1; field=""; next }
  in_t && /string "Volume"/ { field="volume"; next }
  in_t && /string "State"/ { field="state"; next }
  in_t && /variant/ {
    if (field=="volume" && match($0, /(uint(8|16)) +([0-9]+)/, m)) { print "VOL", m[3]; fflush() }
    else if (field=="state" && match($0, /string \"([^\"]+)\"/, m)) { print "STATE", m[1]; fflush() }
    field=""
    next
  }
  /^signal/ { in_t=0; field=""; next }
' \
| while read -r KIND VALUE; do
    case "$KIND" in
      VOL)
        [[ -z "${VALUE:-}" ]] && continue
        last="$(cat "$STATE" 2>/dev/null || echo -1)"
        echo "$VALUE" > "$STATE"
        [[ "$last" -lt 0 ]] && continue
        play_state="$(cat "$PLAYSTATE" 2>/dev/null || echo idle)"
        [[ "$play_state" == "active" ]] && continue
        if   [[ "$VALUE" -gt "$last" ]]; then bump up
        elif [[ "$VALUE" -lt "$last" ]]; then bump down
        fi
        ;;
      STATE)
        [[ -z "${VALUE:-}" ]] && continue
        echo "$VALUE" > "$PLAYSTATE"
        # Reset baseline on any state change so the next volume event establishes direction
        echo "-1" > "$STATE"
        ;;
    esac
  done
BVOLD
chmod +x /usr/local/bin/bt-volume-freqd.sh
chown "$PI_USER":"$PI_USER" /usr/local/bin/bt-volume-freqd.sh

cat >/etc/systemd/system/bt-volume-freqd.service <<'VOLSRV'
[Unit]
Description=Change FM frequency using phone volume keys (BlueZ Absolute Volume)
After=bluetooth.service bt-setup.service
Wants=bluetooth.service
[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/bt2fm
ExecStart=/usr/local/bin/bt-volume-freqd.sh
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
VOLSRV

echo "==> AVRCP -> RDS (PS/RT) daemon"
cat >/usr/local/bin/avrcp_rds.py <<'PYAV'
#!/usr/bin/env python3
import dbus, gi, re
gi.require_version('GLib', '2.0')
from gi.repository import GLib
RDSCTL="/run/rds_ctl"
def safe_ps(s):
  s=(s or "").strip()
  if not s: return "BT-PI"
  s=re.sub(r"[^A-Za-z0-9 -]","",s)
  return (s[:8] or "BT-PI")
def safe_rt(title,artist,album):
  parts=[p for p in [artist,title] if p]
  txt=" - ".join(parts) if parts else (title or artist or "Bluetooth audio")
  if album and len(txt)<48: txt += " \u2022 "+album
  txt=re.sub(r"[\r\n\t]+"," ",txt).strip()
  return txt[:64]
def write_rds(ps=None, rt=None):
  try:
    with open(RDSCTL,"w") as f:
      if ps is not None: f.write(f"PS {ps}\n")
      if rt is not None: f.write(f"RT {rt}\n")
  except Exception: pass
def on_props_changed(interface, changed, invalidated, path):
  if interface!="org.bluez.MediaPlayer1": return
  if "Track" in changed:
    md=changed["Track"]
    title=str(md.get("Title",""))
    artist=md.get("Artist","")
    if isinstance(artist,(list,tuple)): artist=", ".join(str(a) for a in artist)
    else: artist=str(artist)
    album=str(md.get("Album",""))
    write_rds(ps=safe_ps(artist or title), rt=safe_rt(title,artist,album))
def main():
  bus=dbus.SystemBus()
  bus.add_signal_receiver(on_props_changed, "PropertiesChanged","org.freedesktop.DBus.Properties", path_keyword="path")
  write_rds(ps="BT-PI", rt="Bluetooth audio")
  GLib.MainLoop().run()
if __name__=="__main__": main()
PYAV
chmod +x /usr/local/bin/avrcp_rds.py
chown "$PI_USER":"$PI_USER" /usr/local/bin/avrcp_rds.py

cat >/etc/systemd/system/avrcp-rds.service <<'AVSRV'
[Unit]
Description=Update RDS PS/RT from Bluetooth AVRCP track metadata
After=bluetooth.service bt2fm.service
Wants=bluetooth.service
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/avrcp_rds.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
AVSRV

echo "==> Take over ACT LED (software control) + LED helpers/services"
CFG_C1="/boot/config.txt"; CFG_C2="/boot/firmware/config.txt"
for CFG in "$CFG_C1" "$CFG_C2"; do
  [[ -f "$CFG" ]] || continue
  sed -i '/^dtparam=act_led_trigger=/d' "$CFG" || true
  sed -i '/^dtparam=act_led_activelow=/d' "$CFG" || true
  echo 'dtparam=act_led_trigger=none' >> "$CFG"
  echo 'dtparam=act_led_activelow=off' >> "$CFG"
done

cat >/usr/local/bin/ledctl.sh <<'LEDCTL'
#!/usr/bin/env bash
set -euo pipefail
LED="/sys/class/leds/led0"; TR="$LED/trigger"; BR="$LED/brightness"
set_manual(){ [[ -w "$TR" ]] && echo none | sudo tee "$TR" >/dev/null || true; }
on(){ set_manual; echo 1 | sudo tee "$BR" >/dev/null; }
off(){ set_manual; echo 0 | sudo tee "$BR" >/dev/null; }
blink_for(){ local d="$1" p="$2"; set_manual; local end=$(( $(date +%s%3N)+d ))
  while (( $(date +%s%3N) < end )); do echo 1|sudo tee "$BR" >/dev/null; sleep "$(awk -v p="$p" 'BEGIN{printf "%.3f", p/2000}')"
    echo 0|sudo tee "$BR" >/dev/null; sleep "$(awk -v p="$p" 'BEGIN{printf "%.3f", p/2000}')"; done; }
slow(){ blink_for 2000 1000; }  # pairing
fast(){ blink_for 600 200; }
double(){ on; sleep 0.12; off; sleep 0.12; on; sleep 0.12; off; }
flash3(){ for i in 1 2 3; do blink_for 180 180; sleep 0.06; done; }
case "${1:-}" in on|off|slow|fast|double|flash3) "$@";; *) echo "Usage: ledctl.sh {on|off|slow|double|flash3}";; esac
LEDCTL
chmod +x /usr/local/bin/ledctl.sh

cat >/usr/local/bin/led-statusd.sh <<'LEDD'
#!/usr/bin/env bash
set -euo pipefail
is_discoverable(){ bluetoothctl show 2>/dev/null | awk '/Discoverable:/{print $2}' | grep -q yes; }
any_connected(){ bluetoothctl paired-devices | awk '{print $2}' | while read -r d; do
  if bluetoothctl info "$d" 2>/dev/null | awk '/Connected:/{print $2}' | grep -q yes; then echo yes; exit 0; fi; done; exit 1; }
bluealsa_ready(){ arecord -L 2>/dev/null | grep -q bluealsa; }
streaming(){ systemctl is-active --quiet bt2fm.service && bluealsa_ready; }
while true; do
  if streaming; then /usr/local/bin/ledctl.sh on; sleep 1
  else
    if any_connected; then /usr/local/bin/ledctl.sh double; sleep 2
    elif is_discoverable; then /usr/local/bin/ledctl.sh slow; sleep 1
    else /usr/local/bin/ledctl.sh off; sleep 1
    fi
  fi
done
LEDD
chmod +x /usr/local/bin/led-statusd.sh

cat >/etc/systemd/system/led-statusd.service <<'LEDSVC'
[Unit]
Description=On-board LED status (pairing/connected/streaming)
After=bluetooth.service bt-setup.service
Wants=bluetooth.service
[Service]
Type=simple
ExecStart=/usr/local/bin/led-statusd.sh
Restart=always
RestartSec=1
[Install]
WantedBy=multi-user.target
LEDSVC

echo "==> Enable & start services"
systemctl daemon-reload
systemctl enable bt2fm.service bt-volume-freqd.service avrcp-rds.service led-statusd.service bt-setup.service
systemctl restart bt2fm.service bt-volume-freqd.service avrcp-rds.service led-statusd.service bt-setup.service || true

cat <<DONE

================================================================================
INSTALL COMPLETE (with LED)

• Default frequency: $FREQ MHz   step: $STEP MHz   range: $FMIN - $FMAX MHz
• Antenna: connect a short 10–20 cm wire to GPIO4 (pin 7). Keep it short to stay polite.
• Pair your phone with the Pi (name: 'raspberrypi'), ensure Media audio is enabled.
• Play audio; tune a radio to $FREQ MHz.
• Use phone volume keys while playback is paused to change frequency (playing = normal volume). Pi flashes LED (3 quick) and announces new station.
• RDS shows track info (PS=short artist/station, RT="Artist – Title • Album").

LED behavior:
  - Pairing/discoverable: slow blink
  - Connected (idle):     double blink every ~2s
  - Streaming:            solid on
  - Frequency change:     3 quick flashes

Notes:
  - One reboot may be required for full LED control (we set dtparam=act_led_trigger=none).
  - If stutter: edit /usr/local/bin/bt2fm.sh and lower arecord to -r 32000.
  - Services:   sudo systemctl status bt2fm bt-volume-freqd avrcp-rds led-statusd
  - Change defaults later in /etc/default/bt2fm and restart services.

Enjoy!
================================================================================
DONE
