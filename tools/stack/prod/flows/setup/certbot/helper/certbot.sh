#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# Let's Encrypt certificate (certbot standalone)
# Runs from the root of the install: ./tools/prod.sh certbot <domain>
# Optional: CERTBOT_EMAIL (register with email)
# ──────────────────────────────────────────────────────────────────

set -euo pipefail

domain="$1"

CERTBOT_IMAGE="phantom-certbot:latest"
CERTBOT_DOCKERFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTBOT_STATE_DIR="container-data/certbot"
SECRETS_DIR="container-data/secrets/production"

echo "Obtaining Let's Encrypt certificate for ${domain}..."

docker build -q -t "$CERTBOT_IMAGE" "$CERTBOT_DOCKERFILE" > /dev/null

mkdir -p "$CERTBOT_STATE_DIR"

docker run --rm \
    -p 80:80 \
    -v "$(pwd)/${SECRETS_DIR}:/secrets" \
    -v "$(pwd)/${CERTBOT_STATE_DIR}:/etc/letsencrypt" \
    -v "${CERTBOT_DOCKERFILE}/certbot_obtain.py:/app/certbot_obtain.py:ro" \
    ${CERTBOT_EMAIL:+-e CERTBOT_EMAIL="$CERTBOT_EMAIL"} \
    "$CERTBOT_IMAGE" \
    "$domain"

echo "Certificate installed."
echo "  Cert: ${SECRETS_DIR}/tls_cert"
echo "  Key:  ${SECRETS_DIR}/tls_key"
echo ""
echo "Restart nginx to load the new certificate:"
echo "  ./tools/prod.sh restart nginx"
