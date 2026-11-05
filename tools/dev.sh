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
# phantom-daemon  ·  Development Tools
# ──────────────────────────────────────────────────────────────────

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Environment & Libraries ──────────────────────────────────────

source "$TOOLS_DIR/dev.vars"

source "$TOOLS_DIR/lib/common.sh"
source "$TOOLS_DIR/lib/images.sh"
source "$TOOLS_DIR/lib/keys.sh"
source "$TOOLS_DIR/lib/auth.sh"
source "$TOOLS_DIR/lib/tls.sh"
source "$TOOLS_DIR/lib/compose.sh"
source "$TOOLS_DIR/lib/db.sh"
source "$TOOLS_DIR/lib/test.sh"
source "$TOOLS_DIR/lib/spa.sh"
source "$TOOLS_DIR/lib/stubs.sh"
source "$TOOLS_DIR/lib/openapi.sh"
source "$TOOLS_DIR/lib/package.sh"

# ── Help ─────────────────────────────────────────────────────────

cmd_help() {
    cat <<'HELP'
Usage: ./tools/dev.sh <command>

  Stack:
    build                Build dev images (no start)
    up                   Build & start dev stack
    down                 Stop dev stack
    restart              Restart daemon container
    rebuild              Full rebuild (no-cache)
    logs                 Follow daemon logs
    status               Show containers
    shell                Open shell in daemon
    curl [path]          Query via gateway (default: /api/core/hello)

  Test:
    test [args]          Run pytest (ASGI, excluding slow)
    test-full [args]     Run pytest (ASGI, all tests)
    test-uds [args]      Run pytest (UDS mode)
    test-multihop-e2e    Run multihop E2E tests
    test-chaos-e2e       Run chaos E2E tests
    test-scenario-e2e    Run scenario E2E tests

  Data:
    db-ls                List db/ (local)
    db-ls-r              List db/ (container)
    db-reset             Wipe db/ + auth-db/
    state-reset          Wipe state/db/
    key-reset            Wipe development secrets

  Setup:
    gen-keys             Generate WireGuard keypair
    setup-auth           Bootstrap auth service
    setup-tls            Generate self-signed TLS certificate
    build-spa            Build React SPA (translate + vite build)
    stubs                Generate .pyi vendor stubs
    openapi              Export OpenAPI schema (openapi.json)
    fetch-compose-bridge Download compose-bridge for current platform
    generate-production-package  Build dist/phantom-daemon/ package
HELP
}

# ── Dispatch ─────────────────────────────────────────────────────

case "${1:-help}" in
    build)       cmd_build ;;
    up)          cmd_up --build ;;
    down)        cmd_down ;;
    restart)     cmd_restart "$DAEMON" ;;
    rebuild)     cmd_rebuild ;;
    logs)        cmd_logs "$DAEMON" ;;
    status)      cmd_status ;;
    show-versions) cmd_show_versions ;;
    shell)       cmd_shell ;;
    curl)        shift; cmd_curl "$@" ;;

    test)              shift; cmd_test "$@" ;;
    test-full)         shift; cmd_test_full "$@" ;;
    test-uds)          shift; cmd_test_uds "$@" ;;
    test-multihop-e2e) shift; cmd_test_multihop_e2e "$@" ;;
    test-chaos-e2e)    shift; cmd_test_chaos_e2e "$@" ;;
    test-scenario-e2e) shift; cmd_test_scenario_e2e "$@" ;;

    db-ls)       cmd_db_ls ;;
    db-ls-r)     cmd_db_ls_r ;;
    db-reset)    cmd_db_reset ;;
    state-reset) cmd_state_reset ;;
    key-reset)   cmd_key_reset ;;

    gen-keys)    shift; cmd_gen_keys "$@" ;;
    setup-auth)  shift; cmd_setup_auth "$@" ;;
    setup-tls)   shift; cmd_setup_tls "$@" ;;
    build-spa)   cmd_build_spa ;;
    stubs)       cmd_stubs ;;
    openapi)     cmd_openapi ;;
    fetch-compose-bridge) cmd_fetch_compose_bridge ;;
    generate-production-package) cmd_generate_production_package ;;

    help|*)      cmd_help ;;
esac
