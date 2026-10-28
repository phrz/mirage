# Mirage: the brief against what was built

Independent read-only assessment of main at 6fb36c4 (2026-10-28). Sources: `docs/DESIGN.md` as first committed
(a3e05db, 2026-10-16, 279 lines) and at HEAD (3,049 lines), the 558-commit log, and the code.

## 1. What the original brief promised (2026-10-16)

The brief was written for one specific link: MacBook in Japan to mac-daddy in Dallas, "~220 ms RTT, worst case
~1 Mbps". Everything follows from that link.

- **The feeling.** ARD feels broken because of physics: at 1 Mbps a 20 KB frame takes 160 ms just to send. So "the
  *feeling* of latency must be hidden locally: cursor, window management, scroll and text echo ... This is not a
  nice-to-have; it is the product." Later (M-FIVE, 10-21) phrz put the same goal another way: "an Apple-esque, very
  clean remote desktop".
- **The bar.** M1 was done when "side-by-side on this Japan link it beats ARD and feels at least as good as
  Workbench". M3 was done at "drag a remote window at 220 ms RTT without noticing".
- **The architecture.** One Swift package, no FFI. QUIC over the tailnet, with separate streams for control, input,
  tiles and feedback, plus datagrams for video. Pairing with a PAKE (a password-based key exchange; CPace on X25519)
  and Ed25519 keys, no accounts. A **per-tile hybrid codec**: send nothing for static tiles, small lossless WebP
  patches for sparse changes, low-latency hardware HEVC only for the region that is moving, and lossless refinement
  once motion stops. Local cursor. Delay-based rate control.
- **Layers were in the brief from day one,** but as a mode. "Desktop" mode was one display capture ("classic
  full-screen view"). "App layers / Unified" was the optional Coherence-style mode. The same evening (4668487) the
  per-app streams were replaced by **"one desktop stream plus a visibility mask"**: one capture per display, with
  windows cut out of it. Extra per-window streams would exist only for a window that is covered on the host, "zero or
  one extra stream, never one per window."

So the brief was never "whole-display video like Screen Sharing". It was a hybrid tile codec plus local prediction,
built on **one capture per display**. Mirage does not "bear no resemblance" to that brief. It kept the brief's parts and
then broke the brief's central simplification.

## 2. How the render/stream pipeline evolved

| Date | Commit | Turn | Reason given |
|---|---|---|---|
| 10-16 | 922a6ac | M1: whole display → HEVC low-latency → datagrams → Metal, local cursor | The brief. Measured 30 fps and 126 ms frame age at 800 kbps over 200 ms; phrz: "a hint better" than ARD |
| 10-16 | 4668487 | One display stream plus a visibility mask | Cost of N captures |
| 10-17 | 126d877, 1a81817, 89e2ff7 | M2 hybrid codec, copy-rect, tiny-rung "lossy first", progressive whole-picture refinement, fovea | 1 Mbps budget. Bus session: no "march of tiny tiles" |
| 10-17 | 6db1fe4 | M2.5: resume, parity/NACK, input on datagrams | Adversarial review: one lost packet cost a 93 KB keyframe |
| 10-18 | d45bd05, 83b2152 | **M3.1 layered desktop in every mode**: each window its own capture, the display captured minus those windows, client composites | "Desktop-mode dragging can never be local with a single composited capture" |
| 10-18–20 | 680e63e, 7548f94, ce38da3, c9f678d | Seam machinery: display guard, taint, underlay, exclusion verification, picture audit, §3.3d invariants | Window pixels baked into the desktop, holes, stripes on Finder scrolls |
| 10-19 | 5dbdf60 | Window layers via "display excluding every other window" | **macOS**: a capture naming a window paints the purple screen-sharing badge on it |
| 10-21 | 0d0651f | "The host is the product", host-sent tunables | Viewer updates are slow to ship |
| 10-21 | 29ddc01 | **Compositor model** (desktop-only layer + overlay layer + every window a layer), behind a flag | Show Desktop "broke [the seam] repeatedly" |
| 10-21 | bdc5271 | **M-FIVE**: probe, placeholders, coherent-stills barrier, crossfades | Café connect: "a lossy page for far too long ... windows snapped in over fifteen seconds" |
| 10-21 | 58efc0c, 8df7678 | Warm host: idle captures, then a 30 s snapshot | **macOS**: window streams start one after another, ~0.75 s each. Warm captures cost WindowServer ~34 CPU points |
| 10-21 | 0dd810d | Rate control on delivery rate | A still screen's target climbed to the 50 Mbps cap on 4G |
| 10-22–24 | f0d3bda, 1d978c0, fea8904 | Overlay never as video; black-pixel clearing; menu bar and Dock "bands" pasted from the unfiltered display | HEVC carries no alpha (a black edge column); menu titles missing from the overlay |
| 10-23 | ab11d03 | Final quality by measured bandwidth, not by round-trip-time tier | 200 ms RTT at 7 Mbps was treated as a slow link |
| 10-21/25 | 70c8ebb, b9efc7f, d5eeadb | **TRUTH**: `frameEnd` transactions plus `atomicCapture`, on by default | Partial frames: ghost carets, selections painted in one tile. Split captures fell from 30 % to 0.6 % |
| 10-25 | fa4a948, 79b1eeb | LAN recognised at once; send gate; WebP preset 0 | phrz on a 5 ms LAN: "worse than prior art"; per memory, slow to lossless, with low-fps pulsing text |
| 10-26–27 | e88e2f1, 74397c6 | Curtain; unlock with Face ID / Touch ID | Product features |
| 10-27 | 453011b, a33eddd, f9455ce | **Locked host = whole display, as video** | A mosaic of the lock screen; typing waited behind tiles |
| 10-27 | 1fc3b90 | **Whole-display fresh pictures**: connect and unlock use the lock path, then hand over to the layers | After an unlock on 522: "windows still fade in one by one ... patchy all over" |
| 10-28 | ba5f39f…800c077 (9 commits) | Hand-over fixes: filter races, fitted snapshots, motion as video in whole mode, a frame for a still screen, fallback holes | "1 fps and pure patchiness" (544); "a big old hole in the window underneath" (553); a second viewer with 0 of 198 frames whole |

The pattern since 10-21: each nightly fixes the symptom phrz reported, at a seam that exists only because one picture
is assembled from several captures that macOS does not keep in step.

## 3. Brief against today

**Where today still matches the brief:** QUIC transport, datagram video with LTR recovery, PAKE pairing, the local
cursor, WebP lossless tiles, copy-rect scrolling, the delay/delivery rate controller, Unified mode as native windows,
and host-side input injection. These are solid and well measured.

**Where it diverged, and why:**

1. **Desktop mode is no longer one capture (chosen, 10-18).** This is the root divergence. The brief and its same-day
   revision kept one display stream. M3.1 made every window its own capture so a window drag could be drawn locally.
   That buys something only at high round-trip times. Since 10-25 phrz works on a 5 ms LAN, where a drag sent to the
   host comes back within 1 to 2 frames. Every later layer of machinery repairs this one choice: guards, taint,
   underlay, the compositor model, the overlay and bands, the fallback, warm captures, placeholders, stage-1 cuts and
   the hand-over.
2. **macOS made per-window capture expensive and inconsistent (forced, but only for that path).** Window streams start
   one at a time (~0.75 s each, up to 4 s on a busy host). A still window's stream still sends 33 frames a second, each
   marked fully dirty. Naming a window paints the screen-sharing badge on it. Show Desktop delivers blank captures, and
   filter switches race. A still display sends no frames at all, so a dropped first frame means no picture (eef5ab0).
   HEVC has no alpha for the overlay. All of this is real ScreenCaptureKit behaviour, and nearly all of it hurts the
   multi-capture path, not the single display capture.
3. **The operating point moved (circumstance).** Measures built for 1 Mbps (tiny ladder rungs, staged lossless
   levels, fovea tiles, refinement budgets) slowed the LAN case down. Only on 10-25 did a LAN start "at the cap". On
   that link the products phrz compares against (Workbench, Screen Sharing) simply send high-bitrate video.
4. **Correctness became an add-on (consequence).** The brief had no rule that the viewer shows only whole host
   frames. TRUTH, M-FIVE's barrier, `atomicCapture` and the whole-display hand-over were all added afterwards to
   restore what a single capture gives for free.
5. **The brief's bar is unmet on the current link.** "At least as good as Workbench" is the M1 test. phrz's own
   verdict on the LAN (10-25) was "worse than prior art".

Fairly put, the most reliable picture in the codebase today is the whole display sent as video. Evidence: the locked
host ran at 26–28 fps with 0 partial frames out of 101 (8a914cc), and the viewer matched the host's own frames in every
cell while typing at the lock screen (§3.0a). The last three days rebuilt M1 as the safe base, and most of the open
bugs now sit in the hand-over from that base to the layers.

## 4. Complexity, counted

- **Code size.** Swift in `Sources/` is now 36,693 lines, against 3,323 at M1; tests add 10,809 lines (587 test
  functions). `docs/DESIGN.md` grew from 279 lines to 3,049.
- **`Sources/MirageHost/DesktopStreamer.swift`.** 5,421 lines (412 KB): 193 functions, about 213 stored properties, and
  one `captured()` function of about 540 lines. It was 250 lines at M1, then 1,691 (10-17), 3,614 (10-21) and 5,219
  (10-27). 234 commits have touched it, 110 of them since 10-21.
- **Other host streaming files.** ScreenCapturer 547, WindowCapturer 384, WarmPool 278, LayerProbe 273, WindowTracker
  272, Layer 224, HEVCEncoder 153, DesktopUnderlay 54, SendGate 41. Host streaming totals about 7,650 lines.
- **Shared and viewer streaming code.** In MirageCore: Tiles 1,423, Render 1,997 (Compositor 1,283), Rate 1,045, plus
  the tile and video wire formats (812). On the viewer, ViewerSession is 2,086. The render and stream pipeline as a
  whole is about 15,000 lines.
- **Tunables** (`Tunables.swift`). 42 keys:
  - 17 viewer numbers (gestures, zoom, scroll lead, fades);
  - 2 test switches;
  - 23 host keys, of which 14 are on/off switches of pipeline behaviour (`compositorModel`, `placeholders`,
    `injectedDrags`, `connectProbe`, `warmCapture`, `warmIndependent`, `windowShotIndependent`, `shadowProbe`,
    `cutStills`, `alphaMask`, `transactional`, `atomicCapture`, `curtain`, `wholeFreshPicture`) plus a three-way
    `warmMode`.

  There are also 67 `MIRAGE_*` environment variables, 46 of them `MIRAGE_TEST_*`. Note that `compositorModel` is still
  compiled to 0 (the seam design), and DESIGN says "default off until the A/B". No A/B result is recorded, and both
  models are maintained in the code (22 `compositor` branches in DesktopStreamer). Which model mac-daddy runs depends on
  its `tunables.json`, which I did not check.
- **Presentation paths.**
  - *Host capture sources (10):* display minus layers (seam), desktop only (compositor), overlay plus pasted bands,
    per-window captures, fallback full display, whole display (lock and fresh pictures), the underlay's second capture,
    the warm snapshot, window-alone hand-over snapshots, and placeholders.
  - *Encoding routes for a changed pixel (about 12):* masked HEVC on up to four canvases per layer, lossless direct
    tiles, the lossy exposed strip, small-animation tiles, copy-rect, fovea tiles, refinement blocks, the intermediate
    level, stills, ladder rungs, alpha-mask video, and backdrop levels.
  - *Viewer presentation mechanisms (5):* direct writes, staged levels with crossfade, the stage-1 commit set, TRUTH
    frame transactions, and prediction transforms.
  - *Fresh-picture flows:* seven triggers × two models × whole-or-layered × three warm modes.

  Nobody can hold this whole state space in their head, and no test covers it.

## 5. Recommended reset

**The base, which is always correct:** one ScreenCaptureKit capture of the whole display (cursor hidden, curtain left
out), fed to one low-latency hardware HEVC session, sent as datagrams with today's parity, NACK and LTR recovery,
decoded by VideoToolbox and drawn with Metal. This is Apple Screen Sharing, Parsec and Workbench, and it is Mirage's own
M1 plus today's lock path.

- **One capture, one frame, one presentation.** TRUTH then holds by construction, and lock, unlock and connect need no
  hand-over.
- **On a LAN:** native resolution, 60 fps, bitrate from the rate controller, and a low QP ceiling.
- **When the screen goes still:** one sharpening frame. Either a high-quality frame from the encoder (the usual
  approach) or, on slow links, a single lossless WebP pass over the changed tiles of that **same single layer**. That
  is the brief's M2 without the layers, and it reuses TileCodec, TileTracker and copy-rect unchanged.
- **Later:** test HEVC 4:4:4 or an equivalent for text in motion.

**Optional extras, each behind a flag, none ever the source of pixels:**
- the local cursor (keep it on);
- scroll and drag prediction as transforms over the last whole frame, reconciled by the next frame (TRUTH part b);
- Unified mode as a *view* that crops the whole-display texture per window, the brief's visibility-mask design. A
  per-window capture is added only for a window that is covered on the host.
- The layered desktop for local drags should come back only if slow-link tests show it is needed, and only as a
  prediction drawn over the base.

**Keep:**
- transport, pairing, session resume;
- the rate controller with the LAN fixes (fa4a948, 79b1eeb, cb2c729) and "latency is not bandwidth";
- HEVC encode/decode and loss recovery;
- input injection and the iOS touch input;
- curtain, unlock with biometry, permissions first run, updater, device lists, host menu;
- the tunables mechanism, with fewer keys;
- the test tooling: frame recorder, truth reference, connectcheck, scenarios, the NetworkThrottle shaper,
  `MIRAGE_TEST_DRAG` and selecttype key-to-pixel timing.

**Remove, or freeze behind a flag that is off and then delete:**
- the seam machinery: DisplayGuard, DisplayTaint, DesktopUnderlay, exclusion verification;
- the compositor model: overlay, bands, black-pixel clearing, fallback capture;
- per-window captures in Desktop mode;
- WarmPool and the warm snapshot, stage-1 cuts, placeholders and the connect barrier (a whole first frame makes them
  unnecessary);
- `WholeHandover`;
- fovea, small-animation tiles, ladder rungs and staged levels on fast links;
- `cutStills`, `alphaMask`, `shadowProbe`, `atomicCapture`.

Expect DesktopStreamer to shrink to well under 1,500 lines.

**What this costs, honestly:**
- Desktop-mode window drags are no longer local. On a 5 ms LAN that is invisible; at 220 ms it is not.
- Unified windows that are covered on the host need their own capture.
- At about 1 Mbps a whole 3200×1800 desktop as video is soft until the sharpening pass. That is why the tile pass stays
  for slow links.

**How to verify quality without phrz as the test:**

1. **Recorded side-by-side against Workbench** (already allowed: window-only recording on the MacBook). Run the same
   scripted scenario on mac-daddy through Mirage, Workbench and Screen Sharing (High Performance): connect, typing,
   scroll, window drag, a video playing, lock and unlock. For each, report fps during motion, time from motion
   stopping to a sharp picture (edge energy at full scale, never quarter scale), and bitrate.
2. **A truth metric.** The host already logs the composited display's cell means (`testTruthReference`). Line the
   viewer's recorded frames up with them by clock and report: the share of cells that differ, the longest time any
   region stays wrong, and partial frames. On the base design the target is 0 partial frames, and every region matches
   within one round trip plus one frame.
3. **A drag and typing harness.** Have the bench draw a frame counter or timestamp code in a corner, decoded from the
   viewer's recording, to measure input-to-photon latency per event. Extend `MIRAGE_TEST_DRAG` and selecttype to
   report latency p50/p95 and fps during a drag.
4. **A gate.** Run 1 to 3 every night on the shaper's profiles (LAN, 20 Mbps café, Fast 4G, Japan bus). A nightly that
   regresses any metric, or falls behind Workbench on the LAN, does not ship. phrz's sessions then confirm a result
   instead of finding the bugs.

## 6. Bottom line

The brief was ambitious and mostly sound for the link it was written for. Its key simplification, one capture per
display, was dropped on 10-18 to make window drags local. Then the link changed to a LAN, where that trade buys almost
nothing and costs nearly everything. The fixes of the last ten days are not wasted: they found the real ScreenCaptureKit
traps, and they produced the whole-display path, the transport, rate control, curtain, unlock and test tooling, all
worth keeping. But the per-window pipeline should stop being the base. Make whole-display video the always-correct base,
add the brief's tile refinement on that single layer for slow links, and treat everything per-window as an optional
extra that must win a recorded side-by-side before it ships.
