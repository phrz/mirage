// The kernel's display (KMS): the framebuffer scanned out on the first active CRTC, read as root, whatever compositor or
// console drew it (GDM's login screen, the lock screen, a desktop, a text console). The hardware cursor lives on its own
// plane: its image and position are kept apart (the viewer draws the pointer itself), so a moving pointer costs no frame. Only linear 32-bit framebuffers (dumb buffers, as BMC graphics, virtio-gpu and
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
    uint32_t prop_hx, prop_hy;   // the hotspot, on virtual GPUs (0: not given)

    md_picture pic;
    uint8_t *raw, *tmp;   // the primary plane's last copy, and the next one
    size_t raw_cap, tmp_cap;
    uint8_t *cursor;      // premultiplied B, G, R, A; cursor_w*cursor_h
    int cursor_w, cursor_h;
    uint32_t cursor_fb;
    // What readers see of the cursor (under status_lock): the plane's top-left on the screen, whether it shows, and a
    // serial that changes with the image.
    int cur_x, cur_y, cur_on, cur_hx, cur_hy;
    uint64_t cur_serial;
    uint8_t *cur_image;
    int cur_w, cur_h;

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

/// The cursor plane's framebuffer, CRTC and position, in one read. 0 when all four were found.
static int cursor_props(mk_capture *c, uint64_t *fb, uint64_t *crtc, uint64_t *x, uint64_t *y, int64_t *hx, int64_t *hy) {
    drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(c->fd, c->cursor_plane, DRM_MODE_OBJECT_PLANE);
    if (!props) return -1;
    int found = 0;
    for (uint32_t i = 0; i < props->count_props; i++) {
        uint32_t id = props->props[i];
        uint64_t v = props->prop_values[i];
        if (id == c->prop_fb) { *fb = v; found |= 1; }
        else if (id == c->prop_crtc) { *crtc = v; found |= 2; }
        else if (id == c->prop_x) { *x = v; found |= 4; }
        else if (id == c->prop_y) { *y = v; found |= 8; }
        else if (c->prop_hx && id == c->prop_hx) *hx = (int64_t)v;
        else if (c->prop_hy && id == c->prop_hy) *hy = (int64_t)v;
    }
    drmModeFreeObjectProperties(props);
    return found == 15 ? 0 : -1;
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
        // A virtual GPU (virtio, VMware, QXL) shows its cursor plane only to a client that knows cursor hotspots.
        drmSetClientCap(Cards[n], 6 /* DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT */, 1);
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
                    c->prop_hx = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "HOTSPOT_X", NULL);
                    c->prop_hy = prop_id(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "HOTSPOT_Y", NULL);
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

/// Reads the cursor plane's image; publishes it (a new serial) when it differs from the last one.
static void load_cursor(mk_capture *c, uint32_t fb_id) {
    c->cursor_fb = fb_id;
    mapped m;
    const char *why = NULL;
    if (map_fb(c->fd, fb_id, &m, &why) != 0) return;
    size_t need = (size_t)m.width * m.height * 4;
    uint8_t *img = malloc(need);
    if (img) {
        for (uint32_t y = 0; y < m.height; y++) {
            const uint8_t *src = m.base + (size_t)y * m.pitch;
            uint8_t *dst = img + (size_t)y * m.width * 4;
            for (uint32_t x = 0; x < m.width; x++) {   // to B, G, R, A order whatever the plane's format
                dst[x * 4 + 0] = src[x * 4 + m.b]; dst[x * 4 + 1] = src[x * 4 + m.g];
                dst[x * 4 + 2] = src[x * 4 + m.r]; dst[x * 4 + 3] = src[x * 4 + 3];
            }
        }
        int changed = !c->cursor || c->cursor_w != (int)m.width || c->cursor_h != (int)m.height || memcmp(c->cursor, img, need) != 0;
        if (changed) {
            free(c->cursor);
            c->cursor = img; c->cursor_w = (int)m.width; c->cursor_h = (int)m.height;
            uint8_t *copy = malloc(need);
            if (copy) memcpy(copy, img, need);
            pthread_mutex_lock(&c->status_lock);
            free(c->cur_image);
            c->cur_image = copy; c->cur_w = copy ? c->cursor_w : 0; c->cur_h = copy ? c->cursor_h : 0;
            c->cur_serial++;
            pthread_mutex_unlock(&c->status_lock);
        } else free(img);
    }
    unmap(&m);
}

int mk_cursor_state(mk_capture *c, int *x, int *y, int *hx, int *hy, uint64_t *serial) {
    pthread_mutex_lock(&c->status_lock);
    *x = c->cur_x; *y = c->cur_y; *hx = c->cur_hx; *hy = c->cur_hy; *serial = c->cur_serial;
    int on = c->cur_on;
    pthread_mutex_unlock(&c->status_lock);
    return on;
}

int mk_cursor_image(mk_capture *c, uint8_t *bgra, size_t cap, int *width, int *height, uint64_t *serial) {
    pthread_mutex_lock(&c->status_lock);
    size_t need = (size_t)c->cur_w * c->cur_h * 4;
    int ok = c->cur_image && need > 0 && need <= cap;
    if (ok) { memcpy(bgra, c->cur_image, need); *width = c->cur_w; *height = c->cur_h; *serial = c->cur_serial; }
    pthread_mutex_unlock(&c->status_lock);
    return ok ? 0 : -1;
}

static void *capture_thread(void *arg) {
    mk_capture *c = arg;
    uint32_t last_fb = 0;
    uint64_t last_check = 0, last_find = 0, last_cursor_read = 0;
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
            pthread_mutex_lock(&c->status_lock); c->cur_on = 0; pthread_mutex_unlock(&c->status_lock);
            if (now - last_find >= 500) { last_find = now; if (find_display(c) == 0) last_fb = 0; }
            usleep(100000);
            continue;
        }
        uint32_t fb_id = crtc->buffer_id;
        int w = crtc->mode.hdisplay, h = crtc->mode.vdisplay, ox = (int)crtc->x, oy = (int)crtc->y;
        drmModeFreeCrtc(crtc);

        uint64_t cfb = 0, ccrtc = 0, cx = 0, cy = 0;
        int64_t hx = -1, hy = -1;
        int cursor_on = c->cursor_plane && cursor_props(c, &cfb, &ccrtc, &cx, &cy, &hx, &hy) == 0 && cfb && ccrtc == c->crtc_id;
        // A new cursor buffer, and now and then the same one (a compositor may draw a new shape into it).
        if (cursor_on && ((uint32_t)cfb != c->cursor_fb || now - last_cursor_read >= 250)) { load_cursor(c, (uint32_t)cfb); last_cursor_read = now; }
        pthread_mutex_lock(&c->status_lock);
        c->cur_on = cursor_on;
        if (cursor_on) { c->cur_x = (int)(int64_t)cx - ox; c->cur_y = (int)(int64_t)cy - oy; c->cur_hx = (int)hx; c->cur_hy = (int)hy; }   // signed in the property's 64 bits
        pthread_mutex_unlock(&c->status_lock);

        // A flip to another framebuffer is a new picture; a compositor drawing into the same one is caught by comparing.
        int hint = fb_id != last_fb;
        int periodic = now - last_check >= 250;
        if (!hint && !periodic) { usleep(4000); continue; }
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
        int same = c->raw && c->raw_cap == need && memcmp(c->tmp, c->raw, need) == 0;
        last_fb = fb_id;
        if (same) { usleep(4000); continue; }
        uint8_t *t = c->raw; size_t tc = c->raw_cap;
        c->raw = c->tmp; c->raw_cap = need;
        c->tmp = t; c->tmp_cap = tc;
        uint8_t *dst = md_picture_begin(&c->pic, stride, h);
        if (dst) {
            memcpy(dst, c->raw, need);
            md_picture_commit(&c->pic, w, h, stride, ro, go, bo);
        }
        set_status(c, "%s", "");
        usleep(4000);
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
