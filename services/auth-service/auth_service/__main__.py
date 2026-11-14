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

Entry point: python -m auth_service
"""

import copy

import uvicorn
from uvicorn.config import LOGGING_CONFIG

from auth_service.app import create_app
from auth_service.config import load_auth_config


def log_config(level: str) -> dict:
    """uvicorn's logging config plus the service logger, phantom-auth, on stdout.

    uvicorn configures only its own loggers; without a handler here the
    lines of phantom-auth below WARNING are dropped and the rest reach
    stderr with no time or level.
    """
    config = copy.deepcopy(LOGGING_CONFIG)
    config["formatters"]["phantom"] = {
        "format": "%(asctime)s %(levelname)s %(name)s %(message)s",
    }
    config["handlers"]["phantom"] = {
        "class": "logging.StreamHandler",
        "formatter": "phantom",
        "stream": "ext://sys.stdout",
    }
    config["loggers"]["phantom-auth"] = {
        "handlers": ["phantom"],
        "level": level.upper(),
        "propagate": False,
    }
    return config


def main() -> None:
    config = load_auth_config()
    app = create_app()
    # No access log: nginx writes a line for every request. The service
    # log holds what the service writes, refused logins among it.
    uvicorn.run(
        app,
        host=config.host,
        port=config.port,
        log_level=config.log_level,
        log_config=log_config(config.log_level),
        access_log=False,
    )


if __name__ == "__main__":
    main()
