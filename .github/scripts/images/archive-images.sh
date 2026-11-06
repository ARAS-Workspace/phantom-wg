#!/usr/bin/env bash
# Adds images/ to a package tree: the pinned images of one architecture, with
# VERSION and SHA256SUMS, and selects the archive source for the package.
# Usage: .github/scripts/images/archive-images.sh <package dir> <amd64|arm64>
set -euo pipefail

PACKAGE="${1:?package dir}"
ARCH="${2:?architecture}"

cd "${PACKAGE}"
mkdir -p images

for ENTRY in daemon=phantom-daemon-base auth-service=phantom-auth-base nginx=phantom-nginx-base; do
    SERVICE="${ENTRY%%=*}"
    NAME="${ENTRY#*=}"
    REF="$(docker compose -f tools/compose/registry.yml config --images "${SERVICE}")"
    docker pull -q --platform "linux/${ARCH}" "${REF}"
    docker tag "${REF}" "${NAME}:archive"
    docker save --platform "linux/${ARCH}" -o "images/${NAME}.tar" "${NAME}:archive"
    docker image rm "${NAME}:archive" > /dev/null
done

sed -n 's/^    image: .*:\([^:@]*\)@sha256:.*/\1/p' tools/compose/registry.yml | sort -u > images/VERSION
(cd images && sha256sum ./*.tar | sed 's| \./| |' > SHA256SUMS)

sed 's/^PHANTOM_IMAGE_SOURCE=.*/PHANTOM_IMAGE_SOURCE=archive/' .env.example > .env.example.tmp
mv .env.example.tmp .env.example

echo "images/: $(cat images/VERSION), linux/${ARCH}, $(du -sh images | cut -f1)"
