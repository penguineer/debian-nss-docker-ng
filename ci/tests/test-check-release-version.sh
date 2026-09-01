#!/bin/bash
# ci/tests/test-check-release-version.sh — Tests for the release version
# consistency validation script (ci/check-release-version.sh).
#
# Covers:
#   - valid tag matching debian/changelog
#   - malformed tag (no debian/ prefix, empty version, spaces)
#   - tag/changelog mismatch
#   - packaging-only Debian revision (e.g. 1.2.1-2)
#   - upstream-vs-Debian-version mismatch
#   - publication path blocked when validation fails
#   - bash syntax of check-release-version.sh
#
# Run: bash ci/tests/test-check-release-version.sh
# Exit code: 0 = all passed, non-zero = one or more failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/ci/check-release-version.sh"
PASS=0
FAIL=0
TMPDIR_BASE="$(mktemp -d /tmp/test-check-release-version.XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Source helper functions for unit tests
CHECK_RELEASE_VERSION_SOURCED=1 REPO_ROOT="$REPO_ROOT" . "$CHECK_SCRIPT"

# ── Helper: build a minimal fake repo root with overridable files ─────────────
make_fake_repo() {
    local dir="$1"
    local deb_ver="${2:-1.2.1-1}"
    local cargo_ver="${3:-1.2.1}"
    mkdir -p "$dir/debian"
    printf 'nss-docker-ng (%s) unstable; urgency=low\n\n  * Test entry.\n\n -- Test <t@t>  Mon, 01 Sep 2026 00:00:00 +0000\n' \
        "$deb_ver" > "$dir/debian/changelog"
    printf '[package]\nname = "nss-docker-ng"\nversion = "%s"\n' \
        "$cargo_ver" > "$dir/Cargo.toml"
}

# Run check-release-version.sh with REPO_ROOT pointing at a fake repo.
run_check() {
    local repo="$1"; shift
    REPO_ROOT="$repo" bash "$CHECK_SCRIPT" "$@" 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== check-release-version.sh unit tests (sourced helpers) ==="
echo ""

echo "--- is_valid_tag_form ---"
is_valid_tag_form "debian/1.2.1-1"  && pass "debian/1.2.1-1 is valid form"      || fail "debian/1.2.1-1 should be valid"
is_valid_tag_form "debian/1.2.1-2"  && pass "debian/1.2.1-2 is valid form"      || fail "debian/1.2.1-2 should be valid"
is_valid_tag_form "debian/2.0.0-1"  && pass "debian/2.0.0-1 is valid form"      || fail "debian/2.0.0-1 should be valid"
! is_valid_tag_form "1.2.1-1"       && pass "bare version rejected"             || fail "bare version should be rejected"
! is_valid_tag_form "v1.2.1"        && pass "v-prefix rejected"                 || fail "v-prefix should be rejected"
! is_valid_tag_form "debian/"       && pass "empty version rejected"            || fail "empty version should be rejected"
! is_valid_tag_form "release/1.2.1" && pass "wrong prefix rejected"             || fail "wrong prefix should be rejected"
! is_valid_tag_form ""              && pass "empty tag rejected"                || fail "empty tag should be rejected"

echo ""
echo "--- upstream_from_deb_version ---"
R=$(upstream_from_deb_version "1.2.1-1");   [ "$R" = "1.2.1" ] && pass "1.2.1-1 → 1.2.1"  || fail "1.2.1-1: got '$R'"
R=$(upstream_from_deb_version "1.2.1-2");   [ "$R" = "1.2.1" ] && pass "1.2.1-2 → 1.2.1"  || fail "1.2.1-2: got '$R'"
R=$(upstream_from_deb_version "2.0.0-1");   [ "$R" = "2.0.0" ] && pass "2.0.0-1 → 2.0.0"  || fail "2.0.0-1: got '$R'"
R=$(upstream_from_deb_version "2:1.2.1-1"); [ "$R" = "1.2.1" ] && pass "epoch 2:1.2.1-1 → 1.2.1" || fail "epoch: got '$R'"

echo ""
echo "--- changelog_version (real repo) ---"
PARSED=$(REPO_ROOT="$REPO_ROOT" changelog_version)
[ -n "$PARSED" ] && pass "parsed real changelog: $PARSED" || fail "failed to parse real changelog"

echo ""
echo "--- cargo_version (real repo) ---"
CV=$(REPO_ROOT="$REPO_ROOT" cargo_version)
[ -n "$CV" ] && pass "parsed real Cargo.toml: $CV" || fail "failed to parse real Cargo.toml"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== check-release-version.sh integration tests ==="
echo ""

echo "--- Valid tag matching changelog ---"
REPO_VALID="$TMPDIR_BASE/valid"
make_fake_repo "$REPO_VALID" "1.2.1-1" "1.2.1"
OUT=$(run_check "$REPO_VALID" "debian/1.2.1-1"); EXIT=$?
[ "$EXIT" -eq 0 ] \
    && pass "valid tag exits 0" \
    || fail "valid tag should exit 0 (got $EXIT; output: $OUT)"
echo "$OUT" | grep -q "PASSED" \
    && pass "output contains PASSED" \
    || fail "output should contain PASSED"

echo ""
echo "--- Malformed tag: no prefix ---"
REPO_M="$TMPDIR_BASE/malformed"
make_fake_repo "$REPO_M" "1.2.1-1" "1.2.1"
OUT=$(run_check "$REPO_M" "1.2.1-1" 2>&1 || true)
echo "$OUT" | grep -q "ERROR" \
    && pass "bare version produces ERROR" \
    || fail "bare version should produce ERROR"

echo ""
echo "--- Malformed tag: wrong prefix ---"
OUT=$(run_check "$REPO_M" "v1.2.1-1" 2>&1 || true)
echo "$OUT" | grep -q "ERROR" \
    && pass "v-prefix produces ERROR" \
    || fail "v-prefix should produce ERROR"

echo ""
echo "--- Tag/changelog mismatch ---"
REPO_MISMATCH="$TMPDIR_BASE/mismatch"
make_fake_repo "$REPO_MISMATCH" "1.2.1-1" "1.2.1"
OUT=$(run_check "$REPO_MISMATCH" "debian/1.2.1-2" 2>&1 || true)
echo "$OUT" | grep -q "ERROR" \
    && pass "tag/changelog mismatch produces ERROR" \
    || fail "tag/changelog mismatch should produce ERROR"

echo ""
echo "--- Packaging-only revision (1.2.1-2) ---"
REPO_REV="$TMPDIR_BASE/revision"
make_fake_repo "$REPO_REV" "1.2.1-2" "1.2.1"
OUT=$(run_check "$REPO_REV" "debian/1.2.1-2"); EXIT=$?
[ "$EXIT" -eq 0 ] \
    && pass "packaging-only revision 1.2.1-2 exits 0" \
    || fail "packaging-only revision should succeed (got $EXIT)"

echo ""
echo "--- Upstream/Debian version mismatch (Cargo.toml disagrees) ---"
REPO_UPVER="$TMPDIR_BASE/upstream-mismatch"
make_fake_repo "$REPO_UPVER" "1.2.1-1" "1.3.0"
OUT=$(run_check "$REPO_UPVER" "debian/1.2.1-1" 2>&1 || true)
echo "$OUT" | grep -q "ERROR" \
    && pass "upstream/Debian mismatch produces ERROR" \
    || fail "upstream/Debian mismatch should produce ERROR"

echo ""
echo "--- Publication path blocked on failure ---"
# The script exits non-zero on any mismatch; verify exit code
REPO_BLOCK="$TMPDIR_BASE/blocked"
make_fake_repo "$REPO_BLOCK" "1.2.1-1" "1.2.1"
EXIT=0
run_check "$REPO_BLOCK" "debian/9.9.9-1" >/dev/null 2>&1 || EXIT=$?
[ "$EXIT" -ne 0 ] \
    && pass "mismatched tag exits non-zero ($EXIT) — publication path blocked" \
    || fail "mismatched tag should exit non-zero"

echo ""
echo "--- Bash syntax ---"
bash -n "$CHECK_SCRIPT" && pass "check-release-version.sh syntax OK" || fail "syntax error"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " Tests: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
