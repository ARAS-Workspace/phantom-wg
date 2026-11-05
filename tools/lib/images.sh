# ──────────────────────────────────────────────────────────────────
# Image source and image references
# Requires: TOOLS_DIR
# Optional: PHANTOM_IMAGE_SOURCE (registry | build | dev), else .env
# ──────────────────────────────────────────────────────────────────

image_source() {
    local value="${PHANTOM_IMAGE_SOURCE:-}"
    if [[ -z "$value" && -f "${TOOLS_DIR}/../.env" ]]; then
        value="$(sed -n 's/^PHANTOM_IMAGE_SOURCE=//p' "${TOOLS_DIR}/../.env" | tail -n 1)"
    fi
    echo "${value:-registry}"
}

_image_file() {
    echo "${TOOLS_DIR}/compose/$(image_source).yml"
}

# Read from the source file: on the stack, config --images also lists
# the depends_on chain, in no fixed order.
image_ref() {
    docker compose -f "$(_image_file)" config --images "$1"
}

ensure_image() {
    local service="$1" ref
    ref="$(image_ref "$service")"
    docker image inspect "$ref" &>/dev/null && return 0

    if [[ "$(image_source)" == registry ]]; then
        bold "Pulling ${ref}..."
        docker compose -f "$(_image_file)" pull "$service"
    else
        bold "Building ${ref}..."
        docker compose -f "$(_image_file)" build "$service"
    fi
}
