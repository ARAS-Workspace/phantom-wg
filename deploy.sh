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
# Phantom-WG Deployment Script
# Deploy phantom-wg to remote server

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo -e "${WHITE}Third-party licenses - see THIRD_PARTY_LICENSES file for details${NC}"
    echo -e "${WHITE}WireGuard® is a registered trademark of Jason A. Donenfeld.${NC}"
    echo ""
}

# Show usage
show_usage() {
    echo "Usage: $0 <SERVER_IP> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --port PORT    SSH port (default: 22)"
    echo "  -u, --user USER    SSH username (default: root)"
    echo "  -k, --key PATH     SSH private key path (default: ~/.ssh/id_rsa)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Example:"
    echo "  $0 192.168.1.100"
    echo "  $0 192.168.1.100 -u admin -p 2222 -k ~/.ssh/mykey"
}

# Parse arguments
parse_arguments() {
    SERVER_IP=""
    SSH_PORT="22"
    SSH_USER="root"
    SSH_KEY="$HOME/.ssh/id_ed25519"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -*)
                error_exit "Unknown option: $1"
                ;;
            *)
                if [[ -z "$SERVER_IP" ]]; then
                    SERVER_IP="$1"
                    shift
                else
                    error_exit "Multiple server IPs provided"
                fi
                ;;
        esac
    done
    
    # Validate
    if [[ -z "$SERVER_IP" ]]; then
        error_exit "Server IP is required"
    fi
    
    # Expand tilde in SSH key path
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    
    if [[ ! -f "$SSH_KEY" ]]; then
        error_exit "SSH key not found: $SSH_KEY"
    fi
}

# Check SSH agent and key
check_ssh_agent() {
    log "Checking SSH configuration..." "$YELLOW"
    
    # Check if SSH agent is running
    if [[ -z "$SSH_AUTH_SOCK" ]]; then
        log "SSH agent not running, starting one..." "$YELLOW"
        eval "$(ssh-agent -s)" >/dev/null
    fi
    
    # Check if key is already loaded
    if ssh-add -l 2>/dev/null | grep -q "$(ssh-keygen -lf "$SSH_KEY" 2>/dev/null | awk '{print $2}')"; then
        log "SSH key already loaded in agent" "$GREEN"
        return 0
    fi
    
    # Try to add key to agent
    log "Adding SSH key to agent..." "$YELLOW"
    if ssh-add "$SSH_KEY" 2>/dev/null; then
        log "SSH key added successfully" "$GREEN"
    else
        # Key might have passphrase
        log "SSH key requires passphrase" "$YELLOW"
        echo -e "${CYAN}Please enter passphrase for SSH key:${NC}"
        if ssh-add "$SSH_KEY"; then
            log "SSH key added successfully" "$GREEN"
        else
            error_exit "Failed to add SSH key to agent"
        fi
    fi
}

# Test SSH connection
test_ssh_connection() {
    log "Testing SSH connection to $SSH_USER@$SERVER_IP:$SSH_PORT..." "$YELLOW"
    
    # Use BatchMode=yes to avoid interactive prompts
    if ssh -o ConnectTimeout=10 -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no -o BatchMode=yes -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "exit" 2>/dev/null; then
        log "SSH connection successful" "$GREEN"
    else
        # Try without BatchMode in case key needs passphrase
        if ssh -o ConnectTimeout=10 -o PasswordAuthentication=no \
            -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
            "$SSH_USER@$SERVER_IP" "exit"; then
            log "SSH connection successful" "$GREEN"
        else
            error_exit "SSH connection failed"
        fi
    fi
}

# Check server OS
check_server_os() {
    log "Checking server OS..." "$YELLOW"
    
    OS_INFO=$(ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "cat /etc/os-release | grep '^NAME=' | cut -d'\"' -f2")
    
    if [[ "$OS_INFO" == *"Debian"* ]] || [[ "$OS_INFO" == *"Ubuntu"* ]]; then
        log "Server OS: $OS_INFO" "$GREEN"
    else
        error_exit "Server must be running Debian/Ubuntu. Found: $OS_INFO"
    fi
}

# Deploy files
deploy_files() {
    log "Creating deployment package..." "$YELLOW"
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    TEMP_PACKAGE="$TEMP_DIR/phantom-wg.tar.gz"
    
    # Required files
    REQUIRED_FILES=("phantom-install.sh" "requirements.txt" "phantom")
    
    # Check required files
    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -e "$SCRIPT_DIR/$file" ]]; then
            error_exit "Required file/directory not found: $file"
        fi
    done
    
    # Create package with only required files
    cd "$SCRIPT_DIR"
    tar -czf "$TEMP_PACKAGE" \
        --exclude=".git*" \
        --exclude="__pycache__" \
        --exclude="*.pyc" \
        --exclude=".DS_Store" \
        --exclude="phantom_e2e_modular" \
        --exclude="deploy.sh" \
        --exclude=".backup" \
        phantom-install.sh requirements.txt phantom/
    
    log "Package created: $(du -h "$TEMP_PACKAGE" | cut -f1)" "$GREEN"
    
    # Transfer to server
    log "Transferring files to server..." "$YELLOW"
    
    REMOTE_TEMP="/tmp/phantom-install-$(date +%s)"
    ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "mkdir -p $REMOTE_TEMP"
    
    scp -o StrictHostKeyChecking=no -P "$SSH_PORT" -i "$SSH_KEY" \
        "$TEMP_PACKAGE" "$SSH_USER@$SERVER_IP:$REMOTE_TEMP/package.tar.gz"
    
    # Extract on server
    ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "cd $REMOTE_TEMP && tar -xzf package.tar.gz"
    
    log "Files transferred successfully" "$GREEN"
    
    # Run installation
    log "Starting installation on server..." "$BLUE"
    echo ""
    
    # Set sudo command if not root
    SUDO_CMD=""
    if [[ "$SSH_USER" != "root" ]]; then
        SUDO_CMD="sudo"
    fi
    
    # Run installation script
    ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" -t \
        "$SSH_USER@$SERVER_IP" "cd $REMOTE_TEMP && $SUDO_CMD bash phantom-install.sh"
    
    # Cleanup
    ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "rm -rf $REMOTE_TEMP"
    
    rm -rf "$TEMP_DIR"
}

# Verify installation
verify_installation() {
    log "Verifying installation..." "$YELLOW"
    
    # Test phantom-api command
    if ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "phantom-api core list_clients" >/dev/null 2>&1; then
        log "phantom-api command verified" "$GREEN"
    else
        log "Warning: phantom-api command test failed" "$YELLOW"
    fi
    
    # Check WireGuard service
    if ssh -o StrictHostKeyChecking=no -p "$SSH_PORT" -i "$SSH_KEY" \
        "$SSH_USER@$SERVER_IP" "systemctl is-active wg-quick@wg_main" >/dev/null 2>&1; then
        log "WireGuard service is active" "$GREEN"
    else
        log "Warning: WireGuard service is not active" "$YELLOW"
    fi
}

# Show completion
show_completion() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   DEPLOYMENT COMPLETED!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}Server Access:${NC}"
    echo -e "  SSH: ${YELLOW}ssh -p $SSH_PORT -i $SSH_KEY $SSH_USER@$SERVER_IP${NC}"
    echo ""
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  Interactive: ${YELLOW}phantom-wg${NC}"
    echo -e "  API: ${YELLOW}phantom-api core list_clients${NC}"
    echo ""
}

# Main function
main() {
    print_header
    
    # Parse arguments
    parse_arguments "$@"
    
    log "Deploying to $SERVER_IP" "$BLUE"
    echo ""
    
    # Confirm
    read -p "Continue? [Y/n]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        log "Deployment cancelled" "$YELLOW"
        exit 0
    fi
    
    # Deploy
    check_ssh_agent
    test_ssh_connection
    check_server_os
    deploy_files
    verify_installation
    
    # Complete
    show_completion
}

# Run main
main "$@"