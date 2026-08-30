# ci/Dockerfile — Debian Trixie CI environment for nss-docker-ng.
#
# This image installs all tools required by the ci/ scripts and is built
# once per workflow run (with BuildKit cache across runs).  It does NOT
# contain any build output, cargo target directories, or .deb artefacts:
# those are always produced at runtime from the checked-out source.
#
# Rebuild triggers:
#   - Changes to this Dockerfile
#   - Changes to debian:trixie base (cache miss on image digest change)
FROM debian:trixie

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        # Debian packaging infrastructure
        build-essential \
        dpkg-dev \
        devscripts \
        debhelper \
        dh-nss \
        lintian \
        # Rust toolchain (Trixie archive version)
        cargo \
        rustc \
        # Inspection and runtime tools
        binutils \
        file \
        libc-bin \
    && rm -rf /var/lib/apt/lists/*
