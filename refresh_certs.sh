#!/bin/bash
# refresh_certs.sh - install the TLS certificate published by the edge proxy.
#
# The public certificate is managed by Caddy on the edge (see docs/INSTALL.md §5);
# this host downloads it from CERT_SOURCE_URL (refresh_certs.conf) so nginx (LAN TLS
# between the edge and this host) and coturn (TURN over TLS/DTLS) use the same cert.
#
# Run nightly and after boot by matrix-refresh-certs.timer. A downloaded pair is only
# installed if it is a valid certificate for $CERT_NAME, not expiring within a day, and
# the key matches it. nginx is tested before reloading; on failure the old pair is
# restored. Exits non-zero on any failure (shows as a failed unit, which the monitor
# reports); the monitor also warns when the installed cert nears expiry.

set -euo pipefail

CONFIG_FILE="$(dirname "$(readlink -f "$0")")/refresh_certs.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date -Is) Error: $CONFIG_FILE not found (copy refresh_certs.conf.example)."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${CERT_SOURCE_URL:?set CERT_SOURCE_URL in refresh_certs.conf}"
: "${CERT_NAME:?set CERT_NAME in refresh_certs.conf}"

DEST_DIR=/etc/nginx/ssl
CRT="$DEST_DIR/matrix.crt"
KEY="$DEST_DIR/matrix.key"
TURN_CRT=/etc/turn_server_cert.pem
TURN_KEY=/etc/turn_server_pkey.pem

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
umask 077
mkdir -p "$DEST_DIR"

fail() { echo "$(date -Is) Error: $*"; exit 1; }

echo "$(date -Is) Fetching certificate for $CERT_NAME..."
curl -m 10 -sS -f -o "$TEMP_DIR/new.crt" "$CERT_SOURCE_URL/$CERT_NAME.crt" || fail "download of $CERT_NAME.crt failed"
curl -m 10 -sS -f -o "$TEMP_DIR/new.key" "$CERT_SOURCE_URL/$CERT_NAME.key" || fail "download of $CERT_NAME.key failed"

if cmp -s "$TEMP_DIR/new.crt" "$CRT" && cmp -s "$TEMP_DIR/new.key" "$KEY"; then
    echo "Certificates are unchanged. No action taken."
    exit 0
fi

# --- Validate before touching anything --------------------------------------
openssl x509 -noout -in "$TEMP_DIR/new.crt" 2>/dev/null || fail "downloaded file is not a PEM certificate"
openssl pkey -noout -in "$TEMP_DIR/new.key" 2>/dev/null || fail "downloaded file is not a PEM private key"
openssl x509 -noout -checkend 86400 -in "$TEMP_DIR/new.crt" >/dev/null \
    || fail "downloaded certificate is expired or expires within 24 h"
openssl x509 -noout -checkhost "$CERT_NAME" -in "$TEMP_DIR/new.crt" | grep -q 'does match' \
    || fail "downloaded certificate is not valid for $CERT_NAME"
cert_pub=$(openssl x509 -noout -pubkey -in "$TEMP_DIR/new.crt" | openssl sha256)
key_pub=$(openssl pkey -pubout -in "$TEMP_DIR/new.key" | openssl sha256)
[ "$cert_pub" = "$key_pub" ] || fail "downloaded key does not match the certificate"

echo "New certificate valid until $(openssl x509 -noout -enddate -in "$TEMP_DIR/new.crt" | cut -d= -f2); installing."

# --- Install (keep the old pair for rollback) --------------------------------
[ -f "$CRT" ] && cp -p "$CRT" "$TEMP_DIR/old.crt"
[ -f "$KEY" ] && cp -p "$KEY" "$TEMP_DIR/old.key"
install -m 644 "$TEMP_DIR/new.crt" "$CRT.tmp" && mv "$CRT.tmp" "$CRT"
install -m 600 "$TEMP_DIR/new.key" "$KEY.tmp" && mv "$KEY.tmp" "$KEY"

if ! nginx -t -q 2>"$TEMP_DIR/nginx.err"; then
    cat "$TEMP_DIR/nginx.err"
    [ -f "$TEMP_DIR/old.crt" ] && mv "$TEMP_DIR/old.crt" "$CRT"
    [ -f "$TEMP_DIR/old.key" ] && mv "$TEMP_DIR/old.key" "$KEY"
    fail "nginx rejected the new certificate; previous certificate restored"
fi
systemctl reload nginx
echo "nginx reloaded."

# coturn reads its own copies (it runs as turnserver).
install -m 640 -o turnserver -g turnserver "$CRT" "$TURN_CRT"
install -m 640 -o turnserver -g turnserver "$KEY" "$TURN_KEY"
systemctl restart coturn
echo "$(date -Is) Done: nginx and coturn updated."
