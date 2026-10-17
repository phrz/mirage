// Exports Icon Composer layers: one 1024x1024 artboard per layer group on a separate page.
var sketch = require('sketch');
var Artboard = sketch.Artboard, Rectangle = sketch.Rectangle, Page = sketch.Page;
var OUT = null; // resolved in onRun from the plugin's location
var LOGS = [];
function dbg(s) { LOGS.push(String(s)); try { NSString.stringWithString(LOGS.join('\n')).writeToFile_atomically_encoding_error(OUT + '/export.log', true, 4, null); } catch (e) {} }

function resolveOut(context) {
  var p = decodeURIComponent(String(context.scriptPath));
  return p.replace(/\/mirage-icon\.sketchplugin\/Contents\/Sketch\/[^\/]*$/, '');
}
function onRun(context) {
  OUT = resolveOut(context);
  var doc = sketch.getDocuments().filter(function (d) { return /^Mirage Icon/.test(String(d.sketchObject.displayName())); })[0];
  if (!doc) { dbg('no Mirage doc'); return; }
  var iconPage = doc.pages.filter(function (p) { return p.name === 'Icon'; })[0];
  var ab = iconPage.layers.filter(function (l) { return l.name === 'Mirage 1024'; })[0];
  var icon = ab.layers.filter(function (l) { return l.name === 'Icon'; })[0];

  // fresh layers page
  doc.pages.filter(function (p) { return p.name === 'Icon Composer Layers'; }).forEach(function (p) { p.remove(); });
  var page = new Page({ name: 'Icon Composer Layers', parent: doc });

  var sets = [
    ['01 Sky', ['Sky']],
    ['02 Sand', ['Sand']],
    ['03 Cursor', ['Cursor']]
  ];
  var boards = [];
  sets.forEach(function (set, i) {
    var b = new Artboard({ name: set[0], parent: page, frame: new Rectangle(i * 1124, 0, 1024, 1024), background: { enabled: false, includedInExport: false } });
    set[1].forEach(function (n) {
      var src = icon.layers.filter(function (l) { return l.name === n; })[0];
      if (!src) { dbg('missing ' + n); return; }
      var dup = src.duplicate();
      dup.parent = b;
      // duplicate() keeps the same frame relative to the original parent; both parents are 1024 at origin, so it lines up.
    });
    boards.push(b);
  });
  // also a full composite preview artboard (masked) for reference
  var full = new Artboard({ name: '00 Composite', parent: page, frame: new Rectangle(-1124, 0, 1024, 1024), background: { enabled: false, includedInExport: false } });
  var dupIcon = icon.duplicate(); dupIcon.parent = full;
  boards.push(full);

  sketch.export(boards, { formats: 'png', scales: '1', output: OUT + '/export/layers', overwriting: true, 'save-for-web': true, trimmed: false });
  
  dbg('exported ' + boards.length + ' boards');
  doc.save(function (err) { dbg(err ? 'save err ' + err : 'saved'); });
}
