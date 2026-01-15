#!/bin/bash
set -e

# Configuration
# Adapting for LXC environment (chat.minn.info)
CERT_SOURCE_URL="http://192.168.0.25:8009/protected-certs" 
CERT_NAME="chat.minn.info"
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
