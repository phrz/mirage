// The Linux host's desktop: the screen from a GNOME (Mutter) remote-desktop session through PipeWire, or from the
// kernel's display (KMS); input through that GNOME session or virtual devices (uinput); and an x265 encoder. Plain C over
// gio, libpipewire, libdrm and libx265; Swift drives it (LinuxStreamer).
#ifndef MIRAGE_MD_H
#define MIRAGE_MD_H

#include <stddef.h>
#include <stdint.h>

typedef struct md_session md_session;
typedef struct md_encoder md_encoder;
typedef struct md_picture md_picture;
typedef struct mk_capture mk_capture;
typedef struct mu_input mu_input;
typedef struct md_virtual md_virtual;

// MARK: The newest captured picture (from either capture path)

/// Waits up to `timeout_ms` for a frame newer than `after_seq`; returns the newest frame's sequence (== after_seq on
/// timeout). Frame sequences start at 1.
uint64_t md_picture_wait(md_picture *p, uint64_t after_seq, int timeout_ms);
/// The picture's size in pixels (0 until the first frame).
void md_picture_size(md_picture *p, int *width, int *height);
/// Nonzero once its source ended (GNOME closed the session).
int md_picture_ended(md_picture *p);
/// Copies the newest frame (4 bytes per pixel) into `dst` when it fits `cap`; returns its stride, 0 when there is none.
int md_picture_copy(md_picture *p, uint8_t *dst, size_t cap, int *width, int *height);
/// The pointer, for a source that sends it apart from the picture: where it points, in the picture's pixels, and the serial
/// of its image (0: none yet). Returns 1 while it is on the picture, 2 while it is not, 0 when nothing is known of it.
int md_picture_cursor(md_picture *p, int *x, int *y, uint64_t *serial);
/// Its image (premultiplied B, G, R, A, in the picture's pixels; 0x0 for an invisible pointer) and hotspot. 0 when there is
/// one that fits `cap` bytes.
int md_picture_cursor_image(md_picture *p, uint8_t *bgra, size_t cap, int *width, int *height, int *hx, int *hy, uint64_t *serial);

// MARK: GNOME (a logged-in session's own remote-desktop interface; the host runs as that user)

/// Opens a Mutter remote-desktop session with a screen cast of the primary monitor (cursor drawn into the picture) and
/// starts receiving its frames. NULL on failure, with a message in `err`.
md_session *md_session_open(char *err, size_t err_len);
void md_session_close(md_session *s);
/// Ends it (GNOME stops the screen cast) without freeing it: its picture ends.
void md_session_end(md_session *s);
md_picture *md_session_picture(md_session *s);

// MARK: The kernel's display (KMS) and virtual input devices (the host runs as root, from boot)

/// Starts reading the scanned-out framebuffer of the first active display (the cursor kept apart: mk_cursor_*), whatever shows
/// there: the login screen, the lock screen, a desktop, a text console. Needs root. NULL on failure, with a message.
mk_capture *mk_capture_open(char *err, size_t err_len);
md_picture *mk_capture_picture(mk_capture *c);
/// Why there is no picture right now ("" when there is one).
void mk_capture_status(mk_capture *c, char *buf, size_t len);
/// The hardware cursor: its image's top-left on the screen, in pixels, its hotspot when the GPU says (virtual GPUs; else
/// -1) and the serial of its image; 1 when it shows.
int mk_cursor_state(mk_capture *c, int *x, int *y, int *hx, int *hy, uint64_t *serial);
// MARK: GNOME's display configuration (the calling process's session bus)

/// Sets the primary monitor to the mode closest to `width`x`height` points (the desktop's scale applied); the layout before
/// goes into `saved` (for md_display_restore) and the mode chosen into `chosen`. 0 on success.
int md_display_fit(int width, int height, char *saved, size_t saved_len, char *chosen, size_t chosen_len, char *err, size_t err_len);
/// Puts back a layout `md_display_fit` (or `md_display_save`) saved.
int md_display_restore(const char *saved, char *err, size_t err_len);
/// The layout now, as `md_display_fit` saves it. 0 on success.
int md_display_save(char *saved, size_t saved_len, char *err, size_t err_len);
/// Makes the monitor showing a `width`x`height` mode that is not in `saved` the only one on, and the primary, at `scale` or
/// the largest scale below it that the mode supports (into `applied`). 0 on success, 1 while there is no such monitor yet.
int md_display_only_new(const char *saved, int width, int height, double scale, double *applied, char *err, size_t err_len);

// MARK: GNOME's virtual monitor (Dynamic Resolution for a signed-in desktop)

/// The helper's side, run as the desktop's user (`mirage-host virtual-display`): makes a Mutter remote-desktop session with
/// a virtual monitor, sends its PipeWire node and connection over `fd` (a Unix socket to the host), then serves the host's
/// commands until it says quit or closes its end. The layout before goes back afterwards. Returns the exit status.
int md_virtual_helper(int fd, int cursor_metadata);
/// The host's side: takes `fd` (the helper's socket; closed by md_virtual_stop, or on failure), captures the virtual
/// monitor at `width`x`height` pixels and makes it the only monitor, at `scale` when Mutter allows it. NULL on failure.
md_virtual *md_virtual_open(int fd, int width, int height, double scale, int cursor_metadata, char *err, size_t err_len);
/// A new size (the monitor's mode follows the stream's). 0 on success.
int md_virtual_resize(md_virtual *v, int width, int height, double scale, char *err, size_t err_len);
/// Its size in logical pixels and its scale, as GNOME took them.
void md_virtual_geometry(md_virtual *v, int *logical_width, int *logical_height, double *scale);
md_picture *md_virtual_picture(md_virtual *v);
/// Ends it: the helper quits (the monitor goes, the layout comes back) and the picture ends. Its picture stays readable
/// until md_virtual_free.
void md_virtual_stop(md_virtual *v);
void md_virtual_free(md_virtual *v);
/// Input; the pointer at (x, y) in 0...1 of the virtual monitor. Buttons and keys are evdev codes.
void md_virtual_pointer_move(md_virtual *v, double x, double y);
void md_virtual_pointer_button(md_virtual *v, int evdev_button, int pressed);
void md_virtual_pointer_axis(md_virtual *v, double dx, double dy, int finger);
void md_virtual_pointer_axis_discrete(md_virtual *v, int axis, int steps);
void md_virtual_key(md_virtual *v, uint32_t evdev_key, int pressed);
void md_virtual_keysym(md_virtual *v, uint32_t keysym, int pressed);

/// The cursor's image (premultiplied B, G, R, A) into `bgra`; 0 when there is one that fits `cap` bytes.
int mk_cursor_image(mk_capture *c, uint8_t *bgra, size_t cap, int *width, int *height, uint64_t *serial);
/// Creates a virtual keyboard and an absolute pointer (uinput). Needs root. NULL on failure, with a message.
mu_input *mu_input_open(char *err, size_t err_len);
/// Pointer at (x, y) in 0...1 of the screen.
void mu_pointer_move(mu_input *u, double x, double y);
void mu_pointer_button(mu_input *u, int evdev_button, int pressed);
/// Wheel, in 1/120ths of a click (high-resolution scrolling); positive = down/right.
void mu_wheel(mu_input *u, int vertical_120ths, int horizontal_120ths);
void mu_key(mu_input *u, uint32_t evdev_key, int pressed);

/// Keeps GNOME from going idle (and so from locking the screen, which ends remote-desktop sessions) while this process
/// runs. 0 on success.
int md_inhibit_idle(const char *reason, char *err, size_t err_len);

// Input, in the stream's pixel coordinates. Buttons and keys are Linux evdev codes.
void md_pointer_move(md_session *s, double x, double y);
void md_pointer_button(md_session *s, int evdev_button, int pressed);
/// Smooth scroll (`finger`: from a trackpad), in pixels; positive = down/right.
void md_pointer_axis(md_session *s, double dx, double dy, int finger);
/// Wheel clicks; axis 0 = vertical, 1 = horizontal; positive = down/right.
void md_pointer_axis_discrete(md_session *s, int axis, int steps);
void md_key(md_session *s, uint32_t evdev_key, int pressed);
void md_keysym(md_session *s, uint32_t keysym, int pressed);

/// An HEVC encoder (x265, Main profile, 4:2:0, BT.709 limited) for `width`x`height` (even) frames at `fps`, at most
/// `max_kbps`. NULL on failure.
md_encoder *md_encoder_open(int width, int height, int fps, int max_kbps, char *err, size_t err_len);
void md_encoder_close(md_encoder *e);
/// The parameter sets (VPS, SPS, PPS) without length prefixes or start codes.
int md_encoder_param_set_count(md_encoder *e);
const uint8_t *md_encoder_param_set(md_encoder *e, int i, int *len);
/// Encodes the picture's newest frame. `force_idr` makes it a keyframe; `force_qp` > 0 encodes at that quantizer (a
/// sharpening pass over a still picture). The sample (4-byte big-endian length before each NAL unit) stays valid until
/// the next call. Returns its length, 0 when nothing came out, -1 on error; `*keyframe` says whether it is an IDR.
int md_encoder_encode(md_encoder *e, md_picture *p, int force_idr, int force_qp, const uint8_t **sample, int *keyframe);

/// The user id at the other end of a Unix socket. 0 on success.
int md_peer_uid(int fd, uint32_t *uid);

#endif
