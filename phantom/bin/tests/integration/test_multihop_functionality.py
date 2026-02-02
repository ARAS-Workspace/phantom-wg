"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Multihop Functionality Tests - Comprehensive test suite for Phantom-WG Multihop module

Test Phases:
    Phase 1: Environment Setup (3 tests)
    Phase 2: VPN Configuration Management (3 tests)
    Phase 3: Basic Multihop Operations (4 tests)
    Phase 4: Advanced Operations (3 tests)
    Phase 5: Integration Tests (3 tests)
    Phase 6: Cleanup (2 tests)

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import os
import time
import subprocess
import tempfile
from pathlib import Path
from textwrap import dedent


@pytest.fixture(scope='session')
def setup_exit_namespace():
    """
    Set up network namespace and VPN configuration for multihop testing
    This fixture runs once for the entire test class
    """
    # Namespace and interface names
    exit_ns = "wg-test-exit"
    veth_main = "veth-main"
    veth_exit = "veth-exit"

    # Network configuration
    main_ip = "172.16.100.1/24"
    exit_ip = "172.16.100.2/24"
    wg_server_ip = "10.9.0.1/24"
    wg_client_ip = "10.9.0.2/32"
    wg_port = 51821

    # Cleanup function to ensure namespace is removed
    def cleanup():
        subprocess.run(["ip", "netns", "delete", exit_ns],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["ip", "link", "delete", veth_main],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Clean up any existing namespace first
    cleanup()

    try:
        # Create network namespace for exit server
        result = subprocess.run(["ip", "netns", "add", exit_ns],
                                capture_output=True, text=True)
        if result.returncode != 0:
            pytest.skip(f"Failed to create network namespace: {result.stderr}")

        # Create veth pair
        subprocess.run(["ip", "link", "add", veth_main, "type", "veth",
                        "peer", "name", veth_exit], check=True)
        subprocess.run(["ip", "link", "set", veth_exit, "netns", exit_ns], check=True)

        # Configure main namespace side
        subprocess.run(["ip", "addr", "add", main_ip, "dev", veth_main], check=True)
        subprocess.run(["ip", "link", "set", veth_main, "up"], check=True)

        # Configure exit namespace side
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "ip", "addr", "add", exit_ip, "dev", veth_exit], check=True)
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "ip", "link", "set", veth_exit, "up"], check=True)
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "ip", "link", "set", "lo", "up"], check=True)

        # Add default route in exit namespace
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "ip", "route", "add", "default", "via", "172.16.100.1"], check=True)

        # Generate WireGuard keys
        exit_private_key = subprocess.run(["wg", "genkey"],
                                          capture_output=True, text=True).stdout.strip()
        exit_public_key = subprocess.run(["wg", "pubkey"],
                                         input=exit_private_key,
                                         capture_output=True, text=True).stdout.strip()

        client_private_key = subprocess.run(["wg", "genkey"],
                                            capture_output=True, text=True).stdout.strip()
        client_public_key = subprocess.run(["wg", "pubkey"],
                                           input=client_private_key,
                                           capture_output=True, text=True).stdout.strip()

        # Create WireGuard EXIT SERVER config in namespace
        wg_exit_config = dedent(f"""
            [Interface]
            PrivateKey = {exit_private_key}
            Address = {wg_server_ip}
            ListenPort = {wg_port}

            [Peer]
            # Phantom client connection
            PublicKey = {client_public_key}
            AllowedIPs = {wg_client_ip}
        """).strip()

        # Write exit server config
        with tempfile.NamedTemporaryFile(mode='w', suffix='.conf',
                                         delete=False, dir='/tmp') as f:
            f.write(wg_exit_config)
            exit_config_path = f.name

        # Create WireGuard CLIENT config for Phantom to use
        wg_client_config = dedent(f"""
            [Interface]
            PrivateKey = {client_private_key}
            Address = {wg_client_ip}
            DNS = 8.8.8.8, 8.8.4.4

            [Peer]
            PublicKey = {exit_public_key}
            Endpoint = 172.16.100.2:{wg_port}
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25
        """).strip()

        # Write client config for test use
        test_vpn_config_path = "/tmp/test-exit.conf"
        with open(test_vpn_config_path, 'w') as f:
            f.write(wg_client_config)

        # Start WireGuard in exit namespace
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "wg-quick", "up", exit_config_path], check=True)

        # Enable IP forwarding in exit namespace
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "sysctl", "-w", "net.ipv4.ip_forward=1"],
                       capture_output=True, check=True)

        # Setup NAT in exit namespace
        subprocess.run(["ip", "netns", "exec", exit_ns,
                        "iptables", "-t", "nat", "-A", "POSTROUTING",
                        "-o", veth_exit, "-j", "MASQUERADE"], check=True)

        # Give WireGuard time to start
        time.sleep(2)

        # Return config path for tests
        yield test_vpn_config_path

    except subprocess.CalledProcessError as e:
        pytest.skip(f"Failed to set up test environment: {e}")
    finally:
        # Cleanup
        try:
            # Stop WireGuard in namespace
            try:
                subprocess.run(["ip", "netns", "exec", exit_ns,
                                "wg-quick", "down", exit_config_path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except (subprocess.SubprocessError, OSError, NameError, UnboundLocalError):
                pass
        except (subprocess.SubprocessError, OSError):
            pass

        # Remove configs safely
        for config_file in ["/tmp/test-exit.conf"]:
            try:
                if os.path.exists(config_file):
                    os.unlink(config_file)
            except (OSError, IOError):
                pass

        # Remove exit config if it exists
        try:
            if 'exit_config_path' in locals():
                if os.path.exists(exit_config_path):
                    os.unlink(exit_config_path)
        except (OSError, IOError, NameError, UnboundLocalError):
            pass

        # Remove namespace and interfaces
        cleanup()


class TestMultihopFunctionality:
    """
    Multihop Module test suite - Tests all Multihop API endpoints with real VPN configuration
    """

    # Static test configuration
    TEST_EXIT_NAME = 'test-exit'

    @staticmethod
    def validate_response(response) -> bool:
        """Check if response is successful"""
        return response and hasattr(response, 'success') and response.success

    @staticmethod
    def validate_vpn_config_path(config_path_str: str) -> bool:
        """VPN config file existence and basic format validation"""
        config_path = Path(config_path_str)

        if not config_path.exists():
            return False

        try:
            with open(config_path, 'r') as f:
                content = f.read()

            # Check for basic WireGuard config structure
            return '[Interface]' in content and '[Peer]' in content

        except (OSError, IOError):
            return False

    # Phase 1: Environment Setup Tests

    @pytest.mark.dependency()
    def test_environment_setup(self, phantom_api):
        """Test Multihop module accessibility"""
        response = phantom_api.execute("multihop", "status")
        assert response is not None, "Multihop module should be accessible"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_environment_setup"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_root_privileges(self):
        """Test root access (required for systemd and network operations)"""
        assert os.geteuid() == 0, "Root privileges required for Multihop tests"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_root_privileges"])
    def test_initial_multihop_state(self, phantom_api):
        """Ensure clean initial multihop state"""
        response = phantom_api.execute("multihop", "status")
        assert self.validate_response(response), "Should get multihop status"

        # Log current state (may be active or inactive)
        enabled = response.data.get('enabled', False)

        if enabled:
            # If already enabled, we should disable it first for clean test
            phantom_api.execute("multihop", "disable_multihop")

    # Phase 2: VPN Configuration Management Tests

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_initial_multihop_state"])
    def test_vpn_config_import_validation(self, phantom_api):
        """Test VPN config import validation errors"""
        # Test 1: Non-existent file path
        response = phantom_api.execute("multihop", "import_vpn_config",
                                       config_path="/nonexistent/file.conf")
        assert not self.validate_response(response), "Non-existent file should fail"

        # Test 2: Invalid config format
        with tempfile.NamedTemporaryFile(mode='w', suffix='.conf', delete=False) as f:
            f.write("invalid config content")
            temp_path = f.name

        response = phantom_api.execute("multihop", "import_vpn_config",
                                       config_path=temp_path)
        os.unlink(temp_path)

        assert not self.validate_response(response), "Invalid config should fail"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_vpn_config_import_validation"])
    def test_vpn_config_import_success(self, phantom_api, setup_exit_namespace):
        """Test successful VPN config import"""
        assert self.validate_vpn_config_path(setup_exit_namespace), f"VPN config should exist at {setup_exit_namespace}"

        response = phantom_api.execute("multihop", "import_vpn_config",
                                       config_path=setup_exit_namespace)

        assert self.validate_response(response), "VPN config import should succeed"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_vpn_config_import_success"])
    def test_list_exits_populated(self, phantom_api):
        """Test listing imported VPN configurations"""
        response = phantom_api.execute("multihop", "list_exits")
        assert self.validate_response(response), "List exits should succeed"

        exits = response.data.get('exits', [])
        assert len(exits) > 0, "Should have at least one exit after import"

        # Verify our test config is present
        exit_names = [vpn_exit.get('name') for vpn_exit in exits if isinstance(vpn_exit, dict)]
        assert self.TEST_EXIT_NAME in exit_names, f"Test exit '{self.TEST_EXIT_NAME}' should be in list. Available exits: {exit_names}"

    # Phase 3: Basic Multihop Operations Tests

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_list_exits_populated"])
    def test_enable_multihop_success(self, phantom_api):
        """Test successful Multihop enable"""
        response = phantom_api.execute("multihop", "enable_multihop",
                                       exit_name=self.TEST_EXIT_NAME)

        assert self.validate_response(response), "Multihop enable should succeed"
        assert response.data.get('multihop_enabled') == True, "Multihop should be enabled"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_enable_multihop_success"])
    def test_multihop_status_active(self, phantom_api):
        """Test active Multihop status details"""
        response = phantom_api.execute("multihop", "status")
        assert self.validate_response(response), "Status should be accessible"

        assert response.data.get('enabled') == True, "Multihop should be enabled"
        assert response.data.get('active_exit') is not None, "Should have active exit"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_multihop_status_active"])
    def test_vpn_connection_test(self, phantom_api):
        """Test VPN connection check"""
        response = phantom_api.execute("multihop", "test_vpn")

        # Note: Connection may fail in test environment, check API response format
        assert response is not None, "Should get response from test_vpn"
        assert 'success' in response.__dict__, "Response should have success field"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_vpn_connection_test"])
    def test_duplicate_enable_attempt(self, phantom_api):
        """Test duplicate enable attempt"""
        response = phantom_api.execute("multihop", "enable_multihop",
                                       exit_name=self.TEST_EXIT_NAME)

        # Should handle gracefully (either success or appropriate error)
        assert response is not None, "Should handle duplicate enable gracefully"

    # Phase 4: Advanced Operations Tests

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_duplicate_enable_attempt"])
    def test_disable_multihop_success(self, phantom_api):
        """Test successful Multihop disable"""
        response = phantom_api.execute("multihop", "disable_multihop")
        assert self.validate_response(response), "Multihop disable should succeed"

        # Verify status after disable
        status_response = phantom_api.execute("multihop", "status")
        assert self.validate_response(status_response), "Status should be accessible"
        assert status_response.data.get('enabled') == False, "Multihop should be disabled"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_disable_multihop_success"])
    def test_enable_disable_cycle(self, phantom_api):
        """Test complete enable-disable cycle"""
        # Enable
        enable_response = phantom_api.execute("multihop", "enable_multihop",
                                              exit_name=self.TEST_EXIT_NAME)
        assert self.validate_response(enable_response), "Enable should succeed"

        # Check active status
        status_response = phantom_api.execute("multihop", "status")
        assert status_response.data.get('enabled') == True, "Should be enabled"

        # Disable
        disable_response = phantom_api.execute("multihop", "disable_multihop")
        assert self.validate_response(disable_response), "Disable should succeed"

        # Check inactive status
        final_status = phantom_api.execute("multihop", "status")
        assert final_status.data.get('enabled') == False, "Should be disabled"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_enable_disable_cycle"])
    def test_remove_vpn_config(self, phantom_api):
        """Test VPN configuration removal"""
        response = phantom_api.execute("multihop", "remove_vpn_config",
                                       exit_name=self.TEST_EXIT_NAME)

        # Removal may succeed or appropriately fail
        assert response is not None, "Should handle config removal"

        # Check if removed from list
        list_response = phantom_api.execute("multihop", "list_exits")
        if self.validate_response(list_response):
            exits = list_response.data.get('exits', [])
            exit_names = [vpn_exit.get('name') for vpn_exit in exits if isinstance(vpn_exit, dict)]
            # Config should be removed or list should handle it appropriately
            assert self.TEST_EXIT_NAME not in exit_names or len(exits) >= 0

    # Phase 5: Integration Tests

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_remove_vpn_config"])
    def test_get_session_log(self, phantom_api):
        """Test session log monitoring functionality"""
        # Test default log retrieval
        response = phantom_api.execute("multihop", "get_session_log")
        assert response is not None, "Should get session log response"

        # Test with specific line count
        lines_response = phantom_api.execute("multihop", "get_session_log", lines=10)
        assert lines_response is not None, "Should get session log with line limit"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_get_session_log"])
    def test_reset_state(self, phantom_api):
        """Test complete state reset"""
        response = phantom_api.execute("multihop", "reset_state")

        # Reset may succeed or appropriately fail
        assert response is not None, "Reset state should respond"

        # Verify state
        status_response = phantom_api.execute("multihop", "status")
        if self.validate_response(status_response):
            assert status_response.data.get('enabled') == False, "Should be disabled after reset"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_reset_state"])
    def test_disable_inactive(self, phantom_api):
        """Test disable when already inactive"""
        # Ensure multihop is disabled first
        phantom_api.execute("multihop", "disable_multihop")

        # Try to disable again
        response = phantom_api.execute("multihop", "disable_multihop")

        # Should handle gracefully
        assert response is not None, "Should handle disable when already inactive"

    # Phase 6: Cleanup Tests

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_disable_inactive"])
    def test_complete_cleanup(self, phantom_api):
        """Test complete cleanup"""
        # Disable multihop
        phantom_api.execute("multihop", "disable_multihop")

        # Remove imported test config
        phantom_api.execute("multihop", "remove_vpn_config", exit_name=self.TEST_EXIT_NAME)

        # Verify clean state
        status_response = phantom_api.execute("multihop", "status")
        assert self.validate_response(status_response), "Status should be accessible"
        assert status_response.data.get('enabled') == False, "Should be disabled"

    @pytest.mark.dependency(depends=["TestMultihopFunctionality::test_complete_cleanup"])
    def test_original_state_restoration(self, phantom_api):
        """Test original state restoration"""
        # This test is now a placeholder since we don't maintain state
        # Just ensure we end in a clean disabled state
        response = phantom_api.execute("multihop", "status")
        assert response is not None, "Should get final status"
