#!/bin/bash
# ci/prepare-update-branch.sh — Orchestrate update branch creation for a new upstream release.
#
# This script handles the git/branch layer that surrounds prepare-update.sh:
#   1. Configure git identity (bot for commits, package maintainer for dch).
#   2. Create the update branch.
#   3. Invoke prepare-update.sh to update source files and vendor archive.
#   4. Commit the changes.
#   5. Push the branch.
#   6. Emit GITHUB_OUTPUT variables for downstream workflow steps.
#
# This script does NOT create the GitHub PR — that is done by create-update-pr.sh.
#
# Usage:
#   prepare-update-branch.sh
#
# Required environment:
#   NEW_VERSION       — new upstream version (e.g. 1.3.0)
#   CRATE_URL         — crates.io download URL for the new version
#   CRATE_CHECKSUM    — expected sha256 of the crate archive
#   GITHUB_OUTPUT     — path to the GitHub Actions output file
#
# Optional environment:
#   TRIXIE_IMAGE      — Docker image to use for cargo vendor (passed to prepare-update.sh)
#   SKIP_PUSH         — set to "true" to skip git push (for testing)
#
# Outputs (appended to GITHUB_OUTPUT):
#   branch            — update branch name (upstream-update/<version>)
#   commit_sha        — SHA of the prepared commit
#   draft_pr          — "true" if the PR should be opened as a draft
#   cargo_toml_changed — "true"/"false"
#   cargo_lock_changed — "true"/"false"
#   patch_status      — patch evaluation result from prepare-update.sh
#
# Exit codes:
#   0 — success
#   1 — fatal error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare-update.sh"

NEW_VERSION="${NEW_VERSION:?NEW_VERSION must be set}"
CRATE_URL="${CRATE_URL:?CRATE_URL must be set}"
CRATE_CHECKSUM="${CRATE_CHECKSUM:?CRATE_CHECKSUM must be set}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"
SKIP_PUSH="${SKIP_PUSH:-false}"

BRANCH="upstream-update/${NEW_VERSION}"

# ── git identity ──────────────────────────────────────────────────────────────

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# dch maintainer identity: read from debian/control (package owner), not the
# GitHub Actions bot, so changelog entries are attributed to the established
# package maintainer.
MAINTAINER=$(grep -m1 '^Maintainer:' debian/control | sed 's/^Maintainer: *//')
export DEBFULLNAME="${MAINTAINER% <*}"
export DEBEMAIL="${MAINTAINER##*<}"
DEBEMAIL="${DEBEMAIL%>}"

# ── create update branch ──────────────────────────────────────────────────────

echo "Creating branch: ${BRANCH}"
git checkout -b "$BRANCH"

# ── run prepare-update.sh ─────────────────────────────────────────────────────

PREPARE_OUTPUT=$(bash "$PREPARE_SCRIPT" \
    --repo-root "$(pwd)" \
    "$NEW_VERSION" \
    "$CRATE_URL" \
    "$CRATE_CHECKSUM")
echo "$PREPARE_OUTPUT"

DRAFT_PR=$(echo "$PREPARE_OUTPUT" | grep '^DRAFT_PR=' | cut -d= -f2 | tail -1)
CARGO_TOML_CHANGED=$(echo "$PREPARE_OUTPUT" | grep '^CARGO_TOML_CHANGED=' | cut -d= -f2 | tail -1)
CARGO_LOCK_CHANGED=$(echo "$PREPARE_OUTPUT" | grep '^CARGO_LOCK_CHANGED=' | cut -d= -f2 | tail -1)
PATCH_STATUS=$(echo "$PREPARE_OUTPUT" | grep '^PATCH_STATUS=' | cut -d= -f2 | tail -1)

# ── commit ────────────────────────────────────────────────────────────────────

git add -A
git commit -m "chore: update nss-docker-ng to ${NEW_VERSION}"
COMMIT_SHA=$(git rev-parse HEAD)

# ── push ──────────────────────────────────────────────────────────────────────

if [ "$SKIP_PUSH" != "true" ]; then
    echo "Pushing branch ${BRANCH} (commit ${COMMIT_SHA})"
    git push origin "$BRANCH"
fi

# ── emit outputs ─────────────────────────────────────────────────────────────

echo "draft_pr=${DRAFT_PR}"                    >> "$GITHUB_OUTPUT"
echo "branch=${BRANCH}"                        >> "$GITHUB_OUTPUT"
echo "commit_sha=${COMMIT_SHA}"                >> "$GITHUB_OUTPUT"
echo "cargo_toml_changed=${CARGO_TOML_CHANGED}" >> "$GITHUB_OUTPUT"
echo "cargo_lock_changed=${CARGO_LOCK_CHANGED}" >> "$GITHUB_OUTPUT"
echo "patch_status=${PATCH_STATUS}"            >> "$GITHUB_OUTPUT"
