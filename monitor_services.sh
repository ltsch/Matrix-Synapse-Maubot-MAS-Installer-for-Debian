#!/bin/bash
# monitor_services.sh
# Monitors Matrix services and alerts via Webhook (Discord) on failure.
# Intended to be run via cron.

set -o pipefail

# --- Configuration ---
CONFIG_FILE="/root/setup.config"
HOSTNAME=$(hostname)
DATE=$(date)

# Load config
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Warning: $CONFIG_FILE not found. Configuring defaults/loading env..."
fi

# Services to monitor
SERVICES=("matrix-synapse" "coturn" "maubot" "nginx" "postgresql")

# URLs to check (HTTP 200/301/302/404 are acceptable, Connection Refused is bad)
URLS=("https://$MATRIX_FQDN/_matrix/client/versions" "https://$MATRIX_FQDN/_matrix/maubot")

# Webhook URL (from setup.config or passed here)
# If not set in config, you can hardcode it below or set env var.
: ${MONITOR_WEBHOOK_URL:=""}

# --- Functions ---

send_alert() {
    local message="$1"
    
    echo "ALERT: $message"
    
    if [ -n "$MONITOR_WEBHOOK_URL" ]; then
        # Format for Discord
        # Escape double quotes in message
        safe_message=$(echo "$message" | sed 's/"/\\"/g')
        
        json_payload="{\"content\": \"🚨 **Service Alert - $HOSTNAME** 🚨\n$safe_message\"}"
        
        curl -s -H "Content-Type: application/json" \
             -X POST \
             -d "$json_payload" \
             "$MONITOR_WEBHOOK_URL"
    else
        echo "No Webhook URL configured. Skipping alert."
    fi
}

check_service() {
    local service=$1
    if ! systemctl is-active --quiet "$service"; then
        return 1
    fi
    return 0
}

check_url() {
    local url=$1
    # Fail if curl cannot connect or returns status >= 500
    if ! curl -s -f -o /dev/null "$url"; then
        # curl -f fails on server errors (5xx) but also 404. 
        # We might want to be more lenient, checking just connection.
        # Let's check exit code. 
        # 404 is technically 'up' for the webserver, so let's allow it?
        # Re-run without -f to just check connection?
        # Actually curl -f is good for "service is broken".
        return 1
    fi
    return 0
}

# --- Main Logic ---


failures=()

# Test Flag
if [ "$1" == "--test" ] || [ "$1" == "test" ]; then
    echo "Sending test alert to $MONITOR_WEBHOOK_URL..."
    send_alert "Test Notification from Matrix Server ($HOSTNAME) - All is well."
    echo "Test notification sent."
    exit 0
fi

# 1. Check Systemd Services
for svc in "${SERVICES[@]}"; do
    if ! check_service "$svc"; then
        # echo "Example failure: $svc is down"
        failures+=("Service **$svc** is DOWN or INACTIVE")
    fi
done

# 2. Check URL Endpoints (Only if Nginx is up)
if systemctl is-active --quiet nginx; then
    for url in "${URLS[@]}"; do
        # Skip if FQDN is not set (e.g. empty config)
        if [[ "$url" == "https:///"* ]]; then continue; fi
        
        # We use a max-time to avoid hanging
        if ! curl -s --max-time 10 -I "$url" >/dev/null; then
             # echo "Endpoint failure: $url"
             failures+=("Endpoint **$url** is UNREACHABLE")
        fi
    done
fi

# 3. Report
if [ ${#failures[@]} -gt 0 ]; then
    # Failures detected
    # Join failures with newlines
    alert_msg=$(printf -- "- %s\n" "${failures[@]}")
    echo "Failures detected:"
    echo "$alert_msg"
    send_alert "$alert_msg"
    exit 1
else
    # All systems operational (Silent on success)
    exit 0
fi
