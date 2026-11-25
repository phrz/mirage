// See cast.h. Only the newest buffer matters: each is copied whole into the picture the encoder takes from.
#include "cast.h"

#include <errno.h>
#include <spa/debug/types.h>
#include <spa/param/video/type-info.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CURSOR_META_SIZE(w, h) ((int)(sizeof(struct spa_meta_cursor) + sizeof(struct spa_meta_bitmap) + (w) * (h) * 4))

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    md_cast *c = data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) return;
    if (media_type != SPA_MEDIA_TYPE_video || media_subtype != SPA_MEDIA_SUBTYPE_raw) return;
    if (spa_format_video_raw_parse(param, &c->format) < 0) return;

    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[3];
    int n = 0;
    params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
        SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 16),
        SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
        SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
    params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
        SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
        SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
    if (c->cursor_meta)
        params[n++] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
            SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor),
            SPA_PARAM_META_size, SPA_POD_CHOICE_RANGE_Int(CURSOR_META_SIZE(384, 384), CURSOR_META_SIZE(1, 1), CURSOR_META_SIZE(384, 384)));
    pw_stream_update_params(c->stream, params, n);
}

/// The pointer a buffer carries. A buffer without an image keeps the last one.
static void read_cursor(md_cast *c, struct spa_buffer *buf) {
    struct spa_meta *m = spa_buffer_find_meta(buf, SPA_META_Cursor);
    if (!m || !m->data || m->size < sizeof(struct spa_meta_cursor)) return;
    const struct spa_meta_cursor *mc = m->data;
    if (!spa_meta_cursor_is_valid(mc)) { md_picture_cursor_away(c->pic); return; }
    size_t at = mc->bitmap_offset, size = m->size;
    if (at >= sizeof *mc && at <= size && size - at >= sizeof(struct spa_meta_bitmap)) {
        const struct spa_meta_bitmap *bm = (const void *)((const uint8_t *)mc + at);
        size_t w = bm->size.width, h = bm->size.height, stride = bm->stride > 0 ? (size_t)bm->stride : w * 4;
        size_t room = size - at;
        if (w == 0 || h == 0) md_picture_cursor_set(c->pic, NULL, 0, 0, 0, 0);
        else if (w <= 1024 && h <= 1024 && stride >= w * 4 && bm->offset <= room && stride <= (room - bm->offset) / h) {
            int r = 0, g = 1, b = 2, a = 3;   // RGBA
            switch (bm->format) {
            case SPA_VIDEO_FORMAT_BGRA: r = 2; g = 1; b = 0; a = 3; break;
            case SPA_VIDEO_FORMAT_ARGB: r = 1; g = 2; b = 3; a = 0; break;
            case SPA_VIDEO_FORMAT_ABGR: r = 3; g = 2; b = 1; a = 0; break;
            default: break;
            }
            const uint8_t *src = (const uint8_t *)bm + bm->offset;
            uint8_t *img = malloc(w * h * 4);
            if (img) {
                for (size_t y = 0; y < h; y++)
                    for (size_t x = 0; x < w; x++) {
                        const uint8_t *s = src + y * stride + x * 4;
                        uint8_t *d = img + (y * w + x) * 4;
                        d[0] = s[b]; d[1] = s[g]; d[2] = s[r]; d[3] = s[a];
                    }
                md_picture_cursor_set(c->pic, img, (int)w, (int)h, mc->hotspot.x, mc->hotspot.y);
            }
        }
    }
    md_picture_cursor_at(c->pic, mc->position.x, mc->position.y);
}

static int has_picture(struct spa_buffer *buf) {
    struct spa_meta_header *h = spa_buffer_find_meta_data(buf, SPA_META_Header, sizeof *h);
    struct spa_data *d = &buf->datas[0];
    return d->data && d->chunk && d->chunk->size > 0 && !(h && (h->flags & SPA_META_HEADER_FLAG_CORRUPTED));
}

static void on_process(void *data) {
    md_cast *c = data;
    // The newest buffer with a picture (a moved pointer comes in one without), and every buffer's pointer.
    struct pw_buffer *b = NULL, *next;
    while ((next = pw_stream_dequeue_buffer(c->stream))) {
        if (c->cursor_meta) read_cursor(c, next->buffer);
        if (!has_picture(next->buffer)) { pw_stream_queue_buffer(c->stream, next); continue; }
        if (b) pw_stream_queue_buffer(c->stream, b);
        b = next;
    }
    if (!b) return;
    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];
    {
        int w = (int)c->format.size.width, hgt = (int)c->format.size.height;
        int stride = d->chunk->stride ? d->chunk->stride : w * 4;
        int r = 2, g = 1, bl = 0;   // BGRx / BGRA
        switch (c->format.format) {
        case SPA_VIDEO_FORMAT_RGBx: case SPA_VIDEO_FORMAT_RGBA: r = 0; g = 1; bl = 2; break;
        case SPA_VIDEO_FORMAT_xRGB: case SPA_VIDEO_FORMAT_ARGB: r = 1; g = 2; bl = 3; break;
        case SPA_VIDEO_FORMAT_xBGR: case SPA_VIDEO_FORMAT_ABGR: r = 3; g = 2; bl = 1; break;
        default: break;
        }
        size_t need = (size_t)stride * hgt;
        const uint8_t *src = (const uint8_t *)d->data + d->chunk->offset;
        if ((size_t)d->chunk->offset + need <= d->maxsize) {
            uint8_t *dst = md_picture_begin(c->pic, stride, hgt);
            if (dst) { memcpy(dst, src, need); md_picture_commit(c->pic, w, hgt, stride, r, g, bl); }
        }
    }
    pw_stream_queue_buffer(c->stream, b);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old; (void)error;
    md_cast *c = data;
    if ((state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) && c->on_end) c->on_end(c->end_data);
}

static const struct pw_stream_events StreamEvents = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

/// The formats taken: 32-bit RGB in any order, at `width`x`height` when given (a virtual monitor is made that size).
static const struct spa_pod *enum_format(struct spa_pod_builder *b, int width, int height) {
    struct spa_pod_frame f;
    spa_pod_builder_push_object(b, &f, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat);
    spa_pod_builder_add(b,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(9, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRA,
                                                      SPA_VIDEO_FORMAT_RGBx, SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_xRGB,
                                                      SPA_VIDEO_FORMAT_ARGB, SPA_VIDEO_FORMAT_xBGR, SPA_VIDEO_FORMAT_ABGR),
        0);
    if (width > 0 && height > 0)
        spa_pod_builder_add(b, SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE((uint32_t)width, (uint32_t)height)), 0);
    else
        spa_pod_builder_add(b, SPA_FORMAT_VIDEO_size,
                            SPA_POD_CHOICE_RANGE_Rectangle(&SPA_RECTANGLE(1920, 1080), &SPA_RECTANGLE(1, 1), &SPA_RECTANGLE(16384, 16384)), 0);
    spa_pod_builder_add(b, SPA_FORMAT_VIDEO_framerate,
                        SPA_POD_CHOICE_RANGE_Fraction(&SPA_FRACTION(60, 1), &SPA_FRACTION(0, 1), &SPA_FRACTION(240, 1)), 0);
    return spa_pod_builder_pop(b, &f);
}

static void pw_once_init(void) { pw_init(NULL, NULL); }

int md_cast_start(md_cast *c, int pw_fd, uint32_t node, int width, int height, char *err, size_t err_len) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, pw_once_init);
    c->loop = pw_thread_loop_new("mirage-capture", NULL);
    if (!c->loop) { snprintf(err, err_len, "PipeWire: no thread loop"); if (pw_fd >= 0) close(pw_fd); return -1; }
    if (pw_thread_loop_start(c->loop) < 0) { snprintf(err, err_len, "PipeWire: thread loop did not start"); if (pw_fd >= 0) close(pw_fd); return -1; }
    pw_thread_loop_lock(c->loop);
    c->context = pw_context_new(pw_thread_loop_get_loop(c->loop), NULL, 0);
    if (c->context) c->core = pw_fd >= 0 ? pw_context_connect_fd(c->context, pw_fd, NULL, 0) : pw_context_connect(c->context, NULL, 0);
    else if (pw_fd >= 0) close(pw_fd);
    if (!c->core) { pw_thread_loop_unlock(c->loop); snprintf(err, err_len, "cannot connect to PipeWire: %s", strerror(errno)); return -1; }
    c->stream = pw_stream_new(c->core, "Mirage", pw_properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                                   PW_KEY_MEDIA_ROLE, "Screen", NULL));
    pw_stream_add_listener(c->stream, &c->stream_listener, &StreamEvents, c);
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[1] = { enum_format(&b, width, height) };
    int rc = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, node, PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
    pw_thread_loop_unlock(c->loop);
    if (rc < 0) { snprintf(err, err_len, "PipeWire: cannot connect to the screen cast: %s", strerror(-rc)); return -1; }
    return 0;
}

void md_cast_resize(md_cast *c, int width, int height) {
    if (!c->loop || !c->stream) return;
    pw_thread_loop_lock(c->loop);
    uint8_t buf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buf, sizeof buf);
    const struct spa_pod *params[1] = { enum_format(&b, width, height) };
    pw_stream_update_params(c->stream, params, 1);
    pw_thread_loop_unlock(c->loop);
}

void md_cast_stop(md_cast *c) {
    if (!c->loop) return;
    pw_thread_loop_lock(c->loop);
    if (c->stream) { pw_stream_disconnect(c->stream); pw_stream_destroy(c->stream); c->stream = NULL; }
    if (c->core) { pw_core_disconnect(c->core); c->core = NULL; }
    if (c->context) { pw_context_destroy(c->context); c->context = NULL; }
    pw_thread_loop_unlock(c->loop);
    pw_thread_loop_stop(c->loop);
    pw_thread_loop_destroy(c->loop);
    c->loop = NULL;
}
