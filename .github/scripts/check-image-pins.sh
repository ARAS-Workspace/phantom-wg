#!/usr/bin/env bash
# Checks the form of the image pins a product release packages: three published
# images under one version, described by MANIFEST.json with their sources.
# Runs from the root of the tree.
set -euo pipefail
PINS=tools/compose/registry.yml
MANIFEST=tools/compose/MANIFEST.json
PIN='^    image: ghcr\.io/aras-workspace/phantom-(daemon|auth|nginx)-base:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
if [ "$(grep -c '^    image: ' "${PINS}")" -ne 3 ] || [ "$(grep -cE "${PIN}" "${PINS}")" -ne 3 ]; then
  echo "::error::${PINS} holds an image outside the published form"
  grep '^    image: ' "${PINS}"
  exit 1
fi
if [ "$(grep -oE 'phantom-[a-z]+-base' "${PINS}" | sort -u | wc -l)" -ne 3 ]; then
  echo "::error::${PINS} does not name the three images"
  exit 1
fi
if [ "$(sed -n 's/.*:\([0-9.]*\)@sha256:.*/\1/p' "${PINS}" | sort -u | wc -l)" -ne 1 ]; then
  echo "::error::${PINS} holds more than one version"
  exit 1
fi
if [ ! -s "${MANIFEST}" ]; then
  echo "::error::${MANIFEST} is missing"
  exit 1
fi
while read -r REF; do
  if ! grep -qF "\"reference\": \"${REF}\"" "${MANIFEST}"; then
    echo "::error::${MANIFEST} does not describe ${REF}"
    exit 1
  fi
done < <(sed -n 's/^    image: //p' "${PINS}")
VERSION=$(sed -n 's/.*:\([0-9.]*\)@sha256:.*/\1/p' "${PINS}" | sort -u)
SOURCES="\"sources_image\": \"ghcr\.io/aras-workspace/phantom-sources:${VERSION//./\\.}@sha256:[0-9a-f]{64}\""
if ! grep -qE "${SOURCES}" "${MANIFEST}"; then
  echo "::error::${MANIFEST} does not name the sources of ${VERSION}"
  exit 1
fi
