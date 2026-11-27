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

Synapse logs at **INFO** (`root: level: INFO` in `/etc/matrix-synapse/log.yaml`). Raise it to
`DEBUG` only while chasing a problem, then set it back: DEBUG multiplies the log volume and
records request details. Restart `matrix-synapse` after changing it.

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
./manage_users.py deactivate alice     # asks for confirmation
./manage_users.py reactivate alice
./manage_users.py logout alice         # end all sessions
./manage_users.py promote alice | demote alice   # a second admin: register --admin, or promote
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

## Clients (desktop and mobile)

| Platform | App | Notes |
| :--- | :--- | :--- |
| Browser | Element Web at `https://chat.example.com` | hosted on this server |
| Windows / macOS / Linux | Element Desktop | same features as Element Web |
| Android / iOS | **Element X** | the current mobile app (fast sync, calls, QR sign-in); classic Element Android/iOS still work but are being retired |

Everything the apps need is in place: server discovery (`.well-known`, CORS), sign-in through
MAS (apps register themselves automatically), simplified sliding sync for Element X, MatrixRTC
calls, push via Element's gateway, authenticated media (50 MB uploads).

**Signing in.** Enter `chat.example.com` as the server; the app opens MAS
(`auth.chat.example.com`) to sign in. There is no *Create account* in the apps: new accounts
come from the invite page `https://chat.example.com/register` (see *Users*).

**Sign in with QR code** (new device starts out verified, no recovery key needed):
1. On a device that is already signed in — Element Web/Desktop: *Settings → Sessions →
   Link new device* — a QR code appears.
2. On the new phone, Element X: *Sign in with QR code*, scan it, confirm the code shown on
   both screens.

Both rendezvous versions are enabled (`msc4108_enabled`, `msc4388_mode` — see *Configuration
reference*). If the option is missing, update the app.

**Check that a client works** (from outside the LAN, e.g. a phone on mobile data): sign in,
send a message, receive a push notification while the app is closed, and place a call.

## Bots (Maubot)

One bot account, `@maubot_client:<domain>`, runs every plugin. Invite it to a room and it
joins (`autojoin`); it supports encrypted rooms. Admin UI: `https://chat.example.com/_matrix/maubot`
(LAN only), user `admin`. The password is set in `admins:` of `/opt/maubot/config.yaml`
(Maubot replaces it with a bcrypt hash on start); on the reference host it is kept in
`/root/maubot_admin_password.txt` (600).

Installed plugins (instance → commands):

| Instance | Plugin | Commands |
| :--- | :--- | :--- |
| `help` | [mauhelp](https://github.com/vonDassendorf/maubot_mauhelp) | `!help` — lists every bot command |
| `reminder` | [maubot/reminder](https://github.com/maubot/reminder) | `!remind <when> <text>`, `!remind list`, `!remind tz <zone>`; 👍 a reminder to be pinged too |
| `dice` | [maubot/dice](https://github.com/maubot/dice) | `!roll 2d6+3` (also arithmetic) |
| `choose` | [coffee-maubot/choose](https://github.com/coffeebank/coffee-maubot) | `!choose a \| b \| c` |
| `timein` | [coffee-maubot/timein](https://github.com/coffeebank/coffee-maubot) | `!timein Europe/Berlin`, `!timein new york` |
| `weather` | [maubot-weather](https://github.com/kellya/maubot-weather) | `!weather <place>` (wttr.in, no key; provider must be `wttr.in` — the default `test` returns fake data) |
| `urlpreview` | [coffee-maubot/urlpreview](https://github.com/coffeebank/coffee-maubot) | automatic link previews (Element does not preview links in encrypted rooms) |
| `giphy` | [GiphyMaubot](https://github.com/TomCasavant/GiphyMaubot) | `!giphy <words>` (Giphy/Tenor keys in the instance config) |
| `xkcd` | [maubot/xkcd](https://github.com/maubot/xkcd) | `!xkcd [number]` |

Uploaded but without an instance (create one in the UI when wanted): `rss` (feeds into a
room) and `webhook` (post to a room from an HTTP call).

**Adding a plugin.** Many plugins publish no current `.mbp` release, so build from source
with Maubot's own tool (it only packages files), add any Python dependencies from the
plugin's `maubot.yaml` to `maubot_requirements.txt`, then upload:

```bash
git clone --depth 1 https://github.com/<owner>/<plugin> /tmp/p && cd /tmp/p
/opt/maubot/venv/bin/mbc build -o /tmp        # -> /tmp/<id>-v<version>.mbp
# repo dir: add dependencies, then install them into the venv
install -m 644 maubot_requirements.txt /opt/maubot/requirements.txt
sudo -H -u maubot /opt/maubot/venv/bin/pip install -r /opt/maubot/requirements.txt
```

Upload the `.mbp` in the UI (*Plugins → +*), then create an instance with the bot as its
user. Never install `exec`, `manhole` or `maush` — they run code on the server.

**Reconnecting the bot** (new device, e.g. after rotating the pickle key):

```bash
cd /opt/mas
sudo -u mas MAS_CONFIG=/opt/mas/config.yaml ./mas manage kill-sessions maubot_client
sudo -u mas MAS_CONFIG=/opt/mas/config.yaml ./mas manage issue-compatibility-token maubot_client
```

Paste the printed `mct_…` token and its device ID into the client in the Maubot UI (enable it,
keep *sync* and *autojoin* on), then `systemctl restart maubot`: Maubot only starts clients at
startup.

## Upgrades

```bash
./upgrade_services.sh              # back up, upgrade everything, restart, health-check
./upgrade_services.sh --check      # health check only; changes nothing
./upgrade_services.sh --no-backup  # skip the pre-upgrade backup
```

What a run does, in order:

1. **Preflight**: `nginx -t` and that `nginx.conf` still includes `sites-enabled/*`.
2. **Looks up every new release first** (MAS, Element Web, Synapse-Admin, LiveKit,
   lk-jwt-service, coturn) and prints current → latest. If GitHub is unreachable or
   rate-limited nothing has changed yet (set `GITHUB_TOKEN` to raise the limit).
3. **Backup** with `backup_matrix.sh`; a failed backup aborts before any change.
4. APT upgrade (Synapse, PostgreSQL minor, nginx, Debian; existing configs kept), then
   re-checks nginx and starts it if a package left it stopped.
5. Each component whose version differs: MAS (validates the existing config with the new
   binary before swapping, then `database migrate`), Element Web and Synapse-Admin (configs
   carried over, swapped by rename), LiveKit, lk-jwt-service, coturn (rebuilt from source),
   Maubot venv. Assets without a published SHA-256 digest are refused unless
   `ALLOW_UNVERIFIED=1`.
6. Restarts `mas` → `matrix-synapse` → the rest, waits for them to listen, runs the health
   check (services, timers, PostgreSQL cluster + `pg_isready`, failed units, nginx config,
   local endpoints, both vhosts through nginx).

The 5-minute monitor is paused for the run. If a step fails **after** something changed,
the script restarts services on whatever is installed and runs the health check before
exiting, so nothing is left half-restarted.

### Rollback

The previous version of each component is kept next to it:

| Component | Restore the previous version |
| :--- | :--- |
| MAS | `mv /opt/mas/mas.prev /opt/mas/mas && rm -rf /opt/mas/share && mv /opt/mas/share.prev /opt/mas/share && systemctl restart mas mas-invite`. The upgrade always runs `database migrate`, so if the new version changed the schema also restore `mas_db` from the pre-upgrade backup (`systemctl stop mas mas-invite` first; commands under *Rebuild / restore*) |
| LiveKit / lk-jwt-service / coturn | `mv /usr/local/bin/<binary>.prev /usr/local/bin/<binary>` (`livekit-server`, `lk-jwt-service`, `turnserver`), restart the service. For lk-jwt-service also write the old tag to `/usr/local/lib/lk-jwt-service.version` |
| Maubot venv | `sudo -H -u maubot /opt/maubot/venv/bin/pip install -r /opt/maubot/requirements.prev.txt && systemctl restart maubot` (snapshot taken before each upgrade) |
| Element Web / Synapse-Admin | `rm -rf /var/www/<site> && mv /var/www/<site>.prev /var/www/<site>` |
| Synapse (APT) | `apt-get install matrix-synapse-py3=<version>` then `apt-mark hold matrix-synapse-py3` (`apt-cache policy matrix-synapse-py3` lists versions). Database migrations are not reversible, so a downgrade across a schema change needs the backup |
| Anything with data | restore from the pre-upgrade backup (see *Rebuild / restore* below) |

After a rollback, run `./upgrade_services.sh --check`. Only one previous version is kept:
the next upgrade of a component replaces its `.prev`.

* A package held with `apt-mark hold` stays put on later runs (`apt-get upgrade` skips it);
  release it with `apt-mark unhold matrix-synapse-py3` once the fix is out.
* A rolled-back **binary or site is upgraded again by the next run** (the script always
  installs the latest release). Until the upstream fix is out, don't run
  `upgrade_services.sh`, or re-apply the rollback afterwards.

Read release notes when jumping versions — this is where breakage comes from:
* **Synapse** refuses to start with removed options
  ([upgrade notes](https://element-hq.github.io/synapse/latest/upgrade.html)).
* **coturn** stops on removed options (e.g. `no-cli` removed in 4.18; DTLS opt-in since 4.17).
* **MAS / LiveKit / lk-jwt-service**: GitHub release notes.

### PostgreSQL major upgrade (manual)

```bash
systemctl start matrix-backup.service     # fresh backup first; this is not reversible without it
apt-get install postgresql-<new>          # from PGDG; it creates an empty "main" cluster on 5433
pg_dropcluster --stop <new> main          # remove that empty cluster (pg_upgradecluster needs the name free)
systemctl stop matrix-monitor.timer matrix-backup.timer
systemctl stop matrix-synapse mas mas-invite maubot lk-jwt-service
pg_upgradecluster -v <new> <old> main     # new cluster takes port 5432, old one moves to 5433
systemctl start mas matrix-synapse mas-invite maubot lk-jwt-service
systemctl start matrix-monitor.timer matrix-backup.timer
./upgrade_services.sh --check
# when everything works:
pg_dropcluster <old> main && apt-get purge postgresql-<old> postgresql-client-<old>
```

`synapse_db` must keep `C` collation (`pg_upgradecluster` preserves it). To stop new PGDG
majors creating a cluster at all, set `create_main_cluster = false` in
`/etc/postgresql-common/createcluster.conf`.

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
* A lock prevents a manual run and the timer run overlapping; a timer run is killed after
  4 h. Old backups are pruned before and after each run, so a disk filled by old backups
  clears itself.
* Once `/mnt/backup` is real separate storage, set `BACKUP_REQUIRE_MOUNT=1` in `setup.config`:
  the backup then refuses to run (and the unit fails) if the mount is missing, instead of
  filling the root disk.
* Once the timer is enabled, `monitor_services.sh` alerts if it stops or no completed backup
  is newer than 36 h.

`files.tgz` holds plaintext secrets — keep the backup folder (mode 700) and any copy restricted.

`/mnt/backup` is a plain directory on the container's own disk until you give it separate
storage — e.g. a Proxmox mount point (`pct set <vmid> -mp0 <storage>:<size>,mp=/mnt/backup`)
— and copy backups off-host too (Proxmox Backup Server, rsync, restic).

To restore, follow *Rebuild / restore* below (on the same host, skip its first two steps).
The backup files are readable by root only, so they are fed to the `postgres` tools on
stdin.

## Rebuild / restore on a new host

The backup is enough to rebuild the server with the same identity. The Synapse signing key
(`/etc/matrix-synapse/*.signing.key`, in `files.tgz`) and `server_name` define the server
to the federation — never lose the key or change the name.

Work as root inside the backup you are restoring: `cd /mnt/backup/matrix/<timestamp>`
(copy that folder to the new host first). The repo lives in `/root` on this deployment;
`files.tgz` stores `setup.config` and `refresh_certs.conf` under the repo path.

1. Fresh Debian 12 with the same LAN IP (or edit `LAN_IP` after this step). Clone the repo to
   the same path (`/root`), then put back its site files:
   `tar xzf files.tgz -C / root/setup.config root/refresh_certs.conf`.
2. `/root/install.sh` — builds the stack with new secrets and empty databases.
3. Stop everything:
   `systemctl stop matrix-monitor.timer matrix-backup.timer matrix-synapse mas mas-invite maubot lk-jwt-service livekit coturn`.
4. `tar xzf files.tgz -C /` — puts back every config, secret, signing key and unit (this
   overwrites the new secrets, so everything matches the restored databases).
5. Roles and databases, replacing the empty ones:
   ```bash
   (cd /tmp && sudo -u postgres psql -f -) < globals.sql    # "already exists" errors are fine
   for db in synapse_db mas_db maubot_db; do
       (cd /tmp && sudo -u postgres pg_restore --clean --if-exists -d "$db") < "$db.dump"
   done
   ```
6. `tar xzf media.tgz -C /` and `chown -R matrix-synapse:matrix-synapse /var/lib/matrix-synapse/media`.
7. `systemctl daemon-reload`, start `mas`, then `matrix-synapse`, then the rest, and
   `systemctl enable --now matrix-backup.timer` if backups were enabled (the backup holds the
   unit files but not their enabled state). coturn's copy of the certificate
   (`/etc/turn_server_*.pem`) is not in the backup; `systemctl start matrix-refresh-certs.service`
   recreates it.
8. `/root/upgrade_services.sh --check` and `/root/manage_users.py list`.

To restore on the *same* host, skip steps 1–2.

## Rotating secrets

Generate a value with `openssl rand -hex 32`, change every file listed, restart in the order
given. See [ARCHITECTURE → Secrets map](ARCHITECTURE.md#secrets-map).

| Secret | Change in | Then restart |
| :--- | :--- | :--- |
| TURN shared secret | `turn_shared_secret` in `homeserver.yaml` **and** `static-auth-secret` in `/etc/turnserver.conf` | `coturn`, `matrix-synapse` |
| LiveKit API key/secret | `keys:` and `webhook.api_key` in `/etc/livekit/livekit.yaml` **and** `/etc/lk-jwt-service/livekit_keys` (`<key>: <secret>`) | `livekit`, `lk-jwt-service` |
| MAS ↔ Synapse secret | `matrix_authentication_service.secret` in `homeserver.yaml` **and** `matrix.secret` in `/opt/mas/config.yaml` | `mas`, `matrix-synapse` |
| Appservice tokens | `as_token`/`hs_token` in `/etc/matrix-synapse/appservices/lk-jwt-service.yaml` | `matrix-synapse`, `lk-jwt-service` |
| Database password | `ALTER ROLE <role> PASSWORD '<new>'` (as postgres), then `homeserver.yaml` (synapse_user), MAS `database.uri` (mas) or Maubot `database` (maubot) | that service |
| Registration secret | `conf.d/registration.yaml` | `matrix-synapse` |
| SMTP password | at the mail provider, then `conf.d/email.yaml` and MAS `email.password` | `mas`, `matrix-synapse` |
| Maubot admin password | `admins.admin` in `/opt/maubot/config.yaml` | `maubot` |
| Maubot `unshared_secret` | `server.unshared_secret` in `/opt/maubot/config.yaml` | `maubot` |
| Maubot pickle key | not routinely: `crypto_db_pickle_key` protects stored bot encryption keys; changing it loses the bots' E2EE sessions | — |
| MAS encryption/signing keys | not routinely: rotating the encryption key makes stored upstream-OAuth tokens unreadable | — |

Restarting LiveKit or coturn drops calls in progress; do it when nobody is in a call.

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

The monitor timer is paused while `upgrade_services.sh` runs. Job logs in `/var/log/` are
rotated weekly (8 kept, compressed) by `/etc/logrotate.d/matrix-jobs`.

## Host hardening

Recommended for every deployment. Items marked *installer* are set up by `install.sh`.

* **Restart on failure** (*installer*) — nginx and the PostgreSQL clusters ship with
  `Restart=no`; drop-ins (`/etc/systemd/system/nginx.service.d/restart.conf`,
  `postgresql@.service.d/restart.conf`) restart them 5 s after a crash. All other services
  already restart (`always` or `on-failure`). Synapse is ordered after PostgreSQL
  (`matrix-synapse.service.d/matrix.conf`) instead of crash-looping at boot.
* **Logs not world-readable** (*installer*) — Synapse runs with `UMask=0027`, so
  `homeserver.log` (client IPs, user IDs) is `640`; the job logs are `640 root:adm`
  (`/etc/logrotate.d/matrix-jobs` keeps that on rotation); nginx logs are `640` already.
* **Journal size cap** (*installer*) — `/etc/systemd/journald.conf.d/matrix.conf` sets
  `SystemMaxUse=500M` (the default is 10 % of the filesystem).
* **SSH keys only** (manual, done on the reference host) — once your key works:
  ```bash
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/50-matrix-hardening.conf
  sshd -t && systemctl reload ssh
  ```
  Not done by the installer, so it cannot lock you out of a fresh host.
* **Host firewall** (optional, not applied) — the edge firewall is the primary filter. For
  defence in depth, [examples/nftables.conf](../examples/nftables.conf) (native on Debian 12)
  and [examples/ufw.sh](../examples/ufw.sh) allow only SSH and HTTPS from the LAN/edge plus the
  TURN and LiveKit media ports, and keep LiveKit's 7880 closed. Syntax-check with
  `nft -c -f examples/nftables.conf`; apply with a console open.

Monitoring deliberately alerts on the **first** failed check (no "two strikes" delay): a
short blip produces an alert and then a RESOLVED message.

## Configuration reference

### Client assumptions (latest apps only)
* Element Web sends **all** calls through Element Call (`element_call.use_exclusively`);
  embedded Element Call is pinned to `matrix_rtc_mode: matrix_2_0` (sticky events).
* Synapse advertises only the stable `m.livekit` MatrixRTC transport.
* `.well-known/matrix/client` carries only `m.homeserver`; clients find MAS via
  `/_matrix/client/v1/auth_metadata`.
* QR-code sign-in: both rendezvous versions are on — `msc4108_enabled` (2024 version, used by
  current Element X / Element Web) and `msc4388_mode: open` (2025 version, accepted into the spec
  2026-11). Drop MSC4108 once the apps have moved to MSC4388. To sign in a phone: Element Web/Desktop →
  *Settings → Sessions → Link new device*, or on Element X choose *Sign in with QR code* and scan
  the code shown by a device that is already signed in.
* No identity server is configured (no `vector.im`); invites by email address are not available.

### Synapse experimental features
Enabled (all commented inline in `homeserver.yaml`): MatrixRTC (`msc4143`, `msc4502`,
`msc4512`, `msc4354`, `msc4075`), QR login (`msc4108`, `msc4388`), profile fields (`msc4133`),
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
| Debian 12 base (LTS since 2026-07) | Deferred: key services come from upstream repos; plan a Debian 13 upgrade before 2028-06. `install.sh` refuses non-bookworm and the APT sources (`/etc/apt/sources.list.d/{matrix-org,pgdg,nginx}.list`) say `bookworm`: switch them to `trixie` as part of the dist-upgrade, then run `./upgrade_services.sh` (coturn rebuilds against the new libraries) and `--check`. |
| `/register` restricted at the edge only | Caddy's auth protects it from the internet; nginx does not restrict it, so LAN clients reaching nginx directly can mint invites. Add `allow <EDGE_PROXY_IP>; deny all;` to that location if needed. |
| coturn source tarball has no published checksum | Downloaded over HTTPS from GitHub; its SHA-256 is printed in the upgrade output. |
| lk-jwt-service without Redis | In-memory state; a restart mid-call loses delayed-leave bookkeeping only. |
| LiveKit TURN/TLS on 443 disabled | Clients on UDP-hostile networks fall back to 7881/tcp but not to TLS/443. |
| Single TLS cert (`chat.` only) also served for `auth.` | Fine behind Caddy (`tls_insecure_skip_verify`); direct LAN access to `auth.` shows a name mismatch. |
| postfix listening on localhost:25 | Debian default, unused by the stack. |
