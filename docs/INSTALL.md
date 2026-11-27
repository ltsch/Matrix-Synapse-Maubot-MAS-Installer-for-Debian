# Installation

> Docs: [README](../README.md) · [INSTALL](INSTALL.md) · [ARCHITECTURE](ARCHITECTURE.md) · [ADMIN_GUIDE](ADMIN_GUIDE.md) · [AGENTS](../AGENTS.md)

`install.sh` builds the whole stack on a **fresh Debian 12 (bookworm)** LXC or VM. It refuses
to run over a completed installation — use `upgrade_services.sh` for updates. If an install
fails partway, fix the cause and simply run `./install.sh` again: it reuses the secrets from
the first attempt (`/root/.matrix-install-secrets`, deleted on success) and only creates
database roles/databases that are missing.
See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces connect.

## 1. Prerequisites

* Debian 12, root shell, 2+ vCPU, 4 GB+ RAM, 20 GB+ disk.
* **Proxmox LXC**: an *unprivileged* container with the Proxmox defaults works (this
  deployment: unprivileged, 8 vCPU, 8 GB RAM, 32 GB ZFS). No device passthrough (no TUN) is
  needed. systemd inside the container needs `nesting=1`, the default for new containers.
  Optionally add a mount point at `/mnt/backup` on separate storage for backups
  (ADMIN_GUIDE → Backups). A VM works the same way.
* **Outbound access** from the host: Debian mirrors, `packages.matrix.org`,
  `apt.postgresql.org`, `nginx.org`, `api.github.com` + `github.com` (releases),
  `pypi.org` (Maubot), and for public-IP discovery `resolver1.opendns.com` (DNS, UDP/53),
  `ifconfig.me` (fallback) and STUN (LiveKit uses `global.stun.twilio.com:3478`).
* A **static LAN IP** for the host (e.g. `192.168.1.100`).
* An **edge reverse proxy** that terminates public TLS and forwards to this host
  (this project is run behind Caddy on OPNsense; any proxy works if it does the same).
* DNS (public):
  * `chat.example.com` → your public IP
  * `auth.chat.example.com` → your public IP
  * a DDNS name that always tracks your public IP (e.g. `home.example.com`) for coturn/LiveKit
* A TLS certificate for `chat.example.com` that this host can download
  (`refresh_certs.sh` pulls it from the edge — see §5). Until then nginx uses a
  self-signed placeholder, which works behind a proxy that skips upstream verification.

## 2. Firewall / port forwarding

Forward these from the public IP to the Matrix host:

| Port | Protocol | Service | Purpose |
| :--- | :--- | :--- | :--- |
| 443 | TCP | edge proxy → host :443 | Client API, federation, web UIs, LiveKit signalling |
| 3478 | UDP + TCP | coturn | STUN/TURN (legacy calls) |
| 5349 | TCP + UDP | coturn | TURN over TLS / DTLS |
| 49152–50000 | UDP | coturn | TURN relay media |
| 7881 | TCP | LiveKit | MatrixRTC media, ICE/TCP fallback |
| 7882 | UDP | LiveKit | MatrixRTC media (UDP mux) |

Port 443 is handled by the edge proxy itself; the others are plain NAT port forwards.
**Federation also runs over 443**: nginx serves `/.well-known/matrix/server` pointing other
servers at `chat.example.com:443`, so port 8448 is not needed (check with
https://federationtester.matrix.org/).
NAT reflection (hairpin) for these forwards lets LAN clients use the public address too.

## 3. Edge proxy (Caddy example)

The proxy **must preserve the original `Host` header** — Caddy rewrites `Host` to the
upstream address for HTTPS upstreams unless told otherwise, and nginx then routes every
request to the wrong site.

Caddy wildcards match **one** label: `*.example.com` covers `chat.example.com` but *not*
`auth.chat.example.com`. Give `auth.chat.example.com` its own site block (as below) or use a
certificate that names it (e.g. `*.chat.example.com`).

```caddy
*.example.com {
    # --- Matrix homeserver -----------------------------------------------
    @chat host chat.example.com
    handle @chat {
        # Admin surfaces: LAN/VPN only
        @admin path /_synapse/admin* /synapse-admin* /_matrix/maubot*
        handle @admin {
            @denied not client_ip private_ranges
            abort @denied
            reverse_proxy https://192.168.1.100:443 {
                header_up Host {host}
                transport http {
                    tls_insecure_skip_verify
                }
            }
        }
        # Invite-token page: put authentication in front of it
        # (e.g. the caddy-security plugin: `authorize with <policy>`)
        handle /register* {
            # authorize with <policy>
            reverse_proxy https://192.168.1.100:443 {
                header_up Host {host}
                transport http {
                    tls_insecure_skip_verify
                }
            }
        }
        reverse_proxy https://192.168.1.100:443 {
            header_up Host {host}
            transport http {
                tls_insecure_skip_verify
            }
        }
    }

}

# --- Matrix Authentication Service (own block: not covered by *.example.com) ---
auth.chat.example.com {
    reverse_proxy https://192.168.1.100:443 {
        header_up Host {host}
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

The `/register` page's authentication lives at the edge only: nginx does not restrict it,
so anything that reaches nginx directly (the LAN) can mint invite tokens. If that matters,
add `allow <EDGE_PROXY_IP>; deny all;` to `location /register` in the nginx site.

After changing Caddy, make sure it actually reloaded (OPNsense: *Apply*), then test
`curl https://chat.example.com/_matrix/client/versions` from outside.

## 4. Configure and install

```bash
git clone <this repository> /root/matrix && cd /root/matrix   # any path works; this deployment uses /root
cp setup.config.example setup.config && chmod 600 setup.config
nano setup.config                    # see the comments in the file for every setting
cp refresh_certs.conf.example refresh_certs.conf && chmod 600 refresh_certs.conf
nano refresh_certs.conf              # see §5; without it the cert-refresh timer stays disabled

./install.sh --render-only /tmp/preview   # optional: inspect every config it will write
./install.sh                              # safe to re-run if it fails partway
```

What `install.sh` does, in order:

1. Preflight (root, bookworm, no completed install) and any missing bootstrap tools (`dig`,
   `envsubst`, `openssl`, `ip`, `python3`, `curl`) before any secret is generated.
2. Base packages, locale, build tools (for coturn), `unattended-upgrades` (Debian security only).
3. APT repos with fingerprint-pinned signing keys: `packages.matrix.org`, PGDG, nginx.org mainline.
4. Synapse, newest PostgreSQL, nginx, Debian coturn (for its user/unit).
5. Service users `mas`, `maubot`, `livekit`, `lk-jwt`.
6. Latest releases of MAS, Element Web, Synapse-Admin, LiveKit, lk-jwt-service (SHA-256
   verified; an asset without a published digest is refused); coturn built from source;
   Maubot venv; `mas-invite` from this repo.
7. Databases `synapse_db` (C collation), `mas_db`, `maubot_db` (created only if missing).
8. Every config file (see `--render-only`), nginx sites, a placeholder TLS cert.
9. MAS migrations, admin user in MAS, all services enabled; systemd timers for cert refresh,
   monitoring and public-IP sync (the backup timer is installed but left disabled).
10. Credentials → `/root/matrix_credentials.txt` (mode 600).

## 5. Post-install

* **Certificates** — `refresh_certs.sh` downloads `$CERT_NAME.crt/.key` from
  `CERT_SOURCE_URL` (a protected endpoint on the edge that exports Caddy's certificate;
  it carries the private key, so serve it over HTTPS or keep it reachable only from this host),
  installs them for nginx and coturn, and reloads both. `matrix-refresh-certs.timer` runs it
  nightly and after boot.
* **Google (or other) sign-in** — add an upstream provider to `/opt/mas/config.yaml`
  (see ADMIN_GUIDE.md → *Upstream OAuth*), then `mas config sync` and restart MAS.
* **Backups** — `systemctl enable --now matrix-backup.timer` (ADMIN_GUIDE.md → *Backups*).
* **Monitoring** — set `MONITOR_WEBHOOK_URL` in `setup.config`; `./monitor_services.sh --test`.

## 6. Verify

```bash
./upgrade_services.sh --check      # health check only (services, DB, timers, nginx, endpoints)
./monitor_services.sh --test       # webhook alert reaches your channel
curl -s https://chat.example.com/_matrix/client/versions | head -c 100
curl -s https://chat.example.com/_matrix/client/v1/auth_metadata | head -c 100
curl -s https://chat.example.com/livekit/jwt/healthz
```

**Calls.** Check that LiveKit found the public address, then make real calls:

```bash
journalctl -u livekit | grep -E 'found external IP|using external IPs'   # public IP, not the LAN IP
grep '^external-ip' /etc/turnserver.conf                                 # external-ip=<public>/<LAN>
```

* Element Web or Element X: start a call in a room between two accounts, one device off the
  LAN (e.g. a phone on mobile data). Both must see and hear each other. This exercises
  `/livekit/jwt` (token), `/livekit/sfu` (signalling) and 7881/tcp + 7882/udp (media).
* For coturn (legacy 1:1 calls), use the WebRTC *Trickle ICE* test page with
  `turn:chat.example.com:3478` and credentials from
  `/_matrix/client/v3/voip/turnServer` (signed-in request); a `relay` candidate with your
  public IP means TURN works.

Then open `https://chat.example.com`, sign in as the admin, and check federation at
https://federationtester.matrix.org/.
