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

The auth service of this host: its keys and its database.
"""

from __future__ import annotations

import time
from pathlib import Path

from core import runner
from core.runner import ToolError
from stack.prod.libs import compose, identity, images, paths

AUTH_DIR = "services/auth-service"
SERVICE = "auth-service"
DEFAULT_USERNAME = "admin"
DATABASE_SUFFIXES = ("", "-wal", "-shm")
KEY_FILES = ("auth_signing_key", "auth_verify_key")
PRIVATE_FILES = (*KEY_FILES, ".admin_password")


def database() -> Path:
    return paths.auth_db() / "auth.db"


def bootstrapped() -> bool:
    return database().is_file() and all(paths.filled(paths.secrets() / name) for name in KEY_FILES)


def archive() -> str:
    """Moves auth.db aside, with its journal. Returns the new name."""
    target = f"auth.db.{time.strftime('%Y%m%d-%H%M%S')}.bak"
    source = database()
    for suffix in DATABASE_SUFFIXES:
        path = source.with_name(source.name + suffix)
        if path.is_file():
            path.rename(source.with_name(target + suffix))
    return f"{paths.AUTH_DB_DIR}/{target}"


def ready() -> str:
    """What a bootstrap needs, before anything changes. Returns the image."""
    compose.require_down()
    if not (runner.ROOT / AUTH_DIR).is_dir():
        raise ToolError(f"auth-service not found at {AUTH_DIR}/")
    return images.ensure(SERVICE)


def bootstrap(image: str, username: str = DEFAULT_USERNAME) -> None:
    identity.make_dir(paths.secrets())
    identity.make_dir(paths.auth_db())

    print("Bootstrapping auth service...")
    runner.stream([
        "docker", "run", "--rm", *identity.as_operator(),
        "-v", f"{paths.secrets()}:/secrets",
        "-v", f"{paths.auth_db()}:/db",
        "-v", f"{runner.ROOT / AUTH_DIR}/tools/bootstrap.py:/tmp/bootstrap.py:ro",
        image,
        "python", "/tmp/bootstrap.py",
        "--secrets-dir", "/secrets",
        "--db-dir", "/db",
        "--admin-username", username,
    ])

    for name in PRIVATE_FILES:
        (paths.secrets() / name).chmod(0o600)

    print("Auth service bootstrapped.")
    print(f"  Keys:     {paths.SECRETS_DIR}/")
    print(f"  DB:       {paths.AUTH_DB_DIR}/auth.db")
    print(f"  Password: {paths.SECRETS_DIR}/.admin_password")


def first_bootstrap(username: str = DEFAULT_USERNAME) -> None:
    """The bootstrap of setup: it leaves an auth.db it finds to setup-auth -f."""
    if database().is_file():
        raise ToolError(f"{paths.AUTH_DB_DIR}/auth.db exists without its keys. Use -f to start over.")
    bootstrap(ready(), username)
