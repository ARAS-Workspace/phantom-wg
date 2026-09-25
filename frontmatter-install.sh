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
# Phantom-WG Frontmatter Installation Script
#
# Sets up the frontmatter entry-point layer on the front server. Does NOT
# install or touch any backend components — frontmatter only forwards UDP
# to a configured backend (any WireGuard server or arbitrary UDP endpoint).
#
# Installation Flow:
#   1. System checks (OS, root privileges)
#   2. Install system dependencies (Python, socat, openssl)
#   3. Create directory structure (/opt/phantom-frontmatter)
#   4. Copy source files
#   5. Create Python virtual environment (.phantom-venv)
#   6. Install Python dependencies
#   7. Create global command (frontmatter-api)
#   8. Install systemd service templates
#   9. Verify installation and print next steps

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────

INSTALL_DIR="/opt/phantom-frontmatter"
VENV_DIR="${INSTALL_DIR}/.phantom-venv"
BIN_LINK="/usr/local/bin/frontmatter-api"
CERTBOT_LINK="/usr/local/bin/frontmatter-certbot"
UNINSTALL_LINK="/usr/local/sbin/frontmatter-uninstall"

SUPPORTED_DEBIAN_VERSIONS=("12" "13")
SUPPORTED_UBUNTU_VERSIONS=("22.04" "24.04")

# Source layout (where this script lives before install)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ───────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    WHITE='\033[1;37m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' WHITE='' NC=''
fi

log() {
    echo -e "${2:-$NC}[$(date '+%H:%M:%S')] $1${NC}"
}

# ── UI ──────────────────────────────────────────────────────────

print_header() {
    echo -e "${CYAN}"
    echo "██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗"
    echo "██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║"
    echo "██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║"
    echo "██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║"
    echo "██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║"
    echo "╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝"
    echo -e "${NC}"
    echo -e "${CYAN}Phantom-WG Frontmatter — Installation${NC}"
    echo -e "${WHITE}Copyright (c) 2025 Rıza Emre ARAS${NC}"
    echo -e "${WHITE}Licensed under AGPL-3.0${NC}"
    echo ""
}

# ── Pre-flight checks ───────────────────────────────────────────

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR: This script must be run as root (use sudo)" "$RED"
        exit 1
    fi
    log "Root privileges confirmed" "$GREEN"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log "ERROR: Cannot determine OS (missing /etc/os-release)" "$RED"
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="$ID"
    OS_VERSION_ID="$VERSION_ID"

    local supported=0
    case "$OS_ID" in
        debian)
            for v in "${SUPPORTED_DEBIAN_VERSIONS[@]}"; do
                [[ "$OS_VERSION_ID" == "$v" ]] && supported=1
            done
            ;;
        ubuntu)
            for v in "${SUPPORTED_UBUNTU_VERSIONS[@]}"; do
                [[ "$OS_VERSION_ID" == "$v" ]] && supported=1
            done
            ;;
    esac

    if [[ $supported -eq 0 ]]; then
        log "WARNING: Untested OS: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}" "$YELLOW"
        log "Supported: Debian ${SUPPORTED_DEBIAN_VERSIONS[*]}, Ubuntu ${SUPPORTED_UBUNTU_VERSIONS[*]}" "$YELLOW"
        printf "Continue anyway? [y/N]: "
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 1
    else
        log "OS check passed: ${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}" "$GREEN"
    fi
}

# ── System dependencies ────────────────────────────────────────

install_system_deps() {
    log "Installing system dependencies..." "$CYAN"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    apt-get install -y --no-install-recommends \
        python3 \
        python3-venv \
        python3-pip \
        socat \
        openssl \
        ca-certificates \
        certbot \
        cron \
        > /dev/null

    log "System dependencies installed" "$GREEN"
}

# ── Directory setup ───────────────────────────────────────────

create_directories() {
    log "Creating installation directories..." "$CYAN"

    mkdir -p "${INSTALL_DIR}/config"
    mkdir -p "${INSTALL_DIR}/data"
    mkdir -p "${INSTALL_DIR}/logs"
    mkdir -p "${INSTALL_DIR}/secrets"
    mkdir -p "${INSTALL_DIR}/bin"

    chmod 755 "${INSTALL_DIR}"
    chmod 755 "${INSTALL_DIR}/config"
    chmod 755 "${INSTALL_DIR}/data"
    chmod 755 "${INSTALL_DIR}/logs"
    chmod 700 "${INSTALL_DIR}/secrets"
    chmod 755 "${INSTALL_DIR}/bin"

    log "Directory structure created at ${INSTALL_DIR}" "$GREEN"
}

copy_sources() {
    log "Copying source files..." "$CYAN"

    rm -rf "${INSTALL_DIR}/phantom_frontmatter"
    cp -r "${SCRIPT_DIR}/phantom_frontmatter" "${INSTALL_DIR}/phantom_frontmatter"
    cp "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/requirements.txt"

    log "Source files copied" "$GREEN"
}

# ── Python environment ───────────────────────────────────────

create_venv() {
    if [[ -d "$VENV_DIR" ]] && [[ -x "${VENV_DIR}/bin/python3" ]]; then
        log "Virtual environment already exists at ${VENV_DIR}" "$GREEN"
        return
    fi

    log "Creating Python virtual environment..." "$CYAN"
    python3 -m venv "$VENV_DIR"
    "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
    log "Virtual environment created at ${VENV_DIR}" "$GREEN"
}

install_python_deps() {
    log "Installing Python dependencies..." "$CYAN"

    # Only run pip install when requirements.txt has at least one
    # non-comment line.
    if [[ -s "${INSTALL_DIR}/requirements.txt" ]] && \
       grep -qvE '^\s*(#|$)' "${INSTALL_DIR}/requirements.txt"; then
        "${VENV_DIR}/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"
        log "Python dependencies installed" "$GREEN"
    else
        log "No Python dependencies to install (stdlib only)" "$GREEN"
    fi
}

# ── Global command ───────────────────────────────────────────

create_global_command() {
    log "Creating global commands..." "$CYAN"

    local api_script="${INSTALL_DIR}/phantom_frontmatter/bin/frontmatter-api.py"
    local certbot_script="${INSTALL_DIR}/phantom_frontmatter/bin/frontmatter-certbot.py"
    local uninstall_script="${INSTALL_DIR}/phantom_frontmatter/frontmatter-uninstall.sh"

    if [[ -f "$api_script" ]]; then
        chmod +x "$api_script"
        sed -i "1s|.*|#!${VENV_DIR}/bin/python3|" "$api_script"
        ln -sf "$api_script" "$BIN_LINK"
        log "  ${BIN_LINK}" "$GREEN"
    fi

    if [[ -f "$certbot_script" ]]; then
        chmod +x "$certbot_script"
        sed -i "1s|.*|#!${VENV_DIR}/bin/python3|" "$certbot_script"
        ln -sf "$certbot_script" "$CERTBOT_LINK"
        log "  ${CERTBOT_LINK}" "$GREEN"
    fi

    if [[ -f "$uninstall_script" ]]; then
        chmod +x "$uninstall_script"
        ln -sf "$uninstall_script" "$UNINSTALL_LINK"
        log "  ${UNINSTALL_LINK}" "$GREEN"
    fi

    log "Global commands ready" "$GREEN"
}

# ── Verification ─────────────────────────────────────────────

verify_installation() {
    log "Verifying installation..." "$CYAN"

    # Test import
    if ! "${VENV_DIR}/bin/python3" -c "
import sys
sys.path.insert(0, '${INSTALL_DIR}')
from phantom_frontmatter import __version__
print(f'phantom_frontmatter {__version__}')
" > /dev/null 2>&1; then
        log "ERROR: Package import failed" "$RED"
        exit 1
    fi

    # Test CLI
    if ! "$BIN_LINK" --version > /dev/null 2>&1; then
        log "ERROR: frontmatter-api CLI failed" "$RED"
        exit 1
    fi

    log "Installation verified" "$GREEN"
}

# ── Next steps ───────────────────────────────────────────────

print_next_steps() {
    local db_file="${INSTALL_DIR}/data/frontmatter.db"
    local is_update=0
    [[ -f "$db_file" ]] && is_update=1

    echo ""
    if (( is_update )); then
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  Package source replaced.${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Install location: ${INSTALL_DIR}"
        echo ""
        echo "State and secrets preserved."
        echo ""
        echo "  This installer does not touch the extracted wstunnel"
        echo "  binary. To update an existing host, use the updater:"
        echo "     sudo ./frontmatter-update.sh"
        echo ""
        echo "  Restart the data path to load the new package:"
        echo "     frontmatter-api ghost restart"
        echo ""
        echo "  Verify:"
        echo "     frontmatter-api --version"
        echo "     frontmatter-api setup status"
        echo "     frontmatter-api ghost status"
        echo ""
    else
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  Installation complete.${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Install location: ${INSTALL_DIR}"
        echo ""
        echo "  1. Bootstrap:"
        echo "     frontmatter-api setup init backend=<BACKEND_IP[:PORT]>"
        echo ""
        echo "  2. Start:"
        echo "     frontmatter-api ghost start"
        echo ""
        echo "  3. Verify:"
        echo "     frontmatter-api setup status"
        echo "     frontmatter-api ghost status"
        echo ""
        echo "  4. Client snippet:"
        echo "     frontmatter-api ghost client_config"
        echo ""
        echo "  5. Client command:"
        echo "     frontmatter-api ghost client_command"
        echo ""
        echo "  Replace <FRONTMATTER-PUBLIC-IP> with this host's public"
        echo "  address before handing config to clients."
        echo ""
        echo "  Reset: frontmatter-api setup clean yes=true"
        echo ""
    fi
}

# ── Main ─────────────────────────────────────────────────────

main() {
    print_header
    check_root
    check_os
    install_system_deps
    create_directories
    copy_sources
    create_venv
    install_python_deps
    create_global_command
    verify_installation
    print_next_steps
}

main "$@"
