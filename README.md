# A2DP to FM with PiFmRds

This repository contains a single installer script, `a2dp2fm.sh`, that configures a Raspberry Pi to accept Bluetooth A2DP audio and rebroadcast it as an FM radio transmission using [PiFmRds](https://github.com/ChristopheJacquet/PiFmRds). The script also wires together supporting services for AVRCP metadata, a TTS station announcement, frequency control through phone volume buttons, and LED status feedback.

The installer is intended for a headless Raspberry Pi (no desktop environment) with a Bluetooth adapter and speaker/headphone audio disabled. After installation you can pair a phone with the Pi, stream audio over Bluetooth, and receive the broadcast on a nearby FM radio tuned to your configured frequency.

## Tags

`raspberry-pi` · `bluetooth` · `a2dp` · `fm-transmitter` · `rds` · `pi-fm-rds` · `headless-install` · `systemd` · `tts`

## Features

* **Fully automated provisioning** – Installs all required packages, clones PiFmRds, builds the transmitter, and configures systemd units in one pass.
* **Bluetooth setup for headless pairing** – Ensures the adapter is powered, discoverable, and pairable after every boot.
* **A2DP audio to FM broadcast pipeline** – Captures audio via BlueALSA and feeds it directly into PiFmRds running on GPIO 4.
* **Text-to-speech station announcements** – Uses `pico2wave` (or `espeak-ng` fallback) to speak the tuned frequency when it changes.
* **Volume-based frequency changes** – Monitors Bluetooth absolute volume so the phone volume keys bump the FM frequency by a configurable step while playback is paused (during playback they continue adjusting volume normally).
* **AVRCP metadata to RDS** – Mirrors track metadata (Artist, Title, Album) into the RDS PS/RT fields.
* **LED status feedback** – Reconfigures the Raspberry Pi ACT LED and provides visual cues for pairing, connection, streaming, and frequency adjustments.
* **Offline-friendly boot** – Disables the "wait for network" delay so the Pi completes startup even without network connectivity.

## Hardware requirements

* Raspberry Pi with 40-pin header (tested with Pi 3/4/Zero 2 W).
* Bluetooth adapter (onboard or USB) supported by BlueZ.
* Access to the ACT LED (on-board green LED) if LED feedback is desired.
* Short piece of wire (~10–20 cm) connected to GPIO 4 (pin 7) to act as the FM antenna.
* Nearby FM radio to receive the transmission.

> ⚠️ **Regulatory notice:** Broadcasting FM radio may be regulated in your region. Use low power, short antennas, and comply with local laws.

## Software prerequisites

The script targets Raspberry Pi OS (Debian-based). It expects:

* `sudo` access to run as root (the script exits if not run with `sudo`).
* Network connectivity for `apt-get` and cloning PiFmRds from GitHub during installation (the system will no longer wait for a network connection on subsequent boots).
* Python 3 with GObject introspection libraries (installed automatically).

All required packages are installed automatically via `apt-get` when you run the installer.

If you want to work with the Python helper (`avrcp_rds.py`) outside of the
installer flow, the Python dependencies are listed in `requirements.txt`. The
modules are shipped by Raspberry Pi OS via `apt-get` (`python3-dbus` and
`python3-gi`), but the requirement file is provided for tooling that inspects
Python dependencies.

## Installation

1. **Run directly with `curl` (optional).** For a one-liner install on a freshly
   provisioned Pi you can stream the script straight into `bash`. The commands
   below use this repository as published by GitHub user `identd113`:

   ```bash
   curl -fsSL "https://raw.githubusercontent.com/identd113/A2DP2FM/main/a2dp2fm.sh" \
     | sudo bash -s --
   ```

   Append any CLI flags after the `--` if you want to override defaults, e.g.:

   ```bash
   curl -fsSL "https://raw.githubusercontent.com/identd113/A2DP2FM/main/a2dp2fm.sh" \
     | sudo bash -s -- --freq 88.1 --step 0.1
   ```

   This approach is handy for quick installs, while cloning the repo still works
   for local edits and `git pull` updates.

2. **Or clone this repository** on the Raspberry Pi (or download the script) and
   move into the directory:

   ```bash
   git clone "https://github.com/identd113/A2DP2FM.git"
   cd A2DP2FM
   ```

3. **Run the installer as root**. You can customize default frequency parameters via flags:

   ```bash
   sudo bash a2dp2fm.sh [--freq 87.9] [--step 0.2] [--min 87.7] [--max 107.9]
   ```

   * `--freq` – Default FM frequency (MHz) used at boot.
   * `--step` – Frequency step size (MHz) applied when changing stations with volume keys.
   * `--min` / `--max` – Lower/upper bounds (MHz) enforced when adjusting frequency.

4. **Wait for the script to finish.** It performs the following actions:

   * Installs Bluetooth, audio, PiFmRds build dependencies, speech synthesis utilities, and helper tools via `apt-get`.
   * Creates a `bt-setup.service` systemd unit that powers on the adapter, enables the agent, and sets the controller to be discoverable/pairable on boot.
   * Clones PiFmRds into `/home/${SUDO_USER:-pi}/PiFmRds` (the invoking sudo user's home) and builds `pi_fm_rds`.
   * Stores runtime defaults in `/etc/default/bt2fm` using the values you provided.
   * Creates `/run/rds_ctl` FIFO for RDS commands.
   * Installs helper scripts under `/usr/local/bin/`:
     * `bt2fm.sh` – Streams A2DP audio into PiFmRds.
     * `fm_announce.sh` – Performs TTS announcements of the tuned frequency.
     * `bt-volume-freqd.sh` – Listens for BlueZ volume changes to adjust frequency.
     * `avrcp_rds.py` – Publishes AVRCP metadata to the RDS FIFO.
     * `ledctl.sh` and `led-statusd.sh` – Manage ACT LED behavior.
   * Registers corresponding systemd units (`bt2fm.service`, `bt-volume-freqd.service`, `avrcp-rds.service`, `led-statusd.service`) and reloads daemon state.
   * Updates `/boot/config.txt` (and `/boot/firmware/config.txt` if present) to disable kernel control of the ACT LED.
   * Enables and restarts the services so the system is ready immediately.

5. **Reboot (optional but recommended).** Disabling the kernel LED trigger sometimes requires one reboot before the LED can be fully controlled by software.

## Usage

1. Attach the short wire to GPIO 4 (physical pin 7) as an antenna.
2. On your phone, enable Bluetooth and pair with the Raspberry Pi (default hostname `raspberrypi`). Ensure "Media Audio" (A2DP) is enabled for the connection.
3. Tune a nearby FM radio to the configured frequency (default 87.9 MHz).
4. Start playing audio on the phone. The Pi will stream the audio to PiFmRds, and you should hear it over FM.
5. Use the phone's volume buttons while playback is paused to bump the broadcast frequency up or down by the configured step. When audio is playing the buttons adjust volume normally. During a frequency change the LED flashes three times and the TTS script announces the new frequency over the FM channel.
6. AVRCP metadata (Artist/Title/Album) is forwarded to RDS so compatible radios can display track information.

### LED behavior

* **Slow blink:** Device discoverable/pairing mode.
* **Double blink every ~2 seconds:** A device is connected but not streaming.
* **Solid on:** Streaming is active.
* **Three quick flashes:** Frequency change triggered by volume keys.

## Service management

All major components run as systemd services:

| Service | Description |
| ------- | ----------- |
| `bt-setup.service` | Ensures Bluetooth controller is ready and discoverable on boot. |
| `bt2fm.service` | Streams A2DP audio into PiFmRds. |
| `bt-volume-freqd.service` | Watches volume changes and adjusts FM frequency. |
| `avrcp-rds.service` | Mirrors AVRCP metadata onto the RDS FIFO. |
| `led-statusd.service` | Updates ACT LED to reflect current state. |

Use `systemctl` to monitor or control them, e.g. `sudo systemctl status bt2fm.service` or `sudo systemctl restart avrcp-rds.service`.

## Configuration

Runtime defaults are stored in `/etc/default/bt2fm`. You can edit this file to change the FM frequency range and step size after installation:

```ini
FREQ=87.9
STEP=0.2
FMIN=87.7
FMAX=107.9
```

After editing, restart the relevant services:

```bash
sudo systemctl restart bt2fm.service bt-volume-freqd.service
```

To adjust LED behavior or frequency announcement phrasing, edit the scripts under `/usr/local/bin/` and restart their services as needed.

## Troubleshooting

* **No audio on FM radio** – Verify the antenna wire is connected to GPIO 4 and that `bt2fm.service` is active. Check the output of `sudo journalctl -u bt2fm.service` for errors.
* **Bluetooth device cannot connect** – Make sure `bt-setup.service` is active and that the Pi is discoverable (`bluetoothctl show`). Remove stale pairings with `bluetoothctl remove <MAC>` and re-pair.
* **Frequency changes do not trigger** – Confirm that your device supports Bluetooth Absolute Volume and that `bt-volume-freqd.service` is running. Monitor logs with `sudo journalctl -u bt-volume-freqd.service`.
* **RDS text missing** – Ensure your radio supports RDS. Inspect `/run/rds_ctl` activity and the `avrcp-rds.service` logs.
* **LED does not respond** – Reboot once after installation to ensure the LED trigger changes take effect. Verify that `/usr/local/bin/ledctl.sh` can control the LED manually (e.g. `sudo /usr/local/bin/ledctl.sh on`).

## Extending to AirPlay (RAOP)

Bluetooth A2DP is the only audio input path the installer provisions today. Adding
AirPlay reception involves introducing a RAOP server such as `shairport-sync`
and plumbing its audio output into `pi_fm_rds`. Because the current
`bt2fm.service` assumes it owns both capture and FM transmission, the cleanest
approach is to treat AirPlay as a parallel pipeline with its own helper script
and systemd unit. That script can subscribe to metadata from the AirPlay server
and decide when to start or stop `pi_fm_rds` without racing the Bluetooth
workflow.

Attempting to merge Bluetooth and AirPlay into a single monolithic script would
require arbitrating which source controls the transmitter, reconciling
service-specific metadata hooks, and handling extra failure modes. Keeping the
RAOP plumbing isolated lets you experiment without disrupting the proven A2DP
experience; you can later add a lightweight coordinator (e.g. via systemd
targets) if you want both inputs to coexist gracefully.

## Uninstallation

There is no automated uninstaller, but you can remove the components manually:

1. Stop and disable the services:

   ```bash
   sudo systemctl disable --now bt2fm.service bt-volume-freqd.service avrcp-rds.service led-statusd.service bt-setup.service
   ```

2. Delete the helper scripts:

   ```bash
   sudo rm /usr/local/bin/bt2fm.sh /usr/local/bin/fm_announce.sh \
           /usr/local/bin/bt-volume-freqd.sh /usr/local/bin/avrcp_rds.py \
           /usr/local/bin/ledctl.sh /usr/local/bin/led-statusd.sh
   ```

3. Remove unit files and reload systemd:

   ```bash
   sudo rm /etc/systemd/system/{bt2fm.service,bt-volume-freqd.service,avrcp-rds.service,led-statusd.service,bt-setup.service}
   sudo systemctl daemon-reload
   ```

4. Optionally delete `/etc/default/bt2fm`, `/run/rds_ctl`, and the PiFmRds source directory.

5. Revert LED configuration by editing `/boot/config.txt` and removing the added `dtparam=act_led_trigger=none` and `dtparam=act_led_activelow=off` lines. Reboot to apply.

## License

This repository inherits the license of the `a2dp2fm.sh` script. Review the script header and any upstream projects (such as PiFmRds) for their respective licenses.

