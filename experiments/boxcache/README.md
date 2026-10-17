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

| sequence | changed px/frame | copy-rect explains | residual boxes/frame | exact box hits | tolerant | true misses | grid-tile hits (control) | bytes/frame |
|---|---|---|---|---|---|---|---|---|
| AppKit scroll 37 pt | 675 k (18 % of frame) | **95 %** | 37 | **57 %** of residual | +0 % | 43 % (newly exposed lines) | 11 % | ≈2.2 KB WebP + 17 refs |
| AppKit typing | 15 k | 35 % (line reflow) | 21 | **82 %** of residual | +0 % | 18 % (the new glyphs) | 10 % | ≈0.7 KB WebP + 19 refs |

## Conclusions

1. **Reuse must be alignment-free.** Content-box matching recovers 5–8x more of the residual
   than grid-tile hashing (57 % vs 11 %, 82 % vs 10 %). The grid stays for dirty tracking
   and scheduling only; the cache keys on content boxes.
2. **Copy-rect does the heavy lifting on scroll** (95 % of changed pixels); boxes clean up
   what the shift cannot explain (line reflow, partially exposed lines) and are the main
   mechanism for typing, where a keystroke re-renders a whole line but every glyph except
   the new one already exists in the cache.
3. **What remains is genuinely new content**: on AppKit the tolerant tier adds nothing because
   AppKit re-rasterizes identically at integer offsets, so misses are new lines and new
   glyphs. Tolerance is still right as a principle (exactness is a refinement, never a gate):
   it costs nothing when it does not trigger and is expected to matter for subpixel-positioned
   text (Chromium/Electron at odd Retina offsets), which still needs measuring with a visible
   WebKit/Chromium window.
4. **Cost model**: ~17–21 references per frame at ~12 B each is noise; the true-miss area
   encodes to 0.7–2.2 KB. Typing in a text view thus costs well under 1 KB per keystroke
   before any entropy-coding cleverness, which is the number the Extreme tier needs.
5. Index overhead and eviction need the hit-rate measured on long real sessions (hours, many
   apps) before M3 fixes the cache size; boxes per frame are in the tens, not thousands, so a
   content-box index is cheap.
