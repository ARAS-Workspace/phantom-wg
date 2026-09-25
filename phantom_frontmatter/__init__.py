"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Phantom-WG Frontmatter — Ghost Mode entry point for any WireGuard
server (or any UDP endpoint)

Accepts WSS/TLS on TCP 443, carries opaque UDP datagrams inside the
tunnel, and delivers them to a configured backend address — without
exposing the backend address to clients, network observers, or
leaked client configs. The canonical use case is bolting a Ghost
Mode hop in front of a WireGuard server (Phantom-WG Modern, plain
upstream WireGuard, or any other implementation), but the data
path is protocol-agnostic: anything that speaks UDP works.

The wstunnel server is hard-pinned to a loopback target; a
separate socat-backed egress unit is the only component that knows
the real backend IP.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
Third-party licenses - see THIRD_PARTY_LICENSES file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

__version__ = "1.0.1"
__author__ = "Rıza Emre ARAS"
__license__ = "AGPL-3.0"
