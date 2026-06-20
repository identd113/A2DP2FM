# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- **Ground plane docs and side-view antenna diagram** — installer board art now marks
  pin 6 (GND, the nearest GND to GPIO4) as the recommended ground plane connection on
  all board variants (full-size, Zero, Pi 400). A new side-view ASCII diagram in the
  installer footer and README shows the vertical antenna wire on pin 7 and the optional
  horizontal ground plane wire on pin 6.

### Changed
- **PiFmRds build skip on re-install** — both installers now run `git pull --ff-only` on an existing
  clone before deciding whether to recompile. The compiled binary is reused as long as the git HEAD
  matches the `.built_commit` stamp written at last build time. Re-running the installer is now fast
  when PiFmRds has not changed upstream.

---

## 2026-06-15

### Fixed
- **60-second silence after frequency announcement** — `airplay_announce.sh` now opens a
  background drain (`cat /run/airplay_audio >/dev/null`) before stopping `airplay2fm.service`.
  Without this, shairport-sync received SIGPIPE when the FIFO lost its reader, dropped the
  AirPlay session, and iOS took ~60 s to reconnect. The pipeline is restarted first, then the
  drainer is killed after a 0.3 s overlap so there is never a reader gap at either transition.

---

## 2026-06-14

### Added
- **HTTP tuner UI** (`airplay-rds.py`, port 8750) — mobile-friendly page showing current
  frequency, now-playing track (title / artist / album), and play state. Up/Down step buttons
  and a direct-entry frequency field. Frequency changes persist to `/etc/default/airplay2fm`
  and take effect immediately via the announce script.
- **`--vol-tune` installer flag** — volume-rocker frequency control is now opt-in (disabled
  by default, `VOL_TUNE=0`). Pass `--vol-tune` to re-enable it. The HTTP tuner replaces it
  as the primary tuning interface.
- **`/api/status` JSON endpoint** — returns `freq`, `step`, `fmin`, `fmax`, `ap_name`,
  `play_state`, `title`, `artist`, `album`. Polled every 5 s by the UI; also scriptable.
- **`POST /api/up`, `/api/down`, `/api/freq`** HTTP endpoints for headless control.
- **Optimistic UI updates** — frequency display changes instantly on button tap without
  waiting for the server round-trip.
- **`Cache-Control: no-store`** on HTML and API responses so the browser never serves stale data.
- **`theme-color` meta tag** so mobile browsers colour their chrome bar to match the UI.

### Changed
- TTS engine switched from `pico2wave` / `espeak-ng` to **`flite`** — available in Bookworm
  repos, sounds better than espeak-ng, needs no fallback logic. `say()` is now a one-liner.
- HTTP tuner port set to **8750** (bottom of the FM band — easy to remember).
- Post-action poll delay reduced from 400 ms to 250 ms.

### Removed
- **`jq`** from apt package list — never used anywhere in the installer or runtime scripts.
- **`gawk`** — all `awk` usage is POSIX-compatible; `mawk` (default on Raspberry Pi OS) handles it.
- **`alsa-utils`** (`arecord` / `aplay` / `amixer`) — not used by the AirPlay pipeline.
- **`libdaemon-dev`** — was a shairport-sync ≤3 build dependency; shairport-sync 4.x dropped it
  and the `./configure` here has no `--with-libdaemon`.
- TTS fallback chain removed (was `pico2wave` → `espeak-ng`); single `flite` call instead.

---

## 2026-06-12

### Fixed
- **Sender volume restore** — closed the loop on the DACP restore sequence. Previous attempts
  used `setproperty?dmcp.device-volume=<dB>` which returns HTTP 200 but iOS silently ignores
  it. Switched to discrete `volumeup` / `volumedown` commands with a closed-loop feedback
  check on `pvol` echoes. The undo is deferred until playback resumes (`prsm`/`pbeg`) because
  iOS only applies volume commands while playing. A suppression window prevents the undo's own
  `pvol` echoes from being counted as new tuning clicks.

---

## 2026-06-11

### Added
- **Volume-key frequency control for AirPlay** — `airplay-rds.py` monitors `ssnc`/`pvol`
  events while playback is paused. Presses are batched (3 s debounce); net change applied in
  one move with LED flash and TTS announcement on both old and new frequencies.
- **Rapid-click batching** — multiple volume presses within the debounce window accumulate;
  3 up-clicks = +0.6 MHz at the default 0.2 step.
- **Persistent volume baseline** — `pvol` baseline is kept across pause/resume so the first
  click after resuming is not silently discarded.
- **DACP back-channel** — captures `ssnc`/`daid` and `ssnc`/`acre`, resolves the sender's
  control endpoint via `avahi-browse`, restores sender volume after tuning.
- **Pi 5 / Pi 500 guard** — `check_fm_hardware_support()` reads `/proc/device-tree/model`
  and refuses installation on boards whose GPIO is routed through the RP1 chip.
  `A2DP2FM_FORCE_INSTALL=1` overrides for CI.
- **Non-blocking RDS FIFO writes** — `airplay-rds.py` opens `/run/rds_ctl` with `O_NONBLOCK`
  and retries briefly; drops the update rather than wedging the daemon when `pi_fm_rds` is idle.
- **Board pin-out art** with antenna pin highlighted, shown after install.

### Fixed
- ACT LED path: probes both `/sys/class/leds/ACT` (Bookworm+) and `led0` (older releases);
  no-ops when neither exists instead of crash-looping.
- FIFO permissions: `/run/airplay_audio` and `/run/airplay_metadata` are now mode 0666 so the
  `shairport-sync` system user (distro package) can open them. Previously 0660 caused
  "Permission denied" on the first stream.
- Runtime config (`/etc/default/airplay2fm`) was written via `mktemp` which creates 0600 files;
  now explicitly `chmod 644` so the `pi` user can source it from service scripts.
- AirPlay tuning restricted to paused state — during playback the volume rocker is ordinary
  volume control; `pvol` changes only update the baseline.
- `timeout 8` added to announce `pi_fm_rds` calls; `pi_fm_rds` does not exit at WAV EOF so
  without a bound the announce would never return.

---

## 2026-04-25

### Added
- **AirPlay → FM pathway** (`airplay2fm.sh`) — shairport-sync pipe backend → sox (raw PCM to
  WAV) → `pi_fm_rds`. Parallel feature-set to the Bluetooth pathway.
- **Unified uninstall script** (`uninstall.sh`) — detects Bluetooth, AirPlay, or both
  installations; removes only managed units (identified by `# Managed by` marker); preserves
  shared resources (PiFmRds, `ledctl.sh`, RDS FIFO, dtparams) until the last pathway is removed.
- **RDS metadata for AirPlay** (`airplay-rds.py`) — reads shairport-sync's XML metadata pipe,
  decodes hex-encoded `<type>`/`<code>` fields, updates PS/RT on `mden`.
- **systemd tmpfiles.d** entry so FIFOs in `/run` survive reboots.
- **TTS station announcements** (`airplay_announce.sh`) — speaks "Moving to X megahertz" on
  the old frequency then confirms on the new one using `flite`.

---

## 2025-12-07

### Added
- ARMv7 Docker test harness (`tests/run-in-docker.sh`) for end-to-end installer validation
  without real hardware. Stubbed system tools in `tests/bin/`.
- Raspberry Pi OS codename detection (`/etc/os-release`); verified on Bookworm, Bullseye, Trixie.
- `git clone` command configurable via `GIT_CLONE_CMD` for offline/mirrored runs.

### Fixed
- `CMD ["bash"]` in test Dockerfile (not `ENTRYPOINT`) so the harness can pass commands directly.

---

## 2025-10-05

### Added
- `--uninstall` flag to both installer scripts.
- LED status connection loop fix for BlueALSA A2DP path.

---

## Earlier (pre-2025-10)

Initial development: Bluetooth A2DP → BlueALSA → `arecord` → `pi_fm_rds` pipeline,
headless pairing, AVRCP metadata to RDS, ACT LED status indicator, logging and
validation, GPIO pinout diagram in README, curl-based one-line install documentation.
