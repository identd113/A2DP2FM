# A2DP2FM / AirPlay2FM

This repository provides two independent installer scripts that configure a Raspberry Pi to rebroadcast audio as an FM radio transmission using [PiFmRds](https://github.com/ChristopheJacquet/PiFmRds) on GPIO 4.

| Script | Audio source | Discovery |
|--------|-------------|-----------|
| `a2dp2fm.sh` | Bluetooth A2DP (phone/tablet) | Bluetooth pairing |
| `airplay2fm.sh` | AirPlay / RAOP (iPhone, Mac, iPad) | Wi-Fi / Bonjour |

Both scripts share the same FM transmitter hardware (GPIO 4 antenna, PiFmRds), LED feedback system, and RDS support. They cannot run simultaneously — the FM transmitter is exclusive. Use `uninstall.sh` to switch between them or remove either one cleanly.

## Tags

`raspberry-pi` · `bluetooth` · `a2dp` · `airplay` · `raop` · `shairport-sync` · `fm-transmitter` · `rds` · `pi-fm-rds` · `headless-install` · `systemd` · `tts`

## Features

### Shared by both pathways

* **Fully automated provisioning** – Installs all required packages, builds PiFmRds, and configures systemd units in one pass.
* **RDS support** – Mirrors track metadata (Artist, Title, Album) into the RDS PS/RT fields so compatible radios display what's playing.
* **LED status feedback** – Reconfigures the Raspberry Pi ACT LED to provide visual cues for the current state.
* **Offline-friendly boot** – Disables the "wait for network" delay so the Pi completes startup even without network connectivity.
* **Configurable frequency** – Set FM frequency, step size, and min/max range at install time; change them later by editing `/etc/default/bt2fm` or `/etc/default/airplay2fm`.

### Bluetooth (`a2dp2fm.sh`)

* **Headless Bluetooth pairing** – Keeps the adapter powered, discoverable, and pairable after every boot; no screen or keyboard required.
* **A2DP audio pipeline** – Captures audio via BlueALSA and feeds it into PiFmRds.
* **Volume-key frequency control** – Monitors Bluetooth Absolute Volume so the phone's volume buttons shift the FM frequency while playback is paused.
* **TTS station announcements** – Speaks the new frequency over FM after each channel change using `pico2wave` or `espeak-ng`.
* **AVRCP metadata to RDS** – Pushes track info from the connected phone into RDS PS/RT fields.

### AirPlay (`airplay2fm.sh`)

* **Zero-config AirPlay discovery** – Advertises itself on the local network via Avahi/Bonjour; appears instantly in iOS Control Center and macOS audio output.
* **AirPlay audio pipeline** – Uses `shairport-sync` with its pipe backend to feed audio directly into PiFmRds.
* **Metadata to RDS** – Reads shairport-sync's metadata pipe to populate RDS PS/RT fields with the playing track.
* **FM carrier on demand** – The transmitter runs only while audio is playing; carrier is off when idle.

## Hardware requirements

* Raspberry Pi with 40-pin header (tested with Pi 3 / 4 / Zero 2 W).
* **Bluetooth path:** Bluetooth adapter (onboard or USB) supported by BlueZ.
* **AirPlay path:** Wi-Fi connection on the same network as the sending device.
* Short piece of wire (~10–20 cm) connected to GPIO 4 (pin 7) as the FM antenna.
* Nearby FM radio to receive the transmission.

> ⚠️ **Regulatory notice:** Broadcasting FM radio may be regulated in your region. Use low power, short antennas, and comply with local laws.

### GPIO Header Pinout

The 40-pin GPIO header layout is **identical across all supported models**: Pi Zero, Pi Zero W, Pi Zero 2 W, Pi 2B, Pi 3A+/3B/3B+, Pi 4B, Pi 5, and Pi 400. The only physical difference is that Pi Zero (original and W) ships with unpopulated header holes — you need to solder a 2×20 pin header before use.

> The original Pi 1 Model A and B used a 26-pin header (a subset of this layout). Those boards are not supported.

The standard two-column layout, with pin numbers in the centre:

```
        ┌────── USB / Ethernet end ──────┐
        │                                │
   3V3  (1)  (2)  5V
 GPIO2  (3)  (4)  5V
 GPIO3  (5)  (6)  GND
 GPIO4  (7)  (8)  GPIO14     ← (7) FM ANTENNA — attach wire here
   GND  (9) (10)  GPIO15
GPIO17 (11) (12)  GPIO18
GPIO27 (13) (14)  GND
GPIO22 (15) (16)  GPIO23
   3V3 (17) (18)  GPIO24
GPIO10 (19) (20)  GND
 GPIO9 (21) (22)  GPIO25
GPIO11 (23) (24)  GPIO8
   GND (25) (26)  GPIO7
 GPIO0 (27) (28)  GPIO1
 GPIO5 (29) (30)  GND
 GPIO6 (31) (32)  GPIO12
GPIO13 (33) (34)  GND
GPIO19 (35) (36)  GPIO16
GPIO26 (37) (38)  GPIO20
   GND (39) (40)  GPIO21
        │                                │
        └──────── SD card end ───────────┘
```

Pin 1 (3V3) is the corner nearest the SD card slot on most models. On Pi Zero boards the SD card is directly adjacent to pin 1 at the same end of the header.

**Pins used by this project:**

| Physical pin | BCM GPIO | Role |
|-------------|----------|------|
| **7** | **GPIO4** | FM transmit output — connect antenna wire |
| 6, 9, 14, 20, 25 … | GND | Ground (any GND pin works) |

The ACT LED is an on-board LED controlled via `/sys/class/leds/led0`; it is not a header pin.

### Antenna Wiring

Connect a 10–20 cm insulated wire to **physical pin 7** (GPIO4). Ground is provided through the Pi's internal circuits; a separate ground wire is not required for basic operation, but connecting one to any GND pin can improve signal quality.

## Quick setup

### Bluetooth

1. Attach a 10–20 cm wire to GPIO 4 (pin 7).
2. Boot the Pi headless with network access.
3. Run the installer: `sudo bash a2dp2fm.sh --freq 87.9`
4. Pair your phone with the Pi (name: `raspberrypi`), enable Media Audio.
5. Tune a radio to 87.9 MHz and start playing audio.

### AirPlay

1. Attach a 10–20 cm wire to GPIO 4 (pin 7).
2. Boot the Pi on the same Wi-Fi network as your iPhone or Mac.
3. Run the installer: `sudo bash airplay2fm.sh --freq 87.9 --name "My Pi Radio"`
4. Open iOS Control Center → AirPlay → select **My Pi Radio**.
5. Tune a radio to 87.9 MHz and start playing audio.

> Both paths use the same antenna and GPIO 4. Do not run both installers and then start both services — they will fight over the FM transmitter.

## Software prerequisites

Both scripts target Raspberry Pi OS (Debian-based). They require:

* `sudo` access (the scripts exit if not run as root).
* Network connectivity during install for `apt-get` and GitHub clones.
* Python 3 (installed automatically).

All required packages are installed automatically.

**Testing in a container (offline/CI):**

```bash
A2DP2FM_STUB_LOG_DIR=$(mktemp -d) \
  PATH="$(pwd)/tests/bin:$PATH" \
  A2DP2FM_GIT_CLONE_CMD="$(pwd)/tests/bin/git-clone-stub" \
  SUDO_USER=pi sudo ./a2dp2fm.sh --freq 99.1
```

### OS compatibility

Both installers detect the Raspberry Pi OS/Debian codename and are validated on **Trixie**, **Bookworm**, and **Bullseye**. Both `/boot/config.txt` and `/boot/firmware/config.txt` are updated, covering all recent boot layouts.

## Installation

### Bluetooth (`a2dp2fm.sh`)

```bash
sudo bash a2dp2fm.sh [--freq 87.9] [--step 0.2] [--min 87.7] [--max 107.9]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--freq` | `87.9` | FM frequency (MHz) at boot |
| `--step` | `0.2` | Step size (MHz) for volume-key frequency changes |
| `--min` | `87.7` | Lower frequency bound (MHz) |
| `--max` | `107.9` | Upper frequency bound (MHz) |
| `--dry-run` | — | Preview what would be installed |
| `--verbose` | — | Extra logging |

What the installer does:

* Installs Bluetooth, audio, and PiFmRds build dependencies. Prefers a packaged BlueALSA (`bluealsa`/`bluez-alsa`) and falls back to building [Arkq/bluez-alsa](https://github.com/Arkq/bluez-alsa) from source.
* Clones and builds PiFmRds into `$HOME/PiFmRds`.
* Writes runtime defaults to `/etc/default/bt2fm`.
* Deploys helper scripts under `/usr/local/bin/` and `/usr/local/sbin/`.
* Creates and enables systemd units for all services.
* Configures the ACT LED for software control.

### AirPlay (`airplay2fm.sh`)

```bash
sudo bash airplay2fm.sh [--freq 87.9] [--name "Pi FM Radio"] [--step 0.2] [--min 87.7] [--max 107.9]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--freq` | `87.9` | FM frequency (MHz) |
| `--name` | `Pi FM Radio` | AirPlay device name shown in iOS/macOS |
| `--step` | `0.2` | Step size (for future use) |
| `--min` / `--max` | `87.7` / `107.9` | Frequency bounds |
| `--dry-run` | — | Preview what would be installed |
| `--verbose` | — | Extra logging |

What the installer does:

* Installs Avahi, OpenSSL, ALSA, and PiFmRds build dependencies. Uses the apt `shairport-sync` package when available; builds from source ([mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync)) if the package lacks pipe-backend support.
* Writes `/etc/shairport-sync.conf` configuring the pipe audio backend and metadata pipe.
* Registers `/etc/tmpfiles.d/airplay2fm.conf` so systemd recreates the FIFOs at every boot.
* Clones and builds PiFmRds (skipped if already present from a Bluetooth install).
* Writes runtime defaults to `/etc/default/airplay2fm`.
* Deploys helper scripts under `/usr/local/bin/`.
* Creates and enables systemd units for all services.

## Usage

### Bluetooth

1. Pair your phone with the Pi (default hostname `raspberrypi`). Ensure **Media Audio** (A2DP) is enabled.
2. Tune a nearby FM radio to the configured frequency.
3. Start playing audio on the phone.
4. Press volume **down** or **up** while playback is **paused** to shift the FM frequency by the configured step. During playback, volume buttons work normally.
5. Each frequency change flashes the LED three times and plays a TTS announcement of the new frequency.
6. RDS displays Artist / Title / Album on compatible radios.

### AirPlay

1. Ensure your iPhone, iPad, or Mac is on the same Wi-Fi network as the Pi.
2. Open **Control Center → AirPlay** and select your Pi's name.
3. Tune a nearby FM radio to the configured frequency.
4. Start playing audio — the FM carrier comes on automatically.
5. Pause or stop playback to silence the transmitter; RDS resets to the device name.
6. To change frequency after install, edit `/etc/default/airplay2fm` and restart services (see Configuration below).

### LED behavior

| State | Bluetooth | AirPlay |
|-------|-----------|---------|
| Slow blink | Discoverable / pairing mode | shairport-sync running, waiting for stream |
| Double blink ~2 s | Device connected, not streaming | — |
| Solid on | Streaming active | Streaming active |
| Three quick flashes | Frequency changed (Bluetooth only) | — |

## Service management

### Bluetooth services

| Service | Role |
|---------|------|
| `bt-setup.service` | Powers on adapter, sets discoverable/pairable at boot |
| `bt-agent.service` | Headless Bluetooth pairing agent |
| `bt2fm.service` | A2DP audio → PiFmRds pipeline |
| `bt-volume-freqd.service` | Volume-key frequency controller |
| `avrcp-rds.service` | AVRCP metadata → RDS fields |
| `led-statusd.service` | ACT LED status for Bluetooth state |
| `bluealsa.service` | BlueALSA daemon (A2DP capture) |

### AirPlay services

| Service | Role |
|---------|------|
| `shairport-sync.service` | AirPlay receiver; writes raw PCM to audio FIFO |
| `airplay2fm.service` | Reads audio FIFO → PiFmRds pipeline |
| `airplay-rds.service` | shairport-sync metadata → RDS fields |
| `led-airplay-statusd.service` | ACT LED status for AirPlay state |

Use `systemctl status <service>` or `sudo journalctl -u <service>` to inspect any service.

## Uninstallation

A dedicated script detects what is installed and offers interactive removal:

```bash
sudo bash uninstall.sh
```

It scans for both installations, displays their current state, then asks what to remove:

```
  1) Uninstall Bluetooth A2DP -> FM  (a2dp2fm)
  2) Uninstall AirPlay -> FM         (airplay2fm)
  3) Uninstall both
  q) Quit
```

**Non-interactive flags:**

```bash
sudo bash uninstall.sh --bt             # Bluetooth only
sudo bash uninstall.sh --airplay        # AirPlay only
sudo bash uninstall.sh --all            # both
sudo bash uninstall.sh --all --yes      # both, skip confirmation
```

The script handles shared resources (PiFmRds, `ledctl.sh`, ACT LED dtparam config) intelligently — they are removed only when the last remaining install is being uninstalled.

## Configuration

### Bluetooth — `/etc/default/bt2fm`

```ini
FREQ=87.9
STEP=0.2
FMIN=87.7
FMAX=107.9
```

After editing, restart affected services:

```bash
sudo systemctl restart bt2fm.service bt-volume-freqd.service
```

### AirPlay — `/etc/default/airplay2fm`

```ini
FREQ=87.9
STEP=0.2
FMIN=87.7
FMAX=107.9
AP_NAME=Pi FM Radio
```

To change the FM frequency:

```bash
sudo sed -i 's/^FREQ=.*/FREQ=88.5/' /etc/default/airplay2fm
sudo systemctl restart airplay2fm.service
```

To rename the AirPlay device (also requires updating `/etc/shairport-sync.conf`):

```bash
sudo sed -i 's/^AP_NAME=.*/AP_NAME=New Name/' /etc/default/airplay2fm
sudo sed -i 's/name = .*/name = "New Name";/' /etc/shairport-sync.conf
sudo systemctl restart shairport-sync.service
```

## Troubleshooting

### Shared

* **No FM audio** – Verify the antenna wire is on GPIO 4 (pin 7) and that PiFmRds is running (`pgrep pi_fm_rds`). Check `sudo journalctl -u <pipeline service>` for errors.
* **LED does not respond** – Reboot once after installation to apply the ACT LED dtparam change. Test manually: `sudo /usr/local/bin/ledctl.sh on`.

### Bluetooth

* **Phone cannot connect** – Check `bt-setup.service` is active and the Pi is discoverable (`bluetoothctl show`). Remove stale pairings: `bluetoothctl remove <MAC>` then re-pair.
* **Frequency changes do not trigger** – Confirm your phone supports Bluetooth Absolute Volume. Monitor: `sudo journalctl -u bt-volume-freqd.service`.
* **RDS text missing** – Verify your radio supports RDS. Check `/run/rds_ctl` activity and `sudo journalctl -u avrcp-rds.service`.
* **Audio stutter** – Edit `/usr/local/bin/bt2fm.sh` and lower `arecord` to `-r 32000`.
* **BlueALSA diagnostics** – Run `bluealsactl pcm-list` to inspect PCM devices. The daemon binary is `bluealsad` on newer installs.

### AirPlay

* **Device does not appear in AirPlay list** – Confirm `shairport-sync.service` is active and that Avahi is running (`systemctl status avahi-daemon`). Both the Pi and the sending device must be on the same Wi-Fi network.
* **Audio connects but no FM output** – Confirm `airplay2fm.service` is active. The audio FIFO `/run/airplay_audio` must exist; check with `ls -la /run/airplay_audio`. If missing, `sudo systemctl restart airplay2fm.service` recreates it.
* **RDS not updating with track info** – Check `sudo journalctl -u airplay-rds.service`. Confirm the metadata FIFO `/run/airplay_metadata` exists. shairport-sync must be configured with `metadata.enabled = "yes"` in `/etc/shairport-sync.conf`.
* **shairport-sync fails to start** – Run `shairport-sync -v` for a config parse error. Ensure `/etc/shairport-sync.conf` is valid and the pipe paths exist.
* **FIFOs missing after reboot** – Run `sudo systemd-tmpfiles --create /etc/tmpfiles.d/airplay2fm.conf` to recreate them immediately. If the file is missing, re-run `sudo bash airplay2fm.sh` (it is idempotent).

## Manual cleanup

If the `uninstall.sh` script is unavailable, stop and remove services manually.

**Bluetooth:**

```bash
sudo systemctl disable --now bt2fm.service bt-volume-freqd.service \
  avrcp-rds.service led-statusd.service bt-setup.service bt-agent.service
sudo rm -f /usr/local/bin/{bt2fm.sh,fm_announce.sh,bt-volume-freqd.sh,avrcp_rds.py,led-statusd.sh}
sudo rm -f /usr/local/sbin/{bt-agent-wrapper.sh,bt-setup-bluetooth.sh}
sudo rm -f /etc/default/bt2fm /run/rds_ctl
sudo rm -f /etc/systemd/system/{bt2fm,bt-volume-freqd,avrcp-rds,led-statusd,bt-agent,bt-setup,bluealsa}.service
sudo systemctl daemon-reload
```

**AirPlay:**

```bash
sudo systemctl disable --now airplay2fm.service airplay-rds.service \
  led-airplay-statusd.service shairport-sync.service
sudo rm -f /usr/local/bin/{airplay2fm.sh,airplay-rds.py,led-airplay-statusd.sh}
sudo rm -f /etc/default/airplay2fm /etc/tmpfiles.d/airplay2fm.conf
sudo rm -f /run/airplay_audio /run/airplay_metadata
sudo sed -i '/^snd-aloop$/d' /etc/modules
sudo rm -f /etc/systemd/system/{airplay2fm,airplay-rds,led-airplay-statusd}.service
sudo systemctl daemon-reload
```

**Shared (after removing both):**

```bash
sudo rm -f /usr/local/bin/ledctl.sh /run/rds_ctl
sudo rm -rf ~/PiFmRds
# Remove ACT LED overrides and reboot
sudo sed -i '/dtparam=act_led_trigger=none/d;/dtparam=act_led_activelow=off/d' \
  /boot/firmware/config.txt /boot/config.txt 2>/dev/null || true
sudo reboot
```

## License

This repository inherits the license of the installer scripts. Review each script header and upstream projects (PiFmRds, shairport-sync, bluez-alsa) for their respective licenses.
