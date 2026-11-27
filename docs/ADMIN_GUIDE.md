# Administration Guide

> Docs: [README](../README.md) · [INSTALL](INSTALL.md) · [ARCHITECTURE](ARCHITECTURE.md) · [ADMIN_GUIDE](ADMIN_GUIDE.md) · [AGENTS](../AGENTS.md)

Day-to-day operation of the stack. Architecture, ports and troubleshooting tables are in
[ARCHITECTURE.md](ARCHITECTURE.md). Commands assume you are root in the repo directory.

## Services

```bash
systemctl status matrix-synapse mas mas-invite livekit lk-jwt-service coturn maubot nginx postgresql
systemctl restart <service>
```

| Service | Logs |
| :--- | :--- |
| matrix-synapse | `/var/log/matrix-synapse/homeserver.log` (detail), `journalctl -u matrix-synapse` (startup/config errors) |
| mas, mas-invite, livekit, lk-jwt-service, maubot, coturn | `journalctl -u <service> -f` |
| nginx | `/var/log/nginx/access.log`, `error.log` |
| PostgreSQL | `/var/log/postgresql/postgresql-<ver>-main.log` |
| scheduled jobs (`matrix-*.timer`) | `/var/log/update_turn_ip.log`, `matrix_monitor.log`, `refresh_certs.log`, `matrix_backup.log` (rotated weekly) |

Restart order after config changes that touch both: `mas` → `matrix-synapse` → the rest.

Scheduled jobs are systemd timers, not cron: `systemctl list-timers 'matrix-*'`. Unit
details (users, ordering, restart policy, schedules) are in
[ARCHITECTURE → systemd units](ARCHITECTURE.md#systemd-units).

## Users

MAS owns accounts; it provisions them into Synapse. **Change users through MAS**, never by
editing Synapse's database (that is how accounts end up half-existing).

```bash
./manage_users.py list                 # MAS + Synapse view; flags users missing in Synapse
./manage_users.py register alice [--admin]
./manage_users.py lock alice | unlock alice
./manage_users.py deactivate alice     # permanent; asks for confirmation
./manage_users.py logout alice         # end all sessions
./manage_users.py promote alice | demote alice
./manage_users.py invite --uses 1 --days 7
```

Self-service registration is invite-only: `https://chat.example.com/register` (mas-invite,
behind Caddy auth) mints a 5-use, 30-day token and shows the MAS registration link.
Password reset by email is enabled when SMTP is configured.

**Synapse-Admin** (`/synapse-admin`, LAN only): sign in with *password* (not SSO) using a
MAS admin account; nginx routes that login to MAS's compatibility layer.

### Upstream OAuth (e.g. Google sign-in)

Add to `/opt/mas/config.yaml`:

```yaml
upstream_oauth2:
  providers:
    - id: 01JABCDEFGHJKMNPQRSTVWXYZ0   # any ULID (first character 0-7)
      human_name: Google
      issuer: "https://accounts.google.com"
      client_id: "<client id>"
      client_secret: "<client secret>"
      token_endpoint_auth_method: client_secret_post
      scope: "openid profile email"
```

```bash
cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml ./mas config sync --prune --dry-run
cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml ./mas config sync --prune
systemctl restart mas
```

The redirect URI to register with the provider is
`https://auth.chat.example.com/upstream/callback/<id>`. MAS normalises the ULID (an
out-of-range first character is silently changed), so copy the exact URL MAS uses:
`curl -s -o /dev/null -w '%{redirect_url}' https://auth.chat.example.com/upstream/authorize/<id>`
and read its `redirect_uri` parameter.

## Upgrades

```bash
./upgrade_services.sh
```

Upgrades APT packages (Synapse, PostgreSQL minor, nginx, Debian), MAS (validates the
existing config with the new binary before swapping), Element Web, Synapse-Admin, LiveKit,
lk-jwt-service, coturn (rebuilt from source), the Maubot venv; restarts everything; health-checks.

Read release notes when jumping versions — this is where breakage comes from:
* **Synapse** refuses to start with removed options
  ([upgrade notes](https://element-hq.github.io/synapse/latest/upgrade.html)).
* **coturn** stops on removed options (e.g. `no-cli` removed in 4.18; DTLS opt-in since 4.17).
* **MAS / LiveKit / lk-jwt-service**: GitHub release notes.

### PostgreSQL major upgrade (manual)

```bash
apt-get install postgresql-<new>          # from PGDG; do not let it create a cluster
systemctl stop matrix-synapse mas mas-invite maubot lk-jwt-service
pg_upgradecluster <new> <old> main        # new cluster takes port 5432
systemctl start mas matrix-synapse mas-invite maubot lk-jwt-service
# verify, then:
pg_dropcluster <old> main && apt-get purge postgresql-<old> postgresql-client-<old>
```

`synapse_db` must keep `C` collation (`pg_upgradecluster` preserves it).

## Backups

`backup_matrix.sh` writes `$BACKUP_DIR/<timestamp>/` (`BACKUP_DIR` in `setup.config`,
default `/mnt/backup/matrix`): `globals.sql` (database roles and passwords), custom-format
dumps of the three databases, `files.tgz` (configs, secrets, signing keys, nginx, systemd
units, `setup.config`) and `media.tgz`. `matrix-backup.timer` (03:30 nightly) is installed
but **not enabled by default** (it is enabled on the reference deployment):

```bash
systemctl start matrix-backup.service          # first run; check /var/log/matrix_backup.log
systemctl enable --now matrix-backup.timer     # nightly from then on
```

How a run works, so a failure can never look like a good backup:
* It writes into `.partial-<timestamp>`, verifies everything (roles present, each dump
  readable by `pg_restore --list`, both archives readable, `homeserver.yaml`, the MAS config
  and the Synapse signing key present in `files.tgz`), then renames the folder and writes a
  `COMPLETE` marker. A failed run leaves nothing behind; the unit shows as failed.
* Retention counts only completed backups: those older than `BACKUP_KEEP_DAYS` (14) are
  deleted, but the newest `BACKUP_KEEP_MIN` (3) are always kept.
* A lock prevents a manual run and the timer run overlapping; a run is killed after 4 h.
* Once the timer is enabled, `monitor_services.sh` alerts if it stops or no completed backup
  is newer than 36 h.

`files.tgz` holds plaintext secrets — keep the backup folder (mode 700) and any copy restricted.

`/mnt/backup` is a plain directory on the container's own disk until you give it separate
storage — e.g. a Proxmox mount point (`pct set <vmid> -mp0 <storage>:<size>,mp=/mnt/backup`)
— and copy backups off-host too (Proxmox Backup Server, rsync, restic).

Restore, in order: `tar xzf files.tgz -C /`; `sudo -u postgres psql -f globals.sql` (roles);
`sudo -u postgres pg_restore --clean --if-exists -d <db> <db>.dump` for each database
(create it first on a fresh server; `synapse_db` with `C` collation); `tar xzf media.tgz -C /`;
restart services (`mas` → `matrix-synapse` → the rest).

## Certificates

`refresh_certs.sh` (`matrix-refresh-certs.timer`: nightly and after boot) downloads
`<CERT_NAME>.crt`/`.key` from `CERT_SOURCE_URL` (`refresh_certs.conf`). If they differ from the
installed pair it installs them only after checking that the certificate is valid for
`CERT_NAME`, does not expire within 24 h, and matches the key. It then runs `nginx -t`
(restoring the old pair if that fails), reloads nginx, and copies the pair to coturn
(`/etc/turn_server_*.pem`) and restarts it. Any failure exits non-zero, so the unit shows as
failed and the monitor alerts; the monitor also alerts 14 days before the installed cert
expires. Log: `/var/log/refresh_certs.log`. Check expiry:
`openssl x509 -enddate -noout -in /etc/nginx/ssl/matrix.crt`.

## Public IP changes

coturn and LiveKit must advertise the current public IP. `matrix-turn-ip.timer` runs
`update_turn_ip.sh` every 30 s. It asks OpenDNS which address it sees us from
(`myip.opendns.com`), so it does not wait for DDNS to catch up. If that fails it resolves
`TURN_DDNS_HOST`, then tries `ifconfig.me`. Only a routable public IPv4 address is accepted
(private, CGNAT, loopback, link-local and reserved answers are ignored). A new address must be
seen on two consecutive runs before it is applied, so one odd lookup never restarts anything.
Then it rewrites `external-ip=<public>/<LAN>` in `/etc/turnserver.conf` and restarts coturn
and LiveKit: calls recover about a minute after the change. That restart drops calls in
progress, but they are already broken once the public IP moves. The script is silent when
nothing changed; changes go to `/var/log/update_turn_ip.log`. If no source returns a usable
address the run fails, which the monitor reports.

```bash
systemctl list-timers matrix-turn-ip.timer     # last/next run
systemctl start matrix-turn-ip.service         # run now
```

## Monitoring

`monitor_services.sh` (`matrix-monitor.timer`, every 5 min) checks:

* every service and the job timers are active;
* the real PostgreSQL cluster units (`postgresql@<ver>-main`; `postgresql.service` is only a
  wrapper that always looks active) and that PostgreSQL accepts connections (`pg_isready`);
* no systemd unit is in the failed state (catches a failed backup, cert refresh or IP sync);
* a completed backup newer than 36 h (once `matrix-backup.timer` is enabled);
* the TLS certificate does not expire within `MONITOR_CERT_WARN_DAYS` (14);
* `/` and `BACKUP_DIR` are below `MONITOR_DISK_WARN_PCT` (90 %) full;
* the client API, federation, MAS and lk-jwt-service endpoints and the Maubot UI answer through
  the public names without a 5xx.

Alerts go to `MONITOR_WEBHOOK_URL` (Discord-compatible) only when a problem appears or the set of
problems changes, again every `MONITOR_REALERT_HOURS` (6) while it persists, and once as
**RESOLVED** when everything passes (state in `/var/lib/matrix-monitor/`). A delivery failure
is logged and retried on the next run. Every failing run is logged with a timestamp and exits 1.

```bash
./monitor_services.sh --test     # send a multi-line test message to the webhook
./monitor_services.sh; echo $?   # run the checks now (silent and 0 when healthy)
```

Job logs in `/var/log/` are rotated weekly (8 kept, compressed) by `/etc/logrotate.d/matrix-jobs`.

## Configuration reference

### Client assumptions (latest apps only)
* Element Web sends **all** calls through Element Call (`element_call.use_exclusively`);
  embedded Element Call is pinned to `matrix_rtc_mode: matrix_2_0` (sticky events).
* Synapse advertises only the stable `m.livekit` MatrixRTC transport.
* `.well-known/matrix/client` carries only `m.homeserver`; clients find MAS via
  `/_matrix/client/v1/auth_metadata`.
* QR-code sign-in uses MSC4388 (`msc4388_mode: open`).
* No identity server is configured (no `vector.im`); invites by email address are not available.

### Synapse experimental features
Enabled (all commented inline in `homeserver.yaml`): MatrixRTC (`msc4143`, `msc4502`,
`msc4512`, `msc4354`, `msc4075`), QR login (`msc4388`), profile fields (`msc4133`),
dehydrated devices (`msc3814`), threads (`msc4306`, `msc3773`), push rules (`msc3664`,
`msc3381_polls`), invite filtering (`msc4155`), auto-forget (`msc4267`), redact on
kick/ban (`msc4293`), mark unread (`msc4446`), busy presence (`msc3026`), moderator view
of redactions (`msc2815`), relation redactions (`msc3912`), invite reasons (`msc4491`),
profile endpoints (`msc4536`).

Deliberately **off**: `msc4242` (state DAGs), `msc1767` (extensible events) — experimental
and can break rooms; `msc2654` (Synapse warns counts are wrong); `msc4263` (breaks
verifying users you share no room with); `msc3890` (depends on a feature Element removed).

### Privacy
* Public room directory is not browsable without login or over federation.
* URL previews are on, but never fetch private/reserved addresses.

## Known limitations and deferred work

| Item | Status |
| :--- | :--- |
| `mas-invite` runs on Flask's built-in development server | Accepted for now: bound to 127.0.0.1, behind nginx and Caddy auth. Move to waitress/gunicorn if exposure changes. |
| PostgreSQL tuning (`shared_buffers` etc. are defaults) | Deferred: databases are ~40 MB; revisit if they grow into the GB range. |
| Debian 12 base (LTS since 2026-07) | Deferred: key services come from upstream repos; plan a Debian 13 upgrade before 2028-06. |
| lk-jwt-service without Redis | In-memory state; a restart mid-call loses delayed-leave bookkeeping only. |
| LiveKit TURN/TLS on 443 disabled | Clients on UDP-hostile networks fall back to 7881/tcp but not to TLS/443. |
| Single TLS cert (`chat.` only) also served for `auth.` | Fine behind Caddy (`tls_insecure_skip_verify`); direct LAN access to `auth.` shows a name mismatch. |
| Maubot bot account disabled | Plugins are installed; enable the client in the Maubot UI when needed. |
| postfix listening on localhost:25 | Debian default, unused by the stack. |
