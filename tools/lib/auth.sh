# ──────────────────────────────────────────────────────────────────
# Auth service bootstrap
# Requires: SECRETS_DIR, AUTH_IMAGE, AUTH_DB_DIR
# ──────────────────────────────────────────────────────────────────

cmd_setup_auth() {
    local auth_dir="services/auth-service"
    local admin_username="admin"
    local force=false

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

    if [[ -f "${SECRETS_DIR}/auth_signing_key" && -f "${AUTH_DB_DIR}/auth.db" ]]; then
        if [[ "$force" != true ]]; then
            green "Auth service already bootstrapped. Use -f to overwrite."
            return 0
        fi
    fi

    mkdir -p "$SECRETS_DIR" "$AUTH_DB_DIR"

    if ! docker image inspect "$AUTH_IMAGE" &>/dev/null; then
        bold "Building auth image..."
        docker build -t "$AUTH_IMAGE" -f "${auth_dir}/Dockerfile" "$auth_dir"
    fi

    bold "Bootstrapping auth service..."
    local output
    output=$(docker run --rm \
        -v "$(pwd)/${SECRETS_DIR}:/secrets" \
        -v "$(pwd)/${AUTH_DB_DIR}:/db" \
        -v "$(pwd)/${auth_dir}/tools/bootstrap.py:/tmp/bootstrap.py:ro" \
        "$AUTH_IMAGE" \
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
}
