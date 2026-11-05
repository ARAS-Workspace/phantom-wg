# ──────────────────────────────────────────────────────────────────
# Auth service bootstrap
# Requires: SECRETS_DIR, AUTH_DB_DIR, tools/lib/images.sh
# ──────────────────────────────────────────────────────────────────

_archive_auth_db() {
    local target suffix
    target="${AUTH_DB_DIR}/auth.db.$(date +%Y%m%d-%H%M%S).bak"
    for suffix in "" "-wal" "-shm"; do
        if [[ -f "${AUTH_DB_DIR}/auth.db${suffix}" ]]; then
            mv "${AUTH_DB_DIR}/auth.db${suffix}" "${target}${suffix}"
        fi
    done
    echo "$target"
}

cmd_setup_auth() {
    local auth_dir="services/auth-service"
    local admin_username="admin"
    local force=false
    local archived=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--force) force=true; shift ;;
            --username) admin_username="$2"; shift 2 ;;
            *) red "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [ ! -d "$auth_dir" ]; then
        red "auth-service not found at ${auth_dir}/"
        exit 1
    fi

    if [[ -f "${AUTH_DB_DIR}/auth.db" ]]; then
        if [[ "$force" == true ]]; then
            archived="$(_archive_auth_db)"
        elif [[ -f "${SECRETS_DIR}/auth_signing_key" ]]; then
            green "Auth service already bootstrapped. Use -f to overwrite."
            return 0
        else
            red "${AUTH_DB_DIR}/auth.db exists without its keys. Use -f to start over."
            exit 1
        fi
    fi

    mkdir -p "$SECRETS_DIR" "$AUTH_DB_DIR"

    ensure_image auth-service

    bold "Bootstrapping auth service..."
    local output
    output=$(docker run --rm \
        -v "$(pwd)/${SECRETS_DIR}:/secrets" \
        -v "$(pwd)/${AUTH_DB_DIR}:/db" \
        -v "$(pwd)/${auth_dir}/tools/bootstrap.py:/tmp/bootstrap.py:ro" \
        "$(image_ref auth-service)" \
        python /tmp/bootstrap.py \
            --secrets-dir /secrets \
            --db-dir /db \
            --admin-username "$admin_username")

    echo "$output"

    chmod 600 "${SECRETS_DIR}/auth_signing_key" "${SECRETS_DIR}/auth_verify_key" 2>/dev/null || true
    chmod 600 "${SECRETS_DIR}/.admin_password" 2>/dev/null || true

    green "Auth service bootstrapped."
    echo "  Keys:     ${SECRETS_DIR}/"
    echo "  DB:       ${AUTH_DB_DIR}/auth.db"
    echo "  Password: ${SECRETS_DIR}/.admin_password"

    if [[ -n "$archived" ]]; then
        echo "  Previous: ${archived}"
        bold "Restart auth-service if the stack is running."
    fi
}
