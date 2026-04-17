# ──────────────────────────────────────────────────────────────────
# Let's Encrypt certificate (certbot standalone)
# Requires: SECRETS_DIR, TOOLS_DIR
# Optional: CERTBOT_EMAIL (register with email)
# ──────────────────────────────────────────────────────────────────

CERTBOT_IMAGE="phantom-certbot:latest"
CERTBOT_DOCKERFILE="$TOOLS_DIR/lib/helpers/certbot"
CERTBOT_STATE_DIR="container-data/certbot"

cmd_certbot() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        red "Usage: prod.sh certbot <domain>"
        exit 1
    fi

    bold "Obtaining Let's Encrypt certificate for ${domain}..."

    docker build -q -t "$CERTBOT_IMAGE" "$CERTBOT_DOCKERFILE" > /dev/null

    mkdir -p "$CERTBOT_STATE_DIR"

    docker run --rm \
        -p 80:80 \
        -v "$(pwd)/${SECRETS_DIR}:/secrets" \
        -v "$(pwd)/${CERTBOT_STATE_DIR}:/etc/letsencrypt" \
        ${CERTBOT_EMAIL:+-e CERTBOT_EMAIL="$CERTBOT_EMAIL"} \
        "$CERTBOT_IMAGE" \
        "$domain"

    green "Certificate installed."
    echo "  Cert: ${SECRETS_DIR}/tls_cert"
    echo "  Key:  ${SECRETS_DIR}/tls_key"
    echo ""
    bold "Restart nginx to load the new certificate:"
    echo "  ./tools/prod.sh restart nginx"
}