#!/bin/bash
# upgrade_services.sh - upgrade every component of the Matrix stack, then health-check it.
#
#   ./upgrade_services.sh              back up, upgrade everything, restart, health-check
#   ./upgrade_services.sh --check      only run the health check (changes nothing)
#   ./upgrade_services.sh --no-backup  skip the pre-upgrade backup
#
#   APT:     Synapse (packages.matrix.org), PostgreSQL minor (PGDG), nginx (nginx.org), Debian
#   GitHub:  MAS, Element Web, Synapse-Admin, LiveKit, lk-jwt-service (SHA-256 verified)
#   Source:  coturn (latest release, built into /usr/local)
#   pip:     Maubot venv
#
# Order: preflight (nginx config sane) -> look up every new release (nothing changes if
# GitHub is unreachable) -> backup_matrix.sh -> APT -> each component -> restart -> health.
# If anything fails after a change was made, services are restarted on whatever is
# installed and the health check runs, so nothing is left half-restarted. Previous
# binaries/sites are kept as *.prev for rollback (docs/ADMIN_GUIDE.md -> Upgrades).
#
# Configs are preserved. Before crossing many versions, read the upgrade notes:
#   Synapse  https://element-hq.github.io/synapse/latest/upgrade.html
#            (Synapse refuses to start if a removed option is still set)
#   MAS      https://github.com/element-hq/matrix-authentication-service/releases
#   coturn   https://github.com/coturn/coturn/releases (removed options stop turnserver)
#   LiveKit / lk-jwt-service release notes for config or env-var changes
# PostgreSQL MAJOR upgrades are manual (pg_upgradecluster) - see docs/ADMIN_GUIDE.md.

set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=/dev/null
[ -f "$HERE/setup.config" ] && source "$HERE/setup.config"
: "${MATRIX_FQDN:=}"
: "${AUTH_FQDN:=${MATRIX_FQDN:+auth.$MATRIX_FQDN}}"

CHECK_ONLY=false
BACKUP=true
for arg in "$@"; do
    case "$arg" in
        --check)     CHECK_ONLY=true ;;
        --no-backup) BACKUP=false ;;
        -h|--help)   sed -n '2,7p' "$0"; exit 0 ;;
        *)           die "unknown argument: $arg" ;;
    esac
done
[ "$EUID" -eq 0 ] || die "run as root"

SERVICES=(mas matrix-synapse coturn livekit lk-jwt-service maubot mas-invite nginx)
TIMERS=(matrix-turn-ip.timer matrix-monitor.timer matrix-refresh-certs.timer)

nginx_sane() { # the nginx.org package once replaced nginx.conf and dropped our sites
    grep -q '^\s*include /etc/nginx/sites-enabled/\*;' /etc/nginx/nginx.conf \
        || { warn "/etc/nginx/nginx.conf no longer includes sites-enabled/* (package replaced it?)"; return 1; }
    nginx -t -q 2>/dev/null || { nginx -t; return 1; }
}

health_check() {
    local failed=0 s u code
    ok()  { echo "  OK    $*"; }
    bad() { echo "  FAIL  $*"; failed=1; }
    log "Health check"
    for s in "${SERVICES[@]}" "${TIMERS[@]}"; do
        if systemctl is-active --quiet "$s"; then ok "$s"; else bad "$s"; fi
    done
    if systemctl is-enabled --quiet matrix-backup.timer 2>/dev/null; then
        if systemctl is-active --quiet matrix-backup.timer; then ok matrix-backup.timer; else bad matrix-backup.timer; fi
    fi
    # postgresql.service is only a wrapper; check the real clusters and connectivity
    while read -r u; do
        if systemctl is-active --quiet "$u"; then ok "$u"; else bad "$u"; fi
    done < <(systemctl list-units --all --plain --no-legend 'postgresql@*.service' | awk '{print $1}')
    if pg_isready -q -t 5; then ok "PostgreSQL accepting connections"; else bad "PostgreSQL accepting connections"; fi
    while read -r u; do
        if [ -n "$u" ]; then bad "unit $u is in failed state"; fi
    done < <(systemctl list-units --state=failed --plain --no-legend | awk '{print $1}')
    if nginx_sane; then ok "nginx config (nginx -t, sites-enabled included)"; else bad "nginx config"; fi
    for u in http://localhost:8008/health http://localhost:8082/health http://127.0.0.1:8083/healthz \
             http://127.0.0.1:7880/ http://127.0.0.1:8081/ http://127.0.0.1:29316/_matrix/maubot/; do
        if curl -sf -m 10 -o /dev/null "$u"; then ok "$u"; else bad "$u"; fi
    done
    # Through nginx with the real Host names (what the edge proxy sends)
    if [ -n "$MATRIX_FQDN" ]; then
        for u in "$MATRIX_FQDN/_matrix/client/versions" "$MATRIX_FQDN/.well-known/matrix/server" \
                 "$AUTH_FQDN/.well-known/openid-configuration"; do
            code=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve "${u%%/*}:443:127.0.0.1" "https://$u")
            if [ "$code" = 200 ]; then ok "nginx vhost https://$u"; else bad "nginx vhost https://$u (HTTP $code)"; fi
        done
    fi
    return $failed
}

restart_all() {
    log "Restarting services"
    systemctl restart mas || warn "mas failed to restart"
    sleep 3
    systemctl restart matrix-synapse || warn "matrix-synapse failed to restart"
    local up=false
    for _ in $(seq 1 45); do
        if curl -sf -m 5 http://localhost:8008/health >/dev/null; then up=true; break; fi
        sleep 2
    done
    $up || warn "Synapse not healthy after 90 s (journalctl -u matrix-synapse -n 50)"
    systemctl restart coturn livekit lk-jwt-service maubot mas-invite || warn "a service failed to restart"
    # LiveKit finds its public IP via STUN before it listens; give services time to come up.
    local u
    for u in http://127.0.0.1:7880/ http://127.0.0.1:8083/healthz http://127.0.0.1:8081/ \
             http://127.0.0.1:29316/_matrix/maubot/; do
        for _ in $(seq 1 30); do curl -sf -m 2 -o /dev/null "$u" && break; sleep 1; done
    done
    if nginx_sane; then systemctl reload nginx; else warn "nginx NOT reloaded (config problem above)"; fi
}

if $CHECK_ONLY; then
    if health_check; then log "All services healthy."; exit 0; fi
    die "health check FAILED - see journalctl -u <service> -n 50"
fi

WORKDIR=$(mktemp -d)
CHANGED=()
# Pause the 5-minute monitor: restarts would otherwise raise (and then resolve) alerts.
MONITOR_PAUSED=false
if systemctl is-active --quiet matrix-monitor.timer; then systemctl stop matrix-monitor.timer; MONITOR_PAUSED=true; fi
on_exit() {
    local rc=$1
    rm -rf "$WORKDIR"
    if $MONITOR_PAUSED; then systemctl start matrix-monitor.timer || true; fi
    if [ "$rc" -ne 0 ] && [ ${#CHANGED[@]} -gt 0 ]; then
        warn "upgrade stopped with an error after changing: ${CHANGED[*]}"
        warn "restarting services on what is installed now; rollback: docs/ADMIN_GUIDE.md -> Upgrades -> Rollback"
        restart_all || true
        health_check || true
    fi
}
trap 'on_exit $?' EXIT

# --- 1. Preflight -----------------------------------------------------------------
nginx_sane || die "fix the nginx configuration before upgrading"

# --- 2. Look up every release first (nothing changes if this fails) ---------------
log "Checking for new releases"
resolve_asset element-hq/matrix-authentication-service 'mas-cli-x86_64-linux\.tar\.gz'; MAS=("$R_TAG" "$R_URL" "$R_SHA")
resolve_asset element-hq/element-web 'element-v[0-9.]+\.tar\.gz';                         EW=("$R_TAG" "$R_URL" "$R_SHA")
resolve_asset Awesome-Technologies/synapse-admin 'synapse-admin-[0-9.]+\.tar\.gz';        SA=("$R_TAG" "$R_URL" "$R_SHA")
resolve_asset livekit/livekit 'livekit_[0-9.]+_linux_amd64\.tar\.gz';                     LK=("$R_TAG" "$R_URL" "$R_SHA")
resolve_asset element-hq/lk-jwt-service 'lk-jwt-service_linux_amd64';                     JWT=("$R_TAG" "$R_URL" "$R_SHA")
COTURN_TAG=$(latest_coturn_tag) || die "could not look up the latest coturn release"

CUR_MAS=$(/opt/mas/mas --version 2>/dev/null | awk '{print $2}' || echo none)
CUR_EW=$(cat /var/www/element-web/version 2>/dev/null || echo none)
CUR_SA=$(cat /var/www/synapse-admin/.version 2>/dev/null || echo unknown)
CUR_LK="v$(/usr/local/bin/livekit-server --version 2>/dev/null | awk '{print $3}')"
CUR_JWT=$(cat /usr/local/lib/lk-jwt-service.version 2>/dev/null || echo unknown)
CUR_COTURN=$(/usr/local/bin/turnserver --version 2>/dev/null || echo none)
printf '  %-16s %-14s -> %s\n' MAS "$CUR_MAS" "${MAS[0]}" "Element Web" "$CUR_EW" "${EW[0]}" \
    Synapse-Admin "$CUR_SA" "${SA[0]}" LiveKit "$CUR_LK" "${LK[0]}" lk-jwt-service "$CUR_JWT" "${JWT[0]}" \
    coturn "$CUR_COTURN" "$COTURN_TAG"

# --- 3. Backup ----------------------------------------------------------------------
if $BACKUP; then
    log "Pre-upgrade backup"
    "$HERE/backup_matrix.sh" || die "pre-upgrade backup failed; nothing was changed (--no-backup to skip)"
fi

# --- 4. APT ---------------------------------------------------------------------------
log "APT packages (Synapse, PostgreSQL, nginx, Debian)"
OLD_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
apt-get update -qq
CHANGED+=(apt)
DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
NEW_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
if [ "$OLD_SYNAPSE" != "$NEW_SYNAPSE" ]; then warn "Synapse upgraded $OLD_SYNAPSE -> $NEW_SYNAPSE (check the upgrade notes)"; fi
nginx_sane || die "nginx configuration broken after the APT upgrade"
if ! systemctl is-active --quiet nginx; then warn "nginx was stopped by the package upgrade; starting it"; systemctl start nginx; fi

# --- 5. Components --------------------------------------------------------------------
log "Matrix Authentication Service"
if [ "$CUR_MAS" != "${MAS[0]}" ]; then
    install_mas "$WORKDIR" "${MAS[@]}" >/dev/null     # validates config with the new binary first
    CHANGED+=(mas)
    (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas database migrate)
else log "  up to date ($CUR_MAS)"; fi

log "Element Web"
if [ "$CUR_EW" != "${EW[0]}" ]; then install_element_web "$WORKDIR" "${EW[@]}"; CHANGED+=(element-web)
else log "  up to date ($CUR_EW)"; fi

log "Synapse-Admin"
if [ "$CUR_SA" != "${SA[0]}" ]; then install_synapse_admin "$WORKDIR" "${SA[@]}"; CHANGED+=(synapse-admin)
else log "  up to date ($CUR_SA)"; fi

log "LiveKit SFU"
if [ "$CUR_LK" != "${LK[0]}" ]; then install_livekit "$WORKDIR" "${LK[@]}"; CHANGED+=(livekit)
else log "  up to date ($CUR_LK)"; fi

log "lk-jwt-service"
if [ "$CUR_JWT" != "${JWT[0]}" ]; then install_lk_jwt "$WORKDIR" "${JWT[@]}"; CHANGED+=(lk-jwt-service)
else log "  up to date ($CUR_JWT)"; fi

log "coturn (source build)"
if [ "$CUR_COTURN" != "$COTURN_TAG" ]; then build_coturn "$WORKDIR" "$COTURN_TAG"; CHANGED+=(coturn)
else log "  up to date ($CUR_COTURN)"; fi

log "Maubot (Python venv)"
# The maubot user cannot read /root, so stage the requirements file in /opt/maubot.
install -m 644 "$HERE/maubot_requirements.txt" /opt/maubot/requirements.txt
CHANGED+=(maubot)
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade pip
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade -r /opt/maubot/requirements.txt
/opt/maubot/venv/bin/pip check >/dev/null

# --- 6. Restart + health ----------------------------------------------------------------
restart_all
CHANGED=()   # from here on a failure is reported by the health check, not the exit trap
if $MONITOR_PAUSED; then systemctl start matrix-monitor.timer; MONITOR_PAUSED=false; fi
health_check || die "upgrade finished WITH FAILURES - check: journalctl -u <service> -n 50"
log "Upgrade complete. All services healthy."
