#!/opt/phantom-wg/.phantom-venv/bin/python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

MULTIHOP INTERFACE RESTORE SCRIPT
=================================

TR: Sistem yeniden başlatma sonrası Multihop VPN arayüzünü ve policy routing kurallarını otomatik olarak geri yükler
    =======================================================================================================
    
    Bu betik, systemd oneshot servisi olarak çalışarak sistem açılışında Multihop VPN yapılandırmasını
    otomatik olarak restore eder. phantom/modules/multihop/lib/routing_manager.py ile aynı routing
    mantığını kullanarak tutarlılığı sağlar.
    
    Temel Sorumluluklar:
        1. Phantom konfigürasyonundan multihop durumunu kontrol etme
        2. WireGuard VPN arayüzünü (wg_vpn) oluşturma ve yapılandırma
        3. Policy-based routing kurallarını uygulama (rt_tables, ip rule, iptables)
        4. Multihop routing tablosunu (table 100) kurma
        5. NAT/MASQUERADE kurallarını yapılandırma
        6. Sistem ağ yöneticileriyle (systemd-networkd) entegrasyon
        7. Monitor servisini başlatma
        
    Çalışma Akışı:
        - phantom.json'dan multihop durumu okunur
        - Aktif çıkış noktası yapılandırması yüklenir
        - WireGuard arayüzü oluşturulur ve yapılandırılır
        - Routing kuralları uygulanır (peer trafiği main table, diğerleri multihop table)
        - iptables NAT ve FORWARD kuralları eklenir
        - Monitor servisi başlatılır

EN: Automatically restores Multihop VPN interface and policy routing rules after system reboot
    =======================================================================================
    
    This script runs as a systemd oneshot service to automatically restore Multihop VPN
    configuration at system startup. Uses the same routing logic as
    phantom/modules/multihop/lib/routing_manager.py to ensure consistency.
    
    Core Responsibilities:
        1. Check multihop state from Phantom configuration
        2. Create and configure WireGuard VPN interface (wg_vpn)
        3. Apply policy-based routing rules (rt_tables, ip rule, iptables)
        4. Setup multihop routing table (table 100)
        5. Configure NAT/MASQUERADE rules
        6. Integrate with system network managers (systemd-networkd)
        7. Start monitor service
        
    Workflow:
        - Read multihop state from phantom.json
        - Load active exit configuration
        - Create and configure WireGuard interface
        - Apply routing rules (peer traffic to main table, others to multihop table)
        - Add iptables NAT and FORWARD rules
        - Start monitor service

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import json
import subprocess
import sys
import logging
import time
from pathlib import Path

# Paths
CONFIG_PATH = Path("/opt/phantom-wg/config/phantom.json")
EXIT_CONFIGS_DIR = Path("/opt/phantom-wg/exit_configs")
RT_TABLES_FILE = Path("/etc/iproute2/rt_tables")

# Constants
MULTIHOP_TABLE_ID = "100"
MULTIHOP_TABLE_NAME = "multihop"
PEER_TRAFFIC_PRIORITY = "99"
MULTIHOP_TRAFFIC_PRIORITY = "100"

# Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("multihop-restore")


def run_command(cmd: list, check: bool = True) -> dict:
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check
        )
        return {
            "success": True,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode
        }
    except subprocess.CalledProcessError as e:
        return {
            "success": False,
            "stdout": e.stdout,
            "stderr": e.stderr,
            "returncode": e.returncode,
            "error": str(e)
        }
    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }


def ensure_routing_table_exists():
    try:
        if RT_TABLES_FILE.exists():
            with open(RT_TABLES_FILE, 'r') as f:
                rt_content = f.read()
            if f"{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}" not in rt_content:
                with open(RT_TABLES_FILE, 'a') as f:
                    f.write(f"\n{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}\n")
                logger.info("Added multihop table to rt_tables")
        else:
            RT_TABLES_FILE.parent.mkdir(parents=True, exist_ok=True)
            with open(RT_TABLES_FILE, 'w') as f:
                f.write(f"{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}\n")
            logger.info("Created rt_tables with multihop entry")
    except Exception as e:
        logger.error(f"Failed to ensure routing table exists: {e}")
        # Alternative method
        run_command(["sh", "-c",
                     f"grep -q '^{MULTIHOP_TABLE_ID}[[:space:]]\\+{MULTIHOP_TABLE_NAME}' {RT_TABLES_FILE} || echo '{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}' >> {RT_TABLES_FILE}"])


def check_interface_exists(interface_name: str) -> bool:
    result = run_command(["ip", "link", "show", interface_name], check=False)
    return result["success"] and result["returncode"] == 0


def extract_vpn_ip(config_path: Path) -> str:
    with open(config_path) as f:
        for line in f:
            if line.strip().startswith("Address"):
                return line.split("=")[1].strip()
    raise ValueError("No Address found in VPN config")


# noinspection DuplicatedCode
def clean_vpn_config(config_content: str) -> str:
    lines = []
    current_section = None

    # Valid parameters
    interface_valid_params = {'PrivateKey', 'ListenPort', 'FwMark'}
    peer_valid_params = {'PublicKey', 'PresharedKey', 'AllowedIPs', 'Endpoint', 'PersistentKeepalive'}

    for line in config_content.split('\n'):
        line = line.strip()

        # Track section
        if line.startswith('[Interface]'):
            current_section = 'interface'
            lines.append(line)
        elif line.startswith('[Peer]'):
            current_section = 'peer'
            lines.append(line)
        elif line and '=' in line:
            # Extract parameter
            param_name = line.split('=')[0].strip()

            # Keep valid parameters
            if current_section == 'interface' and param_name in interface_valid_params:
                lines.append(line)
            elif current_section == 'peer' and param_name in peer_valid_params:
                lines.append(line)
            # Skip other parameters
        elif not line or line.startswith('#'):
            # Keep empty lines
            lines.append(line)

    return '\n'.join(lines)


def cleanup_existing_rules(wg_network: str, wg_interface: str, vpn_interface: str):
    logger.info("Cleaning up existing rules...")

    cleanup_commands = [
        ["sh", "-c",
         f"ip rule del from {wg_network} to {wg_network} table main priority {PEER_TRAFFIC_PRIORITY} 2>/dev/null || true"],
        ["sh", "-c",
         f"ip rule del from {wg_network} table {MULTIHOP_TABLE_NAME} priority {MULTIHOP_TRAFFIC_PRIORITY} 2>/dev/null || true"],
        ["sh", "-c", f"ip route del default table {MULTIHOP_TABLE_NAME} 2>/dev/null || true"],
        ["sh", "-c",
         f"iptables -t nat -D POSTROUTING -s {wg_network} -o {vpn_interface} -j MASQUERADE 2>/dev/null || true"],
        ["sh", "-c", f"iptables -D FORWARD -i {wg_interface} -o {vpn_interface} -j ACCEPT 2>/dev/null || true"],
        ["sh", "-c",
         f"iptables -D FORWARD -i {vpn_interface} -o {wg_interface} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true"],
        ["sh", "-c",
         f"iptables -D FORWARD -i {wg_interface} -o {wg_interface} -s {wg_network} -d {wg_network} -j ACCEPT 2>/dev/null || true"]
    ]

    for cmd in cleanup_commands:
        run_command(cmd, check=False)


def apply_routing_rules(wg_network: str, wg_interface: str, vpn_interface: str) -> bool:
    logger.info("Applying routing rules...")

    # Enable forwarding
    result = run_command(["sh", "-c", "echo 1 > /proc/sys/net/ipv4/ip_forward"])
    if not result["success"]:
        logger.error("Failed to enable IP forwarding")
        return False

    # Setup commands
    setup_commands = [
        # IP rules
        ["ip", "rule", "add", "from", wg_network, "to", wg_network, "table", "main", "priority", PEER_TRAFFIC_PRIORITY],
        ["ip", "rule", "add", "from", wg_network, "table", MULTIHOP_TABLE_NAME, "priority", MULTIHOP_TRAFFIC_PRIORITY],
        ["ip", "route", "add", "default", "dev", vpn_interface, "table", MULTIHOP_TABLE_NAME],
        # NAT
        ["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", wg_network, "-o", vpn_interface, "-j", "MASQUERADE"],
        # FORWARD rules
        ["iptables", "-A", "FORWARD", "-i", wg_interface, "-o", vpn_interface, "-j", "ACCEPT"],
        ["iptables", "-A", "FORWARD", "-i", vpn_interface, "-o", wg_interface, "-m", "state", "--state",
         "RELATED,ESTABLISHED", "-j", "ACCEPT"],
        ["iptables", "-A", "FORWARD", "-i", wg_interface, "-o", wg_interface, "-s", wg_network, "-d", wg_network, "-j",
         "ACCEPT"]
    ]

    success_count = 0
    for cmd in setup_commands:
        result = run_command(cmd, check=False)
        if result["success"]:
            success_count += 1
            logger.info(f"Applied: {' '.join(cmd)}")
        else:
            logger.error(f"Failed: {' '.join(cmd)} - {result.get('stderr', '')}")

    # Flush cache
    run_command(["ip", "route", "flush", "cache"])

    # Check success count
    if success_count < len(setup_commands) - 2:
        logger.error(f"Only {success_count}/{len(setup_commands)} routing commands succeeded")
        return False

    return True


def restore_multihop_interface() -> bool:
    try:
        # Load config
        if not CONFIG_PATH.exists():
            logger.error("Configuration file not found")
            return False

        with open(CONFIG_PATH) as f:
            config = json.load(f)

        # Check state
        multihop = config.get("multihop", {})
        if not multihop.get("enabled"):
            logger.info("Multihop is not enabled, skipping restore")
            return True

        active_exit = multihop.get("active_exit")
        if not active_exit:
            logger.error("No active exit found in configuration")
            return False

        logger.info(f"Restoring multihop interface for exit: {active_exit}")

        # Get interface name
        vpn_interface = multihop.get("vpn_interface_name", "wg_vpn")
        logger.info(f"VPN interface name: {vpn_interface}")

        # Get config
        wg_config = config.get("wireguard", {})
        wg_network = wg_config.get("network", "10.8.0.0/24")
        wg_interface = wg_config.get("interface", "wg_main")

        logger.info(f"WireGuard network: {wg_network}, interface: {wg_interface}")

        # Check interface
        if check_interface_exists(vpn_interface):
            logger.info(f"Interface {vpn_interface} already exists, checking routing...")
            # Ensure routing
            ensure_routing_table_exists()
            cleanup_existing_rules(wg_network, wg_interface, vpn_interface)
            if not apply_routing_rules(wg_network, wg_interface, vpn_interface):
                logger.error("Failed to apply routing rules")
                return False
            return True

        # Find config
        vpn_config_path = EXIT_CONFIGS_DIR / f"{active_exit}.conf"
        if not vpn_config_path.exists():
            logger.error(f"VPN config not found: {vpn_config_path}")
            return False

        # Extract IP
        vpn_ip = extract_vpn_ip(vpn_config_path)
        logger.info(f"Extracted VPN IP: {vpn_ip}")

        # Ensure table
        ensure_routing_table_exists()

        # Clean existing rules
        cleanup_existing_rules(wg_network, wg_interface, vpn_interface)

        # Create interface
        logger.info(f"Creating WireGuard interface: {vpn_interface}")
        result = run_command(["ip", "link", "add", vpn_interface, "type", "wireguard"])
        if not result["success"]:
            logger.error(f"Failed to create interface: {result.get('stderr', '')}")
            return False

        # Read config
        with open(vpn_config_path) as f:
            config_content = f.read()

        clean_config = clean_vpn_config(config_content)

        # Write config
        wg_config_path = Path(f"/etc/wireguard/{vpn_interface}.conf")
        wg_config_path.parent.mkdir(parents=True, exist_ok=True)
        with open(wg_config_path, 'w') as f:
            f.write(clean_config)

        # Configure interface
        logger.info("Configuring interface...")
        result = run_command(["wg", "setconf", vpn_interface, str(wg_config_path)])
        if not result["success"]:
            logger.error(f"Failed to configure interface: {result.get('stderr', '')}")
            return False

        # Add IP
        logger.info(f"Adding IP address: {vpn_ip}")
        result = run_command(["ip", "-4", "address", "add", vpn_ip, "dev", vpn_interface])
        if not result["success"]:
            logger.error(f"Failed to add IP address: {result.get('stderr', '')}")
            return False

        # Set MTU
        logger.info("Bringing up interface...")
        result = run_command(["ip", "link", "set", "mtu", "1420", "up", "dev", vpn_interface])
        if not result["success"]:
            logger.error(f"Failed to bring up interface: {result.get('stderr', '')}")
            return False

        # Apply routing
        if not apply_routing_rules(wg_network, wg_interface, vpn_interface):
            logger.error("Failed to apply routing rules")
            return False

        # Reload networkd
        logger.info("Reloading systemd-networkd...")
        run_command(["networkctl", "reload"], check=False)

        # Reconfigure
        logger.info("Reconfiguring interface for systemd-networkd...")
        run_command(["networkctl", "reconfigure", vpn_interface], check=False)

        # Wait for networkd
        time.sleep(2)

        # Verify rules
        result = run_command(["ip", "rule", "show"])
        if result["success"] and "table 100" in result["stdout"]:
            logger.info("Routing rules verified successfully")
        else:
            logger.warning("Could not verify routing rules")

        # Check status
        result = run_command(["wg", "show", vpn_interface])
        if result["success"]:
            logger.info("WireGuard interface configured successfully")
        else:
            logger.warning("Could not verify WireGuard status")

        logger.info("Multihop interface and routing restored successfully")

        # Start monitor
        logger.info("Starting multihop monitor service...")
        try:
            # Check monitor
            result = run_command(["systemctl", "is-active", "phantom-multihop-monitor.service"], check=False)
            if result["stdout"].strip() == "active":
                logger.info("Monitor service is already running")
            else:
                # Start monitor
                result = run_command(["systemctl", "start", "phantom-multihop-monitor.service"])
                if result["success"]:
                    logger.info("Monitor service started successfully")
                else:
                    logger.warning(f"Failed to start monitor service: {result.get('stderr', '')}")
        except Exception as e:
            logger.warning(f"Could not start monitor service: {e}")

        return True

    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return False


if __name__ == "__main__":
    success = restore_multihop_interface()
    sys.exit(0 if success else 1)
