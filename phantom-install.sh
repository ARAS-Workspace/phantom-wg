#!/bin/bash
# ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
# ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
# ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
# ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
# ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
# Copyright (c) 2025 Rıza Emre ARAS
# Licensed under AGPL-3.0 - see LICENSE file for details
# Third-party licenses - see THIRD_PARTY_LICENSES file for details
# WireGuard® is a registered trademark of Jason A. Donenfeld.
#
# Phantom-WG Installation Script
# Clean installation for Phantom-WG
#
# Installation Flow:
#   1. System checks (OS, root privileges)
#   2. Install system dependencies (WireGuard, Python, UFW)
#   3. Create directory structure (/opt/phantom-wg)
#   4. Install Python virtual environment (.phantom-venv)
#   5. WireGuard configuration (keys, firewall)
#   6. Create global commands (phantom-wg, phantom-api)
#   7. Install multihop monitor service (systemd service)
#   8. Install multihop interface service (systemd service)
#   9. Verify installation and show completion info

set -euo pipefail

# Installation directory
INSTALL_DIR="/opt/phantom-wg"

# Supported OS versions (add new versions here as they become available)
SUPPORTED_DEBIAN_VERSIONS=("12" "13")
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04")

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    WHITE=''
    NC=''
fi

# Logging
log() {
    echo -e "${2:-$NC}[$(date '+%H:%M:%S')] $1${NC}"
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
    echo -e "${WHITE}Third-party licenses - see THIRD_PARTY_LICENSES file for details${NC}"
    echo -e "${WHITE}WireGuard® is a registered trademark of Jason A. Donenfeld.${NC}"
    echo ""
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root" "$RED"
        exit 1
    fi
    log "Root privileges confirmed" "$GREEN"
}

# Check OS compatibility
check_os() {
    if [[ ! -f /etc/debian_version ]]; then
        log "ERROR: This script requires Debian/Ubuntu" "$RED"
        exit 1
    fi

    # Read OS information
    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="$ID"
    OS_VERSION_ID="$VERSION_ID"
    OS_PRETTY_NAME="$PRETTY_NAME"

    log "Detected: $OS_PRETTY_NAME" "$BLUE"

    # Check if OS version is supported
    local supported=false

    case "$OS_ID" in
        debian)
            for version in "${SUPPORTED_DEBIAN_VERSIONS[@]}"; do
                if [[ "$OS_VERSION_ID" == "$version" ]]; then
                    supported=true
                    break
                fi
            done
            if [[ "$supported" == false ]]; then
                log "ERROR: Debian $OS_VERSION_ID is not supported" "$RED"
                log "Supported Debian versions: ${SUPPORTED_DEBIAN_VERSIONS[*]}" "$YELLOW"
                exit 1
            fi
            ;;
        ubuntu)
            for version in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
                if [[ "$OS_VERSION_ID" == "$version" ]]; then
                    supported=true
                    break
                fi
            done
            if [[ "$supported" == false ]]; then
                log "ERROR: Ubuntu $OS_VERSION_ID is not supported" "$RED"
                log "Supported Ubuntu versions: ${SUPPORTED_UBUNTU_VERSIONS[*]}" "$YELLOW"
                exit 1
            fi
            ;;
        *)
            log "ERROR: $OS_ID is not supported" "$RED"
            log "Supported systems: Debian (${SUPPORTED_DEBIAN_VERSIONS[*]}), Ubuntu (${SUPPORTED_UBUNTU_VERSIONS[*]})" "$YELLOW"
            exit 1
            ;;
    esac

    log "OS: $OS_PRETTY_NAME [Supported]" "$GREEN"
}

# Install system dependencies
install_dependencies() {
    log "Installing system dependencies..." "$YELLOW"

    # Update package list
    apt-get update

    # Install required packages
    apt-get install -y \
        wireguard \
        wireguard-tools \
        python3 \
        python3-pip \
        python3-venv \
        qrencode \
        ufw \
        curl \
        jq \
        net-tools \
        dnsutils

    # Log Python version
    PYTHON_VERSION=$(python3 --version)
    log "Python installed: $PYTHON_VERSION" "$GREEN"

    log "System dependencies installed" "$GREEN"
}

# Install Python requirements
install_python_requirements() {
    log "Installing Python requirements..." "$YELLOW"

    # Get script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check if requirements.txt exists
    if [[ ! -f "$SCRIPT_DIR/requirements.txt" ]]; then
        log "ERROR: requirements.txt not found in $SCRIPT_DIR" "$RED"
        exit 1
    fi

    # Create virtual environment
    VENV_PATH="$INSTALL_DIR/.phantom-venv"
    log "Creating Python virtual environment..." "$YELLOW"
    python3 -m venv "$VENV_PATH"

    # Activate virtual environment and install packages
    log "Installing Python packages in virtual environment..." "$YELLOW"
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip
    pip install -r "$SCRIPT_DIR/requirements.txt"
    deactivate

    log "Python requirements installed" "$GREEN"
}

# Create directory structure
create_directories() {
    log "Creating directory structure..." "$YELLOW"
    
    # Remove existing installation if exists
    if [[ -d "$INSTALL_DIR" ]]; then
        log "Removing existing installation..." "$YELLOW"
        rm -rf "$INSTALL_DIR"
    fi
    
    # Create directories
    # mkdir -p "$INSTALL_DIR"/{config,data,clients,logs,exit_configs}
    mkdir -p "$INSTALL_DIR"/{config,data,logs,exit_configs}
    
    # Get script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Copy phantom directory
    if [[ -d "$SCRIPT_DIR/phantom" ]]; then
        cp -r "$SCRIPT_DIR/phantom" "$INSTALL_DIR/"
        # Create symlinks for backward compatibility
        ln -sf "$INSTALL_DIR/phantom/modules" "$INSTALL_DIR/modules"
        ln -sf "$INSTALL_DIR/phantom/scripts" "$INSTALL_DIR/scripts"
    else
        log "ERROR: phantom directory not found in $SCRIPT_DIR" "$RED"
        exit 1
    fi
    
    # Set permissions
    chmod +x "$INSTALL_DIR"/phantom/bin/*.py 2>/dev/null || true
    chmod +x "$INSTALL_DIR"/phantom/scripts/*.sh 2>/dev/null || true
    find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \;
    
    log "Directory structure created" "$GREEN"
}

# Get default network interface
get_default_interface() {
    # shellcheck disable=SC2155
    local interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        interface="eth0"
    fi
    echo "$interface"
}

# Detect SSH port(s) from multiple sources
detect_ssh_ports() {
    local ports=()

    # Method 1: Get ports that sshd is actively listening on
    while IFS= read -r port; do
        [[ -n "$port" ]] && ports+=("$port")
    done < <(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u)

    # Method 2: Read from sshd_config
    local config_port
    config_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [[ -n "$config_port" ]] && ports+=("$config_port")

    # Method 3: Get port from current SSH connection
    local conn_port
    conn_port=$(echo "${SSH_CONNECTION:-}" | awk '{print $4}')
    [[ -n "$conn_port" ]] && ports+=("$conn_port")

    # Always include default port 22 as fallback
    ports+=(22)

    # Return unique ports
    printf '%s\n' "${ports[@]}" | sort -u
}

# Configure WireGuard
configure_wireguard() {
    log "Configuring WireGuard..." "$YELLOW"
    
    # Get server IP using multiple services for reliability
    IP_CHECK_SERVICES=(
        "https://install.phantom.tc/ip"
        "https://ipinfo.io/ip"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
    )

    if [[ -n "${PHANTOM_SERVER_IP:-}" ]] && [[ "${PHANTOM_SKIP_IP_CHECK:-false}" == "true" ]]; then
        SERVER_IP="$PHANTOM_SERVER_IP"
        log "Using provided server IP: $SERVER_IP " "$GREEN"
    else
        # Standard IP detection via external services
        SERVER_IP=""
        for service in "${IP_CHECK_SERVICES[@]}"; do
            SERVER_IP=$(curl --ipv4 -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ' || echo "")
            if [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                log "Server IP detected: $SERVER_IP (via $service)" "$GREEN"
                break
            else
                log "Failed to get IP from: $service" "$YELLOW"
            fi
        done
    fi
    
    # Check if we got a valid IP
    if [[ ! $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR: Failed to detect server IP address" "$RED"
        exit 1
    fi
    
    # Get default interface
    DEFAULT_INTERFACE=$(get_default_interface)
    log "Network interface: $DEFAULT_INTERFACE" "$BLUE"
    
    # Generate keys
    SERVER_PRIVATE_KEY=$(wg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    
    # Configuration
    WG_PORT=51820
    WG_NETWORK="10.8.0.0/24"
    WG_INTERFACE="wg_main"
    
    # Calculate server IP from network
    NETWORK_BASE=$(echo "$WG_NETWORK" | cut -d'/' -f1 | cut -d'.' -f1-3)
    NETWORK_PREFIX=$(echo "$WG_NETWORK" | cut -d'/' -f2)
    WG_SERVER_IP="${NETWORK_BASE}.1"
    SERVER_ADDRESS="${WG_SERVER_IP}/${NETWORK_PREFIX}"
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-wireguard.conf
    sysctl -p /etc/sysctl.d/99-wireguard.conf > /dev/null
    
    # Create WireGuard config
    cat > "/etc/wireguard/$WG_INTERFACE.conf" << EOF
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = $SERVER_ADDRESS
ListenPort = $WG_PORT
SaveConfig = false
PostUp = iptables -A FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i $WG_INTERFACE -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE
EOF
    
    # Create Phantom configuration
    cat > "$INSTALL_DIR/config/phantom.json" << EOF
{
  "version": "core-v1",
  "wireguard": {
    "interface": "$WG_INTERFACE",
    "port": $WG_PORT,
    "network": "$WG_NETWORK"
  },
  "server": {
    "ip": "$SERVER_IP",
    "private_key": "$SERVER_PRIVATE_KEY",
    "public_key": "$SERVER_PUBLIC_KEY"
  },
  "tweaks": {
    "restart_service_after_client_creation": false
  },
  "dns": {
    "primary": "8.8.8.8",
    "secondary": "1.1.1.1"
  }
}
EOF
    
    # Configure firewall - detect and allow SSH ports first to prevent lockout
    log "Detecting SSH ports..." "$BLUE"
    local ssh_ports
    ssh_ports=$(detect_ssh_ports)
    for port in $ssh_ports; do
        ufw allow "$port/tcp" comment 'SSH' > /dev/null 2>&1
        log "SSH port allowed: $port" "$BLUE"
    done

    ufw allow $WG_PORT/udp > /dev/null 2>&1
    ufw allow from $WG_NETWORK to any port 53 comment 'DNS for WireGuard' > /dev/null 2>&1
    ufw --force enable > /dev/null 2>&1
    
    # Enable and start WireGuard
    systemctl enable "wg-quick@$WG_INTERFACE" > /dev/null 2>&1
    systemctl start "wg-quick@$WG_INTERFACE" > /dev/null 2>&1 || log "Warning: WireGuard service needs manual start" "$YELLOW"
    
    log "WireGuard configured" "$GREEN"
    log "Server: $SERVER_IP:$WG_PORT" "$BLUE"
}

# Create global commands
create_commands() {
    log "Creating global commands..." "$YELLOW"
    
    # phantom-wg command
    if [[ -f "$INSTALL_DIR/phantom/bin/phantom-wg.py" ]]; then
        ln -sf "$INSTALL_DIR/phantom/bin/phantom-wg.py" /usr/local/bin/phantom-wg
        chmod +x "$INSTALL_DIR/phantom/bin/phantom-wg.py"
        log "Command created: phantom-wg" "$GREEN"
    fi
    
    # phantom-api command
    if [[ -f "$INSTALL_DIR/phantom/bin/phantom-api.py" ]]; then
        ln -sf "$INSTALL_DIR/phantom/bin/phantom-api.py" /usr/local/bin/phantom-api
        chmod +x "$INSTALL_DIR/phantom/bin/phantom-api.py"
        log "Command created: phantom-api" "$GREEN"
    fi

    # phantom-casper command
    if [[ -f "$INSTALL_DIR/phantom/bin/phantom-casper.py" ]]; then
        ln -sf "$INSTALL_DIR/phantom/bin/phantom-casper.py" /usr/local/bin/phantom-casper
        chmod +x "$INSTALL_DIR/phantom/bin/phantom-casper.py"
        log "Command created: phantom-casper" "$GREEN"
    fi
    
}

# Install multihop monitor service
install_multihop_monitor_service() {
    log "Installing multihop monitor service..." "$BLUE"
    
    # Copy monitor service file
    if [[ -f "$INSTALL_DIR/phantom/scripts/phantom-multihop-monitor.service" ]]; then
        cp "$INSTALL_DIR/phantom/scripts/phantom-multihop-monitor.service" /etc/systemd/system/
        log "Service file installed: phantom-multihop-monitor.service" "$GREEN"
    else
        log "Warning: phantom-multihop-monitor.service not found" "$YELLOW"
    fi
    
    # Ensure monitor script is executable
    if [[ -f "$INSTALL_DIR/phantom/scripts/multihop-monitor-service.py" ]]; then
        chmod +x "$INSTALL_DIR/phantom/scripts/multihop-monitor-service.py"
        log "Monitor script made executable" "$GREEN"
    else
        log "Warning: multihop-monitor-service.py not found" "$YELLOW"
    fi
    
    # Reload systemd and enable service (but don't start it)
    systemctl daemon-reload
    systemctl enable phantom-multihop-monitor.service > /dev/null 2>&1
    log "Multihop monitor service enabled (will start when multihop is enabled)" "$GREEN"
}

# Install multihop interface service
install_multihop_interface_service() {
    log "Installing multihop interface service..." "$BLUE"
    
    # Copy interface service file
    if [[ -f "$INSTALL_DIR/phantom/scripts/phantom-multihop-interface.service" ]]; then
        cp "$INSTALL_DIR/phantom/scripts/phantom-multihop-interface.service" /etc/systemd/system/
        log "Service file installed: phantom-multihop-interface.service" "$GREEN"
    else
        log "Warning: phantom-multihop-interface.service not found" "$YELLOW"
    fi
    
    # Ensure interface script is executable
    if [[ -f "$INSTALL_DIR/phantom/scripts/multihop-interface-restore.py" ]]; then
        chmod +x "$INSTALL_DIR/phantom/scripts/multihop-interface-restore.py"
        log "Interface script made executable" "$GREEN"
    else
        log "Warning: multihop-interface-restore.py not found" "$YELLOW"
    fi
    
    # Reload systemd and enable service (but don't start it)
    systemctl daemon-reload
    systemctl enable phantom-multihop-interface.service > /dev/null 2>&1
    log "Multihop interface service enabled (will start when multihop is enabled)" "$GREEN"
}

# Show completion
show_completion() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   PHANTOM-WG INSTALLED!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  ${YELLOW}phantom-wg${NC} - Interactive UI"
    echo -e "  ${YELLOW}phantom-api${NC} - API access"
    echo ""
    echo -e "${CYAN}Quick Start:${NC}"
    echo -e "  1. Run: ${YELLOW}phantom-wg${NC}"
    echo -e "  2. Select 'Core Management'"
    echo -e "  3. Add your first client"
    echo ""
    echo -e "${CYAN}API Example:${NC}"
    echo -e "  ${YELLOW}phantom-api core list_clients${NC}"
    echo ""
    echo -e "${CYAN}Python Environment:${NC}"
    echo -e "  Virtual env: ${YELLOW}$INSTALL_DIR/.phantom-venv${NC}"
    echo ""
}

# Main installation
main() {
    print_header
    
    log "Starting Phantom-WG installation..." "$BLUE"
    echo ""
    
    # Pre-flight checks
    check_root
    check_os
    
    # Installation steps
    install_dependencies
    create_directories
    install_python_requirements
    configure_wireguard
    create_commands
    install_multihop_monitor_service
    install_multihop_interface_service
    
    # Complete
    show_completion
    
    log "Installation completed!" "$GREEN"
}

# Run main
main "$@"