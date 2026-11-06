#!/usr/bin/env bash
# Trigger the Verify release mechanics workflow.
# The tag verify-release-dynamics moves to HEAD on every run; the workflow
# leaves the release packages as artifacts, nothing reaches main.
# Usage: .github/scripts/distribution/verify-release.sh
set -euo pipefail

TAG="verify-release-dynamics"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

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
echo "Watch: gh run list --workflow verify-release-mechanics.yml"
