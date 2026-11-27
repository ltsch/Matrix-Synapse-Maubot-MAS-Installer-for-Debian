# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository: a self-hosted
Matrix stack (Synapse + MAS + PostgreSQL + nginx + Element Web/Call + LiveKit +
lk-jwt-service + coturn + Synapse-Admin + Maubot + mas-invite) installed and maintained on
Debian 12 by shell scripts.

## Documentation map

| Need | Read |
| :--- | :--- |
| What this is, versions validated, repo layout | [README.md](README.md) |
| Prerequisites, DNS, port forwards, edge-proxy (Caddy) config, install steps | [docs/INSTALL.md](docs/INSTALL.md) |
| Host requirements (LXC, resources, outbound access) | [INSTALL §1](docs/INSTALL.md#1-prerequisites) |
| Firewall / NAT ports to forward | [INSTALL §2](docs/INSTALL.md#2-firewall--port-forwarding) |
| Edge proxy requirements (`Host` header!) | [INSTALL §3](docs/INSTALL.md#3-edge-proxy-caddy-example) |
| What `install.sh` does, step by step | [INSTALL §4](docs/INSTALL.md#4-configure-and-install) |
| Post-install steps (certs, OAuth, backups, monitoring) | [INSTALL §5](docs/INSTALL.md#5-post-install) |
| Post-install verification, including calls | [INSTALL §6](docs/INSTALL.md#6-verify) |
| How components connect (diagram) | [ARCHITECTURE → Overview](docs/ARCHITECTURE.md#overview) |
| Component / binary / config path / unit table | [ARCHITECTURE → Components](docs/ARCHITECTURE.md#components) |
| systemd services and timers: users, ordering, restart policy, schedules | [ARCHITECTURE → systemd units](docs/ARCHITECTURE.md#systemd-units) |
| Every listening port and who talks to it | [ARCHITECTURE → Ports](docs/ARCHITECTURE.md#ports) |
| Login, client API, federation, MatrixRTC call flows | [ARCHITECTURE → Request flows](docs/ARCHITECTURE.md#request-flows) |
| Which proxies are trusted for client IPs | [ARCHITECTURE → Trust boundaries](docs/ARCHITECTURE.md#trust-boundaries--client-ips) |
| Where each secret lives and who reads it | [ARCHITECTURE → Secrets map](docs/ARCHITECTURE.md#secrets-map) |
| Symptom → cause → fix | [ARCHITECTURE → Troubleshooting](docs/ARCHITECTURE.md#troubleshooting-by-symptom) |
| Service names and log locations | [ADMIN_GUIDE → Services](docs/ADMIN_GUIDE.md#services) |
| User management (always via MAS) | [ADMIN_GUIDE → Users](docs/ADMIN_GUIDE.md#users) |
| Bots: installed Maubot plugins, adding one, reconnecting the bot | [ADMIN_GUIDE → Bots](docs/ADMIN_GUIDE.md#bots-maubot) |
| Google / upstream OAuth in MAS | [ADMIN_GUIDE → Upstream OAuth](docs/ADMIN_GUIDE.md#upstream-oauth-eg-google-sign-in) |
| Upgrading components; breaking-change sources | [ADMIN_GUIDE → Upgrades](docs/ADMIN_GUIDE.md#upgrades) |
| Rolling back a bad upgrade (`*.prev`, `apt-mark hold`) | [ADMIN_GUIDE → Rollback](docs/ADMIN_GUIDE.md#rollback) |
| PostgreSQL major-version upgrade | [ADMIN_GUIDE → PostgreSQL major upgrade](docs/ADMIN_GUIDE.md#postgresql-major-upgrade-manual) |
| Backups | [ADMIN_GUIDE → Backups](docs/ADMIN_GUIDE.md#backups) |
| Rebuild on a new host / restore from backup | [ADMIN_GUIDE → Rebuild / restore](docs/ADMIN_GUIDE.md#rebuild--restore-on-a-new-host) |
| Rotating each secret | [ADMIN_GUIDE → Rotating secrets](docs/ADMIN_GUIDE.md#rotating-secrets) |
| TLS certificate refresh | [ADMIN_GUIDE → Certificates](docs/ADMIN_GUIDE.md#certificates) |
| Public-IP tracking for coturn/LiveKit | [ADMIN_GUIDE → Public IP changes](docs/ADMIN_GUIDE.md#public-ip-changes) |
| Monitoring / alert webhook | [ADMIN_GUIDE → Monitoring](docs/ADMIN_GUIDE.md#monitoring) |
| Client assumptions, enabled MSCs, privacy settings | [ADMIN_GUIDE → Configuration reference](docs/ADMIN_GUIDE.md#configuration-reference) |
| Host hardening: restart policies, log permissions, journal cap, SSH, firewall | [ADMIN_GUIDE → Host hardening](docs/ADMIN_GUIDE.md#host-hardening) |
| Accepted limitations and deferred work | [ADMIN_GUIDE → Known limitations](docs/ADMIN_GUIDE.md#known-limitations-and-deferred-work) |
| Site settings (all variables, with comments) | [setup.config.example](setup.config.example) |
| Cert-refresh settings | [refresh_certs.conf.example](refresh_certs.conf.example) |

## Code map

| File | Role |
| :--- | :--- |
| [install.sh](install.sh) | Fresh install. All config templates live here as `render_*` functions (`render_synapse`, `render_mas`, `render_coturn`, `render_livekit`, `render_maubot`, `render_web`, `render_nginx`, `render_system`). `--render-only DIR` writes every config without touching the system. |
| [lib/common.sh](lib/common.sh) | Shared helpers used by `install.sh` and `upgrade_services.sh`: logging, GitHub release lookup, SHA-256-verified downloads, per-component installers (`install_mas`, `install_element_web`, `install_livekit`, `install_lk_jwt`, `build_coturn`, ...). |
| [upgrade_services.sh](upgrade_services.sh) | Resolve releases, back up, upgrade, restart in order, health-check; `--check` only checks. |
| [manage_users.py](manage_users.py) | User admin; every write goes through the MAS CLI. |
| [monitor_services.sh](monitor_services.sh) | Health check + webhook alerts (`matrix-monitor.timer`, 5 min). |
| [update_turn_ip.sh](update_turn_ip.sh) | Public-IP sync for coturn/LiveKit (`matrix-turn-ip.timer`, 30 s). |
| [refresh_certs.sh](refresh_certs.sh) | TLS cert pull from the edge proxy (`matrix-refresh-certs.timer`, nightly + boot). |
| [backup_matrix.sh](backup_matrix.sh) | DB dumps + configs + media, 14-day retention (`matrix-backup.timer`, disabled by default). |
| [mas-invite/invite_gen.py](mas-invite/invite_gen.py) | Flask invite-token page (deployed to `/opt/mas/invite_gen.py`). |
| [maubot_requirements.txt](maubot_requirements.txt) | Maubot venv packages. |
| [docs/](docs/) | INSTALL, ARCHITECTURE, ADMIN_GUIDE (see the documentation map above). |
| [examples/](examples/) | Optional host firewall configs (nftables, ufw); not applied by `install.sh`. Keep the ports in sync with ARCHITECTURE → Ports. |
| [.gitignore](.gitignore) | Allow-list: every tracked top-level path must be listed with `!`. |
| systemd units, logrotate | Not files in the repo: rendered by `install.sh` (`render_*` functions, `job_unit`/`timer_unit`); see them with `--render-only`. |

## Rules

### Secrets and privacy (this repository is public)
* **Never commit real hostnames, IPs or secrets.** Use `example.com`, `chat.example.com`,
  `auth.chat.example.com`, `192.168.1.x` and `203.0.113.x` placeholders in code and docs.
  The history was rewritten once (2026-11-26) to remove leaked credentials; do not repeat it.
* Real values live only in git-ignored files on the host: `setup.config`,
  `refresh_certs.conf`, `/root/matrix_credentials.txt`, and the live configs under
  `/etc` and `/opt` (see the [Secrets map](docs/ARCHITECTURE.md#secrets-map)).
* Before committing, grep the staged diff for the live domain, public/LAN IPs and any
  `secret`/`password` values.

### The repository lives in `/root`
* `.gitignore` is an **allow-list** (`/*` then `!` entries). A new top-level file is ignored
  until you add a `!/<name>` line for it.
* `/root/archive/` holds pre-upgrade backups and legacy files — not part of the project.

### Keep the repo and the running host in sync
* The repo must describe what is actually deployed and known working. When you change a
  live config, change the matching `render_*` template in `install.sh` (and the docs) too.
* Parity check: `./install.sh --render-only /tmp/render` and diff against the live files
  (secrets render as `@NAME@` placeholders unless supplied via the environment).
* **No cron.** Scheduled jobs are oneshot service + timer pairs created with `job_unit` /
  `timer_unit` in `render_system` (`install.sh`).
* When you add a service, port, secret or scheduled job, update **all** of:
  [ARCHITECTURE](docs/ARCHITECTURE.md) (components, systemd units, ports, secrets map),
  [ADMIN_GUIDE](docs/ADMIN_GUIDE.md) (services/logs), `monitor_services.sh`,
  `upgrade_services.sh`, and the README layout table.

### Operational invariants
* **MAS owns accounts.** Never edit users in Synapse's database; use `manage_users.py` or
  `mas manage`.
* Restart order when both change: `mas` → `matrix-synapse` → everything else.
* MAS, mas-invite, lk-jwt-service and Synapse listen on 127.0.0.1 only; nginx is the only
  LAN-facing HTTP entry point and trusts `X-Forwarded-For` only from `EDGE_PROXY_IP`.
* The edge proxy must forward the original `Host` header, or nginx routes to the wrong site.
* `synapse_db` must keep `C` collation.
* Components are tracked at their newest upstream releases. Read upstream release notes
  before upgrading — Synapse and coturn refuse to start on removed options.

### Style and checks
* Bash: scripts use `set -euo pipefail` (`monitor_services.sh` uses `set -uo pipefail`: it
  must keep going after a failed check); run `shellcheck` on every changed script.
* Scheduled jobs must fail loudly (non-zero exit) and never leave half-done state that looks
  valid; the monitor turns failed units into alerts.
* Python: `python3 -m py_compile` on changed files.
* Templates are rendered with `envsubst` over an explicit variable list (`SUBST_VARS` in
  `install.sh`); a new `${VAR}` in a template must be added to that list.
* Commit only known-working changes; describe *why* in the message.
