#!/bin/sh
# dns-leak-server production CLI.
# Usage: tools/prod.sh <command>
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f ${DIR}/docker-compose.yml --env-file ${DIR}/.env"

check_env() {
    if [ ! -f "$DIR/.env" ]; then
        echo "ERROR: .env not found — copy from .env.example"
        exit 1
    fi
}

check_secrets() {
    missing=""
    [ ! -f "$DIR/secrets/shared_secret" ] && missing="$missing shared_secret"
    [ ! -f "$DIR/secrets/certs/tls_cert" ] && missing="$missing tls_cert"
    [ ! -f "$DIR/secrets/certs/tls_key" ] && missing="$missing tls_key"

    if [ -n "$missing" ]; then
        echo "ERROR: Missing secrets:$missing"
        echo "Run: tools/prod.sh setup"
        exit 1
    fi
}

cmd_setup() {
    FORCE=false
    for arg in "$@"; do
        case "$arg" in -f) FORCE=true ;; esac
    done

    check_env
    . "$DIR/.env"

    # Shared secret
    SECRET_FILE="$DIR/secrets/shared_secret"
    if [ -f "$SECRET_FILE" ] && [ "$FORCE" = false ]; then
        echo "Shared secret exists. Use -f to regenerate."
    else
        mkdir -p "$DIR/secrets"
        openssl rand -hex 32 > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        echo "Shared secret generated: $SECRET_FILE"
    fi

    # TLS certificate
    CERT_FILE="$DIR/secrets/certs/tls_cert"
    if [ -f "$CERT_FILE" ] && [ "$FORCE" = false ]; then
        echo "TLS certificate exists. Use -f to renew."
    else
        : "${DNS_ZONE:?DNS_ZONE not set in .env}"
        : "${NS_HOST:?NS_HOST not set in .env}"
        : "${ACME_EMAIL:?ACME_EMAIL not set in .env}"

        mkdir -p "$DIR/secrets/certs"

        echo "Stopping DNS server..."
        $COMPOSE down 2>/dev/null || true

        echo "Building ACME container..."
        docker build --network host -t dns-leak-acme "$DIR/acme"

        echo "Requesting wildcard certificate for *.${DNS_ZONE}"
        docker run --rm --network host \
            -e DNS_ZONE="$DNS_ZONE" \
            -e NS_HOST="$NS_HOST" \
            -e ACME_EMAIL="$ACME_EMAIL" \
            -v "$DIR/secrets/certs:/certs" \
            dns-leak-acme

        echo "Certificate issued."
    fi

    echo ""
    echo "Setup complete."
    echo "  Secret: $DIR/secrets/shared_secret"
    echo "  Cert:   $DIR/secrets/certs/tls_cert"
    echo "  Key:    $DIR/secrets/certs/tls_key"
    echo ""
    echo "Start with: tools/prod.sh up"
}

cmd_renew_cert() {
    check_env
    . "$DIR/.env"
    : "${DNS_ZONE:?DNS_ZONE not set in .env}"
    : "${NS_HOST:?NS_HOST not set in .env}"
    : "${ACME_EMAIL:?ACME_EMAIL not set in .env}"

    echo "Renewing certificate for *.${DNS_ZONE}"

    $COMPOSE down 2>/dev/null || true

    docker run --rm --network host \
        -e DNS_ZONE="$DNS_ZONE" \
        -e NS_HOST="$NS_HOST" \
        -e ACME_EMAIL="$ACME_EMAIL" \
        -v "$DIR/secrets/certs:/certs" \
        dns-leak-acme

    $COMPOSE up -d

    echo "Certificate renewed. Service restarted."
}

case "${1:-help}" in
    setup)      shift; cmd_setup "$@" ;;
    renew-cert) cmd_renew_cert ;;
    up)         check_env; check_secrets; $COMPOSE up -d ;;
    down)       $COMPOSE down ;;
    rebuild)    check_env; $COMPOSE build --no-cache ;;
    restart)    check_env; check_secrets; $COMPOSE restart ;;
    logs)       shift; $COMPOSE logs -f --tail=100 "$@" ;;
    status)     $COMPOSE ps ;;
    shell)      docker exec -it dns-leak-server /bin/sh ;;
    exec)       shift; docker exec -it dns-leak-server "$@" ;;
    help|*)
        echo "Usage: tools/prod.sh <command>"
        echo "  setup [-f]    Generate secrets + TLS certificate"
        echo "  renew-cert    Renew TLS certificate"
        echo "  up            Start"
        echo "  down          Stop"
        echo "  rebuild       Build from scratch"
        echo "  restart       Restart"
        echo "  logs          Follow logs"
        echo "  status        Show status"
        echo "  shell         Open shell in container"
        echo "  exec <cmd>    Execute command in container"
        ;;
esac