#!/bin/bash
# ci/reconcile-yanked-prs.sh — Reconcile open upstream-update PRs against crates.io yanked state.
#
# For each open automation-created upstream-update/<version> PR, check whether
# the version it tracks is still non-yanked on crates.io.  If it has been yanked,
# add the "yanked-upstream" label and post a warning comment (once only, to avoid
# duplicate comments on repeated runs).  PRs not carrying the exact automation
# marker are never touched.
#
# Usage:
#   reconcile-yanked-prs.sh [--dry-run]
#
# Options:
#   --dry-run   Print what would be done without making any GitHub mutations.
#
# Required environment:
#   GH_TOKEN   — GitHub token with pull-requests:write and issues:write
#
# Optional environment:
#   CRATE_NAME  — crates.io crate name (default: nss-docker-ng)
#   USER_AGENT  — User-Agent header for crates.io requests
#
# Exit codes:
#   0 — completed (mutations made or --dry-run; crates.io unavailable is a soft warning)
#   1 — hard error (gh CLI failure on an expected step)
#
# Pure helper functions in this script (decide_yanked_action, is_automation_owned,
# extract_pr_version) are sourced by tests via RECONCILE_SOURCED=1.
set -euo pipefail

CRATE_NAME="${CRATE_NAME:-nss-docker-ng}"
USER_AGENT="${USER_AGENT:-debian-nss-docker-ng-updater/1 (https://github.com/penguineer/debian-nss-docker-ng)}"

# Automation ownership marker — must match the string written by create-update-pr.sh
AUTOMATION_MARKER="This PR was created automatically by the upstream-release-check workflow."

DRY_RUN=false

# ── helpers (pure — no GitHub I/O; tested independently) ─────────────────────

# Determine whether a PR body contains the automation marker.
# Outputs: "yes" or "no"
is_automation_owned() {
    local body="$1"
    if echo "$body" | grep -qF "$AUTOMATION_MARKER"; then
        echo "yes"
    else
        echo "no"
    fi
}

# Extract the upstream version from an upstream-update/<version> branch name.
# Outputs the version string, or empty string on failure.
extract_pr_version() {
    local branch="$1"
    local ver="${branch#upstream-update/}"
    if [ "$ver" = "$branch" ] || [ -z "$ver" ]; then
        echo ""
    else
        echo "$ver"
    fi
}

# Decide what action to take for a given yanked status string.
# Inputs: yanked_status = "true" | "false" | "unknown" | anything else
# Outputs (to stdout): "flag" | "ok" | "skip"
decide_yanked_action() {
    local yanked="$1"
    case "$yanked" in
        true)    echo "flag" ;;
        false)   echo "ok"   ;;
        *)       echo "skip" ;;
    esac
}

# Return early if sourced for helper functions only (used by tests)
[ "${RECONCILE_SOURCED:-}" = "1" ] && return 0

# ── parse arguments ───────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── fetch all crates.io versions once ────────────────────────────────────────

echo "Fetching crates.io versions for ${CRATE_NAME}..."
VERSIONS_JSON=$(curl --silent --fail \
    --max-time 30 --retry 3 --retry-delay 5 \
    --user-agent "$USER_AGENT" \
    "https://crates.io/api/v1/crates/${CRATE_NAME}/versions") \
    || { echo "WARNING: crates.io API unavailable; skipping reconciliation" >&2; exit 0; }

# ── list open upstream-update/* PRs ──────────────────────────────────────────

OPEN_UPDATE_PRS=$(gh pr list \
    --state open \
    --json number,title,headRefName,labels,body \
    --jq '[.[] | select(.headRefName | startswith("upstream-update/"))]')

# Emit one line per PR: "<number> <branch> <base64-body>" so multi-line PR bodies
# survive the read loop without an extra API call.
echo "$OPEN_UPDATE_PRS" | jq -r '.[] | "\(.number) \(.headRefName) \(.body | @base64)"' | \
while IFS=' ' read -r PR_NUM BRANCH BODY_B64; do
    # Decode body from the bulk fetch (no extra API call needed)
    PR_BODY=$(echo "$BODY_B64" | base64 --decode 2>/dev/null || true)

    PR_VERSION=$(extract_pr_version "$BRANCH")
    if [ -z "$PR_VERSION" ]; then
        echo "PR #${PR_NUM}: could not extract version from branch ${BRANCH} — skipping"
        continue
    fi

    # Only act on automation-owned PRs
    if [ "$(is_automation_owned "$PR_BODY")" != "yes" ]; then
        echo "PR #${PR_NUM} (${PR_VERSION}): automation marker absent — skipping (manually-created PR)"
        continue
    fi

    # Determine yanked state for this version from the bulk fetch
    YANKED=$(echo "$VERSIONS_JSON" | jq -r \
        --arg ver "$PR_VERSION" \
        '.versions | map(select(.num == $ver)) | first | .yanked // "unknown"')

    ACTION=$(decide_yanked_action "$YANKED")

    if [ "$ACTION" = "flag" ]; then
        echo "PR #${PR_NUM} (${PR_VERSION}): version is YANKED on crates.io — flagging"

        if [ "$DRY_RUN" = "true" ]; then
            echo "  [dry-run] would add label yanked-upstream"
            echo "  [dry-run] would check for existing warning comment"
        else
            # Add label (create it if missing)
            gh label create "yanked-upstream" \
                --color "e11d48" \
                --description "Target upstream version has been yanked from crates.io" \
                2>/dev/null || true
            gh pr edit "$PR_NUM" --add-label "yanked-upstream" || true

            # Check whether we already posted a warning on this PR
            ALREADY_WARNED=$(gh pr view "$PR_NUM" \
                --json comments \
                --jq '[.comments[].body | select(contains("yanked on crates.io"))] | length')

            if [ "${ALREADY_WARNED:-0}" -eq 0 ]; then
                COMMENT_BODY="⚠️ **Upstream version \`${PR_VERSION}\` has been yanked on crates.io.**"
                COMMENT_BODY="${COMMENT_BODY}"$'\n\n'
                COMMENT_BODY="${COMMENT_BODY}This PR was created by the automated upstream-release-check workflow,"
                COMMENT_BODY="${COMMENT_BODY} but the upstream release it tracks (\`${PR_VERSION}\`) is no longer"
                COMMENT_BODY="${COMMENT_BODY} available as a stable, non-yanked release on crates.io."
                COMMENT_BODY="${COMMENT_BODY}"$'\n\n'
                COMMENT_BODY="${COMMENT_BODY}Please review and close this PR if the upstream release has been"
                COMMENT_BODY="${COMMENT_BODY} permanently withdrawn, or wait for a corrected upstream release before merging."
                gh pr comment "$PR_NUM" --body "$COMMENT_BODY"
            else
                echo "PR #${PR_NUM} (${PR_VERSION}): already warned — skipping duplicate comment"
            fi
        fi

    elif [ "$ACTION" = "ok" ]; then
        echo "PR #${PR_NUM} (${PR_VERSION}): version still non-yanked — OK"
    else
        echo "PR #${PR_NUM} (${PR_VERSION}): version not found on crates.io — skipping"
    fi
done
