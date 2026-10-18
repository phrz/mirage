# probes — small feasibility checks (2026-10-16, macOS 27, M4 Max)

Compile any of these with `swiftc -O file.swift` (use the Xcode toolchain via DEVELOPER_DIR).

## axmenu.swift — can we read an app's whole menu bar without opening menus?

Yes. Walking the full `AXMenuBar` tree of a running app through Accessibility, including
items of menus that have never been opened, titles, shortcut characters and enabled state:

| app | menu items | walk time |
|---|---|---|
| Finder | 314 | 66 ms |
| Mail | 500 | 357 ms |
| Sketch | 715 | 520 ms |

So the native remote menu bar (DESIGN §3.8) is feasible: walk once per focused app on the
host, send the tree, refresh a single menu lazily when it is opened (enabled state and
dynamic items change), fire `AXPress` on selection. Half a second for a huge app is fine as
a one-off per app and is cached afterwards.

## sck-dirtyrects.swift — are ScreenCaptureKit dirtyRects tight enough to skip a GPU diff?

Captures the display at 1x for 12 s and compares `SCStreamFrameInfo.dirtyRects` with a CPU
diff of consecutive frames, per 64 px tile.

- `dirtyRects` are in **output pixels** (the configured stream size), not display points.
  Multiplying by `scaleFactor` is wrong and makes small rects fall outside the frame.
- On a heavy-motion scene (a browser page scrolling text with animations, ~85k changed
  tiles over 350 frames): **0 frames where changed tiles were not covered**, over-reporting
  of 1.6x in tile count. Chromium repaints tend to collapse to one big rect
  (`0,33 1512x949`), which is the over-report.
- Sparse scene (quiet desktop, ~3 changed tiles per frame over 349 frames: clock, a text
  stream in one window): again **0 uncovered tiles**, over-report **1.7x** (1999 flagged vs
  1161 changed). So the ratio is the same in both regimes.
- Decision: dirtyRects are the first-pass mask; a GPU tile diff inside those rects would save
  roughly 40 % of lossless tile bytes on sparse updates. Worth doing in M2 after the tile
  path exists, not before.

## axtext.swift — can typed-text prediction get caret bounds and fonts through Accessibility?

Queries `AXBoundsForRange` and `AXAttributedStringForRange` on text elements without
focusing them.

| app | toolkit | bounds for range | font attributes |
|---|---|---|---|
| Mail, Finder, Sketch | AppKit | yes, exact glyph rects | yes (`AXFont` dict: name + size) |
| Helium (Chromium) | Blink | returns 0×0 | none |
| Claude (Electron) | Blink | no text elements exposed at all | – |

Setting `AXManualAccessibility` on the Electron app succeeds but still exposes no text
elements; `AXEnhancedUserInterface` is rejected by both. So the mosh-style typed-text
overlay (DESIGN §3.5 item 4) is **AppKit/SwiftUI-only** as far as Accessibility goes:
Xcode, Terminal, Mail, Notes, Sketch, Finder — not Chromium, not Electron, not WebKit
without more work. For browsers and Electron apps the fallback is the generic one: nothing
predicted, normal pixel path. That is well under the 60 % hoped for; realistic coverage is
"native apps and terminals". A browser-side route (an extension exposing caret rects) is
possible later but out of scope.

## menubar-windows.swift — where do status items live?

On macOS 27 the menu bar is **one window** (`Menubar`, owned by Window Server, layer 24,
full width). Status items are drawn inside it; they are not separate windows any more. So
the "status item strip" in DESIGN §3.8 is: capture the Menubar window via SCK
(`desktopIndependentWindow`), get item positions per app through `AXExtrasMenuBar`, crop
the third-party region, and map clicks back. Still cheap: one 1512×33 window.

## layers — per-window capture for the layered desktop (`miraged probe-layers`, 2026-10-18, macOS 27, M4 Max)

The probe lives in the host binary (same TCC grant): `miraged probe-layers --match "Mirage Test Bench"
--seconds 10 --scale 0.5 [--dump out.png] [--mode window|display|exclude]`, against windows of our own
(`MirageTestBench --still --index N`).

- **Window streams render every interval.** Eight still windows at `minimumFrameInterval` 1/30: 311–334
  frames each in 10 s, the dirty rect always the whole window, two IOSurfaces alternating; `memcmp` says the
  pixels are identical. At 1/5 the stream delivers 5 fps. So the frame interval is the cost knob and our own
  diff the change detector; SCK gives no "unchanged" signal for windows the way it does for displays.
- **Cost.** Our process: 1.5 % of a core per 400×266 stream, 8 % for eight. WindowServer went from
  ~28 % to ~50 % with the streams, but a single window stream, a whole-display stream and a display stream
  excluding the window all read 45–60 % on a screen that was in use; the difference between them was
  inside the noise. Start-up 100–170 ms per stream, first frame 20 ms later.
- **Alpha.** Corners are transparent (`bgra(0,0,0,0)`), content opaque; `shouldBeOpaque = false` keeps it.
  `SCStreamUpdateFrameCornerRadius` is attached to every frame.
- **Children.** The traffic lights are a 66×20 level-0 window of the same process at (x+6, y+6) of every
  titled window; `includeChildWindows = true` draws them into the parent's capture.
- **Shadows.** `ignoreShadowsSingleWindow` removes them from a window capture; excluding a window from a
  display capture leaves its shadow behind unless `ignoreShadowsDisplay` is set too.

## codec on the desktop picture (`miraged probe-layers --mode codec`, 2026-10-18)

The desktop without any windows (the display layer of the layered desktop) at 2600×1688, 40 blocks of
320×320, 39 of them photographic (> 4096 colours) on this wallpaper: lossless 1007 KB/Mpx, near-lossless
(WebP `near_lossless` 60) 677, lossy WebP q92 180, q85 118, q75 73. A whole 2x desktop is ≈3 MB
near-lossless and ≈0.6 MB at q90, which is why photographic tiles end at q90 on constrained links.

## framesheet (presentation steps, 2026-10-18)

`swift experiments/probes/framesheet.swift <dir> [--from ms] [--to ms] [--verbose layer]` reads a viewer
`MIRAGE_TEST_FRAMES` directory (the composited scene at a quarter of display size, 5 fps, with each frame's
layer rects). Per layer it prints the runs of frames in which any 16-px block (64 native px) changed, counting
only blocks that belong to exactly one layer, and writes `sheet.png`, a contact sheet of the frames. A level
presented whole is a run of 1–2 frames (the 220 ms crossfade). Blocks landing one by one show up as long runs
or as many small ones. Motion, like a window dragging itself, also shows up as long runs.

## badge (`miraged probe-layers --mode badge`, 2026-10-19)

Per filter variant (desktopIndependentWindow; display excluding every other window; display excluding all
applications except the window), one stream over the first matching bench window (`MIRAGE_PROBE_WINDOW=<id>`
picks one) with `sourceRect` on its frame plus 16 pt. It writes a `screencapture -l` of the window per variant
(the badge shows there) and the captured frame to `--dump`. It also reports frames while static, the alpha
of the margin and the edges, and CPU. Results:

| Variant | Badge | Margin |
|---|---|---|
| desktopIndependentWindow | yes | white |
| excluding every other window | no | transparent |
| excluding applications | no | opaque black |

A covered window renders whole. The outermost pixel of a window is about 89 % alpha at 1x.
