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

_is_compose_locked() {
    # assume-unchanged: git ls-files -v shows lowercase 'h' when set.
    # skip-worktree ('S') is broken in blob:none partial clones —
    # the flag is set but git ignores it. assume-unchanged works
    # reliably in both normal and sparse/partial clones.
    git ls-files -v docker-compose.yml 2>/dev/null | grep -q '^h'
}

cmd_compose() {
    local action="${1:-status}"

    case "$action" in
        lock)
            if _is_compose_locked; then
                echo "  Compose already locked."
                return 0
            fi
            git update-index --assume-unchanged docker-compose.yml
            green "Compose locked."
            echo "  Future 'prod.sh update' calls will preserve local docker-compose.yml changes."
            echo "  Run 'prod.sh compose unlock' to release."
            ;;
        unlock)
            if ! _is_compose_locked; then
                echo "  Compose already unlocked."
                return 0
            fi
            git update-index --no-assume-unchanged docker-compose.yml
            green "Compose unlocked."
            echo "  Next 'prod.sh update' will pull upstream docker-compose.yml."
            ;;
        status)
            if _is_compose_locked; then
                bold "Compose: LOCKED"
                echo "  Local docker-compose.yml changes are preserved on update."
            else
                bold "Compose: UNLOCKED"
                echo "  docker-compose.yml will be pulled from upstream on update."
            fi
            ;;
        *)
            red "Unknown action: $action"
            echo "Usage: prod.sh compose {lock|unlock|status}"
            exit 1
            ;;
    esac
}

cmd_setup() {
    local terazi_subnet=""
    local pass_args=()

    for arg in "$@"; do
        case "$arg" in
            --terazi-ipv4-subnet=*) terazi_subnet="${arg#*=}" ;;
            *) pass_args+=("$arg") ;;
        esac
    done

    bold "Full production setup..."
    _bootstrap_env
    cmd_gen_keys "${pass_args[@]}"
    cmd_setup_auth "${pass_args[@]}"
    cmd_setup_tls "${pass_args[@]}"

    if [[ -n "$terazi_subnet" ]]; then
        echo "$terazi_subnet" > "${TOOLS_DIR}/../.terazi-subnet"
        echo "  Terazi subnet: ${terazi_subnet}"
    fi

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
    local legacy_skip=false
    for arg in "$@"; do
        case "$arg" in
            --skip-compose) legacy_skip=true ;;
        esac
    done

    if [[ "$legacy_skip" == true ]]; then
        red "WARNING: --skip-compose is deprecated."
        echo "  Use 'prod.sh compose lock' to permanently preserve docker-compose.yml changes."
    fi

    local locked=false
    if _is_compose_locked; then
        locked=true
    fi

    # Sanity check: unlocked + uncommitted changes → hard stop
    if [[ "$locked" == false && "$legacy_skip" == false ]]; then
        if ! git diff --quiet docker-compose.yml 2>/dev/null; then
            red "docker-compose.yml has uncommitted local changes."
            echo ""
            echo "  Options:"
            echo "    Preserve changes permanently: ./tools/prod.sh compose lock"
            echo "    Skip once (deprecated):       ./tools/prod.sh update --skip-compose"
            echo "    Discard changes:              git checkout -- docker-compose.yml"
            exit 1
        fi
    fi

    bold "Pulling latest changes..."

    if [[ "$locked" == true ]]; then
        echo "  Compose locked, docker-compose.yml preserved."
    fi

    # One-shot legacy skip (doesn't persist)
    if [[ "$legacy_skip" == true && "$locked" == false ]]; then
        git update-index --assume-unchanged docker-compose.yml
        echo "  One-shot skip applied to docker-compose.yml."
    fi

    git pull origin main

    if [[ "$legacy_skip" == true && "$locked" == false ]]; then
        git update-index --no-assume-unchanged docker-compose.yml
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

    bold "Removing daemon databases..."
    rm -f container-data/db/*.db
    rm -f container-data/state/db/firewall.db
    rm -rf container-data/state/db/wireguard/

    rm -f "${TOOLS_DIR}/../.terazi-subnet"

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
    show-versions       Show daemon + bridge versions
    shell [service]     Open shell (default: daemon)
    exec <svc> <cmd>    Execute command in service

  Compose Lock:
    compose lock        Preserve local docker-compose.yml on update
    compose unlock      Release lock to pull upstream changes
    compose status      Show current lock state

  Update:
    update                 Pull latest + restart (honors compose lock)
    update --skip-compose  One-shot compose skip (deprecated)

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
    up)
        _bootstrap_env; _check_secrets
        if [[ -f "${TOOLS_DIR}/../.terazi-subnet" ]]; then
            export DEFAULT_IPV4_SUBNET="$(cat "${TOOLS_DIR}/../.terazi-subnet")"
            rm -f "${TOOLS_DIR}/../.terazi-subnet"
        fi
        cmd_up ;;

    down)       cmd_down ;;
    restart)    shift; cmd_restart "$@" ;;
    logs)       shift; cmd_logs "$@" ;;
    status)     cmd_status ;;
    show-versions) cmd_show_versions ;;
    shell)      shift; cmd_shell "$@" ;;
    exec)       shift; cmd_exec "$@" ;;

    compose)    shift; cmd_compose "$@" ;;
    update)     shift; cmd_update "$@" ;;
    hard-reset) cmd_hard_reset ;;

    help|*)     cmd_help ;;
esac
