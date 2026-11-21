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

// MARK: The newest captured picture (from either capture path)

/// Waits up to `timeout_ms` for a frame newer than `after_seq`; returns the newest frame's sequence (== after_seq on
/// timeout). Frame sequences start at 1.
uint64_t md_picture_wait(md_picture *p, uint64_t after_seq, int timeout_ms);
/// The picture's size in pixels (0 until the first frame).
void md_picture_size(md_picture *p, int *width, int *height);
/// Nonzero once its source ended (GNOME closed the session).
int md_picture_ended(md_picture *p);

// MARK: GNOME (a logged-in session's own remote-desktop interface; the host runs as that user)

/// Opens a Mutter remote-desktop session with a screen cast of the primary monitor (cursor drawn into the picture) and
/// starts receiving its frames. NULL on failure, with a message in `err`.
md_session *md_session_open(char *err, size_t err_len);
void md_session_close(md_session *s);
md_picture *md_session_picture(md_session *s);

// MARK: The kernel's display (KMS) and virtual input devices (the host runs as root, from boot)

/// Starts reading the scanned-out framebuffer of the first active display (the cursor plane drawn in), whatever shows
/// there: the login screen, the lock screen, a desktop, a text console. Needs root. NULL on failure, with a message.
mk_capture *mk_capture_open(char *err, size_t err_len);
md_picture *mk_capture_picture(mk_capture *c);
/// Why there is no picture right now ("" when there is one).
void mk_capture_status(mk_capture *c, char *buf, size_t len);
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

#endif
