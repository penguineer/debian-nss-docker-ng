# Debian Packaging Strategy for nss-docker-ng

## Overview

This document records the packaging decisions, rationale, and open questions for
the Debian package of [`nss-docker-ng`](https://github.com/petski/nss-docker-ng),
a Rust-based NSS plugin that resolves Docker container hostnames via the `.docker`
virtual domain.

**Note:** The upstream repository (`petski/nss-docker-ng`) already contains a `debian/`
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
| Upstream `debian/` | Present in repository; used for Ubuntu PPA (Launchpad) |

Upstream uses `patchelf` post-build to set the ELF SONAME to `libnss_docker_ng.so.2`.
This step must be reproduced or replaced in the Debian packaging build process.

Upstream does not have a stable release cadence tracked by Git tags; the current version
`1.2.1` is published to crates.io. There is also an unofficial Ubuntu PPA that installs
a binary package named `nss-docker-ng`.

---

## Debian Context

### Obsolete `libnss-docker` Package

The C-based `libnss-docker` package (upstream: <https://github.com/dex4er/nss-docker>,
by Piotr Roszatycki) has been present in Debian since 2015 (version 0.01-1). The last
upload was version 0.02-1 (~2016). The package is effectively abandoned: no upstream
updates since ~2016, and the upstream's own issue tracker references `nss-docker-ng`
as its successor. Debian bug #1124925 is a removal request (RoQA; RC bug; unmaintained
upstream), but as of this writing the package has not yet been removed from all Debian
suites.

`nss-docker-ng` is an independent Rust reimplementation providing equivalent `.docker`
resolution functionality. The two packages install **different** shared libraries
(`libnss_docker.so.2` vs. `libnss_docker_ng.so.2`) and are technically co-installable
at the system level; however, having both active in `nsswitch.conf` would produce
undefined resolution order and should be discouraged.

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

The upstream's own `debian/` uses the binary package name `nss-docker-ng` (without the
`lib` prefix) for its PPA. This packaging repository uses `libnss-docker-ng` to follow
Debian naming conventions and to be consistent with existing NSS module packages in
Debian. The upstream acknowledges this mismatch via a lintian override
(`package-name-doesnt-match-sonames`) in their packaging; this packaging repository
resolves it by using the correct `libnss-docker-ng` name instead.

---

## Package Relationships

`libnss-docker` is still present in Debian but effectively unmaintained and a
removal candidate (bug #1124925). Since the two packages install different sonames
(`libnss_docker.so.2` vs. `libnss_docker_ng.so.2`) they are technically co-installable.
However, having both active simultaneously in `/etc/nsswitch.conf` would result in
undefined resolution order for the `.docker` domain.

The following relationships are therefore recommended:

```
Conflicts: libnss-docker
Replaces: libnss-docker
```

`Provides: libnss-docker` is **not** appropriate because the sonames differ; a package
depending on `libnss-docker` would need the specific `libnss_docker.so.2` symbol set,
which this package does not provide.

**Rationale:**
- `Conflicts` signals that both should not be simultaneously active (avoids `.docker`
  resolution ambiguity and discourages users from having both loaded in `nsswitch.conf`).
- `Replaces` allows `dpkg` to cleanly handle file conflicts if one ever arises and
  simplifies transitions for users upgrading from `libnss-docker`.
- `Provides` is omitted because this package does not provide ABI compatibility with
  the C-based `libnss-docker`; it is a functional successor, not a drop-in ABI
  replacement.

The upstream's `debian/control` declares no `Conflicts`, `Replaces`, or `Provides`.
This packaging repository adds them to improve user safety and transition behaviour.

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

Use `uscan` with a `debian/watch` file pointing to **crates.io** via the Debian QA
`fakeupstream.cgi` service (the same approach used by the upstream's own `debian/watch`):

```
version=4
opts=filenamemangle=s/.*\/(.*)\/download/nss-docker-ng-$1\.tar\.gz/g,\
  uversionmangle=s/(\d)[_\.\-\+]?(RC|rc|alpha|beta|preview)[_\.\-\+]?(\d*)$/\
$1~$2$3/ \
  https://qa.debian.org/cgi-bin/fakeupstream.cgi?upstream=crates.io/nss-docker-ng \
  .*/crates/nss-docker-ng/@ANY_VERSION@/download
```

**Why crates.io rather than GitHub releases?**

The upstream does not publish tagged releases on GitHub (no tags in the repository).
The crates.io release is the canonical versioned source. The `fakeupstream.cgi`
service is the established Debian mechanism for watching crates.io packages.

**Avoid** any mutable URL (e.g. `releases/latest`). Always pin to an explicit version.
`debian/watch` provides reproducible, auditable retrieval and integrates with
`gbp import-orig`.

The upstream tarball from crates.io does not include a `Cargo.lock` or `vendor/`
directory. Both must be generated by the maintainer as part of source preparation (see
the Rust Dependency Strategy section).

---

## Rust Dependency Strategy

### Decision: Vendored `vendor.tar.gz` with direct `cargo` invocation

The source package will include a `vendor.tar.gz` archive (created by `cargo vendor`)
as part of the orig tarball or as a separate component. The build uses a direct
`cargo build --release --offline` invocation, **not** `dh-cargo`.

### Why not `dh-cargo`?

`dh-cargo` and `debcargo` are designed for packaging Rust **library crates** into the
Debian system Rust crate registry at `/usr/share/cargo/registry/`. They are explicitly
**not suitable for `cdylib` targets** such as NSS plugins:

- `cdylib` crates produce C-ABI shared libraries consumed by glibc, not Rust consumers.
- `dh-cargo` installs into the Rust crate registry, not into `/usr/lib/<multiarch>/`.
- The `patchelf` SONAME step required for NSS integration is not part of the `dh-cargo`
  pipeline.
- The entire dependency graph (`docker-api`, `tokio`, etc.) would need to be separately
  packaged as Debian crates — a substantial undertaking.

The Debian Rust Team book explicitly addresses `cdylib` packages and recommends manual
`cargo` invocations for them. The upstream maintainer also notes this in `debian/rules`:
> *"I've seen `debcargo`. It looks promising, but it doesn't seem to work well for `cdylib`"*

### Approach

1. Download the crates.io tarball for the chosen upstream version.
2. Run `cargo vendor` to populate `vendor/`, and record `Cargo.lock`.
3. Bundle them into `vendor.tar.gz` (matching the upstream CI approach):
   ```sh
   mkdir -p .cargo
   cargo vendor | tee .cargo/config.toml
   tar -zcf vendor.tar.gz Cargo.lock .cargo/config.toml vendor/
   ```
4. Include `vendor.tar.gz` alongside the orig tarball.
5. `debian/rules` unpacks the vendor tarball and builds offline:
   ```makefile
   override_dh_auto_build:
       tar zxf ./vendor.tar.gz
       $(CARGO) build --release --offline
       patchelf --set-soname libnss_docker_ng.so.2 \
           ./target/release/libnss_docker_ng.so
   ```

This approach is exactly what the upstream uses for its Launchpad PPA builds.

### DFSG compliance

All vendored crates and their transitive dependencies must be DFSG-free. A full
license audit must be completed before any official Debian upload, with all crate
licenses enumerated in `debian/copyright` (DEP-5 format).

### Path to an official Debian package

If the Debian Rust Team packages the required crates in the future, the vendor
directory can be dropped and the `Build-Depends` updated to list them individually.
The `debian/rules` structure is kept simple to make this migration straightforward.

---

## Build Dependencies

```
Build-Depends:
  debhelper-compat (= 13),
  cargo,
  rustc,
  patchelf,
  dh-sequence-installnss
```

**Notes:**
- `dh-sequence-installnss` provides the `dh_installnss` helper that handles the
  `.nss` snippet (see `/etc/nsswitch.conf` section below).
- The upstream pins Rust to 1.91.0 via `rust-toolchain.toml`. An official Debian
  package must use the Rust compiler available in Debian (`rustc`), not a pinned
  upstream version. This may require upstream coordination if Debian's `rustc` is
  older than 1.91. The minimum supported Rust version (MSRV) should be verified.
- `patchelf` is used to inject the ELF SONAME. See Open Questions for an alternative
  approach using `RUSTFLAGS`.

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

**Decision: Use `dh-sequence-installnss` with a `.nss` snippet; document the required
manual edit but do not modify `nsswitch.conf` automatically in `postinst`.**

The upstream packages a `debian/nss-docker-ng.nss` file with the content:

```
hosts before=dns,resolve docker_ng
```

The `dh_installnss` tool (from `dh-sequence-installnss`) uses this snippet to generate
`postinst` and `postrm` fragments that add and remove the `docker_ng` service from the
`hosts:` line when the user opts in via `dpkg-reconfigure` or the standard NSS
integration mechanism.

**Rationale:**
- `dh-sequence-installnss` is the established Debian mechanism for NSS modules.
- It does not unconditionally modify `/etc/nsswitch.conf` on install; it integrates
  with the debconf/nss framework.
- Other Debian NSS packages (`libnss-resolve`, `libnss-myhostname`) use the same
  approach.
- Manual `postinst` sed scripts that directly modify `/etc/nsswitch.conf` are risky
  (they can break hostname resolution system-wide) and are not recommended.

The package documentation should explain that after installation users should add
`docker_ng` to the `hosts:` line in `/etc/nsswitch.conf`, for example:

```
hosts: files docker_ng dns
```

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
- Use direct `cargo` invocation with vendored dependencies (not `dh-cargo`).
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
| Debian `libnss-docker` | C-based; present in Debian since 2015 but effectively unmaintained; removal pending (bug #1124925) |
| Debian ITP #1119131 | ITP for `libnss-docker-ng`; status: open, unimplemented; coordination required |
| Upstream `petski/nss-docker-ng:debian/` | Upstream's own `debian/` directory used for Ubuntu PPA; binary package named `nss-docker-ng`; uses `vendor.tar.gz` + `cargo build --offline` + `patchelf` + `dh-sequence-installnss` |
| Ubuntu PPA `nss-docker-ng` | Installs to `/usr/local/lib/nss-docker-ng/` — non-standard path; not suitable for Debian |
| `libnss-myhostname` | Debian reference for NSS module packaging conventions |
| `libnss-resolve` | Debian reference for NSS module packaging conventions |

---

## Open Questions

1. **SONAME injection:** Upstream uses `patchelf` post-build. An alternative is to
   pass `-C link-arg=-Wl,-soname,libnss_docker_ng.so.2` via `RUSTFLAGS` during the
   Cargo build, avoiding the `patchelf` build-dependency. This should be tested.

2. **ITP coordination:** Should this repository take over Debian ITP #1119131, or file
   a new ITP? Coordination with the original submitter is needed before any upload.
   The exact ITP details (filer, date, current discussion) could not be verified during
   research as `bugs.debian.org` was unreachable; follow-up via
   `curl https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1119131` is required.

3. **Vendored crate licensing:** A complete audit of all transitive dependencies pulled
   in by `cargo vendor` must be done before upload to confirm DFSG compliance and
   complete the `debian/copyright` file. The upstream's `debian/copyright` (DEP-5
   format) is a starting point but must be reviewed and updated.

4. **`libnss-docker` exact control fields:** The `salsa.debian.org` repository for
   `libnss-docker` was unreachable during research. The exact `Provides`, `Conflicts`,
   and `Replaces` fields of the current package must be verified (via
   `apt-get source libnss-docker`) before finalising the relationships in this package's
   `debian/control`.

5. **Rust toolchain version:** The upstream pins Rust to 1.91.0 via `rust-toolchain.toml`.
   The Debian package must use the Rust toolchain available in Debian, not a pinned
   version. The MSRV of `nss-docker-ng` and its dependencies must be confirmed against
   the Rust version in the target Debian suite.

6. **`arm64` support:** Should `arm64` be added to the initial CI matrix? Docker
   supports `amd64` and `arm64` in practice, making `arm64` a natural second target.

7. **Standards-Version:** The upstream `debian/control` uses `Standards-Version: 4.5.1`.
   This packaging repository should use the current Debian policy version (4.7.x).

---

## Next Implementation Step

Implement the `debian/` packaging directory:

1. `debian/control` — source and binary package metadata with the relationships above.
2. `debian/rules` — minimal `dh $@` rules file with `cargo build --release --offline`
   and `patchelf` SONAME injection.
3. `debian/copyright` — DEP-5 file covering upstream and all vendored crates.
4. `debian/watch` — upstream version tracking.
5. `debian/changelog` — initial entry.
6. Vendor tarball generation script or instructions for maintainers.
7. CI to build the `.deb` and verify library installation path. CI results are
   for validation only; upload to any Debian repository requires explicit maintainer
   review and action and must not be triggered automatically.
