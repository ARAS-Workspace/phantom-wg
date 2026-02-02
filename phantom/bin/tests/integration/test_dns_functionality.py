"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

DNS Functionality Tests - Comprehensive test suite for Phantom-WG DNS module

Test Phases:
    Phase 1: Environment Setup
    Phase 2: Basic Functionality Tests (4 tests)
    Phase 3: Advanced Tests (3 tests)
    Phase 4: Restoration and Cleanup (1 test)

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import re


class TestDnsFunctionality:
    """
    DNS Module test suite - Tests all DNS API endpoints
    """

    TEST_DNS_SERVERS = {
        "cloudflare": ("1.1.1.1", "1.0.0.1"),
        "google": ("8.8.8.8", "8.8.4.4"),
        "quad9": ("9.9.9.9", "149.112.112.112"),
        "opendns": ("208.67.222.222", "208.67.220.220")
    }

    IP_PATTERN = r'^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

    @pytest.fixture(autouse=True)
    def setup(self, phantom_api):
        """Setup test environment with PhantomAPI fixture"""
        self.api = phantom_api
        self.original_dns = {}

    @staticmethod
    def validate_response(response) -> bool:
        """Check if response is successful"""
        return response and hasattr(response, 'success') and response.success

    def validate_ip_address(self, ip: str) -> bool:
        """Validate IP address format"""
        return bool(re.match(self.IP_PATTERN, ip))

    @pytest.mark.dependency()
    def test_get_dns_servers(self):
        """Test get_dns_servers endpoint"""
        response = self.api.execute("dns", "get_dns_servers")
        assert self.validate_response(response), "Response should be successful"

        # Verify response structure
        assert 'primary' in response.data, "Missing 'primary' in response"
        assert 'secondary' in response.data, "Missing 'secondary' in response"

        # Store original settings
        self.original_dns['primary'] = response.data['primary']
        self.original_dns['secondary'] = response.data['secondary']

        # Validate addresses
        assert self.validate_ip_address(response.data['primary']), \
            f"Invalid primary DNS IP: {response.data['primary']}"
        assert self.validate_ip_address(response.data['secondary']), \
            f"Invalid secondary DNS IP: {response.data['secondary']}"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_get_dns_servers"])
    def test_change_dns_servers_both(self):
        """Test changing both primary and secondary DNS servers"""
        # Use test DNS
        primary, secondary = self.TEST_DNS_SERVERS['cloudflare']

        response = self.api.execute("dns", "change_dns_servers",
                                    primary=primary,
                                    secondary=secondary)
        assert self.validate_response(response), "Failed to change DNS servers"

        # Verify change
        assert 'dns_servers' in response.data, "Missing 'dns_servers' in response"
        assert 'client_configs_updated' in response.data, "Missing 'client_configs_updated' in response"

        dns_data = response.data['dns_servers']
        assert dns_data['primary'] == primary, \
            f"Primary DNS mismatch - Expected: {primary}, Got: {dns_data['primary']}"
        assert dns_data['secondary'] == secondary, \
            f"Secondary DNS mismatch - Expected: {secondary}, Got: {dns_data['secondary']}"

        # Verify previous values
        assert 'previous_primary' in dns_data, "Previous primary DNS not included"
        assert 'previous_secondary' in dns_data, "Previous secondary DNS not included"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_change_dns_servers_both"])
    def test_dns_servers_default(self):
        """Test DNS servers with default configuration"""
        response = self.api.execute("dns", "test_dns_servers")
        assert self.validate_response(response), "DNS test failed"

        # Verify structure
        assert 'all_passed' in response.data, "Missing 'all_passed' in response"
        assert 'servers_tested' in response.data, "Missing 'servers_tested' in response"
        assert 'results' in response.data, "Missing 'results' in response"

        results = response.data['results']
        assert isinstance(results, list), "Results should be a list"
        assert len(results) > 0, "No test results returned"

        # Check results
        for result in results:
            assert 'server' in result, f"Missing 'server' in result: {result}"
            assert 'success' in result, f"Missing 'success' in result: {result}"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_dns_servers_default"])
    def test_dns_status(self):
        """Test DNS status endpoint"""
        response = self.api.execute("dns", "status")
        assert self.validate_response(response), "Failed to get DNS status"

        # Verify config
        assert 'configuration' in response.data, "Missing 'configuration' in response"
        config = response.data['configuration']
        assert 'primary' in config, "Missing primary DNS in configuration"
        assert 'secondary' in config, "Missing secondary DNS in configuration"

        # Verify health
        assert 'health' in response.data, "Missing 'health' in response"
        health = response.data['health']
        assert 'status' in health, "Missing status in health"
        assert 'test_results' in health, "Missing test_results in health"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_dns_status"])
    def test_invalid_dns_rejection(self):
        """Test invalid DNS server rejection"""
        # Test invalid IP
        response = self.api.execute("dns", "change_dns_servers",
                                    primary='999.999.999.999')

        assert not self.validate_response(response), "Invalid DNS was not rejected!"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_invalid_dns_rejection"])
    def test_partial_dns_update(self):
        """Test updating only primary DNS"""
        # Get current state
        current_response = self.api.execute("dns", "get_dns_servers")
        assert self.validate_response(current_response), "Failed to get current DNS"

        current_secondary = current_response.data['secondary']

        # Update primary only
        new_primary = self.TEST_DNS_SERVERS['google'][0]
        response = self.api.execute("dns", "change_dns_servers",
                                    primary=new_primary)

        assert self.validate_response(response), "Failed to update primary DNS"

        # Verify partial update
        dns_data = response.data['dns_servers']
        assert dns_data['primary'] == new_primary, \
            f"Primary DNS not updated correctly - Expected: {new_primary}, Got: {dns_data['primary']}"
        assert dns_data['secondary'] == current_secondary, \
            f"Secondary DNS changed unexpectedly - Expected: {current_secondary}, Got: {dns_data['secondary']}"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_partial_dns_update"])
    def test_custom_domain_dns_test(self):
        """Test DNS servers with custom domain"""
        response = self.api.execute("dns", "test_dns_servers",
                                    domain='github.com')

        assert self.validate_response(response), "Custom domain DNS test failed"

        # Verify results
        assert 'all_passed' in response.data, "Missing 'all_passed' in response"
        assert 'results' in response.data, "Missing 'results' in response"

        results = response.data['results']

        # Verify custom domain
        for result in results:
            if 'test_domain' in result:
                assert result['test_domain'] == 'github.com', \
                    f"Custom domain not used in test: {result['test_domain']}"

    @pytest.mark.dependency(depends=["TestDnsFunctionality::test_custom_domain_dns_test"])
    def test_restore_original_dns(self):
        """Restore original DNS settings"""
        # Get initial state
        initial_response = self.api.execute("dns", "get_dns_servers")
        assert self.validate_response(initial_response), "Failed to get initial DNS for restoration"

        # Determine restore values
        if hasattr(self, 'original_dns') and self.original_dns:
            primary = self.original_dns.get('primary', initial_response.data['primary'])
            secondary = self.original_dns.get('secondary', initial_response.data['secondary'])
        else:
            # Use current as fallback
            primary = initial_response.data['primary']
            secondary = initial_response.data['secondary']

        # Apply restoration
        response = self.api.execute("dns", "change_dns_servers",
                                    primary=primary,
                                    secondary=secondary)

        assert self.validate_response(response), "Failed to restore original DNS settings!"

        # Verify restoration
        verify_response = self.api.execute("dns", "get_dns_servers")
        assert self.validate_response(verify_response), "Failed to verify DNS restoration"

        current_primary = verify_response.data['primary']
        current_secondary = verify_response.data['secondary']

        # Verify valid DNS
        assert self.validate_ip_address(current_primary), f"Invalid primary DNS after restore: {current_primary}"
        assert self.validate_ip_address(current_secondary), f"Invalid secondary DNS after restore: {current_secondary}"
