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
# Phantom-WireGuard Exit Server Setup Script
# Sets up a standalone WireGuard exit server and generates a client configuration
# =============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Configuration defaults
WG_INTERFACE="wg0"
WG_PORT=51820
WG_NETWORK="10.66.66.0/24"
WG_SERVER_IP="10.66.66.1"
WG_CLIENT_IP="10.66.66.2"
DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="1.0.0.1"
CLIENT_NAME="exit-server"
OUTPUT_DIR="/root"

# Logging
log() {
    echo -e "${2:-$NC}[$(date '+%H:%M:%S')] $1${NC}"
}

# Error handling
error_exit() {
    log "ERROR: $1" "$RED"
    exit 1
}

# Print header
print_header() {
    echo -e "${CYAN}"
    echo "██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗"
    echo "██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║"
    echo "██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║"
    echo "██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║"
    echo "██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║"
    echo "╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝"
    echo -e "${NC}"
    echo -e "${CYAN}Copyright (c) 2025 Rıza Emre ARAS${NC}"
    echo -e "${WHITE}Licensed under AGPL-3.0 - see LICENSE file for details${NC}"
    echo -e "${WHITE}WireGuard® is a registered trademark of Jason A. Donenfeld.${NC}"
    echo ""
    echo -e "${BLUE}=== Exit WireGuard Server Setup ===${NC}"
    echo ""
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Sets up a WireGuard exit server and generates a client configuration."
    echo ""
    echo "Options:"
    echo "  -p, --port PORT         WireGuard listen port (default: $WG_PORT)"
    echo "  -n, --network CIDR      VPN network CIDR (default: $WG_NETWORK)"
    echo "  -d, --dns DNS           Primary DNS server (default: $DNS_PRIMARY)"
    echo "  -c, --client NAME       Client name (default: $CLIENT_NAME)"
    echo "  -o, --output DIR        Output directory for client config (default: $OUTPUT_DIR)"
    echo "  -i, --interface NAME    WireGuard interface name (default: $WG_INTERFACE)"
    echo "  -h, --help              Show this help"
    echo ""
    echo "Example:"
    echo "  $0"
    echo "  $0 --port 51821 --client phone --dns 8.8.8.8"
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -p|--port)
                WG_PORT="$2"
                shift 2
                ;;
            -n|--network)
                WG_NETWORK="$2"
                shift 2
                ;;
            -d|--dns)
                DNS_PRIMARY="$2"
                shift 2
                ;;
            -c|--client)
                CLIENT_NAME="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -i|--interface)
                WG_INTERFACE="$2"
                shift 2
                ;;
            -*)
                error_exit "Unknown option: $1. Use --help for usage."
                ;;
            *)
                error_exit "Unexpected argument: $1. Use --help for usage."
                ;;
        esac
    done

    # Recalculate network addresses from CIDR
    NETWORK_BASE=$(echo "$WG_NETWORK" | cut -d'/' -f1 | cut -d'.' -f1-3)
    NETWORK_PREFIX=$(echo "$WG_NETWORK" | cut -d'/' -f2)
    WG_SERVER_IP="${NETWORK_BASE}.1"
    WG_CLIENT_IP="${NETWORK_BASE}.2"
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Use: sudo $0"
    fi
}

# Detect OS
detect_os() {
    log "Detecting operating system..." "$YELLOW"

    if [[ ! -f /etc/os-release ]]; then
        error_exit "Cannot detect OS. /etc/os-release not found."
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        error_exit "Unsupported OS: $PRETTY_NAME. Only Debian and Ubuntu are supported."
    fi

    log "OS detected: $PRETTY_NAME" "$GREEN"
}

# Install packages
install_packages() {
    log "Updating package lists..." "$YELLOW"
    apt-get update -qq

    log "Installing WireGuard and dependencies..." "$YELLOW"
    apt-get install -y -qq wireguard wireguard-tools iptables curl > /dev/null 2>&1

    # Verify wg command is available
    if ! command -v wg &> /dev/null; then
        error_exit "WireGuard installation failed. 'wg' command not found."
    fi

    log "Packages installed successfully" "$GREEN"
}

# Enable IP forwarding
enable_ip_forwarding() {
    log "Enabling IP forwarding..." "$YELLOW"

    # Enable immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    # Persist across reboots
    if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    sysctl -p > /dev/null 2>&1

    log "IP forwarding enabled" "$GREEN"
}

# Detect server public IP
detect_server_ip() {
    log "Detecting server public IP address..." "$YELLOW"

    IP_CHECK_SERVICES=(
        "https://install.phantom.tc/ip"
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
    )

    SERVER_PUBLIC_IP=""
    for service in "${IP_CHECK_SERVICES[@]}"; do
        SERVER_PUBLIC_IP=$(curl --ipv4 -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
        if [[ $SERVER_PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "Server public IP: $SERVER_PUBLIC_IP (via $service)" "$GREEN"
            return 0
        fi
    done

    error_exit "Failed to detect server public IP address. Check internet connectivity."
}

# Detect default network interface
detect_default_interface() {
    log "Detecting default network interface..." "$YELLOW"

    DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

    if [[ -z "$DEFAULT_INTERFACE" ]]; then
        DEFAULT_INTERFACE="eth0"
        log "Could not detect default interface, falling back to: $DEFAULT_INTERFACE" "$YELLOW"
    else
        log "Default network interface: $DEFAULT_INTERFACE" "$GREEN"
    fi
}

# Generate WireGuard keys
generate_keys() {
    log "Generating WireGuard keys..." "$YELLOW"

    # Server keys
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)

    # Client keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

    # Preshared key (additional layer of security)
    PRESHARED_KEY=$(wg genpsk)

    log "Server public key: ${SERVER_PUBLIC_KEY:0:10}..." "$GREEN"
    log "Client public key: ${CLIENT_PUBLIC_KEY:0:10}..." "$GREEN"
    log "Preshared key generated" "$GREEN"
}

# Configure WireGuard server
configure_server() {
    log "Configuring WireGuard server..." "$YELLOW"

    # Create server configuration
    cat > "/etc/wireguard/${WG_INTERFACE}.conf" << EOF
# Phantom-WireGuard Exit Server Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_IP}/${NETWORK_PREFIX}
ListenPort = ${WG_PORT}
SaveConfig = false
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE

# ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${WG_CLIENT_IP}/32
EOF

    # Secure file permissions
    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"

    log "Server configuration written to /etc/wireguard/${WG_INTERFACE}.conf" "$GREEN"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..." "$YELLOW"

    # Detect SSH port
    SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || true)
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=$(ss -tlnp 2>/dev/null | grep -E "sshd|:22 " | grep -v "127.0.0.1" | awk '{print $4}' | grep -oE "[0-9]+$" | sort -u | head -n1 || true)
    fi
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=22
    fi

    log "Detected SSH port: $SSH_PORT" "$CYAN"

    # Check if ufw is available
    if command -v ufw &> /dev/null; then
        ufw allow "${SSH_PORT}/tcp" > /dev/null 2>&1
        ufw allow "${WG_PORT}/udp" > /dev/null 2>&1
        ufw --force enable > /dev/null 2>&1
        log "Firewall configured via ufw (SSH: $SSH_PORT/tcp, WG: $WG_PORT/udp)" "$GREEN"
    else
        log "ufw not found, skipping firewall configuration" "$YELLOW"
        log "Ensure port $WG_PORT/udp is open in your firewall" "$YELLOW"
    fi
}

# Start WireGuard service
start_wireguard() {
    log "Starting WireGuard service..." "$YELLOW"

    systemctl enable "wg-quick@${WG_INTERFACE}" > /dev/null 2>&1
    systemctl start "wg-quick@${WG_INTERFACE}"

    # Verify
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        log "WireGuard service is active and running" "$GREEN"
    else
        error_exit "WireGuard service failed to start. Check: journalctl -xeu wg-quick@${WG_INTERFACE}"
    fi
}

# Generate client configuration
generate_client_config() {
    log "Generating client configuration..." "$YELLOW"

    CLIENT_CONF_PATH="${OUTPUT_DIR}/${CLIENT_NAME}.conf"

    cat > "$CLIENT_CONF_PATH" << EOF
# Phantom-WireGuard Client Configuration
# Server: ${SERVER_PUBLIC_IP}
# Client: ${CLIENT_NAME}
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_IP}/${NETWORK_PREFIX}
DNS = ${DNS_PRIMARY}, ${DNS_SECONDARY}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF_PATH"

    log "Client configuration saved to: $CLIENT_CONF_PATH" "$GREEN"
}

# Display results
show_results() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   SETUP COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}Server Information:${NC}"
    echo -e "  Public IP:        ${WHITE}${SERVER_PUBLIC_IP}${NC}"
    echo -e "  WireGuard Port:   ${WHITE}${WG_PORT}/udp${NC}"
    echo -e "  Interface:        ${WHITE}${WG_INTERFACE}${NC}"
    echo -e "  VPN Network:      ${WHITE}${WG_NETWORK}${NC}"
    echo -e "  Server VPN IP:    ${WHITE}${WG_SERVER_IP}${NC}"
    echo -e "  Default Route:    ${WHITE}${DEFAULT_INTERFACE}${NC}"
    echo ""
    echo -e "${CYAN}Client Information:${NC}"
    echo -e "  Client Name:      ${WHITE}${CLIENT_NAME}${NC}"
    echo -e "  Client VPN IP:    ${WHITE}${WG_CLIENT_IP}${NC}"
    echo -e "  Config File:      ${WHITE}${OUTPUT_DIR}/${CLIENT_NAME}.conf${NC}"
    echo ""
    echo -e "${CYAN}DNS:${NC}"
    echo -e "  Primary:          ${WHITE}${DNS_PRIMARY}${NC}"
    echo -e "  Secondary:        ${WHITE}${DNS_SECONDARY}${NC}"
    echo ""

    echo -e "${CYAN}Client Configuration (copy and use on your device):${NC}"
    echo -e "${YELLOW}---${NC}"
    echo ""
    cat "${OUTPUT_DIR}/${CLIENT_NAME}.conf"
    echo ""
    echo -e "${YELLOW}---${NC}"
    echo -e "${WHITE}Config file: ${OUTPUT_DIR}/${CLIENT_NAME}.conf${NC}"
    echo ""
}

# Main function
main() {
    print_header

    # Parse arguments
    parse_arguments "$@"

    # Pre-flight checks
    check_root
    detect_os

    # Install and configure
    install_packages
    enable_ip_forwarding
    detect_server_ip
    detect_default_interface

    # Generate keys and configure
    generate_keys
    configure_server
    configure_firewall
    start_wireguard

    # Generate client output
    generate_client_config
    show_results
}

# Run main
main "$@"