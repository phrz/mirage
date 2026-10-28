# wholeDisplayOnly: the whole display as video

A host tunable, default 0, that changes nothing unless it's set. With `{"wholeDisplayOnly": 1}` in the host's `tunables.json` (read at each stream start):

- **One capture:** the display, every window included, the curtain left out (`displayFilter`), no cursor (`showsCursor` false; the viewer keeps its local cursor). No window layers (`plannedLayers` is empty), no overlay capture (the compositor model is off), no warm pool, no stage-1 stills or placeholders, no whole-display hand-over.
- **Every change as video:** each capture's changed tiles go into its HEVC frame, all of them (`wholeOnlyRoute`), at the display's rate. No copy-rects, fovea, small-animation tiles, direct tiles or rate-held tiles. TRUTH: a presented frame is one capture.
- **Sharpening when still:** once the screen has stood still for 300 ms:
  - on a LAN (tier Local), the last frame is encoded again with the QP ceiling at 20 (one high-quality frame, no tiles over the video);
  - on a slower link, the layer's existing lossless refinement does it.
  - The next change returns the encoder to the budget's ceiling.
- **Lock, unlock and connect** are the same path. The capture's filter never changes, and a fresh picture is a keyframe of the whole display.

## Harness

- `MIRAGE_TEST_DRAG`: viewer-side, works unchanged; it logs picture changes per second during a scripted drag.
- Truth reference (`testTruthReference`): host-side, started at every stream start, works unchanged.
- `selecttype` latency: keys are timed by the bench window's shown changes. With no window layers, the watched region is the window's rect on the display layer. Video frames there now count as shown (they had counted only for tiles).

## Workbench side-by-side recorder (outline only, not built)

Goal: the same host action seen through Mirage and through Astropad Workbench, recorded on phrz's MacBook, window-only, numbers first.

1. **Capture:** a small Mac tool using ScreenCaptureKit with a window filter, one per viewer: Mirage's viewer window and Workbench's. Window-only recordings of both viewers are allowed (memory: record-workbench-vs-mirage). 60 fps, native size, frames kept in memory, nothing written to disk except metrics unless asked.
2. **Sync:** a host-side marker is the clock both recordings share, for example a flash in a corner of the bench window at known host times (from the host log). Each recording's frame times are aligned to the marker.
3. **Metrics per viewer:** frame-to-frame change rate (fps as seen), stall gaps (p95, max), time to sharp after a change (edge-energy recovery against the last frame of a still period), and partial frames (cell differences against the host's truth reference, as the truth tool does).
4. **Cases:** steady drag, scroll, typing in a text field, connect, and unlock (once phrz allows it).
5. **Output:** one table per case, both viewers side by side, plus optional short MP4 clips of the same seconds for phrz to watch.
