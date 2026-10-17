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
4. **Refinement**: when a video region stops moving for ~300 ms, its tiles are re-sent via
   path 2 (lossless), so scrolled text snaps crisp. The client composites lossless tiles over
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

**Two standing rules (phrz, 2026-10-17).**
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

**Window measurements (4G bus, one bar; test bench on the unlocked desktop):** see the
table below, filled as the runs land. Commands are in experiments/testbench/README.md.

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
