# Mirage

A remote desktop for Macs and Apple devices that is designed around bad links
(high latency, ~1 Mbps) and a tailnet instead of accounts. See [docs/DESIGN.md](docs/DESIGN.md)
for the architecture, the teardown of Astropad's LIQUID that informed it, and the milestones.

**Status: M1.** QUIC link over the tailnet, one-time 6-digit pairing (PAKE), mutual
Ed25519 authentication, and full-desktop streaming: ScreenCaptureKit → hardware HEVC
(low-latency, LTR) → QUIC datagrams → VideoToolbox decode in a macOS viewer with a locally
drawn cursor, mouse/keyboard forwarding and a stats overlay.

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
resize the window to change resolution. `⌃⌥⌘S` toggles the overlay (RTT, frame age, fps,
kbps, decode time, losses), `⌃⌥⌘↑/↓` changes the target bitrate by 200 kbps, `⌃⌥⌘Q` quits.
Every other key and ⌘-shortcut goes to the host. `--headless --duration 60 --stats out.json`
connects and decodes without a window and writes per-second samples plus medians, for
measuring a link over SSH. The host cursor is drawn locally at your
pointer, so mouse latency is zero; clicks and typing pay the link RTT.

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
Sources/MirageCore/Wire        framing, ControlMessage (auth, pairing, stream/ack/cursor/input), video datagrams + reassembly
Sources/MirageCore/Video       VideoToolbox HEVC decoder (macOS + iOS)
Sources/MirageCore/Crypto      CPace PAKE, device identity, sealed box
Sources/MirageCore/Transport   QUIC client/host (Network.framework), framed streams, TLS identity
Sources/MirageCore/Session     host and client protocol flows; DesktopStreamer protocol the host plugs into
Sources/MirageCore/Store       on-disk state
Sources/MirageHost             macOS: SCStream capture, HEVC encoder, ack-paced sender, CGEvent input, cursor monitor
Sources/mirage-viewer          macOS viewer (AppKit window, SwiftUI overlay, AVSampleBufferDisplayLayer)
Sources/miraged, Sources/mirage  CLIs
scripts/                       make-viewer-app.sh, deploy-host.sh
```
