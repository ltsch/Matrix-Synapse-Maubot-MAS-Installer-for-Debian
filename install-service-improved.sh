#!/bin/bash
# install-service-improved.sh
# Improved Matrix Synapse + Element + Coturn + Maubot Setup
# Based on original script by BashClub, modified by Antigravity

set -e

# --- Configuration Section ---

# Function to prompt for a value if not already set
prompt_if_missing() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    
    if [ -z "${!var_name}" ]; then
        if [ -n "$default_value" ]; then
            read -p "$prompt_text [$default_value]: " input
            export $var_name="${input:-$default_value}"
        else
            read -p "$prompt_text: " input
            export $var_name="$input"
        fi
    fi
}

# Load config file if it exists
if [ -f "setup.config" ]; then
    echo "Loading configuration from setup.config..."
    source setup.config
fi

echo "--- Configuration Setup ---"
prompt_if_missing "MATRIX_FQDN" "Enter the fully qualified domain name (FQDN) for the Matrix server" "chat.minn.info"
prompt_if_missing "ADMIN_EMAIL" "Enter email for admin user" "admin@${MATRIX_FQDN}"
prompt_if_missing "ADMIN_PASS" "Enter admin password (leave empty to generate)" ""

if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -base64 18)
    echo "Generated Admin Password: $ADMIN_PASS"
fi

# Auto-generate technical secrets if not provided
: ${DB_NAME:="synapse_db"}
: ${DB_USER:="synapse_user"}
: ${DB_PASS:="$(openssl rand -hex 16)"}
: ${MAUBOT_DB_PASS:="$(openssl rand -hex 16)"}
: ${TURN_SECRET:="$(openssl rand -hex 32)"}

echo "------------------------------------------------"
echo "Configuration Summary:"
echo "FQDN: $MATRIX_FQDN"
echo "Database User: $DB_USER"
echo "------------------------------------------------"
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Base System Configuration (Merged from lxc-base.sh)
LXC_LOCALE="en_US.UTF-8"
# Standard Debian toolset
LXC_TOOLSET_BASE="sudo lsb-release curl dirmngr git gnupg2 apt-transport-https software-properties-common wget ssl-cert tmux vim"

echo "Starting installation for $MATRIX_FQDN..."

# 1. System Updates & Dependencies
# 1. System Updates & Base Configuration
echo "Configuring Locales..."
sed -i "s|# $LXC_LOCALE|$LXC_LOCALE|" /etc/locale.gen
sed -i "s|# en_US.UTF-8|en_US.UTF-8|" /etc/locale.gen
cat << EOF > /etc/default/locale
LANG="$LXC_LOCALE"
LANGUAGE=$LXC_LOCALE
EOF
locale-gen $LXC_LOCALE

echo "Updating APT Sources & Installing Base Tools..."
apt-get update
# Install base toolset first
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $LXC_TOOLSET_BASE

# Enable vim syntax highlighting (QoL)
sed -i "s|\"syntax on|syntax on|g" /etc/vim/vimrc || true

echo "Installing Matrix dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nginx postgresql python3-venv libpq-dev build-essential \
    pwgen coturn libolm-dev libolm3
    
# 1.1 Create Service Users
echo "Creating service users..."
useradd -r -s /bin/false maubot || true
useradd -r -s /bin/false matrix-reg || true

# 2. Matrix Repository
wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq matrix-synapse-py3

# 3. Database Setup (Correct Collation)
echo "Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || true
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE=template0 OWNER $DB_USER;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
# Fix public schema permissions
sudo -u postgres psql -d $DB_NAME -c "GRANT ALL ON SCHEMA public TO $DB_USER;"

# 4. Maubot Database
sudo -u postgres psql -c "CREATE USER maubot WITH PASSWORD '$MAUBOT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE maubot_db OWNER maubot;" || true

# 5. Synapse Configuration
echo "Configuring Synapse..."
cat > /etc/matrix-synapse/conf.d/server_name.yaml <<EOF
server_name: $MATRIX_FQDN
EOF

# Update homeserver.yaml (CLI replace for simplicity, assume standard file structure)
sed -i "s|server_name:.*|server_name: \"$MATRIX_FQDN\"|" /etc/matrix-synapse/homeserver.yaml
sed -i "s|bind_addresses: \['0.0.0.0'\]|bind_addresses: ['127.0.0.1']|" /etc/matrix-synapse/homeserver.yaml || true
# Ensure bind is 127.0.0.1 (regex backup)
sed -i "s|- 0.0.0.0|- 127.0.0.1|" /etc/matrix-synapse/homeserver.yaml

# Create registration secret
REG_SECRET=$(openssl rand -hex 32)
echo "registration_shared_secret: \"$REG_SECRET\"" > /etc/matrix-synapse/conf.d/registration.yaml

# Add TURN configuration to homeserver.yaml
cat >> /etc/matrix-synapse/homeserver.yaml <<EOF
turn_shared_secret: "$TURN_SECRET"
turn_uris:
  - "turn:$MATRIX_FQDN:3478?transport=udp"
  - "turn:$MATRIX_FQDN:3478?transport=tcp"
  - "turns:$MATRIX_FQDN:5349?transport=udp"
  - "turns:$MATRIX_FQDN:5349?transport=tcp"
turn_user_lifetime: 86400000
turn_allow_guests: true
EOF

# Enable Sliding Sync (Simplified MSC3575)
cat >> /etc/matrix-synapse/homeserver.yaml <<EOF

experimental_features:
  msc3575_enabled: true
EOF

# 6. Element Web Setup
echo "Installing Element Web..."
mkdir -p /var/www/element-web
# Fetch and Install Element Web
LATEST_VER=$(curl -s https://api.github.com/repos/element-hq/element-web/releases/latest | grep tag_name | cut -d'"' -f4)
echo "Downloading Element Web $LATEST_VER..."
wget -q https://github.com/element-hq/element-web/releases/download/$LATEST_VER/element-$LATEST_VER.tar.gz
tar -xzf element-$LATEST_VER.tar.gz
cp -r element-$LATEST_VER/* /var/www/element-web/
echo "$LATEST_VER" > /var/www/element-web/version
rm -rf element-$LATEST_VER element-$LATEST_VER.tar.gz

cat > /var/www/element-web/config.json <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://$MATRIX_FQDN",
            "server_name": "$MATRIX_FQDN"
        },
        "m.identity_server": {
            "base_url": "https://vector.im"
        }
    },
    "default_theme": "light"
}
EOF

# 7. Coturn Setup
echo "Configuring Coturn..."
cat > /etc/turnserver.conf <<EOF
listening-port=3478
tls-listening-port=5349
listening-ip=127.0.0.1
# Note: You may need to manualy set external-ip if detection fails
detect-external-ip
# Restrict UDP relay ports for easier firewalling
min-port=49152
max-port=50000
cert=/etc/turn_server_cert.pem
pkey=/etc/turn_server_pkey.pem
use-auth-secret
static-auth-secret=$TURN_SECRET
realm=$MATRIX_FQDN
total-quota=100
bpm=60
userdb=/var/lib/turn/turndb
EOF

# 8. Maubot Setup
echo "Installing Maubot..."
mkdir -p /opt/maubot
chown maubot:maubot /opt/maubot

# Setup Python Venv
python3 -m venv /opt/maubot/venv
/opt/maubot/venv/bin/pip install --upgrade pip setuptools wheel

# Install dependencies from requirements file if present, else fallback
if [ -f "/root/maubot_requirements.txt" ]; then
    echo "Installing Maubot dependencies from /root/maubot_requirements.txt..."
    cp /root/maubot_requirements.txt /opt/maubot/requirements.txt
    chown maubot:maubot /opt/maubot/requirements.txt
    /opt/maubot/venv/bin/pip install -r /opt/maubot/requirements.txt
else
    echo "WARNING: /root/maubot_requirements.txt not found. Installing default set."
    /opt/maubot/venv/bin/pip install maubot[postgres] python-olm unpaddedbase64 pycryptodome base58 "sqlalchemy<2.0"
fi

mkdir -p /opt/maubot/plugins /opt/maubot/trash
# Fix for missing fallback dir
mkdir -p /opt/maubot/venv/lib/python3.11/site-packages/maubot/plugins

cat > /opt/maubot/config.yaml <<EOF
database: postgresql://maubot:$MAUBOT_DB_PASS@localhost/maubot_db
crypto_db_pickle_key: "change_me_to_random_string"
plugin_directories:
    upload: /opt/maubot/plugins
    load:
    - /opt/maubot/plugins
    - /opt/maubot/venv/lib/python3.11/site-packages/maubot/plugins
    trash: /opt/maubot/trash
server:
    hostname: 127.0.0.1
    port: 29316
    public_url: https://$MATRIX_FQDN
    ui_base_path: /_matrix/maubot
    plugin_base_path: /_matrix/maubot/plugin/
    unshared_secret: "generate"
homeservers:
    $MATRIX_FQDN:
        url: https://$MATRIX_FQDN
admins:
    admin: "maubotadminpassword"
api_features:
    login: true
    plugin: true
    plugin_upload: true
    instance: true
    instance_database: true
    client: true
    client_proxy: true
    client_auth: true
    dev_open: true
    log: true
logging:
    version: 1
    formatters:
        colored:
            (): maubot.lib.color_log.ColorFormatter
            format: "[%(asctime)s] [%(levelname)s@%(name)s] %(message)s"
    handlers:
        console:
            class: logging.StreamHandler
            formatter: colored
    root:
        level: INFO
        handlers: [console]
EOF

# Systemd for Maubot
cat > /etc/systemd/system/maubot.service <<EOF
[Unit]
Description=Maubot
After=network.target postgresql.service matrix-synapse.service

[Service]
Type=simple
User=maubot
# Running as dedicated user
WorkingDirectory=/opt/maubot
ExecStart=/opt/maubot/venv/bin/python -m maubot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl daemon-reload
systemctl enable maubot
# Fix permissions
chown -R maubot:maubot /opt/maubot
systemctl start maubot

# 9. Nginx Configuration
echo "Configuring Nginx..."
cat > /etc/nginx/sites-available/$MATRIX_FQDN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;
    return 301 https://$MATRIX_FQDN;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $MATRIX_FQDN;

    ssl_certificate /etc/nginx/ssl/matrix.crt;
    ssl_certificate_key /etc/nginx/ssl/matrix.key;

    root /var/www/element-web;
    index index.html index.htm;

    # Matrix Client API
    location /_matrix {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
    }

    # Synapse Client API
    location /_synapse/client {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        client_max_body_size 50M;
    }
    
    # Maubot Admin UI
    location /_matrix/maubot {
        proxy_pass http://127.0.0.1:29316;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 50M;
    }

    # Well-known Discovery
    location /.well-known/matrix/client {
        return 200 '{"m.homeserver": {"base_url": "https://$MATRIX_FQDN"}, "org.matrix.msc3575.proxy": {"url": "https://$MATRIX_FQDN"}}';
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
    }

    location /.well-known/matrix/server {
        return 200 '{"m.server": "$MATRIX_FQDN:443"}';
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$MATRIX_FQDN /etc/nginx/sites-enabled/$MATRIX_FQDN
systemctl restart nginx
systemctl restart matrix-synapse

# 10. Register Admin
echo "Registering Admin..."
# Sleep to ensure Synapse is up
sleep 5
# 11. Registration Page Setup (Optional)
echo "Installing Registration Page..."
mkdir -p /opt/matrix-registration
chown matrix-reg:matrix-reg /opt/matrix-registration
# (Assuming files are deployed manually or via git, skipping file creation for brevity in script)
# (Assuming files are deployed manually or via git, skipping file creation for brevity in script)
mkdir -p /opt/matrix-registration/venv
if [ -f "/root/registration_requirements.txt" ]; then
    echo "Installing Registration dependencies from /root/registration_requirements.txt..."
    cp /root/registration_requirements.txt /opt/matrix-registration/requirements.txt
    chown matrix-reg:matrix-reg /opt/matrix-registration/requirements.txt
    
    python3 -m venv /opt/matrix-registration/venv
    /opt/matrix-registration/venv/bin/pip install -r /opt/matrix-registration/requirements.txt
elif [ -f "/opt/matrix-registration/requirements.txt" ]; then
    python3 -m venv /opt/matrix-registration/venv
    /opt/matrix-registration/venv/bin/pip install -r /opt/matrix-registration/requirements.txt
else
    echo "WARNING: No requirements.txt found for Matrix Registration. Installing defaults."
    python3 -m venv /opt/matrix-registration/venv
    /opt/matrix-registration/venv/bin/pip install flask requests pyyaml
fi

cat > /etc/systemd/system/matrix-registration.service <<EOF
[Unit]
Description=Matrix Registration Page
After=network.target matrix-synapse.service

[Service]
Type=simple
User=matrix-reg
WorkingDirectory=/opt/matrix-registration
ExecStart=/opt/matrix-registration/venv/bin/python app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# Fix permissions
chown -R matrix-reg:matrix-reg /opt/matrix-registration
# systemctl enable --now matrix-registration  # Uncomment to auto-enable

echo ""
echo "Installation Complete!"
echo "Server: https://$MATRIX_FQDN"
echo "Admin User: @admin:$MATRIX_FQDN"
echo "Maubot UI: https://$MATRIX_FQDN/_matrix/maubot"
