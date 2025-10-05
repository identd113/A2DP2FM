# Agent Tips for A2DP2FM Repository

## Purpose of the Project
This repository contains a single installer script, `a2dp2fm.sh`, which prepares a Raspberry Pi to act as a Bluetooth A2DP receiver and rebroadcast the audio over FM via PiFmRds. Any modifications should keep the headless-install workflow simple and robust.

## Working Guidelines
- **Target platform:** Assume Raspberry Pi OS Lite (Debian-based) without a desktop environment.
- **Privileges:** The installer is expected to be executed with `sudo`. Avoid changes that would break non-root execution checks.
- **Network dependencies:** The script pulls packages with `apt-get` and clones PiFmRds. If you touch those sections, document any additional network requirements.
- **Idempotence:** The script may be run more than once on the same system. Preserve or improve safeguards that keep re-runs safe.
- **Systemd units:** Services like `bt2fm.service`, `bt-volume-freqd.service`, `avrcp-rds.service`, `led-statusd.service`, and `bt-setup.service` are core to the pipeline. Ensure any edits keep the units consistent and reload/enable them when needed.
- **Hardware interaction:** GPIO 4 is used as the transmit pin, and the ACT LED provides visual feedback. Changes affecting these should be conservative and well-commented.

## Code Style and Structure
- Stick to portable `bash` (script currently uses `#!/usr/bin/env bash`).
- Favor clear, linear shell logic over dense one-liners; add helper functions instead of repeating long command sequences.
- Keep comments that explain hardware-specific steps; add more when introducing non-obvious operations.
- Validate command success (`set -euo pipefail` is enabled); wrap non-critical failures with explicit error handling if needed.

## Testing and Verification
- After modifying the installer, test on a Raspberry Pi (or an emulator) with Bluetooth hardware whenever feasible.
- Confirm that each systemd service starts successfully and that frequency changes, LED feedback, and TTS announcements still function.
- Update the README if defaults, CLI flags, or required dependencies change.

## Documentation Expectations
- Reflect any substantial behavior changes in both this `AGENTS.md` and the `README.md` to keep instructions in sync.
- When adding new scripts or directories, consider introducing additional `AGENTS.md` files with scope-specific guidance.

