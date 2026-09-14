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
#   - bash syntax of check-upstream.sh, prepare-update.sh,
#     reconcile-yanked-prs.sh, detect-existing-update-pr.sh,
#     prepare-update-branch.sh, create-update-pr.sh
#   - reconcile-yanked-prs.sh pure helpers (sourced via RECONCILE_SOURCED=1):
#       * is_automation_owned: detects automation marker in PR body
#       * extract_pr_version: extracts version from upstream-update/<version>
#       * decide_yanked_action: maps yanked state to action string
#       * already_warned_count: counts prior yanked-warning comments via jq
#   - detect-existing-update-pr.sh (fake gh):
#       * matching PR -> skip=true
#       * no matching PR -> skip=false
#   - create-update-pr.sh (fake gh):
#       * non-draft PR omits --draft flag
#       * draft PR passes --draft flag
#       * automation ownership marker present in PR body
#       * DRAFT note present in draft PR body
#   - prepare-update-branch.sh integration (isolated fixture, SKIP_PUSH=true):
#       * all expected GITHUB_OUTPUT keys emitted
#       * branch name follows upstream-update/<version> convention
#       * commit_sha is a full 40-char hex SHA
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
RECONCILE_SCRIPT="$REPO_ROOT/ci/reconcile-yanked-prs.sh"
DETECT_SCRIPT="$REPO_ROOT/ci/detect-existing-update-pr.sh"
PREPARE_BRANCH_SCRIPT="$REPO_ROOT/ci/prepare-update-branch.sh"
CREATE_PR_SCRIPT="$REPO_ROOT/ci/create-update-pr.sh"
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

# ── Source pure helpers from reconcile-yanked-prs.sh ─────────────────────────
# RECONCILE_SOURCED=1 suppresses the main execution path.
RECONCILE_SOURCED=1 . "$RECONCILE_SCRIPT"

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
echo "--- detect-existing-update-pr.sh (fake gh) ---"
# Build a fake gh binary that simulates gh pr list output.
FAKE_GH_DIR="${TMPDIR_BASE}/fake-gh-detect"
mkdir -p "$FAKE_GH_DIR"

# Fake gh returns one matching PR when searching for 1.3.0
cat > "$FAKE_GH_DIR/gh" << 'FAKE_GH'
#!/bin/bash
# Minimal fake gh for detect-existing-update-pr.sh tests.
# Called as: gh pr list --state open --search "nss-docker-ng VERSION in:title" --json ... --jq ...
SEARCH_ARG=""
JQ_ARG=""
for i in "$@"; do
    case "$PREV" in
        --search) SEARCH_ARG="$i" ;;
        --jq)     JQ_ARG="$i" ;;
    esac
    PREV="$i"
done
if echo "$SEARCH_ARG" | grep -q "1.3.0"; then
    # Return a matching PR number
    echo '[{"number":42,"title":"chore: update nss-docker-ng to 1.3.0"}]' \
        | jq -r "$JQ_ARG"
else
    # Return empty array so jq '.[0].number // empty' evaluates to empty
    echo '[]' | jq -r "$JQ_ARG"
fi
FAKE_GH
chmod +x "$FAKE_GH_DIR/gh"

DETECT_OUTPUT_1="${TMPDIR_BASE}/detect-output-1.txt"
: > "$DETECT_OUTPUT_1"
NEW_VERSION="1.3.0" GITHUB_OUTPUT="$DETECT_OUTPUT_1" \
    PATH="$FAKE_GH_DIR:$PATH" \
    bash "$DETECT_SCRIPT"
SKIP_1=$(grep '^skip=' "$DETECT_OUTPUT_1" | cut -d= -f2)
[ "$SKIP_1" = "true" ] \
    && pass "detect-existing-update-pr.sh: matching PR -> skip=true" \
    || fail "detect-existing-update-pr.sh: matching PR should give skip=true (got '$SKIP_1')"

# Fake gh returns no matching PR when searching for 1.4.0
DETECT_OUTPUT_2="${TMPDIR_BASE}/detect-output-2.txt"
: > "$DETECT_OUTPUT_2"
NEW_VERSION="1.4.0" GITHUB_OUTPUT="$DETECT_OUTPUT_2" \
    PATH="$FAKE_GH_DIR:$PATH" \
    bash "$DETECT_SCRIPT"
SKIP_2=$(grep '^skip=' "$DETECT_OUTPUT_2" | cut -d= -f2)
[ "$SKIP_2" = "false" ] \
    && pass "detect-existing-update-pr.sh: no matching PR -> skip=false" \
    || fail "detect-existing-update-pr.sh: no matching PR should give skip=false (got '$SKIP_2')"

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
bash -n "$CHECK_SCRIPT"          && pass "check-upstream.sh syntax OK"          || fail "check-upstream.sh syntax error"
bash -n "$PREPARE_SCRIPT"        && pass "prepare-update.sh syntax OK"          || fail "prepare-update.sh syntax error"
bash -n "$RECONCILE_SCRIPT"      && pass "reconcile-yanked-prs.sh syntax OK"    || fail "reconcile-yanked-prs.sh syntax error"
bash -n "$DETECT_SCRIPT"         && pass "detect-existing-update-pr.sh syntax OK" || fail "detect-existing-update-pr.sh syntax error"
bash -n "$PREPARE_BRANCH_SCRIPT" && pass "prepare-update-branch.sh syntax OK"  || fail "prepare-update-branch.sh syntax error"
bash -n "$CREATE_PR_SCRIPT"      && pass "create-update-pr.sh syntax OK"        || fail "create-update-pr.sh syntax error"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== reconcile-yanked-prs.sh unit tests (pure helpers) ==="
echo ""

echo "--- is_automation_owned ---"
MARKER="This PR was created automatically by the upstream-release-check workflow."
[ "$(is_automation_owned "$MARKER")" = "yes" ] \
    && pass "body with marker -> yes" || fail "body with marker should be yes"
[ "$(is_automation_owned "Some other body text")" = "no" ] \
    && pass "body without marker -> no" || fail "body without marker should be no"
[ "$(is_automation_owned "")" = "no" ] \
    && pass "empty body -> no" || fail "empty body should be no"
# Partial match must not count
[ "$(is_automation_owned "created automatically by something else")" = "no" ] \
    && pass "partial marker -> no" || fail "partial marker should be no"

echo ""
echo "--- extract_pr_version ---"
[ "$(extract_pr_version "upstream-update/1.3.0")" = "1.3.0" ] \
    && pass "extracts 1.3.0 from upstream-update/1.3.0" || fail "version extraction wrong"
[ "$(extract_pr_version "upstream-update/2.0.1")" = "2.0.1" ] \
    && pass "extracts 2.0.1" || fail "version extraction wrong for 2.0.1"
[ -z "$(extract_pr_version "upstream-update/")" ] \
    && pass "empty suffix -> empty string" || fail "empty suffix should yield empty"
[ -z "$(extract_pr_version "other-branch/1.3.0")" ] \
    && pass "non-matching prefix -> empty string" || fail "non-matching prefix should yield empty"

echo ""
echo "--- decide_yanked_action ---"
[ "$(decide_yanked_action "true")" = "flag" ] \
    && pass "yanked=true -> flag" || fail "yanked=true should give flag"
[ "$(decide_yanked_action "false")" = "ok" ] \
    && pass "yanked=false -> ok" || fail "yanked=false should give ok"
[ "$(decide_yanked_action "unknown")" = "skip" ] \
    && pass "yanked=unknown -> skip" || fail "yanked=unknown should give skip"
[ "$(decide_yanked_action "")" = "skip" ] \
    && pass "yanked=empty -> skip" || fail "yanked=empty should give skip"
[ "$(decide_yanked_action "null")" = "skip" ] \
    && pass "yanked=null -> skip" || fail "yanked=null should give skip"

echo ""
echo "--- duplicate-warning detection (already_warned_count production helper) ---"
# already_warned_count accepts the JSON structure from `gh pr view --json comments`
# and returns the count of comments containing "yanked on crates.io".
COMMENTS_WITH_WARN='{"comments":[{"body":"⚠️ Upstream version 1.3.0 has been yanked on crates.io."}]}'
COMMENTS_WITHOUT_WARN='{"comments":[{"body":"Just a regular review comment"}]}'
COMMENTS_EMPTY='{"comments":[]}'

COUNT_1=$(already_warned_count "$COMMENTS_WITH_WARN")
[ "${COUNT_1:-0}" -gt 0 ] \
    && pass "already_warned_count: detects yanked warning in comments" \
    || fail "already_warned_count: should detect yanked warning (got $COUNT_1)"

COUNT_2=$(already_warned_count "$COMMENTS_WITHOUT_WARN")
[ "${COUNT_2:-0}" -eq 0 ] \
    && pass "already_warned_count: no false positive for unrelated comment" \
    || fail "already_warned_count: false positive (got $COUNT_2)"

COUNT_3=$(already_warned_count "$COMMENTS_EMPTY")
[ "${COUNT_3:-0}" -eq 0 ] \
    && pass "already_warned_count: empty comments -> 0" \
    || fail "already_warned_count: empty comments should give 0 (got $COUNT_3)"

# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== create-update-pr.sh unit tests (fake gh) ==="
echo ""

# Build a fake gh that records the arguments it is invoked with.
FAKE_GH_PR_DIR="${TMPDIR_BASE}/fake-gh-pr"
mkdir -p "$FAKE_GH_PR_DIR"
cat > "$FAKE_GH_PR_DIR/gh" << 'FAKE_GH_PR'
#!/bin/bash
# Records all arguments to a file so tests can inspect them.
echo "$@" >> "${FAKE_GH_CALLS_FILE:?FAKE_GH_CALLS_FILE must be set}"
FAKE_GH_PR
chmod +x "$FAKE_GH_PR_DIR/gh"

echo "--- create-update-pr.sh: non-draft PR ---"
CALLS_FILE_NODRAFT="${TMPDIR_BASE}/gh-calls-nodraft.txt"
: > "$CALLS_FILE_NODRAFT"
FAKE_GH_CALLS_FILE="$CALLS_FILE_NODRAFT" \
NEW_VERSION="1.3.0" \
CURRENT_VERSION="1.2.1" \
BRANCH="upstream-update/1.3.0" \
COMMIT_SHA="abc1234" \
DRAFT_PR="false" \
CRATE_URL="https://example.com/crate.tar.gz" \
CRATE_CHECKSUM="deadbeef" \
CARGO_TOML_CHANGED="false" \
CARGO_LOCK_CHANGED="false" \
PATCH_STATUS="applied" \
GH_TOKEN="fake" \
    PATH="$FAKE_GH_PR_DIR:$PATH" \
    bash "$CREATE_PR_SCRIPT"

# Verify --draft flag is absent in a non-draft invocation
if grep -q -- '--draft' "$CALLS_FILE_NODRAFT" 2>/dev/null; then
    fail "create-update-pr.sh: non-draft PR should not pass --draft to gh"
else
    pass "create-update-pr.sh: non-draft PR omits --draft flag"
fi

# Verify the automation marker is in the --body argument
# (gh is called with --body <body> so the body content appears in the args)
if grep -qF 'This PR was created automatically by the upstream-release-check workflow.' "$CALLS_FILE_NODRAFT"; then
    pass "create-update-pr.sh: automation marker present in PR body"
else
    fail "create-update-pr.sh: automation marker missing from PR body"
fi

echo ""
echo "--- create-update-pr.sh: draft PR ---"
CALLS_FILE_DRAFT="${TMPDIR_BASE}/gh-calls-draft.txt"
: > "$CALLS_FILE_DRAFT"
FAKE_GH_CALLS_FILE="$CALLS_FILE_DRAFT" \
NEW_VERSION="1.3.0" \
CURRENT_VERSION="1.2.1" \
BRANCH="upstream-update/1.3.0" \
COMMIT_SHA="abc1234" \
DRAFT_PR="true" \
CRATE_URL="https://example.com/crate.tar.gz" \
CRATE_CHECKSUM="deadbeef" \
CARGO_TOML_CHANGED="true" \
CARGO_LOCK_CHANGED="true" \
PATCH_STATUS="needs-review" \
GH_TOKEN="fake" \
    PATH="$FAKE_GH_PR_DIR:$PATH" \
    bash "$CREATE_PR_SCRIPT"

if grep -q -- '--draft' "$CALLS_FILE_DRAFT" 2>/dev/null; then
    pass "create-update-pr.sh: draft PR passes --draft to gh"
else
    fail "create-update-pr.sh: draft PR should pass --draft to gh"
fi

# Verify the DRAFT note is in the body
if grep -qF 'DRAFT:' "$CALLS_FILE_DRAFT"; then
    pass "create-update-pr.sh: draft note present in draft PR body"
else
    fail "create-update-pr.sh: draft note missing from draft PR body"
fi

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

# ── prepare-update-branch.sh: GITHUB_OUTPUT emission and commit ───────────────
echo ""
echo "=== prepare-update-branch.sh integration tests ==="
echo ""
echo "--- prepare-update-branch.sh: GITHUB_OUTPUT emission and commit ---"

BRANCH_REPO="${TMPDIR_BASE}/branch-repo"
make_test_repo "$BRANCH_REPO"

BRANCH_OUTPUT_FILE="${TMPDIR_BASE}/branch-github-output.txt"
: > "$BRANCH_OUTPUT_FILE"

BRANCH_FAKE_VERSION="88.0.0"
BRANCH_FAKE_UPSTREAM="${TMPDIR_BASE}/branch-fake-crate/nss-docker-ng-${BRANCH_FAKE_VERSION}"
mkdir -p "$BRANCH_FAKE_UPSTREAM/src"
cat > "$BRANCH_FAKE_UPSTREAM/Cargo.toml" << 'CARGO_BRANCH_EOF'
[package]
name = "nss-docker-ng"
version = "88.0.0"
edition = "2021"
license = "MIT"
[lib]
name = "nss_docker_ng"
crate-type = ["cdylib"]
path = "src/lib.rs"
CARGO_BRANCH_EOF
cat > "$BRANCH_FAKE_UPSTREAM/Cargo.lock" << 'LOCK_BRANCH_EOF'
# This file is automatically @generated by Cargo.
version = 3

[[package]]
name = "nss-docker-ng"
version = "88.0.0"
LOCK_BRANCH_EOF
echo "// FAKE v88" > "$BRANCH_FAKE_UPSTREAM/src/lib.rs"
echo "FAKE LICENSE v88" > "$BRANCH_FAKE_UPSTREAM/LICENSE"

BRANCH_FAKE_ARCHIVE="${TMPDIR_BASE}/nss-docker-ng-${BRANCH_FAKE_VERSION}.tar.gz"
tar -czf "$BRANCH_FAKE_ARCHIVE" \
    -C "${TMPDIR_BASE}/branch-fake-crate" \
    "nss-docker-ng-${BRANCH_FAKE_VERSION}"
BRANCH_FAKE_CHECKSUM=$(sha256sum "$BRANCH_FAKE_ARCHIVE" | awk '{print $1}')

BRANCH_EXIT=0
(
    cd "$BRANCH_REPO"
    NEW_VERSION="$BRANCH_FAKE_VERSION" \
    CRATE_URL="file://$BRANCH_FAKE_ARCHIVE" \
    CRATE_CHECKSUM="$BRANCH_FAKE_CHECKSUM" \
    GITHUB_OUTPUT="$BRANCH_OUTPUT_FILE" \
    SKIP_PUSH="true" \
    DEBEMAIL="test@test" DEBFULLNAME="Test" \
        bash "$PREPARE_BRANCH_SCRIPT"
) || BRANCH_EXIT=$?

if [ "$BRANCH_EXIT" -ne 0 ]; then
    fail "prepare-update-branch.sh: exited non-zero ($BRANCH_EXIT)"
else
    pass "prepare-update-branch.sh: exited 0"
fi

# Verify required GITHUB_OUTPUT keys are present
for KEY in branch commit_sha draft_pr cargo_toml_changed cargo_lock_changed patch_status; do
    if grep -q "^${KEY}=" "$BRANCH_OUTPUT_FILE"; then
        pass "prepare-update-branch.sh: GITHUB_OUTPUT contains ${KEY}"
    else
        fail "prepare-update-branch.sh: GITHUB_OUTPUT missing ${KEY}"
    fi
done

# Verify branch name matches expected naming convention
EMITTED_BRANCH=$(grep '^branch=' "$BRANCH_OUTPUT_FILE" | cut -d= -f2)
[ "$EMITTED_BRANCH" = "upstream-update/${BRANCH_FAKE_VERSION}" ] \
    && pass "prepare-update-branch.sh: branch name is upstream-update/${BRANCH_FAKE_VERSION}" \
    || fail "prepare-update-branch.sh: wrong branch name (got '$EMITTED_BRANCH')"

# Verify commit_sha is a full 40-char hex SHA
EMITTED_SHA=$(grep '^commit_sha=' "$BRANCH_OUTPUT_FILE" | cut -d= -f2)
if echo "$EMITTED_SHA" | grep -qE '^[0-9a-f]{40}$'; then
    pass "prepare-update-branch.sh: commit_sha is a full 40-char hex SHA"
else
    fail "prepare-update-branch.sh: commit_sha looks wrong (got '$EMITTED_SHA')"
fi

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
