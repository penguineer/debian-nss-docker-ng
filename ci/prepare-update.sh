#!/bin/bash
# ci/prepare-update.sh — Prepare a package update for a new upstream release.
#
# Usage:
#   prepare-update.sh [--repo-root DIR] NEW_VERSION CRATE_URL CRATE_CHECKSUM
#
# Options:
#   --repo-root DIR   Operate on DIR instead of the default (the parent directory
#                     of the ci/ directory where this script lives).  Used by
#                     integration tests to direct the script at a fixture checkout
#                     without modifying the real repository.
#
# Required environment (set by the calling workflow):
#   DEBEMAIL    — maintainer email for dch
#   DEBFULLNAME — maintainer name for dch
#
# What this script does:
#   1. Download and verify the upstream .crate archive (aborts on checksum mismatch).
#   2. Synchronise upstream-owned files into the repository tree, preserving
#      packaging-owned paths (.github/, ci/, debian/, docs/, packaging README).
#   3. Re-evaluate the Trixie/MSRV quilt patch.
#   4. Regenerate vendor.tar.gz with .cargo/config.toml and vendor/ (no Cargo.lock).
#   5. Update debian/changelog with the new version.
#   6. Report dependency, patch, and source changes; write DRAFT_PR=true|false.
#
# Packaging-owned files that are NEVER overwritten from the upstream crate:
#   .github/   ci/   debian/   docs/   README.md (top-level packaging README)
#
# Exit codes:
#   0 — success
#   1 — fatal error (repository is not modified on error before step 2 completes)
#
# After this script completes, the repository tree is ready for a commit.
set -euo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo-root)
            REPO_ROOT_OVERRIDE="$(cd "$2" && pwd)"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

NEW_VERSION="${1:?Usage: prepare-update.sh [--repo-root DIR] NEW_VERSION CRATE_URL CRATE_CHECKSUM}"
CRATE_URL="${2:?Missing CRATE_URL}"
EXPECTED_CHECKSUM="${3:?Missing CRATE_CHECKSUM}"

# Default: parent of the ci/ directory where this script lives.
# Tests override this with --repo-root to avoid touching the real checkout.
if [ -n "$REPO_ROOT_OVERRIDE" ]; then
    REPO_ROOT="$REPO_ROOT_OVERRIDE"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

WORK_DIR="$(mktemp -d /tmp/nss-docker-ng-update.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

CRATE_NAME="nss-docker-ng"
CRATE_ARCHIVE="${WORK_DIR}/${CRATE_NAME}-${NEW_VERSION}.tar.gz"
CRATE_EXTRACT="${WORK_DIR}/extracted"
USER_AGENT="debian-nss-docker-ng-updater/1 (https://github.com/penguineer/debian-nss-docker-ng)"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

# ── Packaging-owned paths (never overwritten from upstream crate) ─────────────
# These are paths relative to the repository root that belong to the Debian
# packaging layer.  Any file rooted under one of these prefixes is skipped when
# synchronising the upstream source snapshot.
PACKAGING_OWNED=(
    ".github"
    "ci"
    "debian"
    "docs"
    "vendor.tar.gz"
    "README.md"
)

is_packaging_owned() {
    # $1 = path relative to repo root
    local p="$1"
    local owned
    for owned in "${PACKAGING_OWNED[@]}"; do
        if [ "$p" = "$owned" ] || [[ "$p" == "$owned/"* ]]; then
            return 0
        fi
    done
    return 1
}

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

# ── 2. Extract and synchronise upstream source files ─────────────────────────

mkdir -p "$CRATE_EXTRACT"
tar -xzf "$CRATE_ARCHIVE" -C "$CRATE_EXTRACT"

UPSTREAM_DIR="${CRATE_EXTRACT}/${CRATE_NAME}-${NEW_VERSION}"
[ -d "$UPSTREAM_DIR" ] || die "Expected directory $UPSTREAM_DIR not found in crate archive"

[ -f "$UPSTREAM_DIR/Cargo.toml" ] || die "No Cargo.toml in upstream crate"
[ -f "$UPSTREAM_DIR/Cargo.lock" ] || die "No Cargo.lock in upstream crate"

OLD_CARGO_LOCK="${WORK_DIR}/Cargo.lock.old"
cp "$REPO_ROOT/Cargo.lock" "$OLD_CARGO_LOCK"

info "Synchronising upstream source files into $REPO_ROOT (preserving packaging-owned paths)"

while IFS= read -r -d '' upstream_file; do
    rel="${upstream_file#$UPSTREAM_DIR/}"
    if is_packaging_owned "$rel"; then
        info "  skipping (packaging-owned): $rel"
    else
        dest="$REPO_ROOT/$rel"
        mkdir -p "$(dirname "$dest")"
        cp "$upstream_file" "$dest"
    fi
done < <(find "$UPSTREAM_DIR" -type f -print0)

while IFS= read -r -d '' repo_file; do
    rel="${repo_file#$REPO_ROOT/}"
    is_packaging_owned "$rel" && continue
    [[ "$rel" == ".git/"* ]] && continue
    upstream_counterpart="$UPSTREAM_DIR/$rel"
    if [ ! -f "$upstream_counterpart" ]; then
        info "  removing (deleted upstream): $rel"
        rm "$repo_file"
    fi
done < <(find "$REPO_ROOT" -type f -not -path "$REPO_ROOT/.git/*" -print0)

info "Upstream source synchronisation complete"

# ── 3. Evaluate Trixie/MSRV quilt patch ──────────────────────────────────────

PATCH_DIR="$REPO_ROOT/debian/patches"
PATCH_SERIES="$PATCH_DIR/series"
MSRV_PATCH=$(grep -m1 'trixie' "$PATCH_SERIES" 2>/dev/null || echo "")

PATCH_STATUS="not-applicable"
PATCH_FILE=""

if [ -n "$MSRV_PATCH" ] && [ -f "$PATCH_DIR/$MSRV_PATCH" ]; then
    PATCH_FILE="$PATCH_DIR/$MSRV_PATCH"
    info "Evaluating $MSRV_PATCH against new upstream"

    cd "$REPO_ROOT"
    if patch --dry-run -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
        info "Patch applies cleanly — keeping as-is"
        PATCH_STATUS="applied"
    else
        info "Patch does not apply cleanly — checking if it is still needed"
        NEW_RUST_VERSION=$(grep -oP '(?<=^rust-version = ")[^"]+' "$UPSTREAM_DIR/Cargo.toml" || true)
        if [ -n "$NEW_RUST_VERSION" ]; then
            info "Upstream now declares rust-version = $NEW_RUST_VERSION — patch may be obsolete"
            PATCH_STATUS="possibly-obsolete"
        else
            PATCH_STATUS="needs-review"
        fi
        echo ""
        echo "⚠️  PATCH REVIEW REQUIRED: $MSRV_PATCH"
        echo "   Status: $PATCH_STATUS"
        echo "   A human must review and update the patch before this PR can be merged."
    fi
fi

# ── 4. Regenerate vendor.tar.gz ───────────────────────────────────────────────

cd "$REPO_ROOT"
if [ "$PATCH_STATUS" = "applied" ]; then
    info "Applying patch before vendoring"
    patch -p1 < "$PATCH_FILE"
fi

info "Running cargo vendor"
VENDOR_DIR="${WORK_DIR}/vendor"
CARGO_CONFIG_DIR="${WORK_DIR}/.cargo"
mkdir -p "$VENDOR_DIR" "$CARGO_CONFIG_DIR"

VENDOR_CONFIG=$(cargo vendor --locked "$VENDOR_DIR" 2>/dev/null \
    || cargo vendor "$VENDOR_DIR" 2>/dev/null \
    || die "cargo vendor failed")

cat > "$CARGO_CONFIG_DIR/config.toml" <<EOF
$VENDOR_CONFIG
EOF

if [ "$PATCH_STATUS" = "applied" ]; then
    patch -R -p1 < "$PATCH_FILE"
fi

find "$VENDOR_DIR" -name "Cargo.lock" -delete

info "Creating vendor.tar.gz (.cargo/config.toml + vendor/, no Cargo.lock)"
tar -czf "$REPO_ROOT/vendor.tar.gz" \
    --owner=0 --group=0 \
    -C "$WORK_DIR" \
    .cargo \
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

CARGO_TOML_CHANGED=false
git -C "$REPO_ROOT" diff --quiet HEAD -- Cargo.toml 2>/dev/null || CARGO_TOML_CHANGED=true

CARGO_LOCK_CHANGED=false
if ! diff -q "$OLD_CARGO_LOCK" "$REPO_ROOT/Cargo.lock" >/dev/null 2>&1; then
    CARGO_LOCK_CHANGED=true
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo " Package update summary"
echo "════════════════════════════════════════════════════════════"
echo " Previous upstream: $OLD_UPSTREAM"
echo " New upstream:      $NEW_VERSION"
echo " Crate URL:         $CRATE_URL"
echo " Checksum (sha256): $ACTUAL_CHECKSUM"
echo " Repo root:         $REPO_ROOT"
echo ""
echo " Cargo.toml changed:      $CARGO_TOML_CHANGED"
echo " Cargo.lock changed:      $CARGO_LOCK_CHANGED"
echo " Patch status:            $PATCH_STATUS"

if [ "$PATCH_STATUS" = "needs-review" ] || [ "$PATCH_STATUS" = "possibly-obsolete" ]; then
    echo ""
    echo "⚠️  ACTION REQUIRED: The Trixie/MSRV patch needs human review."
    echo "   This PR is opened as a DRAFT to flag the unresolved point."
fi

echo ""
echo " Cargo.lock diff (stat):"
git diff --no-index --stat \
    "$OLD_CARGO_LOCK" \
    "$REPO_ROOT/Cargo.lock" 2>/dev/null || true

echo "════════════════════════════════════════════════════════════"
echo ""

DRAFT_PR=false
if [ "$PATCH_STATUS" = "needs-review" ] || [ "$PATCH_STATUS" = "possibly-obsolete" ]; then
    DRAFT_PR=true
fi

echo "DRAFT_PR=${DRAFT_PR}"
echo "CARGO_TOML_CHANGED=${CARGO_TOML_CHANGED}"
echo "CARGO_LOCK_CHANGED=${CARGO_LOCK_CHANGED}"
echo "PATCH_STATUS=${PATCH_STATUS}"
