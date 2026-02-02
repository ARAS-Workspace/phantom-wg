"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

TR: Phantom-WG DNS Yönetim Modülü
    ==========================================
    
    Sistem genelindeki DNS yapılandırmasını yöneten ve test eden modül. Tüm WireGuard
    istemcileri için merkezi DNS yönetimi sağlar. phantom.json dosyasında global DNS
    ayarlarını saklar ve tüm istemci yapılandırmaları bu ayarları kullanır.
    
    API Endpoint'leri (4 adet):
        1. Yapılandırma: change_dns_servers, get_dns_servers
        2. Test ve Durum: test_dns_servers, status
    
    Modül Özellikleri:
        - Birincil ve ikincil DNS sunucu yönetimi
        - IP format doğrulaması (NetworkValidator)
        - DNS sunucu erişilebilirlik testleri (nslookup/dig)
        - Gerçek zamanlı performans ölçümü
        - Sistem genelinde yapılandırma senkronizasyonu
        - Typed model desteği (BaseModel inheritance)
    
    Test Yetenekleri:
        - nslookup ile DNS çözümleme testi
        - dig ile hızlı sorgu performansı
        - Çoklu domain testi (google.com, cloudflare.com)
        - Zaman aşımı koruması (5 saniye)
        - Sağlık durumu değerlendirmesi (healthy/degraded)
    
    Model Mimarisi:
        Bu modül @dataclass modelleri kullanarak tip güvenliği sağlar:
        - DNSServerConfig: DNS sunucu yapılandırması
        - TestDNSResult: Test sonuçları
        - DNSStatusResult: Durum bilgisi
        - GetDNSServersResult: Sunucu bilgileri
        Tüm modeller BaseModel'den inherit eder ve to_dict() ile API uyumluluğu sağlar.

EN: Phantom-WG DNS Management Module
    ==========================================
    
    Module that manages and tests system-wide DNS configuration. Provides centralized
    DNS management for all WireGuard clients. Stores global DNS settings in phantom.json
    file and all client configurations use these settings.
    
    API Endpoints (4 total):
        1. Configuration: change_dns_servers, get_dns_servers
        2. Test and Status: test_dns_servers, status
    
    Module Features:
        - Primary and secondary DNS server management
        - IP format validation (NetworkValidator)
        - DNS server accessibility tests (nslookup/dig)
        - Real-time performance measurement
        - System-wide configuration synchronization
        - Typed model support (BaseModel inheritance)
    
    Testing Capabilities:
        - DNS resolution test with nslookup
        - Fast query performance with dig
        - Multiple domain testing (google.com, cloudflare.com)
        - Timeout protection (5 seconds)
        - Health status evaluation (healthy/degraded)
    
    Model Architecture:
        This module uses @dataclass models for type safety:
        - DNSServerConfig: DNS server configuration
        - TestDNSResult: Test results
        - DNSStatusResult: Status information
        - GetDNSServersResult: Server information
        All models inherit from BaseModel and provide API compatibility via to_dict().

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import subprocess
from pathlib import Path
from typing import List, Dict, Any, Optional

from ..base import BaseModule
from ...api import NetworkValidator
from ...api.exceptions import (
    ValidationError,
    InvalidParameterError,
    ConfigurationError
)
from .models import (
    DNSServerConfig, ClientConfigUpdateResult, ChangeDNSResult,
    DNSTestServerResult, TestDNSResult, DNSConfiguration,
    DNSDomainTest, DNSServerStatusTest, DNSHealth, DNSStatusResult,
    GetDNSServersResult
)

# Module constants
DEFAULT_DNS_PRIMARY = "8.8.8.8"
DEFAULT_DNS_SECONDARY = "1.1.1.1"
DNS_TEST_DOMAINS = ["google.com", "cloudflare.com"]
DNS_TEST_TIMEOUT = 5


class DnsModule(BaseModule):
    """Standard DNS management module - API version.

    Module that manages and tests DNS server configuration. Stores
    system-wide DNS settings in phantom.json file and all client
    configurations use these global settings.

    Main Responsibilities:
        - Primary and secondary DNS server management
        - DNS server accessibility and performance tests
        - System-wide DNS configuration synchronization
        - Integration with Core module

    Features:
        - Secure DNS change with IP validation
        - Multiple DNS server testing (dig and nslookup)
        - Real-time performance measurement
        - Automatic configuration refresh
        - Typed model support (to_dict() for API compatibility)

    Model Architecture:
        Uses @dataclass models to provide type safety.
        All models inherit from BaseModel and are converted to dict
        via to_dict() method for API compatibility.
    """

    def __init__(self, install_dir: Optional[Path] = None):
        """Initialize DnsModule object and load DNS configuration.

        Inherits from BaseModule and loads DNS-specific configuration
        from phantom.json file. Default values are set to Google DNS
        (8.8.8.8) and Cloudflare DNS (1.1.1.1).

        Args:
            install_dir: Installation directory path (default: /opt/phantom-wg)
        """
        super().__init__(install_dir)

        # Load DNS configuration with sensible defaults
        self.dns_config = self.config.get("dns", {
            "primary": DEFAULT_DNS_PRIMARY,
            "secondary": DEFAULT_DNS_SECONDARY
        })

    def get_module_name(self) -> str:
        """Return module name."""
        return "dns"

    def get_module_description(self) -> str:
        """Return module description."""
        return "Standard DNS server management"

    def get_actions(self) -> Dict[str, callable]:
        """Return all available actions this module can perform.

        Provides 4 API endpoints for DNS management:
            - change_dns_servers: Changes DNS servers
            - test_dns_servers: Performs DNS server tests
            - status: Shows current DNS status and health
            - get_dns_servers: Returns active DNS servers

        Returns:
            Dict[str, callable]: Map of action names to their handler methods
        """
        return {
            # Configuration Actions
            "change_dns_servers": self.change_dns_servers,
            "test_dns_servers": self.test_dns_servers,

            # Status Actions
            "status": self.status,
            "get_dns_servers": self.get_dns_servers
        }

    def change_dns_servers(self, primary: str = None, secondary: str = None) -> Dict[str, Any]:
        """Change DNS servers and update system-wide.

        This action performs:
            1. Validates given IP addresses (IPv4 format)
            2. Backs up current DNS configuration
            3. Saves new DNS settings to phantom.json
            4. Reloads configuration to synchronize
            5. All client configurations use global DNS

        Uses NetworkValidator for IP validation.
        Returns ChangeDNSResult model and converts to dict via to_dict().

        Args:
            primary: Primary DNS server IP address (optional, keeps current if not provided)
            secondary: Secondary DNS server IP address (optional, keeps current if not provided)

        Returns:
            Dict containing:
            - success: Operation status
            - dns_servers: New and previous DNS configuration
            - client_configs_updated: Update status for client configurations

        Raises:
            ValidationError: If IP addresses are invalid
            ConfigurationError: If configuration update fails
        """
        try:
            # Use current values as defaults if not provided
            if not primary:
                primary = self.dns_config.get('primary', DEFAULT_DNS_PRIMARY)
            if not secondary:
                secondary = self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)

            # Validate DNS servers
            primary = NetworkValidator.validate_ip_address(primary, version=4)
            secondary = NetworkValidator.validate_ip_address(secondary, version=4)

            # Update configuration
            old_primary = self.dns_config.get('primary', DEFAULT_DNS_PRIMARY)
            old_secondary = self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)

            self.dns_config["primary"] = primary
            self.dns_config["secondary"] = secondary

            # Update main config
            self.config["dns"] = self.dns_config
            self._save_config()

            # Client configurations use global DNS from phantom.json
            client_update_result_data = {"success": True, "message": "DNS configuration updated globally"}

            # Reload to prevent stale DNS values in cached config
            self.config = self._load_config()
            self.dns_config = self.config.get("dns", {
                "primary": DEFAULT_DNS_PRIMARY,
                "secondary": DEFAULT_DNS_SECONDARY
            })

            # Create typed models
            dns_server_config = DNSServerConfig(
                primary=primary,
                secondary=secondary,
                previous_primary=old_primary,
                previous_secondary=old_secondary
            )

            client_update_result = ClientConfigUpdateResult(
                success=client_update_result_data["success"],
                message=client_update_result_data["message"]
            )

            result = ChangeDNSResult(
                success=True,
                dns_servers=dns_server_config,
                client_configs_updated=client_update_result
            )

            # Convert to dict for API
            return result.to_dict()

        except ValidationError:
            raise
        except Exception as e:
            self.logger.error(f"Failed to change DNS servers: {e}")
            raise ConfigurationError(f"Failed to change DNS servers: {str(e)}")

    def test_dns_servers(self, servers: List[str] = None, domain: str = None) -> Dict[str, Any]:
        """Test DNS server connectivity and performance.

        This action performs:
            1. Determines DNS servers to test (uses current if not provided)
            2. Validates IP format for each server
            3. Performs DNS resolution test with nslookup command
            4. Records response time and success status
            5. Safe testing with 5 second timeout

        Returns TestDNSResult model and converts to dict via to_dict().
        Creates DNSTestServerResult for each server.

        Args:
            servers: List of DNS servers to test (optional, uses current config if not provided)
            domain: Domain to test (optional, defaults to 'google.com')

        Returns:
            Dict containing:
            - all_passed: True if all tests passed
            - servers_tested: Number of servers tested
            - results: List of test results for each server

        Raises:
            ValidationError: If no valid DNS servers to test
        """
        if not servers:
            servers = [
                self.dns_config.get('primary', DEFAULT_DNS_PRIMARY),
                self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)
            ]

        if not domain:
            domain = 'google.com'

        # Validate servers
        validated_servers = []
        for server in servers:
            try:
                validated_servers.append(NetworkValidator.validate_ip_address(server))
            except InvalidParameterError as e:
                self.logger.warning(f"Skipping invalid DNS server {server}: {e}")
                continue

        if not validated_servers:
            raise ValidationError("No valid DNS servers to test")

        # Test each server
        test_results = []
        all_passed = True

        for server in validated_servers:
            server_result_dict = self._test_single_dns_server(server, domain)

            # Create typed result
            server_result = DNSTestServerResult(
                server=server_result_dict["server"],
                success=server_result_dict["success"],
                status=server_result_dict["status"],
                response_time_ms=server_result_dict.get("response_time_ms"),
                test_domain=server_result_dict.get("test_domain"),
                error=server_result_dict.get("error")
            )

            test_results.append(server_result)
            if not server_result.success:
                all_passed = False

        # Create typed result
        result = TestDNSResult(
            all_passed=all_passed,
            servers_tested=len(validated_servers),
            results=test_results
        )

        # Convert to dict for API
        return result.to_dict()

    def status(self) -> Dict[str, Any]:
        """Get comprehensive DNS status and health information.

        Provides real-time information about:
            - Current DNS configuration (primary/secondary)
            - DNS server health status (with dig test)
            - Multiple domain test results for each server
            - Overall system DNS health (healthy/degraded)

        Returns DNSStatusResult model and converts to dict via to_dict().
        Internally uses DNSConfiguration, DNSHealth and DNSServerStatusTest.

        Returns:
            Dict containing:
            - configuration: Current DNS server IPs
            - health: Server health status and test results
        """
        primary_dns = self.dns_config.get('primary', DEFAULT_DNS_PRIMARY)
        secondary_dns = self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)

        # Test current servers
        test_result_dict = self._test_dns_servers_internal()

        # Create typed models
        configuration = DNSConfiguration(
            primary=primary_dns,
            secondary=secondary_dns
        )

        # Convert to typed models
        typed_test_results = []
        for server_result in test_result_dict["results"]:
            typed_domain_tests = []
            for test in server_result["tests"]:
                # API format adaptation: 'success' field contains response data, not boolean
                success_value = test.get("response") if test["success"] else test["success"]

                domain_test = DNSDomainTest(
                    domain=test["domain"],
                    success=success_value,
                    response=test.get("response"),
                    error=test.get("error")
                )
                typed_domain_tests.append(domain_test)

            server_status_test = DNSServerStatusTest(
                server=server_result["server"],
                tests=typed_domain_tests
            )
            typed_test_results.append(server_status_test)

        health = DNSHealth(
            status="healthy" if test_result_dict["all_passed"] else "degraded",
            test_results=typed_test_results
        )

        result = DNSStatusResult(
            configuration=configuration,
            health=health
        )

        # Convert to dict for API
        return result.to_dict()

    def get_dns_servers(self) -> Dict[str, Any]:
        """Get current DNS servers.

        Reads DNS configuration from phantom.json file and returns
        primary/secondary DNS server IP addresses.

        Returns GetDNSServersResult model and converts to dict via to_dict().

        Returns:
            Dict containing:
            - primary: Primary DNS server IP
            - secondary: Secondary DNS server IP
        """
        # Create typed result
        result = GetDNSServersResult(
            primary=self.dns_config.get('primary', DEFAULT_DNS_PRIMARY),
            secondary=self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)
        )

        # Convert to dict for API
        return result.to_dict()

    # Private helper methods - Internal DNS testing utilities

    def _test_single_dns_server(self, server: str, domain: str = 'google.com') -> Dict[str, Any]:
        """Test a single DNS server - resolution with nslookup.

        Checks if DNS server is working using nslookup command.
        Attempts to parse response time on successful resolution.
        Applies 5 second timeout.

        Test results:
            - OK: Successful resolution
            - FAILED: Resolution failed
            - TIMEOUT: No response within 5 seconds
            - ERROR: Unexpected error

        Args:
            server: DNS server IP address to test
            domain: Domain name to resolve (default: 'google.com')

        Returns:
            Dict containing:
            - server: Tested server IP
            - success: Boolean test result
            - status: Test status (OK/FAILED/TIMEOUT/ERROR)
            - response_time_ms: Response time if available
            - test_domain: Domain used for testing
            - error: Error message if failed
        """
        try:
            # Test with nslookup
            result = subprocess.run(
                ['nslookup', domain, server],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                # Parse response time if available
                response_time = self._parse_nslookup_time(result.stdout)

                return {
                    "server": server,
                    "success": True,
                    "status": "OK",
                    "response_time_ms": response_time,
                    "test_domain": domain
                }
            else:
                return {
                    "server": server,
                    "success": False,
                    "status": "FAILED",
                    "error": result.stderr.strip() if result.stderr else "DNS query failed"
                }

        except subprocess.TimeoutExpired:
            return {
                "server": server,
                "success": False,
                "status": "TIMEOUT",
                "error": "DNS query timed out after 5 seconds"
            }
        except Exception as e:
            return {
                "server": server,
                "success": False,
                "status": "ERROR",
                "error": str(e)
            }

    # noinspection PyMethodMayBeStatic
    def _parse_nslookup_time(self, output: str) -> Optional[float]:
        """Parse response time from nslookup output - simplified.

        Attempts to extract DNS query response time from nslookup output.
        This is a simplified implementation, output format may vary
        across different systems.

        Note: Currently returns None, real parsing can be added in future.

        Args:
            output: nslookup command stdout output

        Returns:
            Optional[float]: Response time in milliseconds or None if not parseable
        """
        # Simplified parser - implementation may vary by system
        _ = output
        return None  # Cannot parse time yet

    def _test_dns_servers_internal(self) -> Dict[str, Any]:
        """Internal DNS server testing - comprehensive check with dig.

        For both DNS servers in current configuration:
            1. Tests all domains in DNS_TEST_DOMAINS list
            2. Performs fast DNS query with dig command (+short)
            3. Applies 3 second query timeout, 5 second command timeout
            4. Records success status and responses
            5. Evaluates overall test success status

        Used by status() method for DNS health check.

        Returns:
            Dict containing:
            - all_passed: True if all tests passed
            - results: List of test results for each server with domain tests
        """
        primary_dns = self.dns_config.get('primary', DEFAULT_DNS_PRIMARY)
        secondary_dns = self.dns_config.get('secondary', DEFAULT_DNS_SECONDARY)
        test_domains = DNS_TEST_DOMAINS

        results = []
        all_passed = True

        for dns_server in [primary_dns, secondary_dns]:
            server_result = {
                "server": dns_server,
                "tests": []
            }

            for domain in test_domains:
                try:
                    result = subprocess.run(
                        ['dig', f'@{dns_server}', domain, '+short', '+timeout=3'],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )

                    success = result.returncode == 0 and result.stdout.strip()

                    server_result['tests'].append({
                        'domain': domain,
                        'success': success,
                        'response': result.stdout.strip()[:50] if success else None,
                        'error': result.stderr.strip()[:50] if not success else None
                    })

                    if not success:
                        all_passed = False

                except Exception as e:
                    server_result['tests'].append({
                        'domain': domain,
                        'success': False,
                        'error': str(e)[:50]
                    })
                    all_passed = False

            results.append(server_result)

        return {
            "all_passed": all_passed,
            "results": results
        }
