#!/bin/bash
# export.sh — Mac branding slide generator
#
# Reads data.json, opens the template PSD for each entry:
#   1. Sets Title + Subtitle text from JSON
#   2. Opens Device Bezel smart object, places screenshot
#      below the "Hardware" layer, scaled to "Screen:" ref
#   3. Exports as PNG at multiple sizes
#   4. Closes without saving (template stays clean)
#
# Usage: ./export.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT_DIR/templates/Mac-Branding-Template.psd"
DATA="$ROOT_DIR/data.json"
OUTPUT_DIR="$ROOT_DIR/output"

SIZES=(
    "5320:3540:full"
    "2660:1770:hero"
    "1920:1278:web"
    "1200:798:social"
)

if [ ! -f "$TEMPLATE" ]; then
    echo "ERROR: Template not found: $TEMPLATE"; exit 1
fi
if [ ! -f "$DATA" ]; then
    echo "ERROR: data.json not found: $DATA"; exit 1
fi

TOTAL=$(python3 -c "import json; print(len(json.load(open('$DATA'))))")
if [ "$TOTAL" -eq 0 ]; then
    echo "No entries in data.json"; exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "═══════════════════════════════════════════"
echo "  Mac Branding Export"
echo "═══════════════════════════════════════════"
echo ""
echo "Template:  $(basename "$TEMPLATE")"
echo "Slides:    $TOTAL"
echo "Sizes:     ${#SIZES[@]} variants per slide"
echo ""

for i in $(seq 0 $((TOTAL - 1))); do
    TITLE=$(python3 -c "import json; print(json.load(open('$DATA'))[$i]['title'])")
    DESC=$(python3 -c "import json; print(json.load(open('$DATA'))[$i]['description'])")
    SCREENSHOT=$(python3 -c "import json; print(json.load(open('$DATA'))[$i]['screenshot'])")
    SCREENSHOT_PATH="$ROOT_DIR/$SCREENSHOT"
    SLIDE_NUM=$((i + 1))

    if [ ! -f "$SCREENSHOT_PATH" ]; then
        echo "[${SLIDE_NUM}/${TOTAL}] SKIP — $SCREENSHOT not found"
        continue
    fi

    printf "[%d/%d] %s ... " "$SLIDE_NUM" "$TOTAL" "$TITLE"

    SLIDE_DIR="$OUTPUT_DIR/slide-${SLIDE_NUM}"
    mkdir -p "$SLIDE_DIR"

    SIZE_JSX=""
    for SIZE_ENTRY in "${SIZES[@]}"; do
        IFS=':' read -r SW SH SUFFIX <<< "$SIZE_ENTRY"
        OUT_FILE="$SLIDE_DIR/${SUFFIX}-${SW}x${SH}.png"
        SIZE_JSX="${SIZE_JSX}sizes.push({w:${SW}, h:${SH}, path:'${OUT_FILE}'});"$'\n'
    done

    JSX_TMP="/tmp/ps_mac_export_$$.jsx"
    cat > "$JSX_TMP" <<JSXEOF
var doc = app.open(new File("$TEMPLATE"));

doc.artLayers.getByName("Title").textItem.contents = "$TITLE";
try { doc.artLayers.getByName("Subtitle").textItem.contents = "$DESC"; } catch(e) {}

// Find and open bezel SO
var mockupGroup = doc.layerSets.getByName("Device Mockup");
var bezelLayer = null;
for (var j = 0; j < mockupGroup.layers.length; j++) {
    if (mockupGroup.layers[j].name.indexOf("Device Bezel") === 0) {
        bezelLayer = mockupGroup.layers[j];
        break;
    }
}

if (bezelLayer) {
    doc.activeLayer = bezelLayer;
    executeAction(stringIDToTypeID("placedLayerEditContents"), new ActionDescriptor(), DialogModes.NO);

    var soDoc = app.activeDocument;

    // Find reference layers
    var hwLayer = null;
    var screenRef = null;
    for (var k = 0; k < soDoc.layers.length; k++) {
        if (soDoc.layers[k].name.indexOf("Hardware") === 0) hwLayer = soDoc.layers[k];
        if (soDoc.layers[k].name.indexOf("Screen:") === 0) screenRef = soDoc.layers[k];
    }

    // Place screenshot
    var placeDesc = new ActionDescriptor();
    placeDesc.putPath(stringIDToTypeID("null"), new File("$SCREENSHOT_PATH"));
    placeDesc.putEnumerated(
        stringIDToTypeID("freeTransformCenterState"),
        stringIDToTypeID("quadCenterState"),
        stringIDToTypeID("QCSAverage")
    );
    executeAction(stringIDToTypeID("placeEvent"), placeDesc, DialogModes.NO);

    var scLayer = soDoc.activeLayer;
    scLayer.name = "Screenshot";

    // Scale + position to match Screen reference layer
    if (screenRef) {
        var refB = screenRef.bounds;
        var targetW = refB[2].as("px") - refB[0].as("px");
        var targetX = refB[0].as("px");
        var targetY = refB[1].as("px");

        var scB = scLayer.bounds;
        var scW = scB[2].as("px") - scB[0].as("px");
        var scalePct = (targetW / scW) * 100;
        scLayer.resize(scalePct, scalePct, AnchorPosition.TOPLEFT);

        var newB = scLayer.bounds;
        scLayer.translate(targetX - newB[0].as("px"), targetY - newB[1].as("px"));
    }

    // Move below hardware layer
    if (hwLayer) {
        scLayer.move(hwLayer, ElementPlacement.PLACEAFTER);
    }

    soDoc.save();
    soDoc.close();
}

// Export at multiple sizes
var sizes = [];
$SIZE_JSX

doc.flatten();

var origW = doc.width.as("px");
var origH = doc.height.as("px");

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
    echo "done"
done

echo ""
echo "═══════════════════════════════════════════"
EXPORTED=$(find "$OUTPUT_DIR" -name "*.png" -type f | wc -l | tr -d ' ')
echo "  Done. $EXPORTED files → output/"
echo ""
echo "  Sizes per slide:"
for SIZE_ENTRY in "${SIZES[@]}"; do
    IFS=':' read -r SW SH SUFFIX <<< "$SIZE_ENTRY"
    echo "    ${SUFFIX}: ${SW}×${SH}"
done
echo "═══════════════════════════════════════════"
