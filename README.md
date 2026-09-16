# Vaultwarden for TerraMaster TOS

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) packaged for the
TOS 7 App Center — a self-hosted, Bitwarden-compatible password manager
server in a single deb.

- **Web vault + admin panel** ship in the box (admin panel at `/admin`).
- **All Bitwarden clients** (browser extension, desktop, mobile) connect to
  `http://<NAS-IP>:8222` as a self-hosted server.
- **Static musl binary** taken from the official `vaultwarden/server:<ver>-alpine`
  image (content-verified by registry digest) — zero runtime dependencies.
- Runs as a dedicated unprivileged user in a hardened systemd sandbox.
- Vault data lives in `/var/lib/vaultwarden` (kept on `apt remove`, deleted on
  `apt purge`).

## Install

Install the deb for your architecture via the TOS App Center (manual install)
or `apt install ./vaultwarden_*.deb`. Builds: `x86_64` and `aarch64`.

## First run

1. Open the app from the TOS desktop — it opens `http://<NAS-IP>:8222` in a
   new browser tab.
2. **Create your account immediately** — the first person to register owns the
   vault. Then turn off open sign-ups (`SIGNUPS_ALLOWED=false` in
   `/usr/local/vaultwarden/vaultwarden.env`, then
   `systemctl restart vaultwarden`) or invite users from the admin panel.
3. Admin panel: `http://<NAS-IP>:8222/admin`. The token is generated at
   install time:
   ```sh
   grep ADMIN_TOKEN /usr/local/vaultwarden/vaultwarden.env
   ```
4. Point your Bitwarden clients (extension / desktop / mobile) at
   `http://<NAS-IP>:8222`.

## HTTPS note (important)

The **web vault in a browser requires HTTPS to unlock** (the browser WebCrypto
API is only available in secure contexts — this is inherent to every Bitwarden
web vault, not specific to this package). On a plain-HTTP LAN:

- use the Bitwarden **apps / browser extension** (they talk to the API directly
  and work over HTTP), or
- enable HTTPS on the NAS, or put an HTTPS reverse proxy in front (the proxy
  must serve Vaultwarden at the URL root, no sub-path).

Also set `DOMAIN=` in `vaultwarden.env` to your real access URL — it affects
email links, WebAuthn/passkeys and a few client features.

## Why a direct port instead of the TOS web-server route?

Vaultwarden's API endpoints are hard-mounted at the URL root (`/api`,
`/identity`, `/notifications`, ...) and the web vault issues root-relative
requests, so it cannot be served behind a `/vaultwarden/` prefix; the TOS web
port's root namespace belongs to TOS itself. The app therefore listens on
`0.0.0.0:8222` and a `/vaultwarden/` location on the TOS web port just
redirects there. (Same approach as other direct-port TOS apps.)

## Build from source

```sh
make check      # syntax + asset self-checks
./build.sh all  # fetch (Docker registry API, no docker needed) → stage → verify → deb
```

`config.env` pins the upstream version, package release and target arch.
Output lands in `out/` (`vaultwarden_<version>_<arch>.deb` for local installs,
`vaultwarden_{x86_64,aarch64}.deb` + `.sha256` as store release assets).

## License

Vaultwarden is AGPL-3.0. The bundled web vault is (c) Bitwarden Inc.
(AGPL-3.0). See `/usr/share/doc/vaultwarden/copyright` inside the package.
