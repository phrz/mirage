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
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&p->cond, &ca);
}

void md_picture_free(md_picture *p) { free(p->frame); p->frame = NULL; p->cap = 0; }

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
