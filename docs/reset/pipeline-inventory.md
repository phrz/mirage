# Mirage render and stream pipeline: inventory (main 6fb36c4, nightly 557)

Read-only. Written from the code on main and from the logs of the last two days.

## 0. First: a confound on mac-daddy right now

mac-daddy's `~/Library/Application Support/Mirage/tunables.json` is
`{"compositorModel": 1, "warmCapture": 1, "testTruthReference": 1, "testLockReference": 1}`.

- The two test knobs are mine, from the truth-metric runs. I never restored the backup (`tunables.json.before-test-knobs`), which I was asked to do.
- `testTruthReference` takes a full-display ScreenCaptureKit screenshot every second during every stream, and ScreenCaptureKit serialises shots with starts and filter updates.
- A `debug-shift` marker file in the same folder turns on per-frame shift-detector logging (the "shift v rect…" lines).
- Both have been loading every live session phrz ran today, and may contribute to the stalls.
- Recommendation: restore the backup and remove the marker before the next test. That's a change on mac-daddy, so it needs phrz's OK under the freeze.

## 1. Presentation modes and paths

| Path | Triggered by | What it's for |
|---|---|---|
| **Seam model** | `compositorModel` 0, the compiled default; `MIRAGE_COMPOSITOR` env | Display stream = the whole display minus windows that are layers. Up to 16 window layers (`maxWindowLayers`, env `MIRAGE_MAX_LAYERS`). Windows not (yet) layers stay in the display picture as **cut-outs**. Fresh picture: tiny keyframe, ladder climb, then lossless blocks. |
| **Compositor model** | `compositorModel` 1 (set in mac-daddy's tunables.json) | Three kinds of layer: a **desktop-only display layer** (wallpaper and icons, every window at level ≥ 0 excluded), an **overlay layer** (display capture of everything above the normal level on a clear background: menu bar, Dock, menus), and **every normal window its own layer**. The viewer composites and draws emulated shadows. |
| **Window layers** (both models) | A planned window (normal level, a real app, under the layer cap) | Per-window capture: an SCStream whose display filter leaves every other window out. Frames are diffed into tiles or video, and moves are layer moves (no pixels). |
| **Stage 1 / stills** (compositor) | Stream start, unlock, a viewer holding nothing | One coherent still per visible layer, presented together behind a barrier (700 ms deadline). Windows' stills come from window-alone snapshots, or from cuts of the warm snapshot (`cutStills`, `placeholders`). |
| **Whole-display fresh picture** (compositor) | `wholeFreshPicture` 1, default; on stream start, unlock, viewer empty | The display capture switches to the whole composited display, no windows listed. Layers assemble invisibly and take over in one step once all are ready (fitted snapshots or own frames, plus a 300 ms settle). No time cap since ba5f39f. |
| **Lock mode** | Session lock flags (CGSSession/IOConsole; shield-window heuristic only for refusing input) | Whole-display filter, window layers paused, one full lock still. After the still, changes go as video (`fresh` set done). The overlay is ignored. |
| **Fallback capture** (compositor) | A window's own capture failed or stopped | One full-display capture. The failed windows' layers are cut from it at their frames. Since 800c077 those windows stay in the desktop picture. |
| **Warm pool** | `warmCapture` 1, `warmMode` 0 | With no stream: a display snapshot every 30 s (plus window captures at 1 fps, depending on mode). At connect: a provisional desktop and stage-1 cuts from the snapshot, and an adopted warm desktop capture. |
| **TRUTH transactional** | `transactional` 1 | The viewer shows a capture's direct changes only at its `frameEnd`, all at once (bounded wait). |
| **TRUTH atomicCapture** | `atomicCapture` 1 | One window capture's change goes down one path (all lossless now, or all video). Since 4ff4d65 the whole display does the same. |
| **Curtain** | `curtain` 1, while a session is unlocked through Mirage | A lock-screen-like window on the host's screens, left out of every capture by **generation**. Frames from a filter older than the current generation are dropped; each capture re-applies its filter and acknowledges. Local input locks the Mac. |
| **Unified view** (viewer) | The viewer's Unified mode (`interest.unified`) | Windows only, no desktop; the whole-display picture is skipped. |
| **Per-capture classification** (every layer) | Always | Per-tile change history: direct tiles, video, small-animation tiles (< 2 % of a layer), fovea (motion near the pointer as native tiles), copy-rects (scroll and move detection), refinement to lossless when changes stop. |

## 2. Tunables that switch between them (compiled defaults)

- `compositorModel` 0 (mac-daddy: 1)
- `wholeFreshPicture` 1
- `placeholders` 1
- `cutStills` 0
- `windowShotIndependent` 1
- `warmCapture` 1; `warmMode` 0; `warmWindows` 12; `warmScale` 1; `warmIndependent` 0; `warmSnapshotSeconds` 30
- `transactional` 1
- `atomicCapture` 1
- `curtain` 1
- `injectedDrags` 1
- `connectProbe` 1
- `startKbps` 2000; `autoMaxKbps` 50000
- `smallAnimationFps` 3; `smallAnimationQuality` 50
- `stage1Seconds` 0.2
- `shadowProbe` 0
- `alphaMask` 0
- `testTruthReference` 0; `testLockReference` 0 (mac-daddy: both 1, see §0)

Env-only, so not reachable on the installed agent: `MIRAGE_MAX_LAYERS`, `MIRAGE_LAYER_APPS`, `MIRAGE_COMPOSITOR`, `MIRAGE_TEST_NO_COVER`, and other test knobs.

## 3. The simplest "whole display as video" path

- **No such mode exists today.** The closest in behaviour is **lock mode**: whole-display filter, one full still, then everything as video at the display rate (27 fps at 3200x1800 on mac-daddy). It only runs while the Mac is locked.
- **The closest unlocked combination** is the seam model with no window layers: `compositorModel` 0 and `MIRAGE_MAX_LAYERS`=0. The display stream is then the whole display. Even so, it isn't Workbench-like: each capture still goes through per-tile classification (direct tiles, fovea, small-animation, refinement, copy-rects), not "encode every frame as video, refine when idle".
- **Selectable by tunables alone? No.** `compositorModel` 0 still makes window layers (up to 16); the layer cap is env-only. Getting there needs a small code change, for example a `maxWindowLayers` tunable or a "whole display only" tunable that also routes the display layer as in lock mode.

## 4. Bugs phrz hit in the last two days, by path (from the logs)

- **Window layers (compositor):**
  - Static windows' captures deliver no frames after a restart ("0 passed, 0 unchanged").
  - macOS 27's unlock zoom resizes every window, replacing its capture.
  - Window-alone snapshots 1 px larger than their layers were dropped.
  - Serial stream starts at ~1.2 s each.
  - Together: the handover never came, "8 s … not ready", repeatedly.
  - Shadows too dark (viewer emulation).
  - "Second window clipped itself".
- **Whole-display fresh picture:**
  - The unlock's desktop-filter switch raced the whole-display one: "everything but desktop faded out" (537), and again late, mid-typing (539).
  - Never ending; motion went as tiles (fovea, per-tile history) at 1–5 fps: "drag froze into big chunks".
  - The lock frame lingered frozen.
  - My cut-based handover left holes (553).
  - 557: "nothing happens for 5 s, then blocks". Not analysed; the whole display staying whole until full-content snapshots arrive is a likely contributor.
- **Lock mode:**
  - Lossy lock screen: video far under budget, and refinement never runs on an animated wallpaper.
  - A black first still while the display woke.
  - Lock detection: a stale shield-window flag skipped Lock When Finished.
  - A SecurityAgent dialog left open made the unlock check refuse truthfully but confusingly.
- **Display filter updates and ScreenCaptureKit contention:** concurrent starts, filter updates and shots serialised inside ScreenCaptureKit. The curtain's re-apply timed out at 3 s ("not started after 3.0 s").
- **Curtain:** generation gating dropped first frames. With a static screen, a session then had no picture (a second viewer on 553).
- **Fallback capture:** holes where front windows covered a cut layer.
- **Rate controller** (all paths):
  - Careful-resume estimates ratcheted down session after session (72 Mbit/s → 8 Mbit/s).
  - Repaired raw loss read as stress switched off the LAN ceiling: "1 fps, pure patchiness" (544).
- **TRUTH transactional:** caret residue after a whole/desktop mode switch (539).
- **Warm pool:** nothing I can attribute in these two days.

## 5. My honest view: essential vs accretion

- **Essential:**
  - A correct full-screen picture that streams motion as video at the display rate, and goes lossless when still.
  - A rate controller that takes a LAN at LAN rate.
  - Lock handling with the strict unlock check, and the curtain, as a feature.
  - Window layers are essential only for what they uniquely give: local window moves and predictions, and Unified mode.
- **Accretion:** every fresh-picture mechanism built to hide window-layer start-up:
  - stage-1 barrier, placeholders, warm snapshot cuts, cut stills, the whole-display handover, snapshot stand-ins and fitting, cut checks, the fallback capture.
  - These exist because per-window ScreenCaptureKit captures are slow to start, serialised, frameless when static, and resized by system animations. Each patch fixed one case and opened another. Most of today's bugs live in the seams between them.
  - The per-tile classification layer (fovea, small-animation, direct-tile rate limits, copy-rect detection) adds a second set of interacting heuristics on top.
- **Suggested re-anchor:** make the whole display, as video plus idle refinement (the lock-mode path, unlocked), the baseline that always works. Layer windows on top only as an optimisation, after they've proved ready, and never as the source of truth for what's on screen. A tunable to run the baseline alone would give phrz a Workbench-like reference to compare against, and an anchor for the truth metric.
