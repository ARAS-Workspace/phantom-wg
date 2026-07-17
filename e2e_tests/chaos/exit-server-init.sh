#!/usr/bin/env bash
# ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
# ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
# ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
# ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
# ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
#
# Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
# Licensed under AGPL-3.0 - see LICENSE file for details
# WireGuard® is a registered trademark of Jason A. Donenfeld.
# ──────────────────────────────────────────────────────────────────
# Chaos test exit server (dual-stack) — one client config carrying both
# families, so a single import makes the daemon apply multihop-exit AND
# multihop-exit-v6 together. This is what a real dual-stack exit looks
# like, and it exercises the has_v4-and-has_v6 branch of the CIDR resync.
#
# Autonomous: chaos owns this exit rather than borrowing the multihop
# one, so the two suites can diverge without touching each other.
# ──────────────────────────────────────────────────────────────────

set -euo pipefail

WG_PORT="${WG_PORT:-51820}"

# ── Generate keys ─────────────────────────────────────────────────

SERVER_PRIV=$(wg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | wg pubkey)
CLIENT_PRIV=$(wg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
PSK=$(wg genpsk)

echo "Exit server keys generated."
echo "  Server pub: $SERVER_PUB"
echo "  Client pub: $CLIENT_PUB"

# ── Server WireGuard config (dual-stack) ──────────────────────────

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = ${SERVER_PRIV}
ListenPort = ${WG_PORT}
Address = 10.0.2.1/24, fd10:0:2::1/64

[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${PSK}
AllowedIPs = 10.0.2.2/32, fd10:0:2::2/128, 10.0.1.0/24
EOF

wg-quick up wg0
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# ── Client config (dual-stack, single import) ─────────────────────

mkdir -p /config

cat > /config/client.conf <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = 10.0.2.2/24, fd10:0:2::2/64

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${PSK}
Endpoint = __EXIT_SERVER_IP__:${WG_PORT}
AllowedIPs = 10.0.2.0/24, fd10:0:2::/64
PersistentKeepalive = 25
EOF

echo "EXIT_READY"
exec sleep infinity
