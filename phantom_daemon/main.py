"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║s
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

Application factory and Uvicorn runner over Unix Domain Socket.
"""

from __future__ import annotations

import logging
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from phantom_daemon import __version__
from phantom_daemon.base import (
    BackupError,
    ExitStoreError,
    StartupError,
    WalletError,
    WalletFullError,
    load_env,
    load_secrets,
    open_exit_store,
    open_firewall,
    open_wallet,
    open_wireguard,
)
from phantom_daemon.base.services.wireguard import WG_INTERFACE_NAME_EXIT
from phantom_daemon.base.services.wireguard.ipc import build_exit_config
from phantom_daemon.modules import setup_routers

log = logging.getLogger("phantom-daemon")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Daemon startup/shutdown lifecycle."""
    try:
        # Phase 1: secrets
        server_keys = load_secrets()

        # Phase 2: environment + wallet
        env = load_env()
        wallet = open_wallet(db_dir=env.db_dir)

        # Phase 3a: WireGuard bridge
        wg = open_wireguard(state_dir=env.state_dir, mtu=env.mtu)
        wg.fast_sync(wallet=wallet, server_keys=server_keys, env=env)
        wg.up()

        # Phase 3a+: OS-level interface setup
        wg.apply_interface(
            ipv4_subnet=wallet.get_config("ipv4_subnet"),
            ipv6_subnet=wallet.get_config("ipv6_subnet"),
        )

        # Phase 3b: Exit store + optional multihop WG recovery
        # WG exit interface must exist BEFORE firewall start, because
        # fw.start() replays routing rules that reference wg_phantom_exit.
        exit_store = open_exit_store(db_dir=env.db_dir)
        wg_exit = None
        if exit_store.is_enabled():
            active = exit_store.get_active()
            exit_data = exit_store.get_exit(active)
            if exit_data:
                wg_exit = open_wireguard(
                    state_dir=env.state_dir, mtu=env.mtu,
                    ifname=WG_INTERFACE_NAME_EXIT,
                )
                config = build_exit_config(
                    private_key_hex=exit_data["private_key_hex"],
                    peer_public_key_hex=exit_data["public_key_hex"],
                    peer_preshared_key_hex=exit_data["preshared_key_hex"],
                    endpoint=exit_data["endpoint"],
                    allowed_ips=exit_data["allowed_ips"],
                    keepalive=exit_data["keepalive"],
                )
                wg_exit._bridge.ipc_set(config)
                wg_exit.up()
                wg_exit.apply_exit_interface(exit_data["address"])
                log.info("Multihop exit WG recovered: %s", active)

        # Phase 3c: Firewall bridge
        # Must come after WG exit recovery so interface exists for routing rules.
        fw = open_firewall(state_dir=env.state_dir)
        if not fw.list_groups():
            fw.bootstrap(env=env, wallet=wallet)
        fw.start()

        app.state.server_keys = server_keys
        app.state.env = env
        app.state.wallet = wallet
        app.state.wg = wg
        app.state.fw = fw
        app.state.exit_store = exit_store
        app.state.wg_exit = wg_exit
    except StartupError as exc:
        log.critical("Startup failed: %s", exc)
        sys.exit(1)

    yield

    # Use app.state — backup import may have torn down wg_exit mid-flight
    # and set app.state.wg_exit = None while local var still holds old ref.
    live_wg_exit = app.state.wg_exit
    if live_wg_exit is not None:
        live_wg_exit.down()
        live_wg_exit.close()
    exit_store.close()
    fw.stop()
    fw.close()
    wg.down()
    wg.close()
    wallet.close()


def create_app(
    lifespan_func: Optional[object] = lifespan,
) -> FastAPI:
    app = FastAPI(
        title="phantom-daemon",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan_func,
    )
    setup_routers(app)
    _register_error_handlers(app)
    return app


_STATUS_CODES: dict[int, str] = {
    400: "BAD_REQUEST",
    401: "UNAUTHORIZED",
    403: "FORBIDDEN",
    404: "NOT_FOUND",
    405: "METHOD_NOT_ALLOWED",
    409: "CONFLICT",
    422: "VALIDATION_ERROR",
    500: "INTERNAL_ERROR",
    502: "SERVICE_UNAVAILABLE",
    503: "SERVICE_UNAVAILABLE",
}


def _register_error_handlers(app: FastAPI) -> None:
    """Register global exception handlers — all errors return ApiErr envelope with code."""

    @app.exception_handler(HTTPException)
    async def _http_error(_request, exc):
        code = getattr(exc, "code", None) or _STATUS_CODES.get(exc.status_code, "UNKNOWN_ERROR")
        return JSONResponse(
            status_code=exc.status_code,
            content={"ok": False, "error": exc.detail, "code": code},
        )

    @app.exception_handler(BackupError)
    async def _backup_error(_request, exc):
        return JSONResponse(
            status_code=400,
            content={"ok": False, "error": str(exc), "code": "BACKUP_ERROR"},
        )

    @app.exception_handler(ExitStoreError)
    async def _exit_store_error(_request, exc):
        return JSONResponse(
            status_code=400,
            content={"ok": False, "error": str(exc), "code": "EXIT_STORE_ERROR"},
        )

    @app.exception_handler(WalletFullError)
    async def _wallet_full(_request, exc):
        return JSONResponse(
            status_code=409,
            content={"ok": False, "error": str(exc), "code": "WALLET_FULL"},
        )

    @app.exception_handler(WalletError)
    async def _wallet_error(_request, exc):
        return JSONResponse(
            status_code=400,
            content={"ok": False, "error": str(exc), "code": "WALLET_ERROR"},
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(_request, exc):
        return JSONResponse(
            status_code=422,
            content={"ok": False, "error": str(exc), "code": "VALIDATION_ERROR"},
        )


def main() -> None:
    socket_path = "/var/run/phantom-daemon.sock"
    if len(sys.argv) > 1:
        socket_path = sys.argv[1]

    app = create_app()
    uvicorn.run(app, uds=socket_path, log_level="info")


if __name__ == "__main__":
    main()
