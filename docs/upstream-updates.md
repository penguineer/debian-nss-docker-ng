# Upstream Update Process

This document describes how new upstream releases of `nss-docker-ng` are detected,
prepared, and submitted for review.

---

## Overview

crates.io is the canonical versioned source for `nss-docker-ng`. The update
pipeline is fully automated up to the point of human review: it detects new
releases, validates them, prepares repository changes, and opens a reviewable
pull request. No update is merged or released automatically.

---

## Automated detection

The **Upstream Release Check** workflow (`.github/workflows/upstream-release-check.yml`)
runs on a weekly schedule (every Monday at 06:00 UTC) and can also be triggered
manually via `workflow_dispatch`.

### Manual trigger

Navigate to **Actions → Upstream Release Check → Run workflow**. You can optionally
supply a `force_version` to target a specific upstream version; it is validated
through the same stability and checksum rules as automatic discovery.

---

## Validation rules

`ci/check-upstream.sh` queries the crates.io API and validates:

- the latest version is a stable semver (no pre-release suffix),
- the version is not yanked on crates.io,
- the crate archive URL and SHA-256 checksum are available.

A yanked version is never prepared as an update.

---

## Preparation

When a new valid upstream version is found, `ci/prepare-update.sh` runs in the
workflow checkout on the GitHub Actions runner and performs the following steps:

1. **Download and verify** the upstream `.crate` archive (aborts on checksum mismatch).
2. **Synchronise upstream source files** into the repository tree, preserving all
   packaging-owned paths (`.github/`, `ci/`, `debian/`, `docs/`, `README.md`,
   `LICENSE.txt`, `.gitignore`).
3. **Evaluate the Trixie/MSRV compatibility patch** (`debian/patches/0001-trixie-compat-msrv.patch`):
   - If it applies cleanly, it is kept and applied before vendoring.
   - If it does not apply, the script reports whether the patch may be obsolete or
     requires manual intervention.
4. **Regenerate `vendor.tar.gz`** — the `cargo vendor --locked` operation is run
   inside the Trixie CI container (via `TRIXIE_IMAGE`) so that dependency resolution
   uses the authoritative Rust toolchain. The archive contains `.cargo/config.toml`
   and `vendor/`; vendor-local `Cargo.lock` files are excluded and the
   repository-root `Cargo.lock` remains authoritative.
5. **Update `debian/changelog`** with a new entry for the new upstream version.
6. **Report** changes to `Cargo.toml`, `Cargo.lock`, and patch status.

---

## Branch and PR creation

`ci/prepare-update-branch.sh` commits the prepared changes onto an
`upstream-update/<version>` branch and pushes it to the repository.

`ci/create-update-pr.sh` opens a pull request against `main`. The PR is opened
as a **draft** when the Trixie/MSRV patch requires human review; otherwise it is
opened as a normal PR.

If an open PR for the same version already exists (detected by
`ci/detect-existing-update-pr.sh`), the preparation step is skipped.

---

## Package CI on the prepared commit

After the PR is created, the **Debian Package CI** workflow runs against the exact
commit SHA of the prepared branch — not the caller's rev. This ensures the PR
already reflects the real build and test result when a reviewer looks at it.

---

## Yanked-release reconciliation

`ci/reconcile-yanked-prs.sh` runs on every scheduled check. For each open
`upstream-update/*` PR it verifies that the corresponding crates.io version is
still non-yanked. If a version has been yanked after the PR was opened, the
script adds a label and posts a comment on the PR. This warning is posted at most
once per PR.

---

## Human review

After automation has prepared the PR and package CI has run:

1. Review the upstream source changes (`Cargo.toml`, `Cargo.lock`, source files).
2. If the PR is a draft because the Trixie/MSRV patch needs attention, update
   `debian/patches/0001-trixie-compat-msrv.patch` and the vendor archive accordingly,
   then convert the draft to a ready PR.
3. Confirm package CI is green on the current head of the PR branch.
4. Merge when satisfied.

No automatic merge or release is performed after the PR is merged. Releasing a new
package version requires a separate explicit tag action; see
[`docs/release-process.md`](release-process.md).

---

## Permission boundaries

| Job | Required permissions | Reason |
|-----|---------------------|--------|
| `check` | `contents: read` | Reads repository state and queries crates.io |
| `reconcile` | `contents: read`, `pull-requests: read`, `issues: write` | Posts PR comments and manages labels on existing PRs |
| `prepare` | `contents: write`, `pull-requests: write`, `issues: write` | Pushes update branch and opens PR |
| `run-ci-on-update-branch` | (inherited from `ci.yml`) | Runs package CI on the prepared commit |

The update workflow cannot merge branches, create or move tags, or publish releases.
