#!/usr/bin/env bash
# Fetch compose-bridge for the current platform from the latest
# successful run of the publish-compose-bridge workflow. No run id or
# version hardcoded here — the script always tracks whatever shipped
# last.
#
# Usage: bash fetch_compose_bridge.sh

set -euo pipefail

REPO="ARAS-Workspace/phantom-wg"
WORKFLOW="publish-compose-bridge.yml"
DEST="lib/compose_bridge"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if ! command -v gh &>/dev/null; then
    echo "GitHub CLI (gh) required: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "Not authenticated. Run: gh auth login"
    exit 1
fi

# Resolve the latest successful publish run.
echo "Locating latest successful ${WORKFLOW}..."
RUN_ID="$(gh run list \
    --repo "$REPO" \
    --workflow "$WORKFLOW" \
    --status success \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId')"

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
    echo "No successful run found for ${WORKFLOW}" >&2
    exit 1
fi

# Resolve the per-platform artifact within that run. Artifact naming
# is compose-bridge-<version>-<os>-<arch>; we match by suffix so the
# version never has to be known client-side.
echo "Resolving artifact for ${OS}-${ARCH} in run ${RUN_ID}..."
ARTIFACT_NAME="$(gh api "/repos/${REPO}/actions/runs/${RUN_ID}/artifacts" \
    --jq ".artifacts[] | select(.name | endswith(\"-${OS}-${ARCH}\")) | .name" \
    | head -1)"

if [ -z "$ARTIFACT_NAME" ]; then
    echo "No artifact matching *-${OS}-${ARCH} in run ${RUN_ID}" >&2
    exit 1
fi

echo "Fetching ${ARTIFACT_NAME} (run ${RUN_ID})..."

rm -rf "$DEST"
mkdir -p "$DEST"

TMP_DIR="$(mktemp -d)"

gh run download "$RUN_ID" \
    --repo "$REPO" \
    --name "$ARTIFACT_NAME" \
    --dir "$TMP_DIR"

ZIP_FILE="$TMP_DIR/${ARTIFACT_NAME}.zip"
if [ -f "$ZIP_FILE" ]; then
    unzip -o "$ZIP_FILE" -d "$TMP_DIR/extracted"
    cp -R "$TMP_DIR/extracted/compose_bridge/"* "$DEST/"
else
    cp -R "$TMP_DIR/"* "$DEST/" 2>/dev/null || true
fi

rm -rf "$TMP_DIR"

echo "Installed to ${DEST}/"
ls -lh "$DEST/"
