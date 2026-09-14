# Copilot Instructions

This repository packages `nss-docker-ng` for Debian.

Treat this repository as low-level system infrastructure. NSS integration, package lifecycle handling, Docker socket access, update automation, and release publication are security- and reliability-sensitive.

## General engineering principles

* Prefer conventional Debian packaging and standard Debian tooling over repository-specific mechanisms.
* Prefer compatibility with a possible future official Debian package over project-specific conventions.
* Keep changes scoped to the assigned issue and avoid implementing later roadmap items prematurely.
* When several reasonable approaches exist, document the tradeoffs and rationale for the chosen approach.
* Preserve existing repository conventions unless there is a clear reason to change them.
* Do not silently weaken existing validation, reproducibility, security, or review boundaries to simplify an implementation.
* Optimize for code and automation that another maintainer can understand without reconstructing project history.

Current architectural decisions described below are defaults and invariants for ordinary changes.

An assigned issue may deliberately change one of those decisions, but only when that change is explicit in scope. In that case:

* treat the architecture change itself as part of the issue, not as incidental implementation cleanup
* review the implications across Debian packaging, CI, security, reproducibility, update automation, release automation, and documentation
* preserve or improve the relevant guarantees of the existing design
* update tests and documentation so the repository consistently describes the replacement architecture
* do not leave old assumptions or comments behind after the change

Strong requirements below should therefore prevent accidental architectural drift, not block an explicitly reviewed architecture change.

## Repository structure and readability

Keep GitHub Actions workflows primarily as orchestration.

Non-trivial shell logic should normally live in repository-local scripts under `ci/`, especially when it:

* contains branching or policy decisions
* parses external or GitHub-provided input
* modifies repository or PR state
* is reusable
* can reasonably be tested independently
* requires more than a short workflow glue block to understand

A workflow should make its high-level behavior obvious when read on its own.

Prefer:

`workflow orchestration -> repository-local script -> explicit outputs`

over large embedded shell programs in workflow YAML.

Do not extract trivial one- or two-command glue merely to reduce YAML line count.

Repository-local scripts should:

* use `set -euo pipefail`
* have a short usage/behavior header
* accept inputs explicitly
* quote shell variables
* fail clearly
* expose machine-readable outputs where workflows consume their results
* be covered by focused tests where practical

## GitHub Actions security

Use least privilege.

* Default workflows/jobs to `contents: read`.
* Grant write permissions only to the jobs that actually require them.
* Grant only the specific GitHub permissions needed by those jobs.
* Do not give build, validation, or discovery jobs write-capable tokens without a demonstrated need.

Treat GitHub context values, workflow inputs, branch names, tag names, PR metadata, and external service data as untrusted input.

Do not interpolate potentially variable `${{ ... }}` values directly into shell source when they can be passed through `env:` and consumed as quoted shell variables.

Prefer:

```yaml
env:
  VERSION: ${{ needs.check.outputs.version }}
run: |
  command "$VERSION"
```

over embedding the expression directly into the generated script.

Use immutable commit SHAs when correctness depends on operating on one exact repository state.

Avoid re-resolving mutable branches or tags between validation, build, and publication steps.

## Remote inputs and reproducibility

Do not:

* weaken Docker API compatibility
* expose the Docker socket remotely
* introduce unnecessary privileged operations
* execute mutable or unpinned remote scripts or binaries
* use `latest` artifacts as build inputs
* replace committed/reviewed source state with mutable upstream content during package builds or releases

External upstream source used for updates must be versioned and checksum-verified before repository changes are prepared.

Package builds must continue to use the committed vendored dependencies and locked/offline Cargo build process unless an assigned issue explicitly changes that packaging strategy under the architecture-change rules above.

## Docker socket usage

The Docker socket is highly privileged.

Use it only where required for the functional NSS smoke test or explicitly required by an assigned issue.

Do not:

* expose it over TCP
* change its permissions to make tests easier
* mount it into unrelated containers
* use `--privileged` when socket access alone is sufficient

## Debian package lifecycle

Changes affecting package installation or maintainer scripts must be reviewed against the complete lifecycle, not only fresh installation.

Consider and test, where relevant:

* clean build
* fresh install
* reinstall/upgrade
* NSS configuration after install/upgrade
* functional `.docker` resolution
* removal
* purge where relevant
* restoration of pre-install NSS state

Do not assume that install/remove coverage is sufficient for an issue involving upgrade behavior.

## NSS integration

`dh_installnss` and the package `.nss` file are the authoritative mechanism for `/etc/nsswitch.conf` integration unless an assigned issue explicitly changes that integration strategy under the architecture-change rules above.

Do not hard-code or replace the user's complete `hosts:` line.

Preserve existing NSS services and ordering according to the `.nss` placement policy.

Tests should verify the intended invariant rather than depend on one exact machine-specific `hosts:` line, except when explicitly testing exact restoration after package removal.

## CI and test design

Reuse the existing authoritative package CI rather than creating parallel build or validation implementations.

A CI implementation change is not automatically a package change.

Keep these concepts distinct:

* package source and Debian metadata
* package build
* package validation
* CI implementation
* artifact retention
* release publication

Do not publish or retain package artifacts from ordinary PR/main CI unless an issue explicitly requires it.

For releases, publish the exact package artifacts that passed the authoritative validation path. Do not validate one build and publish a separately rebuilt package.

Tests should exercise the important invariant, not merely helper syntax.

When adding validation logic, cover both success and failure cases.

## Upstream update automation

Automated upstream handling may:

* detect releases
* validate stable/non-yanked release state
* verify checksums
* prepare repository changes
* regenerate vendored dependencies
* create reviewable update PRs
* run package CI on the exact prepared commit

It must not:

* automatically merge upstream updates
* guess how to resolve packaging conflicts
* silently carry incompatible patches
* publish a package release solely because an upstream update exists

When packaging judgment is required, make that state visible and leave it for human review.

## Release automation

A release tag is an explicit maintainer publication action.

Release automation must:

* validate tag, Debian package version, and upstream version consistency
* operate on the immutable commit that triggered the release
* ensure the tagged commit satisfies the repository's reviewed-state policy
* build through the authoritative package CI
* publish the exact fully validated artifacts
* generate checksums
* fail if the release tag has disappeared or moved
* explicitly target the intended GitHub repository
* never create or move release tags implicitly

Release publication must remain separate from upstream-update automation.

## Linting and accepted warnings

Lintian policy must be explicit.

Do not add broad or stale suppressions simply to make CI green.

For every retained suppression:

* confirm the finding still occurs
* document why it is expected
* explain why changing the package would be less correct

Comments must accurately describe the configured `lintian --fail-on` behavior.

Keep package-structure checks independent of Lintian severity policy.

## Documentation consistency

Whenever implementation changes user, maintainer, CI, update, or release behavior, inspect the related documentation in the same change.

At minimum consider:

* `README.md`
* `docs/packaging-strategy.md`
* `docs/release-process.md`
* upstream-update documentation, if present
* relevant comments in workflows and scripts

Do not leave documentation describing completed work as future work.

Do not preserve obsolete manual procedures as the recommended path after automation supersedes them.

Distinguish clearly between:

* current behavior
* historical rationale
* future work

Keep duplicated procedural documentation to a minimum.

## Before opening or updating a pull request

Perform a repository-level self-review before considering the implementation complete.

Check all of the following:

1. **Issue scope**

   * Does the implementation satisfy every acceptance criterion?
   * Did it accidentally implement unrelated future work?

2. **Architecture**

   * Does it still follow established repository conventions?
   * Is non-trivial workflow logic externalized appropriately?
   * If the issue intentionally changes an architectural invariant, have all dependent assumptions, tests, CI, and documentation been updated consistently?

3. **Security**

   * Are permissions least-privilege?
   * Are variable GitHub/external inputs passed safely to shell?
   * Are mutable refs avoided where exact-state integrity matters?
   * Are Docker privileges no broader than necessary?

4. **Correctness**

   * Are success and important failure paths tested?
   * Are package lifecycle implications covered?
   * If artifacts are published, are they the exact validated artifacts?

5. **Consistency**

   * Do workflows, scripts, Debian files, and documentation agree?
   * Are comments still true?
   * Are old suppressions, TODOs, issue references, or intermediate implementation notes stale?

6. **Human readability**

   * Can the workflow's intent be understood without reading hundreds of lines of embedded shell?
   * Are scripts named and documented according to their responsibilities?
   * Is the resulting maintenance procedure discoverable from the README/docs?

7. **CI**

   * Run or inspect all relevant current-head CI.
   * Do not describe a PR as complete while current-head required CI is failing or has not actually run.

8. **PR description**

   * Update the PR description after the final implementation revision.
   * It must describe the implementation that actually exists, not an earlier design that was subsequently changed.

Do not wait for reviewer feedback to perform these checks.

## Review standard

Before requesting review, assume the reviewer will inspect the entire resulting system, not only the latest diff.

Review your own work at that same level.

A change is complete only when the implementation is correct, consistent with adjacent components and documentation, secure within its privilege boundary, tested at the appropriate level, and understandable to a human maintainer.
