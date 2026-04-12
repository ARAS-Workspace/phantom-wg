// noinspection ALL

var doc = app.activeDocument;
var out = "";

function dumpLayer(layer, indent) {
    var b = layer.bounds;
    var x = b[0].as("px");
    var y = b[1].as("px");
    var w = b[2].as("px") - x;
    var h = b[3].as("px") - y;
    out += indent + layer.name + "  →  X:" + x + " Y:" + y + " W:" + w + " H:" + h + "\n";
}

function walk(layers, indent) {
    for (var i = 0; i < layers.length; i++) {
        var l = layers[i];
        if (l.typename === "LayerSet") {
            out += indent + "[Group] " + l.name + "\n";
            walk(l.layers, indent + "  ");
        } else {
            dumpLayer(l, indent);
        }
    }
}

walk(doc.layers, "");
alert(out);