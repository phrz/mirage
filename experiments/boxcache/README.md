# boxcache — alignment-free reuse: content boxes vs grid tiles

Question (phrz, 2026-10-17): should reuse across frames be grid-aligned at all, or should we
slice by where content is? Renders real AppKit text (NSTextView, system font 13 pt, 2x) at
successive scroll offsets (37 pt per frame, deliberately not a line multiple) and one keystroke
per frame, then measures per frame how much of the change is explained by (1) a copy-rect,
(2) exact matches of **content boxes** (runs found by splitting the residual on background
rows/columns: text lines, words, UI elements) against everything seen before, (3) tolerant
near-matches (≥97 % identical pixels, no channel off by >64), and (4) as control, exact hashes
of 64 px grid tiles over the same residual. `swift build -c release && .build/release/boxcache`
(`SKIP_WEBKIT=1` skips the WebKit sequence, which does not render in a hidden window yet).

| sequence | changed px/frame | copy-rect explains | residual boxes/frame | exact box hits | tolerant | grid-tile hits (control, same regions) | residual to encode |
|---|---|---|---|---|---|---|---|
| AppKit scroll 37 pt | 675 k | **95 %** | 36 | **50 %** of residual | +0 % | 27 % | ≈2.8 KB WebP + 15 refs |
| AppKit typing | 15 k | 35 % (line reflow) | 19 | **69 %** | +0 % | 20 % | ≈1.1 KB WebP + 15 refs |
| WebKit scroll 37 px | 667 k | **95 %** | 33 | 46 % | +0 % | **52 %** | ≈3.1 KB WebP + 12 refs |
| Chromium (Helium) scroll 37 px, SCK capture | 302 k | **96 %** | 15 | 18 % | +0 % | 38 % | ≈2.7 KB WebP + 2 refs |

The residual is the set of changed pixels the best vertical copy-rect does not explain,
clustered into regions (8 px cells, 8-connected); boxes and the grid control are both
evaluated inside those regions only. An earlier version of this table used one bounding box
for the residual, which flattered boxes; these are the corrected numbers.

## Conclusions

1. **Copy-rect is the mechanism that matters for scroll**: 95–96 % of changed pixels in all
   three engines, including Chromium, whose scroll steps landed on exact 74-device-pixel
   shifts. The remaining 4–5 % is mostly newly exposed content, which no cache can supply.
2. **Alignment-free (content-box) reuse wins where text is re-laid-out around a change**:
   typing in AppKit (69 % vs 20 % for grid tiles) and AppKit scroll (50 % vs 27 %). In WebKit
   the grid control was better (52 % vs 46 %) and in Chromium both were low (18 % vs 38 %):
   box bounds there shift by a pixel between frames, so exact-size box matching misses while
   fixed-size grid tiles in the line interiors still match. Neither unit dominates; M3's cache
   should key on both (grid hash for same-position recurrence, box hash for alignment-free),
   on top of copy-rect, and the hit rate must be measured on real multi-hour sessions.
3. **The tolerant tier never fired** with a same-size candidate rule, in any engine. Where
   subpixel re-rasterization shows up it comes with a one-pixel change in box extent, so a
   useful tolerant matcher must be size-tolerant (match the overlap of boxes whose bounds
   differ by ≤2 px). Still worth having, as a principle: exactness is a refinement, not a
   gate, and it costs nothing when it does not trigger.
4. **Bytes**: after copy-rect and cache, 1–3 KB of genuinely new pixels per scroll step or
   keystroke-with-reflow, plus a dozen 12-byte references. That is the budget the Extreme
   tier can live in.
5. Boxes per frame are in the tens, so a content-box index is cheap on the host.
