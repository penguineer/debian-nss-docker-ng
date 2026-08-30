#!/bin/bash
# ci/check-package.sh — Run lintian and inspect generated .deb contents.
#
# Usage: check-package.sh <artifacts-dir>
#   <artifacts-dir>  Directory containing the built .deb and .changes files.
#
# Expected environment: Debian Trixie with lintian and binutils installed.
set -euo pipefail

ARTIFACTS_DIR="${1:?Usage: $0 <artifacts-dir>}"

apt-get update -qq
apt-get install -y --no-install-recommends lintian binutils

DEB=$(ls "$ARTIFACTS_DIR"/libnss-docker-ng_*.deb | head -1)
CHANGES=$(ls "$ARTIFACTS_DIR"/*.changes | head -1)

echo "=== Lintian ==="
# Accepted findings are narrowly suppressed and documented:
#   extended-description-is-empty: upstream summary is intentionally brief;
#     not a packaging defect.
# *.dsc is intentionally omitted: the build is binary-only (-b) and
# produces no source package.
# lintian exits non-zero for any tag not suppressed, preserving failure
# semantics while still allowing the accepted warning.
lintian \
    --suppress-tags extended-description-is-empty \
    --fail-on error \
    "$DEB" "$CHANGES"

echo "Lintian PASSED."

echo ""
echo "=== Package contents: $DEB ==="
dpkg-deb --contents "$DEB"

MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
echo ""
echo "=== Verifying expected library paths (multiarch=$MULTIARCH) ==="

dpkg-deb --contents "$DEB" | grep "$MULTIARCH" | grep 'libnss_docker_ng'

# Must contain both the .so (symlink) and .so.2 (soname library).
dpkg-deb --contents "$DEB" | grep -q "usr/lib/${MULTIARCH}/libnss_docker_ng.so$" \
    || { echo "FAIL: libnss_docker_ng.so not found in expected multiarch path"; exit 1; }
dpkg-deb --contents "$DEB" | grep -q "usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" \
    || { echo "FAIL: libnss_docker_ng.so.2 not found in expected multiarch path"; exit 1; }

echo "Package contents check PASSED."
