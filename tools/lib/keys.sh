# ──────────────────────────────────────────────────────────────────
# WireGuard server keypair generation
# Requires: DAEMON, SECRETS_DIR, tools/lib/images.sh
# ──────────────────────────────────────────────────────────────────

cmd_gen_keys() {
    local force=false
    for arg in "$@"; do
        [[ "$arg" == "-f" || "$arg" == "--force" ]] && force=true
    done

    if [[ -s "${SECRETS_DIR}/wg_private_key" && -s "${SECRETS_DIR}/wg_public_key" ]]; then
        if [[ "$force" != true ]]; then
            green "WG keys already exist. Use -f to overwrite."
            return 0
        fi
        bold "Overwriting WG keys (--force)..."
    fi

    ensure_image "$DAEMON"

    bold "Generating WireGuard keypair..."
    local keys
    keys=$(docker run --rm "$(image_ref "$DAEMON")" python -c "
from wireguard_go_bridge.keys import generate_private_key, derive_public_key
priv = generate_private_key()
pub = derive_public_key(priv)
print(priv)
print(pub)
")

    local private_key public_key
    private_key=$(echo "$keys" | sed -n '1p')
    public_key=$(echo "$keys" | sed -n '2p')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        red "Key generation failed — empty output."
        exit 1
    fi

    if [[ ${#private_key} -ne 64 || ${#public_key} -ne 64 ]]; then
        red "Key generation failed — unexpected length."
        exit 1
    fi

    mkdir -p "$SECRETS_DIR"
    printf '%s' "$private_key" > "${SECRETS_DIR}/wg_private_key"
    printf '%s' "$public_key"  > "${SECRETS_DIR}/wg_public_key"
    chmod 600 "${SECRETS_DIR}/wg_private_key" "${SECRETS_DIR}/wg_public_key"

    green "WG keys written to ${SECRETS_DIR}/"
    bold "Public key:"
    echo "  $public_key"
}
