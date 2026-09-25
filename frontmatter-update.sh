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
# Phantom-WG Frontmatter Update Script
#
# Replaces the installed package with the one shipped in this release
# tarball. State, secrets and the operator's configuration are left
# untouched — this is not a re-install. Run frontmatter-install.sh for
# a first-time setup; run this script for every subsequent version.
#
# Update Flow:
#   1. System checks (root privileges, prior installation present)
#   2. Read the installed and incoming versions
#   3. Stop the data path if it is running (remembered for step 8)
#   4. Overwrite phantom_frontmatter/ and requirements.txt
#   5. Refresh Python dependencies and global commands
#   6. Verify the new version is live
#   7. Swap the bundled wstunnel binary if it changed
#   8. Restart the data path if step 3 stopped it

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────

INSTALL_DIR="/opt/phantom-frontmatter"
VENV_DIR="${INSTALL_DIR}/.phantom-venv"
BIN_LINK="/usr/local/bin/frontmatter-api"
CERTBOT_LINK="/usr/local/bin/frontmatter-certbot"
UNINSTALL_LINK="/usr/local/sbin/frontmatter-uninstall"

WSTUNNEL_SERVICE="phantom-frontmatter-ghost-wstunnel.service"
EGRESS_SERVICE="phantom-frontmatter-ghost-egress.service"

# Source layout (where this script lives inside the new release)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set by stop_data_path, read by start_data_path
WAS_RUNNING=0

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

# Read __version__ out of a phantom_frontmatter/__init__.py
read_version() {
    python3 -c "
import re, pathlib, sys
text = pathlib.Path('$1').read_text()
m = re.search(r'__version__\s*=\s*\"(.+?)\"', text)
sys.stdout.write(m.group(1) if m else '')
"
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
    echo -e "${CYAN}Phantom-WG Frontmatter — Update${NC}"
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

# Refuse to "update" a host that was never installed. Every artifact
# checked here is produced by frontmatter-install.sh.
check_installed() {
    local missing=0

    if [[ ! -d "$INSTALL_DIR" ]]; then
        log "ERROR: Install directory not found: ${INSTALL_DIR}" "$RED"
        missing=1
    fi

    if [[ ! -x "${VENV_DIR}/bin/python3" ]]; then
        log "ERROR: Virtual environment not found: ${VENV_DIR}" "$RED"
        missing=1
    fi

    if [[ ! -d "${INSTALL_DIR}/phantom_frontmatter" ]]; then
        log "ERROR: Installed package not found: ${INSTALL_DIR}/phantom_frontmatter" "$RED"
        missing=1
    fi

    for link in "$BIN_LINK" "$CERTBOT_LINK" "$UNINSTALL_LINK"; do
        if [[ ! -e "$link" ]]; then
            log "ERROR: Global command missing: ${link}" "$RED"
            missing=1
        fi
    done

    if (( missing )); then
        echo ""
        log "This host has no complete frontmatter installation to update." "$RED"
        log "Run ./frontmatter-install.sh for a first-time install." "$YELLOW"
        exit 1
    fi

    log "Existing installation confirmed at ${INSTALL_DIR}" "$GREEN"
}

# Refuse to run from anywhere but an unpacked release tarball.
check_source() {
    if [[ ! -f "${SCRIPT_DIR}/phantom_frontmatter/__init__.py" ]]; then
        log "ERROR: No phantom_frontmatter/ next to this script" "$RED"
        log "Run this script from inside the unpacked release tarball." "$YELLOW"
        exit 1
    fi
    log "Release source found at ${SCRIPT_DIR}" "$GREEN"
}

# ── Versions ────────────────────────────────────────────────────

read_versions() {
    CURRENT_VERSION="$(read_version "${INSTALL_DIR}/phantom_frontmatter/__init__.py")"
    NEW_VERSION="$(read_version "${SCRIPT_DIR}/phantom_frontmatter/__init__.py")"

    if [[ -z "$NEW_VERSION" ]]; then
        log "ERROR: Could not read __version__ from the release source" "$RED"
        exit 1
    fi

    log "Installed version : ${CURRENT_VERSION:-unknown}" "$CYAN"
    log "Release version   : ${NEW_VERSION}" "$CYAN"

    if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
        log "Same version — re-applying the package source" "$YELLOW"
    fi
}

# ── Data path ───────────────────────────────────────────────────

# Stop the ghost services if they are running, and remember that we
# did so. Enable-state is deliberately left alone: the operator's
# boot-time intent is not this script's to change.
stop_data_path() {
    if [[ ! -f "/etc/systemd/system/${WSTUNNEL_SERVICE}" ]]; then
        log "No data path configured yet — nothing to stop" "$GREEN"
        return
    fi

    if systemctl is-active --quiet "$WSTUNNEL_SERVICE"; then
        WAS_RUNNING=1
        log "Stopping ${WSTUNNEL_SERVICE}..." "$CYAN"
        systemctl stop "$WSTUNNEL_SERVICE"
        systemctl stop "$EGRESS_SERVICE" 2>/dev/null || true
        log "Data path stopped" "$GREEN"
    else
        log "Data path is not running — nothing to stop" "$GREEN"
    fi
}

start_data_path() {
    if (( WAS_RUNNING )); then
        log "Restarting the data path..." "$CYAN"
        # The wstunnel unit pulls in egress through Requires=/After=
        systemctl start "$WSTUNNEL_SERVICE"
        log "Data path restarted" "$GREEN"
    fi
}

# ── Package replacement ─────────────────────────────────────────

# Overwrite the package source only. data/, secrets/, bin/, config/
# and logs/ live outside phantom_frontmatter/ and are never touched.
copy_sources() {
    log "Replacing package source..." "$CYAN"

    rm -rf "${INSTALL_DIR}/phantom_frontmatter"
    cp -r "${SCRIPT_DIR}/phantom_frontmatter" "${INSTALL_DIR}/phantom_frontmatter"
    cp "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/requirements.txt"

    log "Package source replaced" "$GREEN"
}

install_python_deps() {
    log "Refreshing Python dependencies..." "$CYAN"

    if [[ -s "${INSTALL_DIR}/requirements.txt" ]] && \
       grep -qvE '^\s*(#|$)' "${INSTALL_DIR}/requirements.txt"; then
        "${VENV_DIR}/bin/pip" install --quiet -r "${INSTALL_DIR}/requirements.txt"
        log "Python dependencies refreshed" "$GREEN"
    else
        log "No Python dependencies to install (stdlib only)" "$GREEN"
    fi
}

# The symlink targets are unchanged, but the files behind them came
# out of the tarball: re-assert the exec bit and the venv shebang.
refresh_global_commands() {
    log "Refreshing global commands..." "$CYAN"

    local api_script="${INSTALL_DIR}/phantom_frontmatter/bin/frontmatter-api.py"
    local certbot_script="${INSTALL_DIR}/phantom_frontmatter/bin/frontmatter-certbot.py"
    local uninstall_script="${INSTALL_DIR}/phantom_frontmatter/frontmatter-uninstall.sh"

    if [[ -f "$api_script" ]]; then
        chmod +x "$api_script"
        sed -i "1s|.*|#!${VENV_DIR}/bin/python3|" "$api_script"
        ln -sf "$api_script" "$BIN_LINK"
    fi

    if [[ -f "$certbot_script" ]]; then
        chmod +x "$certbot_script"
        sed -i "1s|.*|#!${VENV_DIR}/bin/python3|" "$certbot_script"
        ln -sf "$certbot_script" "$CERTBOT_LINK"
    fi

    if [[ -f "$uninstall_script" ]]; then
        chmod +x "$uninstall_script"
        ln -sf "$uninstall_script" "$UNINSTALL_LINK"
    fi

    log "Global commands refreshed" "$GREEN"
}

# ── Verification ─────────────────────────────────────────────────

# The version trace is the proof the new source is the one being
# imported — not the file we just copied, but what Python loads.
verify_update() {
    log "Verifying update..." "$CYAN"

    local live_version
    live_version="$("${VENV_DIR}/bin/python3" -c "
import sys
sys.path.insert(0, '${INSTALL_DIR}')
from phantom_frontmatter import __version__
sys.stdout.write(__version__)
" 2>/dev/null)" || {
        log "ERROR: Package import failed after update" "$RED"
        exit 1
    }

    if [[ "$live_version" != "$NEW_VERSION" ]]; then
        log "ERROR: Imported version ${live_version} does not match release ${NEW_VERSION}" "$RED"
        exit 1
    fi

    if ! "$BIN_LINK" --version > /dev/null 2>&1; then
        log "ERROR: frontmatter-api CLI failed after update" "$RED"
        exit 1
    fi

    log "Update verified: phantom_frontmatter ${live_version}" "$GREEN"
}

# ── wstunnel binary ──────────────────────────────────────────────

# The extracted binary lives in ${INSTALL_DIR}/bin — outside the
# package directory — so replacing the package source never touches
# it. Swapping it is safe here and only here: the data path was
# stopped above, so nothing is executing the file.
#
# The extraction itself is delegated to the freshly installed
# binary_utils, imported inside the install's own venv, so there is
# exactly one implementation of "unpack the bundled tarball". The
# swap is proven by the version the new binary reports — not by the
# copy having succeeded.
update_wstunnel_binary() {
    local binary="${INSTALL_DIR}/bin/wstunnel"

    if [[ ! -f "$binary" ]]; then
        log "No wstunnel binary in place — 'setup init' will install it" "$GREEN"
        return
    fi

    log "Checking the bundled wstunnel binary..." "$CYAN"

    # install_wstunnel truncates the target in place, so a failed
    # extraction would leave a corrupt binary behind. Keep the known
    # good one aside until the new one has identified itself.
    local backup="${binary}.pre-update"
    cp -p "$binary" "$backup"

    if "${VENV_DIR}/bin/python3" - "$INSTALL_DIR" <<'PYTHON'
import subprocess
import sys
import time
from pathlib import Path

install_dir = Path(sys.argv[1])
sys.path.insert(0, str(install_dir))

from phantom_frontmatter.api.store import KVStore
from phantom_frontmatter.modules.setup.lib import binary_utils


def run_command(cmd, **_):
    """Same contract as BaseModule.run_command, minus the extras
    binary_utils never uses."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"success": False, "stdout": "", "stderr": str(exc),
                "returncode": 1, "command": cmd}
    return {
        "success": result.returncode == 0,
        "stdout": result.stdout or "",
        "stderr": result.stderr or "",
        "returncode": result.returncode,
        "command": cmd,
    }


class ShellLogger:
    """Forward binary_utils' log calls into the shell script's own
    timestamped output."""

    def _emit(self, message):
        print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)

    info = _emit
    warning = _emit
    error = _emit


bin_dir = install_dir / "bin"
binary = bin_dir / "wstunnel"
bundled = binary_utils.WSTUNNEL_VERSION
logger = ShellLogger()

before = binary_utils.get_installed_version(binary, run_command)

if before == bundled:
    logger.info(f"wstunnel {bundled} is already installed")
    sys.exit(0)

if not binary_utils.install_wstunnel(
    bin_dir=bin_dir,
    run_command_func=run_command,
    logger=logger,
):
    sys.exit(1)

after = binary_utils.get_installed_version(binary, run_command)

if after != bundled:
    logger.error(
        f"Installed binary reports {after!r}, expected {bundled!r}"
    )
    sys.exit(1)

# setup status reads this back; leaving it stale would report the
# version that was current at 'setup init' time.
store = KVStore(install_dir / "data" / "frontmatter.db", "setup")
if store.get("initialized_at") is not None:
    store.set("wstunnel_version", after)

logger.info(f"wstunnel {before or 'unknown'} -> {after}")
PYTHON
    then
        rm -f "$backup"
        log "wstunnel binary is current" "$GREEN"
    else
        log "ERROR: wstunnel binary update failed" "$RED"
        log "Restoring the previous binary from ${backup}" "$YELLOW"
        mv -f "$backup" "$binary"
        chmod 755 "$binary"
        exit 1
    fi
}

# ── Summary ──────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Update complete.${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Install location: ${INSTALL_DIR}"
    echo "Version         : ${CURRENT_VERSION:-unknown} -> ${NEW_VERSION}"
    echo ""
    echo "State, secrets and configuration were preserved."
    echo ""

    if (( WAS_RUNNING )); then
        echo "  The data path was stopped for the update and restarted."
        echo ""
    else
        echo "  The data path was not running and was left stopped."
        echo ""
    fi

    echo "  Verify:"
    echo "     frontmatter-api --version"
    echo "     frontmatter-api setup status"
    echo "     frontmatter-api ghost status"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────

main() {
    print_header
    check_root
    check_source
    check_installed
    read_versions
    stop_data_path
    copy_sources
    install_python_deps
    refresh_global_commands
    verify_update
    update_wstunnel_binary
    start_data_path
    print_summary
}

main "$@"
