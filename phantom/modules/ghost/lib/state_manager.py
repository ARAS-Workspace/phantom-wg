"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Ghost Mode Durum Yönetimi
    =========================
    
    Ghost Mode durumunu yönetir, kaydeder ve geri yükleme işlemlerini sağlar.
    Gizli anahtar üretimi ve state dosyası işlemlerini içerir.

EN: Ghost Mode State Management
    ==========================
    
    Manages Ghost Mode state, saves and provides rollback operations.
    Contains secret generation and state file operations.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import json
import secrets
import string
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Callable

# Module constants
SECRET_LENGTH = 64


def init_state(server_ip: str, domain: str = None, wg_port: int = 51820) -> Dict[str, Any]:
    """Initialize Ghost Mode state with default values.

    Args:
        server_ip: Server's public IP address
        domain: Domain name for Ghost Mode (optional)
        wg_port: WireGuard listening port (default: 51820)

    Returns:
        Initial state dictionary
    """
    secret = generate_secret()

    state = {
        "enabled": False,
        "server_ip": server_ip,
        "domain": domain,
        "secret": secret,
        "wg_port": wg_port,
        "installed_at": datetime.now().isoformat(),
        "changes": {
            "files_created": [],
            "packages_installed": [],
            "services_added": [],
            "firewall_modified": False,
            "wireguard_restricted": False,
            "certificates_created": []
        }
    }
    return state


def load_state(state_file: Path, read_json_func: Callable) -> Dict[str, Any]:
    """Load existing state from file.

    Args:
        state_file: Path to state file
        read_json_func: Function to read JSON data

    Returns:
        Loaded state dictionary or empty dict if failed
    """
    if state_file.exists():
        try:
            return read_json_func(state_file)
        except (json.JSONDecodeError, OSError, IOError):
            return {}
    return {}


def save_state(state_file: Path, state: Dict[str, Any], write_json_func: Callable) -> None:
    """Save current state to file.

    Args:
        state_file: Path to state file
        state: State dictionary to save
        write_json_func: Function to write JSON data
    """
    write_json_func(state_file, state)


def generate_secret() -> str:
    """Generate cryptographically secure random secret.

    Returns:
        Random alphanumeric string of SECRET_LENGTH characters
    """
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(SECRET_LENGTH))


def rollback(ghost_module_instance, logger) -> None:
    """Rollback all Ghost Mode changes and cleanup.

    Args:
        ghost_module_instance: Ghost module instance with state and methods
        logger: Logger instance for output
    """
    try:
        # Delayed import to avoid circular dependency
        from . import wstunnel_utils, firewall_utils, ssl_utils, network_utils

        # noinspection PyProtectedMember
        wstunnel_utils.stop_services(ghost_module_instance._run_command)

        # noinspection PyProtectedMember
        wstunnel_utils.remove_wstunnel(ghost_module_instance.wstunnel_dir, ghost_module_instance._run_command)

        network_utils.clean_files(ghost_module_instance.state, logger)

        # noinspection PyProtectedMember
        firewall_utils.remove_firewall_rules(
            ghost_module_instance.state,
            ghost_module_instance._run_command,
            logger
        )

        # noinspection PyProtectedMember
        ssl_utils.remove_certificates(
            ghost_module_instance.state,
            ghost_module_instance._run_command,
            logger
        )

        network_utils.final_cleanup(ghost_module_instance.state_file)

        logger.info("Rollback completed")
    except Exception as e:
        logger.error(f"Rollback failed: {e}")
