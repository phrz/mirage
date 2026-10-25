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

### 3.0 The host is the product (standing rule, phrz 2026-10-21)

The host is the product; the viewer renders and predicts within host-given bounds. In phrz's words: "it stands to reason
most of these rendering fixes should be server not client updates". An iOS viewer update needs a cable install or
TestFlight, and once the app ships, every viewer change is an app update for every user. A host update is one deploy.

- **Fix on the host first.** A rendering bug gets a host-side fix whenever the host can produce the right result: crop,
  order, hold back or resend what it sends, own the state through transitions (Show Desktop: the host drops the blank
  captures ScreenCaptureKit delivers for pushed-aside windows, so every viewer, old builds included, keeps their last
  picture). Touch the viewer only where that is impossible, and say why in the commit.
- **The viewer is a dumb compositor.** It draws what the host describes: layer frames, the display rect it clips to, z-order,
  cut-outs, shadows, scroll rects. It does not infer geometry of its own. Where it still does (the unknown-desktop marks,
  the viewer guard, shadow geometry from points per pixel), the inference moves to the host as the protocol allows.
- **Tunables, not constants.** The numbers the viewer uses for local behaviour come from the host: `ControlMessage.tunables`,
  a versioned dictionary sent after every `streamInfo` to viewers whose stream request carries `tunablesVersion`. It covers
  gesture thresholds (two-finger pinch/scroll, hold delay, touch slop, double-click), the zoom limit, the scroll prediction's
  rubber-band lead, and the crossfade and level-fade timings. The viewer keeps safe compiled-in defaults, clamps every value
  to its key's bounds and ignores keys it does not know. The host sends its defaults overridden by `tunables.json` in its
  store directory (`{"pinchRatio": 0.2}`), read at every stream start, so a retune needs neither an app update nor a host
  restart. New viewer behaviour that has a number in it gets a key (`Tunables.Key`), not a literal.
- **Exceptions are written down.** The scene renderer clips every layer to the display rect in the viewer (bf7e8a8), as a
  safety net. For viewers without the clip (no tunables: builds before 0d0651f) the host crops too: a window layer's tiles
  wholly off the display are sent transparent once and stay pending until they come back on screen. Not for viewers that
  clip: blanked tiles come back only as fast as they are resent, and on phrz's iPhone Show Desktop left the returning Finder
  window full of holes until they were.
- **The underlay goes only where no window is** (UnderlayRule): never under a window the desktop picture carries (a window
  that is not a layer is drawn from those very tiles), under layers only when idle, and at once only where a window just
  left and none covers now.
- **The desktop underlay is the host's.** Under a layered window whose exclusion from the display stream is not verified,
  the desktop cannot be read from the display stream, and the viewer held nothing there: Show Desktop revealed a flat fill.
  The host keeps a second capture of only the desktop-level windows (wallpaper, desktop icons and widgets; half size, one
  frame every 2 s), window-free by construction, and when nothing has moved for 2 s it sends those tiles (lossy, on 10 % of
  the tile budget) with the window-free flag. The viewer's guard lets them through; they stay pending on the host, so the
  real desktop follows once a window uncovers them.

### 3.0a The compositor model (phrz approved 2026-10-21; host flag `compositorModel` / `MIRAGE_COMPOSITOR`, default off until the A/B)

The seam design keeps one display stream minus the windows it manages to exclude, and a window becomes a layer only once
the stream verifiably leaves it out. Everything that goes wrong at that seam needed machinery: the display guard, the
viewer guard, taint, unknown-desktop marks, exclusion checks and "unexcludable" windows, the urgent underlay. Show Desktop
broke it repeatedly (a window baked into the desktop picture, revealed when it moved).

In the compositor model nothing is ever baked:
- **The desktop layer** (layer 0) is a capture of the desktop-level windows only (window layer below zero: the wallpaper,
  the desktop icons, widgets). No app window can be in it, so the desktop under a window is always the desktop.
- **The overlay layer** (`WindowInfo.overlayID`, level `overlayLevel`, listed first) is one full-display capture of
  everything above the normal level (the menu bar, the Dock, menus, popovers, tooltips, notifications) on a clear
  background, leaving out the desktop-level and normal windows. New menus appear in it without any filter change.
- **Every visible normal window is a layer** as soon as its first picture lands (no exclusion wait). Layers are published
  as verified, so older viewers' guards let the desktop through. A window entirely covered by normal windows keeps its
  layer (the viewer its last picture) while it is in the list; its capture runs on for 10 s, held back as covered, so a
  quick return (a Show Desktop round trip) needs no restart, then stops until it shows. The layer caps go to what can be
  seen, and a visible window over them is logged.
- **No unowned rectangle:** a shown window whose own capture has not delivered within 400 ms (a new window, one uncovered
  after a while) is cut from the full display capture (the fallback below) until it does; not for a stream's first
  windows, whose captures start as fast as that one.
- Off under the flag: the display guard (nothing waits), taint resends, the desktop underlay
  and its second capture, the exclusion bookkeeping. They are deleted once the flag wins the A/B.
- Streams: desktop + overlay + one per visible window (the seam design: display + underlay + one per planned window).
- The viewer change it needs: hit-testing skips the overlay layer (it covers the whole display). Viewers without it would
  hit the overlay for every title-bar drag, so the default flips only after the app update is out.
- **Fallback:** a window whose own capture fails (or stops with an error) is still a layer, cut at its frame from one full
  display capture (the composited screen, nothing left out) that runs only while some layer needs it. Soft, and partly
  covered where a window is in front, never baked into the desktop. `MIRAGE_TEST_FALLBACK=<app name>` forces it for that
  app's windows.

### 3.0 M-FIVE: The first five seconds (milestone, phrz 2026-10-21; supersedes the connect sequence elsewhere)

phrz, connecting over a ~20 Mbps café link (seam design): "I stared at a lossy page for far too long, then all the windows
snapped in gradually over the next fifteen or so seconds… it just flickers in from a very noisy start. I feel very far from
the original product idea of Mirage being an Apple-esque very clean remote desktop." The connect is the product. Built on
the compositor model (§3.0a), whose layers make a per-window sequence possible.

**Targets** (from the first byte of the handshake, measured on the viewer's presented frames):

| link | coherent picture (every visible layer recognisable) | crisp (every visible layer lossless) |
|---|---|---|
| ~20 Mbps, ~30 ms | ≤ 0.5 s | ≤ 2 s |
| 1 Mbps (Fast 4G uplink-ish, constrained) | ≤ 1 s | ≤ 10 s |
| Japan bus (650 kbps, 420 ms RTT, 0.85 % loss) | ≤ 1.5 s | best effort, no flicker on the way |

**No flicker (hard rule).** On connect each region (the desktop, each window) changes appearance at most three times:
placeholder → coherent lossy → lossless. Each change is a whole-region crossfade (`crossfadeMs`), never tiles popping one by
one, never noise, black, or garbage. The viewer stages every update of a layer and presents it atomically. Live content (a
clock ticking, a video playing, someone typing) is not connect flicker and is exempt; the tests use still content.

**The sequence.**
- **(0) Placeholders, instantly** (§3.0b), for the desktop *and* every visible window at its real frame, in one message
  right after the handshake, ahead of any picture. On a reconnect with the tile cache (§3.0c), the cached pixels paint
  instead wherever the host's tile ids match. The viewer draws placeholders soft (upscaled with a blur), so nothing reads
  as noise.
- **(1) One coherent lossy picture per layer, all at once.** The host sizes every visible layer's still from the measured
  bandwidth so that all of them together arrive in ~0.5 s (the budget split by visible area; a covered part costs nothing),
  sends all of them before any lossless byte, and marks the set. The viewer holds each still until the set is complete
  (or 0.7 s have passed) and crossfades every layer from its placeholder in the same frame. No HEVC ladder (tiny keyframe
  and rung climb) for the desktop: it gets a still like any window. This stage replaces today's "tiny keyframe first, then
  ladder climb" and the per-window stills that arrive one by one as captures start.
- **(2) Lossless per layer.** Each layer's lossless level is staged and crossfaded in when that layer's level is complete
  (the existing level machinery, now the only path for connect refinement); visible windows first by visible area, the
  desktop's visible part with them, hidden parts after. Partial levels never show.
- Captures: every visible window's own capture starts at stream start in parallel (not one after another), and until it
  delivers, stage (1) uses the stream-start screenshot's cut of that window (the composited screen at its frame, front
  windows masked) at the stage-1 size. Neither a placeholder nor a cut is ever replaced by a later cut (no alternation).

**Bandwidth at connect.** No 800 kbps start and creep. During the handshake the host sends a packet-train probe (~40
datagrams of 1.2 KB back to back, ~48 KB, repeated once if the first is short); the viewer echoes first and last arrival
times; the host's first target is 0.7 × (bytes / spread), clamped to the cap, and the delivery-rate controller (§3.4) takes
over from there. Stage (1)'s budget uses this estimate.

**Acceptance test (gates every deploy to phrz).** A `connect` scenario with a still screen (the bench plus a Finder window on
/tmp/mtb2), run on shaped links (Fast 4G, ~20 Mbps, Japan bus) with the frame recorder at 10 fps from the first byte:
- time-to-coherent: first frame where every measured region differs from its placeholder state by less than a threshold
  from the final lossless picture's low-pass version;
- time-to-crisp: first frame where every measured region matches the final picture within the lossless threshold;
- flicker count per region: the number of appearance changes (mean absolute difference between consecutive frames over the
  region above a threshold, merged across a crossfade's frames) up to time-to-crisp. Pass: ≤ 3 per region, targets met, no
  frame with a black or garbage region (a region whose difference to the final picture rises after it fell).
The viewer also logs each stage per layer (placeholder, coherent, lossless) with its time, and the host logs the probe's
estimate, so a failure says where it came from.

**Warm host, snapshot mode (default, phrz 2026-10-21: "it should not be more than every 30s").** Running warm captures
cost WindowServer ~34 points of CPU on mac-daddy (10 windows, each a display-minus-everything-else composite). So while
nobody is connected the host keeps only one display snapshot (half the native width), retaken at most every
`warmSnapshotSeconds` (30), with the on-screen window layout (ids and frames, CGWindowList) it was taken in. At connect,
placeholders and stage-1 cuts come from it when the layout is unchanged (no screenshot to wait for); otherwise a new shot
is taken as before. `warmMode` 1 keeps the running captures below for comparison. `windowShotIndependent` 1 takes each
window's first-frame snapshot with the window-alone filter; the host logs each snapshot's time and its difference from the
window's own first frame.

**Warm host, running captures (prototype, WarmPool, warmMode 1).** ScreenCaptureKit starts window streams *and* screenshots one after another (~0.75 s
each on mac-daddy), so "parallel capture starts" cannot work: with eight windows the last own frame came ~4-6 s after the
connect. So the starts leave the connect path: while no stream is active, the host keeps the visible normal windows'
captures running (the largest 12, 1 fps, the stream's own filter, dirty-rect driven so a still window costs nothing) with
each window's latest frame in memory. At connect the streamer adopts the running capture (follow + exclude reconfigure
it to 10 fps and the layer's size) and its frame is the layer's first. Privacy: frames only in memory, never on disk;
everything dropped while the screen is locked, the display sleeps or the Mac is on battery (laptops warm on AC only).
Tunable `warmCapture` (default 1). In the compositor model the desktop and overlay display captures are warmed too (1 fps,
native size, no display-sleep assertion until a streamer adopts them; adoption reconfigures size and frame rate and the
overlay's exclusion). Next: each layer's lossless tiles kept pre-encoded (1x and 2x), so stage 1 and lossless go out at link
rate from the first round trip.

**Order of work.** Spec (this) → placeholders in both models, with the desktop's → probe → stage (1) set and barrier on the
viewer → stage (2) per-layer only → parallel capture starts → the acceptance test, which then gates deploys. The tile cache
(§3.0c) follows.

### 3.0 TRUTH: Transactional presentation (design, phrz approved 2026-10-21; after M-FIVE's connect test passes)

M-FIVE's barrier made the connect clean; everything after the connect still lands piece by piece: tiles of one capture
arriving over several messages and presenting as they come, video and lossless tiles of the same moment on separate
paths, a moved window and the desktop it uncovered on separate layers. The viewer is split into two layers with one rule
each.

**(a) Truth: only complete host frames.** Every update the host makes from one capture (tiles, copy-rects, a level, video,
a layer's frame or stacking change) belongs to that capture, and the viewer presents a capture's changes to a layer all at
once or not at all; until then the previous complete frame stays.
- *Wire.* Every tile message, copy-rect and window-list delta already carries the capture sequence it belongs to. The host
  ends each capture's output with `frameEnd(captureSeq, layers: [id], deps: [captureSeq])` on the tile stream: the layers it
  touched and, for a window move, the desktop capture whose uncovered tiles must land with it (cross-layer). Old viewers would
  fail to decode an unknown tile message, so it goes only to viewers that announce `transactionalVersion` (as with tunables).
- *Viewer.* Updates are applied to a staging copy of each layer as they arrive (the existing staged levels, generalised from
  refinement to every update); `frameEnd` presents all the named layers' staged changes in one composite, together with the
  window list as of that capture (frames, stacking).
- *Video.* A video frame belongs to its capture; it presents with that capture's tiles. A frame lost in the network (parity
  and NACK failed) leaves the layer at its last complete frame until the next keyframe or recovery frame, as now, but its
  capture's tiles wait for it no longer than the recovery deadline; the layer then skips to the next complete capture.
- *Cost.* Truth is delayed by the time a capture's bytes take to arrive after its first byte (a capture's tail), never
  more. That delay is measured (below) against today's piece-by-piece presentation.

**(b) Prediction: instant, protected (the Mirage difference).** Window drags, scroll offsets, the cursor and typeahead apply
at once as transforms over the last complete frame, never as pixels of their own: a drag moves the window's whole last
picture, a scroll shifts the scroll view's last picture, typeahead draws glyphs over the last picture. When the host frame
carrying the matching input sequence is presented, the prediction is reconciled with a small eased correction (≤ 120 ms),
never a jump. Predictions move complete content only.

**Revealed unknown areas** (a scroll's lead, a moved window's vacated area before the desktop there arrives, a pan into the
unseen): phrz's "dreamy" fill, modelled on Apple's Photos Extend placeholder, which is a mask-aware push-pull pyramid fill
(its kernels are named inward_fill_down / inward_fill_up), not an edge-extend and blur:
- *Pull:* from the known pixels (premultiplied by a coverage mask: 1 known, 0 unknown) down a mip pyramid, each level a 2×2
  premultiplied average carrying its coverage, to the coarsest level (everything covered there).
- *Push:* back up, each level's unknown part filled from the coarser level, blended by (1 − coverage), so known pixels stay
  and the unknown gets a smooth, colour-true continuation of what surrounds it.
- *Feather:* a band of ~24–48 px inside the known edge crossfades known into filled, so no seam shows.
- *Optional:* a slow, low-amplitude domain warp over the filled area (alive, not static).
- Crossfaded to the truth when it lands. It replaces today's edge-colour band. Metal on both viewers (a compute pass per
  pyramid level); budget ≤ 0.5 ms of GPU per frame on an iPhone 15. A Reveal Lab prototype is comparing styles; its winning
  parameters (band width, warp amplitude and speed) go here.

**Acceptance: the glitch metric** (connectcheck extended), over recorded viewer frames during scroll, drag, Show Desktop and
typing scenarios on Fast 4G and Japan bus:
- *Partial frames:* the viewer's recorder logs, per presented frame and layer, the capture sequences whose changes it shows;
  a frame where a layer shows part of a capture's changes (some of its tiles, not all; or a window moved without the desktop
  its move uncovered) is a glitch. Target: zero.
- *Truth delay:* per capture, the time from its first byte's arrival to its presentation, compared with today's presentation
  of the same scenario; reported as p50/p95.
- *Prediction:* drag, scroll and typing feedback stay instant (presented in the frame after the input, as today).

**Order of work.** frameEnd on the wire and per-layer staging for tiles and copy-rects → cross-layer moves (window frame and
uncovered desktop) → video with its capture → predictions as transforms with eased reconciliation → the dreamy fill → the
glitch metric, then gating deploys with it as with M-FIVE's connect test.

### 3.0b Placeholders: every window at once, then sharp (design, phrz 2026-10-21)

phrz: on slow links windows must not pop in one at a time; a compact stand-in while they load. Today each window's first
picture waits for its own capture to start (~0.6 s each, serially, on mac-daddy) and then for its still (5–13 KB): on
Japan bus the last window appeared ~5 s after the first.

- **Source.** At stream start (and on a resume with no picture), the host takes one small screenshot of the composited
  display (SCScreenshotManager, ~400 px wide, one call, no stream) and the desktop layer's first frame. Each visible
  layer's placeholder is cut from it at the layer's frame, with the parts covered by windows in front left transparent
  (as the fallback cut does). The desktop's placeholder comes from the desktop-only frame, so it shows the desktop under
  every window too.
- **Format.** One small lossy image per layer, the long side 32 px (WebP q40 through the still encoder, ~150–400 bytes),
  with its alpha. ThumbHash (~25 bytes) was considered: smaller, but blurrier and an extra codec in both apps; at 32 px a
  dozen windows cost ~3–5 KB, ~60 ms of a 650 kbps link. The format field allows ThumbHash later.
- **Wire.** `ControlMessage.placeholders(Placeholders)`: `[{layer: UInt32, frame: PixelRect, width, height, format,
  data}]`, on the control stream right after the first window list, ahead of every still. A window shown later gets a
  one-item message just before its layer's `.reset`. Only to viewers that put `placeholdersVersion` in their stream
  request (an older viewer would fail on the unknown message), like `tunables`.
- **Viewer.** Each layer draws its placeholder, upscaled to its frame with a blur of about one placeholder pixel, until
  its first still arrives, then crossfades (tunable `crossfadeMs`). Hit-testing and z-order are the window list's, as for
  real layers. The desktop's placeholder also stands under windows wherever the desktop's real tiles have not arrived:
  on slow tiers the hidden desktop is not sent until a window moves (§3.4), and a window moved away reveals the blurred
  desktop instead of an empty canvas while its tiles come.
- **Cost and limits.** One screenshot per stream start (~20 ms of host CPU), a few KB on the wire. A placeholder is a
  picture of the screen like any other: same transport, same pairing, nothing persisted.
- **As built (host only, tunable `placeholders`, on by default in the compositor model):** no new message. A
  placeholder is the window's announcement (`.reset`) plus one 32-px lossy tile covering the layer, i.e. a tiny still;
  the window is published as a layer at once, and its real still (same size: the viewer keeps the pixels) replaces it.
  Every viewer build shows it. Since M-FIVE step 2: taken first thing at a fresh stream start, in both models; the
  desktop gets one too (64 px; the whole screen in the seam design, windows left transparent in the compositor model).
  Windows shown later appear when their own capture delivers (the full-display stopgap is gone). Not yet: a soft
  upscale on the viewer (it draws the placeholder with its normal filtering).

### 3.0c Persistent tile cache (design, phrz 2026-10-21; behind a tunable)

The wallpaper and static app chrome are the same on every reconnect, yet each connect sends them again (the desktop's
lossless blocks were ~1 MB of every first picture). A viewer-side cache of tiles it has seen, content-addressed, lets the
host advertise what a tile is and send only what the viewer lacks.

- **Keys.** A pairing keeps no shared secret (the PAKE yields pinned public keys only), so the viewer owns the cache's
  keys: per paired host, a random 256-bit master key in its keychain. From it, HKDF derives `idKey` (label "mirage tile
  ids v1") and `sealKey` ("mirage tile seal v1"). The viewer sends `idKey` to that host inside the authenticated session
  (`StreamRequest.tileCacheKey`, only when the tunable is on); the host holds it in memory for the session and never
  stores it. `sealKey` never leaves the viewer.
- **Identity.** A tile's id is `HMAC-SHA256(idKey, SHA-256(lossless BGRA of the 64-px tile))`, truncated to 128 bits. Keys
  are random per host and per viewer, so ids for the same pixels differ between hosts and between users: a host cannot
  ask about another host's tiles, and ids are not comparable across pairings.
- **Protocol.** In the fresh picture, for the desktop layer and windows whose content is stable, the host sends
  `tileIDs(layer, [(tile index, id)])` ahead of the blocks. The viewer paints every tile it holds at once (lossless,
  staged into the layer's next level like a block) and answers `tileMisses(layer, [tile index])` on the control stream;
  the host plans its blocks over the misses only (and anything that changed since). Tiles the viewer stores are those it
  received lossless and that stayed unchanged for 2 s (not every passing frame of a scroll). The host keeps no state
  about the cache beyond the misses of the current session.
- **Storage (viewer).** Per pairing: a directory in the app's own container (Application Support on macOS, the app
  container on iOS), excluded from backups (`isExcludedFromBackup`), holding records sealed with AES-GCM under `sealKey` (one per tile; nonce
  random per record; the tile id as associated data). The master key's keychain item is
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable = false`. Size bound per viewer (tunable,
  200 MB default), least-recently-used eviction across pairings.
- **Lifecycle.** Unpairing or revoking a host deletes its cache directory and its master key. Settings has "Clear cache" (all
  pairings). A host whose pairing secret changes (re-pair) starts a new cache.

**Threat model.** The cache holds pictures of the host's screen, which can be sensitive (documents, messages).
- *Another local user or process on the viewer device*: the files are in the user's container and sealed with a key only
  this user's keychain releases after first unlock, never synced and never in a backup, so another macOS account, a
  restored backup on another device or a copied disk image cannot read them.
- *A stolen locked device*: the key is unavailable before first unlock (and the files are sealed even if the container is
  copied off).
- *A malicious or compromised host (or a second paired host)*: it holds only its own `idKey` (never `sealKey`, never
  another host's keys), so it learns nothing about tiles from another host (no cache-existence oracle across hosts), and within its own pairing it learns only which of
  the ids it advertised in this session the viewer lacks, which is no more than the pixels it already sent before.
- *Network observers*: nothing new; ids and misses travel inside the authenticated QUIC session.
- *Not addressed*: a user who can unlock the device and run code as the user can read the screen too; that is the
  device's own security.

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
  **Pairing UI (2026-10-20)**: the Mirage app's menu-bar item on the host Mac; "Pair a Device…"
  opens a window with the 6-digit code (3 + 3), a QR code and a countdown ring. `miraged` stays
  headless: the app drives it over the **local control socket** (`LocalControl`:
  `~/Library/Application Support/Mirage/control.sock`, the directory 0700, the socket 0600, the
  peer's uid checked; one JSON object per line, versioned; requests `hello`, `openPairing`,
  `closePairing`, `decide`, `status`; events `hello`, `pairing` on every rotation, `confirm`,
  `paired`, `pairingClosed`, `status`). The same path and user hold when `miraged` runs as the
  app's login-item helper (SMAppService).
  **The host inside Mirage.app (2026-10-20)**: `miraged` ships in the app bundle
  (`Contents/MacOS/miraged`, built by the app target's Embed host phase, `scripts/embed-host.sh`)
  with its LaunchAgent plist (`Contents/Library/LaunchAgents/com.paulherz.mirage.host.plist`:
  `BundleProgram`, `serve --log-file ~/Library/Logs/mirage-host.log`, KeepAlive, the same label
  as the old standalone agent). The app's menu-bar item turns it on and off ("Allow Connections
  to This Mac": `SMAppService.agent` register/unregister), pairs ("Pair a Device…"), lists and
  revokes paired devices, shows who is streaming, and shows "Mirage needs Screen Recording /
  Accessibility" with buttons to those Settings panes until the host process itself sees both
  grants. Identity, pairings and resume state stay in `~/Library/Application Support/Mirage`, so
  a migrated host keeps every pairing. `miraged` is signed with the Apple Development identity
  under the stable identifier `com.paulherz.mirage.host`: TCC's grants follow its designated
  requirement (identifier + team), so they survive rebuilds and the move into the bundle
  (observed: the bundled binary on the MacBook found both grants already). The CLI stays:
  `/Applications/Mirage.app/Contents/MacOS/miraged serve | devices | revoke | pair`.
  `scripts/migrate-host-to-app.sh` moves a host once; `scripts/deploy-host.sh` deploys the app.
  While connections are allowed the app is a login item too (`SMAppService.mainApp`, the
  Tailscale pattern): it starts at login as a menu-bar accessory (no Dock icon, no window),
  becomes a regular app while a viewer or the connect window is open ("Connect to a Mac…", or a
  click on its icon), and goes back to the menu bar when they close. Quitting asks whether to
  keep allowing connections; the host keeps running headless unless the answer is Stop. A host
  waiting for Login Items approval (`SMAppService.Status.requiresApproval`) shows as such in the
  menu ("Waiting for approval in Login Items", with a button to that pane). Code and QR rotate every
  30 s while the window is open, each attempt takes the current one (both rotate at once: single
  use), and the window closes on success or after 5 min (`PairingWindow`). The QR is a link,
  `miragerd://pair?host=<tailnet name>&addr=<tailnet IP>&port=<port>&key=<SHA-256 of the host's
  Ed25519 key, base64url>&secret=<128 random bits, base64url>&exp=<unix time>` (`PairingLink`):
  the secret is a high-entropy CPace password run through the same exchange as the code
  (`PairRequest.secret`), and the viewer refuses a host whose key does not hash to `key`. Both
  ends confirm: the viewer shows "Pair with <host>?" with the key fingerprint before dialing (an
  opened link never connects silently), and the host asks "<device> wants to pair with this Mac.
  Allow / Deny" after the exchange verifies the device's identity and before it is authorized,
  for a code and a link alike (with no app connected, `miraged pair` asks its terminal instead). iOS
  scans the QR from the code field (VisionKit) or opens it from Camera (`miragerd` scheme on iOS
  and macOS). A failed pairing ends the viewer's attempt instead of retrying a burned code.
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

**Security review checklist** (every change that touches pairing, persistence, or what the host learns):
- [ ] Pairing secrets and per-pairing keys stay in the keychain, `ThisDeviceOnly`, not synchronizable.
- [ ] Anything persisted about a host's screen (the tile cache, §3.0c) is sealed at rest (AES-GCM, key in the keychain),
      excluded from backups, in the user's own container, and deleted with the pairing.
- [ ] Identifiers derived from screen content are keyed per pairing (HMAC), never bare hashes.
- [ ] The host learns nothing about the viewer's stored state beyond answers to what it asked in this session.
- [ ] New control messages are only sent to viewers that announced them (versioned request fields).
- [ ] No screen content in logs (sizes, counts and rects only).

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
menu bar), front first, up to 16 windows or 48 Mpx, gets its own SCStream at the stream's pixel scale, shadow
left out (since 2026-10-19 a display filter excluding every other window, not `desktopIndependentWindow`: see §6
"No screen-sharing badge"), child windows included (macOS 26
draws a titled window's traffic lights in a 66×20 child window of their own; the window list folds such
children into their parent). The display stream excludes exactly the windows the viewer holds as layers,
and their children, and is captured without shadows; the viewer draws a macOS-style soft shadow per layer
(key window, inactive, menu). Everything else in the on-screen list (menus, popovers, the dock, the menu
bar, overflow windows) stays in the display layer and the client draws it as a *cut-out* of that layer at
its frame, in z-order, so menus still sit above windows. A new layer is announced (`reset` with its pixel
size), gets one lossy WebP still (~0.15 s of the tile budget, upscaled on the client) and then lossless
blocks, the layer under the pointer first, then the focused one, pipelined across all layers (a new block starts
while the unacked ones total under ~0.5 s of the tile budget: one at a time, each waiting for its ack, held
refinement to ~40 % of the target at a 220 ms RTT); the display layer keeps its tiny-keyframe ladder. Right
after the window stills, the desktop's menu bar and Dock (the screen's frame minus its visibleFrame) go
lossless and are shown on arrival, not staged: they are on screen whatever the windows do, and waited ~45 s
at the lowest rung behind every window's levels and the desktop's centre-first blocks on an iPhone connect. Each layer has its own tile tracker, last frame, scroll detection, per-tile capture sequences on
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

**As built, M3.2 Unified mode (2026-10-19).** The same session switches Desktop ↔ Unified locally (⌃⌥⌘U, View ▸
Unified Windows, `--unified`); nothing reconnects. Each window layer becomes a titled `NSWindow` with its standard buttons
hidden and a transparent full-size title bar: the window server gives it the native shadow (key and inactive), edge
resizing, Mission Control, ⌘`, the Window menu, tiling and the genie minimize, and every pixel inside is the host's,
drawn 1:1 from the layer's canvas (one stream pixel per backing pixel; Unified asks for a host-points × backing-scale
stream when the current one is more than 15 % off) through the same progressive presentation. The traffic lights are
the host's own pixels: they are already styled and placed for that window's toolbar, which local buttons would have to
re-learn per window style and would show twice whenever they missed. The host publishes their rect (the macOS 26
traffic-light child window, `WindowInfo.controls`) and clicks on them are handled locally: close → AX close (the window
goes when the host's list drops it, after any save sheet), minimize → the local genie into the local Dock plus AX
minimize (the restore goes to the window's last AX target, since a minimized window leaves the host's list), zoom →
AX zoom. A title-bar press (right of the traffic lights, top 28 pt) that moves becomes `performDrag`; any local move or
live resize becomes a local frame override and one window command once it settles (a move 150 ms after the drag
stops, a resize at the end of the live resize: each host-side move re-captures the window there, §6 M3.2); the canvas is drawn 1:1, never stretched, and a resized layer keeps its old picture at
the top-left until the host's new capture replaces it. A purple outline follows the window's corner radius, measured
from the canvas alpha. Menus, popovers and tooltips are borderless child windows of the frontmost window of their app
they touch, cut from the display layer; a sheet-like window in another's top band is its child. A raise on the host
(an app opening a window) brings that window front here when the viewer is active. A `viewInterest` message tells the
host what is shown: in Unified mode window layers are not held back for being covered on the host's screen, and the
display layer is sent only for cut-out-safe windows above the normal level (menus, popovers; the host knows them, so a
new menu costs no extra round trip) and the rects the viewer asks for (status items); desktop motion elsewhere is not
encoded at all, and the desktop's fresh picture no longer gates window layers.

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
  then lossless lands in large centre-first blocks sized to ~0.25 s of the tile budget, pipelined
  (≤ ~0.5 s of it unacked). Progressive steps and refinement blocks crossfade in over 150 ms on the client.
  64-px tiles are strictly for changes. Extreme is video-minimal on the tiny rung (5 fps), not
  video-off.
- **Scheduler, every tier.** (1) changed pixels within ~200 px of the last input event go at once
  on a second, interactive QUIC stream regardless of budget; (2) other changed pixels on budget;
  (3) copy-rects on the interactive stream; (4) refinement only on leftover budget, yielding
  150 ms while changed pixels use the link (over a quarter of the tile budget in the last 150 ms;
  yielding after any three tiles let a few animating windows hold refinement at 0 kbps for minutes
  on an idle link), ≤ 300 ms of link in flight for tiles, ≤ ~0.5 s for blocks (RefinementPacer).
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
  cursor, and keeps the ladder rung. A viewer that holds no picture says so in that stream request
  (`holdsPicture: false`: an iOS app relaunched with its keychain-saved token starts with empty canvases;
  the masked keyframe and unchanged diffs left it grey until the stream size changed): `resume` then
  starts every layer over with a fresh picture (`ResumePicture`, trigger "viewer holds no picture") while
  the controller, tier, rung and all sequences carry on. The viewer keeps its canvas and predictor across the gap; a
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

### 3.3d Picture correctness invariants (2026-10-20, from phrz's Finder and Dock runs on mac-daddy)

Wrong pixels (a stacked toolbar, a vacated tooltip fragment, striped icons) are worse than soft ones and never wait for
refinement budget. What the host counts as delivered must be what the viewer shows:

1. **Ordering.** Every message that changes a layer's pixels on the viewer (tiles, copy-rects, levels, commits, resets)
   goes on the tile stream in capture order from `tileQueue`. A message encoded on `tileQueue` is sent from there as soon
   as it is encoded (direct tiles, a window's still); one that hops through the streamer's queue first (refinement, the
   middle and backdrop levels) is checked for staleness there (`changedSince`) and enqueued from that same block, so no
   copy-rect decided later can overtake it. (a80cbe1: direct tiles hopped unchecked; the next capture's copy-rect
   overtook them, and a scrolled Finder window's icons striped while the host counted them delivered.)
2. **A copy-rect only claims what it got right.** Verification is byte-exact for every tile but photographic ones (more
   than 1024 colours in a 64-px tile, which keep a tolerance): at native scale scrolled pixels are bit-identical, and a
   tolerance let a wrong-period copy of Finder's near-identical label rows pass (the label row repeated at the scroll step).
   Only textured tiles are evidence (flat ones match at any shift): a copy needs at least 20 % textured tiles and its
   confidence counts them alone. The region is the scroll view under the pointer (the AX scroll area of the topmost
   normal-level window, which a wheel event is attributed to), else the changed tiles' bounding box; it is never learned
   from earlier copy-rects (one bad copy taught the whole window and the window body, sidebar included, moved on the viewer).
   On periodic content the profile ties at several shifts: each near-tie is verified, the one explaining the most exact
   area wins, and the wheel delta (magnitude) breaks a tie; exactness makes a wrong period harmless to correctness.
   Destination tiles that fail verification are direct changes due now
   (9755f02), also where the host saw no change; a destination copied from a tile the viewer holds wrong (a pending direct
   change) is wrong too (6f9cddb); leading/trailing rows and columns that mostly fail are left out of the copy-rect
   (63d5545: a translucent toolbar over a scroll view) and go with the exposed strip, lossy at half size.
   Video rides datagrams and cannot be ordered with the stream: the viewer skips a video tile where pixels from a newer
   capture already landed, and the host sends no video for a layer while its copy-rects flow (the 300 ms copy gate); the
   tiles wait as direct changes instead (280 stale video tiles per Finder scroll on mac-daddy before this).
   A copy-rect's new content (changed tiles inside its region that it does not explain: the exposed strip) goes with it,
   whatever the per-tile rate limit or the budget: held back, the next copy-rect copied the not-yet-updated rows on and the
   viewer showed them smeared. So does everything the copy-rect leaves wrong (destinations that failed verification, copies
   of pixels the viewer holds wrong; waiting for budget showed gaps and repeated rows for up to 1 s), and a wheel scroll no
   copy-rect verified for sends its region's changes the same way. It goes as lossy WebP (half size, q60) on the stream, right behind its copy-rect, and is refined
   lossless once it settles: lossless it cost 3.7 Mbps for 5 s of Finder scrolling at native scale on an 800 kbps link.
3. **A tight box only where the viewer holds the previous frame.** A tile still owing an update goes whole (2df0793).
4. **Backstop.** The picture audit compares fingerprints of tiles the host believes delivered with the viewer's canvas,
   for the desktop and every shown window layer (c9f678d), newest changes first; mismatches are resent as direct changes.

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
- **Delivery rate, with or without video** (after phrz on 4G, 2026-10-21: a still screen's target climbed to the 50 Mbps
  cap with no video delay to stop it, refinement queued megabytes in QUIC's buffers, and parts of windows stayed lossy).
  Every acked byte counts (tile messages, blocks, video frames): bytes acked over max(1.5 s, 4 × srtt), windowed max over
  10 s (max in startup, 75th percentile after: retransmissions land in clumps), on the viewer's receive times (acks
  return over the uplink in clumps); samples taken while the host had nothing to send (`noteIdle`) only raise it. The target stays under 2 × that in
  startup (until three windows held by the in-flight cap bring no 25 % growth, or three with nothing to send) and
  1.1 × after (the estimate itself reads up to ~1.2 × a shaped link), and refinement keeps tile-stream bytes in flight
  under 2 × the bandwidth-delay product (delivery rate × min RTT; 3 × in startup; at least 32 KB). Changed pixels are not held by the
  in-flight cap. Shaped-link tests (Fast 4G, Slow 4G, Japan bus; still screen, endless and 3 MB backlogs): the target
  settles at 1.0–1.1 × the link, the link stays busy, acks stay under 2 s, the backlog drains. Blocks are at most half
  the in-flight cap, and blocks still being encoded count toward it.

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
- **As built, M3.2.** Menus: while a remote window is key the local menu bar is the Apple menu, this app's own menu
  (mode switch, dock, quit), then the remote app's menus from `AXMenuBar`. The bar's titles and every menu's first level
  are walked once per app (again after 30 s), each menu is refreshed when it opens (it shows the cached items at once and
  updates in place when the answer arrives, so enabled states and marks follow the app), submenus load the same way, and
  a choice is an AXPress on the host after checking the item's title is still at that path. Key equivalents are shown;
  the keystroke itself goes to the host as a key. An app whose menu bar Accessibility cannot read gets its part of the
  host's menu bar as a strip of pixels under the local menu bar, clicks mapped back. Dock: the host's regular running
  apps in launch order, icons as 128-px PNGs cached by bundle id on disk, the active app marked; a click activates the
  app there and brings its windows front here; it floats above the local dock (inside the screen's visible frame) while
  the viewer is active. Status items: macOS 26+ draws all of them inside the one menu-bar window (no level-25 windows
  are listed any more), so the host reads each app's `AXExtrasMenuBar` every 3 s and on app changes; the strip under the
  right end of the local menu bar crops those rects from the display layer, system-owned items (Control Center, the
  clock, Spotlight, input menus) left out, and a click goes to the item's host coordinates; the menu or popover it opens
  is a transient anchored under the local item.
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

### 3.10 Host updates and distribution (design, 2026-10-25; for phrz's approval)

Today every host is updated by `scripts/deploy-host.sh` from phrz's MacBook: an Apple Development build copied by rsync,
one host at a time. That does not scale past mac-daddy. The goal: every Mac running Mirage knows its version and channel.
Every viewer shows when a host is behind. One tap in the viewer, or one command over SSH, updates a host safely.
A bad build rolls itself back.

**Version identity.**
- Every build carries `MirageVersion { version: "0.4.0", build: 412, commit: "69bb8ba", channel: nightly|beta|stable }`.
  - `build` is monotonic: the count of commits on main, stamped by the release script into `CURRENT_PROJECT_VERSION`.
  - `version` is `MARKETING_VERSION`.
  - The channel a build was published to is stamped in `Info.plist` (`MirageChannel`). A host can follow a different
    channel than the one its build came from (a setting, below).
- Handshake fields:
  - `Hello.viewerVersion` and `Welcome.hostVersion` (structured; `hostBuild` stays for older viewers).
  - `Welcome.latestAvailable`: the newest build the host's last feed check found on its channel. The host is the source
    of truth, so an iOS viewer never fetches the feed itself.
  - `Welcome.updatePolicy`: what that viewer may do, below.
- **Protocol compatibility:** today `HostSession` rejects any `protocolVersion` other than its own. Mixed versions across a
  fleet make that untenable. The host accepts `Mirage.minProtocolVersion ... Mirage.protocolVersion` and gates newer
  features on the peer's version (as `StreamRequest.tileKeys` already does). `Reject` gains `code: .viewerTooOld |
  .hostTooOld`, so the viewer can say which side to update instead of showing a string.

**The outdated marker.**
- Host row in the viewer's list of hosts: a small "Update" badge when `latestAvailable.build > hostVersion.build`. A red
  "Update required" badge when the host rejected the viewer as too old, or the reverse. The row's detail shows
  "0.4.0 (412) → 0.4.1 (420), nightly".
- The host's menu-bar item shows "Update available: 0.4.1" with Install now / Later.
- The Mac viewer's About shows both its own version and the host's (already partly there through `hostBuild`).

**The remote trigger.**
- New control messages (paired, authenticated session only):
  - viewer → host: `updateHost { targetBuild }` and `rollbackHost`;
  - host → viewer: `updateStatus { phase: checking|downloading|verifying|installing|restarting|done|failed|rolledBack,
    progress, message }`.
- **The viewer never sends code.** The host fetches the build from the feed and verifies it itself. The trigger only names
  a build that the feed already lists. A compromised viewer can therefore install at most a genuine, newer, signed Mirage.
- **Who may trigger:** any paired device. Pairing already grants full keyboard and mouse control of the Mac, so installing
  a signed newer build adds no power. A per-host setting can restrict it to "this Mac only" (menu bar or SSH).
- **Restart during a stream:** the triggering viewer shows "Updating mac-daddy…", keeps its last picture dimmed, and
  reconnects on its own once the new host listens. Other viewers with a stream open get a notice first. The host never
  restarts on its own (policy below) while any stream is open.

**Feed and channels (GitHub Releases on the public `phrz/mirage`; no token needed).**
- Channels:
  - **stable:** tags `vX.Y.Z`;
  - **beta:** `vX.Y.Z-beta.N`;
  - **nightly:** any main commit that passes the suite, published as a release `nightly-<build>`. The release script
    prunes nightlies older than the newest 10.
- Each release carries:
  - `Mirage-<version>-<build>.zip` (`ditto -c -k --keepParent` of the notarized, stapled app);
  - `manifest.json`: `{channel, version, build, commit, minProtocol, protocol, minOS, zipURL, zipSHA256, zipSize,
    notes, published, expires}`;
  - `manifest.json.sig`: an Ed25519 signature over the manifest bytes. The key lives in phrz's keychain (and later a CI
    secret); the public key is compiled into the app. CryptoKit's `Curve25519.Signing`, as for the host identity.
- The channel heads are three small rolling releases (`channel-stable`, `channel-beta`, `channel-nightly`) whose only
  asset is the current manifest and its signature. A check is then one unauthenticated GET of
  `releases/download/channel-<name>/manifest.json`, which needs no GitHub API rate limit.
- `expires` (published + 30 days for nightly, + 1 year for stable) stops a stale or replayed manifest from freezing a
  host on an old build.
- **When the host checks:** at start, every 6 h, and on a viewer's request. The check uses jitter and is skipped on
  metered or Extreme links: the host's own uplink, not the viewer's.
- **Host settings** (`updates.json` in Application Support; the menu bar and `miraged update --set` edit them):
  - `channel`: stable by default; mac-daddy is on nightly.
  - `policy`: `notify` (default) | `autoWhenIdle` | `manual`. `autoWhenIdle` installs only when no stream has been open
    for 30 min, between 02:00 and 05:00 local time.

**Verification before anything is replaced (all public API).**
1. The zip's SHA-256 and size match the signed manifest. The manifest's `build` is greater than the running build;
   rollback to the kept previous bundle is the only way down. Its `minOS` and `minProtocol` are satisfied.
2. Extract with `ditto -x -k` into `~/Library/Application Support/Mirage/Updates/<build>/`.
3. Check the code signature: `SecStaticCodeCheckValidity` with `kSecCSCheckAllArchitectures | kSecCSStrictValidate`,
   against a requirement pinned in the running binary:
   `anchor apple generic and identifier "com.paulherz.mirage" and certificate leaf[subject.OU] = "M8MME6Q9DA"`.
   The embedded `miraged` is checked the same way with `identifier "com.paulherz.mirage.host"`.
4. Check notarization: `SecAssessmentCreate` (the Gatekeeper assessment `spctl` uses) on the staged bundle must accept
   it, with the ticket stapled.
5. Run a self-test: the staged `Contents/MacOS/miraged --self-test` must exit 0 within 10 s. It loads (catching
   dyld/architecture breakage), opens its stores read-only, binds no port and prints its `MirageVersion`. That version
   must match the manifest.

**Atomic swap with rollback.**
- Stage the verified bundle on the same volume as `/Applications`. That is the normal case: `~/Library` and
  `/Applications` share the Data volume. Check `st_dev`; if they differ, copy into `/Applications/.Mirage-staged.app`
  first.
- Write `pending-update.json {from, to, attempts: 0, deadline: now + 5 min}`.
- `renamex_np(staged, "/Applications/Mirage.app", RENAME_SWAP)`: one atomic APFS swap, with no instant at which the app
  is missing. The old bundle ends up at the staged path and is moved to `…/Mirage/Previous/Mirage.app`.
  - Exactly one previous bundle is kept. It is kept outside `/Applications`, so Launch Services and Spotlight don't list
    two Mirages.
  - Running processes keep their mapped old code.
- `exit(0)`: the login-item agent is `KeepAlive`, so launchd starts the new `miraged` from the same path. The
  `SMAppService` registration and the TCC grants follow the bundle path and the designated requirement, both unchanged.
- **Commit:** the new host's `main` first increments `attempts` in `pending-update.json`, then starts normally. It commits
  (deletes the file, logs "update committed 412 → 420") once it is healthy:
  - the QUIC listener is ready;
  - the local control socket is up;
  - a capture probe returns a frame, or reports exactly which TCC grant is missing.
- **Rollback:** if `attempts` reaches 3, or the deadline passes without a commit, the new binary swaps
  `Previous/Mirage.app` back with the same `renamex_np` and exits. The old host starts and reports `rolledBack` with the
  new build's last log lines to the viewer that triggered the update. The bad build is marked skipped in `updates.json`
  until a newer one appears.
- **The one hole:** a build that dies before `main` runs (a dyld failure) would never count its attempts. The self-test
  in step 5 catches that before the swap. `scripts/rollback-host.sh HOST` does the same swap over SSH as a last resort.
- A Mirage viewer window open on the host Mac keeps running the old code. It shows "Mirage was updated: Relaunch".

**Developer ID, notarization, and the one-time re-grant.**
- Release builds are signed with the Developer ID Application certificate of team M8MME6Q9DA, with hardened runtime
  (required for notarization; capture, input injection and QUIC need no exceptions), notarized with
  `xcrun notarytool submit --wait --keychain-profile mirage`, and stapled.
- Builds downloaded from Developer ID releases open without right-click → Open or removing the quarantine flag. That is
  what phrz's other Macs need.
- **The cost:** the designated requirement of a Developer ID build differs from that of an Apple Development build (a
  different certificate chain, same team). So the Screen Recording and Accessibility grants on mac-daddy must be given
  once more at the switch. After that they survive every update, because every release keeps the same requirement.
  - `deploy-host.sh` keeps Apple Development signing for quick inner-loop deploys only if phrz accepts flipping grants.
  - Recommended instead: `deploy-host.sh` signs with Developer ID too, without notarizing (notarization isn't needed for
    rsync-copied bundles, which carry no quarantine flag). One re-grant then, and none afterwards.
- `scripts/release.sh [nightly|beta|stable]` runs on phrz's MacBook, where the identities and the notarytool profile
  live:
  1. runs the suite;
  2. stamps the version;
  3. builds the app; signs, notarizes and staples it;
  4. zips it and writes and signs the manifest;
  5. publishes the release and moves the channel head with `gh release`.
- GitHub Actions comes later, when macOS runners carry the Xcode beta this repo needs. The script is written so a CI job
  can call it unchanged.

**First install over SSH, and the fleet.**
- `scripts/install-host.sh HOST`, a generalisation of `deploy-host.sh` and `migrate-host-to-app.sh`:
  1. checks SSH and the macOS version;
  2. copies the newest release zip for the chosen channel (or a local build) and extracts it into `/Applications`;
  3. runs `open -a Mirage --args --allow-connections` to register the login-item agent;
  4. waits for the agent;
  5. prints what still needs a person at that Mac: the Screen Recording and Accessibility grants, which TCC never allows
     remotely (not even MDM can pre-grant Screen Recording), and Login Items approval if `SMAppService` reports
     `requiresApproval`;
  6. prints the pairing code (`miraged pair --code`), so the device can be paired from the iPhone at once.
- `scripts/fleet.sh hosts.txt status|install|update|rollback` runs the per-host scripts in parallel and prints one line
  per host:
  `mac-daddy  0.4.0 (412) nightly  latest 420  streaming: no  grants: ok`.
- `miraged update [--channel c] [--check|--now|--rollback]` is the same updater the remote trigger uses, so SSH and the
  viewer share one code path. `fleet.sh update` is `ssh HOST miraged update --now` for each host.

**Homebrew (a complement, not the main path).**
- A tap `phrz/homebrew-mirage` with a cask that installs the stable zip. The cask is `mirage`: no cask of that name exists
  in Homebrew today, and the tap prefix keeps it unambiguous if one appears.
- It sets `auto_updates true`, so `brew upgrade` doesn't fight the in-app updater, and `zap` removes Application Support
  and the LaunchAgent registration.
- `release.sh stable` bumps the cask's version and SHA-256.

**Viewers.**
- The iOS viewer updates through TestFlight and the App Store.
- The Mac viewer is the same bundle as the host. On a Mac with the host enabled, the host's updater updates both. On a
  viewer-only Mac (phrz's MacBook), the app runs the same updater in-process, from the menu bar and About, with the same
  verification and swap, and relaunches itself.
- A viewer that the host rejects as too old says so in the host row and offers its own update.

**Boundaries for the build session.**
- **It owns:**
  - a new `Sources/MirageUpdater` module (Feed, Manifest, Verifier, Installer, Health, Settings);
  - the version and update fields and the update messages in `Wire.swift`;
  - the protocol range in `HostSession`'s handshake;
  - update status in the menu-bar app;
  - the badge in the device and host lists;
  - `scripts/release.sh`, `install-host.sh`, `fleet.sh`, `rollback-host.sh`;
  - the signing settings in `App/project.yml` and `embed-host.sh`;
  - the `miraged update` and `--self-test` commands.
- **It must not touch:** `DesktopStreamer`, `ScreenCapturer`, `Rate/`, `Render/`, `Tiles/`, the tile and video message
  formats, `ViewerSession`'s streaming paths, or the test bench.

**Milestones.**

| # | Deliverable | Done when |
|---|---|---|
| U1 | Version identity, protocol range, structured reject, outdated badge | An older viewer connects to a newer host (and the reverse), and the row says which to update |
| U2 | Developer ID + notarized `release.sh`, signed manifest, channel heads | A nightly zip downloaded with Safari on a fresh Mac opens with no Gatekeeper warning; mac-daddy re-granted once |
| U3 | `miraged update` with verification, swap, health commit, rollback | Updating mac-daddy over SSH takes < 30 s to "committed"; a deliberately broken build (exits in main) rolls back by itself |
| U4 | Remote trigger and status from the viewer | One tap on the iPhone updates mac-daddy, and the viewer reconnects on its own |
| U5 | `install-host.sh`, `fleet.sh` | A second Mac goes from nothing to paired with one command plus the two grants |
| U6 | Homebrew tap; `autoWhenIdle` policy | `brew install --cask phrz/mirage/mirage` gives a working host |

**Open questions for phrz.**
1. Switch `deploy-host.sh` to Developer ID now: one Screen Recording and Accessibility re-grant on mac-daddy, then never
   again? (recommended)
2. Should any paired device be able to trigger an update, or only devices he marks as owner?
3. Default policy `notify`, with mac-daddy on nightly plus `autoWhenIdle`?

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
- The video ladder on a large full-motion layer (2026-10-22, bench `--motion --translucent`, 3200x1588 on Fast 4G):
  capture and encode reached ~10 fps against the 30 wanted, the shortfall read as budget-limited, and the ladder fell to
  the tiny rung (400x224 for the whole layer) with an 8.8 Mbps target unused. Whether a shortfall the host itself causes
  (capture or encode time, not the link) should drop rungs: measure on real content before changing it.
- Full-window motion in a translucent window (2026-10-22, bench `--transmover`, 600x400 plasma, Fast 4G, 30 s): opaque it
  goes as video, ~4.2 MB (video 3.9, direct 0, ~16 fps); at 60 % opacity it costs 9-17 MB, mostly direct lossless tiles,
  with or without the alpha mask (`alphaMask`, off): classify marks it motion, something after it for non-opaque layers
  sends it lossless. Parked with the mask; start there.
- The connect probe on real links: in the lab the shaper sits in front of QUIC and its timers clump arrivals, so both
  the densest-burst and whole-train reads say little (8.1 Mbps profile read 24-68 Mbps). Judge it on dummynet or a
  phone hotspot; until then it only raises the start, clamped at 4 x.
- A rate collapse on Fast 4G (2026-10-24 05:58Z, check-5 run c5n, the first stream after a host restart at 05:57:32): the
  connect probe read 9586 kbps (31 of 40 echoes, no burst) and set 5600, srtt was 476 ms at the tier decision, and the
  target then fell 2435 -> 2552 -> 1079 kbps over 15 s with queue 0 ms, refinement held at "inflight-cap" (588 stops in
  the last 5 s) and both window layers soft at +19 s. The rerun two minutes later reached 9740.
  It recurred once (c5q, 06:20Z): refinement in flight 601 KB against a 272 KB cap, target 5658 -> 2908, "suspend: 183
  tiles of unacked tile messages queued for resend" at the end. Both began within ~30 s of an agent restart (deploys at
  05:57:32 and 06:19:57Z), but two cued restarts mid-run (2026-10-25, 22 s and 32 s into 60 s check-5 runs) and six plain
  runs did not reproduce it: the viewer applied every message it read (queue waits under 70 ms) and refinement in flight
  drained within ~10 s. Unexplained; the 5-s logging (viewer "tile flow", host "unacked") stays on to catch the next one.

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

**Ghosts on the desktop (fourth mac-daddy run, b7fda04).** After each bench move, fragments of the bench
(its purple title band, columns of its text) stayed painted on the desktop at its previous positions for
many seconds. Root cause: the display stream never excluded the bench. Since d5a233b the exclusion
was applied only when every window to exclude had an `SCWindow`, including the folded child windows. The
traffic-light child that CGWindowList reports for a titled window (66×20) is not listed by
ScreenCaptureKit (`miraged probe-layers --mode list`), so the condition never held. The desktop layer kept
the window, its old positions showed it until the window covered them again, and refinement under it was
spent on window pixels. a1c707a did not show it only because the bench there drifted over a layered
window, which hides the desktop layer. Reproduced on loopback with two new test-only knobs:
`MIRAGE_LAYER_APPS="Mirage Test Bench"` (only the bench becomes a layer, so the rest of the screen is
desktop) and the viewer's `MIRAGE_TEST_DELAY_MS=145` (every message from the host handled 145 ms after
it arrived, so the RTT is ~150 ms). The watch scenario now samples the *display* layer at the bench's
previous caption band, wherever no layer covers it, 1 s and 3 s after each burst (`staleSamples`,
`staleBenchPixels` in `--stats`). Before: 10 of 10 samples showed bench pixels. Fix: every layer's own
window is excluded; child windows ScreenCaptureKit does not list stay in the display stream (logged
once). After: 0 of 10, 1.13 MB in 60 s, the same as before.
Two safety nets came with it:
- **Desktop taint (`DisplayTaint`, unit-tested).** For every desktop tile the host records whether the
  last pixels it sent were captured while a window was there: a window planned as a layer whose still
  has not landed, or one that moved in the last 600 ms. A tainted tile that becomes visible and clear of
  windows is re-sent once from the desktop. That is how the first picture's windows are cleaned up:
  217 tiles in the first 15 s of that run, then none.
- **Exclusion-lag detector.** While a layer moves, the host samples 16 interior points of the layer
  against the display capture and logs when the display stream still shows the window. It needs varied
  colours, since white on white proves nothing, and those areas are treated as tainted. It was silent in
  the fixed run.
Also fixed: the viewer's stall watchdog could trap on a UInt64 underflow when a packet was noted after
it read the clock (crash seen under the test delay; a real race).

**Ghosts, second round (fifth mac-daddy run, 258d391).** Worse to the eye: at 7 s a full second copy of the
bench at its previous position, eroding over seconds and reappearing after the bench had covered the spot
again and left. The exclusion line was logged and the detector stayed silent, so the desktop stream still
carried the window while it covered an area. The detector missed it because a white window over white
yields fewer than four sampled colours. Two changes: find out, and make it impossible regardless.
- **Why the exclusion may not hold.** Each exclusion change started its own `updateContentFilter` task.
  Concurrent calls can finish out of order, leaving an older filter in force (at startup "exclude nothing",
  then "exclude the bench" a moment later) while the host believes the window is excluded. Updates are now
  serialized, latest wish wins, and each applied filter is logged ("display filter applied: excluding
  windows [...]"). Whether that was mac-daddy's cause needs that log line from the next run.
- **Exclusion check, once a second.** For each shown layer, the 6 most textured 32×32 blocks of its own
  capture are compared with the display capture at the same place (mean absolute difference). Measured:
  44–142 when excluded, 10–17 when the display stream shows the window. Below 24 it logs "THE DISPLAY
  STREAM SHOWS THIS WINDOW".
- **DisplayGuard (MirageCore, tested)**, on both ends:
  - *Host:* desktop tiles touching a layered window's current frame, or the box it swept in the last 1 s
    grown by 128 px, are never sent, keyframes and video included. They come back only from a capture
    taken after the window left, through the taint re-send.
  - *Viewer:* drops any desktop write touching a layered window's current frame or its last 0.5 s.
  - *Viewer, first-picture contamination:* when a window becomes a layer, the part of its frame not
    covered by desktop-layer windows in front of it is marked as possibly holding the window. Wherever such
    a part shows, it is filled with the desktop's average colour until a clean write lands; every 2 s the
    viewer asks the host (`refreshTiles`) for the ones that show.
- **Headless fidelity (review M1).** Crossfades now settle on the video queue every 20 ms, so a headless
  viewer's canvas matches what a window would show (with the first picture keeping windows in the desktop
  until their still lands, refinement was the only cleanup, and headless never committed it).
- **Test knobs.** `MIRAGE_TEST_NO_EXCLUDE` (host: the display stream excludes nothing, mac-daddy's failure)
  and `probe-layers --mode list` (what ScreenCaptureKit lists against CGWindowList).

Loopback, bench drifting over a bare desktop (`MIRAGE_LAYER_APPS`), ~150 ms RTT (`MIRAGE_TEST_DELAY_MS=145`),
800 kbps, desktop layer sampled at the bench's previous title band +1 s and +3 s after every burst:

| Run | Bench pixels at the old place | Fill shown | Visible unknown at end |
|---|---|---|---|
| 1.7x stream | 0 of 10 | 2 (the +1 s samples) | 0 |
| native 2x (3024×1964 request) | 0 of 10 | 2 | 0 |
| 1.7x, exclusion disabled | 0 of 8 | 2 | 0 |

The GUI worst case (exclusion disabled) shows the bench moving with no copy left behind. The normal
all-layers run: desktop layer 89 KB in the first 5 s and then nothing, the bench its still and blocks, and
the rest of the bytes from a live app window on the host screen. Residual risk: a desktop-layer window
drawn as a cut-out whose CGWindow frame is wider than its visible content (seen only with the test knob
that keeps Astropad's window out of layering) shows desktop pixels in that margin over a window behind it.

**Underlay instead of fill (sixth mac-daddy run, 680e63e).** The exclusion diagnosis held on mac-daddy
("display filter applied: excluding windows [12180]" at +1.3 s, exclusion check difference 48–50,
"excluded"). But each move left a flat grey rectangle (the unclean fill) for 4–6 s, eroding tile by tile,
and stale bench fragments (desktop pixels captured before the filter was applied) next to it, while the
host idled at 5 kbps. phrz's rule is "lossy whole picture first, never a tile march". Changes:
- **The desktop under shown windows is sent ahead (the underlay).** The host records, per window, the
  capture from which the display stream excludes it (`WindowInfo.excludedFrom`). A window that is
  excluded, not flagged by the exclusion check, and at rest for 1 s no longer guards its frame, so the
  desktop under it (clean by then) goes out right after the visible first picture, in large blocks,
  visible areas first. Photographic areas go at q75 (the whole 2x desktop is ≈0.3 MB at q75), UI losslessly.
  Uncovering a region shows real desktop from the client's canvas at once, and q75 tiles are refined to
  the normal quality when a move uncovers them. Moving windows (their 1 s sweep) and windows not yet
  excluded stay guarded.
- **Viewer.** Never commits a desktop write captured before a window's `excludedFrom` where that window
  was before its exclusion (those were the fragments). Guard and fill use the same verified rule, and the
  viewer asks for missing desktop tiles the moment a layered window moves, not on a 2 s poll.
- **Refinement order.** Window stills, then window blocks and per-tile refinement, then the desktop's
  blocks (visible first, underlay after), then the desktop's per-tile refinement. Before this, a
  window's just-uncovered column waited 14 s behind the desktop's first-picture blocks (it showed as a
  blurry column in the GUI).

Loopback, bench drifting over a bare desktop, ~150 ms RTT, 800 kbps; the vacated title band sampled in the
desktop layer +100 ms, +1 s and +3 s after every burst:

| Run | +100 ms | +1 s | +3 s |
|---|---|---|---|
| 1.7x stream | desktop 5/5 | desktop 5/5 | desktop 5/5 |
| native 2x | desktop 5/5 | desktop 5/5 | desktop 5/5 |
| 1.7x, exclusion disabled | fill 5/5 | fill 5/5 | fill 5/5 |

There were no bench pixels in any sample. With the exclusion disabled no clean desktop can exist under a
window, so the safety net shows fill; on mac-daddy the exclusion is verified. GUI at ~20 s: bench crisp
everywhere, and the area a move vacates shows desktop-layer content with no fill and no copy. The desktop
layer's own refinement runs at 0–31 rects per 5 s after the first picture. The bulk of the bytes in these
runs are direct changes of the person's screen, which bare mode puts in the desktop layer.

**What the traffic after a fresh connection is (seventh mac-daddy run, 7548f94).** The picture was right in
every frame (one crisp bench with its shadow, no ghost, no fill, real desktop the moment an area is
uncovered), but tiles ran 540–900 kbps for the first ~30 s with only the bench drifting. The host now logs,
every 30 s, the bytes per layer by class: still, blocks, refine, direct changes, video, underlay. It also
logs the layer's size, how visible it is and its dirty tiles per second, with app names only
("layer bytes, last 30 s (…)"). On loopback (all layers, drifting bench, ~150 ms RTT, 800 kbps,
2600×1688) the first 30 s were every window's lossless blocks (bench 258 KB, Astropad 155, Claude 221), the
desktop's visible blocks (209 KB; they run after the windows by design), the underlay and the
re-refinement of uncovered q75 areas. In the second 30 s the bench, Astropad and the desktop were idle
(desktop 19 KB, the clock), and the only traffic was a window that really changes (Claude, 55 dirty
tiles/s). So it is the first picture of a layered desktop, larger than a single capture's because every
window's content and the underlay are sent. Two parts were avoidable and are gone:
- **Underlay under two or more windows** waits until only one window covers it, since that desktop shows
  only if both move (here the bench sits on a full-screen window: 210 KB → 0).
- **The rest of the underlay goes edge-first**, nearest a window's edges where a move uncovers the desktop.
The bare-desktop check still shows desktop at +100 ms, +1 s and +3 s (15 of 15). mac-daddy's next log will
show the same lines, per app.

**Fill again in the first 30 s (eighth mac-daddy run, ab0df4c).** Steady state was good (20–40 kbps after
~35 s), but for the first ~30 s each move uncovered fill in jagged tiles again. Reproduced on loopback with
two new bench windows:
- `--icons`: a full-screen transparent normal-level window behind everything, with six opaque squares,
  the way a desktop-icons app window looks to the window list.
- `--photo [--front]`: an opaque photographic backdrop.

Three causes, all now fixed:
- **"Covered twice" counted transparent windows.** A transparent full-screen layer made every tile under
  the bench count as covered twice, so its underlay was deferred. The host now measures where each layer
  is opaque, from its own capture's alpha (5 points per tile, refreshed every 500 ms). Only opaque
  coverage counts, for the underlay as well as for "covered twice". The window list carries
  `opaque: false` for mostly transparent layers, and the viewer counts only opaque layers as hiding the
  desktop. The log marks such layers "transparent".
- **The viewer marked a transparent window's whole frame as unclean.** When a window became a layer, the
  viewer assumed its pixels might sit in the desktop canvas across its whole frame. For a transparent
  full-screen window that is the entire desktop, filled until it was all re-sent. Only windows that hide
  what's behind them leave such marks now, and a window reported transparent has its marks withdrawn.
- **A window ScreenCaptureKit does not list was presented as a layer anyway.** The icons window had a
  layer, but its exclusion could not be applied, and the viewer correctly refused every desktop write
  under a layer without an "excluded from" mark, i.e. the whole desktop. A window is now a layer for the
  viewer only once its exclusion is applied. One unlisted window no longer holds back the others' exclusion.
  A window that cannot be excluded within 5 s stays part of the desktop picture for the session.

**Upgrade queue.** The q75→normal upgrade of uncovered underlay now runs from its own budget, 15 % of the
tile budget, after the interactive yield and the motion freeze, so an animating desktop app cannot starve
it and it never competes with interaction. The 30 s log shows it as "upgrade … of the refine".

Loopback at ~150 ms RTT, 800 kbps, bench drifting, vacated band sampled +100 ms, +1 s and +3 s after each
burst:

| Case | Desktop shown |
|---|---|
| Icons window behind | 30 of 30 |
| Plain 1.7x | 27 of 27 |
| Native 2x | 27 of 27 |
| Photographic backdrop (in front of the person's windows) | 30 of 30 |

The photographic run is the one that isolates the desktop layer: 1.2 MB in the first 30 s (the first
picture, including 84 KB of underlay and the upgrades), then **5 kbps in the second 30 s** (the clock)
while the bench keeps drifting.

**Viewer crash (ninth mac-daddy run, ce38da3).** About 25 s in, the viewer trapped on "arithmetic overflow" in
`askForUnknownDesktop`. `hostWindowList` passed the clock read when the control message arrived, and the
stats loop had meanwhile stamped `lastRefreshAskNanos` with a later reading, so `now - last` underflowed.
The two 15:2x reports from the same day were the stall-watchdog underflow fixed in 258d391. Audit: every
clock difference in the viewer, host and MirageCore (rate controller, frame assembler) now goes through
`Clock.elapsed(since:now:)`, which returns 0 when the stamp is later. That is about 70 sites, including
one more real crash candidate in `hostWindowList`, whose layer stamps are also written by
`ensureLayerView`. Unit tests feed saturating differences, out-of-order times through the guard, predictor,
frame assembler and rate controller, and windows hanging off every edge (negative origin; beyond the right
and bottom; a 56700-px loginwindow shield) through the tracker, guard, taint, occlusion, scene plan and rect
subtraction. Loopback after: no crash; the vacated band shows desktop 27/27 (plain) and 30/30
(photographic backdrop), and the photographic desktop is at 5 kbps in the second 30 s.


**Progressive presentation per layer (phrz after the tenth run, 5bd0399).** The picture was right, but the
step from lossy to lossless still arrived block by block, and that tile-in drew the eye. Transport is
unchanged (blocks, priority order, NACK, budgets). What changed is what the viewer shows and when. Each
layer, every window and the desktop, now shows at most three whole-picture steps:
1. **Level 0, at once.** A window's lossy still. For the desktop, the tiny keyframe.
2. **A middle level over the whole layer, in one 220 ms crossfade.** For a window, one lossy WebP of the
   whole layer at full size (q90, else q75, else a smaller q80 picture), sized to about 0.6 s of the tile
   rate. It is sent only when the lossless level of the visible part would take more than about a second
   at the current rate. For the desktop, the ladder climb is now one keyframe straight to the highest
   rung the target affords, not one crossfade per rung.
3. **The lossless level.** Assembled off-screen and presented in one 220 ms crossfade, only once the
   whole visible part of the layer is complete.

How it works:
- **Wire (protocol 4).** A tile message flagged `staged` is part of a layer's next level. A new `commit(layer)` message
  presents it. The tile stream is ordered, so the commit always follows its tiles.
- **Viewer (`Compositor`, tested).** Each canvas has a staging texture for its next level. Staged tiles
  land only there. Every other write (direct tiles, video, copy-rects) lands on the canvas and on staging,
  and on `incoming` while a fade runs over it. A direct change is therefore shown at once and is also what
  the commit shows there: refinement of a region that changed during assembly is dropped, never shown over
  newer pixels. On commit, the staged tiles (merged into row runs) crossfade in together. A commit that
  arrives during a running fade waits for the fade to end. A staged copy-rect moves the staged tiles with
  it. Desktop the scene would draw as fill takes staged pixels at once (a clean picture beats fill).
- **Host.** Blocks, per-tile refinement and the q75→normal upgrade are sent staged. Direct changes stay
  immediate: changed pixels near the input locus, copy-rects, video, tiles the rate limit or the budget
  held back (the tracker now remembers those as `direct`), and taint corrections. The underlay is also
  immediate, since nobody sees it until a move uncovers it. A layer's level is committed when nothing
  visible owes refinement. Pixels that just changed are waited for, so a burst's refinement joins one
  level. After 2 s, a region still changing within the last second is left out of the level instead. For
  the desktop the host also waits, up to 3 s, while the guard releases desktop a window just left, so an
  uncovered region is presented once and not in two parts. Tiles under a cut-out drawn over a layer (an
  alert, another app's window) are visible, not underlay.
- **Order across layers.** The focused (frontmost normal-level) window first, then the other visible
  windows by visible area, then hidden windows, then the desktop: visible part first, then the underlay.
  All stills go before any middle level, and all middle levels before any lossless level.

Loopback, checked with 5 fps frame sheets. The viewer's `MIRAGE_TEST_FRAMES=<dir>` renders the composited
scene off-screen five times a second. `experiments/probes/framesheet.swift` lists, per layer, the runs of
frames in which any 64-px block changed. It counts only blocks that belong to exactly one layer. `MIRAGE_DEBUG_PRESENT` makes the viewer log every staged, shown and committed write.
- **Fresh connection** (three bench windows, one replacing its text every 8 s, 2 Mbps cap, the controller
  starting near 1.7 Mbps): every window shows still → middle → lossless (3 steps), or still → lossless
  where the middle level is not worth it (2 steps). Each step is one run of 1–2 frames, the 220 ms
  crossfade. The desktop shows key → climb → lossless (3 steps). The key and the climb are 400 ms apart,
  so the sheet reports them as one 3–4 frame run.
- **Text burst:** the change itself in one frame (direct), then its refinement as one crossfade 0.4–1 s
  later.
- **Self-dragging bench:** the uncovered underlay is there at once. Its upgrade and the desktop the guard
  releases arrive as one crossfade per move (before this change: three commits 30–150 ms apart).
- No frame shows refined next to unrefined blocks within a layer except during a crossfade. The viewer's
  per-layer counters (`steps`, `looseRefinements` in `--stats` layers) agree: no refinement block was ever
  presented on its own. Watch and drag scenarios: stale bench pixels 0, fill 0, stale commits 0.

**No screen-sharing badge on layered windows (phrz, 2026-10-19).** macOS paints a purple screen-sharing pill
in place of the traffic lights on every window a capture names. phrz's tests, repeated with
`miraged probe-layers --mode badge`:

| Filter | Badge |
|---|---|
| `desktopIndependentWindow` | yes |
| display including the window | yes |
| display excluding the window | no (the excluded window) |
| display excluding every *other* window | no |

The last one is now how each window layer is captured. It shows normal traffic lights, and the window
renders whole even where others cover it.
- **Capture.** A display stream with `sourceRect` on the window's frame (points) and the output at the layer's
  pixel size. The filter excludes every window ScreenCaptureKit lists except the layer's own window and its
  children: other apps' windows, the other layers, and the wallpaper and desktop-icon windows. The layer
  therefore has transparency around its rounded corners. Excluding the applications instead
  (`excludingApplications:exceptingWindows:`) leaves an opaque black backstop around the window. The part
  of a window outside the display is no longer captured; the streamer already treated those tiles as
  occluded.
- **Exclusion list.** Windows that appear over a layer (within 64 pt) are added to its filter. The update
  is serialized, latest wins. Windows already excluded stay excluded, so churn elsewhere costs nothing.
  For the 100–300 ms until a newly opened menu is excluded, it can be captured into the layer underneath.
  The viewer draws the same menu as a cut-out at the same place, so this does not show. Windows
  ScreenCaptureKit does not list (other windows' traffic-light children) cannot be excluded and stay in the
  capture where they overlap.
- **Following a moving window.** On each window-list change the capture moves `sourceRect`. A frame is
  passed on only if its `screenRect` is the window's current frame. For a window whose edges are opaque
  (learned from the first frames; the outermost pixel is the anti-aliased border, about 89 % alpha), a frame
  is also dropped when an edge midpoint is transparent: the window moved before the list said so. A
  bench drag drops about 100 stale and 20 shifted frames per 30 s, and none reach the viewer. The 30 s log
  line "window captures" counts them. `MIRAGE_DEBUG_CAPTURE` logs every frame.
- **Cost.** Like `desktopIndependentWindow`, a source-rect stream reports the whole rect dirty every
  interval (about 8.5 frames/s for a visible window at 10 fps, 0.5–0.9 ms of diff each). Per layer the
  cost is the same order as before, and the output buffers are window-sized. Comparison on this MacBook,
  4 bench windows plus the desktop, 20 s at steady state, with the person's own apps running: host
  1.3 s CPU (new) against 2.7 s (old), RSS 110 MB both. Extrapolated to 16 layers: about 10 % of one core
  for the diff.

  The 16-layer run on mac-daddy could not run: a test host started from a temporary path has no
  screen-recording grant (TCC ties the grant to the binary's path). It needs a one-time grant or a deployed
  binary.
- **Checks on loopback** (bench windows only):
  - The bench title bars, screenshotted while layered, show normal traffic lights.
  - A covered window's capture shows the whole window (`--mode badge` dump).
  - The fresh-connection frame sheet is unchanged: still → middle → lossless per window, a burst as direct
    plus one crossfade.
  - Watch and drag scenarios: stale bench pixels 0, fill 0, stale commits 0.
- **No including filter anywhere.** The display layer excludes windows. The codec probe now also excludes
  windows instead of naming the desktop windows.

### M3.2 (2026-10-19, Unified mode and native chrome)

**Loopback** (this MacBook as host and viewer, host in input-sink mode with `MIRAGE_LAYER_APPS="Mirage Test Bench"`,
two 800×532 pt bench windows, 2 Mbps cap, the GUI viewer in Unified mode, not activated, its windows offset by 660 pt with
`MIRAGE_TEST_UNIFIED_OFFSET` so they do not sit on top of the host windows they show). The `unified` scenario moves a
bench's native window here in 50 steps of 3×1.5 pt per 16 ms (what the window server does on a drag; nothing is
injected) and raises the other one; the `chrome` scenario installs the bench app's menus, opens each, chooses one.

| Measure | Loopback |
|---|---|
| Local move: the window takes its new frame | median 0.18 ms, max 6.6 ms per step; worst step-to-step gap 17–23 ms at a 16 ms target (main-thread jitter of the scripted loop; a real drag is the window server's) |
| Redraws of the moved window during a drag | 0 in 3 of 5 drags (the window server moves the surface); 1–15 when the bench repainted its own caption |
| Host confirms the dropped frame | 55–121 ms after release (trailing command + AX set + one list sample) |
| Bytes during a 0.8 s drag / 3 s after | 9.5–13 KB / 2–9 KB (the bench repainting its caption; 74 KB/144 KB once when it repainted while moving) |
| Window switch (raise the other bench) | host raised it 89–120 ms later; 51–55 KB in 2 s: both windows' active/inactive appearance (title bar, traffic lights) |
| Desktop layer while Unified is on | 0 KB per 30 s (Desktop mode on the same screen: 0.35–0.75 MB per 30 s) |
| Menu bar after a window becomes key | 11–485 ms (first walk includes the AX IPC); menus cached before opening; refresh on open 5–11 ms |
| Menu choice | AXPress request on the host for `[1,0] "New Measurement"` (recorded by the sink) |
| Native chrome bytes | 84 KB on first connect (16 icons as PNG in JSON), then menus ~1–5 KB each |

Things the loopback runs taught:
- A viewer whose host is this Mac captures its own remote windows: the host's `MIRAGE_LAYER_APPS` test filter matched the
  copied window titles and layered them (a hall of mirrors), and windows sitting exactly on their originals were captured
  over them (the bench layer churned at 125 dirty tiles/s). ScreenCaptureKit no longer honours `sharingType = .none`. On
  loopback the native windows are titled `remote window <id>` and offset; with a real host neither arises.
- `NSApp` terminates after its last window closes; ordering the Desktop window out made the viewer quit two seconds into
  Unified mode. It now stays while Unified is on.
- A view interest sent before the stream exists was dropped by the host (no streamer yet); the session keeps it and
  hands it to the streamer it starts. With "nothing of the desktop is shown" from the first frame, the display's base
  keyframe never went out and its fresh-picture gate held every window back; Unified no longer waits for it.
- Status items are not windows on macOS 27; `AXExtrasMenuBar` gives their rects (y = 4.5 pt, inside the bar).

**Real link (mac-daddy running c5b6b5e, this MacBook in Tokyo, RTT 145 ms, 800 kbps cap, stream 3024×1700, two
800×500 pt bench windows, guards on: console unlocked, bench frontmost).**

| Measure | mac-daddy |
|---|---|
| Local move: the window takes its new frame | median 0.5 ms, max 2.8 ms per step; worst step gap 18–20 ms (16 ms target) |
| Host confirms the dropped frame | 194–272 ms with moves streamed at 20 Hz; 346–359 ms with one debounced move (150 ms after the drag stops + RTT + AX) |
| Bytes during a 0.8 s drag | 32–128 KB with moves streamed; 3.3–57 KB with the debounced move (the rest is the previous switch's refinement) |
| Bytes in the 3 s after the drop | **246–314 KB**: the host re-captures and re-refines the moved window (see below) |
| Window switch | host raised it 200–330 ms later (11 ms when it already was in front); **75–182 KB** in 2 s |
| Menu bar after a window becomes key | 156 ms (one RTT; the walk follows); every menu cached before opening; refresh on open 151–165 ms; the choice pressed on the host |
| Status strip | 1 item; the crop shows the menu bar's overflow chevron, not the bench's item: macOS 27 keeps a new app's status item out of the visible bar until it is allowed, while Accessibility still reports it |
| Native chrome bytes | 127 KB on connect (14–15 app icons), menus ~1–5 KB |
| Desktop layer while Unified is on | 0–14 KB per 30 s |

Frame sheets (5 s apart, the two native windows as this Mac shows them, with the window server's shadow and the purple
outline) show the windows correct and crisp between moves; the frame taken right after a move shows the moved window's
text soft for a moment. That is the cost found here: with 5dbdf60's per-window capture (a display stream minus every
other window, `sourceRect` following the frame) a host-side move makes the layer's capture shift and churn (copy-rects
inside the layer, a ~300-tile refinement backlog, a keyframe), so every move costs a quarter megabyte and a visible soft
step, where M3.1's window streams moved for free. Unified therefore sends the host one move per drag, debounced, instead
of a stream; the capture side of it is open (it affects Desktop-mode host drags the same way). Raises cost 75–180 KB for
the same reason plus the active/inactive appearance change. phrz's verdict: pending.

