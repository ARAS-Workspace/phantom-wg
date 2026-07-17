"""Fixtures for wallet-backed API integration tests.

Each pytest session creates a self-contained TestEnvironment with:
- fresh wallet database
- random listen port (51800-51899)
- isolated state directory
- WireGuard bridge instance
- server key pair

The database is preserved after the session for inspection.

Run with -s to see the DB path:
    pytest tests/modules/core/ -s
"""

from __future__ import annotations

import functools
import hashlib
import os
import random
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from phantom_daemon.base.env import DaemonEnv
from phantom_daemon.base.secrets.secrets import ServerKeys
from phantom_daemon.base.exit_store import ExitStore, open_exit_store
from phantom_daemon.base.wallet import Wallet, open_wallet
from phantom_daemon.base.services.firewall.service import FirewallService, open_firewall
from phantom_daemon.base.services.wireguard.service import WireGuardService, open_wireguard
from phantom_daemon.main import create_app
from wireguard_go_bridge.keys import generate_private_key, derive_public_key

# noinspection PyShadowingBuiltins
print = functools.partial(print, flush=True)

_DB_DIR = "/var/lib/phantom/db/tests"
_STATE_DIR = "/var/lib/phantom/state/db/tests"


@dataclass
class TestEnvironment:
    """Self-contained test session environment."""

    wallet: Wallet
    env: DaemonEnv
    wg: WireGuardService
    fw: FirewallService
    server_keys: ServerKeys
    exit_store: ExitStore


@pytest.fixture(scope="session")
def test_env():
    """Session-scoped environment — wallet, env, wg, server_keys."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    port = random.randint(51800, 51899)

    # Wallet
    os.makedirs(_DB_DIR, exist_ok=True)
    db_name = f"api-{ts}.db"
    db_path = os.path.join(_DB_DIR, db_name)
    print(f"\n  API Test DB: {db_path}")
    w = open_wallet(db_dir=_DB_DIR, db_name=db_name)
    w.close()
    conn = sqlite3.connect(db_path, check_same_thread=False)
    wallet = Wallet(conn, Path(db_path))

    # Env
    state_dir = os.path.join(_STATE_DIR, f"api-{ts}")
    os.makedirs(state_dir, exist_ok=True)
    print(f"\n  API State Dir: {state_dir}")
    print(f"\n  API Listen Port: {port}")
    env = DaemonEnv(
        db_dir=_DB_DIR,
        state_dir=state_dir,
        listen_port=port,
        mtu=1420,
        keepalive=25,
        endpoint_v4="",
        endpoint_v6="",
    )

    # WireGuard
    tag = hashlib.md5(ts.encode()).hexdigest()[:6]
    wg = open_wireguard(state_dir=env.state_dir, mtu=env.mtu, ifname=f"wg_t_{tag}")

    # Firewall — deliberately not started. bootstrap/resync then write to
    # the bridge DB only, so module tests never touch the live nft table
    # they share with the daemon running in this container.
    #
    # The bridge opens its SQLite with the default check_same_thread=True and
    # exposes no way to pass otherwise, so it is bound to the thread that
    # created it. Production satisfies that — lifespan and the async handlers
    # all run on the event loop thread — but TestClient drives the app from a
    # portal thread. Swap the connection the same way wallet and exit_store
    # above do; the reach-in is the price of not mocking the bridge.
    fw = open_firewall(state_dir=env.state_dir)
    fw_db_path = os.path.join(env.state_dir, "firewall.db")
    fw._bridge._db._conn.close()
    fw_conn = sqlite3.connect(fw_db_path, check_same_thread=False)
    fw_conn.row_factory = sqlite3.Row
    fw._bridge._db._conn = fw_conn

    # Server keys
    priv = generate_private_key()
    pub = derive_public_key(priv)
    server_keys = ServerKeys(private_key_hex=priv, public_key_hex=pub)

    # Exit store (same thread-safety pattern as wallet)
    exit_db_name = f"exit-api-{ts}.db"
    es = open_exit_store(db_dir=_DB_DIR, db_name=exit_db_name)
    es.close()
    exit_db_path = os.path.join(_DB_DIR, exit_db_name)
    exit_conn = sqlite3.connect(exit_db_path, check_same_thread=False)
    exit_store = ExitStore(exit_conn, Path(exit_db_path))

    yield TestEnvironment(
        wallet=wallet, env=env, wg=wg, fw=fw, server_keys=server_keys,
        exit_store=exit_store,
    )

    fw.close()
    wg.down()
    wg.close()
    exit_store.close()
    print(f"\n  DB preserved: {db_path}")
    wallet.close()


@pytest.fixture()
def client(test_env):
    """ASGI test client with full environment on app.state."""
    app = create_app(lifespan_func=None)
    app.state.wallet = test_env.wallet
    app.state.wg = test_env.wg
    app.state.fw = test_env.fw
    app.state.env = test_env.env
    app.state.server_keys = test_env.server_keys
    app.state.exit_store = test_env.exit_store
    app.state.wg_exit = None
    with TestClient(app) as c:
        yield c
