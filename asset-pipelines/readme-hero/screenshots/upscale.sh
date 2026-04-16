#!/bin/bash
# upscale.sh — Upscale raw screenshots to 3458×2236
#
# Reads PNGs from raw-screenshots/, scales to target size,
# saves to output/upscaled-screenshots/ with original filenames.
#
# Uses sips (macOS built-in) with Lanczos resampling.
#
# Usage: ./upscale.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_DIR="$ROOT_DIR/raw-screenshots"
OUTPUT_DIR="$ROOT_DIR/output/upscaled-screenshots"

TARGET_W=3458
TARGET_H=2236

mkdir -p "$OUTPUT_DIR"

FILES=("$INPUT_DIR"/*.png)

if [ ! -f "${FILES[0]}" ]; then
    echo "No PNG files found in raw-screenshots/"
    exit 1
fi

TOTAL=${#FILES[@]}

echo "═══════════════════════════════════════════"
echo "  Screenshot Upscale (${TARGET_W}×${TARGET_H})"
echo "═══════════════════════════════════════════"
echo ""

COUNT=0
for FILE in "${FILES[@]}"; do
    FILENAME=$(basename "$FILE")
    OUT_FILE="$OUTPUT_DIR/$FILENAME"
    COUNT=$((COUNT + 1))

    printf "[%d/%d] %s ... " "$COUNT" "$TOTAL" "$FILENAME"

    cp "$FILE" "$OUT_FILE"
    sips -z "$TARGET_H" "$TARGET_W" "$OUT_FILE" > /dev/null 2>&1

    echo "done"
done

echo ""
echo "═══════════════════════════════════════════"
echo "  Done. $COUNT files → output/upscaled-screenshots/"
echo "═══════════════════════════════════════════"
