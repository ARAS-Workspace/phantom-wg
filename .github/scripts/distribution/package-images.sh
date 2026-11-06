#!/usr/bin/env bash
# Trigger the release-base-images workflow.
# The current version is read from tools/compose/registry.yml (the pins).
# Creates base-images-v{version} tag on the pushed head of dev/daemon and
# pushes it. The workflow commits the new pins: pull them afterwards.
# Usage:
#   .github/scripts/distribution/package-images.sh           → 1.0.0 → 1.0.1
#   .github/scripts/distribution/package-images.sh minor     → 1.0.0 → 1.1.0
#   .github/scripts/distribution/package-images.sh major     → 1.0.0 → 2.0.0
#   .github/scripts/distribution/package-images.sh 1.0.0     → the given version
#   .github/scripts/distribution/package-images.sh --dry ... → the plan and the checks only
set -euo pipefail

BRANCH="dev/daemon"
TAG_PREFIX="base-images-v"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PINS="${REPO_ROOT}/tools/compose/registry.yml"

DRY=false
PART="patch"
for arg in "$@"; do
    case "$arg" in
        --dry) DRY=true ;;
        major|minor|patch) PART="$arg" ;;
        *)
            if [[ ! "$arg" =~ $VERSION_RE ]]; then
                echo "Usage: package-images.sh [--dry] [major|minor|patch|X.Y.Z]"
                exit 1
            fi
            PART="$arg"
            ;;
    esac
done

# Read the current version
CURRENT=$(sed -n 's/^    image: .*:\([^:@]*\)@sha256:.*/\1/p' "$PINS" | sort -u)
if [[ -z "$CURRENT" || "$CURRENT" == *$'\n'* ]]; then
    echo "${PINS} does not hold one version:"
    echo "${CURRENT:-(none)}"
    exit 1
fi

is_newer() {
    local a1 a2 a3 b1 b2 b3
    IFS='.' read -r a1 a2 a3 <<< "$1"
    IFS='.' read -r b1 b2 b3 <<< "$2"
    if ((a1 != b1)); then ((a1 > b1)); return; fi
    if ((a2 != b2)); then ((a2 > b2)); return; fi
    ((a3 > b3))
}

# Work out the next version
if [[ "$PART" =~ $VERSION_RE ]]; then
    NEW="$PART"
    if [[ "$CURRENT" =~ $VERSION_RE ]] && ! is_newer "$NEW" "$CURRENT"; then
        echo "${NEW} is not newer than ${CURRENT}."
        exit 1
    fi
elif [[ "$CURRENT" =~ $VERSION_RE ]]; then
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    case "$PART" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        patch) PATCH=$((PATCH + 1)) ;;
    esac
    NEW="${MAJOR}.${MINOR}.${PATCH}"
else
    echo "Current pins carry ${CURRENT}: give the version, for example 1.0.0."
    exit 1
fi

TAG="${TAG_PREFIX}${NEW}"

echo "Current : ${CURRENT}"
echo "Next    : ${NEW}"
echo "Tag     : ${TAG}"
echo "Commit  : $(git -C "${REPO_ROOT}" log -1 --format='%h %s')"
echo ""

# Checks
FAILED=0

check() {
    if [[ "$1" == ok ]]; then
        echo "  ok    $2"
    else
        echo "  FAIL  $2"
        FAILED=1
    fi
}

ON_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
if [[ "$ON_BRANCH" == "$BRANCH" ]]; then
    check ok "on ${BRANCH}"
else
    check fail "on ${ON_BRANCH}, not ${BRANCH}"
fi

if [[ -z "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    check ok "tree clean"
else
    check fail "tree has changes"
fi

if ! git -C "${REPO_ROOT}" fetch -q origin "$BRANCH"; then
    check fail "origin/${BRANCH} could not be fetched"
elif [[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" == "$(git -C "${REPO_ROOT}" rev-parse "origin/${BRANCH}")" ]]; then
    check ok "HEAD is origin/${BRANCH}"
else
    AHEAD="$(git -C "${REPO_ROOT}" rev-list --count "origin/${BRANCH}..HEAD")"
    BEHIND="$(git -C "${REPO_ROOT}" rev-list --count "HEAD..origin/${BRANCH}")"
    check fail "HEAD differs from origin/${BRANCH}: ${AHEAD} ahead, ${BEHIND} behind"
fi

if git -C "${REPO_ROOT}" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    check fail "tag exists here"
elif [[ -n "$(git -C "${REPO_ROOT}" ls-remote --tags origin "refs/tags/${TAG}")" ]]; then
    check fail "tag exists on origin"
else
    check ok "tag is free"
fi

echo ""

if [[ "$FAILED" -ne 0 ]]; then
    echo "Stopped, nothing created."
    exit 1
fi

if [[ "$DRY" == true ]]; then
    echo "Dry run: nothing created, nothing pushed."
    exit 0
fi

git -C "${REPO_ROOT}" tag "${TAG}"
if ! git -C "${REPO_ROOT}" push origin "refs/tags/${TAG}"; then
    git -C "${REPO_ROOT}" tag -d "${TAG}"
    echo "Push failed, tag removed."
    exit 1
fi

echo ""
echo "Triggered: ${TAG}"
echo "Watch: gh run list --workflow release-base-images.yml"
echo "When it finishes: git pull"
