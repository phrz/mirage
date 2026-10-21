/// Metal source, compiled at launch (keeps the SwiftPM build free of a metallib step).
///
/// Coordinates: "content pt" are the host document's points (900 x 6000); the truth texture is 2x.
/// The fill lives in content space: a low-resolution texture of the whole document ("base", 1/divisor of the
/// truth's pixels), recomputed when delivered content changes and eased into a cache with an EMA every frame.
/// The composite samples that cache bicubically at the pixel's content position, so the fill moves rigidly with
/// the content and never snaps to a grid. The boundary (displayed intervals) is sub-pixel and spring-driven.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 bg;
    float viewTopPt, ptPerPx, drawW, drawH;
    float contentW, contentH, baseW, baseH;
    float confTop, confBottom, emaK, emaRow0;
    float feather, ext, vignette, desat;
    float grain, tint, rim, smearRows;
    float tileRows, tileShift, srcLod, warpAmp;
    float warpSpeed, warpTime, pad0, pad1;
    int style, showBoundary, nDelivered, nDisplayed;
};

constant int FLAT = 0, KAWASE = 1, MIRROR = 2, SMEAR = 3, FROSTED = 4, AWARE = 5, PULLPUSH = 6;

constexpr sampler lin(filter::linear, mip_filter::linear, address::clamp_to_edge);

// ---- 2D simplex noise (after Gustavson / McEwan) ----
static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float2 mod289(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float3 permute(float3 x) { return mod289(((x * 34.0) + 1.0) * x); }
static float snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1, 0) : float2(0, 1);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = mod289(i);
    float3 p = permute(permute(i.y + float3(0, i1.y, 1)) + i.x + float3(0, i1.x, 1));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m; m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Nearest boundary of a set of known intervals [a, b) in content pt. d is signed: negative inside known
/// (distance to the nearest real boundary; document ends are not boundaries), positive outside.
/// edge is that boundary, dir points from it into the known interval, h is the interval's height.
struct Near { float d; float edge; float dir; float h; bool inside; };
static Near nearest(constant float2* iv, int n, float r, float H) {
    Near o; o.d = 1e9; o.edge = 0; o.dir = 1; o.h = 1; o.inside = false;
    for (int i = 0; i < n; i++) {
        float a = iv[i].x, b = iv[i].y;
        if (r >= a && r < b) {
            float ea = a <= 0.0 ? 1e9 : r - a;
            float eb = b >= H ? 1e9 : b - r;
            o.inside = true; o.d = -min(ea, eb);
            o.edge = ea < eb ? a : b; o.dir = ea < eb ? 1.0 : -1.0; o.h = b - a;
            return o;
        }
        float d = r < a ? a - r : r - b;
        if (d < o.d) { o.d = d; o.edge = r < a ? a : b; o.dir = r < a ? 1.0 : -1.0; o.h = b - a; }
    }
    return o;
}

/// Signed distance to a set of possibly overlapping intervals: the minimum over intervals of each one's own signed
/// distance, so the truth weight smoothstep(0, F, -sd) is the maximum of the intervals' own ramps. Two displayed
/// intervals sweeping into each other therefore close their gap continuously instead of popping when they merge.
static float signedDist(constant float2* iv, int n, float r, float H) {
    float sd = 1e9;
    for (int i = 0; i < n; i++) {
        float a = iv[i].x, b = iv[i].y;
        float s;
        if (r >= a && r < b) {
            float ea = a <= 0.0 ? 1e9 : r - a;
            float eb = b >= H ? 1e9 : b - r;
            s = -min(ea, eb);
        } else {
            s = r < a ? a - r : r - b;
        }
        sd = min(sd, s);
    }
    return sd;
}

/// Where an unknown point (x, r) samples the known content, for the extension styles.
static float2 mapFill(constant Uniforms& U, Near nr, float x) {
    float d = max(nr.d, 0.0);
    float edgeRow = nr.edge + nr.dir * 0.5;
    float h = max(nr.h - 1.0, 1.0);
    switch (U.style) {
        case MIRROR: {
            float m = fmod(d, 2.0 * h);
            float into = m <= h ? m : 2.0 * h - m;
            return float2(x, edgeRow + nr.dir * into);
        }
        case SMEAR: {
            float n = min(U.smearRows, h);
            return float2(x, edgeRow + nr.dir * n * min(1.0, d / max(U.ext, 1.0)));
        }
        case AWARE: {
            float T = min(U.tileRows, h);
            float k = floor(d / T);
            float into = T - fmod(d, T);
            float xs = clamp(x + (k + 1.0) * U.tileShift * (nr.dir < 0.0 ? 1.0 : -1.0), 0.0, U.contentW);
            return float2(xs, edgeRow + nr.dir * into);
        }
        default:
            return float2(x, edgeRow);
    }
}

static float4 sampleTruth(texture2d<float> truth, constant Uniforms& U, float2 p, float lod) {
    float2 uv = float2(p.x / U.contentW, clamp(p.y, 0.0, U.contentH - 0.25) / U.contentH);
    return truth.sample(lin, uv, level(lod));
}

// ---- Per-row average colour of the truth (once per tab): today's flat fill colour and the dissolve target ----
kernel void rowAverage(texture2d<float> truth [[texture(0)]], device float4* out [[buffer(0)]],
                       uint row [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float4 part[128];
    // Mip level 1 is 1 px per content pt.
    uint w = truth.get_width(1);
    float4 acc = 0;
    for (uint x = tid; x < w; x += 128) acc += truth.read(uint2(x, row), 1);
    part[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 64; s > 0; s >>= 1) {
        if (tid < s) part[tid] += part[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) out[row] = float4(part[0].rgb / float(w), 1.0);
}

static float4 rowAvgAt(const device float4* rowAvg, constant Uniforms& U, Near nr) {
    int r = clamp(int(nr.edge + nr.dir * 0.5), 0, int(U.contentH) - 1);
    return rowAvg[r];
}

// ---- Fill recompute, whole document in content space ----
// Base image: known rows are the truth (downsampled); unknown rows are the style's extension, or coverage 0 for
// pull-push (premultiplied colour + coverage).
kernel void buildSource(texture2d<float> truth [[texture(0)]], texture2d<float, access::write> out [[texture(1)]],
                        constant Uniforms& U [[buffer(0)]], constant float2* delivered [[buffer(1)]],
                        const device float4* rowAvg [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float x = (float(gid.x) + 0.5) / U.baseW * U.contentW;
    float r = (float(gid.y) + 0.5) / U.baseH * U.contentH;
    if (U.nDelivered == 0) { out.write(U.style == PULLPUSH ? float4(0) : U.bg, gid); return; }
    Near nr = nearest(delivered, U.nDelivered, r, U.contentH);
    // Flat (today's look): the nearest edge row's average colour everywhere, so rows not yet revealed are flat too.
    if (U.style == FLAT) { out.write(rowAvgAt(rowAvg, U, nr), gid); return; }
    if (nr.inside) { out.write(float4(sampleTruth(truth, U, float2(x, r), U.srcLod).rgb, 1.0), gid); return; }
    if (U.style == PULLPUSH) { out.write(float4(0), gid); return; }
    out.write(float4(sampleTruth(truth, U, mapFill(U, nr, x), U.srcLod).rgb, 1.0), gid);
}

// Dual Kawase.
kernel void kawaseDown(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                       constant float& offset [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 sz = float2(dst.get_width(), dst.get_height());
    if (gid.x >= uint(sz.x) || gid.y >= uint(sz.y)) return;
    float2 uv = (float2(gid) + 0.5) / sz;
    float2 hp = offset * 0.5 / sz;
    float4 s = src.sample(lin, uv, level(0)) * 4.0;
    s += src.sample(lin, uv - hp, level(0));
    s += src.sample(lin, uv + hp, level(0));
    s += src.sample(lin, uv + float2(hp.x, -hp.y), level(0));
    s += src.sample(lin, uv - float2(hp.x, -hp.y), level(0));
    dst.write(s / 8.0, gid);
}

kernel void kawaseUp(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                     constant float& offset [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 sz = float2(dst.get_width(), dst.get_height());
    if (gid.x >= uint(sz.x) || gid.y >= uint(sz.y)) return;
    float2 uv = (float2(gid) + 0.5) / sz;
    float2 hp = offset * 0.5 / sz;
    float4 s = src.sample(lin, uv + float2(-hp.x * 2.0, 0.0), level(0));
    s += src.sample(lin, uv + float2(-hp.x, hp.y), level(0)) * 2.0;
    s += src.sample(lin, uv + float2(0.0, hp.y * 2.0), level(0));
    s += src.sample(lin, uv + float2(hp.x, hp.y), level(0)) * 2.0;
    s += src.sample(lin, uv + float2(hp.x * 2.0, 0.0), level(0));
    s += src.sample(lin, uv + float2(hp.x, -hp.y), level(0)) * 2.0;
    s += src.sample(lin, uv + float2(0.0, -hp.y * 2.0), level(0));
    s += src.sample(lin, uv + float2(-hp.x, -hp.y), level(0)) * 2.0;
    dst.write(s / 12.0, gid);
}

// Pull-push (Lumigraph-style hole filling), our own implementation of the public algorithm.
// Pull: each coarser texel = mean of its 2x2 children (premultiplied rgb and coverage).
kernel void pullDown(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint sw = src.get_width(), sh = src.get_height();
    float4 acc = 0; float n = 0;
    for (uint j = 0; j < 2; j++) for (uint i = 0; i < 2; i++) {
        uint2 p = gid * 2 + uint2(i, j);
        if (p.x < sw && p.y < sh) { acc += src.read(p); n += 1; }
    }
    dst.write(n > 0 ? acc / n : float4(0), gid);
}

// Push: result = own + (1 - coverage) * upsampled(coarser result), renormalised (alpha 1).
kernel void pushUp(texture2d<float> lvl [[texture(0)]], texture2d<float> coarser [[texture(1)]],
                   texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    float2 sz = float2(dst.get_width(), dst.get_height());
    if (gid.x >= uint(sz.x) || gid.y >= uint(sz.y)) return;
    float4 own = lvl.read(gid);
    float4 up = coarser.sample(lin, (float2(gid) + 0.5) / sz, level(0));
    float4 c = own + (1.0 - saturate(own.a)) * up;
    c.rgb /= max(c.a, 1e-4);
    dst.write(float4(c.rgb, 1.0), gid);
}

kernel void pushTop(texture2d<float> lvl [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = lvl.read(gid);
    dst.write(float4(c.a > 1e-5 ? c.rgb / c.a : float3(0.5), 1.0), gid);
}

// Style-specific finish of the recomputed fill (content space): smear's sharp-to-blur ramp, and the dissolve
// into the edge row's average colour beyond the extension length.
kernel void combineFill(texture2d<float> source [[texture(0)]], texture2d<float> blurred [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]], constant Uniforms& U [[buffer(0)]],
                        constant float2* delivered [[buffer(1)]], const device float4* rowAvg [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 bl = blurred.read(gid);
    if (U.style == FLAT || U.nDelivered == 0) { dst.write(U.style == FLAT ? source.read(gid) : bl, gid); return; }
    float r = (float(gid.y) + 0.5) / U.baseH * U.contentH;
    Near nr = nearest(delivered, U.nDelivered, r, U.contentH);
    float4 c = bl;
    if (!nr.inside) {
        float d = nr.d;
        if (U.style == SMEAR) c = mix(source.read(gid), bl, smoothstep(0.0, 0.6, d / max(U.ext, 1.0)));
        if (U.style != PULLPUSH) c = mix(c, rowAvgAt(rowAvg, U, nr), smoothstep(U.ext * 0.6, U.ext * 1.6, d));
    }
    dst.write(float4(c.rgb, 1.0), gid);
}

// Every frame: the cache eases toward the latest recomputed fill (EMA), over a window of rows around the view.
kernel void emaBlend(texture2d<float> target [[texture(0)]], texture2d<float, access::read_write> cache [[texture(1)]],
                     constant Uniforms& U [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint2 p = uint2(gid.x, gid.y + uint(U.emaRow0));
    if (p.x >= cache.get_width() || p.y >= cache.get_height()) return;
    cache.write(mix(cache.read(p), target.read(p), U.emaK), p);
}

// ---- Composite ----
struct VOut { float4 pos [[position]]; };
vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}

/// Cubic B-spline sampling from four bilinear taps: smooth (C2) and with no visible texel grid.
static float4 bspline(texture2d<float> t, float2 uv) {
    float2 size = float2(t.get_width(), t.get_height());
    float2 p = uv * size - 0.5;
    float2 i = floor(p), f = p - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1, g1 = w2 + w3;
    float2 h0 = (i - 1.0 + w1 / g0 + 0.5) / size;
    float2 h1 = (i + 1.0 + w3 / g1 + 0.5) / size;
    float4 s00 = t.sample(lin, float2(h0.x, h0.y), level(0)), s10 = t.sample(lin, float2(h1.x, h0.y), level(0));
    float4 s01 = t.sample(lin, float2(h0.x, h1.y), level(0)), s11 = t.sample(lin, float2(h1.x, h1.y), level(0));
    return g0.y * (g0.x * s00 + g1.x * s10) + g1.y * (g0.x * s01 + g1.x * s11);
}

fragment float4 compositeFS(VOut in [[stage_in]],
                            texture2d<float> truth [[texture(0)]],
                            texture2d<float> cache [[texture(1)]],
                            constant Uniforms& U [[buffer(0)]],
                            constant float2* displayed [[buffer(1)]],
                            constant float2* delivered [[buffer(2)]]) {
    float2 px = in.pos.xy;
    float x = px.x * U.ptPerPx;
    float r = U.viewTopPt + px.y * U.ptPerPx;
    if (r < 0.0 || r >= U.contentH) return U.bg;
    float4 truthC = truth.sample(lin, float2(x / U.contentW, r / U.contentH));
    // Signed distance to the displayed (spring-driven, sub-pixel) boundary; negative inside known.
    float sd = U.nDisplayed > 0 ? signedDist(displayed, U.nDisplayed, r, U.contentH) : 1e9;
    // One continuous ramp: truth fades into the fill across the feather band inside the boundary; outside, fill only.
    float wTruth = U.feather > 0.0 ? smoothstep(0.0, U.feather, -sd) : (sd < 0.0 ? 1.0 : 0.0);
    float4 outC;
    if (wTruth >= 1.0) {
        outC = truthC;
    } else {
        float2 uv = float2(x / U.contentW, r / U.contentH);
        if (U.warpAmp > 0.0 && U.style != FLAT) {
            // Slow "blobby" drift: a low-frequency domain warp anchored to content, zero at the boundary.
            float2 q = float2(x, r) / 180.0;
            float t = U.warpTime * U.warpSpeed;
            float2 n = float2(snoise(q + float2(0.0, t)), snoise(q + float2(31.7, -t * 0.83)));
            uv += n * U.warpAmp * smoothstep(0.0, 60.0, sd) / float2(U.contentW, U.contentH);
        }
        float4 c = bspline(cache, uv);
        if (U.style != FLAT) {
            // Effects ramp from the inner edge of the feather band outward, so nothing is ever "clear".
            float t = smoothstep(-U.feather, max(U.ext, 1.0), sd);
            if (U.style == FROSTED) {
                float tt = smoothstep(-U.feather, U.feather * 0.5 + 8.0, sd);
                c.rgb = mix(c.rgb, mix(c.rgb, float3(1.0), 0.6), U.tint * tt);
                float l = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
                c.rgb = mix(float3(l), c.rgb, 1.0 + 0.3 * U.tint * tt);       // vibrancy
                c.rgb += U.rim * 0.18 * exp(-abs(sd) / 3.0);                     // glass rim on the boundary
            }
            float l = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
            c.rgb = mix(c.rgb, float3(l), U.desat * t);
            float hx = abs(px.x / U.drawW - 0.5) * 2.0;
            c.rgb *= 1.0 - 0.35 * U.vignette * t * (0.65 + 0.35 * hx * hx);
            c.rgb += (hash12(px) - 0.5) * U.grain * 0.12 * smoothstep(-U.feather, 24.0, sd);
        }
        outC = mix(float4(saturate(c.rgb), 1.0), truthC, wTruth);
    }
    if (U.showBoundary != 0) {
        float lw = U.ptPerPx * 1.5;
        if (sd >= 0.0) {
            float stripe = fmod(floor((px.x + px.y) / 10.0), 2.0);
            outC.rgb = mix(outC.rgb, float3(0.9, 0.1, 0.6), 0.12 + 0.08 * stripe);
        }
        float dd = U.nDelivered > 0 ? abs(nearest(delivered, U.nDelivered, r, U.contentH).d) : 1e9;
        if (abs(sd) < lw) outC = float4(0.1, 0.85, 0.3, 1);
        else if (dd < lw) outC = float4(1.0, 0.8, 0.1, 1);
        else if ((abs(r - U.confTop) < lw || abs(r - U.confBottom) < lw) && fmod(floor(px.x / 12.0), 2.0) < 1.0) outC = float4(0.2, 0.5, 1.0, 1);
    }
    return outC;
}
"""#
