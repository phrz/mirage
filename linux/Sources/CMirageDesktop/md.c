// See md.h. Mutter's remote-desktop and screen-cast D-Bus interfaces are the ones gnome-remote-desktop uses; they need
// no portal dialog for a process of the logged-in user. Frames come over PipeWire into one shared buffer; the encoder
// takes the newest.
#include "md.h"
#include "picture.h"

#include <errno.h>
#include <gio/gio.h>
#include <pipewire/pipewire.h>
#include <pthread.h>
#include <spa/debug/types.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/type-info.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <x265.h>

#define RD_BUS "org.gnome.Mutter.RemoteDesktop"
#define RD_PATH "/org/gnome/Mutter/RemoteDesktop"
#define RD_SESSION_IFACE "org.gnome.Mutter.RemoteDesktop.Session"
#define SC_BUS "org.gnome.Mutter.ScreenCast"
#define SC_PATH "/org/gnome/Mutter/ScreenCast"
#define SC_SESSION_IFACE "org.gnome.Mutter.ScreenCast.Session"
#define SC_STREAM_IFACE "org.gnome.Mutter.ScreenCast.Stream"

struct md_session {
    GDBusConnection *bus;
    char *rd_path;      // remote-desktop session object
    char *sc_path;      // screen-cast session object
    char *stream_path;  // screen-cast stream object
    guint sub_stream, sub_closed;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint32_t node_id;   // 0 until PipeWireStreamAdded
    int ended;

    // Logical size of the stream (pointer coordinates), from the stream's Parameters.
    int logical_w, logical_h;

    // PipeWire
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_video_info_raw format;

    md_picture pic;
};

// MARK: - The D-Bus main loop (one thread for the process, for signals)

static GMainContext *DBusContext;
static void *dbus_thread(void *arg) {
    (void)arg;
    GMainLoop *loop = g_main_loop_new(DBusContext, FALSE);
    g_main_loop_run(loop);
    return NULL;
}
static void dbus_init(void) {
    DBusContext = g_main_context_default();   // nothing else in this process runs it; signals subscribed from any thread arrive here
    pthread_t t;
    pthread_create(&t, NULL, dbus_thread, NULL);
    pthread_detach(t);
}
static void ensure_dbus_thread(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, dbus_init);
}

static GVariant *call(md_session *s, const char *bus, const char *path, const char *iface, const char *method, GVariant *params,
                      const GVariantType *reply, char *err, size_t err_len) {
    GError *e = NULL;
    GVariant *r = g_dbus_connection_call_sync(s->bus, bus, path, iface, method, params, reply, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &e);
    if (!r && err) snprintf(err, err_len, "%s.%s: %s", iface, method, e ? e->message : "failed");
    if (e) g_error_free(e);
    return r;
}

static void fire(md_session *s, const char *method, GVariant *params) {
    if (!s->rd_path) return;
    g_dbus_connection_call(s->bus, RD_BUS, s->rd_path, RD_SESSION_IFACE, method, params, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static void on_stream_added(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *signal,
                            GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal;
    md_session *s = data;
    uint32_t node = 0;
    g_variant_get(params, "(u)", &node);
    pthread_mutex_lock(&s->lock);
    s->node_id = node;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
}

static void on_closed(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *signal,
                      GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)params;
    md_session *s = data;
    pthread_mutex_lock(&s->lock);
    s->ended = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    md_picture_end(&s->pic);
}

// MARK: - PipeWire

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    md_session *s = data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) return;
    if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) return;
    if (spa_format_video_raw_parse(param, &s->format) < 0) return;

    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[2];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 16),
        SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    pw_stream_update_params(s->stream, params, 2);
}

static void on_process(void *data) {
    md_session *s = data;
    struct pw_buffer *b = NULL, *next;
    // Only the newest buffer matters.
    while ((next = pw_stream_dequeue_buffer(s->stream))) {
        if (b) pw_stream_queue_buffer(s->stream, b);
        b = next;
    }
    if (!b) return;
    struct spa_buffer *buf = b->buffer;
    struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof *h);
    struct spa_data *d = &buf->datas[0];
    int ok = d->data && d->chunk && d->chunk->size > 0 && !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED));
    if (ok) {
        int w = (int)s->format.size.width, hgt = (int)s->format.size.height;
        int stride = d->chunk->stride ? d->chunk->stride : w * 4;
        int r = 2, g = 1, bl = 0;   // BGRx / BGRA
        switch (s->format.format) {
        case SPA_VIDEO_FORMAT_RGBx: case SPA_VIDEO_FORMAT_RGBA: r = 0; g = 1; bl = 2; break;
        case SPA_VIDEO_FORMAT_xRGB: case SPA_VIDEO_FORMAT_ARGB: r = 1; g = 2; bl = 3; break;
        case SPA_VIDEO_FORMAT_xBGR: case SPA_VIDEO_FORMAT_ABGR: r = 3; g = 2; bl = 1; break;
        default: break;
        }
        size_t need = (size_t)stride * hgt;
        const uint8_t *src = (const uint8_t *)d->data + d->chunk->offset;
        if ((size_t)d->chunk->offset + need <= d->maxsize) {
            uint8_t *dst = md_picture_begin(&s->pic, stride, hgt);
            if (dst) { memcpy(dst, src, need); md_picture_commit(&s->pic, w, hgt, stride, r, g, bl); }
        }
    }
    pw_stream_queue_buffer(s->stream, b);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old; (void)error;
    md_session *s = data;
    if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
        pthread_mutex_lock(&s->lock);
        s->ended = 1;
        pthread_cond_broadcast(&s->cond);
        pthread_mutex_unlock(&s->lock);
        md_picture_end(&s->pic);
    }
}

static const struct pw_stream_events StreamEvents = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

static void pw_once_init(void) { pw_init(NULL, NULL); }
static int start_pipewire(md_session *s, char *err, size_t err_len) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, pw_once_init);
    s->loop = pw_thread_loop_new("mirage-capture", NULL);
    if (!s->loop) { snprintf(err, err_len, "PipeWire: no thread loop"); return -1; }
    if (pw_thread_loop_start(s->loop) < 0) { snprintf(err, err_len, "PipeWire: thread loop did not start"); return -1; }
    pw_thread_loop_lock(s->loop);
    s->context = pw_context_new(pw_thread_loop_get_loop(s->loop), NULL, 0);
    s->core = s->context ? pw_context_connect(s->context, NULL, 0) : NULL;
    if (!s->core) { pw_thread_loop_unlock(s->loop); snprintf(err, err_len, "cannot connect to PipeWire: %s", strerror(errno)); return -1; }
    s->stream = pw_stream_new(s->core, "Mirage", pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                                   PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(s->stream, &s->stream_listener, &StreamEvents, s);

    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(9, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA,
                                                      SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_xRGB,
                                                      SPA_VIDEO_FORMAT_ARGB, SPA_VIDEO_FORMAT_xBGR, SPA_VIDEO_FORMAT_ABGR),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(60, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(240, 1)));
    int rc = pw_stream_connect(s->stream, PW_DIRECTION_INPUT, s->node_id,
                               PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    pw_thread_loop_unlock(s->loop);
    if (rc < 0) { snprintf(err, err_len, "PipeWire: cannot connect to the screen cast: %s", strerror(-rc)); return -1; }
    return 0;
}

// MARK: - Session

static void read_logical_size(md_session *s) {
    GVariant *r = call(s, SC_BUS, s->stream_path, "org.freedesktop.DBus.Properties", "Get",
                       g_variant_new("(ss)", SC_STREAM_IFACE, "Parameters"), G_VARIANT_TYPE("(v)"), NULL, 0);
    if (!r) return;
    GVariant *v = NULL;
    g_variant_get(r, "(v)", &v);
    int w = 0, h = 0;
    if (v && g_variant_lookup(v, "size", "(ii)", &w, &h)) { s->logical_w = w; s->logical_h = h; }
    if (v) g_variant_unref(v);
    g_variant_unref(r);
}

md_session *md_session_open(char *err, size_t err_len) {
    ensure_dbus_thread();
    md_session *s = calloc(1, sizeof *s);
    pthread_mutex_init(&s->lock, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&s->cond, &ca);
    md_picture_init(&s->pic);
    GError *e = NULL;
    s->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);
    if (!s->bus) {
        snprintf(err, err_len, "no D-Bus session bus (run mirage-host inside the logged-in desktop session): %s", e ? e->message : "");
        if (e) g_error_free(e);
        free(s); return NULL;
    }

    GVariant *r = call(s, RD_BUS, RD_PATH, RD_BUS, "CreateSession", NULL, G_VARIANT_TYPE("(o)"), err, err_len);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &s->rd_path); g_variant_unref(r);

    r = call(s, RD_BUS, s->rd_path, "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", RD_SESSION_IFACE, "SessionId"),
             G_VARIANT_TYPE("(v)"), err, err_len);
    if (!r) goto fail;
    GVariant *idv = NULL; g_variant_get(r, "(v)", &idv); g_variant_unref(r);
    const char *sid = g_variant_get_string(idv, NULL);

    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "remote-desktop-session-id", g_variant_new_string(sid));
    r = call(s, SC_BUS, SC_PATH, SC_BUS, "CreateSession", g_variant_new("(a{sv})", &opts), G_VARIANT_TYPE("(o)"), err, err_len);
    g_variant_unref(idv);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &s->sc_path); g_variant_unref(r);

    GVariantBuilder rec;
    g_variant_builder_init(&rec, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&rec, "{sv}", "cursor-mode", g_variant_new_uint32(1));   // embedded: the pointer is in the picture
    r = call(s, SC_BUS, s->sc_path, SC_SESSION_IFACE, "RecordMonitor", g_variant_new("(sa{sv})", "", &rec), G_VARIANT_TYPE("(o)"), err, err_len);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &s->stream_path); g_variant_unref(r);

    s->sub_stream = g_dbus_connection_signal_subscribe(s->bus, NULL, SC_STREAM_IFACE, "PipeWireStreamAdded", s->stream_path, NULL,
                                                       G_DBUS_SIGNAL_FLAGS_NONE, on_stream_added, s, NULL);
    s->sub_closed = g_dbus_connection_signal_subscribe(s->bus, NULL, RD_SESSION_IFACE, "Closed", s->rd_path, NULL,
                                                       G_DBUS_SIGNAL_FLAGS_NONE, on_closed, s, NULL);

    r = call(s, RD_BUS, s->rd_path, RD_SESSION_IFACE, "Start", NULL, NULL, err, err_len);
    if (!r) goto fail;
    g_variant_unref(r);

    // The PipeWire node arrives as a signal shortly after Start.
    struct timespec until;
    clock_gettime(CLOCK_MONOTONIC, &until);
    until.tv_sec += 5;
    pthread_mutex_lock(&s->lock);
    while (!s->node_id && !s->ended) { if (pthread_cond_timedwait(&s->cond, &s->lock, &until) == ETIMEDOUT) break; }
    uint32_t node = s->node_id;
    pthread_mutex_unlock(&s->lock);
    if (!node) { snprintf(err, err_len, "GNOME started the screen cast but sent no PipeWire stream"); goto fail; }
    read_logical_size(s);
    if (start_pipewire(s, err, err_len) < 0) goto fail;
    return s;
fail:
    md_session_close(s);
    return NULL;
}

void md_session_close(md_session *s) {
    if (!s) return;
    if (s->loop) {
        pw_thread_loop_lock(s->loop);
        if (s->stream) { pw_stream_disconnect(s->stream); pw_stream_destroy(s->stream); }
        if (s->core) pw_core_disconnect(s->core);
        if (s->context) pw_context_destroy(s->context);
        pw_thread_loop_unlock(s->loop);
        pw_thread_loop_stop(s->loop);
        pw_thread_loop_destroy(s->loop);
    }
    if (s->bus) {
        if (s->sub_stream) g_dbus_connection_signal_unsubscribe(s->bus, s->sub_stream);
        if (s->sub_closed) g_dbus_connection_signal_unsubscribe(s->bus, s->sub_closed);
        if (s->rd_path && !s->ended) {
            GVariant *r = call(s, RD_BUS, s->rd_path, RD_SESSION_IFACE, "Stop", NULL, NULL, NULL, 0);
            if (r) g_variant_unref(r);
        }
        g_object_unref(s->bus);
    }
    g_free(s->rd_path); g_free(s->sc_path); g_free(s->stream_path);
    md_picture_free(&s->pic);
    // Signal handlers may still be queued on the D-Bus thread for this session; it is leaked rather than freed under them.
}

md_picture *md_session_picture(md_session *s) { return &s->pic; }

// MARK: - Idle

int md_inhibit_idle(const char *reason, char *err, size_t err_len) {
    GError *e = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);   // the process's shared connection: kept
    if (!bus) { snprintf(err, err_len, "no D-Bus session bus: %s", e ? e->message : ""); if (e) g_error_free(e); return -1; }
    // Flag 8: idle. Held until this process's bus connection closes (it exits).
    GVariant *r = g_dbus_connection_call_sync(bus, "org.gnome.SessionManager", "/org/gnome/SessionManager", "org.gnome.SessionManager",
                                              "Inhibit", g_variant_new("(susu)", "mirage-host", 0u, reason, 8u), G_VARIANT_TYPE("(u)"),
                                              G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &e);
    if (!r) { snprintf(err, err_len, "%s", e ? e->message : "Inhibit failed"); if (e) g_error_free(e); return -1; }
    g_variant_unref(r);
    return 0;
}

// MARK: - Input

void md_pointer_move(md_session *s, double x, double y) {
    int w, h;
    md_picture_size(&s->pic, &w, &h);
    if (s->logical_w > 0 && w > 0) { x = x * s->logical_w / w; y = y * s->logical_h / h; }
    fire(s, "NotifyPointerMotionAbsolute", g_variant_new("(sdd)", s->stream_path, x, y));
}
void md_pointer_button(md_session *s, int evdev_button, int pressed) {
    fire(s, "NotifyPointerButton", g_variant_new("(ib)", evdev_button, pressed ? TRUE : FALSE));
}
void md_pointer_axis(md_session *s, double dx, double dy, int finger) {
    // Flags: 1 finish, 2 wheel, 4 finger, 8 continuous.
    fire(s, "NotifyPointerAxis", g_variant_new("(ddu)", dx, dy, (uint32_t)(finger ? 4 : 2)));
}
void md_pointer_axis_discrete(md_session *s, int axis, int steps) {
    fire(s, "NotifyPointerAxisDiscrete", g_variant_new("(ui)", (uint32_t)axis, steps));
}
void md_key(md_session *s, uint32_t evdev_key, int pressed) {
    fire(s, "NotifyKeyboardKeycode", g_variant_new("(ub)", evdev_key, pressed ? TRUE : FALSE));
}
void md_keysym(md_session *s, uint32_t keysym, int pressed) {
    fire(s, "NotifyKeyboardKeysym", g_variant_new("(ub)", keysym, pressed ? TRUE : FALSE));
}

// MARK: - Encoder

struct md_encoder {
    x265_param *param;
    x265_encoder *enc;
    x265_picture *in, *out;
    int width, height;
    uint8_t *planes;   // I420
    uint8_t *ps[3];
    int ps_len[3];
    int ps_count;
    uint8_t *sample;
    size_t sample_cap;
    int64_t pts;
};

static const uint8_t *strip_prefix(const uint8_t *p, int len, int *out_len) {
    if (len >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) { *out_len = len - 4; return p + 4; }
    if (len >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) { *out_len = len - 3; return p + 3; }
    if (len >= 4) { *out_len = len - 4; return p + 4; }   // a 4-byte length
    *out_len = len; return p;
}

md_encoder *md_encoder_open(int width, int height, int fps, int max_kbps, char *err, size_t err_len) {
    width &= ~1; height &= ~1;
    md_encoder *e = calloc(1, sizeof *e);
    e->width = width; e->height = height;
    e->param = x265_param_alloc();
    const char *preset = getenv("MIRAGE_X265_PRESET");
    if (x265_param_default_preset(e->param, preset && *preset ? preset : "ultrafast", "zerolatency") < 0) {
        snprintf(err, err_len, "x265: unknown preset"); md_encoder_close(e); return NULL;
    }
    x265_param *p = e->param;
    p->sourceWidth = width; p->sourceHeight = height;
    p->fpsNum = (uint32_t)fps; p->fpsDenom = 1;
    p->internalCsp = X265_CSP_I420;
    p->bAnnexB = 0;           // 4-byte lengths before NAL units (hvcC style), as the wire carries them
    p->bRepeatHeaders = 0;
    p->bEmitInfoSEI = 0;
    p->bOpenGOP = 0;
    p->bframes = 0;
    p->keyframeMax = fps * 600;   // keyframes are asked for (start, loss); this is only a backstop
    p->keyframeMin = 1;
    p->scenecutThreshold = 0;
    p->logLevel = X265_LOG_WARNING;
    const char *crf = getenv("MIRAGE_X265_CRF");
    p->rc.rateControlMode = X265_RC_CRF;
    p->rc.rfConstant = crf && *crf ? atof(crf) : 24.0;
    p->rc.vbvMaxBitrate = max_kbps;
    p->rc.vbvBufferSize = max_kbps;   // one second
    p->vui.bEnableVideoSignalTypePresentFlag = 1;
    p->vui.videoFormat = 5;
    p->vui.bEnableVideoFullRangeFlag = 0;
    p->vui.bEnableColorDescriptionPresentFlag = 1;
    p->vui.colorPrimaries = 1; p->vui.transferCharacteristics = 1; p->vui.matrixCoeffs = 1;
    if (x265_param_apply_profile(p, "main") < 0) { snprintf(err, err_len, "x265: Main profile not available"); md_encoder_close(e); return NULL; }
    e->enc = x265_encoder_open(p);
    if (!e->enc) { snprintf(err, err_len, "x265: encoder did not open for %dx%d", width, height); md_encoder_close(e); return NULL; }

    x265_nal *nals; uint32_t n = 0;
    if (x265_encoder_headers(e->enc, &nals, &n) < 0) { snprintf(err, err_len, "x265: no headers"); md_encoder_close(e); return NULL; }
    for (uint32_t i = 0; i < n && e->ps_count < 3; i++) {
        if (nals[i].type != NAL_UNIT_VPS && nals[i].type != NAL_UNIT_SPS && nals[i].type != NAL_UNIT_PPS) continue;
        int len; const uint8_t *body = strip_prefix(nals[i].payload, (int)nals[i].sizeBytes, &len);
        e->ps[e->ps_count] = malloc(len); memcpy(e->ps[e->ps_count], body, len); e->ps_len[e->ps_count] = len; e->ps_count++;
    }
    e->in = x265_picture_alloc(); x265_picture_init(p, e->in);
    e->out = x265_picture_alloc(); x265_picture_init(p, e->out);
    size_t ysize = (size_t)width * height, csize = (size_t)(width / 2) * (height / 2);
    e->planes = malloc(ysize + 2 * csize);
    e->in->planes[0] = e->planes; e->in->planes[1] = e->planes + ysize; e->in->planes[2] = e->planes + ysize + csize;
    e->in->stride[0] = width; e->in->stride[1] = width / 2; e->in->stride[2] = width / 2;
    e->in->colorSpace = X265_CSP_I420;
    e->in->bitDepth = 8;
    return e;
}

void md_encoder_close(md_encoder *e) {
    if (!e) return;
    if (e->enc) x265_encoder_close(e->enc);
    if (e->in) x265_picture_free(e->in);
    if (e->out) x265_picture_free(e->out);
    if (e->param) x265_param_free(e->param);
    for (int i = 0; i < e->ps_count; i++) free(e->ps[i]);
    free(e->planes); free(e->sample); free(e);
}

int md_encoder_param_set_count(md_encoder *e) { return e->ps_count; }
const uint8_t *md_encoder_param_set(md_encoder *e, int i, int *len) { *len = e->ps_len[i]; return e->ps[i]; }

// BT.709, limited range, 8-bit fixed point; chroma from each 2x2 block's mean.
static void to_i420(md_encoder *e, const uint8_t *src, int stride, int ro, int go, int bo) {
    int w = e->width, h = e->height;
    uint8_t *Y = e->in->planes[0], *U = e->in->planes[1], *V = e->in->planes[2];
    for (int y = 0; y < h; y += 2) {
        const uint8_t *r0 = src + (size_t)y * stride, *r1 = r0 + stride;
        uint8_t *y0 = Y + (size_t)y * w, *y1 = y0 + w;
        uint8_t *u = U + (size_t)(y / 2) * (w / 2), *v = V + (size_t)(y / 2) * (w / 2);
        for (int x = 0; x < w; x += 2) {
            const uint8_t *a = r0 + x * 4, *b = a + 4, *c = r1 + x * 4, *d = c + 4;
            int R = a[ro], G = a[go], B = a[bo];
            y0[x] = (uint8_t)(16 + ((47 * R + 157 * G + 16 * B + 128) >> 8));
            int R1 = b[ro], G1 = b[go], B1 = b[bo];
            y0[x + 1] = (uint8_t)(16 + ((47 * R1 + 157 * G1 + 16 * B1 + 128) >> 8));
            int R2 = c[ro], G2 = c[go], B2 = c[bo];
            y1[x] = (uint8_t)(16 + ((47 * R2 + 157 * G2 + 16 * B2 + 128) >> 8));
            int R3 = d[ro], G3 = d[go], B3 = d[bo];
            y1[x + 1] = (uint8_t)(16 + ((47 * R3 + 157 * G3 + 16 * B3 + 128) >> 8));
            int r = (R + R1 + R2 + R3 + 2) >> 2, g = (G + G1 + G2 + G3 + 2) >> 2, bb = (B + B1 + B2 + B3 + 2) >> 2;
            u[x / 2] = (uint8_t)(128 + ((-26 * r - 87 * g + 113 * bb + 128) >> 8));
            v[x / 2] = (uint8_t)(128 + ((113 * r - 103 * g - 10 * bb + 128) >> 8));
        }
    }
}

int md_encoder_encode(md_encoder *e, md_picture *p, int force_idr, int force_qp, const uint8_t **sample, int *keyframe) {
    pthread_mutex_lock(&p->lock);
    if (!p->frame || (p->width & ~1) != e->width || (p->height & ~1) != e->height) { pthread_mutex_unlock(&p->lock); return -2; }
    to_i420(e, p->frame, p->stride, p->r_off, p->g_off, p->b_off);
    pthread_mutex_unlock(&p->lock);

    e->in->pts = e->pts++;
    e->in->sliceType = force_idr ? X265_TYPE_IDR : X265_TYPE_AUTO;
    e->in->forceqp = force_qp > 0 ? force_qp + 1 : 0;
    x265_nal *nals; uint32_t n = 0;
    int got = x265_encoder_encode(e->enc, &nals, &n, e->in, e->out);
    if (got < 0) return -1;
    if (got == 0 || n == 0) return 0;
    size_t total = 0;
    for (uint32_t i = 0; i < n; i++) total += nals[i].sizeBytes;
    if (e->sample_cap < total) { free(e->sample); e->sample = malloc(total); e->sample_cap = total; }
    size_t off = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (nals[i].type == NAL_UNIT_VPS || nals[i].type == NAL_UNIT_SPS || nals[i].type == NAL_UNIT_PPS) continue;
        memcpy(e->sample + off, nals[i].payload, nals[i].sizeBytes);
        off += nals[i].sizeBytes;
    }
    *keyframe = IS_X265_TYPE_I(e->out->sliceType) && e->out->sliceType == X265_TYPE_IDR;
    *sample = e->sample;
    return (int)off;
}
