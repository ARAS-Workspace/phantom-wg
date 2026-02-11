"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Ghost Mode Güvenlik Duvarı Yardımcı Fonksiyonları
    ===================================================
    
    UFW ve iptables güvenlik duvarı kurallarını yönetir. Port açma/kapama,
    WireGuard localhost kısıtlaması ve Ghost Mode güvenlik yapılandırmalarını
    sağlar.

EN: Ghost Mode Firewall Utility Functions
    =====================================
    
    Manages UFW and iptables firewall rules. Provides port opening/closing,
    WireGuard localhost restriction and Ghost Mode security configurations.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from typing import Callable, Dict, Any


# noinspection PyUnusedLocal
def configure_firewall(state: Dict[str, Any], run_command_func: Callable, logger,
                       server_ipv6: str = None) -> bool:
    """Configure firewall rules for Ghost Mode operation.

    Args:
        state: State dictionary to track changes
        run_command_func: Function to execute system commands
        logger: Logger instance for output
        server_ipv6: Server IPv6 address (if available, adds ip6tables rules)

    Returns:
        True on successful configuration
    """
    wg_port = str(state.get("wg_port", 51820))
    ufw_status = run_command_func(["ufw", "status"])

    if "Status: active" in ufw_status.get("stdout", ""):
        firewall_rules = [
            ["ufw", "allow", "443/tcp"],  # wstunnel HTTPS
        ]

        # Restrict WireGuard to localhost for security
        run_command_func(["ufw", "delete", "allow", f"{wg_port}/udp"])
        wireguard_restrict = ["ufw", "allow", "from", "127.0.0.1", "to", "any",
                              "port", wg_port, "proto", "udp"]
        result = run_command_func(wireguard_restrict)
        if result["success"]:
            state["changes"]["wireguard_restricted"] = True

        for rule in firewall_rules:
            run_command_func(rule)

        state["changes"]["firewall_modified"] = True

    # Add iptables rules for non-UFW systems
    iptables_rules = [
        ["iptables", "-A", "INPUT", "-p", "tcp", "--dport", "443", "-j", "ACCEPT"],
    ]

    # Localhost-only WireGuard access
    iptables_restrict = [
        ["iptables", "-A", "INPUT", "-p", "udp", "--dport", wg_port, "-s", "127.0.0.1", "-j", "ACCEPT"],
        ["iptables", "-A", "INPUT", "-p", "udp", "--dport", wg_port, "-j", "DROP"]
    ]

    for rule in iptables_rules:
        run_command_func(rule)

    for rule in iptables_restrict:
        run_command_func(rule)

    # Add ip6tables rules when server has IPv6
    if server_ipv6:
        ip6tables_rules = [
            ["ip6tables", "-A", "INPUT", "-p", "tcp", "--dport", "443", "-j", "ACCEPT"],
            ["ip6tables", "-A", "INPUT", "-p", "udp", "--dport", wg_port, "-s", "::1", "-j", "ACCEPT"],
            ["ip6tables", "-A", "INPUT", "-p", "udp", "--dport", wg_port, "-j", "DROP"]
        ]

        for rule in ip6tables_rules:
            run_command_func(rule)

        state["changes"]["ipv6_firewall_configured"] = True

    return True


def remove_firewall_rules(state: Dict[str, Any], run_command_func: Callable, logger):
    """Remove Ghost Mode firewall rules and restore original configuration.

    Args:
        state: State dictionary tracking changes
        run_command_func: Function to execute system commands
        logger: Logger instance for output
    """
    if not state.get("changes", {}).get("firewall_modified", False):
        return

    wg_port = str(state.get("wg_port", 51820))
    ufw_status = run_command_func(["ufw", "status"])

    if "Status: active" in ufw_status.get("stdout", ""):
        logger.info("Removing Ghost Mode firewall rules...")

        run_command_func(["ufw", "delete", "allow", "443/tcp"])

        # Restore WireGuard to open access
        delete_result = run_command_func([
            "ufw", "--force", "delete", "allow", "from", "127.0.0.1",
            "to", "any", "port", wg_port, "proto", "udp"
        ])

        if delete_result["success"]:
            logger.info("Removed localhost-only WireGuard rule")

        allow_result = run_command_func(["ufw", "allow", f"{wg_port}/udp"])
        if allow_result["success"]:
            logger.info("Restored WireGuard port to open access")

        run_command_func(["ufw", "reload"])

    # Clean up iptables rules
    iptables_rules = [
        ["iptables", "-D", "INPUT", "-p", "tcp", "--dport", "443", "-j", "ACCEPT"],
        ["iptables", "-D", "INPUT", "-p", "udp", "--dport", wg_port, "-s", "127.0.0.1", "-j", "ACCEPT"],
        ["iptables", "-D", "INPUT", "-p", "udp", "--dport", wg_port, "-j", "DROP"]
    ]

    for rule in iptables_rules:
        run_command_func(rule)

    # Clean up ip6tables rules
    if state.get("changes", {}).get("ipv6_firewall_configured", False):
        ip6tables_rules = [
            ["ip6tables", "-D", "INPUT", "-p", "tcp", "--dport", "443", "-j", "ACCEPT"],
            ["ip6tables", "-D", "INPUT", "-p", "udp", "--dport", wg_port, "-s", "::1", "-j", "ACCEPT"],
            ["ip6tables", "-D", "INPUT", "-p", "udp", "--dport", wg_port, "-j", "DROP"]
        ]

        for rule in ip6tables_rules:
            run_command_func(rule)
