# noinspection DuplicatedCode
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Ghost Module Docker Integration Test

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import os
from contextlib import contextmanager

from phantom.modules.core.tests.helpers.docker_test_helper import DockerCommandExecutor
from phantom.modules.core.tests.helpers.command_executor import CommandExecutor


class TestModuleDocker:

    @contextmanager
    def _test_environment(self):
        os.environ["PHANTOM_TEST"] = "1"
        try:
            yield
        finally:
            if "PHANTOM_TEST" in os.environ:
                del os.environ["PHANTOM_TEST"]

    @pytest.fixture
    def docker_executor(self, shared_docker_container):
        executor = DockerCommandExecutor(shared_docker_container)
        executor.container = shared_docker_container
        return executor

    @pytest.fixture
    def command_executor(self, docker_executor):
        return CommandExecutor(docker_executor)

    @pytest.fixture
    def ghost_module(self, shared_docker_container, docker_executor, command_executor):

        from pathlib import Path
        executor_path = Path(__file__).parent.parent.parent.parent / "core" / "tests"/ "helpers" / "path_executor.py"


        # Copy path executor helper to container for file operations
        with open(executor_path, 'r') as f:
            executor_content = f.read()

        # Escape single quotes and write executor to container
        escaped_content = executor_content.replace("'", "'\\''")
        write_cmd = f"cat > /tmp/path_executor.py << 'EXECUTOR_EOF'\n{escaped_content}\nEXECUTOR_EOF"
        docker_executor(f"bash -c '{write_cmd}'")
        docker_executor("chmod +x /tmp/path_executor.py")

        import pathlib
        import builtins
        import pickle
        import base64

        # Store original file operations for non-Docker paths
        original_open = builtins.open
        original_methods = {}

        # Intercept Path methods that need Docker redirection
        for method_name in ['exists', 'is_file', 'is_dir', 'mkdir', 'read_text', 'write_text', 'glob', 'iterdir',
                            'open', 'unlink']:
            if hasattr(pathlib.Path, method_name):
                original_methods[method_name] = getattr(pathlib.Path, method_name)

        def create_method_wrapper(name, method):
            def wrapper(path_self, *args, **kwargs):
                path_str = str(path_self)

                # Redirect operations for container paths only
                if any(prefix in path_str for prefix in ['/opt/phantom-wg', '/etc/', '/opt/wstunnel']):
                    request = {
                        'path': path_str,
                        'method': name,
                        'args': args,
                        'kwargs': kwargs
                    }

                    # Serialize and encode request for container execution
                    encoded_request = base64.b64encode(pickle.dumps(request)).decode()

                    cmd = f"python3 /tmp/path_executor.py '{encoded_request}'"
                    result = docker_executor.run_command(cmd)

                    if result['success'] and result['stdout']:
                        try:
                            raw_output = result['stdout'].strip()

                            # Extract the last line containing encoded response
                            output_lines = raw_output.split('\n')
                            encoded_response = output_lines[-1] if output_lines else ''

                            response = pickle.loads(base64.b64decode(encoded_response))

                            if response['success']:
                                return response['result']
                            else:
                                raise Exception(f"Path operation failed in container: {response['error']}")
                        except Exception:
                            raise
                    else:
                        raise Exception(f"Docker command failed: {result.get('stderr', 'Unknown error')}")
                # Use original method for host paths
                return method(path_self, *args, **kwargs)

            return wrapper

        class DockerFileProxy:

            def __init__(self, path, mode='r'):
                self.path = path
                self.mode = mode
                self.closed = False
                self._content = ""
                if 'r' in mode:
                    # Read file content from container on open
                    request = {
                        'type': 'file',
                        'path': path,
                        'method': 'read',
                        'args': (),
                        'kwargs': {}
                    }
                    encoded_request = base64.b64encode(pickle.dumps(request)).decode()
                    cmd = f"python3 /tmp/path_executor.py '{encoded_request}'"
                    result = docker_executor.run_command(cmd)
                    if result['success'] and result['stdout']:
                        response = pickle.loads(base64.b64decode(result['stdout'].strip().split('\n')[-1]))
                        if response['success']:
                            self._content = response['result']
                        else:
                            raise IOError(f"Cannot read {path}: {response['error']}")

            def read(self):
                if self.closed:
                    raise ValueError("I/O operation on closed file")
                return self._content

            def readlines(self):
                if self.closed:
                    raise ValueError("I/O operation on closed file")
                if not self._content:
                    return []
                lines = self._content.splitlines(keepends=True)
                if not self._content.endswith('\n') and lines:
                    lines[-1] = lines[-1].rstrip('\n')
                return lines

            def write(self, data):
                if self.closed:
                    raise ValueError("I/O operation on closed file")
                self._content += str(data)
                return len(data)

            def close(self):
                if not self.closed and 'w' in self.mode:
                    request = {
                        'type': 'file',
                        'path': self.path,
                        'method': 'write',
                        'args': (self._content,),
                        'kwargs': {}
                    }
                    encoded_request = base64.b64encode(pickle.dumps(request)).decode()
                    cmd = f"python3 /tmp/path_executor.py '{encoded_request}'"
                    docker_executor.run_command(cmd)
                self.closed = True

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_val, exc_tb):
                self.close()

        def wrapped_open(file, mode='r', *args, **kwargs):
            file_str = str(file)
            if any(prefix in file_str for prefix in ['/opt/phantom-wg', '/etc/', '/opt/wstunnel']):
                return DockerFileProxy(file_str, mode)
            return original_open(file, mode, *args, **kwargs)

        # Replace builtins.open with our wrapped version
        builtins.open = wrapped_open
        # Replace Path methods with Docker-aware versions
        for method_name, original_method in original_methods.items():
            setattr(pathlib.Path, method_name, create_method_wrapper(method_name, original_method))

        # Intercept shutil.rmtree for Docker container paths
        import shutil
        original_rmtree = shutil.rmtree

        def wrapped_rmtree(path):
            path_str = str(path)
            if any(prefix in path_str for prefix in ['/opt/phantom-wg', '/opt/wstunnel']):
                # Execute rm -rf in docker container
                docker_executor(["rm", "-rf", path_str])
            else:
                # Use original for other paths
                original_rmtree(path)

        shutil.rmtree = wrapped_rmtree

        from phantom.modules.ghost.module import GhostModule

        class DockerGhostModule(GhostModule):
            def _run_command(self, command, **kwargs):
                return command_executor.run_command(command, **kwargs)

        ghost_module = DockerGhostModule()

        yield ghost_module

    @pytest.mark.docker
    @pytest.mark.dependency()
    def test_enable_ghost_mode(self, docker_executor, shared_docker_container, ghost_module):

        # noinspection PyArgumentList
        with self._test_environment():
            ip_result = docker_executor(["curl", "-s", "https://checkip.amazonaws.com"])
            assert ip_result["success"], "Failed to retrieve server IP"

            server_ip = ip_result["stdout"].strip()
            assert server_ip, "Server IP is empty"

            # nip.io provides wildcard DNS for testing
            test_domain = f"ghost-test-{server_ip.replace('.', '-')}.nip.io"

            enable_result = ghost_module.enable_ghost_mode(test_domain)
            assert enable_result is not None, "enable_ghost_mode returned None"
            assert isinstance(enable_result, dict), "Result should be a dictionary"

            assert "status" in enable_result, "Missing 'status' field"
            assert "server_ip" in enable_result, "Missing 'server_ip' field"
            assert "domain" in enable_result, "Missing 'domain' field"
            assert "secret" in enable_result, "Missing 'secret' field"
            assert "protocol" in enable_result, "Missing 'protocol' field"
            assert "port" in enable_result, "Missing 'port' field"
            assert enable_result["status"] == "active", f"Status should be 'active', got: {enable_result['status']}"
            assert enable_result["server_ip"] == server_ip, "Server IP mismatch"
            assert enable_result["domain"] == test_domain, "Domain mismatch"
            assert enable_result["protocol"] == "wss", "Protocol should be 'wss'"
            assert enable_result["port"] == 443, "Port should be 443"
            assert enable_result["secret"], "Secret should not be empty"
            cert_path = f"/etc/letsencrypt/live/{test_domain}/fullchain.pem"
            key_path = f"/etc/letsencrypt/live/{test_domain}/privkey.pem"

            cert_check = docker_executor(["test", "-f", cert_path])
            assert cert_check["success"], f"SSL certificate not found at {cert_path}"

            key_check = docker_executor(["test", "-f", key_path])
            assert key_check["success"], f"SSL private key not found at {key_path}"
            service_check = docker_executor(["test", "-f", "/etc/systemd/system/wstunnel.service"])
            assert service_check["success"], "wstunnel service file not created"
            wstunnel_check = docker_executor(["test", "-x", "/opt/wstunnel/wstunnel"])
            assert wstunnel_check["success"], "wstunnel binary not found or not executable"
            # Systemd might not work in container environment
            service_status = docker_executor(["systemctl", "is-active", "wstunnel"])
            if service_status["returncode"] == 0:
                assert service_status["stdout"].strip() == "active", "wstunnel service not active"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_enable_ghost_mode"])
    def test_get_status_enabled(self, docker_executor, shared_docker_container, ghost_module):
        status_result = ghost_module.get_status()
        assert status_result is not None, "get_status returned None"
        assert isinstance(status_result, dict), "Result should be a dictionary"

        assert "status" in status_result, "Missing 'status' field"
        assert "enabled" in status_result, "Missing 'enabled' field"

        assert status_result["enabled"] is True, "Ghost Mode should be enabled"

        assert status_result["status"] in ["active", "error"], f"Unexpected status: {status_result['status']}"
        assert "server_ip" in status_result, "Missing 'server_ip' field"
        assert "domain" in status_result, "Missing 'domain' field"
        assert "secret" in status_result, "Missing 'secret' field"
        assert "protocol" in status_result, "Missing 'protocol' field"
        assert "port" in status_result, "Missing 'port' field"

        assert status_result["protocol"] == "wss", "Protocol should be 'wss'"
        assert status_result["port"] == 443, "Port should be 443"
        # Secret truncation: first 10 chars + "..."
        assert status_result["secret"].endswith("..."), "Secret should be truncated with '...'"
        assert len(status_result["secret"]) == 13, "Secret should be 10 chars + '...'"
        assert "services" in status_result, "Missing 'services' field"
        assert isinstance(status_result["services"], dict), "Services should be a dictionary"
        assert "wstunnel" in status_result["services"], "Missing wstunnel service status"
        assert status_result["services"]["wstunnel"] in ["active", "inactive"], "Invalid wstunnel status"
        assert "activated_at" in status_result, "Missing 'activated_at' field"
        assert "connection_command" in status_result, "Missing 'connection_command' field"
        assert "client_export_info" in status_result, "Missing 'client_export_info' field"

        assert status_result["client_export_info"] == "To export client configuration, use: phantom-casper [username]"
        assert "message" not in status_result, "Message field should not be present when enabled"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_get_status_enabled"])
    def test_disable_ghost_mode(self, docker_executor, shared_docker_container, ghost_module):

        ip_result = docker_executor(["curl", "-s", "https://checkip.amazonaws.com"])
        server_ip = ip_result["stdout"].strip()
        test_domain = f"ghost-test-{server_ip.replace('.', '-')}.nip.io"

        disable_result = ghost_module.disable_ghost_mode()
        assert disable_result is not None, "disable_ghost_mode returned None"
        assert isinstance(disable_result, dict), "Result should be a dictionary"

        assert "status" in disable_result, "Missing 'status' field"
        assert "message" in disable_result, "Missing 'message' field"
        assert disable_result["status"] == "inactive", f"Status should be 'inactive', got: {disable_result['status']}"

        assert disable_result[
                   "message"] == "Ghost Mode disabled successfully", f"Unexpected message: {disable_result['message']}"
        assert "restored" in disable_result, "Missing 'restored' field"
        assert disable_result["restored"] is True, "Restored should be True"
        cert_path = f"/etc/letsencrypt/live/{test_domain}/fullchain.pem"
        cert_check = docker_executor(["test", "-f", cert_path])
        assert not cert_check["success"], f"SSL certificate should be removed: {cert_path}"
        service_check = docker_executor(["test", "-f", "/etc/systemd/system/wstunnel.service"])
        assert not service_check["success"], "wstunnel service file should be removed"
        wstunnel_dir_check = docker_executor(["test", "-d", "/opt/wstunnel"])
        assert not wstunnel_dir_check["success"], "wstunnel directory should be removed"
        state_file_check = docker_executor(["test", "-f", "/opt/phantom-wg/config/ghost-state.json"])
        if state_file_check["returncode"] == 0:
            cat_result = docker_executor(["cat", "/opt/phantom-wg/config/ghost-state.json"])
            if cat_result["success"] and cat_result["stdout"]:
                import json
                try:
                    state_data = json.loads(cat_result["stdout"])
                    assert state_data.get("enabled", True) is False, "State file should show disabled"
                except (json.JSONDecodeError, ValueError):
                    pass  # Empty file is acceptable

        # Test idempotency
        disable_again_result = ghost_module.disable_ghost_mode()
        assert disable_again_result is not None, "Second disable returned None"
        assert disable_again_result["status"] == "inactive", "Second disable should also be inactive"
        assert disable_again_result[
                   "message"] == "Ghost Mode is not active", "Second disable should indicate not active"
        assert "restored" not in disable_again_result, "Restored field should not be present when already disabled"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_disable_ghost_mode"])
    def test_get_status_disabled(self, docker_executor, shared_docker_container, ghost_module):

        status_result = ghost_module.get_status()
        assert status_result is not None
        assert isinstance(status_result, dict)
        assert status_result["status"] == "inactive"
        assert status_result["enabled"] is False
        assert status_result["message"] == "Ghost Mode is not active"
