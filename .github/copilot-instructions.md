# Copilot Instructions

This repository packages `nss-docker-ng` for Debian.

* Treat NSS integration and Docker socket access as security-sensitive system infrastructure.
* Do not weaken Docker API compatibility, expose the Docker socket remotely, or introduce unnecessary privileged operations.
* Do not execute mutable or unpinned remote scripts, binaries, or `latest` artifacts during builds or package installation.
* Prefer conventional Debian packaging and build tooling over repository-specific mechanisms.
* Keep changes scoped to the assigned issue and avoid implementing later roadmap items prematurely.
* Prefer compatibility with a possible future official Debian package over project-specific conventions.
* When several packaging approaches are reasonable, document the tradeoffs and rationale for the chosen approach.
* CI may validate and prepare changes, but upstream updates and releases must remain reviewable rather than being merged or published automatically.
