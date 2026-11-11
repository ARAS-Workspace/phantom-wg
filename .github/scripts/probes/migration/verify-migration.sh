#!/usr/bin/env bash
# Trigger the Verify migration workflow, from 1.1.5 to 2.0.0.
# The tag migration-v1.1.5-v2.0.0 moves to HEAD; each run clones main as
# 1.1.5 and takes a Let's Encrypt certificate for its domain. One run: main is
# 1.1.5 until 2.0.0 is out.
# Usage: .github/scripts/probes/migration/verify-migration.sh
set -euo pipefail

TAG="migration-v1.1.5-v2.0.0"

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
echo "Watch: gh run list --workflow verify-migration.yml"
