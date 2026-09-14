#!/bin/bash
# ci/test-lifecycle.sh — Install, reinstall, and remove the Debian package; verify NSS lifecycle.
#
# Usage: test-lifecycle.sh <artifacts-dir>
#   <artifacts-dir>  Directory containing the built .deb file.
#
# Lifecycle exercised:
#   baseline -> install -> verify -> reinstall same .deb -> verify idempotence -> remove -> verify restoration
#
# Expected environment: Debian Trixie CI image (ci/Dockerfile).
set -euo pipefail

ARTIFACTS_DIR="${1:?Usage: $0 <artifacts-dir>}"

MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
DEB=$(ls "$ARTIFACTS_DIR"/libnss-docker-ng_*.deb | head -1)

# ---------------------------------------------------------------------------
# Helper: verify the installed state of the package.
# Checks library presence, NSS symbols, ldconfig cache, and that docker_ng
# appears exactly once in the hosts: line.
#
# Usage: verify_installed_state <phase_label>
# ---------------------------------------------------------------------------
verify_installed_state() {
    local phase="${1:?phase label required}"

    echo ""
    echo "=== [$phase] Verifying library is in multiarch path ==="
    ls -la "/usr/lib/${MULTIARCH}/libnss_docker_ng.so"  || { echo "FAIL: .so missing"; exit 1; }
    ls -la "/usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" || { echo "FAIL: .so.2 missing"; exit 1; }

    echo ""
    echo "=== [$phase] Verifying NSS entry points in .so.2 ==="
    nm -D "/usr/lib/${MULTIARCH}/libnss_docker_ng.so.2" \
        | grep -E '_nss_docker_ng_(gethostbyname[24]?_r|gethostbyaddr_r)'

    echo ""
    echo "=== [$phase] Verifying library is loadable ==="
    ldconfig
    ldconfig -p | grep libnss_docker_ng || { echo "FAIL: library not in ldconfig cache"; exit 1; }

    echo ""
    echo "=== [$phase] Verifying docker_ng appears exactly once in hosts: ==="
    local count
    count=$(awk '
        $1 == "hosts:" {
            for (i = 2; i <= NF; i++)
                if ($i == "docker_ng")
                    count++
        }
        END { print count + 0 }
    ' /etc/nsswitch.conf)
    if [ "$count" -ne 1 ]; then
        echo "FAIL: docker_ng appears $count time(s) in hosts: line (expected 1)."
        echo "  hosts: [$(grep '^hosts:' /etc/nsswitch.conf || true)]"
        exit 1
    fi
    echo "$phase verification PASSED."
}

echo "=== Pre-install nsswitch.conf ==="
PRE_NSS=$(grep '^hosts:' /etc/nsswitch.conf || true)
echo "$PRE_NSS"

# ---------------------------------------------------------------------------
# Phase 1: Initial install
# ---------------------------------------------------------------------------
echo ""
echo "=== Installing $DEB ==="
dpkg -i "$DEB"

echo ""
echo "=== Post-install nsswitch.conf ==="
POST_INSTALL_NSS=$(grep '^hosts:' /etc/nsswitch.conf)
echo "$POST_INSTALL_NSS"

verify_installed_state "post-install"

# ---------------------------------------------------------------------------
# Phase 2: Reinstall the same .deb (idempotence / upgrade-path check)
# ---------------------------------------------------------------------------
echo ""
echo "=== Reinstalling $DEB (same-version reinstall) ==="
dpkg -i "$DEB"

echo ""
echo "=== Post-reinstall nsswitch.conf ==="
POST_REINSTALL_NSS=$(grep '^hosts:' /etc/nsswitch.conf)
echo "$POST_REINSTALL_NSS"

verify_installed_state "post-reinstall"

echo ""
echo "=== Verifying hosts: line is identical after reinstall ==="
if [ "$POST_INSTALL_NSS" = "$POST_REINSTALL_NSS" ]; then
    echo "NSS hosts: line unchanged by reinstall. PASSED."
else
    echo "FAIL: NSS hosts: line changed after reinstall."
    echo "  Post-install:   [$POST_INSTALL_NSS]"
    echo "  Post-reinstall: [$POST_REINSTALL_NSS]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 3: Remove and verify restoration
# ---------------------------------------------------------------------------
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
