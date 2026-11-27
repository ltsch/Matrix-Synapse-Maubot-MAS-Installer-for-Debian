# Matrix Homeserver Stack for Debian 12

Scripts and documentation to install, run and maintain a self-hosted Matrix server with
modern authentication and calling, on a Debian 12 LXC/VM behind an edge reverse proxy.

| Component | Role | Source |
| :--- | :--- | :--- |
| Synapse | Homeserver | packages.matrix.org |
| Matrix Authentication Service (MAS) | Accounts, OIDC login, QR sign-in | GitHub release |
| PostgreSQL | Databases | PGDG (newest major) |
| nginx | Routing / static files | nginx.org mainline |
| Element Web + Element Call | Web client, calling | GitHub release |
| LiveKit + lk-jwt-service | MatrixRTC calls (Element Call, Element X) | GitHub release |
| coturn | TURN/STUN for legacy calls | built from source |
| Synapse-Admin | Admin UI | GitHub release |
| Maubot | Bots | pip |
| mas-invite | Invite-token web page | this repo |

Versions validated together on 2026-11-26: Synapse 1.166.0, MAS 1.30.0, PostgreSQL 19,
nginx 1.31.10, Element Web 1.12.36, LiveKit 1.13.11, lk-jwt-service 0.10.0, coturn 4.19.2,
Synapse-Admin 0.11.4, Maubot 0.6.1.

## Quick start

```bash
cp setup.config.example setup.config && chmod 600 setup.config && nano setup.config
./install.sh
```

Prerequisites (DNS, port forwards, edge proxy config) are in **[docs/INSTALL.md](docs/INSTALL.md)**.

## Documentation

* [docs/INSTALL.md](docs/INSTALL.md) — prerequisites, firewall ports, Caddy example, install, verify
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — component diagram, systemd units and timers, ports, request flows, secrets, troubleshooting
* [docs/ADMIN_GUIDE.md](docs/ADMIN_GUIDE.md) — users, upgrades and rollback, backups, rebuild/restore, secret rotation, certificates, public IP, monitoring, configuration reference, known limitations
* [AGENTS.md](AGENTS.md) — documentation/code map and rules for contributors and AI agents

## Repository layout

| Path | Purpose | Schedule |
| :--- | :--- | :--- |
| `install.sh` | Fresh install (safe to re-run if it fails); `--render-only DIR` writes all configs for review | once |
| `upgrade_services.sh` | Back up, upgrade every component, health check; `--check` = health check only | manual |
| `lib/common.sh` | Shared download/verify/build helpers | — |
| `manage_users.py` | User admin via MAS (list/register/lock/deactivate/invite...) | manual |
| `monitor_services.sh` | Service + endpoint checks, webhook alerts | `matrix-monitor.timer`, every 5 min |
| `update_turn_ip.sh` | Keep coturn/LiveKit public IP current | `matrix-turn-ip.timer`, every 30 s |
| `refresh_certs.sh` | Pull TLS cert from the edge, reload nginx/coturn | `matrix-refresh-certs.timer`, nightly + boot |
| `backup_matrix.sh` | DB dumps + configs + media, 14-day retention | `matrix-backup.timer`, nightly (enable manually) |
| `mas-invite/invite_gen.py` | Invite-token page served at `/register` | systemd |
| `maubot_requirements.txt` | Maubot venv packages | — |
| `setup.config.example`, `refresh_certs.conf.example` | Site settings templates (real files are git-ignored) | — |
| `docs/` | INSTALL, ARCHITECTURE, ADMIN_GUIDE | — |
| `examples/` | Optional host firewall (nftables, ufw) — not applied by the installer | — |
| `AGENTS.md` | Documentation/code map and rules for contributors and agents | — |

## Credits

Originally inspired by the BashClub
[zamba-lxc-toolbox Matrix installer](https://github.com/bashclub/zamba-lxc-toolbox).
