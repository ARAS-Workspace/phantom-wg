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
# Auth Service Developer Helper
# ──────────────────────────────────────────────────────────────────

set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose -f docker-compose-dev.yml"
AUTH="auth"
DEV_DB_DIR="container-data/auth-db/development"
DEV_SECRETS_DIR="container-data/secrets/development"
CONTAINER_DB_DIR="/var/lib/phantom/auth"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

cmd_build() {
    bold "Building dev image..."
    $COMPOSE build
    green "Image built."
}

cmd_up() {
    bold "Starting auth service..."
    $COMPOSE up -d --build
    green "Auth service: http://localhost:8443"
}

cmd_down() {
    bold "Stopping auth service..."
    $COMPOSE down
    green "Stopped."
}

cmd_restart() {
    bold "Restarting auth service..."
    $COMPOSE restart "$AUTH"
    green "Restarted."
}

cmd_logs() {
    $COMPOSE logs -f "$AUTH"
}

cmd_test() {
    local docker=false
    local args=()

    for arg in "$@"; do
        if [[ "$arg" == "--docker" ]]; then
            docker=true
        else
            args+=("$arg")
        fi
    done

    if [[ "$docker" == true ]]; then
        bold "Running docker tests (inside container)..."
        $COMPOSE exec "$AUTH" python -m pytest tests/ -v -s -m "docker" "${args[@]}"
    else
        bold "Running local tests (unit + integration, excluding docker)..."
        python -m pytest tests/ -m "not docker and not slow" "${args[@]}"
    fi
}

cmd_test_full() {
    bold "Running local tests (unit + integration)..."
    python -m pytest tests/ -m "not docker and not slow" "$@"

    bold "Running docker tests (inside container)..."
    $COMPOSE exec "$AUTH" python -m pytest tests/ -v -s -m "docker" "$@"

    green "All tests passed."
}

cmd_shell() {
    $COMPOSE exec "$AUTH" /bin/bash
}

cmd_status() {
    $COMPOSE ps
}

cmd_setup() {
    bold "Running bootstrap..."
    exec tools/setup.sh "$@"
}

cmd_add_superadmin() {
    if [[ $# -ne 1 || -z "$1" ]]; then
        red "Usage: ./tools/dev.sh add-superadmin <username>"
        exit 1
    fi
    if [[ ! -t 0 ]]; then
        red "add-superadmin reads the password from a terminal."
        exit 1
    fi
    if [[ -z "$($COMPOSE ps --status running -q "$AUTH")" ]]; then
        red "The auth service is not running. Start it first: ./tools/dev.sh up"
        exit 1
    fi

    local password repeat status=0
    read -rsp "Password: " password; echo
    read -rsp "Repeat:   " repeat; echo
    if [[ -z "$password" || "$password" != "$repeat" ]]; then
        red "The passwords are empty or differ."
        exit 1
    fi
    unset repeat

    # printf is a builtin: the password goes into the pipe and into no
    # argument list. exec -T keeps stdin a pipe; the script refuses a terminal.
    printf '%s\n' "$password" | $COMPOSE exec -T "$AUTH" \
        python -m tools.add_superadmin --db-dir "$CONTAINER_DB_DIR" --username "$1" || status=$?
    unset password
    return "$status"
}

cmd_db_reset() {
    bold "Resetting development database..."
    cmd_down 2>/dev/null || true
    rm -f "${DEV_DB_DIR}/auth.db" "${DEV_DB_DIR}/auth.db-wal" "${DEV_DB_DIR}/auth.db-shm"
    green "Database cleared: ${DEV_DB_DIR}/"
    bold "Run 'tools/dev.sh setup' to re-bootstrap."
}

cmd_secrets_reset() {
    bold "Resetting development secrets..."
    cmd_down 2>/dev/null || true
    rm -f "${DEV_SECRETS_DIR}/auth_signing_key" "${DEV_SECRETS_DIR}/auth_verify_key" "${DEV_SECRETS_DIR}/.admin_password"
    green "Secrets cleared: ${DEV_SECRETS_DIR}/"
    bold "Run 'tools/dev.sh setup' to re-bootstrap."
}

cmd_hard_reset() {
    bold "Hard reset — clearing development database and secrets..."
    cmd_down 2>/dev/null || true
    rm -f "${DEV_DB_DIR}/auth.db" "${DEV_DB_DIR}/auth.db-wal" "${DEV_DB_DIR}/auth.db-shm"
    rm -f "${DEV_SECRETS_DIR}/auth_signing_key" "${DEV_SECRETS_DIR}/auth_verify_key" "${DEV_SECRETS_DIR}/.admin_password"
    green "Development environment cleared."
    bold "Run 'tools/dev.sh setup' to re-bootstrap."
}

cmd_help() {
    cat <<'HELP'
Usage: ./tools/dev.sh <command>

  build          Build dev image
  up             Build & start auth service
  down           Stop auth service
  restart        Restart auth container
  logs           Follow auth logs
  test           Run local tests (unit + integration)
  test --docker  Run docker tests (live service scenarios)
  test-full      Run all tests (local + docker)
  shell          Open shell in auth container
  status         Show container status
  setup          Bootstrap auth service (keys + DB + admin)
  add-superadmin <username>
                 Add a superadmin to the running service; the
                 password is asked twice and goes in on stdin
  db-reset       Clear development database
  secrets-reset  Clear development secrets
  hard-reset     Clear both database and secrets
HELP
}

# ── Main ─────────────────────────────────────────────────────────

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
    build)      cmd_build ;;
    up)         cmd_up ;;
    down)       cmd_down ;;
    restart)    cmd_restart ;;
    logs)       cmd_logs ;;
    test)       cmd_test "$@" ;;
    test-full)  cmd_test_full "$@" ;;
    shell)      cmd_shell ;;
    status)     cmd_status ;;
    setup)          cmd_setup "$@" ;;
    add-superadmin) cmd_add_superadmin "$@" ;;
    db-reset)       cmd_db_reset ;;
    secrets-reset)  cmd_secrets_reset ;;
    hard-reset)     cmd_hard_reset ;;
    help|*)         cmd_help ;;
esac
