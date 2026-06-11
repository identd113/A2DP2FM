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

### Outstanding
- AirPlay path fixes are documentation-verified and harness-tested but still
  need a real-hardware smoke test (AirPlay stream → FM audio → RDS update).
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
