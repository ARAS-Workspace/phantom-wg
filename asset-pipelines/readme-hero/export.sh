#!/bin/bash
# export.sh — README hero PNG exporter
#
# Opens the composed README-Hero.psd and exports at multiple sizes.
# No template manipulation — PSD is already composed with devices
# and screenshots in place.
#
# Output: output/readme-hero-{W}x{H}.png
#
# Usage: ./export.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PSD="$ROOT_DIR/README-Hero.psd"
OUTPUT_DIR="$ROOT_DIR/output"

# Canvas: 6880x3440 (2:1)
SIZES=(
    "6880:3440"
    "3440:1720"
    "1920:960"
    "1200:600"
)

if [ ! -f "$PSD" ]; then
    echo "ERROR: PSD not found: $PSD"; exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "═══════════════════════════════════════════"
echo "  README Hero Export"
echo "═══════════════════════════════════════════"
echo ""
echo "Source:  $(basename "$PSD")"
echo "Sizes:   ${#SIZES[@]} variants"
echo ""

SIZE_JSX=""
for SIZE_ENTRY in "${SIZES[@]}"; do
    IFS=':' read -r SW SH <<< "$SIZE_ENTRY"
    OUT_FILE="$OUTPUT_DIR/readme-hero-${SW}x${SH}.png"
    SIZE_JSX="${SIZE_JSX}sizes.push({w:${SW}, h:${SH}, path:'${OUT_FILE}'});"$'\n'
done

JSX_TMP="/tmp/ps_hero_export_$$.jsx"
cat > "$JSX_TMP" <<JSXEOF
var doc = app.open(new File("$PSD"));

doc.flatten();

var origW = doc.width.as("px");
var origH = doc.height.as("px");

var sizes = [];
$SIZE_JSX

for (var s = 0; s < sizes.length; s++) {
    doc.resizeImage(
        UnitValue(sizes[s].w, "px"),
        UnitValue(sizes[s].h, "px"),
        null,
        ResampleMethod.BICUBICSHARPER
    );

    var opts = new PNGSaveOptions();
    opts.compression = 6;
    opts.interlaced = false;
    doc.saveAs(new File(sizes[s].path), opts, true, Extension.LOWERCASE);

    if (s < sizes.length - 1) {
        doc.resizeImage(
            UnitValue(origW, "px"),
            UnitValue(origH, "px"),
            null,
            ResampleMethod.BICUBICSHARPER
        );
    }
}

doc.close(SaveOptions.DONOTSAVECHANGES);
JSXEOF

osascript -e '
tell application "Adobe Photoshop 2026"
    activate
    do javascript file "'"$JSX_TMP"'"
end tell
' > /dev/null

rm -f "$JSX_TMP"

echo "Export complete:"
echo ""
for SIZE_ENTRY in "${SIZES[@]}"; do
    IFS=':' read -r SW SH <<< "$SIZE_ENTRY"
    FILE="$OUTPUT_DIR/readme-hero-${SW}x${SH}.png"
    if [ -f "$FILE" ]; then
        FILE_SIZE=$(du -h "$FILE" | cut -f1 | tr -d ' ')
        echo "  readme-hero-${SW}x${SH}.png  (${FILE_SIZE})"
    else
        echo "  readme-hero-${SW}x${SH}.png  (MISSING)"
    fi
done
echo ""
echo "═══════════════════════════════════════════"
echo "  Done. ${#SIZES[@]} files → output/"
echo "═══════════════════════════════════════════"
