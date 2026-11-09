"""What a user does on a production host, on the real stack, from the outside.

DESTRUCTIVE: every run wipes the stack, its volumes, container-data and the local
files of this tree, and the development stack shares them. It stops when a
phantom container runs. It runs only when named, top to bottom, each test on what
the last left:

    pytest tests/integration_tests/prod -x -s
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import threading
import time

import pytest
from prod_host import (
    AUTH_DB,
    AUTH_SOURCE,
    BOUND,
    COMMANDS,
    ENTRY,
    LOCAL_FILES,
    LONG,
    OPERATOR,
    ROOT,
    SECRET_FILES,
    SECRETS,
    SERVICES,
    STACK_IS_RUNNING,
    STACK_SECRETS,
    WALLET,
    api_answers,
    assert_the_operator_owns_the_host,
    call,
    code_version,
    digest,
    emptied,
    linux_only,
    logged_in,
    lost,
    only_gitkeep,
    prod,
    sudo,
    superadmins,
    wipe_the_tree,
)

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
    assert not WALLET.exists()
    assert not (ROOT / ".env").exists()


def test_setup_takes_the_admin_username():
    done = prod("setup", "--admin-username", "e2e-root", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert superadmins() == ["e2e-root"]
    wipe_the_tree()


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
    assert superadmins() == ["admin"]


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


def test_setup_auth_force_takes_the_admin_username():
    done = prod("setup-auth", "-f", "--admin-username", "e2e-root", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert superadmins() == ["e2e-root"]
    done = prod("setup-auth", "-f", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert superadmins() == ["admin"]


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
        (("status", "--nope"), "status"),
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


@pytest.mark.parametrize(
    "args",
    [("help", "gen-keys"), ("gen-keys", "--help"), ("gen-keys", "-h")],
    ids=["help-command", "long-flag", "short-flag"],
)
def test_a_command_shows_its_usage_and_does_not_run(args):
    before = digest(SECRETS / "wg_private_key")
    done = prod(*args)
    assert done.returncode == 0
    assert done.stdout == "Usage: ./tools/prod.sh gen-keys [-f]\n\n  Generate WireGuard keypair\n"
    assert digest(SECRETS / "wg_private_key") == before


# ── Starting over ───────────────────────────────────────────────────


def test_hard_reset_needs_yes():
    done = prod("hard-reset", stdin="no\n")
    assert done.returncode == 1
    assert "Aborted." in done.stdout
    assert AUTH_DB.is_file()


def test_hard_reset_clears_the_host_and_keeps_its_local_files():
    done = prod("hard-reset", stdin="yes\n", timeout=LONG)
    assert done.returncode == 0, done.stdout
    for name in BOUND:
        assert not [path.name for path in (ROOT / name).iterdir() if path.name != ".gitkeep"], name
    for name in LOCAL_FILES:
        assert (ROOT / name).is_file(), name


def test_a_chosen_subnet_reaches_the_daemon():
    done = prod("setup", "--terazi-ipv4-subnet=10.9.0.0/24", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "Pool: 10.9.0.0/24" in done.stdout
    assert WALLET.is_file()

    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    status, data = api_answers(logged_in(), "/api/core/network")
    assert status == 200
    assert data["data"]["ipv4_subnet"] == "10.9.0.0/24"
    assert prod("down").returncode == 0


def test_a_wallet_keeps_its_subnet():
    with lost(ROOT / ".env"):
        done = prod("setup", "--terazi-ipv4-subnet=10.10.0.0/24", timeout=LONG)
    assert done.returncode == 1
    assert "wallet.db exists, its subnet is fixed." in done.stdout


def test_up_needs_the_wallet():
    with lost(WALLET):
        done = prod("up", timeout=LONG)
    assert done.returncode == 1
    assert "Missing: container-data/db/wallet.db" in done.stdout


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
    directories = (SECRETS, AUTH_DB.parent, WALLET.parent)
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
    directories = (ROOT / "container-data/state/db",)
    for directory in directories:
        shutil.rmtree(directory)
    try:
        assert prod("up", timeout=LONG).returncode == 0
        assert api_answers(logged_in())[0] == 200
        assert prod("down").returncode == 0
        assert [directory.stat().st_uid for directory in directories] == [0]
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
