#!/bin/bash
# ci/prepare-update.sh — Prepare a package update for a new upstream release.
#
# Usage:
#   prepare-update.sh NEW_VERSION CRATE_URL CRATE_CHECKSUM
#
# Required environment (set by the calling workflow):
#   DEBEMAIL   — maintainer email for dch
#   DEBFULLNAME — maintainer name for dch
#
# What this script does:
#   1. Download and verify the upstream .crate archive.
#   2. Extract Cargo.toml and Cargo.lock from the new release.
#   3. Re-evaluate the Trixie/MSRV quilt patch (apply, test, skip if unneeded).
#   4. Regenerate vendor.tar.gz from the final patched dependency state.
#   5. Update debian/changelog with the new version.
#   6. Report dependency, patch, and notable changes to stdout.
#
# Exit codes:
#   0 — success
#   1 — fatal error
#
# After this script completes, the repository tree is ready for a commit.
set -euo pipefail

NEW_VERSION="${1:?Usage: prepare-update.sh NEW_VERSION CRATE_URL CRATE_CHECKSUM}"
CRATE_URL="${2:?Missing CRATE_URL}"
EXPECTED_CHECKSUM="${3:?Missing CRATE_CHECKSUM}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d /tmp/nss-docker-ng-update.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

CRATE_NAME="nss-docker-ng"
CRATE_ARCHIVE="${WORK_DIR}/${CRATE_NAME}-${NEW_VERSION}.tar.gz"
CRATE_EXTRACT="${WORK_DIR}/extracted"
USER_AGENT="debian-nss-docker-ng-updater/1 (https://github.com/penguineer/debian-nss-docker-ng)"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

# ── 1. Download and verify ────────────────────────────────────────────────────

info "Downloading $CRATE_NAME $NEW_VERSION from $CRATE_URL"
curl --silent --fail \
    --max-time 120 \
    --retry 3 \
    --retry-delay 5 \
    --user-agent "$USER_AGENT" \
    --location \
    --output "$CRATE_ARCHIVE" \
    "$CRATE_URL" || die "Download failed"

info "Verifying checksum"
ACTUAL_CHECKSUM=$(sha256sum "$CRATE_ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
    die "Checksum mismatch: expected $EXPECTED_CHECKSUM, got $ACTUAL_CHECKSUM"
fi
info "Checksum OK: $ACTUAL_CHECKSUM"

# ── 2. Extract upstream Cargo.toml and Cargo.lock ────────────────────────────

mkdir -p "$CRATE_EXTRACT"
tar -xzf "$CRATE_ARCHIVE" -C "$CRATE_EXTRACT"

# The crate extracts into a directory named <name>-<version>/
UPSTREAM_DIR="${CRATE_EXTRACT}/${CRATE_NAME}-${NEW_VERSION}"
[ -d "$UPSTREAM_DIR" ] || die "Expected directory $UPSTREAM_DIR not found in crate archive"

[ -f "$UPSTREAM_DIR/Cargo.toml" ] || die "No Cargo.toml in upstream crate"
[ -f "$UPSTREAM_DIR/Cargo.lock" ] || die "No Cargo.lock in upstream crate"

info "Updating Cargo.toml and Cargo.lock from upstream"
# Save the previous Cargo.lock for the diff report at the end
OLD_CARGO_LOCK="${WORK_DIR}/Cargo.lock.old"
cp "$REPO_ROOT/Cargo.lock" "$OLD_CARGO_LOCK"
cp "$UPSTREAM_DIR/Cargo.toml" "$REPO_ROOT/Cargo.toml"
cp "$UPSTREAM_DIR/Cargo.lock" "$REPO_ROOT/Cargo.lock"

# ── 3. Evaluate Trixie/MSRV quilt patch ──────────────────────────────────────

PATCH_DIR="$REPO_ROOT/debian/patches"
PATCH_SERIES="$PATCH_DIR/series"
MSRV_PATCH=$(grep -m1 'trixie' "$PATCH_SERIES" 2>/dev/null || echo "")

PATCH_STATUS="not-applicable"

if [ -n "$MSRV_PATCH" ] && [ -f "$PATCH_DIR/$MSRV_PATCH" ]; then
    PATCH_FILE="$PATCH_DIR/$MSRV_PATCH"
    info "Evaluating $MSRV_PATCH against new upstream"

    # Try applying the patch in dry-run mode
    cd "$REPO_ROOT"
    if patch --dry-run -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
        info "Patch applies cleanly — keeping as-is"
        PATCH_STATUS="applied"
    else
        info "Patch does not apply cleanly — attempting to check if it is still needed"

        # Check if the patch's intent (adding rust-version and dep caps) is
        # already present in the new Cargo.toml.  If upstream already caps the
        # deps at suitable versions, the patch may not be needed.
        NEW_RUST_VERSION=$(grep -oP '(?<=^rust-version = ")[^"]+' "$UPSTREAM_DIR/Cargo.toml" || true)
        if [ -n "$NEW_RUST_VERSION" ]; then
            info "Upstream now declares rust-version = $NEW_RUST_VERSION — patch may be obsolete"
            PATCH_STATUS="possibly-obsolete"
        else
            PATCH_STATUS="needs-review"
        fi
        echo ""
        echo "⚠️  PATCH REVIEW REQUIRED: $MSRV_PATCH"
        echo "   The Trixie/MSRV patch does not apply cleanly to the new upstream."
        echo "   Status: $PATCH_STATUS"
        echo "   A human must review and update the patch before this PR can be merged."
    fi
fi

# ── 4. Regenerate vendor.tar.gz ───────────────────────────────────────────────

# Apply the patch if it is still applicable before vendoring
cd "$REPO_ROOT"
if [ "$PATCH_STATUS" = "applied" ]; then
    info "Applying patch before vendoring"
    patch -p1 < "$PATCH_FILE"
fi

info "Running cargo vendor"
VENDOR_DIR="${WORK_DIR}/vendor"
mkdir -p "$VENDOR_DIR"

# cargo vendor into a temp dir so we can control the archive
cargo vendor --locked "$VENDOR_DIR" >/dev/null 2>&1 \
    || cargo vendor "$VENDOR_DIR" >/dev/null 2>&1 \
    || die "cargo vendor failed"

# Revert patch before re-checking tree (the patch is stored in debian/patches)
if [ "$PATCH_STATUS" = "applied" ]; then
    patch -R -p1 < "$PATCH_FILE"
fi

info "Creating vendor.tar.gz (excluding Cargo.lock)"
# Remove any Cargo.lock that cargo vendor may have written inside vendor
find "$VENDOR_DIR" -name "Cargo.lock" -delete

tar -czf "$REPO_ROOT/vendor.tar.gz" \
    --owner=0 --group=0 \
    -C "$WORK_DIR" \
    vendor

info "vendor.tar.gz created"

# ── 5. Update debian/changelog ───────────────────────────────────────────────

OLD_VERSION=$(head -1 "$REPO_ROOT/debian/changelog" | grep -oP '\(\K[^)]+')
OLD_UPSTREAM=$(echo "$OLD_VERSION" | sed 's/-[0-9]*$//')
NEW_DEB_VERSION="${NEW_VERSION}-1"

info "Updating debian/changelog: $OLD_VERSION → $NEW_DEB_VERSION"

cd "$REPO_ROOT"
dch \
    --newversion "$NEW_DEB_VERSION" \
    --distribution unstable \
    --urgency low \
    "New upstream release $NEW_VERSION (was $OLD_UPSTREAM)."

# ── 6. Report changes ────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Package update summary"
echo "════════════════════════════════════════════════════════════"
echo " Previous upstream: $OLD_UPSTREAM"
echo " New upstream:      $NEW_VERSION"
echo " Crate URL:         $CRATE_URL"
echo " Checksum (sha256): $ACTUAL_CHECKSUM"
echo ""
echo " Patch status:      $PATCH_STATUS"

if [ "$PATCH_STATUS" = "needs-review" ] || [ "$PATCH_STATUS" = "possibly-obsolete" ]; then
    echo ""
    echo "⚠️  ACTION REQUIRED: The Trixie/MSRV patch needs human review."
    echo "   This PR is created as a DRAFT to flag the unresolved point."
fi

echo ""
echo " Cargo dependency changes (Cargo.lock diff):"
cd "$REPO_ROOT"
git diff --no-index --stat \
    "$OLD_CARGO_LOCK" \
    "$REPO_ROOT/Cargo.lock" 2>/dev/null || true

echo "════════════════════════════════════════════════════════════"
echo ""

# Write a machine-readable flag for the workflow to detect draft state
if [ "$PATCH_STATUS" = "needs-review" ] || [ "$PATCH_STATUS" = "possibly-obsolete" ]; then
    echo "DRAFT_PR=true"
else
    echo "DRAFT_PR=false"
fi
