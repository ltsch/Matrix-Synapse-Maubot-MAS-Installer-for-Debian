#!/bin/bash
# monitor_services.sh - health check for the Matrix stack.
#
# Run every 5 minutes by matrix-monitor.timer. Posts to MONITOR_WEBHOOK_URL
# (Discord-compatible) only when something changes:
#   * when a failure appears or the set of failures changes,
#   * again every MONITOR_REALERT_HOURS (default 6) while the same failures persist,
#   * once with RESOLVED when everything is healthy again.
# Every run that finds failures logs them (timestamped). Exit status: 0 healthy, 1 failures.
#
#   ./monitor_services.sh          run the checks
#   ./monitor_services.sh --test   send a (multi-line) test message to the webhook

set -uo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$HERE/setup.config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

: "${MATRIX_FQDN:=}"
: "${AUTH_FQDN:=auth.$MATRIX_FQDN}"
: "${MONITOR_WEBHOOK_URL:=}"
: "${BACKUP_DIR:=/mnt/backup/matrix}"
REALERT_HOURS="${MONITOR_REALERT_HOURS:-6}"
CERT_WARN_DAYS="${MONITOR_CERT_WARN_DAYS:-14}"
DISK_WARN_PCT="${MONITOR_DISK_WARN_PCT:-90}"
CERT_FILE=/etc/nginx/ssl/matrix.crt
STATE_DIR=/var/lib/matrix-monitor
STATE="$STATE_DIR/failures"
HOST=$(hostname)

# Long-running services and the job timers (a stopped timer = a job that silently stopped).
SERVICES=(matrix-synapse mas mas-invite coturn livekit lk-jwt-service maubot nginx
          matrix-turn-ip.timer matrix-refresh-certs.timer)

# Endpoints through the public names (edge proxy -> nginx -> backend).
URLS=("https://$MATRIX_FQDN/_matrix/client/versions"
      "https://$MATRIX_FQDN/_matrix/federation/v1/version"
      "https://$AUTH_FQDN/.well-known/openid-configuration"
      "https://$MATRIX_FQDN/livekit/jwt/healthz"
      "https://$MATRIX_FQDN/_matrix/maubot")

log() { echo "$(date -Is) $*"; }

mkdir -p "$STATE_DIR"

# send_webhook MESSAGE - JSON-encodes properly (newlines, quotes), trims to Discord's limit.
send_webhook() {
    if [ -z "$MONITOR_WEBHOOK_URL" ]; then
        log "No MONITOR_WEBHOOK_URL configured; alert only logged."
        return 0
    fi
    local payload
    payload=$(python3 -c '
import json, sys
m = sys.argv[1]
if len(m) > 1900:
    m = m[:1900] + "\n... (truncated)"
print(json.dumps({"content": m}))' "$1") || return 1
    if ! curl -fsS --max-time 10 --retry 2 -o /dev/null -H "Content-Type: application/json" \
            -d "$payload" "$MONITOR_WEBHOOK_URL" 2>"$STATE_DIR/webhook.err"; then
        log "WARNING: webhook delivery failed: $(head -c 300 "$STATE_DIR/webhook.err")"
        return 1
    fi
}

if [ "${1:-}" = "--test" ] || [ "${1:-}" = "test" ]; then
    send_webhook "🧪 **Test notification - $HOST**
Matrix monitor can reach this channel.
(This message has several lines to test formatting.)" && echo "Test notification sent."
    exit $?
fi

failures=()

# 1. systemd services and timers
for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$svc" || failures+=("Service **$svc** is not active")
done

# 2. PostgreSQL: postgresql.service is only a wrapper that stays "active" even when the
#    cluster is down, so check the real cluster units and that it accepts connections.
mapfile -t PG_UNITS < <(systemctl list-units --all --plain --no-legend 'postgresql@*.service' | awk '{print $1}')
[ ${#PG_UNITS[@]} -gt 0 ] || failures+=("No PostgreSQL cluster unit (postgresql@*) found")
for u in "${PG_UNITS[@]}"; do
    systemctl is-active --quiet "$u" || failures+=("Service **$u** is not active")
done
# -U/-d postgres: otherwise the probe connects as "root" and PostgreSQL logs a FATAL each run
pg_isready -q -t 5 -U postgres -d postgres || failures+=("PostgreSQL is not accepting connections")

# 3. Any failed unit (e.g. a scheduled job whose last run failed). A previous monitor run
#    that crashed shows up here too (finding problems exits 1, which the unit treats as success).
while read -r u; do
    [ -n "$u" ] && failures+=("Unit **$u** failed (systemctl status $u)")
done < <(systemctl list-units --state=failed --plain --no-legend | awk '{print $1}')

# 4. Backups - only once matrix-backup.timer is enabled. A backup counts only if it completed.
if systemctl is-enabled --quiet matrix-backup.timer 2>/dev/null; then
    systemctl is-active --quiet matrix-backup.timer || failures+=("Timer **matrix-backup.timer** is not active")
    if [ -z "$(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -name COMPLETE -mmin -2160 2>/dev/null | head -n 1)" ]; then
        failures+=("No completed backup newer than 36 h in **$BACKUP_DIR**")
    fi
fi

# 5. TLS certificate expiry
if [ -f "$CERT_FILE" ]; then
    if ! openssl x509 -noout -checkend $((CERT_WARN_DAYS * 86400)) -in "$CERT_FILE" >/dev/null 2>&1; then
        failures+=("TLS certificate expires within $CERT_WARN_DAYS days ($(openssl x509 -noout -enddate -in "$CERT_FILE" | cut -d= -f2))")
    fi
else
    failures+=("TLS certificate $CERT_FILE is missing")
fi

# 6. Disk space (root filesystem and the backup location)
for path in / "$BACKUP_DIR"; do
    [ -e "$path" ] || continue
    pct=$(df -P "$path" | awk 'NR==2 {sub("%","",$5); print $5}')
    [ -n "$pct" ] && [ "$pct" -ge "$DISK_WARN_PCT" ] && failures+=("Disk for **$path** is ${pct}% full")
done

# 7. Endpoints (only meaningful while nginx is up; a 5xx or no response is a failure)
if [ -n "$MATRIX_FQDN" ] && systemctl is-active --quiet nginx; then
    for url in "${URLS[@]}"; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url")
        if [ "$code" = "000" ]; then
            failures+=("Endpoint **$url** did not respond")
        elif [ "$code" -ge 500 ]; then
            failures+=("Endpoint **$url** returned HTTP $code")
        fi
    done
fi

# --- Report (deduplicated) ---------------------------------------------------
if [ ${#failures[@]} -gt 0 ]; then
    current=$(printf -- '- %s\n' "${failures[@]}" | sort)
    previous=$(cat "$STATE" 2>/dev/null || true)
    log "Failures detected:"
    echo "$current"
    if [ "$current" != "$previous" ] || [ -n "$(find "$STATE" -mmin +$((REALERT_HOURS * 60)) 2>/dev/null)" ]; then
        label="🚨 **Matrix alert - $HOST**"
        [ "$current" = "$previous" ] && label="🚨 **Matrix alert (still failing) - $HOST**"
        # Only record the state once the alert went out, so a failed delivery is retried.
        send_webhook "$label
$current" && printf '%s\n' "$current" > "$STATE"
    fi
    exit 1
fi

if [ -s "$STATE" ]; then
    log "All checks passing again; sending RESOLVED."
    send_webhook "✅ **Matrix RESOLVED - $HOST**
All checks are passing again. Previously:
$(cat "$STATE")" && rm -f "$STATE"
fi
exit 0
