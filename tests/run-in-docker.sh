#!/usr/bin/env bash
# Build and run the ARMv7 test container so we can exercise the installer.
#
# Usage: ./tests/run-in-docker.sh
# Optional environment variables:
#   A2DP2FM_RPI_IMAGE   Name for the built image (default: a2dp2fm-rpi-sim)
#   DOCKER_BUILD_ARGS   Extra args passed to docker build (e.g. --no-cache)
#   DOCKER_RUN_ARGS     Extra args passed to docker run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="${A2DP2FM_RPI_IMAGE:-a2dp2fm-rpi-sim}"
DOCKER_BIN="${DOCKER:-docker}"

# On arm/arm64 hosts (e.g. Apple Silicon) the ARMv7 image runs natively, so no
# emulation setup is needed. On other hosts (amd64), register qemu binfmt
# handlers so the kernel can execute ARMv7 binaries. Docker Desktop handles
# emulation itself, but running the registration unconditionally on x86_64 is
# harmless and covers non-Desktop hosts.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm*|aarch64)
    echo "Host architecture $HOST_ARCH runs ARMv7 natively; skipping qemu binfmt setup."
    ;;
  *)
    echo "Registering qemu binfmt handlers for ARMv7 emulation (host: $HOST_ARCH)..."
    $DOCKER_BIN run --rm --privileged multiarch/qemu-user-static --reset -p yes
    ;;
esac

echo "Building ARMv7 test image ($IMAGE_NAME)..."
$DOCKER_BIN build ${DOCKER_BUILD_ARGS:-} -f "$SCRIPT_DIR/Dockerfile.rpi-sim" -t "$IMAGE_NAME" "$REPO_ROOT"

# Run privileged so tools like useradd can manipulate /etc/shadow without container restrictions.
echo "Running installer test inside container..."
$DOCKER_BIN run --rm --privileged ${DOCKER_RUN_ARGS:-} \
  -v "$REPO_ROOT:/workspace" \
  -w /workspace \
  "$IMAGE_NAME" \
  bash tests/run-install-test.sh
