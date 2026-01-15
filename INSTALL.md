# Installation Guide

This document details the installation, configuration, and network requirements for the Matrix Synapse server stack.

## 1. Prerequisites

### System Requirements
- **OS**: Debian 12 (Bookworm) or Ubuntu 22.04 LTS recommended.
- **Resources**:
  - Minimum: 2 vCPU, 4GB RAM.
  - Recommended: 4 vCPU, 8GB RAM (especially for larger state events).
- **Storage**: 20GB+ SSD (state database grows over time).

### Network & DNS
Before installation, ensure the following DNS records point to your server's public IP:
- `A` record for your main domain (e.g., `chat.example.com`).
- `A` record for any subdomains if you plan to split services (though this stack consolidates on one).

If you are behind a NAT, ensure your router forwards the necessary ports (see Section 3).

## 2. Installation Information

The installation is handled by the `install-service-improved.sh` script. This script is **idempotent** (can be run multiple times) and **interactive**.

### Automated Installation (Recommended)
You can pre-configure the installation by creating a `setup.config` file in the same directory:

```bash
# setup.config
MATRIX_FQDN="chat.example.com"
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="super_secure_password"
# Optional: Database secrets are auto-generated if omitted
```

### Interactive Installation
Simply run the script:
```bash
./install-service-improved.sh
```
The script will prompt you for:
1.  **FQDN**: The public domain name of your Matrix server.
2.  **Admin Email**: For Let's Encrypt (if handling certs directly) or admin reference.
3.  **Admin Password**: For the initial `@admin` user.

## 3. Network & Firewall Configuration

You must allow the following ports through your firewall (UFW/IPTables) and forward them from your router/edge gateway.

| Port | Protocol | Service | Direction | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **80** | TCP | Nginx | Inbound | HTTP (ACME Challenges / Redirects) |
| **443** | TCP | Nginx | Inbound | HTTPS (Client API, Federation, Element Web) |
| **3478** | UDP/TCP | Coturn | Inbound | STUN/TURN Signaling |
| **5349** | TCP | Coturn | Inbound | TURN over TLS |
| **49152-50000** | UDP | Coturn | Inbound | TURN Relay Media Range (RTP) |

> [!WARNING]
> **TURN Relay Ports (49152-50000 UDP)** are critical for Voice/Video calls to work through NAT. If these are blocked, calls will fail or fall back to slow relays.

### Upstream Proxy Configuration (Caddy/Traefik/Nginx)
If this server sits behind another reverse proxy (e.g., OPNsense, Caddy), configure the upstream to trust and update headers.

**Required Headers:**
- `Host`: Pass the original host.
- `X-Forwarded-For`: The client's real IP.
- `X-Forwarded-Proto`: The schema (`https`).
- **WebSockets**: Ensure the proxy handles `Upgrade: websocket` and `Connection: Upgrade` headers.

**Example (Caddy Upstream):**
```caddy
chat.example.com {
    reverse_proxy 192.168.1.100 {
        header_up Host {host}
        header_up X-Real-IP {remote}
    }
}
```

## 4. Software Dependencies

The global dependencies are installed via `apt`, but specific services use Python Virtual Environments to ensure stability and isolation.

### Service Requirements
These files track the specific python packages needed.
1.  **Maubot**: `/root/maubot_requirements.txt`
2.  **Registration**: `/root/registration_requirements.txt`

The install script automatically deploys these requirements. To update them manually:
```bash
/opt/maubot/venv/bin/pip install -r /root/maubot_requirements.txt
```

## 5. Post-Installation Steps

1.  **Verify Services**:
    ```bash
    systemctl status matrix-synapse nginx coturn maubot
    ```
2.  **Access Element**: Open `https://Your_FQDN` in a browser.
3.  **Login**: Use the `@admin:Your_FQDN` account and the password you set.
4.  **Test Federation**: Use the [Matrix Federation Tester](https://federationtester.matrix.org/) to check your `/.well-known` configuration.

## 6. Maintenance & Upgrades

- **Update System**: Run `/root/upgrade_services.sh`. This script handles OS packages (apt) and updates Maubot/Element Web safely.
- **Certificates**: If not using a global proxy, certificates can be refreshed via `/root/refresh_certs.sh` (assumes Caddy integration).
