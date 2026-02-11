"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: NetworkAdmin Manager - WireGuard ağ yapılandırması ve subnet yönetimi
    =====================================================================
    
    Bu sınıf, WireGuard VPN ağ yapılandırmasını ve subnet geçiş işlemlerini yönetir.
    Ağ analizi, subnet değişikliği validasyonu ve güvenli geçiş işlemlerini
    gerçekleştirir.
    
    Ana Sorumluluklar:
        - Mevcut ağ yapılandırmasını analiz etme
        - Subnet değişikliği için validasyon ve uygunluk kontrolü
        - Güvenli subnet geçişi (yedekleme ve geri alma desteği)
        - RFC1918 özel IP aralıklarının yönetimi
        - Firewall kuralları ve NAT yapılandırması güncelleme
        - Ghost Mode ve Multihop durum kontrolü
        
    Refactoring Notları:
        - Facade pattern ile %100 geriye dönük uyumluluk
        - 5 internal helper modülü ile kod organizasyonu
        - Public API hiçbir şekilde değişmemiştir
        - Tüm metodlar ve imzalar korunmuştur

EN: NetworkAdmin Manager - WireGuard network configuration and subnet management
    ===========================================================================
    
    This class manages WireGuard VPN network configuration and subnet transitions.
    Performs network analysis, subnet change validation and secure migration
    operations.
    
    Main Responsibilities:
        - Analyze current network configuration
        - Validate and check eligibility for subnet changes
        - Secure subnet migration (with backup and rollback support)
        - RFC1918 private IP range management
        - Update firewall rules and NAT configuration
        - Ghost Mode and Multihop state checking
        
    Refactoring Notes:
        - 100% backward compatibility with facade pattern
        - Code organization with 5 internal helper modules
        - Public API has not changed in any way
        - All methods and signatures are preserved

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import ipaddress
from pathlib import Path
from typing import Dict, Any, List, Callable

from phantom.api.exceptions import (
    ValidationError,
    ConfigurationError
)

from ..models import (
    NetworkAnalysis,
    NetworkValidationResult,
    NetworkMigrationResult,
    MainInterfaceInfo
)

from .network_admin_helpers import (
    SubnetOperations as _SubnetOperations,
    IPOperations as _IPOperations,
    FirewallOperations as _FirewallOperations,
    StateOperations as _StateOperations,
    MigrationOperations as _MigrationOperations
)

from .default_constants import (
    DEFAULT_WG_NETWORK,
    BACKUPS_DIR
)


class NetworkAdmin:
    """
    Network administration and subnet management orchestrator.

    Coordinates network operations through specialized helper classes while
    maintaining full backward compatibility with the original API.
    """

    RFC1918_SUBNETS = [
        ipaddress.IPv4Network('10.0.0.0/8'),
        ipaddress.IPv4Network('172.16.0.0/12'),
        ipaddress.IPv4Network('192.168.0.0/16')
    ]

    MIN_SUBNET_SIZE = 8  # Minimum subnet prefix length difference from /32
    CAPACITY_BUFFER = 1.2  # Required 20% spare capacity for future growth

    def __init__(self, data_store, common_tools, service_monitor,
                 config: Dict[str, Any], save_config: Callable,
                 run_command: Callable, wg_interface: str,
                 wg_config_file: Path, install_dir: Path):
        """
        Initialize NetworkAdmin with dependencies and helper classes.

        Args:
            data_store: Client data storage interface
            common_tools: Shared utility functions
            service_monitor: Service monitoring interface
            config: Main configuration dictionary
            save_config: Function to persist configuration
            run_command: Command execution interface
            wg_interface: WireGuard interface name (e.g., 'wg0')
            wg_config_file: Path to WireGuard configuration file
            install_dir: Base installation directory
        """
        self.data_store = data_store
        self.common_tools = common_tools
        self.service_monitor = service_monitor
        self.config = config
        self._save_config = save_config
        self._run_command = run_command
        self.wg_interface = wg_interface
        self.wg_config_file = wg_config_file
        self.install_dir = install_dir
        self.data_dir = install_dir / "data"
        self.backup_dir = install_dir / BACKUPS_DIR

        # Create backup directory for migration rollback support
        self.backup_dir.mkdir(exist_ok=True)

        # Initialize specialized helper classes for different operation domains
        self._subnet_ops = _SubnetOperations(
            config=self.config,
            run_command=self._run_command,
            common_tools=self.common_tools
        )

        self._ip_ops = _IPOperations(
            data_store=self.data_store,
            config=self.config
        )

        self._state_ops = _StateOperations(
            install_dir=self.install_dir,
            config=self.config,
            run_command=self._run_command,
            wg_interface=self.wg_interface
        )

        self._firewall_ops = _FirewallOperations(
            run_command=self._run_command,
            wg_interface=self.wg_interface,
            detect_ssh_port=self._state_ops.detect_ssh_port,
            analyze_interface=self._state_ops.analyze_main_network_interface
        )

        self._migration_ops = _MigrationOperations(
            data_store=self.data_store,
            common_tools=self.common_tools,
            service_monitor=self.service_monitor,
            config=self.config,
            save_config=self._save_config,
            run_command=self._run_command,
            wg_interface=self.wg_interface,
            wg_config_file=self.wg_config_file,
            install_dir=self.install_dir,
            data_dir=self.data_dir,
            backup_dir=self.backup_dir,
            subnet_ops=self._subnet_ops,
            ip_ops=self._ip_ops,
            firewall_ops=self._firewall_ops,
            state_ops=self._state_ops,
            validate_network_modification=lambda x: self._validate_network_modification_typed(x),
            analyze_current_network=lambda: self._analyze_current_network_typed()
        )

    def analyze_current_network(self) -> Dict[str, Any]:
        """
        Analyze current WireGuard network configuration and state.

        Returns:
            Dictionary containing subnet info, client counts, blockers, and interface details
        """
        result: NetworkAnalysis = self._analyze_current_network_typed()
        return result.to_dict()

    def validate_network_modification(self, new_subnet: str) -> Dict[str, Any]:
        """
        Validate if subnet change is possible and safe.

        Args:
            new_subnet: Target subnet in CIDR notation (e.g., '10.8.0.0/24')

        Returns:
            Validation result with checks, errors, warnings, and IP mapping preview
        """
        result: NetworkValidationResult = self._validate_network_modification_typed(new_subnet)
        return result.to_dict()

    def execute_network_migration(self, new_subnet: str, force: bool = False) -> Dict[str, Any]:
        """
        Execute complete subnet migration with automatic rollback on failure.

        Args:
            new_subnet: Target subnet in CIDR notation
            force: Bypass safety checks if True (use with caution)

        Returns:
            Migration result including success status, backup ID, and IP mappings
        """
        result: NetworkMigrationResult = self._execute_network_migration_typed(new_subnet, force)
        return result.to_dict()

    def _analyze_current_network_typed(self) -> NetworkAnalysis:
        """
        Internal typed version of network analysis.

        Returns:
            NetworkAnalysis object with complete network state information
        """
        # Load fresh config to capture any external changes
        config_file = self.install_dir / "config" / "phantom.json"
        if config_file.exists():
            import json
            current_config = json.loads(config_file.read_text())
        else:
            current_config = self.config

        # Extract WireGuard network settings from config
        wg_config = current_config.get("wireguard", {})
        current_subnet = wg_config.get("network", DEFAULT_WG_NETWORK)

        # Validate and parse subnet string into IPv4Network object
        try:
            network = ipaddress.IPv4Network(current_subnet)
        except ValueError:
            raise ConfigurationError(f"Invalid network configuration: {current_subnet}")

        # Calculate available IP addresses in subnet
        total_ips = network.num_addresses

        # Retrieve all clients and count active connections
        clients = self.data_store.get_all_clients()
        active_count = self._state_ops.count_active_connections()

        # Identify conditions that prevent subnet changes
        ghost_mode = self._state_ops.check_if_ghost_mode_is_active()
        multihop = self._state_ops.check_if_multihop_is_active()

        # Analyze primary network interface for routing
        main_interface = self._state_ops.analyze_main_network_interface()

        # Compile detailed client information with timestamps
        clients_detail = {}
        for client in clients:
            clients_detail[client.name] = {
                "ip": client.ip,
                "created": client.created.isoformat() if hasattr(client.created, 'isoformat') else str(client.created),
                "last_seen": getattr(client, 'last_handshake', None).isoformat() if hasattr(
                    getattr(client, 'last_handshake', None), 'isoformat') else None
            }

        # Construct complete client statistics dictionary
        clients_dict = {
            "total": len(clients),
            "total_configured": len(clients),
            "active": active_count,
            "clients": clients_detail
        }

        # Determine server IP address (first usable IP in network)
        server_ip = str(network.network_address + 1)

        # Network change allowed only when no blockers present
        can_change = not (ghost_mode or multihop or active_count > 0)

        # Collect warning messages for active blockers
        warnings = []
        if ghost_mode:
            warnings.append("Ghost Mode is active")
        if multihop:
            warnings.append("Multihop is active")
        if active_count > 0:
            warnings.append(f"{active_count} active connections")

        return NetworkAnalysis(
            current_subnet=current_subnet,
            subnet_size=total_ips,
            clients=clients_dict,
            server_ip=server_ip,
            can_change=can_change,
            blockers={
                "ghost_mode": ghost_mode,
                "multihop": multihop,
                "active_connections": active_count > 0
            },
            main_interface=main_interface,
            warnings=warnings
        )

    def _validate_network_modification_typed(self, new_subnet: str) -> NetworkValidationResult:
        """
        Perform comprehensive validation of proposed subnet change.

        Args:
            new_subnet: Target subnet in CIDR notation

        Returns:
            NetworkValidationResult with detailed validation results
        """
        # Parse and validate subnet format
        try:
            new_network = ipaddress.IPv4Network(new_subnet)
        except ValueError:
            raise ValidationError(
                f"Invalid subnet format for '{new_subnet}'. "
                "Please use CIDR notation (e.g., '10.8.0.0/24'). "
                "Valid examples: '10.8.0.0/24', '192.168.1.0/24', '172.16.0.0/16'. "
                "The subnet must be a valid IPv4 network address with prefix length."
            )

        # Retrieve current network state for comparison
        current_info = self.analyze_current_network()
        current_network = ipaddress.IPv4Network(current_info["current_subnet"])

        # Initialize validation result containers
        valid = True
        checks = {}
        warnings = []
        errors = []

        # Check for active Ghost Mode blocker
        if current_info["blockers"]["ghost_mode"]:
            valid = False
            errors.append("Ghost Mode is active. Disable it before changing subnet.")

        if current_info["blockers"]["multihop"]:
            valid = False
            errors.append("Multihop is active. Disable it before changing subnet.")

        # Verify subnet has minimum required size
        subnet_size_check = self._subnet_ops.ensure_subnet_size_is_adequate(new_network)
        checks["subnet_size"] = subnet_size_check
        if not subnet_size_check["valid"]:
            valid = False
            errors.append(subnet_size_check["error"])

        # Ensure subnet uses RFC1918 private address space
        private_subnet_check = self._subnet_ops.ensure_subnet_is_private(new_network)
        checks["private_subnet"] = private_subnet_check
        if not private_subnet_check["valid"]:
            valid = False
            errors.append(private_subnet_check["error"])

        # Detect conflicts with system network interfaces
        network_conflicts_check = self._subnet_ops.ensure_no_network_conflicts(new_network)
        checks["network_conflicts"] = network_conflicts_check
        if not network_conflicts_check["valid"]:
            valid = False
            errors.append(network_conflicts_check["error"])

        # Verify subnet can accommodate all existing clients
        client_count = current_info["clients"]["total"]
        capacity_check = self._subnet_ops.ensure_sufficient_capacity_for_clients(
            new_network, client_count
        )
        checks["capacity"] = capacity_check
        if not capacity_check["valid"]:
            valid = False
            errors.append(capacity_check["error"])

        # Generate user warnings for potential issues
        if current_info["blockers"]["active_connections"]:
            warnings.append(
                f"There are {current_info['clients']['active']} active connections that will be disconnected."
            )

        if new_network.prefixlen > current_network.prefixlen:
            warnings.append(
                "New subnet is smaller than current subnet. Ensure all clients can be accommodated."
            )

        # Preview IP address remapping if validation passes
        ip_mapping_preview = None
        if valid:
            ip_mapping_preview = self._ip_ops.preview_ip_remapping(
                current_network, new_network, current_info
            )

        return NetworkValidationResult(
            valid=valid,
            new_subnet=str(new_network),
            current_subnet=str(current_network),
            checks=checks,
            warnings=warnings,
            errors=errors,
            ip_mapping_preview=ip_mapping_preview
        )

    def _execute_network_migration_typed(self, new_subnet: str, force: bool = False) -> NetworkMigrationResult:
        """
        Execute subnet migration with backup and rollback capability.

        Args:
            new_subnet: Target subnet in CIDR notation
            force: Bypass safety checks if True

        Returns:
            NetworkMigrationResult with migration status and details
        """
        result_dict = self._migration_ops.execute_network_migration_typed(new_subnet, force)

        return NetworkMigrationResult(
            success=result_dict["success"],
            old_subnet=result_dict["old_subnet"],
            new_subnet=result_dict["new_subnet"],
            clients_updated=result_dict["clients_updated"],
            backup_id=result_dict["backup_id"],
            ip_mapping=result_dict["ip_mapping"]
        )

    def _ensure_subnet_size_is_adequate(self, network: ipaddress.IPv4Network) -> Dict[str, Any]:
        return self._subnet_ops.ensure_subnet_size_is_adequate(network)

    def _ensure_subnet_is_private(self, network: ipaddress.IPv4Network) -> Dict[str, Any]:
        return self._subnet_ops.ensure_subnet_is_private(network)

    def _ensure_no_network_conflicts(self, network: ipaddress.IPv4Network) -> Dict[str, Any]:
        return self._subnet_ops.ensure_no_network_conflicts(network)

    def _ensure_sufficient_capacity_for_clients(self, network: ipaddress.IPv4Network,
                                                client_count: int) -> Dict[str, Any]:
        return self._subnet_ops.ensure_sufficient_capacity_for_clients(network, client_count)

    @staticmethod
    def _generate_subnet_change_warnings(client_count: int, active_count: int) -> List[str]:
        return _SubnetOperations.generate_subnet_change_warnings(client_count, active_count)

    def _preview_ip_remapping(self, old_network: ipaddress.IPv4Network,
                              new_network: ipaddress.IPv4Network,
                              current_info: Dict[str, Any]) -> Dict[str, Any]:
        return self._ip_ops.preview_ip_remapping(old_network, new_network, current_info)

    def _calculate_complete_ip_remapping(self, old_network: ipaddress.IPv4Network,
                                         new_network: ipaddress.IPv4Network) -> Dict[str, str]:
        return self._ip_ops.calculate_complete_ip_remapping(old_network, new_network)

    def _update_client_database_with_new_ips(self, ip_mapping: Dict[str, str]) -> None:
        self._ip_ops.update_client_database_with_new_ips(ip_mapping)

    def _capture_current_firewall_rules(self) -> Dict[str, Any]:
        return self._firewall_ops.capture_current_firewall_rules()

    def _update_firewall_rules_for_new_subnet(self, old_network: ipaddress.IPv4Network,
                                              new_network: ipaddress.IPv4Network) -> None:
        self._firewall_ops.update_firewall_rules_for_new_subnet(old_network, new_network)

    def _update_ufw_rules_for_subnet(self, old_network: ipaddress.IPv4Network,
                                     new_network: ipaddress.IPv4Network) -> None:
        self._firewall_ops.update_ufw_rules_for_subnet(old_network, new_network)

    def _update_iptables_nat_for_subnet(self, old_network: ipaddress.IPv4Network,
                                        new_network: ipaddress.IPv4Network) -> None:
        self._firewall_ops.update_iptables_nat_for_subnet(old_network, new_network)

    def _detect_ssh_port(self) -> str:
        return self._state_ops.detect_ssh_port()

    def _check_state_file_enabled(self, state_filename: str) -> bool:
        return self._state_ops.check_state_file_enabled(state_filename)

    def _check_if_ghost_mode_is_active(self) -> bool:
        return self._state_ops.check_if_ghost_mode_is_active()

    def _check_if_multihop_is_active(self) -> bool:
        return self._state_ops.check_if_multihop_is_active()

    def _count_active_connections(self) -> int:
        return self._state_ops.count_active_connections()

    def _analyze_main_network_interface_typed(self) -> MainInterfaceInfo:
        return self._state_ops.analyze_main_network_interface_typed()

    def _analyze_main_network_interface(self) -> Dict[str, Any]:
        return self._state_ops.analyze_main_network_interface()

    def _create_comprehensive_migration_backup(self, backup_id: str) -> Dict[str, Any]:
        return self._migration_ops.create_comprehensive_migration_backup(backup_id)

    def _safely_stop_wireguard_service(self) -> None:
        self._migration_ops.safely_stop_wireguard_service()

    def _safely_start_wireguard_service(self) -> None:
        self._migration_ops.safely_start_wireguard_service()

    def _verify_network_migration_success(self, new_network: ipaddress.IPv4Network) -> bool:
        return self._migration_ops.verify_network_migration_success(new_network)

    def _execute_emergency_rollback(self, backup_data: Dict[str, Any]) -> None:
        self._migration_ops.execute_emergency_rollback(backup_data)

    def _update_server_network_configuration(self, new_network: ipaddress.IPv4Network,
                                             ip_mapping: Dict[str, str]) -> None:
        self._migration_ops.update_server_network_configuration(new_network, ip_mapping)

    def _update_main_config_with_new_subnet(self, new_subnet: str) -> None:
        self._migration_ops.update_main_config_with_new_subnet(new_subnet)
