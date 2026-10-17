# Mirage

A remote desktop for Macs and Apple devices that is designed around bad links
(high latency, ~1 Mbps) and a tailnet instead of accounts. See [docs/DESIGN.md](docs/DESIGN.md)
for the architecture, the teardown of Astropad's LIQUID that informed it, and the milestones.

**Status: M2.** QUIC link over the tailnet, one-time 6-digit pairing (PAKE), mutual
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

`scripts/make-viewer-app.sh` wraps the viewer in `.build/MirageViewer.app` (SwiftUI/AppKit
want a bundle); `scripts/deploy-host.sh HOST` signs `miraged` with your Apple Development
identity (so the TCC grants below survive rebuilds), copies it over and restarts the LaunchAgent.

## Host setup (once, on the Mac you want to reach)

```bash
scp .build/release/miraged .build/release/mirage HOST:~/.local/bin/
ssh HOST '~/.local/bin/miraged install'      # LaunchAgent, runs at login, logs to ~/Library/Logs/mirage-host.log
```

`miraged serve` runs in the foreground instead. The host generates its Ed25519 identity and a
self-signed TLS certificate on first start under `~/Library/Application Support/Mirage/`.

## Viewer app (GUI)

`scripts/make-viewer-app.sh` wraps the release viewer in `MirageViewer.app`; copy it to
`~/Applications`. Launched from Finder or the Dock it opens a connect window listing your paired
Macs, with a host field and a 6-digit code field for pairing a new one. The command line
(`mirage-viewer HOST [--pair CODE] …`) still works for scripts and headless measurement.

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
than native, so prefer `--scale` ≥ 1 on a big screen). `⌃⌥⌘S` toggles the overlay (RTT, frame
age, fps, video/tile kbps, the controller's target, capacity and queuing-delay estimates, the
ladder rung, copy-rects, prediction confirm/mismatch counts), `⌃⌥⌘↑/↓` changes the bitrate
*cap* by 200 kbps (the controller stays at or below it), `⌃⌥⌘Q` quits. Every other key and
⌘-shortcut goes to the host. The host cursor is drawn locally at your pointer, so mouse latency
is zero; trackpad scrolls and title-bar drags move pixels locally before the host confirms them;
clicks and typing pay the link RTT.

The first picture of a stream is one tiny keyframe within a fraction of a second, then the
ladder climbs and lossless lands in large blocks, never as a march of tiles; on constrained links
quality follows the pointer (foveated). If the link drops, the viewer keeps the last picture and
reconnects by itself. `--observe` shows the picture without forwarding any input.

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
Sources/MirageCore/Render      Compositor (Metal canvas, MetalFX), Predictor (scroll/drag reconciliation)
Sources/MirageCore/Video       VideoToolbox HEVC decoder (macOS + iOS)
Sources/MirageCore/Crypto      CPace PAKE, device identity, sealed box
Sources/MirageCore/Transport   QUIC client/host (Network.framework), framed streams, TLS identity
Sources/MirageCore/Session     host and client protocol flows; DesktopStreamer protocol the host plugs into
Sources/MirageCore/Store       on-disk state
Sources/MirageHost             macOS: SCStream capture (BGRA + dirty rects), tile diff, copy-rect detection, window tracker,
                               HEVC canvas encoder, tile encoder, pacing, CGEvent input, cursor monitor
Sources/mirage-viewer          macOS viewer (AppKit window, CAMetalLayer, SwiftUI overlay, scripted scenarios)
Sources/miraged, Sources/mirage  CLIs
experiments/                   measurements that fixed the design (tilebench, seqbench, probes) and the test bench app
scripts/                       make-viewer-app.sh, deploy-host.sh
```
