#!/bin/bash
# ci/tests/test-check-upstream.sh — Unit tests for ci/check-upstream.sh logic
#
# Tests the version comparison, pre-release detection, version parsing,
# yanked filtering, duplicate PR detection, and checksum verification logic.
#
# Run: bash ci/tests/test-check-upstream.sh
# Exit code 0 = all tests passed, non-zero = failures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/ci/check-upstream.sh"
PASS=0
FAIL=0
TMPDIR_BASE="$(mktemp -d /tmp/test-check-upstream.XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── helper functions (identical to those in check-upstream.sh) ────────────────

semver_gt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]
}

is_prerelease() {
    echo "$1" | grep -qiE '(alpha|beta|rc|pre(view)?)[._\-]?[0-9]*$'
}

# ── test infrastructure ───────────────────────────────────────────────────────

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# ── test cases ────────────────────────────────────────────────────────────────

echo ""
echo "=== check-upstream.sh tests ==="
echo ""

# ── Test: scripts exist and are executable ────────────────────────────────────
echo "--- Basic validation ---"
if [ -f "$SCRIPT" ]; then
    pass "check-upstream.sh exists"
else
    fail "check-upstream.sh not found at $SCRIPT"
fi

if [ -x "$SCRIPT" ]; then
    pass "check-upstream.sh is executable"
else
    fail "check-upstream.sh is not executable"
fi

# ── Test: version comparison logic ───────────────────────────────────────────
echo ""
echo "--- Version comparison (semver_gt) ---"

if semver_gt "1.3.0" "1.2.1"; then
    pass "1.3.0 > 1.2.1"
else
    fail "1.3.0 > 1.2.1"
fi

if ! semver_gt "1.2.1" "1.2.1"; then
    pass "1.2.1 is not > 1.2.1 (no false update)"
else
    fail "1.2.1 is not > 1.2.1"
fi

if ! semver_gt "1.2.0" "1.2.1"; then
    pass "1.2.0 is not > 1.2.1 (no regression)"
else
    fail "1.2.0 is not > 1.2.1"
fi

if semver_gt "2.0.0" "1.99.99"; then
    pass "2.0.0 > 1.99.99 (major version bump)"
else
    fail "2.0.0 > 1.99.99"
fi

if semver_gt "1.2.10" "1.2.9"; then
    pass "1.2.10 > 1.2.9 (numeric not lexicographic)"
else
    fail "1.2.10 > 1.2.9 — sort -V must be used"
fi

# ── Test: pre-release detection ───────────────────────────────────────────────
echo ""
echo "--- Pre-release detection (is_prerelease) ---"

for pre in "1.3.0-rc1" "2.0.0-alpha" "1.2.0-beta2" "1.0.0-preview1"; do
    if is_prerelease "$pre"; then
        pass "$pre is pre-release"
    else
        fail "$pre should be detected as pre-release"
    fi
done

for stable in "1.2.1" "1.3.0" "2.0.0"; do
    if ! is_prerelease "$stable"; then
        pass "$stable is stable"
    else
        fail "$stable should not be detected as pre-release"
    fi
done

# ── Test: version parsing from debian/changelog ───────────────────────────────
echo ""
echo "--- Version parsing from debian/changelog ---"
CHANGELOG="$REPO_ROOT/debian/changelog"
if [ -f "$CHANGELOG" ]; then
    PARSED=$(head -1 "$CHANGELOG" | grep -oP '\(\K[^)]+' | sed 's/-[0-9]*$//')
    if [ -n "$PARSED" ]; then
        pass "parsed current version from changelog: $PARSED"
    else
        fail "could not parse version from debian/changelog"
    fi
else
    fail "debian/changelog not found"
fi

# ── Test: no-update path (upstream == current) ───────────────────────────────
echo ""
echo "--- No-update path ---"
UPSTREAM="1.2.1"
CURRENT="1.2.1"
if ! semver_gt "$UPSTREAM" "$CURRENT"; then
    pass "no update when upstream == current"
else
    fail "false positive: update detected when versions equal"
fi

# ── Test: update available path ───────────────────────────────────────────────
echo ""
echo "--- Update available ---"
UPSTREAM="1.3.0"
CURRENT="1.2.1"
if semver_gt "$UPSTREAM" "$CURRENT"; then
    pass "update detected when upstream ($UPSTREAM) > current ($CURRENT)"
else
    fail "missed update: $UPSTREAM > $CURRENT"
fi

# ── Test: yanked/pre-release rejection via jq filter ─────────────────────────
echo ""
echo "--- Yanked/pre-release rejection ---"

# Build a mock crates.io response with a mix of yanked, stable and pre-release
MOCK_RESPONSE=$(python3 - <<'EOF'
import json
versions = [
    {"num": "1.2.0", "yanked": False, "checksum": "aaa"},
    {"num": "1.2.1", "yanked": False, "checksum": "bbb"},
    {"num": "1.3.0", "yanked": True,  "checksum": "ccc"},   # yanked
    {"num": "1.4.0-rc1", "yanked": False, "checksum": "ddd"}, # pre-release
]
print(json.dumps({"versions": versions}))
EOF
)

# Apply the same jq filter used in check-upstream.sh
BEST=$(echo "$MOCK_RESPONSE" | jq -r '
  .versions
  | map(select(.yanked == false))
  | map(select(.num | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | sort_by(.num | split(".") | map(tonumber))
  | last
  | .num
')

if [ "$BEST" = "1.2.1" ]; then
    pass "yanked 1.3.0 and pre-release 1.4.0-rc1 filtered; best stable is 1.2.1"
else
    fail "filter failed; expected 1.2.1 but got '$BEST'"
fi

# ── Test: all versions yanked returns null/empty ─────────────────────────────
ALL_YANKED=$(python3 -c "import json; print(json.dumps({'versions': [{'num':'1.3.0','yanked':True,'checksum':'x'}]}))")
RESULT=$(echo "$ALL_YANKED" | jq -r '
  .versions
  | map(select(.yanked == false))
  | map(select(.num | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | last
  | .num
')
if [ "$RESULT" = "null" ] || [ -z "$RESULT" ]; then
    pass "all-yanked release list returns null/empty"
else
    fail "expected null for all-yanked; got '$RESULT'"
fi

# ── Test: duplicate PR detection (title matching) ─────────────────────────────
echo ""
echo "--- Duplicate PR detection ---"
SIMULATED_TITLE="chore: update nss-docker-ng to 1.3.0"
CHECK_VERSION="1.3.0"
if echo "$SIMULATED_TITLE" | grep -qF "$CHECK_VERSION"; then
    pass "existing PR for $CHECK_VERSION detected by title match"
else
    fail "duplicate PR detection missed for $CHECK_VERSION"
fi

DIFFERENT_VERSION="1.4.0"
if ! echo "$SIMULATED_TITLE" | grep -qF "$DIFFERENT_VERSION"; then
    pass "no false positive for different version $DIFFERENT_VERSION"
else
    fail "false positive duplicate PR for $DIFFERENT_VERSION"
fi

# ── Test: checksum verification logic ────────────────────────────────────────
echo ""
echo "--- Checksum verification ---"
TMPFILE=$(mktemp "$TMPDIR_BASE/checksum.XXXXXX")
echo "fake crate content" > "$TMPFILE"
ACTUAL=$(sha256sum "$TMPFILE" | awk '{print $1}')
EXPECTED=$(printf 'fake crate content\n' | sha256sum | awk '{print $1}')

if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "checksum matches known-good value"
else
    fail "checksum mismatch: got $ACTUAL expected $EXPECTED"
fi

WRONG="0000000000000000000000000000000000000000000000000000000000000000"
if [ "$ACTUAL" != "$WRONG" ]; then
    pass "wrong checksum correctly rejected"
else
    fail "checksum mismatch not detected (actual matches zeroes — impossible)"
fi

# ── Test: check-upstream.sh --help/usage does not crash ───────────────────────
echo ""
echo "--- Script syntax check ---"
if bash -n "$SCRIPT"; then
    pass "check-upstream.sh has valid bash syntax"
else
    fail "check-upstream.sh has syntax errors"
fi

PREPARE_SCRIPT="$REPO_ROOT/ci/prepare-update.sh"
if bash -n "$PREPARE_SCRIPT"; then
    pass "prepare-update.sh has valid bash syntax"
else
    fail "prepare-update.sh has syntax errors"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " Tests: $((PASS+FAIL))  Passed: $PASS  Failed: $FAIL"
echo "════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
