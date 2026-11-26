#!/bin/bash
# upgrade_services.sh
# Upgrades the full Matrix stack: APT packages (Synapse, Coturn, Nginx, Postgres),
# Matrix Authentication Service (MAS), Element Web, Synapse-Admin and Maubot.
#
# GitHub downloads are verified against the SHA-256 digest GitHub publishes
# for each release asset. Configs are preserved across upgrades.
#
# IMPORTANT: Before upgrading Synapse across many versions, read
#   https://element-hq.github.io/synapse/latest/upgrade.html
# Synapse will refuse to start if a config option it no longer supports is set
# (e.g. experimental_features.msc3861 was removed in 1.157).

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# gh_asset <owner/repo> <asset-name-regex> -> prints "tag url sha256" for latest release
gh_asset() {
    curl -fsS "https://api.github.com/repos/$1/releases/latest" | python3 -I -c '
import json, re, sys
r = json.load(sys.stdin)
for a in r["assets"]:
    if re.fullmatch(sys.argv[1], a["name"]):
        print(r["tag_name"], a["browser_download_url"], (a.get("digest") or "sha256:").split(":", 1)[1])
        break
' "$2"
}

# fetch_verified <url> <sha256> <outfile>
fetch_verified() {
    curl -fsSL -o "$3" "$1"
    if [ -n "$2" ]; then
        echo "$2  $3" | sha256sum -c --quiet
    else
        echo "   WARNING: no digest published for $1, skipping checksum verification"
    fi
}

echo "=============================================="
echo "Step 1: APT packages (Synapse, Coturn, Nginx, Postgres, system)"
echo "=============================================="
OLD_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold upgrade
NEW_SYNAPSE=$(dpkg-query -W -f='${Version}' matrix-synapse-py3)
if [ "$OLD_SYNAPSE" != "$NEW_SYNAPSE" ]; then
    echo "-> Synapse upgraded $OLD_SYNAPSE -> $NEW_SYNAPSE (check upgrade notes!)"
fi

echo ""
echo "=============================================="
echo "Step 2: Matrix Authentication Service (MAS)"
echo "=============================================="
CURRENT_MAS=$(/opt/mas/mas --version 2>/dev/null | awk '{print $2}' || echo none)
read -r MAS_TAG MAS_URL MAS_SHA < <(gh_asset element-hq/matrix-authentication-service 'mas-cli-x86_64-linux\.tar\.gz')
if [ "$CURRENT_MAS" != "$MAS_TAG" ]; then
    echo "-> Upgrading MAS $CURRENT_MAS -> $MAS_TAG"
    fetch_verified "$MAS_URL" "$MAS_SHA" "$WORKDIR/mas.tar.gz"
    mkdir "$WORKDIR/mas" && tar xzf "$WORKDIR/mas.tar.gz" -C "$WORKDIR/mas"
    rm -rf /opt/mas/share.new && cp -a "$WORKDIR/mas/share" /opt/mas/share.new
    install -m 755 "$WORKDIR/mas/mas-cli" /opt/mas/mas.new
    # Validate existing config with the new binary before swapping it in
    (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas.new config check)
    rm -rf /opt/mas/share.old && mv /opt/mas/share /opt/mas/share.old
    mv /opt/mas/share.new /opt/mas/share && mv /opt/mas/mas.new /opt/mas/mas
    rm -rf /opt/mas/share.old
    (cd /opt/mas && sudo -u mas MAS_CONFIG=/opt/mas/config.yaml /opt/mas/mas database migrate)
else
    echo "-> MAS is up to date ($CURRENT_MAS)."
fi

echo ""
echo "=============================================="
echo "Step 3: Element Web"
echo "=============================================="
CURRENT_EW=$(cat /var/www/element-web/version 2>/dev/null || echo none)
read -r EW_TAG EW_URL EW_SHA < <(gh_asset element-hq/element-web 'element-v[0-9.]+\.tar\.gz')
if [ "$CURRENT_EW" != "$EW_TAG" ]; then
    echo "-> Upgrading Element Web $CURRENT_EW -> $EW_TAG"
    fetch_verified "$EW_URL" "$EW_SHA" "$WORKDIR/element.tar.gz"
    tar xzf "$WORKDIR/element.tar.gz" -C "$WORKDIR"
    cp /var/www/element-web/config.json "$WORKDIR/element-config.json"
    rm -rf /var/www/element-web/*
    cp -r "$WORKDIR/element-$EW_TAG"/* /var/www/element-web/
    cp "$WORKDIR/element-config.json" /var/www/element-web/config.json
    chown -R www-data:www-data /var/www/element-web
else
    echo "-> Element Web is up to date ($CURRENT_EW)."
fi

echo ""
echo "=============================================="
echo "Step 4: Synapse-Admin"
echo "=============================================="
CURRENT_SA=$(cat /var/www/synapse-admin/.version 2>/dev/null || echo unknown)
read -r SA_TAG SA_URL SA_SHA < <(gh_asset Awesome-Technologies/synapse-admin 'synapse-admin-[0-9.]+\.tar\.gz')
if [ "$CURRENT_SA" != "$SA_TAG" ]; then
    echo "-> Upgrading Synapse-Admin $CURRENT_SA -> $SA_TAG"
    fetch_verified "$SA_URL" "$SA_SHA" "$WORKDIR/sa.tar.gz"
    tar xzf "$WORKDIR/sa.tar.gz" -C "$WORKDIR"
    cp /var/www/synapse-admin/config.json "$WORKDIR/sa-config.json"
    rm -rf /var/www/synapse-admin/*
    cp -r "$WORKDIR/synapse-admin-$SA_TAG"/* /var/www/synapse-admin/
    cp "$WORKDIR/sa-config.json" /var/www/synapse-admin/config.json
    echo "$SA_TAG" > /var/www/synapse-admin/.version
    chown -R www-data:www-data /var/www/synapse-admin
else
    echo "-> Synapse-Admin is up to date ($CURRENT_SA)."
fi

echo ""
echo "=============================================="
echo "Step 4.5: MatrixRTC (LiveKit SFU + lk-jwt-service)"
echo "=============================================="
CURRENT_LK="v$(/usr/local/bin/livekit-server --version 2>/dev/null | awk '{print $3}')"
read -r LK_TAG LK_URL LK_SHA < <(gh_asset livekit/livekit 'livekit_[0-9.]+_linux_amd64\.tar\.gz')
if [ "$CURRENT_LK" != "$LK_TAG" ]; then
    echo "-> Upgrading LiveKit $CURRENT_LK -> $LK_TAG (check release notes for config changes)"
    fetch_verified "$LK_URL" "$LK_SHA" "$WORKDIR/livekit.tar.gz"
    mkdir "$WORKDIR/lk" && tar xzf "$WORKDIR/livekit.tar.gz" -C "$WORKDIR/lk"
    install -m 755 "$WORKDIR/lk/livekit-server" /usr/local/bin/livekit-server
else
    echo "-> LiveKit is up to date ($CURRENT_LK)."
fi
# lk-jwt-service has no --version flag; track the installed tag in a stamp file
CURRENT_JWT=$(cat /usr/local/lib/lk-jwt-service.version 2>/dev/null || echo unknown)
read -r JWT_TAG JWT_URL JWT_SHA < <(gh_asset element-hq/lk-jwt-service 'lk-jwt-service_linux_amd64')
if [ "$CURRENT_JWT" != "$JWT_TAG" ]; then
    echo "-> Upgrading lk-jwt-service $CURRENT_JWT -> $JWT_TAG (check README for new env vars)"
    fetch_verified "$JWT_URL" "$JWT_SHA" "$WORKDIR/lk-jwt-service"
    install -m 755 "$WORKDIR/lk-jwt-service" /usr/local/bin/lk-jwt-service
    echo "$JWT_TAG" > /usr/local/lib/lk-jwt-service.version
else
    echo "-> lk-jwt-service is up to date ($CURRENT_JWT)."
fi

echo ""
echo "=============================================="
echo "Step 5: Maubot (Python venv)"
echo "=============================================="
# The maubot user cannot read /root, so stage the requirements file in /opt/maubot.
install -m 644 "$(dirname "$(readlink -f "$0")")/maubot_requirements.txt" /opt/maubot/requirements.txt
# sqlalchemy<2.0 (pinned in requirements) is REQUIRED for the xkcd/rss plugins.
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade pip
sudo -H -u maubot /opt/maubot/venv/bin/pip install -q --upgrade -r /opt/maubot/requirements.txt
/opt/maubot/venv/bin/pip check

echo ""
echo "=============================================="
echo "Step 6: Restarting services & health check"
echo "=============================================="
systemctl restart mas
sleep 3
systemctl restart matrix-synapse
for _ in $(seq 1 30); do curl -sf http://localhost:8008/health >/dev/null && break; sleep 2; done
systemctl restart coturn maubot mas-invite livekit lk-jwt-service
systemctl reload nginx

FAILED=0
for s in mas matrix-synapse coturn livekit lk-jwt-service maubot mas-invite nginx postgresql; do
    if systemctl is-active --quiet "$s"; then echo "  OK    $s"; else echo "  FAIL  $s"; FAILED=1; fi
done
curl -sf http://localhost:8008/health >/dev/null && echo "  OK    synapse /health" || { echo "  FAIL  synapse /health"; FAILED=1; }
curl -sf http://localhost:8082/health >/dev/null && echo "  OK    mas /health"     || { echo "  FAIL  mas /health"; FAILED=1; }
curl -sf http://127.0.0.1:8083/healthz >/dev/null && echo "  OK    lk-jwt /healthz" || { echo "  FAIL  lk-jwt /healthz"; FAILED=1; }

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "Upgrade complete. All services healthy."
else
    echo "Upgrade finished WITH FAILURES. Check: journalctl -u <service> -n 50"
    exit 1
fi
