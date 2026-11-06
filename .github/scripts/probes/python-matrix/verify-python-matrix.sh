#!/usr/bin/env bash
# Trigger the Verify Linux Distribution Python Matrix Probe workflow.
# The tag verify-python-matrix moves to HEAD on every run; the workflow leaves
# its report and each guest's logs as artifacts.
# Usage: .github/scripts/probes/python-matrix/verify-python-matrix.sh
set -euo pipefail

TAG="verify-python-matrix"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    echo "The tree has changes: the tag would not match what you see."
    exit 1
fi

echo "Commit: $(git -C "${REPO_ROOT}" log -1 --format='%h %s')"

git -C "${REPO_ROOT}" tag -d "${TAG}" 2>/dev/null || true
git -C "${REPO_ROOT}" push origin ":refs/tags/${TAG}" 2>/dev/null || true

git -C "${REPO_ROOT}" tag "${TAG}"
git -C "${REPO_ROOT}" push origin "refs/tags/${TAG}"

echo ""
echo "Triggered: ${TAG}"
echo "Watch: gh run list --workflow verify-linux-distribution-python-matrix-probe.yml"
