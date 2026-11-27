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
| cron jobs | `/var/log/refresh_certs.log`, `matrix_monitor.log`, `update_turn_ip.log`, `matrix_backup.log` |

Restart order after config changes that touch both: `mas` → `matrix-synapse` → the rest.

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

`backup_matrix.sh` writes `/var/backups/matrix/<timestamp>/`: custom-format dumps of the three
databases, `files.tgz` (configs, secrets, signing keys, nginx, units) and `media.tgz`; keeps
14 days. **Not scheduled by default** — enable it:

```bash
./backup_matrix.sh                     # first run
(crontab -l; echo '30 3 * * * /root/backup_matrix.sh >> /var/log/matrix_backup.log 2>&1') | crontab -
```

Backups are on the same disk — copy them off-host (Proxmox backup, rsync, restic).
Restore: `sudo -u postgres pg_restore --clean --if-exists -d <db> <db>.dump`;
`tar xzf files.tgz -C /`; `tar xzf media.tgz -C /`; restart services.

## Certificates

`refresh_certs.sh` (nightly) fetches `matrix.crt`/`matrix.key` from `CERT_SOURCE_URL`
(`refresh_certs.conf`), installs them for nginx and coturn, reloads both. Errors appear in
`/var/log/refresh_certs.log`. Check expiry:
`openssl x509 -enddate -noout -in /etc/nginx/ssl/matrix.crt`.

## Public IP changes

coturn and LiveKit must advertise the current public IP. `update_turn_ip.sh` (every 15 min)
resolves `TURN_DDNS_HOST`, rewrites `external-ip=<public>/<LAN>` in `/etc/turnserver.conf`
and restarts coturn and LiveKit when it changes. It is silent when nothing changed.

## Monitoring

`monitor_services.sh` (every 5 min) checks all services and key endpoints and posts to
`MONITOR_WEBHOOK_URL` on failure. Test with `./monitor_services.sh --test`.

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
