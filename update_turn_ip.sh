#!/bin/bash
# update_turn_ip.sh
# Keeps Coturn's external-ip in sync with this site's (dynamic) public IP.
#
# Coturn runs behind NAT, so it must advertise the public IP to clients while
# relaying on the LAN IP: external-ip=<public>/<private>. If this is wrong,
# coturn hands out unreachable relay addresses and calls fail to connect.
#
# Runs every 30 s from matrix-turn-ip.timer. Restarts coturn/LiveKit only when the
# IP actually changes and two consecutive runs agree (so about a minute). The restart
# drops in-progress calls, but they are already broken once the public IP has moved.
#
# Lookup order: direct query (OpenDNS reports the address it sees us from, so
# there is no DDNS update lag) -> TURN_DDNS_HOST -> ifconfig.me.

set -euo pipefail

# Site-specific values live in the git-ignored setup.config:
#   TURN_DDNS_HOST="home.example.com"   # hostname that tracks the public IP
#   LAN_IP="192.168.x.x"                # coturn relay-ip (this host's LAN IP)
CONFIG_FILE="$(dirname "$(readlink -f "$0")")/setup.config"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
DDNS_HOST="${TURN_DDNS_HOST:?set TURN_DDNS_HOST in setup.config}"
PRIVATE_IP="${LAN_IP:-${TURN_PRIVATE_IP:-$(grep -oP '^relay-ip=\K.*' /etc/turnserver.conf || true)}}"
CONF=/etc/turnserver.conf

[ -n "$PRIVATE_IP" ] || { echo "$(date -Is) ERROR: LAN_IP not set and no relay-ip in $CONF"; exit 1; }
PENDING=/run/matrix-turn-ip.pending

# Accept only a routable public IPv4 address: rejects octets > 255 and private,
# loopback, link-local, CGNAT, benchmark, multicast/reserved and "this network" ranges,
# so a captive portal or broken resolver cannot push a useless address to coturn/LiveKit.
is_public_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1   # CGNAT 100.64/10
    (( a == 169 && b == 254 )) && return 1              # link-local
    (( a == 172 && b >= 16 && b <= 31 )) && return 1    # 172.16/12
    (( a == 192 && b == 168 )) && return 1              # 192.168/16
    (( a == 198 && (b == 18 || b == 19) )) && return 1  # benchmark 198.18/15
    return 0
}

last_ipv4() { grep -E '^[0-9.]+$' | tail -n 1 || true; }

# Lookup order: OpenDNS (no DDNS lag) -> TURN_DDNS_HOST -> ifconfig.me.
PUBLIC_IP=""
for source in opendns ddns ifconfig; do
    case $source in
        opendns)  cand=$(dig +short +time=2 +tries=1 myip.opendns.com A @resolver1.opendns.com 2>/dev/null | last_ipv4) ;;
        ddns)     cand=$(dig +short +time=2 +tries=2 "$DDNS_HOST" A 2>/dev/null | last_ipv4) ;;
        ifconfig) cand=$(curl -fsS -4 -m 5 https://ifconfig.me 2>/dev/null || true) ;;
    esac
    if is_public_ipv4 "$cand"; then PUBLIC_IP=$cand; break; fi
    [ -n "$cand" ] && echo "$(date -Is) Ignoring non-public address from $source"
done
if [ -z "$PUBLIC_IP" ]; then
    echo "$(date -Is) ERROR: could not determine a public IP from any source"
    exit 1
fi

WANT="external-ip=$PUBLIC_IP/$PRIVATE_IP"
if grep -qx "$WANT" "$CONF"; then
    rm -f "$PENDING"
    exit 0   # unchanged; stay silent
fi

# Debounce: apply a new address only when two consecutive runs (30 s apart) agree,
# so one odd lookup never restarts coturn/LiveKit (which drops calls).
if [ "$(cat "$PENDING" 2>/dev/null)" != "$PUBLIC_IP" ]; then
    echo "$PUBLIC_IP" > "$PENDING"
    echo "$(date -Is) Public IP appears to have changed to $PUBLIC_IP; confirming on the next run"
    exit 0
fi
rm -f "$PENDING"

cp "$CONF" "$CONF.bak"
if grep -q '^#\? *external-ip=' "$CONF"; then
    sed -i "s|^#\? *external-ip=.*|$WANT|" "$CONF"
else
    echo "$WANT" >> "$CONF"
fi
systemctl restart coturn
# LiveKit detects its public IP (STUN) only at startup
if systemctl is-enabled --quiet livekit 2>/dev/null; then systemctl restart livekit; fi
echo "$(date -Is) Coturn/LiveKit updated: $WANT"
