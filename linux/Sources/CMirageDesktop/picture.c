// The newest captured picture, shared by a capture path (GNOME's screen cast, or the kernel's framebuffer) and the
// encoder. See md.h.
#include "picture.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void md_picture_init(md_picture *p) {
    memset(p, 0, sizeof *p);
    pthread_mutex_init(&p->lock, NULL);
    pthread_mutex_init(&p->cursor_lock, NULL);
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&p->cond, &ca);
}

void md_picture_free(md_picture *p) {
    free(p->frame); p->frame = NULL; p->cap = 0;
    free(p->cursor); p->cursor = NULL;
}

uint8_t *md_picture_begin(md_picture *p, int stride, int height) {
    size_t need = (size_t)stride * height;
    pthread_mutex_lock(&p->lock);
    if (p->cap < need) {
        free(p->frame);
        p->frame = malloc(need);
        p->cap = p->frame ? need : 0;
    }
    if (!p->frame) { pthread_mutex_unlock(&p->lock); return NULL; }
    return p->frame;
}

void md_picture_commit(md_picture *p, int width, int height, int stride, int r_off, int g_off, int b_off) {
    p->width = width; p->height = height; p->stride = stride;
    p->r_off = r_off; p->g_off = g_off; p->b_off = b_off;
    p->seq++;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

void md_picture_abort(md_picture *p) { pthread_mutex_unlock(&p->lock); }

void md_picture_end(md_picture *p) {
    pthread_mutex_lock(&p->lock);
    p->ended = 1;
    pthread_cond_broadcast(&p->cond);
    pthread_mutex_unlock(&p->lock);
}

uint64_t md_picture_wait(md_picture *p, uint64_t after_seq, int timeout_ms) {
    struct timespec until;
    clock_gettime(CLOCK_MONOTONIC, &until);
    until.tv_sec += timeout_ms / 1000;
    until.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&p->lock);
    while (p->seq == after_seq && !p->ended) { if (pthread_cond_timedwait(&p->cond, &p->lock, &until) == ETIMEDOUT) break; }
    uint64_t seq = p->seq;
    pthread_mutex_unlock(&p->lock);
    return seq;
}

void md_picture_size(md_picture *p, int *width, int *height) {
    pthread_mutex_lock(&p->lock);
    *width = p->width; *height = p->height;
    pthread_mutex_unlock(&p->lock);
}

int md_picture_ended(md_picture *p) {
    pthread_mutex_lock(&p->lock);
    int e = p->ended;
    pthread_mutex_unlock(&p->lock);
    return e;
}

int md_picture_copy(md_picture *p, uint8_t *dst, size_t cap, int *width, int *height) {
    pthread_mutex_lock(&p->lock);
    int stride = 0;
    if (p->frame && (size_t)p->stride * p->height <= cap) {
        memcpy(dst, p->frame, (size_t)p->stride * p->height);
        stride = p->stride; *width = p->width; *height = p->height;
    }
    pthread_mutex_unlock(&p->lock);
    return stride;
}

void md_picture_cursor_away(md_picture *p) {
    pthread_mutex_lock(&p->cursor_lock);
    p->cursor_state = 2;
    pthread_mutex_unlock(&p->cursor_lock);
}

void md_picture_cursor_at(md_picture *p, int x, int y) {
    pthread_mutex_lock(&p->cursor_lock);
    p->cursor_x = x; p->cursor_y = y; p->cursor_state = 1;
    pthread_mutex_unlock(&p->cursor_lock);
}

void md_picture_cursor_set(md_picture *p, uint8_t *bgra, int width, int height, int hx, int hy) {
    pthread_mutex_lock(&p->cursor_lock);
    size_t n = (size_t)width * height * 4;
    int same = p->cursor_serial && p->cursor_w == width && p->cursor_h == height && p->cursor_hx == hx && p->cursor_hy == hy &&
               (n == 0 || memcmp(p->cursor, bgra, n) == 0);
    if (same) free(bgra);
    else {
        free(p->cursor);
        p->cursor = bgra; p->cursor_w = width; p->cursor_h = height; p->cursor_hx = hx; p->cursor_hy = hy;
        p->cursor_serial++;
    }
    pthread_mutex_unlock(&p->cursor_lock);
}

int md_picture_cursor(md_picture *p, int *x, int *y, uint64_t *serial) {
    pthread_mutex_lock(&p->cursor_lock);
    int state = p->cursor_state;
    *x = p->cursor_x; *y = p->cursor_y; *serial = p->cursor_serial;
    pthread_mutex_unlock(&p->cursor_lock);
    return state;
}

int md_picture_cursor_image(md_picture *p, uint8_t *bgra, size_t cap, int *width, int *height, int *hx, int *hy, uint64_t *serial) {
    pthread_mutex_lock(&p->cursor_lock);
    size_t n = (size_t)p->cursor_w * p->cursor_h * 4;
    int ok = p->cursor_serial && n <= cap;
    if (ok) {
        if (n) memcpy(bgra, p->cursor, n);
        *width = p->cursor_w; *height = p->cursor_h; *hx = p->cursor_hx; *hy = p->cursor_hy; *serial = p->cursor_serial;
    }
    pthread_mutex_unlock(&p->cursor_lock);
    return ok ? 0 : -1;
}
