#!/usr/bin/env bash
# Build and run the ARMv7 test container so we can exercise the installer under QEMU.
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

echo "Building ARMv7 test image ($IMAGE_NAME)..."
$DOCKER_BIN build ${DOCKER_BUILD_ARGS:-} -f "$SCRIPT_DIR/Dockerfile.rpi-sim" -t "$IMAGE_NAME" "$REPO_ROOT"

# Run privileged so tools like useradd can manipulate /etc/shadow without container restrictions.
echo "Running installer test inside container..."
$DOCKER_BIN run --rm --privileged ${DOCKER_RUN_ARGS:-} \
  -v "$REPO_ROOT:/workspace" \
  -w /workspace \
  "$IMAGE_NAME" \
  bash tests/run-install-test.sh
