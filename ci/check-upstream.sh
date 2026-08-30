#!/bin/bash
# ci/check-upstream.sh — Check crates.io for a newer stable nss-docker-ng release.
#
# Usage: check-upstream.sh [--current-version VERSION]
#
# Outputs (to stdout, one per line, KEY=VALUE):
#   CURRENT_VERSION=<semver from debian/changelog>
#   UPSTREAM_VERSION=<latest stable crates.io version>
#   UPDATE_AVAILABLE=true|false
#   CRATE_URL=<immutable crates.io download URL>
#   CRATE_CHECKSUM=<sha256 from crates.io index>
#
# Exit codes:
#   0  — success (UPDATE_AVAILABLE may be true or false)
#   1  — hard error (API failure, parse error, yanked/malformed release)
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

# ── determine current packaged version ───────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = "--current-version" ] && [ -n "${2:-}" ]; then
    CURRENT_VERSION="$2"
else
    CHANGELOG="$REPO_ROOT/debian/changelog"
    [ -f "$CHANGELOG" ] || die "debian/changelog not found at $CHANGELOG"
    # First line: "nss-docker-ng (1.2.1-1) unstable; ..."
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

# Select the newest non-yanked, non-pre-release version using jq
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

# Verify this is not a pre-release (belt-and-suspenders)
is_prerelease "$UPSTREAM_VERSION" \
    && die "Latest stable version '$UPSTREAM_VERSION' looks like a pre-release"

# ── get checksum for the upstream version ────────────────────────────────────

CRATE_URL="https://static.crates.io/crates/${CRATE_NAME}/${UPSTREAM_VERSION}/download"

# The checksum is available in the version metadata
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
