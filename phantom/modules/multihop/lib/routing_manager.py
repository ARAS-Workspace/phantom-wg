"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Multihop Modülü Yönlendirme Yöneticisi
    =======================================

    IP yönlendirme tablolarını yönetir, policy routing kurallarını yapılandırır,
    iptables NAT/FORWARD kurallarını uygular ve trafik akışını kontrol eder.

EN: Multihop Module Routing Manager
    ================================

    Manages IP routing tables, configures policy routing rules,
    applies iptables NAT/FORWARD rules and controls traffic flow.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import time
from pathlib import Path
from typing import Dict, Any
from textwrap import dedent

from .common_tools import (
    SYSTEMD_NETWORK_DIR, RT_TABLES_FILE, MULTIHOP_TABLE_ID,
    MULTIHOP_TABLE_NAME, PEER_TRAFFIC_PRIORITY, MULTIHOP_TRAFFIC_PRIORITY,
    NETWORKD_SERVICE_NAME, SERVICE_START_DELAY, DEFAULT_MAIN_INTERFACE, build_networkd_config_path,
)


class RoutingManager:

    def __init__(self, config: Dict[str, Any], logger, run_command_func):
        self.config = config
        self.logger = logger
        self._run_command = run_command_func

    def create_networkd_routing_policy(self, vpn_interface: str, wg_network: str) -> Dict[str, Any]:
        try:
            networkd_dir = Path(SYSTEMD_NETWORK_DIR)
            networkd_dir.mkdir(parents=True, exist_ok=True)

            network_config = dedent(f"""
                # Phantom-WG Multihop Routing Policy
                # Auto-generated - Do not edit manually
                [Match]
                Name={vpn_interface}

                [Network]
                ConfigureWithoutCarrier=yes
                KeepConfiguration=yes

                [RoutingPolicyRule]
                # Rule 1: Keep peer-to-peer traffic in main table
                From={wg_network}
                To={wg_network}
                Table=main
                Priority={PEER_TRAFFIC_PRIORITY}

                [RoutingPolicyRule]
                # Rule 2: Route all other traffic through multihop table
                From={wg_network}
                Table={MULTIHOP_TABLE_ID}
                Priority={MULTIHOP_TRAFFIC_PRIORITY}

                [Route]
                # Default route for multihop table
                Destination=0.0.0.0/0
                Table={MULTIHOP_TABLE_ID}
                Scope=global
                """).strip()

            network_file = Path(build_networkd_config_path(vpn_interface))
            with open(network_file, 'w') as f:
                f.write(network_config)

            # Create routing table entry if not exists
            self._ensure_routing_table_exists()

            # Check if systemd-networkd is running
            check_result = self._run_command(["systemctl", "is-active", NETWORKD_SERVICE_NAME])

            if check_result["stdout"].strip() != "active":
                self._run_command(["systemctl", "enable", NETWORKD_SERVICE_NAME])
                self._run_command(["systemctl", "start", NETWORKD_SERVICE_NAME])
                time.sleep(SERVICE_START_DELAY)

            # Reload systemd-networkd
            reload_result = self._run_command(["networkctl", "reload"])
            if not reload_result["success"]:
                self._run_command(["systemctl", "restart", NETWORKD_SERVICE_NAME])
                time.sleep(SERVICE_START_DELAY)

            # Force reconfigure the interface
            self._run_command(["networkctl", "reconfigure", vpn_interface])

            return {"success": True}

        except Exception as e:
            self.logger.error(f"Failed to create networkd routing policy: {e}")
            return {"success": False, "error": str(e)}

    def apply_routing_rules_immediately(self, wg_network: str, vpn_interface: str) -> Dict[str, Any]:
        try:
            # Ensure routing table exists
            self._ensure_routing_table_exists()

            # Remove existing rules to avoid duplicates (with error suppression)
            self._run_command(["sh", "-c",
                               f"ip rule del from {wg_network} to {wg_network} table main priority {PEER_TRAFFIC_PRIORITY} 2>/dev/null || true"])
            self._run_command(["sh", "-c",
                               f"ip rule del from {wg_network} table {MULTIHOP_TABLE_NAME} priority {MULTIHOP_TRAFFIC_PRIORITY} 2>/dev/null || true"])

            # Add policy rules
            self._run_command(["ip", "rule", "add", "from", wg_network, "to", wg_network, "table", "main", "priority",
                               str(PEER_TRAFFIC_PRIORITY)])
            self._run_command(["ip", "rule", "add", "from", wg_network, "table", MULTIHOP_TABLE_NAME, "priority",
                               str(MULTIHOP_TRAFFIC_PRIORITY)])

            # Add default route to multihop table
            self._run_command(["ip", "route", "del", "default", "table", MULTIHOP_TABLE_NAME])
            self._run_command(["ip", "route", "add", "default", "dev", vpn_interface, "table", MULTIHOP_TABLE_NAME])

            # Flush route cache
            self._run_command(["ip", "route", "flush", "cache"])

            return {"success": True}

        except Exception as e:
            self.logger.error(f"Failed to apply routing rules immediately: {e}")
            return {"success": False, "error": str(e)}

    def setup_routing_rules_manual(self, wg_network: str, vpn_interface: str) -> Dict[str, Any]:
        try:
            wg_config = self.config.get("wireguard", {})
            wg_interface_name = wg_config.get("interface", DEFAULT_MAIN_INTERFACE)

            # Pre-setup: ensure multihop table exists
            self._ensure_routing_table_exists()

            # Cleanup existing rules to avoid duplicates
            cleanup_commands = [
                ["sh", "-c",
                 f"ip rule del from {wg_network} to {wg_network} table main priority {PEER_TRAFFIC_PRIORITY} 2>/dev/null || true"],
                ["sh", "-c",
                 f"ip rule del from {wg_network} table {MULTIHOP_TABLE_NAME} priority {MULTIHOP_TRAFFIC_PRIORITY} 2>/dev/null || true"],
                ["sh", "-c", f"ip route del default table {MULTIHOP_TABLE_NAME} 2>/dev/null || true"],
                ["sh", "-c",
                 f"iptables -t nat -D POSTROUTING -s {wg_network} -o {vpn_interface} -j MASQUERADE 2>/dev/null || true"],
                ["sh", "-c",
                 f"iptables -D FORWARD -i {wg_interface_name} -o {vpn_interface} -j ACCEPT 2>/dev/null || true"],
                ["sh", "-c",
                 f"iptables -D FORWARD -i {vpn_interface} -o {wg_interface_name} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true"]
            ]

            # Run cleanup commands (ignore errors)
            for cmd in cleanup_commands:
                self._run_command(cmd)

            # Setup commands
            setup_commands = [
                ["sh", "-c", "echo 1 > /proc/sys/net/ipv4/ip_forward"],
                ["ip", "rule", "add", "from", wg_network, "to", wg_network, "table", "main", "priority",
                 str(PEER_TRAFFIC_PRIORITY)],
                ["ip", "rule", "add", "from", wg_network, "table", MULTIHOP_TABLE_NAME, "priority",
                 str(MULTIHOP_TRAFFIC_PRIORITY)],
                ["ip", "route", "add", "default", "dev", vpn_interface, "table", MULTIHOP_TABLE_NAME],
                ["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", wg_network, "-o", vpn_interface, "-j",
                 "MASQUERADE"],
                ["iptables", "-A", "FORWARD", "-i", wg_interface_name, "-o", vpn_interface, "-j", "ACCEPT"],
                ["iptables", "-A", "FORWARD", "-i", vpn_interface, "-o", wg_interface_name, "-m", "state", "--state",
                 "RELATED,ESTABLISHED", "-j", "ACCEPT"],
                ["iptables", "-A", "FORWARD", "-i", wg_interface_name, "-o", wg_interface_name, "-s", wg_network, "-d",
                 wg_network, "-j", "ACCEPT"]
            ]

            success_count = 0
            failed_commands = []

            for cmd in setup_commands:
                result = self._run_command(cmd)
                if result["success"]:
                    success_count += 1
                else:
                    # Track failed commands for reporting
                    cmd_str = " ".join(cmd) if isinstance(cmd, list) else cmd
                    error = result.get("error", "Unknown error")
                    self.logger.error(f"Failed command: {cmd_str} - Error: {error}")
                    failed_commands.append(f"{cmd_str}: {error}")

            # Allow up to 2 failures (some cleanup commands may fail normally)
            if success_count < len(setup_commands) - 2:
                return {
                    "success": False,
                    "error": f"Failed to execute firewall rules. {len(failed_commands)} commands failed",
                    "failed_commands": failed_commands
                }

            return {"success": True}

        except Exception as e:
            self.logger.error(f"Failed to setup routing rules manually: {e}")
            return {"success": False, "error": str(e)}

    def remove_networkd_routing_policy(self, vpn_interface: str) -> bool:
        try:
            network_file = Path(build_networkd_config_path(vpn_interface))
            if network_file.exists():
                network_file.unlink()

                check_result = self._run_command(["systemctl", "is-active", NETWORKD_SERVICE_NAME])
                if check_result["stdout"].strip() == "active":
                    reload_result = self._run_command(["networkctl", "reload"])
                    if not reload_result["success"]:
                        self._run_command(["systemctl", "restart", NETWORKD_SERVICE_NAME])

            return True
        except Exception as e:
            self.logger.error(f"Failed to remove networkd routing policy: {e}")
            return False

    def _ensure_routing_table_exists(self):
        try:
            rt_tables_file = Path(RT_TABLES_FILE)
            if rt_tables_file.exists():
                with open(rt_tables_file, 'r') as f:
                    rt_content = f.read()
                if f"{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}" not in rt_content:
                    with open(rt_tables_file, 'a') as f:
                        f.write(f"\n{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}\n")
            else:
                # Create rt_tables file if it doesn't exist
                rt_tables_file.parent.mkdir(parents=True, exist_ok=True)
                with open(rt_tables_file, 'w') as f:
                    f.write(f"{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}\n")
        except Exception as e:
            self.logger.error(f"Failed to ensure routing table exists: {e}")
            # Try alternative method
            self._run_command(["sh", "-c",
                               f"grep -q '^{MULTIHOP_TABLE_ID}[[:space:]]\\+{MULTIHOP_TABLE_NAME}' {RT_TABLES_FILE} || echo '{MULTIHOP_TABLE_ID} {MULTIHOP_TABLE_NAME}' >> {RT_TABLES_FILE}"])
