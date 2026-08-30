#!/bin/bash
# ci/test-lifecycle.sh — Install and remove the Debian package; verify NSS lifecycle.
#
# Usage: test-lifecycle.sh <artifacts-dir>
#   <artifacts-dir>  Directory containing the built .deb file.
#
# Expected environment: Debian Trixie CI image (ci/Dockerfile).
set -euo pipefail

ARTIFACTS_DIR="${1:?Usage: $0 <artifacts-dir>}"

MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
DEB=$(ls "$ARTIFACTS_DIR"/libnss-docker-ng_*.deb | head -1)

echo "=== Pre-install nsswitch.conf ==="
PRE_NSS=$(grep '^hosts:' /etc/nsswitch.conf || true)
echo "$PRE_NSS"

echo ""
echo "=== Installing $DEB ==="
dpkg -i "$DEB"

echo ""
echo "=== Post-install nsswitch.conf ==="
grep '^hosts:' /etc/nsswitch.conf

echo ""
echo "=== Verifying library is in multiarch path ==="
ls -la "/usr/lib/${MULTIARCH}/libnss_docker_ng.so"  || { echo "FAIL: .so missing"; exit 1; }
ls -la "/usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" || { echo "FAIL: .so.2 missing"; exit 1; }

echo ""
echo "=== Verifying NSS entry points in .so.2 ==="
nm -D "/usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" \
    | grep -E '_nss_docker_ng_(gethostbyname[24]?_r|gethostbyaddr_r)'

echo ""
echo "=== Verifying library is loadable ==="
ldconfig
ldconfig -p | grep libnss_docker_ng || { echo "FAIL: library not in ldconfig cache"; exit 1; }

echo ""
echo "=== Verifying dh_installnss added docker_ng to hosts: ==="
grep '^hosts:' /etc/nsswitch.conf | grep -q 'docker_ng' \
    || { echo "FAIL: docker_ng not in hosts: line after install"; exit 1; }
echo "Install verification PASSED."

echo ""
echo "=== Removing package ==="
dpkg -r libnss-docker-ng

echo ""
echo "=== Post-removal nsswitch.conf ==="
POST_REMOVE_NSS=$(grep '^hosts:' /etc/nsswitch.conf || true)
echo "$POST_REMOVE_NSS"

echo ""
echo "=== Verifying libraries are removed ==="
test ! -f "/usr/lib/${MULTIARCH}/libnss_docker_ng.so"  \
    || { echo "FAIL: .so still present after removal"; exit 1; }
test ! -f "/usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" \
    || { echo "FAIL: .so.2 still present after removal"; exit 1; }

echo ""
echo "=== Verifying docker_ng removed from NSS config ==="
grep '^hosts:' /etc/nsswitch.conf | grep -qv 'docker_ng' \
    || { echo "FAIL: docker_ng still in hosts: line after removal"; exit 1; }
echo "Removal verification PASSED."

echo ""
echo "=== Verifying NSS hosts: line restored to pre-install state ==="
CURRENT_NSS=$(grep '^hosts:' /etc/nsswitch.conf || true)
if [ "$PRE_NSS" = "$CURRENT_NSS" ]; then
    echo "NSS configuration restored correctly."
else
    echo "FAIL: NSS line changed after install+remove."
    echo "  Pre-install:   [$PRE_NSS]"
    echo "  Post-removal:  [$CURRENT_NSS]"
    exit 1
fi
