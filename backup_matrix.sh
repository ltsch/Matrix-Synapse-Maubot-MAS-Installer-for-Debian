#!/bin/bash
# backup_matrix.sh
# Nightly backup of the Matrix stack: database roles, PostgreSQL databases
# (custom-format dumps), configs/secrets/signing keys, and the media store.
#
# Run nightly by matrix-backup.timer. Destination: BACKUP_DIR in setup.config
# (default /mnt/backup/matrix). Make /mnt/backup a mount point on separate storage
# (e.g. a Proxmox mp0) - until then backups share the disk with the data.
#
# Each run writes to $DEST/.partial-<stamp>, verifies every archive, then renames it
# to $DEST/<stamp> and writes a COMPLETE marker. Only completed backups count for the
# monitor and for retention: completed backups older than BACKUP_KEEP_DAYS (14) are
# deleted, but the newest BACKUP_KEEP_MIN (3) are always kept.
#
# files.tgz contains plaintext secrets - keep copies of $DEST restricted.
#
# Restore roles:       sudo -u postgres psql -f globals.sql
# Restore a database:  sudo -u postgres pg_restore --clean --if-exists -d <db> <db>.dump
# Restore files:       tar xzf files.tgz -C /

set -euo pipefail

CONFIG_FILE="$(dirname "$(readlink -f "$0")")/setup.config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
DEST="${BACKUP_DIR:-/mnt/backup/matrix}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
STAMP=$(date +%Y-%m-%d_%H%M%S)
WORK="$DEST/.partial-$STAMP"
FINAL="$DEST/$STAMP"
DATABASES=(synapse_db mas_db maubot_db)

umask 077
mkdir -p "$DEST"

# One backup at a time (timer run vs. a manual run).
exec 9>"$DEST/.lock"
flock -n 9 || { echo "$(date -Is) another backup is running; exiting"; exit 1; }

# A failed or killed run never leaves something that looks like a backup.
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK"

# Roles and their passwords (pg_dump does not include them), then each database.
(cd /tmp && sudo -u postgres pg_dumpall --globals-only) > "$WORK/globals.sql"
for db in "${DATABASES[@]}"; do
    (cd /tmp && sudo -u postgres pg_dump -Fc "$db") > "$WORK/$db.dump"
done

# Configs, secrets and signing keys (anything needed to rebuild the server).
# Paths that do not exist on this host (e.g. matrix_credentials.txt, only written by a
# fresh install) are skipped explicitly, so any real read error still fails the backup.
cd /   # paths and globs below are relative to /
CANDIDATES=(
    etc/matrix-synapse
    opt/mas/config.yaml opt/mas/invite_gen.py
    etc/turnserver.conf etc/systemd/system/coturn.service.d
    etc/livekit etc/lk-jwt-service
    etc/nginx
    opt/maubot/config.yaml opt/maubot/plugins
    var/www/element-web/config.json var/www/element-web/widgets/element-call/config.json
    var/www/synapse-admin/config.json
    etc/systemd/system/mas.service etc/systemd/system/mas-invite.service
    etc/systemd/system/maubot.service etc/systemd/system/livekit.service
    etc/systemd/system/lk-jwt-service.service
    etc/systemd/system/matrix-*.service etc/systemd/system/matrix-*.timer
    etc/logrotate.d/matrix-jobs
    root/setup.config root/refresh_certs.conf root/matrix_credentials.txt
)
PATHS=()
for p in "${CANDIDATES[@]}"; do [ -e "$p" ] && PATHS+=("$p"); done
tar czf "$WORK/files.tgz" "${PATHS[@]}"

# Uploaded media (small today; consider excluding remote_content if it grows).
tar czf "$WORK/media.tgz" var/lib/matrix-synapse/media

# --- Verify before calling it a backup ---------------------------------------
grep -q 'CREATE ROLE' "$WORK/globals.sql"
for db in "${DATABASES[@]}"; do
    pg_restore --list "$WORK/$db.dump" >/dev/null
done
tar tzf "$WORK/files.tgz" > "$WORK/files.list"
for required in etc/matrix-synapse/homeserver.yaml opt/mas/config.yaml; do
    grep -qx "$required" "$WORK/files.list" || { echo "$(date -Is) ERROR: $required missing from files.tgz"; exit 1; }
done
grep -q '^etc/matrix-synapse/.*signing\.key$' "$WORK/files.list" \
    || { echo "$(date -Is) ERROR: Synapse signing key missing from files.tgz"; exit 1; }
tar tzf "$WORK/media.tgz" >/dev/null

date -Is > "$WORK/COMPLETE"
mv "$WORK" "$FINAL"

# --- Retention: only completed backups; always keep the newest $KEEP_MIN ------
mapfile -t COMPLETED < <(find "$DEST" -mindepth 2 -maxdepth 2 -name COMPLETE -printf '%h\n' | sort -r)
for old in "${COMPLETED[@]:$KEEP_MIN}"; do
    [ -n "$(find "$old" -maxdepth 0 -mtime +"$KEEP_DAYS")" ] && rm -rf "$old"
done
# Leftovers from runs that were killed before their trap ran.
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '.partial-*' -mmin +1440 -exec rm -rf {} +

kept=$(find "$DEST" -mindepth 2 -maxdepth 2 -name COMPLETE | wc -l)
echo "$(date -Is) backup OK: $FINAL ($(du -sh --apparent-size "$FINAL" | cut -f1)), $kept completed backups kept"
