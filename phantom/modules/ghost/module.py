"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG Ghost Mode Sansür Dayanıklılık Modülü
    ==========================================
    
    WireGuard trafiğini WebSocket üzerinden tünelleyerek sansür sistemlerini
    atlatan gelişmiş modül. SSL/TLS şifrelemesi ve domain kullanarak DPI (Deep
    Packet Inspection) sistemlerini ve port engellemelerini aşar.
    
    API Endpoint'leri (3 adet):
        1. Yönetim: enable, disable  
        2. Durum: status
    
    Mimari:
        WireGuard (51820) → wstunnel → WebSocket (443/SSL)
        - İstemci: WireGuard → wstunnel client → wss://domain
        - Sunucu: wstunnel server → localhost:51820 → WireGuard
    
    Modül Özellikleri:
        - Let's Encrypt ile otomatik SSL sertifikası yönetimi
        - DNS A kayıt doğrulaması
        - UFW güvenlik duvarı entegrasyonu (443, 80 portları)
        - systemd servis yönetimi (wstunnel.service)
        - Durum yedekleme ve geri yükleme (ghost-state.json)
        - Otomatik rollback mekanizması
    
    Manager'lar (6 adet):
        - ssl_utils: Let's Encrypt sertifika yönetimi
        - wstunnel_utils: wstunnel kurulum ve yapılandırma
        - firewall_utils: UFW kural yönetimi
        - state_manager: Durum kalıcılığı ve yönetimi
        - dns_utils: DNS kayıt doğrulama ve IP çözümleme
        - network_utils: Ağ yapılandırma ve temizlik
    
    Model Mimarisi:
        Bu modül @dataclass modelleri kullanarak tip güvenliği sağlar:
        - EnableGhostResult: Etkinleştirme sonuçları
        - DisableGhostResult: Devre dışı bırakma sonuçları
        - GhostStatusResult: Durum bilgisi
        - GhostServiceInfo: Servis durumları
        Tüm modeller BaseModel'den inherit eder ve to_dict() ile API uyumluluğu sağlar.
    
    Referans:
        Hetzner Community tutorial'dan esinlenilmiştir:
        https://community.hetzner.com/tutorials/obfuscating-wireguard-using-wstunnel

EN: Phantom-WG Ghost Mode Censorship Resistance Module
    ==========================================
    
    Advanced module that bypasses censorship systems by tunneling WireGuard traffic
    over WebSocket. Uses SSL/TLS encryption and domains to bypass DPI (Deep Packet
    Inspection) systems and port blocking.
    
    API Endpoints (3 total):
        1. Management: enable, disable
        2. Status: status
    
    Architecture:
        WireGuard (51820) → wstunnel → WebSocket (443/SSL)
        - Client: WireGuard → wstunnel client → wss://domain
        - Server: wstunnel server → localhost:51820 → WireGuard
    
    Module Features:
        - Automatic SSL certificate management with Let's Encrypt
        - DNS A record validation
        - UFW firewall integration (ports 443, 80)
        - systemd service management (wstunnel.service)
        - State backup and restore (ghost-state.json)
        - Automatic rollback mechanism
    
    Managers (6 total):
        - ssl_utils: Let's Encrypt certificate management
        - wstunnel_utils: wstunnel installation and configuration
        - firewall_utils: UFW rule management
        - state_manager: State persistence and management
        - dns_utils: DNS record validation and IP resolution
        - network_utils: Network configuration and cleanup
    
    Model Architecture:
        This module uses @dataclass models for type safety:
        - EnableGhostResult: Enable operation results
        - DisableGhostResult: Disable operation results
        - GhostStatusResult: Status information
        - GhostServiceInfo: Service status
        All models inherit from BaseModel and provide API compatibility via to_dict().
    
    Reference:
        Inspired by Hetzner Community tutorial:
        https://community.hetzner.com/tutorials/obfuscating-wireguard-using-wstunnel

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from pathlib import Path
from typing import Dict, Any, Optional

from phantom.modules.base import BaseModule
from phantom.api.exceptions import (
    GhostModeError,
    GhostModeActiveError,
    ValidationError
)
from .models import (
    EnableGhostResult, DisableGhostResult, GhostServiceInfo, GhostStatusResult
)

# Import library modules
from .lib import ssl_utils, wstunnel_utils, firewall_utils
from .lib import state_manager, dns_utils, network_utils

# Module constants
DNS_VALIDATION_SERVER = "8.8.8.8"


class GhostModule(BaseModule):
    """Ghost Mode censorship resistance module - API version.

    Module that bypasses censorship systems by tunneling WireGuard
    traffic over WebSocket. Uses SSL/TLS encryption and domains
    to bypass DPI blocking. Provides automatic certificate management
    with Let's Encrypt.

    Main Responsibilities:
        - WebSocket tunneling setup and management
        - SSL certificate automation (Let's Encrypt)
        - DNS record validation and management
        - UFW firewall rule management
        - Service lifecycle management
        - State persistence and rollback

    Features:
        - WebSocket tunneling with wstunnel
        - Automatic SSL certificate management
        - DNS A record validation
        - UFW rule automation (443, 80)
        - systemd integration
        - State backup (ghost-state.json)
        - Automatic rollback on failure
        - Typed model support (to_dict() for API compatibility)

    Manager Architecture:
        Functional separation with 6 specialized managers:
        - ssl_utils: Certificate operations
        - wstunnel_utils: Tunnel management
        - firewall_utils: Firewall rules
        - state_manager: State management
        - dns_utils: DNS operations
        - network_utils: Network configuration
    """

    def __init__(self, install_dir: Optional[Path] = None):
        """Initialize GhostModule and load Ghost Mode state.

        Inherits from BaseModule and loads Ghost Mode-specific configuration
        from ghost-state.json file. Sets up wstunnel installation directory
        and state file paths.

        Args:
            install_dir: Installation directory path (default: /opt/phantom-wg)
        """
        super().__init__(install_dir)
        self.state_file = self.config_dir / "ghost-state.json"
        self.wstunnel_dir = Path("/opt/wstunnel")
        self.state = state_manager.load_state(self.state_file, self._read_json_file)

    def get_module_name(self) -> str:
        """Return module name."""
        return "ghost"

    def get_module_description(self) -> str:
        """Return module description."""
        return "Censorship-resistant WireGuard connections using wstunnel"

    def get_actions(self) -> Dict[str, Any]:
        """Return all available actions this module can perform.

        Provides 3 API endpoints for Ghost Mode management:
        - enable: Enables Ghost Mode
        - disable: Disables Ghost Mode
        - status: Returns current status and connection information

        Returns:
            Dict[str, Any]: Map of action names to their handler methods
        """
        return {
            # Ghost Mode Management Actions
            "enable": self.enable_ghost_mode,
            "disable": self.disable_ghost_mode,
            "status": self.get_status
        }

    def enable_ghost_mode(self, domain: str) -> Dict[str, Any]:
        """Enable Ghost Mode and provide censorship-resistant connection.

        This action performs:
        1. Validates domain parameter
        2. Checks if Ghost Mode is not already active
        3. Gets server IP and validates DNS A record
        4. Obtains SSL certificate with Let's Encrypt
        5. Installs and configures wstunnel
        6. Updates UFW firewall rules (443, 80)
        7. Starts services and saves state

        Returns EnableGhostResult model and converts to dict via to_dict().
        Automatic rollback on failure.

        Args:
            domain: Domain name for SSL certificate (must have valid A record pointing to server)

        Returns:
            Dict containing:
            - status: Operational status ("active")
            - server_ip: Server public IP address
            - domain: Configured domain name
            - secret: Authentication secret for wstunnel
            - protocol: Connection protocol ("wss")
            - port: Connection port (443)
            - activated_at: Activation timestamp
            - connection_command: Client connection instructions

        Raises:
            ValidationError: If domain is invalid or missing A record
            GhostModeActiveError: If Ghost Mode is already active
            GhostModeError: If setup fails at any step
        """
        # Validate domain parameter
        if not domain:
            raise ValidationError("Domain is required for Ghost Mode")

        # Check if already enabled
        if self.state.get("enabled", False):
            raise GhostModeActiveError(
                "Ghost Mode is already active",
                data={
                    "server_ip": self.state.get("server_ip"),
                    "domain": self.state.get("domain"),
                    "secret": self.state.get("secret"),
                    "protocol": "wss",
                    "activated_at": self.state.get("installed_at")
                }
            )

        # Get server IP
        server_ip = dns_utils.get_server_ip(self._run_command, self.logger)

        # Validate domain A record
        if not dns_utils.validate_domain_a_record(domain, server_ip, self._run_command, self.logger):
            raise ValidationError(
                f"Domain {domain} does not have an A record pointing to {server_ip}. "
                f"Please create an A record for {domain} pointing to {server_ip} and try again."
            )

        # Initialize state with domain
        self.state = state_manager.init_state(server_ip, domain)
        state_manager.save_state(self.state_file, self.state, self._write_json_file)

        try:
            # Setup SSL certificate first
            self.logger.info("Setting up SSL certificate...")
            if not ssl_utils.setup_ssl(domain, self.logger, self._run_command):
                raise GhostModeError("Failed to obtain SSL certificate")
            # Install wstunnel
            self.logger.info("Installing wstunnel...")
            wstunnel_utils.install_wstunnel(self.wstunnel_dir, self.state, self._run_command, self.logger)

            # Configure wstunnel service
            self.logger.info("Configuring wstunnel service...")
            wstunnel_utils.configure_wstunnel(self.state, self._run_command)

            # Configure firewall rules
            self.logger.info("Configuring firewall rules...")
            firewall_utils.configure_firewall(self.state, self._run_command, self.logger)

            # Start services
            self.logger.info("Starting services...")
            wstunnel_utils.start_services(self._run_command)

            # Mark as enabled
            self.state["enabled"] = True
            state_manager.save_state(self.state_file, self.state, self._write_json_file)

            # Create typed result internally
            result = EnableGhostResult(
                status="active",
                server_ip=server_ip,
                domain=domain,
                secret=self.state["secret"],
                protocol="wss",
                port=443,
                activated_at=self.state["installed_at"],
                connection_command=network_utils.get_connection_command(self.state)
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            self.logger.error(f"Failed to enable Ghost Mode: {e}")
            # Rollback on failure
            state_manager.rollback(self, self.logger)
            raise GhostModeError(f"Failed to enable Ghost Mode: {str(e)}")

    def disable_ghost_mode(self) -> Dict[str, Any]:
        """Disable Ghost Mode and restore normal operation.

        This action performs:
        1. Checks if Ghost Mode is active
        2. Stops wstunnel service
        3. Removes wstunnel binary and configurations
        4. Cleans network configuration files
        5. Removes UFW firewall rules
        6. Deletes SSL certificates (Let's Encrypt)
        7. Cleans ghost-state.json file

        Returns DisableGhostResult model and converts to dict via to_dict().
        System returns to normal WireGuard mode.

        Returns:
            Dict containing:
            - status: Operational status ("inactive")
            - message: Operation result message
            - restored: Whether normal operation was restored

        Raises:
            GhostModeError: If disable operation fails at any step
        """
        if not self.state.get("enabled", False):
            # Create typed result internally
            result = DisableGhostResult(
                status="inactive",
                message="Ghost Mode is not active"
            )
            # Return as dict for API compatibility
            return result.to_dict()

        try:
            self.logger.info("Disabling Ghost Mode...")

            # Stop services
            wstunnel_utils.stop_services(self._run_command)

            # Clean all files
            network_utils.clean_files(self.state, self.logger)

            # Remove wstunnel
            wstunnel_utils.remove_wstunnel(self.wstunnel_dir, self._run_command)

            # Remove firewall rules
            firewall_utils.remove_firewall_rules(self.state, self._run_command, self.logger)

            # Remove SSL certificates
            ssl_utils.remove_certificates(self.state, self._run_command, self.logger)

            # Final cleanup
            network_utils.final_cleanup(self.state_file)

            # Reload state to ensure UI reflects current status
            # This prevents stale Ghost Mode status after disable operation
            self.state = state_manager.load_state(self.state_file, self._read_json_file)

            # Create typed result internally
            result = DisableGhostResult(
                status="inactive",
                message="Ghost Mode disabled successfully",
                restored=True
            )

            # Return as dict for API compatibility
            return result.to_dict()

        except Exception as e:
            self.logger.error(f"Failed to disable Ghost Mode: {e}")
            raise GhostModeError(f"Failed to disable Ghost Mode: {str(e)}")

    def get_status(self) -> Dict[str, Any]:
        """Get comprehensive Ghost Mode status and connection information.

        Provides real-time information about:
        - Whether Ghost Mode is active
        - wstunnel service status (systemd)
        - Configured domain and SSL status
        - Connection parameters (IP, port, secret)
        - Client connection commands
        - phantom-casper export information

        Returns GhostStatusResult model and converts to dict via to_dict().
        Internally uses GhostServiceInfo to report service status.

        Returns:
            Dict containing:
            - status: Current operational status ("active"/"inactive"/"error")
            - enabled: Whether Ghost Mode is enabled
            - server_ip: Server public IP (if active)
            - domain: Configured domain name (if active)
            - secret: Truncated authentication secret (if active)
            - protocol: Connection protocol ("wss")
            - port: Connection port (443)
            - services: Service status information
            - activated_at: Activation timestamp (if active)
            - connection_command: Client connection instructions (if active)
            - client_export_info: Export command information
            - message: Status message (if inactive)
        """
        if not self.state.get("enabled", False):
            # Create typed result internally
            result = GhostStatusResult(
                status="inactive",
                enabled=False,
                message="Ghost Mode is not active"
            )
            # Return as dict for API compatibility
            return result.to_dict()

        # Check wstunnel service
        wstunnel_active = wstunnel_utils.check_service("wstunnel", self._run_command)

        # Get connection details
        server_ip = self.state.get("server_ip", "Unknown")
        domain = self.state.get("domain", "")
        secret = self.state.get("secret", "")

        # Create typed service info internally
        services = GhostServiceInfo(
            wstunnel="active" if wstunnel_active else "inactive"
        )

        # Create typed result internally
        result = GhostStatusResult(
            status="active" if wstunnel_active else "error",
            enabled=True,
            server_ip=server_ip,
            domain=domain,
            secret=secret[:10] + "..." if secret else "N/A",
            protocol="wss",
            port=443,
            services=services,
            activated_at=self.state.get("installed_at"),
            connection_command=network_utils.get_connection_command(self.state),
            client_export_info="To export client configuration, use: phantom-casper [username]"
        )

        # Return as dict for API compatibility
        return result.to_dict()
