// Mirage app icon v2 — clear sky, straight horizon, photoreal sand, inferior mirage, floating cursor.
var sketch = require('sketch');
var UI = require('sketch/ui');
var Document = sketch.Document, Artboard = sketch.Artboard, ShapePath = sketch.ShapePath,
    Rectangle = sketch.Rectangle, Group = sketch.Group, Style = sketch.Style, Image = sketch.Image;

var OUT = null; // resolved in onRun from the plugin's location
var HORIZON = 620;
var LOGS = [];
function dbg(s) { LOGS.push(String(s)); try { NSString.stringWithString(LOGS.join('\n')).writeToFile_atomically_encoding_error(OUT + '/build.log', true, 4, null); } catch (e) {} }

function arr(v) { if (Array.isArray(v)) return v; var a = []; a.push(v); return a; }
function lin(stops, from, to) {
  return { fillType: Style.FillType.Gradient, gradient: { gradientType: Style.GradientType.Linear,
    from: from || { x: 0.5, y: 0 }, to: to || { x: 0.5, y: 1 },
    stops: stops.map(function (s) { return { position: s[0], color: s[1] }; }) } };
}
function rad(stops, from, to, aspect) {
  return { fillType: Style.FillType.Gradient, gradient: { gradientType: Style.GradientType.Radial,
    from: from || { x: 0.5, y: 0.5 }, to: to || { x: 0.5, y: 1 }, aspectRatio: aspect || 1,
    stops: stops.map(function (s) { return { position: s[0], color: s[1] }; }) } };
}
function solid(c) { return { fillType: Style.FillType.Color, color: c }; }
function applyExtra(s, extra) { if (!extra) return s; Object.keys(extra).forEach(function (k) { s.style[k] = extra[k]; }); return s; }
function rect(parent, name, x, y, w, h, fills, extra) {
  var s = new ShapePath({ name: name, parent: parent, shapeType: ShapePath.ShapeType.Rectangle,
    frame: new Rectangle(x, y, w, h), style: { fills: arr(fills), borders: [] } });
  return applyExtra(s, extra);
}
function oval(parent, name, x, y, w, h, fills, extra) {
  var s = new ShapePath({ name: name, parent: parent, shapeType: ShapePath.ShapeType.Oval,
    frame: new Rectangle(x, y, w, h), style: { fills: arr(fills), borders: [] } });
  return applyExtra(s, extra);
}
function path(parent, name, d, fills, extra) {
  var s = ShapePath.fromSVGPath(d); s.name = name; s.parent = parent;
  s.style = { fills: arr(fills), borders: [] };
  return applyExtra(s, extra);
}
function radius(shape, r, smooth) {
  shape.points.forEach(function (p) { p.cornerRadius = r; });
  if (smooth) { try { shape.sketchObject.setPointRadiusBehaviour(2); } catch (e) {} }
  return shape;
}
function G(name, parent) { return new Group({ name: name, parent: parent, frame: new Rectangle(0, 0, 1024, 1024) }); }
function blur(r) { return { blurType: Style.BlurType.Gaussian, radius: r, enabled: true }; }

// macOS arrow pointer, 1 unit = design px; tip at (0,0). Classic proportions (w 60 : h 95).
var ARROW = 'M0,0 L0,82 L19.5,64 L33.5,95 L47.5,88.5 L33.5,58.5 L60,58.5 Z';


// Inverted, squashed copy of the pointer whose outline is displaced horizontally by a smooth
// shimmer function of depth. Edges are subdivided so the wobble shows along vertical edges.
var ARROW_PTS = [[0, 0], [0, 82], [19.5, 64], [33.5, 95], [47.5, 88.5], [33.5, 58.5], [60, 58.5]];
// Heat-shimmer warp for the inverted image. Primary motion is VERTICAL: rows are pushed up/down by a
// sine keyed on depth below the horizon (like a rippled water reflection), amplitude growing with depth.
// A much shorter-wavelength, small horizontal jiggle rides on top.
var BAND = 56;   // px below the horizon where the mirage sheet has faded out (matches gen_textures band)
function warpY(r) { return (0.8 + 0.075 * r) * Math.sin(r / 2.6 + 0.6) + (0.4 + 0.03 * r) * Math.sin(r / 6.1 + 2.0); }
function warpX(r) { return 1.1 * Math.sin(r / 0.9) + 0.6 * Math.sin(r / 1.7 + 1.0); }
function displacedReflection(scale, cx, cy) {
  var squash = 0.5, bottom = cy + 95 * scale;
  function map(p) { var X = cx + p[0] * scale, Y = cy + p[1] * scale; return [X, HORIZON + (bottom - Y) * squash]; }
  var out = [];
  for (var i = 0; i < ARROW_PTS.length; i++) {
    var a = map(ARROW_PTS[i]), b = map(ARROW_PTS[(i + 1) % ARROW_PTS.length]);
    var len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    var n = Math.max(1, Math.ceil(len / 1.2));            // dense sampling on every edge so the y-warp shows
    for (var k = 0; k < n; k++) {
      var t = k / n, x = a[0] + (b[0] - a[0]) * t, y = a[1] + (b[1] - a[1]) * t;
      var r = Math.max(0, y - HORIZON);
      var yy = Math.max(HORIZON, y + warpY(r)), xx = x + warpX(r);
      out.push([xx.toFixed(2), yy.toFixed(2)]);
    }
  }
  return 'M' + out.map(function (q) { return q[0] + ',' + q[1]; }).join(' L') + ' Z';
}

function buildIcon(ab, opts) {
  var icon = G('Icon', ab);
  var mask = radius(rect(icon, 'Squircle Mask', 100, 100, 824, 824, solid('#FFFFFF')), 185, true);
  mask.sketchObject.hasClippingMask = true;

  // ---- SKY: clear daytime, zenith saturated, pale and hazy at the horizon
  var sky = G('Sky', icon);
  rect(sky, 'Sky Gradient', 0, 0, 1024, HORIZON, lin([
    [0.00, '#1E5FCF'], [0.30, '#3C7FE0'], [0.62, '#79B0EE'], [0.86, '#B8D9F7'], [1.00, '#DCEEFC']
  ]));
  // sun is out of frame upper-left: a wide soft brightening of the sky toward that corner
  oval(sky, 'Sun Wash', -420, -520, 1100, 1100, rad([[0, 'rgba(255,255,255,0.35)'], [1, 'rgba(255,255,255,0)']]));
  // atmospheric haze sitting on the horizon
  rect(sky, 'Horizon Haze', 0, HORIZON - 160, 1024, 160, lin([[0, 'rgba(236,243,250,0)'], [0.6, 'rgba(238,244,250,0.22)'], [1, 'rgba(240,245,250,0.5)']]));

  // ---- SAND: procedural raster plane (grain, speckle, ripples, mirage band baked in)
  var sand = G('Sand', icon);
  var sandImg = new Image({ name: 'Sand Plane', parent: sand, image: OUT + '/export/textures/sand.png',
    frame: new Rectangle(0, HORIZON, 1024, 1024 - HORIZON) });
  // heat shimmer: horizontal motion blur of whatever is behind, right at the horizon line
  var shimmer = G('Heat Shimmer', sand);
  var shimMask = rect(shimmer, 'Shimmer Fade', 0, HORIZON - 14, 1024, 64, lin([
    [0, 'rgba(0,0,0,0)'], [0.3, 'rgba(0,0,0,1)'], [0.7, 'rgba(0,0,0,1)'], [1, 'rgba(0,0,0,0)']]));
  shimMask.sketchObject.hasClippingMask = true; shimMask.sketchObject.clippingMaskMode = 1;
  rect(shimmer, 'Shimmer Blur', 0, HORIZON - 14, 1024, 64, solid('rgba(255,255,255,0.01)'),
    { blur: { blurType: Style.BlurType.Background, radius: 5, enabled: true } });
  // ---- optional WINDOW (glass frame) hovering above the horizon
  if (opts.window) {
    var win = G('Window', icon);
    var wx = 262, wy = 262, ww = 500, wh = 320, wr = 40;
    var glass = radius(rect(win, 'Glass', wx, wy, ww, wh,
      lin([[0, 'rgba(255,255,255,0.34)'], [1, 'rgba(255,255,255,0.10)']], { x: 0.2, y: 0 }, { x: 0.8, y: 1 }), {
      borders: [{ color: 'rgba(255,255,255,0.85)', thickness: 3, position: Style.BorderPosition.Inside }],
      shadows: [{ color: 'rgba(20,50,110,0.28)', blur: 50, x: 0, y: 24, spread: 0 }],
      innerShadows: [{ color: 'rgba(255,255,255,0.6)', blur: 2, x: 0, y: 1, spread: 0 }]
    }), wr, true);
    radius(rect(win, 'Title Bar', wx, wy, ww, 64, lin([[0, 'rgba(255,255,255,0.35)'], [1, 'rgba(255,255,255,0)']])), wr, true);
    rect(win, 'Title Divider', wx + 2, wy + 64, ww - 4, 2, solid('rgba(255,255,255,0.45)'));
    var tl = G('Traffic Lights', win);
    oval(tl, 'Close', wx + 30, wy + 22, 20, 20, lin([[0, '#FF7B72'], [1, '#F0493B']]));
    oval(tl, 'Minimize', wx + 62, wy + 22, 20, 20, lin([[0, '#FFD05A'], [1, '#F0A51B']]));
    oval(tl, 'Zoom', wx + 94, wy + 22, 20, 20, lin([[0, '#5DE07A'], [1, '#1FAF3F']]));
    tl.adjustToFit(); win.adjustToFit();
  }

  // ---- CURSOR geometry
  var scale = opts.cursorScale, cx = opts.cursorX, cy = opts.cursorY;
  function arrow(parent, name, fills, extra) {
    var a = path(parent, name, ARROW, fills, extra);
    var f = a.frame; f.width = 60 * scale; f.height = 95 * scale; f.x = cx; f.y = cy; a.frame = f;
    return a;
  }

  // ---- MIRAGE REFLECTION (part of the ground, not the pointer): inverted, squashed, outline displaced
  var refl = G('Mirage Reflection', sand);
  var reflMask = rect(refl, 'Reflection Fade', cx - 80, HORIZON, 60 * scale + 160, BAND, lin([
    [0, 'rgba(0,0,0,1)'], [0.25, 'rgba(0,0,0,0.9)'], [0.5, 'rgba(0,0,0,0.55)'], [0.75, 'rgba(0,0,0,0.2)'], [1, 'rgba(0,0,0,0)']]));
  reflMask.sketchObject.hasClippingMask = true; reflMask.sketchObject.clippingMaskMode = 1;
  path(refl, 'Reflected Pointer', displacedReflection(scale, cx, cy),
    lin([[0, 'rgba(70,84,110,0.48)'], [1, 'rgba(70,84,110,0.2)']]), { blur: blur(5) });
  // bright turbulent air veils the inverted image
  rect(refl, 'Air Veil', cx - 80, HORIZON, 60 * scale + 160, BAND, lin([[0, 'rgba(226,238,252,0.55)'], [1, 'rgba(226,238,252,0)']]));
  refl.adjustToFit();

  // ---- CURSOR: the macOS pointer standing on the vanishing line, its base dissolving into the sheet of light
  var cur = G('Cursor', icon);
  var curMask = rect(cur, 'Base Dissolve Mask', cx - 40, cy - 40, 60 * scale + 80, HORIZON - cy + 40, lin([
    [0, 'rgba(0,0,0,1)'], [0.86, 'rgba(0,0,0,1)'], [0.95, 'rgba(0,0,0,0.6)'], [1, 'rgba(0,0,0,0.15)']]));
  curMask.sketchObject.hasClippingMask = true; curMask.sketchObject.clippingMaskMode = 1;
  arrow(cur, 'Pointer Keyline', solid('#FFFFFF'), {
    borders: [{ color: '#FFFFFF', thickness: 6 * scale / 3, position: Style.BorderPosition.Outside }],
    shadows: [{ color: 'rgba(10,20,50,0.16)', blur: 30, x: 0, y: 12, spread: 0 }]
  });
  arrow(cur, 'Pointer', lin([[0, '#2B2F3A'], [0.6, '#15171D'], [1, '#0A0B0F']], { x: 0.2, y: 0 }, { x: 0.8, y: 1 }));
  arrow(cur, 'Pointer Edge Light', lin([[0, 'rgba(255,255,255,0.28)'], [0.25, 'rgba(255,255,255,0)'], [1, 'rgba(255,255,255,0)']], { x: 0, y: 0.5 }, { x: 1, y: 0.5 }));
  cur.adjustToFit();

  sky.adjustToFit(); shimmer.adjustToFit(); sand.adjustToFit();
  return icon;
}

function resolveOut(context) {
  var p = decodeURIComponent(String(context.scriptPath));
  return p.replace(/\/mirage-icon\.sketchplugin\/Contents\/Sketch\/[^\/]*$/, '');
}
function onRun(context) {
  OUT = resolveOut(context);
  dbg('start');
  sketch.getDocuments().filter(function (d) { return /^(Untitled|Mirage Icon)/.test(String(d.sketchObject.displayName())) && !/^Untitled 2/.test(String(d.sketchObject.displayName())); })
    .forEach(function (d) { try { d.sketchObject.updateChangeCount(2); d.sketchObject.close(); } catch (e) {} });
  var doc = new Document();
  var page = doc.selectedPage; page.name = 'Icon';

  var A = new Artboard({ name: 'Mirage 1024', parent: page, frame: new Rectangle(0, 0, 1024, 1024), background: { enabled: true, color: '#1E1E1E', includedInExport: false } });
  buildIcon(A, { window: false, cursorScale: 3.3, cursorX: 432, cursorY: HORIZON - 95 * 3.3 });
  dbg('A built');
  var variants = new sketch.Page({ name: 'Variants', parent: doc });
  var B = new Artboard({ name: 'Mirage 1024 (window variant)', parent: variants, frame: new Rectangle(0, 0, 1024, 1024), background: { enabled: true, color: '#1E1E1E', includedInExport: false } });
  buildIcon(B, { window: true, cursorScale: 2.4, cursorX: 560, cursorY: 400 });
  dbg('B built');

  doc.selectedPage = page;
  doc.centerOnLayer(A);
  doc.save(OUT + '/Mirage Icon.sketch', { saveMode: Document.SaveMode.SaveAs }, function (err) { dbg(err ? 'save error ' + err : 'saved'); });
  UI.message('Mirage icon v2 built');
}
