// Menu-bar template glyphs for the Mirage menu-bar app: monochrome, alpha only, 18x18 pt.
// Two candidates (pointer over its mirage reflection; pointer over heat waves), each with a
// status variant that keeps the top-right 6x6 pt clear for the updater's yellow dot.
var sketch = require('sketch');
var Artboard = sketch.Artboard, ShapePath = sketch.ShapePath, Rectangle = sketch.Rectangle, Style = sketch.Style, Page = sketch.Page;
var OUT = null, LOGS = [];
function dbg(s) { LOGS.push(String(s)); try { NSString.stringWithString(LOGS.join('\n')).writeToFile_atomically_encoding_error(OUT + '/menubar.log', true, 4, null); } catch (e) {} }
function f(v) { return v.toFixed(3); }
function pt(x, y) { var a = []; a.push(x); a.push(y); return a; }   // CocoaScript mis-parses [ident ...] literals
var ARROW_PTS = [[0, 0], [0, 82], [19.5, 64], [33.5, 95], [47.5, 88.5], [33.5, 58.5], [60, 58.5]];

function poly(parent, name, pts, opacity) {
  var d = 'M' + pts.map(function (p) { return f(p[0]) + ',' + f(p[1]); }).join(' L') + ' Z';
  var s = ShapePath.fromSVGPath(d); s.name = name; s.parent = parent;
  s.style = { fills: [{ fillType: Style.FillType.Color, color: '#000000' }], borders: [] };
  if (opacity !== undefined) s.style.opacity = opacity;
  return s;
}
function outline(parent, name, pts, w, opacity) {
  var d = 'M' + pts.map(function (p) { return f(p[0]) + ',' + f(p[1]); }).join(' L') + ' Z';
  var s = ShapePath.fromSVGPath(d); s.name = name; s.parent = parent;
  s.style = { fills: [], borders: [{ color: '#000000', thickness: w, position: Style.BorderPosition.Center }] };
  if (opacity !== undefined) s.style.opacity = opacity;
  return s;
}
// the pointer upside down (tip at the bottom), its outline carrying a simplified heat-shimmer wobble
function invertedWavyPts(x, yTop, sc, h, amp, waves) {
  var pts = arrowPts(x, yTop, sc), out = [];
  for (var i = 0; i < pts.length; i++) {
    var a = pts[i], b = pts[(i + 1) % pts.length], n = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 0.2));
    for (var k = 0; k < n; k++) {
      var t = k / n, px = a[0] + (b[0] - a[0]) * t, py = a[1] + (b[1] - a[1]) * t;
      var iy = yTop + (yTop + h - py);                                   // flip about the glyph's vertical centre
      out.push(pt(px + amp * Math.sin((iy - yTop) / h * 2 * Math.PI * waves), iy));
    }
  }
  return out;
}
function sineStroke(parent, name, x0, x1, yc, amp, wl, ph, w, n, opacity) {
  var pts = [];
  for (var i = 0; i <= n; i++) { var x = x0 + (x1 - x0) * i / n; pts.push(f(x) + ',' + f(yc + amp * Math.sin(2 * Math.PI * (x - x0) / wl + ph))); }
  var sh = ShapePath.fromSVGPath('M' + pts.join(' L')); sh.name = name; sh.parent = parent;
  sh.style = { fills: [], borders: [{ color: '#000000', thickness: w, position: Style.BorderPosition.Center }] };
  sh.style.borderOptions = { lineEnd: Style.LineEnd.Round, lineJoin: Style.LineJoin.Round };
  if (opacity !== undefined) sh.style.opacity = opacity;
  return sh;
}
function arrowPts(x, y, sc) { return ARROW_PTS.map(function (p) { return pt(x + p[0] * sc, y + p[1] * sc); }); }
// filled stroke along a sine: centre line y = yc + amp*sin(2*pi*(x - x0)/wl + ph), thickness w
function wavePts(x0, x1, yc, amp, wl, ph, w, n) {
  var top = [], bot = [];
  for (var i = 0; i <= n; i++) {
    var x = x0 + (x1 - x0) * i / n, y = yc + amp * Math.sin(2 * Math.PI * (x - x0) / wl + ph);
    top.push(pt(x, y - w / 2)); bot.push(pt(x, y + w / 2));
  }
  return top.concat(bot.reverse());
}
// inverted, squashed pointer whose edges ripple vertically (the mirage), mirrored about yLine
function reflectionPts(x, yTop, sc, yLine, squash, amp) {
  var pts = arrowPts(x, yTop, sc), out = [];
  for (var i = 0; i < pts.length; i++) {
    var a = pts[i], b = pts[(i + 1) % pts.length], n = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 0.25));
    for (var k = 0; k < n; k++) {
      var t = k / n, px = a[0] + (b[0] - a[0]) * t, py = a[1] + (b[1] - a[1]) * t;
      var ry = yLine + (yLine - py) * squash, r = ry - yLine;
      out.push(pt(px + 0.25 * Math.sin(r * 4.0), Math.max(yLine, ry + amp * Math.sin(r * 5.5 + 0.8))));
    }
  }
  return out;
}

function glyph(ab, kind, status) {
  var sc = 0.105, ax = status ? 4.2 : 5.0, ay = 1.2;              // pointer 6.3 x 10 pt, tip at (ax, ay)
  var yTop = ay + 95 * sc + 1.9, w = 1.35, xl = 2.8, xr = status ? 14.2 : 15.2;
  poly(ab, 'Pointer', arrowPts(ax, ay, sc));
  // two heat waves that interlock: same wavelength, half a cycle apart, spaced closer than twice the amplitude
  if (kind === 'wavesB') {
    // B: the second wave is the first translated down, same period, amplitude and phase: parallel rails.
    // Centre lines sit on half-pixel rows (12.5, 15.5) with a 1 pt stroke so each wave fills one clean 1x row
    // at its crests/troughs and the 2 px gap between them survives at 18 pt.
    var yA = 12.5, yB = 15.5, wv = 1.0, ampv = 0.5;
    sineStroke(ab, 'Wave 1', xl, xr, yA, ampv, 6.2, 0.35, wv, 60);
    sineStroke(ab, 'Wave 2', xl, xr, yB, ampv, 6.2, 0.35, wv, 60);
  } else {
    // A: half a cycle apart, close enough to touch at the crossings (braid)
    sineStroke(ab, 'Wave 1', xl, xr, yTop, 0.7, 6.2, 0.35, w, 60);
    sineStroke(ab, 'Wave 2', xl, xr, yTop + 2.4, 0.7, 6.2, 0.35 + Math.PI, w, 60);
  }
}

function onRun(context) {
  OUT = decodeURIComponent(String(context.scriptPath)).replace(/\/mirage-icon\.sketchplugin\/Contents\/Sketch\/[^\/]*$/, '');
  var doc = sketch.getDocuments().filter(function (d) { return /^Mirage Icon/.test(String(d.sketchObject.displayName())); })[0];
  if (!doc) { dbg('no Mirage doc'); return; }
  doc.pages.filter(function (p) { return p.name === 'Menu Bar'; }).forEach(function (p) { p.remove(); });
  var page = new Page({ name: 'Menu Bar', parent: doc });
  var specs = [['MirageMenuBar', 'wavesB', false], ['MirageMenuBarStatus', 'wavesB', true]];
  var boards = specs.map(function (sp, i) {
    var ab = new Artboard({ name: sp[0], parent: page, frame: new Rectangle(i * 40, 0, 18, 18), background: { enabled: false, includedInExport: false } });
    glyph(ab, sp[1], sp[2]);
    return ab;
  });
  sketch.export(boards, { formats: 'pdf', output: OUT + '/export/menubar', overwriting: true });
  sketch.export(boards, { formats: 'png', scales: '1,2', output: OUT + '/export/menubar', overwriting: true, 'save-for-web': true });   // mac idiom has no 3x
  dbg('exported ' + boards.length);
  doc.save(function (err) { dbg(err ? 'save err ' + err : 'saved'); });
}
