# nss-docker-ng Debian packaging

This repository packages [`nss-docker-ng`](https://github.com/petski/nss-docker-ng)
for Debian as the `libnss-docker-ng` binary package.

## Repository contents

- upstream source snapshot for `nss-docker-ng` 1.2.1
- `vendor.tar.gz` generated with `cargo vendor`
- Debian packaging in `debian/`
- packaging notes in `docs/packaging-strategy.md`

## Building

Install the Debian packaging helpers and Rust toolchain, then build the binary
package:

```bash
sudo apt-get install -y debhelper dh-nss cargo rustc
dpkg-buildpackage -us -uc -b
```

The minimum supported Rust version is **1.85** (the version shipped with Debian
Trixie). The package has been verified to build and pass its upstream test suite
with `rustc 1.85.0`. A clean Debian Trixie build and Docker-backed `getent`
test are tracked in issue #4.

The `vendor.tar.gz` contains all 198 Rust crate dependencies pre-fetched with
`cargo vendor`. No network access is required during the build.

## Installing

After a successful build, install the generated package from the parent
directory:

```bash
sudo apt install ../libnss-docker-ng_1.2.1-1_amd64.deb
```

`dh_installnss` updates `/etc/nsswitch.conf` automatically so that `docker_ng`
is added to the `hosts:` line.

## NSS configuration

The package manages `/etc/nsswitch.conf` automatically. If you need to inspect
the expected result, the relevant line looks like:

```text
hosts: files docker_ng dns resolve
```

## Usage

Make sure the system can talk to Docker through `/var/run/docker.sock`, then
look up a container name in the `.docker` domain:

```bash
getent hosts my-container.docker
```

## Uninstalling

Remove the package; `dh_installnss` removes the `docker_ng` entry from
`/etc/nsswitch.conf` automatically during removal:

```bash
sudo apt remove libnss-docker-ng
```

To additionally purge any leftover package state:

```bash
sudo apt purge libnss-docker-ng
```

## Validation

The following was verified on Ubuntu Noble (glibc 2.39) with `rustc 1.85.0`
(matching Debian Trixie's compiler version):

- Package builds successfully with `rustc 1.85.0`
- Upstream unit tests (`cargo test --locked --offline`) pass during build
- `dpkg -i` installs cleanly; `dh_installnss` inserts `docker_ng` into `/etc/nsswitch.conf`
- glibc can `dlopen` `libnss_docker_ng.so.2`; NSS symbols
  `_nss_docker_ng_gethostbyname2_r` and `_nss_docker_ng_gethostbyaddr_r` resolve
- `apt remove` reverts `/etc/nsswitch.conf` to its pre-install state and removes all library files

A clean Debian Trixie build environment and a live Docker-backed `getent` test
are tracked in issue #4.

## Maintainer notes

To refresh vendored dependencies for the packaged upstream release:

```bash
mkdir -p work
cd work
curl -L -A cargo --fail \
  https://static.crates.io/crates/nss-docker-ng/nss-docker-ng-1.2.1.crate \
  -o nss-docker-ng-1.2.1.crate
tar xzf nss-docker-ng-1.2.1.crate
cd nss-docker-ng-1.2.1
# Apply the Trixie compatibility patch before vendoring, so the vendored
# crates match the Trixie-compatible dependency resolution in Cargo.lock
patch -p1 < /path/to/debian/patches/0001-trixie-compat-msrv.patch
mkdir -p .cargo
cargo vendor > .cargo/config.toml
tar -zcf ../../vendor.tar.gz .cargo/config.toml vendor/
```

`Cargo.lock` is **not** included in `vendor.tar.gz`. The repository's
`Cargo.lock` (with the Trixie compatibility patch applied) is the single
authoritative lockfile used by `cargo --locked --offline` during the build.

## License

[MIT](LICENSE.txt) © 2026 Stefan Haun and contributors
