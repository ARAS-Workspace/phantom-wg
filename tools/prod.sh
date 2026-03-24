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

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Environment & Libraries ──────────────────────────────────────

source "$TOOLS_DIR/prod.vars"

source "$TOOLS_DIR/lib/common.sh"
source "$TOOLS_DIR/lib/keys.sh"
source "$TOOLS_DIR/lib/auth.sh"
source "$TOOLS_DIR/lib/tls.sh"
source "$TOOLS_DIR/lib/compose.sh"

# ── Production-specific ─────────────────────────────────────────

_check_secrets() {
    local missing=false
    for key in wg_private_key wg_public_key auth_signing_key auth_verify_key tls_cert tls_key; do
        if [[ ! -s "${SECRETS_DIR}/${key}" ]]; then
            red "Missing: ${SECRETS_DIR}/${key}"
            missing=true
        fi
    done
    if [[ "$missing" == true ]]; then
        red "Run './tools/prod.sh setup' first."
        exit 1
    fi
}

_bootstrap_env() {
    local root
    root="$(cd "$TOOLS_DIR/.." && pwd)"

    if [[ ! -f "$root/.env.daemon" ]]; then
        if [[ -f "$root/.env.daemon.example" ]]; then
            cp "$root/.env.daemon.example" "$root/.env.daemon"
            green "Created .env.daemon from .env.daemon.example"
        else
            red "Missing .env.daemon.example"
            exit 1
        fi
    else
        echo "  .env.daemon already exists, skipping."
    fi

    if [[ ! -f "$root/.env.auth-service" ]]; then
        if [[ -f "$root/.env.auth-service.example" ]]; then
            cp "$root/.env.auth-service.example" "$root/.env.auth-service"
            green "Created .env.auth-service from .env.auth-service.example"
        else
            red "Missing .env.auth-service.example"
            exit 1
        fi
    else
        echo "  .env.auth-service already exists, skipping."
    fi
}

cmd_setup() {
    bold "Full production setup..."
    _bootstrap_env
    cmd_gen_keys "$@"
    cmd_setup_auth "$@"
    cmd_setup_tls "$@"
    green "Production setup complete."
    echo ""
    echo "  Environment:  .env.daemon, .env.auth-service"
    echo "  WG keys:      ${SECRETS_DIR}/"
    echo "  Auth keys:    ${SECRETS_DIR}/"
    echo "  TLS cert:     ${SECRETS_DIR}/tls_cert"
    echo "  Auth DB:      ${AUTH_DB_DIR}/auth.db"
    echo "  Admin pass:   ${SECRETS_DIR}/.admin_password"
    echo ""
    bold "Edit .env.daemon and set WIREGUARD_ENDPOINT_V4 before starting."
    bold "Start with: ./tools/prod.sh up"
}

cmd_update() {
    local skip_compose=false
    for arg in "$@"; do
        case "$arg" in
            --skip-compose) skip_compose=true ;;
        esac
    done

    bold "Pulling latest changes..."

    if [[ "$skip_compose" == true ]]; then
        git update-index --skip-worktree docker-compose.yml
        echo "  docker-compose.yml preserved (--skip-compose)"
    fi

    git pull

    if [[ "$skip_compose" == true ]]; then
        git update-index --no-skip-worktree docker-compose.yml
    fi

    bold "Restarting stack..."
    $COMPOSE restart
    green "Update complete."
}

cmd_hard_reset() {
    bold "This will destroy ALL data: secrets, auth DB, and Docker volumes."
    printf "Type 'yes' to confirm: "
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        red "Aborted."
        exit 1
    fi

    bold "Stopping stack..."
    $COMPOSE down -v 2>/dev/null || true

    bold "Removing secrets..."
    rm -rf "$SECRETS_DIR"

    bold "Removing auth database..."
    rm -rf "$AUTH_DB_DIR"

    green "Hard reset complete. Run './tools/prod.sh setup' to start fresh."
}

# ── Help ─────────────────────────────────────────────────────────

cmd_help() {
    cat <<'HELP'
Usage: ./tools/prod.sh <command>

  Setup:
    setup               Full setup (env bootstrap + gen-keys + setup-auth + setup-tls)
    gen-keys            Generate WireGuard keypair
    setup-auth          Bootstrap auth service
    setup-tls           Generate self-signed TLS certificate

  Stack:
    build               Build production images
    rebuild             Rebuild images from scratch (no-cache)
    up                  Start production stack
    down                Stop production stack
    restart [service]   Restart all or specific service
    logs [service]      Follow logs (all or specific)
    status              Show container status
    shell [service]     Open shell (default: daemon)
    exec <svc> <cmd>    Execute command in service

  Update:
    update              Pull latest + restart
    update --skip-compose  Pull but preserve local docker-compose.yml

  Danger:
    hard-reset          Wipe ALL data (secrets + auth DB + volumes)

  Options:
    -f, --force         Overwrite existing keys/bootstrap
HELP
}

# ── Dispatch ─────────────────────────────────────────────────────

case "${1:-help}" in
    setup)      shift; cmd_setup "$@" ;;
    gen-keys)   shift; cmd_gen_keys "$@" ;;
    setup-auth) shift; cmd_setup_auth "$@" ;;
    setup-tls)  shift; cmd_setup_tls "$@" ;;

    build)      cmd_build ;;
    rebuild)    cmd_rebuild ;;
    up)         _bootstrap_env; _check_secrets; cmd_up ;;
    down)       cmd_down ;;
    restart)    shift; cmd_restart "$@" ;;
    logs)       shift; cmd_logs "$@" ;;
    status)     cmd_status ;;
    shell)      shift; cmd_shell "$@" ;;
    exec)       shift; cmd_exec "$@" ;;

    update)     shift; cmd_update "$@" ;;
    hard-reset) cmd_hard_reset ;;

    help|*)     cmd_help ;;
esac
