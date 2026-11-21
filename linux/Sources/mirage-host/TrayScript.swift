/// The top-bar icon (`mirage-host tray`): a GJS program (GNOME's JavaScript, GTK 4 and libadwaita, present on every
/// GNOME desktop), embedded here so it updates with the host. It is the Linux twin of the Mac's menu-bar item: the same
/// menu and windows over the same local control socket (LocalControl), with "this computer" for "this Mac".
///
/// - The icon is a StatusNotifierItem with a com.canonical.dbusmenu menu (GNOME shows them through the AppIndicator
///   extension, which `mirage-host tray` turns on).
/// - Pair a Device… shows the rotating code and its QR code (drawn here: QR encoder below, byte mode, level M).
/// - Allow / Deny and Revoke are libadwaita alert dialogs.
let trayScript = #"""
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GdkPixbuf from 'gi://GdkPixbuf';
import Gtk from 'gi://Gtk?version=4.0';
import Adw from 'gi://Adw?version=1';
import System from 'system';

const SOCKET = '/run/mirage/control.sock';
const ICON_PNG = 'iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAABGdBTUEAALGPC/xhBQAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAJKADAAQAAAABAAAAJAAAAAAJxsHGAAAB20lEQVRYCe2WPSiFURjHr6/YxGYklMmADAy3SCgGJpRSMthMBmWUSXYlMhopmQyMBsnKpFh8hHx//f65p95u57r3Pe/xWt6nfp3zPuc8/+e55z3n3DeVSszfCjT7k/KjdIVMix8pPypfyNxAux+56CoqSNxBR3S56AqmILUPkI4uGU0hWJD6j9AdTTJadHZBen6Cvmiy7tG2guR7gUF3WffIXAXJ/wrD7tJukb8VpLE3GHGTdovKV5DGP2DcTT58VCEFmaImw8v/RBSFCFSyXLbLgE6cMc2dhxPj+Is2e4W0Z4xv+i8S5tM0yd+ZqFeyAsZ3Rr8EYjUlf4ahTNYm2k8wRcV6wlTDPXSpE7Bt+qago4A/lm6bJUsanylIba9lTuyuw0BRe7FntyTU3tGFuAmtlvHYXaVkrPeVtTiEkC7RAdiCW9Af6jHMwjXYrBbnEpyCrotL2IBQn8HVBEhkDCozjNLqFAU3cLCvz9pFaIQy0KtbheDlGZyv/g5IP6/1MyM72DyfMzYDNVABPSBhM57dqqA10AlVoQ2wAPoBmqtcBdkEs/ZBn6niAKagHGymhOtwAXo1urmXoQ5sVoWz0zaQ+HyuQK5TNkcSHQSbJacsOWW2fZH4/nUFvgEp89t71BFj2QAAAABJRU5ErkJggg==';

// MARK: QR codes (byte mode, error correction M), after Nayuki's reference design

const QR = (() => {
    const ECC = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28];
    const BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49];
    const FORMAT_M = 0;
    const rawModules = v => {
        let r = (16 * v + 128) * v + 64;
        if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; }
        return r;
    };
    const dataCodewords = v => Math.floor(rawModules(v) / 8) - ECC[v] * BLOCKS[v];
    const mul = (x, y) => { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11d); z ^= ((y >>> i) & 1) * x; } return z & 0xff; };
    const divisor = d => {
        const r = new Array(d).fill(0); r[d - 1] = 1; let root = 1;
        for (let i = 0; i < d; i++) { for (let j = 0; j < r.length; j++) { r[j] = mul(r[j], root); if (j + 1 < r.length) r[j] ^= r[j + 1]; } root = mul(root, 0x02); }
        return r;
    };
    const remainder = (data, div) => {
        const r = div.map(() => 0);
        for (const b of data) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => { r[i] ^= mul(c, f); }); }
        return r;
    };
    const alignment = v => {
        if (v === 1) return [];
        const n = Math.floor(v / 7) + 2, step = v === 32 ? 26 : Math.ceil((v * 4 + 4) / (n * 2 - 2)) * 2;
        const out = [6]; for (let p = v * 4 + 10; out.length < n; p -= step) out.splice(1, 0, p);
        return out;
    };
    return function encode(text) {
        const bytes = Array.from(new TextEncoder().encode(text));
        let v = 1;
        for (; v <= 40; v++) { const bits = 4 + (v < 10 ? 8 : 16) + bytes.length * 8; if (bits <= dataCodewords(v) * 8) break; }
        if (v > 40) throw new Error('too long for a QR code');
        const bits = [];
        const put = (val, n) => { for (let i = n - 1; i >= 0; i--) bits.push((val >>> i) & 1); };
        put(4, 4); put(bytes.length, v < 10 ? 8 : 16); bytes.forEach(b => put(b, 8));
        const cap = dataCodewords(v) * 8;
        put(0, Math.min(4, cap - bits.length)); put(0, (8 - bits.length % 8) % 8);
        for (let pad = 0xec; bits.length < cap; pad ^= 0xec ^ 0x11) put(pad, 8);
        const data = []; for (let i = 0; i < bits.length; i += 8) data.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
        // Blocks with their error correction, interleaved.
        const nb = BLOCKS[v], ecl = ECC[v], raw = Math.floor(rawModules(v) / 8), short = nb - raw % nb, shortLen = Math.floor(raw / nb);
        const div = divisor(ecl), blocks = [];
        for (let i = 0, k = 0; i < nb; i++) {
            const d = data.slice(k, k + shortLen - ecl + (i < short ? 0 : 1)); k += d.length;
            const e = remainder(d, div); if (i < short) d.push(0); blocks.push(d.concat(e));
        }
        const all = [];
        for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - ecl || j >= short) all.push(b[i]); });
        // The matrix.
        const size = v * 4 + 17;
        const m = Array.from({ length: size }, () => new Array(size).fill(false));
        const fn = Array.from({ length: size }, () => new Array(size).fill(false));
        const set = (x, y, on) => { m[y][x] = on; fn[y][x] = true; };
        for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
        const finder = (x, y) => { for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
            const d = Math.max(Math.abs(dx), Math.abs(dy)), xx = x + dx, yy = y + dy;
            if (xx >= 0 && xx < size && yy >= 0 && yy < size) set(xx, yy, d !== 2 && d !== 4); } };
        finder(3, 3); finder(size - 4, 3); finder(3, size - 4);
        const al = alignment(v);
        al.forEach((ax, i) => al.forEach((ay, j) => {
            if ((i === 0 && j === 0) || (i === 0 && j === al.length - 1) || (i === al.length - 1 && j === 0)) return;
            for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
        }));
        const format = mask => {
            const d = (FORMAT_M << 3) | mask; let r = d;
            for (let i = 0; i < 10; i++) r = (r << 1) ^ ((r >>> 9) * 0x537);
            const b = ((d << 10) | r) ^ 0x5412, bit = i => ((b >>> i) & 1) === 1;
            for (let i = 0; i <= 5; i++) set(8, i, bit(i));
            set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8));
            for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
            for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i));
            for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i));
            set(8, size - 8, true);
        };
        format(0);
        if (v >= 7) {
            let r = v; for (let i = 0; i < 12; i++) r = (r << 1) ^ ((r >>> 11) * 0x1f25);
            const b = (v << 12) | r;
            for (let i = 0; i < 18; i++) { const on = ((b >>> i) & 1) === 1, a = size - 11 + i % 3, c = Math.floor(i / 3); set(a, c, on); set(c, a, on); }
        }
        let i = 0;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let vert = 0; vert < size; vert++) for (let j = 0; j < 2; j++) {
                const x = right - j, upward = ((right + 1) & 2) === 0, y = upward ? size - 1 - vert : vert;
                if (!fn[y][x] && i < all.length * 8) { m[y][x] = ((all[i >>> 3] >>> (7 - (i & 7))) & 1) === 1; i++; }
            }
        }
        // Mask 0: (x + y) % 2 === 0.
        for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y][x] && (x + y) % 2 === 0) m[y][x] = !m[y][x];
        format(0);
        return m;
    };
})();

// MARK: The connection to the host (one JSON object per line)

class Control {
    constructor(onEvent, onState) { this.onEvent = onEvent; this.onState = onState; this.connected = false; }
    connect() {
        const client = new Gio.SocketClient();
        client.connect_async(Gio.UnixSocketAddress.new(SOCKET), null, (c, res) => {
            try { this.conn = c.connect_finish(res); } catch (e) { this.retry(); return; }
            this.out = this.conn.get_output_stream();
            this.inp = new Gio.DataInputStream({ base_stream: this.conn.get_input_stream() });
            this.connected = true; this.onState(true);
            this.send({ hello: { version: 1, client: 'mirage-tray' } });
            this.read();
        });
    }
    read() {
        this.inp.read_line_async(GLib.PRIORITY_DEFAULT, null, (s, res) => {
            let line = null;
            try { [line] = s.read_line_finish_utf8(res); } catch (e) { line = null; }
            if (line === null) { this.lost(); return; }
            try { this.onEvent(JSON.parse(line)); } catch (e) { logError(e); }
            this.read();
        });
    }
    lost() { if (!this.connected) return; this.connected = false; try { this.conn.close(null); } catch (e) {} this.onState(false); this.retry(); }
    retry() { GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => { this.connect(); return GLib.SOURCE_REMOVE; }); }
    send(obj) {
        if (!this.connected) return;
        try { this.out.write_all(new TextEncoder().encode(JSON.stringify(obj) + '\n'), null); } catch (e) { this.lost(); }
    }
}

// MARK: The icon and its menu (StatusNotifierItem + com.canonical.dbusmenu)

const SNI_XML = `<node><interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
  <signal name="NewIcon"/><signal name="NewTitle"/><signal name="NewToolTip"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>`;

const MENU_XML = `<node><interface name="com.canonical.dbusmenu">
  <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
  <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
  <method name="GetProperty"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
  <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
  <property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
</interface></node>`;

/// The icon, white on GNOME's dark top bar, as ARGB32 rows in network byte order.
function iconPixmap() {
    const bytes = GLib.base64_decode(ICON_PNG);
    const loader = GdkPixbuf.PixbufLoader.new(); loader.write(bytes); loader.close();
    const pb = loader.get_pixbuf().add_alpha(false, 0, 0, 0);
    const w = pb.get_width(), h = pb.get_height(), stride = pb.get_rowstride(), px = pb.get_pixels();
    const out = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const a = px[y * stride + x * 4 + 3], o = (y * w + x) * 4;
        out[o] = a; out[o + 1] = 255; out[o + 2] = 255; out[o + 3] = 255;
    }
    return [[w, h, out]];
}

class Tray {
    constructor(app) {
        this.app = app;
        this.items = [];      // [{id, label, enabled, toggle, checked, separator, children, action}]
        this.revision = 1;
        this.pixmap = iconPixmap();
        this.bus = Gio.bus_get_sync(Gio.BusType.SESSION, null);
        const self = this;
        this.sni = Gio.DBusExportedObject.wrapJSObject(SNI_XML, {
            get Category() { return 'ApplicationStatus'; }, get Id() { return 'mirage'; }, get Title() { return 'Mirage'; },
            get Status() { return 'Active'; }, get IconName() { return ''; }, get IconPixmap() { return self.pixmap; },
            get ItemIsMenu() { return true; }, get Menu() { return '/MenuBar'; },
            get ToolTip() { return ['', [], 'Mirage', '']; },
            Activate() {}, SecondaryActivate() {}, ContextMenu() {}, Scroll() {},
        });
        this.sni.export(this.bus, '/StatusNotifierItem');
        this.menu = Gio.DBusExportedObject.wrapJSObject(MENU_XML, {
            get Version() { return 3; }, get TextDirection() { return 'ltr'; }, get Status() { return 'normal'; }, get IconThemePath() { return []; },
            GetLayout: (parent, depth, names) => [self.revision, self.layout(parent)],
            GetGroupProperties: (ids, names) => ids.map(id => [id, self.props(self.find(id))]).filter(([, p]) => p),
            GetProperty: (id, name) => self.props(self.find(id))?.[name] ?? new GLib.Variant('s', ''),
            Event: (id, ev) => self.clicked(id, ev),
            EventGroup: events => { events.forEach(([id, ev]) => self.clicked(id, ev)); return []; },
            AboutToShow: () => false,
            AboutToShowGroup: () => [[], []],
        });
        this.menu.export(this.bus, '/MenuBar');
        this.name = `org.kde.StatusNotifierItem-${new Gio.Credentials().get_unix_pid()}-1`;
        Gio.bus_own_name_on_connection(this.bus, this.name, Gio.BusNameOwnerFlags.NONE, null, null);
        Gio.bus_watch_name_on_connection(this.bus, 'org.kde.StatusNotifierWatcher', Gio.BusNameWatcherFlags.NONE, () => this.register(), null);
    }
    clicked(id, ev) {
        if (ev !== 'clicked') return;
        const it = this.find(id);
        if (it?.action) GLib.idle_add(GLib.PRIORITY_DEFAULT, () => { it.action(); return GLib.SOURCE_REMOVE; });
    }
    register() {
        this.bus.call('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher', 'RegisterStatusNotifierItem',
            new GLib.Variant('(s)', [this.name]), null, Gio.DBusCallFlags.NONE, -1, null, null);
    }
    find(id, list = this.items) {
        if (id === 0) return { id: 0, children: this.items };
        for (const it of list) { if (it.id === id) return it; const c = it.children && this.find(id, it.children); if (c) return c; }
        return null;
    }
    props(it) {
        if (!it) return null;
        const p = {};
        if (it.id === 0) { p['children-display'] = new GLib.Variant('s', 'submenu'); return p; }
        if (it.separator) { p.type = new GLib.Variant('s', 'separator'); return p; }
        p.label = new GLib.Variant('s', it.label.replace(/_/g, '__'));
        p.enabled = new GLib.Variant('b', it.enabled !== false && (!!it.action || !!it.children));
        if (it.toggle) { p['toggle-type'] = new GLib.Variant('s', 'checkmark'); p['toggle-state'] = new GLib.Variant('i', it.checked ? 1 : 0); }
        if (it.children) p['children-display'] = new GLib.Variant('s', 'submenu');
        return p;
    }
    layout(id) {
        const it = this.find(id) ?? { id: 0, children: this.items };
        const kids = (it.children ?? []).map(c => new GLib.Variant('(ia{sv}av)', this.layout(c.id)));
        return [it.id, this.props(it) ?? {}, kids];
    }
    /// A new menu: [{label, action?, toggle?, checked?, enabled?, children?}] or 'separator'.
    set(items) {
        let next = 1;
        const build = list => list.map(x => x === 'separator' ? { id: next++, separator: true } :
            Object.assign({ id: next++ }, x, x.children ? { children: build(x.children) } : {}));
        this.items = build(items);
        this.revision++;
        this.menu.emit_signal('LayoutUpdated', new GLib.Variant('(ui)', [this.revision, 0]));
    }
}

// MARK: Windows

function fingerprint(hex) { return hex.slice(0, 32).match(/.{1,4}/g).join(' '); }

class PairWindow {
    constructor(app, onClose) {
        this.onClose = onClose; this.finished = false;
        this.win = new Adw.Window({ application: app, title: 'Pair a Device', default_width: 360, resizable: false });
        const view = new Adw.ToolbarView();
        view.add_top_bar(new Adw.HeaderBar());
        const box = new Gtk.Box({ orientation: Gtk.Orientation.VERTICAL, spacing: 14, margin_top: 6, margin_bottom: 24, margin_start: 24, margin_end: 24 });
        box.append(new Gtk.Label({ label: 'Scan with the Mirage app on your iPhone, or type the code on the other device.', wrap: true, justify: Gtk.Justification.CENTER, max_width_chars: 36 }));
        this.matrix = null;
        this.qr = new Gtk.DrawingArea({ content_width: 220, content_height: 220, halign: Gtk.Align.CENTER });
        this.qr.set_draw_func((area, cr, w, h) => {
            cr.setSourceRGB(1, 1, 1); cr.paint();
            if (this.matrix) {
                const n = this.matrix.length, cell = Math.floor(Math.min(w, h) / (n + 8)), off = Math.floor((Math.min(w, h) - cell * n) / 2);
                cr.setSourceRGB(0, 0, 0);
                for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (this.matrix[y][x]) cr.rectangle(off + x * cell, off + y * cell, cell, cell);
                cr.fill();
            }
            cr.$dispose();
        });
        box.append(this.qr);
        this.code = new Gtk.Label({ label: '', css_classes: ['title-1', 'monospace'] });
        box.append(this.code);
        this.status = new Gtk.Label({ label: 'Waiting for the host…', css_classes: ['dim-label'], wrap: true, justify: Gtk.Justification.CENTER });
        box.append(this.status);
        view.set_content(box);
        this.win.set_content(view);
        this.win.connect('close-request', () => { if (!this.finished) this.onClose(); return false; });
        this.win.present();
        this.timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => { this.tick(); return GLib.SOURCE_CONTINUE; });
    }
    show(p) {
        this.p = p;
        this.code.label = `${p.code.slice(0, 3)} ${p.code.slice(3)}`;
        try { this.matrix = QR(p.link); } catch (e) { this.matrix = null; }
        this.qr.queue_draw();
        this.tick();
    }
    tick() {
        if (!this.p || this.finished) return;
        const left = Math.max(0, Math.round(this.p.closesAt - Date.now() / 1000));
        this.status.label = `New code every 30 seconds. Closes in ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}.\nThis computer: ${this.p.hostName}, ${this.p.address}`;
    }
    finish(text, after) {
        this.finished = true;
        this.code.label = ''; this.matrix = null; this.qr.queue_draw();
        this.status.label = text;
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, after, () => { this.close(); return GLib.SOURCE_REMOVE; });
    }
    close() { this.finished = true; if (this.timer) GLib.source_remove(this.timer); this.timer = 0; this.win.close(); }
}

function alert(heading, body, responses, done) {
    const d = new Adw.AlertDialog({ heading, body });
    for (const [id, label, look] of responses) { d.add_response(id, label); if (look) d.set_response_appearance(id, look); }
    d.set_default_response(responses[responses.length - 1][0]);
    d.set_close_response(responses[0][0]);
    d.connect('response', (_d, id) => done(id));
    d.present(null);
    return d;
}

// MARK: The app

class MirageTray {
    constructor(app) {
        this.app = app;
        this.status = null;
        this.pairWindow = null;
        this.tray = new Tray(app);
        this.control = new Control(e => this.event(e), up => { if (!up) { this.status = null; } this.rebuild(); });
        this.control.connect();
        this.rebuild();
    }
    event(e) {
        const [kind] = Object.keys(e), body = e[kind] ?? {}, v = body._0 ?? body;
        switch (kind) {
        case 'status': this.status = v; this.rebuild(); break;
        case 'updateStatus': if (this.status) { this.status.updating = ['done', 'failed', 'rolledBack'].includes(v.phase) ? null : v; this.rebuild(); } break;
        case 'pairing': if (this.pairWindow) this.pairWindow.show(v); break;
        case 'pairingClosed':
            if (this.pairWindow && !this.pairWindow.finished)
                this.pairWindow.finish(v.reason === 'expired' ? 'The code expired. Choose Pair a Device… again for a new one.' : `Pairing closed (${v.reason}).`, 3);
            this.pairWindow = null; break;
        case 'paired': if (this.pairWindow) this.pairWindow.finish(`✓ Paired ${v.deviceName}.`, 2); this.pairWindow = null; break;
        case 'confirm':
            alert(`${v.deviceName} wants to pair with this computer.`,
                `Allow it to see and control this computer through Mirage?\n\nDevice key ${fingerprint(v.deviceID)}`,
                [['deny', 'Deny'], ['allow', 'Allow', Adw.ResponseAppearance.SUGGESTED]],
                id => this.control.send({ decide: { requestID: v.requestID, allow: id === 'allow' } }));
            break;
        }
    }
    settings(change) {
        const hs = Object.assign({}, this.status?.hostSettings ?? {});
        change(hs);
        this.control.send({ setHostSettings: { _0: hs } });
    }
    rebuild() {
        const s = this.status, items = [];
        if (!this.control.connected || !s) {
            items.push({ label: 'Mirage is not running on this computer' });
            items.push('separator', { label: 'Quit', action: () => this.app.quit() });
            this.tray.set(items); return;
        }
        const hs = s.hostSettings ?? {}, sharing = hs.shareThisMac !== false;
        items.push({ label: 'Share This Computer', toggle: true, checked: sharing, action: () => this.settings(h => { h.shareThisMac = !sharing; }) });
        const newer = s.latestAvailable && s.hostVersion && s.latestAvailable.build > s.hostVersion.build;
        if (s.updating) items.push({ label: 'Updating this computer…' });
        else if (newer) {
            items.push({ label: `Mirage ${s.latestAvailable.version} (${s.latestAvailable.build}) is available` });
            if (s.canUpdate) items.push({ label: 'Update Now', action: () => this.control.send({ updateNow: {} }) });
        }
        if (sharing && s.connected?.length) items.push({ label: `Connected: ${s.connected.join(', ')}` });
        if (sharing) {
            items.push('separator');
            items.push({ label: 'Lock When Finished', toggle: true, checked: hs.lockWhenFinished !== false, action: () => this.settings(h => { h.lockWhenFinished = !(hs.lockWhenFinished !== false); }) });
            items.push({ label: 'Stay Reachable', toggle: true, checked: hs.stayReachable !== false, action: () => this.settings(h => { h.stayReachable = !(hs.stayReachable !== false); }) });
        }
        items.push('separator');
        items.push({ label: 'Pair a Device…', enabled: sharing, action: sharing ? () => this.pair() : undefined });
        const devices = (s.devices ?? []).slice().sort((a, b) => a.pairedAt - b.pairedAt);
        if (devices.length) items.push({ label: devices.length === 1 ? '1 Paired Device' : `${devices.length} Paired Devices`,
            children: devices.map(d => ({ label: `Revoke ${d.name}…`, action: () => this.revoke(d) })) });
        items.push('separator', { label: 'Quit', action: () => this.app.quit() });
        this.tray.set(items);
    }
    pair() {
        if (this.pairWindow) { this.pairWindow.win.present(); return; }
        this.pairWindow = new PairWindow(this.app, () => { this.control.send({ closePairing: {} }); this.pairWindow = null; });
        this.control.send({ openPairing: {} });
    }
    revoke(d) {
        alert(`Revoke ${d.name}?`, 'It can no longer connect to this computer until it is paired again.',
            [['cancel', 'Cancel'], ['revoke', 'Revoke', Adw.ResponseAppearance.DESTRUCTIVE]],
            id => { if (id === 'revoke') this.control.send({ revoke: { deviceID: d.id } }); });
    }
}

const app = new Adw.Application({ application_id: 'com.paulherz.mirage.tray', flags: Gio.ApplicationFlags.DEFAULT_FLAGS });
let tray = null;
app.connect('activate', () => { if (!tray) { app.hold(); tray = new MirageTray(app); } });
app.run([System.programInvocationName]);
"""#
