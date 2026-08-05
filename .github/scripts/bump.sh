#!/usr/bin/env bash
# Bump Mac app version (patch by default).
# Updates MARKETING_VERSION in project.yml for both app and extension targets.
# Usage:
#   .github/scripts/bump.sh          → 1.0.1 → 1.0.2
#   .github/scripts/bump.sh minor    → 1.0.1 → 1.1.0
#   .github/scripts/bump.sh major    → 1.0.1 → 2.0.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECT_YML="${REPO_ROOT}/project.yml"
PART="${1:-patch}"

# Extract current version (first MARKETING_VERSION in project.yml)
CURRENT=$(grep -m1 'MARKETING_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')

if [[ -z "$CURRENT" ]]; then
    echo "ERROR: Could not find MARKETING_VERSION in project.yml"
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$PART" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: bump.sh [major|minor|patch]"; exit 1 ;;
esac

NEW="${MAJOR}.${MINOR}.${PATCH}"

# Update all MARKETING_VERSION occurrences in project.yml
sed -i '' "s/MARKETING_VERSION: \"${CURRENT}\"/MARKETING_VERSION: \"${NEW}\"/g" "$PROJECT_YML"

# Verify — the app and all three extension targets carry the pair,
# and ExtensionIdentity derives the activation stamp from it, so a
# partial update means a stale extension would survive the release.
COUNT=$(grep -c "MARKETING_VERSION: \"${NEW}\"" "$PROJECT_YML")
if [[ "$COUNT" -ne 4 ]]; then
    echo "WARNING: Expected 4 MARKETING_VERSION entries, found ${COUNT}"
fi

echo "${CURRENT} → ${NEW}"

# Commit
git -C "${REPO_ROOT}" add "${PROJECT_YML}"
git -C "${REPO_ROOT}" commit -m "Bump v${NEW}"

echo ""
echo "Push, wait for CI, then run: .github/scripts/release.sh"
