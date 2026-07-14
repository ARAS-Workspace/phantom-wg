# ──────────────────────────────────────────────────────────────────
# Vendor type stub generation
# Requires: DAEMON_DOCKERFILE, TOOLS_DIR
# ──────────────────────────────────────────────────────────────────

cmd_stubs() {
    local out_dir="typings"
    local vendor_dir="/opt/phantom/vendor"

    if ! docker image inspect phantom-daemon:latest &>/dev/null; then
        bold "Image phantom-daemon:latest not found. Building..."
        docker build -t phantom-daemon:latest -f "$DAEMON_DOCKERFILE" .
    fi

    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    bold "Generating type stubs from vendor packages..."
    docker run --rm \
        -v "${TOOLS_DIR}/lib/helpers/gen_stubs.py:/tmp/gen_stubs.py:ro" \
        -v "$(pwd)/$out_dir:/out" \
        phantom-daemon:latest \
        python /tmp/gen_stubs.py "$vendor_dir" /out

    green "Stubs written to ${out_dir}/"
}
