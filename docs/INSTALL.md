# Installation

`install.sh` builds the whole stack on a **fresh Debian 12 (bookworm)** LXC or VM. It refuses
to run over an existing installation — use `upgrade_services.sh` for updates.
See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces connect.

## 1. Prerequisites

* Debian 12, root shell, 2+ vCPU, 4 GB+ RAM, 20 GB+ disk.
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
NAT reflection (hairpin) for these forwards lets LAN clients use the public address too.

## 3. Edge proxy (Caddy example)

The proxy **must preserve the original `Host` header** — Caddy rewrites `Host` to the
upstream address for HTTPS upstreams unless told otherwise, and nginx then routes every
request to the wrong site.

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
        # (this deployment uses caddy-security: `authorize with <policy>`)
        handle /register* {
            # authorize with discord
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

    # --- Matrix Authentication Service ---------------------------------
    @auth host auth.chat.example.com
    handle @auth {
        reverse_proxy https://192.168.1.100:443 {
            header_up Host {host}
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
}
```

After changing Caddy, make sure it actually reloaded (OPNsense: *Apply*), then test
`curl https://chat.example.com/_matrix/client/versions` from outside.

## 4. Configure and install

```bash
cp setup.config.example setup.config && chmod 600 setup.config
nano setup.config                    # MATRIX_FQDN, LAN_IP, EDGE_PROXY_IP, TURN_DDNS_HOST, SMTP_*...
cp refresh_certs.conf.example refresh_certs.conf && nano refresh_certs.conf   # optional, see §5

./install.sh --render-only /tmp/preview   # optional: inspect every config it will write
./install.sh
```

What `install.sh` does, in order:

1. Base packages, locale, build tools (for coturn), `unattended-upgrades` (Debian security only).
2. APT repos with pinned signing keys: `packages.matrix.org`, PGDG, nginx.org mainline.
3. Synapse, newest PostgreSQL, nginx, Debian coturn (for its user/unit).
4. Service users `mas`, `maubot`, `livekit`, `lk-jwt`; databases `synapse_db` (C collation),
   `mas_db`, `maubot_db`.
5. Latest releases of MAS, Element Web, Synapse-Admin, LiveKit, lk-jwt-service (SHA-256
   verified); coturn built from source; Maubot venv; `mas-invite` from this repo.
6. Every config file (see `--render-only`), nginx sites, a placeholder TLS cert.
7. MAS migrations, admin user in MAS, all services enabled; cron jobs for cert refresh,
   monitoring and public-IP sync.
8. Credentials → `/root/matrix_credentials.txt` (mode 600).

## 5. Post-install

* **Certificates** — `refresh_certs.sh` downloads `$CERT_NAME.crt/.key` from
  `CERT_SOURCE_URL` (a protected endpoint on the edge that exports Caddy's certificate),
  installs them for nginx and coturn, and reloads both. It runs nightly from cron.
* **Google (or other) sign-in** — add an upstream provider to `/opt/mas/config.yaml`
  (see ADMIN_GUIDE.md → *Upstream OAuth*), then `mas config sync` and restart MAS.
* **Backups** — enable the nightly job (ADMIN_GUIDE.md → *Backups*).
* **Monitoring** — set `MONITOR_WEBHOOK_URL` in `setup.config`; `./monitor_services.sh --test`.

## 6. Verify

```bash
./upgrade_services.sh                                   # also a full health check
curl -s https://chat.example.com/_matrix/client/versions | head -c 100
curl -s https://chat.example.com/_matrix/client/v1/auth_metadata | head -c 100
curl -s https://chat.example.com/livekit/jwt/healthz
```

Then open `https://chat.example.com`, sign in as the admin, place a call between two
devices (one off-LAN), and check https://federationtester.matrix.org/.
