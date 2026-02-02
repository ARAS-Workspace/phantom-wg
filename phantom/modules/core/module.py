"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Core Modülü
    ==========================================
    
    WireGuard VPN yönetiminin ana orkestrasyon katmanı. Bu modül, 7 işlevsel
    olarak özelleşmiş yönetici kullanarak tüm temel işlevleri koordine eder.
    
    API Endpoint'leri (14 adet):
        1. İstemci Yönetimi: add_client, remove_client, list_clients, export_client, latest_clients
        2. Servis Yönetimi: server_status, service_logs, restart_service, get_firewall_status
        3. Yapılandırma: get_tweak_settings, update_tweak_setting
        4. Ağ Yönetimi: get_subnet_info, validate_subnet_change, change_subnet

EN: Phantom-WG Core Module
    ==========================================
    
    Main orchestration layer for WireGuard VPN management. This module coordinates
    all core functionality using 7 functionally specialized managers.
    
    API Endpoints (14 total):
        1. Client Management: add_client, remove_client, list_clients, export_client, latest_clients
        2. Service Management: server_status, service_logs, restart_service, get_firewall_status
        3. Configuration: get_tweak_settings, update_tweak_setting
        4. Network Management: get_subnet_info, validate_subnet_change, change_subnet

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from pathlib import Path
from typing import Dict, Any, Optional, Callable

from phantom.modules.base import BaseModule

from .models import (
    ClientAddResult,
    ClientRemoveResult,
    ClientListResult,
    ClientExportResult,
    LatestClientsResult,
    ServiceHealth
)

from .lib import DataStore, KeyGenerator, CommonTools
from .lib.default_constants import (
    DEFAULT_WG_NETWORK
)

class CoreModule(BaseModule):
    """Core WireGuard management module - Main orchestration layer.

    Provides all core WireGuard VPN functionality by coordinating
    7 specialized managers. Each manager specializes in a specific area
    and uses self-explanatory method names.

    Manager Responsibilities:
        - DataStore: TinyDB operations and IP allocation
        - KeyGenerator: WireGuard key generation
        - CommonTools: Validation and common utilities
        - ClientHandler: Client lifecycle management
        - ServiceMonitor: systemd service health monitoring
        - ConfigKeeper: Configuration persistence
        - NetworkAdmin: Subnet and network operations

    Model Architecture:
        Uses @dataclass models with functional semantic organization.
        Each model represents a specific functional area (client_models,
        service_models, network_models, etc.) and inherits from BaseModel
        to provide API compatibility through to_dict() method.

    Typed Method Approach:
        Dual method strategy for type safety:
        - Methods with _typed suffix: Return typed dataclass models
        - Regular methods: Return dict via to_dict() for backward compatibility
        This enables gradual type safety migration and IDE autocomplete support.
    """

    def __init__(self, install_dir: Optional[Path] = None, wg_config_file: Optional[Path] = None):
        super().__init__(install_dir)
        self.wg_interface = self.config.get("wireguard", {}).get("interface", "wg_main")
        if wg_config_file:
            self.wg_config_file = wg_config_file
        else:
            self.wg_config_file = Path(f"/etc/wireguard/{self.wg_interface}.conf")

        subnet = self.config.get("wireguard", {}).get("network", DEFAULT_WG_NETWORK)
        self.store_data = DataStore(
            db_path=self.data_dir / "clients.db",
            data_dir=self.data_dir,
            subnet=subnet
        )

        self.db_path = self.data_dir / "clients.db"
        self.db = self.store_data.db
        self.clients_table = self.store_data.clients_table
        self.ip_table = self.store_data.ip_table
        self.data_store = self.store_data

        self.generate_keys = KeyGenerator(run_command=self._run_command)
        self.key_generator = self.generate_keys

        self.common_utilities = CommonTools(config=self.config, run_command=self._run_command)
        self.common_tools = self.common_utilities

        from .lib import ClientHandler
        self.manage_clients = ClientHandler(
            data_store=self.store_data,
            key_generator=self.generate_keys,
            common_tools=self.common_utilities,
            config=self.config,
            run_command=self._run_command,
            wg_interface=self.wg_interface,
            wg_config_file=self.wg_config_file,
            install_dir=self.install_dir
        )
        self.manage_clients.core_module = self
        self.client_handler = self.manage_clients

        from .lib import ServiceMonitor
        self.monitor_service = ServiceMonitor(
            data_store=self.store_data,
            common_tools=self.common_utilities,
            config=self.config,
            run_command=self._run_command,
            wg_interface=self.wg_interface,
            wg_config_file=self.wg_config_file,
            install_dir=self.install_dir
        )
        self.service_monitor = self.monitor_service

        from .lib import ConfigKeeper
        self.keep_config = ConfigKeeper(
            config_dir=self.config_dir,
            logger=self.logger,
            load_config_func=self._load_config,
            save_config_func=self._save_config,
            runtime_updater=self._update_runtime_tweak
        )
        self.config_keeper = self.keep_config

        from .lib import NetworkAdmin
        self.administer_network = NetworkAdmin(
            data_store=self.store_data,
            common_tools=self.common_utilities,
            service_monitor=self.monitor_service,
            config=self.config,
            save_config=self._save_config,
            run_command=self._run_command,
            wg_interface=self.wg_interface,
            wg_config_file=self.wg_config_file,
            install_dir=self.install_dir
        )
        self.network_admin = self.administer_network

        # Load tweak settings
        tweaks = self.config.get("tweaks", {})
        self.restart_service_after_client_creation = tweaks.get(
            "restart_service_after_client_creation", False
        )

    def _update_runtime_tweak(self, setting_name: str, value: bool) -> None:
        """Update runtime tweak values - callback from ConfigKeeper.

        Called by ConfigKeeper when configuration changes
        to keep runtime variables in sync with saved configuration.

        Args:
            setting_name: Name of the tweak setting
            value: New boolean value for the setting
        """
        # Update runtime variable based on setting name
        if setting_name == "restart_service_after_client_creation":
            self.restart_service_after_client_creation = value
            self.logger.debug(f"Runtime tweak updated: {setting_name} = {value}")

    def get_module_name(self) -> str:
        """Return module name."""
        return "core"

    def get_module_description(self) -> str:
        """Return module description."""
        return "Core WireGuard client and server management"

    def get_actions(self) -> Dict[str, Callable]:
        """Return all available actions this module can perform.

        Actions are organized by functional area:
            - Client Management: add, remove, list, export clients
            - Service Management: status, logs, restart, firewall
            - Configuration: tweak settings
            - Network Administration: subnet operations

        Returns:
            Dict[str, Callable]: Map of action names to their handler methods
        """
        return {
            # Client Management Actions
            "add_client": self.add_client,
            "remove_client": self.remove_client,
            "list_clients": self.list_clients,
            "export_client": self.export_client,
            "latest_clients": self.latest_clients,

            # Service Management Actions
            "server_status": self.server_status,
            "service_logs": self.service_logs,
            "restart_service": self.restart_service,
            "get_firewall_status": self.get_firewall_status,

            # Configuration Management Actions
            "get_tweak_settings": self.get_tweak_settings,
            "update_tweak_setting": self.update_tweak_setting,

            # Network Administration Actions
            "get_subnet_info": self.get_subnet_info,
            "validate_subnet_change": self.validate_subnet_change,
            "change_subnet": self.change_subnet
        }

    def add_client(self, client_name: str) -> Dict[str, Any]:
        """Add a new WireGuard client with automatic configuration.

        This action will:
            1. Validate the client name
            2. Generate secure WireGuard keys
            3. Allocate an IP address
            4. Create client configuration
            5. Update server configuration
            6. Apply changes (with or without restart based on tweaks)

        Args:
            client_name: Name of the client (alphanumeric, hyphens, underscores)

        Returns:
            Dict containing:
            - client: Client details (name, ip, public_key, created)
            - config_file: Path to generated configuration file
            - ghost_mode: Ghost mode status if applicable
        """
        result: ClientAddResult = self.manage_clients.add_new_client(client_name)
        return result.to_dict()

    def remove_client(self, client_name: str) -> Dict[str, Any]:
        """Remove a WireGuard client and clean up all configurations.

        This action will:
            1. Remove client from TinyDB database
            2. Remove peer from server configuration
            3. Delete client configuration files
            4. Free up the IP address for reuse
            5. Apply changes to WireGuard

        Returns ClientRemoveResult through ClientHandler and converts
        to dict via to_dict().

        Args:
            client_name: Name of the client to remove

        Returns:
            Dict containing:
            - removed: True if successful
            - client_name: Name of removed client
            - client_ip: IP address that was freed
            - config_files_removed: Status of file cleanup
        """
        # ClientHandler ensures clean removal from database, configs, and server
        result: ClientRemoveResult = self.manage_clients.remove_existing_client(client_name)
        return result.to_dict()

    def list_clients(self, page: int = 1, per_page: int = 10, search: str = None) -> Dict[str, Any]:
        """List all configured WireGuard clients with pagination and search.

        Shows connection status based on recent handshakes.
        Active = handshake within last 3 minutes.

        Returns ClientListResult through ClientHandler and converts
        to dict via to_dict(). Client data retrieved from DataStore
        and enriched with wg show command.

        Args:
            page: Page number (default: 1)
            per_page: Items per page (default: 10)
            search: Optional search term for filtering by name

        Returns:
            Dict containing:
            - clients: List of client objects with status
            - total: Total number of clients
            - pagination: Page info (current, total, has_next, has_prev)
        """
        # ClientHandler queries DataStore and enriches with connection status
        result: ClientListResult = self.manage_clients.list_all_clients(page=page, per_page=per_page, search=search)
        return result.to_dict()

    def export_client(self, client_name: str) -> Dict[str, Any]:
        """Export client configuration.

        Returns WireGuard configuration text for the client.
        Configuration is generated dynamically, not stored in filesystem.
        Returns ClientExportResult through ClientHandler and converts
        to dict via to_dict().

        Args:
            client_name: Name of the client to export

        Returns:
            Dict containing client configuration and export details
        """
        # ClientHandler generates dynamic configs from database + phantom.json
        result: ClientExportResult = self.manage_clients.export_client_configuration(client_name)
        return result.to_dict()

    def server_status(self) -> Dict[str, Any]:
        """Get comprehensive WireGuard server status and health information.

        Provides real-time information about:
            - Service status (running/stopped)
            - Interface status and statistics
            - Active connections with transfer data
            - Server configuration
            - System information

        Returns:
            Dict containing:
            - service: Service status and uptime
            - interface: WireGuard interface details
            - clients: Connected clients statistics
            - configuration: Server settings
            - system: Installation paths and firewall status
        """
        health: ServiceHealth = self.monitor_service.check_wireguard_health()
        return health.to_dict()

    def service_logs(self, lines: int = 50) -> Dict[str, Any]:
        """Get WireGuard service logs.

        Retrieves systemd journal entries through ServiceMonitor.
        Reads wg-quick@wg_main service logs using journalctl command.
        Returns last 50 lines by default.

        Args:
            lines: Number of log lines to retrieve (default: 50)

        Returns:
            Dict containing service logs
        """
        # ServiceMonitor fetches and formats systemd journal entries
        return self.monitor_service.retrieve_service_logs(lines)

    def latest_clients(self, count: int = 5) -> Dict[str, Any]:
        """Get latest added clients.

        Queries DataStore through ClientHandler for most recently
        added clients. Sorted by created_at field.
        Returns LatestClientsResult and converts to dict via to_dict().

        Args:
            count: Number of clients to retrieve (default: 5)

        Returns:
            Dict containing latest clients
        """
        # ClientHandler queries DataStore for latest additions
        result: LatestClientsResult = self.manage_clients.get_recently_added_clients(count)
        return result.to_dict()

    def restart_service(self) -> Dict[str, Any]:
        """Restart WireGuard service.

        Ensures safe restart through ServiceMonitor.
        Executes systemctl restart wg-quick@wg_main command.
        Checks service status and verifies proper restart.
        Returns RestartResult.

        Returns:
            Dict containing restart status
        """
        # ServiceMonitor ensures safe restart with proper checks
        return self.monitor_service.restart_wireguard_safely()

    def get_firewall_status(self) -> Dict[str, Any]:
        """Get detailed firewall status and rules.

        Examines UFW rules and WireGuard port status through ServiceMonitor.
        Checks NAT and IP forwarding settings.
        Returns FirewallConfiguration model.

        Returns:
            Dict containing firewall information
        """
        # Check firewall status through ServiceMonitor
        # ServiceMonitor examines UFW rules and WireGuard port status
        return self.monitor_service.check_firewall_configuration()

    def get_tweak_settings(self) -> Dict[str, Any]:
        """Get current tweak settings.

        Returns all tweak settings that control system behavior.
        Example: restart_service_after_client_creation

        Returns:
            Dict containing current tweak settings and descriptions
        """
        # ConfigKeeper provides current settings with descriptions
        return self.keep_config.retrieve_current_tweaks()

    def update_tweak_setting(self, setting_name: str, value: bool) -> Dict[str, Any]:
        """Update a specific tweak setting.

        Updates tweak settings that modify system behavior.
        Changes are applied to both configuration file and runtime.

        Args:
            setting_name: Name of the setting to update
            value: New boolean value for the setting

        Returns:
            Dict containing update status
        """
        # ConfigKeeper validates and applies the setting change
        return self.keep_config.apply_tweak_modification(setting_name, value)

    # Subnet Change Methods

    def get_subnet_info(self) -> Dict[str, Any]:
        """Get current subnet information and change impact analysis.

        Examines subnet usage and change feasibility through NetworkAdmin.
        Analyzes used and available IPs.
        Checks Ghost Mode and Multihop status.
        Returns NetworkAnalysis model.

        Returns:
            Dict containing current subnet details and potential impact
        """
        # NetworkAdmin examines subnet usage and change feasibility
        return self.administer_network.analyze_current_network()

    def validate_subnet_change(self, new_subnet: str) -> Dict[str, Any]:
        """Validate if subnet change is possible and safe.

        Checks safety and compatibility of proposed change through NetworkAdmin.
        Validates RFC 1918 compliance, minimum /29 subnet,
        20% growth capacity and SSH access protection.
        Returns NetworkValidationResult model.

        Args:
            new_subnet: New subnet in CIDR notation (e.g., "10.9.0.0/24")

        Returns:
            Dict containing validation results and warnings
        """
        # NetworkAdmin checks safety and compatibility of proposed change
        return self.administer_network.validate_network_modification(new_subnet)

    def change_subnet(self, new_subnet: str, confirm: bool = False) -> Dict[str, Any]:
        """Change the VPN subnet.

        Performs complete subnet migration through NetworkAdmin.
        Ensures safe migration with backup and rollback support.
        Performs IP remapping, firewall update and service restart.
        Returns NetworkMigrationResult model.

        Args:
            new_subnet: New subnet in CIDR notation
            confirm: Must be True to proceed with the change

        Returns:
            Dict containing change results
        """
        # NetworkAdmin performs complete subnet change with backup/rollback
        return self.administer_network.execute_network_migration(new_subnet, force=confirm)
