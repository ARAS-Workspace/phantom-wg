#!/usr/bin/env python3
"""
Firewall Bridge E2E test runner — host-side orchestration via compose-bridge.

Starts the full topology (bridge, exit-server, client, rules-caps), runs
pytest in three stages, then tears down:

    topology    bridge      e2e_tests/tests/  tunnels, presets, crash recovery, traffic
    rules       bridge      e2e_tests/rules/  the bridge's rules against nft and the database
    rules-caps  rules-caps  e2e_tests/rules/  the same, with the daemon's capabilities

Usage:
    python e2e_tests/runner.py
    python e2e_tests/runner.py --no-cleanup
    python e2e_tests/runner.py --stage rules
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import time
from pathlib import Path

RUNNER_DIR = Path(__file__).parent
PROJECT_ROOT = RUNNER_DIR.parent
sys.path.insert(0, str(PROJECT_ROOT))

from e2e_tests.environment import E2ETestEnvironment, step, LOG_FMT

logging.basicConfig(
    level=logging.INFO, format=LOG_FMT,
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("e2e.firewall-bridge")

COMPOSE_PATH = str(RUNNER_DIR / "docker-compose.yml")

# stage: (service, test path)
STAGES = {
    "topology": ("bridge", "e2e_tests/tests/"),
    "rules": ("bridge", "e2e_tests/rules/"),
    "rules-caps": ("rules-caps", "e2e_tests/rules/"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Firewall Bridge E2E test runner")
    parser.add_argument(
        "--no-cleanup", action="store_true",
        help="Keep containers after tests (for debugging)",
    )
    parser.add_argument(
        "--stage", choices=["all", *STAGES], default="all",
        help="Stage to run (default: all, in the order above)",
    )
    parser.add_argument(
        "pytest_args", nargs="*",
        help="Extra arguments passed to pytest in each stage that runs",
    )
    return parser.parse_args()


def run_stage(env: E2ETestEnvironment, service: str, path: str,
              pytest_args: list[str]) -> int:
    """Runs pytest on `path` in `service`; returns its exit code."""
    pytest_cmd = [
        "python3", "-m", "pytest",
        path,
        "-v", "-s",
    ]
    if pytest_args:
        pytest_cmd.extend(pytest_args)

    docker_cmd = [
        "docker", "compose",
        "-f", COMPOSE_PATH,
        "-p", env.project_name,
        "exec",
        "-e", f"COMPOSE_PROJECT_NAME={env.project_name}",
        "-T", service,
        *pytest_cmd,
    ]

    proc = subprocess.Popen(
        docker_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
    )
    for raw in proc.stdout:
        line = raw.decode("utf-8", errors="replace").rstrip("\n")
        sys.stdout.write(f"  TEST | {line}\n")
        sys.stdout.flush()
    return proc.wait()


def main() -> None:
    args = parse_args()
    start_time = time.time()
    rc = 1

    env = E2ETestEnvironment("fw", compose_path=COMPOSE_PATH)
    stages = list(STAGES) if args.stage == "all" else [args.stage]
    results: dict[str, int] = {}

    try:
        env.up()

        env.wait_for_log("exit-server", "EXIT_READY", timeout=30)
        env.wait_for_ready("bridge", timeout=30)
        env.wait_for_ready("rules-caps", timeout=30)

        for stage in stages:
            service, path = STAGES[stage]
            step(f"Running E2E tests in {service} container: {stage} stage")
            results[stage] = run_stage(env, service, path, args.pytest_args)
            log.info("  %s stage: %s", stage,
                     "PASSED" if results[stage] == 0 else f"FAILED (rc={results[stage]})")
        rc = 0 if all(r == 0 for r in results.values()) else 1

    except Exception as exc:
        log.error("E2E FAILED: %s", exc)
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
