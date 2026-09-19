# Build Verification — Vaultwarden for TOS

This document explains where every binary shipped in the TOS App Center
package comes from, and how to verify or reproduce it yourself.

## Artifact chain

```
upstream source tag ──► GitHub Actions (this repo) ──► GitHub Release ──► deb
                        public build recipe              pinned sha256      fetch re-verifies
```

| Artifact | Origin | Verification |
|---|---|---|
| `vaultwarden` server binary | Built by the public CI workflow (`.github/workflows/release.yml`) from the upstream source tag `VAULTWARDEN_VERSION` of [dani-garcia/vaultwarden](https://github.com/dani-garcia/vaultwarden) | `SHA256SUMS` in the Release + `VW_SHA256_*` pin in `config.env`; the package build (`./build.sh verify`) re-checks the exact sha256 of the binary it stages |
| web vault (static HTML/JS) | Official [dani-garcia/bw_web_builds](https://github.com/dani-garcia/bw_web_builds) release tarball, tag `v<WEB_VAULT_VERSION>`, redistributed unmodified | Same double pin (`SHA256SUMS` + `WEB_VAULT_SHA256` in `config.env`) |

## Why the binaries are built here (and not taken from Docker Hub)

The TOS App Center rejects prebuilt ELF blobs that have no auditable source
chain (review finding V6). Upstream Vaultwarden publishes no binary releases
since 1.37.x — its GitHub Release is source-only — and the binaries inside
the official Docker image are opaque blobs. Therefore this repository builds
the binaries itself, in public CI, using the exact same recipe as the
official `docker/Dockerfile.alpine`:

* container: `ghcr.io/blackdex/rust-musl:<arch>-musl-stable-<rust>`
  (the same builder images the upstream Dockerfile uses)
* command:
  `cargo build --features sqlite,mysql,postgresql,enable_mimalloc --profile release --target <arch>-unknown-linux-musl`
* version embedding: `VW_VERSION` env var, identical to the upstream
  Dockerfile build argument
* result: static-pie musl binary, no dynamic loader, no UPX

The web vault is **not** modified or rebuilt by us; it is the official
bw_web_builds artifact (frontend-only static assets — no ELF code), which the
CI records with its upstream tag and sha256.

## How to verify a published deb

```sh
# 1. deb sha256 (asset-level)
sha256sum vaultwarden_x86_64.deb        # compare with the .sha256 sidecar

# 2. binary sha256 (source-level): unpack and compare with the Release
dpkg-deb -x vaultwarden_x86_64.deb pkg && sha256sum pkg/usr/local/vaultwarden/bin/vaultwarden
# → must equal the vaultwarden-<arch> line in the Release's SHA256SUMS
#   and the VW_SHA256_AMD64 pin in config.env

# 3. static + arch sanity
file pkg/usr/local/vaultwarden/bin/vaultwarden
# → ELF 64-bit ... x86-64 ... static-pie linked  (no "dynamically linked",
#   no "no section header" which would indicate UPX)
```

## How to reproduce the binaries

```sh
./repro-build.sh x86_64     # or aarch64; needs Docker
```

This runs the upstream-identical build inside
`ghcr.io/blackdex/rust-musl:<arch>-musl-stable-1.98.1` and prints the
resulting sha256. Note that Rust builds are not guaranteed bit-for-bit
reproducible across builder hosts (paths and timestamps can be embedded);
the authoritative value is the sha256 recorded in the Release and pinned in
`config.env`. The public CI run linked from the Release is the audit trail.

## Package provenance inside the deb

`/usr/share/doc/vaultwarden/PROVENANCE.md` in every deb records the upstream
tag, web vault tag, CI repository, toolchain and both sha256 pins.
