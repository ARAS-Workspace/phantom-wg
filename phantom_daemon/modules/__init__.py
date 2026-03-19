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

Auto-discovery engine for API modules. Scans api.py files under modules/,
finds router attributes and mounts them to the FastAPI application with
calculated prefixes.
"""

from __future__ import annotations

import importlib
import logging
import pkgutil
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fastapi import FastAPI

logger = logging.getLogger(__name__)

_PACKAGE = "phantom_daemon.modules"


def _module_to_prefix(dotted_name: str) -> str:
    """Convert dotted module path to URL prefix.

    phantom_daemon.modules.core.hello.api → /api/core/hello
    """
    # Strip the base package prefix
    suffix = dotted_name.removeprefix(_PACKAGE)  # .core.hello.api
    # Split into parts, drop empty strings
    parts = [p for p in suffix.split(".") if p]
    # Drop trailing "api" segment
    if parts and parts[-1] == "api":
        parts = parts[:-1]
    return "/api/" + "/".join(parts) if parts else "/api"


def setup_routers(app: FastAPI) -> int:
    """Walk modules/ tree, find api.py files, mount their routers."""
    package = importlib.import_module(_PACKAGE)
    count = 0

    for finder, module_name, is_pkg in pkgutil.walk_packages(
        package.__path__, prefix=_PACKAGE + "."
    ):
        # Only interested in modules named "api"
        if not module_name.endswith(".api"):
            continue

        try:
            mod = importlib.import_module(module_name)
        except (ImportError, AttributeError):
            logger.exception("Failed to import %s", module_name)
            continue

        router = getattr(mod, "router", None)
        if router is None:
            logger.warning("No router attribute in %s", module_name)
            continue

        prefix = _module_to_prefix(module_name)
        app.include_router(router, prefix=prefix)
        count += 1
        logger.debug("Mounted %s → %s", module_name, prefix)

    logger.info("Auto-discovery mounted %d router(s)", count)
    return count
