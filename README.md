# nss-docker-ng Debian packaging

This repository packages [`nss-docker-ng`](https://github.com/petski/nss-docker-ng)
for Debian as the `libnss-docker-ng` binary package.

## Repository contents

- upstream source snapshot for `nss-docker-ng` 1.2.1
- `vendor.tar.gz` — offline Cargo build archive (`.cargo/config.toml` + `vendor/`)
- Debian packaging in `debian/`
- packaging notes in `docs/packaging-strategy.md`
- upstream update process in `docs/upstream-updates.md`
- release process in `docs/release-process.md`

## CI

Every push to `main` and every pull request runs the authoritative **Debian Package CI**
on Debian Trixie:

1. **Package build** — `dpkg-buildpackage` inside a Debian Trixie container; upstream
   unit tests run during `dh_auto_test`.
2. **Lintian / package-content checks** — lintian policy check plus explicit
   verification of installed file layout.
3. **Install + reinstall + removal lifecycle test** — installs the built `.deb`,
   verifies `docker_ng` is inserted into `/etc/nsswitch.conf`, reinstalls the same
   package and confirms no duplicate entry, removes the package and confirms exact
   NSS restoration to the pre-install state.
4. **Docker-backed `getent` smoke test** — installs the package and resolves a live
   container name via `getent hosts <container>.docker` using the real Docker socket.

All four stages must pass before a commit is considered valid.

## Building

Inside a Debian Trixie environment, install the build dependencies and build:

```bash
sudo apt-get install -y debhelper dh-nss cargo rustc
dpkg-buildpackage -us -uc -b
```

The minimum supported Rust version is **1.85** (the version shipped with Debian
Trixie). The `vendor.tar.gz` contains 198 pre-fetched Rust crate dependencies;
no network access is required during the build.

## Installing

After a successful build, install the generated package:

```bash
sudo apt install ../libnss-docker-ng_1.2.1-1_amd64.deb
```

`dh_installnss` updates `/etc/nsswitch.conf` automatically on install and reverts
the change automatically on removal.

## NSS configuration

The package ships `debian/libnss-docker-ng.nss` which declares the placement policy:

```
hosts before=dns,resolve docker_ng
```

`dh_installnss` reads this policy and inserts `docker_ng` before `dns` and `resolve`
on the `hosts:` line of `/etc/nsswitch.conf` at install time, while preserving all
other services already present on that line. On removal it removes `docker_ng` and
restores the line to its exact pre-install state.

The resulting `hosts:` line therefore depends on what was already configured on the
system; it is not a fixed string.

## Usage

Make sure the system can talk to Docker through `/var/run/docker.sock`, then
look up a container name in the `.docker` domain:

```bash
getent hosts my-container.docker
```

## Uninstalling

```bash
sudo apt remove libnss-docker-ng
```

`dh_installnss` removes the `docker_ng` entry from `/etc/nsswitch.conf` and restores
the original line automatically. To additionally purge any leftover package state:

```bash
sudo apt purge libnss-docker-ng
```

## Maintainer notes

### Upstream updates

New upstream releases are detected automatically by a scheduled workflow that queries
crates.io every Monday. When a new stable, non-yanked release is found, the workflow:

1. validates the release and verifies the crate checksum,
2. prepares an `upstream-update/<version>` branch with updated sources, a regenerated
   `vendor.tar.gz`, and a bumped `debian/changelog`,
3. evaluates the Trixie/MSRV compatibility patch,
4. runs the full package CI on the exact prepared commit, and
5. opens a reviewable pull request (draft if patch review is required).

No upstream update is merged or released automatically; human review is always required.

See [`docs/upstream-updates.md`](docs/upstream-updates.md) for the full maintainer flow,
including how to trigger the workflow manually and how to handle yanked releases.

### Releasing

Push a `debian/<version>` tag on a reviewed `main` commit. The release workflow
validates version consistency, runs the full package CI, and publishes the exact
validated artifacts to a GitHub Release.

See [`docs/release-process.md`](docs/release-process.md) for the complete sequence.

### Historical context

Early validation was performed on Ubuntu Noble (glibc 2.39) with `rustc 1.85.0`,
which matched Debian Trixie's compiler version at the time. Debian Trixie running
inside a Docker container is now the authoritative CI environment for all build,
lintian, lifecycle, and smoke-test validation.

## License

[MIT](LICENSE.txt) © 2026 Stefan Haun and contributors
