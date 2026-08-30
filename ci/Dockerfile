# ci/Dockerfile — Debian Trixie CI environment for nss-docker-ng.
#
# This image installs all tools required by the ci/ scripts and is built
# once per workflow run (with BuildKit cache across runs).  It does NOT
# contain any build output, cargo target directories, or .deb artefacts:
# those are always produced at runtime from the checked-out source.
#
# Cache invalidation:
#   - Changes to this Dockerfile cause a full rebuild.
#   - Changes to the debian:trixie base-image digest cause a rebuild.
#   - APT_WEEK is a date-stamped build argument (YYYY-Www) passed by the
#     workflow.  It changes every Monday, ensuring the apt-get layer is
#     refreshed at most once per week so CI sees current Trixie package
#     versions (rustc, cargo, lintian, debhelper, etc.) rather than a
#     permanently frozen apt cache.  The base-image pull and apt download
#     layers below APT_WEEK are still cached across runs that share the
#     same week value.
FROM debian:trixie

ARG APT_WEEK
RUN echo "APT_WEEK=${APT_WEEK}" && \
    apt-get update -qq && \
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
