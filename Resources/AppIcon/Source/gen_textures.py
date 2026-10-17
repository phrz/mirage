"""Procedural sand plane for the Mirage icon.
Output: export/textures/sand.png  (2048 x 2*(1024-HORIZON)) -> placed at y=HORIZON in a 1024 canvas at 0.5 scale.
Realism cues: perspective-scaled grain, quartz/dark speckle, wind ripples that compress toward the
horizon, atmospheric haze, and an inferior-mirage band (sky reflected on hot sand) with heat shimmer.
"""
import sys, os, numpy as np
from PIL import Image, ImageFilter, ImageDraw

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = [a for a in sys.argv[1:] if a.startswith("--")]
HORIZON = int(args[0]) if args else 620
FORM = "--form" in flags          # large-scale swells, vignette, mineral chips
WAVER = "--waver" in flags        # horizon hairline wavers with the heat
OUT_DIR = "export/textures/" + (flags[flags.index("--out") + 1] if "--out" in flags else "base") if False else None
tag = None
for i, a in enumerate(sys.argv[1:]):
    if a == "--out": tag = sys.argv[1:][i + 1]
OUT_DIR = "export/textures/" + (tag or "base")
S = 3                       # supersample vs 1024 canvas (3072 px wide)
W = 1024 * S
H = (1024 - HORIZON) * S
rng = np.random.default_rng(7)

def noise(h, w, cell, octaves=1, persistence=0.5):
    """Value noise via bicubic upsampling of random grids."""
    out = np.zeros((h, w), np.float32); amp = 1.0; total = 0.0
    for o in range(octaves):
        c = max(1, int(cell / (2 ** o)))
        gh, gw = max(2, h // c + 2), max(2, w // c + 2)
        g = rng.random((gh, gw)).astype(np.float32)
        im = Image.fromarray((g * 255).astype(np.uint8)).resize((gw * c, gh * c), Image.BICUBIC)
        a = np.asarray(im, np.float32)[:h, :w] / 255.0
        out += a * amp; total += amp; amp *= persistence
    return out / total

def anoise(h, w, cx, cy, octaves=1, persistence=0.5):
    """Anisotropic value noise: cell size cx along x, cy along y (stretched sheets when cx >> cy)."""
    out = np.zeros((h, w), np.float32); amp = 1.0; total = 0.0
    for o in range(octaves):
        ccx = max(1, int(cx / (2 ** o))); ccy = max(1, int(cy / (2 ** o)))
        gh, gw = max(2, h // ccy + 2), max(2, w // ccx + 2)
        g = rng.random((gh, gw)).astype(np.float32)
        im = Image.fromarray((g * 255).astype(np.uint8)).resize((gw * ccx, gh * ccy), Image.BICUBIC)
        a = np.asarray(im, np.float32)[:h, :w] / 255.0
        out += a * amp; total += amp; amp *= persistence
    return out / total

def lerp(a, b, t): return a + (b - a) * t
def smooth(t): t = np.clip(t, 0, 1); return t * t * (3 - 2 * t)

yy = np.linspace(0, 1, H, dtype=np.float32)[:, None]        # 0 at horizon, 1 at bottom
xx = np.linspace(0, 1, W, dtype=np.float32)[None, :]
Y = np.broadcast_to(yy, (H, W)); X = np.broadcast_to(xx, (H, W))

# ---- base colour: real sand, lit from upper-left, slightly cooler & paler toward the horizon
near  = np.array([0.91, 0.83, 0.64])   # foreground sand (dry, pale gold)
far   = np.array([0.96, 0.92, 0.80])   # hazy distant sand
base  = lerp(far, near, smooth(Y ** 0.6)[..., None])

# ---- large-scale tonal variation (gentle undulation / patches of darker, damp-looking sand)
big = noise(H, W, 210 * S, octaves=3) - 0.5
base = base * (1 + 0.10 * big[..., None] * Y[..., None] ** 0.5)
if FORM:
    # gentle swells under the ripples, lit on sun-facing (upper-left) slopes, shaded on the far slopes
    sw = anoise(H, W, 520 * S, 240 * S, octaves=2)
    slope = (np.roll(np.roll(sw, 3 * S, 0), 3 * S, 1) - np.roll(np.roll(sw, -3 * S, 0), -3 * S, 1))
    base = base * (1 + 7.0 * slope[..., None] * (0.25 + 0.75 * Y[..., None]))
    # soft vignette in the bottom corners for depth
    vx = np.abs(X - 0.5) * 2; vig = np.clip(vx ** 2.2 * Y ** 1.5, 0, 1)
    base = base * (1 - 0.16 * vig[..., None])

# ---- wind ripples: spacing compresses toward the horizon (perspective), wobbly, lit edges
# phase accumulates with 1/spacing(y); spacing grows with depth
spacing = lerp(3.5, 58.0, Y ** 1.4) * S                      # pixels between ripple crests
phase = np.cumsum(1.0 / spacing[:, 0]) * 2 * np.pi            # per-row phase
wob = (noise(H, W, 80 * S, octaves=2) - 0.5) * 2.2            # crest wobble
ripple = np.sin(phase[:, None] + wob * 2.0 + X * 9.0)
ripple_amt = lerp(0.015, 0.085, Y) * smooth((Y - 0.03) / 0.25)  # fade out near horizon
# sharpen crests: light on top edge, shade beneath
crest = np.clip(ripple, 0, 1) ** 1.6 - np.clip(-ripple, 0, 1) ** 1.2
base = base * (1 + (ripple_amt * crest)[..., None])

# ---- grain: multi-octave, amplitude grows with proximity, frequency scales with perspective
g1 = noise(H, W, round(1.5 * S), octaves=2) - 0.5
g2 = noise(H, W, round(3.5 * S), octaves=2) - 0.5
grain = g1 * lerp(0.025, 0.07, Y) + g2 * lerp(0.015, 0.05, Y)
base = base * (1 + grain[..., None])

# ---- speckle: individual grains (quartz bright, dark basalt, a few rusty), denser & bigger nearer.
# Rendered as a SEPARATE RGBA layer (grains + their cast shadows + contact edges) so a vector fine-grain
# pass in Sketch can sit between the sand plate and the big grains.
classes = [((1.0, 0.985, 0.93), 0.72, (0.55, 0.9)),     # quartz: colour, cumulative share, alpha range
           ((0.59, 0.47, 0.33), 0.93, (0.2, 0.4)),       # dark basalt
           ((0.78, 0.44, 0.26), 1.00, (0.3, 0.55))]      # iron-stained
if FORM:   # a specific mineral sand: a few percent garnet, olivine and magnetite chips
    classes = [((1.0, 0.985, 0.93), 0.66, (0.55, 0.9)),
               ((0.59, 0.47, 0.33), 0.86, (0.2, 0.4)),
               ((0.78, 0.44, 0.26), 0.92, (0.3, 0.55)),
               ((0.55, 0.12, 0.14), 0.955, (0.5, 0.8)),   # garnet
               ((0.36, 0.44, 0.20), 0.98, (0.45, 0.7)),   # olivine
               ((0.12, 0.10, 0.10), 1.00, (0.5, 0.8))]    # magnetite
n = 5000
ys = (rng.random(n) ** 0.5)
xs = rng.random(n)
ks = rng.random(n)
masks = [Image.new("L", (W, H), 0) for _ in classes]
draws = [ImageDraw.Draw(m) for m in masks]
for xr, yr, k in zip(xs, ys, ks):
    px, py = xr * W, yr * H
    r = lerp(0.45, 2.6, yr ** 1.3) * S * (0.5 + rng.random())
    ci = next(i for i, c in enumerate(classes) if k < c[1])
    lo, hi = classes[ci][2]
    draws[ci].ellipse([px - r, py - r * 0.75, px + r, py + r * 0.75], fill=int(255 * (lo + (hi - lo) * rng.random())))
spk_fade = smooth((Y - 0.02) / 0.3)
def shift(a, dy, dx):
    return np.roll(np.roll(a, int(round(dy)), axis=0), int(round(dx)), axis=1)
def blur_arr(a, rad):
    return np.asarray(Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(rad)), np.float32) / 255.0
cover = np.zeros((H, W), np.float32)
for m in masks:
    cover = np.maximum(cover, np.asarray(m, np.float32) / 255.0)
cover_soft = blur_arr(cover, 0.45 * S)

# grain layer accumulators (straight alpha compositing, bottom to top)
GL_rgb = np.zeros((H, W, 3), np.float32); GL_a = np.zeros((H, W), np.float32)
def over(rgb, a):
    global GL_rgb, GL_a
    a3 = a[..., None]
    GL_rgb = rgb * a3 + GL_rgb * (1 - a3)
    GL_a = a + GL_a * (1 - a)
# 1. each grain casts a small, soft, warm shadow down-right (sun upper-left)
shadow = blur_arr(shift(cover, 1.1 * S, 0.7 * S), 0.9 * S) * (1 - cover_soft) * spk_fade * lerp(0.14, 0.32, Y)
over(np.broadcast_to(np.array([0.33, 0.22, 0.10], np.float32), (H, W, 3)), shadow)
# 2. thin warm contact edge, darkest toward the grain's lower-right, faint on the lit side
dil = np.asarray(Image.fromarray((cover * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)), np.float32) / 255.0
ring = np.clip(dil - cover, 0, 1) * spk_fade
br = blur_arr(shift(cover, 1.4 * S, 1.4 * S), 0.6 * S)
ring = ring * (0.15 + 0.85 * np.clip(br * 1.6, 0, 1)) * 0.38
over(np.broadcast_to(np.array([0.45, 0.30, 0.14], np.float32), (H, W, 3)), ring)
# 3. the grains, shaded: lit crescent top-left, warm shaded crescent bottom-right (sand backscatter)
hi = np.clip(cover_soft - shift(cover_soft, 0.7 * S, 0.7 * S), 0, 1)
lo = np.clip(cover_soft - shift(cover_soft, -0.7 * S, -0.7 * S), 0, 1)
shade = (1 + 0.35 * hi[..., None]) * (1 - lo[..., None] * np.array([0.18, 0.30, 0.46]))
for (col, _, _), m in zip(classes, masks):
    a = np.asarray(m.filter(ImageFilter.GaussianBlur(0.4 * S)), np.float32) / 255.0 * spk_fade
    over(np.clip(np.broadcast_to(np.array(col, np.float32), (H, W, 3)) * shade, 0, 1), a)

# ---- atmospheric haze toward the horizon
haze_col = np.array([0.94, 0.95, 0.97])
haze = (1 - Y) ** 4 * 0.55
base = lerp(base, haze_col, haze[..., None])

# ---- inferior mirage: sky reflected on hot sand just below the horizon, as thin stratified sheets
sky_h = np.array([0.86, 0.93, 1.00])     # bright sky right at the horizon, as a sheet of light
band_px = 50 * S
ypix = np.arange(H, dtype=np.float32)[:, None]
fall = np.exp(-(ypix / band_px) ** 1.6)                              # smooth falloff with depth
# stratification: smooth variation along y with a slow drift along x (sheets of hot air)
strata = anoise(H, W, 420 * S, 2 * S, octaves=2)
strata = 0.6 + 0.4 * smooth((strata - 0.25) / 0.5)
# slow lateral breathing of the band's strength
breath = 0.75 + 0.25 * anoise(1, W, 120 * S, 1)[0][None, :]
m = np.clip(fall * strata * breath, 0, 1) * 0.97
base = lerp(base, sky_h, m[..., None])
# hairline darkening right at the horizon (the far edge of the ground)
if WAVER:
    wob = (anoise(1, W, 28 * S, 1, octaves=3)[0] - 0.5) * 2.4 * S     # per-column vertical offset of the edge
    edge_dark = 1 - 0.14 * np.exp(-((ypix - wob[None, :]) / (1.6 * S)) ** 2) * (ypix - wob[None, :] > -1.5 * S)
else:
    edge_dark = 1 - 0.14 * np.exp(-(ypix / (1.6 * S)) ** 2)
base = base * edge_dark[..., None]

# accumulators are premultiplied; un-premultiply to straight alpha for the PNG, then haze-veil the colour
GL_rgb = np.where(GL_a[..., None] > 1e-4, GL_rgb / np.maximum(GL_a, 1e-4)[..., None], 0)
GL_rgb = lerp(GL_rgb, haze_col, haze[..., None])
img = Image.fromarray((np.clip(base, 0, 1) * 255).astype(np.uint8), "RGB")
# faint horizontal motion blur inside the mirage band (heat shimmer)
band = img.crop((0, 0, W, int(band_px * 1.8)))
band = band.filter(ImageFilter.GaussianBlur(0.7 * S))
band_np = np.asarray(band, np.float32)
K = 5 * S
for _ in range(3):
    band_np = sum(np.roll(band_np, s, axis=1) for s in range(-K, K + 1)) / (2 * K + 1)
band = Image.fromarray(band_np.astype(np.uint8))
fade = Image.linear_gradient("L").resize((W, band.height)).transpose(Image.FLIP_TOP_BOTTOM)
img.paste(band, (0, 0), fade)

os.makedirs(OUT_DIR, exist_ok=True)
img.save(OUT_DIR + "/sand.png", optimize=True)                      # plate: sand without the big grains
grains = Image.fromarray((np.dstack([np.clip(GL_rgb, 0, 1), np.clip(GL_a, 0, 1)]) * 255).astype(np.uint8), "RGBA")
grains.save(OUT_DIR + "/sand-grains.png", optimize=True)            # big grains with shadows and edges
comp = img.convert("RGBA"); comp.alpha_composite(grains)
comp.convert("RGB").resize((1024, H // S), Image.LANCZOS).save(OUT_DIR + "/sand@1x.png", optimize=True)
print(OUT_DIR, img.size, "FORM" if FORM else "", "WAVER" if WAVER else "")

# ---- fine monochrome grain tile for the sky (kills gradient banding, adds film texture)
g = rng.normal(0.5, 0.08, (1024, 1024)).astype(np.float32)
Image.fromarray((np.clip(g, 0, 1) * 255).astype(np.uint8), "L").save("export/textures/sky-grain.png", optimize=True)
