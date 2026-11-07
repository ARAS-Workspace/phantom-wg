"""What a user does on a production host, on the real stack, from the outside.

DESTRUCTIVE: every run wipes the stack, its volumes, container-data and the local
files of this tree, and the development stack shares them. It stops when a
phantom container runs. It runs only when named, top to bottom, each test on what
the last left:

    pytest tests/integration_tests/prod -x -s
"""

from __future__ import annotations

import contextlib
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
ENTRY = "./tools/prod.sh"
SECRETS = ROOT / "container-data/secrets/production"
AUTH_DB = ROOT / "container-data/auth-db/auth.db"
AUTH_SOURCE = ROOT / "services/auth-service"
APPLIED = ROOT / "container-data/.applied-version"
SUBNET_FILE = ROOT / ".terazi-subnet"
SPA_INDEX = ROOT / "services/react-spa/dist/index.html"
ENV_DAEMON = ROOT / ".env.daemon"
BOUND = ("container-data/db", "container-data/state/db", "container-data/auth-db", "container-data/secrets/production")
LOCAL_FILES = (".env", ".env.daemon", ".env.auth-service", "docker-compose.override.yml")
STACK_SECRETS = ("wg_private_key", "wg_public_key", "auth_signing_key", "auth_verify_key", "tls_cert", "tls_key")
SECRET_FILES = (*STACK_SECRETS, ".admin_password")
COMMANDS = (
    "setup", "gen-keys", "setup-auth", "setup-tls", "up", "down", "restart", "logs", "status",
    "show-versions", "shell", "exec", "hard-reset", "gates",
)
SERVICES = ("phantom-daemon", "phantom-auth", "phantom-nginx")
API = "https://127.0.0.1"
LONG = 600
STACK_IS_RUNNING = "The stack is running. Stop it first: ./tools/prod.sh down"
OPERATOR = f"{os.getuid()}:{os.getgid()}"

linux_only = pytest.mark.skipif(sys.platform != "linux", reason="Docker Desktop hides the owner of a file")


def prod(*args: str, stdin: str = "", timeout: int = 120, cwd: Path = ROOT, entry: str = ENTRY) -> subprocess.CompletedProcess:
    """Runs prod.sh with its output on the terminal, line by line."""
    print(f"\n--- prod.sh {' '.join(args)}", flush=True)
    process = subprocess.Popen(
        [entry, *args], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
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


def sudo(*args: str) -> subprocess.CompletedProcess:
    """Runs a command as root, with its output on the terminal."""
    print(f"\n--- sudo {' '.join(args)}", flush=True)
    done = subprocess.run(
        ["sudo", "-n", *args], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding="utf-8", errors="replace", timeout=LONG, check=False,
    )
    print(done.stdout, end="", flush=True)
    return done


def wipe_the_tree() -> None:
    prod("down")
    prod("hard-reset", stdin="yes\n", timeout=LONG)
    for name in LOCAL_FILES:
        (ROOT / name).unlink(missing_ok=True)


@pytest.fixture(scope="module", autouse=True)
def tree():
    """The tree is the host: empty at the start, and empty again at the end."""
    running = subprocess.run(
        ["docker", "ps", "-q", "--filter", "name=phantom"], capture_output=True, encoding="utf-8", timeout=30, check=True,
    )
    if running.stdout.strip():
        pytest.exit("A phantom container runs. This suite takes over the tree: stop the stack first.", returncode=1)

    placeholder = not SPA_INDEX.exists()
    if placeholder:
        SPA_INDEX.parent.mkdir(parents=True, exist_ok=True)
        SPA_INDEX.write_text("<!DOCTYPE html><html><body>test</body></html>\n", encoding="utf-8")

    wipe_the_tree()
    yield
    wipe_the_tree()
    if placeholder:
        SPA_INDEX.unlink()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def only_gitkeep(name: str) -> bool:
    return [path.name for path in (ROOT / name).iterdir()] == [".gitkeep"]


def code_version() -> str:
    text = (ROOT / "phantom_daemon/__init__.py").read_text(encoding="utf-8")
    return re.search(r'__version__ = "(.+?)"', text)[1]


@contextlib.contextmanager
def lost(path: Path):
    """The file is gone for as long as the block runs."""
    aside = path.with_name(f"{path.name}-aside")
    path.rename(aside)
    try:
        yield
    finally:
        aside.rename(path)


@contextlib.contextmanager
def emptied(path: Path):
    content = path.read_bytes()
    path.write_bytes(b"")
    try:
        yield
    finally:
        path.write_bytes(content)


def assert_the_operator_owns_the_host() -> None:
    paths = [
        *(ROOT / name for name in LOCAL_FILES), *(SECRETS / name for name in SECRET_FILES),
        SECRETS, AUTH_DB.parent, AUTH_DB, APPLIED,
    ]
    assert not [str(path) for path in paths if path.stat().st_uid != os.getuid()]


def set_the_endpoint() -> None:
    text = ENV_DAEMON.read_text(encoding="utf-8")
    ENV_DAEMON.write_text(text.replace("WIREGUARD_ENDPOINT_V4=\n", "WIREGUARD_ENDPOINT_V4=127.0.0.1\n"), encoding="utf-8")


def call(path: str, token: str = "", body: dict | None = None) -> tuple:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(f"{API}{path}", data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, context=context, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except OSError:
        return 0, b""


def logged_in(username: str = "admin", seconds: int = 60) -> str:
    """A token, once the stack answers with one. An anonymous 401 proves nothing of the daemon."""
    password = (SECRETS / ".admin_password").read_text(encoding="utf-8").strip()
    status = 0
    for _ in range(seconds):
        status, body = call("/auth/login", body={"username": username, "password": password})
        if status == 200:
            return json.loads(body)["data"]["token"]
        time.sleep(1)
    raise AssertionError(f"login answered {status}")


def api_answers(token: str, path: str = "/api/core/hello", seconds: int = 60) -> tuple:
    status, body = 0, b""
    for _ in range(seconds):
        status, body = call(path, token=token)
        if status == 200:
            return status, json.loads(body)
        time.sleep(1)
    return status, body


# ── First install ───────────────────────────────────────────────────


def test_help_lists_every_command():
    done = prod("help")
    assert done.returncode == 0
    listed = {line.split()[0] for line in done.stdout.splitlines() if line.startswith("    ")}
    assert listed == {*COMMANDS, "help"}
    assert done.stdout.isascii()


def test_unknown_command_stops():
    done = prod("no-such-command")
    assert done.returncode == 1
    assert "Unknown command: no-such-command" in done.stdout


def test_up_before_setup_names_what_is_missing():
    done = prod("up")
    assert done.returncode == 1
    for name in (*LOCAL_FILES, "wg_private_key", "tls_key", "auth.db"):
        assert name in done.stdout, name
    assert done.stdout.strip().endswith("Run './tools/prod.sh setup' first.")


def test_setup_takes_no_force():
    done = prod("setup", "-f")
    assert done.returncode == 1
    assert "Usage: ./tools/prod.sh setup" in done.stdout


def test_setup_refuses_a_subnet_the_daemon_refuses():
    done = prod("setup", "--terazi-ipv4-subnet=8.8.8.0/24", timeout=LONG)
    assert done.returncode != 0
    assert not SUBNET_FILE.exists()
    assert not (ROOT / ".env").exists()


def test_setup_builds_the_host():
    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "Edit .env.daemon and set WIREGUARD_ENDPOINT_V4 before starting." in done.stdout
    for name in LOCAL_FILES:
        assert (ROOT / name).is_file(), name
    for name in SECRET_FILES:
        path = SECRETS / name
        assert path.stat().st_size > 0, name
        assert path.stat().st_mode & 0o777 == 0o600, name
    assert AUTH_DB.is_file()
    assert APPLIED.read_text(encoding="utf-8").strip() == code_version()


def test_setup_refuses_a_complete_host():
    before = {name: digest(SECRETS / name) for name in SECRET_FILES}
    done = prod("setup")
    assert done.returncode == 1
    assert "Setup is already complete." in done.stdout
    assert before == {name: digest(SECRETS / name) for name in SECRET_FILES}


# ── Rotation and lost files, the stack down ─────────────────────────


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
    done = prod(command)
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
    done = prod(command, "-f", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert all(old != digest(SECRETS / name) for old, name in zip(before, files))
    for name in files:
        assert (SECRETS / name).stat().st_mode & 0o777 == 0o600, name


def test_setup_auth_force_keeps_the_old_database():
    assert list(AUTH_DB.parent.glob("auth.db.*.bak"))


def test_force_changes_nothing_without_the_auth_source():
    before = sorted(AUTH_DB.parent.iterdir())
    with lost(AUTH_SOURCE):
        done = prod("setup-auth", "-f")
    assert done.returncode == 1
    assert "auth-service not found" in done.stdout
    assert sorted(AUTH_DB.parent.iterdir()) == before


@pytest.mark.parametrize("empty", [False, True], ids=["lost", "empty"])
def test_setup_brings_a_public_key_back_from_the_private_key(empty):
    path = SECRETS / "wg_public_key"
    private_key = digest(SECRETS / "wg_private_key")
    public_key = digest(path)
    if empty:
        path.write_bytes(b"")
    else:
        path.unlink()
    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert digest(SECRETS / "wg_private_key") == private_key
    assert digest(path) == public_key


def test_a_lost_private_key_gives_a_new_pair():
    public_key = digest(SECRETS / "wg_public_key")
    (SECRETS / "wg_private_key").unlink()
    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert digest(SECRETS / "wg_public_key") != public_key


@pytest.mark.parametrize(("gone", "kept"), [("tls_key", "tls_cert"), ("tls_cert", "tls_key")])
def test_a_lost_tls_file_stops_setup(gone, kept):
    before = digest(SECRETS / kept)
    with lost(SECRETS / gone):
        for args in (("setup",), ("setup-tls",)):
            done = prod(*args)
            assert done.returncode == 1
            assert f"{gone} is missing" in done.stdout
            assert "setup-tls -f" in done.stdout
    assert digest(SECRETS / kept) == before


def test_setup_tls_force_replaces_a_lost_file():
    (SECRETS / "tls_key").unlink()
    done = prod("setup-tls", "-f")
    assert done.returncode == 0, done.stdout
    assert (SECRETS / "tls_key").stat().st_size > 0


def test_setup_sends_a_lost_auth_key_to_force():
    with lost(SECRETS / "auth_verify_key"):
        done = prod("setup")
    assert done.returncode == 1
    assert "Use -f to start over." in done.stdout


def test_rotation_from_another_directory_stays_in_this_tree(tmp_path):
    before = digest(SECRETS / "wg_private_key")
    done = prod("gen-keys", "-f", cwd=tmp_path, entry=str(ROOT / "tools/prod.sh"), timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert digest(SECRETS / "wg_private_key") != before
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize("name", LOCAL_FILES)
def test_up_stops_without_a_local_file(name):
    with lost(ROOT / name):
        done = prod("up")
    assert done.returncode == 1
    assert f"Missing: {name}" in done.stdout


@pytest.mark.parametrize("name", STACK_SECRETS)
@pytest.mark.parametrize("damage", [lost, emptied], ids=["lost", "empty"])
def test_up_stops_without_a_secret(name, damage):
    with damage(SECRETS / name):
        done = prod("up")
    assert done.returncode == 1
    assert f"Missing: container-data/secrets/production/{name}" in done.stdout


def test_up_stops_without_the_auth_database():
    with lost(AUTH_DB):
        done = prod("up")
    assert done.returncode == 1
    assert "Missing: container-data/auth-db/auth.db" in done.stdout


# ── The running stack ───────────────────────────────────────────────


def test_up_gives_a_stack_that_logs_in():
    set_the_endpoint()
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Stack started.")
    for name in SERVICES:
        assert name in done.stdout, name
    status, data = api_answers(logged_in())
    assert status == 200
    assert data["data"]["version"] == code_version()


def test_the_dashboard_answers():
    assert call("/")[0] == 200


def test_status_lists_the_stack():
    done = prod("status")
    assert done.returncode == 0
    for name in SERVICES:
        assert name in done.stdout


def test_show_versions_reads_the_container():
    done = prod("show-versions")
    assert done.returncode == 0, done.stdout
    assert f"Phantom Daemon        {code_version()}" in done.stdout
    assert "not found" not in done.stdout


def test_exec_runs_in_the_service():
    done = prod("exec", "daemon", "sh", "-c", "echo inside-$((6*7))")
    assert done.returncode == 0, done.stdout
    assert "inside-42" in done.stdout


def test_exec_keeps_the_exit_code():
    assert prod("exec", "daemon", "sh", "-c", "exit 7").returncode == 7


def test_logs_follow_a_service():
    process = subprocess.Popen(
        [ENTRY, "logs", "daemon"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
    )
    timer = threading.Timer(20, process.kill)
    timer.start()
    try:
        assert process.stdout.readline()
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


@pytest.mark.parametrize("args", [(), ("daemon",)], ids=["all", "one"])
def test_restart_brings_the_api_back(args):
    done = prod("restart", *args)
    assert done.returncode == 0, done.stdout
    assert api_answers(logged_in())[0] == 200


def test_restart_of_a_service_that_does_not_exist_stops():
    assert prod("restart", "no-such-service").returncode != 0


@pytest.mark.parametrize(
    "args",
    [("hard-reset",), ("gen-keys", "-f"), ("setup-tls", "-f"), ("setup-auth", "-f")],
    ids=" ".join,
)
def test_a_running_stack_refuses(args):
    before = {name: digest(SECRETS / name) for name in STACK_SECRETS}
    done = prod(*args, stdin="yes\n")
    assert done.returncode == 1
    assert done.stdout.strip().endswith(STACK_IS_RUNNING)
    assert {name: digest(SECRETS / name) for name in STACK_SECRETS} == before
    assert AUTH_DB.is_file()


def test_setup_makes_nothing_under_a_running_stack():
    with lost(SECRETS / "wg_private_key"), lost(SECRETS / "wg_public_key"):
        done = prod("setup")
        assert not (SECRETS / "wg_private_key").exists()
    assert done.returncode == 1
    assert done.stdout.strip().endswith(STACK_IS_RUNNING)


def test_down_stops_the_stack():
    done = prod("down")
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Stopped.")
    assert call("/")[0] == 0


def test_restart_needs_a_running_stack():
    done = prod("restart")
    assert done.returncode == 1
    assert done.stdout.strip().endswith("The stack is not running. Start it: ./tools/prod.sh up")


# ── Arguments ───────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("args", "usage"),
    [
        (("gen-keys", "--nope"), "gen-keys [-f]"),
        (("status", "--help"), "status"),
        (("down", "extra"), "down"),
        (("exec", "daemon"), "exec <service> <command>"),
        (("hard-reset", "--force"), "hard-reset"),
    ],
    ids=["gen-keys", "status", "down", "exec", "hard-reset"],
)
def test_bad_arguments_stop_with_the_usage(args, usage):
    done = prod(*args)
    assert done.returncode == 1
    assert done.stdout.strip() == f"Usage: ./tools/prod.sh {usage}"


# ── Starting over ───────────────────────────────────────────────────


def test_hard_reset_needs_yes():
    done = prod("hard-reset", stdin="no\n")
    assert done.returncode == 1
    assert "Aborted." in done.stdout
    assert AUTH_DB.is_file()


def test_hard_reset_clears_the_host_and_keeps_its_local_files():
    SUBNET_FILE.write_text("10.9.0.0/24\n", encoding="utf-8")
    done = prod("hard-reset", stdin="yes\n", timeout=LONG)
    assert done.returncode == 0, done.stdout
    for name in BOUND:
        assert not [path.name for path in (ROOT / name).iterdir() if path.name != ".gitkeep"], name
    assert not APPLIED.exists()
    assert not SUBNET_FILE.exists()
    for name in LOCAL_FILES:
        assert (ROOT / name).is_file(), name


def test_a_chosen_subnet_reaches_the_daemon():
    done = prod("setup", "--terazi-ipv4-subnet=10.9.0.0/24", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert SUBNET_FILE.read_text(encoding="utf-8").strip() == "10.9.0.0/24"

    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert not SUBNET_FILE.exists()
    status, data = api_answers(logged_in(), "/api/core/network")
    assert status == 200
    assert data["data"]["ipv4_subnet"] == "10.9.0.0/24"
    assert prod("down").returncode == 0


# ── Owners of files and directories ─────────────────────────────────


def test_what_setup_wrote_belongs_to_the_operator():
    assert_the_operator_owns_the_host()
    for name in SECRET_FILES:
        assert (SECRETS / name).stat().st_mode & 0o777 == 0o600, name


@linux_only
def test_hard_reset_wipes_what_the_containers_left_as_root():
    assert prod("up", timeout=LONG).returncode == 0
    assert api_answers(logged_in())[0] == 200
    assert prod("down").returncode == 0
    assert (ROOT / "container-data/db/wallet.db").stat().st_uid == 0
    assert [path for path in (ROOT / "container-data/state/db").rglob("*") if path.stat().st_uid == 0]

    done = prod("hard-reset", stdin="yes\n", timeout=LONG)
    assert done.returncode == 0, done.stdout
    for name in BOUND:
        assert only_gitkeep(name), name


def test_setup_makes_the_directories_a_package_lacks():
    assert prod("hard-reset", stdin="yes\n", timeout=LONG).returncode == 0
    directories = (SECRETS, AUTH_DB.parent)
    for directory in directories:
        shutil.rmtree(directory)
    try:
        done = prod("setup", timeout=LONG)
        assert done.returncode == 0, done.stdout
        assert_the_operator_owns_the_host()
    finally:
        for directory in directories:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / ".gitkeep").touch()


@linux_only
def test_hard_reset_wipes_the_directories_docker_made():
    directories = (ROOT / "container-data/db", ROOT / "container-data/state/db")
    for directory in directories:
        shutil.rmtree(directory)
    try:
        assert prod("up", timeout=LONG).returncode == 0
        assert api_answers(logged_in())[0] == 200
        assert prod("down").returncode == 0
        assert [directory.stat().st_uid for directory in directories] == [0, 0]
        assert list(directories[0].iterdir())

        done = prod("hard-reset", stdin="yes\n", timeout=LONG)
        assert done.returncode == 0, done.stdout
        assert not [path for directory in directories for path in directory.iterdir()]
    finally:
        sudo("chown", "-R", OPERATOR, *(str(directory) for directory in directories))
        for directory in directories:
            (directory / ".gitkeep").touch()


@linux_only
def test_setup_under_sudo_leaves_the_host_to_the_operator():
    assert prod("hard-reset", stdin="yes\n", timeout=LONG).returncode == 0
    for name in LOCAL_FILES:
        (ROOT / name).unlink()
    done = sudo(ENTRY, "setup")
    assert done.returncode == 0, done.stdout
    assert_the_operator_owns_the_host()
    assert prod("gen-keys", "-f", timeout=LONG).returncode == 0


@linux_only
def test_a_secret_of_root_stops_with_a_message():
    path = SECRETS / "wg_private_key"
    sudo("chown", "root:root", str(path))
    try:
        done = prod("gen-keys", "-f", timeout=LONG)
    finally:
        sudo("chown", OPERATOR, str(path))
    assert done.returncode == 1
    assert "Permission denied" in done.stdout
    assert "Traceback" not in done.stdout
