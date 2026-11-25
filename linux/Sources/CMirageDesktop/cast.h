// Internal: receiving a Mutter screen cast's frames over PipeWire into a picture (GNOME's monitor and the virtual monitor).
#ifndef MIRAGE_CAST_H
#define MIRAGE_CAST_H

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>

#include "picture.h"

typedef struct md_cast {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_stream *stream;
    struct spa_hook stream_listener;
    struct spa_video_info_raw format;
    md_picture *pic;
    /// Asks for the pointer as metadata (into the picture's cursor) instead of drawn in.
    int cursor_meta;
    /// Called (on PipeWire's thread) when the stream fails or disconnects.
    void (*on_end)(void *data);
    void *end_data;
} md_cast;

/// Connects to the node `node` (over `pw_fd`, a connected PipeWire socket the cast owns from here on, or -1 for this
/// process's own PipeWire) asking for `width`x`height` pixels (0: whatever the source offers). 0 on success.
int md_cast_start(md_cast *c, int pw_fd, uint32_t node, int width, int height, char *err, size_t err_len);
/// Asks for another size: a virtual monitor takes it as its new mode.
void md_cast_resize(md_cast *c, int width, int height);
void md_cast_stop(md_cast *c);

#endif
