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

Subnet check for tools/prod.sh, run before setup writes anything.

The daemon does not import this module. tools/prod.sh calls it in the daemon
image with the value of --terazi-ipv4-subnet.
"""

from __future__ import annotations

import ipaddress
import sys

_MIN_PREFIX = 16
_MAX_PREFIX = 30
_PRIVATE_BLOCKS = (
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
)


def check_subnet(value: str) -> str:
    """Return the subnet in normal form. Raises ValueError with the reason."""
    try:
        network = ipaddress.IPv4Network(value, strict=False)
    except ValueError:
        raise ValueError(f"Invalid subnet: {value!r} is not an IPv4 subnet") from None

    if not _MIN_PREFIX <= network.prefixlen <= _MAX_PREFIX:
        raise ValueError(
            f"Invalid subnet: {value} (the prefix range is "
            f"/{_MIN_PREFIX} to /{_MAX_PREFIX})"
        )

    if not any(network.subnet_of(block) for block in _PRIVATE_BLOCKS):
        raise ValueError(f"Invalid subnet: {value} (not a private range)")

    return str(network)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: subnet_check <subnet>", file=sys.stderr)
        return 2

    try:
        print(check_subnet(argv[1]))
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
