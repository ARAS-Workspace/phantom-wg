// noinspection ALL

/*
 * build-starter-kit.jsx
 * Creates a 5320×3540 branding template PSD for Phantom-WG Mac with:
 *   - 5 gradient background alternatives (toggle visibility)
 *   - "Device Mockup" layer group with:
 *       - Device bezel smart object (4260×2840, native mockup PSD)
 *       - Screen Content smart object (3840×2490, screenshot area)
 *   - Title + Subtitle text layers
 *
 * Target: Landing page, marketing materials, download page hero
 * Device: MacBook Pro M4 14" Space Black
 * Canvas: 5320×3540 (mockup native × 1.25, proportional padding)
 * Mockup SO: 4260×2840 (opens at native resolution for 1:1 placement)
 *
 * Export targets (scale from canvas):
 *   - Hero / landing:  2660×1770 (50%)
 *   - Web / marketing: 1920×1278 (36.1%)
 *   - Social:          1200×798  (22.6%)
 *
 * Device bezel smart object opens at 4260×2840. Place the mockup
 * PSD directly at 1:1 — no resizing needed.
 *
 * Screen content smart object: double-click to edit, or
 * Right-click → Replace Contents to link an external PSD.
 *
 * Gradient method: Gradient Fill Layer (non-destructive, editable)
 * Uses stringIDToTypeID for PS 2026 compatibility.
 *
 * Usage: Run from Photoshop (File → Scripts → Browse)
 */

var WIDTH = 5320;
var HEIGHT = 3540;

// MacBook Pro 14" mockup — native PSD resolution as smart object
var MOCKUP_W = 4260;
var MOCKUP_H = 2840;
var MOCKUP_X = 552;
var MOCKUP_Y = 756;

// Screen content area inside the bezel
var SCREEN_W = 3840;
var SCREEN_H = 2490;
var SCREEN_X = 760;
var SCREEN_Y = 815;

var gradients = [
    { name: "A — Midnight Blue",  top: [10,10,26],  mid: [22,22,56],  bot: [10,10,26]  },
    { name: "B — Deep Purple",    top: [10,10,20],  mid: [26,16,48],  bot: [10,10,20]  },
    { name: "C — Pure Dark",      top: [0,0,0],     mid: [17,17,17],  bot: [0,0,0]     },
    { name: "D — Teal Accent",    top: [10,10,15],  mid: [10,26,42],  bot: [10,10,15]  },
    { name: "E — Warm Dark",      top: [15,10,8],   mid: [26,20,16],  bot: [15,10,8]   }
];

// ── Helpers ───��─────────────────────────────────────────────────────

function hexToColor(hex) {
    var c = new SolidColor();
    c.rgb.red   = parseInt(hex.substring(0, 2), 16);
    c.rgb.green = parseInt(hex.substring(2, 4), 16);
    c.rgb.blue  = parseInt(hex.substring(4, 6), 16);
    return c;
}

function makeColorDesc(r, g, b) {
    var d = new ActionDescriptor();
    d.putDouble(stringIDToTypeID("red"), r);
    d.putDouble(stringIDToTypeID("grain"), g);
    d.putDouble(stringIDToTypeID("blue"), b);
    return d;
}

function makeColorStop(r, g, b, location) {
    var stop = new ActionDescriptor();
    var color = makeColorDesc(r, g, b);
    stop.putObject(stringIDToTypeID("color"), stringIDToTypeID("RGBColor"), color);
    stop.putEnumerated(stringIDToTypeID("type"), stringIDToTypeID("colorStopType"), stringIDToTypeID("userStop"));
    stop.putInteger(stringIDToTypeID("location"), location);
    stop.putInteger(stringIDToTypeID("midpoint"), 50);
    return stop;
}

function makeTransparencyStop(opacity, location) {
    var stop = new ActionDescriptor();
    stop.putUnitDouble(stringIDToTypeID("opacity"), stringIDToTypeID("percentUnit"), opacity);
    stop.putInteger(stringIDToTypeID("location"), location);
    stop.putInteger(stringIDToTypeID("midpoint"), 50);
    return stop;
}

function makeGradientFillLayer(name, topRGB, midRGB, botRGB, visible) {
    var colors = new ActionList();
    colors.putObject(stringIDToTypeID("colorStop"), makeColorStop(topRGB[0], topRGB[1], topRGB[2], 0));
    colors.putObject(stringIDToTypeID("colorStop"), makeColorStop(midRGB[0], midRGB[1], midRGB[2], 2048));
    colors.putObject(stringIDToTypeID("colorStop"), makeColorStop(botRGB[0], botRGB[1], botRGB[2], 4096));

    var trans = new ActionList();
    trans.putObject(stringIDToTypeID("transferSpec"), makeTransparencyStop(100, 0));
    trans.putObject(stringIDToTypeID("transferSpec"), makeTransparencyStop(100, 4096));

    var grad = new ActionDescriptor();
    grad.putString(stringIDToTypeID("name"), name);
    grad.putEnumerated(stringIDToTypeID("gradientForm"), stringIDToTypeID("gradientForm"), stringIDToTypeID("customStops"));
    grad.putDouble(stringIDToTypeID("interfaceIconFrameDimmed"), 4096);
    grad.putList(stringIDToTypeID("colors"), colors);
    grad.putList(stringIDToTypeID("transparency"), trans);

    var gradFill = new ActionDescriptor();
    gradFill.putObject(stringIDToTypeID("gradient"), stringIDToTypeID("gradient"), grad);
    gradFill.putEnumerated(stringIDToTypeID("type"), stringIDToTypeID("gradientType"), stringIDToTypeID("linear"));
    gradFill.putUnitDouble(stringIDToTypeID("angle"), stringIDToTypeID("angleUnit"), -90);
    gradFill.putUnitDouble(stringIDToTypeID("scale"), stringIDToTypeID("percentUnit"), 100);
    gradFill.putBoolean(stringIDToTypeID("reverse"), false);
    gradFill.putBoolean(stringIDToTypeID("dither"), true);
    gradFill.putBoolean(stringIDToTypeID("alignWithLayer"), true);

    var layerDesc = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putClass(stringIDToTypeID("contentLayer"));
    layerDesc.putReference(stringIDToTypeID("null"), ref);

    var usingDesc = new ActionDescriptor();
    usingDesc.putString(stringIDToTypeID("name"), name);
    usingDesc.putObject(stringIDToTypeID("type"), stringIDToTypeID("gradientLayer"), gradFill);

    layerDesc.putObject(stringIDToTypeID("using"), stringIDToTypeID("contentLayer"), usingDesc);

    executeAction(stringIDToTypeID("make"), layerDesc, DialogModes.NO);

    var activeLayer = app.activeDocument.activeLayer;
    activeLayer.visible = visible;

    return activeLayer;
}

function makeLayerGroup(name) {
    var desc = new ActionDescriptor();
    var ref = new ActionReference();
    ref.putClass(stringIDToTypeID("layerSection"));
    desc.putReference(stringIDToTypeID("null"), ref);

    var groupDesc = new ActionDescriptor();
    groupDesc.putString(stringIDToTypeID("name"), name);
    desc.putObject(stringIDToTypeID("using"), stringIDToTypeID("layerSection"), groupDesc);

    executeAction(stringIDToTypeID("make"), desc, DialogModes.NO);
    return app.activeDocument.activeLayer;
}

function makeSmartObjectPlaceholder(name, w, h, x, y) {
    var doc = app.activeDocument;

    var layer = doc.artLayers.add();
    layer.name = name;

    var region = [
        [x, y],
        [x + w, y],
        [x + w, y + h],
        [x, y + h]
    ];
    doc.selection.select(region);

    var fillColor = new SolidColor();
    fillColor.rgb.red = 30;
    fillColor.rgb.green = 30;
    fillColor.rgb.blue = 30;
    doc.selection.fill(fillColor);
    doc.selection.deselect();

    // Convert to Smart Object — opens at exactly w×h when double-clicked
    var smDesc = new ActionDescriptor();
    executeAction(stringIDToTypeID("newPlacedLayer"), smDesc, DialogModes.NO);

    doc.activeLayer.name = name;
    return doc.activeLayer;
}

// ���─ Main ───────────────────────────────���─────────────────────────���──

var doc = app.documents.add(WIDTH, HEIGHT, 144, "Mac-Branding-Template", NewDocumentMode.RGB);

doc.artLayers[0].isBackgroundLayer = false;
doc.artLayers[0].name = "Base";
doc.artLayers[0].visible = false;

// ── Gradient backgrounds (only C visible) ───────────────────────────
for (var i = gradients.length - 1; i >= 0; i--) {
    var g = gradients[i];
    makeGradientFillLayer(g.name, g.top, g.mid, g.bot, g.name === "C — Pure Dark");
}

// ── Device Mockup group ─────────────────────────────────────────────

// Screen Content — smart object for app screenshot
var screenSO = makeSmartObjectPlaceholder(
    "Screen Content",
    SCREEN_W, SCREEN_H,
    SCREEN_X, SCREEN_Y
);

// Device Bezel — smart object at native 4260×2840
// Place the MacBook Pro mockup PSD directly at 1:1
var bezelSO = makeSmartObjectPlaceholder(
    "Device Bezel (4260×2840)",
    MOCKUP_W, MOCKUP_H,
    MOCKUP_X, MOCKUP_Y
);

var mockupGroup = makeLayerGroup("Device Mockup");

screenSO.move(mockupGroup, ElementPlacement.INSIDE);
doc.activeLayer = bezelSO;
bezelSO.move(mockupGroup, ElementPlacement.INSIDE);

// ── Title text ───────────────���──────────────────────────────────────
var titleLayer = doc.artLayers.add();
titleLayer.kind = LayerKind.TEXT;
titleLayer.name = "Title";
var titleText = titleLayer.textItem;
titleText.contents = "Ghost Mode";
titleText.font = "SFProDisplay-Bold";
titleText.size = new UnitValue(168, "px");
titleText.color = hexToColor("FFFFFF");
titleText.justification = Justification.CENTER;
titleText.position = [1742, 194];

// ── Subtitle text ───────────────────────────────────────────────────
var subLayer = doc.artLayers.add();
subLayer.kind = LayerKind.TEXT;
subLayer.name = "Subtitle";
var subText = subLayer.textItem;
subText.contents = "Invisible traffic routing";
subText.font = "SFProDisplay-Regular";
subText.size = new UnitValue(72, "px");
subText.color = hexToColor("8E8E93");
subText.justification = Justification.CENTER;
subText.position = [WIDTH / 2, 534];

alert(
    "Mac branding template ready!\n\n" +
    "Canvas: " + WIDTH + "×" + HEIGHT + " @144ppi\n" +
    "Mockup SO: " + MOCKUP_W + "×" + MOCKUP_H + " (native, 1:1)\n" +
    "Screen SO: " + SCREEN_W + "×" + SCREEN_H + "\n\n" +
    "Export targets (scale from canvas):\n" +
    "  Hero:     2660×1770 (50%)\n" +
    "  Web:      1920×1278 (36.1%)\n" +
    "  Social:   1200×798  (22.6%)\n\n" +
    "Layer structure:\n" +
    "  Title / Subtitle\n" +
    "  Device Mockup (group)\n" +
    "    → Device Bezel SO (4260×2840, place PSD 1:1)\n" +
    "    → Screen Content SO (replace contents)\n" +
    "  Gradient backgrounds (toggle visibility)"
);
