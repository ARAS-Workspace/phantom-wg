#!/usr/bin/env python3
"""
Measures what the operator tools need from a Linux host: the system Python,
the kernel, the identity of the operator, the flow of tools/prod.sh under that
identity, and the disposable container that deletes what the daemon wrote.

Standard library only, and modules beyond the ones below are imported where
they are used: that this file runs on the system Python is part of the
measurement. It reads on Python 3.9, so a host under the floor reports itself.

Usage:
    python_matrix_probe.py host <json>
    python_matrix_probe.py flow <install dir> <json>
    python_matrix_probe.py check <results dir>
    python_matrix_probe.py report <artifacts dir>
"""

from __future__ import annotations

import importlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

KERNEL_FLOOR = (5, 15)
PYTHON_FLOOR = (3, 10)

# What the operator tools use. python3-minimal holds some of these, not all.
MODULES = (
    "argparse",
    "dataclasses",
    "hashlib",
    "json",
    "pathlib",
    "pwd",
    "re",
    "shutil",
    "signal",
    "socket",
    "ssl",
    "subprocess",
    "tarfile",
    "tempfile",
    "urllib.request",
    "zipfile",
)

SECRETS = (
    ".admin_password",
    "auth_signing_key",
    "auth_verify_key",
    "tls_cert",
    "tls_key",
    "wg_private_key",
    "wg_public_key",
)

SECRETS_DIR = "container-data/secrets/production"
EXPECTED_STEPS = ("python", "gate", "docker", "tree", "flow")


def version_tuple(text: str) -> tuple[int, int]:
    match = re.match(r"(\d+)\.(\d+)", text)
    return (int(match[1]), int(match[2])) if match else (0, 0)


def write_json(path: str | Path, data: dict) -> None:
    Path(path).write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text()) if path.is_file() else {}


def os_name() -> str:
    for line in Path("/etc/os-release").read_text().splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip('"')
    return "unknown"


def cmd_host(out: str) -> int:
    """Reads the host as it is. Exit 3 when it sits under a floor."""
    missing = []
    for name in MODULES:
        # On python3-minimal tempfile raises NameError, not ImportError.
        # noinspection PyBroadException
        try:
            importlib.import_module(name)
        except Exception:
            missing.append(name)

    release = os.uname().release
    result = {
        "kernel": release,
        "kernel_floor": version_tuple(release) >= KERNEL_FLOOR,
        "modules_missing": missing,
        "os": os_name(),
        "python": sys.version.split()[0],
        "python_floor": sys.version_info[:2] >= PYTHON_FLOOR,
        "python_path": sys.executable,
        "python_preinstalled": os.environ.get("PYTHON_PREINSTALLED") == "yes",
    }
    write_json(out, result)
    for key in sorted(result):
        print(f"{key}: {result[key]}")

    return 0 if result["kernel_floor"] and result["python_floor"] and not missing else 3


def run(args: list[str], cwd: Path | None = None, stdin: str | None = None) -> int:
    """Runs a command with its output in this process's log."""
    sys.stdout.flush()
    return subprocess.run(args, cwd=cwd, input=stdin, text=True, check=False).returncode


def capture(args: list[str], cwd: Path | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False
    )
    return proc.returncode, proc.stdout.strip()


def request(path: str, token: str = "", body: dict | None = None) -> tuple[int, bytes]:
    """HTTPS request to the stack; status 0 when nothing answers."""
    import ssl
    import urllib.error
    import urllib.request

    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE

    headers = {"Content-Type": "application/json"} if body else {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(f"https://127.0.0.1{path}", data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, context=context, timeout=6) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()
    except OSError:
        return 0, b""


def hello(token: str = "") -> int:
    return request("/api/core/hello", token)[0]


def wait_for(status: int, token: str = "", seconds: int = 60) -> bool:
    for _ in range(seconds):
        if hello(token) == status:
            return True
        time.sleep(1)
    return False


def secret_modes(root: Path) -> dict:
    """Owner and mode of each secret, and whether other local users can read it."""
    import pwd

    modes = {}
    for name in SECRETS:
        info = (root / SECRETS_DIR / name).stat()
        modes[name] = {
            "mode": f"{info.st_mode & 0o777:o}",
            "others_read": bool(info.st_mode & 0o004),
            "owner": pwd.getpwuid(info.st_uid).pw_name,
        }
    return modes


def entries(path: Path) -> int:
    return sum(len(dirs) + len(files) for _, dirs, files in os.walk(path))


def disposable_delete(root: Path, result: dict) -> None:
    """Deletes container-data from a disposable container, without root.

    accepted: the host let this user start the container and the capability
    worked. refused: the daemon or a plugin turned the container down.
    ineffective: the container ran and could not delete, as under user
    namespaces, where its root is not the host's.
    """
    rc, image = capture(
        ["docker", "compose", "-f", "tools/compose/registry.yml", "config", "--images", "daemon"],
        cwd=root,
    )
    data = root / "container-data"
    before = entries(data)
    rc, output = capture(
        [
            "docker", "run", "--rm", "--pull", "never", "--network", "none",
            "--cap-drop", "ALL", "--cap-add", "DAC_OVERRIDE",
            "--mount", f"type=bind,src={data},dst=/data",
            image, "find", "/data", "-mindepth", "1", "-delete",
        ]
    )
    left = entries(data)

    if rc == 0 and left == 0:
        state = "accepted"
    elif rc == 125:
        state = "refused"
    else:
        state = "ineffective"

    print(f"disposable: {state}, exit {rc}, entries {before} then {left}", flush=True)
    if output:
        print(output[-400:], flush=True)
    result["dac_override"] = {"before": before, "exit": rc, "left": left, "state": state}


def run_flow(root: Path, result: dict) -> bool:
    steps = result["steps"]

    def prod(name: str, *args: str, stdin: str | None = None) -> bool:
        print(f"--- prod.sh {' '.join(args)}", flush=True)
        steps[name] = run(["./tools/prod.sh", *args], cwd=root, stdin=stdin)
        return steps[name] == 0

    rc, text = capture(["docker", "info", "--format", "{{json .}}"])
    result["docker_access"] = rc == 0
    if rc != 0:
        print(text, flush=True)
        return False

    info = json.loads(text)
    result["docker"] = {
        "kernel": info.get("KernelVersion"),
        "root_dir": info.get("DockerRootDir"),
        "security": info.get("SecurityOptions"),
        "storage": info.get("Driver"),
        "version": info.get("ServerVersion"),
    }
    result["kernel_floor"] = version_tuple(info.get("KernelVersion", "")) >= KERNEL_FLOOR
    print(f"euid {result['euid']}, docker {result['docker']}", flush=True)

    result["tun"] = Path("/dev/net/tun").exists()
    if not prod("setup", "setup"):
        return False
    result["secrets"] = secret_modes(root)

    env_file = root / ".env.daemon"
    env_file.write_text(
        re.sub(
            r"^WIREGUARD_ENDPOINT_V4=.*$",
            "WIREGUARD_ENDPOINT_V4=127.0.0.1",
            env_file.read_text(),
            flags=re.MULTILINE,
        )
    )

    if not prod("up", "up") or not wait_for(401):
        return False

    password = (root / SECRETS_DIR / ".admin_password").read_text().strip()
    status, body = request("/auth/login", body={"username": "admin", "password": password})
    steps["login"] = status
    if status != 200:
        return False
    token = json.loads(body)["data"]["token"]
    if not wait_for(200, token):
        return False

    print("--- daemon stopped: what each request sees", flush=True)
    run(["docker", "stop", "phantom-daemon"])
    time.sleep(2)
    result["daemon_stopped"] = {"anonymous": hello(), "authorized": hello(token)}
    print(result["daemon_stopped"], flush=True)
    run(["docker", "start", "phantom-daemon"])
    if not wait_for(200, token):
        return False

    if not prod("update", "update") or not wait_for(200, token):
        return False

    prod("hard_reset", "hard-reset", stdin="yes\n")
    disposable_delete(root, result)
    return True


def cmd_flow(install_dir: str, out: str) -> int:
    """Runs the tools as this user. Exit 1 when the flow does not reach the end."""
    result: dict = {"euid": os.geteuid(), "reached_end": False, "steps": {}}
    try:
        result["reached_end"] = run_flow(Path(install_dir), result)
    finally:
        write_json(out, result)
    return 0 if result["reached_end"] else 1


def read_env(path: Path) -> dict:
    values = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            key, _, value = line.partition("=")
            values[key] = value.strip("'")
    return values


def read_steps(path: Path) -> dict:
    steps = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            name, code, _ = line.split()
            steps[name] = int(code)
    return steps


def evaluate(role: str, host: dict, flow: dict, steps: dict) -> tuple[list[str], list[str]]:
    """The failures and the warnings of one host."""
    if not host:
        return ["the guest wrote no host measurement"], []

    floors = host["kernel_floor"] and host["python_floor"]
    if role == "below-floor":
        return ([] if not floors else ["this host was expected under a floor"]), []

    failures, warnings = [], []
    if not host["kernel_floor"]:
        failures.append(f"kernel {host['kernel']} is under {KERNEL_FLOOR}")
    if not host["python_floor"]:
        failures.append(f"Python {host['python']} is under {PYTHON_FLOOR}")
    if host["modules_missing"]:
        failures.append(f"missing modules: {', '.join(host['modules_missing'])}")
    if not host["python_preinstalled"]:
        warnings.append("python3 did not come with the image")

    for name in EXPECTED_STEPS:
        if name not in steps:
            failures.append(f"step {name} did not run")
        elif steps[name] != 0:
            failures.append(f"step {name} exited {steps[name]}")

    if flow:
        stopped = flow.get("daemon_stopped", {})
        if stopped.get("authorized") == 200:
            failures.append("an authorized request passed with the daemon stopped")
        state = flow.get("dac_override", {}).get("state")
        if state and state != "accepted":
            warnings.append(
                f"DAC_OVERRIDE for a user of the docker group: {state}; "
                "disposable deletion needs root on this host"
            )

    return failures, warnings


def cmd_check(directory: str) -> int:
    results = Path(directory)
    env = read_env(results / "matrix.env")
    role, name = env.get("ROLE", "required"), env.get("NAME", directory)
    host = load_json(results / "host.json")
    flow = load_json(results / "flow.json")
    failures, warnings = evaluate(role, host, flow, read_steps(results / "steps"))

    print(f"## {name}\n\n```")
    print(f"role:    {role}")
    print(f"os:      {host.get('os')}")
    print(f"kernel:  {host.get('kernel')}")
    print(f"python:  {host.get('python')} ({host.get('python_path')})")
    print(f"docker:  {flow.get('docker', {}).get('version')}")
    print(f"steps:   {flow.get('steps')}")
    print(f"dac:     {flow.get('dac_override')}")
    print("```\n")

    level = "warning" if role == "observe" else "error"
    for text in warnings:
        print(f"::warning title={name}::{text}")
    for text in failures:
        print(f"::{level} title={name}::{text}")
    return 1 if failures else 0


def report_row(results: Path) -> tuple[int, str]:
    env = read_env(results / "matrix.env")
    role = env.get("ROLE", "?")
    host = load_json(results / "host.json")
    flow = load_json(results / "flow.json")
    failures, warnings = evaluate(role, host, flow, read_steps(results / "steps"))

    dependents = results / "python-dependents"
    held_by = len(dependents.read_text().split()) if dependents.is_file() else 0
    secrets = flow.get("secrets", {})
    open_secrets = sum(1 for item in secrets.values() if item["others_read"])
    outcome = "fail" if failures else ("warn" if warnings else "pass")
    cells = [
        env.get("NAME", results.parent.name),
        role,
        host.get("kernel", "?"),
        host.get("python", "?"),
        "yes" if host.get("python_preinstalled") else "no",
        str(held_by),
        ", ".join(host.get("modules_missing", [])) or "none",
        flow.get("docker", {}).get("version", "-"),
        "yes" if flow.get("reached_end") else "-",
        str(flow.get("steps", {}).get("hard_reset", "-")),
        f"{open_secrets} of {len(secrets)}" if secrets else "-",
        flow.get("dac_override", {}).get("state", "-"),
        outcome,
    ]
    order = {"required": 0, "observe": 1, "below-floor": 2}.get(role, 3)
    return order, "| " + " | ".join(cells) + " |"


def cmd_report(directory: str) -> int:
    print("# Linux distribution Python matrix\n")
    print(
        f"Floors: kernel {'.'.join(map(str, KERNEL_FLOOR))}, "
        f"Python {'.'.join(map(str, PYTHON_FLOOR))}.\n"
    )
    print(
        "| Host | Role | Kernel | Python | With the image | Packages on python3 "
        "| Missing modules | Docker | Flow | `hard-reset` exit | Secrets others read "
        "| `DAC_OVERRIDE` | Result |"
    )
    print("|" + "---|" * 13)
    for _, row in sorted(report_row(path) for path in Path(directory).glob("*/results")):
        print(row)
    return 0


def main() -> int:
    commands = {"host": cmd_host, "flow": cmd_flow, "check": cmd_check, "report": cmd_report}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        print(__doc__)
        return 2
    return commands[sys.argv[1]](*sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
