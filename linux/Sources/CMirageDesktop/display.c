// GNOME's display configuration (org.gnome.Mutter.DisplayConfig on the session bus of whoever has the screen: the
// login screen's or a user's): the mode closest to a viewer's window for the primary monitor, and the layout back after.
// Changes are temporary (method 1): never written to monitors.xml.
#include "include/md.h"

#include <gio/gio.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#define DC_NAME "org.gnome.Mutter.DisplayConfig"
#define DC_PATH "/org/gnome/Mutter/DisplayConfig"

#define MAX_LM 8
#define MAX_CONN 4

/// A logical monitor: where it is, and its connectors (more than one when mirrored), each with its mode.
typedef struct {
    int x, y;
    double scale;
    guint32 transform;
    gboolean primary;
    int count;
    char connector[MAX_CONN][64];
    char mode[MAX_CONN][64];
} lm_conf;

static GVariant *call(GDBusConnection *bus, const char *method, GVariant *args, const char *type, char *err, size_t err_len) {
    GError *e = NULL;
    GVariant *r = g_dbus_connection_call_sync(bus, DC_NAME, DC_PATH, DC_NAME, method, args, G_VARIANT_TYPE(type),
                                              G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &e);
    if (!r) { snprintf(err, err_len, "%s: %s", method, e ? e->message : "failed"); g_clear_error(&e); }
    return r;
}

static GDBusConnection *session_bus(char *err, size_t err_len) {
    GError *e = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);
    if (!bus) { snprintf(err, err_len, "no session bus: %s", e ? e->message : "?"); g_clear_error(&e); }
    return bus;
}

static gboolean lookup_bool(GVariant *dict, const char *key) {
    gboolean v = FALSE;
    g_variant_lookup(dict, key, "b", &v);
    return v;
}

static int apply(GDBusConnection *bus, guint32 serial, const lm_conf *lms, int n, char *err, size_t err_len) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(iiduba(ssa{sv}))"));
    for (int i = 0; i < n; i++) {
        GVariantBuilder mons;
        g_variant_builder_init(&mons, G_VARIANT_TYPE("a(ssa{sv})"));
        for (int k = 0; k < lms[i].count; k++)
            g_variant_builder_add(&mons, "(ss@a{sv})", lms[i].connector[k], lms[i].mode[k], g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0));
        g_variant_builder_add(&b, "(iidub@a(ssa{sv}))", lms[i].x, lms[i].y, lms[i].scale, lms[i].transform, lms[i].primary,
                              g_variant_builder_end(&mons));
    }
    GVariant *args = g_variant_new("(uu@a(iiduba(ssa{sv}))@a{sv})", serial, (guint32)1, g_variant_builder_end(&b),
                                   g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0));
    GVariant *r = call(bus, "ApplyMonitorsConfig", args, "()", err, err_len);
    if (!r) return -1;
    g_variant_unref(r);
    return 0;
}

/// The current layout (every connector of every logical monitor), the serial, and the state for choosing modes.
static int current(GDBusConnection *bus, guint32 *serial, lm_conf *lms, int *n, GVariant **state, char *err, size_t err_len) {
    GVariant *st = call(bus, "GetCurrentState", NULL, "(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})", err, err_len);
    if (!st) return -1;
    GVariant *monitors = NULL, *logical = NULL, *props = NULL;
    g_variant_get(st, "(u@a((ssss)a(siiddada{sv})a{sv})@a(iiduba(ssss)a{sv})@a{sv})", serial, &monitors, &logical, &props);
    *n = 0;
    GVariantIter it;
    g_variant_iter_init(&it, logical);
    gint32 x, y; double scale; guint32 transform; gboolean primary;
    GVariant *specs, *lprops;
    int incomplete = 0;
    while (g_variant_iter_next(&it, "(iidub@a(ssss)@a{sv})", &x, &y, &scale, &transform, &primary, &specs, &lprops)) {
        gsize nspecs = g_variant_n_children(specs);
        if (*n >= MAX_LM || nspecs > MAX_CONN) incomplete = 1;
        else if (nspecs > 0) {
            lm_conf *c = &lms[*n];
            c->x = x; c->y = y; c->scale = scale; c->transform = transform; c->primary = primary; c->count = 0;
            for (gsize k = 0; k < nspecs; k++) {
                const char *connector;
                g_variant_get_child(specs, k, "(&s&s&s&s)", &connector, NULL, NULL, NULL);
                snprintf(c->connector[k], sizeof c->connector[k], "%s", connector);
                c->mode[k][0] = 0;
                // Its current mode, from the monitors.
                GVariantIter mi;
                g_variant_iter_init(&mi, monitors);
                GVariant *mon;
                while ((mon = g_variant_iter_next_value(&mi))) {
                    GVariant *spec = g_variant_get_child_value(mon, 0);
                    const char *mc;
                    g_variant_get_child(spec, 0, "&s", &mc);
                    if (strcmp(mc, connector) == 0) {
                        GVariant *modes = g_variant_get_child_value(mon, 1);
                        GVariantIter mo;
                        g_variant_iter_init(&mo, modes);
                        const char *id; gint32 w, h; double rate, pref; GVariant *scales, *mprops;
                        while (g_variant_iter_next(&mo, "(&siidd@ad@a{sv})", &id, &w, &h, &rate, &pref, &scales, &mprops)) {
                            if (lookup_bool(mprops, "is-current")) snprintf(c->mode[k], sizeof c->mode[k], "%s", id);
                            g_variant_unref(scales); g_variant_unref(mprops);
                        }
                        g_variant_unref(modes);
                    }
                    g_variant_unref(spec); g_variant_unref(mon);
                }
                if (!c->mode[k][0]) incomplete = 1;
                c->count++;
            }
            (*n)++;
        }
        g_variant_unref(specs); g_variant_unref(lprops);
    }
    g_variant_unref(logical); g_variant_unref(props);
    *state = monitors;
    g_variant_unref(st);
    // A layout this cannot write back whole is left alone: applying part of it would turn the rest off.
    if (incomplete) { g_variant_unref(monitors); snprintf(err, err_len, "the monitor layout is more than this can put back"); return -1; }
    if (*n == 0) { g_variant_unref(monitors); snprintf(err, err_len, "no monitor is on"); return -1; }
    return 0;
}

static void save(const lm_conf *lms, int n, char *saved, size_t saved_len) {
    size_t off = 0;
    saved[0] = 0;
    for (int i = 0; i < n && off < saved_len; i++) {
        off += snprintf(saved + off, saved_len - off, "%s%d,%d,%.6f,%u,%d,", i ? ";" : "", lms[i].x, lms[i].y, lms[i].scale,
                        lms[i].transform, lms[i].primary ? 1 : 0);
        for (int k = 0; k < lms[i].count && off < saved_len; k++)
            off += snprintf(saved + off, saved_len - off, "%s%s:%s", k ? "|" : "", lms[i].connector[k], lms[i].mode[k]);
    }
}

int md_display_fit(int width, int height, char *saved, size_t saved_len, char *chosen, size_t chosen_len, char *err, size_t err_len) {
    GDBusConnection *bus = session_bus(err, err_len);
    if (!bus) return -1;
    guint32 serial; lm_conf lms[MAX_LM]; int n; GVariant *monitors;
    if (current(bus, &serial, lms, &n, &monitors, err, err_len) != 0) { g_object_unref(bus); return -1; }
    save(lms, n, saved, saved_len);
    int target = 0;
    for (int i = 0; i < n; i++) if (lms[i].primary) target = i;
    lm_conf *t = &lms[target];
    if (t->count != 1) {
        g_variant_unref(monitors); g_object_unref(bus);
        snprintf(err, err_len, "the main display is mirrored (left as it is)"); return -1;
    }
    // The window's points in the desktop's pixels (its scale), and the mode closest in shape first, then in size.
    double tw = width * t->scale, th = height * t->scale;
    double best = 1e9, best_rate = 0;
    char best_id[64] = "";
    gboolean scale_ok = FALSE;
    GVariantIter mi;
    g_variant_iter_init(&mi, monitors);
    GVariant *mon;
    while ((mon = g_variant_iter_next_value(&mi))) {
        GVariant *spec = g_variant_get_child_value(mon, 0);
        const char *mc;
        g_variant_get_child(spec, 0, "&s", &mc);
        if (strcmp(mc, t->connector[0]) == 0) {
            GVariant *modes = g_variant_get_child_value(mon, 1);
            GVariantIter mo;
            g_variant_iter_init(&mo, modes);
            const char *id; gint32 w, h; double rate, pref; GVariant *scales, *mprops;
            while (g_variant_iter_next(&mo, "(&siidd@ad@a{sv})", &id, &w, &h, &rate, &pref, &scales, &mprops)) {
                if (w > 0 && h > 0 && !lookup_bool(mprops, "is-interlaced")) {
                    double score = 3 * fabs(log(((double)w / h) / (tw / th))) + fabs(log(w / tw)) + fabs(log(h / th));
                    // The same size at a rate nearer 60 Hz wins.
                    if (score < best - 1e-6 || (fabs(score - best) < 1e-6 && fabs(rate - 60) < fabs(best_rate - 60))) {
                        best = score; best_rate = rate;
                        snprintf(best_id, sizeof best_id, "%s", id);
                        gsize ns = 0;
                        const double *sc = g_variant_get_fixed_array(scales, &ns, sizeof(double));
                        scale_ok = FALSE;
                        for (gsize k = 0; k < ns; k++) if (fabs(sc[k] - t->scale) < 1e-3) scale_ok = TRUE;
                    }
                }
                g_variant_unref(scales); g_variant_unref(mprops);
            }
            g_variant_unref(modes);
        }
        g_variant_unref(spec); g_variant_unref(mon);
    }
    g_variant_unref(monitors);
    if (!best_id[0]) { snprintf(err, err_len, "%s has no modes", t->connector[0]); g_object_unref(bus); return -1; }
    snprintf(chosen, chosen_len, "%s", best_id);
    if (strcmp(best_id, t->mode[0]) == 0) { g_object_unref(bus); return 0; }
    snprintf(t->mode[0], sizeof t->mode[0], "%s", best_id);
    if (!scale_ok) t->scale = 1;
    int rc = apply(bus, serial, lms, n, err, err_len);
    g_object_unref(bus);
    return rc;
}

int md_display_restore(const char *saved, char *err, size_t err_len) {
    lm_conf lms[MAX_LM]; int n = 0;
    char buf[2048];
    snprintf(buf, sizeof buf, "%s", saved);
    char *save_ptr = NULL;
    for (char *tok = strtok_r(buf, ";", &save_ptr); tok && n < MAX_LM; tok = strtok_r(NULL, ";", &save_ptr)) {
        lm_conf *c = &lms[n];
        int primary = 0, used = 0;
        if (sscanf(tok, "%d,%d,%lf,%u,%d,%n", &c->x, &c->y, &c->scale, &c->transform, &primary, &used) < 5 || !used) continue;
        c->primary = primary != 0; c->count = 0;
        char *conn_ptr = NULL;
        for (char *cm = strtok_r(tok + used, "|", &conn_ptr); cm && c->count < MAX_CONN; cm = strtok_r(NULL, "|", &conn_ptr)) {
            char *colon = strchr(cm, ':');
            if (!colon) continue;
            *colon = 0;
            snprintf(c->connector[c->count], sizeof c->connector[0], "%s", cm);
            snprintf(c->mode[c->count], sizeof c->mode[0], "%s", colon + 1);
            c->count++;
        }
        if (c->count > 0) n++;
    }
    if (n == 0) { snprintf(err, err_len, "nothing to restore"); return -1; }
    GDBusConnection *bus = session_bus(err, err_len);
    if (!bus) return -1;
    guint32 serial; lm_conf now[MAX_LM]; int m; GVariant *monitors;
    if (current(bus, &serial, now, &m, &monitors, err, err_len) != 0) { g_object_unref(bus); return -1; }
    g_variant_unref(monitors);
    int rc = apply(bus, serial, lms, n, err, err_len);
    g_object_unref(bus);
    return rc;
}
