"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: ClientHandler Manager - WireGuard istemci yaşam döngüsü ve işlemlerini yönetme
    ===============================================================================

    Bu sınıf, WireGuard VPN istemcilerinin tam yaşam döngüsünü yönetir.
    İstemci ekleme, kaldırma, listeleme ve yapılandırma dışa aktarma işlemlerini
    gerçekleştirir.

    Ana Sorumluluklar:
        - Yeni istemci ekleme ve kriptografik anahtar yönetimi
        - Mevcut istemci kaldırma ve temizlik işlemleri
        - İstemci listesi görüntüleme (sayfalama ve arama desteği)
        - İstemci yapılandırma dosyası dışa aktarma
        - Sunucu yapılandırması peer yönetimi
        - Dinamik peer ekleme (servis yeniden başlatmadan)

    İstemci Yaşam Döngüsü:
        1. İstemci adı doğrulaması ve benzersizlik kontrolü
        2. Kriptografik anahtar üretimi (private, public, preshared)
        3. IP adresi tahsisi ve veritabanında saklama
        4. Sunucu yapılandırmasına peer ekleme
        5. Dinamik peer ekleme veya servis yeniden başlatma
        6. İstemci yapılandırma dosyası üretimi (talep üzerine)

    Dinamik İşlemler:
        - Servis yeniden başlatmadan peer ekleme (wg set)
        - Anlık yapılandırma değişiklikleri
        - Bağlantı durumu izleme
        - Hata durumunda otomatik geri alma

    Güvenlik:
        - Güvenli anahtar yönetimi ve depolama
        - Yapılandırma dosyası izinleri (600)
        - İstemci adı doğrulaması
        - Atomik işlemler ve rollback

EN: ClientHandler Manager - Manage WireGuard client lifecycle and operations
    ======================================================================

    This class manages the complete lifecycle of WireGuard VPN clients.
    Handles client addition, removal, listing and configuration export
    operations.

    Main Responsibilities:
        - New client addition and cryptographic key management
        - Existing client removal and cleanup operations
        - Client listing with pagination and search support
        - Client configuration file export
        - Server configuration peer management
        - Dynamic peer addition (without service restart)

    Client Lifecycle:
        1. Client name validation and uniqueness check
        2. Cryptographic key generation (private, public, preshared)
        3. IP address allocation and database storage
        4. Server configuration peer addition
        5. Dynamic peer addition or service restart
        6. Client configuration file generation (on demand)

    Dynamic Operations:
        - Add peers without service restart (wg set)
        - Instant configuration changes
        - Connection status monitoring
        - Automatic rollback on error conditions

    Security:
        - Secure key management and storage
        - Configuration file permissions (600)
        - Client name validation
        - Atomic operations and rollback

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import os
from pathlib import Path
from typing import Dict, Any, Optional
from datetime import datetime
from textwrap import dedent

from phantom.api.exceptions import (
    ClientExistsError,
    ClientNotFoundError,
    InvalidClientNameError,
    ServiceOperationError,
    IPAllocationError
)
# Internal models for functional semantic organization
from ..models import (
    WireGuardClient,
    ClientAddResult,
    ClientRemoveResult,
    ClientExportResult,
    LatestClientsResult,
    ClientListResult,
    ClientInfo,
    PaginationInfo,
    # Storage models for connection tracking
    ActiveConnectionsMap
)
from .service_monitor import ServiceMonitor

from .default_constants import (
    DEFAULT_HOST_CIDR,
    DEFAULT_PAGE_SIZE,
    DEFAULT_LATEST_COUNT,
    DEFAULT_WG_NETWORK,
    WG_CONFIG_PERMISSIONS
)


class ClientHandler:
    """Manages WireGuard client lifecycle and operations.

    Handles complete lifecycle of WireGuard VPN clients including addition,
    removal, listing and configuration operations.

    Features:
        - Cryptographic key management and secure storage
        - IP address allocation and tracking
        - Dynamic peer addition without service restart
        - Server configuration synchronization
        - Client configuration file generation
        - Pagination and search-enabled listing
        - Atomic operations with error rollback
        - Tweak-based dynamic/restart mode
        - Connection status tracking
        - Secure file permissions management
    """

    def __init__(self, data_store, key_generator, common_tools, config: Dict[str, Any],
                 run_command, wg_interface: str, wg_config_file: Path, install_dir: Path):
        self.data_store = data_store
        self.key_generator = key_generator
        self.common_tools = common_tools
        self.config = config
        self._run_command = run_command
        self.wg_interface = wg_interface
        self.wg_config_file = wg_config_file
        self.install_dir = install_dir

        from .config_generation_service import ConfigGenerationService
        self.config_service = ConfigGenerationService(config)

        self.service_monitor = ServiceMonitor(
            data_store=data_store,
            common_tools=common_tools,
            config=config,
            run_command=run_command,
            wg_interface=wg_interface,
            wg_config_file=wg_config_file,
            install_dir=install_dir
        )

        self.core_module = None

        tweaks = self.config.get("tweaks", {})
        self.restart_service_after_client_creation = tweaks.get(
            "restart_service_after_client_creation", False
        )

    def add_new_client(self, client_name: str) -> ClientAddResult:

        # Validate client name format
        if not client_name:
            raise InvalidClientNameError("Client name is required")

        self.common_tools.ensure_name_is_valid(client_name)

        # Check for duplicate client
        if self.data_store.check_if_client_exists(client_name):
            raise ClientExistsError(f"Client '{client_name}' already exists")

        try:
            # Generate cryptographic keys
            private_key = self.key_generator.create_private_key()
            public_key = self.key_generator.derive_public_key(private_key)
            preshared_key = self.key_generator.create_preshared_key()

            # Allocate IP address
            try:
                client_ip = self.data_store.allocate_next_available_ip()
            except ValueError:
                # Get network info for error message
                wg_config = self.config.get("wireguard", {})
                current_subnet = wg_config.get("network", DEFAULT_WG_NETWORK)

                raise IPAllocationError(
                    f"Cannot add new client: No available IP addresses in subnet {current_subnet}. "
                    "Please remove unused clients or change to a larger subnet."
                )

            # Create client object
            client = WireGuardClient(
                name=client_name,
                ip=client_ip,
                private_key=private_key,
                public_key=public_key,
                preshared_key=preshared_key,
                created=datetime.now(),
                enabled=True
            )

            # Store client in database
            self.data_store.store_new_client(client)

            # Add peer to server configuration
            self.add_peer_to_server_configuration(client_name, client.public_key, client.preshared_key, client.ip)

            # Handle service restart or dynamic peer addition based on tweak settings
            should_restart = (self.core_module.restart_service_after_client_creation
                              if self.core_module else self.restart_service_after_client_creation)

            if should_restart:
                self._restart_wireguard_service_if_needed()
            else:
                self.add_peer_to_server_dynamically(client_name, client.public_key, client.preshared_key, client.ip)

            result = ClientAddResult(
                client=client,
                message="Client added successfully"
            )

            return result

        except (OSError, IOError, ValueError):
            # Clean up on failure
            import logging
            logger = logging.getLogger(__name__)
            logger.error("Failed to add client")

            # Attempt rollback
            try:
                self.data_store.remove_existing_client(client_name)
            except (ClientNotFoundError, ServiceOperationError):
                pass

            raise ServiceOperationError(
                "Unable to add the client. This could be due to:\n"
                "• WireGuard service not running - check with 'systemctl status wg-quick@wg_main'\n"
                "• Database access issues - ensure /opt/phantom-wg/data/ is writable\n"
                "• Network configuration problems - verify subnet has available IPs\n"
                "For details, check the logs at /opt/phantom-wg/logs/"
            )

    def remove_existing_client(self, client_name: str) -> ClientRemoveResult:

        if not client_name:
            raise InvalidClientNameError("Client name is required")

        # Get client data including public key for dynamic removal
        client_data = self.data_store.find_client_by_name(client_name)
        if not client_data:
            raise ClientNotFoundError(f"Client '{client_name}' not found")

        client_ip = client_data.ip
        client_public_key = client_data.public_key  # Needed for dynamic removal

        try:
            # Remove from database
            self.data_store.remove_existing_client(client_name)

            # Remove peer from server configuration
            peer_removed = self.remove_peer_from_server_configuration(client_ip)
            if not peer_removed:
                import logging
                logger = logging.getLogger(__name__)
                logger.warning(f"Peer with IP {client_ip} not found in server configuration")

            # Use same tweak setting as client addition for consistency
            should_restart = (self.core_module.restart_service_after_client_creation
                              if self.core_module else self.restart_service_after_client_creation)

            if should_restart:
                # Restart service approach
                self._restart_wireguard_service_if_needed()
            else:
                self.delete_peer_to_server_dynamically(client_name, client_public_key)

            result = ClientRemoveResult(
                removed=True,
                client_name=client_name,
                client_ip=client_ip
            )

            return result

        except (OSError, IOError, RuntimeError) as e:
            import logging
            logger = logging.getLogger(__name__)
            logger.error(f"Failed to remove client: {e}")
            raise ServiceOperationError(
                "Unable to remove the client. Please ensure:\n"
                "• You have proper permissions to modify WireGuard configuration\n"
                "• The WireGuard config file exists at /etc/wireguard/wg_main.conf\n"
                "• No other process is currently modifying the configuration\n"
                "Try running the command with sudo if permission issues persist."
            )

    def list_all_clients(self, page: int = 1, per_page: int = DEFAULT_PAGE_SIZE,
                         search: Optional[str] = None) -> ClientListResult:

        # Get all clients from database
        all_clients = self.data_store.get_all_clients()

        # Get active connections
        active_connections = self._get_active_connections()

        # Build client info list
        client_infos = []
        for client in all_clients:
            # Apply search filter
            if search and search.lower() not in client.name.lower():
                continue

            # Build client info
            client_info = ClientInfo(
                name=client.name,
                ip=client.ip,
                enabled=client.enabled,
                created=client.created.isoformat(),
                connected=client.name in active_connections,
                connection=active_connections.get(client.name) if client.name in active_connections else None
            )
            client_infos.append(client_info)

        client_infos.sort(key=lambda x: x.created)

        # Calculate pagination
        total_clients = len(client_infos)
        total_pages = (total_clients + per_page - 1) // per_page if total_clients > 0 else 0

        # Validate page number
        if page < 1:
            page = 1
        elif 0 < total_pages < page:
            page = total_pages

        # Get page slice
        start_idx = (page - 1) * per_page
        end_idx = min(start_idx + per_page, total_clients)
        paginated_clients = client_infos[start_idx:end_idx]

        # Build pagination info
        pagination = PaginationInfo(
            page=page,
            per_page=per_page,
            total_pages=total_pages,
            has_next=page < total_pages,
            has_prev=page > 1,
            showing_from=start_idx + 1 if paginated_clients else 0,
            showing_to=end_idx
        )

        # Create result
        result = ClientListResult(
            clients=paginated_clients,
            total=total_clients,
            pagination=pagination
        )

        # Return result
        return result

    def export_client_configuration(self, client_name: str) -> ClientExportResult:
        if not client_name:
            raise InvalidClientNameError("Client name is required")

        # Get client data
        client = self.data_store.find_client_by_name(client_name)
        if not client:
            raise ClientNotFoundError(f"Client '{client_name}' not found")

        try:
            # Generate client configuration (convert to dict for compatibility)
            config_content = self.config_service.generate_client_config(client.to_dict())

            result = ClientExportResult(
                client=client,
                config=config_content
            )

            return result

        except Exception as e:
            import logging
            logger = logging.getLogger(__name__)
            logger.error(f"Failed to export client config: {e}")
            raise ServiceOperationError(
                f"Unable to export configuration for client '{client_name}'. "
                "Please verify the client exists and has valid configuration."
            )

    def get_recently_added_clients(self, count: int = DEFAULT_LATEST_COUNT) -> LatestClientsResult:
        try:
            # Get all clients sorted by creation date
            all_clients = self.data_store.get_all_clients()

            # Sort by creation date (newest first)
            sorted_clients = sorted(
                all_clients,
                key=lambda x: x.created,
                reverse=True
            )[:count]

            # Get connection status
            active_connections = self._get_active_connections()

            latest = []
            for client in sorted_clients:
                client_info = ClientInfo(
                    name=client.name,
                    ip=client.ip,
                    created=client.created.isoformat(),
                    enabled=client.enabled,
                    connected=client.name in active_connections,
                    connection=active_connections.get(client.name) if client.name in active_connections else None
                )
                latest.append(client_info)

            result = LatestClientsResult(
                latest_clients=latest,
                count=len(latest),
                total_clients=len(all_clients)
            )

            return result

        except (ValueError, AttributeError, KeyError) as e:
            import logging
            logger = logging.getLogger(__name__)
            logger.error(f"Failed to get latest clients: {e}")
            raise ServiceOperationError(
                "Unable to retrieve client list. This might indicate:\n"
                "• Database connection issues\n"
                "• Corrupted client data\n"
                "• Permission problems accessing /opt/phantom-wg/data/\n"
                "Try restarting the Phantom service or check database integrity."
            )

    # Public helper methods

    def add_peer_to_server_dynamically(self, client_name: str, public_key: str,
                                       preshared_key: str, client_ip: str) -> bool:
        """Add peer to server without restarting WireGuard service.

        Args:
            client_name: Name of the client
            public_key: Client's public key
            preshared_key: Pre-shared key for additional security
            client_ip: IP address allocated to client

        Returns:
            True if peer was added successfully, False if fallback to restart was needed
        """

        import logging
        logger = logging.getLogger(__name__)

        logger.info(f"Adding peer {client_name} dynamically without service restart")

        try:
            # Build wg set command
            cmd = [
                "wg", "set", self.wg_interface,
                "peer", public_key,
                "preshared-key", "/dev/stdin",  # Read from stdin for security
                "allowed-ips", f"{client_ip}{DEFAULT_HOST_CIDR}"
            ]

            # Execute with preshared key via stdin
            result = self._run_command(
                cmd,
                input=preshared_key,
                text=True,
                capture_output=True
            )

            # noinspection DuplicatedCode
            if result.returncode != 0:
                error_msg = result.stderr or "Unknown error"
                logger.error(f"Failed to add peer dynamically: {error_msg}")
                # Fallback to service restart
                logger.info("Falling back to service restart method")
                self._restart_wireguard_service_if_needed()
                return False

            # Save runtime configuration for persistence
            save_cmd = ["wg-quick", "save", self.wg_interface]
            save_result = self._run_command(save_cmd, capture_output=True, text=True)

            if save_result.returncode != 0:
                logger.warning(f"Failed to save configuration: {save_result.stderr}")
                # Peer added but may not persist after restart

            logger.info(f"Successfully added peer {client_name} dynamically")
            return True

        except (OSError, RuntimeError, ValueError) as e:
            logger.error(f"Exception during dynamic peer addition: {e}")
            # Fallback to service restart
            logger.info("Falling back to service restart method due to exception")
            self._restart_wireguard_service_if_needed()
            return False

    def delete_peer_to_server_dynamically(self, client_name: str, public_key: str) -> bool:
        """Remove peer from server without restarting WireGuard service.

        Args:
            client_name: Name of the client to remove
            public_key: Client's public key for identification

        Returns:
            True if peer was removed successfully, False if fallback to restart was needed
        """

        import logging
        logger = logging.getLogger(__name__)

        logger.info(f"Removing peer {client_name} dynamically without service restart")

        try:
            # Build wg set command to remove peer
            cmd = [
                "wg", "set", self.wg_interface,
                "peer", public_key,
                "remove"
            ]

            # Execute removal command
            result = self._run_command(
                cmd,
                capture_output=True,
                text=True
            )

            # noinspection DuplicatedCode
            if result.returncode != 0:
                error_msg = result.stderr or "Unknown error"
                logger.error(f"Failed to remove peer dynamically: {error_msg}")
                # Fallback to service restart
                logger.info("Falling back to service restart method")
                self._restart_wireguard_service_if_needed()
                return False

            # Save runtime configuration for persistence
            save_cmd = ["wg-quick", "save", self.wg_interface]
            save_result = self._run_command(save_cmd, capture_output=True, text=True)

            if save_result.returncode != 0:
                logger.warning(f"Failed to save configuration: {save_result.stderr}")
                # Peer removed but may reappear after restart

            logger.info(f"Successfully removed peer {client_name} dynamically")
            return True

        except (OSError, RuntimeError, ValueError) as e:
            logger.error(f"Exception during dynamic peer removal: {e}")
            # Fallback to service restart
            logger.info("Falling back to service restart method due to exception")
            self._restart_wireguard_service_if_needed()
            return False

    def add_peer_to_server_configuration(self, client_name: str, public_key: str,
                                         preshared_key: str, client_ip: str) -> None:
        """Add peer configuration to server config file.

        Args:
            client_name: Name of the client (used in comment)
            public_key: Client's public key
            preshared_key: Pre-shared key for additional security
            client_ip: IP address allocated to client
        """

        peer_config = dedent(f"""
            [Peer] # {client_name}
            PublicKey = {public_key}
            PresharedKey = {preshared_key}
            AllowedIPs = {client_ip}/32

            """)

        # Append to server configuration
        with open(self.wg_config_file, 'a') as f:
            f.write(peer_config)

        # Set secure file permissions
        os.chmod(self.wg_config_file, WG_CONFIG_PERMISSIONS)

    def remove_peer_from_server_configuration(self, client_ip: str) -> bool:
        """Remove peer configuration from server config file based on IP address

        Args:
            client_ip: The IP address of the client to remove (without /32)

        Returns:
            bool: True if peer was found and removed, False otherwise
        """

        if not self.wg_config_file.exists():
            return False

        content = self.wg_config_file.read_text()
        lines = content.split('\n')

        # Parse config into sections
        sections = []
        current_section = []

        for line in lines:
            if line.strip().startswith('['):
                if current_section:
                    sections.append(current_section)
                current_section = [line]
            else:
                current_section.append(line)

        # Add last section
        if current_section:
            sections.append(current_section)

        # Find and remove peer with matching IP
        peer_removed = False
        new_sections = []

        for section in sections:
            # Check if peer section has target IP
            if section and section[0].strip().startswith('[Peer'):
                # Look for AllowedIPs with target IP
                has_target_ip = any(
                    line.strip().startswith('AllowedIPs') and
                    f"{client_ip}/32" in line
                    for line in section
                )

                if has_target_ip:
                    peer_removed = True
                    continue  # Skip matched section

            new_sections.append(section)

        if peer_removed:
            # Reconstruct configuration
            new_lines = []
            for i, section in enumerate(new_sections):
                new_lines.extend(section)
                # Add separator between sections
                if i < len(new_sections) - 1:
                    new_lines.append('')

            # Write modified config
            new_content = '\n'.join(new_lines)
            self.wg_config_file.write_text(new_content)

            # Set secure file permissions
            os.chmod(self.wg_config_file, WG_CONFIG_PERMISSIONS)

        return peer_removed

    # Private helper methods

    def _get_active_connections_typed(self) -> ActiveConnectionsMap:
        # Use ServiceMonitor instance
        active_connections = self.service_monitor.gather_active_connections()

        # Format connections for listing
        formatted_connections = {}
        for client_name, conn_data in active_connections.items():
            formatted_connections[client_name] = {
                "connected": True,
                "latest_handshake": conn_data.get("latest_handshake", "Never"),
                "endpoint": conn_data.get("endpoint", "N/A"),  # Parsed from ServiceMonitor
                "transfer": {
                    "rx": conn_data.get("transfer", {}).get("received_bytes", 0),
                    "tx": conn_data.get("transfer", {}).get("sent_bytes", 0)
                }
            }

        return ActiveConnectionsMap(connections=formatted_connections)

    def _get_active_connections(self) -> Dict[str, Any]:
        result: ActiveConnectionsMap = self._get_active_connections_typed()
        return result.to_dict()

    def _restart_wireguard_service_if_needed(self) -> None:
        """Restart WireGuard service based on tweak settings.

        Attempts systemctl restart first, falls back to wg-quick down/up if needed.
        Raises ServiceOperationError if restart fails.
        """
        self.service_monitor.perform_service_restart()
