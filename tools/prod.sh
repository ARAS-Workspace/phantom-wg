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
source "$TOOLS_DIR/lib/images.sh"
source "$TOOLS_DIR/lib/keys.sh"
source "$TOOLS_DIR/lib/auth.sh"
source "$TOOLS_DIR/lib/tls.sh"
source "$TOOLS_DIR/lib/compose.sh"
source "$TOOLS_DIR/lib/certbot.sh"

# ── Production-specific ─────────────────────────────────────────

LOCAL_FILES=(.env .env.daemon .env.auth-service docker-compose.override.yml)

_missing_requirements() {
    local name key
    for name in "${LOCAL_FILES[@]}"; do
        [[ -f "${TOOLS_DIR}/../${name}" ]] || echo "$name"
    done
    for key in wg_private_key wg_public_key auth_signing_key auth_verify_key tls_cert tls_key; do
        [[ -s "${SECRETS_DIR}/${key}" ]] || echo "${SECRETS_DIR}/${key}"
    done
    [[ -f "${AUTH_DB_DIR}/auth.db" ]] || echo "${AUTH_DB_DIR}/auth.db"
}

_check_requirements() {
    local missing name
    missing="$(_missing_requirements)"
    [[ -z "$missing" ]] && return 0

    while IFS= read -r name; do
        red "Missing: ${name}"
    done <<< "$missing"
    red "Run './tools/prod.sh setup' first."
    exit 1
}

_bootstrap_env() {
    local root name
    root="$(cd "$TOOLS_DIR/.." && pwd)"

    for name in "${LOCAL_FILES[@]}"; do
        if [[ -f "$root/$name" ]]; then
            echo "  $name already exists, skipping."
        elif [[ -f "$root/$name.example" ]]; then
            cp "$root/$name.example" "$root/$name"
            green "Created $name from $name.example"
        else
            red "Missing $name.example"
            exit 1
        fi
    done
}

_images_status() {
    local service ref state
    bold "Image source: $(image_source)"
    for service in daemon auth-service nginx; do
        ref="$(image_ref "$service")"
        state="missing"
        docker image inspect "$ref" &>/dev/null && state="present"
        printf '  %-13s %-8s %s\n' "$service" "$state" "$ref"
    done
}

_images_use() {
    local value="${1:-}" env_file
    case "$value" in
        registry|build) ;;
        *)
            red "Usage: prod.sh images use {registry|build}"
            exit 1
            ;;
    esac

    env_file="$(cd "$TOOLS_DIR/.." && pwd)/.env"
    if [[ ! -f "$env_file" ]]; then
        red "Missing: .env"
        red "Run './tools/prod.sh setup' first."
        exit 1
    fi

    if grep -q '^PHANTOM_IMAGE_SOURCE=' "$env_file"; then
        sed "s/^PHANTOM_IMAGE_SOURCE=.*/PHANTOM_IMAGE_SOURCE=${value}/" "$env_file" > "${env_file}.tmp"
        mv "${env_file}.tmp" "$env_file"
    else
        echo "PHANTOM_IMAGE_SOURCE=${value}" >> "$env_file"
    fi

    green "Image source: ${value}"
    echo "  Apply it with: ./tools/prod.sh up"
}

cmd_images() {
    local action="${1:-status}"

    case "$action" in
        status) _images_status ;;
        use)    _images_use "${2:-}" ;;
        *)
            red "Unknown action: $action"
            echo "Usage: prod.sh images [status|use {registry|build}]"
            exit 1
            ;;
    esac
}

cmd_pull() {
    if [[ "$(image_source)" != registry ]]; then
        bold "Images are built here, nothing to pull."
        echo "  Pull from the registry: ./tools/prod.sh images use registry"
        return 0
    fi

    bold "Pulling images..."
    $COMPOSE pull
    green "Images pulled."
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
            -f|--force)
                red "setup does not overwrite. Start over with './tools/prod.sh hard-reset'."
                exit 1
                ;;
            *) pass_args+=("$arg") ;;
        esac
    done

    if [[ -z "$(_missing_requirements)" ]]; then
        red "Setup is already complete."
        echo "  Start the stack: ./tools/prod.sh up"
        echo "  Start over:      ./tools/prod.sh hard-reset"
        exit 1
    fi

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
    echo "  Environment:  .env, .env.daemon, .env.auth-service"
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
    local locked=false
    if _is_compose_locked; then
        locked=true
    fi

    # Sanity check: unlocked + uncommitted changes → hard stop
    if [[ "$locked" == false ]]; then
        if ! git diff --quiet docker-compose.yml 2>/dev/null; then
            red "docker-compose.yml has uncommitted local changes."
            echo ""
            echo "  Options:"
            echo "    Preserve changes permanently: ./tools/prod.sh compose lock"
            echo "    Discard changes:              git checkout -- docker-compose.yml"
            exit 1
        fi
    fi

    bold "Pulling latest changes..."

    if [[ "$locked" == true ]]; then
        echo "  Compose locked, docker-compose.yml preserved."
    fi

    local before after
    before=$(git rev-parse HEAD)
    git pull origin main
    after=$(git rev-parse HEAD)

    # Detect build-affecting changes between the pre-/post-pull HEADs.
    # Source (phantom_daemon/, auth_service/) is bind-mounted, so a plain
    # restart picks it up — but image-baked inputs (Dockerfile, requirements)
    # need a rebuild + recreate to take effect. Rebuild only what changed.
    local rebuild=()
    if ! git diff --quiet "$before" "$after" -- Dockerfile requirements.txt; then
        rebuild+=(daemon)
    fi
    if ! git diff --quiet "$before" "$after" -- \
            services/auth-service/Dockerfile services/auth-service/requirements.txt; then
        rebuild+=(auth-service)
    fi
    if ! git diff --quiet "$before" "$after" -- nginx.Dockerfile; then
        rebuild+=(nginx)
    fi

    if [[ ${#rebuild[@]} -gt 0 ]]; then
        bold "Build inputs changed (${rebuild[*]}) — rebuilding..."
        $COMPOSE build "${rebuild[@]}"
        bold "Recreating stack..."
        $COMPOSE up -d
    else
        bold "Restarting stack..."
        $COMPOSE restart
    fi
    green "Update complete."
}

_wipe_dir() {
    [[ -d "$1" ]] || return 0
    find "$1" -mindepth 1 ! -name '.gitkeep' -delete
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
    _wipe_dir "$SECRETS_DIR"

    bold "Removing auth database..."
    _wipe_dir "$AUTH_DB_DIR"

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
    certbot <domain>    Obtain Let's Encrypt TLS certificate

  Images:
    images              Show the image source and its images
    images use <source> Select registry (pull) or build (build here)
    pull                Pull the registry images
    build               Build the images here (build source)
    rebuild             Rebuild them from scratch (no-cache, build source)

  Stack:
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
    update              Pull latest + restart (honors compose lock)

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
    certbot)    shift; cmd_certbot "$@" ;;

    images)     shift; cmd_images "$@" ;;
    pull)       cmd_pull ;;
    build)      cmd_build ;;
    rebuild)    cmd_rebuild ;;
    up)
        _check_requirements
        if [[ -f "${TOOLS_DIR}/../.terazi-subnet" ]]; then
            DEFAULT_IPV4_SUBNET="$(cat "${TOOLS_DIR}/../.terazi-subnet")"
            export DEFAULT_IPV4_SUBNET
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
    update)     cmd_update ;;
    hard-reset) cmd_hard_reset ;;

    help|*)     cmd_help ;;
esac
