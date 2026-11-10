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

Multihop E2E test runner -- host-side orchestration via compose-bridge.

Starts the full topology (daemon, gateway, master, exit-server, client),
runs pytest inside the master container, then tears down.

Usage:
    ./tools/dev.sh test-multihop-e2e
    ./tools/dev.sh test-multihop-e2e --no-cleanup
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import time
from pathlib import Path

RUNNER_DIR = Path(__file__).parent
E2E_DIR = RUNNER_DIR.parent
REPO_ROOT = E2E_DIR.parent
sys.path.insert(0, str(REPO_ROOT))

from e2e_tests.environment import LOG_FMT, E2ETestEnvironment, step

logging.basicConfig(
    level=logging.INFO, format=LOG_FMT,
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("e2e.multihop")

COMPOSE_PATH = str(RUNNER_DIR / "docker-compose.yml")
BOOTSTRAP_SCRIPT = RUNNER_DIR / "helpers" / "bootstrap.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Multihop E2E test runner")
    parser.add_argument(
        "--no-cleanup", action="store_true",
        help="Keep containers after tests (for debugging)",
    )
    parser.add_argument(
        "pytest_args", nargs="*",
        help="Extra arguments passed to pytest",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    start_time = time.time()
    rc = 1

    env = E2ETestEnvironment("mg", compose_path=COMPOSE_PATH)

    try:
        # Fresh secrets every run
        step("Bootstrapping WireGuard keys")
        subprocess.run(
            ["bash", str(BOOTSTRAP_SCRIPT)],
            cwd=str(REPO_ROOT),
            check=True,
        )

        env.up()

        # Wait for services to be ready
        env.wait_for_log("daemon", "Application startup complete", timeout=60)
        env.wait_for_log("exit-server", "EXIT_READY", timeout=30)
        env.wait_for_ready("master", timeout=30)

        # Run pytest inside master (streaming via subprocess)
        step("Running tests in master")
        pytest_cmd = [
            "python", "-m", "pytest",
            "e2e_tests/multihop/tests/",
            "-v", "-s",
        ]
        if args.pytest_args:
            pytest_cmd.extend(args.pytest_args)

        docker_cmd = [
            "docker", "compose",
            "-f", COMPOSE_PATH,
            "-p", env.project_name,
            "exec",
            "-e", f"COMPOSE_PROJECT_NAME={env.project_name}",
            "-T", "master",
            *pytest_cmd,
        ]

        proc = subprocess.Popen(
            docker_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        for raw in proc.stdout:
            line = raw.decode("utf-8", errors="replace").rstrip("\n")
            sys.stdout.write(f"  TEST | {line}\n")
            sys.stdout.flush()
        rc = proc.wait()

    except Exception:
        log.exception("E2E FAILED")
        rc = 1

    finally:
        duration = time.time() - start_time
        status = "PASSED" if rc == 0 else "FAILED"
        step(f"RESULT: {status} ({duration:.1f}s)")

        if not args.no_cleanup:
            env.close()
        else:
            log.info("Skipping cleanup (--no-cleanup)")

    sys.exit(rc)


if __name__ == "__main__":
    main()
