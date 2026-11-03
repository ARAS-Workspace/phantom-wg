#!/usr/bin/env python3
"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Test runner for wireguard-go-bridge.

Three containers:
    bridge-test  — Go .so + Python code, runs pytest (Docker socket mounted)
    exit-server  — WireGuard server, provides client config (external VPN provider)
    client       — Plain WireGuard client (wg-quick), controlled from bridge via Docker SDK

Docker SDK manages all containers + shared network.
Code synced dynamically into bridge container at runtime.

Usage:
    python test_runner.py
"""

import io
import logging
import sys
import tarfile
import time
from datetime import datetime
from pathlib import Path

LOG_FMT = "%(asctime)s [%(levelname)s] %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FMT, handlers=[logging.StreamHandler(sys.stdout)])
log = logging.getLogger("test_runner")

ROOT = Path(__file__).parent
BRIDGE_IMAGE = "wireguard-go-bridge-test"
EXIT_IMAGE = "wireguard-go-bridge-exit"
CLIENT_IMAGE = "wireguard-go-bridge-client"
NETWORK_NAME = "wg-bridge-test-net"
BRIDGE_NAME = "wg-bridge-test"
EXIT_NAME = "wg-exit-server"
CLIENT_NAME = "wg-client"


def step(msg: str):
    log.info("=" * 60)
    log.info("STEP: %s", msg)
    log.info("=" * 60)


# ============================================================================
# Docker helpers
# ============================================================================

def get_docker_client():
    try:
        from docker import from_env
        from docker.errors import DockerException
    except ImportError:
        log.error("Docker SDK not installed: pip install docker")
        return None
    try:
        client = from_env()
        client.ping()
        return client
    except DockerException as e:
        log.error("Docker not available: %s", e)
        return None


def build_image(client, dockerfile: str, tag: str) -> bool:
    """Builds tag from dockerfile on every run; Docker's layer cache keeps
    the steps whose inputs are unchanged."""
    log.info("  Building: %s (dockerfile=%s)", tag, dockerfile)
    try:
        for line in client.api.build(
            path=str(ROOT), dockerfile=dockerfile,
            tag=tag, rm=True, forcerm=True, decode=True,
        ):
            if "stream" in line:
                text = line["stream"].strip()
                if text:
                    log.info("    BUILD | %s", text)
            elif "error" in line:
                log.error("    BUILD ERROR | %s", line["error"])
                return False
        return True
    except Exception as e:
        log.error("  Build failed: %s", e)
        return False


def ensure_network(client) -> str:
    from docker.errors import NotFound
    try:
        net = client.networks.get(NETWORK_NAME)
        return net.id
    except NotFound:
        net = client.networks.create(NETWORK_NAME, driver="bridge")
        log.info("  Network created: %s", NETWORK_NAME)
        return net.id


def remove_container(client, name: str):
    from docker.errors import NotFound, APIError
    try:
        c = client.containers.get(name)
        c.stop(timeout=3)
        c.remove(force=True)
    except (NotFound, APIError):
        pass


def get_container_ip(container, network_name: str) -> str:
    container.reload()
    networks = container.attrs["NetworkSettings"]["Networks"]
    return networks[network_name]["IPAddress"]


def _make_tar(src: Path) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(str(src), arcname=src.name)
    return buf.getvalue()


def sync_code(container):
    step("Syncing code into bridge container")
    targets = [
        ("wireguard_go_bridge", "/workspace"),
        ("tests", "/workspace"),
        ("pytest.ini", "/workspace"),
    ]
    for src_name, dest_dir in targets:
        src = ROOT / src_name
        if not src.exists():
            continue
        container.exec_run(["rm", "-rf", f"{dest_dir}/{src_name}"])
        container.put_archive(dest_dir, _make_tar(src))
        log.info("  %s → %s/%s", src_name, dest_dir, src_name)


def exec_stream(container, cmd: str) -> tuple[int, str]:
    exec_id = container.client.api.exec_create(container.id, ["sh", "-c", cmd])
    stream = container.client.api.exec_start(exec_id, stream=True)
    lines = []
    for chunk in stream:
        text = chunk.decode("utf-8", errors="replace")
        for line in text.splitlines():
            lines.append(line)
            if line.strip():
                log.info("  TEST | %s", line)
    inspect = container.client.api.exec_inspect(exec_id)
    return inspect.get("ExitCode", -1), "\n".join(lines)


def copy_from_container(container, src: str, dest: Path) -> bool:
    from docker.errors import NotFound, APIError
    try:
        bits, _ = container.get_archive(src)
        tar_bytes = b"".join(bits)
        tf = tarfile.open(fileobj=io.BytesIO(tar_bytes))
        tf.extractall(path=str(dest))
        tf.close()
        return True
    except (NotFound, APIError, OSError):
        return False


# ============================================================================
# Exit server
# ============================================================================

def start_exit_server(client) -> tuple:
    """Start exit server, wait for ready, return (container, client_conf)."""
    step("Starting exit server")

    remove_container(client, EXIT_NAME)
    container = client.containers.run(
        image=EXIT_IMAGE, name=EXIT_NAME, detach=True, privileged=True,
        cap_add=["NET_ADMIN"],
        network=NETWORK_NAME,
        remove=False,
    )

    # Wait for EXIT_READY
    for _ in range(30):
        container.reload()
        if container.status != "running":
            logs = container.logs().decode()
            raise RuntimeError(f"Exit server died: {logs}")
        logs = container.logs().decode()
        if "EXIT_READY" in logs:
            break
        time.sleep(1)
    else:
        raise TimeoutError("Exit server not ready")

    exit_ip = get_container_ip(container, NETWORK_NAME)
    log.info("  Exit server IP: %s", exit_ip)

    # Read client config
    r = container.exec_run(["cat", "/config/client.conf"])
    client_conf = r.output.decode()
    # Replace placeholder with actual IP
    client_conf = client_conf.replace("__EXIT_SERVER_IP__", exit_ip)
    log.info("  Client config received (%d bytes)", len(client_conf))

    return container, client_conf


# ============================================================================
# Client container
# ============================================================================

def start_client(client):
    """Start client container — plain WireGuard, connects via bridge config."""
    step("Starting client container")
    remove_container(client, CLIENT_NAME)

    container = client.containers.run(
        image=CLIENT_IMAGE, name=CLIENT_NAME, detach=True, privileged=True,
        cap_add=["NET_ADMIN"],
        devices=["/dev/net/tun:/dev/net/tun"],
        network=NETWORK_NAME,
        remove=False,
    )

    for _ in range(30):
        container.reload()
        if container.status == "running":
            r = container.exec_run(["echo", "ready"])
            if r.exit_code == 0:
                log.info("  Client container ready")
                return container
        time.sleep(1)
    raise TimeoutError("Client container not ready")


# ============================================================================
# Bridge container
# ============================================================================

def start_bridge(client, env: dict = None):
    step("Starting bridge container")
    remove_container(client, BRIDGE_NAME)

    environment = {
        "WIREGUARD_GO_BRIDGE_LIB_PATH": "/workspace/wireguard_go_bridge.so",
        "PYTHONPATH": "/workspace",
    }
    if env:
        environment.update(env)

    container = client.containers.run(
        image=BRIDGE_IMAGE, name=BRIDGE_NAME, detach=True, privileged=True,
        cap_add=["NET_ADMIN", "SYS_ADMIN"],
        devices=["/dev/net/tun:/dev/net/tun"],
        volumes={"/var/run/docker.sock": {"bind": "/var/run/docker.sock", "mode": "rw"}},
        sysctls={"net.ipv4.ip_forward": "1"},
        network=NETWORK_NAME,
        environment=environment,
        remove=False,
    )

    for _ in range(30):
        container.reload()
        if container.status == "running":
            r = container.exec_run(["echo", "ready"])
            if r.exit_code == 0:
                log.info("  Bridge container ready")
                return container
        time.sleep(1)
    raise TimeoutError("Bridge container not ready")


# ============================================================================
# Test execution
# ============================================================================

def run_tests(bridge, results_dir: Path) -> bool:
    step("Running tests: unit + integration")

    cmd = (
        "cd /workspace && python3 -m pytest "
        "tests/unit/ tests/integration/ --docker "
        "-v --tb=short "
        "--cov=wireguard_go_bridge --cov-report=term-missing "
        "--cov-report=html:/workspace/coverage_html "
        "2>&1"
    )

    exit_code, output = exec_stream(bridge, cmd)
    (results_dir / "tests.log").write_text(output)

    step("Collecting coverage")
    if copy_from_container(bridge, "/workspace/coverage_html", results_dir):
        log.info("  Coverage → %s", results_dir / "coverage_html")

    return exit_code == 0


# ============================================================================
# Main
# ============================================================================

def main():
    start_time = time.time()
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    results_dir = ROOT / "test_results" / timestamp
    results_dir.mkdir(parents=True, exist_ok=True)

    client = get_docker_client()
    if client is None:
        sys.exit(1)

    # Build images
    step("Building images")
    if not build_image(client, "tests/Dockerfile", BRIDGE_IMAGE):
        sys.exit(1)
    if not build_image(client, "tests/exit-server.Dockerfile", EXIT_IMAGE):
        sys.exit(1)
    if not build_image(client, "tests/client.Dockerfile", CLIENT_IMAGE):
        sys.exit(1)

    # Network + containers
    ensure_network(client)
    exit_container, client_conf = start_exit_server(client)
    client_container = start_client(client)
    client_ip = get_container_ip(client_container, NETWORK_NAME)
    log.info("  Client container IP: %s", client_ip)

    env = {
        "EXIT_SERVER_CONFIGURATION": client_conf,
        "CLIENT_CONTAINER_IP": client_ip,
    }
    bridge = start_bridge(client, env)
    passed = False

    try:
        sync_code(bridge)
        passed = run_tests(bridge, results_dir)
    finally:
        remove_container(client, BRIDGE_NAME)
        remove_container(client, EXIT_NAME)
        remove_container(client, CLIENT_NAME)
        from docker.errors import NotFound, APIError
        try:
            client.networks.get(NETWORK_NAME).remove()
        except (NotFound, APIError):
            pass
        log.info("Cleanup complete — all containers + network destroyed")

    duration = time.time() - start_time
    status = "PASSED" if passed else "FAILED"
    step(f"OVERALL: {status} ({duration:.1f}s)")

    summary = [
        "wireguard-go-bridge — Test Results",
        "=" * 50,
        f"Timestamp: {datetime.now().isoformat()}",
        f"Duration:  {duration:.1f}s",
        f"Result:    {status}",
        f"Log:      {results_dir / 'tests.log'}",
    ]
    (results_dir / "summary.txt").write_text("\n".join(summary) + "\n")
    for line in summary:
        log.info("  %s", line)

    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()