"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Ghost Functionality Tests - Comprehensive test suite for Phantom-WG Ghost module

Test Phases:
    Phase 1: Environment Setup (3 tests)
    Phase 2: Basic Functionality Tests (6 tests)
    Phase 3: Advanced Tests (4 tests)
    Phase 4: Integration Tests (3 tests)
    Phase 5: Cleanup Tests (2 tests)

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import os
import time
import subprocess
from pathlib import Path
from contextlib import contextmanager


# noinspection PyArgumentList
class TestGhostFunctionality:
    """
    Ghost Module test suite - Tests all Ghost API endpoints with sslip.io integration
    """

    @pytest.fixture(autouse=True)
    def setup(self, phantom_api):
        """Setup test environment with PhantomAPI fixture"""
        self.api = phantom_api
        self.original_ghost_state = None
        self.test_domain = None
        self._server_ip = None

    @staticmethod
    def validate_response(response) -> bool:
        """Check if response is successful"""
        return response and hasattr(response, 'success') and response.success

    @contextmanager
    def _test_environment(self):
        """
        Context manager for test environment variables
        Enables test certificate allocation with PHANTOM_TEST=1
        """
        os.environ["PHANTOM_TEST"] = "1"
        try:
            yield
        finally:
            if "PHANTOM_TEST" in os.environ:
                del os.environ["PHANTOM_TEST"]

    def get_server_ip(self) -> str:
        """Get server IP and cache it"""
        if self._server_ip:
            return self._server_ip

        # Try IP services
        services = [
            "https://install.phantom.tc/ip",
            "https://ipinfo.io/ip",
            "https://api.ipify.org",
            "https://checkip.amazonaws.com"
        ]

        for service in services:
            try:
                result = subprocess.run(["curl", "-s", service],
                                        capture_output=True, text=True, timeout=10)

                if result.returncode == 0 and result.stdout.strip():
                    ip = result.stdout.strip()
                    # Validate IP
                    parts = ip.split('.')
                    if len(parts) == 4 and all(0 <= int(part) <= 255 for part in parts):
                        self._server_ip = ip
                        return ip
            except (subprocess.TimeoutExpired, subprocess.CalledProcessError,
                    OSError, ValueError, TypeError):
                continue

        raise Exception("Failed to determine server IP")

    def generate_test_domain(self) -> str:
        """Generate sslip.io domain for testing"""
        server_ip = self.get_server_ip()
        timestamp = int(time.time())
        return f"ghost-test-{timestamp}-{server_ip}.sslip.io"

    @pytest.mark.dependency()
    def test_environment_setup(self):
        """Test Ghost module accessibility"""
        response = self.api.execute("ghost", "status")
        assert response is not None, "Ghost module should be accessible"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_environment_setup"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_root_privileges(self):
        """Test root access (required for SSL and systemd)"""
        assert os.geteuid() == 0, "Root privileges required for Ghost Mode tests"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_root_privileges"])
    def test_sslip_domain_generation(self):
        """Test sslip.io domain generation"""
        domain = self.generate_test_domain()
        self.test_domain = domain
        assert domain is not None, "Failed to generate test domain"
        assert "sslip.io" in domain, "Domain should use sslip.io"

        # Test resolution
        result = subprocess.run(["dig", "+short", domain],
                                capture_output=True, text=True, timeout=10)

        if result.returncode == 0:
            resolved_ip = result.stdout.strip()
            expected_ip = self.get_server_ip()
            assert resolved_ip == expected_ip, f"DNS resolution mismatch - Expected: {expected_ip}, Got: {resolved_ip}"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_sslip_domain_generation"])
    def test_ghost_status_inactive_initial(self):
        """Test initial Ghost status (should be inactive)"""
        response = self.api.execute("ghost", "status")
        assert self.validate_response(response), "Ghost status should be accessible"

        # Save state
        self.original_ghost_state = response.data

        # Verify initial state
        assert response.data.get('enabled') == False, "Ghost should be disabled initially"
        assert response.data.get('status') == 'inactive', "Ghost status should be inactive"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_ghost_status_inactive_initial"])
    def test_enable_validation_errors(self):
        """Test enable validation errors"""
        # Test missing domain
        with self._test_environment():
            response = self.api.execute("ghost", "enable")
        assert not self.validate_response(response), "Enable without domain should fail"

        # Test invalid domain
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain="invalid-domain-test")
        assert not self.validate_response(response), "Enable with invalid domain should fail"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_enable_validation_errors"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_enable_ghost_mode_success(self):
        """Test successful Ghost Mode enable"""
        if not self.test_domain:
            self.test_domain = self.generate_test_domain()

        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=self.test_domain)

        assert self.validate_response(response), "Ghost Mode enable should succeed"
        assert response.data.get('status') == 'active', "Ghost status should be active"
        assert response.data.get('domain') == self.test_domain, f"Domain mismatch"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_enable_ghost_mode_success"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_ghost_status_active_details(self):
        """Test active Ghost status details"""
        response = self.api.execute("ghost", "status")
        assert self.validate_response(response), "Ghost status should be accessible"

        assert response.data.get('enabled') == True, "Ghost should be enabled"
        assert response.data.get('status') == 'active', "Ghost status should be active"
        assert 'connection_command' in response.data, "Connection command should be provided"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_ghost_status_active_details"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_ghost_phantom_casper_configuration_export(self):
        """Test phantom-casper configuration export"""
        # Verify active state
        status_response = self.api.execute("ghost", "status")
        assert self.validate_response(status_response), "Ghost status should be accessible"
        assert status_response.data.get('enabled') == True, "Ghost should be enabled for casper export"

        add_client_response = self.api.execute("core", "add_client", client_name='test-ghost-client')
        client_data = add_client_response.data['client']
        assert client_data['name'] == 'test-ghost-client', "Client name mismatch"

        # Test casper export
        import io
        import contextlib

        from phantom.casper import CasperService
        service = CasperService()

        # Capture output
        output_buffer = io.StringIO()
        with contextlib.redirect_stdout(output_buffer):
            service.export_client_config('test-ghost-client')

        export_output = output_buffer.getvalue()

        remove_client_response = self.api.execute("core", "remove_client", client_name='test-ghost-client')
        assert hasattr(remove_client_response, 'success')

        # Verify export content
        assert len(export_output) > 0, "Export should produce output"
        assert '[Interface]' in export_output, "Export should contain WireGuard interface section"
        assert '[Peer]' in export_output, "Export should contain WireGuard peer section"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_ghost_phantom_casper_configuration_export"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_duplicate_enable_attempt(self):
        """Test duplicate enable attempt"""
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=self.test_domain)

        # Verify duplicate fails
        assert not self.validate_response(response), "Duplicate enable should fail"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_duplicate_enable_attempt"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_disable_ghost_mode_success(self):
        """Test successful Ghost Mode disable"""
        response = self.api.execute("ghost", "disable")
        assert self.validate_response(response), "Ghost Mode disable should succeed"

        # Verify disabled state
        status_response = self.api.execute("ghost", "status")
        assert self.validate_response(status_response), "Ghost status should be accessible"
        assert status_response.data.get('enabled') == False, "Ghost should be disabled"
        assert status_response.data.get('status') == 'inactive', "Ghost status should be inactive"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_disable_ghost_mode_success"])
    def test_disable_inactive_ghost(self):
        """Test disable when already inactive"""
        response = self.api.execute("ghost", "disable")
        # Verify graceful handling
        assert response is not None, "Disable when inactive should be handled gracefully"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_disable_inactive_ghost"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_enable_disable_cycle(self):
        """Test complete enable-disable cycle"""
        # Generate domain
        domain = self.generate_test_domain()

        # Enable Ghost Mode
        with self._test_environment():
            enable_response = self.api.execute("ghost", "enable", domain=domain)
        assert self.validate_response(enable_response), "Enable should succeed"

        # Verify enabled
        status_response = self.api.execute("ghost", "status")
        assert self.validate_response(status_response), "Status should be accessible"
        assert status_response.data.get('enabled') == True, "Ghost should be enabled"
        assert status_response.data.get('status') == 'active', "Ghost should be active"

        # Disable Ghost Mode
        disable_response = self.api.execute("ghost", "disable")
        assert self.validate_response(disable_response), "Disable should succeed"

        # Verify final state
        final_status = self.api.execute("ghost", "status")
        assert self.validate_response(final_status), "Final status should be accessible"
        assert final_status.data.get('enabled') == False, "Ghost should be disabled"
        assert final_status.data.get('status') == 'inactive', "Ghost should be inactive"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_enable_disable_cycle"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_state_persistence(self):
        """Test state persistence"""
        # Enable Ghost
        domain = self.generate_test_domain()
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=domain)
        assert self.validate_response(response), "Enable should succeed"

        # Verify state file
        state_file = Path("/opt/phantom-wg/config/ghost-state.json")
        assert state_file.exists(), "State file should exist"

        # Clean up
        self.api.execute("ghost", "disable")

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_state_persistence"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_ssl_certificate_validation(self):
        """Test SSL certificate validation"""
        # Enable Ghost
        domain = self.generate_test_domain()
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=domain)

        assert self.validate_response(response), "Enable should succeed"

        # Check certificates
        cert_path = Path(f"/etc/letsencrypt/live/{domain}/fullchain.pem")
        key_path = Path(f"/etc/letsencrypt/live/{domain}/privkey.pem")

        cert_exists = cert_path.exists()
        key_exists = key_path.exists()

        # Clean up
        self.api.execute("ghost", "disable")

        assert cert_exists, f"Certificate should exist at {cert_path}"
        assert key_exists, f"Private key should exist at {key_path}"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_ssl_certificate_validation"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_wstunnel_service_health(self):
        """Test wstunnel service health"""
        # Enable Ghost
        domain = self.generate_test_domain()
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=domain)

        assert self.validate_response(response), "Enable should succeed"

        # Check service
        try:
            result = subprocess.run(["systemctl", "is-active", "wstunnel"],
                                    capture_output=True, text=True, timeout=5)
            service_active = result.stdout.strip() == "active"
        except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
            service_active = False

        # Clean up
        self.api.execute("ghost", "disable")

        assert service_active, "wstunnel service should be active"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_wstunnel_service_health"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_connection_command_format(self):
        """Test connection command format"""
        # Enable Ghost
        domain = self.generate_test_domain()
        with self._test_environment():
            response = self.api.execute("ghost", "enable", domain=domain)

        assert self.validate_response(response), "Enable should succeed"

        # Get connection command
        status_response = self.api.execute("ghost", "status")
        assert self.validate_response(status_response), "Status should be accessible"

        connection_command = status_response.data.get('connection_command', '')

        # Validate format
        assert 'wstunnel client' in connection_command, "Command should contain wstunnel client"
        assert '--http-upgrade-path-prefix' in connection_command, "Command should contain upgrade path"
        assert f'wss://{domain}:443' in connection_command, "Command should contain correct WSS URL"

        # Clean up
        self.api.execute("ghost", "disable")

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_connection_command_format"])
    def test_complete_cleanup(self):
        """Test complete cleanup"""
        # Disable Ghost
        self.api.execute("ghost", "disable")

        # Verify final status
        status_response = self.api.execute("ghost", "status")
        assert self.validate_response(status_response), "Status should be accessible"
        assert status_response.data.get('enabled') == False, "Ghost should be disabled"
        assert status_response.data.get('status') == 'inactive', "Ghost should be inactive"

    @pytest.mark.dependency(depends=["TestGhostFunctionality::test_complete_cleanup"])
    def test_original_state_restoration(self):
        """Test original state restoration"""
        if not self.original_ghost_state:
            # No original state to restore
            return

        # If Ghost was originally active, re-enable it
        if self.original_ghost_state.get('enabled'):
            original_domain = self.original_ghost_state.get('domain')
            if original_domain:
                with self._test_environment():
                    response = self.api.execute("ghost", "enable", domain=original_domain)
                assert self.validate_response(response), "Restoration should succeed"
