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
# Phantom-WireGuard Exit Server Setup Script (Dual-Stack)
# Sets up a standalone WireGuard exit server with IPv4 + IPv6 tunnel support
# and generates a dual-stack client configuration
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

# Configuration defaults — IPv4
WG_INTERFACE="wg0"
WG_PORT=51820
WG_NETWORK_V4="10.66.66.0/24"
WG_SERVER_IP_V4="10.66.66.1"
WG_CLIENT_IP_V4="10.66.66.2"
DNS_V4_PRIMARY="1.1.1.1"
DNS_V4_SECONDARY="1.0.0.1"

# Configuration defaults — IPv6
WG_NETWORK_V6="fd10:66:66::/64"
WG_SERVER_IP_V6="fd10:66:66::1"
WG_CLIENT_IP_V6="fd10:66:66::2"
DNS_V6_PRIMARY="2606:4700:4700::1111"
DNS_V6_SECONDARY="2606:4700:4700::1001"

# General
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
    echo -e "${BLUE}=== Exit WireGuard Server Setup (Dual-Stack) ===${NC}"
    echo ""
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Sets up a WireGuard exit server (Dual-Stack IPv4 + IPv6) and generates"
    echo "a client configuration with AllowedIPs = 0.0.0.0/0, ::/0"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT              WireGuard listen port (default: $WG_PORT)"
    echo "  -4, --network-v4 CIDR        IPv4 VPN network (default: $WG_NETWORK_V4)"
    echo "  -6, --network-v6 CIDR        IPv6 VPN network (default: $WG_NETWORK_V6)"
    echo "  --dns-v4 PRIMARY,SECONDARY   IPv4 DNS servers (default: $DNS_V4_PRIMARY,$DNS_V4_SECONDARY)"
    echo "  --dns-v6 PRIMARY,SECONDARY   IPv6 DNS servers (default: $DNS_V6_PRIMARY,$DNS_V6_SECONDARY)"
    echo "  -c, --client NAME            Client name (default: $CLIENT_NAME)"
    echo "  -o, --output DIR             Output directory for client config (default: $OUTPUT_DIR)"
    echo "  -i, --interface NAME         WireGuard interface name (default: $WG_INTERFACE)"
    echo "  -h, --help                   Show this help"
    echo ""
    echo "Example:"
    echo "  $0"
    echo "  $0 --port 51821 --client phone"
    echo "  $0 --network-v4 10.99.99.0/24 --network-v6 fd99:99:99::/64"
    echo "  $0 --dns-v4 8.8.8.8,8.8.4.4 --dns-v6 2001:4860:4860::8888,2001:4860:4860::8844"
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
            -4|--network-v4)
                WG_NETWORK_V4="$2"
                shift 2
                ;;
            -6|--network-v6)
                WG_NETWORK_V6="$2"
                shift 2
                ;;
            --dns-v4)
                DNS_V4_PRIMARY=$(echo "$2" | cut -d',' -f1)
                DNS_V4_SECONDARY=$(echo "$2" | cut -d',' -f2)
                shift 2
                ;;
            --dns-v6)
                DNS_V6_PRIMARY=$(echo "$2" | cut -d',' -f1)
                DNS_V6_SECONDARY=$(echo "$2" | cut -d',' -f2)
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

    # Recalculate IPv4 network addresses from CIDR
    V4_NETWORK_BASE=$(echo "$WG_NETWORK_V4" | cut -d'/' -f1 | cut -d'.' -f1-3)
    V4_NETWORK_PREFIX=$(echo "$WG_NETWORK_V4" | cut -d'/' -f2)
    WG_SERVER_IP_V4="${V4_NETWORK_BASE}.1"
    WG_CLIENT_IP_V4="${V4_NETWORK_BASE}.2"

    # Recalculate IPv6 network addresses from CIDR
    V6_NETWORK_PREFIX=$(echo "$WG_NETWORK_V6" | cut -d'/' -f2)
    V6_NETWORK_BASE=$(echo "$WG_NETWORK_V6" | cut -d'/' -f1 | sed 's/::$//')
    WG_SERVER_IP_V6="${V6_NETWORK_BASE}::1"
    WG_CLIENT_IP_V6="${V6_NETWORK_BASE}::2"
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

# Enable IP forwarding (both IPv4 and IPv6)
enable_ip_forwarding() {
    log "Enabling IPv4 + IPv6 forwarding..." "$YELLOW"

    # Enable immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null 2>&1

    # Persist IPv4 across reboots
    if grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
        sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    # Persist IPv6 across reboots
    if grep -q "^net.ipv6.conf.all.forwarding" /etc/sysctl.conf; then
        sed -i 's/^net.ipv6.conf.all.forwarding.*/net.ipv6.conf.all.forwarding = 1/' /etc/sysctl.conf
    else
        echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
    fi

    sysctl -p > /dev/null 2>&1

    log "IPv4 + IPv6 forwarding enabled" "$GREEN"
}

# Detect server public IPv4 address
detect_server_ipv4() {
    log "Detecting server public IPv4 address..." "$YELLOW"

    IP_CHECK_SERVICES=(
        "https://get.phantom.tc/ip"
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
    )

    SERVER_PUBLIC_IPV4=""
    for service in "${IP_CHECK_SERVICES[@]}"; do
        SERVER_PUBLIC_IPV4=$(curl --ipv4 -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
        if [[ $SERVER_PUBLIC_IPV4 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log "Server public IPv4: $SERVER_PUBLIC_IPV4 (via $service)" "$GREEN"
            return 0
        fi
    done

    error_exit "Failed to detect server public IPv4 address. Check internet connectivity."
}

# Detect server public IPv6 address (optional — not fatal)
detect_server_ipv6() {
    log "Detecting server public IPv6 address..." "$YELLOW"

    IP_CHECK_SERVICES=(
        "https://get.phantom.tc/ip"
        "https://api6.ipify.org"
        "https://v6.ident.me"
    )

    SERVER_PUBLIC_IPV6=""
    for service in "${IP_CHECK_SERVICES[@]}"; do
        SERVER_PUBLIC_IPV6=$(curl --ipv6 -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
        if [[ $SERVER_PUBLIC_IPV6 =~ : ]]; then
            log "Server public IPv6: $SERVER_PUBLIC_IPV6 (via $service)" "$GREEN"
            return 0
        fi
    done

    SERVER_PUBLIC_IPV6=""
    log "No public IPv6 detected — tunnel will still carry IPv6 traffic via ULA" "$YELLOW"
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
    log "Configuring WireGuard server (dual-stack)..." "$YELLOW"

    # Create server configuration
    cat > "/etc/wireguard/${WG_INTERFACE}.conf" << EOF
# Phantom-WireGuard Exit Server Configuration (Dual-Stack)
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_IP_V4}/${V4_NETWORK_PREFIX}, ${WG_SERVER_IP_V6}/${V6_NETWORK_PREFIX}
ListenPort = ${WG_PORT}
SaveConfig = false
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE; ip6tables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE; ip6tables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE

# ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${WG_CLIENT_IP_V4}/32, ${WG_CLIENT_IP_V6}/128
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

# Generate client configurations (v4 endpoint + v6 endpoint)
generate_client_configs() {
    log "Generating client configurations (dual-stack)..." "$YELLOW"

    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    # --- IPv4 endpoint config ---
    CLIENT_CONF_V4="${OUTPUT_DIR}/${CLIENT_NAME}-v4.conf"

    cat > "$CLIENT_CONF_V4" << EOF
# Phantom-WireGuard Client Configuration (Dual-Stack, IPv4 Endpoint)
# Server: ${SERVER_PUBLIC_IPV4}
# Client: ${CLIENT_NAME}
# Generated: ${generated_at}

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_IP_V4}/${V4_NETWORK_PREFIX}, ${WG_CLIENT_IP_V6}/${V6_NETWORK_PREFIX}
DNS = ${DNS_V4_PRIMARY}, ${DNS_V4_SECONDARY}, ${DNS_V6_PRIMARY}, ${DNS_V6_SECONDARY}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${SERVER_PUBLIC_IPV4}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF_V4"
    log "IPv4 endpoint config saved to: $CLIENT_CONF_V4" "$GREEN"

    # --- IPv6 endpoint config ---
    if [[ -z "$SERVER_PUBLIC_IPV6" ]]; then
        log "Skipping IPv6 endpoint config — no public IPv6 address detected" "$YELLOW"
        CLIENT_CONF_V6=""
        return 0
    fi

    CLIENT_CONF_V6="${OUTPUT_DIR}/${CLIENT_NAME}-v6.conf"

    cat > "$CLIENT_CONF_V6" << EOF
# Phantom-WireGuard Client Configuration (Dual-Stack, IPv6 Endpoint)
# Server: ${SERVER_PUBLIC_IPV6}
# Client: ${CLIENT_NAME}
# Generated: ${generated_at}

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_IP_V4}/${V4_NETWORK_PREFIX}, ${WG_CLIENT_IP_V6}/${V6_NETWORK_PREFIX}
DNS = ${DNS_V4_PRIMARY}, ${DNS_V4_SECONDARY}, ${DNS_V6_PRIMARY}, ${DNS_V6_SECONDARY}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = [${SERVER_PUBLIC_IPV6}]:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF_V6"
    log "IPv6 endpoint config saved to: $CLIENT_CONF_V6" "$GREEN"
}

# Display results
show_results() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   SETUP COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}Server Information:${NC}"
    echo -e "  Public IPv4:      ${WHITE}${SERVER_PUBLIC_IPV4}${NC}"
    if [[ -n "$SERVER_PUBLIC_IPV6" ]]; then
        echo -e "  Public IPv6:      ${WHITE}${SERVER_PUBLIC_IPV6}${NC}"
    else
        echo -e "  Public IPv6:      ${YELLOW}not detected (ULA-only tunnel)${NC}"
    fi
    echo -e "  WireGuard Port:   ${WHITE}${WG_PORT}/udp${NC}"
    echo -e "  Interface:        ${WHITE}${WG_INTERFACE}${NC}"
    echo -e "  Default Route:    ${WHITE}${DEFAULT_INTERFACE}${NC}"
    echo ""
    echo -e "${CYAN}VPN Networks:${NC}"
    echo -e "  IPv4 Network:     ${WHITE}${WG_NETWORK_V4}${NC}"
    echo -e "  IPv4 Server IP:   ${WHITE}${WG_SERVER_IP_V4}${NC}"
    echo -e "  IPv6 Network:     ${WHITE}${WG_NETWORK_V6}${NC}"
    echo -e "  IPv6 Server IP:   ${WHITE}${WG_SERVER_IP_V6}${NC}"
    echo ""
    echo -e "${CYAN}Client Information:${NC}"
    echo -e "  Client Name:      ${WHITE}${CLIENT_NAME}${NC}"
    echo -e "  Client IPv4:      ${WHITE}${WG_CLIENT_IP_V4}${NC}"
    echo -e "  Client IPv6:      ${WHITE}${WG_CLIENT_IP_V6}${NC}"
    echo ""
    echo -e "${CYAN}DNS:${NC}"
    echo -e "  IPv4 Primary:     ${WHITE}${DNS_V4_PRIMARY}${NC}"
    echo -e "  IPv4 Secondary:   ${WHITE}${DNS_V4_SECONDARY}${NC}"
    echo -e "  IPv6 Primary:     ${WHITE}${DNS_V6_PRIMARY}${NC}"
    echo -e "  IPv6 Secondary:   ${WHITE}${DNS_V6_SECONDARY}${NC}"
    echo ""

    echo -e "${CYAN}Client Config — IPv4 Endpoint:${NC}"
    echo -e "${YELLOW}---${NC}"
    echo ""
    cat "$CLIENT_CONF_V4"
    echo ""
    echo -e "${YELLOW}---${NC}"
    echo -e "${WHITE}File: ${CLIENT_CONF_V4}${NC}"
    echo ""

    if [[ -n "$CLIENT_CONF_V6" ]]; then
        echo -e "${CYAN}Client Config — IPv6 Endpoint:${NC}"
        echo -e "${YELLOW}---${NC}"
        echo ""
        cat "$CLIENT_CONF_V6"
        echo ""
        echo -e "${YELLOW}---${NC}"
        echo -e "${WHITE}File: ${CLIENT_CONF_V6}${NC}"
        echo ""
    fi
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
    detect_server_ipv4
    detect_server_ipv6
    detect_default_interface

    # Generate keys and configure
    generate_keys
    configure_server
    configure_firewall
    start_wireguard

    # Generate client output
    generate_client_configs
    show_results
}

# Run main
main "$@"
