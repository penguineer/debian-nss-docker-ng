# Debian Packaging Strategy for nss-docker-ng

## Overview

This document records the packaging decisions, rationale, and open questions for
the Debian package of [`nss-docker-ng`](https://github.com/petski/nss-docker-ng),
a Rust-based NSS plugin that resolves Docker container hostnames via the `.docker`
virtual domain.

---

## Upstream Summary

| Field | Value |
|---|---|
| Upstream repository | <https://github.com/petski/nss-docker-ng> |
| Language | Rust (2021 edition) |
| Current version | 1.2.1 |
| License | MIT |
| Build output | `libnss_docker_ng.so` (cdylib, renamed to `libnss_docker_ng.so.2`) |
| Build tool | Cargo |
| Key dependencies | `libnss`, `docker-api`, `tokio`, `libc`, `debug_print` |

Upstream uses `patchelf` post-build to set the ELF SONAME to `libnss_docker_ng.so.2`.
This step must be reproduced or replaced in the Debian packaging build process.

Upstream does not have a stable release cadence tracked by Git tags; the current version
`1.2.1` is published to crates.io. There is also an unofficial Ubuntu PPA that installs
a binary package named `nss-docker-ng`.

---

## Debian Context

### Obsolete `libnss-docker` Package

The Go-based `libnss-docker` package (upstream: <https://github.com/dex4er/nss-docker>)
was previously available in Debian sid. It was removed via Debian bug #1124925 (RoQA;
RC bug; unmaintained upstream). `nss-docker-ng` is an independent Rust reimplementation
that provides equivalent `.docker` resolution functionality.

### Debian ITP #1119131

Debian bug #1119131 is an Intent To Package (ITP) for `libnss-docker-ng`. This packaging
effort should be coordinated with that ITP or should reference it to avoid duplication.

---

## Package Naming

| Item | Decision |
|---|---|
| Debian **source** package name | `nss-docker-ng` |
| Debian **binary** package name | `libnss-docker-ng` |

**Rationale:** `libnss-docker-ng` follows the Debian naming convention for NSS modules
(cf. `libnss-myhostname`, `libnss-resolve`, `libnss-ldap`). The source package name
`nss-docker-ng` matches the upstream project name and avoids the `lib` prefix on source
packages, which is the convention for packages that produce a single library binary.

---

## Package Relationships

The old `libnss-docker` package has been removed from Debian. To allow a clean upgrade
path if it is ever reintroduced, or if users have it installed from a third-party source,
the following relationships are appropriate:

```
Provides: libnss-docker
Conflicts: libnss-docker
Replaces: libnss-docker
```

**Rationale:**
- `Provides` satisfies any residual `Depends: libnss-docker` in other packages.
- `Conflicts` prevents simultaneous installation of both NSS modules, which would
  result in undefined `.docker` resolution order and potential file path collisions.
- `Replaces` allows `dpkg` to cleanly overwrite any files left by the old package.

Because `libnss-docker` was removed and is currently absent from all supported Debian
releases, these fields add clarity and safety without causing installation friction.

---

## Versioning Scheme

Use the native upstream version directly:

```
libnss-docker-ng (1.2.1-1) unstable; urgency=low
```

The Debian revision (`-1`, `-2`, …) increments for packaging-only changes.
There is no epoch needed. If a future upstream release resets the version counter,
an epoch would be required at that time.

---

## Upstream Source Retrieval

Use `uscan` with a `debian/watch` file pointing to the upstream GitHub releases page
or the crates.io tarball:

```
version=4
opts=filenamemangle=s/.+\/v?(\d\S+)\.tar\.gz/nss-docker-ng-$1.tar.gz/ \
  https://github.com/petski/nss-docker-ng/releases .*/v?(\d\S+)\.tar\.gz
```

**Avoid** the `latest` redirect or any mutable URL. Always pin to an explicit version
tag. `debian/watch` provides reproducible, auditable retrieval and integrates with
`gbp import-orig`.

The upstream tarball does not include a `Cargo.lock` at the library-crate level, so
vendoring will need to be performed by the maintainer as described below.

---

## Rust Dependency Strategy

### Decision: Vendored source tarball with `dh-cargo`

The source package will include a `vendor/` directory created by `cargo vendor` and
will use `dh-cargo` as the Debhelper build system.

**Approach:**

1. Download the upstream tarball.
2. Run `cargo vendor` in the source tree to populate `vendor/`.
3. Create a `debian/cargo-checksum.json` or equivalent as required by `dh-cargo`.
4. Set `Build-Depends: dh-cargo (>= 31), cargo:native, rustc:native`.

**Why vendored instead of individually packaged crates?**

- The Debian Rust Team's preferred route is to package each crate separately via
  `debcargo`. This is the right path for an official Debian package.
- However, `nss-docker-ng` depends on several crates (`docker-api`, `libnss`,
  `debug_print`, `mockall`, `mockito`) that are not yet individually packaged in Debian.
- Vendoring all dependencies into the source tarball is an accepted and widely-used
  alternative for system software that is not a library itself. It allows the package
  to enter Debian without requiring the entire dependency graph to be packaged first.
- The DFSG requires that all vendored source be DFSG-free and licensed compatibly. A
  `debian/copyright` file must enumerate all vendored crates and their licenses.

**Path to an official Debian package:**

A maintainer seeking to upload to the official Debian archive should consult with the
Debian Rust Team about whether to:
(a) Vendor dependencies temporarily while crates are packaged separately, or
(b) Work with the Rust Team to get the missing crates into Debian first.

This packaging repository uses vendoring as a pragmatic starting point. The `debian/`
directory structure and `dh-cargo`-based build are intentionally compatible with
eventual migration to individually packaged crates.

---

## Build Dependencies

```
Build-Depends:
  debhelper-compat (= 13),
  dh-cargo (>= 31),
  cargo:native,
  rustc:native,
  patchelf
```

`patchelf` is needed to set the ELF SONAME on the compiled shared library unless an
alternative approach (e.g., a Rust linker flag) is used; see Open Questions below.

---

## Runtime Dependencies

```
Depends:
  ${misc:Depends},
  ${shlibs:Depends}
```

The plugin communicates with Docker over the Unix socket `/run/docker.sock` or
`/var/run/docker.sock`. There is no hard dependency on a Docker package because the
plugin is functional only when Docker is running; installation must not require Docker.

---

## NSS Library Installation Path

Install the shared library to the Debian multiarch path:

```
/usr/lib/$(DEB_HOST_MULTIARCH)/libnss_docker_ng.so.2
```

with a symlink:

```
/usr/lib/$(DEB_HOST_MULTIARCH)/libnss_docker_ng.so -> libnss_docker_ng.so.2
```

`ldconfig` will manage the cache. The package should call `ldconfig` via the `shlibs`
trigger mechanism (automatically handled by `debhelper` when libraries are installed
under `/usr/lib`).

**Note on the library name:** The NSS service name used in `nsswitch.conf` is
`docker_ng`; glibc resolves this to `libnss_docker_ng.so.2` at runtime. This naming
is dictated by the upstream Rust crate's `[lib] name = "nss_docker_ng"` and cannot
be changed without forking upstream.

---

## `/etc/nsswitch.conf` Handling

**Decision: Document only; do not modify automatically.**

The package will ship documentation instructing users to add `docker_ng` to the
`hosts:` line in `/etc/nsswitch.conf`. For example:

```
hosts: files docker_ng dns
```

**Rationale:**
- Modifying `/etc/nsswitch.conf` automatically on install/remove is risky: incorrect
  NSS configuration can break hostname resolution system-wide, including logins and
  `sudo`.
- Debian Policy discourages postinst scripts that modify configuration files owned
  by the administrator.
- Other Debian NSS packages (`libnss-resolve`, `libnss-myhostname`) take the same
  approach: document the required change but do not make it automatically.
- A `debconf` prompt is an option for future consideration but is not required for
  an initial release.

---

## Architecture Support

**Initial support: `amd64` only.**

`nss-docker-ng` is a Rust cdylib. Rust supports many Debian architectures, but the
initial package will target `amd64` (`x86_64-linux-gnu`) to allow the packaging work
to proceed without a full cross-compilation matrix.

The `Architecture:` field in `debian/control` should be set to `any` rather than
`amd64` so that the package can be built on other architectures without changes to
the control file. Build infrastructure will determine which architectures are actually
built.

Docker itself is effectively `amd64`/`arm64`-only in practice, so `arm64` is a
natural second target when testing resources are available.

---

## Installation, Upgrade, and Removal Behaviour

| Scenario | Expected behaviour |
|---|---|
| Fresh install | Library installed; `ldconfig` cache updated; manual `nsswitch.conf` edit required |
| Upgrade | Library replaced in place; `ldconfig` re-run; `nsswitch.conf` unchanged |
| Removal | Library removed; `ldconfig` cache updated; `nsswitch.conf` entry left in place (documented) |
| Purge | Same as removal (no conffiles owned by the package) |

On removal, any `docker_ng` entry in `/etc/nsswitch.conf` becomes a no-op because
glibc will simply fail to load the missing module and continue to the next service.
This is safe behaviour.

---

## Compatibility with a Future Official Debian Package

The packaging structure in this repository is intended to be as close as possible to
what an official Debian package would look like, to minimise friction at a future
upload:

- Use `debhelper-compat = 13`.
- Use `dh-cargo` as the build system.
- Follow Debian multiarch library paths.
- Use `debian/watch` for reproducible source retrieval.
- Use a full `debian/copyright` in DEP-5 machine-readable format.
- Do not use non-standard helpers or repository-specific scripts in `debian/rules`.

The main delta from official policy is the vendored `vendor/` directory. If the Debian
Rust Team packages the required crates, the vendor directory can be dropped and the
`Build-Depends` updated to list them individually.

---

## Prior Art

| Package / Project | Notes |
|---|---|
| Debian `libnss-docker` | Removed (bug #1124925); Go-based; same `.docker` domain |
| Debian ITP #1119131 | ITP for `libnss-docker-ng`; status: open, unimplemented |
| Ubuntu PPA `nss-docker-ng` | Binary named `nss-docker-ng`; installs to `/usr/local/lib/nss-docker-ng/` — non-standard path, not suitable for Debian |
| `libnss-myhostname` | Debian reference for NSS module packaging conventions |
| `libnss-resolve` | Debian reference for NSS module packaging conventions |

---

## Open Questions

1. **SONAME injection:** Upstream uses `patchelf` post-build. An alternative is to
   pass `-C link-arg=-Wl,-soname,libnss_docker_ng.so.2` via `RUSTFLAGS` during the
   Cargo build, avoiding the `patchelf` build-dependency. This should be tested.

2. **ITP coordination:** Should this repository take over Debian ITP #1119131, or file
   a new ITP? Coordination with the original submitter is needed before upload.

3. **Vendored crate licensing:** A complete audit of all transitive dependencies pulled
   in by `cargo vendor` must be done before upload to confirm DFSG compliance and
   complete the `debian/copyright` file.

4. **Docker socket permissions:** The plugin requires read access to the Docker socket.
   No special installation-time permissions are needed, but documentation should note
   that processes (and their NSS resolver) need socket access.

5. **`arm64` support:** Should `arm64` be added to the initial CI matrix?

6. **`debconf`:** Should a `debconf` prompt be added to offer automatic `nsswitch.conf`
   modification? This could improve the user experience but adds complexity.

---

## Next Implementation Step

Implement the `debian/` packaging directory:

1. `debian/control` — source and binary package metadata with the relationships above.
2. `debian/rules` — minimal `dh $@ --buildsystem=cargo` rules file.
3. `debian/copyright` — DEP-5 file covering upstream and all vendored crates.
4. `debian/watch` — upstream version tracking.
5. `debian/changelog` — initial entry.
6. Vendor tarball generation script or instructions for maintainers.
7. CI to build the `.deb` and verify library installation path. CI results are
   for validation only; upload to any Debian repository requires explicit maintainer
   review and action and must not be triggered automatically.
