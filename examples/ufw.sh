#!/bin/bash
# examples/ufw.sh - OPTIONAL host firewall using ufw (same rules as examples/nftables.conf).
#
# The edge firewall (e.g. OPNsense) is the primary filter; this is defence in depth and is
# NOT applied by install.sh. Review, adjust LAN/EDGE_PROXY, then run it as root:
#   apt-get install ufw && bash examples/ufw.sh
# Keep a console (Proxmox: pct enter <vmid>) open in case a rule locks you out.
set -euo pipefail

LAN=192.168.1.0/24        # SSH and direct (admin) HTTPS from the LAN
EDGE_PROXY=192.168.1.1    # reverse proxy forwarding HTTPS here

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow from "$LAN" to any port 22 proto tcp comment 'SSH (LAN)'
ufw allow from "$EDGE_PROXY" to any port 80,443 proto tcp comment 'nginx (edge proxy)'
ufw allow from "$LAN" to any port 80,443 proto tcp comment 'nginx (LAN admin)'

ufw allow 3478,5349/udp comment 'coturn STUN/TURN, DTLS'
ufw allow 3478,5349/tcp comment 'coturn TURN, TURN/TLS'
ufw allow 49152:50000/udp comment 'coturn relay range'

ufw allow 7881/tcp comment 'LiveKit ICE/TCP'
ufw allow 7882/udp comment 'LiveKit UDP mux'
# LiveKit 7880 (signalling) stays closed: nginx reaches it on localhost.

ufw --force enable
ufw status verbose
