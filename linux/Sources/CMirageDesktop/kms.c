// The kernel's display (KMS): the framebuffer scanned out on the first active CRTC, read as root, whatever compositor or
// console drew it (GDM's login screen, the lock screen, a desktop, a text console). The hardware cursor lives on its own
// plane and is drawn into the copy. Only linear 32-bit framebuffers (dumb buffers, as BMC graphics, virtio-gpu and
// software rendering use); a GPU's tiled buffers are reported as unsupported.
#include "md.h"
#include "picture.h"

#include <drm_fourcc.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

struct mk_capture {
    int fd;
    uint32_t crtc_id;
    int crtc_index;
    uint32_t cursor_plane;
    uint32_t prop_fb, prop_crtc, prop_x, prop_y;

    md_picture pic;
    uint8_t *raw, *tmp;   // the primary plane's last copy, and the next one
    size_t raw_cap, tmp_cap;
    uint8_t *cursor;      // premultiplied ARGB8888, cursor_w*cursor_h
    int cursor_w, cursor_h;
    uint32_t cursor_fb;

    pthread_mutex_t status_lock;
    char status[256];
    pthread_t thread;
};

static uint64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}

static void set_status(mk_capture *c, const char *fmt, const char *arg) {
    pthread_mutex_lock(&c->status_lock);
    snprintf(c->status, sizeof c->status, fmt, arg);
    pthread_mutex_unlock(&c->status_lock);
}

void mk_capture_status(mk_capture *c, char *buf, size_t len) {
    pthread_mutex_lock(&c->status_lock);
    snprintf(buf, len, "%s", c->status);
    pthread_mutex_unlock(&c->status_lock);
}

static uint32_t prop_id(int fd, uint32_t obj, uint32_t type, const char *name, uint64_t *value) {
    drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(fd, obj, type);
    if (!props) return 0;
    uint32_t id = 0;
    for (uint32_t i = 0; i < props->count_props && !id; i++) {
        drmModePropertyPtr p = drmModeGetProperty(fd, props->props[i]);
        if (!p) continue;
        if (strcmp(p->name, name) == 0) { id = p->prop_id; if (value) *value = props->prop_values[i]; }
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(props);
    return id;
}

static int prop_value(int fd, uint32_t obj, uint32_t prop, uint64_t *value) {
    drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(fd, obj, DRM_MODE_OBJECT_PLANE);
    if (!props) return -1;
    int found = -1;
    for (uint32_t i = 0; i < props->count_props; i++) if (props->props[i] == prop) { *value = props->prop_values[i]; found = 0; break; }
    drmModeFreeObjectProperties(props);
    return found;
}

/// The cards, each opened once for the process's life and never as DRM master: the first opener of a card becomes its
/// master, which would keep GDM and GNOME from driving the display (they fail with EBUSY). Master is dropped at once, and
/// the descriptor is kept so no later open can take it again (between GDM's greeter and the user's session nobody holds it).
static int Cards[16];
static void open_cards(void) {
    for (int n = 0; n < 16; n++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/dri/card%d", n);
        Cards[n] = open(path, O_RDWR | O_CLOEXEC);
        if (Cards[n] < 0) continue;
        drmDropMaster(Cards[n]);
        drmSetClientCap(Cards[n], DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1);
        drmSetClientCap(Cards[n], DRM_CLIENT_CAP_ATOMIC, 1);
    }
}

/// Finds a card with an active CRTC, and that CRTC's cursor plane. 0 on success.
static int find_display(mk_capture *c) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, open_cards);
    c->fd = -1;
    c->crtc_id = 0; c->cursor_plane = 0; c->cursor_fb = 0;
    for (int n = 0; n < 16; n++) {
        int fd = Cards[n];
        if (fd < 0) continue;
        drmModeResPtr res = drmModeGetResources(fd);
        if (!res) continue;
        for (int i = 0; i < res->count_crtcs && !c->crtc_id; i++) {
            drmModeCrtcPtr crtc = drmModeGetCrtc(fd, res->crtcs[i]);
            if (crtc && crtc->mode_valid && crtc->buffer_id) { c->crtc_id = crtc->crtc_id; c->crtc_index = i; }
            drmModeFreeCrtc(crtc);
        }
        drmModeFreeResources(res);
        if (!c->crtc_id) continue;
        c->fd = fd;
        drmModePlaneResPtr planes = drmModeGetPlaneResources(fd);
        for (uint32_t i = 0; planes && i < planes->count_planes && !c->cursor_plane; i++) {
            drmModePlanePtr p = drmModeGetPlane(fd, planes->planes[i]);
            if (p && (p->possible_crtcs & (1u << c->crtc_index))) {
                uint64_t type = 0;
                if (prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type", &type) && type == DRM_PLANE_TYPE_CURSOR) {
                    c->cursor_plane = p->plane_id;
                    c->prop_fb = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "FB_ID", NULL);
                    c->prop_crtc = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_ID", NULL);
                    c->prop_x = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_X", NULL);
                    c->prop_y = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "CRTC_Y", NULL);
                    if (!c->prop_fb || !c->prop_crtc || !c->prop_x || !c->prop_y) c->cursor_plane = 0;
                }
            }
            drmModeFreePlane(p);
        }
        drmModeFreePlaneResources(planes);
        return 0;
    }
    return -1;
}

typedef struct mapped {
    const uint8_t *base;   // first pixel (offset applied)
    void *map;
    size_t len;
    int dmabuf;
    uint32_t width, height, pitch;
    int r, g, b;
} mapped;

static void unmap(mapped *m) {
    if (m->dmabuf >= 0) {
        struct dma_buf_sync s = { DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ };
        ioctl(m->dmabuf, DMA_BUF_IOCTL_SYNC, &s);
    }
    if (m->map && m->map != MAP_FAILED) munmap(m->map, m->len);
    if (m->dmabuf >= 0) close(m->dmabuf);
    memset(m, 0, sizeof *m);
    m->dmabuf = -1;
}

/// Maps a framebuffer for reading. 0 on success, else a message in `why`.
static int map_fb(int fd, uint32_t fb_id, mapped *m, const char **why) {
    memset(m, 0, sizeof *m);
    m->dmabuf = -1;
    drmModeFB2Ptr fb = drmModeGetFB2(fd, fb_id);
    if (!fb) { *why = "cannot read the display's framebuffer"; return -1; }
    uint32_t handle = fb->handles[0];
    int rc = -1;
    if (!handle) { *why = "the framebuffer has no handle (mirage-host must run as root)"; goto out; }
    if ((fb->flags & DRM_MODE_FB_MODIFIERS) && fb->modifier != DRM_FORMAT_MOD_LINEAR) {
        *why = "the display's framebuffer is tiled by the GPU (unsupported)"; goto out;
    }
    switch (fb->pixel_format) {
    case DRM_FORMAT_XRGB8888: case DRM_FORMAT_ARGB8888: m->r = 2; m->g = 1; m->b = 0; break;
    case DRM_FORMAT_XBGR8888: case DRM_FORMAT_ABGR8888: m->r = 0; m->g = 1; m->b = 2; break;
    default: *why = "the display's pixel format is not 32-bit RGB (unsupported)"; goto out;
    }
    m->width = fb->width; m->height = fb->height; m->pitch = fb->pitches[0];
    size_t need = (size_t)fb->offsets[0] + (size_t)fb->pitches[0] * fb->height;
    int pfd = -1;
    if (drmPrimeHandleToFD(fd, handle, DRM_CLOEXEC, &pfd) == 0) {
        off_t size = lseek(pfd, 0, SEEK_END);
        m->len = size > 0 ? (size_t)size : need;
        m->map = mmap(NULL, m->len, PROT_READ, MAP_SHARED, pfd, 0);
        if (m->map != MAP_FAILED) {
            m->dmabuf = pfd;
            struct dma_buf_sync s = { DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ };
            ioctl(pfd, DMA_BUF_IOCTL_SYNC, &s);
        } else { close(pfd); m->map = NULL; }
    }
    if (!m->map) {
        // A dumb buffer without dma-buf mmap: map it through the card.
        struct drm_mode_map_dumb md = { .handle = handle };
        if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md) == 0) {
            m->len = need;
            m->map = mmap(NULL, need, PROT_READ, MAP_SHARED, fd, (off_t)md.offset);
            if (m->map == MAP_FAILED) m->map = NULL;
        }
    }
    if (!m->map || m->len < need) { *why = "cannot map the display's framebuffer"; unmap(m); goto out; }
    m->base = (const uint8_t *)m->map + fb->offsets[0];
    rc = 0;
out:
    for (int i = 0; i < 4; i++) {
        if (!fb->handles[i]) continue;
        int dup = 0;
        for (int j = 0; j < i; j++) if (fb->handles[j] == fb->handles[i]) dup = 1;
        if (!dup) { struct drm_gem_close gc = { .handle = fb->handles[i] }; drmIoctl(fd, DRM_IOCTL_GEM_CLOSE, &gc); }
    }
    drmModeFreeFB2(fb);
    return rc;
}

static void load_cursor(mk_capture *c, uint32_t fb_id) {
    c->cursor_fb = fb_id;
    c->cursor_w = c->cursor_h = 0;
    mapped m;
    const char *why = NULL;
    if (map_fb(c->fd, fb_id, &m, &why) != 0) return;
    size_t need = (size_t)m.width * m.height * 4;
    free(c->cursor);
    c->cursor = malloc(need);
    if (c->cursor) {
        for (uint32_t y = 0; y < m.height; y++) {
            const uint8_t *src = m.base + (size_t)y * m.pitch;
            uint8_t *dst = c->cursor + (size_t)y * m.width * 4;
            for (uint32_t x = 0; x < m.width; x++) {   // to B, G, R, A order whatever the plane's format
                dst[x * 4 + 0] = src[x * 4 + m.b]; dst[x * 4 + 1] = src[x * 4 + m.g];
                dst[x * 4 + 2] = src[x * 4 + m.r]; dst[x * 4 + 3] = src[x * 4 + 3];
            }
        }
        c->cursor_w = (int)m.width; c->cursor_h = (int)m.height;
    }
    unmap(&m);
}

/// Premultiplied cursor over the picture (its own channel order).
static void draw_cursor(mk_capture *c, uint8_t *dst, int w, int h, int stride, int cx, int cy, int ro, int go, int bo) {
    for (int y = 0; y < c->cursor_h; y++) {
        int py = cy + y;
        if (py < 0 || py >= h) continue;
        const uint8_t *src = c->cursor + (size_t)y * c->cursor_w * 4;
        uint8_t *row = dst + (size_t)py * stride;
        for (int x = 0; x < c->cursor_w; x++) {
            int px = cx + x;
            if (px < 0 || px >= w) continue;
            const uint8_t *s = src + x * 4;
            int a = s[3];
            if (!a) continue;
            uint8_t *d = row + px * 4;
            d[bo] = (uint8_t)(s[0] + d[bo] * (255 - a) / 255);
            d[go] = (uint8_t)(s[1] + d[go] * (255 - a) / 255);
            d[ro] = (uint8_t)(s[2] + d[ro] * (255 - a) / 255);
        }
    }
}

static void *capture_thread(void *arg) {
    mk_capture *c = arg;
    uint32_t last_fb = 0;
    int64_t last_cx = -1, last_cy = -1;
    uint32_t last_cfb = 0;
    uint64_t last_check = 0, last_find = 0;
    for (;;) {
        uint64_t now = now_ms();
        if (c->fd < 0 || !c->crtc_id) {
            if (now - last_find >= 500 || !last_find) {
                last_find = now;
                if (find_display(c) != 0) set_status(c, "%s", "the screen is off or not set up yet");
                else { set_status(c, "%s", ""); last_fb = 0; }
            }
            if (c->fd < 0) { usleep(200000); continue; }
        }
        drmModeCrtcPtr crtc = drmModeGetCrtc(c->fd, c->crtc_id);
        if (!crtc || !crtc->mode_valid || !crtc->buffer_id) {
            // The screen is off (blanked), or the display moved to another CRTC: look again now and then.
            drmModeFreeCrtc(crtc);
            if (now - last_find >= 500) { last_find = now; if (find_display(c) == 0) last_fb = 0; }
            usleep(100000);
            continue;
        }
        uint32_t fb_id = crtc->buffer_id;
        int w = crtc->mode.hdisplay, h = crtc->mode.vdisplay, ox = (int)crtc->x, oy = (int)crtc->y;
        drmModeFreeCrtc(crtc);

        uint64_t cfb = 0, ccrtc = 0, cx = 0, cy = 0;
        int cursor_on = 0;
        if (c->cursor_plane && prop_value(c->fd, c->cursor_plane, c->prop_fb, &cfb) == 0 &&
            prop_value(c->fd, c->cursor_plane, c->prop_crtc, &ccrtc) == 0 && prop_value(c->fd, c->cursor_plane, c->prop_x, &cx) == 0 &&
            prop_value(c->fd, c->cursor_plane, c->prop_y, &cy) == 0) {
            cursor_on = cfb && ccrtc == c->crtc_id;
        }
        int64_t sx = (int64_t)cx, sy = (int64_t)cy;   // signed in the property's 64 bits
        if (!cursor_on) { sx = -1; sy = -1; cfb = 0; }
        int hint = fb_id != last_fb || sx != last_cx || sy != last_cy || (uint32_t)cfb != last_cfb;
        int periodic = now - last_check >= 250;
        if (!hint && !periodic) { usleep(16000); continue; }
        last_check = now;

        mapped m;
        const char *why = NULL;
        if (map_fb(c->fd, fb_id, &m, &why) != 0) {
            set_status(c, "%s", why);
            last_fb = fb_id;   // retried at the next change or check
            usleep(100000);
            continue;
        }
        if (ox + w > (int)m.width) w = (int)m.width - ox;
        if (oy + h > (int)m.height) h = (int)m.height - oy;
        int stride = w * 4;
        size_t need = (size_t)stride * h;
        if (c->tmp_cap < need) { free(c->tmp); c->tmp = malloc(need); c->tmp_cap = c->tmp ? need : 0; }
        if (!c->tmp || w <= 0 || h <= 0) { unmap(&m); usleep(100000); continue; }
        for (int y = 0; y < h; y++) memcpy(c->tmp + (size_t)y * stride, m.base + (size_t)(oy + y) * m.pitch + (size_t)ox * 4, stride);
        int ro = m.r, go = m.g, bo = m.b;
        unmap(&m);
        int same = !hint && c->raw && c->raw_cap == need && memcmp(c->tmp, c->raw, need) == 0;
        last_fb = fb_id;
        if (same) { usleep(16000); continue; }
        uint8_t *t = c->raw; size_t tc = c->raw_cap;
        c->raw = c->tmp; c->raw_cap = need;
        c->tmp = t; c->tmp_cap = tc;
        if (cursor_on && (uint32_t)cfb != c->cursor_fb) load_cursor(c, (uint32_t)cfb);
        last_cx = sx; last_cy = sy; last_cfb = (uint32_t)cfb;

        uint8_t *dst = md_picture_begin(&c->pic, stride, h);
        if (dst) {
            memcpy(dst, c->raw, need);
            if (cursor_on && c->cursor_w > 0) draw_cursor(c, dst, w, h, stride, (int)(sx - ox), (int)(sy - oy), ro, go, bo);
            md_picture_commit(&c->pic, w, h, stride, ro, go, bo);
        }
        set_status(c, "%s", "");
        usleep(16000);
    }
    return NULL;
}

mk_capture *mk_capture_open(char *err, size_t err_len) {
    if (geteuid() != 0) { snprintf(err, err_len, "reading the display needs root"); return NULL; }
    mk_capture *c = calloc(1, sizeof *c);
    c->fd = -1;
    pthread_mutex_init(&c->status_lock, NULL);
    md_picture_init(&c->pic);
    if (pthread_create(&c->thread, NULL, capture_thread, c) != 0) { snprintf(err, err_len, "no capture thread"); free(c); return NULL; }
    pthread_detach(c->thread);
    return c;
}

md_picture *mk_capture_picture(mk_capture *c) { return &c->pic; }
