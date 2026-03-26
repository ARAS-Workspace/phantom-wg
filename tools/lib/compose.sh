# ──────────────────────────────────────────────────────────────────
# Docker Compose operations
# Requires: COMPOSE, DAEMON
# Optional: GATEWAY_PORT (for curl and up message)
# ──────────────────────────────────────────────────────────────────

cmd_build() {
    bold "Building images..."
    $COMPOSE build
    green "Images built."
}

cmd_up() {
    bold "Starting stack..."
    $COMPOSE up -d "$@"
    [[ -n "${GATEWAY_PORT:-}" ]] && green "Gateway: http://localhost:${GATEWAY_PORT}"
    green "Stack started."
}

cmd_down() {
    bold "Stopping stack..."
    $COMPOSE down
    green "Stopped."
}

cmd_restart() {
    if [[ $# -eq 0 ]]; then
        bold "Restarting all services..."
        $COMPOSE restart
    else
        bold "Restarting $1..."
        $COMPOSE restart "$1"
    fi
    green "Restarted."
}

cmd_rebuild() {
    bold "Rebuilding (no-cache)..."
    $COMPOSE down
    $COMPOSE build --no-cache
    green "Rebuilt. Run 'up' to start."
}

cmd_logs() {
    if [[ $# -eq 0 ]]; then
        $COMPOSE logs -f
    else
        $COMPOSE logs -f "$@"
    fi
}

cmd_status() {
    $COMPOSE ps
}

cmd_shell() {
    local target="${1:-$DAEMON}"
    $COMPOSE exec "$target" /bin/bash
}

cmd_exec() {
    if [[ $# -lt 2 ]]; then
        red "Usage: exec <service> <command...>"
        exit 1
    fi
    local service="$1"; shift
    $COMPOSE exec "$service" "$@"
}

cmd_show_versions() {
    local py_cmd='
import sys, pathlib, re

def ver(path):
    try:
        text = pathlib.Path(path).read_text()
        m = re.search(r"__version__\s*=\s*\"(.+?)\"", text)
        return m.group(1) if m else "?"
    except FileNotFoundError:
        return "not found"

def ver_file(path):
    try:
        return pathlib.Path(path).read_text().strip()
    except FileNotFoundError:
        return "not found"

daemon    = ver("/app/phantom_daemon/__init__.py")
fw_bridge = ver("/opt/phantom/vendor/firewall_bridge/__init__.py")
fw_ver    = ver_file("/opt/phantom/vendor/firewall_bridge/VERSION")
wg_bridge = ver("/opt/phantom/vendor/wireguard_go_bridge/__init__.py")
wg_ver    = ver_file("/opt/phantom/vendor/wireguard_go_bridge/VERSION")

print(f"  Phantom Daemon        {daemon}")
print(f"  firewall-bridge       {fw_bridge}  (vendor: {fw_ver})")
print(f"  wireguard-go-bridge   {wg_bridge}  (vendor: {wg_ver})")
'
    bold "Component Versions"
    $COMPOSE exec -T "$DAEMON" python3 -c "$py_cmd" 2>/dev/null || red "Daemon container not running."
}

cmd_curl() {
    local path="${1:-/api/core/hello}"
    curl -s "http://localhost:${GATEWAY_PORT:-9080}${path}" | python3 -m json.tool
}
