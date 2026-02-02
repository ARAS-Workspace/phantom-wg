"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Core Functionality Tests - Comprehensive test suite for Phantom-WG Core module

Test Phases:
    Phase 1: Environment Setup
    Phase 2: Basic Functionality Tests (6 tests)
    Phase 3: Service Management Tests (3 tests)
    Phase 4: Tweak Settings Tests (2 tests)
    Phase 5: Network Management Tests (3 tests)
    Phase 6: Rollback Mechanism Test (1 test)
    Phase 7: Cleanup Tests (1 test)

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import os
import time
import subprocess


class TestCoreFunctionality:
    """
    Core Module test suite - Tests all Core API endpoints
    """

    @pytest.fixture(autouse=True)
    def setup(self, phantom_api):
        """Setup test environment with PhantomAPI fixture"""
        self.api = phantom_api
        self.test_clients = ["test-client-1", "test-client-2", "test-client-3"]
        self.original_state = {}

    @staticmethod
    def validate_response(response) -> bool:
        """Check if response is successful"""
        return response and hasattr(response, 'success') and response.success

    @pytest.mark.dependency()
    def test_server_status(self):
        """Test server_status endpoint"""
        response = self.api.execute("core", "server_status")
        assert self.validate_response(response), "Response should be successful"

        # Check response data structure
        assert 'service' in response.data, "Missing 'service' in response"
        assert 'interface' in response.data, "Missing 'interface' in response"
        assert 'clients' in response.data, "Missing 'clients' in response"

        # Service can be a dict or string, interface can be a dict or string
        # Just verify they exist and have some content
        assert response.data['service'] is not None, "Service data should not be None"
        assert response.data['interface'] is not None, "Interface data should not be None"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_server_status"])
    def test_list_clients_empty(self):
        """Test list_clients with initial state"""
        response = self.api.execute("core", "list_clients")
        assert self.validate_response(response), "Response should be successful"

        assert 'clients' in response.data, "Missing 'clients' in response"
        assert 'total' in response.data, "Missing 'total' in response"

        # Store original client count
        self.original_state['client_count'] = response.data['total']
        assert isinstance(response.data['clients'], list), "Clients should be a list"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_list_clients_empty"])
    def test_add_clients(self):
        """Test adding multiple clients"""
        for client_name in self.test_clients:
            response = self.api.execute("core", "add_client", client_name=client_name)
            assert self.validate_response(response), f"Failed to add client {client_name}"

            assert 'client' in response.data, "Missing 'client' in response"
            client_data = response.data['client']

            # Verify basic client data
            assert client_data['name'] == client_name, f"Client name mismatch"
            assert 'public_key' in client_data, "Missing public key"
            assert 'ip' in client_data, "Missing IP address"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_add_clients"])
    def test_list_clients_populated(self):
        """Test list_clients with populated state"""
        response = self.api.execute("core", "list_clients")
        assert self.validate_response(response), "Response should be successful"

        assert 'clients' in response.data, "Missing 'clients' in response"
        assert 'total' in response.data, "Missing 'total' in response"

        # Verify our test clients exist
        client_names = [c['name'] for c in response.data['clients']]
        for test_client in self.test_clients:
            assert test_client in client_names, f"Test client {test_client} not found in client list"

        # Verify total count increased
        assert response.data['total'] >= len(self.test_clients), "Client count should include test clients"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_list_clients_populated"])
    def test_export_client(self):
        """Test export_client for each test client"""
        for client_name in self.test_clients:
            response = self.api.execute("core", "export_client", client_name=client_name)
            assert self.validate_response(response), f"Failed to export client {client_name}"

            assert 'client' in response.data, "Missing 'client' in response"
            assert 'config' in response.data, "Missing 'config' in response"

            # Verify configuration content
            config = response.data['config']
            assert '[Interface]' in config, "Missing [Interface] section in config"
            assert '[Peer]' in config, "Missing [Peer] section in config"
            assert 'PrivateKey' in config, "Missing PrivateKey in config"
            assert 'Address' in config, "Missing Address in config"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_export_client"])
    def test_latest_clients(self):
        """Test latest_clients endpoint"""
        response = self.api.execute("core", "latest_clients")
        assert self.validate_response(response), "Response should be successful"

        assert 'latest_clients' in response.data, "Missing 'latest_clients' in response"

        # Verify we see our recently added test clients
        latest = response.data['latest_clients']
        assert isinstance(latest, list), "Latest clients should be a list"

        # Check if at least some test clients appear in latest
        latest_names = [c['name'] for c in latest]
        test_clients_found = sum(1 for tc in self.test_clients if tc in latest_names)
        assert test_clients_found > 0, "No test clients found in latest clients list"

    # Phase 3: Service Management Tests

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_latest_clients"])
    def test_get_firewall_status(self):
        """Test get_firewall_status endpoint"""
        response = self.api.execute("core", "get_firewall_status")
        assert self.validate_response(response), "Response should be successful"

        assert 'ufw' in response.data, "Missing 'ufw' in response"
        assert 'status' in response.data, "Missing 'status' in response"

        # Verify status format
        assert response.data['status'] in ['active', 'inactive', 'enabled', 'disabled',
                                           'unknown'], "Invalid firewall status"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_get_firewall_status"])
    def test_service_logs(self):
        """Test service_logs endpoint"""
        response = self.api.execute("core", "service_logs", lines="10")
        assert self.validate_response(response), "Response should be successful"

        assert 'logs' in response.data, "Missing 'logs' in response"

        # Verify logs format
        logs = response.data['logs']
        assert isinstance(logs, (str, list)), "Logs should be string or list"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_service_logs"])
    def test_restart_service(self):
        """Test restart_service endpoint"""
        response = self.api.execute("core", "restart_service")
        assert self.validate_response(response), "Response should be successful"

        # Wait for service to stabilize
        time.sleep(2)

        # Verify service is running after restart
        status_response = self.api.execute("core", "server_status")
        assert self.validate_response(status_response), "Should get server status after restart"

    # Phase 4: Tweak Settings Tests

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_restart_service"])
    def test_get_tweak_settings(self):
        """Test get_tweak_settings endpoint"""
        response = self.api.execute("core", "get_tweak_settings")
        assert self.validate_response(response), "Response should be successful"

        assert 'restart_service_after_client_creation' in response.data, "Missing tweak setting"

        # Store original tweak settings
        self.original_state['tweaks'] = {
            'restart_service_after_client_creation': response.data['restart_service_after_client_creation']
        }

        # Verify setting type - API might return boolean or string
        setting_value = response.data['restart_service_after_client_creation']
        assert setting_value in [True, False], "Tweak setting should be boolean"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_get_tweak_settings"])
    def test_update_tweak_setting(self):
        """Test update_tweak_setting endpoint"""
        # Get original value (string 'true'/'false')
        original_value = self.original_state.get('tweaks', {}).get('restart_service_after_client_creation', 'false')
        # Toggle the string value
        new_value = 'false' if original_value == 'true' else 'true'

        # Update setting
        response = self.api.execute("core", "update_tweak_setting",
                                    setting_name='restart_service_after_client_creation',
                                    value=new_value)
        assert self.validate_response(response), "Failed to update tweak setting"

        # Verify update
        verify_response = self.api.execute("core", "get_tweak_settings")
        assert self.validate_response(verify_response), "Failed to get tweak settings"

        current_value = verify_response.data['restart_service_after_client_creation']
        assert current_value != original_value, "Setting value should have changed"

        # Restore original value
        restore_response = self.api.execute("core", "update_tweak_setting",
                                            setting_name='restart_service_after_client_creation',
                                            value=original_value)
        assert self.validate_response(restore_response), "Failed to restore tweak setting"

    # Phase 5: Network Management Tests

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_update_tweak_setting"])
    def test_get_subnet_info(self):
        """Test get_subnet_info endpoint"""
        response = self.api.execute("core", "get_subnet_info")
        assert self.validate_response(response), "Response should be successful"

        assert 'current_subnet' in response.data, "Missing 'current_subnet' in response"
        assert 'clients' in response.data, "Missing 'clients' in response"

        # Store original subnet
        self.original_state['subnet'] = response.data['current_subnet']

        # Verify subnet format
        subnet = response.data['current_subnet']
        assert '/' in subnet, "Subnet should be in CIDR format"
        assert '.' in subnet, "Subnet should contain IP address"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_get_subnet_info"])
    def test_validate_subnet_change(self):
        """Test validate_subnet_change with valid and invalid subnets"""
        # Test valid subnet
        response = self.api.execute("core", "validate_subnet_change",
                                    new_subnet='192.168.100.0/24')
        assert self.validate_response(response), "Response should be successful"
        assert 'valid' in response.data, "Missing 'valid' in response"
        # Subnet validation might return false due to conflicts, that's OK

        # Test invalid subnet
        response = self.api.execute("core", "validate_subnet_change",
                                    new_subnet='300.300.300.0/24')
        # This should fail validation
        assert response.success is False, "Invalid subnet should fail validation"

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_validate_subnet_change"])
    def test_change_subnet(self):
        """Test change_subnet endpoint"""
        # Only run if we have a different subnet to test
        test_subnet = '192.168.100.0/24'
        original_subnet = self.original_state.get('subnet', '10.0.0.0/24')

        # Skip if test subnet is same as current
        if test_subnet == original_subnet:
            test_subnet = '172.16.0.0/24'

        # Change subnet
        response = self.api.execute("core", "change_subnet",
                                    new_subnet=test_subnet,
                                    confirm='true')
        assert self.validate_response(response), "Failed to change subnet"

        # Wait for change to complete
        time.sleep(3)

        # Verify change
        info_response = self.api.execute("core", "get_subnet_info")
        assert self.validate_response(info_response), "Failed to get subnet info"

        current_subnet = info_response.data['current_subnet']
        assert current_subnet == test_subnet, f"Subnet should be changed to {test_subnet}"

        # Restore original subnet
        restore_response = self.api.execute("core", "change_subnet",
                                            new_subnet=original_subnet,
                                            confirm='true')
        assert self.validate_response(restore_response), "Failed to restore subnet"

        # Verify restoration
        time.sleep(3)
        final_response = self.api.execute("core", "get_subnet_info")
        assert final_response.data['current_subnet'] == original_subnet, "Subnet should be restored"

    # Phase 6: Rollback Mechanism Test

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_change_subnet"])
    @pytest.mark.skipif(os.geteuid() != 0, reason="Requires root privileges")
    def test_rollback_mechanism(self):
        """Test rollback mechanism with service masking"""
        # Get current subnet
        info_response = self.api.execute("core", "get_subnet_info")
        assert self.validate_response(info_response), "Failed to get subnet info"
        original_subnet = info_response.data['current_subnet']

        # Mask WireGuard service to simulate failure
        mask_result = subprocess.run(['systemctl', 'mask', 'wg-quick@wg_main'],
                                     capture_output=True)
        assert mask_result.returncode == 0, "Failed to mask WireGuard service"

        # Attempt subnet change (should fail and rollback)
        _ = self.api.execute("core", "change_subnet",
                             new_subnet='172.16.0.0/24',
                             confirm='true')
        # We expect this to fail - don't check response

        # Unmask service
        unmask_result = subprocess.run(['systemctl', 'unmask', 'wg-quick@wg_main'],
                                       capture_output=True)
        assert unmask_result.returncode == 0, "Failed to unmask WireGuard service"

        # Verify rollback occurred (subnet should be unchanged)
        time.sleep(2)
        verify_response = self.api.execute("core", "get_subnet_info")
        assert self.validate_response(verify_response), "Failed to get subnet info after rollback"

        current_subnet = verify_response.data['current_subnet']
        assert current_subnet == original_subnet, f"Rollback failed! Expected: {original_subnet}, Got: {current_subnet}"

    # Phase 7: Cleanup Tests

    @pytest.mark.dependency(depends=["TestCoreFunctionality::test_rollback_mechanism"])
    def test_remove_clients(self):
        """Test removing all test clients"""
        for client_name in self.test_clients:
            response = self.api.execute("core", "remove_client", client_name=client_name)
            assert self.validate_response(response), f"Failed to remove client {client_name}"

            # Verify client is removed
            time.sleep(0.5)

        # Verify all test clients are removed
        list_response = self.api.execute("core", "list_clients")
        assert self.validate_response(list_response), "Failed to list clients"

        client_names = [c['name'] for c in list_response.data['clients']]
        for test_client in self.test_clients:
            assert test_client not in client_names, f"Test client {test_client} should be removed"
