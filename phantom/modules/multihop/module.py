"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Multihop Yönlendirme Modülü
    ==========================================
    
    İstemci trafiğini harici VPN sağlayıcılar üzerinden yönlendirirken WireGuard
    peer erişimini koruyan gelişmiş yönlendirme modülü. Çoklu VPN atlama noktası
    desteği ile anonimlik ve güvenlik katmanları sağlar.
    
    API Endpoint'leri (9 adet):
        1. Yapılandırma: import_vpn_config, remove_vpn_config, list_exits
        2. Yönetim: enable_multihop, disable_multihop, reset_state
        3. Test ve Durum: status, test_vpn, get_session_log
    
    Mimari:
        İstemci trafiği akışı: İstemciler → Phantom → VPN Çıkışı → İnternet
        - WireGuard peer trafiği doğrudan sunucu üzerinden
        - systemd-networkd ile politika tabanlı yönlendirme
        - iptables NAT ve FORWARD kuralları ile trafik yönetimi
    
    Modül Özellikleri:
        - Harici VPN yapılandırma içe aktarma ve optimizasyon
        - PersistentKeepalive otomatik ayarlama (5 saniye)
        - Dinamik multihop yönlendirme aktivasyonu
        - Otomatik handshake izleme (systemd servisi)
        - Gerçek zamanlı oturum günlüğü
        - Otomatik rollback mekanizması
    
    Manager'lar (7 adet):
        - ConfigHandler: VPN yapılandırma doğrulama ve optimizasyon
        - NetworkAdmin: VPN arayüz yönetimi ve subnet algılama
        - RoutingManager: systemd-networkd ve iptables kuralları
        - ServiceManager: systemd servis yönetimi
        - ConnectionTester: VPN bağlantı testleri
        - StateManager: Durum kalıcılığı
        - SessionLogger: Oturum günlüğü yönetimi
    
    Model Mimarisi:
        Bu modül @dataclass modelleri kullanarak tip güvenliği sağlar:
        - VPNExitInfo: VPN çıkış noktası bilgileri
        - EnableMultihopResult: Aktivasyon sonuçları
        - ListExitsResult: Çıkış noktaları listesi
        - MultihopStatusResult: Durum bilgisi
        - DeactivationResult: Devre dışı bırakma sonuçları
        - RemoveConfigResult: Yapılandırma kaldırma sonuçları
        - VPNTestResult: Test sonuçları
        - ResetStateResult: Sıfırlama sonuçları
        Tüm modeller BaseModel'den inherit eder ve to_dict() ile API uyumluluğu sağlar.

EN: Phantom-WG Multihop Routing Module
    ==========================================
    
    Advanced routing module that routes client traffic through external VPN
    providers while maintaining WireGuard peer access. Provides anonymity and
    security layers with multiple VPN hop support.
    
    API Endpoints (9 total):
        1. Configuration: import_vpn_config, remove_vpn_config, list_exits
        2. Management: enable_multihop, disable_multihop, reset_state
        3. Test and Status: status, test_vpn, get_session_log
    
    Architecture:
        Client traffic flow: Clients → Phantom → VPN Exit → Internet
        - WireGuard peer traffic directly through server
        - Policy-based routing with systemd-networkd
        - Traffic management with iptables NAT and FORWARD rules
    
    Module Features:
        - External VPN configuration import and optimization
        - Automatic PersistentKeepalive adjustment (5 seconds)
        - Dynamic multihop routing activation
        - Automatic handshake monitoring (systemd service)
        - Real-time session logging
        - Automatic rollback mechanism
    
    Managers (7 total):
        - ConfigHandler: VPN configuration validation and optimization
        - NetworkAdmin: VPN interface management and subnet detection
        - RoutingManager: systemd-networkd and iptables rules
        - ServiceManager: systemd service management
        - ConnectionTester: VPN connection tests
        - StateManager: State persistence
        - SessionLogger: Session log management
    
    Model Architecture:
        This module uses @dataclass models for type safety:
        - VPNExitInfo: VPN exit node information
        - EnableMultihopResult: Activation results
        - ListExitsResult: Exit nodes list
        - MultihopStatusResult: Status information
        - DeactivationResult: Deactivation results
        - RemoveConfigResult: Configuration removal results
        - VPNTestResult: Test results
        - ResetStateResult: Reset results
        All models inherit from BaseModel and provide API compatibility via to_dict().

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from pathlib import Path
from typing import Dict, Any, Optional, Callable
from datetime import datetime

from phantom.modules.base import BaseModule
from phantom.api.exceptions import (
    MultihopError, VPNConfigError, ExitNodeError,
    ValidationError, MissingParameterError
)
from .models import (
    VPNExitInfo, EnableMultihopResult, ListExitsResult,
    MultihopStatusResult, DeactivationResult, RemoveConfigResult,
    TestResult, VPNTestResult, ResetStateResult
)

from .lib.common_tools import (
    VPN_INTERFACE_NAME
)

class MultihopModule(BaseModule):
    """Multihop VPN routing module - API version.

    Advanced routing module that routes client traffic through external
    VPN providers while maintaining WireGuard intra-network access.
    Provides multihop routing with systemd-networkd and iptables.

    Main Responsibilities:
        - External VPN configuration management
        - Dynamic routing rule creation
        - VPN interface lifecycle management
        - systemd-networkd policy management
        - iptables NAT and FORWARD rules
        - Handshake monitoring and auto-reconnection

    Features:
        - VPN configuration import and optimization
        - Automatic PersistentKeepalive adjustment
        - Dynamic routing rules management
        - Automatic handshake monitoring (systemd service)
        - Real-time session logging
        - Automatic rollback mechanism
        - Typed model support (to_dict() for API compatibility)

    Manager Architecture:
        Functional separation with 7 specialized managers:
        - ConfigHandler: VPN configuration operations
        - NetworkAdmin: Network interface management
        - RoutingManager: Routing rules
        - ServiceManager: systemd service management
        - ConnectionTester: Connection tests
        - StateManager: State persistence
        - SessionLogger: Session logging
    """

    def __init__(self, install_dir: Optional[Path] = None):
        """Initializes MultihopModule object and prepares directory structure.

        Inherits from BaseModule and loads multihop-specific configuration.
        Creates exit_configs directory to store VPN exit configurations.
        Provides functional separation with 7 managers.

        Args:
            install_dir: Installation directory path (default: /opt/phantom-wg)
        """
        super().__init__(install_dir)
        self.exit_configs_dir = self.install_dir / "exit_configs"
        self.exit_configs_dir.mkdir(exist_ok=True)

        # Initialize lib managers - lazy imports for optimization
        from .lib.config_handler import ConfigHandler
        from .lib.network_admin import NetworkAdmin
        from .lib.routing_manager import RoutingManager
        from .lib.service_manager import ServiceManager
        from .lib.connection_tester import ConnectionTester
        from .lib.state_manager import StateManager
        from .lib.session_logger import SessionLogger
        self.config_handler = ConfigHandler(self.exit_configs_dir, self.config, self.logger)
        self.network_admin = NetworkAdmin(self.config, self.logger, self._run_command)
        self.routing_manager = RoutingManager(self.config, self.logger, self._run_command)
        self.service_manager = ServiceManager(self.config, self.logger, self._run_command)
        self.connection_tester = ConnectionTester(self.config, self.logger, self._run_command)
        self.state_manager = StateManager(self.config, self.logger, self._save_config)
        self.session_logger = SessionLogger(self.logs_dir, self.logger)

        # Session logging handled by SessionLogger
        # Monitor settings removed - now handled by systemd service only

        # Load multihop state using StateManager
        self.state_manager.load_multihop_state()
        # Maintain backward compatibility with existing code
        self.multihop_enabled = self.state_manager.multihop_enabled
        self.active_exit = self.state_manager.active_exit

    def get_module_name(self) -> str:
        """Return module name."""
        return "multihop"

    def get_module_description(self) -> str:
        """Return module description."""
        return "Route traffic through external VPN providers while keeping WireGuard peer access"

    def get_actions(self) -> Dict[str, Callable]:
        """Return all available actions this module can perform.

        Provides 9 API endpoints for multihop management:
            - import_vpn_config: Import VPN configuration
            - remove_vpn_config: Remove VPN configuration
            - list_exits: List exit nodes
            - enable_multihop: Enable multihop routing
            - disable_multihop: Disable multihop routing
            - reset_state: Reset state
            - status: Query current status
            - test_vpn: Test VPN connection
            - get_session_log: Access session log

        Returns:
            Dict[str, Callable]: Map of action names to their handler methods
        """
        return {
            # VPN Configuration Management
            "import_vpn_config": self.import_vpn_config,
            "remove_vpn_config": self.remove_vpn_config,
            "list_exits": self.list_exits,

            # Multihop Routing Management
            "enable_multihop": self.enable_multihop,
            "disable_multihop": self.disable_multihop,
            "reset_state": self.reset_state,

            # Status and Testing
            "status": self.get_status,
            "test_vpn": self.test_vpn,
            "get_session_log": self.get_session_log
        }

    def import_vpn_config(self, config_path: str, custom_name: Optional[str] = None) -> Dict[str, Any]:
        """Imports VPN provider WireGuard configuration.

        Imports WireGuard configuration file from external VPN provider,
        validates and optimizes it for multihop usage. Automatically sets
        PersistentKeepalive value.

        Args:
            config_path: Path to VPN configuration file
            custom_name: Optional custom name for configuration

        Returns:
            Dict with import result and optimizations applied

        Raises:
            MissingParameterError: If config_path is not provided
            VPNConfigError: If configuration is invalid or import fails
        """
        # Validate input
        if not config_path:
            raise MissingParameterError("config_path is required")

        config_file = Path(config_path)
        if not config_file.exists():
            raise VPNConfigError(f"Config file not found: {config_path}")

        try:
            # Read and parse config
            with open(config_file, 'r') as f:
                config_content = f.read()

            # Parse config to extract name and validate (using ConfigHandler)
            config_name = self._extract_config_name(config_content, config_path, custom_name)

            # Validate VPN config
            validation_result = self.config_handler.validate_vpn_config(config_content)
            if not validation_result["valid"]:
                raise VPNConfigError(f"Invalid VPN configuration: {validation_result['error']}")

            # Create backup of original config
            backup_path = f"{config_path}.backup"
            with open(backup_path, 'w') as f:
                f.write(config_content)

            # Enhance config for multihop stability
            enhanced_config, optimizations = self.config_handler.enhance_vpn_config_for_multihop(config_content)

            # Save enhanced config
            exit_config_file = self.exit_configs_dir / f"{config_name}.conf"
            with open(exit_config_file, 'w') as f:
                f.write(enhanced_config)

            # Save metadata (using ConfigHandler)
            metadata = {
                "name": config_name,
                "imported_at": datetime.now().isoformat(),
                "original_path": config_path,
                "backup_path": backup_path,
                "config_file": str(exit_config_file),
                "provider": 'Phantom-WG',
                "optimizations_applied": optimizations,
                "multihop_enhanced": True
            }

            metadata_file = self.exit_configs_dir / f"{config_name}.json"
            self._write_json_file(metadata_file, metadata)

            return {
                "config_name": config_name,
                "backup_path": backup_path,
                "metadata": metadata,
                "optimizations": optimizations,
                "message": f"VPN config '{config_name}' imported and optimized for multihop"
            }

        except Exception as e:
            if isinstance(e, (MultihopError, VPNConfigError, ValidationError)):
                raise
            raise VPNConfigError(f"Failed to import config: {str(e)}")

    def list_exits(self) -> Dict[str, Any]:
        """Lists available VPN exit configurations.

        Lists all imported VPN configurations with metadata information.
        Shows endpoint, provider and active status for each configuration.

        Returns:
            Dict with list of exit configurations
        """
        config_files = list(self.exit_configs_dir.glob("*.conf"))

        exits = []
        for config_file in config_files:
            # Handle both Path and string types
            config_name = config_file.stem if hasattr(config_file, 'stem') else Path(config_file).stem
            metadata_file = self.exit_configs_dir / f"{config_name}.json"

            # Load metadata if available
            metadata = self._read_json_file(metadata_file)

            # Extract endpoint from config
            try:
                with open(config_file, 'r') as f:
                    config_content = f.read()
                endpoint = self.config_handler.extract_endpoint(config_content)
            except (OSError, IOError, UnicodeDecodeError):
                endpoint = "Unknown"

            # Build exit info using typed model internally
            exit_info = VPNExitInfo(
                name=config_name,
                endpoint=endpoint or "Unknown",
                active=config_name == self.active_exit,
                provider=metadata.get("provider", "Phantom-WG"),
                imported_at=metadata.get("imported_at"),
                multihop_enhanced=metadata.get("multihop_enhanced", False)
            )

            exits.append(exit_info)

        # Create typed result internally
        result = ListExitsResult(
            exits=exits,
            multihop_enabled=self.multihop_enabled,
            active_exit=self.active_exit,
            total=len(exits)
        )

        # Return as dict for API compatibility
        return result.to_dict()

    def enable_multihop(self, exit_name: str) -> Dict[str, Any]:
        """Enables multihop routing through VPN exit.

        Starts multihop routing using specified VPN exit node. Configures
        traffic routing with systemd-networkd policy rules and iptables
        NAT rules. Connection is automatically tested and handshake
        monitoring is started.

        Args:
            exit_name: Name of VPN exit configuration to use

        Returns:
            Dict with activation result and connection status

        Raises:
            MissingParameterError: If exit_name is not provided
            ExitNodeError: If VPN configuration not found
            MultihopError: If activation or connection test fails
        """
        if not exit_name:
            raise MissingParameterError("exit_name is required")

        exit_config_file = self.exit_configs_dir / f"{exit_name}.conf"
        if not exit_config_file.exists():
            raise ExitNodeError(f"VPN config '{exit_name}' not found")

        try:
            self.logger.info("Ensuring clean state before enabling multihop")
            cleanup_result = self.network_admin.cleanup_vpn_interface_basic()
            if not cleanup_result["success"]:
                self.logger.warning(f"Pre-enable cleanup had issues: {cleanup_result.get('error', 'Unknown')}")

            # Setup multihop routing
            setup_result = self._setup_multihop_routing(exit_name, str(exit_config_file))
            if not setup_result["success"]:
                raise MultihopError(f"Failed to setup multihop routing: {setup_result.get('error', 'Unknown error')}")

            # Initialize state variables temporarily
            temp_multihop_enabled = True
            temp_active_exit = exit_name

            # Initialize session log
            self.session_logger.init_session_log(exit_name)

            # Wait for VPN handshake and test connection
            handshake_result = self.connection_tester.wait_for_vpn_handshake(timeout=30)
            if not handshake_result["success"]:
                # Auto-rollback
                self._disable_multihop_silently()
                raise MultihopError(
                    "VPN handshake timeout - server may be unreachable or overloaded",
                    data={"handshake_result": handshake_result}
                )

            # Test VPN connection
            test_result = self.connection_tester.test_vpn_connection_silently(exit_name, self.exit_configs_dir)
            if not test_result["success"]:
                # Auto-rollback
                self._disable_multihop_silently()
                raise MultihopError(
                    "VPN connection test failed",
                    data={
                        "test_result": test_result,
                        "possible_issues": [
                            "VPN server unreachable",
                            "Incorrect VPN configuration",
                            "Network connectivity problems",
                            "IP routing not working through VPN"
                        ]
                    }
                )

            # Test passed, save state permanently
            self.multihop_enabled = temp_multihop_enabled
            self.active_exit = temp_active_exit
            self.state_manager.update_state(self.multihop_enabled, self.active_exit)

            # Start handshake monitor service
            self.service_manager.start_monitor_service()

            # Get endpoint for traffic_flow display
            with open(exit_config_file, 'r') as f:
                config_content = f.read()
            endpoint = self.config_handler.extract_endpoint(config_content) or "Unknown"

            # Create typed result internally
            result = EnableMultihopResult(
                exit_name=exit_name,
                multihop_enabled=True,
                handshake_established=True,
                connection_verified=True,
                monitor_started=True,
                traffic_flow=f"Clients → Phantom → VPN Exit ({endpoint})",
                peer_access="Peers can still connect directly",
                message=f"Multihop enabled successfully through {exit_name}"
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            if isinstance(e, (MultihopError, ExitNodeError, ValidationError)):
                raise
            raise MultihopError(f"Failed to enable multihop: {str(e)}")

    def disable_multihop(self) -> Dict[str, Any]:
        """Disables multihop routing.

        Stops active multihop routing, removes VPN interface, cleans up
        routing rules and stops handshake monitoring service. Client
        traffic is routed directly through server again.

        Returns:
            Dict with deactivation result
        """
        if not self.multihop_enabled:
            return {
                "multihop_enabled": False,
                "message": "Multihop is not currently enabled"
            }

        try:
            previous_exit = self.active_exit

            # Stop handshake monitor service
            self.service_manager.stop_monitor_service()

            # Clean up session log
            self.session_logger.cleanup_session_log()

            # Remove systemd-networkd routing policy (use RoutingManager)
            self.routing_manager.remove_networkd_routing_policy(VPN_INTERFACE_NAME)

            # Cleanup VPN interface (use NetworkAdmin)
            cleanup_result = self.network_admin.cleanup_vpn_interface_basic()

            # Update state
            self.multihop_enabled = False
            self.active_exit = None
            self.state_manager.update_state(self.multihop_enabled, self.active_exit)

            # Cleanup sonrası doğrulama ekle
            wg_config = self.config.get("wireguard", {})
            wg_network = wg_config.get("network", "10.8.0.0/24")

            # Final cleanup verification
            # noinspection PyProtectedMember
            if not self.network_admin._verify_rules_cleaned(wg_network):
                self.logger.warning("Some routing rules may persist - forcing cleanup")
                # noinspection PyProtectedMember
                self.network_admin._force_cleanup_rules(wg_network)

            # Create typed result internally
            result = DeactivationResult(
                multihop_enabled=False,
                previous_exit=previous_exit,
                interface_cleaned=cleanup_result["success"],
                message="Multihop routing disabled - client traffic now routes directly through server"
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            raise MultihopError(f"Failed to disable multihop: {str(e)}")

    def get_status(self) -> Dict[str, Any]:
        """Returns multihop status.

        Returns comprehensive status information including multihop
        activation status, active VPN exit, available configurations,
        VPN interface status and handshake monitoring service status.

        Returns:
            Dict with current multihop status
        """
        # Get VPN interface status (use NetworkAdmin)
        vpn_interface_status = self.network_admin.get_vpn_interface_status()

        # Get available VPN configs
        config_files = list(self.exit_configs_dir.glob("*.conf"))

        # Get monitor status
        monitor_status = self.service_manager.get_monitor_status()

        # Create typed result internally
        result = MultihopStatusResult(
            enabled=self.multihop_enabled,
            active_exit=self.active_exit,
            available_configs=len(config_files),
            vpn_interface=vpn_interface_status,
            monitor_status=monitor_status,
            traffic_routing="VPN Exit" if self.multihop_enabled else "Direct",
            traffic_flow="Clients -> Phantom Server -> VPN Exit -> Internet" if self.multihop_enabled else "Clients -> Phantom Server -> Internet (direct)"
        )

        # Return as dict for API compatibility
        return result.to_dict()

    def remove_vpn_config(self, exit_name: str) -> Dict[str, Any]:
        """Removes VPN configuration.

        Removes specified VPN exit configuration from system. If this
        configuration is actively in use, multihop is disabled first.

        Args:
            exit_name: Name of VPN configuration to remove

        Returns:
            Dict with removal result

        Raises:
            MissingParameterError: If exit_name is not provided
            ExitNodeError: If VPN configuration not found
            MultihopError: If removal fails
        """
        if not exit_name:
            raise MissingParameterError("exit_name is required")

        # Check if this VPN is currently active
        was_active = False
        if self.active_exit == exit_name:
            was_active = True
            # Disable multihop first
            self.disable_multihop()

        # Remove config files
        config_file = self.exit_configs_dir / f"{exit_name}.conf"
        metadata_file = self.exit_configs_dir / f"{exit_name}.json"

        if not config_file.exists():
            raise ExitNodeError(f"VPN configuration '{exit_name}' not found")

        try:
            if config_file.exists():
                config_file.unlink()
            if metadata_file.exists():
                metadata_file.unlink()

            # Create typed result internally
            result = RemoveConfigResult(
                removed=exit_name,
                was_active=was_active,
                message=f"VPN configuration '{exit_name}' removed"
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            raise MultihopError(f"Failed to remove VPN config: {str(e)}")

    def test_vpn(self) -> Dict[str, Any]:
        """Tests VPN connection.

        Performs connection tests for specified or active VPN connection.
        Checks network accessibility, VPN interface status and WireGuard
        handshake status.

        Returns:
            Dict with test results

        Raises:
            ValidationError: If no VPN specified and none active
            ExitNodeError: If VPN configuration not found
            MultihopError: If test fails
        """
        if not self.active_exit:
            raise ValidationError("No active VPN to test - specify exit_name")
        exit_name = self.active_exit

        exit_config_file = self.exit_configs_dir / f"{exit_name}.conf"
        if not exit_config_file.exists():
            raise ExitNodeError(f"VPN config '{exit_name}' not found")

        try:
            # Extract endpoint from config
            with open(exit_config_file, 'r') as f:
                config_content = f.read()

            endpoint = self.config_handler.extract_endpoint(config_content)
            if not endpoint:
                raise VPNConfigError("No endpoint found in config")

            # Parse endpoint
            host, port = endpoint.split(':')

            # Create typed test results internally
            tests = {}

            # Test network connectivity
            ping_result = self._run_command(['ping', '-c', '3', '-W', '5', host])
            tests["network_connectivity"] = TestResult(
                passed=ping_result["success"],
                host=host
            )

            # Test VPN interface connectivity (if VPN is active)
            if self.active_exit == exit_name:
                vpn_ip = self.config_handler.extract_vpn_ip(config_content)
                if vpn_ip:
                    vpn_ping_result = self._run_command(['ping', '-c', '1', '-W', '2', vpn_ip])
                    tests["vpn_interface"] = TestResult(
                        passed=vpn_ping_result["success"],
                        vpn_ip=vpn_ip
                    )

                # Check WireGuard handshake
                wg_result = self._run_command(['wg', 'show', VPN_INTERFACE_NAME])
                has_handshake = wg_result["success"] and 'latest handshake' in wg_result["stdout"]
                tests["wireguard_handshake"] = TestResult(
                    passed=has_handshake,
                    has_recent_handshake=bool(has_handshake)
                )

            # Create typed result internally
            all_passed = all(test.passed for test in tests.values())
            result = VPNTestResult(
                exit_name=exit_name,
                endpoint=endpoint,
                tests=tests,
                all_tests_passed=all_passed,
                message="All tests passed" if all_passed else "Some tests failed"
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            if isinstance(e, (ExitNodeError, VPNConfigError, ValidationError)):
                raise
            raise MultihopError(f"Test failed: {str(e)}")

    def reset_state(self) -> Dict[str, Any]:
        """Resets multihop state and cleans up all VPN interfaces.

        Cleans up all multihop routing rules, VPN interfaces, NAT
        rules and policy-based routing. System is returned to default
        direct routing mode.

        Returns:
            Dict with reset result

        Raises:
            MultihopError: If reset fails
        """
        try:
            # Remove systemd-networkd routing policy (use RoutingManager)
            self.routing_manager.remove_networkd_routing_policy(VPN_INTERFACE_NAME)

            # Use comprehensive cleanup (use NetworkAdmin)
            cleanup_result = self.network_admin.cleanup_vpn_interface()

            # Reset multihop state completely
            self.multihop_enabled = False
            self.active_exit = None
            self.state_manager.update_state(self.multihop_enabled, self.active_exit)

            # Create typed result internally
            result = ResetStateResult(
                reset_complete=True,
                cleanup_successful=cleanup_result["success"],
                cleaned_up=[
                    "VPN interfaces (" + VPN_INTERFACE_NAME + ")",
                    "Multihop routing rules",
                    "Policy routing tables",
                    "NAT rules",
                    "Multihop configuration state",
                    "systemd-networkd routing policies"
                ],
                message="Multihop state reset completed - system returned to default direct routing"
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            raise MultihopError(f"Failed to reset multihop state: {str(e)}")

    def get_session_log(self, lines: int = 50) -> Dict[str, Any]:
        """Returns current multihop session log.

        Returns handshake monitoring log of active multihop session.
        Log lines are presented structured with timestamp, message
        and severity level.

        Args:
            lines: Number of lines to return (default: 50)

        Returns:
            Dict with session log data

        Raises:
            MultihopError: If reading log fails
        """
        try:
            return self.session_logger.get_session_log(
                lines=lines,
                multihop_enabled=self.multihop_enabled,
                active_exit=self.active_exit,
                get_monitor_status_func=self.service_manager.get_monitor_status
            )
        except Exception as e:
            raise MultihopError(f"Failed to read session log: {str(e)}")

    # Private helper methods

    def _extract_config_name(self, config_content: str, config_path: str, custom_name: Optional[str] = None) -> str:
        """Extracts or creates a name for configuration.

        Uses custom name if provided, otherwise creates name from
        filename or endpoint information. Checks for name conflicts
        and converts to alphanumeric characters.

        Args:
            config_content: VPN configuration content
            config_path: Path to configuration file
            custom_name: Optional custom name

        Returns:
            str: Sanitized configuration name

        Raises:
            VPNConfigError: If name cannot be determined or already exists
        """
        if custom_name:
            config_name = custom_name
        else:
            # Try to extract from filename first
            base_name = Path(config_path).stem
            if base_name and base_name not in ["wg", "client", "config"]:
                config_name = base_name
            else:
                # Extract from endpoint
                endpoint = self.config_handler.extract_endpoint(config_content)
                if endpoint:
                    host = endpoint.split(':')[0]
                    config_name = host.replace('.', '_').replace('-', '_')
                else:
                    raise VPNConfigError("Could not determine config name - please provide custom_name")

        # Sanitize name
        config_name = ''.join(c for c in config_name if c.isalnum() or c in '-_').lower()

        if not config_name:
            raise VPNConfigError("Invalid config name")

        # Check if already exists
        existing_config = self.exit_configs_dir / f"{config_name}.conf"
        if existing_config.exists():
            raise VPNConfigError(f"Config '{config_name}' already exists")

        return config_name

    def _setup_multihop_routing(self, exit_name: str, config_file: str) -> Dict[str, Any]:
        """Sets up multihop routing configuration.

        Creates VPN interface, configures systemd-networkd policy rules,
        applies iptables NAT rules and verifies connection. Returns
        success status of all steps.

        Args:
            exit_name: Name of VPN exit configuration
            config_file: Path to VPN configuration file

        Returns:
            Dict[str, Any]: Setup result with success status of each step
        """
        self.logger.info(f"Setting up multihop routing for VPN: {exit_name}")

        try:
            # Read VPN config
            with open(config_file, 'r') as f:
                config_content = f.read()

            # Get current WireGuard network (use NetworkAdmin)
            wg_network = self.network_admin.detect_current_subnet()

            # Setup VPN interface (use NetworkAdmin)
            vpn_interface = VPN_INTERFACE_NAME
            interface_result = self.network_admin.setup_vpn_interface(vpn_interface, config_content)
            if not interface_result["success"]:
                return {"success": False, "error": interface_result.get("error", "Failed to setup VPN interface")}

            # Setup systemd-networkd routing policy (use RoutingManager)
            networkd_result = self.routing_manager.create_networkd_routing_policy(vpn_interface, wg_network)

            # Apply routing rules immediately (use RoutingManager)
            rules_result = self.routing_manager.apply_routing_rules_immediately(wg_network, vpn_interface)

            # Wait for VPN interface to be fully up
            import time
            time.sleep(2)

            # Verify VPN interface is active
            interface_check = self._run_command(["ip", "link", "show", vpn_interface])
            if not interface_check["success"]:
                return {"success": False, "error": f"VPN interface {vpn_interface} is not active"}

            # Activate multihop firewall profile (use RoutingManager)
            firewall_result = self.routing_manager.setup_routing_rules_manual(wg_network, vpn_interface)
            if not firewall_result["success"]:
                error_details = firewall_result.get("error", "Unknown error")
                failed_cmds = firewall_result.get("failed_commands", [])
                error_msg = f"Failed to activate multihop firewall profile: {error_details}"
                if failed_cmds:
                    error_msg += f"\nFailed commands:\n" + "\n".join(failed_cmds)
                return {"success": False, "error": error_msg}

            # Verify VPN connection (use NetworkAdmin)
            verify_result = self.network_admin.verify_vpn_connection(vpn_interface)

            return {
                "success": True,
                "wg_network": wg_network,
                "vpn_interface": vpn_interface,
                "interface_setup": interface_result["success"],
                "networkd_policy": networkd_result["success"],
                "routing_rules": rules_result["success"],
                "firewall_activated": firewall_result["success"],
                "connection_verified": verify_result["success"]
            }

        except Exception as e:
            self.logger.error(f"Failed to setup multihop routing: {e}")
            return {"success": False, "error": str(e)}

    def _disable_multihop_silently(self) -> bool:
        """Silently disables multihop for auto-rollback.

        Disables multihop without notifying user in case of error
        and performs cleanup.

        Returns:
            bool: True if successful, False otherwise
        """
        try:
            if not self.multihop_enabled:
                return True

            self.routing_manager.remove_networkd_routing_policy(VPN_INTERFACE_NAME)
            self.network_admin.cleanup_vpn_interface_basic()

            self.multihop_enabled = False
            self.active_exit = None
            self.state_manager.update_state(self.multihop_enabled, self.active_exit)

            return True

        except Exception as e:
            self.logger.error(f"Failed to disable multihop silently: {e}")
            return False
