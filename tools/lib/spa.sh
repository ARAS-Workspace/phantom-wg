# ──────────────────────────────────────────────────────────────────
# React SPA build
# ──────────────────────────────────────────────────────────────────

cmd_build_spa() {
    bold "Building React SPA..."
    (cd services/react-spa && npm run build)
    green "SPA built → services/react-spa/dist/"
}
