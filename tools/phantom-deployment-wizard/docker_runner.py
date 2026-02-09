"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Phantom Deployment Wizard - Docker Orchestration for Development Environment

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
"""

import sys
import logging
import time
import os
import signal
import threading
import json
from textwrap import dedent
from pathlib import Path
from typing import Any, Dict

import docker
from docker.errors import ImageNotFound, BuildError, NotFound

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

# Container name prefixes (PID appended for session isolation)
TOR_CONTAINER_PREFIX = "phantom-tor-router"
APP_CONTAINER_PREFIX = "phantom-deployment-app"

# Image names
TOR_IMAGE = "phantom-tor:latest"
APP_IMAGE = "phantom-deployment:latest"

# Global state for cleanup (with proper type annotations)
_cleanup_state: Dict[str, Any] = {
    'client': None,
    'tor_container': None,
    'app_container': None,
    'session_id': None,
    'shutdown_requested': False
}


def get_project_root():
    """Get the project root directory (phantom-deployment-wizard)"""
    return Path(__file__).parent.absolute()


def print_banner():
    """Display Phantom banner with ASCII art"""
    banner = dedent("""
        ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
        ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
        ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
        ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
        ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
        ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
        Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
    """).strip()

    print(banner)


def log_section(title: str):
    """Log a section header"""
    logger.info(title)


def log_info(message: str, indent: int = 0):
    """Log an info message with optional indentation"""
    prefix = "  " * indent
    logger.info(f"{prefix}{message}")


def log_success(message: str):
    """Log a success message"""
    logger.info(f"✓ {message}")


def log_step(step: str):
    """Log a step in the process"""
    logger.info(f"→ {step}")


def perform_cleanup():
    """Cleanup containers on shutdown"""
    if _cleanup_state['shutdown_requested']:
        return  # Already cleaning up

    _cleanup_state['shutdown_requested'] = True
    log_section("Shutting Down Gracefully")

    client = _cleanup_state['client']
    session_id = _cleanup_state['session_id']

    if client and session_id:
        tor_container_name = f"{TOR_CONTAINER_PREFIX}-{session_id}"
        app_container_name = f"{APP_CONTAINER_PREFIX}-{session_id}"

        # Stop app container first
        try:
            log_step(f"Stopping {app_container_name}")
            container = client.containers.get(app_container_name)
            container.stop(timeout=5)
            container.remove()
            log_success(f"Removed {app_container_name}")
        except NotFound:
            pass
        except Exception as e:
            logger.warning(f"⚠ Error stopping app container: {e}")

        # Stop Tor container
        try:
            log_step(f"Stopping {tor_container_name}")
            container = client.containers.get(tor_container_name)
            container.stop(timeout=5)
            container.remove()
            log_success(f"Removed {tor_container_name}")
        except NotFound:
            pass
        except Exception as e:
            logger.warning(f"⚠ Error stopping Tor container: {e}")

    log_success("Cleanup completed")


def signal_handler(signum, _frame):
    """Handle shutdown signals"""
    signal_name = signal.Signals(signum).name
    logger.info(f"Received {signal_name} signal")
    perform_cleanup()
    sys.exit(0)


def cleanup_containers(client, session_id):
    """Remove existing containers for this session"""
    # Generate session-specific container names
    tor_container_name = f"{TOR_CONTAINER_PREFIX}-{session_id}"
    app_container_name = f"{APP_CONTAINER_PREFIX}-{session_id}"

    for container_name in [tor_container_name, app_container_name]:
        try:
            container = client.containers.get(container_name)
            log_step(f"Cleaning up existing container: {container_name}")
            container.stop()
            container.remove()
            log_success(f"Removed {container_name}")
        except NotFound:
            pass
        except Exception as e:
            logger.warning(f"⚠ Error removing {container_name}: {e}")


def build_app_image(client, show_output=True):
    """Build the Streamlit app Docker image"""
    log_section("Building Streamlit App Image")

    project_root = get_project_root()

    try:
        # Check if image already exists
        try:
            client.images.get(APP_IMAGE)
            log_info(f"Image {APP_IMAGE} already exists", indent=1)
            log_info(f"To rebuild: docker rmi {APP_IMAGE}", indent=1)
            return True
        except ImageNotFound:
            log_step("Building new image")

        # Build with streaming logs
        build_logs = client.api.build(
            path=str(project_root),
            dockerfile="main.Dockerfile",
            tag=APP_IMAGE,
            rm=True,
            forcerm=True,
            decode=True
        )

        # Process build logs
        # noinspection DuplicatedCode
        for log in build_logs:
            if 'stream' in log:
                output = log['stream']
                if show_output and output.strip():
                    logger.info(f"  {output.strip()}")
            elif 'error' in log:
                error_msg = log['error']
                logger.error(f"✗ Build error: {error_msg}")
                raise BuildError(error_msg, build_logs)
            elif 'errorDetail' in log:
                error_detail = log['errorDetail']
                error_msg = error_detail.get('message', str(error_detail))
                logger.error(f"✗ Build error: {error_msg}")
                raise BuildError(error_msg, build_logs)

        log_success(f"Built image: {APP_IMAGE}")
        return True

    except BuildError as e:
        logger.error(f"✗ Failed to build Docker image: {e}")
        return False
    except Exception as e:
        logger.error(f"✗ Unexpected error during build: {e}")
        return False


def build_tor_image(client, show_output=True):
    """Build the Tor Docker image"""
    log_section("Building Tor Router Image")

    project_root = get_project_root()

    try:
        # Check if image already exists
        try:
            client.images.get(TOR_IMAGE)
            log_info(f"Image {TOR_IMAGE} already exists", indent=1)
            log_info(f"To rebuild: docker rmi {TOR_IMAGE}", indent=1)
            return True
        except ImageNotFound:
            log_step("Building new Tor image")

        # Build with streaming logs
        build_logs = client.api.build(
            path=str(project_root),
            dockerfile="tor.Dockerfile",
            tag=TOR_IMAGE,
            rm=True,
            forcerm=True,
            decode=True
        )

        # Process build logs
        # noinspection DuplicatedCode
        for log in build_logs:
            if 'stream' in log:
                output = log['stream']
                if show_output and output.strip():
                    logger.info(f"  {output.strip()}")
            elif 'error' in log:
                error_msg = log['error']
                logger.error(f"✗ Build error: {error_msg}")
                raise BuildError(error_msg, build_logs)
            elif 'errorDetail' in log:
                error_detail = log['errorDetail']
                error_msg = error_detail.get('message', str(error_detail))
                logger.error(f"✗ Build error: {error_msg}")
                raise BuildError(error_msg, build_logs)

        log_success(f"Built image: {TOR_IMAGE}")
        return True

    except BuildError as e:
        logger.error(f"  ✗ Failed to build Tor image: {e}")
        return False
    except Exception as e:
        logger.error(f"  ✗ Unexpected error during Tor build: {e}")
        return False


def wait_for_tor_ready(container, timeout=60):
    """Wait for Tor transparent proxy to be fully configured and connected"""
    log_step("Waiting for Tor transparent proxy setup")

    start_time = time.time()
    iptables_ready = False

    # Phase 1: Wait for iptables rules
    while time.time() - start_time < 30:
        try:
            result = container.exec_run("iptables -t nat -L OUTPUT -n")
            if result.exit_code == 0:
                output = result.output.decode('utf-8')
                if 'REDIRECT' in output and '9040' in output:
                    log_success("iptables transparent proxy configured")
                    iptables_ready = True
                    break
        except Exception as e:
            logger.debug(f"Waiting for iptables: {e}")
        time.sleep(2)

    if not iptables_ready:
        logger.warning("⚠ Timeout waiting for iptables configuration")
        return False

    # Phase 2: Wait for Tor circuit and internet connectivity
    log_step("Waiting for Tor to establish internet connection")

    elapsed = int(time.time() - start_time)
    remaining_timeout = timeout - elapsed

    for attempt in range(remaining_timeout):
        try:
            # Test actual Tor connectivity using check.torproject.org
            result = container.exec_run(
                "curl -s --max-time 5 https://check.torproject.org/api/ip",
                demux=False
            )

            if result.exit_code == 0:
                try:
                    data = json.loads(result.output.decode('utf-8'))
                    if data.get('IsTor'):
                        log_success(f"Tor connection established (Exit IP: {data.get('IP', 'unknown')})")
                        return True
                except (json.JSONDecodeError, ValueError):
                    pass

            # Show progress every 3 seconds
            if attempt % 3 == 0:
                elapsed_total = int(time.time() - start_time)
                logger.info(f"  Waiting for Tor connection... ({elapsed_total}/{timeout}s)")

        except Exception as e:
            logger.debug(f"Tor connectivity check failed: {e}")

        time.sleep(1)

    logger.error("✗ Tor connection timeout - Unable to establish Tor circuit")
    logger.error("  This may be due to:")
    logger.error("  - Network connectivity issues")
    logger.error("  - Tor network being blocked")
    logger.error("  - Firewall restrictions")
    logger.info("  Please restart docker_runner.py to try again")
    return False


def start_tor_container(client, session_id):
    """Start Tor router container with transparent proxy (iptables)

    Requires NET_ADMIN capability for iptables rules that redirect
    all traffic through Tor automatically.
    """
    log_section("Starting Tor Router Container")

    # Generate session-specific container name
    tor_container_name = f"{TOR_CONTAINER_PREFIX}-{session_id}"

    try:
        container = client.containers.run(
            TOR_IMAGE,
            name=tor_container_name,
            cap_add=['NET_ADMIN'],  # Required for iptables transparent proxy
            ports={'8501/tcp': 8501},  # Expose Streamlit port for host access
            detach=True,
            restart_policy={"Name": "unless-stopped"}
        )

        log_success(f"Tor router started (ID: {container.id[:12]})")

        # Wait for transparent proxy to be configured and Tor connection
        if not wait_for_tor_ready(container):
            logger.error("✗ Tor connection could not be established")
            logger.info("  Cleaning up Tor container")
            try:
                container.stop(timeout=5)
                container.remove()
            except (NotFound, docker.errors.APIError):
                # Container already stopped or removed
                pass
            return None, None

        return container, tor_container_name
    except Exception as e:
        logger.error(f"✗ Failed to start Tor container: {e}")
        return None, None


def start_app_container(client, session_id, tor_container_name):
    """Start Streamlit app container using Tor's network namespace"""
    log_section("Starting Streamlit App Container")

    # Generate session-specific container name
    app_container_name = f"{APP_CONTAINER_PREFIX}-{session_id}"
    project_root = get_project_root()

    try:
        container = client.containers.run(
            APP_IMAGE,
            name=app_container_name,
            network_mode=f'container:{tor_container_name}',  # Share Tor's network stack
            environment={
                'TOR_MODE': "1"  # Signal to app that we're using Tor with higher latency,
        },
            volumes={
                str(project_root): {
                    'bind': '/app',
                    'mode': 'rw'
                }
            },
            command=[
                "python", "-m", "streamlit", "run", "wizard/app.py",
                "--server.port=8501",
                "--server.address=0.0.0.0",
                "--server.headless=true"
            ],
            detach=True,
            restart_policy={"Name": "unless-stopped"}
        )

        log_success(f"Streamlit app started (ID: {container.id[:12]})")
        log_info("Using Tor's network namespace", indent=1)
        log_info("All traffic routed through Tor automatically", indent=1)
        return container
    except Exception as e:
        logger.error(f"✗ Failed to start app container: {e}")
        return None


def show_status(client, session_id):
    """Show container status for this session"""
    log_section("Container Status")

    # Generate session-specific container names
    tor_container_name = f"{TOR_CONTAINER_PREFIX}-{session_id}"
    app_container_name = f"{APP_CONTAINER_PREFIX}-{session_id}"

    for container_name in [tor_container_name, app_container_name]:
        try:
            container = client.containers.get(container_name)
            status = container.status
            log_info(f"{container_name}", indent=1)
            log_info(f"Status: {status}", indent=2)
            log_info(f"ID: {container.id[:12]}", indent=2)

            if container_name == app_container_name:
                log_info("URL: http://localhost:8501", indent=2)
        except NotFound:
            log_info(f"{container_name}", indent=1)
            log_info("Status: Not Found", indent=2)


def stream_logs(container, prefix, color_code=""):
    """Stream container logs in real-time with color coding"""
    reset_code = '\033[0m' if color_code else ''
    try:
        for log_line in container.logs(stream=True, follow=True):
            if _cleanup_state['shutdown_requested']:
                break
            try:
                line = log_line.decode('utf-8').rstrip()
                if line:
                    # Format: [PREFIX] message
                    print(f"{color_code}[{prefix:^6}]{reset_code} {line}", flush=True)
            except (UnicodeDecodeError, AttributeError):
                # Ignore malformed log lines
                pass
    except Exception as e:
        if not _cleanup_state['shutdown_requested']:
            logger.debug(f"Log streaming ended for {prefix}: {e}")


def stream_both_logs(tor_container, app_container):
    """Stream logs from both containers simultaneously using threads"""
    # ANSI color codes for better visibility
    tor_color = "\033[36m"  # Cyan for TOR
    app_color = "\033[32m"  # Green for APP

    # Create threads for each container's log stream
    tor_thread = threading.Thread(
        target=stream_logs,
        args=(tor_container, "TOR", tor_color),
        daemon=True
    )
    app_thread = threading.Thread(
        target=stream_logs,
        args=(app_container, "APP", app_color),
        daemon=True
    )

    # Start both threads
    tor_thread.start()
    app_thread.start()

    # Wait for interruption (CTRL+C)
    try:
        while not _cleanup_state['shutdown_requested']:
            time.sleep(0.5)

            # Check if containers are still running
            tor_container.reload()
            app_container.reload()

            if tor_container.status != 'running' or app_container.status != 'running':
                logger.warning("\nOne or more containers stopped")
                break
    except KeyboardInterrupt:
        pass

    # Wait for threads to finish (with timeout)
    tor_thread.join(timeout=2)
    app_thread.join(timeout=2)


def main():
    """Main orchestration function"""
    # Display banner
    print_banner()

    # Register signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        log_section("Initializing")

        # Generate unique session ID for container isolation
        session_id = os.getpid()
        log_info(f"Session ID: {session_id}", indent=1)

        # Initialize Docker client
        client = docker.from_env()
        log_success("Docker client initialized")

        # Store in global state for cleanup
        _cleanup_state['client'] = client
        _cleanup_state['session_id'] = session_id

        # Cleanup existing containers for this session
        cleanup_containers(client, session_id)

        # Build Tor image
        if not build_tor_image(client):
            sys.exit(1)

        # Build app image
        if not build_app_image(client):
            sys.exit(1)

        # Start Tor container (uses default bridge network)
        tor_container, tor_name = start_tor_container(client, session_id)
        if not tor_container:
            sys.exit(1)

        _cleanup_state['tor_container'] = tor_container

        # Start app container (shares Tor's network namespace)
        app_container = start_app_container(client, session_id, tor_name)
        if not app_container:
            tor_container.stop()
            tor_container.remove()
            sys.exit(1)

        _cleanup_state['app_container'] = app_container

        # Show status
        show_status(client, session_id)

        log_section("Deployment Successful")
        log_info("Application URL: http://localhost:8501", indent=1)
        log_info("All traffic routed through Tor", indent=1)
        log_section("Streaming Container Logs (Press CTRL+C to stop)")

        # Stream logs from both containers
        stream_both_logs(tor_container, app_container)

        # If we get here without interrupt, container stopped
        if not _cleanup_state['shutdown_requested']:
            logger.warning("⚠ Container(s) stopped unexpectedly")
            perform_cleanup()

    except docker.errors.DockerException as e:
        logger.error(f"✗ Docker error: {e}")
        perform_cleanup()
        sys.exit(1)
    except KeyboardInterrupt:
        # Signal handler will clean up
        pass
    except Exception as e:
        logger.error(f"✗ Unexpected error: {e}")
        perform_cleanup()
        sys.exit(1)


if __name__ == "__main__":
    main()
