#!/bin/bash
# update_turn_ip.sh
# Keeps Coturn's external-ip in sync with this site's (dynamic) public IP.
#
# Coturn runs behind NAT, so it must advertise the public IP to clients while
# relaying on the LAN IP: external-ip=<public>/<private>. If this is wrong,
# coturn hands out unreachable relay addresses and calls fail to connect.
#
# Run from cron; only restarts coturn when the IP actually changes.

set -euo pipefail

# Site-specific values live in the git-ignored setup.config:
#   TURN_DDNS_HOST="home.example.com"   # hostname that tracks the public IP
#   TURN_PRIVATE_IP="192.168.x.x"       # coturn relay-ip (this container's LAN IP)
CONFIG_FILE="$(dirname "$(readlink -f "$0")")/setup.config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
DDNS_HOST="${TURN_DDNS_HOST:?set TURN_DDNS_HOST in setup.config}"
PRIVATE_IP="${TURN_PRIVATE_IP:-$(grep -oP '^relay-ip=\K.*' /etc/turnserver.conf || true)}"
CONF=/etc/turnserver.conf

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

PUBLIC_IP=$(dig +short "$DDNS_HOST" A | grep -E '^[0-9.]+$' | tail -n 1 || true)
if ! is_ipv4 "$PUBLIC_IP"; then
    echo "$(date -Is) Failed to resolve $DDNS_HOST, falling back to ifconfig.me"
    PUBLIC_IP=$(curl -fsS -4 -m 10 https://ifconfig.me || true)
fi
if ! is_ipv4 "$PUBLIC_IP"; then
    echo "$(date -Is) ERROR: could not determine public IP"
    exit 1
fi

WANT="external-ip=$PUBLIC_IP/$PRIVATE_IP"
if grep -qx "$WANT" "$CONF"; then
    exit 0   # unchanged; stay silent for cron
fi

cp "$CONF" "$CONF.bak"
if grep -q '^#\? *external-ip=' "$CONF"; then
    sed -i "s|^#\? *external-ip=.*|$WANT|" "$CONF"
else
    echo "$WANT" >> "$CONF"
fi
systemctl restart coturn
echo "$(date -Is) Coturn updated: $WANT"
