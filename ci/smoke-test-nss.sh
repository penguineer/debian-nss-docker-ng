#!/bin/bash
# ci/smoke-test-nss.sh — End-to-end Docker/NSS smoke test.
#
# Usage: smoke-test-nss.sh <artifacts-dir> <container-name> <expected-ip>
#   <artifacts-dir>   Directory containing the built .deb file.
#   <container-name>  Name of the already-running Docker test container.
#   <expected-ip>     IP address reported by the host Docker daemon for
#                     the test container.
#
# Expected environment: Debian Trixie CI image (ci/Dockerfile).
# The Docker socket must be mounted in from the host runner.
set -euo pipefail

ARTIFACTS_DIR="${1:?Usage: $0 <artifacts-dir> <container-name> <expected-ip>}"
TEST_NAME="${2:?Usage: $0 <artifacts-dir> <container-name> <expected-ip>}"
EXPECTED_IP="${3:?Usage: $0 <artifacts-dir> <container-name> <expected-ip>}"

DEB=$(ls "$ARTIFACTS_DIR"/libnss-docker-ng_*.deb | head -1)

echo "=== Pre-install nsswitch.conf ==="
PRE_NSS=$(grep '^hosts:' /etc/nsswitch.conf || true)
echo "$PRE_NSS"

echo ""
echo "=== Installing $DEB ==="
dpkg -i "$DEB"
ldconfig

echo ""
echo "=== nsswitch.conf hosts: line ==="
grep '^hosts:' /etc/nsswitch.conf

echo ""
echo "=== getent hosts ${TEST_NAME}.docker ==="
RESOLVED=$(getent hosts "${TEST_NAME}.docker" || true)
echo "Result: $RESOLVED"

if [ -z "$RESOLVED" ]; then
    echo "FAIL: getent returned nothing for ${TEST_NAME}.docker"
    exit 1
fi

RESOLVED_IP=$(echo "$RESOLVED" | awk '{print $1}')
if [ "$RESOLVED_IP" = "$EXPECTED_IP" ]; then
    echo "PASS: resolved $RESOLVED_IP matches expected $EXPECTED_IP"
else
    echo "FAIL: resolved $RESOLVED_IP but expected $EXPECTED_IP"
    exit 1
fi

echo ""
echo "=== Removing package and verifying NSS is restored ==="
dpkg -r libnss-docker-ng
POST_REMOVE=$(grep '^hosts:' /etc/nsswitch.conf || true)
echo "After removal: $POST_REMOVE"

echo "$POST_REMOVE" | grep -qv 'docker_ng' \
    || { echo "FAIL: docker_ng still present in NSS config after removal"; exit 1; }
echo "PASS: docker_ng removed from NSS config."

echo ""
echo "=== Verifying NSS hosts: line restored to pre-install state ==="
if [ "$PRE_NSS" = "$POST_REMOVE" ]; then
    echo "NSS configuration restored correctly."
else
    echo "FAIL: NSS line changed after install+remove."
    echo "  Pre-install:  [$PRE_NSS]"
    echo "  Post-removal: [$POST_REMOVE]"
    exit 1
fi
