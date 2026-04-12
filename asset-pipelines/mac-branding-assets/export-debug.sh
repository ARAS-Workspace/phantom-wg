#!/bin/bash
# export-debug.sh — Single slide debug
# Hardcoded values, no JSON. Saves debug.psd in current dir.
#
# Usage: ./export-debug.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT_DIR/templates/Mac-Branding-Template.psd"
OUTPUT="$ROOT_DIR/debug.psd"

TITLE="Ghost Mode"
DESC="Invisible traffic routing"
SCREENSHOT_PATH="$ROOT_DIR/screenshots/1.png"

echo "Template:   $TEMPLATE"
echo "Screenshot: $SCREENSHOT_PATH"
echo "Output:     $OUTPUT"

JSX_TMP="/tmp/ps_mac_debug_$$.jsx"
cat > "$JSX_TMP" <<JSXEOF
var doc = app.open(new File("$TEMPLATE"));

doc.artLayers.getByName("Title").textItem.contents = "$TITLE";
try { doc.artLayers.getByName("Subtitle").textItem.contents = "$DESC"; } catch(e) {}

var mockupGroup = doc.layerSets.getByName("Device Mockup");
var bezelLayer = null;
for (var j = 0; j < mockupGroup.layers.length; j++) {
    if (mockupGroup.layers[j].name.indexOf("Device Bezel") === 0) {
        bezelLayer = mockupGroup.layers[j];
        break;
    }
}

if (!bezelLayer) {
    alert("ERROR: Device Bezel layer not found");
} else {
    doc.activeLayer = bezelLayer;
    executeAction(stringIDToTypeID("placedLayerEditContents"), new ActionDescriptor(), DialogModes.NO);

    var soDoc = app.activeDocument;
    var soW = soDoc.width.as("px");
    var soH = soDoc.height.as("px");

    // Log all layers
    var info = "SO canvas: " + soW + "x" + soH + "\\n\\nLayers:\\n";
    for (var k = 0; k < soDoc.layers.length; k++) {
        var l = soDoc.layers[k];
        var b = l.bounds;
        info += "  " + l.name + " → " +
            b[0].as("px") + "," + b[1].as("px") + " " +
            (b[2].as("px") - b[0].as("px")) + "x" +
            (b[3].as("px") - b[1].as("px")) + "\\n";
    }
    alert(info);

    // Find hardware + screen ref layers
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

    var scB = scLayer.bounds;
    var scW = scB[2].as("px") - scB[0].as("px");
    var scH = scB[3].as("px") - scB[1].as("px");
    var result = "After place (auto-fit): " + scW + "x" + scH;

    if (screenRef) {
        var refB = screenRef.bounds;
        var targetW = refB[2].as("px") - refB[0].as("px");
        var targetH = refB[3].as("px") - refB[1].as("px");
        var targetX = refB[0].as("px");
        var targetY = refB[1].as("px");

        var scalePct = (targetW / scW) * 100;
        scLayer.resize(scalePct, scalePct, AnchorPosition.TOPLEFT);
        result += "\\nScale: " + scalePct.toFixed(1) + "%";

        var newB = scLayer.bounds;
        scLayer.translate(targetX - newB[0].as("px"), targetY - newB[1].as("px"));

        var finalB = scLayer.bounds;
        result += "\\nFinal: " + (finalB[2].as("px") - finalB[0].as("px")) + "x" +
            (finalB[3].as("px") - finalB[1].as("px")) +
            " at (" + finalB[0].as("px") + "," + finalB[1].as("px") + ")";
        result += "\\nTarget: " + targetW + "x" + targetH +
            " at (" + targetX + "," + targetY + ")";
    } else {
        result += "\\nWARNING: Screen ref not found";
    }

    if (hwLayer) {
        scLayer.move(hwLayer, ElementPlacement.PLACEAFTER);
        result += "\\nMoved below: " + hwLayer.name;
    }

    alert(result);

    soDoc.save();
    soDoc.close();

    doc.saveAs(new File("$OUTPUT"), new PhotoshopSaveOptions(), true, Extension.LOWERCASE);
    alert("Saved: debug.psd");
}
JSXEOF

osascript -e '
tell application "Adobe Photoshop 2026"
    activate
    do javascript file "'"$JSX_TMP"'"
end tell
' > /dev/null

rm -f "$JSX_TMP"
echo "Done → debug.psd"
