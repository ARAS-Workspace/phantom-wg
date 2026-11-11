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

Where a production installation keeps its data.
"""

from __future__ import annotations

from pathlib import Path

from core import runner

SECRETS_DIR = "container-data/secrets/production"
AUTH_DB_DIR = "container-data/auth-db"
DB_DIR = "container-data/db"
STATE_DIR = "container-data/state/db"
CERTBOT_DIR = "container-data/certbot"
BOUND_DIRS = (SECRETS_DIR, AUTH_DB_DIR, DB_DIR, STATE_DIR, CERTBOT_DIR)
# Configuration of the Cloudflare mode, like the env files: hard-reset leaves it.
CLOUDFLARE_DIR = "container-data/cloudflare"


def filled(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def secrets() -> Path:
    return runner.ROOT / SECRETS_DIR


def auth_db() -> Path:
    return runner.ROOT / AUTH_DB_DIR


def wallet() -> Path:
    return runner.ROOT / DB_DIR / "wallet.db"


def cloudflare() -> Path:
    return runner.ROOT / CLOUDFLARE_DIR
