"""Shared fixtures for unit tests.

Each pytest session creates a self-contained UnitTestEnvironment with:
- fresh wallet database
- random listen port (51800-51899)
- isolated state directory
- server key pair

Run with -s to see paths:
    pytest tests/unit/ -s
"""

from __future__ import annotations

import functools
import os
import random
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import pytest
from wireguard_go_bridge.keys import derive_public_key, generate_private_key

from phantom_daemon.base.env import DaemonEnv
from phantom_daemon.base.secrets.secrets import ServerKeys
from phantom_daemon.base.wallet import Wallet, create_wallet

# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)

_DB_DIR = "/var/lib/phantom/db/tests"
_STATE_DIR = "/var/lib/phantom/state/db/tests"


@dataclass
class UnitTestEnvironment:
    """Self-contained unit test session environment."""

    wallet: Wallet
    env: DaemonEnv
    server_keys: ServerKeys
    state_dir: str

    def sub(self, name: str) -> str:
        """Create and return an isolated sub-directory under state_dir."""
        s = Path(self.state_dir) / name
        s.mkdir(parents=True, exist_ok=True)
        return str(s)


@pytest.fixture(scope="session")
def test_env():
    """Session-scoped unit test environment."""
    ts = datetime.now(UTC).strftime("%Y%m%dT%H%M%S")
    port = random.randint(51800, 51899)

    # Wallet
    os.makedirs(_DB_DIR, exist_ok=True)
    db_name = f"unit-{ts}.db"
    db_path = os.path.join(_DB_DIR, db_name)
    print(f"\n  Unit Test DB: {db_path}")
    w = create_wallet(db_dir=_DB_DIR, db_name=db_name)

    # State dir
    state_dir = os.path.join(_STATE_DIR, f"unit-{ts}")
    os.makedirs(state_dir, exist_ok=True)
    print(f"\n  Unit State Dir: {state_dir}")
    print(f"\n  Unit Listen Port: {port}")

    # Env
    env = DaemonEnv(
        db_dir=_DB_DIR,
        state_dir=state_dir,
        listen_port=port,
        mtu=1420,
        keepalive=25,
        endpoint_v4="",
        endpoint_v6="",
    )

    # Server keys
    priv = generate_private_key()
    pub = derive_public_key(priv)
    server_keys = ServerKeys(private_key_hex=priv, public_key_hex=pub)

    yield UnitTestEnvironment(
        wallet=w, env=env, server_keys=server_keys, state_dir=state_dir,
    )

    print(f"\n  DB preserved: {db_path}")
    w.close()
