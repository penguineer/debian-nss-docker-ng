#!/bin/bash
# ci/create-update-pr.sh — Construct and open the upstream-update pull request.
#
# Builds the PR body from metadata collected during the prepare step and opens
# the PR via gh.  If the upstream-update label is missing it falls back to
# creating a PR without it, rather than aborting.
#
# The automation ownership marker written into the PR body is the string used
# by reconcile-yanked-prs.sh to identify automation-owned PRs:
#   "This PR was created automatically by the upstream-release-check workflow."
# Do not change this string without updating reconcile-yanked-prs.sh.
#
# Usage:
#   create-update-pr.sh
#
# Required environment:
#   NEW_VERSION        — new upstream version (e.g. 1.3.0)
#   CURRENT_VERSION    — current packaged version (e.g. 1.2.1)
#   BRANCH             — update branch name (e.g. upstream-update/1.3.0)
#   COMMIT_SHA         — SHA of the prepared commit
#   DRAFT_PR           — "true" to open as draft
#   CRATE_URL          — crates.io download URL
#   CRATE_CHECKSUM     — sha256 of the crate archive
#   CARGO_TOML_CHANGED — "true"/"false"
#   CARGO_LOCK_CHANGED — "true"/"false"
#   PATCH_STATUS       — patch evaluation result
#   GH_TOKEN           — GitHub token with pull-requests:write
#
# Exit codes:
#   0 — PR created (or already existed)
#   1 — fatal error
set -euo pipefail

NEW_VERSION="${NEW_VERSION:?NEW_VERSION must be set}"
CURRENT_VERSION="${CURRENT_VERSION:?CURRENT_VERSION must be set}"
BRANCH="${BRANCH:?BRANCH must be set}"
COMMIT_SHA="${COMMIT_SHA:?COMMIT_SHA must be set}"
DRAFT_PR="${DRAFT_PR:?DRAFT_PR must be set}"
CRATE_URL="${CRATE_URL:?CRATE_URL must be set}"
CRATE_CHECKSUM="${CRATE_CHECKSUM:?CRATE_CHECKSUM must be set}"
CARGO_TOML_CHANGED="${CARGO_TOML_CHANGED:?CARGO_TOML_CHANGED must be set}"
CARGO_LOCK_CHANGED="${CARGO_LOCK_CHANGED:?CARGO_LOCK_CHANGED must be set}"
PATCH_STATUS="${PATCH_STATUS:?PATCH_STATUS must be set}"

CRATES_PAGE="https://crates.io/crates/nss-docker-ng/${NEW_VERSION}"

# ── build PR body ─────────────────────────────────────────────────────────────

build_pr_body() {
    local draft_note=""
    if [ "${DRAFT_PR}" = "true" ]; then
        draft_note=$'\n\n> **⚠️ DRAFT:** The Trixie/MSRV quilt patch requires human review before this PR can be merged. See CI output for details.'
    fi

    cat <<EOF
## Upstream release: nss-docker-ng ${NEW_VERSION}

| Field | Value |
|-------|-------|
| Previous upstream version | \`${CURRENT_VERSION}\` |
| New upstream version | \`${NEW_VERSION}\` |
| Crate archive URL | [download](${CRATE_URL}) |
| crates.io release page | [${CRATES_PAGE}](${CRATES_PAGE}) |
| Archive checksum (sha256) | \`${CRATE_CHECKSUM}\` |
| Update branch commit | \`${COMMIT_SHA}\` |

### Observed changes

| Item | Changed |
|------|---------|
| \`Cargo.toml\` | ${CARGO_TOML_CHANGED} |
| \`Cargo.lock\` / dependency set | ${CARGO_LOCK_CHANGED} |
| Trixie/MSRV quilt patch | status: ${PATCH_STATUS} |

See the [CI run for branch \`${BRANCH}\`](../actions) for the full dependency diff and patch evaluation output.

### Review checklist

- [ ] Upstream release notes reviewed (see crates.io page above)
- [ ] Dependency changes acceptable (\`Cargo.lock\` diff in CI output)
- [ ] Quilt patch status confirmed (applied / updated / dropped as needed)
- [ ] License/copyright metadata reviewed if \`Cargo.toml\` changed
- [ ] CI passes on this branch
- [ ] Package installs and smoke test passes${draft_note}

---
*This PR was created automatically by the upstream-release-check workflow.*
EOF
}

# ── determine draft flag ──────────────────────────────────────────────────────

DRAFT_FLAG=""
if [ "$DRAFT_PR" = "true" ]; then
    DRAFT_FLAG="--draft"
fi

# ── create PR ─────────────────────────────────────────────────────────────────

PR_BODY=$(build_pr_body)
PR_TITLE="chore: update nss-docker-ng to ${NEW_VERSION}"

gh pr create \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --base main \
    --head "$BRANCH" \
    --label "upstream-update" \
    $DRAFT_FLAG \
    || gh pr create \
        --title "$PR_TITLE" \
        --body "$PR_BODY" \
        --base main \
        --head "$BRANCH" \
        $DRAFT_FLAG
