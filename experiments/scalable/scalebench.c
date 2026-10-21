// scalebench: resolution-scalable lossless coding of 2x screen content, per 64x64 tile and per whole layer.
//
//   A  WebP lossless of the 2x pixels (Mirage's tile codec; effort 4 = HostEffort.full).
//   B  1x base (exact integer 2x2 filter) as WebP lossless + the 2x detail from a reversible lifting
//      transform, coded four ways: as a WebP lossless image, zstd, LZ4-HC, and a context-modelled
//      binary arithmetic coder (ctx). Two transforms: Haar / S-transform and a JPEG XL-style squeeze
//      (S-transform plus a "smooth tendency" prediction of the difference from neighbouring averages).
//   C  JPEG XL lossless (libjxl), plain and with the squeeze transform + progressive passes, measuring the
//      bytes a decoder needs before it reports a 2:1 (1x-equivalent) pass and the full lossless size.
//   D  lossy 1x base (WebP q75) + lossless 2x completion (2x residual against the upsampled lossy base, ctx).
//
// Every transform and coder is round-tripped and checked bit-exact on every tile and layer.
// Usage: scalebench IMAGE.png CATEGORY TILES.csv LAYERS.csv [--stride N] [--no-jxl] [--no-layer]
//        scalebench --scroll IMAGE.png CATEGORY SCROLL.csv
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <webp/encode.h>
#include <webp/decode.h>
#include <zstd.h>
#include <lz4hc.h>
#include <lz4.h>
#include <jxl/encode.h>
#include <jxl/decode.h>

#define T 64            // 2x tile size
#define WEBP_EFFORT 4
// libjxl renders a 2:1 pass by upsampling (not mean-preserving): block means of that render are within +-4 of the truth.
#define JXL_2X_TOL 6

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static void die(const char *m) { fprintf(stderr, "FATAL: %s\n", m); exit(1); }

// ---------------------------------------------------------------- image loading (ImageIO, no colour conversion)
static uint8_t *load_rgb(const char *path, int *W, int *H) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageSourceRef src = CGImageSourceCreateWithURL(url, NULL);
    if (!src) die("cannot open image");
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    int w = (int)CGImageGetWidth(img), h = (int)CGImageGetHeight(img);
    CGColorSpaceRef cs = CGImageGetColorSpace(img);
    if (!cs || CGColorSpaceGetModel(cs) != kCGColorSpaceModelRGB) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint8_t *rgba = calloc((size_t)w * h, 4);
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    // Crop to whole tiles; flatten the window's transparent corners over a light grey (premultiplied over).
    int cw = w / T * T, ch = h / T * T;
    uint8_t *rgb = malloc((size_t)cw * ch * 3);
    for (int y = 0; y < ch; y++) for (int x = 0; x < cw; x++) {
        const uint8_t *p = rgba + ((size_t)y * w + x) * 4;
        for (int c = 0; c < 3; c++) rgb[((size_t)y * cw + x) * 3 + c] = (uint8_t)(p[c] + (255 - p[3]) * 236 / 255);
    }
    CGContextRelease(ctx); CGImageRelease(img); CFRelease(src); CFRelease(url); free(rgba);
    *W = cw; *H = ch;
    return rgb;
}

// ---------------------------------------------------------------- WebP
static size_t webp_ll(const uint8_t *px, int w, int h, int channels, int effort, uint8_t **out) {
    WebPConfig cfg; WebPPicture pic; WebPMemoryWriter wr;
    if (!WebPConfigInit(&cfg) || !WebPConfigLosslessPreset(&cfg, effort)) die("webp config");
    cfg.lossless = 1; cfg.exact = channels == 4; cfg.thread_level = 0;
    WebPPictureInit(&pic); pic.use_argb = 1; pic.width = w; pic.height = h;
    if (!(channels == 4 ? WebPPictureImportRGBA(&pic, px, w * 4) : WebPPictureImportRGB(&pic, px, w * 3))) die("webp import");
    WebPMemoryWriterInit(&wr); pic.writer = WebPMemoryWrite; pic.custom_ptr = &wr;
    if (!WebPEncode(&cfg, &pic)) die("webp encode");
    WebPPictureFree(&pic);
    size_t n = wr.size;
    if (out) *out = wr.mem; else WebPMemoryWriterClear(&wr);
    return n;
}
static size_t webp_lossy(const uint8_t *px, int w, int h, float q, uint8_t **out) {
    WebPConfig cfg; WebPPicture pic; WebPMemoryWriter wr;
    if (!WebPConfigInit(&cfg) || !WebPConfigPreset(&cfg, WEBP_PRESET_TEXT, q)) die("webp lossy config");
    cfg.method = 3; cfg.thread_level = 0;
    WebPPictureInit(&pic); pic.use_argb = 1; pic.width = w; pic.height = h;
    WebPPictureImportRGB(&pic, px, w * 3);
    WebPMemoryWriterInit(&wr); pic.writer = WebPMemoryWrite; pic.custom_ptr = &wr;
    if (!WebPEncode(&cfg, &pic)) die("webp lossy encode");
    WebPPictureFree(&pic);
    *out = wr.mem;
    return wr.size;
}
static void webp_dec(const uint8_t *d, size_t n, uint8_t *dst, int w, int h, int channels) {
    void *r = channels == 4 ? (void *)WebPDecodeRGBAInto(d, n, dst, (size_t)w * h * 4, w * 4) : (void *)WebPDecodeRGBInto(d, n, dst, (size_t)w * h * 3, w * 3);
    if (!r) die("webp decode");
}

// ---------------------------------------------------------------- reversible transforms (per channel, int32 planes)
// Haar / S-transform, horizontal step first: for each 2x2 block (a b / c d):
//   l1 = (a+b)>>1, h1 = a-b, l2 = (c+d)>>1, h2 = c-d; LL = (l1+l2)>>1, LH = l1-l2, HL = (h1+h2)>>1, HH = h1-h2.
// LL is the 1x base: an exact, defined 2x2 mean (floor at each step). Bands are W/2 x H/2.
static void haar_fwd(const int32_t *in, int w, int h, int32_t *LL, int32_t *HL, int32_t *LH, int32_t *HH) {
    int bw = w / 2;
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < bw; x++) {
        int a = in[(2 * y) * w + 2 * x], b = in[(2 * y) * w + 2 * x + 1], c = in[(2 * y + 1) * w + 2 * x], d = in[(2 * y + 1) * w + 2 * x + 1];
        int l1 = (a + b) >> 1, h1 = a - b, l2 = (c + d) >> 1, h2 = c - d;
        int i = y * bw + x;
        LL[i] = (l1 + l2) >> 1; LH[i] = l1 - l2; HL[i] = (h1 + h2) >> 1; HH[i] = h1 - h2;
    }
}
static void haar_inv(int32_t *out, int w, int h, const int32_t *LL, const int32_t *HL, const int32_t *LH, const int32_t *HH) {
    int bw = w / 2;
    for (int y = 0; y < h / 2; y++) for (int x = 0; x < bw; x++) {
        int i = y * bw + x;
        int l1 = LL[i] + ((LH[i] + 1) >> 1), l2 = l1 - LH[i];
        int h1 = HL[i] + ((HH[i] + 1) >> 1), h2 = h1 - HH[i];
        int a = l1 + ((h1 + 1) >> 1), b = a - h1, c = l2 + ((h2 + 1) >> 1), d = c - h2;
        out[(2 * y) * w + 2 * x] = a; out[(2 * y) * w + 2 * x + 1] = b; out[(2 * y + 1) * w + 2 * x] = c; out[(2 * y + 1) * w + 2 * x + 1] = d;
    }
}

// JPEG XL-style squeeze: avg = (A+B+(A>B))>>1, residual = (A-B) - tendency(left reconstructed pixel, avg, next avg).
static int tendency(int B, int a, int n) {
    int diff = 0;
    if (B >= a && a >= n) {
        diff = (4 * B - 3 * n - a + 6) / 12;
        if (diff - (diff & 1) > 2 * (B - a)) diff = 2 * (B - a) + 1;
        if (diff + (diff & 1) > 2 * (a - n)) diff = 2 * (a - n);
    } else if (B <= a && a <= n) {
        diff = (4 * B - 3 * n - a - 6) / 12;
        if (diff + (diff & 1) < 2 * (B - a)) diff = 2 * (B - a) - 1;
        if (diff - (diff & 1) < 2 * (a - n)) diff = 2 * (a - n);
    }
    return diff;
}
static inline int sq_avg(int A, int B) { return (A + B + (A > B)) >> 1; }
static inline void sq_pair(int avg, int diff, int *A, int *B) {
    int pos = diff > 0;
    int sum = 2 * avg + ((diff + pos) & 1) - pos;
    *A = (sum + diff) / 2; *B = *A - diff;
}
// 1D squeeze of n=2m samples at stride s: avg[m], res[m].
static void sq1_fwd(const int32_t *in, int s, int m, int32_t *avg, int as, int32_t *res, int rs) {
    for (int x = 0; x < m; x++) avg[x * as] = sq_avg(in[(2 * x) * s], in[(2 * x + 1) * s]);
    for (int x = 0; x < m; x++) {
        int a = avg[x * as], nx = x + 1 < m ? avg[(x + 1) * as] : a, left = x ? in[(2 * x - 1) * s] : a;
        res[x * rs] = (in[(2 * x) * s] - in[(2 * x + 1) * s]) - tendency(left, a, nx);
    }
}
static void sq1_inv(int32_t *out, int s, int m, const int32_t *avg, int as, const int32_t *res, int rs) {
    for (int x = 0; x < m; x++) {
        int a = avg[x * as], nx = x + 1 < m ? avg[(x + 1) * as] : a, left = x ? out[(2 * x - 1) * s] : a;
        int A, B; sq_pair(a, res[x * rs] + tendency(left, a, nx), &A, &B);
        out[(2 * x) * s] = A; out[(2 * x + 1) * s] = B;
    }
}
// 2D: horizontal squeeze of rows -> HA (w/2 x h) + HR (w/2 x h); vertical squeeze of HA columns -> LL + VR (w/2 x h/2).
static void squeeze_fwd(const int32_t *in, int w, int h, int32_t *LL, int32_t *HR, int32_t *VR, int32_t *tmp) {
    int bw = w / 2;
    for (int y = 0; y < h; y++) sq1_fwd(in + y * w, 1, bw, tmp + y * bw, 1, HR + y * bw, 1);
    for (int x = 0; x < bw; x++) sq1_fwd(tmp + x, bw, h / 2, LL + x, bw, VR + x, bw);
}
static void squeeze_inv(int32_t *out, int w, int h, const int32_t *LL, const int32_t *HR, const int32_t *VR, int32_t *tmp) {
    int bw = w / 2;
    for (int x = 0; x < bw; x++) sq1_inv(tmp + x, bw, h / 2, LL + x, bw, VR + x, bw);
    for (int y = 0; y < h; y++) sq1_inv(out + y * w, 1, bw, tmp + y * bw, 1, HR + y * bw, 1);
}

// ---------------------------------------------------------------- adaptive binary range coder (LZMA style)
#define PB 12
#define PADAPT 4
typedef struct { uint8_t *buf; size_t pos, cap; uint64_t low; uint32_t range, code; uint8_t cache; uint64_t csize; int enc; } RC;
static void rc_put(RC *r, uint8_t b) { if (r->pos == r->cap) { r->cap *= 2; r->buf = realloc(r->buf, r->cap); } r->buf[r->pos++] = b; }
static void rc_shift(RC *r) {
    if ((uint32_t)r->low < 0xFF000000u || (r->low >> 32)) {
        uint8_t carry = (uint8_t)(r->low >> 32), t = r->cache;
        do { rc_put(r, (uint8_t)(t + carry)); t = 0xFF; } while (--r->csize);
        r->cache = (uint8_t)(r->low >> 24);
    }
    r->csize++;
    r->low = (r->low & 0x00FFFFFFu) << 8;
}
static void rc_enc_init(RC *r, size_t cap) { memset(r, 0, sizeof *r); r->cap = cap; r->buf = malloc(cap); r->range = 0xFFFFFFFFu; r->csize = 1; r->enc = 1; }
static size_t rc_enc_finish(RC *r) { for (int i = 0; i < 5; i++) rc_shift(r); return r->pos; }
static void rc_dec_init(RC *r, uint8_t *buf, size_t n) {
    memset(r, 0, sizeof *r); r->buf = buf; r->cap = n; r->range = 0xFFFFFFFFu;
    for (int i = 0; i < 5; i++) r->code = (r->code << 8) | (r->pos < n ? buf[r->pos++] : 0);
}
static inline int rc_bit(RC *r, uint16_t *p, int bit) {
    uint32_t bound = (r->range >> PB) * *p;
    if (r->enc) {
        if (!bit) { r->range = bound; *p += ((1 << PB) - *p) >> PADAPT; }
        else { r->low += bound; r->range -= bound; *p -= *p >> PADAPT; }
        while (r->range < (1u << 24)) { r->range <<= 8; rc_shift(r); }
    } else {
        if (r->code < bound) { r->range = bound; *p += ((1 << PB) - *p) >> PADAPT; bit = 0; }
        else { r->code -= bound; r->range -= bound; *p -= *p >> PADAPT; bit = 1; }
        while (r->range < (1u << 24)) { r->range <<= 8; r->code = (r->code << 8) | (r->pos < r->cap ? r->buf[r->pos++] : 0); }
    }
    return bit;
}

// ---------------------------------------------------------------- context-modelled coefficient coder
// Planes are coded in order; a chroma plane (R-G or B-G) uses the G plane of the same band as context, and a
// plane may name up to two "aux" planes of the same size coded earlier (other bands at the same position).
typedef struct { int32_t *d; int w, h, pc, band; const int32_t *g, *aux0, *aux1; } Plane;
#define NB 5
typedef struct {
    uint16_t zero[2][NB][24], sign[2][NB][9], expo[2][NB][12][12], mant[2][12][12], same[2][NB][12];
} Ctx;
static void ctx_init(Ctx *c) { uint16_t *p = (uint16_t *)c; for (size_t i = 0; i < sizeof *c / 2; i++) p[i] = 1 << (PB - 1); }
static inline int qlog(int s) { int k = 0; while (s && k < 11) { s >>= 1; k++; } return k; }   // 0..11
static void code_planes(RC *r, Plane *pl, int np) {
    Ctx *c = malloc(sizeof(Ctx)); ctx_init(c);
    for (int p = 0; p < np; p++) {
        Plane *P = &pl[p]; int w = P->w, pc = P->pc, b = P->band;
        for (int y = 0; y < P->h; y++) for (int x = 0; x < w; x++) {
            int i = y * w + x;
            int W = x ? P->d[i - 1] : 0, N = y ? P->d[i - w] : 0;
            int NW = x && y ? P->d[i - w - 1] : 0, NE = y && x + 1 < w ? P->d[i - w + 1] : 0;
            int s = 2 * abs(W) + 2 * abs(N) + abs(NW) + abs(NE);
            if (P->aux0) s += abs(P->aux0[i]);
            if (P->aux1) s += abs(P->aux1[i]);
            int gz = 0;
            if (P->g) { s += 2 * abs(P->g[i]); gz = P->g[i] != 0; }
            int k = qlog(s >> 1); if (k > 11) k = 11;
            int v = r->enc ? P->d[i] : 0;
            int nz = rc_bit(r, &c->zero[pc][b][k * 2 + gz], v != 0);
            if (!nz) { P->d[i] = 0; continue; }
            // "same as the pixel above" (repeated strokes in text): one bit when N is non-zero.
            if (N) {
                int same = rc_bit(r, &c->same[pc][b][k], v == N);
                if (same) { P->d[i] = N; continue; }
            }
            int sctx = (W > 0) - (W < 0) + 1 + 3 * ((N > 0) - (N < 0) + 1);
            int neg = rc_bit(r, &c->sign[pc][b][sctx], v < 0);
            int u = r->enc ? abs(v) : 0;   // u >= 1
            int nb = r->enc ? qlog(u) - 1 : 0;  // floor(log2 u)
            if (r->enc) { for (int j = 0; j < nb; j++) rc_bit(r, &c->expo[pc][b][k][j], 1); if (nb < 11) rc_bit(r, &c->expo[pc][b][k][nb], 0); }
            else { while (nb < 11 && rc_bit(r, &c->expo[pc][b][k][nb], 0)) nb++; }
            int m = 1;
            for (int j = nb - 1; j >= 0; j--) m = (m << 1) | rc_bit(r, &c->mant[pc][nb][j], (u >> j) & 1);
            P->d[i] = neg ? -m : m;
        }
    }
    free(c);
}

// ---------------------------------------------------------------- scalable layer: transform + detail coders
typedef struct { int w, h; int32_t *ch[3]; } Planar;     // full-res planar copy
typedef struct {
    int bw, bh;                  // base size
    uint8_t *base;               // base RGB (bw x bh)
    int32_t *band[3][3];         // [band][channel]; Haar: HL, LH, HH (bw x bh); squeeze: HR (bw x 2bh), VR (bw x bh), unused
    int nbands, bandh[3];
} Split;

static void split_fwd(const uint8_t *rgb, int w, int h, int stride_px, int squeeze, Split *S) {
    int bw = w / 2, bh = h / 2;
    S->bw = bw; S->bh = bh; S->base = malloc((size_t)bw * bh * 3);
    S->nbands = squeeze ? 2 : 3;
    int32_t *in = malloc(sizeof(int32_t) * w * h), *LL = malloc(sizeof(int32_t) * bw * bh), *tmp = malloc(sizeof(int32_t) * bw * h);
    for (int k = 0; k < S->nbands; k++) S->bandh[k] = squeeze && k == 0 ? h : bh;
    for (int c = 0; c < 3; c++) {
        for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) in[y * w + x] = rgb[((size_t)y * stride_px + x) * 3 + c];
        for (int k = 0; k < S->nbands; k++) S->band[k][c] = malloc(sizeof(int32_t) * bw * S->bandh[k]);
        if (squeeze) squeeze_fwd(in, w, h, LL, S->band[0][c], S->band[1][c], tmp);
        else haar_fwd(in, w, h, LL, S->band[0][c], S->band[1][c], S->band[2][c]);
        for (int i = 0; i < bw * bh; i++) S->base[i * 3 + c] = (uint8_t)LL[i];
    }
    free(in); free(LL); free(tmp);
}
static void split_free(Split *S) { free(S->base); for (int k = 0; k < S->nbands; k++) for (int c = 0; c < 3; c++) free(S->band[k][c]); }
// Inverse into rgb (w x h, packed); bands as given.
static void split_inv(const Split *S, int squeeze, uint8_t *rgb) {
    int bw = S->bw, bh = S->bh, w = bw * 2, h = bh * 2;
    int32_t *out = malloc(sizeof(int32_t) * w * h), *LL = malloc(sizeof(int32_t) * bw * bh), *tmp = malloc(sizeof(int32_t) * bw * h);
    for (int c = 0; c < 3; c++) {
        for (int i = 0; i < bw * bh; i++) LL[i] = S->base[i * 3 + c];
        if (squeeze) squeeze_inv(out, w, h, LL, S->band[0][c], S->band[1][c], tmp);
        else haar_inv(out, w, h, LL, S->band[0][c], S->band[1][c], S->band[2][c]);
        for (int i = 0; i < w * h; i++) { if (out[i] < 0 || out[i] > 255) die("inverse out of range"); rgb[i * 3 + c] = (uint8_t)out[i]; }
    }
    free(out); free(LL); free(tmp);
}
static int total_rows(const Split *S) { int r = 0; for (int k = 0; k < S->nbands; k++) r += S->bandh[k]; return r; }

// Detail as a WebP lossless RGBA image: bands stacked vertically; RGB = low byte of v+128, A = the three
// channels' high parts (floor((v+128)/256) in -2..2) packed base-5.
static size_t detail_webp(const Split *S, uint8_t **out) {
    int bw = S->bw, rows = total_rows(S);
    uint8_t *img = malloc((size_t)bw * rows * 4);
    int row0 = 0;
    for (int k = 0; k < S->nbands; k++) {
        for (int i = 0; i < bw * S->bandh[k]; i++) {
            uint8_t *p = img + ((size_t)row0 * bw + i) * 4; int a = 0, mul = 1;
            for (int c = 0; c < 3; c++) {
                int v = S->band[k][c][i] + 128, hi = v >= 0 ? v / 256 : -((255 - v) / 256);
                if (hi < -2 || hi > 2) die("detail out of packable range");
                p[c] = (uint8_t)(v - hi * 256); a += (hi + 2) * mul; mul *= 5;
            }
            p[3] = (uint8_t)a;
        }
        row0 += S->bandh[k];
    }
    size_t n = webp_ll(img, bw, rows, 4, WEBP_EFFORT, out);
    free(img);
    return n;
}
static void detail_webp_dec(Split *S, const uint8_t *d, size_t n) {
    int bw = S->bw, rows = total_rows(S);
    uint8_t *img = malloc((size_t)bw * rows * 4);
    webp_dec(d, n, img, bw, rows, 4);
    int row0 = 0;
    for (int k = 0; k < S->nbands; k++) {
        for (int i = 0; i < bw * S->bandh[k]; i++) {
            uint8_t *p = img + ((size_t)row0 * bw + i) * 4; int a = p[3];
            for (int c = 0; c < 3; c++) { int hi = a % 5 - 2; a /= 5; S->band[k][c][i] = p[c] + hi * 256 - 128; }
        }
        row0 += S->bandh[k];
    }
    free(img);
}
// Byte-plane serialisation for zstd/LZ4: per band, G, R-G, B-G, zigzag to 16 bits, all low bytes then all high bytes.
static size_t detail_serialise(const Split *S, uint8_t **out) {
    size_t n = 0; for (int k = 0; k < S->nbands; k++) n += (size_t)S->bw * S->bandh[k] * 3;
    uint8_t *b = malloc(n * 2); size_t o = 0;
    for (int k = 0; k < S->nbands; k++) for (int c = 0; c < 3; c++) for (int i = 0; i < S->bw * S->bandh[k]; i++) {
        int g = S->band[k][1][i], v = c == 0 ? g : S->band[k][c == 1 ? 0 : 2][i] - g;
        uint32_t z = ((uint32_t)v << 1) ^ (uint32_t)(v >> 31);
        b[o] = (uint8_t)z; b[n + o] = (uint8_t)(z >> 8); o++;
    }
    *out = b; return n * 2;
}
static void detail_deserialise(Split *S, const uint8_t *b) {
    size_t n = 0; for (int k = 0; k < S->nbands; k++) n += (size_t)S->bw * S->bandh[k] * 3;
    size_t o = 0;
    for (int k = 0; k < S->nbands; k++) {
        int cnt = S->bw * S->bandh[k];
        for (int c = 0; c < 3; c++) for (int i = 0; i < cnt; i++) {
            uint32_t z = b[o] | (uint32_t)b[n + o] << 8; o++;
            int v = (int)(z >> 1) ^ -(int)(z & 1);
            if (c == 0) S->band[k][1][i] = v;          // G first
            else S->band[k][c == 1 ? 0 : 2][i] = v;    // stored as R-G, B-G; fixed below
        }
        for (int i = 0; i < cnt; i++) { S->band[k][0][i] += S->band[k][1][i]; S->band[k][2][i] += S->band[k][1][i]; }
    }
}
// Context coder over G, R-G, B-G planes of each band.
static void make_planes(Split *S, int32_t **dec, Plane *pl, int *np) {
    // dec[k*3+c]: decorrelated planes (c=0 G, 1 R-G, 2 B-G)
    int n = 0;
    for (int k = 0; k < S->nbands; k++) for (int c = 0; c < 3; c++) {
        Plane *P = &pl[n++]; P->d = dec[k * 3 + c]; P->w = S->bw; P->h = S->bandh[k]; P->pc = c ? 1 : 0; P->band = k;
        P->g = c ? dec[k * 3] : NULL;
        P->aux0 = P->aux1 = NULL;
        // Haar bands share a size: LH sees HL, HH sees HL and LH (same channel plane).
        if (S->nbands == 3 && k >= 1) { P->aux0 = dec[0 * 3 + c]; if (k == 2) P->aux1 = dec[1 * 3 + c]; }
    }
    *np = n;
}
static size_t detail_ctx(const Split *S, uint8_t **out) {
    int32_t *dec[9]; Plane pl[9]; int np;
    for (int k = 0; k < S->nbands; k++) {
        int cnt = S->bw * S->bandh[k];
        for (int c = 0; c < 3; c++) dec[k * 3 + c] = malloc(sizeof(int32_t) * cnt);
        for (int i = 0; i < cnt; i++) { int g = S->band[k][1][i]; dec[k * 3][i] = g; dec[k * 3 + 1][i] = S->band[k][0][i] - g; dec[k * 3 + 2][i] = S->band[k][2][i] - g; }
    }
    make_planes((Split *)S, dec, pl, &np);
    RC r; rc_enc_init(&r, 4096);
    code_planes(&r, pl, np);
    size_t n = rc_enc_finish(&r);
    for (int i = 0; i < S->nbands * 3; i++) free(dec[i]);
    *out = r.buf; return n;
}
static void detail_ctx_dec(Split *S, uint8_t *d, size_t n) {
    int32_t *dec[9]; Plane pl[9]; int np;
    for (int k = 0; k < S->nbands; k++) for (int c = 0; c < 3; c++) dec[k * 3 + c] = calloc((size_t)S->bw * S->bandh[k], sizeof(int32_t));
    make_planes(S, dec, pl, &np);
    RC r; rc_dec_init(&r, d, n);
    code_planes(&r, pl, np);
    for (int k = 0; k < S->nbands; k++) for (int i = 0; i < S->bw * S->bandh[k]; i++) {
        int g = dec[k * 3][i]; S->band[k][1][i] = g; S->band[k][0][i] = dec[k * 3 + 1][i] + g; S->band[k][2][i] = dec[k * 3 + 2][i] + g;
    }
    for (int i = 0; i < S->nbands * 3; i++) free(dec[i]);
}
static void bands_clear(Split *S) { for (int k = 0; k < S->nbands; k++) for (int c = 0; c < 3; c++) memset(S->band[k][c], 0x5A, sizeof(int32_t) * S->bw * S->bandh[k]); }

// ---------------------------------------------------------------- D: lossless completion against an upsampled lossy 1x base
static size_t completion_ctx(const uint8_t *rgb, int w, int h, const uint8_t *lossy1x, uint8_t **out, int verify) {
    int n = w * h;
    int32_t *dec[3]; for (int c = 0; c < 3; c++) dec[c] = malloc(sizeof(int32_t) * n);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int i = y * w + x; const uint8_t *b = lossy1x + ((size_t)(y / 2) * (w / 2) + x / 2) * 3, *p = rgb + (size_t)i * 3;
        int g = p[1] - b[1];
        dec[0][i] = g; dec[1][i] = (p[0] - b[0]) - g; dec[2][i] = (p[2] - b[2]) - g;
    }
    Plane pl[3];
    for (int c = 0; c < 3; c++) { pl[c] = (Plane){ dec[c], w, h, c ? 1 : 0, 3, c ? dec[0] : NULL, NULL, NULL }; }
    RC r; rc_enc_init(&r, 4096); code_planes(&r, pl, 3); size_t sz = rc_enc_finish(&r);
    if (verify) {
        int32_t *chk[3]; for (int c = 0; c < 3; c++) chk[c] = calloc(n, sizeof(int32_t));
        Plane pd[3]; for (int c = 0; c < 3; c++) pd[c] = (Plane){ chk[c], w, h, c ? 1 : 0, 3, c ? chk[0] : NULL, NULL, NULL };
        RC d; rc_dec_init(&d, r.buf, sz); code_planes(&d, pd, 3);
        for (int c = 0; c < 3; c++) { if (memcmp(chk[c], dec[c], sizeof(int32_t) * n)) die("completion roundtrip"); free(chk[c]); }
    }
    for (int c = 0; c < 3; c++) free(dec[c]);
    *out = r.buf; return sz;
}

// ---------------------------------------------------------------- JPEG XL
static size_t jxl_enc(const uint8_t *rgb, int w, int h, int effort, int squeeze, int patches, uint8_t **out) {
    JxlEncoder *enc = JxlEncoderCreate(NULL);
    JxlBasicInfo bi; JxlEncoderInitBasicInfo(&bi);
    bi.xsize = w; bi.ysize = h; bi.bits_per_sample = 8; bi.num_color_channels = 3; bi.alpha_bits = 0; bi.uses_original_profile = JXL_TRUE;
    if (JxlEncoderSetBasicInfo(enc, &bi) != JXL_ENC_SUCCESS) die("jxl basic info");
    JxlColorEncoding ce; JxlColorEncodingSetToSRGB(&ce, JXL_FALSE); JxlEncoderSetColorEncoding(enc, &ce);
    JxlEncoderFrameSettings *fs = JxlEncoderFrameSettingsCreate(enc, NULL);
    JxlEncoderSetFrameLossless(fs, JXL_TRUE);
    JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_EFFORT, effort);
    if (patches >= 0) JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_PATCHES, patches);   // -1 = libjxl default
    if (squeeze) {
        JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_RESPONSIVE, 1);
        JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_PROGRESSIVE_AC, 1);
        if (squeeze > 1) JxlEncoderFrameSettingsSetOption(fs, JXL_ENC_FRAME_SETTING_QPROGRESSIVE_AC, 1);
    }
    JxlPixelFormat pf = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
    if (JxlEncoderAddImageFrame(fs, &pf, rgb, (size_t)w * h * 3) != JXL_ENC_SUCCESS) die("jxl add frame");
    JxlEncoderCloseInput(enc);
    size_t cap = 65536 + (size_t)w * h * 4; uint8_t *buf = malloc(cap), *next = buf; size_t avail = cap;
    JxlEncoderStatus st;
    while ((st = JxlEncoderProcessOutput(enc, &next, &avail)) == JXL_ENC_NEED_MORE_OUTPUT) {
        size_t off = next - buf; cap *= 2; buf = realloc(buf, cap); next = buf + off; avail = cap - off;
    }
    if (st != JXL_ENC_SUCCESS) die("jxl encode");
    JxlEncoderDestroy(enc);
    *out = buf; return next - buf;
}
// Decodes fully (checks bit-exactness) feeding `chunk` bytes at a time; returns the bytes provided when the decoder
// first reported a pass at downsampling ratio <= 2 (0 if never), and the ratios seen.
static size_t jxl_dec(const uint8_t *d, size_t n, size_t chunk, const uint8_t *ref, int w, int h, char *ratios, size_t rlen) {
    JxlDecoder *dec = JxlDecoderCreate(NULL);
    JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FRAME | (chunk ? JXL_DEC_FRAME_PROGRESSION : 0) | JXL_DEC_FULL_IMAGE);
    if (chunk && JxlDecoderSetProgressiveDetail(dec, kPasses) != JXL_DEC_SUCCESS) die("progressive detail");
    JxlPixelFormat pf = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
    uint8_t *pix = malloc((size_t)w * h * 3);
    if (chunk > 8 && chunk < n / 400) chunk = n / 400;   // big layers: ~400 probes (each flush renders the whole frame)
    size_t given = chunk ? (chunk < n ? chunk : n) : n, at2 = 0; int checked = 0, have_buf = 0, last_err = -1;
    if (ratios) ratios[0] = 0;
    JxlDecoderSetInput(dec, d, given);
    if (given == n) JxlDecoderCloseInput(dec);
    for (;;) {
        JxlDecoderStatus st = JxlDecoderProcessInput(dec); 
        if (st == JXL_DEC_NEED_MORE_INPUT) {
            // What a viewer could show now: flush the partial frame and compare its 2x2 block means with the
            // truth. Within +-1 everywhere = every 1x pixel is known (the 2:1 pass is complete).
            if (chunk && ref && have_buf && !at2 && JxlDecoderFlushImage(dec) == JXL_DEC_SUCCESS) {
                int maxe = 0;
                for (int y = 0; y + 1 < h; y += 2) for (int x = 0; x + 1 < w; x += 2) for (int c = 0; c < 3; c++) {
                    #define PX(b, yy, xx) (b)[((size_t)(yy) * w + (xx)) * 3 + c]
                    int m1 = PX(pix, y, x) + PX(pix, y, x + 1) + PX(pix, y + 1, x) + PX(pix, y + 1, x + 1);
                    int m2 = PX(ref, y, x) + PX(ref, y, x + 1) + PX(ref, y + 1, x) + PX(ref, y + 1, x + 1);
                    int e = abs(m1 - m2); if (e > 4 * maxe) maxe = (e + 3) / 4;
                }
                if (ratios && maxe != last_err && strlen(ratios) + 40 < rlen) { char t[48]; snprintf(t, sizeof t, "err%d@%zu ", maxe, given); strcat(ratios, t); }
                last_err = maxe;
                if (maxe <= JXL_2X_TOL) at2 = given;
            }
            size_t rem = JxlDecoderReleaseInput(dec);
            if (given >= n) die("jxl truncated");
            size_t start = given - rem; given = given + chunk < n ? given + chunk : n;
            JxlDecoderSetInput(dec, d + start, given - start);
            if (given == n) JxlDecoderCloseInput(dec);
        } else if (st == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
            JxlDecoderSetImageOutBuffer(dec, &pf, pix, (size_t)w * h * 3); have_buf = 1;
        } else if (st == JXL_DEC_FRAME_PROGRESSION) {
            size_t r = JxlDecoderGetIntendedDownsamplingRatio(dec);
            if (ratios && strlen(ratios) + 8 < rlen) { char t[16]; snprintf(t, sizeof t, "%zu@%zu ", r, given); strcat(ratios, t); }
            if (r <= 2 && !at2) at2 = given;
        } else if (st == JXL_DEC_FULL_IMAGE) {
            if (ref && memcmp(pix, ref, (size_t)w * h * 3)) die("jxl not lossless");
            checked = 1;
        } else if (st == JXL_DEC_SUCCESS) break;
        else if (st == JXL_DEC_ERROR) die("jxl decode error");
    }
    if (!checked) die("jxl: no full image");
    JxlDecoderDestroy(dec); free(pix);
    return at2;
}

// ---------------------------------------------------------------- per-region measurement
typedef struct {
    size_t jxlp, jxlsq_np, jxlsq_np_2x; double tJp_enc, tJp_dec;
    size_t A, base[2], dwebp[2], dz3[2], dz19[2], dlz4[2], dctx[2], jxl, jxlsq_full, jxlsq_2x, lossy2x, lossy1x, compl;
    double tA_enc, tA_dec, tB_enc[2], tB_dec[2], tBw_enc, tBw_dec, tJ_enc, tJ_dec, tJsq_enc, tJsq_dec, tz_dec;
    double tbase_enc, tbase_dec;
} Res;

static void measure(const uint8_t *rgb, int w, int h, int do_jxl, int jxl_effort, int extras, Res *R) {
    memset(R, 0, sizeof *R);
    uint8_t *buf, *chk = malloc((size_t)w * h * 3);
    double t;
    // A
    t = now_ms(); R->A = webp_ll(rgb, w, h, 3, WEBP_EFFORT, &buf); R->tA_enc = now_ms() - t;
    t = now_ms(); webp_dec(buf, R->A, chk, w, h, 3); R->tA_dec = now_ms() - t;
    if (memcmp(chk, rgb, (size_t)w * h * 3)) die("webp not lossless");
    WebPFree(buf);
    // B (0 = Haar, 1 = squeeze)
    for (int sq = 0; sq < 2; sq++) {
        Split S;
        double t0 = now_ms();
        split_fwd(rgb, w, h, w, sq, &S);
        double ttr = now_ms() - t0;
        uint8_t *bbuf; t = now_ms(); R->base[sq] = webp_ll(S.base, S.bw, S.bh, 3, WEBP_EFFORT, &bbuf); double tbe = now_ms() - t;
        uint8_t *bchk = malloc((size_t)S.bw * S.bh * 3);
        t = now_ms(); webp_dec(bbuf, R->base[sq], bchk, S.bw, S.bh, 3); double tbd = now_ms() - t;
        if (memcmp(bchk, S.base, (size_t)S.bw * S.bh * 3)) die("base not lossless");
        free(bchk); WebPFree(bbuf);
        if (!sq) { R->tbase_enc = tbe; R->tbase_dec = tbd; }
        // detail: WebP image
        t = now_ms(); R->dwebp[sq] = detail_webp(&S, &buf); double tdw = now_ms() - t;
        Split D = S; for (int k = 0; k < S.nbands; k++) for (int c = 0; c < 3; c++) D.band[k][c] = malloc(sizeof(int32_t) * S.bw * S.bandh[k]);
        D.base = S.base;
        bands_clear(&D); t = now_ms(); detail_webp_dec(&D, buf, R->dwebp[sq]); split_inv(&D, sq, chk); double tdwd = now_ms() - t;
        if (memcmp(chk, rgb, (size_t)w * h * 3)) die("B webp roundtrip");
        WebPFree(buf);
        if (!sq) { R->tBw_enc = ttr + tbe + tdw; R->tBw_dec = tbd + tdwd; }
        // detail: zstd / lz4
        uint8_t *ser; size_t sn = detail_serialise(&S, &ser);
        size_t cap = ZSTD_compressBound(sn); uint8_t *z = malloc(cap), *back = malloc(sn);
        R->dz3[sq] = ZSTD_compress(z, cap, ser, sn, 3);
        R->dz19[sq] = ZSTD_compress(z, cap, ser, sn, 19);
        t = now_ms(); if (ZSTD_decompress(back, sn, z, R->dz19[sq]) != sn) die("zstd"); bands_clear(&D); detail_deserialise(&D, back); split_inv(&D, sq, chk);
        if (!sq) R->tz_dec = tbd + now_ms() - t;
        if (memcmp(chk, rgb, (size_t)w * h * 3)) die("B zstd roundtrip");
        size_t lcap = LZ4_compressBound((int)sn); uint8_t *l = malloc(lcap);
        R->dlz4[sq] = LZ4_compress_HC((const char *)ser, (char *)l, (int)sn, (int)lcap, 9);
        if (LZ4_decompress_safe((const char *)l, (char *)back, (int)R->dlz4[sq], (int)sn) != (int)sn || memcmp(back, ser, sn)) die("lz4");
        free(z); free(back); free(l); free(ser);
        // detail: context coder
        t = now_ms(); R->dctx[sq] = detail_ctx(&S, &buf); double tdc = now_ms() - t;
        bands_clear(&D); t = now_ms(); detail_ctx_dec(&D, buf, R->dctx[sq]); split_inv(&D, sq, chk); double tdcd = now_ms() - t;
        if (memcmp(chk, rgb, (size_t)w * h * 3)) die("B ctx roundtrip");
        free(buf);
        R->tB_enc[sq] = ttr + tbe + tdc; R->tB_dec[sq] = tbd + tdcd;
        for (int k = 0; k < S.nbands; k++) for (int c = 0; c < 3; c++) free(D.band[k][c]);
        // D (once, on the Haar base): lossy 1x base + lossless 2x completion; and lossy 2x for reference
        if (!sq) {
            uint8_t *lb; R->lossy1x = webp_lossy(S.base, S.bw, S.bh, 75, &lb);
            uint8_t *dl = malloc((size_t)S.bw * S.bh * 3); webp_dec(lb, R->lossy1x, dl, S.bw, S.bh, 3); WebPFree(lb);
            uint8_t *cb; R->compl = completion_ctx(rgb, w, h, dl, &cb, 1); free(cb); free(dl);
            uint8_t *l2; R->lossy2x = webp_lossy(rgb, w, h, 75, &l2); WebPFree(l2);
        }
        split_free(&S);
    }
    // C
    if (do_jxl) {
        size_t chunk = (size_t)w * h > 100000 ? 256 : 8;
        t = now_ms(); R->jxl = jxl_enc(rgb, w, h, jxl_effort, 0, -1, &buf); R->tJ_enc = now_ms() - t;
        t = now_ms(); jxl_dec(buf, R->jxl, 0, rgb, w, h, NULL, 0); R->tJ_dec = now_ms() - t;
        free(buf);
        t = now_ms(); R->jxlsq_full = jxl_enc(rgb, w, h, jxl_effort, 1, -1, &buf); R->tJsq_enc = now_ms() - t;
        t = now_ms(); jxl_dec(buf, R->jxlsq_full, 0, rgb, w, h, NULL, 0); R->tJsq_dec = now_ms() - t;
        R->jxlsq_2x = jxl_dec(buf, R->jxlsq_full, chunk, rgb, w, h, NULL, 0);
        free(buf);
        if (extras) {   // layers: patches (glyph dictionary) forced on without squeeze; squeeze with patches off
            t = now_ms(); R->jxlp = jxl_enc(rgb, w, h, jxl_effort, 0, 1, &buf); R->tJp_enc = now_ms() - t;
            t = now_ms(); jxl_dec(buf, R->jxlp, 0, rgb, w, h, NULL, 0); R->tJp_dec = now_ms() - t;
            free(buf);
            R->jxlsq_np = jxl_enc(rgb, w, h, jxl_effort, 1, 0, &buf);
            R->jxlsq_np_2x = jxl_dec(buf, R->jxlsq_np, chunk, rgb, w, h, NULL, 0);
            free(buf);
        }
    }
    free(chk);
}

static int is_solid(const uint8_t *rgb, int stride, int x0, int y0) {
    const uint8_t *f = rgb + ((size_t)y0 * stride + x0) * 3;
    for (int y = 0; y < T; y++) for (int x = 0; x < T; x++) { const uint8_t *p = rgb + ((size_t)(y0 + y) * stride + x0 + x) * 3; if (p[0] != f[0] || p[1] != f[1] || p[2] != f[2]) return 0; }
    return 1;
}
static int colours(const uint8_t *rgb, int stride, int x0, int y0) {
    static uint32_t seen[T * T]; int n = 0;
    for (int y = 0; y < T; y++) for (int x = 0; x < T; x++) {
        const uint8_t *p = rgb + ((size_t)(y0 + y) * stride + x0 + x) * 3; uint32_t v = p[0] | p[1] << 8 | p[2] << 16; int k;
        for (k = 0; k < n && seen[k] != v; k++);
        if (k == n) { seen[n++] = v; if (n > 4096) return n; }
    }
    return n;
}

#define HDR "image,cat,x,y,colours,A,base_haar,base_sq,dwebp_haar,dwebp_sq,dz3_haar,dz3_sq,dz19_haar,dz19_sq,dlz4_haar,dlz4_sq,dctx_haar,dctx_sq,jxl,jxlsq_full,jxlsq_2x,lossy2x,lossy1x,compl,tA_enc,tA_dec,tBw_enc,tBw_dec,tBctx_enc,tBctx_dec,tBsq_enc,tBsq_dec,tz_dec,tbase_enc,tbase_dec,tJ_enc,tJ_dec,tJsq_enc,tJsq_dec,jxlp,tJp_enc,tJp_dec,jxlsq_np,jxlsq_np_2x\n"
static void row(FILE *f, const char *img, const char *cat, int x, int y, int col, const Res *R) {
    fprintf(f, "%s,%s,%d,%d,%d,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%zu,%.4f,%.4f,%zu,%zu\n",
            img, cat, x, y, col, R->A, R->base[0], R->base[1], R->dwebp[0], R->dwebp[1], R->dz3[0], R->dz3[1], R->dz19[0], R->dz19[1], R->dlz4[0], R->dlz4[1],
            R->dctx[0], R->dctx[1], R->jxl, R->jxlsq_full, R->jxlsq_2x, R->lossy2x, R->lossy1x, R->compl, R->tA_enc, R->tA_dec, R->tBw_enc, R->tBw_dec,
            R->tB_enc[0], R->tB_dec[0], R->tB_enc[1], R->tB_dec[1], R->tz_dec, R->tbase_enc, R->tbase_dec, R->tJ_enc, R->tJ_dec, R->tJsq_enc, R->tJsq_dec, R->jxlp, R->tJp_enc, R->tJp_dec, R->jxlsq_np, R->jxlsq_np_2x);
}

// ---------------------------------------------------------------- scroll: is the 1x base of a scrolled 2x frame derivable?
// For dy = 1..4 (2x pixels, content moves up by dy): new frame J(y) = I(y + dy) over the rows both share.
static void scroll_study(const uint8_t *rgb, int w, int h, const char *img, const char *cat, FILE *f) {
    int bw = w / 2;
    for (int dy = 1; dy <= 4; dy++) {
        int hj = (h - dy) / 2 * 2, bh = hj / 2;
        const uint8_t *J = rgb + (size_t)dy * w * 3;
        Split SI, SJ; split_fwd(rgb, w, h, w, 0, &SI); split_fwd(J, w, hj, w, 0, &SJ);   // SI covers every block the guess reads
        // (1) the 1x client's best guess from its own base alone: even dy -> base shifted by dy/2; odd dy -> the mean
        //     of the two base rows the new row straddles.
        // (2) base + LH band (the vertical half of the detail): exact for odd dy (new l1 = old l2 of block j+k, new l2 = old l1 of block j+k+1).
        long exact_guess = 0, exact_lh = 0, n = 0;
        uint8_t *guess = malloc((size_t)bw * bh * 3);
        int32_t *res[3]; for (int c = 0; c < 3; c++) res[c] = malloc(sizeof(int32_t) * bw * bh);
        int k = dy / 2;
        for (int y = 0; y < bh; y++) for (int x = 0; x < bw; x++) for (int c = 0; c < 3; c++) {
            int truth = SJ.base[((size_t)y * bw + x) * 3 + c], g, lhv;
            if (!(dy & 1)) { g = SI.base[((size_t)(y + k) * bw + x) * 3 + c]; lhv = g; }
            else {
                int i0 = (y + k) * bw + x, i1 = (y + k + 1) * bw + x;
                int a = SI.base[(size_t)i0 * 3 + c], b = SI.base[(size_t)i1 * 3 + c];
                g = (a + b + 1) >> 1;
                int l1_0 = a + ((SI.band[1][c][i0] + 1) >> 1), l2_0 = l1_0 - SI.band[1][c][i0];
                int l1_1 = b + ((SI.band[1][c][i1] + 1) >> 1);
                lhv = (l2_0 + l1_1) >> 1;
            }
            guess[((size_t)y * bw + x) * 3 + c] = (uint8_t)g;
            exact_guess += g == truth; exact_lh += lhv == truth; n++;
            res[c][y * bw + x] = truth - g;
        }
        // Bytes: the new base sent fresh (WebP), the residual against the guess (ctx), the LH band alone (ctx).
        size_t fresh = webp_ll(SJ.base, bw, bh, 3, WEBP_EFFORT, NULL);
        int32_t *dec[3]; for (int c = 0; c < 3; c++) dec[c] = malloc(sizeof(int32_t) * bw * bh);
        for (int i = 0; i < bw * bh; i++) { dec[0][i] = res[1][i]; dec[1][i] = res[0][i] - res[1][i]; dec[2][i] = res[2][i] - res[1][i]; }
        Plane pl[3]; for (int c = 0; c < 3; c++) pl[c] = (Plane){ dec[c], bw, bh, c ? 1 : 0, 4, c ? dec[0] : NULL, NULL, NULL };
        RC r; rc_enc_init(&r, 4096); code_planes(&r, pl, 3); size_t resid = rc_enc_finish(&r); free(r.buf);
        for (int i = 0; i < bw * bh; i++) { int g = SI.band[1][1][i]; dec[0][i] = g; dec[1][i] = SI.band[1][0][i] - g; dec[2][i] = SI.band[1][2][i] - g; }
        for (int c = 0; c < 3; c++) pl[c] = (Plane){ dec[c], bw, bh, c ? 1 : 0, 1, c ? dec[0] : NULL, NULL, NULL };
        rc_enc_init(&r, 4096); code_planes(&r, pl, 3); size_t lh = rc_enc_finish(&r); free(r.buf);
        size_t full2x = webp_ll(J, w, hj, 3, WEBP_EFFORT, NULL);
        fprintf(f, "%s,%s,%d,%ld,%.5f,%.5f,%zu,%zu,%zu,%zu\n", img, cat, dy, n, (double)exact_guess / n, (double)exact_lh / n, fresh, resid, lh, full2x);
        for (int c = 0; c < 3; c++) { free(res[c]); free(dec[c]); }
        free(guess); split_free(&SI); split_free(&SJ);
    }
}

// ---------------------------------------------------------------- 1x / 1.5x / 2x plain WebP-LL (what a non-scalable ladder costs)
// 1.5x: separable 4->3 area resample (weights 3:1, 1:1, 1:3 per group of four pixels, rounded); 1x: 2x2 box (rounded).
static uint8_t *resample(const uint8_t *in, int w, int h, int num, int *ow, int *oh) {   // num = 3 (x0.75) or 2 (x0.5)
    int gw = w / 4, gh = h / 4, W = gw * num, H = gh * num;
    uint8_t *tmp = malloc((size_t)W * h * 3), *out = malloc((size_t)W * H * 3);
    static const int w3[3][4] = { {3, 1, 0, 0}, {0, 2, 2, 0}, {0, 0, 1, 3} }, w2[2][4] = { {2, 2, 0, 0}, {0, 0, 2, 2} };
    for (int y = 0; y < h; y++) for (int g = 0; g < gw; g++) for (int o = 0; o < num; o++) for (int c = 0; c < 3; c++) {
        int acc = 0; for (int k = 0; k < 4; k++) acc += (num == 3 ? w3[o][k] : w2[o][k]) * in[((size_t)y * w + g * 4 + k) * 3 + c];
        tmp[((size_t)y * W + g * num + o) * 3 + c] = (uint8_t)((acc + 2) / 4);
    }
    for (int g = 0; g < gh; g++) for (int o = 0; o < num; o++) for (int x = 0; x < W; x++) for (int c = 0; c < 3; c++) {
        int acc = 0; for (int k = 0; k < 4; k++) acc += (num == 3 ? w3[o][k] : w2[o][k]) * tmp[((size_t)(g * 4 + k) * W + x) * 3 + c];
        out[((size_t)(g * num + o) * W + x) * 3 + c] = (uint8_t)((acc + 2) / 4);
    }
    free(tmp); *ow = W; *oh = H; return out;
}
static void scales_study(const uint8_t *rgb, int w, int h, const char *img, const char *cat, FILE *f) {
    int w15, h15, w1, h1;
    uint8_t *s15 = resample(rgb, w, h, 3, &w15, &h15), *s1 = resample(rgb, w, h, 2, &w1, &h1);
    size_t L2 = webp_ll(rgb, w, h, 3, WEBP_EFFORT, NULL), L15 = webp_ll(s15, w15, h15, 3, WEBP_EFFORT, NULL), L1 = webp_ll(s1, w1, h1, 3, WEBP_EFFORT, NULL);
    // per tile: the same screen area (64 px at 2x = 48 at 1.5x = 32 at 1x), non-solid tiles of the 2x grid only
    size_t T2 = 0, T15 = 0, T1 = 0; int n = 0;
    uint8_t *t = malloc(T * T * 3);
    for (int ty = 0; ty < h; ty += T) for (int tx = 0; tx < w; tx += T) {
        if (is_solid(rgb, w, tx, ty)) continue;
        n++;
        for (int y = 0; y < T; y++) memcpy(t + y * T * 3, rgb + ((size_t)(ty + y) * w + tx) * 3, T * 3);
        T2 += webp_ll(t, T, T, 3, WEBP_EFFORT, NULL);
        int q = T * 3 / 4;
        for (int y = 0; y < q; y++) memcpy(t + y * q * 3, s15 + ((size_t)(ty * 3 / 4 + y) * w15 + tx * 3 / 4) * 3, q * 3);
        T15 += webp_ll(t, q, q, 3, WEBP_EFFORT, NULL);
        q = T / 2;
        for (int y = 0; y < q; y++) memcpy(t + y * q * 3, s1 + ((size_t)(ty / 2 + y) * w1 + tx / 2) * 3, q * 3);
        T1 += webp_ll(t, q, q, 3, WEBP_EFFORT, NULL);
    }
    fprintf(f, "%s,%s,%zu,%zu,%zu,%d,%zu,%zu,%zu\n", img, cat, L2, L15, L1, n, T2, T15, T1);
    free(t); free(s15); free(s1);
}

// ---------------------------------------------------------------- Laplacian variant: 2x residual against the upsampled 1x base,
// mod 256, as a full-size RGB image for WebP lossless (redundant: four values per 2x2 block instead of three, but WebP's
// spatial predictors, colour cache and LZ77 then run at 2x). Predictors: 0 = nearest (pixel replication), 1 = bilinear.
static void lap_residual(const uint8_t *t, const uint8_t *base, int n, int pred, uint8_t *res) {
    int b = n / 2;
    for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) for (int c = 0; c < 3; c++) {
        int p;
        if (!pred) p = base[((y / 2) * b + x / 2) * 3 + c];
        else {   // bilinear between base sample centres, in quarter-pixel units, clamped at the tile edge
            int fy = 2 * y - 1, fx = 2 * x - 1;
            int y0 = fy < 0 ? 0 : fy / 4, x0 = fx < 0 ? 0 : fx / 4, y1 = y0 + 1 < b ? y0 + 1 : y0, x1 = x0 + 1 < b ? x0 + 1 : x0;
            int wy = fy < 0 ? 0 : fy % 4, wx = fx < 0 ? 0 : fx % 4;
            int p00 = base[(y0 * b + x0) * 3 + c], p01 = base[(y0 * b + x1) * 3 + c], p10 = base[(y1 * b + x0) * 3 + c], p11 = base[(y1 * b + x1) * 3 + c];
            p = ((4 - wy) * ((4 - wx) * p00 + wx * p01) + wy * ((4 - wx) * p10 + wx * p11) + 8) / 16;
        }
        res[(y * n + x) * 3 + c] = (uint8_t)(t[(y * n + x) * 3 + c] - p);
    }
}
static void lap_study(const uint8_t *rgb, int w, int h, const char *img, const char *cat, FILE *f) {
    size_t sA = 0, sBase = 0, sNear = 0, sBil = 0; int n = 0;
    uint8_t *t = malloc(T * T * 3), *res = malloc(T * T * 3);
    for (int ty = 0; ty < h; ty += T) for (int tx = 0; tx < w; tx += T) {
        if (is_solid(rgb, w, tx, ty)) continue;
        n++;
        for (int y = 0; y < T; y++) memcpy(t + y * T * 3, rgb + ((size_t)(ty + y) * w + tx) * 3, T * 3);
        Split S; split_fwd(t, T, T, T, 0, &S);
        sA += webp_ll(t, T, T, 3, WEBP_EFFORT, NULL);
        sBase += webp_ll(S.base, T / 2, T / 2, 3, WEBP_EFFORT, NULL);
        lap_residual(t, S.base, T, 0, res); sNear += webp_ll(res, T, T, 3, WEBP_EFFORT, NULL);
        lap_residual(t, S.base, T, 1, res); sBil += webp_ll(res, T, T, 3, WEBP_EFFORT, NULL);
        split_free(&S);
    }
    fprintf(f, "%s,%s,%d,%zu,%zu,%zu,%zu\n", img, cat, n, sA, sBase, sNear, sBil);
    free(t); free(res);
}

int main(int argc, char **argv) {
    if (argc >= 5 && !strcmp(argv[1], "--lap")) {
        int w, h; uint8_t *rgb = load_rgb(argv[2], &w, &h);
        FILE *f = fopen(argv[4], "a"); if (!f) die("lap csv");
        const char *b = strrchr(argv[2], '/'); b = b ? b + 1 : argv[2];
        lap_study(rgb, w, h, b, argv[3], f); fclose(f); free(rgb); return 0;
    }
    if (argc >= 5 && !strcmp(argv[1], "--scales")) {
        int w, h; uint8_t *rgb = load_rgb(argv[2], &w, &h);
        FILE *f = fopen(argv[4], "a"); if (!f) die("scales csv");
        const char *b = strrchr(argv[2], '/'); b = b ? b + 1 : argv[2];
        scales_study(rgb, w, h, b, argv[3], f); fclose(f); free(rgb); return 0;
    }
    if (argc >= 5 && !strcmp(argv[1], "--scroll")) {
        int w, h; uint8_t *rgb = load_rgb(argv[2], &w, &h);
        FILE *f = fopen(argv[4], "a"); if (!f) die("scroll csv");
        const char *b = strrchr(argv[2], '/'); b = b ? b + 1 : argv[2];
        scroll_study(rgb, w, h, b, argv[3], f); fclose(f); free(rgb); return 0;
    }
    if (argc >= 5 && !strcmp(argv[1], "--jxlfile")) {   // progression of an existing .jxl (W H given)
        FILE *f = fopen(argv[2], "rb"); fseek(f, 0, SEEK_END); size_t n = ftell(f); fseek(f, 0, SEEK_SET);
        uint8_t *d = malloc(n); fread(d, 1, n, f); fclose(f); char ratios[8192];
        size_t at2 = jxl_dec(d, n, 256, NULL, atoi(argv[3]), atoi(argv[4]), ratios, sizeof ratios);
        printf("%zu bytes, 2:1 at %zu; passes: %s\n", n, at2, ratios); return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "--jxlprobe")) {   // which passes does libjxl emit for lossless squeeze?
        int w, h; uint8_t *rgb = load_rgb(argv[2], &w, &h);
        int tw = argc > 3 ? atoi(argv[3]) : w, th = tw == w ? h : tw;
        uint8_t *crop = malloc((size_t)tw * th * 3);
        for (int y = 0; y < th; y++) memcpy(crop + (size_t)y * tw * 3, rgb + ((size_t)y * w) * 3, (size_t)tw * 3);
        for (int mode = 0; mode <= 2; mode++) {
            uint8_t *buf; size_t n = jxl_enc(crop, tw, th, 7, mode, -1, &buf); char ratios[4096];
            size_t at2 = jxl_dec(buf, n, tw * th > 100000 ? 256 : 8, crop, tw, th, ratios, sizeof ratios);
            printf("mode %d: %zu bytes, 2:1 at %zu; passes: %s\n", mode, n, at2, ratios); free(buf);
        }
        return 0;
    }
    if (argc < 5) { fprintf(stderr, "usage: scalebench IMAGE CATEGORY TILES.csv LAYERS.csv [--stride N] [--no-jxl] [--no-layer] [--jxl-effort E]\n"); return 2; }
    int stride = 1, do_jxl = 1, do_layer = 1, jxl_effort = 7;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--stride")) stride = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--no-jxl")) do_jxl = 0;
        else if (!strcmp(argv[i], "--no-layer")) do_layer = 0;
        else if (!strcmp(argv[i], "--jxl-effort")) jxl_effort = atoi(argv[++i]);
    }
    int w, h; uint8_t *rgb = load_rgb(argv[1], &w, &h);
    const char *b = strrchr(argv[1], '/'); b = b ? b + 1 : argv[1];
    FILE *ft = fopen(argv[3], "a"), *fl = fopen(argv[4], "a");
    if (!ft || !fl) die("csv");
    uint8_t *tile = malloc(T * T * 3);
    int idx = 0, solid = 0;
    for (int ty = 0; ty < h; ty += T) for (int tx = 0; tx < w; tx += T) {
        if (is_solid(rgb, w, tx, ty)) { solid++; continue; }
        if (idx++ % stride) continue;
        for (int y = 0; y < T; y++) memcpy(tile + y * T * 3, rgb + ((size_t)(ty + y) * w + tx) * 3, T * 3);
        Res R; measure(tile, T, T, do_jxl, jxl_effort, 0, &R);
        row(ft, b, argv[2], tx, ty, colours(rgb, w, tx, ty), &R);
    }
    if (do_layer) {
        Res R; measure(rgb, w, h, do_jxl, jxl_effort, 1, &R);
        row(fl, b, argv[2], w, h, solid, &R);    // layer rows: x,y = size, colours = solid tile count
    }
    fclose(ft); fclose(fl);
    return 0;
}
