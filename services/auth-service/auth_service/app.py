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

FastAPI application factory and lifespan.
"""

from __future__ import annotations

import logging
import sys
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from auth_service import __version__
from auth_service.config import load_auth_config
from auth_service.crypto.keys import build_signing_key, build_verify_key, load_auth_keys
from auth_service.db.repository import open_auth_db, resolve_db_path
from auth_service.middleware.rate_limit import RateLimiter
from auth_service.routes import setup_routers

log = logging.getLogger("phantom-auth")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Auth service startup/shutdown lifecycle."""
    try:
        # Phase 1: Load configuration
        config = load_auth_config()

        # Phase 2: Load signing keys
        keys = load_auth_keys(secrets_dir=config.secrets_dir)
        signing_key = build_signing_key(keys)
        verify_key = build_verify_key(keys)
        log.info("Auth keys loaded")

        # Phase 3: Validate auth database path (must exist — created by tools/setup.sh)
        db_path = resolve_db_path(db_dir=config.db_dir)
        log.info("Auth database ready: %s", db_path)

        # Phase 4: Build httpx client for daemon proxy
        if config.proxy_is_uds:
            transport = httpx.AsyncHTTPTransport(uds=config.proxy_socket_path)
            proxy_client = httpx.AsyncClient(transport=transport, timeout=config.proxy_timeout)
            log.info("Proxy target: UDS %s", config.proxy_socket_path)
        else:
            proxy_client = httpx.AsyncClient(timeout=config.proxy_timeout)
            log.info("Proxy target: HTTP %s", config.proxy_url)

        # Phase 5: Rate limiter
        rate_limiter = RateLimiter(
            window=config.rate_limit_window,
            max_attempts=config.rate_limit_max,
        )

        # Store in app.state
        app.state.config = config
        app.state.keys = keys
        app.state.signing_key = signing_key
        app.state.verify_key = verify_key
        app.state.db_path = db_path
        app.state.proxy_client = proxy_client
        app.state.rate_limiter = rate_limiter
    except Exception as exc:
        log.critical("Auth service startup failed: %s", exc)
        sys.exit(1)

    yield

    await proxy_client.aclose()
    log.info("Auth service stopped")


class _DBMiddleware(BaseHTTPMiddleware):
    """Open a per-request SQLite connection on request.state.db, close after response."""

    async def dispatch(self, request: Request, call_next):
        db = open_auth_db(request.app.state.db_path)
        request.state.db = db
        try:
            response = await call_next(request)
        finally:
            db.close()
        return response


def create_app(
    lifespan_func: Optional[object] = lifespan,
) -> FastAPI:
    """Create the FastAPI application."""
    app = FastAPI(
        title="phantom-auth",
        version=__version__,
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan_func,
    )
    app.add_middleware(_DBMiddleware)
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
    413: "PAYLOAD_TOO_LARGE",
    422: "VALIDATION_ERROR",
    429: "TOO_MANY_REQUESTS",
    500: "INTERNAL_ERROR",
    502: "SERVICE_UNAVAILABLE",
    503: "SERVICE_UNAVAILABLE",
}


def _register_error_handlers(app: FastAPI) -> None:
    """Register global exception handlers — all errors return ApiErr envelope with error_code."""

    @app.exception_handler(HTTPException)
    async def _http_error(_request, exc):
        error_code = getattr(exc, "error_code", None) or _STATUS_CODES.get(
            exc.status_code, "UNKNOWN_ERROR"
        )
        return JSONResponse(
            status_code=exc.status_code,
            content={"ok": False, "error_code": error_code},
        )

    @app.exception_handler(RequestValidationError)
    async def _validation(_request, _exc):
        return JSONResponse(
            status_code=422,
            content={"ok": False, "error_code": "VALIDATION_ERROR"},
        )
