#!/bin/bash
# backup_matrix.sh
# Nightly backup of the Matrix stack: PostgreSQL databases (custom-format dumps),
# configs/secrets/signing keys, and the media store. Keeps $KEEP_DAYS days.
#
# Run nightly by matrix-backup.timer. Destination: BACKUP_DIR in setup.config
# (default /mnt/backup/matrix). Make /mnt/backup a mount point on separate storage
# (e.g. a Proxmox mp0) - until then backups share the disk with the data.
#
# Restore roles:       sudo -u postgres psql -f globals.sql
# Restore a database:  sudo -u postgres pg_restore --clean --if-exists -d <db> <db>.dump
# Restore files:       tar xzf files.tgz -C /

set -euo pipefail

CONFIG_FILE="$(dirname "$(readlink -f "$0")")/setup.config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
DEST="${BACKUP_DIR:-/mnt/backup/matrix}"
KEEP_DAYS=14
STAMP=$(date +%Y-%m-%d_%H%M)
OUT="$DEST/$STAMP"

umask 077
mkdir -p "$OUT"

# Roles and their passwords (pg_dump does not include them).
(cd /tmp && sudo -u postgres pg_dumpall --globals-only) > "$OUT/globals.sql"
for db in synapse_db mas_db maubot_db; do
    (cd /tmp && sudo -u postgres pg_dump -Fc "$db") > "$OUT/$db.dump"
done

# Configs, secrets and signing keys (anything needed to rebuild the server).
cd /   # globs below are relative to /
tar czf "$OUT/files.tgz" --ignore-failed-read -C / \
    etc/matrix-synapse \
    opt/mas/config.yaml opt/mas/policies opt/mas/invite_gen.py \
    etc/turnserver.conf etc/systemd/system/coturn.service.d \
    etc/livekit etc/lk-jwt-service \
    etc/nginx \
    opt/maubot/config.yaml opt/maubot/plugins \
    var/www/element-web/config.json var/www/element-web/widgets/element-call/config.json \
    var/www/synapse-admin/config.json \
    etc/systemd/system/mas.service etc/systemd/system/mas-invite.service \
    etc/systemd/system/maubot.service etc/systemd/system/livekit.service \
    etc/systemd/system/lk-jwt-service.service etc/systemd/system/matrix-*.service \
    etc/systemd/system/matrix-*.timer \
    root/setup.config root/refresh_certs.conf root/matrix_credentials.txt \
    2>/dev/null

# Uploaded media (small today; consider excluding remote_content if it grows).
tar czf "$OUT/media.tgz" -C / var/lib/matrix-synapse/media

find "$DEST" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf {} +

echo "$(date -Is) backup OK: $OUT ($(du -sh --apparent-size "$OUT" | cut -f1))"
