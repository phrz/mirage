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
- A sparse-scene measurement (typing only) is still to be done; expect the ratio to be
  worse there because a one-glyph change often comes back as a whole-line or whole-window
  rect. Decision: use dirtyRects as the first-pass mask and add a GPU tile diff
  (Astropad's wgpu pass) inside those rects only if the sparse-scene number justifies it.
