# Matrix Synapse + Services Installer

A comprehensive, opinionated installation script for setting up a full-featured Matrix Homeserver stack on Debian 12 (Bookworm).

**Features:**
- **Core**: Matrix Synapse (Homeserver) & Nginx (Proxy).
- **Client**: Element Web.
- **VoIP**: Coturn (STUN/TURN) configured for standard and TLS media.
- **Bots**: Maubot framework with virtualization.
- **Utilities**: Interactive installation or config-file driven for automation.

## ⚠️ Requirements & Warnings

- **OS**: Designed and tested **ONLY on Debian 12 (Bookworm)**.
  - *Other distributions (Ubuntu, Fedora, etc.) have NOT been tested and may break due to package naming or path differences.*
- **Root Access**: Scripts must be run as root.
- **Clean Install**: Best run on a fresh LXC container or VM.

## Installation

### 1. Quick Start (Interactive)
Run the script and follow the prompts.
```bash
chmod +x install-service-improved.sh
./install-service-improved.sh
```

### 2. Config-based (Automated)
Create a `setup.config` file to skip prompts (useful for automation).
```bash
cp setup.config.example setup.config
nano setup.config
# Edit settings...
./install-service-improved.sh
```

## Documentation
- [INSTALL.md](INSTALL.md) - Detailed installation, network, and firewall guide.
- [admin_guide.md](admin_guide.md) - Administration, commands, and maintenance.

## Credits & Inspiration
This toolkit was built for reliability and ease of deployment, heavily inspired by the work of the **BashClub** team:
- Source: [zamba-lxc-toolbox/matrix/install-service.sh](https://raw.githubusercontent.com/bashclub/zamba-lxc-toolbox/refs/heads/main/src/matrix/install-service.sh)

Modifications include externalizing requirements, adding interactive configuration, ensuring native Sliding Sync support, and integrating Maubot/Registration services.
