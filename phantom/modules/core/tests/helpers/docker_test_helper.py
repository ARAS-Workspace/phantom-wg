"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ██║   ██║██║╚██╔╝██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Docker Test Helper

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

import time
import sys
import logging
import os
import tempfile
import shutil
from pathlib import Path
from textwrap import dedent
from typing import Dict, Any, Optional

import docker
from docker.errors import ImageNotFound, ContainerError, BuildError, NotFound
from docker.models.containers import Container

# Docker Container Constants
DOCKER_IMAGE_NAME = "phantom-test-core"  # Base name for test container images
DOCKER_BUILD_TAG = "latest"  # Tag for built images (allows version control)
DOCKER_CONTAINER_PREFIX = "phantom-test-core"  # Prefix for container naming (PID appended for uniqueness)
DOCKER_DOCKERFILE_NAME = "Dockerfile"  # Dockerfile name in tests directory

# Configure logging with explicit handler
# Check if we're running under pytest - pytest captures output differently than direct execution
in_pytest = "PYTEST_CURRENT_TEST" in os.environ

# Pytest detection is necessary because pytest intercepts stdout/stderr for test reporting
if in_pytest:
    # Simplified format for pytest test output (levelname only, no timestamps)
    logging.basicConfig(
        level=logging.INFO,
        format='%(levelname)s: %(message)s',  # Minimal format for cleaner test output
        handlers=[
            logging.StreamHandler(sys.stdout)
        ],
        force=True  # Override any existing logging configuration from pytest
    )
else:
    # Full format for standalone execution (includes timestamps and module names)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        handlers=[
            logging.StreamHandler(sys.stdout)
        ]
    )

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


class WireGuardTestContainer:
    """
    Manages a Docker container running WireGuard for integration testing.

    This container provides:
    - Real WireGuard service
    - UFW firewall configuration
    - iptables for NAT and firewall rules
    - Network tools for testing
    """

    def __init__(self, container_name: str = None):
        """Initializes WireGuard test container manager with Docker client.

        Creates temporary directories on host for config file synchronization and sets up
        bidirectional volume mappings between host and container for both WireGuard configs
        (/etc/wireguard) and Phantom installation directory (/opt/phantom-wg).

        Args:
            container_name: Optional custom container name. Defaults to process-specific name.
        """
        self.client = docker.from_env()

        # Use constants defined at module level
        self.container_name = container_name or f"{DOCKER_CONTAINER_PREFIX}-{os.getpid()}"
        self.container: Optional[Container] = None
        self.image_name = f"{DOCKER_IMAGE_NAME}:{DOCKER_BUILD_TAG}"
        self.dockerfile_name = DOCKER_DOCKERFILE_NAME

        # Initialize attributes for directory mappings
        self.host_config_dir: Optional[str] = None  # Host directory for WireGuard config files
        self.host_phantom_dir: Optional[str] = None  # Host directory for Phantom config files
        self.container_config_dir: str = "/etc/wireguard"  # Container path for WireGuard configs
        self.container_phantom_dir: str = "/opt/phantom-wg"  # Container path for Phantom installation

    def build_image(self, show_output: bool = True) -> None:
        """
        Builds the Docker image for WireGuard testing container.

        Args:
            show_output: Whether to display build output in real-time

        Raises:
            BuildError: If Docker image build fails
            ImageNotFound: If base image cannot be found
        """
        dockerfile_path = Path(__file__).parent.parent / self.dockerfile_name

        logger.info(f"Building Docker image from {dockerfile_path}")
        logger.info("=" * 60)

        try:
            # Check if image already exists
            try:
                self.client.images.get(self.image_name)
                logger.info(f"Image {self.image_name} already exists")
                logger.info(f"To rebuild, run: docker rmi {self.image_name}")
                logger.info("=" * 60)
                return
            except ImageNotFound:
                logger.info("Building new image...")

            # Build with streaming logs
            build_logs = self.client.api.build(
                path=str(dockerfile_path.parent),
                dockerfile=dockerfile_path.name,
                tag=self.image_name,
                rm=True,
                forcerm=True,
                decode=True
            )

            # Process and display build logs in real-time
            for log in build_logs:
                if 'stream' in log:
                    output = log['stream']
                    if show_output and output.strip():
                        # Use print for real-time output, logger buffers it
                        print(f"BUILD: {output.strip()}", flush=True)

                # Handle build steps
                elif 'status' in log:
                    status = log.get('status', '')
                    progress = log.get('progress', '')
                    if show_output and status:
                        logger.info(f"BUILD STATUS: {status} {progress}")

                # Handle aux messages (like image ID)
                elif 'aux' in log:
                    if 'ID' in log['aux']:
                        image_id = log['aux']['ID']
                        if show_output:
                            logger.info(f"Image ID: {image_id}")

                # Handle errors
                elif 'error' in log:
                    error_msg = log['error']
                    logger.error(f"BUILD ERROR: {error_msg}")
                    raise BuildError(error_msg, build_logs)

                # Handle error detail
                elif 'errorDetail' in log:
                    error_detail = log['errorDetail']
                    error_msg = error_detail.get('message', str(error_detail))
                    logger.error(f"BUILD ERROR: {error_msg}")
                    raise BuildError(error_msg, build_logs)

            logger.info("=" * 60)
            logger.info(f"Successfully built image: {self.image_name}")

        except BuildError as e:
            logger.error(f"Failed to build Docker image: {e}")
            raise
        except Exception as e:
            logger.error(f"Unexpected error during Docker build: {e}")
            raise

    def start_container(self, show_output: bool = True) -> None:
        """Starts the Docker container with WireGuard and systemd support."""
        # Stop any existing container with same name
        self.stop_container()

        if show_output:
            logger.info(f"Starting container: {self.container_name}")
            logger.info("=" * 60)

        try:
            # Create temp directories for config files on host
            temp_base = os.environ.get('RUNNER_TEMP', None)

            self.host_config_dir = tempfile.mkdtemp(prefix="wg_test_configs_", dir=temp_base)
            self.host_phantom_dir = tempfile.mkdtemp(prefix="phantom_test_", dir=temp_base)

            logger.info(f"Created host config directory: {self.host_config_dir}")
            logger.info(f"Created host phantom directory: {self.host_phantom_dir}")

            # Don't create initial config here - will be generated in container
            # This ensures WireGuard keys are properly generated

            # Define volumes for container
            volumes = {
                # WireGuard config directory mapping (/etc/wireguard)
                self.host_config_dir: {
                    'bind': self.container_config_dir,  # /etc/wireguard
                    'mode': 'rw'
                },
                # Phantom installation directory mapping (/opt/phantom-wg)
                self.host_phantom_dir: {
                    'bind': self.container_phantom_dir,  # /opt/phantom-wg
                    'mode': 'rw'
                },
                # System volumes for container functionality
                '/sys/fs/cgroup': {
                    'bind': '/sys/fs/cgroup',
                    'mode': 'rw'  # Required for systemd
                },
                '/lib/modules': {
                    'bind': '/lib/modules',
                    'mode': 'ro'  # For kernel modules
                }
            }

            # Run container with privileged mode for WireGuard and systemd
            if show_output:
                logger.info("Creating container with privileged mode (systemd enabled)...")

            # Container configuration with systemd support (based on antmelekhin/docker-systemd)
            container_config = {
                'image': self.image_name,
                'name': self.container_name,
                'detach': True,
                'privileged': True,  # Required for WireGuard and systemd
                'cap_add': ["SYS_ADMIN", "NET_ADMIN", "SYS_MODULE"],  # Required capabilities
                'security_opt': ['seccomp=unconfined'],  # For systemd
                'devices': ["/dev/net/tun:/dev/net/tun"],  # TUN device for VPN
                'sysctls': {
                    "net.ipv4.ip_forward": "1",  # Enable IP forwarding
                    "net.ipv6.conf.all.forwarding": "1"
                },
                'volumes': volumes,  # Container volumes
                'ports': {
                    "51820/udp": None  # WireGuard port - random host port
                },
                'environment': {
                    "DEBIAN_FRONTEND": "noninteractive",
                    "PHANTOM_TEST": "1",
                    "container": "docker"  # For systemd detection
                },
                'remove': False,  # Keep container for debugging
                'tmpfs': {  # Tmpfs mounts required for systemd runtime directories
                    '/run': 'rw,noexec,nosuid,size=256m',  # Systemd needs writable /run for service state
                    '/run/lock': 'rw,noexec,nosuid,size=256m'  # Lock files for systemd service coordination
                },
                'cgroupns': 'host'  # Use host cgroup namespace for proper systemd cgroup management
            }

            self.container = self.client.containers.run(**container_config)

            if show_output:
                logger.info(f"Container created: {self.container.short_id}")
                logger.info("Waiting for container to be ready...")

            # Wait for container to be ready
            self._wait_for_container(show_output=show_output)

            if show_output:
                logger.info("Starting WireGuard service...")

            # Start WireGuard service
            self._start_wireguard_service(show_output=show_output)

            # Setup UFW firewall
            self._setup_ufw_firewall(show_output=show_output)

            if show_output:
                logger.info("=" * 60)
                logger.info(f"Container {self.container_name} started successfully")

            logger.info(f"Container {self.container_name} started successfully")

        except ContainerError as e:
            logger.error(f"Container failed to start: {e}")
            raise
        except ImageNotFound:
            logger.error(f"Image {self.image_name} not found. Run build_image() first.")
            raise

    def _wait_for_container(self, timeout: int = 30, show_output: bool = False) -> None:
        """Waits for container to be ready and optionally for systemd initialization.

        Polls container status until it responds to basic commands. If systemd is detected,
        waits additional time for service manager initialization before proceeding.

        Args:
            timeout: Maximum seconds to wait for container readiness
            show_output: Whether to log detailed status information

        Raises:
            RuntimeError: If container exits unexpectedly during startup
            TimeoutError: If container doesn't become ready within timeout period
        """
        start_time = time.time()
        systemd_wait_count = 0  # Counter to ensure systemd initialization completes before proceeding

        while time.time() - start_time < timeout:
            self.container.reload()

            if self.container.status == "running":
                # Check if we can execute basic commands
                result = self.exec_command("echo 'test'")
                if result['success']:
                    # Check if systemd is available (grep pattern ensures we find the actual systemd process, not just any process with 'systemd' in the name)
                    systemd_check = self.exec_command("ps aux | grep -E '^root.*systemd$' | grep -v grep || true")
                    if systemd_check['success'] and 'systemd' in systemd_check['output']:
                        # Systemd detected - increment counter to track initialization time
                        systemd_wait_count += 1
                        if systemd_wait_count >= 3:  # 3 iterations = 3 seconds wait for systemd services to initialize
                            if show_output:
                                logger.info("Container is ready (with systemd)")
                            logger.info("Container status: running, systemd detected")
                            return
                        else:
                            time.sleep(1)  # Sleep 1 second per iteration to give systemd time to start services
                            continue
                    else:
                        # No systemd, but container is ready
                        if show_output:
                            logger.info("Container is ready (without systemd)")
                        logger.info("Container status: running")
                        return

            elif self.container.status == "exited":
                # Container exited, get logs for debugging
                logs = self.get_container_logs(lines=20)
                logger.error(f"Container exited. Last logs:\n{logs}")
                raise RuntimeError(f"Container exited unexpectedly")

            time.sleep(1)

        # Container still not ready, get status info
        self.container.reload()
        logs = self.get_container_logs(lines=20)
        raise TimeoutError(
            f"Container not ready after {timeout} seconds. Status: {self.container.status}. Logs:\n{logs}")

    def _start_wireguard_service(self, show_output: bool = False) -> None:
        """Initializes and starts WireGuard service with full configuration.

        Performs complete WireGuard setup including:
        - Generating cryptographic key pair (private/public keys) using wg genkey
        - Creating wg_main.conf with Interface section and iptables NAT rules
        - Writing configuration line-by-line to handle shell escaping reliably
        - Setting up phantom.json with server keys and network parameters
        - Starting wg-quick@wg_main systemd service
        - Enabling IP forwarding for VPN routing

        The config writing uses line-by-line approach because Docker exec doesn't handle
        multi-line heredocs or quoted strings consistently across different shells.

        Args:
            show_output: Whether to log detailed setup progress
        """
        if show_output:
            logger.info("Starting WireGuard interface wg_main...")

        # First check if interface already exists
        check_result = self.exec_command("ip link show wg_main")
        if check_result['success']:
            logger.info("WireGuard interface wg_main already exists")
            return

        # Ensure /etc/wireguard directory exists
        self.exec_command("mkdir -p /etc/wireguard")

        # Enable IP forwarding (required for NAT)
        self.exec_command("sysctl -w net.ipv4.ip_forward=1")
        self.exec_command("sysctl -w net.ipv6.conf.all.forwarding=1")

        # Generate WireGuard cryptographic keys inside container for security
        # Private key generation using WireGuard's built-in key generator
        private_key_result = self.exec_command("wg genkey")
        if not private_key_result['success']:
            logger.error("Failed to generate WireGuard private key")
            return

        private_key = private_key_result['output'].strip()
        # Use sh -c to properly handle the pipe command
        public_key_result = self.exec_command(f"sh -c \"echo '{private_key}' | wg pubkey\"")
        if not public_key_result['success']:
            logger.error("Failed to generate WireGuard public key")
            return

        public_key = public_key_result['output'].strip()

        # Create proper WireGuard config with generated keys and iptables NAT rules
        # PostUp/PostDown commands configure packet forwarding for VPN clients
        config_content = dedent(f"""
            [Interface]
            PrivateKey = {private_key}
            Address = 10.8.0.1/24
            ListenPort = 51820
            SaveConfig = false
            PostUp = iptables -A FORWARD -i wg_main -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
            PostDown = iptables -D FORWARD -i wg_main -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
        """).strip()
        # PostUp explanation:
        # - iptables -A FORWARD -i wg_main -j ACCEPT: Allow forwarding packets from wg_main interface
        # - iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE: NAT masquerade for outgoing packets (enables internet access for VPN clients)
        # PostDown explanation:
        # - Same rules with -D (delete) instead of -A (append) for cleanup when interface goes down

        # Write config to container line by line (most reliable method)
        # First clear/create the file
        self.exec_command('> /etc/wireguard/wg_main.conf')

        # Write each line individually (avoids shell escaping issues with multi-line heredocs)
        for line in config_content.split('\n'):
            if line.strip():  # Skip empty lines to avoid cluttering config file
                # Printf is preferred over echo for better cross-shell compatibility (handles special chars like -n)
                append_cmd = f'printf "%s\\n" \'{line}\' >> /etc/wireguard/wg_main.conf'
                result = self.exec_command(append_cmd)
                if not result['success']:
                    # Echo fallback for systems where printf might not be available or behaves differently
                    echo_cmd = f"echo '{line}' >> /etc/wireguard/wg_main.conf"
                    self.exec_command(echo_cmd)

        # Set proper permissions
        self.exec_command("chmod 600 /etc/wireguard/wg_main.conf")

        # Also write to host config dir for volume sync
        try:
            host_config_path = Path(self.host_config_dir) / "wg_main.conf"
            host_config_path.write_text(config_content)
            host_config_path.chmod(0o600)
        except Exception as e:
            logger.warning(f"Could not write to host config: {e}")

        # Create phantom.json configuration file with test-specific settings
        phantom_config = {
            "version": "core-v1",  # Config schema version for compatibility checks
            "install_dir": "/opt/phantom-wg",  # Installation directory path
            "wireguard": {  # WireGuard network configuration
                "interface": "wg_main",  # VPN interface name
                "port": 51820,  # UDP listen port for WireGuard
                "network": "10.8.0.0/24"  # VPN subnet for client IP allocation
            },
            "tweaks": {  # Performance and behavior tweaks
                'restart_service_after_client_creation': True  # Auto-restart service after adding clients
            },
            "server": {  # Server cryptographic keys
                "private_key": private_key,  # Server's WireGuard private key
                "public_key": public_key  # Server's WireGuard public key (for client configs)
            },
        }

        # Convert to JSON string with proper formatting
        import json
        phantom_json_content = json.dumps(phantom_config, indent=2)

        # Write phantom.json to container
        self.exec_command('> /opt/phantom-wg/config/phantom.json')

        # Write JSON content line by line (required due to shell interpretation of special chars)
        for line in phantom_json_content.split('\n'):
            # Escape double quotes to prevent shell from interpreting them as string delimiters
            # Escape dollar signs to prevent shell variable expansion (e.g., $var would try to expand)
            escaped_line = line.replace('"', '\\"').replace('$', '\\$')
            write_cmd = f'echo "{escaped_line}" >> /opt/phantom-wg/config/phantom.json'
            self.exec_command(write_cmd)

        # Set proper permissions
        self.exec_command("chmod 644 /opt/phantom-wg/config/phantom.json")

        # Also write to host phantom dir for test access
        try:
            host_phantom_config_path = Path(self.host_phantom_dir) / "config" / "phantom.json"
            host_phantom_config_path.parent.mkdir(parents=True, exist_ok=True)
            host_phantom_config_path.write_text(phantom_json_content)
            host_phantom_config_path.chmod(0o644)
        except Exception as e:
            logger.warning(f"Could not write phantom.json to host: {e}")

        if show_output:
            logger.info(f"Generated WireGuard keys - Public: {public_key[:20]}...")
            logger.info("Created phantom.json configuration file")

        # Verify config was written correctly
        verify_result = self.exec_command("cat /etc/wireguard/wg_main.conf")
        if verify_result['success']:
            logger.debug(f"Config file content:\n{verify_result['output'][:200]}...")

        # Enable and start WireGuard service via systemd
        enable_result = self.exec_command("systemctl enable wg-quick@wg_main")
        if enable_result['success']:
            logger.debug("Enabled wg-quick@wg_main systemd service")

        # Start the service
        result = self.exec_command("systemctl start wg-quick@wg_main")

        if result['exit_code'] == 0:
            logger.info("WireGuard service wg-quick@wg_main started successfully")
            if show_output and result['output']:
                logger.debug(f"WireGuard output: {result['output']}")
        else:
            # Non-zero exit code doesn't always mean failure - interface might already exist
            # Recheck interface existence to distinguish between actual failure and "already exists" case
            recheck = self.exec_command("ip link show wg_main")
            if recheck['success']:
                logger.info("WireGuard interface wg_main is up (already existed)")
            else:
                if result['output']:
                    logger.warning(f"WireGuard service start failed: {result['output']}")
                else:
                    logger.warning(f"WireGuard service start failed with exit code {result['exit_code']}")

        # Wait for interface to fully initialize before proceeding with verification
        # WireGuard needs time to set up network interface and apply PostUp commands
        time.sleep(1)

        # Check if interface exists
        result_check = self.exec_command("ip link show wg_main")
        if result_check['success']:
            logger.info("WireGuard interface wg_main is up and configured")

            if show_output:
                # Show interface details
                result_info = self.exec_command("ip addr show wg_main")
                if result_info['success'] and result_info['output']:
                    lines = result_info['output'].strip().split('\n')
                    for line in lines:
                        if 'inet' in line:
                            logger.info(f"Interface IP: {line.strip()}")

                # Show WireGuard status (might be empty if no peers)
                result_wg = self.exec_command("wg show wg_main")
                if result_wg['output']:
                    logger.debug(f"WireGuard status: {result_wg['output'][:200]}")

                # Verify NAT rules are in place
                nat_check = self.exec_command("iptables -t nat -L POSTROUTING -n")
                if nat_check['success'] and 'MASQUERADE' in nat_check['output']:
                    logger.debug("NAT masquerade rules are active")
        else:
            error_output = result_check.get('output', '') or result_check.get('stderr', '')
            logger.warning(f"WireGuard interface wg_main not found: {error_output}")
            logger.warning("Failed to create WireGuard interface wg_main")

    def _setup_ufw_firewall(self, show_output: bool = False) -> None:
        """Configures UFW firewall rules for WireGuard operation.

        Sets up comprehensive firewall rules:
        - Default deny incoming, allow outgoing, allow routed (critical for VPN forwarding)
        - Port 51820/udp allowed for WireGuard traffic
        - Port 22/tcp allowed for SSH access during testing
        - Route rules for wg_main interface (in/out traffic)

        The 'allow routed' policy is essential for WireGuard to forward packets between
        VPN clients and the internet through the server.

        Args:
            show_output: Whether to log detailed firewall configuration steps

        Note:
            UFW may have limited functionality in Docker containers due to kernel
            restrictions, but configuration is attempted for testing purposes.
        """
        if show_output:
            logger.info("Setting up UFW firewall...")

        # Reset UFW to clean state
        self.exec_command("echo 'y' | ufw --force reset")

        # Set default policies
        self.exec_command("ufw default deny incoming")
        self.exec_command("ufw default allow outgoing")
        self.exec_command("ufw default allow routed")  # Important for WireGuard forwarding

        # Allow WireGuard port
        result = self.exec_command("ufw allow 51820/udp")
        if result['success']:
            logger.debug("UFW: Allowed WireGuard port 51820/udp")

        # Allow SSH (for testing/debugging)
        self.exec_command("ufw allow 22/tcp")

        # Allow forwarding for WireGuard subnet
        self.exec_command("ufw route allow in on wg_main")
        self.exec_command("ufw route allow out on wg_main")

        # Enable UFW (non-interactively)
        enable_result = self.exec_command("ufw --force enable")
        if enable_result['success']:
            logger.info("UFW firewall enabled successfully")
            if show_output:
                # Show UFW status
                status_result = self.exec_command("ufw status verbose")
                if status_result['success'] and status_result['output']:
                    logger.debug(f"UFW Status:\n{status_result['output']}")
        else:
            logger.warning(f"Failed to enable UFW: {enable_result.get('output', '')}")
            # UFW might not work properly in container, but that's OK for testing
            logger.info("Note: UFW may not fully work in container environment, continuing...")

    def exec_command(self, command: str) -> Dict[str, Any]:
        """Executes command inside Docker container and returns standardized result.

        Automatically replaces 'wg0' with 'wg_main' for interface name consistency.
        Uses Docker exec_run with combined stdout/stderr output stream.

        Args:
            command: Shell command to execute in container

        Returns:
            Dictionary with standardized format:
                - exit_code: Command exit code (0 = success, -1 = exception)
                - output: Combined stdout/stderr as decoded UTF-8 string
                - error: Error message if exception occurred (otherwise empty)
                - success: Boolean indicating exit_code == 0
                - stdout: Alias for output (compatibility)
                - stderr: Empty string (combined with stdout in output)

        Raises:
            RuntimeError: If container is not running
        """
        # Auto-replace wg0 with wg_main for consistency
        if "wg0" in command:
            command = command.replace("wg0", "wg_main")
            logger.debug(f"Replaced wg0 with wg_main in command: {command}")

        if not self.container:
            raise RuntimeError("Container is not running")

        try:
            result = self.container.exec_run(
                command,
                stderr=True,
                stdout=True,
                demux=False  # Get combined output
            )

            # result.output is bytes when demux=False
            output = result.output.decode('utf-8') if result.output else ""

            return {
                'exit_code': result.exit_code,
                'output': output,
                'error': '',  # Combined in output
                'success': result.exit_code == 0,
                'stdout': output,  # For compatibility
                'stderr': ''  # Combined in output
            }

        except Exception as e:
            logger.error(f"Failed to execute command '{command}': {e}")
            return {
                'exit_code': -1,
                'output': '',
                'error': str(e),
                'success': False
            }

    def stop_container(self) -> None:
        """Stops and removes Docker container if it exists.

        Attempts graceful shutdown with 10-second timeout before forced removal.
        Silently succeeds if container doesn't exist (NotFound exception).
        """
        try:
            # Try to get existing container
            existing = self.client.containers.get(self.container_name)
            logger.info(f"Stopping existing container: {self.container_name}")
            existing.stop(timeout=10)
            existing.remove(force=True)
            logger.info(f"Removed container: {self.container_name}")
        except NotFound:
            pass  # Container doesn't exist
        except Exception as e:
            logger.warning(f"Error stopping container: {e}")

    def get_container_logs(self, lines: int = 50) -> str:
        """Retrieves recent container logs with timestamps.

        Args:
            lines: Number of recent log lines to retrieve (default: 50)

        Returns:
            Decoded UTF-8 log output, or empty string if container not running or error occurs
        """
        if not self.container:
            return ""

        try:
            logs = self.container.logs(tail=lines, timestamps=True)
            return logs.decode('utf-8')
        except Exception as e:
            logger.error(f"Failed to get container logs: {e}")
            return ""

    def sync_config(self) -> bool:
        """Applies WireGuard configuration changes without full service restart.

        Attempts hot-reload using `wg syncconf` first (preserves existing connections).
        Falls back to full restart (`wg-quick down/up`) if syncconf fails.

        Returns:
            True if configuration was successfully applied, False otherwise

        Raises:
            RuntimeError: If container is not running

        Note:
            syncconf is preferred because it doesn't disrupt existing VPN connections,
            but may fail if configuration changes are incompatible with hot-reload.
        """
        if not self.container:
            raise RuntimeError("Container is not running")

        # Use wg syncconf to apply config changes without restart
        result = self.exec_command(f"wg syncconf wg_main {self.container_config_dir}/wg_main.conf")

        if result['success']:
            logger.info("WireGuard config synced successfully using syncconf")
            return True
        else:
            logger.warning(f"Config sync failed: {result['output']}")
            # Fallback to restart
            logger.info("Falling back to wg-quick restart")
            self.exec_command("wg-quick down wg_main")  # No need to store result
            up_result = self.exec_command("wg-quick up wg_main")
            return up_result['success']

    def cleanup(self) -> None:
        """Performs complete cleanup of container and host resources.

        Stops container and removes all temporary directories created during testing.
        Cleans up both WireGuard config directory and Phantom installation directory
        from host filesystem.
        """
        self.stop_container()

        # Clean up host config directory
        if self.host_config_dir and os.path.exists(self.host_config_dir):
            try:
                shutil.rmtree(self.host_config_dir)
                logger.info(f"Removed host config directory: {self.host_config_dir}")
            except Exception as e:
                logger.error(f"Error cleaning up config directory: {e}")

        # Clean up host phantom directory
        if self.host_phantom_dir and os.path.exists(self.host_phantom_dir):
            try:
                shutil.rmtree(self.host_phantom_dir)
                logger.info(f"Removed host phantom directory: {self.host_phantom_dir}")
            except Exception as e:
                logger.error(f"Error cleaning up phantom directory: {e}")

    def __enter__(self):
        """Context manager entry: builds image and starts container.

        Returns:
            Self for use in 'with' statement
        """
        self.build_image()
        self.start_container()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit: performs cleanup regardless of exceptions."""
        self.cleanup()


class DockerCommandExecutor:
    """
    Command executor that runs commands in Docker container.
    Implements the same interface as the regular run_command.
    """

    def __init__(self, container: WireGuardTestContainer):
        """Initializes executor with WireGuard test container reference.

        Args:
            container: WireGuardTestContainer instance to execute commands in
        """
        self.container = container

    def __call__(self, cmd) -> Dict[str, Any]:
        """Executes command in container (callable interface).

        Accepts both string and list command formats, converting lists to
        space-separated strings. Provides compatibility layer between Docker
        exec format and standard run_command interface.

        Args:
            cmd: Command as string or list of arguments

        Returns:
            Dictionary in run_command format:
                - success: Boolean indicating command success
                - stdout: Command output
                - stderr: Error output
                - returncode: Always 0 (for compatibility)
        """
        # Convert list command to string
        if isinstance(cmd, list):
            command_str = ' '.join(cmd)
        else:
            command_str = str(cmd)  # Ensure it's a string

        # Execute in container
        result = self.container.exec_command(command_str)

        # Convert to run_command format
        return {
            'success': result['success'],
            'stdout': result['output'],
            'stderr': result['error'],
            'returncode': 0
        }

    def run_command(self, cmd):
        """Executes command in container (method interface).

        Wrapper around __call__ for explicit method-style invocation.

        Args:
            cmd: Command as string or list of arguments

        Returns:
            Same as __call__: dictionary with success, stdout, stderr, returncode
        """
        return self.__call__(cmd)


def create_test_environment_with_docker():
    """
    Creates and initializes a complete Docker-based WireGuard test environment.

    Returns:
        Dict containing:
            - container: WireGuardTestContainer instance
            - run_command: DockerCommandExecutor for running commands
            - wg_interface: WireGuard interface name ('wg_main')
            - wg_port: WireGuard listen port (51820)
            - host_config_dir: Host directory with WireGuard configs
    """
    container = WireGuardTestContainer()
    container.build_image()
    container.start_container()

    executor = DockerCommandExecutor(container)

    return {
        'container': container,
        'run_command': executor,
        'wg_interface': 'wg_main',
        'wg_port': 51820,
        'host_config_dir': container.host_config_dir
    }
