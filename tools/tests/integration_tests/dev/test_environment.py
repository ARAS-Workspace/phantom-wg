"""The development environment from nothing, on the real stack, from the outside.

DESTRUCTIVE: every run wipes the stack, its volumes and container-data of this
tree. It runs only when named, top to bottom, each test on what the last left:

    pytest tests/integration_tests -x -s
"""

from __future__ import annotations

import hashlib
import json
import os
import pty
import re
import select
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
ENTRY = "./tools/dev.sh"
SECRETS = ROOT / "container-data/secrets/development"
AUTH_DB = ROOT / "container-data/auth-db/auth.db"
DB = ROOT / "container-data/db"
STATE = ROOT / "container-data/state/db"
PACKAGE = ROOT / "dist/phantom-wg-modern"
SPA_DIST = ROOT / "services/react-spa/dist"
BOUND = ("container-data/db", "container-data/state/db", "container-data/auth-db", "container-data/secrets/development")
SECRET_FILES = (
    "wg_private_key", "wg_public_key", "auth_signing_key", "auth_verify_key",
    "tls_cert", "tls_key", ".admin_password",
)
COMMANDS = (
    "build", "up", "down", "restart", "rebuild", "logs", "status", "show-versions", "shell", "curl",
    "test", "test-full", "test-uds", "test-multihop-e2e", "test-chaos-e2e", "test-scenario-e2e", "test-spa-e2e",
    "db-ls", "db-ls-r", "db-reset", "state-reset", "key-reset", "hard-reset",
    "setup", "gen-keys", "setup-auth", "setup-tls",
    "build-spa", "stubs", "openapi", "fetch-compose-bridge", "generate-production-package",
)
DAEMON_CONTAINER = "phantom-daemon-dev"
GATEWAY = "http://127.0.0.1:9080/api/core/hello"
ONE_TEST_FILE = "tests/unit/test_subnet_check.py"
LONG = 600


def dev(
    *args: str, stdin: str = "", timeout: int = 120, cwd: Path = ROOT, entry: str = ENTRY, env: dict | None = None,
) -> subprocess.CompletedProcess:
    """Runs dev.sh with its output on the terminal, line by line."""
    print(f"\n--- dev.sh {' '.join(args)}", flush=True)
    process = subprocess.Popen(
        [entry, *args], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding="utf-8", errors="replace",
    )
    timer = threading.Timer(timeout, process.kill)
    timer.start()
    try:
        process.stdin.write(stdin)
        process.stdin.close()
        lines = []
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            lines.append(line)
        process.wait()
    finally:
        timer.cancel()
    return subprocess.CompletedProcess(args, process.returncode, "".join(lines))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def without_docker(directory: Path) -> dict:
    """A PATH that holds what dev.sh needs to start, and no docker."""
    for tool in ("bash", "dirname", "python3"):
        os.symlink(shutil.which(tool), directory / tool)
    return {"PATH": str(directory)}


def only_gitkeep(name: str) -> bool:
    return [path.name for path in (ROOT / name).iterdir()] == [".gitkeep"]


def hello() -> int:
    try:
        with urllib.request.urlopen(GATEWAY, timeout=3) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return 0


def wait_for_hello(seconds: int = 60) -> int:
    status = 0
    for _ in range(seconds):
        status = hello()
        if status == 200:
            break
        time.sleep(1)
    return status


def started_at() -> str:
    done = subprocess.run(
        ["docker", "inspect", "-f", "{{.State.StartedAt}}", DAEMON_CONTAINER],
        capture_output=True, encoding="utf-8", timeout=30, check=True,
    )
    return done.stdout.strip()


def code_version() -> str:
    text = (ROOT / "phantom_daemon/__init__.py").read_text(encoding="utf-8")
    return re.search(r'__version__ = "(.+?)"', text)[1]


def login() -> int:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    password = (SECRETS / ".admin_password").read_text(encoding="utf-8").strip()
    body = json.dumps({"username": "admin", "password": password}).encode()
    request = urllib.request.Request(
        "https://127.0.0.1/auth/login", data=body, headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, context=context, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return 0


def test_help_lists_every_command():
    done = dev("help")
    assert done.returncode == 0
    listed = {line.split()[0] for line in done.stdout.splitlines() if line.startswith("    ")}
    assert listed == {*COMMANDS, "help"}


def test_unknown_command_stops():
    done = dev("no-such-command")
    assert done.returncode == 1
    assert "Unknown command: no-such-command" in done.stdout


def test_runs_from_any_directory():
    done = dev("db-ls", cwd=Path("/"), entry=str(ROOT / "tools/dev.sh"))
    assert done.returncode == 0, done.stdout


def test_stops_without_python3(tmp_path):
    for tool in ("bash", "dirname"):
        os.symlink(shutil.which(tool), tmp_path / tool)
    done = subprocess.run(
        [str(ROOT / "tools/dev.sh"), "help"], env={"PATH": str(tmp_path)},
        capture_output=True, encoding="utf-8", timeout=20, check=False,
    )
    assert done.returncode == 1
    assert done.stderr == "python3 is required.\n"


def test_hard_reset_needs_yes():
    done = dev("hard-reset", stdin="no\n")
    assert done.returncode == 1
    assert "Aborted." in done.stdout


def test_hard_reset_clears_what_the_stack_bound():
    for name in BOUND:
        (ROOT / name / "left-behind").touch()
    done = dev("hard-reset", stdin="yes\n", timeout=LONG)
    assert done.returncode == 0, done.stdout
    for name in BOUND:
        assert only_gitkeep(name), name


def test_setup_builds_the_environment():
    done = dev("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert AUTH_DB.is_file()
    for name in SECRET_FILES:
        path = SECRETS / name
        assert path.stat().st_size > 0, name
        assert path.stat().st_mode & 0o777 == 0o600, name


def test_setup_refuses_an_existing_environment():
    before = {name: digest(SECRETS / name) for name in SECRET_FILES}
    done = dev("setup")
    assert done.returncode == 1
    assert "Setup is already complete." in done.stdout
    assert before == {name: digest(SECRETS / name) for name in SECRET_FILES}


def test_setup_takes_no_force():
    done = dev("setup", "-f")
    assert done.returncode == 1
    assert done.stdout.strip().endswith("Usage: ./tools/dev.sh setup")


@pytest.mark.parametrize(
    ("command", "files"),
    [
        ("gen-keys", ("wg_private_key", "wg_public_key")),
        ("setup-auth", ("auth_signing_key", ".admin_password")),
        ("setup-tls", ("tls_cert", "tls_key")),
    ],
)
def test_existing_files_ask_for_force(command, files):
    before = [digest(SECRETS / name) for name in files]
    done = dev(command)
    assert done.returncode == 0
    assert "Use -f to overwrite." in done.stdout
    assert before == [digest(SECRETS / name) for name in files]


@pytest.mark.parametrize(
    ("command", "files"),
    [
        ("gen-keys", ("wg_private_key", "wg_public_key")),
        ("setup-tls", ("tls_cert", "tls_key")),
        ("setup-auth", ("auth_signing_key", ".admin_password")),
    ],
)
def test_force_replaces_the_files(command, files):
    before = [digest(SECRETS / name) for name in files]
    done = dev(command, "-f", timeout=LONG)
    assert done.returncode == 0, done.stdout
    after = [digest(SECRETS / name) for name in files]
    assert all(old != new for old, new in zip(before, after))
    for name in files:
        assert (SECRETS / name).stat().st_mode & 0o777 == 0o600, name


def test_setup_auth_force_keeps_the_old_database():
    assert list(AUTH_DB.parent.glob("auth.db.*.bak"))


def test_build_builds_the_images():
    done = dev("build", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Images built.")


def test_up_answers():
    done = dev("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Stack started.")
    assert wait_for_hello() == 200


def test_login_works_with_the_generated_password():
    status = 0
    for _ in range(30):
        status = login()
        if status == 200:
            break
        time.sleep(1)
    assert status == 200


def test_status_lists_the_stack():
    done = dev("status")
    assert done.returncode == 0
    for name in (DAEMON_CONTAINER, "phantom-auth-dev", "phantom-nginx-dev", "phantom-gateway", "phantom-exit-dev"):
        assert name in done.stdout


def test_show_versions_reads_the_container():
    done = dev("show-versions")
    assert done.returncode == 0, done.stdout
    assert f"Phantom Daemon        {code_version()}" in done.stdout
    assert "firewall-bridge" in done.stdout
    assert "not found" not in done.stdout


def test_curl_reads_the_gateway():
    done = dev("curl")
    assert done.returncode == 0, done.stdout
    assert json.loads(done.stdout)["ok"] is True


def test_curl_takes_a_path():
    done = dev("curl", "/api/core/no-such-path")
    assert done.returncode == 0, done.stdout


def test_db_ls_sees_the_files_of_the_daemon():
    assert "wallet.db" in dev("db-ls").stdout
    assert "wallet.db" in dev("db-ls-r").stdout


@pytest.mark.parametrize("command", ["test", "test-full", "test-uds"])
def test_pytest_runs_in_the_container_with_its_arguments(command):
    done = dev(command, ONE_TEST_FILE, timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert " passed" in done.stdout


def test_a_failing_pytest_keeps_its_exit_code():
    done = dev("test", "tests/no_such_file.py")
    assert done.returncode == 4


def test_openapi_writes_the_schema():
    target = ROOT / "openapi.json"
    target.unlink(missing_ok=True)
    done = dev("openapi")
    assert done.returncode == 0, done.stdout
    assert "/api/core/hello" in json.loads(target.read_text(encoding="utf-8"))["paths"]


def test_stubs_writes_the_vendor_stubs():
    done = dev("stubs", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert list((ROOT / "typings").rglob("*.pyi"))


def test_restart_starts_the_daemon_again():
    before = started_at()
    done = dev("restart")
    assert done.returncode == 0, done.stdout
    assert started_at() != before
    assert wait_for_hello() == 200


def test_logs_follow_the_daemon():
    process = subprocess.Popen(
        [ENTRY, "logs"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
    )
    timer = threading.Timer(20, process.kill)
    timer.start()
    try:
        line = process.stdout.readline()
        print(line, end="", flush=True)
        assert line
        assert process.poll() is None
    finally:
        timer.cancel()
        process.terminate()
        process.wait(timeout=10)


def test_shell_opens_bash_on_a_terminal():
    master, slave = pty.openpty()
    process = subprocess.Popen([ENTRY, "shell"], cwd=ROOT, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    os.write(master, b"echo inside-$((6*7)); exit 7\n")
    output = b""
    deadline = time.time() + 30
    while time.time() < deadline and process.poll() is None:
        if select.select([master], [], [], 0.5)[0]:
            try:
                output += os.read(master, 4096)
            except OSError:
                break
    assert process.wait(timeout=10) == 7
    os.close(master)
    assert b"inside-42" in output


def test_down_stops_the_stack():
    done = dev("down")
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Stopped.")
    assert hello() == 0


def test_setup_is_still_complete_after_down():
    assert dev("setup").returncode == 1


def test_db_reset_clears_the_databases():
    done = dev("db-reset")
    assert done.returncode == 0, done.stdout
    assert only_gitkeep("container-data/db")
    assert not AUTH_DB.exists()


def test_state_reset_clears_the_state():
    done = dev("state-reset")
    assert done.returncode == 0, done.stdout
    assert only_gitkeep("container-data/state/db")


def test_key_reset_clears_the_secrets():
    done = dev("key-reset")
    assert done.returncode == 0, done.stdout
    assert only_gitkeep("container-data/secrets/development")


def test_setup_rebuilds_what_the_resets_took():
    done = dev("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert AUTH_DB.is_file()
    assert (SECRETS / "tls_key").is_file()


def test_build_spa_builds_the_dashboard():
    done = dev("build-spa", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert (ROOT / "services/react-spa/dist/index.html").is_file()


def test_generate_production_package_builds_the_spa_and_the_tree():
    done = dev("generate-production-package", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "Building React SPA..." in done.stdout
    assert (PACKAGE / "docker-compose.yml").is_file()


def test_no_spa_packages_what_is_there():
    done = dev("generate-production-package", "--no-spa")
    assert done.returncode == 0, done.stdout
    assert "Building React SPA..." not in done.stdout
    assert done.stdout.isascii()
    assert (PACKAGE / "services/react-spa/dist/index.html").is_file()


def test_the_package_holds_what_a_host_needs():
    for name in ("tools/compose/registry.yml", "tools/compose/MANIFEST.json", "phantom_daemon/__init__.py"):
        assert (PACKAGE / name).is_file(), name
    assert ".terazi-subnet" in (PACKAGE / ".gitignore").read_text(encoding="utf-8")


def test_the_tool_of_the_package_starts():
    done = subprocess.run(
        [str(PACKAGE / "tools/prod.sh"), "help"], capture_output=True, encoding="utf-8", timeout=20, check=False,
    )
    assert done.returncode == 0, done.stderr
    assert done.stdout.startswith("Usage: ./tools/prod.sh <command>")


def test_the_package_leaves_development_out():
    for name in ("tools/dev.sh", "tools/stack/dev", "tools/tests", "tools/compose/dev.yml", "e2e_tests", "tests"):
        assert not (PACKAGE / name).exists(), name
    found = {path.name for path in PACKAGE.rglob("*")}
    assert not found & {"__pycache__", ".gitkeep"}
    assert not [name for name in found if name.endswith((".pyc", ".pyo"))]


def test_a_missing_path_stops_the_package_and_keeps_the_last_one():
    aside = SPA_DIST.with_name("dist-aside")
    SPA_DIST.rename(aside)
    try:
        done = dev("generate-production-package", "--no-spa")
    finally:
        aside.rename(SPA_DIST)
    assert done.returncode == 1
    assert done.stdout.strip().endswith("Missing from the package: services/react-spa/dist")
    assert (PACKAGE / "docker-compose.yml").is_file()


def test_fetch_compose_bridge_installs_the_library():
    done = dev("fetch-compose-bridge", timeout=LONG)
    assert done.returncode == 0, done.stdout
    directory = ROOT / "lib/compose_bridge"
    assert [*directory.glob("*.dylib"), *directory.glob("*.so")]


@pytest.mark.parametrize("command", ["test-multihop-e2e", "test-chaos-e2e", "test-scenario-e2e", "test-spa-e2e"])
def test_e2e_runners_start_with_their_arguments(command):
    probe = subprocess.run(["python3", "-c", "import typing; typing.Self"], capture_output=True, timeout=20, check=False)
    if probe.returncode != 0:
        pytest.skip("the E2E runners need the python3 of the daemon venv")
    done = dev(command, "--help")
    assert done.returncode == 0, done.stdout
    assert "--no-cleanup" in done.stdout


def test_hard_reset_starts_over_after_a_real_run():
    done = dev("hard-reset", stdin="yes\n")
    assert done.returncode == 0, done.stdout
    for name in BOUND:
        assert only_gitkeep(name), name


def test_nothing_to_wipe_needs_no_docker(tmp_path):
    done = dev("state-reset", env=without_docker(tmp_path))
    assert done.returncode == 0, done.stdout


def test_a_wipe_goes_through_a_container(tmp_path):
    left = STATE / "left-behind"
    left.touch()
    done = dev("state-reset", env=without_docker(tmp_path))
    assert done.returncode != 0
    assert left.exists()


def test_the_wipe_container_is_closed(tmp_path):
    record = tmp_path / "docker-calls"
    shim = tmp_path / "docker"
    shim.write_text(f'#!/bin/sh\necho "$*" >> "{record}"\nexec "{shutil.which("docker")}" "$@"\n', encoding="utf-8")
    shim.chmod(0o755)
    done = dev("state-reset", env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}"})
    assert done.returncode == 0, done.stdout
    assert only_gitkeep("container-data/state/db")
    call = next(line for line in record.read_text(encoding="utf-8").splitlines() if line.startswith("run "))
    for flag in ("--rm", "--pull never", "--network none", "--cap-drop ALL", "--cap-add DAC_OVERRIDE", "--mount type=bind"):
        assert flag in call
