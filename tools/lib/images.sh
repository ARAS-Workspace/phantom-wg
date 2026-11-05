# ──────────────────────────────────────────────────────────────────
# Image source and image references
# Requires: TOOLS_DIR
# Optional: PHANTOM_IMAGE_SOURCE (registry | build | archive | dev), else
# .env, else .env.example
# ──────────────────────────────────────────────────────────────────

image_source() {
    local value="${PHANTOM_IMAGE_SOURCE:-}" file
    for file in .env .env.example; do
        if [[ -z "$value" && -f "${TOOLS_DIR}/../${file}" ]]; then
            value="$(sed -n 's/^PHANTOM_IMAGE_SOURCE=//p' "${TOOLS_DIR}/../${file}" | tail -n 1)"
        fi
    done
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

    case "$(image_source)" in
        registry)
            bold "Pulling ${ref}..."
            docker compose -f "$(_image_file)" pull "$service"
            ;;
        archive)
            archive_load
            ;;
        *)
            bold "Building ${ref}..."
            docker compose -f "$(_image_file)" build "$service"
            ;;
    esac
}

images_built_here() {
    local source
    source="$(image_source)"
    [[ "$source" != registry && "$source" != archive ]] && return 0
    bold "Images come from the ${source} source here, nothing to build."
    echo "  Fetch them:  ./tools/prod.sh images sync"
    echo "  Build here:  ./tools/prod.sh images use build"
    return 1
}

# images/ of a release zip: the image tars, VERSION and SHA256SUMS. The tars
# belong to the image version this package pins in registry.yml.
archive_check() {
    local dir="${TOOLS_DIR}/../images" version pinned
    if [[ ! -f "${dir}/VERSION" || ! -f "${dir}/SHA256SUMS" ]]; then
        red "images/ holds no image archive."
        exit 1
    fi

    version="$(cat "${dir}/VERSION")"
    pinned="$(sed -n 's/^    image: .*:\([^:@]*\)@sha256:.*/\1/p' "${TOOLS_DIR}/compose/registry.yml" | sort -u)"
    if [[ "$version" != "$pinned" ]]; then
        red "images/ holds ${version}, this package pins ${pinned}."
        exit 1
    fi

    if ! (cd "$dir" && sha256sum -c --quiet SHA256SUMS); then
        red "images/ does not match SHA256SUMS."
        exit 1
    fi
}

archive_load() {
    local tar
    archive_check
    bold "Loading images..."
    for tar in "${TOOLS_DIR}/../images"/*.tar; do
        docker load -q -i "$tar" > /dev/null
    done
    green "Images loaded."
}
