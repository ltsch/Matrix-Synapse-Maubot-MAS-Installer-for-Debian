#!/bin/bash
# update_turn_ip.sh
# Run this via cron (e.g., every 15 mins) if 'detect-external-ip' fails for you.
# It fetches your public IP and updates /etc/turnserver.conf.

set -e

# Fetch Public IP via DNS (home.minn.info)
PUBLIC_IP=$(dig +short home.minn.info | head -n 1)

if [[ -z "$PUBLIC_IP" ]]; then
    echo "Failed to resolve home.minn.info, trying fallback..."
    PUBLIC_IP=$(curl -s -4 https://ifconfig.me)
fi

if [[ -z "$PUBLIC_IP" ]]; then
    echo "Failed to fetch public IP."
    exit 1
fi

echo "Current Public IP: $PUBLIC_IP"

# Backup config
cp /etc/turnserver.conf /etc/turnserver.conf.bak

# Update external-ip (Uncomment if commented, replace value)
# Handles both "external-ip=1.2.3.4" and "# external-ip=..."
if grep -q "external-ip" /etc/turnserver.conf; then
    sed -i "s|^#\? *external-ip=.*|external-ip=$PUBLIC_IP|" /etc/turnserver.conf
else
    echo "external-ip=$PUBLIC_IP" >> /etc/turnserver.conf
fi

# Ensure detect-external-ip is disabled if we are hardcoding
sed -i "s|^detect-external-ip|# detect-external-ip|" /etc/turnserver.conf

# Restart Coturn to apply changes
systemctl restart coturn
echo "Coturn updated with external-ip=$PUBLIC_IP"
