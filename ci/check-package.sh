#!/bin/bash
# ci/check-package.sh — Run lintian and inspect generated .deb contents.
#
# Usage: check-package.sh <artifacts-dir>
#   <artifacts-dir>  Directory containing the built .deb and .changes files.
#
# Expected environment: Debian Trixie CI image (ci/Dockerfile).
set -euo pipefail

ARTIFACTS_DIR="${1:?Usage: $0 <artifacts-dir>}"
DEB=$(ls "$ARTIFACTS_DIR"/libnss-docker-ng_*.deb | head -1)
CHANGES=$(ls "$ARTIFACTS_DIR"/*.changes | head -1)

echo "=== Lintian ==="
# Accepted findings are narrowly suppressed and documented:
#   extended-description-is-empty: upstream summary is intentionally brief;
#     not a packaging defect.
#   package-name-doesnt-match-sonames: libnss-docker-ng ships libnss_docker_ng.so.2
#     but is intentionally named without a SONAME version suffix.  This package
#     implements the glibc NSS service interface, not a conventional shared library
#     ABI.  The canonical Debian precedent (e.g. libnss-mdns) retains an unversioned
#     package name for NSS plugins.  The SONAME on the .so.2 is required by glibc's
#     NSS loader; it does not imply the package should follow lib<name><version>
#     naming.
# *.dsc is intentionally omitted: the build is binary-only (-b) and
# produces no source package.
# lintian exits non-zero for any tag not suppressed, preserving failure
# semantics while still allowing the accepted warnings.
lintian \
    --suppress-tags extended-description-is-empty \
    --suppress-tags package-name-doesnt-match-sonames \
    --fail-on error \
    "$DEB" "$CHANGES"

echo "Lintian PASSED."

echo ""
echo "=== Package contents: $DEB ==="
# Capture the listing once to avoid SIGPIPE from repeated dpkg-deb | grep -q
# pipelines under set -o pipefail.
CONTENTS=$(dpkg-deb --contents "$DEB")
echo "$CONTENTS"

MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
echo ""
echo "=== Verifying expected library paths (multiarch=$MULTIARCH) ==="

echo "$CONTENTS" | grep "$MULTIARCH" | grep 'libnss_docker_ng'

# Must contain both the .so (symlink) and .so.2 (soname library).
echo "$CONTENTS" | grep -q "usr/lib/${MULTIARCH}/libnss_docker_ng.so$" \
    || { echo "FAIL: libnss_docker_ng.so not found in expected multiarch path"; exit 1; }
echo "$CONTENTS" | grep -q "usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" \
    || { echo "FAIL: libnss_docker_ng.so.2 not found in expected multiarch path"; exit 1; }

echo "Package contents check PASSED."
