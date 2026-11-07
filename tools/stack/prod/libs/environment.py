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

What setup leaves behind and the stack needs.
"""

from __future__ import annotations

import shutil

from core import runner
from core.runner import ToolError
from stack.prod.libs import auth, identity, paths

LOCAL_FILES = (".env", ".env.daemon", ".env.auth-service", "docker-compose.override.yml")
SECRET_FILES = ("wg_private_key", "wg_public_key", "auth_signing_key", "auth_verify_key", "tls_cert", "tls_key")


def missing() -> list[str]:
    found = [name for name in LOCAL_FILES if not (runner.ROOT / name).is_file()]
    found += [f"{paths.SECRETS_DIR}/{name}" for name in SECRET_FILES if not paths.filled(paths.secrets() / name)]
    if not auth.database().is_file():
        found.append(f"{paths.AUTH_DB_DIR}/auth.db")
    if not paths.wallet().is_file():
        found.append(f"{paths.DB_DIR}/wallet.db")
    return found


def require() -> None:
    found = missing()
    if found:
        lines = [f"Missing: {name}" for name in found]
        raise ToolError("\n".join([*lines, "Run './tools/prod.sh setup' first."]))


def bootstrap() -> None:
    """The local files of this host, each from its example."""
    for name in LOCAL_FILES:
        target = runner.ROOT / name
        example = runner.ROOT / f"{name}.example"
        if target.is_file():
            print(f"  {name} already exists, skipping.")
        elif example.is_file():
            shutil.copy2(example, target)
            identity.own(target)
            print(f"Created {name} from {example.name}")
        else:
            raise ToolError(f"Missing {example.name}")
