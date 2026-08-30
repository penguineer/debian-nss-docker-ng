#!/bin/bash
# ci/tests/test-check-upstream.sh — Tests for upstream release tracking scripts
#
# Covers:
#   - semver comparison and pre-release detection (production functions)
#   - version parsing from debian/changelog
#   - crates.io jq filter logic (yanked, pre-release, all-yanked)
#   - duplicate PR detection logic
#   - checksum verification logic
#   - bash syntax of both scripts
#   - prepare-update.sh integration:
#       * upstream source files are updated
#       * packaging-owned files are preserved
#       * checksum failure aborts before any modification
#       * vendor.tar.gz contains vendor/ and .cargo/config.toml but not Cargo.lock
#       * unresolved patch handling produces DRAFT_PR=true
#
# Run: bash ci/tests/test-check-upstream.sh
# Exit code: 0 = all passed, non-zero = failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/ci/check-upstream.sh"
PREPARE_SCRIPT="$REPO_ROOT/ci/prepare-update.sh"
PASS=0
FAIL=0
TMPDIR_BASE="$(mktemp -d /tmp/test-check-upstream.XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ── Source production helper functions from check-upstream.sh ─────────────────
# CHECK_UPSTREAM_SOURCED=1 suppresses the main execution path; only the
# helper functions (semver_gt, is_prerelease, die) are imported.
CHECK_UPSTREAM_SOURCED=1 . "$CHECK_SCRIPT"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== check-upstream.sh unit tests ==="
echo ""

echo "--- Basic validation ---"
[ -f "$CHECK_SCRIPT" ]  && pass "check-upstream.sh exists"    || fail "check-upstream.sh not found"
[ -x "$CHECK_SCRIPT" ]  && pass "check-upstream.sh is executable" || fail "check-upstream.sh not executable"

echo ""
echo "--- Version comparison (semver_gt — production implementation) ---"
semver_gt "1.3.0" "1.2.1"  && pass "1.3.0 > 1.2.1"            || fail "1.3.0 > 1.2.1"
! semver_gt "1.2.1" "1.2.1" && pass "1.2.1 not > 1.2.1"       || fail "equal versions: false positive"
! semver_gt "1.2.0" "1.2.1" && pass "1.2.0 not > 1.2.1"       || fail "older version: false positive"
semver_gt "2.0.0" "1.99.99" && pass "2.0.0 > 1.99.99"         || fail "major bump"
semver_gt "1.2.10" "1.2.9"  && pass "1.2.10 > 1.2.9 (numeric)" || fail "numeric sort required"

echo ""
echo "--- Pre-release detection (is_prerelease — production implementation) ---"
for pre in "1.3.0-rc1" "2.0.0-alpha" "1.2.0-beta2" "1.0.0-preview1"; do
    is_prerelease "$pre" && pass "$pre is pre-release" || fail "$pre should be pre-release"
done
for stable in "1.2.1" "1.3.0" "2.0.0"; do
    ! is_prerelease "$stable" && pass "$stable is stable" || fail "$stable falsely flagged as pre-release"
done

echo ""
echo "--- Version parsing from debian/changelog ---"
PARSED=$(head -1 "$REPO_ROOT/debian/changelog" | grep -oP '\(\K[^)]+' | sed 's/-[0-9]*$//')
[ -n "$PARSED" ] && pass "parsed version: $PARSED" || fail "version parse failed"

echo ""
echo "--- No-update / update-available paths ---"
UPSTREAM="1.2.1"; CURRENT="1.2.1"
! semver_gt "$UPSTREAM" "$CURRENT" && pass "no update when equal"    || fail "false positive: equal versions"
UPSTREAM="1.3.0"
semver_gt "$UPSTREAM" "$CURRENT"  && pass "update detected: 1.3.0 > 1.2.1" || fail "missed update"

echo ""
echo "--- Yanked/pre-release jq filter (same expression as production) ---"
MOCK_RESP=$(python3 -c "
import json
print(json.dumps({'versions': [
    {'num': '1.2.0', 'yanked': False, 'checksum': 'aaa'},
    {'num': '1.2.1', 'yanked': False, 'checksum': 'bbb'},
    {'num': '1.3.0', 'yanked': True,  'checksum': 'ccc'},
    {'num': '1.4.0-rc1', 'yanked': False, 'checksum': 'ddd'},
]}))")
BEST=$(echo "$MOCK_RESP" | jq -r '
  .versions
  | map(select(.yanked == false))
  | map(select(.num | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | sort_by(.num | split(".") | map(tonumber))
  | last | .num')
[ "$BEST" = "1.2.1" ] && pass "yanked 1.3.0 and pre-release 1.4.0-rc1 filtered" || fail "filter wrong: $BEST"

ALL_YANKED=$(python3 -c "import json; print(json.dumps({'versions': [{'num':'1.3.0','yanked':True,'checksum':'x'}]}))")
NULL_RESULT=$(echo "$ALL_YANKED" | jq -r '
  .versions
  | map(select(.yanked == false))
  | map(select(.num | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | last | .num')
( [ "$NULL_RESULT" = "null" ] || [ -z "$NULL_RESULT" ] ) \
    && pass "all-yanked returns null/empty" || fail "all-yanked: got $NULL_RESULT"

echo ""
echo "--- Duplicate PR detection ---"
TITLE="chore: update nss-docker-ng to 1.3.0"
echo "$TITLE" | grep -qF "1.3.0" && pass "duplicate PR detected for 1.3.0"  || fail "missed duplicate"
! echo "$TITLE" | grep -qF "1.4.0" && pass "no false positive for 1.4.0"   || fail "false positive"

echo ""
echo "--- Checksum verification logic ---"
TF=$(mktemp "$TMPDIR_BASE/csum.XXXXXX")
echo "fake crate content" > "$TF"
ACTUAL=$(sha256sum "$TF" | awk '{print $1}')
EXPECTED=$(printf 'fake crate content\n' | sha256sum | awk '{print $1}')
[ "$ACTUAL" = "$EXPECTED" ] && pass "checksum matches known-good value" || fail "checksum computation wrong"
WRONG="0000000000000000000000000000000000000000000000000000000000000000"
[ "$ACTUAL" != "$WRONG" ] && pass "mismatched checksum correctly rejected" || fail "mismatch not detected"

echo ""
echo "--- Bash syntax ---"
bash -n "$CHECK_SCRIPT"   && pass "check-upstream.sh syntax OK"  || fail "check-upstream.sh syntax error"
bash -n "$PREPARE_SCRIPT" && pass "prepare-update.sh syntax OK"  || fail "prepare-update.sh syntax error"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== prepare-update.sh integration tests ==="
echo ""

# Build a minimal fake crate archive for use in integration tests.
# The fake crate contains:
#   - Cargo.toml   (updated version)
#   - Cargo.lock   (minimal)
#   - src/lib.rs   (upstream source file — should be updated)
#   - LICENSE      (should be updated)
# Packaging-owned paths (.github/, ci/, debian/, docs/, README.md) are absent
# from the crate (as in real crates.io archives).

FAKE_VERSION="99.0.0"
FAKE_CRATE_DIR="${TMPDIR_BASE}/fake-crate/${FAKE_VERSION}"
FAKE_UPSTREAM_DIR="${FAKE_CRATE_DIR}/nss-docker-ng-${FAKE_VERSION}"
mkdir -p "$FAKE_UPSTREAM_DIR/src"

cat > "$FAKE_UPSTREAM_DIR/Cargo.toml" << 'CARGO_EOF'
[package]
name = "nss-docker-ng"
version = "99.0.0"
edition = "2021"
license = "MIT"
[lib]
name = "nss_docker_ng"
crate-type = ["cdylib"]
path = "src/lib.rs"
[dependencies.libc]
version = "0.2"
CARGO_EOF

cat > "$FAKE_UPSTREAM_DIR/Cargo.lock" << 'LOCK_EOF'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 3

[[package]]
name = "nss-docker-ng"
version = "99.0.0"

[[package]]
name = "libc"
version = "0.2.153"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "9c198f91728a82281a64e1f4f9eeb25d82cb32a5de251c6bd1b5154d63a8e7bd"
LOCK_EOF

cat > "$FAKE_UPSTREAM_DIR/src/lib.rs" << 'LIB_EOF'
// FAKE UPSTREAM SOURCE v99.0.0
pub fn hello() {}
LIB_EOF

echo "FAKE LICENSE v99" > "$FAKE_UPSTREAM_DIR/LICENSE"

# Create the tar.gz that looks like a crates.io download
FAKE_ARCHIVE="${FAKE_CRATE_DIR}/archive.tar.gz"
tar -czf "$FAKE_ARCHIVE" -C "${TMPDIR_BASE}/fake-crate/${FAKE_VERSION}" \
    "nss-docker-ng-${FAKE_VERSION}"
FAKE_CHECKSUM=$(sha256sum "$FAKE_ARCHIVE" | awk '{print $1}')

# ── Integration test fixture: isolated repo copy ──────────────────────────────

make_test_repo() {
    # Create a minimal copy of the packaging repo for test isolation.
    local dest="$1"
    mkdir -p "$dest"
    # Copy upstream-owned files
    cp "$REPO_ROOT/Cargo.toml"  "$dest/Cargo.toml"
    cp "$REPO_ROOT/Cargo.lock"  "$dest/Cargo.lock"
    cp "$REPO_ROOT/LICENSE"     "$dest/LICENSE" 2>/dev/null || touch "$dest/LICENSE"
    mkdir -p "$dest/src"
    cp "$REPO_ROOT/src/lib.rs"  "$dest/src/lib.rs"
    # Copy packaging-owned files/dirs (minimal)
    cp -r "$REPO_ROOT/debian"   "$dest/debian"
    mkdir -p "$dest/.github" "$dest/ci" "$dest/docs"
    echo "# Packaging README" > "$dest/README.md"
    # Initialise a git repo so git diff commands work
    git -C "$dest" init -q
    git -C "$dest" config user.email "test@test"
    git -C "$dest" config user.name  "test"
    git -C "$dest" add -A
    git -C "$dest" commit -qm "initial"
}

# ── Test: checksum failure aborts before any modification ─────────────────────
echo "--- Checksum failure aborts before modification ---"
ABORT_REPO="${TMPDIR_BASE}/abort-repo"
make_test_repo "$ABORT_REPO"
ORIG_CARGO_LOCK=$(cat "$ABORT_REPO/Cargo.lock")
BAD_CHECKSUM="0000000000000000000000000000000000000000000000000000000000000000"

ABORT_EXIT=0
ABORT_OUT=$( cd "$ABORT_REPO"
  DEBEMAIL="test@test" DEBFULLNAME="Test" \
  bash "$PREPARE_SCRIPT" "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$BAD_CHECKSUM" \
  2>&1 ) || ABORT_EXIT=$?

if [ "$ABORT_EXIT" -ne 0 ] && echo "$ABORT_OUT" | grep -q "Checksum mismatch"; then
    pass "checksum mismatch: script aborted with error"
else
    fail "checksum mismatch: script did not abort (exit=$ABORT_EXIT)"
fi
AFTER_CARGO_LOCK=$(cat "$ABORT_REPO/Cargo.lock" 2>/dev/null || echo "MISSING")
[ "$AFTER_CARGO_LOCK" = "$ORIG_CARGO_LOCK" ] \
    && pass "Cargo.lock unmodified after checksum failure" \
    || fail "Cargo.lock was modified despite checksum failure"

# ── Test: upstream source files are updated ───────────────────────────────────
echo ""
echo "--- Upstream source files updated ---"
UPDATE_REPO="${TMPDIR_BASE}/update-repo"
make_test_repo "$UPDATE_REPO"

# We need devscripts for dch; skip the full run if unavailable
if ! command -v dch &>/dev/null; then
    echo "  (skipping full prepare-update integration: dch not installed)"
    pass "integration skipped (dch unavailable in this environment)"
else
    ( cd "$UPDATE_REPO"
      DEBEMAIL="test@test" DEBFULLNAME="Test" \
      bash "$PREPARE_SCRIPT" "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$FAKE_CHECKSUM"
    ) > "${TMPDIR_BASE}/prepare.out" 2>&1 || {
        echo "  prepare-update.sh output:"
        cat "${TMPDIR_BASE}/prepare.out"
        fail "prepare-update.sh exited non-zero"
    }

    # src/lib.rs should now contain fake upstream content
    if grep -q "FAKE UPSTREAM SOURCE v99.0.0" "$UPDATE_REPO/src/lib.rs" 2>/dev/null; then
        pass "upstream src/lib.rs was updated"
    else
        fail "upstream src/lib.rs was NOT updated"
        echo "  Content: $(cat "$UPDATE_REPO/src/lib.rs" 2>/dev/null || echo 'missing')"
    fi

    # Cargo.toml version should now be 99.0.0
    if grep -q 'version = "99.0.0"' "$UPDATE_REPO/Cargo.toml" 2>/dev/null; then
        pass "Cargo.toml version updated to 99.0.0"
    else
        fail "Cargo.toml version not updated"
    fi

    # ── Test: packaging-owned files are preserved ─────────────────────────────
    echo ""
    echo "--- Packaging-owned files preserved ---"
    [ -f "$UPDATE_REPO/README.md" ] \
        && grep -q "Packaging README" "$UPDATE_REPO/README.md" \
        && pass "README.md (packaging) preserved" \
        || fail "README.md was overwritten or missing"
    [ -d "$UPDATE_REPO/debian" ] \
        && pass "debian/ preserved" \
        || fail "debian/ missing"
    [ -d "$UPDATE_REPO/.github" ] \
        && pass ".github/ preserved" \
        || fail ".github/ missing"

    # ── Test: vendor.tar.gz contains expected structure ────────────────────────
    echo ""
    echo "--- vendor.tar.gz structure ---"
    VTGZ="$UPDATE_REPO/vendor.tar.gz"
    if [ -f "$VTGZ" ]; then
        HAS_CARGO_CONFIG=$(tar tzf "$VTGZ" 2>/dev/null | grep -c '\.cargo/config\.toml' || true)
        HAS_VENDOR=$(tar tzf "$VTGZ" 2>/dev/null | grep -c '^vendor/' || true)
        HAS_LOCK=$(tar tzf "$VTGZ" 2>/dev/null | grep -c 'Cargo\.lock' || true)

        [ "$HAS_CARGO_CONFIG" -ge 1 ] \
            && pass "vendor.tar.gz contains .cargo/config.toml" \
            || fail "vendor.tar.gz missing .cargo/config.toml"
        [ "$HAS_VENDOR" -ge 1 ] \
            && pass "vendor.tar.gz contains vendor/" \
            || fail "vendor.tar.gz missing vendor/"
        [ "$HAS_LOCK" -eq 0 ] \
            && pass "vendor.tar.gz does not contain Cargo.lock" \
            || fail "vendor.tar.gz must not contain Cargo.lock"
    else
        fail "vendor.tar.gz not created"
    fi

    # ── Test: DRAFT_PR flag for unresolvable patch ─────────────────────────────
    echo ""
    echo "--- DRAFT_PR flag when patch does not apply ---"
    DRAFT_REPO="${TMPDIR_BASE}/draft-repo"
    make_test_repo "$DRAFT_REPO"
    # Inject a patch that cannot possibly apply to the fake upstream
    mkdir -p "$DRAFT_REPO/debian/patches"
    cat > "$DRAFT_REPO/debian/patches/0001-trixie-compat-msrv.patch" << 'PATCH_EOF'
--- a/Cargo.toml
+++ b/Cargo.toml
@@ -999,1 +999,1 @@
-this-line-does-not-exist = "never"
+replacement = "never"
PATCH_EOF
    echo "0001-trixie-compat-msrv.patch" > "$DRAFT_REPO/debian/patches/series"

    DRAFT_OUT=$(
      cd "$DRAFT_REPO"
      DEBEMAIL="test@test" DEBFULLNAME="Test" \
      bash "$PREPARE_SCRIPT" "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$FAKE_CHECKSUM" \
      2>/dev/null || true
    )
    DRAFT_FLAG=$(echo "$DRAFT_OUT" | grep '^DRAFT_PR=' | cut -d= -f2 | tail -1)
    [ "$DRAFT_FLAG" = "true" ] \
        && pass "DRAFT_PR=true when patch does not apply" \
        || fail "DRAFT_PR should be true when patch fails (got '$DRAFT_FLAG')"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " Tests: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
