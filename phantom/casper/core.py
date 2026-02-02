"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Casper Servisi - Ghost Mode Configuration Export Core
    ================================================================
    
    Bu modül, Ghost Mode client konfigürasyonlarını dışa aktarmak için temel
    servisi sağlar. Yalnızca stdout'a çıktı verir.

    Ana Bileşenler:
        - CasperService: Ghost Mode konfigürasyonlarını yöneten ana servis sınıfı
        - Ghost durumu kontrolü ve bilgi okuma
        - Phantom API üzerinden client verilerine erişim
        - wstunnel komutunu Ghost API'den alma
        - AllowedIPs hesaplama algoritması (binary tree split)
    
    Mimari:
        Servis, Ghost Mode'un aktif olup olmadığını kontrol eder, ardından
        client verilerini ve Ghost bağlantı bilgilerini alarak özelleştirilmiş
        bir WireGuard konfigürasyonu üretir. Tüm çıktı stdout'a verilir.

EN: Casper Service - Ghost Mode Configuration Export Core
    ====================================================
    
    This module provides the core service for exporting Ghost Mode client
    configurations. Only outputs to stdout.
    
    Key Components:
        - CasperService: Main service class managing Ghost Mode configurations
        - Ghost state checking and information reading
        - Client data access via Phantom API
        - Fetching wstunnel command from Ghost API
        - AllowedIPs calculation algorithm (binary tree split)
    
    Architecture:
        The service checks if Ghost Mode is active, then retrieves client
        data and Ghost connection information to generate a customized
        WireGuard configuration. All output goes to stdout.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import re
import json
import ipaddress
from pathlib import Path
from datetime import datetime

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


class CasperService:
    def __init__(self):
        """Initialize Casper service.

        Sets up configuration paths and initializes the Phantom API
        connection with graceful fallback if the API is not available.
        """
        # Setup configuration paths
        self.config_dir = Path("/opt/phantom-wg/config")
        self.ghost_state_file = self.config_dir / "ghost-state.json"

        # Initialize API
        self.phantom_api = None
        if PHANTOM_API_AVAILABLE:
            try:
                self.phantom_api = PhantomAPI()
            except (AttributeError, TypeError, RuntimeError):
                # API initialization failed
                pass

    def export_client_config(self, username):
        """Export client configuration to stdout.

        Retrieves and displays the Ghost Mode WireGuard configuration for
        the specified client, including wstunnel command and setup instructions.

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

        # Output formatted result
        print("=" * 80)
        print("PHANTOM-WG - GHOST MODE CLIENT CONFIGURATION")
        print("=" * 80)
        print(f"\nClient: {username}")
        print(f"Server: {ghost_info['domain']}")
        print(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("\n" + "-" * 80)
        print("STEP 1: Start wstunnel client")
        print("-" * 80)
        print("\nRun this command in a separate terminal (keep it running):\n")
        print(f"    {wstunnel_cmd}")
        print("\n" + "-" * 80)
        print("STEP 2: WireGuard Configuration")
        print("-" * 80)
        print("\nSave the following configuration to a file (e.g., phantom-ghost.conf):\n")
        print(config)
        print("\n" + "-" * 80)
        print("STEP 3: Connect")
        print("-" * 80)
        print("\nLinux/macOS:")
        print("    sudo wg-quick up /path/to/phantom-ghost.conf")
        print("\nWindows:")
        print("    Import the configuration file in WireGuard client")
        print("\nTo disconnect:")
        print("    sudo wg-quick down /path/to/phantom-ghost.conf")
        print("\n" + "=" * 80)
        print("NOTE: Keep the wstunnel command running while connected!")
        print("=" * 80)

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
            dict: Connection info with 'domain', 'server_ip', and 'secret' keys,
                 or None if unable to read the state file
        """
        try:
            # Read state file
            with open(self.ghost_state_file, 'r') as f:
                state = json.load(f)
                # Return required fields
                return {
                    "domain": state.get("domain"),
                    "server_ip": state.get("server_ip"),
                    "secret": state.get("secret")
                }
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

            # Calculate new IPs
            new_allowed_ips = self._calculate_allowed_ips(original_allowed_ips, ghost_info.get('server_ip'))

            # Update config
            modified_config = re.sub(
                r'AllowedIPs\s*=\s*[^\n]+',
                f'AllowedIPs = {", ".join(new_allowed_ips)}',
                modified_config
            )

        return modified_config

    # noinspection PyMethodMayBeStatic
    def _calculate_allowed_ips(self, original_ips, server_ip):
        """Calculate AllowedIPs excluding server IP.

        Uses a binary tree splitting algorithm to exclude the server's IP
        address from the default route (0.0.0.0/0) to prevent routing loops.

        Args:
            original_ips: Comma-separated string of original AllowedIPs
            server_ip: The server's IP address to exclude

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

        def split_cidr(network, exclude_ip):
            """
            Recursively split a CIDR block to exclude a specific IP.
            
            Uses binary tree splitting: divides the network in half,
            determines which half contains the excluded IP, and recurses.
            """
            # Return if IP not in network
            if exclude_ip < int(network.network_address) or exclude_ip > int(network.broadcast_address):
                return [str(network)]

            # Exclude single IP
            if network.prefixlen >= 32:
                return []

            # Split network
            networks = list(network.subnets(prefixlen_diff=1))
            result = []

            # Process halves
            for subnet in networks:
                result.extend(split_cidr(subnet, exclude_ip))

            return result

        # Start with full IPv4 space
        all_ipv4 = ipaddress.IPv4Network("0.0.0.0/0")
        allowed_cidrs = split_cidr(all_ipv4, server_int)

        # Add non-default routes
        for ip in ips_list:
            if ip != "0.0.0.0/0" and ip not in allowed_cidrs:
                allowed_cidrs.append(ip)

        return allowed_cidrs
