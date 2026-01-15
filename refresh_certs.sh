#!/bin/bash
set -e

# ==============================================================================
# Certificate Refresh Script
# ==============================================================================
# Context:
# This script is responsible for pulling TLS certificates from a remote source
# rather than generating them locally (e.g., via Certbot).
#
# Reason:
# - The certificates are managed by a central Caddy instance on a different machine
#   (192.168.x.x) which acts as the edge reverse proxy/CA manager.
# - Caddy certificates often have short lifetimes (internal CA or Let's Encrypt),
#   requiring frequent automated refreshing.
#
# Logic:
# 1. Downloads the latest certs from the internal protected endpoint.
# 2. Compares them against the currently installed certificates.
# 3. If standard system services (Nginx, Coturn) need updates, it replaces the
#    old files and reloads the services.
# ==============================================================================

# Configuration
# ==============================================================================
# Load configuration from external file
CONFIG_FILE="$(dirname "$0")/refresh_certs.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file $CONFIG_FILE not found."
    echo "Please copy refresh_certs.conf.example to refresh_certs.conf and edit usage."
    exit 1
fi

DEST_DIR="/etc/nginx/ssl"
TEMP_DIR=$(mktemp -d)

# Ensure destination directory exists
mkdir -p "$DEST_DIR"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Fetching certificate for $CERT_NAME..."
# Download to tempdir first
curl -m 5 -s -f -o "$TEMP_DIR/matrix.crt" "$CERT_SOURCE_URL/$CERT_NAME.crt"
curl -m 5 -s -f -o "$TEMP_DIR/matrix.key" "$CERT_SOURCE_URL/$CERT_NAME.key"

# Verify files exist and are non-empty
if [[ ! -s "$TEMP_DIR/matrix.crt" || ! -s "$TEMP_DIR/matrix.key" ]]; then
    echo "Error: Failed to fetch valid certificates."
    exit 1
fi

CHANGE_DETECTED=false

# Compare with existing files
if ! cmp -s "$TEMP_DIR/matrix.crt" "$DEST_DIR/matrix.crt"; then
    echo "Certificate has changed."
    CHANGE_DETECTED=true
fi
if ! cmp -s "$TEMP_DIR/matrix.key" "$DEST_DIR/matrix.key"; then
    echo "Private key has changed."
    CHANGE_DETECTED=true
fi

if [ "$CHANGE_DETECTED" = true ]; then
    echo "Updating certificates..."
    mv "$TEMP_DIR/matrix.crt" "$DEST_DIR/matrix.crt"
    mv "$TEMP_DIR/matrix.key" "$DEST_DIR/matrix.key"
    
    chmod 644 "$DEST_DIR/matrix.crt"
    chmod 600 "$DEST_DIR/matrix.key"

    # Update Coturn Certs (it runs as turnserver user)
    echo "Updating Coturn certificates..."
    cp "$DEST_DIR/matrix.crt" /etc/turn_server_cert.pem
    cp "$DEST_DIR/matrix.key" /etc/turn_server_pkey.pem
    chown turnserver:turnserver /etc/turn_server_*.pem
    chmod 640 /etc/turn_server_*.pem

    # Reload Services
    echo "Reloading Nginx..."
    systemctl reload nginx
    
    echo "Restarting Coturn..."
    systemctl restart coturn
    
    echo "Done! Services updated."
else
    echo "Certificates are unchanged. No action taken."
fi
