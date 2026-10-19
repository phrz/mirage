# byterace: should video be chosen by a byte race instead of the motion classifier?

**Question (2026-10-19):** today a region goes to hardware HEVC when `TileTracker`'s classifier sees sustained
motion over a large area; it never compares bytes. Should Mirage instead race lossless patching (WebP + copy-rect
+ cache references) against video per episode, switching to video only when lossless costs ≥ 1.5× the video
estimate for about a second?

**Answer: no.** A byte race is right exactly where the classifier is badly wrong (scrolls and terminal output,
where copy-rect + lossless is 1.4–3.2× cheaper *and* pixel-exact), but those cases are fixed more cheaply and more
reliably by a **copy-rect gate on the classifier** plus two host bugs (findings 1 and 2), and the gate was replayed:
scroll drops from 675 to 209 kbps at 2000 kbps with no soft text. Everywhere else the race loses or ties: on genuine
animation and video it must watch lossless lose for a second before switching (on the test clip that second is
11 MB of lossless), and on text at low budgets it misfires because the low-latency encoder's bytes are elastic (a
sparse change is cheap through video only because it comes out at 19–28 dB). No variant tested (1 s hold, 0.3 s
hold, constant-QP "equal quality" estimate, classifier-proposes/race-gates hybrid, classifier with a byte veto on
staying in video) beats "classifier + copy-rect gate + host fixes" across the set; the byte veto's only measured
win (flat vector animation at 2000 kbps, 12 %) did not survive a cheap estimator. Policy and DESIGN paragraph at
the end.

Everything below is measured on this MacBook (M4 Max, macOS 27.0.1) from real ScreenCaptureKit captures of
content generated for the purpose, replayed through the host's own tile code.

## Method

**Recording** (`bytrec`, `record.sh`, `make-clip.sh`). An accessory app opens its own windows (never key, ordered
front without activating, bottom-right of the screen) and generates content in them; each window is captured as its
own layer with SCK's desktop-independent window filter at native 2x, 30 fps cap, like a frontmost window layer
since M3.1. Frames are stored as LZ4 of the XOR with the previous frame (2.8 GB for the set, kept out of git).
Nothing of anyone else's screen is captured; no input is injected.

| sequence | content | window (px) | length | frames (fps achieved) |
|---|---|---|---|---|
| typing | NSTextView, prose typed at 5–14 chars/s with sentence pauses, typos backed out and retyped, hand-drawn blinking caret | 1600×1176 | 40 s | 1162 (29) |
| terminal | dark monospace view, bursts of build-log lines at 15–80 lines/s for 0.5–3 s, pauses, `\r` progress bars | 1600×1176 | 40 s | 1168 (29) |
| scroll | long rich-text document, trackpad-like flicks (momentum, τ = 0.33 s), slow drags, reading pauses | 1600×1176 | 25 s of frames | 719 (29) |
| spinner | settings form with a spinning `NSProgressIndicator` | 1600×1176 | 20 s | 523 (26) |
| anim | 240 pt flat vector animation (five orbiting rounded squares, pulsing dot) in a text page | 1600×1176 | 17 s | 430 (25) |
| anim-rich | the same shapes with gradients and soft shadows on a rotating gradient | 1600×1176 | 19 s | 480 (25) |
| video | a 640×360 pt player (`AVPlayerLayer`) playing a generated 1280×720 clip: camera-like pan over a detailed still with film grain, plus a moving test-pattern inset | 1600×1176 | 30 s | 746 (25) |
| mixed | three windows at once: editor typing, terminal with bursts, a status window with the flat animation and a spinner | 1040×816, 1040×816, 840×816 | 40 s | 369 / 363 / 359 (9) |

The machine was under load from other sessions (load average 7–34), so SCK delivered 9–29 fps rather than 30; all
strategies see the same frames, so comparisons within a sequence are unaffected. The mixed scene's 9 fps is close to
what the host gives non-frontmost window layers (10 fps).

**Replay** (`byterace run`). Per layer and frame, exactly the host's window-layer pipeline (`DesktopStreamer.captured`),
using the host's own `TileTracker`, `ShiftDetector` and `TileCodec` (symlinked from `Sources/`, not copied):
CPU diff with ±4 tolerance and tight changed boxes (alpha-layer rules), copy-rect detection on the unexplained dirty
box with the learned scroll rect at `HostEffort.full` (maxShift 900), the tracker's rate limit (80 ms), pending
tiles and refinement after 300 ms of calm with the motion freeze, WebP lossless at effort 4 on merged rects shrunk
to the changed boxes, solid rects as 4 bytes, near-lossless above 4096 colours. Video is a VideoToolbox HEVC
hardware session configured like `HEVCEncoder` (low-latency rate control, no reordering, LTR on, MaxKeyFrameInterval
2²⁰, DataRateLimits 1.5× average, first frame a keyframe at QP ≥ 40), fed the per-layer canvas that only receives
the tiles sent as video, at ≤ 30 fps (15 when the region is under 3 % of the layer), decoded again to measure PSNR.
Added on top, identically in every strategy: a client tile cache (exact 64-px tile hashes; a tile already sent once
costs a 20-byte reference, DESIGN §3.3). Wire overheads: tile message 33 B + 12 B per rect, copy-rect 45 B, video
47 B per 1200-byte datagram plus one parity datagram per 8 (DESIGN §3.3c) plus the tile mask. Not modelled: the
link (no token pacing, tier or fovea, so the host's "tile budget exhausted → video" escape never fires), loss (so
LTR never matters), and a layer's first picture (frame 0 is on the client already, crisp).

**Strategies.**
- *classifier*: today's `TileTracker.classify` (≥ 28 dirty tiles, or a cluster of ≥ 8 tiles dirty 4× in 400 ms).
- *all-lossless* / *all-video*: every episode (changes separated by ≥ 300 ms of calm) lossless, or through video.
- *race*: per layer, lossless by default; a shadow HEVC session at the link's budget is fed the whole current frame
  whenever anything changed (in both modes, so its reference never goes stale) and its P-frame bytes are the video
  estimate; switch to video when lossless sent over the last 1 s ≥ 1.5 × the estimate, held for 1 s; on the switch
  the region (bounding box of the last second's dirty tiles) is copied whole into the canvas and masked, i.e.
  refreshed against the encoder's stale reference (that refresh is where the "intra" cost lands; the first
  switch also creates the session, a QP ≥ 40 keyframe); while in video the lossless estimate is the WebP of the
  region's dirty tiles, computed and not sent; back to lossless after 300 ms of calm in the region or when lossless
  ≤ video over 2 s for 2 s, minimum dwell 1 s; soft tiles are refined as today.
- *race-fast*: the same with a 0.3 s hold.
- *race-q*: "equal quality": the shadow runs at constant QP 30 (min = max) instead of the link budget, plus an
  immediate switch when lossless ≥ 4× the estimate over 200 ms.
- *hybrid*: the classifier proposes video; it is taken only if no copy-rect explained ≥ half a frame's change in the
  last 300 ms and the race (≥ 200 ms of history) says lossless ≥ 1.5× video; leaving as in *race*.
- *veto*: the classifier's sustained-motion rule enters video (no shadow encoder), except within 300 ms of a frame
  whose change a copy-rect explained at least half of (the *copy-rect gate*); in video, the lossless estimate is
  WebP at effort 4 on at most 16 sampled dirty tiles, scaled; when it is ≤ the video actually sent over 1 s (after
  1 s in video) the region returns to lossless and stays there 10 s unless lossless then costs ≥ 1.5× the region's
  last video rate; otherwise leaving as in *race*.
- *oracle*: per episode, whichever of all-lossless and all-video cost less in hindsight (bytes after an episode,
  refinement included, are charged to it), then replayed for real so switch costs are actual. It is a per-episode
  oracle: a policy that mixes within an episode (the classifier does) can beat it.

Two budgets: 600 kbps (≈ a 1 Mbps link after the tile share) and 2000 kbps (≈ 3–4 Mbps).

## Results

Average kbps over each sequence (all layers), lower is better; bold is the cheapest per row.

#### Average kbps per strategy (all layers of the sequence; lower is better)

| sequence | video budget | classifier | all-lossless | all-video | race | race-fast | race-q | hybrid | veto | oracle |
|---|---|---|---|---|---|---|---|---|---|---|
| typing | 600 | 17 | 17 | 29 | 17 | 18 | 27 | 17 | 17 | **17** |
| typing | 2000 | **17** | **17** | 30 | **17** | **17** | 26 | **17** | **17** | **17** |
| terminal | 600 | 323 | 352 | 574 | 357 | 365 | 392 | 361 | 324 | **276** |
| terminal | 2000 | 795 | **352** | 1064 | **352** | 527 | 643 | 521 | 556 | **352** |
| scroll | 600 | 291 | **209** | 412 | **209** | **209** | **209** | **209** | **209** | 209 |
| scroll | 2000 | 675 | **209** | 1045 | **209** | 319 | **209** | **209** | **209** | **209** |
| spinner | 600 | **12** | **12** | 46 | **12** | 20 | **12** | **12** | **12** | **12** |
| spinner | 2000 | **12** | **12** | 49 | **12** | **12** | **12** | **12** | **12** | **12** |
| anim | 600 | 759 | 1177 | **756** | 777 | 767 | 757 | 762 | 758 | **756** |
| anim | 2000 | 1338 | **1177** | 1336 | **1177** | 1328 | 1331 | 1332 | 1335 | **1177** |
| anim-rich | 600 | 750 | 3601 | **746** | 973 | 877 | 793 | 827 | 772 | **746** |
| anim-rich | 2000 | **1461** | 3601 | 1463 | 1612 | 1542 | 1506 | 1501 | 1483 | 1463 |
| video | 600 | 783 | 70469 | **778** | 3750 | 2710 | 1052 | 1640 | 1050 | **778** |
| video | 2000 | 2187 | 70469 | **2182** | 4599 | 4078 | 2452 | 2755 | 2468 | **2182** |
| mixed | 600 | 362 | 457 | 389 | 454 | 388 | 378 | 352 | 375 | **335** |
| mixed | 2000 | 535 | 457 | 620 | 478 | 504 | 561 | 482 | 566 | **403** |

#### Text shown soft (share of time a changed text/UI tile is video-quality), switches to video, text PSNR

| layer | budget | classifier | all-lossless | all-video | race | race-fast | race-q | hybrid | veto | oracle |
|---|---|---|---|---|---|---|---|---|---|---|
| typing | 600 | 0 % | 0 % | 40 % ·20↗ ·49 dB | 0 % | 1 % ·1↗ ·40 dB | 8 % ·4↗ ·41 dB | 0 % | 0 % | 1 % ·1↗ ·35 dB |
| typing | 2000 | 0 % | 0 % | 40 % ·20↗ ·52 dB | 0 % | 0 % | 18 % ·4↗ ·44 dB | 0 % | 0 % | 0 % |
| terminal | 600 | 67 % ·29 dB | 0 % | 88 % ·24↗ ·29 dB | 26 % ·2↗ ·19 dB | 53 % ·4↗ ·27 dB | 62 % ·4↗ ·26 dB | 56 % ·3↗ ·27 dB | 50 % ·3↗ ·28 dB | 51 % ·2↗ ·28 dB |
| terminal | 2000 | 72 % ·40 dB | 0 % | 88 % ·24↗ ·40 dB | 0 % | 33 % ·2↗ ·24 dB | 62 % ·4↗ ·36 dB | 36 % ·2↗ ·35 dB | 52 % ·3↗ ·37 dB | 0 % |
| scroll | 600 | 93 % ·24 dB | 0 % | 94 % ·14↗ ·24 dB | 0 % | 0 % | 0 % | 0 % | 0 % | 0 % ·1↗ |
| scroll | 2000 | 93 % ·29 dB | 0 % | 94 % ·14↗ ·28 dB | 0 % | 26 % ·2↗ ·19 dB | 0 % | 0 % | 0 % | 0 % |
| spinner | 600 | 0 % | 0 % | 0 % ·1↗ | 0 % | 0 % ·1↗ | 0 % | 0 % | 0 % | 0 % |
| spinner | 2000 | 0 % | 0 % | 0 % ·1↗ | 0 % | 0 % | 0 % | 0 % | 0 % | 0 % |
| anim | 600 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| anim | 2000 | 0 % | 0 % | 0 % ·1↗ | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % |
| anim-rich | 600 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| anim-rich | 2000 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| video | 600 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| video | 2000 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| mixed/editor | 600 | 0 % | 0 % | 84 % ·6↗ ·40 dB | 8 % ·1↗ ·33 dB | 8 % ·1↗ ·33 dB | 19 % ·2↗ ·35 dB | 0 % | 0 % | 0 % ·1↗ |
| mixed/editor | 2000 | 0 % | 0 % | 84 % ·6↗ ·43 dB | 0 % | 0 % | 19 % ·2↗ ·35 dB | 0 % | 0 % | 0 % ·1↗ |
| mixed/terminal | 600 | 12 % ·28 dB | 0 % | 93 % ·5↗ ·31 dB | 2 % ·1↗ ·27 dB | 88 % ·2↗ ·31 dB | 91 % ·3↗ ·23 dB | 9 % ·1↗ ·20 dB | 27 % ·3↗ ·23 dB | 83 % ·2↗ ·28 dB |
| mixed/terminal | 2000 | 84 % ·36 dB | 0 % | 93 % ·5↗ ·41 dB | 2 % ·1↗ ·27 dB | 88 % ·2↗ ·38 dB | 91 % ·3↗ ·27 dB | 9 % ·1↗ ·25 dB | 27 % ·3↗ ·24 dB | 10 % ·1↗ ·31 dB |
| mixed/status | 600 | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ |
| mixed/status | 2000 | 0 % | 0 % | 0 % ·1↗ | 0 % | 0 % | 0 % ·1↗ | 0 % ·1↗ | 0 % ·1↗ | 0 % |

"Text soft" is the share of time that a text/UI tile which changed at least once in the sequence was showing
video-quality pixels (tiles outside the animation, spinner and player rects); ↗ is the number of switches to video;
the dB figure is the luma PSNR of text tiles in decoded video frames. Animation/video tiles are never counted as text.

### What the numbers say

1. **Text and UI (typing, spinner, editor): every sensible policy agrees on lossless** (17 kbps typing, 12 kbps
   spinner). All-video costs 1.7–4× more. The classifier is already right here; so is the race.
2. **Scroll: the classifier wastes bytes and leaves text soft.** At 2000 kbps it spends 675 kbps against 209 for
   copy-rect + lossless (3.2×), at 600 kbps 291 against 209 (1.4×), and text is soft 93 % of the time at 24–29 dB,
   because momentum frames the copy-rect does not explain are classified as motion. Every race variant keeps
   scroll lossless and crisp.
3. **Terminal output: same story, once copy-rects work.** With the host's detector unchanged (finding 1) there are
   no copy-rects at all and all-lossless costs 2405 kbps, so the classifier's video (398 / 878 kbps) looks like a
   bargain. With a working copy-rect, lossless is 352 kbps and the classifier's 795 kbps at 2000 is 2.3× too much,
   with text soft 72 % of the time. At 600 kbps video can undercut lossless by 8–22 % (classifier 323, oracle 276),
   but only by showing build output at 26–29 dB.
4. **Genuine animation and video: video, and quickly.** Shaded animation costs 3601 kbps lossless against 746
   through video at 600 kbps (4.8×) and 1461 at 2000 (2.5×); the video clip 70 469 kbps lossless against 778 (90×).
   The classifier switches within ~130 ms; the 1 s race pays its hold in lossless: +30 % on the 19 s shaded
   animation, and on the clip 3750 kbps instead of 783 (11 MB of lossless in the first two seconds). On a real link
   the tile budget would cap that (the host's existing "budget spent → video" escape), so the true cost of the hold
   is about one second of the tile budget, not 11 MB, but it is still a second of a stalled, partially drawn video.
   The hybrid (classifier proposes, ≥ 200 ms of race history gates) still pays 3.3 MB (1640 kbps). *race-q* and
   *veto* pay one frame (1 MB at 1280×720 lossless, 1052 / 1050 kbps instead of 783): the replay's race machinery
   decides after a frame has been sent, so their first motion frame goes lossless; a host implementation deciding
   before sending would not pay it, so read those two as ≈ classifier on the clip.
5. **Flat vector animation at a high budget is the one place a byte race finds bytes the classifier wastes:**
   1177 kbps lossless against 1338 through video at 2000 kbps (the low-latency rate controller spends toward its
   target whatever the content), while at 600 kbps video wins (756). The race gets both right; race-q and hybrid
   switch to video at 2000 and lose the 12 %.
6. **The video estimate is the race's weak point.** At the link budget it is cheap for sparse text only because the
   encoder produces mush (the race's 600 kbps misfires: terminal soft 26 % at 19 dB, editor 8 %, for no byte gain).
   At constant QP 30 (race-q) it is cheap for terminal bursts too, and race-q misfires more (terminal 392 / 643 kbps
   against 352 lossless, typing 27 against 17). Bytes alone cannot tell "text that changes a lot" from "motion".
7. **Switches are few in every policy** (0–4 per layer per sequence); the per-switch region refresh plus, on the
   first switch, the session's keyframe is 3–73 KB (73 KB for the 1600×1176 terminal's first keyframe, 3 KB for an
   animation box), small next to the episode it buys.
8. **Mixed desktop:** the per-layer race helps where the classifier misfires on the terminal window and loses where
   it hesitates on the status animation; the hybrid is best of the online policies at 600 (352 kbps vs 362
   classifier, oracle 335) and close at 2000 (482 vs 535, all-lossless 457, oracle 403).
9. **Classifier + copy-rect gate + byte veto (*veto*), replayed:** the gate is what works. Scroll goes from 291 / 675
   kbps to 209 / 209 with no soft text; typing, spinner and editor stay lossless; animation and video keep the
   classifier's fast entry (anim 758 / 1335, anim-rich 772 / 1483, status window 272 / 377 kbps, within 0–4 % of the
   classifier). The veto itself never fired where it should: on the flat animation at 2000 kbps the sampled
   estimate (per-tile WebP plus per-message overhead, no rect merging) overstates lossless by more than the 12 % the
   veto could save. On the terminal the 300 ms gate is too short: bursts whose frames the copy-rect misses still go to
   video (324 / 556 kbps against 352 all-lossless, text soft ~50 %), better than the classifier's 323 / 795 at 2000
   but not the 352 lossless.

### Cost of computing both estimates (host CPU per frame)

#### Per layer: bytes by path for the classifier and the veto policy (KB: direct lossless / refinement / copy-rect / video incl. keyframes)

| layer | budget | frames | dirty tiles/frame | copy-rects | classifier | veto | veto: sampled lossless estimate CPU per frame |
|---|---|---|---|---|---|---|---|
| typing | 600 | 1162 | 0.3 | 0 | 86 / 0 / 0 / 0 | 86 / 0 / 0 / 0 | 0.00 ms |
| typing | 2000 | 1162 | 0.3 | 0 | 86 / 0 / 0 / 0 | 86 / 0 / 0 / 0 | 0.00 ms |
| terminal | 600 | 1168 | 17.0 | 308 | 95 / 335 / 14 / 1170 | 1102 / 28 / 14 / 476 | 0.62 ms |
| terminal | 2000 | 1168 | 17.0 | 308 | 95 / 335 / 14 / 3534 | 1102 / 28 / 14 / 1637 | 0.35 ms |
| scroll | 600 | 719 | 13.6 | 314 | 45 / 16 / 14 / 822 | 629 / 0 / 14 / 0 | 0.00 ms |
| scroll | 2000 | 719 | 13.6 | 314 | 45 / 16 / 14 / 2003 | 629 / 0 / 14 / 0 | 0.00 ms |
| spinner | 600 | 523 | 1.6 | 0 | 31 / 0 / 0 / 0 | 31 / 0 / 0 / 0 | 0.00 ms |
| spinner | 2000 | 523 | 1.6 | 0 | 31 / 0 / 0 / 0 | 31 / 0 / 0 / 0 | 0.00 ms |
| anim | 600 | 430 | 29.8 | 307 | 11 / 0 / 14 / 1625 | 14 / 0 / 14 / 1619 | 8.92 ms |
| anim | 2000 | 430 | 29.8 | 307 | 11 / 0 / 14 / 2881 | 14 / 0 / 14 / 2872 | 11.42 ms |
| anim-rich | 600 | 480 | 31.1 | 8 | 1 / 0 / 0 / 1813 | 53 / 0 / 0 / 1814 | 36.17 ms |
| anim-rich | 2000 | 480 | 31.1 | 8 | 1 / 0 / 0 / 3533 | 53 / 0 / 0 / 3534 | 36.95 ms |
| video | 600 | 746 | 249.6 | 4 | 0 / 0 / 0 / 2939 | 1034 / 0 / 0 / 2905 | 40.98 ms |
| video | 2000 | 746 | 249.6 | 4 | 0 / 0 / 0 / 8205 | 1034 / 0 / 0 / 8224 | 40.92 ms |
| mixed/editor | 600 | 369 | 0.4 | 1 | 28 / 0 / 0 / 0 | 28 / 0 / 0 / 0 | 0.00 ms |
| mixed/editor | 2000 | 369 | 0.4 | 1 | 28 / 0 / 0 / 0 | 28 / 0 / 0 / 0 | 0.00 ms |
| mixed/terminal | 600 | 363 | 14.7 | 45 | 42 / 113 / 2 / 264 | 265 / 9 / 2 / 232 | 0.64 ms |
| mixed/terminal | 2000 | 363 | 14.7 | 45 | 42 / 113 / 2 / 708 | 265 / 9 / 2 / 670 | 0.64 ms |
| mixed/status | 600 | 359 | 16.5 | 0 | 43 / 0 / 0 / 1337 | 27 / 0 / 0 / 1333 | 9.98 ms |
| mixed/status | 2000 | 359 | 16.5 | 0 | 43 / 0 / 0 / 1770 | 27 / 0 / 0 / 1861 | 9.84 ms |

(The last column is the *veto* policy's sampled estimate; the race's full estimates are in the bullets.)

- **Video estimate:** a second hardware session on the same frames costs 0.2–0.6 ms of CPU but **4–21 ms of wall
  time per frame** on the media engine (measured with `VTCompressionSessionCompleteFrames` per frame, on a machine
  under load), the same engine that encodes the real stream. On mac-daddy (M3 Ultra, two media engines) it would
  likely fit; on a host with one engine it halves the encoder headroom for every racing layer.
- **Lossless estimate while in video** (WebP of what video carries, at effort 4): 1–3 ms per frame for terminal
  bursts, 16–44 ms for the animations and **482 ms per frame for the video clip**. It cannot run at effort 4 on a
  whole video region; sampled to 16 tiles (*veto*) it costs the per-frame figure in the table above, but is then not
  accurate enough to decide anything (finding 9).
- Diff and copy-rect search, needed by every policy: 0.4–5.5 ms and 0.2–5 ms per frame.

## Host findings (worth more than the race)

1. **`ShiftDetector` misses terminal scrolls.** On monospace output the line-profile SAD of the true shift (one line,
   −30 px) is *above* the SAD at zero shift (e.g. 749 against 507), so `best.sad < 0.4 × zero` rejects it, although
   the shift verifies tile by tile at 0.91–0.93. Result: 0 copy-rects in 1168 frames of terminal output, all-lossless
   at 2405 kbps instead of 352, and the classifier sending a terminal through video. The replay's fallback (verify the
   three best profile shifts; accept a verification ≥ 0.8 that explains ≥ 60 % of the frame's dirty tiles) finds 308
   copy-rects there and none on the animations; that or an equivalent belongs in `ShiftDetector.detect`.
2. **`TileTracker.markCopied` marks copied tiles crisp unconditionally** ("crisp again if the source was crisp", but
   the code does not check the source). Video-soft text moved by a copy-rect is never refined: in the classifier's
   scroll replay text stays soft 93 % of the time after scrolling stops. Copied tiles should inherit the pending
   state of their source tiles.
3. The classifier's motion rule treats a scroll's unexplained frames (momentum steps where detection fails, exposed
   strips) as sustained motion; once the copy-rect is found again the region is already video. The copy-rect gate
   below (replayed as *veto*) keeps scroll lossless and crisp: 209 kbps instead of 675 at 2000.

## Recommended policy

Keep the motion classifier as the trigger (it switches within a few frames, which matters for animation and video)
and do not race bytes:

1. **Fix `ShiftDetector` (finding 1) and `markCopied` (finding 2).** They account for most of the wasted bytes and
   all of the lasting soft text in the classifier's runs.
2. **Copy-rect gate (replayed):** a frame where a copy-rect explained at least half of the change, or did in the last
   300 ms, is never motion; its dirty tiles stay on the lossless path with the usual rate limit. Measured: scroll
   675 → 209 kbps at 2000 kbps and 291 → 209 at 600, text never soft; no effect on animation or video. For terminal
   output a longer memory (e.g. 1 s, or "this layer's scroll rect is known") is the next thing to try; it was not
   replayed.
3. **No shadow HEVC session and no hold-then-switch race.** The shadow costs 4–21 ms of media-engine time per frame,
   its estimate is not comparable with lossless at equal quality in either form tried, and any hold costs a second
   of the tile budget on every animation.
4. **Byte veto: optional, low value.** The only case it would win is flat vector animation at budgets ≥ 2 Mbps
   (12 %), and a cheap estimator has to be within a few percent of the real lossless cost to catch it (merge the
   sampled tiles into rects as `submitLossless` does). Not worth building before 1 and 2.
5. Switches need no IDR: the canvas already refreshes a region against the encoder's stale reference (the first
   switch's keyframe and the refresh measured 3–73 KB), and LTR plays no part without loss.

What this replay could not settle: behaviour under a real tile budget (the "tile budget spent → video" escape never
fires here), the mac-daddy media engines, and hours-long sessions. A `--scenario scroll` run against mac-daddy with
the gate and the two fixes would confirm the scroll numbers on a real link.

## Proposed DESIGN.md §3.3 paragraph (not applied)

> **Video is chosen by motion, never for a scroll (byterace, 2026-10-19).** A byte race between lossless patching
> and video was measured on recorded typing, terminal, scroll, spinner, animation, video and mixed sequences and
> rejected (experiments/byterace): it finds the classifier's waste only on scrolls and terminal output, where a
> copy-rect gate does better, while on animation and video any hold before switching costs a second of the tile
> budget (the test clip is 90× cheaper as video), the low-latency encoder's bytes are elastic (sparse text is cheap
> through video only at 19–28 dB), and a shadow encoder costs 4–21 ms of media-engine time per frame. The classifier
> stays the trigger with one rule on top: a frame where a copy-rect explains at least half the change, or did in the
> last 300 ms, is never motion, which keeps scrolls copy-rect + lossless (209 kbps against 675 through video at a
> 2 Mbps budget) and pixel-exact. Copied tiles inherit their source's refinement state, and the scroll detector
> verifies its best candidate shifts when the profile ratio test fails (monospace output otherwise yields no
> copy-rects at all).

## Files

- `Sources/bytrec/main.swift` recorder; `record.sh` records every scene; `make-clip.sh` writes the test clip (ffmpeg).
- `Sources/byterace/main.swift` replay; `run-all.sh` replays every scene; `summarize.py` prints the tables above.
- `Sources/MirageTiles`: symlinks to the host's `TileTracker`, `ShiftDetector`, `TileCodec` plus a copy of `PixelRect`;
  `Sources/CWebP` symlinks the vendored libwebp.
- `results/*.txt|json`: the runs above (`results/race-q/` for race-q, `results/veto/` for veto, `results/host-detector/` for an earlier run with
  the host's detector unchanged and without race-fast/race-q/hybrid).

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
swift build -c release
./make-clip.sh clip.mp4 && ./record.sh seq clip.mp4      # ~5 min, windows bottom-right, never key
./run-all.sh seq                                         # ~2 h on a busy M4 Max (the video scene dominates)
python3 summarize.py
```

`HOST_DETECTOR=1` replays with the host's copy-rect detector unchanged (no fallback); `SHADOW_MAXQP` sets race-q's QP;
`byterace dump <file.frames> <index> <out.png>` writes one recorded frame.
