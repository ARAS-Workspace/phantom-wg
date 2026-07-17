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

Fixtures for chaos E2E tests.

Runs INSIDE the master container. Provides:
- Docker client for exec into service containers
- Gateway URL for daemon API access
- Container interaction helpers
- restart_daemon: graceful restart (SIGTERM) and wait for ready
- kill_daemon: SIGKILL (ungraceful) + restart and wait for ready
- sigkill_daemon: raw SIGKILL only (no restart, no wait)
- start_daemon: start stopped daemon + gateway, wait for ready
- wait_for_api: poll gateway until daemon API responds
"""

from __future__ import annotations

import base64
import os
import time

import docker
import pytest
import requests


@pytest.fixture(scope="session")
def docker_client():
    """Docker client via mounted socket."""
    client = docker.from_env()
    yield client
    client.close()


@pytest.fixture(scope="session")
def gateway_url() -> str:
    """Daemon API base URL via gateway service."""
    return os.environ.get("GATEWAY_URL", "http://gateway:9080")


@pytest.fixture(scope="session")
def project_name() -> str:
    """Compose project name (set by runner)."""
    return os.environ["COMPOSE_PROJECT_NAME"]


def _find_container(
    client: docker.DockerClient,
    project: str,
    service: str,
    include_stopped: bool = False,
):
    """Find a container by compose project + service label.

    By default only running containers are returned. Set include_stopped=True
    to also find exited containers (needed after SIGKILL).
    """
    containers = client.containers.list(
        all=include_stopped,
        filters={
            "label": [
                f"com.docker.compose.project={project}",
                f"com.docker.compose.service={service}",
            ],
        },
    )
    if not containers:
        raise RuntimeError(f"Container not found: {service} (project={project})")
    return containers[0]


@pytest.fixture(scope="session")
def container_exec(docker_client, project_name):
    """Factory fixture: execute command in a compose service container."""

    def _exec(
        service: str,
        cmd: str | list[str],
        check: bool = True,
        environment: dict[str, str] | None = None,
    ) -> tuple[int, str]:
        container = _find_container(docker_client, project_name, service)
        if isinstance(cmd, list):
            cmd = ["sh", "-c", " ".join(cmd)] if len(cmd) > 1 else cmd
        else:
            cmd = ["sh", "-c", cmd]
        exit_code, output = container.exec_run(
            cmd, environment=environment, demux=True,
        )
        stdout = (output[0] or b"").decode("utf-8", errors="replace")
        stderr = (output[1] or b"").decode("utf-8", errors="replace")
        if check and exit_code != 0:
            raise RuntimeError(
                f"exec in {service} failed (rc={exit_code}): {cmd}\n"
                f"stdout: {stdout}\nstderr: {stderr}"
            )
        return exit_code, stdout

    return _exec


@pytest.fixture(scope="session")
def container_write_file(container_exec):
    """Factory fixture: write file into a compose service container."""

    def _write(service: str, path: str, content: str) -> None:
        encoded = base64.b64encode(content.encode()).decode()
        container_exec(service, f"echo '{encoded}' | base64 -d > {path}")

    return _write


@pytest.fixture(scope="session")
def container_ip(docker_client, project_name):
    """Factory fixture: get container IP on compose default network."""

    def _ip(service: str) -> str:
        container = _find_container(docker_client, project_name, service)
        container.reload()
        networks = container.attrs["NetworkSettings"]["Networks"]
        for net_info in networks.values():
            ip = net_info.get("IPAddress")
            if ip:
                return ip
        raise RuntimeError(f"No IP found for {service}")

    return _ip


@pytest.fixture(scope="session")
def restart_daemon(docker_client, project_name, gateway_url):
    """Factory fixture: restart daemon container and wait for API ready.

    Uses docker restart (SIGTERM → SIGKILL after timeout).
    Waits for gateway to respond with 200 on /api/core/firewall/groups/list.
    Returns the time (seconds) it took for the daemon to become ready.
    """

    def _restart(timeout: int = 60) -> float:
        daemon = _find_container(docker_client, project_name, "daemon")
        gateway = _find_container(docker_client, project_name, "gateway")
        t0 = time.monotonic()

        # Restart daemon — SIGTERM then SIGKILL after 10s
        daemon.restart(timeout=10)

        # Gateway (socat) holds stale UDS handle — must restart too
        gateway.restart(timeout=5)

        # Poll gateway until daemon API responds
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                resp = requests.get(
                    f"{gateway_url}/api/core/firewall/groups/list",
                    timeout=2,
                )
                if resp.status_code == 200:
                    return time.monotonic() - t0
            except (requests.ConnectionError, requests.Timeout):
                pass
            time.sleep(1)
        raise TimeoutError(f"Daemon not ready after {timeout}s restart")

    return _restart


@pytest.fixture(scope="session")
def kill_daemon(docker_client, project_name, gateway_url):
    """Factory fixture: SIGKILL daemon and wait for API ready.

    Unlike restart_daemon (SIGTERM → graceful shutdown), this sends
    SIGKILL which terminates the process immediately:
    - Lifespan shutdown handlers do NOT run
    - UDS socket is NOT cleaned up
    - SQLite WAL/journal may be mid-write

    Returns the time (seconds) it took for the daemon to recover.
    """

    def _kill(timeout: int = 60) -> float:
        daemon = _find_container(docker_client, project_name, "daemon")
        gateway = _find_container(docker_client, project_name, "gateway")
        t0 = time.monotonic()

        daemon.kill(signal="SIGKILL")
        time.sleep(0.5)
        daemon.start()

        # Gateway (socat) holds stale UDS handle — must restart too
        gateway.restart(timeout=5)

        # Poll gateway until daemon API responds
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                resp = requests.get(
                    f"{gateway_url}/api/core/firewall/groups/list",
                    timeout=2,
                )
                if resp.status_code == 200:
                    return time.monotonic() - t0
            except (requests.ConnectionError, requests.Timeout):
                pass
            time.sleep(1)
        raise TimeoutError(f"Daemon not ready after {timeout}s SIGKILL recovery")

    return _kill


@pytest.fixture(scope="session")
def sigkill_daemon(docker_client, project_name):
    """Factory fixture: send SIGKILL to daemon without restarting.

    Use with start_daemon for fine-grained control (e.g. mid-flight kill).
    """

    def _kill() -> None:
        daemon = _find_container(docker_client, project_name, "daemon")
        daemon.kill(signal="SIGKILL")

    return _kill


@pytest.fixture(scope="session")
def start_daemon(docker_client, project_name, gateway_url):
    """Factory fixture: start a stopped daemon + gateway, wait for API ready.

    Returns the time (seconds) it took for the daemon to become ready.
    """

    def _start(timeout: int = 90) -> float:
        daemon = _find_container(docker_client, project_name, "daemon", include_stopped=True)
        gateway = _find_container(docker_client, project_name, "gateway", include_stopped=True)
        t0 = time.monotonic()

        daemon.start()
        gateway.restart(timeout=5)

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                resp = requests.get(
                    f"{gateway_url}/api/core/firewall/groups/list",
                    timeout=2,
                )
                if resp.status_code == 200:
                    return time.monotonic() - t0
            except (requests.ConnectionError, requests.Timeout):
                pass
            time.sleep(1)
        raise TimeoutError(f"Daemon not ready after {timeout}s start")

    return _start


@pytest.fixture(scope="session")
def wait_for_api(gateway_url):
    """Factory fixture: poll daemon API until it responds."""

    def _wait(path: str = "/api/core/firewall/groups/list", timeout: int = 60) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                resp = requests.get(f"{gateway_url}{path}", timeout=2)
                if resp.status_code == 200:
                    return
            except (requests.ConnectionError, requests.Timeout):
                pass
            time.sleep(1)
        raise TimeoutError(f"API not ready after {timeout}s at {path}")

    return _wait


# ── API client + exit config (shared across scenarios) ───────────

@pytest.fixture(scope="module")
def api(gateway_url):
    """Thin API client that logs each call via helpers._api."""
    from .helpers import _api

    class _Api:
        def __init__(self, base: str):
            self.base = base

        def get(self, path: str, **kwargs) -> requests.Response:
            resp = requests.get(f"{self.base}{path}", timeout=10, **kwargs)
            _api("GET", path, resp)
            return resp

        def post(self, path: str, body: dict | None = None, **kwargs) -> requests.Response:
            if body is not None:
                kwargs["json"] = body
            resp = requests.post(f"{self.base}{path}", timeout=10, **kwargs)
            _api("POST", path, resp)
            return resp

    return _Api(gateway_url)


@pytest.fixture(scope="module")
def exit_conf(container_exec, container_ip):
    """The exit server's client config, with the endpoint filled in.

    The chaos exit is dual-stack, so this one config carries both
    families and a single import applies both multihop presets.
    """
    for _ in range(30):
        rc, out = container_exec("exit-server", "cat /config/client.conf", check=False)
        if rc == 0 and "PublicKey" in out:
            break
        time.sleep(1)
    else:
        pytest.fail("exit-server config not ready after 30s")

    exit_ip = container_ip("exit-server")
    _, conf = container_exec("exit-server", "cat /config/client.conf")
    return conf.replace("__EXIT_SERVER_IP__", exit_ip)
