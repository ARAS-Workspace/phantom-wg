"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

DNS Module Integration Test

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest

from phantom.modules.dns.module import DnsModule


# noinspection PyDeprecation
class TestModule:
    @pytest.fixture
    def dns_module(self, test_environment):
        dns_module = DnsModule(install_dir=test_environment["tmp_path"])
        yield dns_module

    @pytest.mark.dependency()
    def test_get_module_name(self, dns_module):
        result = dns_module.get_module_name()
        assert result == "dns"

    @pytest.mark.dependency(depends=["TestModule::test_get_module_name"])
    def test_get_module_description(self, dns_module):
        result = dns_module.get_module_description()
        assert isinstance(result, str)
        assert "DNS" in result

    @pytest.mark.dependency(depends=["TestModule::test_get_module_description"])
    def test_get_actions(self, dns_module):
        result = dns_module.get_actions()

        assert isinstance(result, dict)
        assert "change_dns_servers" in result
        assert "test_dns_servers" in result
        assert "status" in result
        assert "get_dns_servers" in result

        for action in result.values():
            assert callable(action)

    @pytest.mark.dependency(depends=["TestModule::test_get_actions"])
    def test_get_dns_servers(self, dns_module):
        result = dns_module.get_dns_servers()

        assert isinstance(result, dict)
        assert "primary" in result
        assert "secondary" in result
        assert result["primary"] == "1.1.1.1"
        assert result["secondary"] == "1.0.0.1"

    @pytest.mark.dependency(depends=["TestModule::test_get_dns_servers"])
    def test_change_dns_servers_valid(self, dns_module, test_environment):
        new_primary = "1.1.1.1"
        new_secondary = "8.8.4.4"

        result = dns_module.change_dns_servers(
            primary=new_primary,
            secondary=new_secondary
        )

        assert isinstance(result, dict)
        assert result["success"] is True
        assert "dns_servers" in result
        assert result["dns_servers"]["primary"] == new_primary
        assert result["dns_servers"]["secondary"] == new_secondary

        # Verify persistence
        import json
        config_path = test_environment["config_path"]
        with open(config_path, 'r') as f:
            saved_config = json.load(f)

        assert saved_config["dns"]["primary"] == new_primary
        assert saved_config["dns"]["secondary"] == new_secondary

        current = dns_module.get_dns_servers()
        assert current["primary"] == new_primary
        assert current["secondary"] == new_secondary

    @pytest.mark.dependency(depends=["TestModule::test_change_dns_servers_valid"])
    def test_change_dns_servers_partial(self, dns_module):
        original = dns_module.get_dns_servers()
        original_secondary = original["secondary"]

        new_primary = "9.9.9.9"
        result = dns_module.change_dns_servers(primary=new_primary)

        assert result["success"] is True
        assert result["dns_servers"]["primary"] == new_primary
        assert result["dns_servers"]["secondary"] == original_secondary

        new_secondary = "149.112.112.112"
        result = dns_module.change_dns_servers(secondary=new_secondary)

        assert result["success"] is True
        assert result["dns_servers"]["primary"] == new_primary
        assert result["dns_servers"]["secondary"] == new_secondary

    @pytest.mark.dependency(depends=["TestModule::test_change_dns_servers_partial"])
    def test_change_dns_servers_invalid(self, dns_module):
        from phantom.api.exceptions import ValidationError

        with pytest.raises(ValidationError):
            dns_module.change_dns_servers(primary="invalid.ip")

        with pytest.raises(ValidationError):
            dns_module.change_dns_servers(secondary="256.256.256.256")

        with pytest.raises(ValidationError):
            dns_module.change_dns_servers(primary="2001:4860:4860::8888")

    @pytest.mark.dependency(depends=["TestModule::test_change_dns_servers_invalid"])
    def test_test_dns_servers_default(self, dns_module):
        import shutil

        if not shutil.which('nslookup'):
            pytest.skip("nslookup command not available on this system")

        result = dns_module.test_dns_servers()

        assert isinstance(result, dict)
        assert "all_passed" in result
        assert "servers_tested" in result
        assert "results" in result
        assert isinstance(result["results"], list)

        assert result["servers_tested"] == 2
        assert len(result["results"]) == 2

        for server_result in result["results"]:
            assert "server" in server_result
            assert "status" in server_result
            assert "success" in server_result

            if server_result["success"]:
                assert server_result["status"] == "OK"
                assert "test_domain" in server_result
                assert server_result["test_domain"] == "google.com"

                if "response_time_ms" in server_result:
                    assert isinstance(server_result["response_time_ms"], (int, float))
                    assert server_result["response_time_ms"] >= 0
            else:
                assert server_result["status"] in ["FAILED", "TIMEOUT", "ERROR"]
                if "error" in server_result:
                    assert isinstance(server_result["error"], str)

        result_servers = [r["server"] for r in result["results"]]
        assert "1.1.1.1" in result_servers
        assert "1.0.0.1" in result_servers

    @pytest.mark.dependency(depends=["TestModule::test_test_dns_servers_default"])
    def test_test_dns_servers_custom(self, dns_module):
        servers = ["8.8.8.8", "1.1.1.1"]
        domain = "cloudflare.com"

        result = dns_module.test_dns_servers(
            servers=servers,
            domain=domain
        )

        assert result["servers_tested"] == 2

        for server_result in result["results"]:
            assert server_result["server"] in servers

            if server_result["success"]:
                assert "test_domain" in server_result
                assert server_result["test_domain"] == domain

    @pytest.mark.dependency(depends=["TestModule::test_test_dns_servers_custom"])
    def test_test_dns_servers_invalid(self, dns_module):
        from phantom.api.exceptions import ValidationError

        with pytest.raises(ValidationError):
            dns_module.test_dns_servers(servers=["invalid", "256.256.256.256"])

    @pytest.mark.dependency(depends=["TestModule::test_test_dns_servers_invalid"])
    def test_test_dns_servers_mixed(self, dns_module):
        servers = ["8.8.8.8", "invalid.ip", "1.1.1.1"]

        result = dns_module.test_dns_servers(servers=servers)

        assert result["servers_tested"] == 2

        tested_servers = [r["server"] for r in result["results"]]
        assert "8.8.8.8" in tested_servers
        assert "1.1.1.1" in tested_servers
        assert "invalid.ip" not in tested_servers

    @pytest.mark.dependency(depends=["TestModule::test_test_dns_servers_mixed"])
    def test_unreachable_dns_server_sets_all_passed_false(self, dns_module):
        import shutil

        if not shutil.which('nslookup'):
            pytest.skip("nslookup command not available on this system")

        unreachable_servers = ["192.0.2.1", "192.0.2.2"]

        result = dns_module.test_dns_servers(servers=unreachable_servers)

        assert isinstance(result, dict)
        assert "all_passed" in result
        assert "servers_tested" in result
        assert "results" in result

        assert result["all_passed"] is False
        assert result["servers_tested"] == len(unreachable_servers)

        for server_result in result["results"]:
            assert server_result["success"] is False
            assert server_result["status"] in ["FAILED", "TIMEOUT", "ERROR"]
            assert server_result["server"] in unreachable_servers

    @pytest.mark.dependency(depends=["TestModule::test_unreachable_dns_server_sets_all_passed_false"])
    def test_mixed_reachable_unreachable_dns_servers(self, dns_module):
        import shutil

        if not shutil.which('nslookup'):
            pytest.skip("nslookup command not available on this system")

        mixed_servers = ["8.8.8.8", "192.0.2.1", "1.1.1.1", "192.0.2.2"]

        result = dns_module.test_dns_servers(servers=mixed_servers)

        assert isinstance(result, dict)
        assert "all_passed" in result
        assert "results" in result
        assert result["servers_tested"] == len(mixed_servers)

        failure_count = sum(1 for r in result["results"] if not r["success"])
        assert failure_count >= 2

        if failure_count > 0:
            assert result["all_passed"] is False

        for server_result in result["results"]:
            if server_result["server"].startswith("192.0.2."):
                assert server_result["success"] is False
                assert server_result["status"] in ["FAILED", "TIMEOUT", "ERROR"]

    @pytest.mark.dependency(depends=["TestModule::test_mixed_reachable_unreachable_dns_servers"])
    def test_status(self, dns_module):
        result = dns_module.status()

        assert isinstance(result, dict)
        assert "configuration" in result
        assert "health" in result

        config = result["configuration"]
        assert "primary" in config
        assert "secondary" in config

        health = result["health"]
        assert "status" in health
        assert health["status"] in ["healthy", "degraded", "unavailable"]
        assert "test_results" in health

        test_results = health["test_results"]
        assert len(test_results) >= 2

        for test in test_results:
            assert "server" in test
            assert "tests" in test

    @pytest.mark.dependency(depends=["TestModule::test_status"])
    def test_config_persistence(self, dns_module, test_environment):
        new_primary = "9.9.9.9"
        new_secondary = "149.112.112.112"

        dns_module.change_dns_servers(
            primary=new_primary,
            secondary=new_secondary
        )

        new_dns_module = DnsModule(install_dir=test_environment["tmp_path"])

        result = new_dns_module.get_dns_servers()
        assert result["primary"] == new_primary
        assert result["secondary"] == new_secondary

    @pytest.mark.dependency(depends=["TestModule::test_config_persistence"])
    def test_dns_config_defaults(self, test_environment):
        import os
        import json

        config_path = test_environment["config_path"]
        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                config = json.load(f)

            if "dns" in config:
                del config["dns"]

            with open(config_path, 'w') as f:
                json.dump(config, f, indent=4)

        dns_module = DnsModule(install_dir=test_environment["tmp_path"])

        result = dns_module.get_dns_servers()
        assert result["primary"] == "9.9.9.9"
        assert result["secondary"] == "1.1.1.1"

    @pytest.mark.dependency(depends=["TestModule::test_dns_config_defaults"])
    def test_change_dns_servers_config_error(self, dns_module, monkeypatch):
        from phantom.api.exceptions import ConfigurationError

        def mock_save_config():
            raise Exception("Permission denied")

        monkeypatch.setattr(dns_module, "_save_config", mock_save_config)

        with pytest.raises(ConfigurationError) as exc_info:
            dns_module.change_dns_servers(primary="8.8.8.8", secondary="8.8.4.4")

        assert "Failed to change DNS servers" in str(exc_info.value)

    @pytest.mark.dependency(depends=["TestModule::test_change_dns_servers_config_error"])
    def test_dns_server_test_timeout(self, dns_module, monkeypatch):
        import subprocess

        def mock_subprocess_run(*args, **_kwargs):
            raise subprocess.TimeoutExpired(cmd=args[0], timeout=5)

        monkeypatch.setattr(subprocess, "run", mock_subprocess_run)

        result = dns_module._test_single_dns_server("8.8.8.8", "google.com")

        assert result["success"] is False
        assert result["status"] == "TIMEOUT"
        assert "timed out" in result["error"]

    @pytest.mark.dependency(depends=["TestModule::test_dns_server_test_timeout"])
    def test_dns_server_test_failure(self, dns_module, monkeypatch):
        import subprocess
        from unittest.mock import MagicMock

        def mock_subprocess_run(*_args, **_kwargs):
            mock_result = MagicMock()
            mock_result.returncode = 1
            mock_result.stderr = "NXDOMAIN: domain not found"
            mock_result.stdout = ""
            return mock_result

        monkeypatch.setattr(subprocess, "run", mock_subprocess_run)

        result = dns_module._test_single_dns_server("8.8.8.8", "invalid.domain.test")

        assert result["success"] is False
        assert result["status"] == "FAILED"
        assert "NXDOMAIN" in result["error"]

    @pytest.mark.dependency(depends=["TestModule::test_dns_server_test_failure"])
    def test_dns_server_test_exception(self, dns_module, monkeypatch):
        import subprocess

        def mock_subprocess_run(*_args, **_kwargs):
            raise OSError("Network unreachable")

        monkeypatch.setattr(subprocess, "run", mock_subprocess_run)

        result = dns_module._test_single_dns_server("8.8.8.8", "google.com")

        assert result["success"] is False
        assert result["status"] == "ERROR"
        assert "Network unreachable" in result["error"]

    @pytest.mark.dependency(depends=["TestModule::test_dns_server_test_exception"])
    def test_internal_dns_test_exception(self, dns_module, monkeypatch):
        import subprocess
        from unittest.mock import MagicMock

        def mock_subprocess_failure(cmd, *_args, **_kwargs):
            if 'dig' in cmd[0]:
                mock_result = MagicMock()
                mock_result.returncode = 1
                mock_result.stdout = ""
                mock_result.stderr = "Query failed: SERVFAIL"
                return mock_result
            return subprocess.CompletedProcess(cmd, 0, "OK", "")

        monkeypatch.setattr(subprocess, "run", mock_subprocess_failure)

        result = dns_module._test_dns_servers_internal()
        assert isinstance(result, dict)
        assert "all_passed" in result
        assert result["all_passed"] is False
        assert "results" in result
        assert len(result["results"]) == 2

        for server_result in result["results"]:
            assert "tests" in server_result
            for test in server_result["tests"]:
                assert test["success"] is False
                assert test.get("error") is not None

        def mock_subprocess_exception(cmd, *_args, **_kwargs):
            if 'dig' in cmd[0]:
                raise subprocess.TimeoutExpired(cmd=cmd, timeout=5)
            return subprocess.CompletedProcess(cmd, 0, "OK", "")

        monkeypatch.setattr(subprocess, "run", mock_subprocess_exception)

        result2 = dns_module._test_dns_servers_internal()
        assert result2["all_passed"] is False
        assert len(result2["results"]) == 2

        for server_result in result2["results"]:
            for test in server_result["tests"]:
                assert test["success"] is False
                error_msg = test.get("error", "")
                assert error_msg and ("Command" in error_msg or "timeout" in error_msg.lower())

        call_count = [0]

        def mock_subprocess_mixed(cmd, *_args, **_kwargs):
            nonlocal call_count
            call_count[0] += 1

            if 'dig' in cmd[0]:
                mock_result = MagicMock()
                # First call succeeds, rest fail
                if call_count[0] == 1:
                    mock_result.returncode = 0
                    mock_result.stdout = "93.184.216.34"
                    mock_result.stderr = ""
                else:
                    mock_result.returncode = 1
                    mock_result.stdout = ""
                    mock_result.stderr = "Connection refused"
                return mock_result
            return subprocess.CompletedProcess(cmd, 0, "OK", "")

        call_count = [0]

        monkeypatch.setattr(subprocess, "run", mock_subprocess_mixed)

        result3 = dns_module._test_dns_servers_internal()
        assert result3["all_passed"] is False

        success_count = 0
        failure_count = 0
        for server_result in result3["results"]:
            for test in server_result["tests"]:
                if test["success"]:
                    success_count += 1
                else:
                    failure_count += 1

        assert success_count >= 1
        assert failure_count >= 1
