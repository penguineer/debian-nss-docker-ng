#!/bin/bash
# ci/build-package.sh — Build the Debian package using dpkg-buildpackage.
#
# Expected environment: Debian Trixie CI image (ci/Dockerfile) with all
# build dependencies pre-installed.
# Run from the root of the source tree.
#
# The package build exercises debian/rules, which calls:
#   cargo build --release --locked --offline
#   cargo test --locked --offline
set -euo pipefail

echo "=== Trixie toolchain ==="
rustc --version
cargo --version

echo ""
echo "=== Building package ==="
dpkg-buildpackage -us -uc -b
