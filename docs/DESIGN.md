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

### 3.2 Capture: layers, not a framebuffer

The host streams one or more **layers**; the client composites them.

| Mode | SCK filter | Purpose |
|---|---|---|
| Desktop | `display`, cursor hidden | classic full-screen view |
| App layers (Unified / Parallels Coherence style) | `display including:[app]` per app | every window of the app at desktop coordinates on a transparent background; menus, sheets, popovers, tooltips come along correctly; empty area costs nothing after diffing |
| Window | `desktopIndependentWindow` | a single window as its own stream (Citrix-style seamless) |
| Menu bar | `display including:[Control Center, WindowServer menubar]` | shown on client when a remote app is focused |

App layers are the default Unified mode because per-window capture misses transient windows
(menus, autocomplete popups) that are separate windows. Each layer is its own `SCStream`
scaled by SCK to the client's requested pixel size (never ship 5K to a 1 Mbps link; the
resolution ladder is part of the rate control).

Window metadata (id, pid, title, frame, level, z-order, minimized, focused) is published on
`control` at up to 30 Hz from `SCShareableContent` + `CGWindowListCopyWindowInfo` +
AX notifications (`kAXWindowMoved/Resized/Created/UIElementDestroyed`). Client-side, each
remote window in Unified mode is a real `NSWindow` (or an iPadOS scene) whose content view
is a Metal layer sampling the right sub-rect of its app layer.

### 3.3 Codec: per-tile hybrid, three paths

Per layer, per captured frame, split into 64×64 tiles (128 on 2x). Use SCK `dirtyRects`
(later: GPU diff like Astropad for exact tile masks). Classify each dirty tile by **motion
history** (dirty in N of the last M frames):

1. **Static → nothing.** Most of a desktop, most of the time.
2. **Settling / sparse → lossless tile** on the `tiles` stream. Typing, cursor-caused UI
   changes, blinking carets, a button highlight. Encoder: start with **WebP lossless** via
   libwebp (2–4 KB for a 64² text tile, fast decode); later a custom predictor + rANS/LZFSE
   codec tuned for UI (Astropad's path) if it measurably wins.
3. **Sustained motion → video**: the moving region's bounding rect (snapped to 64 px, or the
   whole layer if >40% dirty) goes to a hardware **HEVC low-latency session**, one per layer,
   `AllowFrameReordering=false`, `EnableLTR=true`, `MaxKeyFrameInterval` large (recover via
   LTR acks, not keyframes), `DataRateLimits` set per frame from the rate controller, QP map
   biased sharp on text-classified tiles. Decoded with `VTDecompressionSession` straight into
   a Metal texture.
4. **Refinement**: when a video region stops moving for ~300 ms, its tiles are re-sent via
   path 2 (lossless), so scrolled text snaps crisp. The client composites lossless tiles over
   the video texture and invalidates them when a newer video frame covers them.

Photographic tiles (high entropy, lots of colors) that are static still go lossless unless
the budget says otherwise; near-lossless WebP (`-near_lossless 60`) or an HEVC intra tile
at low QP is the fallback.

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
3. **Scroll prediction** (experiment). Host publishes AX scroll-area frames for the focused
   window. On wheel events the client shifts the pixels inside that rect by the delta
   immediately, exposing a neutral band at the edge, and reconciles when frames arrive.
   Mosh-style rule: predict only while recent predictions were confirmed; back off on misses.
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
| Measured frame age | | 120–150 ms at 800 kbps |
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
- `VTCompressionSession` in low-latency mode emits `RequireLTRAcknowledgementToken` per
  frame; feeding tokens back via `AcknowledgedLTRTokens` + `ForceLTRRefresh` compiles and runs,
  but with 0% loss on this link the recovery path was only exercised by the opening frames.
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
