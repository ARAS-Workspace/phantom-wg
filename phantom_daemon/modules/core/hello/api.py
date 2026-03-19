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

Health-check endpoint.
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from phantom_daemon.modules._envelope import ApiOk


class HelloResponse(BaseModel):
    """Daemon health status."""

    message: str
    version: str


router = APIRouter(tags=["hello"])


@router.get(
    "",
    response_model=ApiOk[HelloResponse],
    summary="Health Check",
    description="Returns daemon status and version. Use this endpoint to verify "
    "that the daemon process is running and reachable.",
)
async def hello():
    from phantom_daemon import __version__

    return ApiOk(data=HelloResponse(
        message="phantom-daemon is running",
        version=__version__,
    ))


@router.get("/openapi", include_in_schema=False)
async def openapi_schema(request: Request):
    """Serve the generated OpenAPI 3.1 JSON schema (hidden from spec itself)."""
    return JSONResponse(content=request.app.openapi())
