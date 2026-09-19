# Vaultwarden for TerraMaster TOS

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) packaged for the
TOS 7 App Center — a self-hosted, Bitwarden-compatible password manager
server in a single deb.

- **Web vault + admin panel** ship in the box, served through the TOS gateway
  route `/vaultwarden/` (admin panel at `/vaultwarden/admin`).
- **All Bitwarden clients** (browser extension, desktop, mobile) connect to
  `http(s)://<your-NAS>/vaultwarden` as a self-hosted server.
- **CI-built static binary**: this repository's public GitHub Actions build
  the server from the upstream source tag (musl, zero runtime dependencies);
  the web vault is the official [bw_web_builds](https://github.com/dani-garcia/bw_web_builds)
  release. See [VERIFICATION.md](VERIFICATION.md) for the full provenance chain.
- The service **listens on loopback only**; the TOS nginx gateway is the single
  entry point (reverse proxy with WebSocket support).
- Runs as a dedicated unprivileged user in a hardened systemd sandbox.
- Vault data lives in `/var/lib/vaultwarden` (kept on `apt remove`, deleted on
  `apt purge`).
- Privacy policy: `/vaultwarden/privacy-policy.html` (no telemetry; your vault
  never leaves the NAS).

## Install

Install the deb for your architecture via the TOS App Center (manual install)
or `apt install ./vaultwarden_*.deb`. Builds: `x86_64` and `aarch64`.

## First run

1. Open the app from the TOS desktop — it opens the web vault at
   `/vaultwarden/` (through the TOS web entry point).
2. **Create your account immediately** — the first person to register owns the
   vault. Then turn off open sign-ups (`SIGNUPS_ALLOWED=false` in
   `/usr/local/vaultwarden/vaultwarden.env`, then
   `systemctl restart vaultwarden`) or invite users from the admin panel.
3. Admin panel: `http(s)://<NAS>/vaultwarden/admin`. The token is generated at
   install time:
   ```sh
   grep ADMIN_TOKEN /usr/local/vaultwarden/vaultwarden.env
   ```
4. Point your Bitwarden clients (extension / desktop / mobile) at
   `http(s)://<NAS>/vaultwarden`.

## HTTPS note (important)

The **web vault in a browser requires HTTPS to unlock** (the browser WebCrypto
API is only available in secure contexts — this is inherent to every Bitwarden
web vault, not specific to this package). On a plain-HTTP LAN:

- use the Bitwarden **apps / browser extension** (they talk to the API directly
  and work over HTTP), or
- enable HTTPS on the NAS (the TOS gateway route `/vaultwarden/` then serves
  the web vault over HTTPS automatically).

Also set `DOMAIN=` in `vaultwarden.env` to your real access URL — it affects
email links, WebAuthn/passkeys and a few client features. **Keep the
`/vaultwarden` path part**; only change the scheme/host/port (the path is
pinned to the gateway route).

## Upstream & credits

- Server: [Vaultwarden](https://github.com/dani-garcia/vaultwarden) by
  Daniel García (AGPL-3.0) — built from source by this repo's CI.
- Web vault: [bw_web_builds](https://github.com/dani-garcia/bw_web_builds)
  (official patched builds of the Bitwarden web vault, AGPL-3.0).
- TOS packaging maintained by Moechz.

## Building the deb yourself

```sh
make check        # static asset checks
./build.sh        # fetch (from GitHub Releases) + stage + verify + deb
```

Version pins and sha256 checks live in `config.env`. To bump the upstream
version, update `config.env`, push, tag `v<version>` (CI builds and publishes
the binaries), then fill the new sha256 pins and rebuild.
