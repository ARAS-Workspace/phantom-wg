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

Base startup services: secrets, environment, wallet, wireguard, firewall.
"""

from phantom_daemon.base.env import DaemonEnv, load_env
from phantom_daemon.base.errors import (
    BackupError,
    ExitStoreError,
    FirewallError,
    SecretsError,
    StartupError,
    WalletError,
    WalletFullError,
    WireGuardError,
)
from phantom_daemon.base.exit_store import ExitStore, open_exit_store
from phantom_daemon.base.secrets import ServerKeys, load_secrets
from phantom_daemon.base.services.firewall import FirewallService, open_firewall
from phantom_daemon.base.services.wireguard import WireGuardService, open_wireguard
from phantom_daemon.base.wallet import Wallet, open_wallet

__all__ = [
    "BackupError",
    "DaemonEnv",
    "ExitStore",
    "ExitStoreError",
    "FirewallError",
    "FirewallService",
    "SecretsError",
    "ServerKeys",
    "StartupError",
    "Wallet",
    "WalletError",
    "WalletFullError",
    "WireGuardError",
    "WireGuardService",
    "load_env",
    "load_secrets",
    "open_exit_store",
    "open_firewall",
    "open_wallet",
    "open_wireguard",
]
