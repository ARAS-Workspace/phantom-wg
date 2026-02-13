"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Casper iOS Servisi - Ghost Mode iOS Configuration Export Core
    ================================================================

    Bu modül, Ghost Mode client konfigürasyonlarını Phantom-WG iOS uygulaması
    için JSON formatında dışa aktarır. Yalnızca stdout'a çıktı verir.

    Ana Bileşenler:
        - CasperIOSService: Ghost Mode iOS konfigürasyonlarını yöneten ana servis sınıfı
        - Ghost durumu kontrolü ve bilgi okuma
        - Phantom API üzerinden client verilerine erişim
        - wstunnel komutunu Ghost API'den alma
        - AllowedIPs hesaplama algoritması (binary tree split, yalnızca IPv4)

    Mimari:
        Servis, Ghost Mode'un aktif olup olmadığını kontrol eder, ardından
        client verilerini ve Ghost bağlantı bilgilerini alarak iOS uyumlu
        bir JSON konfigürasyonu üretir. Tüm çıktı stdout'a verilir.

EN: Casper iOS Service - Ghost Mode iOS Configuration Export Core
    ====================================================

    This module exports Ghost Mode client configurations in JSON format
    for the Phantom-WG iOS application. Only outputs to stdout.

    Key Components:
        - CasperIOSService: Main service class managing Ghost Mode iOS configurations
        - Ghost state checking and information reading
        - Client data access via Phantom API
        - Fetching wstunnel command from Ghost API
        - AllowedIPs calculation algorithm (binary tree split, IPv4 only)

    Architecture:
        The service checks if Ghost Mode is active, then retrieves client
        data and Ghost connection information to generate an iOS-compatible
        JSON configuration. All output goes to stdout.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import re
import json
import ipaddress
from pathlib import Path

# Import PhantomAPI
try:
    from phantom.api.core import PhantomAPI
    from phantom.api.exceptions import ClientNotFoundError

    PHANTOM_API_AVAILABLE = True
except ImportError:
    # Define dummy classes
    class PhantomAPI:
        pass


    class ClientNotFoundError(Exception):
        pass


    PHANTOM_API_AVAILABLE = False


class CasperIOSService:
    def __init__(self):
        """Initialize Casper iOS service.

        Sets up configuration paths and initializes the Phantom API
        connection with graceful fallback if the API is not available.
        """
        # Setup configuration paths
        self.config_dir = Path("/opt/phantom-wg/config")
        self.ghost_state_file = self.config_dir / "ghost-state.json"
        self.phantom_config_file = self.config_dir / "phantom.json"

        # Initialize API
        self.phantom_api = None
        if PHANTOM_API_AVAILABLE:
            try:
                self.phantom_api = PhantomAPI()
            except (AttributeError, TypeError, RuntimeError):
                # API initialization failed
                pass

    def export_client_config(self, username):
        """Export client configuration as iOS JSON to stdout.

        Retrieves and displays the Ghost Mode iOS configuration for
        the specified client, including wstunnel parameters.

        Args:
            username: The username of the client to export configuration for

        Raises:
            Exception: If Ghost Mode is not active, client not found, or API unavailable
        """
        # Check Ghost Mode status
        if not self._is_ghost_active():
            raise Exception(
                "Ghost Mode is not active. Enable it first with: phantom-api ghost enable domain=your-domain.com")

        # Get connection info
        ghost_info = self._get_ghost_info()
        if not ghost_info:
            raise Exception("Unable to read Ghost Mode state")

        # Get client data
        client_data = self._get_client_data(username)
        if not client_data:
            raise Exception(f"Client '{username}' not found")

        # Get wstunnel command
        wstunnel_cmd = self._get_wstunnel_command()

        # Generate configuration
        config = self._generate_ghost_config(client_data, ghost_info)

        # Build iOS JSON
        ios_json = self._build_ios_json(username, config, wstunnel_cmd)
        json_string = json.dumps(ios_json, indent=2, ensure_ascii=False)

        # Output JSON to stdout
        print(json_string)

    def _is_ghost_active(self):
        """Check if Ghost Mode is active.

        Reads the ghost-state.json file to determine if Ghost Mode
        is currently enabled.

        Returns:
            bool: True if Ghost Mode is active, False otherwise
        """
        # Check state file
        if not self.ghost_state_file.exists():
            return False

        try:
            # Read state
            with open(self.ghost_state_file, 'r') as f:
                state = json.load(f)
                return state.get("enabled", False)
        except FileNotFoundError:
            return False
        except (json.JSONDecodeError, KeyError):
            return False

    def _get_ghost_info(self):
        """Get Ghost Mode connection information.

        Reads the ghost-state.json file and extracts connection details
        including domain, server IP, and secret.

        Returns:
            dict: Connection info with 'domain', 'server_ip',
                 and 'secret' keys, or None if unable to read the state file
        """
        try:
            # Read state file
            with open(self.ghost_state_file, 'r') as f:
                state = json.load(f)

            info = {
                "domain": state.get("domain"),
                "server_ip": state.get("server_ip"),
                "secret": state.get("secret")
            }

            return info
        except FileNotFoundError:
            return None
        except (json.JSONDecodeError, KeyError):
            return None

    def _get_wstunnel_command(self):
        """Get wstunnel command from Ghost API.

        Queries the Ghost module via Phantom API to retrieve the
        wstunnel client connection command.

        Returns:
            str: The wstunnel command string, or empty string on error

        Raises:
            Exception: If Phantom API is not available
        """
        # Check API
        if not self.phantom_api:
            raise Exception("Phantom API not available")

        try:
            # Get status
            response = self.phantom_api.execute("ghost", "status")
            if response.success and response.data:
                return response.data.get("connection_command", "")
            return ""
        except (AttributeError, KeyError, TypeError):
            # API error
            return ""

    def _get_client_data(self, client_name):
        """Get client data via Phantom API.

        Retrieves the WireGuard configuration for the specified client
        using the Phantom API's core module.

        Args:
            client_name: The name of the client to retrieve data for

        Returns:
            dict: Client configuration data, or None if client not found

        Raises:
            Exception: If Phantom API is not available or operation fails
        """
        # Check API
        if not self.phantom_api:
            raise Exception("Phantom API not available")

        try:
            # Export client
            response = self.phantom_api.execute("core", "export_client", client_name=client_name)
            if response.success:
                return response.data
            return None
        except ClientNotFoundError:
            # Client not found
            return None
        except Exception as e:
            # Re-raise with context
            raise Exception(f"Failed to get client data: {e}")

    def _generate_ghost_config(self, client_data, ghost_info):
        """Generate Ghost Mode WireGuard configuration.

        Modifies the standard WireGuard configuration for use with Ghost Mode
        by updating the endpoint to localhost and adjusting AllowedIPs.
        Only excludes server IPv4 address from AllowedIPs.

        Args:
            client_data: Dictionary containing client configuration data
            ghost_info: Dictionary containing Ghost Mode connection information

        Returns:
            str: Modified WireGuard configuration for Ghost Mode
        """
        # Extract config
        client_config = client_data.get("config", "")

        # Replace endpoint with localhost
        modified_config = client_config.replace(
            f"Endpoint = {ghost_info.get('server_ip')}:51820",
            "Endpoint = 127.0.0.1:51820"
        )

        # Update AllowedIPs
        allowed_ips_match = re.search(r'AllowedIPs\s*=\s*([^\n]+)', modified_config)
        if allowed_ips_match and ghost_info.get('server_ip'):
            # Get original IPs
            original_allowed_ips = allowed_ips_match.group(1).strip()

            # Calculate new IPs (IPv4 split only)
            new_allowed_ips = self._calculate_allowed_ips(
                original_allowed_ips, ghost_info.get('server_ip')
            )

            # Update config
            modified_config = re.sub(
                r'AllowedIPs\s*=\s*[^\n]+',
                f'AllowedIPs = {", ".join(new_allowed_ips)}',
                modified_config
            )

        return modified_config

    # noinspection PyMethodMayBeStatic
    def _calculate_allowed_ips(self, original_ips, server_ip):
        """Calculate AllowedIPs excluding server IPv4 address.

        Uses a binary tree splitting algorithm to exclude the server's IP
        address from the default route (0.0.0.0/0) to prevent routing loops.
        Only handles IPv4 — no IPv6 calculation.

        Args:
            original_ips: Comma-separated string of original AllowedIPs
            server_ip: The server's IPv4 address to exclude

        Returns:
            list: List of CIDR blocks that exclude the server IP
        """
        # Parse IPs
        ips_list = [ip.strip() for ip in original_ips.split(',')]

        # Check for default route
        has_default_route = any(ip == "0.0.0.0/0" for ip in ips_list)

        # Return if no default route
        if not has_default_route:
            return ips_list

        # Convert server IP
        server_ip_obj = ipaddress.IPv4Address(server_ip)
        server_int = int(server_ip_obj)

        def split_cidr(network, exclude_ip, max_prefix):
            """
            Recursively split a CIDR block to exclude a specific IP.

            Uses binary tree splitting: divides the network in half,
            determines which half contains the excluded IP, and recurses.
            """
            # Return if IP not in network
            if exclude_ip < int(network.network_address) or exclude_ip > int(network.broadcast_address):
                return [str(network)]

            # Exclude single IP
            if network.prefixlen >= max_prefix:
                return []

            # Split network
            networks = list(network.subnets(prefixlen_diff=1))
            result = []

            # Process halves
            for subnet in networks:
                result.extend(split_cidr(subnet, exclude_ip, max_prefix))

            return result

        # IPv4: Split 0.0.0.0/0 excluding server IPv4
        all_ipv4 = ipaddress.IPv4Network("0.0.0.0/0")
        allowed_cidrs = split_cidr(all_ipv4, server_int, 32)

        # Add non-default routes
        for ip in ips_list:
            if ip != "0.0.0.0/0" and ip not in allowed_cidrs:
                allowed_cidrs.append(ip)

        return allowed_cidrs

    # noinspection PyMethodMayBeStatic
    def _parse_wstunnel_command(self, wstunnel_cmd):
        """Parse wstunnel command string into structured parameters.

        Extracts secret, local/remote port, and WebSocket URL from
        the wstunnel client connection command.

        Args:
            wstunnel_cmd: The wstunnel command string from Ghost API

        Returns:
            dict: Parsed wstunnel parameters with 'secret', 'local_port',
                  'remote_host', 'remote_port', and 'url' keys
        """
        # Extract secret from --http-upgrade-path-prefix "..."
        secret_match = re.search(r'--http-upgrade-path-prefix\s+"([^"]+)"', wstunnel_cmd)
        secret = secret_match.group(1) if secret_match else ""

        # Extract local and remote from -L udp://127.0.0.1:PORT:127.0.0.1:PORT
        tunnel_match = re.search(r'-L\s+udp://([^:]+):(\d+):([^:]+):(\d+)', wstunnel_cmd)
        if tunnel_match:
            local_port = int(tunnel_match.group(2))
            remote_host = tunnel_match.group(3)
            remote_port = int(tunnel_match.group(4))
        else:
            local_port = 51820
            remote_host = "127.0.0.1"
            remote_port = 51820

        # Extract WebSocket URL (wss://domain:port at the end)
        url_match = re.search(r'(wss://\S+)', wstunnel_cmd)
        url = url_match.group(1) if url_match else ""

        return {
            "secret": secret,
            "local_port": local_port,
            "remote_host": remote_host,
            "remote_port": remote_port,
            "url": url
        }

    # noinspection PyMethodMayBeStatic
    def _parse_wireguard_config(self, config_text):
        """Parse WireGuard configuration text into a dictionary.

        Extracts all key-value pairs from the WireGuard .conf format.

        Args:
            config_text: WireGuard configuration string in .conf format

        Returns:
            dict: Parsed configuration values
        """
        def extract(pattern, text):
            match = re.search(pattern, text)
            return match.group(1).strip() if match else None

        return {
            "private_key": extract(r'PrivateKey\s*=\s*(.+)', config_text),
            "address": extract(r'Address\s*=\s*(.+)', config_text),
            "dns": extract(r'DNS\s*=\s*(.+)', config_text),
            "mtu": extract(r'MTU\s*=\s*(\d+)', config_text),
            "public_key": extract(r'PublicKey\s*=\s*(.+)', config_text),
            "preshared_key": extract(r'PresharedKey\s*=\s*(.+)', config_text),
            "endpoint": extract(r'Endpoint\s*=\s*(.+)', config_text),
            "allowed_ips": extract(r'AllowedIPs\s*=\s*(.+)', config_text),
            "persistent_keepalive": extract(r'PersistentKeepalive\s*=\s*(\d+)', config_text),
        }

    def _build_ios_json(self, username, ghost_config, wstunnel_cmd):
        """Build iOS-compatible JSON configuration.

        Parses the modified Ghost Mode WireGuard configuration and wstunnel
        command to construct the JSON structure expected by the iOS app.

        Args:
            username: Client username (used as profile name)
            ghost_config: Modified WireGuard configuration string
            wstunnel_cmd: The wstunnel command string from Ghost API

        Returns:
            dict: iOS-compatible configuration dictionary
        """
        # Parse modified config
        parsed = self._parse_wireguard_config(ghost_config)

        # Parse wstunnel command
        wstunnel = self._parse_wstunnel_command(wstunnel_cmd)

        return {
            "v": 1,
            "interface": {
                "address": parsed.get("address"),
                "dns": parsed.get("dns"),
                "mtu": int(parsed.get("mtu")),
                "private_key": parsed.get("private_key"),
            },
            "name": username,
            "peer": {
                "allowed_ips": parsed.get("allowed_ips"),
                "endpoint": parsed.get("endpoint"),
                "persistent_keepalive": int(parsed.get("persistent_keepalive")),
                "preshared_key": parsed.get("preshared_key"),
                "public_key": parsed.get("public_key"),
            },
            "wstunnel": {
                "local_port": wstunnel.get("local_port"),
                "remote_host": wstunnel.get("remote_host"),
                "remote_port": wstunnel.get("remote_port"),
                "secret": wstunnel.get("secret"),
                "url": wstunnel.get("url"),
            },
        }
