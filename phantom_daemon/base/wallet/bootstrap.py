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

Creates wallet.db for tools/prod.sh setup: the pool stands before the first start.

Usage: python -m phantom_daemon.base.wallet.bootstrap <db dir> [subnet]
"""

from __future__ import annotations

import sys

from phantom_daemon.base.errors import WalletError
from phantom_daemon.base.wallet.wallet import _DEFAULT_IPV4_SUBNET, create_wallet


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print("Usage: bootstrap <db dir> [subnet]", file=sys.stderr)
        return 2

    subnet = argv[2] if len(argv) == 3 else _DEFAULT_IPV4_SUBNET
    try:
        wallet = create_wallet(argv[1], ipv4_subnet=subnet)
    except WalletError as exc:
        print(exc, file=sys.stderr)
        return 1

    print(f"Pool: {wallet.get_config('ipv4_subnet')}, {wallet.get_config('ipv6_subnet')}")
    wallet.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
