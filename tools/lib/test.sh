# ──────────────────────────────────────────────────────────────────
# Test runners — unit, UDS, E2E
# Requires: COMPOSE, DAEMON
# ──────────────────────────────────────────────────────────────────

cmd_test() {
    bold "Running pytest (ASGI mode, excluding slow)..."
    if [ $# -eq 0 ]; then
        $COMPOSE exec "$DAEMON" python -m pytest tests/ -v -s -m "not slow"
    else
        $COMPOSE exec "$DAEMON" python -m pytest -v -s -m "not slow" "$@"
    fi
}

cmd_test_full() {
    bold "Running pytest (ASGI mode, all tests)..."
    if [ $# -eq 0 ]; then
        $COMPOSE exec "$DAEMON" python -m pytest tests/ -v -s
    else
        $COMPOSE exec "$DAEMON" python -m pytest -v -s "$@"
    fi
}

cmd_test_uds() {
    bold "Running pytest (UDS mode)..."
    if [ $# -eq 0 ]; then
        $COMPOSE exec "$DAEMON" python -m pytest tests/ -v --uds /var/run/phantom/daemon.sock
    else
        $COMPOSE exec "$DAEMON" python -m pytest -v --uds /var/run/phantom/daemon.sock "$@"
    fi
}

# ── E2E helpers ──────────────────────────────────────────────────

_require_compose_bridge() {
    if [ ! -d "lib/compose_bridge" ] || [ -z "$(ls lib/compose_bridge/*.so lib/compose_bridge/*.dylib 2>/dev/null)" ]; then
        red "compose-bridge not found. Run: ./tools/dev.sh fetch-compose-bridge"
        exit 1
    fi
}

_run_e2e() {
    local runner="$1"; shift
    _require_compose_bridge
    local lib_file
    lib_file="$(find lib/compose_bridge -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -print -quit)"
    COMPOSE_BRIDGE_LIB_PATH="$(pwd)/${lib_file}" \
    PYTHONPATH="$(pwd)/lib:${PYTHONPATH:-}" \
    python3 "$runner" "$@"
}

cmd_test_multihop_e2e() {
    bold "Running multihop E2E tests..."
    _run_e2e e2e_tests/multihop/runner.py "$@"
}

cmd_test_chaos_e2e() {
    bold "Running chaos E2E tests..."
    _run_e2e e2e_tests/chaos/runner.py "$@"
}

cmd_test_scenario_e2e() {
    bold "Running scenario E2E tests..."
    _run_e2e e2e_tests/scenario/runner.py "$@"
}

cmd_fetch_compose_bridge() {
    local repo="ARAS-Workspace/phantom-wg"
    local workflow="publish-compose-bridge.yml"
    local dest="lib/compose_bridge"

    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        arm64)   arch="arm64" ;;
        *)       red "Unsupported architecture: $arch"; exit 1 ;;
    esac

    if ! command -v gh &>/dev/null; then
        red "GitHub CLI (gh) required: brew install gh"
        exit 1
    fi

    if ! gh auth status &>/dev/null; then
        red "Not authenticated. Run: gh auth login"
        exit 1
    fi

    # Resolve the latest successful run of the publish workflow — no
    # hardcoded run id, always track whatever shipped last.
    bold "Locating latest successful ${workflow}..."
    local run_id
    run_id="$(gh run list \
        --repo "$repo" \
        --workflow "$workflow" \
        --status success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId')"

    if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
        red "No successful run found for ${workflow}"
        exit 1
    fi

    # Resolve the per-platform artifact within that run. Artifact naming
    # is compose-bridge-<version>-<os>-<arch>; we match by suffix so the
    # version never has to be known client-side.
    bold "Resolving artifact for ${os}-${arch} in run ${run_id}..."
    local artifact_name
    artifact_name="$(gh api "/repos/${repo}/actions/runs/${run_id}/artifacts" \
        --jq ".artifacts[] | select(.name | endswith(\"-${os}-${arch}\")) | .name" \
        | head -1)"

    if [ -z "$artifact_name" ]; then
        red "No artifact matching *-${os}-${arch} in run ${run_id}"
        exit 1
    fi

    bold "Fetching ${artifact_name} (run ${run_id})..."

    rm -rf "$dest"
    mkdir -p "$dest"

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    gh run download "$run_id" \
        --repo "$repo" \
        --name "$artifact_name" \
        --dir "$tmp_dir"

    local zip_file="$tmp_dir/${artifact_name}.zip"
    if [ -f "$zip_file" ]; then
        unzip -o "$zip_file" -d "$tmp_dir/extracted"
        cp -R "$tmp_dir/extracted/compose_bridge/"* "$dest/"
    else
        cp -R "$tmp_dir/"* "$dest/" 2>/dev/null || true
    fi

    rm -rf "$tmp_dir"

    green "Installed to ${dest}/"
    ls -lh "$dest/"
}
