#!/bin/bash
# ci/build-package.sh — Build the Debian package using dpkg-buildpackage.
#
# Expected environment: Debian Trixie with build dependencies installed.
# Run from the root of the source tree.
#
# The package build exercises debian/rules, which calls:
#   cargo build --release --locked --offline
#   cargo test --locked --offline
set -euo pipefail

echo "=== Trixie toolchain ==="
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential \
    dpkg-dev devscripts debhelper dh-nss \
    cargo rustc \
    binutils file

rustc --version
cargo --version

echo ""
echo "=== Building package ==="
dpkg-buildpackage -us -uc -b
