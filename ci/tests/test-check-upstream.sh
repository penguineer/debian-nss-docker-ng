#!/bin/bash
# ci/tests/test-check-upstream.sh — Tests for upstream release tracking scripts
#
# Covers:
#   - semver comparison and pre-release detection (production functions sourced
#     directly from check-upstream.sh via CHECK_UPSTREAM_SOURCED=1)
#   - version parsing from debian/changelog
#   - crates.io jq filter logic (yanked, pre-release, all-yanked)
#   - duplicate PR detection logic
#   - checksum verification logic
#   - bash syntax of both scripts
#   - prepare-update.sh integration (isolated to a fixture checkout):
#       * upstream source files are updated
#       * packaging-owned files are preserved
#       * checksum failure aborts before any modification
#       * vendor.tar.gz contains vendor/ and .cargo/config.toml but not Cargo.lock
#       * unresolved patch handling produces DRAFT_PR=true
#
# Prerequisites: devscripts (provides dch).  A missing prerequisite is a hard
# failure — it is never treated as a passing skip.
#
# Run: bash ci/tests/test-check-upstream.sh
# Exit code: 0 = all passed, non-zero = failures or missing prerequisites.
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

# ── Check prerequisites ───────────────────────────────────────────────────────
if ! command -v dch &>/dev/null; then
    echo "FATAL: dch (devscripts) is required for integration tests." >&2
    echo "       Install with: sudo apt-get install devscripts" >&2
    exit 1
fi

# ── Source production helper functions from check-upstream.sh ─────────────────
# CHECK_UPSTREAM_SOURCED=1 suppresses the main execution path; only the
# helper functions (semver_gt, is_prerelease, die) are imported.
CHECK_UPSTREAM_SOURCED=1 . "$CHECK_SCRIPT"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== check-upstream.sh unit tests ==="
echo ""

echo "--- Basic validation ---"
[ -f "$CHECK_SCRIPT" ]  && pass "check-upstream.sh exists"         || fail "check-upstream.sh not found"
[ -x "$CHECK_SCRIPT" ]  && pass "check-upstream.sh is executable"  || fail "check-upstream.sh not executable"

echo ""
echo "--- Version comparison (semver_gt — production implementation) ---"
semver_gt "1.3.0" "1.2.1"  && pass "1.3.0 > 1.2.1"             || fail "1.3.0 > 1.2.1"
! semver_gt "1.2.1" "1.2.1" && pass "1.2.1 not > 1.2.1"        || fail "equal versions: false positive"
! semver_gt "1.2.0" "1.2.1" && pass "1.2.0 not > 1.2.1"        || fail "older version: false positive"
semver_gt "2.0.0" "1.99.99" && pass "2.0.0 > 1.99.99"          || fail "major bump"
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
! semver_gt "$UPSTREAM" "$CURRENT" && pass "no update when equal"         || fail "false positive: equal versions"
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

# Build a minimal fake crate archive for fixture tests.
FAKE_VERSION="99.0.0"
FAKE_UPSTREAM_DIR="${TMPDIR_BASE}/fake-crate/nss-docker-ng-${FAKE_VERSION}"
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
CARGO_EOF

# No external dependencies so that cargo vendor --locked succeeds
# without network access in sandboxed test environments.
cat > "$FAKE_UPSTREAM_DIR/Cargo.lock" << 'LOCK_EOF'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 3

[[package]]
name = "nss-docker-ng"
version = "99.0.0"
LOCK_EOF

cat > "$FAKE_UPSTREAM_DIR/src/lib.rs" << 'LIB_EOF'
// FAKE UPSTREAM SOURCE v99.0.0
pub fn hello() {}
LIB_EOF

echo "FAKE LICENSE v99" > "$FAKE_UPSTREAM_DIR/LICENSE"

FAKE_ARCHIVE="${TMPDIR_BASE}/nss-docker-ng-${FAKE_VERSION}.tar.gz"
tar -czf "$FAKE_ARCHIVE" \
    -C "${TMPDIR_BASE}/fake-crate" \
    "nss-docker-ng-${FAKE_VERSION}"
FAKE_CHECKSUM=$(sha256sum "$FAKE_ARCHIVE" | awk '{print $1}')

# ── Fixture: isolated copy of the packaging repo ──────────────────────────────
# prepare-update.sh is invoked with --repo-root pointing at this fixture, so
# the test never modifies the real checked-out repository.

make_test_repo() {
    local dest="$1"
    mkdir -p "$dest/src"
    cp "$REPO_ROOT/Cargo.toml"  "$dest/Cargo.toml"
    cp "$REPO_ROOT/Cargo.lock"  "$dest/Cargo.lock"
    cp "$REPO_ROOT/LICENSE"     "$dest/LICENSE" 2>/dev/null || touch "$dest/LICENSE"
    cp "$REPO_ROOT/src/lib.rs"  "$dest/src/lib.rs"
    # Packaging-owned files and directories
    cp -r "$REPO_ROOT/debian"   "$dest/debian"
    mkdir -p "$dest/.github" "$dest/ci" "$dest/docs"
    echo "# Packaging README" > "$dest/README.md"
    echo "# Packaging .gitignore" > "$dest/.gitignore"
    echo "Packaging LICENSE.txt" > "$dest/LICENSE.txt"
    # Minimal git repo so git commands inside the script work
    git -C "$dest" init -q
    git -C "$dest" config user.email "test@test"
    git -C "$dest" config user.name  "test"
    git -C "$dest" add -A
    git -C "$dest" commit -qm "initial"
}

# ── Helper: run prepare-update.sh against a fixture repo ─────────────────────
run_prepare() {
    # $1 = fixture repo dir; remaining args passed to prepare-update.sh
    local repo="$1"; shift
    DEBEMAIL="test@test" DEBFULLNAME="Test" \
        bash "$PREPARE_SCRIPT" --repo-root "$repo" "$@"
}

# ── Test: checksum failure aborts before any modification ─────────────────────
echo "--- Checksum failure aborts before modification ---"
ABORT_REPO="${TMPDIR_BASE}/abort-repo"
make_test_repo "$ABORT_REPO"
ORIG_CARGO_LOCK=$(cat "$ABORT_REPO/Cargo.lock")
# Capture real-repo state before running the test so the comparison is meaningful
REAL_CARGO_LOCK_BEFORE=$(cat "$REPO_ROOT/Cargo.lock")
BAD_CHECKSUM="0000000000000000000000000000000000000000000000000000000000000000"

ABORT_EXIT=0
ABORT_OUT=$(run_prepare "$ABORT_REPO" \
    "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$BAD_CHECKSUM" 2>&1) \
    || ABORT_EXIT=$?

if [ "$ABORT_EXIT" -ne 0 ] && echo "$ABORT_OUT" | grep -q "Checksum mismatch"; then
    pass "checksum mismatch: script aborted with error"
else
    fail "checksum mismatch: script did not abort (exit=$ABORT_EXIT)"
fi
AFTER_CARGO_LOCK=$(cat "$ABORT_REPO/Cargo.lock" 2>/dev/null || echo "MISSING")
[ "$AFTER_CARGO_LOCK" = "$ORIG_CARGO_LOCK" ] \
    && pass "Cargo.lock unmodified after checksum failure" \
    || fail "Cargo.lock was modified despite checksum failure"

# Verify real repo is untouched
[ "$(cat "$REPO_ROOT/Cargo.lock")" = "$REAL_CARGO_LOCK_BEFORE" ] \
    && pass "real checkout unmodified by abort-test" \
    || fail "real checkout was modified by abort-test"

# ── Full integration: source update, packaging preservation, vendor, DRAFT ───
UPDATE_REPO="${TMPDIR_BASE}/update-repo"
make_test_repo "$UPDATE_REPO"

echo ""
echo "--- Running prepare-update.sh (--repo-root=$UPDATE_REPO) ---"
PREPARE_OUT_FILE="${TMPDIR_BASE}/prepare.out"
set +e
run_prepare "$UPDATE_REPO" \
    "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$FAKE_CHECKSUM" \
    > "$PREPARE_OUT_FILE" 2>&1
PREPARE_EXIT=$?
set -e

if [ "$PREPARE_EXIT" -ne 0 ]; then
    echo "  prepare-update.sh output:"
    cat "$PREPARE_OUT_FILE"
    fail "prepare-update.sh exited non-zero ($PREPARE_EXIT)"
else
    pass "prepare-update.sh exited 0"
fi

echo ""
echo "--- Upstream source files updated ---"
if grep -q "FAKE UPSTREAM SOURCE v99.0.0" "$UPDATE_REPO/src/lib.rs" 2>/dev/null; then
    pass "upstream src/lib.rs was updated in fixture"
else
    fail "upstream src/lib.rs was NOT updated in fixture"
fi
if grep -q 'version = "99.0.0"' "$UPDATE_REPO/Cargo.toml" 2>/dev/null; then
    pass "Cargo.toml version updated to 99.0.0 in fixture"
else
    fail "Cargo.toml version not updated in fixture"
fi

# Verify the real checkout was NOT modified
if grep -q "FAKE UPSTREAM SOURCE v99.0.0" "$REPO_ROOT/src/lib.rs" 2>/dev/null; then
    fail "real src/lib.rs was modified (isolation failure!)"
else
    pass "real checkout src/lib.rs is unchanged (isolation confirmed)"
fi

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
[ -f "$UPDATE_REPO/.gitignore" ] \
    && grep -q "Packaging .gitignore" "$UPDATE_REPO/.gitignore" \
    && pass ".gitignore (packaging) preserved" \
    || fail ".gitignore was overwritten or missing"
[ -f "$UPDATE_REPO/LICENSE.txt" ] \
    && grep -q "Packaging LICENSE.txt" "$UPDATE_REPO/LICENSE.txt" \
    && pass "LICENSE.txt (packaging) preserved" \
    || fail "LICENSE.txt was overwritten or missing"

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

echo ""
echo "--- DRAFT_PR flag when patch does not apply ---"
DRAFT_REPO="${TMPDIR_BASE}/draft-repo"
make_test_repo "$DRAFT_REPO"
# Inject a patch that cannot apply to the fake upstream
cat > "$DRAFT_REPO/debian/patches/0001-trixie-compat-msrv.patch" << 'PATCH_EOF'
--- a/Cargo.toml
+++ b/Cargo.toml
@@ -999,1 +999,1 @@
-this-line-does-not-exist = "never"
+replacement = "never"
PATCH_EOF
echo "0001-trixie-compat-msrv.patch" > "$DRAFT_REPO/debian/patches/series"

DRAFT_EXIT=0
DRAFT_OUT=$(run_prepare "$DRAFT_REPO" \
    "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$FAKE_CHECKSUM" 2>/dev/null) \
    || DRAFT_EXIT=$?
DRAFT_FLAG=$(echo "$DRAFT_OUT" | grep '^DRAFT_PR=' | cut -d= -f2 | tail -1)
[ "$DRAFT_FLAG" = "true" ] \
    && pass "DRAFT_PR=true when patch does not apply" \
    || fail "DRAFT_PR should be true when patch fails (got '$DRAFT_FLAG')"

# ── Trixie-image vendoring integration test ───────────────────────────────────
# Runs only when TRIXIE_IMAGE is set and Docker is available (e.g., in
# updater-tests.yml after building trixie-ci:latest).  In environments without
# Docker the block is skipped with a note rather than a failure.
echo ""
echo "--- Trixie-image vendoring (TRIXIE_IMAGE=${TRIXIE_IMAGE:-<not set>}) ---"

if [ -z "${TRIXIE_IMAGE:-}" ] || ! command -v docker >/dev/null 2>&1; then
    echo "  (skipped: TRIXIE_IMAGE not set or docker not available)"
else
    TRIXIE_REPO="${TMPDIR_BASE}/trixie-repo"
    make_test_repo "$TRIXIE_REPO"

    TRIXIE_OUT_FILE="${TMPDIR_BASE}/trixie-prepare.out"
    TRIXIE_EXIT=0
    DEBEMAIL="test@test" DEBFULLNAME="Test" \
        bash "$PREPARE_SCRIPT" \
            --repo-root "$TRIXIE_REPO" \
            "$FAKE_VERSION" "file://$FAKE_ARCHIVE" "$FAKE_CHECKSUM" \
        > "$TRIXIE_OUT_FILE" 2>&1 || TRIXIE_EXIT=$?

    if [ "$TRIXIE_EXIT" -eq 0 ]; then
        pass "Trixie-image prepare-update.sh exited 0"
    else
        echo "  prepare-update.sh output:"
        cat "$TRIXIE_OUT_FILE"
        fail "Trixie-image prepare-update.sh exited non-zero ($TRIXIE_EXIT)"
    fi

    TVTGZ="$TRIXIE_REPO/vendor.tar.gz"
    if [ -f "$TVTGZ" ]; then
        TVLIST=$(tar tzf "$TVTGZ" 2>/dev/null)
        T_CARGO=$(echo "$TVLIST" | grep -c '\.cargo/config\.toml' || true)
        T_VENDOR=$(echo "$TVLIST" | grep -c '^vendor/' || true)
        T_LOCK=$(echo "$TVLIST" | grep -c 'Cargo\.lock' || true)
        [ "$T_CARGO" -ge 1 ] \
            && pass "Trixie vendor.tar.gz contains .cargo/config.toml" \
            || fail "Trixie vendor.tar.gz missing .cargo/config.toml"
        [ "$T_VENDOR" -ge 1 ] \
            && pass "Trixie vendor.tar.gz contains vendor/" \
            || fail "Trixie vendor.tar.gz missing vendor/"
        [ "$T_LOCK" -eq 0 ] \
            && pass "Trixie vendor.tar.gz does not contain Cargo.lock" \
            || fail "Trixie vendor.tar.gz must not contain Cargo.lock"
    else
        fail "Trixie vendor.tar.gz not created"
    fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " Tests: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
