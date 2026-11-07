"""What the production flows share: the host, its commands and its API."""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
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
WALLET = ROOT / "container-data/db/wallet.db"
SPA_INDEX = ROOT / "services/react-spa/dist/index.html"
ENV_DAEMON = ROOT / ".env.daemon"
BOUND = ("container-data/db", "container-data/state/db", "container-data/auth-db", "container-data/secrets/production")
LOCAL_FILES = (".env", ".env.daemon", ".env.auth-service", "docker-compose.override.yml")
STACK_SECRETS = ("wg_private_key", "wg_public_key", "auth_signing_key", "auth_verify_key", "tls_cert", "tls_key")
SECRET_FILES = (*STACK_SECRETS, ".admin_password")
COMMANDS = (
    "setup", "gen-keys", "setup-auth", "setup-tls", "certbot", "up", "down", "restart", "logs", "status",
    "show-versions", "shell", "exec", "hard-reset", "gates", "images", "pull", "build", "rebuild", "update",
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
    """The local files go first: the wipe takes its image from the default source, whatever a test selected."""
    prod("down")
    for name in LOCAL_FILES:
        (ROOT / name).unlink(missing_ok=True)
    done = prod("hard-reset", stdin="yes\n", timeout=LONG)
    assert done.returncode == 0, done.stdout


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
        SECRETS, AUTH_DB.parent, AUTH_DB,
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
