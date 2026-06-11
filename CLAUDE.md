# CLAUDE.md

Guidance for Claude Code when working in this repository. See `AGENTS.md` for
the full contributor guide (services, pipelines, uninstall semantics, code
style) — this file covers the essentials plus pitfalls that are easy to miss.

## What this repo is

Two independent installer scripts that turn a headless Raspberry Pi into an FM
transmitter via [PiFmRds](https://github.com/ChristopheJacquet/PiFmRds) on
GPIO 4:

- `a2dp2fm.sh` — Bluetooth A2DP → BlueALSA → `arecord` → `pi_fm_rds`
- `airplay2fm.sh` — AirPlay → shairport-sync → FIFO → `sox` (WAV wrap) → `pi_fm_rds`
- `uninstall.sh` — detects either/both installs, handles shared resources

There is no application code that runs from the repo itself: the installers
**embed** all runtime scripts, systemd units, and config files as heredocs and
write them to the target system.

## Critical: edit the heredocs, not the deployed files

Runtime scripts like `/usr/local/bin/bt2fm.sh`, `avrcp_rds.py`,
`airplay-rds.py`, `ledctl.sh`, etc. only exist inside heredoc blocks in the
two installer scripts. To change runtime behavior, edit the heredoc in
`a2dp2fm.sh` / `airplay2fm.sh`. Heredocs with quoted delimiters (`<<'BTFM'`)
do not expand installer variables; unquoted ones (`<<EOF`) do.

## Verifying changes

```bash
# Full end-to-end install test in an ARMv7 container (preferred):
./tests/run-in-docker.sh

# Static checks:
bash -n a2dp2fm.sh airplay2fm.sh uninstall.sh
shellcheck -S warning a2dp2fm.sh airplay2fm.sh uninstall.sh tests/run-in-docker.sh tests/bin/*
```

When you change an embedded script, also extract and check it, e.g.:

```bash
sed -n "/<<'PYAP'$/,/^PYAP$/p" airplay2fm.sh | sed '1d;$d' \
  | python3 -c 'import sys, ast; ast.parse(sys.stdin.read()); print("OK")'
sed -n "/<<'BTFM'$/,/^BTFM$/p" a2dp2fm.sh | sed '1d;$d' | bash -n /dev/stdin
```

The Docker harness only exercises the Bluetooth installer with stubbed system
tools (`tests/bin/`); the AirPlay path and anything touching real hardware
(GPIO, Bluetooth radio, LED) needs a real Pi.

## Pitfalls (each of these was a real bug)

- **systemd + sudo:** the runtime pipelines run as the pi user and call
  `sudo pi_fm_rds` (it needs root for `/dev/mem`). Never add
  `NoNewPrivileges=true` to `bt2fm.service` or `airplay2fm.service` — it
  blocks setuid and silently kills FM output.
- **pi_fm_rds stdin needs a WAV header** (it reads via libsndfile). `arecord`
  emits one by default; shairport-sync's pipe is headerless raw PCM, which is
  why the AirPlay pipeline pipes through
  `sox -t raw -r 44100 -e signed -b 16 -c 2 - -t wav -`. Don't remove it.
- **shairport-sync config groups matter:** `allow_session_interruption` and
  `session_timeout` belong in `sessioncontrol = { ... }`, not `general`.
  Misplaced options are a fatal startup error.
- **shairport-sync metadata is hex-encoded:** the `<type>`/`<code>` elements
  in `/run/airplay_metadata` are 8-hex-digit ASCII (e.g. `73736e63` = `ssnc`).
  `airplay-rds.py` decodes them with `hex2ascii()` before comparing.
- **Test image uses `CMD ["bash"]`, not `ENTRYPOINT`:** `run-in-docker.sh`
  passes `bash tests/run-install-test.sh` as the container command; an
  ENTRYPOINT would turn that into `bash bash …` and fail with
  "cannot execute binary file".
- **`set -e` and associative arrays:** an empty subscript
  (`${MAP[$choice]}` with empty `$choice`) is a fatal "bad array subscript".
  Guard user input before indexing (see the menu loop in `uninstall.sh`).
- **Pi 5/500 cannot transmit:** PiFmRds needs the SoC clock generator on
  GPIO4; the RP1 chip on Pi 5/500 breaks this. `check_fm_hardware_support()`
  refuses those boards (`A2DP2FM_FORCE_INSTALL=1` overrides, for tests).
- **RDS FIFO writes must not block:** `pi_fm_rds` (the `/run/rds_ctl`
  reader) only runs while audio flows. The metadata daemons open the FIFO
  with `O_NONBLOCK` and drop updates when there is no reader — don't revert
  to plain `open()`, it wedges the daemon.

## Conventions

- Bash only, `#!/usr/bin/env bash`, `set -euo pipefail`. Non-critical
  failures are wrapped with `|| true`.
- Both installers must stay symmetrical in features and docs; keep
  `README.md` (end-user) and `AGENTS.md` (contributor) in sync with any
  behavioral change.
- Installer-written systemd units carry a `# Managed by a2dp2fm` /
  `# Managed by airplay2fm` marker; `uninstall.sh` relies on it to avoid
  deleting distro-provided units. Keep the marker on any new unit.
- Shared assets (`ledctl.sh`, `$PI_HOME/PiFmRds`, `/run/rds_ctl`, ACT LED
  dtparams) are removed only when the last pathway is uninstalled.
- The target user is `${SUDO_USER:-pi}`; runtime configs live in
  `/etc/default/bt2fm` and `/etc/default/airplay2fm` and record `PI_USER` /
  `PI_HOME` for the uninstaller.
- `detect_pi_board()` / `show_board_art()` (board diagram with the antenna
  pin highlighted) are duplicated identically in both installers. Board
  detection reads `/proc/device-tree/model`; override with
  `A2DP2FM_PI_MODEL` for tests. The log line format `(layout: <category>)`
  is asserted by the test harness. Pi 400/500 header is mirrored (pin 1
  top-right viewed from the rear) — don't "fix" that art to match other
  boards.
