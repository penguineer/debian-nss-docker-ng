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
Trixie). The package was tested with `rustc 1.85.0` using Trixie's archive
packages.

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

Remove the package:

```bash
sudo apt remove libnss-docker-ng
```

Purge it and remove the `nsswitch.conf` change:

```bash
sudo apt purge libnss-docker-ng
```

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
mkdir -p .cargo
cargo vendor > .cargo/config.toml
tar -zcf ../../vendor.tar.gz Cargo.lock .cargo/config.toml vendor/
```

## License

[MIT](LICENSE.txt) © 2026 Stefan Haun and contributors
