# Handoff: Mirage director, 2026-10-28

For a new Claude Code session on phrz-mini-m4-pro taking over as Mirage's coordinator ("director"). Read
`CLAUDE.md` (UI rules), `docs/reset/README.md` (the reset, approved by phrz), then this file.

## Where things stand

- **Direction (approved 2026-10-28):** the render and stream pipeline resets to a known-good base: one whole-display
  capture → low-latency hardware HEVC → datagrams → one presented picture. The viewer-side "mirages" (local
  illusions such as drag prediction) come back later, on top of that base, and must each win a recorded comparison.
  Background: `docs/reset/assessment-brief-vs-reality.md`, `docs/reset/pipeline-inventory.md`,
  `docs/reset/workbench-research.md`.
- **On main:** `wholeDisplayOnly` host tunable (f8b2f79, default off), the gate harness and run-scoped truth
  reference (a2cb029; `scripts/gate.sh`, four shaper profiles), and a release.sh guard against a checkout that moves
  mid-release (6fc32bd). Nightly 564 is current on the `nightly` channel.
- **Branch `gate-additions` (c8d7c12, WIP, untested):** gate metrics for keyframes, frame-pacing p95, idle/active
  kbps, and host-vs-stream pixels.
- **Paused:** all Mirage work was paused for another project's GPU measurements. Resume only when phrz says so.

## Next steps, in order

1. Finish `gate-additions`, test it, merge it.
2. Run the gate against today's pipeline on mac-daddy (baseline), via the installed host and a headless viewer.
3. With phrz's OK, set `wholeDisplayOnly: 1` in mac-daddy's `~/Library/Application Support/Mirage/tunables.json`, run
   the gate again, and compare. Report frame rate in motion, time to sharp, partial frames, latency and kbps.
4. Apply the Workbench lessons to `wholeDisplayOnly`: lossless tiles from the same capture for small changes (typing,
   caret) in the same frame transaction as the video; test 4:4:4 chroma; codec choice by content, never by RTT.
5. Resolution matching (phrz: "Yes, try it"): an option where the host switches its display mode to the viewer's
   size for the session (`kCGConfigureForSession`), with a guaranteed restore on session end, suspend expiry, host
   restart and crash (persist the original mode), and never while someone is at the Mac.
6. Then shrink: put the seam and compositor machinery behind an off switch, then delete it.

## How the work runs

- **Roles:** the director reviews and merges; worker sessions or agents implement on branches. Before merging
  updater or security-sensitive code, get an independent read-only review. Merge by fast-forward or squash in a
  scratch clone, run `swift test` (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer), then push `main` and
  `universal-app`.
- **Releases:** phrz runs `scripts/release.sh nightly --skip-tests` himself (an automated permission check blocks
  agents from publishing). Afterwards, commit the `MIN_BUILD_NIGHTLY` bump it leaves in `scripts/install-host.sh`.
  Never commit in the main checkout while a release runs.
- **Updating hosts:** `miraged update --now` over SSH hands off to the running agent (safe since 537), or the viewer's
  Update button.
- **iOS:** `scripts/testflight.sh` uploads a TestFlight build.

## Rules from phrz (keep them)

- These are his real personal and business Macs: never comb through personal files, never take full-desktop
  screenshots, never kill other people's processes, and never click macOS permission prompts (only phrz does).
  Never handle or type his password.
- **No test copies of the host on his Macs.** Every new binary that starts screen capture triggers macOS's
  screen-picker bypass consent prompt. Test through the installed app after a nightly.
- **Gate visible or injected tests:** nobody connected, about 10 minutes without local input, and no system prompt
  on screen. Check first, act second, as separate steps. Capture-only checks may run while he's present.
- **Latency is not bandwidth:** never lower quality because of round-trip time. On a probe-confirmed LAN, start at
  LAN rate.
- **phrz is not the test.** Every candidate passes the gate before he sees it. Report what wasn't verified.
- **UI:** follow `CLAUDE.md`. Say something as an alert or not at all, and never alarm.
- Requesting Apple's persistent content-capture entitlement (for remote-desktop apps) is phrz's to-do.

## Hosts

mac-daddy (Mac Studio, the main test host, Automatic updates), green-machine (iMac), big-mac, and phrz-mini-m4-pro
(new, just installed). phrz-mbp-m4 is viewer only ("Share This Mac" off).
