// Internal: the shared picture's layout and the writer's side (capture paths). Readers use md.h.
#ifndef MIRAGE_PICTURE_H
#define MIRAGE_PICTURE_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#include "include/md.h"

struct md_picture {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *frame;   // 4 bytes per pixel, `stride` bytes per row
    size_t cap;
    int width, height, stride;
    int r_off, g_off, b_off;
    uint64_t seq;
    int ended;
    // The pointer, when the source sends it apart from the picture (under cursor_lock).
    pthread_mutex_t cursor_lock;
    int cursor_state;             // as md_picture_cursor returns it
    int cursor_x, cursor_y, cursor_hx, cursor_hy;
    uint8_t *cursor;              // premultiplied B, G, R, A; cursor_w*cursor_h (none for an invisible pointer)
    int cursor_w, cursor_h;
    uint64_t cursor_serial;
};

void md_picture_init(md_picture *p);
void md_picture_free(md_picture *p);
/// Locks the picture and returns a buffer of at least stride*height bytes to write the new frame into (NULL, unlocked,
/// when out of memory); `md_picture_commit` or `md_picture_abort` unlocks it.
uint8_t *md_picture_begin(md_picture *p, int stride, int height);
void md_picture_commit(md_picture *p, int width, int height, int stride, int r_off, int g_off, int b_off);
void md_picture_abort(md_picture *p);
void md_picture_end(md_picture *p);
/// The pointer is off the picture.
void md_picture_cursor_away(md_picture *p);
/// The pointer is at (x, y), with the image it had.
void md_picture_cursor_at(md_picture *p, int x, int y);
/// Its image from here on: `bgra` (malloc'd, the picture's from here on; NULL with 0x0 for an invisible pointer).
void md_picture_cursor_set(md_picture *p, uint8_t *bgra, int width, int height, int hx, int hy);

#endif
