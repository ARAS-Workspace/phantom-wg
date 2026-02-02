"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Multihop Module Integration Tests

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import pytest
import shutil
from pathlib import Path
from textwrap import dedent

from phantom.modules.core.tests.helpers.docker_test_helper import DockerCommandExecutor
from phantom.modules.core.tests.helpers.command_executor import CommandExecutor
from phantom.modules.multihop.lib.common_tools import (
    VPN_INTERFACE_NAME
)
from phantom.api.exceptions import MultihopError

# noinspection DuplicatedCode
class TestModuleDocker:

    @staticmethod
    def _prepare_container_for_multihop_tests(shared_docker_container, docker_executor):

        host_phantom_dir = Path(shared_docker_container.host_phantom_dir)
        container_phantom_dir = Path(shared_docker_container.container_phantom_dir)

        scripts_source = Path(__file__).parent.parent.parent.parent.parent / "scripts"
        scripts_dest = host_phantom_dir / "phantom" / "scripts"
        if scripts_source.exists():
            shutil.copytree(scripts_source, scripts_dest, dirs_exist_ok=True)

        docker_executor(f'python3 -m venv {container_phantom_dir}/.phantom-venv')

        docker_executor(
            f'cp {container_phantom_dir}/phantom/scripts/phantom-multihop-monitor.service /etc/systemd/system')
        docker_executor(f'chmod +x {container_phantom_dir}/phantom/scripts/multihop-monitor-service.py')

        docker_executor(
            f'cp {container_phantom_dir}/phantom/scripts/phantom-multihop-interface.service /etc/systemd/system')
        docker_executor(f'chmod +x {container_phantom_dir}/phantom/scripts/multihop-interface-restore.py')

        docker_executor('systemctl daemon-reload')

        docker_executor('mkdir -p /opt/phantom-wg/exit_configs')
        docker_executor('mkdir -p /opt/phantom-wg/data/vpn_configs')

        docker_executor('mkdir -p /etc/iproute2')
        docker_executor("sh -c 'echo \"100 multihop\" >> /etc/iproute2/rt_tables'")
        docker_executor("cat /etc/iproute2/rt_tables")

    @staticmethod
    def _prepare_exit_for_multihop_tests(shared_docker_container, docker_executor):
        # Get container paths
        container_phantom_dir = Path(shared_docker_container.container_phantom_dir)

        # Create network namespace for exit server simulation
        exit_ns = "wg-test-exit"

        # Create network namespace for exit server
        docker_executor(f"ip netns add {exit_ns}")
        docker_executor("ip link add veth-main type veth peer name veth-exit")
        docker_executor(f"ip link set veth-exit netns {exit_ns}")

        # Configure main namespace side
        docker_executor("ip addr add 172.16.100.1/24 dev veth-main")
        docker_executor("ip link set veth-main up")

        # Configure exit namespace side
        docker_executor(f"ip netns exec {exit_ns} ip addr add 172.16.100.2/24 dev veth-exit")
        docker_executor(f"ip netns exec {exit_ns} ip link set veth-exit up")
        docker_executor(f"ip netns exec {exit_ns} ip link set lo up")

        # Add default route in exit namespace
        docker_executor(f"ip netns exec {exit_ns} ip route add default via 172.16.100.1")

        # Generate WireGuard keys for exit server
        exit_private_result = docker_executor.run_command("wg genkey")
        exit_private_key = exit_private_result['stdout'].strip()
        exit_public_result = docker_executor.run_command(f"sh -c \"echo '{exit_private_key}' | wg pubkey\"")
        exit_public_key = exit_public_result['stdout'].strip()

        # Generate client keys for Phantom to connect to exit
        client_private_result = docker_executor.run_command("wg genkey")
        client_private_key = client_private_result['stdout'].strip()
        client_public_result = docker_executor.run_command(f"sh -c \"echo '{client_private_key}' | wg pubkey\"")
        client_public_key = client_public_result['stdout'].strip()

        # Setup WireGuard EXIT SERVER config in namespace
        exit_server_config = dedent(f"""
            [Interface]
            PrivateKey = {exit_private_key}
            Address = 10.9.0.1/24
            ListenPort = 51821

            [Peer]
            # Phantom client connection
            PublicKey = {client_public_key}
            AllowedIPs = 10.9.0.2/32
        """).strip()

        # Escape single quotes for bash
        escaped_exit_config = exit_server_config.replace("'", "'\"'\"'")

        # Write exit server config
        docker_executor(f"bash -c 'cat > /tmp/wg-exit-server.conf << \"EOF\"\n{escaped_exit_config}\nEOF'")

        # Setup WireGuard CLIENT config for Phantom to use
        phantom_exit_config = dedent(f"""
            [Interface]
            PrivateKey = {client_private_key}
            Address = 10.9.0.2/32
            DNS = 8.8.8.8, 8.8.4.4

            [Peer]
            PublicKey = {exit_public_key}
            Endpoint = 172.16.100.2:51821
            AllowedIPs = 0.0.0.0/0
            PersistentKeepalive = 25
        """).strip()

        # Escape single quotes for bash
        escaped_phantom_config = phantom_exit_config.replace("'", "'\"'\"'")

        # Save client config to data directory for import
        docker_executor(f"mkdir -p {container_phantom_dir}/data/vpn_configs")
        docker_executor(
            f"bash -c 'cat > {container_phantom_dir}/data/vpn_configs/test-exit.conf << \"EOF\"\n{escaped_phantom_config}\nEOF'")

        # Start WireGuard in exit namespace
        docker_executor(f"ip netns exec {exit_ns} wg-quick up /tmp/wg-exit-server.conf")

        # Enable IP forwarding in exit namespace
        docker_executor(f"ip netns exec {exit_ns} sysctl -w net.ipv4.ip_forward=1")

        # Verify exit server is listening
        docker_executor("nc -zuv -w 2 172.16.100.2 51821")

        # Setup NAT in exit namespace
        docker_executor(f"ip netns exec {exit_ns} iptables -t nat -A POSTROUTING -o veth-exit -j MASQUERADE")

    @pytest.fixture
    def docker_executor(self, shared_docker_container):
        executor = DockerCommandExecutor(shared_docker_container)
        executor.container = shared_docker_container
        return executor

    @pytest.fixture
    def command_executor(self, docker_executor):
        return CommandExecutor(docker_executor)

    @pytest.fixture
    def multihop_module(self, shared_docker_container, docker_executor, command_executor):

        TestModuleDocker._prepare_container_for_multihop_tests(shared_docker_container, docker_executor)
        TestModuleDocker._prepare_exit_for_multihop_tests(shared_docker_container, docker_executor)

        from pathlib import Path
        executor_path = Path(__file__).parent.parent.parent.parent / "core" / "tests"/ "helpers" / "path_executor.py"

        with open(executor_path, 'r') as f:
            executor_content = f.read()

        escaped_content = executor_content.replace("'", "'\\''")
        write_cmd = f"cat > /tmp/path_executor.py << 'EXECUTOR_EOF'\n{escaped_content}\nEXECUTOR_EOF"
        docker_executor(f"bash -c '{write_cmd}'")
        docker_executor("chmod +x /tmp/path_executor.py")

        import pathlib
        import builtins
        import pickle
        import base64

        original_open = builtins.open
        original_methods = {}

        for method_name in ['exists', 'is_file', 'is_dir', 'mkdir', 'read_text', 'write_text', 'glob', 'iterdir',
                            'open', 'unlink']:
            if hasattr(pathlib.Path, method_name):
                original_methods[method_name] = getattr(pathlib.Path, method_name)

        def create_method_wrapper(name, method):
            def wrapper(path_self, *args, **kwargs):
                path_str = str(path_self)

                if any(prefix in path_str for prefix in ['/opt/phantom-wg', '/etc/']):
                    request = {
                        'path': path_str,
                        'method': name,
                        'args': args,
                        'kwargs': kwargs
                    }

                    encoded_request = base64.b64encode(pickle.dumps(request)).decode()

                    cmd = f"python3 /tmp/path_executor.py '{encoded_request}'"
                    result = docker_executor.run_command(cmd)

                    if result['success'] and result['stdout']:
                        try:
                            raw_output = result['stdout'].strip()

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
                return method(path_self, *args, **kwargs)

            return wrapper

        class DockerFileProxy:
            def __init__(self, path, mode='r'):
                self.path = path
                self.mode = mode
                self.closed = False
                self._content = ""
                if 'r' in mode:
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
                # Split content into lines, preserving line endings
                if not self._content:
                    return []
                lines = self._content.splitlines(keepends=True)
                # If content doesn't end with newline, last line won't have one
                if not self._content.endswith('\n') and lines:
                    lines[-1] = lines[-1].rstrip('\n')
                return lines

            def write(self, data):
                if self.closed:
                    raise ValueError("I/O operation on closed file")
                self._content += str(data)
                return len(data)

            def flush(self):
                """Flush the write buffer. For compatibility with file-like objects."""
                if self.closed:
                    raise ValueError("I/O operation on closed file")
                # In a real file, flush would write buffered data to disk
                # For our proxy, we only write on close, so this is a no-op
                pass

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
            if any(prefix in file_str for prefix in ['/opt/phantom-wg', '/etc/']):
                return DockerFileProxy(file_str, mode)
            return original_open(file, mode, *args, **kwargs)

        builtins.open = wrapped_open
        for method_name, original_method in original_methods.items():
            setattr(pathlib.Path, method_name, create_method_wrapper(method_name, original_method))

        from phantom.modules.multihop.module import MultihopModule

        class DockerMultihopModule(MultihopModule):
            def _run_command(self, command, **kwargs):
                return command_executor.run_command(command, **kwargs)

        multihop_module = DockerMultihopModule()

        yield multihop_module

    @pytest.mark.docker
    @pytest.mark.dependency()
    def test_import_vpn_config(self, docker_executor, shared_docker_container, multihop_module):
        """Test VPN config import."""
        container_phantom_dir = Path(shared_docker_container.container_phantom_dir)
        config_path = f'{container_phantom_dir}/data/vpn_configs/test-exit.conf'

        result = multihop_module.import_vpn_config(config_path)

        # Basic structure check
        assert isinstance(result, dict)
        assert result['config_name'] == 'test-exit'
        assert 'backup_path' in result
        assert 'metadata' in result
        assert 'optimizations' in result
        assert 'message' in result

        # Check metadata
        assert result['metadata']['name'] == 'test-exit'
        assert result['metadata']['multihop_enhanced'] is True

        # Check optimizations applied
        assert isinstance(result['optimizations'], list)
        assert len(result['optimizations']) > 0

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_import_vpn_config"])
    def test_list_exits(self, docker_executor, shared_docker_container, multihop_module):
        """Test listing VPN exits after import."""
        # Assumes test_import_vpn_config already ran
        result = multihop_module.list_exits()

        # Basic structure check
        assert isinstance(result, dict)
        assert 'exits' in result
        assert 'multihop_enabled' in result
        assert 'active_exit' in result
        assert 'total' in result

        # Check exits list
        assert isinstance(result['exits'], list)
        assert result['total'] == 1
        assert len(result['exits']) == 1

        # Check exit info structure
        exit_info = result['exits'][0]
        assert exit_info['name'] == 'test-exit'
        assert exit_info['endpoint'] == '172.16.100.2:51821'
        assert exit_info['active'] is False  # Not active yet
        assert 'provider' in exit_info
        assert exit_info['multihop_enhanced'] is True

        # Check multihop status
        assert result['multihop_enabled'] is False  # Not enabled yet
        assert result['active_exit'] is None  # No active exit yet

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_list_exits"])
    def test_enable_multihop(self, docker_executor, shared_docker_container, multihop_module):
        """Test enabling multihop routing."""
        # Assumes test_import_vpn_config already ran
        result = multihop_module.enable_multihop('test-exit')

        # Basic structure check
        assert isinstance(result, dict)

        # Verify all required keys present
        required_keys = ['exit_name', 'multihop_enabled', 'handshake_established',
                         'connection_verified', 'monitor_started', 'traffic_flow',
                         'peer_access', 'message']
        for key in required_keys:
            assert key in result, f"Result should contain '{key}'"

        # Verify successful enablement
        assert result['exit_name'] == 'test-exit'
        assert result['multihop_enabled'] is True, "Multihop must be enabled"
        assert result['handshake_established'] is True, "Handshake should be established"
        assert result['connection_verified'] is True, "Connection should be verified"
        assert result['monitor_started'] is True, "Monitor should be started"

        # Verify traffic flow information
        assert '172.16.100.2:51821' in result['traffic_flow'], "Traffic flow should contain endpoint"
        assert 'Clients → Phantom → VPN Exit' in result['traffic_flow']
        assert result['peer_access'] == "Peers can still connect directly"

        # Verify success message
        assert 'successfully' in result['message']
        assert 'test-exit' in result['message']

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_enable_multihop"])
    def test_get_status(self, docker_executor, shared_docker_container, multihop_module):
        """Test getting multihop status after enablement."""
        # Assumes test_enable_multihop already ran
        result = multihop_module.get_status()

        # Basic structure check
        assert isinstance(result, dict)

        # Verify all required keys present
        required_keys = ['enabled', 'active_exit', 'available_configs',
                         'vpn_interface', 'monitor_status', 'traffic_routing',
                         'traffic_flow']
        for key in required_keys:
            assert key in result, f"Result should contain '{key}'"

        # Verify multihop is enabled (from previous test)
        assert result['enabled'] is True, "Multihop should be enabled"
        assert result['active_exit'] == 'test-exit', "Active exit should be test-exit"
        assert result['available_configs'] == 1, "Should have 1 available config"

        # Verify VPN interface status
        assert isinstance(result['vpn_interface'], dict)
        assert result['vpn_interface'].get('active') is True, "VPN interface should be active"
        if 'output' in result['vpn_interface']:
            assert VPN_INTERFACE_NAME in result['vpn_interface']['output'], f"Should show {VPN_INTERFACE_NAME} interface"

        # Verify monitor status
        assert isinstance(result['monitor_status'], dict)

        # Verify traffic routing information
        assert result['traffic_routing'] == "VPN Exit", "Traffic should be routed through VPN Exit"
        assert "Clients -> Phantom Server -> VPN Exit -> Internet" in result['traffic_flow']

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_get_status"])
    def test_vpn(self, docker_executor, shared_docker_container, multihop_module):
        """Test VPN connectivity after multihop is enabled."""
        # Assumes test_enable_multihop already ran
        result = multihop_module.test_vpn()

        # Basic structure check
        assert isinstance(result, dict)

        # Verify required keys
        required_keys = ['exit_name', 'endpoint', 'tests', 'all_tests_passed', 'message']
        for key in required_keys:
            assert key in result, f"Result should contain '{key}'"

        # Verify exit info
        assert result['exit_name'] == 'test-exit'
        assert result['endpoint'] == '172.16.100.2:51821'

        # Verify tests structure
        assert isinstance(result['tests'], dict)
        assert len(result['tests']) > 0, "Should have at least one test"

        # Check individual test results
        for test_name, test_result in result['tests'].items():
            assert isinstance(test_result, dict)
            assert 'passed' in test_result, f"Test '{test_name}' should have 'passed' field"

        # Verify overall result
        assert result['all_tests_passed'] is True, "All VPN tests should pass"
        assert 'passed' in result['message'].lower() or 'success' in result['message'].lower()

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_vpn"])
    def test_get_session_log(self, docker_executor, shared_docker_container, multihop_module):
        """Test getting session log after multihop is enabled."""
        # Assumes test_enable_multihop already ran
        result = multihop_module.get_session_log()

        # Basic structure check
        assert isinstance(result, dict)

        # Check if multihop is active
        assert 'active_session' in result
        assert result['active_session'] is True, "Session should be active"

        # Check log existence
        assert 'log_exists' in result
        assert result['log_exists'] is True, "Log file should exist"

        # Check active exit
        assert 'active_exit' in result
        assert result['active_exit'] == 'test-exit', "Active exit should be test-exit"

        # Check monitor status
        if 'monitor_status' in result and result['monitor_status']:
            assert isinstance(result['monitor_status'], dict)

        # Check log lines
        assert 'log_lines' in result
        assert isinstance(result['log_lines'], list)
        assert 'total_lines' in result
        assert 'displayed_lines' in result

        # Check that we have some log entries
        if result['log_lines']:
            # Each log line should be a dict with parsed info
            for log_line in result['log_lines']:
                assert isinstance(log_line, dict)

        # Check systemctl service status separately
        service_check = docker_executor('systemctl is-active phantom-multihop-monitor')
        service_status = service_check['stdout'].strip()
        assert service_status == 'active', f"Monitor service should be active, got: {service_status}"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_get_session_log"])
    def test_disable_multihop(self, docker_executor, shared_docker_container, multihop_module):
        """Test disabling multihop routing."""
        # Assumes test_enable_multihop already ran
        result = multihop_module.disable_multihop()

        # Basic structure check
        assert isinstance(result, dict)

        # Verify required keys
        required_keys = ['multihop_enabled', 'previous_exit', 'interface_cleaned', 'message']
        for key in required_keys:
            assert key in result, f"Result should contain '{key}'"

        # Verify multihop is disabled
        assert result['multihop_enabled'] is False, "Multihop should be disabled"

        # Check previous exit information
        assert result['previous_exit'] == 'test-exit', "Previous exit should be test-exit"

        # Verify interface cleanup
        assert result['interface_cleaned'] is True, "Interface should be cleaned up"

        # Verify success message
        assert 'disabled' in result['message'].lower() or 'direct' in result['message'].lower()
        assert 'client traffic now routes directly' in result['message'].lower()

        # Verify VPN interface is removed
        interface_check = docker_executor(f'ip link show {VPN_INTERFACE_NAME} 2>&1')
        assert 'does not exist' in interface_check['stdout'].lower() or interface_check['success'] is False

        # Verify monitor service is stopped
        service_check = docker_executor('systemctl is-active phantom-multihop-monitor')
        service_status = service_check['stdout'].strip()
        assert service_status == 'inactive', f"Monitor service should be inactive after disable, got: {service_status}"

        # Verify routing rules are cleaned up
        rules_check = docker_executor('ip rule list')
        assert 'lookup 100' not in rules_check['stdout'], "Routing rules should be cleaned up"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_disable_multihop"])
    def test_reset_state(self, docker_executor, shared_docker_container, multihop_module):
        """Test reset_state functionality to clean all multihop components."""
        # Assumes test_import_vpn_config already ran
        enable_result = multihop_module.enable_multihop('test-exit')

        # Basic structure check
        assert isinstance(enable_result, dict)
        assert enable_result['exit_name'] == 'test-exit'

        # Verify all components are active after enable
        # Check VPN interface exists
        interface_check = docker_executor(f'ip link show {VPN_INTERFACE_NAME}')
        assert interface_check['success'] is True, f"VPN interface ({VPN_INTERFACE_NAME}) should exist after enable"

        # Check routing rules exist
        rules_check = docker_executor('ip rule list')
        assert 'lookup multihop' in rules_check['stdout'], "Multihop routing rules should exist after enable"

        # Check NAT rules exist
        nat_check = docker_executor('iptables -t nat -L POSTROUTING -n')
        assert 'MASQUERADE' in nat_check['stdout'], "NAT MASQUERADE rules should exist after enable"

        # Check multihop state is enabled
        assert multihop_module.multihop_enabled is True, "Multihop configuration state should be enabled"
        assert multihop_module.active_exit == 'test-exit', "Active exit should be test-exit"

        # Now reset the state
        result = multihop_module.reset_state()

        assert isinstance(result, dict)

        # Verify reset response structure
        assert 'reset_complete' in result
        assert 'cleanup_successful' in result
        assert 'cleaned_up' in result
        assert 'message' in result

        # Verify reset was successful
        assert result['reset_complete'] is True, "Reset should be complete"
        assert result['cleanup_successful'] is True, "Cleanup should be successful"

        # Verify all components are cleaned
        expected_components = [
            "VPN interfaces (" + VPN_INTERFACE_NAME + ")",
            "Multihop routing rules",
            "Policy routing tables",
            "NAT rules",
            "Multihop configuration state",
            "systemd-networkd routing policies"
        ]
        for component in expected_components:
            assert component in result['cleaned_up'], f"'{component}' should be in cleaned_up list"

        # Verify VPN interface is removed
        interface_check = docker_executor(f'ip link show {VPN_INTERFACE_NAME} 2>&1')
        assert 'does not exist' in interface_check['stdout'].lower() or interface_check['success'] is False, \
            f"VPN interface ({VPN_INTERFACE_NAME}) should be removed after reset"

        # Verify routing rules are cleaned
        rules_check = docker_executor('ip rule list')
        assert 'lookup multihop' not in rules_check['stdout'], "Multihop routing rules should be removed after reset"

        # Verify NAT rules are cleaned
        nat_check_after = docker_executor('iptables -t nat -L POSTROUTING -n')
        # After reset, NAT rules for VPN_INTERFACE_NAME (wg_vpn) should be removed but basic MASQUERADE may remain
        assert VPN_INTERFACE_NAME not in nat_check_after['stdout'], f"NAT rules for {VPN_INTERFACE_NAME} should be removed after reset"

        # Verify multihop state is reset
        assert multihop_module.multihop_enabled is False, "Multihop configuration state should be disabled after reset"
        assert multihop_module.active_exit is None, "Active exit should be None after reset"

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_reset_state"])
    def test_cleanup_verification_and_force_cleanup(self, docker_executor, shared_docker_container, multihop_module):
        """Test cleanup verification mechanism and forced cleanup retry logic."""

        # Step 1: Enable multihop
        enable_result = multihop_module.enable_multihop('test-exit')
        assert enable_result['multihop_enabled'] is True, "Multihop should be enabled"

        # Step 2: Disable multihop (this runs normal cleanup)
        disable_result = multihop_module.disable_multihop()
        assert disable_result['multihop_enabled'] is False, "Multihop should be disabled"

        # Step 3: Inject leftover rules (simulating incomplete cleanup)
        # Now ANY rule with "from {wg_network}" will trigger force cleanup
        docker_executor('ip rule add from 10.8.0.0/24 lookup 999')
        docker_executor('ip rule add from 10.8.0.0/24 table multihop priority 101')
        docker_executor('ip rule add from 10.8.0.0/24 blackhole priority 95')

        # Step 4: Verify rules were actually injected
        rules_before = docker_executor('ip rule show')
        print(rules_before['stdout'])

        assert 'from 10.8.0.0/24' in rules_before['stdout'], "Leftover rules should be injected"
        assert 'lookup 999' in rules_before['stdout'] or 'priority 101' in rules_before['stdout'], \
            "At least one of the injected rules should be present"

        # Step 5: Manually call _verify_rules_cleaned to trigger force cleanup
        wg_config = multihop_module.config.get("wireguard", {})
        wg_network = wg_config.get("network", "10.8.0.0/24")

        # This should detect leftover rules and trigger _force_cleanup_rules
        is_clean = multihop_module.network_admin._verify_rules_cleaned(wg_network)

        # Step 6: Verify force cleanup was triggered (should return False)
        assert is_clean is False, "_verify_rules_cleaned should have detected leftover rules"

        # Step 7: Verify rules are cleaned after force cleanup
        rules_after = docker_executor('ip rule show')
        print(rules_after['stdout'])

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_cleanup_verification_and_force_cleanup"])
    def test_silent_disable_on_handshake_failure(self, docker_executor, shared_docker_container, multihop_module):
        """Test _disable_multihop_silently auto-rollback when VPN handshake fails."""

        exit_ns = "wg-test-exit"

        # First enable multihop successfully to establish baseline
        enable_result = multihop_module.enable_multihop('test-exit')
        assert enable_result['multihop_enabled'] is True

        # Stop exit server to simulate unavailable VPN
        docker_executor(f"ip netns exec {exit_ns} wg-quick down /tmp/wg-exit-server.conf")

        # Verify server is down
        nc_check = docker_executor("nc -zuv -w 1 172.16.100.2 51821 2>&1")
        assert 'succeeded' not in nc_check['stdout'].lower()

        # Attempt enable again with unavailable server (will trigger auto-rollback)
        with pytest.raises(MultihopError):
            multihop_module.enable_multihop('test-exit')

        # Verify auto-rollback cleaned state
        assert multihop_module.multihop_enabled is False
        assert multihop_module.active_exit is None

        # Verify interface removed
        interface_check = docker_executor(f'ip link show {VPN_INTERFACE_NAME} 2>&1')
        assert 'does not exist' in interface_check['stdout'].lower() or interface_check['success'] is False

        # Verify routing rules removed
        rules_check = docker_executor('ip rule show')
        assert 'table multihop' not in rules_check['stdout']

        # Verify NAT rules removed
        nat_check = docker_executor('iptables -t nat -L POSTROUTING -n')
        assert VPN_INTERFACE_NAME not in nat_check['stdout']

        # Restore exit server for subsequent tests
        docker_executor(f"ip netns exec {exit_ns} wg-quick up /tmp/wg-exit-server.conf")

    @pytest.mark.docker
    @pytest.mark.dependency(depends=["TestModuleDocker::test_silent_disable_on_handshake_failure"])
    def test_remove_vpn_config(self, docker_executor, shared_docker_container, multihop_module):
        """Test removing VPN configuration."""
        # Assumes all previous tests ran (config imported, enabled, then disabled)
        result = multihop_module.remove_vpn_config('test-exit')

        # Basic structure check
        assert isinstance(result, dict)

        # Verify required keys
        required_keys = ['removed', 'was_active', 'message']
        for key in required_keys:
            assert key in result, f"Result should contain '{key}'"

        # Verify removal details
        assert result['removed'] == 'test-exit', "Should confirm removed config name"
        assert result['was_active'] is False, "Config should not be active (was disabled in previous test)"

        # Verify success message
        assert 'removed' in result['message'].lower()
        assert 'test-exit' in result['message']

        # Verify config files are actually removed
        config_file_check = docker_executor(f'ls /opt/phantom-wg/exit_configs/test-exit.conf 2>&1')
        assert 'No such file' in config_file_check['stdout'] or config_file_check['success'] is False

        metadata_file_check = docker_executor(f'ls /opt/phantom-wg/exit_configs/test-exit.json 2>&1')
        assert 'No such file' in metadata_file_check['stdout'] or metadata_file_check['success'] is False