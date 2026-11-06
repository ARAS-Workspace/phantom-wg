#!/usr/bin/env bash
# Trigger the release-modern workflow.
# Version is read from phantom_daemon/__init__.py (single source of truth).
# Creates release-v{version} tag and pushes it.
# Usage: .github/scripts/distribution/release.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

VERSION=$(python3 -c "
import re, pathlib
text = pathlib.Path('${REPO_ROOT}/phantom_daemon/__init__.py').read_text()
m = re.search(r'__version__\s*=\s*\"(.+?)\"', text)
print(m.group(1))
")

TAG="release-v${VERSION}"

echo "Version : ${VERSION}"
echo "Tag     : ${TAG}"
echo ""

# Check if tag already exists
if git -C "${REPO_ROOT}" rev-parse "${TAG}" &>/dev/null 2>&1; then
    echo "Tag ${TAG} already exists locally."
    printf "Delete and recreate? [y/N]: "
    read -r confirm
    if [[ "$confirm" != "y" ]]; then
        echo "Aborted."
        exit 1
    fi
    git -C "${REPO_ROOT}" tag -d "${TAG}"
    git -C "${REPO_ROOT}" push origin ":refs/tags/${TAG}" 2>/dev/null || true
    # Also clean up the version tag if it exists
    git -C "${REPO_ROOT}" tag -d "v${VERSION}" 2>/dev/null || true
    git -C "${REPO_ROOT}" push origin ":refs/tags/v${VERSION}" 2>/dev/null || true
fi

git -C "${REPO_ROOT}" tag "${TAG}"
git -C "${REPO_ROOT}" push origin "${TAG}"

echo ""
echo "Release triggered: ${TAG}"
echo "Watch: gh run list --workflow release-modern.yml"
