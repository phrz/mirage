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
