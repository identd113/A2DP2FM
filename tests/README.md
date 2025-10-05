# Test Utilities for Offline Verification

The scripts in `tests/bin` provide lightweight shims for `apt-get`, `systemctl`,
`raspi-config`, and Git. They exist solely to let us exercise `a2dp2fm.sh` inside
restricted containers (e.g. CI) where we cannot reach the public apt mirrors, run
systemd, or invoke `raspi-config`.

Set the PATH so that these shims precede the real commands before executing the
installer, for example:

```bash
A2DP2FM_STUB_LOG_DIR=$(mktemp -d)
PATH="$(pwd)/tests/bin:$PATH" SUDO_USER=pi sudo ./a2dp2fm.sh --freq 99.1
```

If outbound HTTPS is blocked, copy `tests/bin/git-clone-stub` to `/usr/local/bin/git`
(or a similar early PATH location) before running the installer. The stub produces a
minimal PiFmRds tree with a fake `pi_fm_rds` binary so the rest of the pipeline can be
validated.

Each shim logs its invocations to `$A2DP2FM_STUB_LOG_DIR` so you can audit what would
have been executed on a real Raspberry Pi. Remove the directory afterwards if desired.

## Automated merge test

Run `tests/run-install-test.sh` to execute the installer against the shims and verify
key artifacts. The script:

- Ensures a `pi` user exists for file ownership operations.
- Executes the installer with a custom frequency while capturing logs.
- Confirms that configuration files, helper scripts, and systemd unit files are emitted.
- Verifies that the runtime script waits up to 240 seconds for the BlueALSA device,
  guaranteeing adequate startup time during installation.
- Cleans up generated files so the test remains idempotent.

This harness is safe to run in CI containers and is suitable for merge-time validation.
