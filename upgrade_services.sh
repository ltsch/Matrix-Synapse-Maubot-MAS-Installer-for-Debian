#!/bin/bash
# upgrade_services.sh
# Safely upgrades Synapse, Coturn, and Maubot while preserving custom dependency fixes.

set -e

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

echo "=============================================="
echo "Step 1: Upgrading System Packages (APT)"
echo "Targets: Synapse, Coturn, Nginx, System Libs"
echo "=============================================="
apt-get update
# Install upgrades for specific packages to avoid full system churn if not desired, 
# or just run full upgrade. Here we target key components.
apt-get install -y --only-upgrade matrix-synapse-py3 coturn nginx libolm-dev libolm3

echo ""
echo "=============================================="
echo "Step 1.5: Upgrading Element Web (Manual)"
echo "=============================================="
# Fetch latest version tag from GitHub
CURRENT_VER=$(cat /var/www/element-web/version)
LATEST_VER=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | grep tag_name | cut -d'"' -f4)

if [ "$CURRENT_VER" != "$LATEST_VER" ]; then
    echo "-> Upgrading Element Web from $CURRENT_VER to $LATEST_VER..."
    
    WORKDIR=$(mktemp -d)
    cd $WORKDIR
    
    echo "-> Downloading element-$LATEST_VER.tar.gz..."
    wget -q https://github.com/element-hq/element-web/releases/download/$LATEST_VER/element-$LATEST_VER.tar.gz
    
    echo "-> Extracting..."
    tar -xzf element-$LATEST_VER.tar.gz
    
    # Backup config
    echo "-> Backing up config.json..."
    cp /var/www/element-web/config.json $WORKDIR/config.json.bak
    
    # Deploy new files
    echo "-> Deploying new files..."
    rm -rf /var/www/element-web/*
    cp -r element-$LATEST_VER/* /var/www/element-web/
    
    # Restore config
    echo "-> Restoring config.json..."
    cp $WORKDIR/config.json.bak /var/www/element-web/config.json
    chown -R www-data:www-data /var/www/element-web
    
    # Clean up
    cd /
    rm -rf $WORKDIR
    echo "-> Element Web upgraded to $LATEST_VER"
else
    echo "-> Element Web is already up to date ($CURRENT_VER)."
fi

echo ""
echo "=============================================="
echo "Step 2: Upgrading Maubot (Python/Pip)"
echo "Targets: Maubot Core + Re-enforcing Dependencies"
echo "=============================================="
VENV_PIP="/opt/maubot/venv/bin/pip"

# 1. Upgrade Maubot core
echo "-> Upgrading Maubot..."
sudo -u maubot $VENV_PIP install --upgrade maubot

# 2. Re-assert critical dependencies that might get clobbered or are just needed
#    - sqlalchemy<2.0: REQUIRED for xkcd/rss plugins
#    - Encryption deps: REQUIRED for Maubot to talk to Synapse encrypted
echo "-> Enforcing critical dependencies (Encryption + Legacy Compatibility)..."
sudo -u maubot $VENV_PIP install "sqlalchemy<2.0" python-olm unpaddedbase64 pycryptodome base58

echo ""
echo "=============================================="
echo "Step 3: Restarting Services"
echo "=============================================="
echo "-> Restarting Synapse..."
systemctl restart matrix-synapse
echo "-> Restarting Coturn..."
systemctl restart coturn
echo "-> Restarting Maubot..."
systemctl restart maubot

echo ""
echo "=============================================="
echo "Upgrade Complete!"
echo "Please check: systemctl status maubot"
echo "=============================================="
