"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: MigrationOperations - Ağ geçiş orkestrasyonu yardımcı modülü
    =====================================================================

    Yedeklemeler, servis yönetimi, yapılandırma güncellemeleri ve geri alma
    yetenekleri dahil olmak üzere tam ağ geçiş sürecini koordine eder.

    Ana Sorumluluklar:
        - Tam ağ geçişini yürüt
        - Değişikliklerden önce kapsamlı yedekler oluştur
        - Geçiş sırasında WireGuard servis yaşam döngüsünü yönet
        - Tamamlandıktan sonra geçiş başarısını doğrula
        - Başarısızlıkta acil geri almaları yönet
        - Tüm yapılandırmaları atomik olarak güncelle

    Kritik İşlemler:
        - Alt ağ değişikliğinden önce tam sistem yedeği
        - IP eşleme ve istemci veritabanı güncellemeleri
        - Güvenlik duvarı kuralları senkronizasyonu
        - Minimum kesinti ile kusursuz servis yeniden başlatma
        - Herhangi bir hatada otomatik geri alma

EN: MigrationOperations - Helper module for network migration orchestration
    =====================================================================

    Coordinates the complete network migration process including backups,
    service management, configuration updates, and rollback capabilities.

    Main Responsibilities:
        - Execute complete network migration
        - Create comprehensive backups before changes
        - Manage WireGuard service lifecycle during migration
        - Verify migration success after completion
        - Handle emergency rollbacks on failure
        - Update all configurations atomically

    Critical Operations:
        - Full system backup before subnet change
        - IP mapping and client database updates
        - Firewall rules synchronization
        - Seamless service restart with minimal downtime
        - Automatic rollback on any failure

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import re
import json
import time
import shutil
import ipaddress
from pathlib import Path
from datetime import datetime
from typing import Dict, Any, Optional, Callable

from phantom.api.exceptions import (
    ValidationError,
    ConfigurationError,
    ServiceOperationError,
    NetworkError
)

from phantom.modules.core.lib.default_constants import (
    DEFAULT_WG_NETWORK
)


class _MigrationOperations:
    """
    Internal helper class for network migration orchestration.

    Responsibilities:
        - Execute complete network migration workflow
        - Create comprehensive backups before changes
        - Manage WireGuard service lifecycle during migration
        - Verify migration success after completion
        - Handle emergency rollbacks on failures
        - Update all configurations atomically
    """

    # Service management constants
    DEFAULT_WG_NETWORK = "10.8.0.0/24"

    def __init__(self, data_store, common_tools, service_monitor,
                 config: Dict[str, Any], save_config: Callable, run_command: Callable,
                 wg_interface: str, wg_config_file: Path,
                 install_dir: Path, data_dir: Path, backup_dir: Path,
                 subnet_ops, ip_ops, firewall_ops, state_ops,
                 validate_network_modification: Optional[Callable] = None,
                 analyze_current_network: Optional[Callable] = None):
        """
        Initialize migration operations helper
        
        Args:
            data_store: DataStore instance
            common_tools: CommonTools instance
            service_monitor: ServiceMonitor instance
            config: Main configuration dictionary
            save_config: Config save function
            run_command: Command execution function
            wg_interface: WireGuard interface name
            wg_config_file: Path to WireGuard config
            install_dir: Installation directory
            data_dir: Data directory path
            backup_dir: Backup directory path
            subnet_ops: SubnetOperations helper instance
            ip_ops: IPOperations helper instance
            firewall_ops: FirewallOperations helper instance
            state_ops: StateOperations helper instance
            validate_network_modification: Optional validation callback
            analyze_current_network: Optional analysis callback
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
        self.data_dir = data_dir
        self.backup_dir = backup_dir

        # Helper references
        self.subnet_ops = subnet_ops
        self.ip_ops = ip_ops
        self.firewall_ops = firewall_ops
        self.state_ops = state_ops

        # Optional callbacks for typed methods
        self._validate_network_modification_typed = validate_network_modification
        self._analyze_current_network_typed = analyze_current_network

    def execute_network_migration_typed(self, new_subnet: str, force: bool = False) -> Dict[str, Any]:
        """
        Execute the network migration with full backup and rollback capabilities.

        Migration Workflow (8 Steps):
        1. Validation and confirmation check
        2. Create comprehensive backup
        3. Stop WireGuard service
        4. Remap IP addresses
        5. Update server and client configurations
        6. Update firewall rules
        7. Start WireGuard service
        8. Verify success

        Automatic rollback occurs on any failure.
        """
        if not force:
            raise ValidationError(
                "Subnet change requires explicit confirmation. "
                "Please review the validation results and add 'confirm=true' parameter "
                "if you want to proceed. This is a safety measure to prevent accidental "
                "network disruptions."
            )

        # Perform validation if callback is available
        if self._validate_network_modification_typed:
            validation = self._validate_network_modification_typed(new_subnet)
            if not validation.valid:
                raise ValidationError(
                    "Subnet change cannot proceed due to validation errors:\n" +
                    "\n".join(f"• {error}" for error in validation.errors) +
                    "\n\nPlease address these issues before attempting the subnet change. "
                    "Use 'phantom-api core validate_subnet_change' to test your configuration."
                )

        # Parse the new network configuration
        new_network = ipaddress.IPv4Network(new_subnet)

        # Get current subnet
        if self._analyze_current_network_typed:
            current_info = self._analyze_current_network_typed()
            old_network = ipaddress.IPv4Network(current_info.current_subnet)
        else:
            # Fall back to configuration if analysis not available
            old_subnet = self.config.get("wireguard", {}).get("network", DEFAULT_WG_NETWORK)
            old_network = ipaddress.IPv4Network(old_subnet)

        # Create comprehensive backup
        backup_id = f"subnet_change_{int(time.time())}"
        backup_data = self.create_comprehensive_migration_backup(backup_id)

        try:
            # Stop WireGuard service
            self.safely_stop_wireguard_service()

            # Create IP mapping
            ip_mapping = self.ip_ops.calculate_complete_ip_remapping(old_network, new_network)

            # Update all configuration files atomically
            self.update_server_network_configuration(new_network, ip_mapping)
            # Client configurations are generated dynamically from database
            # Static config files no longer need regeneration
            self.ip_ops.update_client_database_with_new_ips(ip_mapping)
            self.update_main_config_with_new_subnet(str(new_network))
            self.firewall_ops.update_firewall_rules_for_new_subnet(old_network, new_network)

            # Start WireGuard service
            self.safely_start_wireguard_service()

            # Verify that the migration completed successfully
            if not self.verify_network_migration_success(new_network):
                raise ServiceOperationError(
                    "Subnet change completed but verification failed. "
                    "The WireGuard service may not be running properly.\n"
                    "Please check:\n"
                    "• Service status: 'systemctl status wg-quick@wg_main'\n"
                    "• Configuration: 'wg-quick strip wg_main'\n"
                    "• System logs: 'journalctl -xe'\n"
                    "A backup was created and can be restored if needed."
                )

            return {
                "success": True,
                "old_subnet": str(old_network),
                "new_subnet": str(new_network),
                "clients_updated": len(ip_mapping) - 1,  # Exclude server
                "backup_id": backup_id,
                "ip_mapping": ip_mapping
            }

        except Exception as e:
            # Attempt rollback on any error
            try:
                self.execute_emergency_rollback(backup_data)
            except Exception:
                raise NetworkError(
                    f"Critical error: Subnet change failed and rollback also failed. "
                    f"Original error: {str(e)}. "
                    f"Manual intervention required. Backup ID: {backup_id}"
                )

            raise NetworkError(f"Subnet change failed and was rolled back: {str(e)}")

    def create_comprehensive_migration_backup(self, backup_id: str) -> Dict[str, Any]:
        """Create comprehensive backup before migration"""
        backup_path = self.backup_dir / backup_id
        backup_path.mkdir(exist_ok=True)

        backup_data = {
            "id": backup_id,
            "timestamp": datetime.now().isoformat(),
            "original_subnet": self.config.get("wireguard", {}).get("network", DEFAULT_WG_NETWORK),
            "paths": {}
        }

        try:
            # 1. Backup WireGuard config
            if self.wg_config_file.exists():
                wg_backup = backup_path / "wg_main.conf"
                shutil.copy2(self.wg_config_file, wg_backup)
                backup_data["paths"]["wireguard_config"] = str(wg_backup)

            # 2. Backup main config
            main_config = self.install_dir / "config" / "phantom.json"
            if main_config.exists():
                config_backup = backup_path / "phantom.json"
                shutil.copy2(main_config, config_backup)
                backup_data["paths"]["main_config"] = str(config_backup)

            # 3. Backup client database
            clients_db = self.data_dir / "clients.db"
            if clients_db.exists():
                db_backup = backup_path / "clients.db"
                shutil.copy2(clients_db, db_backup)
                backup_data["paths"]["clients_db"] = str(db_backup)

            # 4. Backup firewall rules
            ufw_rules = self.firewall_ops.capture_current_firewall_rules()
            firewall_backup = backup_path / "firewall_rules.json"
            with open(firewall_backup, 'w') as f:
                json.dump(ufw_rules, f, indent=2)
            backup_data["paths"]["firewall_rules"] = str(firewall_backup)

            # 5. Save backup metadata
            metadata_file = backup_path / "backup_metadata.json"
            with open(metadata_file, 'w') as f:
                json.dump(backup_data, f, indent=2)

            return backup_data

        except Exception:
            # Clean up incomplete backup on failure
            if backup_path.exists():
                shutil.rmtree(backup_path, ignore_errors=True)
            raise ServiceOperationError(
                "Unable to create backup before subnet change. "
                "Please ensure:\n"
                "• Sufficient disk space in /opt/phantom-wg/backups/\n"
                "• Write permissions for the backup directory\n"
                "• No disk quota restrictions\n"
                "Cannot proceed without a backup for safety reasons."
            )

    def safely_stop_wireguard_service(self) -> None:
        """Safely stop WireGuard service"""
        result = self._run_command(["systemctl", "stop", f"wg-quick@{self.wg_interface}"])
        if result["returncode"] != 0:
            raise ServiceOperationError(
                "Unable to stop WireGuard service for subnet change.\n"
                f"Error details: {result['stderr']}\n\n"
                "Please try:\n"
                "• Manually stop the service: 'systemctl stop wg-quick@wg_main'\n"
                "• Check for stuck processes: 'ps aux | grep wg'\n"
                "• Review system logs: 'journalctl -u wg-quick@wg_main'\n"
                "The subnet change has been aborted for safety."
            )

        # Wait for service to fully stop
        time.sleep(1)

        # Remove the interface to prevent conflicts on restart
        self._run_command(["ip", "link", "delete", self.wg_interface])

    def safely_start_wireguard_service(self) -> None:
        """Safely start WireGuard service"""
        result = self._run_command(["systemctl", "start", f"wg-quick@{self.wg_interface}"])
        if result["returncode"] != 0:
            # Retry after cleaning up any remaining interface
            self._run_command(["ip", "link", "delete", self.wg_interface])
            time.sleep(1)
            result = self._run_command(["systemctl", "start", f"wg-quick@{self.wg_interface}"])
            if result["returncode"] != 0:
                raise ServiceOperationError(
                    "Unable to start WireGuard service after subnet change.\n"
                    f"Error details: {result['stderr']}\n\n"
                    "This is critical! Please:\n"
                    "• Check configuration syntax: 'wg-quick strip wg_main'\n"
                    "• Review the config file: '/etc/wireguard/wg_main.conf'\n"
                    "• Try manual start: 'systemctl start wg-quick@wg_main'\n"
                    "• Check logs: 'journalctl -u wg-quick@wg_main -n 100'\n"
                    "A backup exists and may need to be restored."
                )

        # Wait for service to fully initialize
        time.sleep(2)

    def verify_network_migration_success(self, new_network: ipaddress.IPv4Network) -> bool:
        """Verify that network migration was successful"""
        try:
            # 1. Check if service is running
            status_result = self._run_command(["systemctl", "is-active", f"wg-quick@{self.wg_interface}"])
            if status_result["returncode"] != 0:
                return False

            # 2. Check if interface has correct IP
            result = self._run_command(["ip", "addr", "show", self.wg_interface])
            if result["returncode"] == 0:
                expected_ip = str(new_network.network_address + 1)
                if expected_ip not in result["stdout"]:
                    return False
            else:
                return False

            # 3. Check if config reflects new subnet
            current_config = self.config.get("wireguard", {}).get("network", "")
            if current_config != str(new_network):
                return False

            return True

        except (OSError, ValueError, KeyError, AttributeError):
            return False

    def execute_emergency_rollback(self, backup_data: Dict[str, Any]) -> None:
        """Execute emergency rollback to restore previous state"""
        try:
            # Stop the service before restoring files
            self._run_command(["systemctl", "stop", f"wg-quick@{self.wg_interface}"])

            # Remove existing interface to prevent conflicts
            self._run_command(["ip", "link", "delete", self.wg_interface])

            # Wait to ensure interface is fully removed
            time.sleep(1)

            # Restore files
            paths = backup_data.get("paths", {})

            # Restore WireGuard config
            if "wireguard_config" in paths:
                shutil.copy2(paths["wireguard_config"], self.wg_config_file)

            # Restore main config
            if "main_config" in paths:
                shutil.copy2(paths["main_config"], self.install_dir / "config" / "phantom.json")

            # Restore client database
            if "clients_db" in paths:
                shutil.copy2(paths["clients_db"], self.data_dir / "clients.db")

            # Attempt to restore firewall rules
            original_subnet = backup_data.get("original_subnet")
            if original_subnet:
                try:
                    original_network = ipaddress.IPv4Network(original_subnet)
                    current_network = ipaddress.IPv4Network(
                        self.config.get("wireguard", {}).get("network", DEFAULT_WG_NETWORK)
                    )
                    self.firewall_ops.update_firewall_rules_for_new_subnet(current_network, original_network)
                except (OSError, ValueError):
                    pass

            # Reload config
            self.config = json.loads((self.install_dir / "config" / "phantom.json").read_text())

            # Start service and verify
            start_result = self._run_command(["systemctl", "start", f"wg-quick@{self.wg_interface}"])
            if start_result["returncode"] != 0:
                # Retry after additional cleanup
                self._run_command(["ip", "link", "delete", self.wg_interface])
                time.sleep(1)
                start_result = self._run_command(["systemctl", "start", f"wg-quick@{self.wg_interface}"])
                if start_result["returncode"] != 0:
                    raise ServiceOperationError(
                        f"Failed to restart WireGuard service after rollback. "
                        f"Error: {start_result.get('stderr', 'Unknown error')}"
                    )

        except Exception:
            raise ServiceOperationError(
                "CRITICAL: Rollback operation failed!\n"
                "The system may be in an inconsistent state.\n\n"
                "Immediate actions required:\n"
                "• Stop the WireGuard service: 'systemctl stop wg-quick@wg_main'\n"
                f"• Manually restore from backup at: {backup_data.get('backup_path', '/opt/phantom-wg/backups/')}\n"
                "• Check the backup metadata file for original configuration\n"
                "• Restart the service after manual restoration\n"
            )

    def update_server_network_configuration(self, new_network: ipaddress.IPv4Network,
                                            ip_mapping: Dict[str, str]) -> None:
        """Update server network configuration in WireGuard config file"""
        if not self.wg_config_file.exists():
            raise ConfigurationError(
                f"WireGuard configuration file not found at '{self.wg_config_file}'.\n"
                "This file is required for subnet changes. Please:\n"
                "• Verify WireGuard is properly installed\n"
                "• Check if the file exists: 'ls -la /etc/wireguard/'\n"
                "• Ensure the service has been initialized at least once\n"
                "Run 'phantom-wg' to initialize if this is a fresh installation."
            )

        # Retrieve current subnet information
        old_subnet = ipaddress.IPv4Network(
            self.config.get("wireguard", {}).get("network", DEFAULT_WG_NETWORK)
        )

        # Define patterns for parsing WireGuard configuration
        section_pattern = re.compile(r'^\[(Interface|Peer)]')
        key_value_pattern = re.compile(r'^(\w+)\s*=\s*(.+)$')

        # Read current config
        with open(self.wg_config_file, 'r') as f:
            config_lines = f.readlines()

        # Process each line
        updated_lines = []
        current_section = None

        for line in config_lines:
            stripped = line.strip()

            # Check for section header
            section_match = section_pattern.match(stripped)
            if section_match:
                current_section = section_match.group(1)
                updated_lines.append(line)
                continue

            # Check for key-value pair
            kv_match = key_value_pattern.match(stripped)
            if kv_match:
                key, value = kv_match.groups()

                # Update server IP address in Interface section
                if current_section == 'Interface' and key == 'Address':
                    # Update server address
                    old_server_ip = str(old_subnet.network_address + 1)
                    new_server_ip = ip_mapping[old_server_ip]

                    # Maintain CIDR notation format
                    if '/' in value:
                        prefix = value.split('/')[1]
                        new_value = f"{new_server_ip}/{prefix}"
                    else:
                        new_value = f"{new_server_ip}/{new_network.prefixlen}"

                    # Preserve original formatting
                    updated_lines.append(f"{key} = {new_value}\n")
                    continue

                # Update client IP addresses in Peer sections
                if current_section == 'Peer' and key == 'AllowedIPs':
                    # Parse allowed IPs
                    allowed_ips = [ip.strip() for ip in value.split(',')]
                    new_allowed_ips = []

                    for ip in allowed_ips:
                        # Parse IP address and CIDR notation
                        if '/' in ip:
                            ip_part = ip.split('/')[0]
                            cidr_part = ip.split('/')[1]
                        else:
                            ip_part = ip
                            cidr_part = '32'

                        # Update IP if it exists in our mapping
                        if ip_part in ip_mapping:
                            new_ip = ip_mapping[ip_part]
                            new_allowed_ips.append(f"{new_ip}/{cidr_part}")
                        else:
                            # Preserve IPs not in our subnet
                            new_allowed_ips.append(ip)

                    # Preserve original formatting
                    new_value = ', '.join(new_allowed_ips)
                    updated_lines.append(f"{key} = {new_value}\n")
                    continue

            # Preserve all other configuration lines
            updated_lines.append(line)

        # Write updated config
        with open(self.wg_config_file, 'w') as f:
            f.writelines(updated_lines)

    def update_main_config_with_new_subnet(self, new_subnet: str) -> None:
        """Update main configuration with new subnet"""
        self.config["wireguard"]["network"] = new_subnet
        self._save_config(self.config)

        # Update DataStore network configuration for future client allocations
        self.data_store.update_network_configuration(new_subnet)
