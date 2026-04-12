#!/usr/bin/env bash
# Trigger the push-documents workflow.
# Deletes existing tag if present, creates and pushes.
# Usage: .github/scripts/push-documents.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TAG="push-documents"

echo "Triggering: ${TAG}"

# Clean existing tag
git -C "${REPO_ROOT}" tag -d "${TAG}" 2>/dev/null || true
git -C "${REPO_ROOT}" push origin ":refs/tags/${TAG}" 2>/dev/null || true

# Create and push
git -C "${REPO_ROOT}" tag "${TAG}"
git -C "${REPO_ROOT}" push origin "${TAG}"

echo "Done. Watch: gh run list --repo ARAS-Workspace/phantom-wg --workflow push-documents.yml"
