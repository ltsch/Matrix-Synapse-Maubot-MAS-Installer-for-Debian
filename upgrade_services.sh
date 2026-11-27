#!/bin/bash
# upgrade_services.sh - upgrade every component of the Matrix stack, then health-check it.
#
#   APT:     Synapse (packages.matrix.org), PostgreSQL minor (PGDG), nginx (nginx.org), Debian
#   GitHub:  MAS, Element Web, Synapse-Admin, LiveKit, lk-jwt-service (SHA-256 verified)
#   Source:  coturn (latest release, built into /usr/local)
#   pip:     Maubot venv
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

[ "$EUID" -eq 0 ] || die "run as root"
WORKDIR=$(mktemp -d); trap 'rm -rf "$WORKDIR"' EXIT

log "APT packages (Synapse, PostgreSQL, nginx, Debian)"
OLD_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
NEW_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
[ "$OLD_SYNAPSE" != "$NEW_SYNAPSE" ] && warn "Synapse upgraded $OLD_SYNAPSE -> $NEW_SYNAPSE (check the upgrade notes)"

log "Matrix Authentication Service"
CUR=$(/opt/mas/mas --version 2>/dev/null | awk '{print $2}' || echo none)
read -r TAG _ _ < <(gh_asset element-hq/matrix-authentication-service 'mas-cli-x86_64-linux\.tar\.gz')
if [ "$CUR" != "$TAG" ]; then
    install_mas "$WORKDIR" >/dev/null       # validates config with the new binary first
    (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas database migrate)
else log "  up to date ($CUR)"; fi

log "Element Web"
CUR=$(cat /var/www/element-web/version 2>/dev/null || echo none)
read -r TAG _ _ < <(gh_asset element-hq/element-web 'element-v[0-9.]+\.tar\.gz')
if [ "$CUR" != "$TAG" ]; then install_element_web "$WORKDIR"; else log "  up to date ($CUR)"; fi

log "Synapse-Admin"
CUR=$(cat /var/www/synapse-admin/.version 2>/dev/null || echo unknown)
read -r TAG _ _ < <(gh_asset Awesome-Technologies/synapse-admin 'synapse-admin-[0-9.]+\.tar\.gz')
if [ "$CUR" != "$TAG" ]; then install_synapse_admin "$WORKDIR"; else log "  up to date ($CUR)"; fi

log "LiveKit SFU"
CUR="v$(/usr/local/bin/livekit-server --version 2>/dev/null | awk '{print $3}')"
read -r TAG _ _ < <(gh_asset livekit/livekit 'livekit_[0-9.]+_linux_amd64\.tar\.gz')
if [ "$CUR" != "$TAG" ]; then install_livekit "$WORKDIR"; else log "  up to date ($CUR)"; fi

log "lk-jwt-service"
CUR=$(cat /usr/local/lib/lk-jwt-service.version 2>/dev/null || echo unknown)
read -r TAG _ _ < <(gh_asset element-hq/lk-jwt-service 'lk-jwt-service_linux_amd64')
if [ "$CUR" != "$TAG" ]; then install_lk_jwt "$WORKDIR"; else log "  up to date ($CUR)"; fi

log "coturn (source build)"
CUR=$(/usr/local/bin/turnserver --version 2>/dev/null || echo none)
TAG=$(latest_coturn_tag)
if [ "$CUR" != "$TAG" ]; then build_coturn "$WORKDIR" "$TAG"; else log "  up to date ($CUR)"; fi

log "Maubot (Python venv)"
# The maubot user cannot read /root, so stage the requirements file in /opt/maubot.
install -m 644 "$HERE/maubot_requirements.txt" /opt/maubot/requirements.txt
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade pip
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade -r /opt/maubot/requirements.txt
/opt/maubot/venv/bin/pip check >/dev/null

log "Restarting services"
systemctl restart mas
sleep 3
systemctl restart matrix-synapse
for _ in $(seq 1 30); do curl -sf http://localhost:8008/health >/dev/null && break; sleep 2; done
systemctl restart coturn livekit lk-jwt-service maubot mas-invite
systemctl reload nginx

log "Health check"
FAILED=0
for s in mas matrix-synapse coturn livekit lk-jwt-service maubot mas-invite nginx postgresql \
         matrix-turn-ip.timer matrix-monitor.timer matrix-refresh-certs.timer; do
    if systemctl is-active --quiet "$s"; then echo "  OK    $s"; else echo "  FAIL  $s"; FAILED=1; fi
done
for u in http://localhost:8008/health http://localhost:8082/health http://127.0.0.1:8083/healthz; do
    if curl -sf "$u" >/dev/null; then echo "  OK    $u"; else echo "  FAIL  $u"; FAILED=1; fi
done
[ "$FAILED" -eq 0 ] || die "upgrade finished WITH FAILURES - check: journalctl -u <service> -n 50"
log "Upgrade complete. All services healthy."
