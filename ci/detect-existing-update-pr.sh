#!/bin/bash
# ci/detect-existing-update-pr.sh — Detect whether an open update PR already exists.
#
# Searches for an open PR whose title includes the target version string.
# Emits skip=true/false to GITHUB_OUTPUT.
#
# Usage:
#   detect-existing-update-pr.sh
#
# Required environment:
#   NEW_VERSION    — upstream version to check (e.g. 1.3.0)
#   GITHUB_OUTPUT  — path to the GitHub Actions output file
#   GH_TOKEN       — GitHub token with pull-requests:read
#
# Outputs (appended to GITHUB_OUTPUT):
#   skip — "true" if an existing open PR was found, "false" otherwise
#
# Exit codes:
#   0 — always (skip value communicates the result)
set -euo pipefail

NEW_VERSION="${NEW_VERSION:?NEW_VERSION must be set}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

EXISTING=$(gh pr list \
    --state open \
    --search "nss-docker-ng ${NEW_VERSION} in:title" \
    --json number,title \
    --jq '.[0].number // empty')

if [ -n "$EXISTING" ]; then
    echo "PR #${EXISTING} already exists for ${NEW_VERSION} — skipping"
    echo "skip=true" >> "$GITHUB_OUTPUT"
else
    echo "No existing PR for ${NEW_VERSION}"
    echo "skip=false" >> "$GITHUB_OUTPUT"
fi
