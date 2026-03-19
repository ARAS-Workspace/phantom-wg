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

Environment variable loading for daemon operational parameters.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class DaemonEnv:
    """Immutable container for daemon environment configuration."""

    db_dir: str
    state_dir: str
    listen_port: int
    mtu: int
    keepalive: int
    endpoint_v4: str
    endpoint_v6: str


def load_env() -> DaemonEnv:
    """Load daemon configuration from environment variables with defaults."""
    return DaemonEnv(
        db_dir=os.environ.get("PHANTOM_DB_DIR", "/var/lib/phantom/db"),
        state_dir=os.environ.get("PHANTOM_STATE_DIR", "/var/lib/phantom/state/db"),
        listen_port=int(os.environ.get("WIREGUARD_LISTEN_PORT", "51820")),
        mtu=int(os.environ.get("WIREGUARD_MTU", "1420")),
        keepalive=int(os.environ.get("WIREGUARD_KEEPALIVE", "25")),
        endpoint_v4=os.environ.get("WIREGUARD_ENDPOINT_V4", ""),
        endpoint_v6=os.environ.get("WIREGUARD_ENDPOINT_V6", ""),
    )
