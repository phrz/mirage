/// Metal source, compiled at launch (keeps the SwiftPM build free of a metallib step).
/// Coordinates: "content pt" are the host document's points (900 x 6000); the truth texture is 2x.
let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 bg;
    float viewTopPt, ptPerPx, drawW, drawH;
    float contentW, contentH, sTop, sBottom;
    float kTop, kBottom, confTop, confBottom;
    float now, crossfade, feather, innerFeather;
    float ext, vignette, desat, grain;
    float tint, rim, smearRows, tileRows;
    float tileShift, regTop, regH, srcLod;
    float warpAmp, warpSpeed, warpTime, blendK;
    float prevRegTop, prevRegH, pad2, pad3;
    int style, showBoundary, hasKnown, pad1;
};

// Style ids
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

static bool inSettled(constant Uniforms& U, float r) { return U.hasKnown != 0 && r >= U.sTop && r < U.sBottom; }

/// Where a fill pixel at content (x, r) samples the known content. Identity inside the settled band.
static float2 mapFill(constant Uniforms& U, float x, float r) {
    if (U.hasKnown == 0 || inSettled(U, r)) return float2(x, r);
    bool below = r >= U.sBottom;
    float d = below ? (r - U.sBottom) : (U.sTop - r);
    float edge = below ? U.sBottom - 0.5 : U.sTop + 0.5;
    float dir = below ? -1.0 : 1.0;       // direction pointing into the known band
    float h = max(U.sBottom - U.sTop - 1.0, 1.0);
    switch (U.style) {
        case MIRROR: {
            float m = fmod(d, 2.0 * h);
            float into = m <= h ? m : 2.0 * h - m;
            return float2(x, edge + dir * into);
        }
        case SMEAR: {
            float n = min(U.smearRows, h);
            return float2(x, edge + dir * n * min(1.0, d / max(U.ext, 1.0)));
        }
        case AWARE: {
            float T = min(U.tileRows, h);
            float k = floor(d / T);
            float into = T - fmod(d, T);
            float xs = clamp(x + (k + 1.0) * U.tileShift * (below ? 1.0 : -1.0), 0.0, U.contentW);
            return float2(xs, edge + dir * into);
        }
        default:
            return float2(x, edge);
    }
}

static float4 sampleTruth(texture2d<float> truth, constant Uniforms& U, float2 p, float lod) {
    float2 uv = float2(p.x / U.contentW, clamp(p.y, 0.0, U.contentH - 0.25) / U.contentH);
    return truth.sample(lin, uv, level(lod));
}

// ---- Fill pass: base texture over the fill region (viewport plus padding) ----
kernel void buildSource(texture2d<float> truth [[texture(0)]],
                        texture2d<float, access::write> out [[texture(1)]],
                        constant Uniforms& U [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint w = out.get_width(), h = out.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float x = (float(gid.x) + 0.5) / float(w) * U.contentW;
    float r = U.regTop + (float(gid.y) + 0.5) / float(h) * U.regH;
    if (U.style == PULLPUSH) {
        // Premultiplied colour + coverage: known = 1, unknown = 0.
        float cov = (inSettled(U, r) && r >= 0.0 && r < U.contentH) ? 1.0 : 0.0;
        float4 c = cov > 0.0 ? sampleTruth(truth, U, float2(x, r), U.srcLod) : float4(0);
        out.write(float4(c.rgb * cov, cov), gid);
        return;
    }
    float2 m = mapFill(U, x, r);
    float4 c = sampleTruth(truth, U, m, U.srcLod);
    out.write(float4(c.rgb, 1.0), gid);
}

// ---- Dual Kawase ----
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

// ---- Pull-push (Lumigraph-style hole filling), our own implementation of the public algorithm ----
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

// Push: result = own + (1 - coverage) * upsampled(coarser result); output is normalised (alpha 1).
kernel void pushUp(texture2d<float> lvl [[texture(0)]], texture2d<float> coarser [[texture(1)]],
                   texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    float2 sz = float2(dst.get_width(), dst.get_height());
    if (gid.x >= uint(sz.x) || gid.y >= uint(sz.y)) return;
    float4 own = lvl.read(gid);
    float2 uv = (float2(gid) + 0.5) / sz;
    float4 up = coarser.sample(lin, uv, level(0));       // already normalised, alpha ~1
    float4 c = own + (1.0 - saturate(own.a)) * up;
    c.rgb /= max(c.a, 1e-4);
    dst.write(float4(c.rgb, 1.0), gid);
}

// Coarsest level: just normalise.
kernel void pushTop(texture2d<float> lvl [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = lvl.read(gid);
    dst.write(float4(c.a > 1e-5 ? c.rgb / c.a : float3(0.5), 1.0), gid);
}

// ---- Temporal smoothing of the fill, reprojected in content space: fill changes (an edge advancing, a style's
// extension being replaced by newly arrived content) ease in instead of popping. ----
kernel void temporalBlend(texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]], constant Uniforms& U [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    float2 sz = float2(dst.get_width(), dst.get_height());
    if (gid.x >= uint(sz.x) || gid.y >= uint(sz.y)) return;
    float4 c = cur.read(gid);
    float r = U.regTop + (float(gid.y) + 0.5) / sz.y * U.regH;
    float pv = (r - U.prevRegTop) / U.prevRegH;
    float k = U.blendK;
    if (pv < 0.0 || pv > 1.0) k = 1.0;
    float4 p = prev.sample(lin, float2((float(gid.x) + 0.5) / sz.x, pv), level(0));
    dst.write(mix(p, c, k), gid);
}

// ---- Average colour of the known band's top and bottom rows (today's flat fill colour) ----
kernel void edgeAverage(texture2d<float> truth [[texture(0)]], device float4* out [[buffer(0)]],
                        constant Uniforms& U [[buffer(1)]],
                        uint tg [[threadgroup_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float4 part[256];
    float r = tg == 0 ? U.sTop + 0.25 : U.sBottom - 0.25;
    uint y = uint(clamp(r * 2.0, 0.0, float(truth.get_height() - 1)));
    uint w = truth.get_width();
    float4 acc = 0;
    for (uint x = tid; x < w; x += 256) acc += truth.read(uint2(x, y));
    part[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128; s > 0; s >>= 1) {
        if (tid < s) part[tid] += part[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) out[tg] = float4(part[0].rgb / float(w), 1.0);
}

// ---- Composite ----
struct VOut { float4 pos [[position]]; };
vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}

static float3 desaturate(float3 c, float amount) {
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return mix(c, float3(l), amount);
}

static float4 computeFill(constant Uniforms& U, texture2d<float> truth, texture2d<float> source, texture2d<float> blurred,
                          const device float4* edgeAvg, float2 px, float x, float r, float d, bool below, bool inside) {
    if (U.hasKnown == 0) return U.bg;
    float4 avg = edgeAvg[below ? 1 : 0];
    if (U.style == FLAT) return avg;

    float2 srcUV = float2(x / U.contentW, (r - U.regTop) / U.regH);
    // Optional slow "blobby" motion: a low-frequency domain warp anchored to content, zero at the known edge.
    if (U.warpAmp > 0.0) {
        float2 q = float2(x, r) / 180.0;
        float t = U.warpTime * U.warpSpeed;
        float2 n = float2(snoise(q + float2(0.0, t)), snoise(q + float2(31.7, -t * 0.83)));
        float k = smoothstep(0.0, 60.0, d);
        srcUV += n * U.warpAmp * k / float2(U.contentW, U.regH);
    }
    float4 bl = blurred.sample(lin, srcUV, level(0));
    // Inside the known band (rows crossfading in, or the inner feather): the smoothed fill there, which is
    // what was shown before the rows arrived easing towards a blur of them, so arrival reads as a focus pull.
    if (inside) return float4(bl.rgb, 1.0);
    float t = smoothstep(0.0, max(U.ext, 1.0), d);
    float4 c;
    if (U.style == PULLPUSH) {
        c = bl;
    } else {
        float2 m = mapFill(U, x, r);
        float4 sharp = sampleTruth(truth, U, m, 0.0);
        float wf = smoothstep(0.0, max(U.feather, 0.001), d);
        if (U.style == SMEAR) {
            float4 mid = source.sample(lin, srcUV, level(0));
            float s = saturate(d / max(U.ext, 1.0));
            c = mix(sharp, mid, smoothstep(0.0, 0.2, s));
            c = mix(c, bl, smoothstep(0.1, 0.7, s));
        } else {
            c = mix(sharp, bl, wf);
        }
        // Dissolve into the soft edge average beyond the extension length.
        c = mix(c, avg, smoothstep(U.ext * 0.6, U.ext * 1.6, d));
        if (U.style == FROSTED) {
            float3 tintC = mix(avg.rgb, float3(1.0), 0.6);
            c.rgb = mix(c.rgb, tintC, U.tint * wf);
            float l = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
            c.rgb = mix(float3(l), c.rgb, 1.0 + 0.3 * U.tint);   // vibrancy
            c.rgb += U.rim * 0.22 * exp(-d / 3.0);                  // glass rim at the boundary
        }
    }
    c.rgb = desaturate(c.rgb, U.desat * t);
    float hx = abs(px.x / U.drawW - 0.5) * 2.0;
    c.rgb *= 1.0 - 0.35 * U.vignette * t * (0.65 + 0.35 * hx * hx);
    c.rgb += (hash12(px) - 0.5) * U.grain * 0.12 * smoothstep(0.0, 24.0, d);
    return float4(saturate(c.rgb), 1.0);
}

fragment float4 compositeFS(VOut in [[stage_in]],
                            texture2d<float> truth [[texture(0)]],
                            texture2d<float> source [[texture(1)]],
                            texture2d<float> blurred [[texture(2)]],
                            constant Uniforms& U [[buffer(0)]],
                            const device float* arrival [[buffer(1)]],
                            const device float4* edgeAvg [[buffer(2)]]) {
    float2 px = in.pos.xy;
    float x = px.x * U.ptPerPx;
    float r = U.viewTopPt + px.y * U.ptPerPx;
    float4 outC;
    if (r < 0.0 || r >= U.contentH) {
        outC = U.bg;
    } else {
        float4 truthC = truth.sample(lin, float2(x / U.contentW, r / U.contentH));
        int row = clamp(int(floor(r)), 0, int(U.contentH) - 1);
        float a = saturate((U.now - arrival[row]) / max(U.crossfade, 1e-4));
        if (inSettled(U, r)) {
            // Distance inside the known band to a real boundary (document ends are not boundaries).
            float eTop = U.sTop <= 0.0 ? 1e9 : r - U.sTop;
            float eBot = U.sBottom >= U.contentH ? 1e9 : U.sBottom - r;
            float e = min(eTop, eBot);
            float w = a;                                   // crossfade of newly arrived rows
            if (U.style != FLAT && U.innerFeather > 0.0) w = min(w, smoothstep(0.0, U.innerFeather, e));
            if (w >= 1.0) {
                outC = truthC;
            } else {
                float4 f = computeFill(U, truth, source, blurred, edgeAvg, px, x, r, 0.0, eBot < eTop, true);
                outC = mix(f, truthC, w);
            }
        } else {
            bool below = U.hasKnown != 0 && r >= U.sBottom;
            float d = U.hasKnown != 0 ? (below ? r - U.sBottom : U.sTop - r) : 0.0;
            outC = computeFill(U, truth, source, blurred, edgeAvg, px, x, r, max(d, 0.0), below, false);
        }
        if (U.showBoundary != 0) {
            float lw = U.ptPerPx * 1.5;
            if (!inSettled(U, r)) {
                float stripe = fmod(floor((px.x + px.y) / 10.0), 2.0);
                outC.rgb = mix(outC.rgb, float3(0.9, 0.1, 0.6), 0.12 + 0.08 * stripe);
            } else if (a < 1.0) {
                outC.rgb = mix(outC.rgb, float3(1.0, 0.8, 0.1), 0.18);
            }
            if (U.hasKnown != 0 && (abs(r - U.sTop) < lw || abs(r - U.sBottom) < lw)) outC = float4(0.1, 0.85, 0.3, 1);
            else if ((abs(r - U.confTop) < lw || abs(r - U.confBottom) < lw) && fmod(floor(px.x / 12.0), 2.0) < 1.0) outC = float4(0.2, 0.5, 1.0, 1);
        }
    }
    return outC;
}
"""#
