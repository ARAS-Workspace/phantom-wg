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

setup: everything a host needs before its first up.
"""

from __future__ import annotations

from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import (
    archive,
    auth,
    environment,
    gates,
    host,
    images,
    keys,
    paths,
    terazi,
    tls,
)

ABOUT = "Full setup (env + keys + auth + TLS + pool)"
ARGUMENTS = (
    argument("--terazi-ipv4-subnet", default=""),
    argument("--admin-username", default=auth.DEFAULT_USERNAME),
)
USAGE = "setup [--terazi-ipv4-subnet=<subnet>] [--admin-username <name>]"


def run(terazi_ipv4_subnet: str, admin_username: str) -> None:
    gates.enforce(host.SETUP_GATES)
    if not environment.missing():
        raise ToolError(
            "Setup is already complete.\n"
            "  Start the stack: ./tools/prod.sh up\n"
            "  Start over:      ./tools/prod.sh hard-reset"
        )
    tls.require_whole()
    if images.source() == "archive":
        archive.load()
    if terazi_ipv4_subnet and terazi.present():
        raise ToolError(
            f"{paths.DB_DIR}/wallet.db exists, its subnet is fixed.\n"
            "Another subnet starts over: ./tools/prod.sh hard-reset"
        )
    subnet = terazi.check(terazi_ipv4_subnet) if terazi_ipv4_subnet else ""

    print("Full production setup...")
    environment.bootstrap()
    if not keys.present():
        keys.provide()
    if not auth.bootstrapped():
        auth.first_bootstrap(admin_username)
    if not tls.present():
        tls.generate()
    if not terazi.present():
        terazi.create(subnet)

    print("Production setup complete.\n")
    print("  Environment:  .env, .env.daemon, .env.auth-service")
    print(f"  WG keys:      {paths.SECRETS_DIR}/")
    print(f"  Auth keys:    {paths.SECRETS_DIR}/")
    print(f"  TLS cert:     {paths.SECRETS_DIR}/tls_cert")
    print(f"  Auth DB:      {paths.AUTH_DB_DIR}/auth.db")
    print(f"  Wallet:       {paths.DB_DIR}/wallet.db")
    print(f"  Admin pass:   {paths.SECRETS_DIR}/.admin_password\n")
    print("Edit .env.daemon and set WIREGUARD_ENDPOINT_V4 before starting.")
    print("Start with: ./tools/prod.sh up")
