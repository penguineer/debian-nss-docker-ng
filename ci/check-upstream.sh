#!/bin/bash
# ci/check-upstream.sh — Check crates.io for a newer stable nss-docker-ng release.
#
# Usage:
#   check-upstream.sh [--current-version VERSION]
#   check-upstream.sh --target-version VERSION
#
# Modes:
#   (default)                 Compare the crates.io latest stable release against
#                             the version in debian/changelog.
#   --current-version VER     Override the "current" baseline used for comparison.
#   --target-version VER      Validate a specific version through the same full
#                             crates.io safety rules (stable semver, non-yanked,
#                             checksum present) without doing a comparison.
#                             Outputs the same KEY=VALUE block and exits 0 on
#                             success, 1 if the version fails any safety check.
#                             UPDATE_AVAILABLE is always true in this mode.
#
# Outputs (to stdout, one per line, KEY=VALUE):
#   CURRENT_VERSION=<semver from debian/changelog>
#   UPSTREAM_VERSION=<validated version>
#   UPDATE_AVAILABLE=true|false
#   CRATE_URL=<immutable crates.io download URL>
#   CRATE_CHECKSUM=<sha256 from crates.io index>
#
# Exit codes:
#   0  — success (UPDATE_AVAILABLE may be true or false; always true in --target-version mode)
#   1  — hard error (API failure, parse error, yanked/malformed release, validation failure)
#
# The script does NOT modify the repository; that is done by prepare-update.sh.
#
# Sourcing guard: when CHECK_UPSTREAM_SOURCED=1 is set in the environment,
# this script only defines its helper functions and returns without executing
# the main logic.  Tests use this to import semver_gt and is_prerelease
# directly from the production implementation.
set -euo pipefail

CRATE_NAME="nss-docker-ng"
CRATES_IO_API="https://crates.io/api/v1/crates"
# Respect crates.io crawling policy
USER_AGENT="debian-nss-docker-ng-updater/1 (https://github.com/penguineer/debian-nss-docker-ng)"

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

semver_gt() {
    # Returns 0 (true) if $1 > $2 using sort -V
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]
}

is_prerelease() {
    # A version is pre-release if it contains alpha, beta, rc, preview, or a
    # pre-release separator such as -rc1, .alpha2, etc.
    echo "$1" | grep -qiE '(alpha|beta|rc|pre(view)?)[._\-]?[0-9]*$'
}

# Return early if sourced for helper functions only (used by tests)
[ "${CHECK_UPSTREAM_SOURCED:-}" = "1" ] && return 0

# ── parse arguments ───────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURRENT_VERSION_OVERRIDE=""
TARGET_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --current-version)
            CURRENT_VERSION_OVERRIDE="${2:?--current-version requires a value}"
            shift 2
            ;;
        --target-version)
            TARGET_VERSION="${2:?--target-version requires a value}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

# ── determine current packaged version ───────────────────────────────────────

if [ -n "$CURRENT_VERSION_OVERRIDE" ]; then
    CURRENT_VERSION="$CURRENT_VERSION_OVERRIDE"
else
    CHANGELOG="$REPO_ROOT/debian/changelog"
    [ -f "$CHANGELOG" ] || die "debian/changelog not found at $CHANGELOG"
    CURRENT_VERSION=$(head -1 "$CHANGELOG" | grep -oP '\(\K[^)]+' | sed 's/-[0-9]*$//')
    [ -n "$CURRENT_VERSION" ] || die "Could not parse upstream version from debian/changelog"
fi

# ── query crates.io ──────────────────────────────────────────────────────────

API_URL="${CRATES_IO_API}/${CRATE_NAME}/versions"

RESPONSE=$(curl --silent --fail \
    --max-time 30 \
    --retry 3 \
    --retry-delay 5 \
    --user-agent "$USER_AGENT" \
    "$API_URL") \
    || die "crates.io API request failed for $API_URL"

# ── --target-version mode ─────────────────────────────────────────────────────
# Validate the requested version through the full production safety rules.

if [ -n "$TARGET_VERSION" ]; then
    # 1. Must be exact stable semver form (same regex the automatic filter uses)
    echo "$TARGET_VERSION" | grep -qP '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "--target-version '$TARGET_VERSION' is not stable semver (x.y.z)"

    # 2. Must not look like a pre-release (belt-and-suspenders)
    is_prerelease "$TARGET_VERSION" \
        && die "--target-version '$TARGET_VERSION' looks like a pre-release"

    # 3. Must exist in crates.io and must not be yanked
    VERSION_ENTRY=$(echo "$RESPONSE" | jq \
        --arg ver "$TARGET_VERSION" '
          .versions | map(select(.num == $ver)) | first')
    [ -n "$VERSION_ENTRY" ] && [ "$VERSION_ENTRY" != "null" ] \
        || die "Version $TARGET_VERSION not found on crates.io"

    YANKED=$(echo "$VERSION_ENTRY" | jq -r '.yanked')
    [ "$YANKED" = "false" ] \
        || die "Version $TARGET_VERSION is yanked on crates.io"

    # 4. Must have a checksum
    CRATE_CHECKSUM=$(echo "$VERSION_ENTRY" | jq -r '.checksum')
    [ -n "$CRATE_CHECKSUM" ] && [ "$CRATE_CHECKSUM" != "null" ] \
        || die "No checksum found for $TARGET_VERSION on crates.io"

    CRATE_URL="https://static.crates.io/crates/${CRATE_NAME}/${TARGET_VERSION}/download"

    echo "CURRENT_VERSION=${CURRENT_VERSION}"
    echo "UPSTREAM_VERSION=${TARGET_VERSION}"
    echo "UPDATE_AVAILABLE=true"
    echo "CRATE_URL=${CRATE_URL}"
    echo "CRATE_CHECKSUM=${CRATE_CHECKSUM}"
    exit 0
fi

# ── automatic discovery mode ─────────────────────────────────────────────────

# Select the newest non-yanked, non-pre-release version
UPSTREAM_VERSION=$(echo "$RESPONSE" | \
    jq -r '
      .versions
      | map(select(.yanked == false))
      | map(select(.num | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
      | sort_by(.num | split(".") | map(tonumber))
      | last
      | .num
    ') || die "Failed to parse crates.io response"

[ -n "$UPSTREAM_VERSION" ] && [ "$UPSTREAM_VERSION" != "null" ] \
    || die "No stable non-yanked release found for $CRATE_NAME"

# Belt-and-suspenders: reject pre-releases that slip past the regex
is_prerelease "$UPSTREAM_VERSION" \
    && die "Latest stable version '$UPSTREAM_VERSION' looks like a pre-release"

CRATE_URL="https://static.crates.io/crates/${CRATE_NAME}/${UPSTREAM_VERSION}/download"

CRATE_CHECKSUM=$(echo "$RESPONSE" | \
    jq -r --arg ver "$UPSTREAM_VERSION" '
      .versions
      | map(select(.num == $ver))
      | first
      | .checksum
    ') || die "Failed to extract checksum"

[ -n "$CRATE_CHECKSUM" ] && [ "$CRATE_CHECKSUM" != "null" ] \
    || die "No checksum found for $CRATE_NAME $UPSTREAM_VERSION"

# ── compare versions ─────────────────────────────────────────────────────────

if semver_gt "$UPSTREAM_VERSION" "$CURRENT_VERSION"; then
    UPDATE_AVAILABLE=true
else
    UPDATE_AVAILABLE=false
fi

# ── output ───────────────────────────────────────────────────────────────────

echo "CURRENT_VERSION=${CURRENT_VERSION}"
echo "UPSTREAM_VERSION=${UPSTREAM_VERSION}"
echo "UPDATE_AVAILABLE=${UPDATE_AVAILABLE}"
echo "CRATE_URL=${CRATE_URL}"
echo "CRATE_CHECKSUM=${CRATE_CHECKSUM}"
