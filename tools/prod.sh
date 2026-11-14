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
# phantom-daemon  ·  Production Tools
# ──────────────────────────────────────────────────────────────────
# Starts the Python toolchain. Without python3 nothing else can answer,
# so the command that installs it on this distribution is named here.

set -euo pipefail

TOOLCHAIN_DIR="$(cd "$(dirname "$0")" && pwd)"

install_command() {
    [ -r /etc/os-release ] || return 0
    case " $(sed -n 's/^ID\(_LIKE\)\{0,1\}=//p' /etc/os-release | tr -d "\"'" | tr '\n' ' ') " in
        *" debian "*) echo "sudo apt-get install python3" ;;
        *" fedora "* | *" rhel "*) echo "sudo dnf install python3" ;;
        *" arch "*) echo "sudo pacman -S python" ;;
    esac
}

if ! command -v python3 > /dev/null; then
    echo "python3 is required." >&2
    command="$(install_command)"
    [ -z "$command" ] || echo "Install it with: $command" >&2
    exit 1
fi

exec python3 -I -B -u "$TOOLCHAIN_DIR" prod "$@"
