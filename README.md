# Mirage

A remote desktop for Macs and Apple devices that is designed around bad links
(high latency, ~1 Mbps) and a tailnet instead of accounts. See [docs/DESIGN.md](docs/DESIGN.md)
for the architecture, the teardown of Astropad's LIQUID that informed it, and the milestones.

**Status: M3.2 (Unified mode and native chrome).** QUIC link over the tailnet, one-time 6-digit pairing (PAKE), mutual
Ed25519 authentication, and a hybrid desktop codec: ScreenCaptureKit dirty tiles classified by
motion history; sparse changes (typing, carets, highlights) go as pixel-exact WebP rects on a
reliable QUIC stream, sustained motion goes through hardware HEVC (low-latency) on QUIC
datagrams and is re-sent lossless once it settles; scrolls and window drags are detected on the
host and sent as copy-rects. The macOS viewer composites all of it on a Metal canvas (MetalFX
upscaling when the host drops a rung of the resolution ladder), draws the cursor locally, and
moves scrolled content and dragged windows locally at the input, reconciling with the host's
copy-rects mosh-style. A delay-based rate controller on the host keeps the link out of its queue.
Measured from a Tokyo hotel to Dallas (144 ms RTT, DESIGN §6): idle 18–26 kbps, typing 45–50 kbps,
a keystroke's pixels back in one RTT plus serialization (176–187 ms), scrolls and drags as
copy-rects with local prediction confirmed, text under the pointer pixel-exact 2 s after connecting.
M2.5 (DESIGN §3.3c, §4a, §6 "M2.5") made it tolerant of droppy links, measured on loopback: a session
survives a 30 s outage and comes back in 0.23 s with the picture, caches and prediction state intact
(resume tokens; a killed host gets a fresh stream in 2.2 s with no re-pairing); 5 % datagram loss costs
a longest video gap of 142 ms and a 2 s loss burst is over 134–309 ms after it ends (parity on every
frame, fragment and whole-frame NACKs, keyframes last);
input rides datagrams with mosh-style redundancy and 1000 keystrokes under 5 % loss plus 2 s bursts
arrive once, in order; keepalives are one small datagram per 10 s with a 45 s idle timeout. A field
day against mac-daddy then fixed the delay controller (path delay from video acks only) and the
drag path: refinement is frozen while motion is sustained so video has the whole target, a dragged
window follows the pointer from the host's last confirmed frame, and a refinement block captured
before a move is never committed after it.
M3.1 (DESIGN §3.2 "layered desktop", §6 "M3.1") changed the capture model: the host captures the desktop
without its windows as one layer and every normal window as its own unoccluded layer (ScreenCaptureKit
per-window streams), publishes the window list with frames and z-order, and the viewer composites the
scene itself with a shadow per window; menus, the dock and the menu bar are cut-outs of the display
layer. Dragging a window is local on both sides: a title-bar drag moves the layer at the pointer and tells
the host the frame through Accessibility, a host-side drag arrives as window-list frames at 30 Hz, and
in neither direction does a pixel travel for it (loopback: 0 video frames, 0 copy-rects, 0 bytes of the
dragged window per 0.8 s burst, against 8 fps of video plus 25 copy-rects and 1–1.7 s to crisp before).
`--stats` JSON carries per-layer diagnostics (`layers`: bytes received, canvas, frame, viewport rect,
drawn as layer / cut-out / display, visible or why not, presentation steps); the test bench's `--overlay`
opens a transparent full-screen window, the case that broke the first mac-daddy run. `MIRAGE_TEST_FRAMES=<dir>`
makes the viewer record the composited scene at 5 fps, and `experiments/probes/framesheet.swift` turns that into
change events per layer plus a contact sheet.

M3.2 (DESIGN §3.2 "As built, M3.2", §3.8, §6 "M3.2") adds **Unified mode**: ⌃⌥⌘U (View ▸ Unified Windows, or
`--unified`) turns every remote window into a native macOS window on the same session, pixel-exact, with the native
shadow, resizing, Mission Control, ⌘` and the genie minimize, outlined in purple; the host's traffic lights act locally
(close, minimize into the local Dock, zoom), and moves, resizes and raises are local, with the host following through
Accessibility. Menus and popovers appear as child windows. While a remote window is key the local menu bar holds its
app's menus, read through Accessibility and pressed there; a remote dock lists the host's running apps; a strip under
the menu bar shows the host's third-party status items. In Unified mode the desktop layer is not streamed at all.

## Build

The Command Line Tools' package manifest API is broken on macOS 27 with Xcode 27 beta
installed; build with Xcode's toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
swift build -c release
swift test
```

Products: `miraged` (host daemon + admin CLI), `mirage` (client CLI), `mirage-viewer`
(macOS viewer), `MirageCore` (shared, iOS-compilable), `MirageHost` (macOS capture/encode/input).

`scripts/make-viewer-app.sh` builds `.build/MirageViewer.app`, the macOS slice of the universal app
(`App/Mirage.xcodeproj`, one target and bundle ID for macOS and iOS; `scripts/testflight.sh` ships the iOS
slice to TestFlight); `scripts/deploy-host.sh HOST` signs `miraged` with your Apple Development
identity (so the TCC grants below survive rebuilds), copies it over and restarts the LaunchAgent.

## Host setup (once, on the Mac you want to reach)

```bash
scp .build/release/miraged .build/release/mirage HOST:~/.local/bin/
ssh HOST '~/.local/bin/miraged install'      # LaunchAgent, runs at login, logs to ~/Library/Logs/mirage-host.log
```

`miraged serve` runs in the foreground instead. The host generates its Ed25519 identity and a
self-signed TLS certificate on first start under `~/Library/Application Support/Mirage/`.

## Viewer app (GUI)

`scripts/make-viewer-app.sh` builds `MirageViewer.app` (the universal app's macOS slice, incremental); copy it to
`~/Applications`. On iPhone and iPad the same app (TestFlight) runs Desktop mode: one finger moves a
trackpad-style pointer, tap clicks, two fingers scroll, a long press drags, and the on-screen or a hardware
keyboard types, with the same scroll prediction and typeahead. Launched from Finder or the Dock it opens a connect window listing your paired
Macs, with a host field and a 6-digit code field for pairing a new one. The command line
(`mirage-viewer HOST [--pair CODE] …`) still works for scripts and headless measurement.

On a phone or tablet the picture fills the safe area (in landscape, the full height; the control pill hides itself
after 3 s there, and the small handle in the corner brings it back). Stats are off until the stats button shows them
as a small overlay. Touch gestures:

| Gesture | Does |
|---|---|
| one finger drag | moves the pointer (trackpad style, accelerated) |
| tap / taps in a row | click / double-click |
| long press, then drag | press and drag (title bars move the window at once) |
| two-finger drag | scrolls the remote content (with momentum) |
| two-finger tap | right-click |
| pinch | zooms the view about the fingers' centre, from fit up to 1:1 host pixels and half as far again (at least 3×); while pinching, the fingers' travel pans |
| three-finger drag | pans the view |
| two-finger double tap | toggles fit and 1:1 host pixels at that point |

A two-finger gesture is a scroll once the fingers travel together 12 pt without spreading, and a zoom once they spread
or close by 5 % first; it stays what it became until the fingers lift (so "two fingers after a pinch" pan the view
rather than scroll). Three fingers are always the view pan. The stream is the host display at its own pixels (as the Mac
viewer's native snap): fit shows it downscaled with an area filter (no shimmer on text), and zoom up to 1:1 shows real host
pixels, sharp. Zoom and pan are presentation only: the host sends the same stream at every zoom, orientation and keyboard
state, so no message goes out for them and a rotation never reconfigures the stream (`-nativeStream 0` asks for the old
fit-sized stream instead). An app relaunched by iOS resumes its session with the saved token and says it holds no picture;
the host then sends every layer's picture afresh in the same session (DESIGN §4a). Zoomed in, the
view follows the pointer when it nears an edge, and from 1.5× it glides to keep the caret in view above the keyboard
while typing. The keyboard never resizes the picture; it lifts it, or bounds how far a zoomed one pans.

## Pair a device

On the host (over SSH is fine):

```bash
miraged pair
```

It prints a 6-digit code valid for two minutes, one attempt. On the device:

```bash
mirage connect HOST --pair 123456
```

Afterwards `mirage connect HOST` authenticates with the device key and streams RTT
statistics for the reliable stream and the unreliable datagram flow:

```
  stream   ▁▆▁▆▆▁▆▁▆█▅▁▆▁▁ rtt last  236.9 ms  mean  209.4  min  158.7  p95  247.7  jitter   44.7  loss  0.0%  n=33
  datagram ▁▁▁▆▁▁▁▁▁█▅▁▁▁▁ rtt last  237.2 ms  mean  185.2  min  158.1  p95  247.7  jitter   33.8  loss  0.0%  n=33
```

Admin: `miraged devices`, `miraged revoke <id-prefix>`, `mirage hosts`, `miraged uninstall`.

## View the desktop

```bash
.build/MirageViewer.app/Contents/MacOS/mirage-viewer HOST [--bitrate 800] [--scale 1.0]
```

The viewer requests the stream at its window size (points × backing scale × `--scale`), so
resize the window to change resolution; the host's tiles are pixel-exact at that size (a
window smaller than the host display means downscaled text, which costs 2–3x more per tile
than native, so prefer `--scale` ≥ 1 on a big screen). `⌃⌥⌘U` switches between Desktop and Unified mode, `⌃⌥⌘S` toggles the overlay (RTT, frame
age, fps, video/tile kbps, the controller's target, capacity and queuing-delay estimates, the
ladder rung, copy-rects, prediction confirm/mismatch counts), `⌃⌥⌘↑/↓` changes the bitrate
*cap* by 200 kbps (the controller stays at or below it), `⌃⌥⌘Q` quits. Every other key and
⌘-shortcut goes to the host. The host cursor is drawn locally at your pointer, so mouse latency
is zero; trackpad scrolls and title-bar drags move pixels locally before the host confirms them;
clicks and typing pay the link RTT.

The first picture of a stream is one tiny keyframe within a fraction of a second. Each layer (every
window and the desktop) then improves in at most three whole-picture steps: the lossy first picture at
once, a middle level over the whole layer in one crossfade, and the lossless level, assembled off-screen
and crossfaded in only once the visible part is complete. A refinement block is never shown on its own;
changed pixels still show the moment they arrive (DESIGN §6 "Progressive presentation"). On constrained links
quality follows the pointer (foveated). If the link drops, the viewer keeps the last picture and
reconnects by itself (every second while the host still holds the session, then backing off to
15 s); the host resumes the same session, with its caches, on the new connection. Keystrokes typed
while the host is unreachable are queued (the overlay counts them); after 10 s the viewer asks:
`⌃⌥⌘↩` sends them, `⌃⌥⌘⌫` drops them. `--observe` shows the picture without forwarding any input.

`scripts/resilience-test.sh all` runs the DESIGN §4a loopback scenarios (outage, host restart, 5 %
loss, 2 s bursts, input integrity, keepalive) against a local host in input-sink mode
(`MIRAGE_INPUT_SINK=/path`: the host writes what it would inject to a file and injects nothing);
`MIRAGE_TEST_LOSS=0.05 MIRAGE_TEST_BURST_MS=2000` inject loss in either process's datagram path.
For screenshots of a client against your own Mac, `MIRAGE_TEST_ONLY_APP=com.paulherz.mirage.testbench` puts only the
test bench's windows in the display picture (the rest is black, whatever else is on screen, the lock screen included)
and `MIRAGE_LAYER_APPS="measurement window started by Claude"` keeps every other window from becoming a layer. The iOS
app's `-demo 1` launch argument (`xcrun simctl launch … -connect 127.0.0.1:PORT -demo 1`) then drives its gestures on a
timeline, writing `demo: shot NAME` marks to `tmp/demo.log` in its container when it holds still for a screenshot.

`--headless --duration 60 --stats out.json` connects and decodes without a window and writes
per-second samples plus medians, for measuring a link over SSH. `--scenario typing:30` (or
`scroll:40`, `drag:30`, `idle:20`, `login:30`, `fovea:20`) additionally drives the "Mirage Test Bench" window on the host
(`experiments/testbench/make.sh`, then `open` the app there) with scripted input and reports
bytes into that window, per-burst time-to-crisp and prediction counters. Scripted input is
refused by the host while its console is locked, and the runner injects nothing until the bench
is frontmost and visible in the picture.

### Host permissions (once)

`miraged` needs two TCC grants on the host. On its first start after install it prompts for
both, which also lists it in System Settings. On the host (over ARD or locally):

1. System Settings → Privacy & Security → **Screen & System Audio Recording** → enable `miraged`
   (if it is not listed: `+`, press ⌘⇧G, enter `~/.local/bin/miraged`).
2. System Settings → Privacy & Security → **Accessibility** → enable `miraged` (same `+` trick).
3. Restart it: `launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host`, and check
   `~/Library/Logs/mirage-host.log` says `permissions: screen recording granted, accessibility granted`.

Without 1 the viewer shows "host is missing Screen Recording permission"; without 2 the
picture works but input is silently ignored by the HID tap.

## Security model in one paragraph

Tailscale provides the network: WireGuard, NAT traversal, relay fallback. Mirage adds device
authorization on top. Pairing runs a CPace-shaped PAKE on X25519 with the 6-digit code as the
password and the host's TLS certificate fingerprint as the channel binding, then exchanges
Ed25519 device keys in a sealed box. Every later session signs a transcript that includes the
TLS leaf fingerprint the client saw and fresh nonces from both sides, so TLS can stay
self-signed and unpinned while still being immune to a TLS-terminating man-in-the-middle.
Keys live in `~/Library/Application Support/Mirage/` with 0600 permissions; moving them to
the keychain / Secure Enclave is on the list.

## Layout

```
Sources/CWebP                  libwebp 1.6.0, vendored unmodified (lossless tiles; compiles for iOS)
Sources/MirageCore/Wire        framing, ControlMessage (auth, pairing, stream/ack/cursor/input/window list/rate state),
                               video datagrams + reassembly (region, tile mask, input seq), tile-stream messages
Sources/MirageCore/Tiles       TileCodec (WebP), TileTracker (classification, refinement queue), ShiftDetector (copy-rects)
Sources/MirageCore/Rate        RateController (one-way-delay/dispersion based target, budget split, resolution ladder)
Sources/MirageCore/Render      Compositor (one Metal canvas per layer, MetalFX), SceneRenderer (layers, cut-outs, shadows), Predictor,
                               UnifiedLayout (which host windows become native windows, where, whose children)
Sources/MirageCore/Video       VideoToolbox HEVC decoder (macOS + iOS)
Sources/MirageCore/Input       touch input for iOS clients: Mac key codes, trackpad pointer, scroll momentum, ZoomViewport
Sources/MirageCore/Crypto      CPace PAKE, device identity, sealed box
Sources/MirageCore/Transport   QUIC client/host (Network.framework), framed streams, TLS identity
Sources/MirageCore/Session     host and client protocol flows; DesktopStreamer protocol the host plugs into
Sources/MirageCore/Store       on-disk state
Sources/MirageHost             macOS: display + per-window SCStream capture (layers), tile diff, copy-rect detection, window tracker,
                               AX window commands, per-layer HEVC canvas encoders, tile encoder, pacing, CGEvent input, cursor monitor,
                               `miraged probe-layers` (per-window capture measurements)
Sources/mirage-viewer          the viewer: Session/ (platform-neutral session layer: connection, presentation and prediction
                               state, typeahead), macOS/ (AppKit window, CAMetalLayer, scripted scenarios, Unified mode, native
                               chrome), iOS/ (UIKit Desktop mode: touch pointer, scroll, zoom and pan, keyboards)
App/                           the universal app target (project.yml for xcodegen, the generated Mirage.xcodeproj)
Sources/miraged, Sources/mirage  CLIs
experiments/                   measurements that fixed the design (tilebench, seqbench, probes) and the test bench app
scripts/                       make-viewer-app.sh, testflight.sh, deploy-host.sh, resilience-test.sh (§4a loopback scenarios + dummynet notes)
```
