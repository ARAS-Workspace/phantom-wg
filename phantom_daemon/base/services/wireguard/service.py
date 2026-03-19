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

WireGuard service lifecycle — device DB, bridge wrapper, wallet sync.
"""

from __future__ import annotations

import importlib.resources
import ipaddress
import logging
import sqlite3
import subprocess
from pathlib import Path
from typing import TYPE_CHECKING, Optional, Type

from phantom_daemon.base.errors import WireGuardError
from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME
from phantom_daemon.base.services.wireguard.ipc import (
    DeviceStatus,
    build_full_config,
    build_peer_config,
    build_peer_remove_config,
    parse_device_status,
    parse_ipc_peers,
)

if TYPE_CHECKING:
    from wireguard_go_bridge import WireGuardBridge

    from phantom_daemon.base.env import DaemonEnv
    from phantom_daemon.base.secrets.secrets import ServerKeys
    from phantom_daemon.base.wallet.wallet import Wallet

log = logging.getLogger("phantom-daemon")


# ── Device DB ────────────────────────────────────────────────────


def _read_schema() -> str:
    """Read schema.sql from package resources."""
    ref = importlib.resources.files("phantom_daemon.base.services.wireguard").joinpath(
        "schema.sql"
    )
    return ref.read_text(encoding="utf-8")


def _ensure_device_db(state_dir: str) -> Path:
    """Create device.db if it does not exist, return its path."""
    dir_path = Path(state_dir)
    if not dir_path.is_dir():
        raise WireGuardError(f"State directory does not exist: {state_dir}")

    db_path = dir_path / "device.db"
    if not db_path.exists():
        conn = sqlite3.connect(str(db_path))
        try:
            conn.executescript(_read_schema())
            conn.commit()
        finally:
            conn.close()

    return db_path


# ── Helpers ─────────────────────────────────────────────────────


def _server_address(subnet: str) -> str:
    """Compute server address (first host) from subnet string."""
    net = ipaddress.ip_network(subnet)
    return f"{net.network_address + 1}/{net.prefixlen}"


# ── Service ──────────────────────────────────────────────────────


class WireGuardService:
    """WireGuard bridge lifecycle and wallet synchronisation."""

    __slots__ = ("_bridge", "_db_path", "_ifname")

    def __init__(self, bridge: WireGuardBridge, db_path: Path, ifname: str) -> None:
        self._bridge = bridge
        self._db_path = db_path
        self._ifname = ifname

    def fast_sync(
        self,
        wallet: Wallet,
        server_keys: ServerKeys,
        env: DaemonEnv,
    ) -> tuple[int, int]:
        """Wallet to IPC reconciliation.

        Strategy: replace_peers=true full config rebuild.
        Wallet is authoritative — all clients are read from wallet,
        IPC state is completely rewritten.

        Returns (wallet_peer_count, ipc_peer_count_before_sync).
        """
        clients = wallet.list_clients()
        wallet_count = len(clients)

        ipc_before = self._bridge.ipc_get()
        ipc_peers_before = parse_ipc_peers(ipc_before)
        ipc_count = len(ipc_peers_before)

        config = build_full_config(
            private_key_hex=server_keys.private_key_hex,
            listen_port=env.listen_port,
            clients=clients,
            keepalive=env.keepalive,
        )
        self._bridge.ipc_set(config)

        log.info(
            "fast_sync: wallet=%d peers, ipc_before=%d peers",
            wallet_count,
            ipc_count,
        )
        return wallet_count, ipc_count

    def get_status(self) -> DeviceStatus:
        """Full device status — wg show equivalent."""
        dump = self._bridge.ipc_get()
        return parse_device_status(dump)

    def add_peer(self, client: dict, keepalive: int) -> None:
        """Add a single peer to the IPC device.

        Accepts a wallet client dict (assign_client output).
        """
        config = build_peer_config(
            public_key_hex=client["public_key_hex"],
            preshared_key_hex=client["preshared_key_hex"],
            ipv4_address=client["ipv4_address"],
            ipv6_address=client["ipv6_address"],
            keepalive=keepalive,
        )
        self._bridge.ipc_set(config)
        log.info("add_peer: %s", client["public_key_hex"][:8])

    def remove_peer(self, public_key_hex: str) -> None:
        """Remove a single peer from the IPC device."""
        config = build_peer_remove_config(public_key_hex)
        self._bridge.ipc_set(config)
        log.info("remove_peer: %s", public_key_hex[:8])

    def apply_interface(self, ipv4_subnet: str, ipv6_subnet: str) -> None:
        """Bring interface UP and assign server addresses.

        Raises WireGuardError on link/addr failure.
        IPv6 failure tolerated (warning only).
        """
        try:
            server_v4 = _server_address(ipv4_subnet)
            server_v6 = _server_address(ipv6_subnet)
            subprocess.run(["ip", "link", "set", self._ifname, "up"], check=True)
            subprocess.run(
                ["ip", "addr", "add", server_v4, "dev", self._ifname], check=True,
            )
            try:
                subprocess.run(
                    ["ip", "-6", "addr", "add", server_v6, "dev", self._ifname],
                    check=True,
                )
            except subprocess.CalledProcessError:
                log.warning("IPv6 address assignment failed — continuing IPv4-only")
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(
                f"Interface setup failed: {exc.cmd} exit={exc.returncode}"
            ) from exc

    def apply_exit_interface(self, address: str) -> None:
        """Bring exit interface UP and assign address.

        address should include prefix (e.g. '10.0.0.2/32').
        Raises WireGuardError on failure.
        """
        try:
            subprocess.run(["ip", "link", "set", self._ifname, "up"], check=True)
            subprocess.run(
                ["ip", "addr", "add", address, "dev", self._ifname], check=True,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(
                f"Exit interface setup failed: {exc.cmd} exit={exc.returncode}"
            ) from exc

    def update_exit_address(self, address: str) -> None:
        """Flush and re-assign exit interface address.

        Raises WireGuardError on failure.
        """
        try:
            subprocess.run(["ip", "addr", "flush", "dev", self._ifname], check=True)
            subprocess.run(
                ["ip", "addr", "add", address, "dev", self._ifname], check=True,
            )
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(
                f"Exit address update failed: {exc.cmd} exit={exc.returncode}"
            ) from exc

    def update_addresses(self, ipv4_subnet: str, ipv6_subnet: str) -> None:
        """Flush and re-assign addresses (for CIDR change).

        Raises WireGuardError on failure. IPv6 tolerated.
        """
        try:
            subprocess.run(["ip", "addr", "flush", "dev", self._ifname], check=True)
            server_v4 = _server_address(ipv4_subnet)
            server_v6 = _server_address(ipv6_subnet)
            subprocess.run(
                ["ip", "addr", "add", server_v4, "dev", self._ifname], check=True,
            )
            try:
                subprocess.run(
                    ["ip", "-6", "addr", "add", server_v6, "dev", self._ifname],
                    check=True,
                )
            except subprocess.CalledProcessError:
                log.warning("IPv6 address assignment failed — continuing IPv4-only")
        except subprocess.CalledProcessError as exc:
            raise WireGuardError(
                f"Address update failed: {exc.cmd} exit={exc.returncode}"
            ) from exc

    def up(self) -> None:
        """Activate the WireGuard device."""
        self._bridge.up()

    def down(self) -> None:
        """Deactivate the WireGuard device."""
        self._bridge.down()

    def close(self) -> None:
        """Close the bridge and release resources."""
        self._bridge.close()

    def __enter__(self) -> WireGuardService:
        return self

    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]],
        exc_val: Optional[BaseException],
        exc_tb: Optional[object],
    ) -> None:
        self.close()


# ── Factory ──────────────────────────────────────────────────────


def open_wireguard(
    state_dir: str,
    mtu: int,
    ifname: str = WG_INTERFACE_NAME,
) -> WireGuardService:
    """Create device DB if needed, instantiate bridge, return service.

    State layout: {state_dir}/wireguard/{ifname}/device.db
    """
    if not Path(state_dir).is_dir():
        raise WireGuardError(f"State directory does not exist: {state_dir}")
    wg_dir = Path(state_dir) / "wireguard" / ifname
    wg_dir.mkdir(parents=True, exist_ok=True)
    try:
        db_path = _ensure_device_db(str(wg_dir))
    except WireGuardError:
        raise
    except Exception as exc:
        raise WireGuardError(f"Failed to prepare device DB: {exc}") from exc

    try:
        from wireguard_go_bridge import WireGuardBridge

        bridge = WireGuardBridge(ifname=ifname, mtu=mtu, db_path=str(db_path))
    except Exception as exc:
        raise WireGuardError(f"Failed to create WireGuard bridge: {exc}") from exc

    return WireGuardService(bridge=bridge, db_path=db_path, ifname=ifname)
