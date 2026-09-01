#!/bin/bash
# ci/check-release-version.sh — Validate release tag/changelog/upstream version consistency.
#
# Usage: check-release-version.sh <git-tag>
#   <git-tag>  The release tag being validated (e.g. debian/1.2.1-1).
#
# Checks:
#   1. Tag matches the required form  debian/<version>
#   2. Tag version exactly matches the first entry in debian/changelog
#   3. The upstream version (everything before the last -<revision>) is
#      consistent with the version declared in Cargo.toml
#
# Exits 0 on success, non-zero with a clear error message on any failure.
# Pass CHECK_RELEASE_VERSION_SOURCED=1 to source only (for unit tests).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ── Helper functions (sourced by tests) ──────────────────────────────────────

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Extract the Debian package version from the first line of debian/changelog.
# Prints the full epoch:upstream-revision string, or exits non-zero.
changelog_version() {
    local changelog="$REPO_ROOT/debian/changelog"
    [[ -f "$changelog" ]] || die "debian/changelog not found at $changelog"
    head -1 "$changelog" | grep -oP '\(\K[^)]+' \
        || die "Could not parse version from debian/changelog"
}

# Extract the upstream version from Cargo.toml (version = "...").
cargo_version() {
    local cargo_toml="$REPO_ROOT/Cargo.toml"
    [[ -f "$cargo_toml" ]] || die "Cargo.toml not found at $cargo_toml"
    grep -m1 '^version\s*=' "$cargo_toml" \
        | grep -oP '"[^"]+"' | tr -d '"' \
        || die "Could not parse version from Cargo.toml"
}

# Extract the upstream portion from a Debian version string.
# Strips the Debian revision suffix (the last -<digits>) and any epoch prefix.
# Example: 1.2.1-1 → 1.2.1;  2:1.2.1-3 → 1.2.1
upstream_from_deb_version() {
    local deb_ver="$1"
    # Remove epoch if present
    local no_epoch="${deb_ver#*:}"
    # Remove the Debian revision suffix
    echo "${no_epoch%-*}"
}

# Return 0 if the tag has the required form debian/<version>
is_valid_tag_form() {
    local tag="$1"
    [[ "$tag" =~ ^debian/ ]] || return 1
    local ver="${tag#debian/}"
    [[ -n "$ver" ]] || return 1
    # The version portion must not contain spaces or slashes
    [[ "$ver" =~ ^[^\ /]+$ ]] || return 1
    return 0
}

# ── Main validation (skipped when sourced) ────────────────────────────────────

if [[ "${CHECK_RELEASE_VERSION_SOURCED:-}" == "1" ]]; then
    return 0
fi

GIT_TAG="${1:?Usage: $0 <git-tag>}"

echo "=== Release version consistency check ==="
echo "Tag: $GIT_TAG"

# 1. Tag form
is_valid_tag_form "$GIT_TAG" \
    || die "Tag '$GIT_TAG' does not match required form 'debian/<version>'. \
Release tags must be of the form debian/<debian-package-version> (e.g. debian/1.2.1-1)."

TAG_VERSION="${GIT_TAG#debian/}"
echo "Tag version:       $TAG_VERSION"

# 2. Changelog version
CHANGELOG_VER=$(changelog_version)
echo "Changelog version: $CHANGELOG_VER"

[[ "$TAG_VERSION" == "$CHANGELOG_VER" ]] \
    || die "Tag version '$TAG_VERSION' does not match debian/changelog version '$CHANGELOG_VER'. \
Update debian/changelog or correct the release tag."

# 3. Upstream version consistency
CARGO_VER=$(cargo_version)
UPSTREAM_VER=$(upstream_from_deb_version "$CHANGELOG_VER")
echo "Debian upstream:   $UPSTREAM_VER"
echo "Cargo.toml:        $CARGO_VER"

[[ "$UPSTREAM_VER" == "$CARGO_VER" ]] \
    || die "Upstream version derived from Debian version ('$UPSTREAM_VER') does not \
match Cargo.toml version ('$CARGO_VER'). Ensure the packaged upstream source matches \
the Debian changelog entry."

echo ""
echo "Version consistency check PASSED."
echo "  Tag:       $GIT_TAG"
echo "  Debian:    $CHANGELOG_VER"
echo "  Upstream:  $UPSTREAM_VER"
echo ""
# Machine-readable output for workflow consumption:
echo "DEB_VERSION=$CHANGELOG_VER"
echo "UPSTREAM_VERSION=$UPSTREAM_VER"
