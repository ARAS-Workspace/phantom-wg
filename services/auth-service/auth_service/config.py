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

Auth service configuration from environment variables.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class AuthConfig:
    """Immutable auth service configuration."""

    host: str
    port: int
    log_level: str
    proxy_url: str
    db_dir: str
    secrets_dir: str
    token_lifetime: int
    inactivity_timeout: int
    mfa_token_lifetime: int
    totp_setup_lifetime: int
    proxy_timeout: float
    proxy_max_body: int
    rate_limit_window: int
    rate_limit_max: int

    @property
    def proxy_is_uds(self) -> bool:
        """True if proxy target is a Unix domain socket."""
        return self.proxy_url.startswith("unix://")

    @property
    def proxy_socket_path(self) -> str:
        """Extract UDS path from unix:// URL."""
        return self.proxy_url[7:]

    @property
    def proxy_base_url(self) -> str:
        """Base URL for proxy requests. UDS uses placeholder hostname."""
        if self.proxy_is_uds:
            return "http://daemon"
        return self.proxy_url.rstrip("/")


def load_auth_config() -> AuthConfig:
    """Load configuration from environment variables."""
    return AuthConfig(
        host=os.environ.get("AUTH_HOST", "0.0.0.0"),
        port=int(os.environ.get("AUTH_PORT", "8443")),
        log_level=os.environ.get("AUTH_LOG_LEVEL", "info"),
        proxy_url=os.environ.get("AUTH_PROXY_URL", "unix:///var/run/phantom/daemon.sock"),
        db_dir=os.environ.get("AUTH_DB_DIR", "/var/lib/phantom/auth"),
        secrets_dir=os.environ.get("AUTH_SECRETS_DIR", "/run/secrets"),
        token_lifetime=int(os.environ.get("AUTH_TOKEN_LIFETIME", "86400")),
        inactivity_timeout=int(os.environ.get("AUTH_INACTIVITY_TIMEOUT", "1800")),
        mfa_token_lifetime=int(os.environ.get("AUTH_MFA_TOKEN_LIFETIME", "120")),
        totp_setup_lifetime=int(os.environ.get("AUTH_TOTP_SETUP_LIFETIME", "300")),
        proxy_timeout=float(os.environ.get("AUTH_PROXY_TIMEOUT", "30.0")),
        proxy_max_body=int(os.environ.get("AUTH_PROXY_MAX_BODY", "67108864")),
        rate_limit_window=int(os.environ.get("AUTH_RATE_LIMIT_WINDOW", "60")),
        rate_limit_max=int(os.environ.get("AUTH_RATE_LIMIT_MAX", "5")),
    )
