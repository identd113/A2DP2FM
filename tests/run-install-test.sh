#!/usr/bin/env bash
# Exercise the installer using stubbed system utilities so we can validate it in CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/a2dp2fm.sh"

if [[ $EUID -ne 0 ]]; then
  echo "This test must run as root (use sudo)." >&2
  exit 1
fi

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "$TMP_WORK"' EXIT

export A2DP2FM_STUB_LOG_DIR="$TMP_WORK/stub-logs"
mkdir -p "$A2DP2FM_STUB_LOG_DIR"

STUB_BIN="$TMP_WORK/bin"
mkdir -p "$STUB_BIN"
ln -s "$REPO_ROOT/tests/bin/git-clone-stub" "$STUB_BIN/git"
PATH="$STUB_BIN:$SCRIPT_DIR/bin:$PATH"
export PATH

ensure_pi_user() {
  if ! id -u pi >/dev/null 2>&1; then
    useradd -m pi >/dev/null 2>&1 || {
      echo "Failed to create pi user" >&2
      exit 1
    }
  fi
  if [[ ! -d /home/pi ]]; then
    mkdir -p /home/pi
    chown pi:pi /home/pi
  fi
}

INSTALL_PATHS=(
  /etc/default/bt2fm
  /usr/local/bin/bt2fm.sh
  /usr/local/bin/fm_announce.sh
  /usr/local/bin/bt-volume-freqd.sh
  /usr/local/bin/avrcp_rds.py
  /usr/local/bin/ledctl.sh
  /usr/local/bin/led-statusd.sh
  /etc/systemd/system/bt2fm.service
  /etc/systemd/system/bt-volume-freqd.service
  /etc/systemd/system/avrcp-rds.service
  /etc/systemd/system/led-statusd.service
  /etc/systemd/system/bt-setup.service
)

cleanup_install_artifacts() {
  rm -rf /home/pi/PiFmRds
  rm -f /run/rds_ctl
  for path in "${INSTALL_PATHS[@]}"; do
    rm -f "$path"
  done
}

fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

pass() {
  echo "[ OK ] $1"
}

action() {
  echo
  echo "==> $1"
}

ensure_pi_user
cleanup_install_artifacts

action "Running installer with stubs"
SUDO_USER=pi bash "$INSTALLER" --freq 102.5 >"$TMP_WORK/installer.log" 2>&1 || {
  cat "$TMP_WORK/installer.log" >&2
  fail "Installer execution failed"
}
pass "Installer completed"

for path in "${INSTALL_PATHS[@]}"; do
  [[ -f "$path" ]] || fail "Expected file missing: $path"
  pass "Found $path"
done

[[ -p /run/rds_ctl ]] || fail "RDS control FIFO not created"
pass "RDS control FIFO exists"

BT2FM_SCRIPT=/usr/local/bin/bt2fm.sh
if ! grep -F 'for i in {1..120}; do' "$BT2FM_SCRIPT" >/dev/null; then
  fail "bt2fm.sh does not wait long enough for BlueALSA"
fi
if ! grep -F 'sleep 2' "$BT2FM_SCRIPT" >/dev/null; then
  fail "bt2fm.sh missing 2s sleep in wait loop"
fi
pass "bt2fm.sh waits up to 240s for BlueALSA"
if ! grep -F 'bluealsa|bluealsad' "$BT2FM_SCRIPT" >/dev/null; then
  fail "bt2fm.sh does not handle bluealsad rename"
fi
pass "bt2fm.sh checks for both bluealsa and bluealsad"

LED_STATUS_SCRIPT=/usr/local/bin/led-statusd.sh
if ! grep -F 'bluealsa|bluealsad' "$LED_STATUS_SCRIPT" >/dev/null; then
  fail "led-statusd.sh does not handle bluealsad rename"
fi
pass "led-statusd.sh checks for both bluealsa and bluealsad"

if [[ -f "$A2DP2FM_STUB_LOG_DIR/apt-get.log" ]]; then
  mapfile -t apt_calls <"$A2DP2FM_STUB_LOG_DIR/apt-get.log"
  [[ "${apt_calls[0]:-}" == "apt-get update -y" ]] || fail "apt-get update not invoked"
  install_line="${apt_calls[1]:-}"
  expected_prefix="apt-get install -y git build-essential libsndfile1-dev python3-dbus python3-gi dbus bluez bluez-tools "
  expected_suffix=" alsa-utils sox jq libttspico-utils espeak-ng gawk"
  if [[ "$install_line" == "${expected_prefix}bluealsa${expected_suffix}" ]]; then
    :
  elif [[ "$install_line" == "${expected_prefix}bluez-alsa${expected_suffix}" ]]; then
    :
  else
    fail "apt-get install not invoked with expected packages"
  fi
  pass "apt-get commands captured"
else
  fail "apt-get log missing"
fi

BT_SERVICE=/etc/systemd/system/bt2fm.service
if ! grep -F 'ExecStart=/usr/local/bin/bt2fm.sh' "$BT_SERVICE" >/dev/null; then
  fail "bt2fm.service missing ExecStart"
fi
pass "bt2fm.service references runtime script"

action "Cleaning up"
cleanup_install_artifacts
pass "Removed generated files"

rm -rf "$TMP_WORK"
trap - EXIT

action "Success"
pass "All checks passed"
