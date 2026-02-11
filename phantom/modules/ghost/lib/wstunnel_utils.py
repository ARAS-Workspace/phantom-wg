"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Ghost Mode wstunnel Yardımcı Fonksiyonları
    ==========================================
    
    wstunnel binary kurulumu, systemd servis yönetimi ve WebSocket
    tünelleme yapılandırmasını sağlar.

EN: Ghost Mode wstunnel Utility Functions
    =====================================
    
    Provides wstunnel binary installation, systemd service management
    and WebSocket tunneling configuration.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import shutil
import time
from pathlib import Path
from typing import Callable, Dict, Any
from textwrap import dedent

# Module constants
WSTUNNEL_VERSION = "v10.5.2"
WSTUNNEL_VERSION_NUM = "10.5.2"


# noinspection PyUnusedLocal
def install_wstunnel(wstunnel_dir: Path, state: Dict[str, Any],
                     run_command_func: Callable, logger) -> bool:
    """Install wstunnel binary for the system architecture.

    Args:
        wstunnel_dir: Directory to install wstunnel
        state: State dictionary to track changes
        run_command_func: Function to execute system commands
        logger: Logger instance (unused but required for signature)

    Returns:
        True on successful installation

    Raises:
        ServiceError: If download or extraction fails
    """
    arch_result = run_command_func(["uname", "-m"])
    arch = arch_result["stdout"].strip() if arch_result["success"] else "x86_64"

    # Map uname output to GitHub release architecture names
    arch_map = {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64"
    }

    arch = arch_map.get(arch, "amd64")

    filename = f"wstunnel_{WSTUNNEL_VERSION_NUM}_linux_{arch}.tar.gz"
    download_url = f"https://github.com/erebe/wstunnel/releases/download/{WSTUNNEL_VERSION}/{filename}"

    wstunnel_dir.mkdir(exist_ok=True, parents=True)

    download_cmd = [
        "wget", "-q", "-O", f"/tmp/{filename}", download_url
    ]

    result = run_command_func(download_cmd)
    if not result["success"]:
        # Fallback to curl if wget unavailable
        result = run_command_func([
            "curl", "-L", "-o", f"/tmp/{filename}", download_url
        ])
        if not result["success"]:
            from phantom.api.exceptions import ServiceError
            raise ServiceError("Failed to download wstunnel")

    extract_cmd = [
        "tar", "-xzf", f"/tmp/{filename}",
        "-C", str(wstunnel_dir)
    ]

    result = run_command_func(extract_cmd)
    if not result["success"]:
        from phantom.api.exceptions import ServiceError
        raise ServiceError("Failed to extract wstunnel")

    wstunnel_bin = wstunnel_dir / "wstunnel"
    if wstunnel_bin.exists():
        run_command_func(["chmod", "+x", str(wstunnel_bin)])
    else:
        from phantom.api.exceptions import ServiceError
        raise ServiceError("wstunnel binary not found after extraction")

    run_command_func(["rm", "-f", f"/tmp/{filename}"])

    state["changes"]["packages_installed"].append("wstunnel")
    return True


def configure_wstunnel(state: Dict[str, Any], run_command_func: Callable) -> bool:
    """Configure wstunnel systemd service with SSL.

    Args:
        state: State dictionary containing secret and domain
        run_command_func: Function to execute system commands

    Returns:
        True on successful configuration
    """
    secret = state.get("secret")
    domain = state.get("domain")
    wg_port = state.get("wg_port", 51820)
    cert_path = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    key_path = f"/etc/letsencrypt/live/{domain}/privkey.pem"

    # Build wstunnel server command with SSL certificates
    exec_cmd = (
        f"/opt/wstunnel/wstunnel server "
        f"--restrict-http-upgrade-path-prefix \"{secret}\" "
        f"--restrict-to 127.0.0.1:{wg_port} "
        f"--tls-certificate \"{cert_path}\" "
        f"--tls-private-key \"{key_path}\" "
        f"wss://[::]:443"
    )

    service_content = dedent(f"""
        [Unit]
        Description=wstunnel WebSocket Tunnel Server for Ghost Mode
        After=network.target

        [Service]
        Type=simple
        ExecStart={exec_cmd}
        Restart=always
        RestartSec=5
        StandardOutput=journal
        StandardError=journal
        SyslogIdentifier=wstunnel
        User=root
        LimitNOFILE=65535

        # Security
        NoNewPrivileges=true
        PrivateTmp=true
        ProtectSystem=strict
        ProtectHome=true
        ReadWritePaths=/opt/wstunnel

        [Install]
        WantedBy=multi-user.target
    """).strip()

    service_file = Path("/etc/systemd/system/wstunnel.service")
    with open(service_file, 'w') as f:
        f.write(service_content)

    state["changes"]["files_created"].append(str(service_file))
    state["changes"]["services_added"].append("wstunnel")

    run_command_func(["systemctl", "daemon-reload"])

    return True


def start_services(run_command_func: Callable) -> bool:
    """Start wstunnel systemd service.

    Args:
        run_command_func: Function to execute system commands

    Returns:
        True if service started successfully

    Raises:
        ServiceError: If service fails to start
    """
    run_command_func(["systemctl", "enable", "wstunnel"])
    start_result = run_command_func(["systemctl", "start", "wstunnel"])

    if not start_result["success"]:
        from phantom.api.exceptions import ServiceError
        raise ServiceError("Failed to start wstunnel service")

    # Wait for service initialization
    time.sleep(2)

    status_result = run_command_func(["systemctl", "is-active", "wstunnel"])
    if status_result["stdout"].strip() != "active":
        from phantom.api.exceptions import ServiceError
        raise ServiceError("wstunnel service failed to start")

    return True


def stop_services(run_command_func: Callable):
    """Stop and disable wstunnel service.

    Args:
        run_command_func: Function to execute system commands
    """
    run_command_func(["systemctl", "stop", "wstunnel"])
    run_command_func(["systemctl", "disable", "wstunnel"])

    # Ensure all wstunnel processes terminated
    run_command_func(["pkill", "-f", "wstunnel"])

    run_command_func(["killall", "wstunnel"], capture_output=False)

    time.sleep(2)


def remove_wstunnel(wstunnel_dir: Path, run_command_func: Callable):
    """Remove wstunnel binary and service files.

    Args:
        wstunnel_dir: Directory containing wstunnel
        run_command_func: Function to execute system commands
    """
    if wstunnel_dir.exists():
        shutil.rmtree(wstunnel_dir)

    service_file = Path("/etc/systemd/system/wstunnel.service")
    if service_file.exists():
        service_file.unlink()

    run_command_func(["systemctl", "daemon-reload"])


def check_service(service: str, run_command_func: Callable) -> bool:
    """Check if systemd service is active.

    Args:
        service: Service name to check
        run_command_func: Function to execute system commands

    Returns:
        True if service is active, False otherwise
    """
    result = run_command_func(["systemctl", "is-active", service])
    return result["stdout"].strip() == "active" if result["success"] else False
