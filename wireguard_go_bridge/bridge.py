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

Bridge — PersistentDevice Python wrapper.

A Bridge requires a pre-existing device.db to start. The DB holds
the IPC state dump that wireguard-go uses. On creation, previous
state is automatically restored. Every ipc_set call persists the
device state, without the fields filterIpcDump removes, to DB.

Usage:
    bridge = WireGuardBridge(ifname="wg0", mtu=1420, db_path="/path/to/device.db")
    bridge.ipc_set("private_key=HEX\\nlisten_port=51820\\n")
    bridge.up()
    ...
    bridge.down()
    bridge.close()
"""

from __future__ import annotations

import os
from types import TracebackType
from typing import Optional, Type

from ._ffi import get_lib, _read_and_free, last_error
from .types import BridgeError, IpcError, check_result


class WireGuardBridge:
    """WireGuard PersistentDevice — thin wrapper over Go FFI.

    The device.db must exist before creating a WireGuardBridge.
    Python (daemon) is responsible for creating the DB with the ipc_state table.
    Go opens it, restores state if available, and persists on every IpcSet.
    """

    __slots__ = ("_lib", "_handle")

    def __init__(self, ifname: str, mtu: int, db_path: str) -> None:
        if not os.path.isfile(db_path):
            raise FileNotFoundError(f"device.db not found: {db_path}")

        self._lib = get_lib()
        self._handle: int = self._lib.NewPersistentDevice(
            ifname.encode("utf-8"),
            mtu,
            db_path.encode("utf-8"),
        )
        self._check(self._handle)

    def _check(self, code: int) -> None:
        """Raise the exception of a negative code, with the message the
        bridge recorded for this thread's call."""
        if code < 0:
            check_result(code, last_error(self._lib)[1])

    def ipc_set(self, config: str) -> None:
        """Apply IPC config. Automatically persists full state to DB."""
        self._check(self._lib.DeviceIpcSet(self._handle, config.encode("utf-8")))

    def ipc_get(self) -> str:
        """Read current device state in IPC format."""
        ptr = self._lib.DeviceIpcGet(self._handle)
        if not ptr:
            code, message = last_error(self._lib)
            if code >= 0:
                raise IpcError("DeviceIpcGet returned NULL with no error recorded")
            check_result(code, message)
        return _read_and_free(ptr)

    def up(self) -> None:
        """Activate the device (bring interface up)."""
        self._check(self._lib.DeviceUp(self._handle))

    def down(self) -> None:
        """Deactivate the device (bring interface down)."""
        self._check(self._lib.DeviceDown(self._handle))

    def close(self) -> None:
        """Close device and state DB. The handle is 0 after the call,
        whether DeviceClose succeeded or not."""
        if self._handle > 0:
            handle, self._handle = self._handle, 0
            self._check(self._lib.DeviceClose(handle))

    def __enter__(self) -> WireGuardBridge:
        return self

    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]],
        exc_val: Optional[BaseException],
        exc_tb: Optional[TracebackType],
    ) -> None:
        self.close()

    def __del__(self) -> None:
        if hasattr(self, "_handle") and self._handle > 0:
            try:
                self.close()
            except BridgeError:
                pass

    @property
    def handle(self) -> int:
        return self._handle