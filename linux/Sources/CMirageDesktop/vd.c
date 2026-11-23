// See md.h (MARK: GNOME's virtual monitor). Two halves over one Unix socket, one text line per message:
//
//   the helper (as the desktop's user, on its session bus)     the host (any user; root for the system service)
//   ← sends "node N" with a connected PipeWire socket          → "fit W H SCALE" (pixels), answered "fit LW LH SCALE"
//   ← "ended" when GNOME closes the session (the screen locks) → input: "m X Y" (0...1), "b CODE 0|1", "a DX DY FINGER",
//                                                                "d AXIS STEPS", "k CODE 0|1", "s KEYSYM 0|1"; "quit"
//
// The PipeWire socket is the helper's own connection, so PipeWire sees the desktop's user whoever reads the frames.
// Mutter makes the virtual monitor the size the host's stream asks for, and changes it when the stream asks again.
#include "md.h"
#include "cast.h"
#include "gnome.h"

#include <errno.h>
#include <gio/gio.h>
#include <poll.h>
#include <stdarg.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define RD_BUS "org.gnome.Mutter.RemoteDesktop"
#define RD_PATH "/org/gnome/Mutter/RemoteDesktop"
#define RD_SESSION_IFACE "org.gnome.Mutter.RemoteDesktop.Session"
#define SC_BUS "org.gnome.Mutter.ScreenCast"
#define SC_PATH "/org/gnome/Mutter/ScreenCast"
#define SC_SESSION_IFACE "org.gnome.Mutter.ScreenCast.Session"
#define SC_STREAM_IFACE "org.gnome.Mutter.ScreenCast.Stream"

static void send_line(int fd, pthread_mutex_t *lock, const char *line) {
    pthread_mutex_lock(lock);
    size_t len = strlen(line), off = 0;
    while (off < len) {
        ssize_t n = send(fd, line + off, len - off, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        off += (size_t)n;
    }
    pthread_mutex_unlock(lock);
}

static void deadline_in(struct timespec *t, int ms) {
    clock_gettime(CLOCK_MONOTONIC, t);
    t->tv_sec += ms / 1000;
    t->tv_nsec += (long)(ms % 1000) * 1000000L;
    if (t->tv_nsec >= 1000000000L) { t->tv_sec++; t->tv_nsec -= 1000000000L; }
}

// MARK: - The helper

typedef struct {
    GDBusConnection *bus;
    char *rd_path, *sc_path, *stream_path;
    pthread_mutex_t lock, wlock;
    pthread_cond_t cond;
    uint32_t node;
    int ended;
    int fd;
    double lw, lh;   // the virtual monitor's logical size (pointer coordinates)
} helper;

static GVariant *hcall(helper *h, const char *bus, const char *path, const char *iface, const char *method, GVariant *params,
                       const GVariantType *reply, char *err, size_t err_len) {
    GError *e = NULL;
    GVariant *r = g_dbus_connection_call_sync(h->bus, bus, path, iface, method, params, reply, G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &e);
    if (!r && err) snprintf(err, err_len, "%s: %s", method, e ? e->message : "failed");
    if (e) g_error_free(e);
    return r;
}

static void hfire(helper *h, const char *method, GVariant *params) {
    g_dbus_connection_call(h->bus, RD_BUS, h->rd_path, RD_SESSION_IFACE, method, params, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

static void on_node(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *signal,
                    GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal;
    helper *h = data;
    uint32_t node = 0;
    g_variant_get(params, "(u)", &node);
    pthread_mutex_lock(&h->lock);
    h->node = node;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
}

static void on_session_closed(GDBusConnection *c, const char *sender, const char *path, const char *iface, const char *signal,
                              GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)params;
    helper *h = data;
    pthread_mutex_lock(&h->lock);
    h->ended = 1;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
    send_line(h->fd, &h->wlock, "ended\n");
    shutdown(h->fd, SHUT_RD);   // the command loop stops reading and puts the layout back
}

/// A connected socket to the user's PipeWire.
static int pipewire_socket(char *err, size_t err_len) {
    const char *remote = getenv("PIPEWIRE_REMOTE");
    if (!remote || !*remote) remote = "pipewire-0";
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (remote[0] == '/') snprintf(a.sun_path, sizeof a.sun_path, "%s", remote);
    else {
        const char *dir = getenv("PIPEWIRE_RUNTIME_DIR");
        if (!dir || !*dir) dir = getenv("XDG_RUNTIME_DIR");
        if (!dir || !*dir) { snprintf(err, err_len, "no XDG_RUNTIME_DIR for PipeWire"); return -1; }
        snprintf(a.sun_path, sizeof a.sun_path, "%s/%s", dir, remote);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        snprintf(err, err_len, "cannot connect to PipeWire at %s: %s", a.sun_path, strerror(errno));
        if (fd >= 0) close(fd);
        return -1;
    }
    return fd;
}

/// The connectors of a saved layout, as ";conn;conn;".
static void layout_connectors(const char *layout, char *out, size_t len) {
    snprintf(out, len, ";");
    const char *p = layout;
    while (*p) {
        // Each logical monitor: x,y,scale,transform,primary, then conn:mode|conn:mode, then ';'.
        int commas = 0;
        while (*p && commas < 5) { if (*p == ',') commas++; p++; }
        while (*p && *p != ';') {
            const char *colon = strchr(p, ':');
            if (!colon) return;
            size_t used = strlen(out);
            snprintf(out + used, len - used, "%.*s;", (int)(colon - p), p);
            p = colon;
            while (*p && *p != '|' && *p != ';') p++;
            if (*p == '|') p++;
        }
        if (*p == ';') p++;
    }
}

/// After the virtual monitor went: the layout as it was (Mutter otherwise picks its own for the monitors left).
static void put_back(const char *saved) {
    char want[512], now[2048], conns[512], err[256];
    layout_connectors(saved, want, sizeof want);
    for (int i = 0; i < 60; i++) {
        if (md_display_save(now, sizeof now, err, sizeof err) == 0) {
            if (strcmp(now, saved) == 0) return;
            layout_connectors(now, conns, sizeof conns);
            // Only the monitors that were there before: the virtual one is gone.
            int only_old = 1;
            for (char *c = conns + 1; *c; ) {
                char *end = strchr(c, ';');
                if (!end) break;
                char name[80];
                snprintf(name, sizeof name, ";%.*s;", (int)(end - c), c);
                if (!strstr(want, name)) only_old = 0;
                c = end + 1;
            }
            if (only_old) {
                if (md_display_restore(saved, err, sizeof err) != 0) fprintf(stderr, "virtual display: layout not put back: %s\n", err);
                return;
            }
        }
        usleep(50000);
    }
    fprintf(stderr, "virtual display: the virtual monitor did not go away in 3 s\n");
}

static void helper_fit(helper *h, const char *saved, int w, int ht, double scale) {
    char err[256] = "", line[300];
    double applied = 1;
    int rc = 1;
    // Mutter adds or changes the monitor once the host's stream has taken the size: a moment after the stream asks.
    for (int i = 0; i < 100 && rc == 1; i++) {
        pthread_mutex_lock(&h->lock); int ended = h->ended; pthread_mutex_unlock(&h->lock);
        if (ended) { snprintf(err, sizeof err, "GNOME ended the session"); rc = -1; break; }
        rc = md_display_only_new(saved, w, ht, scale, &applied, err, sizeof err);
        if (rc == 1) usleep(50000);
    }
    if (rc == 1) snprintf(err, sizeof err, "no %dx%d virtual monitor appeared", w, ht);
    if (rc != 0) { snprintf(line, sizeof line, "error %s\n", err); send_line(h->fd, &h->wlock, line); return; }
    pthread_mutex_lock(&h->lock);
    h->lw = w / applied; h->lh = ht / applied;
    pthread_mutex_unlock(&h->lock);
    snprintf(line, sizeof line, "fit %d %d %.4f\n", (int)(w / applied), (int)(ht / applied), applied);
    send_line(h->fd, &h->wlock, line);
}

static void helper_command(helper *h, const char *saved, char *line) {
    double a, b; int i, j; unsigned u;
    if (sscanf(line, "m %lf %lf", &a, &b) == 2) {
        pthread_mutex_lock(&h->lock); double lw = h->lw, lh = h->lh; pthread_mutex_unlock(&h->lock);
        if (lw <= 0) return;
        // Mutter takes a virtual stream's positions in its logical pixels, from its top-left.
        hfire(h, "NotifyPointerMotionAbsolute", g_variant_new("(sdd)", h->stream_path, a * lw, b * lh));
    } else if (sscanf(line, "b %d %d", &i, &j) == 2) {
        hfire(h, "NotifyPointerButton", g_variant_new("(ib)", i, j ? TRUE : FALSE));
    } else if (sscanf(line, "a %lf %lf %d", &a, &b, &i) == 3) {
        hfire(h, "NotifyPointerAxis", g_variant_new("(ddu)", a, b, (uint32_t)(i ? 4 : 2)));   // flags: 2 wheel, 4 finger
    } else if (sscanf(line, "d %d %d", &i, &j) == 2) {
        hfire(h, "NotifyPointerAxisDiscrete", g_variant_new("(ui)", (uint32_t)i, j));
    } else if (sscanf(line, "k %u %d", &u, &j) == 2) {
        hfire(h, "NotifyKeyboardKeycode", g_variant_new("(ub)", u, j ? TRUE : FALSE));
    } else if (sscanf(line, "s %u %d", &u, &j) == 2) {
        hfire(h, "NotifyKeyboardKeysym", g_variant_new("(ub)", u, j ? TRUE : FALSE));
    } else {
        int w, ht; double scale;
        if (sscanf(line, "fit %d %d %lf", &w, &ht, &scale) == 3) helper_fit(h, saved, w, ht, scale);
    }
}

int md_virtual_helper(int fd, int cursor_metadata) {
    md_dbus_thread();
    helper h = { .fd = fd };
    pthread_mutex_init(&h.lock, NULL);
    pthread_mutex_init(&h.wlock, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&h.cond, &ca);
    char err[512] = "", line[600], saved[2048] = "";
    int status = 1;
    GError *e = NULL;
    h.bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);
    if (!h.bus) { snprintf(err, sizeof err, "no D-Bus session bus: %s", e ? e->message : ""); if (e) g_error_free(e); goto fail; }
    if (md_display_save(saved, sizeof saved, err, sizeof err) != 0) goto fail;

    GVariant *r = hcall(&h, RD_BUS, RD_PATH, RD_BUS, "CreateSession", NULL, G_VARIANT_TYPE("(o)"), err, sizeof err);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &h.rd_path); g_variant_unref(r);
    r = hcall(&h, RD_BUS, h.rd_path, "org.freedesktop.DBus.Properties", "Get", g_variant_new("(ss)", RD_SESSION_IFACE, "SessionId"),
              G_VARIANT_TYPE("(v)"), err, sizeof err);
    if (!r) goto fail;
    GVariant *idv = NULL; g_variant_get(r, "(v)", &idv); g_variant_unref(r);
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "remote-desktop-session-id", g_variant_new_string(g_variant_get_string(idv, NULL)));
    r = hcall(&h, SC_BUS, SC_PATH, SC_BUS, "CreateSession", g_variant_new("(a{sv})", &opts), G_VARIANT_TYPE("(o)"), err, sizeof err);
    g_variant_unref(idv);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &h.sc_path); g_variant_unref(r);

    GVariantBuilder rec;
    g_variant_builder_init(&rec, G_VARIANT_TYPE("a{sv}"));
    // 1: the pointer drawn into the picture; 2: as metadata (the self-test reads where it is).
    g_variant_builder_add(&rec, "{sv}", "cursor-mode", g_variant_new_uint32(cursor_metadata ? 2 : 1));
    r = hcall(&h, SC_BUS, h.sc_path, SC_SESSION_IFACE, "RecordVirtual", g_variant_new("(a{sv})", &rec), G_VARIANT_TYPE("(o)"), err, sizeof err);
    if (!r) goto fail;
    g_variant_get(r, "(o)", &h.stream_path); g_variant_unref(r);

    guint sub_node = g_dbus_connection_signal_subscribe(h.bus, NULL, SC_STREAM_IFACE, "PipeWireStreamAdded", h.stream_path, NULL,
                                                        G_DBUS_SIGNAL_FLAGS_NONE, on_node, &h, NULL);
    guint sub_closed = g_dbus_connection_signal_subscribe(h.bus, NULL, RD_SESSION_IFACE, "Closed", h.rd_path, NULL,
                                                          G_DBUS_SIGNAL_FLAGS_NONE, on_session_closed, &h, NULL);
    r = hcall(&h, RD_BUS, h.rd_path, RD_SESSION_IFACE, "Start", NULL, NULL, err, sizeof err);
    if (!r) goto fail;
    g_variant_unref(r);

    struct timespec until;
    deadline_in(&until, 5000);
    pthread_mutex_lock(&h.lock);
    while (!h.node && !h.ended) { if (pthread_cond_timedwait(&h.cond, &h.lock, &until) == ETIMEDOUT) break; }
    uint32_t node = h.node;
    pthread_mutex_unlock(&h.lock);
    if (!node) { snprintf(err, sizeof err, "GNOME started the screen cast but sent no PipeWire stream"); goto stop; }
    int pw = pipewire_socket(err, sizeof err);
    if (pw < 0) goto stop;

    // The node, and the PipeWire connection with it.
    snprintf(line, sizeof line, "node %u\n", node);
    struct iovec iov = { .iov_base = line, .iov_len = strlen(line) };
    union { struct cmsghdr align; char buf[CMSG_SPACE(sizeof(int))]; } cm;
    memset(&cm, 0, sizeof cm);
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cm.buf, .msg_controllen = sizeof cm.buf };
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET; c->cmsg_type = SCM_RIGHTS; c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &pw, sizeof(int));
    pthread_mutex_lock(&h.wlock);
    ssize_t sent = sendmsg(fd, &msg, MSG_NOSIGNAL);
    pthread_mutex_unlock(&h.wlock);
    close(pw);
    if (sent < 0) goto stop;

    // Commands until the host says quit, goes away (its end of the socket closes) or GNOME ends the session.
    char buf[4096];
    size_t have = 0;
    status = 0;
    for (;;) {
        ssize_t n = read(fd, buf + have, sizeof buf - 1 - have);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        have += (size_t)n;
        buf[have] = 0;
        char *start = buf, *nl;
        int quit = 0;
        while ((nl = strchr(start, '\n'))) {
            *nl = 0;
            if (strcmp(start, "quit") == 0) { quit = 1; break; }
            helper_command(&h, saved, start);
            start = nl + 1;
        }
        if (quit) break;
        have = strlen(start);
        memmove(buf, start, have);
        if (have >= sizeof buf - 1) have = 0;   // a line this long is no command
    }
stop:
    pthread_mutex_lock(&h.lock); int ended = h.ended; pthread_mutex_unlock(&h.lock);
    g_dbus_connection_signal_unsubscribe(h.bus, sub_node);
    g_dbus_connection_signal_unsubscribe(h.bus, sub_closed);
    if (!ended) { r = hcall(&h, RD_BUS, h.rd_path, RD_SESSION_IFACE, "Stop", NULL, NULL, NULL, 0); if (r) g_variant_unref(r); }
    put_back(saved);
    if (err[0]) { snprintf(line, sizeof line, "error %s\n", err); send_line(fd, &h.wlock, line); fprintf(stderr, "virtual display: %s\n", err); }
    return status;
fail:
    if (h.rd_path) { r = hcall(&h, RD_BUS, h.rd_path, RD_SESSION_IFACE, "Stop", NULL, NULL, NULL, 0); if (r) g_variant_unref(r); }
    snprintf(line, sizeof line, "error %s\n", err);
    send_line(fd, &h.wlock, line);
    fprintf(stderr, "virtual display: %s\n", err);
    return 1;
}

// MARK: - The host's side

struct md_virtual {
    int fd;
    md_cast cast;
    md_picture pic;
    pthread_t reader;
    int reader_started;
    pthread_mutex_t lock, wlock;
    pthread_cond_t cond;
    char reply[512];
    int has_reply, ended;
    int lw, lh;
    double scale;
};

static void virtual_ended(void *data) {
    md_virtual *v = data;
    pthread_mutex_lock(&v->lock);
    v->ended = 1;
    pthread_cond_broadcast(&v->cond);
    pthread_mutex_unlock(&v->lock);
    md_picture_end(&v->pic);
}

static void *reader_main(void *arg) {
    md_virtual *v = arg;
    char buf[2048];
    size_t have = 0;
    for (;;) {
        ssize_t n = read(v->fd, buf + have, sizeof buf - 1 - have);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        have += (size_t)n;
        buf[have] = 0;
        char *start = buf, *nl;
        while ((nl = strchr(start, '\n'))) {
            *nl = 0;
            if (strcmp(start, "ended") == 0) virtual_ended(v);
            else {
                pthread_mutex_lock(&v->lock);
                snprintf(v->reply, sizeof v->reply, "%s", start);
                v->has_reply = 1;
                pthread_cond_broadcast(&v->cond);
                pthread_mutex_unlock(&v->lock);
            }
            start = nl + 1;
        }
        have = strlen(start);
        memmove(buf, start, have);
        if (have >= sizeof buf - 1) have = 0;
    }
    virtual_ended(v);
    return NULL;
}

/// Sends a fit and waits for the helper's answer. 0 on success.
static int virtual_fit(md_virtual *v, int width, int height, double scale, char *err, size_t err_len) {
    char line[128];
    pthread_mutex_lock(&v->lock); v->has_reply = 0; pthread_mutex_unlock(&v->lock);
    snprintf(line, sizeof line, "fit %d %d %.4f\n", width, height, scale);
    send_line(v->fd, &v->wlock, line);
    struct timespec until;
    deadline_in(&until, 10000);
    pthread_mutex_lock(&v->lock);
    while (!v->has_reply && !v->ended) { if (pthread_cond_timedwait(&v->cond, &v->lock, &until) == ETIMEDOUT) break; }
    char reply[512];
    snprintf(reply, sizeof reply, "%s", v->has_reply ? v->reply : "");
    int ended = v->ended;
    pthread_mutex_unlock(&v->lock);
    int lw, lh; double s;
    if (sscanf(reply, "fit %d %d %lf", &lw, &lh, &s) == 3) {
        pthread_mutex_lock(&v->lock); v->lw = lw; v->lh = lh; v->scale = s; pthread_mutex_unlock(&v->lock);
        return 0;
    }
    if (strncmp(reply, "error ", 6) == 0) snprintf(err, err_len, "%s", reply + 6);
    else snprintf(err, err_len, ended ? "the virtual display ended" : "the virtual display did not answer");
    return -1;
}

md_virtual *md_virtual_open(int fd, int width, int height, double scale, int cursor_metadata, char *err, size_t err_len) {
    md_virtual *v = calloc(1, sizeof *v);
    v->fd = fd;
    pthread_mutex_init(&v->lock, NULL);
    pthread_mutex_init(&v->wlock, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&v->cond, &ca);
    md_picture_init(&v->pic);

    // The helper's first message: the node and a PipeWire connection, or why not.
    char line[600] = "";
    size_t have = 0;
    int pw = -1;
    while (have < sizeof line - 1 && !memchr(line, '\n', have)) {
        struct pollfd p = { .fd = fd, .events = POLLIN };
        if (poll(&p, 1, 10000) <= 0) { snprintf(err, err_len, "the virtual display helper did not start"); goto fail; }
        struct iovec iov = { .iov_base = line + have, .iov_len = sizeof line - 1 - have };
        union { struct cmsghdr align; char buf[CMSG_SPACE(sizeof(int))]; } cm;
        struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = cm.buf, .msg_controllen = sizeof cm.buf };
        ssize_t n = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { snprintf(err, err_len, "the virtual display helper exited"); goto fail; }
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
            if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && pw < 0) memcpy(&pw, CMSG_DATA(c), sizeof(int));
        have += (size_t)n;
        line[have] = 0;
    }
    char *nl = strchr(line, '\n');
    if (nl) *nl = 0;
    unsigned node = 0;
    if (strncmp(line, "error ", 6) == 0) { snprintf(err, err_len, "%s", line + 6); goto fail; }
    if (sscanf(line, "node %u", &node) != 1 || pw < 0) { snprintf(err, err_len, "the virtual display helper said: %s", line); goto fail; }

    v->cast.pic = &v->pic;
    v->cast.cursor_meta = cursor_metadata;
    v->cast.on_end = virtual_ended;
    v->cast.end_data = v;
    int rc = md_cast_start(&v->cast, pw, node, width, height, err, err_len);
    pw = -1;
    if (rc < 0) goto fail;
    if (pthread_create(&v->reader, NULL, reader_main, v) != 0) { snprintf(err, err_len, "no reader thread"); goto fail; }
    v->reader_started = 1;
    if (virtual_fit(v, width, height, scale, err, err_len) != 0) goto fail;
    return v;
fail:
    if (pw >= 0) close(pw);
    md_virtual_stop(v);
    md_virtual_free(v);
    return NULL;
}

int md_virtual_resize(md_virtual *v, int width, int height, double scale, char *err, size_t err_len) {
    md_cast_resize(&v->cast, width, height);
    return virtual_fit(v, width, height, scale, err, err_len);
}

void md_virtual_geometry(md_virtual *v, int *logical_width, int *logical_height, double *scale) {
    pthread_mutex_lock(&v->lock);
    *logical_width = v->lw; *logical_height = v->lh; *scale = v->scale;
    pthread_mutex_unlock(&v->lock);
}

md_picture *md_virtual_picture(md_virtual *v) { return &v->pic; }

int md_virtual_cursor(md_virtual *v, int *x, int *y) {
    if (!v->cast.cursor_seen) return 0;
    *x = v->cast.cursor_x; *y = v->cast.cursor_y;
    return 1;
}

void md_virtual_stop(md_virtual *v) {
    if (v->fd < 0) return;
    send_line(v->fd, &v->wlock, "quit\n");
    md_cast_stop(&v->cast);
    shutdown(v->fd, SHUT_RDWR);
    if (v->reader_started) { pthread_join(v->reader, NULL); v->reader_started = 0; }
    close(v->fd);
    v->fd = -1;
    virtual_ended(v);
}

void md_virtual_free(md_virtual *v) {
    if (!v) return;
    md_picture_free(&v->pic);
    free(v);
}

static void vsend(md_virtual *v, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void vsend(md_virtual *v, const char *fmt, ...) {
    if (v->fd < 0) return;
    char line[128];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    send_line(v->fd, &v->wlock, line);
}

void md_virtual_pointer_move(md_virtual *v, double x, double y) { vsend(v, "m %.6f %.6f\n", x, y); }
void md_virtual_pointer_button(md_virtual *v, int evdev_button, int pressed) { vsend(v, "b %d %d\n", evdev_button, pressed ? 1 : 0); }
void md_virtual_pointer_axis(md_virtual *v, double dx, double dy, int finger) { vsend(v, "a %.3f %.3f %d\n", dx, dy, finger ? 1 : 0); }
void md_virtual_pointer_axis_discrete(md_virtual *v, int axis, int steps) { vsend(v, "d %d %d\n", axis, steps); }
void md_virtual_key(md_virtual *v, uint32_t evdev_key, int pressed) { vsend(v, "k %u %d\n", evdev_key, pressed ? 1 : 0); }
void md_virtual_keysym(md_virtual *v, uint32_t keysym, int pressed) { vsend(v, "s %u %d\n", keysym, pressed ? 1 : 0); }
