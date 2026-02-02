#!/bin/bash
# ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
# ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
# ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
# ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
# ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
# Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
# Licensed under AGPL-3.0 - see LICENSE file for details
# Third-party licenses - see THIRD_PARTY_LICENSES file for details
# WireGuard® is a registered trademark of Jason A. Donenfeld.
# =============================================================================
# Phantom-WG Factory Reset Script
# =============================================================================
set -e

echo "Phantom-WG Factory Reset (HARD RESET)"
echo "============================================="

# Logging
log() {
    echo -e "${2:-$NC}[$(date '+%H:%M:%S')] $1${NC}"
}

# Check if phantom-api is available
if ! command -v phantom-api &> /dev/null; then
    echo "ERROR: phantom-api command not found!"
    echo "This script requires Phantom-WG to be installed."
    exit 1
fi

# Confirmation
# shellcheck disable=SC2162
read -p "This will DELETE ALL configurations. Type 'RESET' to confirm: " confirm
if [ "$confirm" != "RESET" ]; then
    echo "Aborted."
    exit 1
fi

echo "Starting HARD RESET..."

# 1. Detect SSH port for security
# First try to get from sshd_config
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
# If not found in config, try to detect from running sshd
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E "sshd|:22 " | grep -v "127.0.0.1" | awk '{print $4}' | grep -oE "[0-9]+$" | sort -u | head -n1)
fi
# Default to 22 if still not found
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi
echo "Detected SSH port: $SSH_PORT"

# 2. Disable Ghost Mode if active
echo "Checking Ghost Mode status..."
ghost_status=$(cd /opt/phantom-wg && phantom-api ghost status 2>/dev/null | grep -o '"enabled": [^,]*' | cut -d' ' -f2)
if [ "$ghost_status" = "true" ]; then
    echo "Disabling Ghost Mode..."
    cd /opt/phantom-wg && phantom-api ghost disable
fi

# 3. Disable Multihop if active
echo "Checking Multihop status..."
multihop_status=$(cd /opt/phantom-wg && phantom-api multihop status 2>/dev/null | grep -o '"enabled": [^,]*' | cut -d' ' -f2)
if [ "$multihop_status" = "true" ]; then
    echo "Disabling Multihop..."
    cd /opt/phantom-wg && phantom-api multihop disable_multihop
fi

# 4. Stop WireGuard service
echo "Stopping WireGuard service..."
systemctl stop wg-quick@wg_main 2>/dev/null || true

# 5. Remove ALL WireGuard interfaces
echo "Removing WireGuard interfaces..."
for interface in $(wg show interfaces); do
    ip link delete "$interface" 2>/dev/null || true
done

# 6. Clean ALL wstunnel processes
pkill -f wstunnel 2>/dev/null || true
killall wstunnel 2>/dev/null || true

# 7. COMPLETE cleanup - HARD DELETE EVERYTHING
echo "Performing HARD RESET..."
rm -rf /opt/phantom-wg/data/*
rm -rf /opt/phantom-wg/logs/*
rm -rf /opt/phantom-wg/config/*
rm -rf /opt/phantom-wg/backups/*
rm -rf /opt/phantom-wg/exit_configs/*

rm -f /etc/wireguard/wg_*.conf
rm -rf /etc/letsencrypt/live/*
rm -rf /etc/letsencrypt/archive/*
rm -rf /etc/letsencrypt/renewal/*

# 8. Remove systemd services
rm -f /etc/systemd/system/wstunnel.service
rm -f /etc/systemd/system/multihop-monitor.service
systemctl daemon-reload

# 9. Create fresh directories
mkdir -p /opt/phantom-wg/data
mkdir -p /opt/phantom-wg/logs
mkdir -p /opt/phantom-wg/backups
mkdir -p /opt/phantom-wg/exit_configs

# 10. Generate NEW server keys
echo "Generating new server keys..."
private_key=$(wg genkey)
public_key=$(echo "$private_key" | wg pubkey)
echo "New server public key: ${public_key:0:10}..."

# Configuration variables
WG_PORT=51820
WG_NETWORK="10.8.0.0/24"
WG_INTERFACE="wg_main"

# Calculate server IP from network
NETWORK_BASE=$(echo "$WG_NETWORK" | cut -d'/' -f1 | cut -d'.' -f1-3)
NETWORK_PREFIX=$(echo "$WG_NETWORK" | cut -d'/' -f2)
WG_SERVER_IP="${NETWORK_BASE}.1"
SERVER_ADDRESS="${WG_SERVER_IP}/${NETWORK_PREFIX}"

# Get default interface
DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [[ -z "$DEFAULT_INTERFACE" ]]; then
    DEFAULT_INTERFACE="eth0"
fi

# 11. Create FRESH WireGuard config
cat > /etc/wireguard/$WG_INTERFACE.conf << EOF
[Interface]
PrivateKey = $private_key
Address = $SERVER_ADDRESS
ListenPort = $WG_PORT
SaveConfig = false
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
EOF

# 12. Create FRESH phantom.json
# Get server IP using multiple services for reliability
IP_CHECK_SERVICES=(
    "https://install.phantom.tc/ip"
    "https://ipinfo.io/ip"
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
)

SERVER_IP=""
for service in "${IP_CHECK_SERVICES[@]}"; do
    SERVER_IP=$(curl --ipv4 -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
    if [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "Server IP detected: $SERVER_IP (via $service)" "$GREEN"
        break
    fi
done

# Check if we got a valid IP
if [[ ! $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: Failed to detect server IP address" "$RED"
    exit 1
fi

cat > /opt/phantom-wg/config/phantom.json << EOF
{
  "version": "core-v1",
  "wireguard": {
    "interface": "$WG_INTERFACE",
    "port": $WG_PORT,
    "network": "$WG_NETWORK"
  },
  "server": {
    "ip": "$SERVER_IP",
    "private_key": "$private_key",
    "public_key": "$public_key"
  },
  "tweaks": {
    "restart_service_after_client_creation": false
  },
  "dns": {
    "primary": "8.8.8.8",
    "secondary": "8.8.4.4"
  }
}
EOF

# 13. Reset firewall (keeping SSH port)
echo "Resetting firewall (keeping SSH port $SSH_PORT)..."
ufw --force reset
ufw --force enable
ufw allow "$SSH_PORT"/tcp
ufw allow $WG_PORT/udp
ufw allow from $WG_NETWORK to any port 53 comment 'DNS for WireGuard'
ufw reload

# 14. Start fresh WireGuard
echo "Starting fresh WireGuard..."
systemctl enable wg-quick@$WG_INTERFACE
systemctl start wg-quick@$WG_INTERFACE

# 15. Set permissions
chown -R root:root /opt/phantom-wg
chmod 755 /opt/phantom-wg
chmod 700 /opt/phantom-wg/data

echo "✓ HARD RESET COMPLETED!"
echo "System is now in FRESH INSTALL state."
echo "- No clients"
echo "- Fresh server keys" 
echo "- Clean database"
echo "- All logs deleted"
echo "- SSH port $SSH_PORT preserved"
echo ""
echo "Verifying system status..."
cd /opt/phantom-wg && phantom-api core server_status