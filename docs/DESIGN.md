# Pro remote desktop for Apple devices — design

Working name: TBD. Host = `mac-daddy` (M3 Ultra, 256 GB, macOS 27.0.1, 5K + 3200×1800 displays).
Clients = this MacBook (M4 Max, macOS 27.0.1), iPhone, iPad. Link today: direct WireGuard
path over the tailnet, ~220 ms RTT, worst case ~1 Mbps.

## 0. The physics that explains why ARD feels broken

Click-to-pixel at 220 ms RTT, best case:

| Stage | Cost |
|---|---|
| input to host | 110 ms |
| capture + HW encode | ~15 ms |
| **serialize one 20 KB frame at 1 Mbps** | **160 ms** |
| wire back | 110 ms |
| decode + present | ~10 ms |
| total | **~400 ms** |

Two consequences drive everything below:

1. Frame payloads must stay around 5–10 KB at the bottom of the ladder, so the only workable
   design is "send nothing for what did not change, send tiny lossless patches for what settled,
   send low-fps video only for what is actually moving."
2. 220 ms is unfixable on the wire, so the *feeling* of latency must be hidden locally:
   cursor, window management, scroll and text echo have to happen on the client before the
   host confirms. This is not a nice-to-have; it is the product.

ARD/VNC fails both: full-frame or coarse-rect image updates over one TCP stream, with input
multiplexed behind pixel data (head-of-line blocking is the "lost clicks" feeling), and a
remote-drawn cursor.

## 1. What Astropad LIQUID actually is (from the Workbench 1.3.1 binary)

Workbench is a Rust core (crates `liquid_*`) wrapped in a Swift app. No REA skill was
available, so this is from `otool`/`strings` on the installed app:

- **Capture**: ScreenCaptureKit via `objc2-screen-capture-kit`; uses per-display *and*
  per-window filters (`initWithDesktopIndependentWindow:`, `includingWindows:`), plus a
  `window_tracking` module and a virtual-display path (`LiquidVirtualDisplayScreenInfo`).
- **Change detection**: a wgpu compute shader (`diffing_pipeline.rs`, `dirty_rect.rs`) that
  marks dirty tiles on the GPU (`diff_output[tile_idx] = 1u`), plus a GPU scaling pipeline.
- **Codec = per-tile hybrid** (`liquid_codec`): `frame_grid`, `tile_estimator`,
  `tile_scheduler`, `data_limits`. Tile encoders present in the binary:
  - a custom **lossless rANS codec with prediction** (`rans.rs`, `rans/predict.rs`,
    "Invalid lossless version number") — this is the "perceptually lossless Retina" part;
  - **VP8 intra/inter** (the WebP crate, lossy stills);
  - **AV1 via rav1e** (software; Apple Silicon has *no* AV1 hardware encoder, confirmed
    locally — `VTCopyVideoEncoderList` lists HEVC, H.264, ProRes, JPEG hardware only);
  - **H.264/HEVC via VideoToolbox** (`video_encoder/apple.rs`, `h264_frame_segment.rs`,
    `hevc_support`, "Successfully set average bitrate").
  So "LIQUID picks the optimal codec per frame" really means per *tile*, per frame.
- **Transport**: QUIC (`quinn` 0.11) with datagrams, STUN + hole punching, relay fallback,
  AWDL probing for same-room links, short-term and long-term RTT tracking, a
  `latency_tracker`, and a `render_proxy/frame_aggregator` on the receive side.
- **Input**: CGEvent injection, pen pressure, and — the key latency trick — the cursor is
  *not* in the video; `CursorInfo` (type, size, hotspot, PNG images) is streamed as metadata
  and drawn locally by the client.
- **Not present**: any prediction of typed text or scrolling, and any client-side window
  management. Everything else about it (accounts, 11-region relay, subscription) exists
  because they have to work without a tailnet. You do not.

Takeaway: the architecture is right and it is reproducible with Apple frameworks alone.
The parts worth copying are the per-tile hybrid codec and the local cursor. The parts worth
adding are per-app/per-window layers with local window management and GUI-level prediction.

## 2. Verified platform capabilities (macOS 27.0.1, M4 Max)

- `VTCompressionSession` HEVC **hardware, low-latency rate control mode: works**
  (`EnableLowLatencyRateControl`), exposing `EnableLTR` (long-term reference frames for
  loss recovery without keyframes), temporal layering (`BaseLayerBitRateFraction`,
  `AverageTemporalBitRates`), `MaxAllowedFrameQP`/`MinAllowedFrameQP`, `DataRateLimits`,
  `RequestedMaxEncoderLatency`, `AllowFrameReordering=false`. Normal mode additionally has
  `ConstantBitRate`, `MaxFrameDelayCount`, `PrioritizeEncodingSpeedOverQuality`,
  `EnableUserQPMap` (per-region QP map — useful for "text sharp, photo soft").
- Hardware **HEVC-with-alpha** encoder exists (`muxa`) — per-window layers can be streamed
  with real transparency.
- `Network.framework` QUIC with `isDatagram = true` compiles and configures; QUIC streams +
  datagrams, TLS 1.3, client certificates, all native on macOS/iOS. No Rust needed.
- ScreenCaptureKit delivers frames only on change and attaches `dirtyRects` and
  `contentRect` per frame, so GPU diffing (Astropad's wgpu pass) is optional at first.

## 3. Architecture

Single Swift Package, three products, no FFI:

```
RemoteCore      protocol, pairing, transport, codec, tile store   (macOS + iOS)
HostAgent       LaunchAgent in the login session: SCK, VT encode, CGEvent, AX  (macOS)
Viewer          SwiftUI + AppKit/UIKit, Metal presentation         (macOS, iPadOS, iOS)
remotectl       CLI on host: pair, status, revoke, metrics       (macOS)
```

### 3.1 Transport and security

- **QUIC over the tailnet** (`NWConnection` with `NWProtocolQUIC`). Tailscale already gives
  NAT traversal, DERP relay fallback, and WireGuard. No relay infrastructure, no accounts.
- Stream layout (independent QUIC streams = no head-of-line blocking between classes):
  - `control` — reliable, ordered: session setup, layer/window list, cursor shapes, clipboard.
  - `input` — reliable, ordered, highest priority, flushed per event; sequence-numbered so
    nothing is ever silently dropped. Mouse moves coalesced to one per client vsync.
  - `tiles` — reliable: lossless/near-lossless tile patches (must arrive, order within a
    layer matters).
  - `video` — **QUIC datagrams**: HEVC frames, fragmented with per-frame sequence + fragment
    index; a lost frame is skipped and recovered by LTR/next frame, never retransmitted.
  - `feedback` — client → host: per-packet receive timestamps, decoded-frame acks, RTT.
- **Pairing without accounts**: `miraged pair` on the host (run over SSH or ARD) prints a
  6-digit code valid for 2 minutes. Client and host run a **CPace-shaped PAKE on X25519**
  (CryptoKit exposes no raw P-256 point arithmetic, so SPAKE2+ was dropped) with the code as
  the password and the host's TLS leaf fingerprint as the channel identifier, then exchange
  long-term **Ed25519 device keys** inside a ChaChaPoly box keyed from the PAKE. The host
  burns the code after one wrong confirmation tag, so 6 digits allow exactly one online guess.
- **Session authentication**: every later connection is QUIC/TLS 1.3 with a self-signed host
  certificate that nobody pins. Instead both sides sign a transcript containing the TLS leaf
  fingerprint the client actually saw plus fresh nonces (host first, then client). A
  man-in-the-middle terminating TLS presents a different leaf, so every signature fails.
  The host checks the client key against `authorized-devices.json`; the client checks the
  host key against `known-hosts.json`. Certificates and keychains stay out of it, which is
  what makes the same code run on iOS unchanged.
- Optional second factor for free: host calls the Tailscale local API `whois` on the peer
  address and refuses nodes not owned by `phrz@`.
- TCC: Screen Recording + Accessibility granted once on the host via GUI (over ARD today).

### 3.2 Capture: one desktop stream plus a visibility mask

Decided 2026-10-16 evening, replacing the earlier "one SCStream per app layer" plan.

The host keeps **one** ScreenCaptureKit display capture per physical display, scaled by SCK
to the client's chosen pixel size, cursor hidden, frames only on change with `dirtyRects`.
Everything the client shows, whether the whole desktop or three individual windows, is cut
out of that one stream. What makes individual windows cheap is a **visibility mask**, not
extra captures:

- The client knows which remote windows it has open locally and where, and which parts of
  them are covered by its own local windows. It sends the host a mask: the set of tiles it
  can actually show, updated on every local move, resize, focus change or occlusion change.
- The host intersects SCK's dirty tiles with the mask and encodes only the intersection.
  Pixels nobody can see are dropped before they cost a byte or an encoder cycle.
- One SCStream and one HEVC session per display regardless of window count, so it scales,
  and overlap on the client side is free: a window 80% covered sends 20% of its tiles.
- The lossless refinement pass, the tile scheduler and the bandwidth budget all already
  work in tiles, so the mask is one more filter in the same pipeline.

The one thing a single composited capture cannot give you is a window that is partly
**covered on the host**. Two rules handle it:

1. Focusing a remote window locally raises it on the host through Accessibility
   (`AXRaise`), the same call the local-window-management latency trick already uses, so in
   normal use the window you are looking at is on top over there as well.
2. If a window you have open locally stays occluded on the host (you want two host-stacked
   windows side by side here), the host opens a dedicated `desktopIndependentWindow`
   SCStream for just that window, for as long as the condition holds. In practice that is
   zero or one extra stream, never one per window.

Opening a remote window locally also grabs a single unoccluded `desktopIndependentWindow`
snapshot so its initial content is complete even if it was buried on the host.

Window metadata (id, pid, title, frame, level, z-order, minimized, focused) is published on
`control` at up to 30 Hz from `SCShareableContent` + `CGWindowListCopyWindowInfo` +
AX notifications. In Unified mode each remote window is a real `NSWindow` (or iPadOS scene)
whose content view is a Metal layer sampling its rect of the display texture; in Desktop
mode the whole texture is shown in one window or a full-screen Space.

**Layered desktop, client-side composition (phrz, 2026-10-18).** Desktop-mode dragging can
never be local with a single composited capture: the area a window uncovers does not exist on
the client until the host streams it, and the dragged rectangle has no shadow and wrong
layering. So the capture model becomes *layers in every mode*: the desktop background as one
lossless layer, each window as its own unoccluded lossless layer (ScreenCaptureKit
`desktopIndependentWindow` capture gives the full window even when covered), captured when a
window is first seen and refreshed through the same dirty tracking and tile/copy-rect path,
plus the window list with frames and z-order. The client composites the scene itself, with a
standard macOS shadow per window. Dragging, raising, minimizing and overlap are then purely
local in Desktop mode too, with the host told the result; the stream only keeps layers
current. Unified mode later maps these same layers onto native `NSWindow`s. Transient windows
(menus, sheets, popovers, tooltips) are short-lived layers of their own, and the one display
stream remains as the fallback for anything not attributable to a window.

**As built, M3.1 (2026-10-18).** Every window at CGWindow level 0 of a real app (not the dock, not the
menu bar), front first, up to 16 windows or 48 Mpx, gets a `desktopIndependentWindow` SCStream at the
stream's pixel scale, shadow left out, the off-screen part included, child windows included (macOS 26
draws a titled window's traffic lights in a 66×20 child window of their own; the window list folds such
children into their parent). The display stream excludes exactly the windows the viewer holds as layers,
and their children, and is captured without shadows; the viewer draws a macOS-style soft shadow per layer
(key window, inactive, menu). Everything else in the on-screen list (menus, popovers, the dock, the menu
bar, overflow windows) stays in the display layer and the client draws it as a *cut-out* of that layer at
its frame, in z-order, so menus still sit above windows. A new layer is announced (`reset` with its pixel
size), gets one lossy WebP still (~0.15 s of the tile budget, upscaled on the client) and then lossless
blocks, locus layer first, one in flight across all layers; the display layer keeps its tiny-keyframe
ladder. Each layer has its own tile tracker, last frame, scroll detection, per-tile capture sequences on
the viewer and, when it moves, its own HEVC canvas and encoder (at most four live, released after 10 s
idle); the rate controller, pacer, in-flight cap and tile budget stay shared. Tiles of a layer fully
covered on the host are tracked but not sent until uncovered. Measured facts that shaped it
(`miraged probe-layers`, experiments/probes): a window stream delivers a frame per interval whether or
not anything changed (33 fps for a still window, alternating two IOSurfaces, dirty rect always the whole
window), so the tolerant CPU diff is the change detector and the interval the cost knob (30 fps for the
frontmost window, 10 for the rest, 2 for fully covered ones); corner anti-aliasing of a still window
jitters by ±10 levels between frames, so semi-transparent pixels get a wide tolerance; a stream starts in
100–170 ms. Window management: a press on a layered window's title bar (right of the traffic lights)
sends nothing; if the pointer moves the window follows it locally and the host receives
`windowCommand(move)` at ≤ 20 Hz and on release (applied with `kAXPositionAttribute`), else the click is
sent on release; a press anywhere in a layered window raises it locally at once; the host's window list
carries the input sequence it reflects so the local override is retired when the host has caught up.
Host-side drags of layered windows cost no pixels at all: the list carries the frame at up to 30 Hz.
Cut-outs and occlusion (fixed after the first mac-daddy run, see §6 "M3.1 field regression"): the host
marks a non-layered window `cutout` only when it is safe to draw over window layers (pop-up menus,
popovers, the dock, the menu bar, normal app windows; never Window Server's own windows, never anything
desktop-sized above the normal level), the viewer draws a cut-out only where it overlaps a window layer
(and that layer's shadow) behind it, and the host counts only layers and cut-out-safe windows as occluders
when it holds back covered tiles. Every window gets its still before any window gets lossless blocks.

Mode summary:

| Mode | Capture | Mask |
|---|---|---|
| Desktop | display stream | whole frame minus nothing |
| Unified (windows) | same display stream | union of locally visible window rects |
| Occluded-on-host window | + one per-window stream | that window only |

### 3.3 Codec: per-tile hybrid, three paths

Per layer, per captured frame, split into 64×64 tiles (128 on 2x). Use SCK `dirtyRects`
(later: GPU diff like Astropad for exact tile masks). Classify each dirty tile by **motion
history** (dirty in N of the last M frames):

1. **Static → nothing.** Most of a desktop, most of the time.
2. **Settling / sparse → lossless tile** on the `tiles` stream. Typing, cursor-caused UI
   changes, blinking carets, a button highlight. Encoder: **WebP lossless** via libwebp,
   measured at ~550–800 B per 64² text tile and ~2x smaller than anything in Apple's
   Compression framework on UI content (experiments/tilebench). Adjacent dirty tiles are
   merged and encoded as one rect, which halves the per-pixel cost again. Near-lossless mode
   only for tiles classified rich (>256 colours), where it saves ~20 %. A custom predictor +
   rANS codec (Astropad's path) is not worth building: predictors measurably hurt on UI.
3. **Sustained motion → video**: the moving region's bounding rect (snapped to 64 px, or the
   whole layer if >40% dirty) goes to a hardware **HEVC low-latency session**, one per layer,
   `AllowFrameReordering=false`, `EnableLTR=true`, `MaxKeyFrameInterval` large (recover via
   LTR acks, not keyframes), `DataRateLimits` set per frame from the rate controller, QP map
   biased sharp on text-classified tiles. Decoded with `VTDecompressionSession` straight into
   a Metal texture.
   Scrolling is a special case: the host detects a uniform shift of a region (scroll event +
   AX scroll-area rect, or phase correlation on the dirty region) and sends a **copy-rect**
   plus the newly exposed strip as lossless tiles instead of video; see §3.5 item 3.
   Measured (experiments/seqbench): scroll and drag cost ~3 KB per frame at 36–38 dB at
   800 kbps in low-latency mode, so ~30 fps of motion fits in 1 Mbps; a single changed text
   tile through video costs 1 KB at an unreadable 20 dB, versus 0.55 KB lossless, which is
   why sparse changes never take this path. Unchanged frames must never be submitted: the
   rate controller otherwise spends its budget refreshing a static picture. The first
   keyframe (161 KB at 2x, 72 KB at 1x) is the stall to engineer around: cap its QP, start
   one rung down the ladder, refine with lossless tiles, and avoid later keyframes via LTR.
   Checked against the field (experiments/codecbench): on screen content WebP lossless is
   1.7–3x smaller than JPEG XL lossless and 5–10x smaller than AVIF/HEIC lossless, and decodes
   fastest; JPEG XL only wins on encode time for whole desktops, which the tile path never
   does. **Learned ("neural") image codecs** are allowed in exactly one place: a learned
   entropy model behind an exactly reversible coder (a 20–30 % gain over WebP is plausible on
   UI tiles, with zero substitution risk). A learned *lossy* codec may only ever be a first
   pass that lossless refinement overwrites, never the final state of text: the JBIG2/Xerox
   failure, where a symbol matcher swapped visually similar digits, is the exact failure mode
   of a text-trained lossy model, and no quality metric catches it. The safe extreme form of
   font-aware coding is verified glyph re-rendering: recognize a glyph, render it locally from
   the same font, accept it only if the rendered pixels hash-match the host's, else send
   pixels; lossless by construction.
   **Reuse is alignment-free where it pays; the grid is bookkeeping (phrz, 2026-10-17).**
   Three units, three jobs: the 64 px grid for dirty tracking, masks and budgets; merged
   rects for encoding; and for reuse across frames, *two* keys on top of copy-rect: grid-tile
   hashes for same-position recurrence and **content-box** hashes (runs split on background
   rows/columns: lines, words, controls) for alignment-free recurrence. Measured
   (experiments/boxcache): copy-rect explains 95–96 % of a scroll's changed pixels in AppKit,
   WebKit and Chromium alike; on the residual, content boxes beat grid tiles where text
   reflows around a change (AppKit typing 69 % vs 20 %, AppKit scroll 50 % vs 27 %) but not
   in WebKit (46 % vs 52 %), where box extents shift by a pixel. Neither unit dominates, so
   both are keyed; the hit rate on real multi-hour sessions decides cache sizes. What remains
   after copy-rect and cache is 1–3 KB of genuinely new pixels per scroll step or keystroke.
   **Exactness is a refinement, never a gate**: a box that matches within tolerance (size
   within ±2 px, ≥97 % identical pixels) is drawn immediately from the cache and marked
   approximate; exact pixels backfill at the lowest priority, like video building to
   lossless. RDP's glyph cache and Citrix text caching did exact box reuse a decade ago;
   pairing it with the prediction layer and the tolerant tier is the new part.
   Why boxes win on reflow: inserting one glyph shifts every word after it, so every grid
   tile crossing the line changes its hash, while word/line boxes move as units and keep
   theirs; boxes lose when a line's extent wobbles by a pixel. Selection is therefore not a
   mode: per residual region the host looks up both grid and box hashes and sends whichever
   reference set covers more pixels, mixing freely.
   **Client-side native scroll containers (phrz, 2026-10-17).** In both modes each scrollable
   area becomes a native `NSScrollView`/`UIScrollView` on the client whose content is the
   per-window document canvas (visible pixels plus cached off-screen content). That unifies
   scroll prediction, the scrollback canvas and the cache in one object and gives native
   momentum, rubber-banding and one-frame response for free. The client owns scroll physics;
   the host follows positions, by setting the scroll offset through Accessibility where it
   exists or by sending position-matched discrete deltas (never momentum events) where not,
   so the host app never runs a second physics simulation. Document extent for springing
   comes from Accessibility, or is learned from observed offsets with springing enabled only
   after the host has reported an end. A mismatch detector (host offset diverging from the
   client's) drops that window back to pixel-follow mode for nested scroll views and
   scroll-linked animations.
   **Tile cache (phrz, 2026-10-17).** Both ends keep a content-addressed LRU of lossless tiles
   (hash → pixels on the client; hash → "client has it" on the host, confirmed by acks). A
   tile the client already holds is sent as `hash @ (x,y)`, ~20 bytes instead of ~550, which
   makes same-position recurrence (tab switches, re-exposed windows, reopened menus, dialogs)
   nearly free. It does **not** help scroll-back by itself: a 30 px wheel step moves every
   glyph inside its tile, so grid-aligned hashes almost never repeat across a scroll
   (REVIEW §5). Scroll-back is instead served by a **document-space canvas per window that
   both ends track**: the host answers a scroll-back with history copy-rects into that canvas
   and only sends tiles for content never seen, while the client draws from its canvas
   *before* the host answers and reconciles on mismatch with the same rule as scroll
   prediction. Consistency model: optimistic references from the host plus a client "miss"
   message, since a 256 GB host and an iPhone will evict differently; acks are unnecessary on
   the reliable stream. Hit rates must be measured before either is promised. Tile types also
   get a one-byte solid-colour and a two-colour form (WebP's floor is 44–95 B for those), and
   photographic tiles refine to visually lossless (HEVC intra tile or JPEG XL d=1, ~3x under
   WebP near-lossless), not to bit-exact.
4. **Refinement**: two different things, never confused. *Settled changes* (a region that was
   moving and stopped, a line that was typed) are refined by 64 px tiles via path 2, so
   scrolled text snaps crisp. *Fresh or invalidated pictures* (stream start, tier change,
   resize, large invalidation) are refined **progressively and whole**, pyramid style, after
   the base lossy frame has been acknowledged and never before: the video ladder climbs rung
   by rung (400×225 → 800×450 → 1600×900 → native), each step a whole frame the client
   crossfades over the previous (~150 ms); then lossless in large blocks (3×3 of the picture,
   then 6×6, then 12×12, centre-first within a level, each block crossfading in, a level
   finishing before the next starts). Granularity shrinks only as budget allows, the pass is
   capped at ~30 % of the link so the interactive stream is never starved, and no block
   boundary is ever visible. The "march of tiny tiles" and the tartan of ARD and Workbench
   are explicitly the failure this rule exists to prevent (phrz, bus, 2026-10-17). The client composites lossless tiles over
   the video texture and invalidates them when a newer video frame covers them.

Photographic tiles (high entropy, lots of colors) that are static still go lossless unless
the budget says otherwise; near-lossless WebP (`-near_lossless 60`) or an HEVC intra tile
at low QP is the fallback.

### 3.3a As built in M2 (2026-10-17)

The three paths above exist; the mechanics that were not obvious from the plan:

- **One encoder, a host-side canvas, a tile mask.** The HEVC session stays full-frame (a fixed
  size keeps temporal prediction alive and the hardware does not care about skip blocks). Dirty
  tiles classified as motion are copied into a native-size BGRA canvas, the canvas is encoded,
  and the datagram header carries the native rect the frame updates plus a bit per 64-px tile of
  that rect in the payload. The client only takes masked tiles from the decoded picture, so
  crisp lossless tiles elsewhere are never degraded by a video frame, and a keyframe masks out
  every tile the client already has pixel-exact. Lower ladder rungs scale the canvas through
  `VTPixelTransferSession` into a smaller encoder; the client upscales with MetalFX before
  taking tiles.
- **Client canvas.** The compositor keeps one native BGRA texture; video tiles, lossless tiles
  and copy-rects write into it in arrival order (one Metal command queue, so ordering is free).
  "Invalidate the overlay where video covers it" falls out of this for nothing.
- **Dirty tracking.** SCK `dirtyRects` → 64-px tiles → a CPU diff against the previous capture
  with ±4/channel tolerance (invisible whole-screen flickers and glyph re-renders otherwise turn
  into a video frame plus a full lossless refinement pass) → the exact changed box inside each
  tile. Sparse updates send that box: a typed glyph is ~500 B, a caret blink ~250 B at native
  scale. Near-lossless is used only above 4096 colours, because downscaled text already exceeds
  256 and has to stay exact.
- **Copy-rects.** Window drags come from the window list (frame deltas between captures,
  verified against the pixels, refined ±8 px by a patch search because the list lags the
  composited pixels by a few ms); scrolls from a line-profile correlation (sum of absolute
  differences over every candidate shift, then per-tile verification with tolerance 12) over
  the Accessibility scroll area under the pointer, the rect learned from an earlier detection,
  or the dirty bounding box. Exact row hashing never fired on a real scroll: SCK's downscale
  leaves ±1–3 levels between a moved pixel and its original.
- **Prediction epochs.** Every input message carries a client sequence number; every pixel
  update from the host (video header, tile batch, copy-rect) echoes the last input injected at
  least 40 ms before its capture. The client's predictor consumes host copy-rects FIFO per
  window and retires a prediction when an update that reflects its input touches its rect
  without a copy-rect having matched it (mismatch → predictions for that window are tracked
  but not shown until one is confirmed again, or 2 s pass). Displayed picture = confirmed
  canvas + unconfirmed displacements, drawn at present time.
- **Rate control.** The controller sees one-way delay (receiver clock minus host send clock,
  offset-free after subtracting the windowed minimum) from every video and tile ack, and
  delivery rate from datagram-train dispersion. On the tailnet the dispersion reads the physical
  path (20–100 Mbps), not the ~1–2 Mbps that actually congests, so in practice the delay signal
  does the work: ×0.85 per RTT above 60 ms of queue, +8 %/s below 25 ms, ×0.8 on loss, floor
  150 kbps, ceiling the viewer's cap. Tiles may use 45 % of the target while video is active
  (90 % otherwise); video gets the target minus what tiles actually used.

**Three standing rules (phrz, 2026-10-17).**
*Change beats refinement; change near the input beats everything.* Observed failure on a 400 ms
cellular link: the viewer refined the static login screen centre-out while the password field
being typed into never updated. Scheduler order, strict and per frame in every tier: newly
changed pixels in the focused element or near the last input event; all other changed pixels;
copy-rects and the lossy first frame of newly visible regions; refinement of unchanged areas
on leftover budget only, yielding the moment new dirt appears.
*Lossy first, always.* A fresh picture, in any tier including Extreme, arrives as one whole
lossy frame within about a second at the current rate (a tiny HEVC keyframe at a low rung or a
quarter-resolution lossy still, MetalFX-upscaled) and then sharpens centre-first with lossless
tiles. Building a picture tile by tile from nothing is a bug, not a tier policy.
*Host load is cheap, wire bytes are not.* Hosts are Apple silicon desktops on mains power, so
the host spends CPU and GPU freely for wire efficiency: higher WebP effort, both grid and
content-box hashes per residual region with the cheaper reference set sent, copy-rect as a
third candidate, GPU diff inside dirty rects, wide copy-rect search. One host-pressure signal
(load relative to core count, thermal state, the host's own encode and tile latency) scales
that effort down when the host is genuinely busy, for example under a large AI job, and the
current effort level is visible in the stats.

**Foveated two-layer mode (phrz, 2026-10-17).** On constrained and extreme links quality is a
function of distance to the input locus (pointer, caret, focused element), the same locus the
scheduler rule uses. Two layers rather than per-region QP, which VideoToolbox's low-latency
mode does not offer: a *base layer*, the whole screen as one low HEVC rung (half or quarter
resolution, MetalFX-upscaled) so a complete picture always exists; and a *fovea*, a generous
window (about a third of the screen, so pointer lag and attention stay inside it) carried as
native-resolution tiles and copy-rects at top priority, or as a second small HEVC stream while
it is in motion, following the pointer smoothly. The client composites the fovea over the
upscaled base with a feathered edge. In Extreme, far-field text may be sent luma-only first
and receive chroma later: text is legible in luma and it halves the bytes. On Local and Normal
tiers the fovea covers the screen and the mode is inert.

### 3.3b As built on 2026-10-17 (after the adversarial review and phrz's bus sessions)

- **Lossy-first, never a tile march.** Every stream, resize and tier downgrade starts on a new
  tiny ladder rung (1/8 native, ~400×225, a 3–4 KB keyframe), upscaled on the client. Nothing
  from the refinement queue goes out until the viewer has acked that base; the ladder then climbs
  rung by rung, each step a whole-frame keyframe sent as soon as the previous one is acked and the
  target affords the next rung (masked-out crisp tiles are flattened to their mean colour first);
  then lossless lands in large centre-first blocks sized to ~1 s of a 30 % refinement budget, one
  in flight. Progressive steps and refinement blocks crossfade in over 150 ms on the client.
  64-px tiles are strictly for changes. Extreme is video-minimal on the tiny rung (5 fps), not
  video-off.
- **Scheduler, every tier.** (1) changed pixels within ~200 px of the last input event go at once
  on a second, interactive QUIC stream regardless of budget; (2) other changed pixels on budget;
  (3) copy-rects on the interactive stream; (4) refinement only on leftover budget, yielding
  150 ms after real change (three tiles or more, not a caret blink), ≤ 300 ms of link in flight.
  The client drops a tile older than the capture it already holds, so a refinement queued before
  an interactive update of the same tile cannot overwrite it.
- **Foveated two-layer mode** on Constrained/Extreme: a fovea of about a third of the screen
  around the input locus takes changed pixels as native tiles ahead of video while the budget
  holds, refinement orders by distance to the locus, and ground a moving fovea newly covers is
  refined first. The ladder's low rung is the base layer. Inert on Local/Normal.
- **Loss.** Frames are delivered in sequence order (a hole holds its dependents), missing fragments
  are NACKed 30 ms after the gap and resent from a 2 s ring on the host, single losses per group
  of 8 are rebuilt from XOR parity (always on key/recovery frames, on every frame above 0.5 % loss),
  and a frame is given up only after ~2.5 RTT; keyframe recovery is the last resort. Every frame's
  datagrams are paced over its interval at 1.25x the video budget.
- **Tiers** classify on min-RTT, loss (after 30 samples) and the controller's delay-limited
  target when the link rather than the cap holds it down; dispersion capacity reads the physical
  path and is not used. Hysteresis 2 s down, 10 s up.
- **Host effort.** Load per core, thermal state and the streamer's own capture time give
  full/reduced/minimal, which sets WebP effort, copy-rect search range, drag refinement radius and
  whether exact changed boxes are computed. Hosts are desktops on mains power; CPU is spent freely
  unless genuinely busy.
- **Wire.** Window list as coalesced deltas at ≤ 10 Hz (full list on start and every 10 s;
  control bytes are counted); solid-colour tiles are 4 bytes; every input message carries a
  sequence number and a `scripted` flag.
- **Safety.** Scripted (measurement) input is refused by the host while the console is locked;
  the host publishes console lock state and the frontmost app/window once a second; the scenario
  runner injects nothing until the console is unlocked, the bench is frontmost and the picture
  shows the bench's caption band.
- **Viewer.** Reconnects forever (1, 2, 4, 8, then 15 s) keeping the last picture, re-requests the
  stream; `--observe` shows the picture without forwarding input; QUIC idle timeout 10 s.

### 3.3c As built in M2.5 (2026-10-17, resilience on droppy links)

The §4a bar, implemented on loopback (measurements in §6 "M2.5 (loopback)"):

- **Session resume.** `Welcome` carries a 32-byte resume token; a reconnecting viewer presents it in
  `Hello` and still authenticates in full. When a control stream ends, the host *suspends* its
  streamer instead of stopping it: capture and timers stop, everything else stays (tile tracker and
  its crisp map, rate controller target, tier and rung, encoder, frame/tile/input sequence numbers,
  the last frame sent) for five minutes. Tile messages that were unacked at the cut have their rects
  queued for a lossless resend; unacked video frames are forgotten. A claim of the token moves the
  streamer to the new connection (also away from an old connection the host has not yet noticed is
  dead), the viewer re-sends its stream request, and `resume` restarts capture with the first frame
  forced fully dirty so the diff against the last frame finds whatever changed during the gap, sends
  a keyframe masked to the tiles the viewer does not hold crisp, re-publishes the window list and
  cursor, and keeps the ladder rung. The viewer keeps its canvas and predictor across the gap; a
  same-size `reset` (a genuinely new session, e.g. a restarted host) keeps the pixels too, until the
  first keyframe replaces them (review M11), and resets the assembler (M4). A killed host has no
  state to resume: the viewer gets a fresh stream, no re-pairing.
- **Reconnect policy.** The viewer never dead-ends: backoff 1, 2, 4, 8, 15 s, but while the session is
  resumable it dials every second with a 4 s connect timeout, because the bar is "back within 2 s of
  the path returning" and QUIC's own Initial retransmits back off too slowly to meet it. A stall
  watchdog redials after 12 s without any packet from the host (resume makes a wrong redial cheap:
  one handshake and one masked keyframe); Network.framework's viability / better-path callbacks
  redial at once when the path changes under a stalled connection. Each connection is closed on
  exit and its receive loops are generation-tagged (M5).
- **Idle and keepalive.** QUIC idle timeout 45 s on both ends, so a 30 s outage closes nothing
  (an 8 s black hole survives without even a reconnect). The viewer's keepalive is one 32-byte
  datagram ping per 10 s; the host echoes it with its clock, which also gives RTT, loss and the clock
  offset. Host status goes on change (and every 10 s), not every second.
- **Loss, video.** XOR parity on every frame of two or more datagrams (group 8, group 4 above 2 %
  measured fragment loss); fragment NACKs ask only for indices below the highest received until the
  tail is overdue (review H5); a short sequence gap gets whole-frame NACKs for every missing frame in
  one round trip, a gap of more than 8 frames is reported as a burst so the host sends a recovery
  keyframe at once instead of after a timeout; a complete recovery frame drops the holes before it.
  The viewer reports per frame how many fragments needed parity or a NACK; the host's *fragment*
  loss rate sizes parity, while the tier reads only the loss the recovery layer could not hide (frames
  given up): 5 % raw loss repaired at 30 fps is not an Extreme link. Datagrams are paced from the rate
  (H6) on their own queue, resends queue behind the frame in flight, and a paced frame contributes
  no delay or dispersion sample (pacing time is ours, not the link's); a frame that needed recovery
  contributes none either (a NACK round trip is not queuing delay). Stale-frame purging waits for the
  pacer plus the viewer's own give-up time (H3), the fresh-picture climb and the keyframe demotion
  share one affordability test (H4), the fps-shortfall ladder compares with the cap the host applied
  and only when budget held frames back (H7), parity rebuilds a missing non-last fragment at full size
  (H1), and the frame sequence is monotonic across streamers of one host process (M4).
- **Loss, tiles and copy-rects: kept on the reliable streams.** Measured on loopback with 5 % loss
  injected on the datagram path, video recovers every loss in under a frame interval (parity) or one
  RTT plus 30 ms (NACK), which is exactly what QUIC's own per-stream retransmission gives a lost tile
  packet; the interactive and refinement streams are already separate so a loss stalls only its own
  class. Copy-rects are order-dependent and not idempotent, so a datagram variant would need its own
  ordering layer against the tiles that touch the same pixels. Parity would only buy anything where a
  round trip is itself a freeze (the Extreme tier's 1 s RTTs), and that is where §3.9 item 6 puts it.
  Decision: stream, revisit for Extreme with the dummynet rig.
- **Input.** Datagrams with redundancy (`InputPacket`): the latest pointer state and every unacked
  discrete event (keys, buttons, scrolls, modifier changes) in each packet, oldest first; the host
  applies each event once in sequence order and acks the highest event and pointer sequence; the
  viewer retransmits with backoff until acked, caps the queue at 512 events (shown in the overlay),
  and after 10 s unacked holds the keystrokes for a decision: ⌃⌥⌘↩ sends them, ⌃⌥⌘⌫ drops them.
  Scripted and headless runs flush automatically. `MIRAGE_INPUT_SINK=/path` makes the host record
  every input it would inject to a file and inject nothing; the input-integrity scenario refuses to
  run against a host that is not in that mode, and the scenario runner re-checks its guards before
  every burst and no longer ends with ⌘A+⌫ (review M8, M9).
- **Motion first, refinement frozen (field fix, 2026-10-18).** phrz dragging windows against
  mac-daddy at 800 kbps saw a slideshow: refinement took 65–85 % of the budget during the drag
  (`refine 512–670 kbps`, a 1003-tile backlog) and video starved to ~2 fps. Now: while motion is
  sustained (classified video, copy-rects, or a drag/scroll/press on the input stream in the last
  300 ms) refinement sends nothing and its queue is frozen, including the fresh picture's blocks;
  only the interactive tile bytes (changed pixels at the locus, copy-rects) are reserved from the
  target, so video has the rest; refinement resumes 300 ms after the motion stops, locus first. A
  pending tile that moves again is dropped and re-queued (its place in the oldest-first order is
  forfeited), and a backlog above 40 % of the screen is refined as large locus-first blocks, one in
  flight, not as a tile march. The host publishes a dragged window's frame as the pixels verified
  it (one frame per move, both axes), where the window list reports a diagonal move axis by axis.
- **Drag prediction reworked.** The viewer no longer queues one prediction per pointer move for
  the host's copy-rects to consume one by one. A drag is one state: the window is displaced from
  the host's last confirmed frame by (pointer now − pointer at that confirmation); a host copy-rect
  moves the confirmed frame by its exact (dx, dy), any other host update that reflects input k
  moves it to where the pointer was at k. A copy-rect confirms when the host's cumulative
  displacement since mouse-down has moved toward the pointer and not past it (per axis, 8 px), so
  per-axis and coalesced host updates confirm; a disagreement hides the displacement for 2 s and
  re-syncs to the host. Measured on loopback with the bench dragging itself (`--drift`, nothing
  injected, 1512×982 stream so the 6×3 pt moves are integer pixels, five 0.8 s bursts per run):
  video frames during the bursts went from 7.9 fps median (4–13) to 9.5–12.5 fps (7–21) at an
  800 kbps cap with the host before/after this change; at 2000 kbps 19–23 fps either way (the
  budget is not the constraint there); ~24 copy-rects per burst in every run; **0 stale tiles
  committed** into a region that had moved since their capture (6–8 discarded per run, the host
  dropped 1–15 encoded blocks per 5 s as stale); time-to-crisp after a burst ~5.0 s at both caps,
  which is the refinement pacing (blocks of ~1 s of 30 % of the tile budget, one in flight), the
  same figure the M2 Shibuya drags measured, and the next thing to tune. The field case (a
  3200×1800 stream, refinement at 65–85 % of the budget) is the one the freeze is for; loopback
  at 1512×982 only shows the direction.
- **Stale blocks never committed (field fix, 2026-10-18).** phrz: the dragged window first follows
  the pointer, then "shatters into blocks". Those were refinement tiles captured before a move and
  applied after it. Every pixel update already carries its host capture sequence; the viewer now
  keeps, per 64-px tile, the newest capture that touched it from tiles, copy-rects *and* video, and
  applies a tile message only if no tile under its rect holds a newer capture (review M2); a
  crossfade still running under a copy-rect, a video frame or a direct tile is dropped, never
  committed (review M1); and the host drops refinement it has already encoded when the region
  changed meanwhile (`stale-dropped` in the stats line). `staleTilesCommitted` in the viewer's
  stats must read 0; it did in every loopback drag run.
- **Path migration.** Not testable here (one interface). Network.framework decides whether a QUIC
  connection migrates; what Mirage does is react to its viability / better-path callbacks and to a
  stall by redialing with the resume token, so an IP change costs at most a handshake and a masked
  keyframe. Untested.
- **Test rig.** `MIRAGE_TEST_LOSS` / `MIRAGE_TEST_BURST_MS` / `MIRAGE_TEST_BURST_EVERY_S` /
  `MIRAGE_TEST_SEED` inject loss in the host's video datagram path and the viewer's input datagram
  path; `scripts/resilience-test.sh` runs the loopback scenarios (host in input-sink mode, the test
  bench's `--motion` window as the moving picture) and asserts the §4a rows; its last section lists
  the `dnctl`/`pfctl` profiles and the bus-trace replay for the conditions it cannot create itself.

### 3.4 Rate control and adaptation

- Client sends receive timestamps for every packet; host runs a GCC/BBR-style **delivery-rate
  and queuing-delay estimator** (inter-arrival jitter trend = congestion onset), independent
  of QUIC's own congestion controller, and targets ~70% of estimated capacity.
- Budget is split per frame: input/control first, tiles second, video gets the remainder.
  `tile_scheduler`: oldest-dirty-first, capped bytes per frame; leftover tiles carry over.
- Video frame rate is a *result*, not a setting: one frame in flight, next capture encoded
  when the previous is acked or budget allows. At 1 Mbps that is ~5–10 fps for full-screen
  motion and 30–60 fps for a small moving region.
- Resolution ladder per layer: 2x → 1.5x → 1x → 0.75x, driven by sustained bitrate shortfall,
  with lossless refinement always at the current scale.
- Target budgets at 1 Mbps: idle 0 kbps; typing <100 kbps; document scroll ~700 kbps video
  then ~1 s of refinement; video playback ~700 kbps at reduced scale.

### 3.5 Latency hiding ("GUI mosh"), in order of payoff/risk

1. **Local cursor** (ship now). SCK `showsCursor=false`; host streams cursor shape + hotspot
   on change (`NSCursor.currentSystem`, same trick as Astropad). Client draws it at the local
   pointer. Zero perceived mouse latency.
2. **Local window management** (Unified mode). Drag, resize, focus, minimize and z-order
   happen on the client's own `NSWindow` instantly; the host applies them through AX
   (`kAXPositionAttribute`, `kAXSizeAttribute`, `AXRaise`) and the layer catches up. Old
   pixels are stretched/clipped until new frames arrive. This is most of what makes Parallels
   Coherence feel local, and ARD cannot do it at all.
3. **Scroll prediction** (required, not an experiment). Rule: *the client never waits for the
   wire to move pixels it already has.* On the wheel event the client shifts the pixels inside
   the scrollable rect by the delta at once, showing a neutral band where new content will land,
   and only then sends the input. The host detects the real shift and answers with a
   **copy-rect** (VNC CopyRect / RDP style: "move this rect by (0,-40)") plus the newly exposed
   strip as lossless tiles, or video if the region is churning. On arrival the client
   reconciles: same offset, nothing visible happens; different offset (end of document, snap,
   nested scroll view), one small correction and a mosh-style confidence back-off for that
   window until predictions match again. The rect to shift comes from the Accessibility
   scroll-area frame under the pointer for native apps; for browsers and Electron, which expose
   nothing, the window content area minus title bar. Copy-rect has no encoder search-range
   cliff, so fast flicks stay cheap and sharp.
4. **Typed-text prediction** (experiment, the mosh part). Host tracks the AX focused element.
   For text roles it ships role, frame, caret bounds (`kAXBoundsForRangeParameterizedAttribute`
   at the insertion point) and the font from
   `kAXAttributedStringForRangeParameterizedAttribute`. On a printable keypress the client
   draws the glyph at the predicted caret position with the reported font in an overlay,
   underlined like mosh, advances the caret by the measured glyph width, and clears the
   prediction when the host reports the AX value change containing it (or after the covering
   tile arrives). AppKit/SwiftUI text views, WebKit and Chromium (Electron) all expose these
   attributes; terminals vary. Covers roughly the 60% you estimated; falls back to normal
   behavior everywhere else.
   For apps that expose nothing through Accessibility (Chromium, Electron, measured in
   experiments/probes), the host finds the caret itself: a temporal diff spots the blinking
   1–2 px bar inside the focused window, Apple's Vision text-rectangle detection (ANE, a few
   ms) gives the line's baseline and height, and glyph advances are learned per field by
   measuring how far the caret moves after each confirmed keystroke. The host ships the caret
   rect as metadata like the cursor shape. No language or vision-language model anywhere in
   this loop; if a learned detector is ever needed it is a sub-millisecond Core ML keypoint
   CNN trained on synthetic renders. Scroll rects for such apps are learned from the first
   observed copy-rect shift per window.
5. Hover/press feedback: not generalizable; skipped on purpose.

### 3.6 Input

Host posts events at the HID tap (`CGEvent.post(tap: .cghidEventTap)`), with host-side
coalescing and an absolute-position model (client sends layer-relative coordinates; host
maps through the current window frame so a window that moved mid-flight still gets the
click). Modifier state is mirrored explicitly. Keyboard goes as key codes + modifiers + the
resolved characters so dead keys and IMEs behave. Trackpad gestures: pinch/rotate/momentum
forwarded as `CGEvent` gesture events where possible. iPad: Pencil → tablet events with
pressure/tilt (Astropad's home turf); touch → pointer with a right-click long-press; hardware
keyboard and trackpad pass straight through.

### 3.7 Clients

- **macOS Viewer**: SwiftUI shell; Desktop mode in one window, Unified mode as per-window
  `NSWindow`s plus an optional remote menu bar strip. Metal presenter, HDR/EDR pass-through
  later.
- **iPadOS/iOS**: same `RemoteCore` and presenter; Desktop mode first, Stage-Manager-style
  windows later. External display support for iPad.
- Clipboard sync, drag-and-drop file transfer over a dedicated QUIC stream, and audio
  (SCK audio → Opus via `AudioConverter` → datagrams) after the pixel path is solid.

### 3.7a Permissions and first run (requirement from phrz, 2026-10-17)

The host's permission experience must feel like an Apple app's, and it must ask for the
minimum. Inventory of what macOS can demand and what Mirage actually needs:

| Permission | Host | Viewer (macOS) | Viewer (iOS) | Why / how avoided |
|---|---|---|---|---|
| Screen & System Audio Recording | **required** | – | – | capture; unavoidable |
| Accessibility | **required** | – | – | CGEvent input injection, AX window management and native menus; one grant covers all |
| Monthly "bypass the system private window picker" reminder (macOS 15+) | once per month unless deferred | – | – | a consequence of SCK without the content picker; the picker is a per-session UI and unusable for a headless host, so accept the reminder and explain it in-app |
| Local Network | avoided | avoided | avoided | no Bonjour; tailnet names and addresses only |
| Automation (Apple Events) | avoided | – | – | nothing is scripted |
| Input Monitoring | avoided | – | – | we post events, never read them |
| Notifications | avoided | avoided | avoided | not used |
| Camera, microphone, contacts, files | never | never | never | |

So the host needs exactly two toggles, the viewers need none. Rules:

- The host ships as a signed, notarized `.app` with a LaunchAgent helper, not a bare binary,
  so it appears in System Settings by name and icon and grants survive updates (Developer ID
  signing; M1 already signs with an Apple Development identity for this reason).
- First run is a single assistant window: what Mirage is, the two toggles with one button each
  that deep-links straight to the right pane
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and
  `…?Privacy_Accessibility`), live checkmarks as each is granted, then "Start". No ⌘⇧G, no
  hunting for a path, no restart dance: the host polls `CGPreflightScreenCaptureAccess` and
  `AXIsProcessTrusted` and begins serving the moment both flip.
- Pairing lives in the same window: show the 6-digit code there as well as in `miraged pair`.
- Nothing prompts at launch after first run. If a grant is later revoked, the viewer gets a
  specific, human message (already done for Screen Recording in M1) rather than a dead stream.

### 3.8 Native chrome: menu bar, dock, status items, notifications

The host's menu bar and dock are not streamed as pixels. They are read as data through
Accessibility and NSWorkspace and rendered natively on the client, which is both the
"Apple designed it" look and a latency win: browsing a menu happens locally with no round
trip, only the final selection travels.

- **Menu bar.** When a remote window is frontmost, the viewer app owns the local menu bar
  anyway, so it fills it with the remote app's menus: Apple menu stays local, then the host
  app's menus from `AXMenuBar`, items fetched lazily on open, shortcuts forwarded. Click a
  local window and the local menus return. There is never a second strip, because macOS
  already gives the menu bar to whoever is focused. The purple screen-sharing outline goes
  around the remote window itself, where macOS already draws it for shared content.
- **Dock.** A native remote dock built from the host's running apps and windows, icons
  cached by bundle id after first transfer. It avoids the local dock's edge (read from
  `NSScreen.visibleFrame` and the dock's auto-hide state) or collapses into a small app
  switcher in the menu bar when space is tight. Activating an app raises it on the host and
  brings its windows up locally.
- **Status items.** Different animal: tiny windows owned by each app, opening custom popover
  windows rather than real menus, so Accessibility gives positions and names but not
  reliably contents. Plan: capture all windows at the status-item level as one thin SCK
  layer (cheap after tile diffing), filter out system-owned items (Control Center, clock,
  Wi-Fi, battery describe the host, not you) by default, show third-party items in a
  purple-outlined strip that drops down under the right end of the local menu bar while a
  remote window is focused, or behind a single status item of our own that expands on
  click. Clicking an icon sends a click to its host coordinates; whatever opens arrives
  through the masked desktop stream and is translated to sit under the right local icon.
  Real menus get the native treatment as a bonus.
- **Notifications.** Notification banners are windows at a known level too, so the same
  trick yields a remote notification layer: an agent finishing on the host shows a
  purple-outlined banner in a corner here, even with no remote window open.
- **Fallback.** Apps with broken Accessibility fall back to masked pixels, same as the rest
  of the desktop. Desktop mode in a full-screen Space needs none of this.

### 3.9 Link tiers and Extreme mode (requirement from phrz, 2026-10-17)

Goal: the only remote desktop that still works on the world's worst links (Antarctic
satellite, Iridium, congested rural cellular: 64–256 kbps, 600–1500 ms RTT, 1–10 % loss,
bufferbloat), without making a LAN session one bit worse. One code path, four tiers, chosen
transparently by the rate controller's own estimates with hysteresis so it never flaps, and
shown to the user only as a small badge next to the purple outline.

| Tier | Engages when | What changes |
|---|---|---|
| Local | >50 Mbps, <10 ms | 60–120 fps video at near-lossless QP, 2x, no ladder, lossless refresh within one frame, audio on |
| Normal | 2–50 Mbps, <100 ms | the M2 defaults |
| Constrained | 0.5–2 Mbps or 100–400 ms | the design's main target (this Japan link): tiles for sparse change, video for motion, ladder, prediction |
| Extreme | <0.5 Mbps or >400 ms RTT or >2 % loss | everything below |

Corrections from REVIEW §5, accepted: tier selection must not rely on packet-dispersion
capacity estimates (on this tailnet they read 20–100 Mbps for a 1 Mbps path); use the
controller's delay-limited target rate as the proxy. "Video off" in Extreme is wrong at face
value: 16-colour tiles of a half-resolution screen are ~45 KB, i.e. 5.6 s per frame at
64 kbps, so Extreme keeps a tiny HEVC rung (1–2 KB per 320×240 frame) for motion and uses
tiles for everything else. FEC and mosh-style redundancy only mean something on datagram
paths: input moves to datagrams with redundancy (latest pointer state + unacked key sequence
in every packet) in **every** tier, and FEC applies to the video datagrams and to a datagram
variant of the tile path, not to the reliable QUIC stream.

Extreme mode, in order of payoff:

1. **Pixels become confirmation, not the primary channel.** Local prediction (cursor, scroll,
   drag, caret echo, native menus and dock) runs first; the stream catches up behind it.
   Standard controls get local pressed/hover states from their Accessibility roles and frames.
2. **Video nearly off.** Motion goes through a tiny HEVC rung (1–2 KB per 320×240 frame at
   2–5 fps, MetalFX-upscaled); everything else is lossless or paletted tiles (16 colours for
   UI cuts a text tile 2–3x); full-colour, full-resolution refinement only for the focused
   window.
3. **Spotlight capture.** Only the focused window (plus menus) is streamed; other windows are
   frozen snapshots with a dim overlay, refreshed on focus.
4. **Host-side simplification while in this tier**: ask macOS to reduce transparency and
   motion for the session (restored on exit), since blur and animation are the most
   expensive pixels on screen and carry no information.
5. **Text mode for text apps.** Terminals, editors and text views expose their text through
   Accessibility; send the text runs and render them locally with the same font, which both
   ends have. At 64 kbps this is the difference between usable and not; it is also the only
   path where a keystroke costs bytes of text rather than bytes of pixels.
6. **Loss is handled by redundancy, not retransmission.** At 1 s RTT a retransmit is a
   second of frozen screen: forward error correction on tiles and video (RaptorQ or simple
   XOR parity per frame, rate chosen from measured loss), input events repeated in every
   outgoing packet until acked (mosh-style state sync: the latest pointer position and the
   unacked keystroke sequence, idempotent on the host).
7. **Session survives anything.** QUIC connection migration plus our own resume token: sleep,
   IP change, a 30 s outage all come back to the same session with the client's last frame
   still on screen and its prediction state intact.
8. **Audio off**, or a 6 kbps Opus voice band if explicitly wanted.

Testing: use the Japan link while we have it, and reproduce Antarctica on demand with
macOS's own link conditioner (`dnctl`/`pfctl` pipes: bandwidth, delay, loss, queue size) in a
script, so every tier is a repeatable CI-style run against loopback or mac-daddy.

## 4. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Package skeleton, QUIC link, `remotectl pair` with SPAKE2+, mutual-cert sessions | MacBook ↔ mac-daddy handshake over tailnet, RTT graph in the viewer |
| M1 | Desktop mode: SCK → HEVC low-latency → datagrams → VT decode → Metal; input; local cursor | Side-by-side on this Japan link it beats ARD and feels at least as good as Workbench |
| M2 | Hybrid codec: tile classifier, lossless tiles, refinement, rate controller, ladder | Typing stays <100 kbps and text is always crisp within 1 s of motion stopping |
| M3 | Unified mode: app layers, window metadata, client `NSWindow`s, local window management | Drag a remote window at 220 ms RTT without noticing |
| M4 | iPad + iPhone viewer | Pencil and keyboard usable against mac-daddy |
| M5 | Prediction: scroll and typed text overlays; audio; clipboard; files | Typing in Xcode/VS Code/Safari over 1 Mbps feels local |

### 4a. Resilience bar (phrz, 2026-10-17: "must be more tolerant of droppy connections")

Bitrate adaptation is in place (delay-based controller, tiers). Resilience to drops is a
separate axis and gets its own acceptance test, run with the macOS link conditioner
(`dnctl`/`pfctl`: loss, outage, delay) and on real cellular links:

| Requirement | Pass condition | M2.5 status (loopback, §6) |
|---|---|---|
| Outage survival | A 30 s total outage returns to the same session with the last picture kept, cache and prediction state intact, no re-pairing, within 2 s of the path returning | **Pass**: host frozen 30 s, same session resumed, picture back 0.23 s after the path returned |
| IP change | A cellular handoff or Wi-Fi→cellular switch is a QUIC connection migration, not a reconnect: no visible interruption beyond the frames lost in transit | **Untested** (one interface here); implemented as path-change → redial with the resume token |
| Reconnect policy | The viewer never dead-ends: exponential backoff 1→15 s forever, "reconnecting…" badge with attempt count, automatic stream resume | **Pass**: host killed and restarted 30 s later, 5 attempts, no re-pairing, fresh stream 2.2 s after the host returned |
| Loss | 5 % random loss and 2 s loss bursts: no freeze longer than 500 ms; recovery by fragment NACK and parity, keyframe only as last resort | **Pass** (datagram path): 5 % → longest video gap 142 ms, 0 frames given up; 2 s bursts → video back 134–309 ms after each burst ends. Reliable-stream loss needs the dummynet rig (sudo, documented) |
| Input integrity | Input is never lost or duplicated: latest pointer state wins, keystrokes queue with a visible cap during a gap, user chooses flush or drop after a long gap | **Pass**: 1000 keystrokes under 5 % loss each way plus 2 s bursts, every event applied once, in order |
| Idle timeout | Host and client idle timeouts long enough that a 30 s outage is not a close; keepalives sparse (one small datagram per 10 s) | **Pass**: 45 s idle timeout both ends, an 8 s black hole survives without a reconnect, 5 pings in 42 s |

This is milestone work in its own right (M2.5 or the first part of M3), not a side effect of
the codec. Built 2026-10-17 as M2.5 (§3.3c); loopback measurements in §6.

## 5. Open questions to settle by measurement, not debate

- HEVC low-latency mode lacks `ConstantBitRate`; verify `DataRateLimits` holds frame sizes
  tightly enough at 1 Mbps, else fall back to normal mode with `MaxFrameDelayCount=0`.
- Cost of N simultaneous `SCStream`s (one per app layer) on the host; may need a single
  display stream plus per-app masks derived from window geometry instead.
- Whether `dirtyRects` from SCK is tight enough, or the GPU diff pass is needed from M2.
- SPAKE2+ in Swift: implement on CryptoKit P-256 primitives (small, RFC-specified) vs. vendor.
- Headless operation on mac-daddy: real displays today; a virtual display (CGVirtualDisplay,
  private) only if you ever want a client-shaped desktop without a monitor attached.

## 6. Status

### M0 (2026-10-16)

Built and measured between this MacBook (Japan, rural link) and mac-daddy (Dallas):

| Measurement | Value |
|---|---|
| QUIC handshake | 265–356 ms |
| Pair + mutual auth round trips | 326–488 ms |
| Stream RTT min / mean / p95 | 158 / 205 / 245 ms |
| Datagram RTT min / mean / p95 | 158 / 185 / 243 ms |
| Loss over ~80 pings | 0% |

Network.framework findings that cost time, recorded so they are not rediscovered:

- A client `NWConnectionGroup` over `NWMultiplexGroup` **never dials until its
  `newConnectionHandler` is set**; `extract()` returns nil until the group is ready.
- A QUIC `NWListener` fails with `EINVAL` if **both** `newConnectionHandler` and
  `newConnectionGroupHandler` are set. Use only the group handler.
- The per-stream `isDatagram` option is not visible on the receiving side; the datagram flow
  is identified by a magic first byte (`0xD7`) instead.
- Groups report a transient `.waiting(Network is down)` before `.ready`; treat it as benign.
- `SecPKCS12Import` with `kSecImportToMemoryOnly` (macOS 15+) gives a `SecIdentity` without
  touching the keychain; the P12 is produced once by the system LibreSSL `openssl`.
- The Command Line Tools' SwiftPM manifest API is broken on this machine; build with
  `DEVELOPER_DIR` pointing at Xcode.

### M1 (2026-10-16, Desktop mode)

What was built: SCK display stream (scaled by SCK to the viewer's pixel size, cursor hidden,
frames only on change) → hardware HEVC in low-latency mode (`AllowFrameReordering=false`,
`EnableLTR`, `MaxKeyFrameInterval` 2²⁰, `DataRateLimits` = one second of the target bitrate,
`ExpectedFrameRate` = bitrate / 6 KB clamped to [5, 30]) → ≤1200-byte QUIC datagrams with a
23-byte header (seq, fragment i/n, flags, capture clock, frame size) → reassembly →
`VTDecompressionSession` → `AVSampleBufferDisplayLayer`. Host cursor shape + hotspot travel on
the control stream and are drawn at the local pointer; mouse, scroll and keys travel back as
JSON on the same stream and are posted with `CGEvent` at the HID tap. Pacing is a token bucket
at the target bitrate plus an in-flight cap of bitrate × (sRTT + 150 ms); SCK frames that do
not fit are dropped, never queued. Loss recovery: the viewer acks every frame; a loss triggers
`ForceLTRRefresh` against acknowledged LTR tokens (keyframe if none), and the viewer skips
decoding until a frame flagged *recovery* arrives.

Measured on the real link. Because mac-daddy's TCC grants were not yet clicked, the link run
was done in the **reverse direction**: `miraged` on this MacBook (M4 Max, Japan, already
permitted) streaming its 1512×982-pt display to the viewer running on mac-daddy (M3 Ultra,
Dallas), launched over SSH with `open … --stats-log`. The direction does not change the
RTT or the bottleneck; the content was a page with a scrolling text column, a spinning box
and a millisecond clock. Stream size 2216×1440 (fitted to the viewer's 1280×720-pt window
at 2x). Steady state over 30–50 s each:

| Target | Delivered | fps | Frame age (capture→decoded, clock-offset corrected) | Decode | Loss |
|---|---|---|---|---|---|
| 800 kbps | 780–900 kbps | 26–32 | 120–150 ms typical, 180–250 ms during RTT spikes | 1.6–3 ms | 0 after the opening keyframe |
| 2000 kbps | 1.94–2.2 Mbps | 28–32 | 117–147 ms | 1.6–2.4 ms | 0 |
| 4000 kbps | 3.7–4.5 Mbps | 25–32 | 122–158 ms | 1.7–2.6 ms | 0 |

A repeatable version of the same run, headless over SSH (no GUI needed on the measuring
machine), 60 s at 800 kbps with the scrolling-text/spinning-box window (97% dirty):

```bash
ssh mac-daddy '~/.local/bin/mirage-viewer phrz-mbp-m4 --headless --duration 60 --bitrate 800 --window 2560x1440 --stats /tmp/m1-800.json'
```

→ 1644 frames, median 30 fps, 829 kbps, frame age median 126 ms / p95 139 ms, decode 2.1 ms,
RTT median 200 ms (min 159), 0 lost. Note the direction: this is the Japan→Dallas uplink
(~4.5 Mbps measured by scp), the opposite of the eventual use; the latency figures are symmetric,
the capacity figure may not be.

**Forward direction (the real one): mac-daddy → this MacBook**, after the TCC grants, same
motion window on mac-daddy's 5K display streamed at 2560×1440, viewer window 1280×720 pt at 2x:

| Run | fps | Delivered | Frame age median / p95 | RTT median | Lost / 60 s | Notes |
|---|---|---|---|---|---|---|
| GUI viewer, 800 kbps | 29 | 801 kbps | 100 / 126 ms | 213 ms | 4 | mouse + keyboard verified (below) |
| GUI viewer, 2000 kbps | 29 | 1969 kbps | 104 / **522** ms | 217 ms | 10 | sRTT spiked to 567 ms, 15 frames in flight: the Dallas→Japan downlink is congested at 2 Mbps even though the uplink carried 4 Mbps cleanly |
| headless, 800 kbps (final build) | 30 | 821 kbps | 102 / 107 ms | 208 ms | 1 | 1578 frames; the one loss recovered in ~2 s via a 97 KB keyframe |

So on this link the usable video rate downstream is ~1 Mbps today, which is exactly the
design point. Frame age in this direction is ~100 ms, i.e. roughly RTT/2, with decode 2.3 ms.

Input, verified end to end with `--headless --probe-input`: the host echoes its real cursor
position on the control stream, and after five injected moves it reported (0.25,0.25) …
(0.5,0.5) exactly as sent; ⌘Space opened Spotlight on mac-daddy (visible in the stream and
as a 28 fps dirty burst in the host log). Esc did not close it because a macOS
"miraged is requesting to bypass the system private window picker" dialog had focus — that
dialog is the macOS 15+ periodic re-confirmation for screen capture; capture keeps running
while it is up, but it needs an *Allow* click on the host.

Loss recovery, measured: a lost frame costs about 2 s of frozen picture at 800 kbps (viewer
skips until the recovery frame, host sends a keyframe, keyframe serialises). Keyframe size is
content-bound: ~18 KB for a mostly flat desktop, 125 KB for a screen of dense text at the
encoder's own choice of QP, 93 KB with the QP floor at 40 (the default now), 61 KB at 45.

Host side at every rate: encode 10 ms per frame, sRTT 195–260 ms as seen through acks, 4–7
frames in flight, delivered bitrate within 2% of target. Frame age of ~125 ms is one-way
delay (~90 ms) + serialization of a 3–4 KB frame + capture/encode/decode (~15 ms); the
~200 ms readings coincide with RTT spikes to 300–500 ms on the ping stream, i.e. the link,
not the pipeline. In loopback the same pipeline shows 9–16 ms frame age, and the infinite
mirror of a viewer looking at its own host shows each recursion level exactly one frame
(33 ms) behind the last — a cheap end-to-end latency check worth keeping.

Quality at 800 kbps: 30 fps of a 2216×1440 frame is ~3.3 KB per frame, so moving text is soft
but legible and snaps crisp within a frame of motion stopping (HEVC spends the saved bits
immediately). At 2 Mbps text in motion is clean. The "frame rate is a result" rule holds: the
encoder's own rate control stayed at the capture ceiling (30 fps) at all three rates on this
content; the token bucket only intervened for the first second (the opening keyframe).

Click-to-pixel is therefore RTT + ~40 ms ≈ 250 ms at 800 kbps on this link — the §0 budget
without the 160 ms serialization term, because frames are 3–8 KB instead of 20 KB.

**ARD comparison: pending a human.** It needs someone at this MacBook with both ARD and the
viewer open on mac-daddy and both machines' TCC grants in place. Procedure, so it is a
five-minute job: on mac-daddy show a millisecond clock (e.g. the `motion.html` page from this
session, or `while true; do date +%T.%N; done` in Terminal at 72 pt); open ARD and the Mirage
viewer side by side here; take local screenshots (`screencapture -x`) and read the two clocks
off each — the difference is the relative latency; compare each to the clock shown by a
third viewer that is known-good (or to the host clock via `ssh mac-daddy date` with the clock
offset from `ntpdate -q`). Record subjective feel for: cursor (Mirage draws it locally so it
should be the obvious win), typing echo, window drag, scroll. Fill in the table below.

| | ARD | Mirage M1 |
|---|---|---|
| Cursor latency | remote-drawn, ~RTT | local, 0 |
| Measured frame age | | 100 ms median at 800 kbps (Dallas→Japan) |
| Typing / drag / scroll feel | | |

Idle and sparse change, same link, 800 kbps target, after adding a dirty-area frame-rate cap
(SCK `dirtyRects`, in output pixels: <0.5% dirty → 5 fps, <3% → 10 fps, <15% → 20 fps,
else the 30 fps ceiling) and a QP floor of 36 on keyframes:

| Content | fps | kbps | Notes |
|---|---|---|---|
| Static desktop | 1 | 13 | SCK delivers nothing until something changes |
| One small spinner (0.1% dirty) | 5 | 70 | was 29 fps / 270 kbps before the cap: low-latency HEVC re-polishes a static picture at any frame rate it is given |
| Scrolling text + spinning box (75% dirty) | 28 | 800 | cap not engaged |
| Opening keyframe, 2216×1440 | — | 17.7 KB | 72–160 KB without the QP floor (0.6–1.6 s on a 1 Mbps link); P-frames restore detail within ~300 ms |

The sparse case is the argument for M2's lossless tiles: 70 kbps for a spinner is still a
whole-frame refresh five times a second.

Platform findings from M1:

- `SCStreamConfiguration` with `width/height` set scales the display on the GPU; requesting
  the viewer's pixel size costs nothing on the host and avoids shipping 5K.
- Low-latency HEVC drops frames itself when `DataRateLimits` would be exceeded
  (`kVTEncodeInfo_FrameDropped`); treat that as a normal skip, not an error — forcing a
  keyframe there starves the link (first version did).
- `MinAllowedFrameQP` can be flipped per frame between encodes in low-latency mode; raising
  it to 36 for keyframes only cuts the opening frame 4–9x. `dirtyRects` from SCK are in the
  configured output pixel size, and a frame with an empty list is delivered only around start.
- Apple Events to third-party apps (`osascript … tell application "Helium"`) trigger a TCC
  Automation prompt per target app; `System Events` was already allowed. Drive test content
  from your own process (`scratch motion.swift`-style window) rather than scripting a browser.
- **LTR refresh does not work as a loss-recovery path the way the docs suggest.** The encoder
  emits `RequireLTRAcknowledgementToken` per frame and accepts `AcknowledgedLTRTokens` +
  `ForceLTRRefresh`, but on the first Dallas→Japan run every refresh frame the viewer received
  after skipping the frames following a loss failed with `kVTVideoDecoderBadDataErr` (-12909),
  and because each failure asked for another refresh the picture stayed frozen for the rest
  of the minute. Recovery is now a keyframe by default (`MIRAGE_LTR=1` re-enables one LTR
  attempt before escalating). Worth revisiting with a decoder that is fed every frame
  (decode-with-errors instead of skip) before concluding the encoder is at fault.
- `MinAllowedFrameQP` changes take effect on the frame *after* the next one, so the QP floor is
  armed one capture before a forced keyframe; a mid-stream keyframe without that was 125 KB
  (107 datagrams) instead of ~18 KB, and a 107-datagram burst is itself the likeliest thing to
  lose on this link.
- `NWConnection.maximumDatagramSize` is 1252 on the tailnet (1280 MTU) and 16336 on loopback;
  1200-byte datagrams fit everywhere.
- A SwiftUI `App` scene opened no window when the executable was launched from a shell
  (bundled or not); an AppKit `NSWindow` with `NSHostingView` works. The viewer still needs a
  bundle (`scripts/make-viewer-app.sh`) for a Dock icon and key-window behaviour.
- TCC identifies CLI tools by code signature. `swift build`'s ad-hoc signature changes every
  build and would reset the host's grants; `scripts/deploy-host.sh` signs `miraged` with the
  Apple Development identity so the designated requirement is stable across rebuilds.
- `NSCursor.currentSystem` works from a LaunchAgent without an `NSApplication`; polling at
  20 Hz and hashing the PNG is cheap and ships every I-beam/arrow change.
- The macOS application firewall auto-allowed the signed `miraged` (no prompt) when mac-daddy
  connected inbound.

**ARD side-by-side (phrz, 2026-10-17 morning, Japan ↔ Dallas, Mirage at 800 kbps):** subjectively
"a hint better" than Apple Remote Desktop on codec decisions alone; window dragging and typing
still reveal the half-world RTT. Expected: those are the two interactions whose latency only
local prediction can hide (DESIGN §3.5), and M1 ships none of it yet except the local cursor.
Both cheats are mode-independent and will apply in Desktop mode too: copy-rect-driven window
dragging and the caret echo overlay are M2/M3 work, not Unified-mode work.

### M2 (2026-10-17, hybrid codec + local prediction)

What was built is in §3.3a; the viewer, host and test bench are described in the README. Measured
on the real link, mac-daddy (Dallas, now a 3200×1800 panel at 2x: the 5K is offline) → this
MacBook (Japan), RTT 160–240 ms, stream 2560×1440 unless noted, headless viewer over the tailnet.

**Full-screen motion (hotel Wi-Fi, 2026-10-17 morning JST).** mac-daddy was at its lock screen for these runs, whose animated wallpaper
changes essentially every tile at 25 fps (the tolerant diff still prunes 84 % of the tiles SCK
flags, because the fades are mostly below ±4). 60 s per run, display held awake by the host:

| Cap | Delivered (video + lossless) | Video fps | Frame age median / p95 | Queue median / p95 | Controller target | Tier / rung | Lost |
|---|---|---|---|---|---|---|---|
| 800 kbps | 460 + 370 kbps | 4 | 113 / 122 ms | 15 / 23 ms | 800 | Constrained / 0 | 0 |
| 2000 kbps | 1050 + 920 kbps | 5 | 114 / 125 ms | 21 / 30 ms | 2000 | Constrained / 0 | 0 |

So at a 2 Mbps cap the link carried ~2 Mbps today with the queue under 30 ms and p95 frame age
125 ms, well inside the 250 ms criterion; the controller backed off only during the opening
burst (queue 101 ms at t = 3 s → target 680 kbps) and then climbed to the cap at 8 %/s. The
M1 run that saw 567 ms sRTT at 2 Mbps had 15 frames in flight; M2 keeps 1–2 (in-flight cap of
one base RTT + 50 ms of the video budget) and backs off on delay, which is the difference. The
dispersion-based capacity estimate reads 40–100 Mbps here (the physical path), so the 70 %
rule never engages on this link; the delay rule does the work. Full-screen photographic motion
at 2560×1440 costs ~25 KB per HEVC frame, hence 4–5 fps at 1 Mbps of video: that is the
ladder's job, and the Constrained tier allows all four rungs (the rung stayed at 0 because the
target was above the 0.18 kbps/kpixel threshold; the wallpaper is not the content the ladder
is tuned for).

A loss at the 2 Mbps cap exposed a recovery bug (fixed): the assembler's late "lost" verdict for
a frame *older* than the recovery keyframe re-armed the viewer's wait, the host rightly ignored
the stale loss, and video froze for 40 s while lossless refinement kept the picture current.
The viewer now ignores such verdicts and the host resends a keyframe when a viewer keeps
skipping frames newer than the last recovery.

**Typing, scrolling, dragging: loopback and host-side facts** (the link runs against the test
bench window need mac-daddy unlocked; see below):

- A typed glyph is one lossless rect of the exact changed box, ~500 B at native scale, a caret
  blink ~250 B (9×40 px); at 6 keys/s that is ~30 kbps plus ~4 kbps of caret. The same glyph
  costs 1.4 KB as a whole 64-px tile and 2.8 KB when the stream is a downscaled copy of the
  display (viewer window smaller than the host display), which is why direct updates send tight
  boxes and why `--scale` ≥ 1 matters for text.
- Scroll bursts of 40 wheel events (30 pt each) through NSTextView: every capture became a
  copy-rect plus the exposed strip as lossless tiles, no video; the viewer's 80 predictions were
  all confirmed by the host's copy-rects, 0 mismatches. Window drags of 6×3 px per 16 ms: 47
  copy-rects per burst, 81 of 90 predictions confirmed, 6 mismatches (the translucent title bar
  and the shadow verify as "changed" at the edges).
- Exact-match detection found nothing on a real scroll: SCK's downscale leaves ±1–3 levels
  between a moved pixel and its original. Line-profile correlation with tolerant verification
  finds the shift (−30 px per wheel event) on every capture.
- Invisible whole-screen flickers (±1–2 levels) turned into a video frame plus a full lossless
  refinement pass (~400 KB) until the tile diff got a ±4 tolerance.

**4G bus, one bar (2026-10-17 ~10:25 JST, MacBook on a moving bus far from towns; ping RTT
414–451 ms).** 60 s idle at an 800 kbps cap against the unlocked, quiet desktop. The tier went
*Extreme* after its 2 s dwell (min-RTT > 400 ms), so video was off for the rest of the run and
everything travelled as lossless tiles. The opening picture, a full-screen lossless refinement
(1451 rects), ran at ~700 kbps with a 7–13 ms queue and finished in ~40 s; the opening burst
(2.2 Mbps in the first second, before the controller had a sample) cost one back-off to
173 kbps and a 73 ms queue, then the target climbed back to the cap within 15 s. After the
refinement the idle desktop (caret blink, menu-bar clock) cost **4–27 kbps**. No loss, no
disconnect, QUIC RTT 395–635 ms. The capacity estimate stayed 0 because no datagram trains
flowed, which is the expected Extreme-tier shape: the controller ran on tile acks alone.

**Window measurements, Shibuya hotel (2026-10-17 evening JST; RTT 144 ms, ~3.5 Mbps up; host
2711e3e+; test bench on the unlocked desktop, stream 3200×1800 native, headless, guards passed,
no loss).** "kbps" is the post-refinement median of everything on the wire; "into window" is the
lossless bytes that landed inside the bench window, direct (changed pixels) in brackets.

| Scenario, 800 kbps cap | kbps | into window | Copy-rects | Predictions confirmed / mismatched | Time-to-crisp | Other |
|---|---|---|---|---|---|---|
| idle (quiet desktop, caret blinking) | 26 | 30 (14) | – | – | – | queue p95 8 ms |
| typing 6 keys/s | 45 | 63 (50) | 1 | – | – | |
| login-field typing, 2 keys/s | 17 | 22 (16) | – | – | – | **first changed pixels in the field 176 ms median after each keystroke** (RTT 145): one RTT plus serialization |
| scroll bursts (40 × 30 pt at 30 Hz) | 27 median, 147 mean | 251 (18) | 272 | 263 / 3 of 273 | 3.0 s median, 5.0 s max | queue p95 36 ms |
| window drag (6×3 px per 16 ms) | 55 median, 287 mean | 648 (27) | 277 | 34 / 25 of 61 | 4.6 s median | the window list reports a diagonal move axis by axis and the alternating bursts reverse while earlier moves are unconfirmed: each reversal reads as a sign conflict |
| fovea (pointer over the text from the start) | 16 | 496 (15) | – | – | – | **text under the pointer lossless 2.1 s after stream start** (re-measured with 56abb5c; a first pass read 21.7 s because the metric ignored blocks that landed before the pointer was known); 0.9 s on loopback |

Fresh connection at an 800 kbps cap (coordinator's capture, 89e2ff7's predecessor): a whole
picture at ~1.7 s, crisp text by 4 s, idle ~15 kbps afterwards.

| Scenario, 2000 kbps cap | kbps | into window | Copy-rects | Predictions confirmed / mismatched | Time-to-crisp | Other |
|---|---|---|---|---|---|---|
| idle | 18 | 23 (13) | – | – | – | queue p95 21 ms |
| typing 6 keys/s | 50 median, 163 mean | 357 (120) | 0 | – | – | the mean is the line-wrap auto-scrolls of the text view going out as lossless strips |
| login-field typing | 25 | 44 (23) | – | – | – | first changed pixels in the field **187 ms** median after each keystroke |
| scroll bursts | 38 median, 215 mean | 523 (81) | 255 | 270 / 2 | 3.4 s median, 5.0 s max | queue p95 42 ms |
| window drag | 46 median, 270 mean | 690 (16) | 177 | 87 / 12 of 137 | 4.9 s median | queue p95 69 ms |
| fovea | 15 | 390 (18) | – | – | – | **text under the pointer lossless 2.1 s after stream start** |

What the two caps say together: on this link the cap barely matters for interaction cost, because
typing, carets and idle are tens of kbps either way and copy-rects make scrolls and drags cost only
their exposed strips; the cap decides how fast the first picture and the refinement blocks land
(rung 2 at 800 kbps, higher at 2000) and how quickly a scroll's strips become crisp (3.0–3.4 s
median here, above the 1 s target: the strips of a 3200-px-wide native scroll are ~60 px × 2200 px
of text per wheel event, and 40 events per burst). Keystroke-to-pixels stays at one RTT plus
serialization at both caps, which is the login-screen acceptance criterion.

Platform findings from M2:

- SCK lists no displays while the panels sleep, and lists only Astropad's virtual display while
  they wake; `IOPMAssertionDeclareUserActivity` wakes them like a local user, and a
  `PreventUserIdleDisplaySleep` assertion for the life of the capture keeps them on (they
  otherwise re-sleep ~90 s later and the stream goes silent).
- `WebPConfigLosslessPreset` does not initialise the rest of `WebPConfig`; call `WebPConfigInit`
  first or `WebPEncode` fails with an invalid configuration.
- `CGWindowListCopyWindowInfo` sampled in the SCK callback lags the composited pixels by a few
  ms, so a dragged window's frame delta is a few px stale at 30 fps; verify against the pixels
  and refine, never trust it blind.
- The one-way-delay EWMA sits ~30 ms above its windowed minimum even on a nearly idle link (tile
  acks ride a reliable stream, the control stream carries JSON); the controller's dead band
  starts above that (40–90 ms).
- The 1600×900 virtual display reports `CGDisplayPixelsWide` of 1600 for a 3200×1800 mode;
  take the mode's pixel size, not the display's.

### M2.5 (2026-10-17, resilience on droppy links, loopback)

Everything here ran on this MacBook against itself: `miraged serve --port 7800` in input-sink mode
(`MIRAGE_INPUT_SINK`, so no input of any kind was injected), headless viewers on `localhost`, the
test bench's `--motion` window as the moving picture, 1280×720 stream at an 800 kbps cap, loopback
RTT ~0.5 ms. Loss was injected in Mirage's own datagram send paths (`MIRAGE_TEST_LOSS`,
`MIRAGE_TEST_BURST_MS`); outages were made by stopping or killing the host process. The whole run
is `scripts/resilience-test.sh all`; numbers are from its last run. What loopback cannot do (real
delay, loss on the reliable streams, an IP change) is listed at the end.

| §4a row | Scenario | Result |
|---|---|---|
| Outage survival | `kill -STOP` the host 12 s into the stream, 30 s, `kill -CONT` | The viewer's watchdog redialed after 13 s of silence; dials failed every 4 s until the host woke; the first dial after `SIGCONT` authenticated with the token, the host logged `resuming its session` and `resumed … rung 0, tier Local, target 800 kbps, fresh done; masked keyframe next`; **picture back 0.23 s after the path returned**, 148 ms from the resume to the first new pixels; same viewer canvas and predictor throughout; no re-pairing |
| Idle timeout | `kill -STOP` 8 s | The QUIC connection survived (idle timeout 45 s), no reconnect, no resume; picture back 0.05 s after `SIGCONT` |
| Reconnect policy | `kill -9` the host, restart 30 s later | 5 attempts at 1 s intervals (4 s timeouts), no re-pairing, a fresh stream 2.2 s after the host was back (a killed host keeps no session state; the viewer kept its picture until the first keyframe) |
| Keepalive | 42 s idle | 5 datagram pings (one per 10 s plus the opener), nothing closed |
| Loss, 5 % random | 45 s, freezes counted from 20 s (after the fresh picture's lossless blocks, which hold video to 3–8 fps at this cap: a budget matter, not loss) | 0 % baseline: 13 fps median, longest video gap 125 ms. 5 %: 13 fps median, **longest video gap 142 ms**, no gap over 500 ms, 106 fragments rebuilt from parity, 28 resent after 23 NACKs, 0 frames given up, 15 keyframes in 45 s (the ladder's fresh-picture climbs and recoveries), controller target stayed at the cap, tier Local |
| Loss, 2 s bursts every 10 s (plus 5 %) | 48 s, freezes counted from 15 s (three bursts in the window) | Each burst is one video gap of **2.13, 2.21 and 2.31 s**: the picture was back 134, 213 and 309 ms after the burst ended; two of the three were noticed by the viewer's gap report on the first post-burst frame (recovery keyframe within ~150 ms), the third had swallowed a keyframe whole and was recovered by the host's stale deadline (3 srtt + 350 ms after the pacer finished); 48 keyframes in 48 s, most of them the fresh-picture climbs that follow each recovery; fps 20–30 between bursts, tier Local throughout |
| Input integrity | 1000 scripted keystrokes (2000 key events) at 20 keys/s with pointer moves interleaved; 5 % loss on the viewer's input datagrams and on the host's acks, a 2 s burst each way | Host applied **2000 of 2000 events, in order, no duplicates, none missing**; 2334 datagrams for 2000 events (redundancy, not loss), nothing dropped by the queue cap; the same property holds in the unit test's simulated link |

Things the runs taught:

- Pacing from the rate (review H6) broke the controller until the acks were adjusted: a paced
  frame's one-way delay read as queuing (the pacing time), and its dispersion read 1.25× our own
  budget as the capacity ceiling, so the target decayed to the 150 kbps floor and the tier to
  Extreme within 20 s. One-way delay is now measured from when the last datagram left the pacer,
  paced trains give no capacity sample, and frames that needed a NACK or parity give no delay
  sample at all.
- The tier must not read raw fragment loss: with parity and NACKs repairing 5 % loss at 16 fps,
  the "> 2 % loss → Extreme" rule put the stream on the tiny rung at 5 fps where every remaining
  loss cost 500 ms. The tier now reads frames given up; raw loss sizes parity.
- A base keyframe swallowed whole by a burst produces no ack and no gap report (nothing later is
  sent while it holds the in-flight cap), so the fresh-picture frame must be purgeable like any
  other; its purge re-arms the fresh picture on the next keyframe.
- Cancelling an `NWConnectionGroup` does not end its extracted streams on macOS 27: each has to be
  cancelled for the viewer's receive loop to notice a redial.
- A host that is killed does not refuse the viewer's dials quickly on loopback; the 4 s connect
  timeout and 1 s redial are what bound the recovery (2.2–2.5 s here).
- On loopback the viewer's next Hello reached the host 7 ms before the old connection's suspend had
  finished, and found no session: the session is now registered as suspended before the streamer's
  own suspend runs, and a claim waits for that suspend before resuming.
- Resends must go ahead of the pacer, not behind the frame in flight: queued behind a 17 KB
  keyframe they arrived after the viewer's 300 ms give-up time and turned one lost datagram into a
  lost frame, a recovery keyframe, more pacing, and so on until the tier read the losses as Extreme.
- The host's stale deadline bounds burst recovery (nothing from the viewer can arrive about a frame
  it never heard of, and the in-flight cap stops new frames behind it), so it sits just above the
  viewer's own give-up time (3 srtt + 350 ms after the pacer finishes), not comfortably above it.
- On mac-daddy (148 ms, 3.5 Mbps, no loss) the first M2.5 build read a constant ~90 ms queue on an
  idle link and decayed to the floor: the video samples had become honest about their own pacing,
  which exposed that a tile message's one-way delay carries its own serialization (a 30 KB
  refinement block is 70–90 ms at 3.5 Mbps), and the M2 base had only hidden that because
  keyframe serialization inflated it. Only tile messages that serialize in ~10 ms at the target
  rate are delay samples now; large blocks are not (they cannot be the minimum either), and the
  baseline is a 20 s windowed minimum for both sample sources (review M6).
- Replacing the HEVC session while a frame is inside it never calls that frame's completion; the
  `encoding` flag then stayed set and video stopped for good after a ladder step. The rebuild now
  waits for an idle encoder, and a 2 s watchdog releases the pipeline if it ever happens again.

Not measured here, with the command that would: real delay and loss on the *reliable* streams
(tiles, copy-rects, control) and the Extreme-tier profiles (`dnctl`/`pfctl`, the sudo section of
`scripts/resilience-test.sh`); the recorded bus trace (`experiments/linktraces/replay.sh`); an
IP change (needs two interfaces; the code path is a redial with the resume token).

### M3.1 (2026-10-18, layered desktop with client-side composition, loopback)

Built on this MacBook against itself (`miraged serve --port 7800` in input-sink mode, headless viewers on
`localhost`, 1512×982 stream at an 800 kbps cap, the test bench as the window under test, phrz's own
windows open and changing on the same screen). The baseline is 99e652a's host and viewer built in a
worktree, run against the same drifting bench in the same minute.

| Scenario | 99e652a (single capture) | M3.1 (layers) |
|---|---|---|
| Host-side drag (`--drift`: 0.8 s bursts of 6×3 pt per 16 ms), per burst | 3.6–14.6 fps of video of the moving window (median ~8), 24–26 copy-rects, time-to-crisp 1.0–1.7 s after the burst (the strip under the window re-sent lossless), link peaks of 800–1250 kbps for a second around each burst | **0 video frames, 0 copy-rects, 0 bytes of the dragged window**: 15–17 window-list frame updates per burst (19–21 Hz, the host samples CGWindowList at 30 Hz), 6–12 KB on the whole link during a burst (the list deltas plus other windows' changes), time-to-crisp 0 ms, bench layer silent afterwards |
| Client drag (local layer drag + `windowCommand(move)`, ~18 commands per 0.8 s) | copy-rect prediction: 9.5–12.5 fps during the burst, ~24 copy-rects, time-to-crisp ~5 s (§3.3c) | window moves locally at the pointer; the host's list confirmed the final frame **53–82 ms after release** (loopback: AX set + one list sample), 7–35 KB on the link during the drag (none of it the dragged window), time-to-crisp 0 ms, 0 stale tiles committed, 0 prediction mismatches |
| Fresh picture, 4 windows (two 1512×948, 800×532, 288×464) | one keyframe ladder for the display | display keyframe 537 B → ladder → blocks as before; window stills 2–28 KB each (288×464: 3.2 KB; 800×532: 15–28 KB; 1512×948: 8.5 KB at 464×290), all four layers announced within 0.75 s of the stream start, stills within 4 s, then lossless blocks locus-layer first |
| §4a outage survival (30 s black hole), `scripts/resilience-test.sh outage-stop` | picture back 0.23 s after the path returned | **pass**, picture back 0.84 s (the window capturers restart on resume; the first frame of each layer is diffed in full against the last one sent) |
| Host cost (M4 Max, 4 window layers at 10–30 fps plus the display) | – | 300–440 captures per 5 s at 0.6–0.9 ms each (~7 % of one core), 0–1 HEVC encoders live |

What the numbers say: in Desktop mode a window drag no longer touches the pixel path at all, in
either direction; what remains is the control stream (a 150-byte list delta per 33 ms while something
moves) and, for client drags, one AX call per command on the host. The uncovered area was already on
the client. Time-to-crisp after a drag is zero by construction; the ~5 s of §3.3c was the refinement of
the strip the single capture had to re-send.

Things the runs taught (all in `experiments/probes/README.md` under "layers"):

- `desktopIndependentWindow` streams render every interval: 33 fps of identical frames for a still window,
  the dirty rect always the whole window. Nothing in SCK says "unchanged"; the tolerant diff does, cheaply
  (a row-wise `memcmp` first). The capture interval is therefore per layer: 30 fps frontmost, 10 fps
  others, 2 fps fully covered.
- The traffic lights are a separate 66×20 level-0 window on macOS 26/27, 6 pt inside the parent's corner.
  Without `includeChildWindows` a layer has no buttons; without folding them into the parent the display
  layer sees a tiny window dragging around and sends copy-rects for it.
- A still window's rounded corners re-render with ±10 levels of difference between consecutive frames
  (four 23×23 boxes "changing" at 10 fps). Semi-transparent pixels need a tolerance of ~48 and fully
  transparent ones must never count, else every idle layer costs ~5 kbps and never settles.
- Excluding a window from the display stream does not exclude its shadow; `ignoreShadowsDisplay` does,
  for every window, so the viewer draws shadows for cut-outs too (menus; not the dock or menu bar).
- Odd window heights: SCK is configured with even sizes (the encoder wants them); a layer is the even
  size, one pixel short of its frame at most, and a frame of any other size is skipped.
- `MetalContext` compiles the shaders once per viewer; a shader that fails to compile (a variable named
  `half`) made `Compositor()` nil and the viewer silently decode nothing, which the compositor tests
  skipped rather than failed. They no longer skip on this machine.

Not measured here: the real link (RTT and the AX round trip decide how long a dropped window takes to
be confirmed; the local picture does not wait for it), windows with heavy translucency (a layer captured
alone has no backdrop blur), the look of the shadows against mac-daddy's wallpaper, and more than four
windows at once (the cap is 16 layers / 48 Mpx; beyond it windows are cut-outs of the display layer).

**M3.1 field regression (mac-daddy, d5a233b, 2026-10-18) and fix.** The coordinator's first run on
mac-daddy (3200×1800 at 2x, stream 3024×1700, 145 ms RTT, 800 kbps cap, bench `--drift`): the bench was
visible in the first frame only, then only the desktop, icons and dock rendered for 39 s, while the host
sent its still and then refined at 600–750 kbps for 35 s. Reproduced on loopback with a ~1.7x non-native
stream by adding one window the test bench can now open (`--overlay`: full-screen, transparent,
click-through, floating level, the kind of window utilities keep on screen): exactly the same picture.
Two causes, both "a transparent window in front of everything was treated as opaque":
1. The viewer drew every non-layered window as a cut-out of the display layer at its full frame. The
   overlay's cut-out repainted the whole screen from the display layer, which by then no longer contains
   the layered windows; every window vanished once it became a layer.
2. The host's occlusion test counted the overlay as covering every window, so every layer's tiles were
   "covered on the host" and held back after the still (and its capture dropped to 2 fps).
Fix: the host marks cut-out-safe windows explicitly (`WindowInfo.cutout`), the viewer plans the scene in
`LayerScenePlan` (MirageCore, unit-tested) and draws a cut-out only where it overlaps a window layer or
its shadow behind it, shadows never paint inside their own box, and host-side occlusion counts only layers
and cut-out-safe windows. Also from the same run: per-tile refinement now holds tiles covered on the host
(a fully covered window was refined tile by tile after its blocks), and every window's still goes before
any window's blocks (four stills within 1.3 s of the stream start on loopback, 60 ms apart, instead of
spread over 4 s behind one window's blocks). The host logs the window list (id, level, owner, size,
cut-out or not; titles only for the bench) at stream start, and the viewer logs per-layer diagnostics on
every change and writes them to `--stats` JSON (`layers`: received bytes, tiles, stills, canvas size,
frame, viewport rect, drawn as layer / cut-out / display / missing, visible, and why not).
Loopback after the fix (2600×1688 stream, 800 kbps, `--drift` + `--overlay`, phrz's windows on screen):
the bench layer VISIBLE across every host-side move (diagnostics: 352,188 → 633,328 → …), 15–17 list
updates per burst, 0 video and 0 copy-rects for it, its lossless blocks delivered (320 KB), the fully
covered Sketch window nothing beyond its 3.7 KB still; client drags with the overlay present confirmed
48–88 ms after release, 0 stale tiles, 0 mismatches; `outage-stop` pass (0.59 s). Scene tests: a layered
window stays visible across a host-side move under a full-screen overlay; a menu cut-out draws only over
the window it overlaps; a host-layered window without a viewer canvas is reported, not silently hidden.

**Screen lock (second mac-daddy run, 30aa008).** The re-recording showed only wallpaper because mac-daddy's
screen was locked: `IOConsoleLocked` read false while `CGSSessionScreenIsLocked` was 1, and the host's new
window-list log showed loginwindow's shields (level 2004 at display size, level 2001 at 56700×56700). The
bench itself was correctly drawn (a display-layer window, VISIBLE), so the overlay fix held. Every lock
guard (scripted-input refusal, window commands, `hostStatus.consoleLocked`, the runner's checks before
each burst) already read `CGSSessionScreenIsLocked`; they now go through one predicate, `ScreenLock`
(MirageCore, unit-tested), that is locked if *any* signal says so: `CGSSessionScreenIsLocked` (CFBoolean,
NSNumber, Int or string), `IOConsoleLocked`, or a loginwindow window at level ≥ 2000 covering the display.
While locked the host pauses layering (window capturers stopped, layers and their pixels kept, no layer
refinement, the display stream excludes nothing, the list marks nothing layered, so the viewer shows the
lock screen), announces it in `hostStatus`, and resumes on unlock (capturers restart; each layer's first
frame is diffed in full against the last one sent). The viewer shows a banner, "<host>'s screen is locked.
Unlock it to see its windows.", and logs each change. Loopback, with the test-only
`MIRAGE_TEST_SCREEN_LOCK=/path` (locked while the file exists; nothing locks the person's screen): lock at
15 s → 0 of 4 window capturers running within a second, link 4–170 kbps; unlock at 30 s → 4 capturing,
the windows layers again; the display layer then re-sends where the windows were (it carried them while
locked), ~10 s at 550–1100 kbps at 1512×982 here.

**Steady refinement after the drag fix (third mac-daddy run, a1c707a).** The bench result was the one we
wanted (drawn as a layer, visible, crisp, shadowed, no ghost, 0 video), but tiles ran 860–956 kbps for
~15 s and 350–675 kbps for the rest of the 40 s with nothing changing but the bench and the clock, while the
bench layer took only ~370 KB. Loopback at a 1.7x stream (2600×1688, 800 kbps, drifting bench) showed where
it goes, with the host's per-layer accounting now including the display layer: the **display layer's
fresh-picture refinement**, 400–530 KB per 5 s for ~35 s (≈2.5 MB), then quiet. Not the bench moves: the
display layer sent one direct rect per 5 s (the clock) and nothing on moves (the desktop does not change
under an excluded window). Two reasons it was that large:
- It refined the whole desktop, including everything under layered windows, which the viewer cannot see.
- The desktop is a photographic wallpaper. Measured on this one (`miraged probe-layers --mode codec`:
  the desktop picture without windows, 320×320 blocks at 2600 px): lossless 1007 KB/Mpx, near-lossless
  677, lossy WebP q92 180, q85 118, q75 73, i.e. ≈3.0 MB for the whole desktop near-lossless against
  ≈0.5–0.8 MB at q85–q92.
Fix: display tiles under a layered window (frame inset by the corner radius) are treated as covered: left
out of the fresh picture's blocks (blocks are now filtered per tile) and of per-tile refinement, and
refined once when a window move first uncovers them. Photographic rects (> 4096 colours) end at visually
lossless on constrained links (cap or target ≤ 2 Mbps, or the Constrained/Extreme tier): lossy WebP q90 at
full size, review #22; text and UI stay lossless everywhere. Same loopback run after: **1.36 MB on the wire
in 60 s instead of 3.95 MB**, refinement done at ~19 s instead of ~44 s, display layer ≈220 KB instead of
≈2.5 MB, then 8–63 kbps (a live app window on the host screen); bench a visible layer through every burst,
10–14 KB per burst, 0 stale tiles. Not done: re-refining photographic tiles to lossless when the link
improves to Normal/Local.

