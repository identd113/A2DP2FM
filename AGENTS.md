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

## Board Detection & Pin-out Art

Both installers carry identical `detect_pi_board()` / `show_board_art()`
functions (duplicated, like `ledctl.sh` — the installers stay standalone).
They read `/proc/device-tree/model` (override with `A2DP2FM_PI_MODEL` for
testing or non-Pi machines) and print a board diagram highlighting GPIO4 /
pin 7 plus antenna wire guidance after the install-complete banner (and at
the end of `--dry-run` output). Categories:

| Layout | Match | Boards |
|--------|-------|--------|
| `pi400` | `*"Pi 400"*` / `*"Pi 500"*` | header on rear, **mirrored**: pin 1 top-right viewed from behind |
| `zero` | `*Zero*` | Zero / Zero W / Zero 2 W |
| `fullsize` | `*"Pi 2"*` … `*"Pi 5"*` | 2B, 3A+/3B/3B+, 4B, 5 |
| `generic` | anything else | plain numbered-header fallback |

Match order matters (`Pi 400` before `Pi 4`). The detection log line includes
`(layout: <category>)` — the test harness asserts on it, so keep that format.

`check_fm_hardware_support()` (also duplicated in both installers) refuses to
install on Pi 5/500 — PiFmRds drives FM via the SoC clock generator on GPIO4,
which the RP1 I/O chip on those boards makes impossible. The
`A2DP2FM_FORCE_INSTALL=1` env var overrides the refusal (used in tests).
ANSI highlighting is TTY-only; piped output stays plain. If you edit the art,
keep every line of a block the same visible width and ≤ 76 columns, and keep
both installers' copies identical.

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
| `airplay-rds.service` | shairport-sync metadata → RDS FIFO + volume-key frequency control |
| `led-airplay-statusd.service` | ACT LED driver for AirPlay state |

All units include the comment `# Managed by a2dp2fm` (Bluetooth) or `# Managed by airplay2fm` (AirPlay) in their unit files. The uninstall logic uses these markers to distinguish installer-managed units from system-provided ones.

## Audio Pipelines

**Bluetooth:**
```
Phone (A2DP) → BlueALSA (bluealsad) → arecord → pi_fm_rds (GPIO 4) → FM
```

**AirPlay:**
```
iPhone/Mac (RAOP) → shairport-sync → /run/airplay_audio (FIFO) → cat | sox (raw→WAV) | pi_fm_rds (GPIO 4) → FM
```

shairport-sync's pipe backend emits headerless raw PCM (S16_LE 44100 Hz stereo); `pi_fm_rds` reads stdin via libsndfile, which requires a WAV header, so `sox` wraps the stream in a WAV container. The Bluetooth path needs no sox stage because `arecord` emits a WAV header by default.

The AirPlay pipeline restarts `pi_fm_rds` automatically after each stream ends (the FIFO hits EOF). The FM carrier is off when no stream is active.

## RDS / Metadata

Both pathways write to `/run/rds_ctl` (a named FIFO read by `pi_fm_rds`). The format is:
```
PS <8-char station name>
RT <64-char radiotext>
```

- Bluetooth metadata comes from BlueZ AVRCP D-Bus signals (`avrcp_rds.py`).
- AirPlay metadata comes from shairport-sync's XML metadata pipe at `/run/airplay_metadata` (`airplay-rds.py`). The `<type>` and `<code>` element values arrive hex-encoded (e.g. `73736e63` = `ssnc`); `airplay-rds.py` decodes them with `hex2ascii()` before comparing. The `mden` (metadata-end) event is type `ssnc`, not `core` — keep this in mind if modifying the metadata reader.
- `airplay-rds.py` also implements volume-key frequency control from the same pipe: `ssnc`/`pvol` events carry `"airplay_volume,volume,lowest,highest"` (first field −144 = mute, else −30..0 dB). While playback is paused (`pfls`/`pend` seen), a volume change bumps `FREQ` by `STEP` within `[FMIN, FMAX]` and runs `airplay_announce.sh` (LED flash + TTS at the new frequency, stop/start of `airplay2fm.service`). The metadata pipe must have exactly one reader — never split `pvol` handling into a second process reading the same FIFO.

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
