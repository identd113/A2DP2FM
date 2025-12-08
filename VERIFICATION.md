# Verification Notes

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
