"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Riza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard is a registered trademark of Jason A. Donenfeld.

E2E test environment -- host-side orchestration via compose-bridge.

Handles compose lifecycle (build, up, down) and exec into services.
Test logic runs inside the master container; this class only drives
the topology from the host.
"""

from __future__ import annotations

import logging
import subprocess
import time
from pathlib import Path
from types import TracebackType
from typing import Self

from lib.compose_bridge import ComposeBridge, ExecResult

LOG_FMT = "%(asctime)s [%(levelname)s] %(message)s"
log = logging.getLogger("e2e")


def step(msg: str) -> None:
    log.info("=" * 60)
    log.info("STEP: %s", msg)
    log.info("=" * 60)


class E2ETestEnvironment:
    """Host-side E2E test environment backed by compose-bridge."""

    __slots__ = ("_bridge", "_compose_path", "_started", "name")

    def __init__(self, name: str, compose_path: str) -> None:
        self._compose_path = str(Path(compose_path).resolve())
        self._bridge = ComposeBridge(self._compose_path, project_name=name)
        self.name = name
        self._started = False

    @property
    def project_name(self) -> str:
        """Compose project name assigned by the bridge."""
        return self._bridge.project_name

    # -- lifecycle --

    def build(self) -> None:
        """Build images via docker compose (bridge has no build API)."""
        log.info("  Building images...")
        subprocess.run(
            ["docker", "compose", "-f", self._compose_path,
             "-p", self._bridge.project_name, "build"],
            check=True,
        )

    def up(self) -> None:
        """Build images and start all services."""
        step("Starting E2E topology")
        self.build()
        self._bridge.up()
        self._started = True
        log.info("  All services started (project=%s)", self.name)

    def down(self) -> None:
        """Stop and remove all services."""
        if self._started:
            self._bridge.down()
            self._started = False
            log.info("  All services stopped")

    def remove_images(self) -> None:
        """Remove the images built for this project (bridge has no image API)."""
        log.info("  Removing images...")
        done = subprocess.run(
            ["docker", "compose", "-f", self._compose_path,
             "-p", self._bridge.project_name, "down", "--rmi", "local"],
            check=False,
        )
        if done.returncode != 0:
            log.warning("  Image removal exited %d", done.returncode)

    def close(self) -> None:
        """Release bridge resources and the images of the project."""
        self.down()
        self.remove_images()
        self._bridge.close()

    # -- exec --

    def service_exec(
        self,
        service: str,
        cmd: list[str] | str,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> ExecResult:
        """Execute command in a service container."""
        result = self._bridge.exec(service, cmd, env=env)
        if check and result.exit_code != 0:
            raise RuntimeError(
                f"exec in {service} failed (rc={result.exit_code}): {cmd}\n"
                f"stdout: {result.stdout}\nstderr: {result.stderr}"
            )
        return result

    # -- wait helpers --

    def wait_for_log(self, service: str, marker: str, timeout: int = 60) -> None:
        """Wait until marker string appears in service logs."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            logs = self._bridge.logs(service)
            if marker in logs:
                log.info("  %s ready (%s found)", service, marker)
                return
            time.sleep(1)
        raise TimeoutError(f"Timeout waiting for '{marker}' in {service}")

    def wait_for_ready(self, service: str, timeout: int = 30) -> None:
        """Wait until service container is responsive."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                result = self._bridge.exec(service, ["echo", "ready"])
                if result.exit_code == 0:
                    log.info("  %s ready", service)
                    return
            except (RuntimeError, OSError):
                pass
            time.sleep(1)
        raise TimeoutError(f"Timeout waiting for {service}")

    # -- context manager --

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> None:
        self.close()
