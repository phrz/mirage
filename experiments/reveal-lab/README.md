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

`build/` is gitignored. Flags for scripted captures: run the binary
`"build/Reveal Lab.app/Contents/MacOS/RevealLab"` with any of `--tab finder|text|photos|web|terminal`, `--style 1…7`,
`--replay` (runs the scripted fling 1.2 s after launch), `--freeze-at <s>` (freezes simulated time that many seconds
into the fling), `--latency <ms>`, `--bandwidth <rows/s>`, `--boundary`, `--log-timings` (prints GPU timings to stdout)
and `--winid-file <path>` (writes `<CGWindowID> x,y,w,h` for `screencapture -l` / `-R`).

## What it simulates

- **Truth**: each tab is drawn once into a 900 × 6000 pt document at 2× (1800 × 12000 px, mipmapped).
- **Prediction**: a transparent `NSScrollView` over the `MTKView` takes the trackpad, so scrolling, momentum and
  rubber-banding are AppKit's own and move the view instantly.
- **Host**: sees the viewer's offset `latency` late, wants a band of the confirmed viewport ± *host margin*, and sends
  rows into it at *bandwidth* rows/s in frames every *host frame interval*, filling the confirmed viewport first and
  then the side the confirmed motion points to. Rows far from the band are forgotten. Everything outside the
  delivered band is unknown and gets the fill.
- **Arrival**: delivered rows crossfade from the fill to the truth over *crossfade*. The fill is temporally smoothed
  in content space (time constant crossfade / 3), so a fill replaced by newly arrived content eases over rather
  than popping; arrivals read as a focus pull.
- **Replay** (R): jump to top with the band delivered, hold 0.6 s, fling down at 3000 pt/s with UIScrollView's
  0.998/ms deceleration for 3 s, hold 1 s, fling up at 2400 pt/s. It runs in simulated time, so *Freeze* stops it
  mid-fling and recordings are comparable.
- **Boundary overlay**: green = edge of delivered content, yellow tint = rows still crossfading, blue dashes =
  host-confirmed viewport, pink = unknown.

## Fill styles

All except Flat build a base image over the viewport plus half a view of padding each side at 1/divisor
resolution (default ¼), sampling the truth's mip level that matches.

| # | Style | How |
|---|---|---|
| 1 | Flat | Average colour of the known edge row, as the viewer does today (`Compositor.sampleEdgeColor`). |
| 2 | Kawase (spec) | Clamp-extend the edge row, dual Kawase down/up (passes, offset), sharp-to-blur feather outside the edge, dissolve to the edge average beyond the extension length, vignette and desaturation growing with distance, optional grain. |
| 3 | Mirror | As 2, but the unknown side mirrors the known band (ping-pong). |
| 4 | Smear | Mirrored stretch of the last N known rows over the extension length, going sharp → ¼-res → Kawase blur → edge average with distance. |
| 5 | Frosted | 2 plus a light material tint, a vibrancy boost, a thin bright rim at the boundary and grain. |
| 6 | Aware | Repeats the nearest T known rows (a tile row) into the unknown, each repetition shifted sideways by a few pt, at ¼ res with a light blur. On a Finder grid it predicts more icon rows. |
| 7 | Pull-push (default) | Mask-aware pull-push pyramid, the Lumigraph hole-filling algorithm (our own implementation of the public algorithm, after the `inward_fill_down` / `inward_fill_up` kernels in macOS 27 Photos' Extend preview): pull averages premultiplied colour and coverage 2×2 down to 1×1; push goes back up with `own + (1 − coverage) × bilinear(coarser)` and renormalises. Known colours spread smoothly into the hole. A feather inside the known edge fades truth into the fill, and an optional simplex-noise domain warp (amplitude, speed) makes the fill drift slowly, zero at the edge. |

Every style has its own slider set (blur radius, passes, divisor, feathers, extension length, vignette,
desaturation, grain, tint, rim, rows, offset, blob motion, crossfade); only the ones a style uses are shown.

## GPU time

The fill pass (edge average, base image, blur or pyramid, temporal blend) is its own command buffer and is timed
with `GPUStartTime`/`GPUEndTime`; the composite (full-screen pass that also shades the fill) is timed separately.
Measured on an M4 Max (40-core GPU), 1878 × 1620 px view, base 469 × 810, Finder tab, ~1.5 s into the scripted fling,
averages over the last ~2 s of frames:

| Style | Fill pass | Dispatches | Composite |
|---|---|---|---|
| Flat | 0.026 ms | 1 | 0.18 ms |
| Kawase | 0.22 ms | 11 | 0.38 ms |
| Mirror | 0.21 ms | 11 | 0.37 ms |
| Smear | 0.20 ms | 11 | 0.37 ms |
| Frosted | 0.20 ms | 11 | 0.38 ms |
| Aware | 0.17 ms | 7 | 0.33 ms |
| Pull-push | 0.28 ms | 24 | 0.47 ms |

These are pessimistic: the load is light, so the GPU stays at low clocks (a plain full-screen composite taking 0.18 ms
says as much), and the fill time tracks the number of dependent dispatches (~5–12 µs each) more than pixels. The
panel's "iPhone 15 estimate" scales by GPU cores (40 / 5) and pixel count and is only meaningful for pixel-bound
work; whether pull-push fits 0.5 ms on an iPhone 15 needs measuring there. If dispatch count is the cost, the pull
levels can be merged into one or two dispatches with threadgroup memory (as single-pass downsamplers do) and the
pyramid stopped at ~4 px.
