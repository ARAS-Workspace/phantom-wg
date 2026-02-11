"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Ghost Mode DNS Yardımcı Fonksiyonları
    =====================================
    
    DNS doğrulama, IP kontrolü ve sunucu IP'si alma işlemlerini yönetir.
    Domain A kaydı doğrulaması için araçlar sağlar.

EN: Ghost Mode DNS Utility Functions
    ================================
    
    Manages DNS validation, IP checking and server IP retrieval operations.
    Provides tools for domain A record validation.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from typing import Callable

# Module constants
DNS_VALIDATION_SERVER = "8.8.8.8"
IP_CHECK_SERVICES = [
    "https://install.phantom.tc/ip",
    "https://ipinfo.io/ip",
    "https://api.ipify.org",
    "https://checkip.amazonaws.com"
]


# noinspection PyUnusedLocal
def get_server_ip(run_command_func: Callable, logger) -> str:
    """Retrieve server's public IP address from external services.

    Args:
        run_command_func: Function to execute system commands
        logger: Logger instance for output

    Returns:
        Public IP address of the server

    Raises:
        Exception: If unable to determine server IP from any service
    """
    try:
        for service in IP_CHECK_SERVICES:
            result = run_command_func(["curl", "--ipv4", "-s", service])
            if result["success"] and result["stdout"]:
                ip = result["stdout"].strip()
                if is_valid_ip(ip):
                    return ip

        raise Exception("Failed to determine server IP")
    except:
        raise Exception("Failed to determine server IP")


def is_valid_ip(ip: str) -> bool:
    """Validate IP address format.

    Args:
        ip: IP address string to validate

    Returns:
        True if valid IPv4 address, False otherwise
    """
    try:
        parts = ip.split('.')
        return len(parts) == 4 and all(0 <= int(part) <= 255 for part in parts)
    except (ValueError, AttributeError):
        return False


def _query_dns_record(expected_ip: str, tools: list, host_pattern: str,
                      run_command_func: Callable) -> bool:
    """Query DNS record using multiple tools with fallback.

    Tries dig, nslookup, and host in order. Returns True on first match.

    Args:
        expected_ip: Expected IP address (IPv4 or IPv6)
        tools: List of DNS query commands to try
        host_pattern: Expected pattern in host command output
        run_command_func: Function to execute system commands

    Returns:
        True if any tool confirms the expected IP, False otherwise
    """
    for tool in tools:
        result = run_command_func(tool)
        if result["success"] and result["stdout"]:
            output = result["stdout"].strip()

            if tool[0] == "dig":
                if expected_ip in output:
                    return True
            elif tool[0] == "nslookup":
                for line in output.split('\n'):
                    if "Address:" in line and expected_ip in line:
                        return True
            elif tool[0] == "host":
                if host_pattern in output:
                    return True

    return False


def validate_domain_a_record(domain: str, server_ip: str, run_command_func: Callable, logger) -> bool:
    """Validate that domain A record points to specified IP.

    Args:
        domain: Domain name to validate
        server_ip: Expected IP address
        run_command_func: Function to execute system commands
        logger: Logger instance for output

    Returns:
        True if domain A record matches server_ip, False otherwise
    """
    logger.info(f"Validating A record for {domain} -> {server_ip}")

    tools = [
        ["dig", "+short", domain, f"@{DNS_VALIDATION_SERVER}"],
        ["nslookup", domain, DNS_VALIDATION_SERVER],
        ["host", domain, DNS_VALIDATION_SERVER]
    ]

    if _query_dns_record(server_ip, tools, f"has address {server_ip}", run_command_func):
        logger.info(f"Domain {domain} correctly points to {server_ip}")
        return True

    logger.error(f"Domain {domain} does not point to {server_ip}")
    return False


def validate_domain_aaaa_record(domain: str, server_ipv6: str, run_command_func: Callable, logger) -> bool:
    """Validate that domain AAAA record points to specified IPv6 address.

    This is an optional check — failure does not block Ghost Mode activation.

    Args:
        domain: Domain name to validate
        server_ipv6: Expected IPv6 address from phantom.json
        run_command_func: Function to execute system commands
        logger: Logger instance for output

    Returns:
        True if domain AAAA record matches server_ipv6, False otherwise
    """
    logger.info(f"Validating AAAA record for {domain} -> {server_ipv6}")

    tools = [
        ["dig", "+short", domain, "AAAA", f"@{DNS_VALIDATION_SERVER}"],
        ["nslookup", "-type=AAAA", domain, DNS_VALIDATION_SERVER],
        ["host", "-t", "AAAA", domain, DNS_VALIDATION_SERVER]
    ]

    if _query_dns_record(server_ipv6, tools, f"has IPv6 address {server_ipv6}", run_command_func):
        logger.info(f"Domain {domain} AAAA record correctly points to {server_ipv6}")
        return True

    logger.warning(f"Domain {domain} does not have an AAAA record pointing to {server_ipv6}")
    return False
