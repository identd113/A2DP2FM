# Verification Notes

## 2026-06-11

### Environment
- macOS (Apple Silicon) host; ARMv7 Debian Bookworm container via
  `tests/run-in-docker.sh` (image runs natively on arm64 hosts; the harness
  registers qemu binfmt handlers on amd64 hosts).

### Scope
Full-repo verification followed by fixes, committed as `5c569b7`..`e0c4c88`:

1. **Static checks** — `bash -n` and `shellcheck -S warning` on every shell
   script, including all embedded heredoc scripts (extracted and checked
   separately); both embedded Python daemons parsed with `ast.parse`.
2. **Confirmed and fixed** — `NoNewPrivileges` blocking `sudo pi_fm_rds` in
   both pipeline units; shairport-sync session options in the wrong config
   group; headerless raw PCM fed to libsndfile (sox WAV wrap added);
   hex-encoded shairport-sync metadata codes never matching (verified against
   upstream docs); uninstaller empty-input crash and user/home fallback;
   broken Docker harness (amd64 qemu binary, missing make/gcc,
   ENTRYPOINT/CMD collision).
3. **New behavior verified** — board detection + pin-out art for all four
   layouts (fullsize/zero/pi400/generic) with programmatic width/alignment
   checks and TTY-vs-piped ANSI handling; Pi 5/500 refusal with
   `A2DP2FM_FORCE_INSTALL=1` override; non-blocking RDS FIFO writes
   functionally tested against a real FIFO (no reader → drop after ~2 s;
   reader → intact delivery).
4. **Harness** — `tests/run-in-docker.sh` passes end to end: 35 checks
   including art-in-install-log, four layout assertions, and three
   unsupported-board assertions.

### Real-hardware validation (Pi 3, hostname pi3-BT, Bookworm)
First live runs of the AirPlay pathway surfaced three environment bugs, each
fixed same-day with regression tests:
1. Runtime config staged via mktemp was mode 0600 — pipeline service
   (running as the pi user) failed to source it.
2. `/sys/class/leds/led0` renamed to `ACT` on Bookworm kernels — LED daemon
   crash-looped; ledctl.sh now probes both names.
3. FIFOs created 0660 pi:pi — the distro shairport-sync service runs as its
   own user and got "Permission denied" opening the audio pipe on the first
   stream; pipes are now 0666.

After fixes, confirmed live on hardware: shairport-sync session accepted,
audio pipeline up (pi_fm_rds consuming the pipe), AVRCP-equivalent metadata
decoded and delivered to RDS ("RDS updated: 'Blocks w/ Neal Brennan' /
'Prolific Standup Posting — Josh Johnson'"), LED status driving
/sys/class/leds/ACT.

### Volume-key tuning — hardware-validated (Pi 3 + iPhone, same day)
Live testing drove three iterations, all validated on hardware:
1. pi_fm_rds never exits when its announcement WAV ends — announce legs
   are now bounded with `timeout 8`.
2. iOS routes the volume rocker to AirPlay only while playing (plus a
   ~2-3 s grace window after pausing). A rapid-click playing-state
   gesture was prototyped and validated, then removed by product
   decision: tuning is paused-only (click promptly after pausing). The
   pvol baseline persists across pause/resume so no click is consumed
   re-establishing it.
3. Click batching (net change applied after 3 s of quiet, one announce)
   confirmed end to end: 87.9→88.3 (+2), 88.3→87.9 (−2), and a stacked
   multi-burst run of +11 clicks applying 87.9→90.1 in a single move,
   including a mixed-direction burst correctly netting +2.

### DACP volume restore (same evening)
Tuning clicks move the sender's AirPlay volume; the daemon now undoes
them over the DACP back-channel. Live findings on the Pi 3 + iPhone:
- mDNS discovery of the sender's control endpoint works
  (`iTunes_Ctrl_<DACP-ID>` via avahi-browse; port changes per session).
- `setproperty?dmcp.device-volume=<dB>` returns HTTP 200 but iOS does
  not apply it.
- Discrete `volumeup`/`volumedown` commands deliver, but iOS only
  applies volume commands while playing — the undo is deferred until
  playback resumes (validated in unit tests; visual confirmation of the
  bar restoring on resume pending user retest).

### Outstanding
- Radio-side confirmation (FM audio audible, RDS text displayed) pending
  antenna wire installation on the test Pi.
- Visual confirmation that the deferred volume undo moves the sender's
  volume bar on resume.
- BlueALSA capture addressing (`DEV=` parameter) needs verification on a
  physical Pi — see TODO.md "FM Code Review Findings".

## 2025-12-08 02:30:29Z

### Environment
- Codespaces Ubuntu container without systemd.
- Installer executed through the `tests/run-install-test.sh` harness, which layers
  the stub utilities in `tests/bin` over the PATH to mimic Raspberry Pi behavior
  without requiring privileged services or external network access.

### Procedure
1. Ran `./tests/run-install-test.sh` to create the `pi` user (if missing), inject
   the stubbed commands, and invoke the installer with a custom frequency.
2. Allowed the harness to verify emitted artifacts (systemd units, helper
   scripts, RDS FIFO), confirm BlueALSA wait logic, and ensure the services were
   enabled and restarted in the expected order.
3. Let the harness clean up generated files so the run remains idempotent.

### Results
- The installer completed successfully with every verification step passing.
- All expected helper scripts and systemd unit files were present, the runtime
  script enforced a 240-second BlueALSA wait, and the stubbed apt and
  BlueALSA build steps were exercised.
- Cleanup removed generated files, keeping the working tree tidy for subsequent
  runs.

## 2025-10-05 04:01:46Z

### Environment
- Base image: Codespaces Ubuntu container (non-systemd)
- Shim commands: `tests/bin/apt-get`, `tests/bin/systemctl`, `tests/bin/raspi-config`,
  `tests/bin/git-clone-stub`
- Additional setup: created `pi` user and symlinked the Git stub into
  `/usr/local/bin`

### Procedure
1. Exported `PATH="$(pwd)/tests/bin:$PATH"` so the shims masked missing utilities.
2. Ran the installer with a custom frequency to ensure CLI flag parsing works:
   `SUDO_USER=pi ./a2dp2fm.sh --freq 99.1`.
3. Confirmed that configuration and service files were emitted with the requested
   values.

### Results
- Installer completed without error and printed the expected success banner.
- `/etc/default/bt2fm` captured the custom frequency range values.
- `bt2fm.service` references the generated runtime script under the pi user.
- Helper scripts such as `/usr/local/bin/bt2fm.sh` were generated with BlueALSA
  wait logic.

These results show that the installer successfully renders its configuration and
service artifacts when executed in a clean environment.
