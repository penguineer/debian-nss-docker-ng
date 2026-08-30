# Debian Packaging Strategy for nss-docker-ng

## Overview

This document records the packaging decisions, rationale, and open questions for
the Debian package of [`nss-docker-ng`](https://github.com/petski/nss-docker-ng),
a Rust-based NSS plugin that resolves Docker container hostnames via the `.docker`
virtual domain.

The upstream repository (`petski/nss-docker-ng`) already contains a `debian/`
directory used for its Ubuntu PPA. Where this packaging repository follows the same
decisions, that is noted explicitly. Where it diverges, the rationale is given.

---

## Upstream Summary

| Field | Value |
|---|---|
| Upstream repository | <https://github.com/petski/nss-docker-ng> |
| Language | Rust (2021 edition) |
| Current version | 1.2.1 |
| License | MIT (2024 Patrick Kuijvenhoven) |
| Build output | `libnss_docker_ng.so` (cdylib, renamed to `libnss_docker_ng.so.2`) |
| Build tool | Cargo (pinned to Rust 1.91.0 via `rust-toolchain.toml`) |
| Key dependencies | `libnss`, `docker-api`, `tokio`, `libc`, `debug_print` |
| Upstream `debian/` | Present; used for Ubuntu PPA (Launchpad) |

Upstream uses `patchelf` post-build to set the ELF SONAME to `libnss_docker_ng.so.2`.
This packaging instead injects the SONAME at link time via
`RUSTFLAGS="-C link-arg=-Wl,-soname,libnss_docker_ng.so.2"`. This was tested
successfully: a clean `cargo build --release` with that flag produces the correct
`DT_SONAME` field. An earlier concern that the flag would break proc-macro dylibs
was a false alarm caused by stale build artifacts. `patchelf` is not required.

Upstream does not publish tagged releases on GitHub; version `1.2.1` is published to
crates.io, which is the canonical versioned source. In this environment, the
crates.io API redirect returned HTTP 403 to `curl`, so the vendoring workflow used
the canonical static crate payload at
`https://static.crates.io/crates/nss-docker-ng/nss-docker-ng-1.2.1.crate`.

---

## Debian Context

### `libnss-docker`

The C-based `libnss-docker` package (upstream: <https://github.com/dex4er/nss-docker>)
has been in Debian since 2015; the last upload was version 0.02-1 (~2016). The package
is effectively abandoned and a removal request is open as Debian bug #1124925 (RoQA;
RC bug; unmaintained upstream). As of this writing the package has not yet been removed.

`nss-docker-ng` is an independent Rust reimplementation. The two packages install
**different** shared libraries (`libnss_docker.so.2` vs. `libnss_docker_ng.so.2`) and
are technically co-installable, but having both active in `nsswitch.conf` simultaneously
would produce undefined `.docker` resolution order and should be discouraged.

### Debian ITP #1119131

Debian bug #1119131 is an Intent To Package (ITP) for `libnss-docker-ng`. This
packaging work should coordinate with that ITP before any upload.

---

## Package Naming

| Item | Decision |
|---|---|
| Debian **source** package name | `nss-docker-ng` |
| Debian **binary** package name | `libnss-docker-ng` |

`libnss-docker-ng` follows the Debian naming convention for NSS modules
(cf. `libnss-myhostname`, `libnss-resolve`, `libnss-ldap`). The upstream's own PPA
uses `nss-docker-ng` (without the `lib` prefix) and carries a lintian override for the
resulting name mismatch. This packaging repository uses the correct `libnss-docker-ng`
name instead, eliminating the need for that override.

---

## Package Relationships

The recommended relationships are:

```
Conflicts: libnss-docker
Replaces: libnss-docker
```

`Provides: libnss-docker` is **not** appropriate: the sonames differ
(`libnss_docker.so.2` vs. `libnss_docker_ng.so.2`), so this package does not provide
ABI compatibility with the C-based predecessor.

`Conflicts` prevents simultaneous activation of both `.docker` resolvers.
`Replaces` covers any transitional file conflicts.

The upstream's `debian/control` declares no `Conflicts`, `Replaces`, or `Provides`.
This repository adds them to make the transition from `libnss-docker` safe.

The existing `libnss-docker` package (version 0.02-1.1, verified via `apt-cache show`)
carries no `Conflicts`, `Replaces`, or `Provides` fields of its own. The transition
fields added here do not collide with any reciprocal metadata in that package.

---

## Versioning

Use the upstream version directly:

```
libnss-docker-ng (1.2.1-1) unstable; urgency=low
```

The Debian revision increments for packaging-only changes. No epoch is needed.

---

## Upstream Source Retrieval

Use `debian/watch` pointing to crates.io via the Debian QA `fakeupstream.cgi` service,
matching the approach used in the upstream's own `debian/watch`:

```
version=4
opts=filenamemangle=s/.*\/(.*)\/download/nss-docker-ng-$1\.tar\.gz/g,\
  uversionmangle=s/(\d)[_\.\-\+]?(RC|rc|alpha|beta|preview)[_\.\-\+]?(\d*)$/\
$1~$2$3/ \
  https://qa.debian.org/cgi-bin/fakeupstream.cgi?upstream=crates.io/nss-docker-ng \
  .*/crates/nss-docker-ng/@ANY_VERSION@/download
```

The crates.io crate includes `Cargo.lock`, but it does not include `vendor/`;
the vendored dependency tree must therefore be generated by the maintainer as
part of source preparation.

---

## Rust Dependency Strategy

### Decision: Vendored `vendor.tar.gz` with direct `cargo` invocation

The source package includes a `vendor.tar.gz` archive (created by `cargo vendor`) and
builds via `cargo build --release --offline`. This is the approach used by the upstream
for its Launchpad PPA builds.

### `dh-cargo`/`debcargo` and `cdylib`

**Decision (recorded after review in issue #3):** The direct `cargo build --release --offline` approach is the correct approach for NSS plugin modules and is aligned with accepted Debian practice.

The Debian Rust Team provides two distinct patterns for Rust cdylib packaging:

1. **`cargo-c` (`cbuild`/`cinstall`)** — for Rust libraries with a *C public API*: generates `.so`, C headers, and `.pc` pkg-config files. Used by packages like `rust-rav1e` (`librav1e`) which are linked against from C code.

2. **Direct `cargo build --release --offline`** — for *plugin modules* with a fixed ABI convention (NSS, codec plugins, etc.) where there are no C headers or pkg-config files to generate. This is the accepted Debian pattern for NSS modules.

`libnss-docker-ng` follows pattern 2: there is no C public API to expose; the ABI is entirely defined by glibc's NSS convention (`_nss_<name>_<fn>` symbols, `libnss_<name>.so.2` SONAME). `cargo-c` would not add any value — its generated headers and pkg-config files are not applicable. `dh-cargo`/`debcargo` target Rust library crates for the Debian Rust ecosystem (`.rlib` in `/usr/share/cargo/registry/`), not cdylib plugins.

The `RUSTFLAGS = -C link-arg=-Wl,-soname,libnss_docker_ng.so.2` approach correctly embeds the SONAME in the ELF header without `cargo-c` or `patchelf`. This is the right method for NSS modules.

Sources: Debian Rust Team Book cdylib page; `cargo-c` upstream README; `rust-rav1e` and `rust-sequoia-octopus-librnp` Debian packaging reviewed in issue #3.

### Vendoring approach

```sh
mkdir -p work
cd work
curl -L -A cargo --fail \
  https://static.crates.io/crates/nss-docker-ng/nss-docker-ng-1.2.1.crate \
  -o nss-docker-ng-1.2.1.crate
tar xzf nss-docker-ng-1.2.1.crate
cd nss-docker-ng-1.2.1
mkdir -p .cargo
cargo vendor > .cargo/config.toml
tar -zcf ../../vendor.tar.gz Cargo.lock .cargo/config.toml vendor/
```

`debian/rules` unpacks the tarball and builds offline:

```makefile
override_dh_auto_build:
    tar zxf ./vendor.tar.gz
    $(CARGO) build --release --offline
    ln -sf libnss_docker_ng.so ./target/release/libnss_docker_ng.so.2
```

### DFSG compliance

A preliminary audit of the vendored crates was completed from the embedded
`Cargo.toml` metadata and recorded in `debian/copyright` (DEP-5 format). Major
embedded crates include `docker-api` (MIT), `tokio` (MIT), `libc` (MIT or
Apache-2.0), and `libnss` (LGPL-3.0). A full crate-by-crate license and
compliance review is still required before any official Debian upload,
particularly for the statically linked `libnss` crate.

---

## Build Dependencies

```
Build-Depends:
  debhelper-compat (= 13),
  dh-nss,
  cargo,
  rustc
```

Note: the package providing `dh_installnss` is `dh-nss` (verified on Ubuntu Noble with
debhelper 13.14; the strategy document initially listed `dh-sequence-installnss`).
`dh-nss` also declares `Provides: dh-sequence-installnss`. The sequence is activated via
`dh $@ --with installnss` in `debian/rules`.

The upstream pins Rust to 1.91.0 via `rust-toolchain.toml`. That file must **not** be
included in the packaging repository; Debian packages must build with the distribution's
`rustc`. The initial packaging was validated with the runner's preinstalled
`cargo`/`rustc` 1.98.0. Ubuntu Noble's archive `cargo`/`rustc` 1.75.0 were too old
for the current vendored tree because they could not parse the upstream lockfile
format v4 and some vendored `edition2024` manifests. Confirm the Debian target
suite's `rustc` version before an official upload.

---

## Runtime Dependencies

```
Depends: ${misc:Depends}, ${shlibs:Depends}
```

The plugin communicates with the Docker daemon via the Unix socket at
`/var/run/docker.sock` (upstream hardcodes this path). On current Debian and Docker CE
systems `/var/run` maps to `/run`, so the socket is available as both
`/var/run/docker.sock` and `/run/docker.sock` regardless of whether Docker was installed
from the Debian archive (`docker.io`) or from the Docker Inc. repository (Docker CE).
No package-level socket handling is therefore needed.

There is no hard `Depends` on a Docker package: the plugin is non-functional without a
running Docker daemon, but installation must not require Docker. `Suggests: docker.io`
is omitted to remain neutral between Docker distributions.

---

## NSS Library Installation Path

The installed file layout follows the upstream `debian/` packaging:

- `libnss_docker_ng.so` — the ELF shared library (SONAME set to `libnss_docker_ng.so.2`
  at link time via `RUSTFLAGS`); this is the file loaded by glibc at runtime
- `libnss_docker_ng.so.2` — a symlink pointing to `libnss_docker_ng.so`

Both are installed into:
```
/usr/lib/${DEB_HOST_MULTIARCH}/
```

This layout is intentional: the `.so.2` versioned name is what glibc looks up from the
`nsswitch.conf` service name `docker_ng`, and the SONAME embedded in the ELF header
ensures `ldconfig` maps it correctly. The symlink points back to the actual file.

`ldconfig` cache is managed via the `shlibs` trigger, automatically handled by
debhelper for libraries installed under `/usr/lib`.

This matches the upstream `debian/install` and `debian/rules`:
```
# debian/install
target/release/libnss_docker_ng.so usr/lib/${DEB_HOST_MULTIARCH}
target/release/libnss_docker_ng.so.2 usr/lib/${DEB_HOST_MULTIARCH}

# debian/rules (build step)
# SONAME set at link time via RUSTFLAGS in the environment
ln -sf libnss_docker_ng.so target/release/libnss_docker_ng.so.2
```

---

## `/etc/nsswitch.conf` Handling

**Decision: Use `dh_installnss` (via the `dh-nss` package) with a `.nss` snippet.**

`dh_installnss` automatically modifies `/etc/nsswitch.conf` on install and reverts
the change on removal. It is not an opt-in or manual step. The package ships a
`debian/libnss-docker-ng.nss` file specifying placement:

```
hosts before=dns,resolve docker_ng
```

This generates the `postinst` and `postrm` fragments that inject and remove
`docker_ng` from the `hosts:` line automatically.

This is the same mechanism used by `libnss-myhostname`, `libnss-resolve`, and the
upstream's own PPA packaging.

---

## Architecture Support

`Architecture: any` in `debian/control`; `amd64` is the initial tested target.

Debian's `docker.io` package supports amd64, arm64, armel, armhf, i386, ppc64el,
riscv64, and s390x in Trixie. Architecture support for this package should be
determined by Rust/upstream build compatibility and available CI resources, not by
Docker architecture availability.

---

## Installation, Upgrade, and Removal Behaviour

| Scenario | Expected behaviour |
|---|---|
| Fresh install | Library installed; `ldconfig` cache updated; `docker_ng` added to `nsswitch.conf` `hosts:` line by `dh_installnss` |
| Upgrade | Library replaced; `ldconfig` re-run; `nsswitch.conf` unchanged |
| Removal | Library removed; `ldconfig` cache updated; `docker_ng` removed from `nsswitch.conf` by `postrm` fragment |
| Purge | Same as removal (no conffiles owned by the package) |

---

## Compatibility with a Future Official Debian Package

- `debhelper-compat = 13`
- Direct `cargo` invocation with vendored dependencies
- Debian multiarch library path
- `debian/watch` for reproducible source retrieval
- `debian/copyright` in DEP-5 format
- `Standards-Version` at current level (4.7.x)

The main delta from official Debian Rust Team practice is the vendored `vendor.tar.gz`.
If the required crates are packaged in Debian, the vendor directory can be dropped and
`Build-Depends` updated accordingly.

---

## Prior Art

| Package / Project | Notes |
|---|---|
| Debian `libnss-docker` | C-based; present in Debian since 2015; effectively unmaintained; removal pending (bug #1124925) |
| Debian ITP #1119131 | ITP for `libnss-docker-ng`; status: open, unimplemented; coordination required |
| Upstream `petski/nss-docker-ng:debian/` | Upstream's own `debian/` for Ubuntu PPA; binary package named `nss-docker-ng`; installs to `/usr/lib/${DEB_HOST_MULTIARCH}` |
| `libnss-myhostname`, `libnss-resolve` | Reference implementations for Debian NSS module packaging conventions |
| `rust-rav1e` | Existing Debian `cdylib` package; potential prior art for Rust Team `cdylib` packaging approach |

---

## Open Questions

1. ~~**SONAME injection via `RUSTFLAGS`:**~~ **Resolved — RUSTFLAGS confirmed.**
   `RUSTFLAGS="-C link-arg=-Wl,-soname,libnss_docker_ng.so.2"` is applied during
   `cargo build --release` and results in the correct `DT_SONAME` field. An earlier
   concern about proc-macro dylibs was a false alarm from stale build artifacts.
   `patchelf` is not required.

2. **ITP coordination:** Take over or reference ITP #1119131 before any official upload.
   Not a blocker for the initial amd64 package.

3. **Vendored crate license audit:** A preliminary audit is recorded in
   `debian/copyright`, but a full crate-by-crate DFSG and compliance review is
   still required before upload.

4. ~~**`libnss-docker` control fields:**~~ **Resolved.** `libnss-docker` 0.02-1.1
   carries no `Conflicts`/`Replaces`/`Provides`. Transition fields are safe to add.

5. **MSRV vs Debian `rustc`:** **Resolved in issue #3.** The transitive dependency
   chain `url → idna → idna_adapter → icu_* 2.2.0` introduced a `rustc >= 1.86`
   requirement in crate versions released in early 2025. To maintain compatibility
   with Debian Trixie's `rustc 1.85.0`, `Cargo.toml` caps the affected crates
   (`url < 2.5.5`, `idna < 1.1`, `idna_adapter < 1.2.1`). The package builds and
   all upstream tests pass with `rustc 1.85.0`. `debian/control` declares
   `rustc (>= 1.85~)` and the `vendor.tar.gz` was regenerated accordingly (198 crates).

6. **`dh-cargo`/`cargo-c` revisit:** **Resolved in issue #3.** See "Debian cdylib
   packaging decision" section above. `cargo build --release --offline` is the
   correct and well-precedented approach for NSS plugin modules. `cargo-c` is
   for C-ABI libraries with public headers; `dh-cargo` is for `.rlib` crates in the
   Debian Rust ecosystem. Neither applies here.

7. **`arm64` CI:** Add `arm64` as a second tested architecture once amd64 packaging
   is validated.

---

## Implementation Status

The initial `debian/` packaging for version `1.2.1-1` is implemented:

- `debian/control` — source/binary metadata, `Conflicts`/`Replaces: libnss-docker`
- `debian/rules` — `dh $@ --with installnss`, `RUSTFLAGS` SONAME injection,
  `cargo build --release --offline`, versioned `.so.2` symlink
- `debian/libnss-docker-ng.nss` — `hosts before=dns,resolve docker_ng`
- `debian/install` — installs `libnss_docker_ng.so` and `libnss_docker_ng.so.2`
  to `usr/lib/${DEB_HOST_MULTIARCH}`
- `debian/copyright` — DEP-5 covering upstream MIT and a preliminary vendor audit
- `debian/watch` — crates.io via `fakeupstream.cgi`
- `debian/changelog` — initial entry referencing ITP #1119131
- `vendor.tar.gz` — offline build tarball (198 crates, Cargo.lock, .cargo/config.toml);
  dependency version caps applied in `Cargo.toml` to maintain `rustc 1.85` compatibility

The package builds successfully and produces a correctly structured `.deb`. Upstream
unit tests (`cargo test --offline`) run during `dh_auto_test` and pass. Maintainers
regenerate `vendor.tar.gz` for each upstream version bump via `cargo vendor`.
