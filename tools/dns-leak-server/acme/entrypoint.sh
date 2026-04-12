#!/bin/sh
set -e

DOMAIN="${DNS_ZONE:?DNS_ZONE is required}"
EMAIL="${ACME_EMAIL:?ACME_EMAIL is required}"
CERTS_OUT="/certs"

# Start ACME DNS server in background
acme-dns &
DNS_PID=$!
sleep 1

echo "Requesting wildcard certificate for *.${DOMAIN}"

certbot certonly \
    --manual \
    --preferred-challenges dns-01 \
    --manual-auth-hook /auth-hook.sh \
    --manual-cleanup-hook 'rm -f /tmp/acme-challenge' \
    -d "*.${DOMAIN}" \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive

mkdir -p "$CERTS_OUT"
cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "$CERTS_OUT/tls_cert"
cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "$CERTS_OUT/tls_key"
chmod 600 "$CERTS_OUT/tls_key"

echo "Certificates saved to ${CERTS_OUT}/"

kill $DNS_PID 2>/dev/null || true
