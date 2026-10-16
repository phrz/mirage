# Mirage

A remote desktop for Macs and Apple devices that is designed around bad links
(high latency, ~1 Mbps) and a tailnet instead of accounts. See [docs/DESIGN.md](docs/DESIGN.md)
for the architecture, the teardown of Astropad's LIQUID that informed it, and the milestones.

**Status: M0.** QUIC link over the tailnet, one-time 6-digit pairing (PAKE), mutual
Ed25519 authentication, stream and datagram RTT measurement. No pixels yet (that is M1).

## Build

The Command Line Tools' package manifest API is broken on macOS 27 with Xcode 27 beta
installed; build with Xcode's toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
swift build -c release
swift test
```

Products: `miraged` (host daemon + admin CLI), `mirage` (client CLI), `MirageCore` (shared).

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
Sources/MirageCore/Wire        framing + ControlMessage
Sources/MirageCore/Crypto      CPace PAKE, device identity, sealed box
Sources/MirageCore/Transport   QUIC client/host (Network.framework), framed streams, TLS identity
Sources/MirageCore/Session     host and client protocol flows (auth, pairing, ping)
Sources/MirageCore/Store       on-disk state
Sources/miraged, Sources/mirage  CLIs
```
