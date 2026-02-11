"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Ghost Mode Ağ Yardımcı Fonksiyonları
    ====================================
    
    Komut çalıştırma, dosya işlemleri ve genel ağ araçlarını içerir.
    BaseModule metodları için wrapper fonksiyonlar sağlar.

EN: Ghost Mode Network Utility Functions
    ===================================
    
    Contains command execution, file operations and general network tools.
    Provides wrapper functions for BaseModule methods.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from pathlib import Path
from typing import Dict, Any, List


def run_command(command: List[str], run_command_func) -> Dict[str, Any]:
    """Execute system command via provided function.

    Args:
        command: Command and arguments as list
        run_command_func: Function to execute the command

    Returns:
        Command execution result dictionary
    """
    return run_command_func(command)


def read_json_file(file_path: Path, read_json_func) -> Dict[str, Any]:
    """Read JSON file via provided function.

    Args:
        file_path: Path to JSON file
        read_json_func: Function to read JSON data

    Returns:
        Parsed JSON data as dictionary
    """
    return read_json_func(file_path)


def write_json_file(file_path: Path, data: Dict[str, Any], write_json_func) -> bool:
    """Write data to JSON file via provided function.

    Args:
        file_path: Path to JSON file
        data: Data to write
        write_json_func: Function to write JSON data

    Returns:
        True on success
    """
    return write_json_func(file_path, data)


def get_connection_command(state: Dict[str, Any]) -> str:
    """Generate wstunnel client connection command.

    Args:
        state: State dictionary containing domain and secret

    Returns:
        Complete wstunnel client command string
    """
    domain = state.get("domain", "<DOMAIN>")
    secret = state.get("secret")
    wg_port = state.get("wg_port", 51820)

    return (
        f"wstunnel client --http-upgrade-path-prefix \"{secret}\" "
        f"-L udp://127.0.0.1:{wg_port}:127.0.0.1:{wg_port} "
        f"wss://{domain}:443"
    )


# noinspection PyUnusedLocal
def clean_files(state: Dict[str, Any], logger) -> None:
    """Clean up files created during Ghost Mode setup.

    Args:
        state: State dictionary with files_created list
        logger: Logger instance (unused but required for signature)
    """
    for file_path in state.get("changes", {}).get("files_created", []):
        try:
            Path(file_path).unlink()
        except (OSError, FileNotFoundError):
            pass


def final_cleanup(state_file: Path) -> None:
    """Remove state file during final cleanup.

    Args:
        state_file: Path to state file to remove
    """
    if state_file.exists():
        state_file.unlink()
