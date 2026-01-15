# System Administration Guide

This document is a comprehensive reference for managing the [chat.minn.info](file:///etc/nginx/sites-available/chat.minn.info) Matrix server stack.

## Service Overview

| Component | Service Name | Port (Internal) | Description |
| :--- | :--- | :--- | :--- |
| **Matrix Synapse** | `matrix-synapse` | `8008` (localhost) | Core Matrix homeserver. |
| **Nginx** | `nginx` | `80`, `443` | Reverse proxy, TLS termination, and routing. |
| **Coturn** | `coturn` | `3478`, `5349` | TURN/STUN server for Voice/Video calls. |
| **Maubot** | `maubot` | `29316` (localhost) | Matrix bot framework (encapsulated in venv). Runs as `maubot` user. |
| **Invite Generator** | `mas-invite` | `8081` (localhost) | Custom web UI to issue MAS invite tokens. | |
| **PostgreSQL** | `postgresql` | `5432` | Database for Synapse and Maubot. |
| **Synapse Admin** | `nginx` | `443` | Static web UI for Synapse administration. |
| **MAS** | `mas` | `8080`, `8082` | Matrix Authentication Service (OIDC Provider). Runs as `mas` user. |

## Configuration Files

| Service | File Path | Key Notes |
| :--- | :--- | :--- |
| **Synapse** | [/etc/matrix-synapse/homeserver.yaml](file:///etc/matrix-synapse/homeserver.yaml) | Main config (DB, paths, listeners). |
| **Synapse** | `/etc/matrix-synapse/conf.d/` | Override files (`server_name.yaml`, `registration.yaml`). |
| **Nginx** | `/etc/nginx/sites-available/chat.minn.info` | Reverse proxy config. Handles `/`, `/_matrix`, `/_synapse`, etc. |
| **Coturn** | `/etc/turnserver.conf` | TURN server setup, secrets, and TLS paths. |
| **Maubot** | `/opt/maubot/config.yaml` | Database URI, Admin user, Listen port. |
| **Registration** | `/opt/matrix-registration/app.py` | Flask source (binds to localhost, reads Synapse config). |
| **Element Web** | `/var/www/element-web/config.json` | Client config (points to `https://chat.minn.info`). |
| **MAS** | `/opt/mas/config.yaml` | MAS Config (DB, Secrets, Synapse Integration). |

## Common Tasks

### 1. Managing Services
All services are managed via systemd:
```bash
systemctl restart matrix-synapse
systemctl restart nginx
systemctl restart coturn
systemctl restart maubot
systemctl restart mas-invite
```
**Note:** `maubot` and `mas-invite` run as dedicated users (`maubot`, `mas`). Ensure strict file permissions.

### 2. Monitoring Logs
Access logs via `journalctl`:
```bash
journalctl -u matrix-synapse -f
journalctl -u maubot -f
journalctl -u mas-invite -f
journalctl -u coturn -f
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
```

### 3. Upgrading System
Use the provided upgrade script to safely update all components (including Maubot's venv):
```bash
/root/upgrade_services.sh
```

### 4. Updating Certificates
Certificates are fetched from Caddy via the refresh script. This is typically automated via cron (if configured) or run manually:
```bash
/root/refresh_certs.sh
```

### 5. Managing Maubot
- **Web UI**: [https://chat.minn.info/_matrix/maubot/](https://chat.minn.info/_matrix/maubot/)
- **Virtual Environment**: `/opt/maubot/venv`
- **Plugin Management**: Install plugins via the Web UI to ensure they are properly registered.

### 6. Managing Users
- **Create User**: Visit [https://chat.minn.info/register](https://chat.minn.info/register)
- **Promote to Admin** (SQL):
  ```bash
  sudo -u postgres psql -d synapse_db -c "UPDATE users SET admin = 1 WHERE name = '@username:chat.minn.info';"
  ```

### Synapse Admin Config
The Synapse Admin UI is available at `https://chat.minn.info/synapse-admin`.

**Important Login Instructions:**
`synapse-admin` is a legacy application and does not support the new OIDC/SSO Native login flow natively.
To log in:
1.  Ensure you are using the **Password** login field (not "Sign in with SSO").
2.  Use your username (e.g., `@admin:chat.minn.info`) and your MAS password.
3.  *Note:* We have configured Nginx to transparently proxy these password requests to the MAS compatibility layer.

### 7. Synapse Admin UI
- **URL**: [https://chat.minn.info/synapse-admin](https://chat.minn.info/synapse-admin)
- **Log in**: Use your Matrix admin ID (`@user:chat.minn.info`) and password.
- **Features**: Manage users, rooms, media, and server configuration visually.

### 8. Security Recommendations

#### Restricting Admin Access
It is highly recommended to restrict access to the Admin UI (`/synapse-admin`) and API (`/_synapse/admin`) to trusted IP addresses only (e.g., your generic local subnets like `192.168.0.0/16`, `10.0.0.0/8`, or VPN IPs).

**Option A: Caddy (Upstream)**
If you are using Caddy as your ingress, add this matcher to your site block:
```caddy
@admin_restricted {
    path /synapse-admin* /_synapse/admin*
    not remote_ip 192.168.0.0/16 10.0.0.0/8 127.0.0.1
}
respond @admin_restricted 403
```

**Option B: Nginx (Local)**
To enforce this on the local Nginx server, add `allow` and `deny` rules to the `/synapse-admin` and `/_synapse/admin` blocks in `/etc/nginx/sites-available/chat.minn.info`:
```nginx
location /synapse-admin {
    allow 192.168.0.0/16;
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;
    ...
}
```

### 9. Managing Matrix Authentication Service (MAS)
- **Status**: `systemctl status mas`
- **Logs**: `journalctl -u mas -f`
- **Configuration**: `/opt/mas/config.yaml` after editing, run `systemctl restart mas`.
- **Database**: Uses `mas_db` (Postgres).
- **Migration**: Tools located at `/opt/mas/mas`.

### 10. User Registration (MAS)
By default, public registration is **disabled**.

**To Invite Users via Web UI:**
1.  Navigate to [https://chat.minn.info/register](https://chat.minn.info/register).
2.  **Login** (Protected by Caddy basic auth or similar, if configured).
3.  Click "Generate Invite Token".
4.  Copy the link and send it to your user.

**Manual Creation (CLI):**
```bash
/opt/mas/mas manage register-user <username> <password>
```

### 11. FAQ / Troubleshooting
**Q: Why does `auth.chat.minn.info` show a "Discovery" page?**
A: This is normal. `auth.chat.minn.info` is the **Identity Provider**. It doesn't have a "home" page for users because its job is to handle logins *for other apps* (like Element).
- The "Sign In" button there takes you to your **Account Management** page.
- The "OpenID Connect discovery document" link is used by apps (like Element) to automatically find the login servers.

**Q: Can I enable Social Login (Google, Discord, etc.)?**
A: **Yes!** MAS natively supports "Upstream OAuth 2.0 / OIDC Providers".
To enable this, you need to edit `/opt/mas/config.yaml` and add an `upstream_oauth2` section.

**Example (Google):**
```yaml
upstream_oauth2:
  providers:
    - id: google
      human_name: Google
      issuer: "https://accounts.google.com"
      client_id: "YOUR_GOOGLE_CLIENT_ID"
      client_secret: "YOUR_GOOGLE_CLIENT_SECRET"
      scope: "openid profile email"
      # Mapping claims is often automatic for standard OIDC

**Redirect URI / Callback URL:**
The Callback URL must include the **Provider ID**, which **MUST be a ULID** (26-character string) defined in your config.
For the configuration I just set up, the URL is:
`https://auth.chat.minn.info/upstream/callback/MNZXB3BSSBGC1ACK1FNPW3S63T`

*(Note: If you change the `id` in `config.yaml`, this URL will change. The ID cannot be a simple word like `google`, it must be a valid ULID).*

**Q: How do I link an existing Matrix account to Google?**
A: **Do not** just sign in with Google seamlessly; that might create a *new* account if the emails don't match perfectly or if auto-linking isn't enabled.
**The Safe Way:**
1.  Go to `https://auth.chat.minn.info/account`.
2.  Log in with your **username and password**.
3.  Go to the **"Authentication"** or **"Cross-post / Social"** section (UI varies by version).
4.  Click **"Connect"** next to Google.
5.  Once connected, you can log in with either method.

**Q: How does a new user pick a username when signing up with Google?**
A: When a **new user** signs in with Google for the first time:
1.  MAS verifies their email with Google.
2.  MAS shows a **"Finish Registration"** screen.
3.  The user **types their desired username** (e.g., `@alice:chat.minn.info`) and clicks "Create Account".
    *   *Note: If you have locked down registration (e.g., invites only), they might need an invite link to start this process, or you must enable public registration.*
```
*After editing, restart the service: `systemctl restart mas`.*

## Important Scripts

- **`/root/install-service-improved.sh`**: The master installation script. Contains logic for a complete rebuild. Now interactive (prompts for FQDN, passwords) but can be automated via `setup.config`.
- **`/root/upgrade_services.sh`**: Safely upgrades system packages and Maubot's Python environment.
- **`/root/refresh_certs.sh`**: Fetches TLS certificates from the Caddy source.
- **`/root/update_turn_ip.sh`**: Updaters Coturn's external IP configuration (dynamic IP handling).

## Software Requirements

### Maubot (pip)
Dependencies are now tracked in `/root/maubot_requirements.txt`.
- `maubot[postgres]`
- `python-olm`
- `unpaddedbase64`
- `pycryptodome`
- `base58`
- `sqlalchemy<2.0` (Pinned for legacy plugin support)

### Matrix Registration (pip)
Dependencies are now tracked in `/root/registration_requirements.txt`.
- `flask`
- `requests`
- `pyyaml`
