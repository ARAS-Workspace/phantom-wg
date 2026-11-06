#!/usr/bin/env bash
# Bump daemon version (patch by default).
# Usage:
#   .github/scripts/distribution/bump.sh          → 1.0.2 → 1.0.3
#   .github/scripts/distribution/bump.sh minor    → 1.0.2 → 1.1.0
#   .github/scripts/distribution/bump.sh major    → 1.0.2 → 2.0.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
INIT_FILE="${REPO_ROOT}/phantom_daemon/__init__.py"
PART="${1:-patch}"

# Extract current version
CURRENT=$(python3 -c "
import re, pathlib
text = pathlib.Path('${INIT_FILE}').read_text()
m = re.search(r'__version__\s*=\s*\"(.+?)\"', text)
print(m.group(1))
")

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$PART" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: bump.sh [major|minor|patch]"; exit 1 ;;
esac

NEW="${MAJOR}.${MINOR}.${PATCH}"

# Update __init__.py
python3 -c "
import pathlib
p = pathlib.Path('${INIT_FILE}')
p.write_text(p.read_text().replace('__version__ = \"${CURRENT}\"', '__version__ = \"${NEW}\"'))
"

echo "${CURRENT} → ${NEW}"

# Commit
git -C "${REPO_ROOT}" add "${INIT_FILE}"
git -C "${REPO_ROOT}" commit -m "Bump v${NEW}"

echo ""
echo "Push, wait for CI, then run: .github/scripts/distribution/release.sh"
