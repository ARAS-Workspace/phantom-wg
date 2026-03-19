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

Backup endpoints: export (download) and import (upload + restore).
"""

from __future__ import annotations

import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel
from starlette.background import BackgroundTask

from phantom_daemon.base.backup import create_backup_tar, restore_backup_tar
from phantom_daemon.base.services.firewall.service import MULTIHOP_PRESET_NAME
from phantom_daemon.modules._envelope import ApiOk


# ── Models ───────────────────────────────────────────────────────


class RestoreResult(BaseModel):
    """Summary returned after a successful backup restore."""

    timestamp: str
    wallet_clients: int
    wallet_subnet: str
    exit_count: int
    exit_enabled: bool


# ── Router ───────────────────────────────────────────────────────

router = APIRouter(tags=["backup"])


def _cleanup(tar_path: Path) -> None:
    """Remove the temporary backup directory after response is sent."""
    parent = tar_path.parent
    shutil.rmtree(parent, ignore_errors=True)


@router.post(
    "/export",
    summary="Export Backup",
    description="Create and download a portable backup archive (.tar) containing "
    "wallet.db, exit.db, and a JSON manifest. The response is a binary file "
    "stream — save it directly to disk.",
)
async def export_backup(request: Request):
    """Create and download a portable backup (wallet.db + exit.db + manifest)."""
    wallet = request.app.state.wallet
    exit_store = request.app.state.exit_store

    tar_path = create_backup_tar(wallet._conn, exit_store._conn)

    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S")
    filename = f"phantom-backup-{timestamp}.tar"

    return FileResponse(
        path=str(tar_path),
        media_type="application/x-tar",
        filename=filename,
        background=BackgroundTask(_cleanup, tar_path),
    )


@router.post(
    "/import",
    response_model=ApiOk[RestoreResult],
    summary="Import Backup",
    description="Upload a previously exported .tar backup and restore it. "
    "Replaces wallet.db and exit.db, then re-syncs WireGuard peers with the "
    "restored data. If multihop is active, it is torn down automatically before "
    "restore to keep kernel state consistent.",
)
async def import_backup(file: UploadFile, request: Request):
    """Upload and restore a previously exported backup."""
    wallet = request.app.state.wallet
    exit_store = request.app.state.exit_store
    wg_exit = request.app.state.wg_exit

    # Teardown multihop before restore — DB will be replaced with
    # multihop disabled, kernel state must be consistent.
    if wg_exit is not None:
        try:
            fw = request.app.state.fw
            fw.remove_preset(MULTIHOP_PRESET_NAME)
        except (RuntimeError, OSError, AttributeError):
            pass
        try:
            wg_exit.down()
        except (RuntimeError, OSError):
            pass
        wg_exit.close()
        request.app.state.wg_exit = None

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".tar")
    try:
        content = await file.read()
        tmp.write(content)
        tmp.close()

        manifest = restore_backup_tar(
            Path(tmp.name), wallet._conn, exit_store._conn
        )
    finally:
        Path(tmp.name).unlink(missing_ok=True)

    # Re-sync WireGuard peers with restored wallet — IPC state must
    # match the new database, just like daemon startup (fast_sync).
    wg = request.app.state.wg
    server_keys = request.app.state.server_keys
    env = request.app.state.env
    wg.fast_sync(wallet=wallet, server_keys=server_keys, env=env)

    wallet_info = manifest.get("wallet", {})
    exit_info = manifest.get("exit_store", {})

    return ApiOk(data=RestoreResult(
        timestamp=manifest.get("timestamp", ""),
        wallet_clients=wallet_info.get("clients", 0),
        wallet_subnet=wallet_info.get("subnet", ""),
        exit_count=exit_info.get("exits", 0),
        exit_enabled=exit_info.get("enabled", False),
    ))
