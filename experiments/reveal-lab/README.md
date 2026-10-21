# Reveal Lab: what to show where a predicted scroll runs ahead of the host

A throwaway macOS app (SwiftUI + Metal) to try fills for the area a viewer reveals before the host has delivered it.
DESIGN.md §3.0 TRUTH proposes "phrz's dreamy fill": edge-extend, dual Kawase blur at quarter resolution, a vignette,
then a crossfade to the truth. This lab puts that next to six alternatives on mock content, with a simulated host.

## Build and open

```sh
cd experiments/reveal-lab
./build.sh                       # DEVELOPER_DIR defaults to /Applications/Xcode-27.1.0-Beta.app/Contents/Developer
open "build/Reveal Lab.app"
```

`build/` is gitignored. For scripted runs, start the binary `"build/Reveal Lab.app/Contents/MacOS/RevealLab"` with:
`--tab finder|text|photos|web|terminal`, `--style 1…7`, `--replay` (scripted fling 1.2 s after launch),
`--fling-scale <k>` (fling speed ×k; 3 = a 9000 pt/s fling), `--freeze-at <s>` (freeze simulated time that long into
the fling), `--latency <ms>`, `--bandwidth <rows/s>`, `--boundary`, `--log-timings` (GPU and smoothness to stdout),
`--frame-log <csv>` (per frame: interval, scroll offset, boundary position and velocity, per-edge |Δv|, snaps),
`--record <mov> --record-seconds <s>` (every presented frame of the Metal view, at its display-link timestamp: a true
120 fps file on ProMotion) and `--winid-file <path>` (writes `<CGWindowID> x,y,w,h` for `screencapture -l` / `-R`).

## What it simulates

- **Truth**: each tab is drawn once into a 900 × 6000 pt document at 2× (1800 × 12000 px, mipmapped).
- **Prediction**: a transparent `NSScrollView` over the `MTKView` takes the trackpad, so scrolling, momentum and
  rubber-banding are AppKit's own and move the view instantly. Frames are driven by a `CADisplayLink` (120 Hz on
  ProMotion) and simulated time is the link's target presentation time, so motion is sampled at an even cadence.
- **Host**: sees the viewer's offset `latency` late, wants the confirmed viewport ± *host margin*, and sends whole
  *chunks* (32 pt, a 64 px tile row) at *bandwidth* rows/s, once per *host frame interval*: the confirmed viewport
  first, then growing contiguously from what is already known, else from the side the content came from. Chunks
  1.5 views beyond the band are forgotten. Known content can be several intervals.
- **Boundary**: what is shown as known follows what is delivered through a cascade of two critically damped springs
  per edge (4th order; *reveal time* sets it). The delivered edge is a staircase (chunks, once per host frame); the
  cascade makes the shown boundary move with continuous velocity and acceleration, sub-pixel, only ever outward (a
  monotone target driven from rest gives a monotone response that never passes it). A fresh interval opens from
  the side the motion comes from; intervals that sweep into each other overlap and merge only once the overlap is
  two feathers wide, so merging changes no pixel.
- **Fill**: computed in content space over the whole document at 1/divisor of the truth's pixels (450 × 3000 at
  ¼), only when delivered content or a fill parameter changes, from the delivered content (so the fog beyond the
  boundary already holds a blur of rows about to be revealed). A cache eases toward each recomputed fill with an EMA
  (*fill smoothing*, 150 ms), every frame, over the rows around the view. The composite samples the cache with a
  cubic B-spline at each pixel's content position, so the fog moves rigidly with the content, has no texel grid
  and never snaps.
- **Composite**: one continuous ramp. With signed distance `sd` to the shown boundary (negative inside),
  `out = mix(fill, truth, smoothstep(0, feather, −sd))`: the fill exists under the feather band too (it is blurred
  known content there), and the style's effects (vignette, desaturation, tint, grain) ramp from the feather's inner
  edge outward, so there is no strip clear of effects.
- **Replay** (R): jump to top with the band delivered, hold 0.6 s, fling down at 3000 pt/s × scale with
  UIScrollView's 0.998/ms deceleration for 3 s, hold 1 s, fling up at 2400 pt/s × scale. Simulated time, so *Freeze*
  stops it mid-fling and runs are comparable.
- **Boundary overlay**: green = shown boundary (spring), yellow = edge of delivered content, blue dashes =
  host-confirmed viewport, pink = unknown.

## Fill styles

| # | Style | Fill (content space, before the ramp) |
|---|---|---|
| 1 | Flat | The nearest boundary row's average colour, as the viewer does today (`Compositor.sampleEdgeColor`); feather 0 by default (today's hard edge). |
| 2 | Kawase (spec) | Clamp-extend the edge row, dual Kawase down/up (passes, offset), dissolve to the edge row's average beyond the extension length; vignette and desaturation with distance; optional grain. |
| 3 | Mirror | As 2, but the unknown side mirrors the known band (ping-pong). |
| 4 | Smear | Mirrored stretch of the last N known rows over the extension length, from the stretched rows to their blur with distance. |
| 5 | Frosted | 2 plus a light material tint, a vibrancy boost, a soft bright rim on the boundary and grain. |
| 6 | Aware | Repeats the nearest T known rows (a tile row) into the unknown, each repetition shifted sideways a few pt, blurred lightly. On a Finder grid it predicts more icon rows. |
| 7 | Pull-push (default) | Mask-aware pull-push pyramid, the Lumigraph hole-filling algorithm (our own implementation of the public algorithm, after the `inward_fill_down` / `inward_fill_up` kernels in macOS 27 Photos' Extend preview): pull averages premultiplied colour and coverage 2×2 down to 1×1; push goes back up with `own + (1 − coverage) × bilinear(coarser)` and renormalises; then two Kawase passes soften it so known content under the feather is as soft as the fill beyond. Optional slow simplex-noise domain warp ("blobby" motion; amplitude, speed), zero at the boundary. |

Every style has its own sliders; only the ones a style uses are shown. Reveal time, feather and fill smoothing
apply to all styles.

## Measurements (M4 Max, 40-core GPU, ProMotion; Finder tab; fast fling, `--fling-scale 3`)

GPU time per command buffer (`GPUStartTime`/`GPUEndTime`), view 1878 × 1620 px, fill 450 × 3000 (whole document):

| Style | Fill recompute | Recomputes/s | Dispatches | Fill EMA / frame | Composite / frame |
|---|---|---|---|---|---|
| Flat | 0.15 ms | ~11 | 2 | 0.08 ms | 0.29 ms |
| Kawase | 0.49 ms | ~11 | 10 | 0.08 ms | 0.33 ms |
| Mirror | 0.51 ms | ~11 | 10 | 0.08 ms | 0.34 ms |
| Smear | 0.48 ms | ~11 | 10 | 0.09 ms | 0.34 ms |
| Frosted | 0.48 ms | ~11 | 10 | 0.10 ms | 0.36 ms |
| Aware | 0.40 ms | ~11 | 6 | 0.08 ms | 0.35 ms |
| Pull-push | 0.75 ms | ~11 | 31 | 0.05 ms | 0.40 ms |

Amortised over 120 Hz, pull-push's fill costs about 0.75 × 11 / 120 + 0.05 ≈ 0.12 ms per frame here. These are
pessimistic (light loads run at low GPU clocks; a plain full-screen composite at ~0.3 ms says as much), and the
recompute covers the whole 6000 pt document; a product version would recompute a window around the view, aligned to
the pyramid's coarsest block in content space so it stays stable. iPhone 15 numbers need measuring there.

Smoothness, from `--frame-log` (pull-push, fast fling, ~440 frames, no recorder running): frame interval 8.33 ms
average, 8.36 ms max, no frame over 12.5 ms; no boundary direction reversals; no edge snaps inside the view (all
styles); boundary up to ~4400 pt/s, per-edge velocity change ≤ ~280 pt/s per frame (continuous acceleration), and
position follows velocity to within 0.27 pt per frame. Other styles: 0–4 frames over 12.5 ms in ~430.

Flicker, from a 120 fps in-app recording (947 frames, 0 dropped) shifted by the logged scroll offset so rigidly
moving content cancels (mean absolute change per frame, grey levels of 255): fast phase with the view entirely
unknown 0.08 (max 0.6); boundary sweeping through the view 1.2 (max 1.9, including the reveal itself); still view
(control) 0.001.
