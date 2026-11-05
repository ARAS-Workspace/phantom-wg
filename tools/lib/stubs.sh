# ──────────────────────────────────────────────────────────────────
# Vendor type stub generation
# Requires: DAEMON, TOOLS_DIR, tools/lib/images.sh
# ──────────────────────────────────────────────────────────────────

cmd_stubs() {
    local out_dir="typings"
    local vendor_dir="/opt/phantom/vendor"

    ensure_image "$DAEMON"

    rm -rf "$out_dir"
    mkdir -p "$out_dir"

    bold "Generating type stubs from vendor packages..."
    docker run --rm \
        -v "${TOOLS_DIR}/lib/helpers/gen_stubs.py:/tmp/gen_stubs.py:ro" \
        -v "$(pwd)/$out_dir:/out" \
        "$(image_ref "$DAEMON")" \
        python /tmp/gen_stubs.py "$vendor_dir" /out

    green "Stubs written to ${out_dir}/"
}
