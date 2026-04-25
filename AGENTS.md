# Agent Tips for A2DP2FM Repository

## Purpose of the Project

This repository provides two independent installer scripts that configure a headless Raspberry Pi to receive audio and rebroadcast it as an FM transmission via [PiFmRds](https://github.com/ChristopheJacquet/PiFmRds) on GPIO 4:

* **`a2dp2fm.sh`** — Bluetooth A2DP pathway (BlueALSA → PiFmRds)
* **`airplay2fm.sh`** — AirPlay / RAOP pathway (shairport-sync → PiFmRds)
* **`uninstall.sh`** — Interactive uninstaller that detects both pathways and handles shared resources correctly

The two pathways share hardware (GPIO 4, ACT LED) and some installed assets (`ledctl.sh`, `$PI_HOME/PiFmRds`) but maintain separate configs (`/etc/default/bt2fm` vs `/etc/default/airplay2fm`), separate systemd services, and cannot run simultaneously.

## Working Guidelines

- **Target platform:** Raspberry Pi OS Lite (Debian-based), headless, no desktop. Assume Bullseye, Bookworm, or Trixie unless testing otherwise.
- **Privileges:** Both installers require root (`sudo`). Never relax the EUID check.
- **Network dependencies:** Scripts pull packages via `apt-get` and clone from GitHub. Document any new network dependencies you add.
- **Idempotence:** Both installers may be re-run on the same system. Preserve or improve safeguards for re-runs (e.g. `[[ ! -d ... ]] && git clone`).
- **GPIO 4 is exclusive:** Both pathways use GPIO 4 for the FM transmitter. Adding features that switch between sources must stop one `pi_fm_rds` instance before starting another.
- **Shared resources:** `ledctl.sh` and `$PI_HOME/PiFmRds` are used by both pathways. The `uninstall.sh` script is aware of this and only removes them when the last pathway is being uninstalled. Follow the same logic if you add new shared assets.

## Systemd Services

### Bluetooth (`a2dp2fm.sh`)

| Service | Role |
|---------|------|
| `bt-setup.service` | Powers on adapter, sets discoverable/pairable at boot |
| `bt-agent.service` | Headless pairing agent |
| `bt2fm.service` | A2DP audio → PiFmRds pipeline |
| `bt-volume-freqd.service` | Volume-key frequency controller |
| `avrcp-rds.service` | AVRCP metadata → RDS FIFO |
| `led-statusd.service` | ACT LED driver for Bluetooth state |
| `bluealsa.service` | BlueALSA daemon (A2DP capture) |

### AirPlay (`airplay2fm.sh`)

| Service | Role |
|---------|------|
| `shairport-sync.service` | AirPlay receiver; writes raw PCM to `/run/airplay_audio` |
| `airplay2fm.service` | Reads audio FIFO → PiFmRds pipeline |
| `airplay-rds.service` | shairport-sync metadata → RDS FIFO |
| `led-airplay-statusd.service` | ACT LED driver for AirPlay state |

All units include the comment `# Managed by a2dp2fm` (Bluetooth) or `# Managed by airplay2fm` (AirPlay) in their unit files. The uninstall logic uses these markers to distinguish installer-managed units from system-provided ones.

## Audio Pipelines

**Bluetooth:**
```
Phone (A2DP) → BlueALSA (bluealsad) → arecord → pi_fm_rds (GPIO 4) → FM
```

**AirPlay:**
```
iPhone/Mac (RAOP) → shairport-sync → /run/airplay_audio (FIFO) → cat | pi_fm_rds (GPIO 4) → FM
```

The AirPlay pipeline restarts `pi_fm_rds` automatically after each stream ends (the FIFO hits EOF). The FM carrier is off when no stream is active.

## RDS / Metadata

Both pathways write to `/run/rds_ctl` (a named FIFO read by `pi_fm_rds`). The format is:
```
PS <8-char station name>
RT <64-char radiotext>
```

- Bluetooth metadata comes from BlueZ AVRCP D-Bus signals (`avrcp_rds.py`).
- AirPlay metadata comes from shairport-sync's XML metadata pipe at `/run/airplay_metadata` (`airplay-rds.py`). The `mden` (metadata-end) event is type `ssnc`, not `core` — keep this in mind if modifying the metadata reader.

## FIFO Persistence

The FIFOs in `/run` (a tmpfs) are wiped on every reboot. The AirPlay installer registers `/etc/tmpfiles.d/airplay2fm.conf` so systemd-tmpfiles recreates them before services start. The Bluetooth installer recreates `/run/rds_ctl` inside `bt2fm.sh` at runtime. When modifying either pipeline, ensure FIFOs are recreated at the right point in the boot sequence.

## Uninstall Script (`uninstall.sh`)

The uninstaller detects installations by checking for marker files (`/etc/default/bt2fm`, `/etc/default/airplay2fm`, `/usr/local/bin/bt2fm.sh`, `/usr/local/bin/airplay2fm.sh`). It reads `PI_USER` and `PI_HOME` from those config files.

Key behaviors to preserve if modifying:
- Shared resources (PiFmRds, `ledctl.sh`, dtparam lines, `/run/rds_ctl`) are removed only when removing the last installed pathway.
- The `shairport-sync.service` unit is only removed if it contains the `Managed by airplay2fm` marker (meaning it was written by our installer, not the distro package manager).
- The `--bt`, `--airplay`, `--all`, and `--yes` flags allow non-interactive / scripted removal.

## Code Style and Structure

- Bash only (`#!/usr/bin/env bash`), `set -euo pipefail` throughout.
- Favor clear linear logic over dense one-liners. Add helper functions rather than repeating long command sequences.
- Keep hardware-specific comments (GPIO pins, dtparam interactions, ALSA PCM formats).
- Wrap non-critical failures with `|| true`; let critical failures propagate through `set -e`.
- Heredocs inside installer scripts use single-quoted delimiters (`<<'EOF'`) when the embedded content must not expand installer-level variables; use unquoted delimiters (`<<EOF`) when expansion is desired.

## Testing and Verification

- After modifying either installer, test on a real Raspberry Pi or the Docker-based test harness in `tests/`.
- For the Bluetooth path, verify Bluetooth pairing, audio streaming, RDS display, LED states, and frequency changes with volume keys.
- For the AirPlay path, verify device discovery in iOS/macOS, audio playback, RDS update, LED states, and correct behavior across stream start/stop cycles (including reboot).
- For `uninstall.sh`, verify that each removal mode leaves the correct residual state (shared resources kept when one pathway remains, all cleaned when both removed).
- Update the README if defaults, CLI flags, or required dependencies change.

## Documentation Expectations

- Keep `README.md` and `AGENTS.md` in sync with behavioral changes.
- The README audience is end-users; `AGENTS.md` is for contributors and AI agents.
- Both pathways must remain equally documented — do not let the Bluetooth section drift ahead of AirPlay or vice versa.
