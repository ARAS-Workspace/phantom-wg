// noinspection ALL

/*
 * build-starter-kit.jsx
 * Creates a 6880x3440 (2:1) README hero template PSD with:
 *   - 5 gradient background alternatives (toggle visibility)
 *   - "Mac Device" layer group:
 *       - Device bezel smart object (4260x2840, native mockup PSD)
 *       - Screen Content smart object (3840x2490, screenshot area)
 *   - "iOS Device" layer group:
 *       - Device bezel smart object (1008x1952, native mockup PSD)
 *       - Screen Content smart object (888x1862, screenshot area)
 *   - Title + Subtitle text layers
 *
 * Target: GitHub README hero image (renders ~980x490 on desktop, 2x retina)
 * Devices: MacBook Pro M4 14" Space Black + iPhone 15 Pro
 * Canvas: 6880x3440 (2:1 ratio — both devices at native SO size, no crop)
 *
 * Smart objects open at native resolution — place mockup PSD at 1:1.
 * Both bezels fit entirely within canvas bounds.
 *
 * Export targets (scale from canvas):
 *   - Retina:  3440x1720 (50%)
 *   - Web:     1920x960  (27.9%)
 *   - Social:  1200x600  (17.4%)
 *
 * Gradient method: Gradient Fill Layer (non-destructive, editable)
 * Uses stringIDToTypeID for PS 2026 compatibility.
 *
 * Usage: Run from Photoshop (File > Scripts > Browse)
 */

var WIDTH = 6880;
var HEIGHT = 3440;

// ── Mac — MacBook Pro 14" mockup (native SO dimensions) ────────────
var MAC_BEZEL_W = 4260;
var MAC_BEZEL_H = 2840;
var MAC_BEZEL_X = 300;
var MAC_BEZEL_Y = 500;

var MAC_SCREEN_W = 3840;
var MAC_SCREEN_H = 2490;
var MAC_SCREEN_X = MAC_BEZEL_X + 208;   // 508
var MAC_SCREEN_Y = MAC_BEZEL_Y + 59;    // 559

// ── iOS — iPhone 15 Pro mockup (native SO dimensions) ──────────────
var IOS_BEZEL_W = 1008;
var IOS_BEZEL_H = 1952;
var IOS_BEZEL_X = 5260;
var IOS_BEZEL_Y = 680;

var IOS_SCREEN_W = 888;
var IOS_SCREEN_H = 1862;
var IOS_SCREEN_X = IOS_BEZEL_X + 60;    // 5320
var IOS_SCREEN_Y = IOS_BEZEL_Y + 45;    // 725

// ── Gradients ───────────────────────────────────────────────────────
var gradients = [
    { name: "A — Midnight Blue",  top: [10,10,26],  mid: [22,22,56],  bot: [10,10,26]  },
    { name: "B — Deep Purple",    top: [10,10,20],  mid: [26,16,48],  bot: [10,10,20]  },
    { name: "C — Pure Dark",      top: [0,0,0],     mid: [17,17,17],  bot: [0,0,0]     },
    { name: "D — Teal Accent",    top: [10,10,15],  mid: [10,26,42],  bot: [10,10,15]  },
    { name: "E — Warm Dark",      top: [15,10,8],   mid: [26,20,16],  bot: [15,10,8]   }
];

// ── Helpers ─────────────────────────────────────────────────────────

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

    // Convert to Smart Object — opens at exactly w*h when double-clicked
    var smDesc = new ActionDescriptor();
    executeAction(stringIDToTypeID("newPlacedLayer"), smDesc, DialogModes.NO);

    doc.activeLayer.name = name;
    return doc.activeLayer;
}

// ── Main ────────────────────────────────────────────────────────────

var doc = app.documents.add(WIDTH, HEIGHT, 144, "README-Hero-Template", NewDocumentMode.RGB);

doc.artLayers[0].isBackgroundLayer = false;
doc.artLayers[0].name = "Base";
doc.artLayers[0].visible = false;

// ── Gradient backgrounds (only B visible) ───────────────────────────
for (var i = gradients.length - 1; i >= 0; i--) {
    var g = gradients[i];
    makeGradientFillLayer(g.name, g.top, g.mid, g.bot, g.name === "B — Deep Purple");
}

// ── iOS Device group ────────────────────────────────────────────────

var iosScreenSO = makeSmartObjectPlaceholder(
    "Screen Content (888x1862)",
    IOS_SCREEN_W, IOS_SCREEN_H,
    IOS_SCREEN_X, IOS_SCREEN_Y
);

var iosBezelSO = makeSmartObjectPlaceholder(
    "Device Bezel (1008x1952)",
    IOS_BEZEL_W, IOS_BEZEL_H,
    IOS_BEZEL_X, IOS_BEZEL_Y
);

var iosGroup = makeLayerGroup("iOS Device");

iosScreenSO.move(iosGroup, ElementPlacement.INSIDE);
doc.activeLayer = iosBezelSO;
iosBezelSO.move(iosGroup, ElementPlacement.INSIDE);

// ── Mac Device group ────────────────────────────────────────────────

var macScreenSO = makeSmartObjectPlaceholder(
    "Screen Content (3840x2490)",
    MAC_SCREEN_W, MAC_SCREEN_H,
    MAC_SCREEN_X, MAC_SCREEN_Y
);

var macBezelSO = makeSmartObjectPlaceholder(
    "Device Bezel (4260x2840)",
    MAC_BEZEL_W, MAC_BEZEL_H,
    MAC_BEZEL_X, MAC_BEZEL_Y
);

var macGroup = makeLayerGroup("Mac Device");

macScreenSO.move(macGroup, ElementPlacement.INSIDE);
doc.activeLayer = macBezelSO;
macBezelSO.move(macGroup, ElementPlacement.INSIDE);

// ── Title text ──────────────────────────────────────────────────────
var titleLayer = doc.artLayers.add();
titleLayer.kind = LayerKind.TEXT;
titleLayer.name = "Title";
var titleText = titleLayer.textItem;
titleText.contents = "Ecosystem Overview";
titleText.font = "SFProDisplay-Bold";
titleText.size = new UnitValue(168, "px");
titleText.color = hexToColor("FFFFFF");
titleText.justification = Justification.CENTER;
titleText.position = [WIDTH / 2, 200];

// ── Subtitle text ───────────────────────────────────────────────────
var subLayer = doc.artLayers.add();
subLayer.kind = LayerKind.TEXT;
subLayer.name = "Subtitle";
var subText = subLayer.textItem;
subText.contents = "Server and client, all in one";
subText.font = "SFProDisplay-Regular";
subText.size = new UnitValue(72, "px");
subText.color = hexToColor("8E8E93");
subText.justification = Justification.CENTER;
subText.position = [WIDTH / 2, 400];

alert(
    "README hero template ready!\n\n" +
    "Canvas: " + WIDTH + "\u00D7" + HEIGHT + " @144ppi (2:1)\n\n" +
    "Mac Device (native, no crop):\n" +
    "  Bezel SO:  " + MAC_BEZEL_W + "\u00D7" + MAC_BEZEL_H + " @ (" + MAC_BEZEL_X + "," + MAC_BEZEL_Y + ")\n" +
    "  Screen SO: " + MAC_SCREEN_W + "\u00D7" + MAC_SCREEN_H + " @ (" + MAC_SCREEN_X + "," + MAC_SCREEN_Y + ")\n\n" +
    "iOS Device (native, no crop):\n" +
    "  Bezel SO:  " + IOS_BEZEL_W + "\u00D7" + IOS_BEZEL_H + " @ (" + IOS_BEZEL_X + "," + IOS_BEZEL_Y + ")\n" +
    "  Screen SO: " + IOS_SCREEN_W + "\u00D7" + IOS_SCREEN_H + " @ (" + IOS_SCREEN_X + "," + IOS_SCREEN_Y + ")\n\n" +
    "Export targets (scale from canvas):\n" +
    "  Retina:  3440\u00D71720 (50%)\n" +
    "  Web:     1920\u00D7960  (27.9%)\n" +
    "  Social:  1200\u00D7600  (17.4%)\n\n" +
    "Layer structure:\n" +
    "  Title / Subtitle\n" +
    "  Mac Device (group)\n" +
    "    \u2192 Device Bezel SO (4260\u00D72840, place MacBook PSD 1:1)\n" +
    "    \u2192 Screen Content SO (3840\u00D72490, replace contents)\n" +
    "  iOS Device (group)\n" +
    "    \u2192 Device Bezel SO (1008\u00D71952, place iPhone PSD 1:1)\n" +
    "    \u2192 Screen Content SO (888\u00D71862, replace contents)\n" +
    "  Gradient backgrounds (toggle visibility, B default)"
);
