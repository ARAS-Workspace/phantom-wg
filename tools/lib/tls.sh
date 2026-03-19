# ──────────────────────────────────────────────────────────────────
# TLS certificate generation (self-signed)
# Requires: SECRETS_DIR, TLS_SUBJECT, TLS_SAN
# Optional: TLS_PRODUCTION (enables policy extensions + detail output)
# ──────────────────────────────────────────────────────────────────

cmd_setup_tls() {
    local cert_path="${SECRETS_DIR}/tls_cert"
    local key_path="${SECRETS_DIR}/tls_key"
    local force=false

    for arg in "$@"; do
        [[ "$arg" == "-f" || "$arg" == "--force" ]] && force=true
    done

    if [[ -f "$cert_path" && -f "$key_path" ]]; then
        if [[ "$force" != true ]]; then
            green "TLS cert already exists. Use -f to overwrite."
            return 0
        fi
        bold "Overwriting TLS cert (--force)..."
    fi

    mkdir -p "$SECRETS_DIR"

    bold "Generating self-signed TLS certificate..."

    local args=(
        req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
        -days 365 -nodes
        -keyout /secrets/tls_key
        -out /secrets/tls_cert
        -subj "$TLS_SUBJECT"
        -addext "subjectAltName=${TLS_SAN}"
    )

    if [[ "${TLS_PRODUCTION:-false}" == true ]]; then
        args+=(-addext "certificatePolicies=2.5.29.32.0")
        args+=(-addext "nsComment=Phantom-WG Self-Signed Certificate")
    fi

    docker run --rm \
        -v "$(pwd)/${SECRETS_DIR}:/secrets" \
        alpine/openssl "${args[@]}" \
        2>/dev/null

    chmod 600 "$key_path" "$cert_path" 2>/dev/null || true

    green "TLS certificate written to ${SECRETS_DIR}/"
    echo "  Cert: ${cert_path}"
    echo "  Key:  ${key_path}"

    if [[ "${TLS_PRODUCTION:-false}" == true ]]; then
        echo ""
        bold "Certificate details:"
        openssl x509 -in "$cert_path" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
    fi
}
