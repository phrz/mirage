# Mirage reset, 2026-10-28

Written while phrz stepped away after nightly 557. All feature and fix work is frozen until he decides on the
direction below. Two source documents sit next to this one: an independent read of the original brief against today
(`assessment-brief-vs-reality.md`) and the streaming session's inventory of every pipeline path
(`pipeline-inventory.md`). They reached the same conclusion separately.

## What went wrong

The brief (2026-10-16) built everything on **one capture per display**: one picture, sent as a hybrid of video and
lossless tiles, with the cursor drawn locally. On 10-18 Desktop mode became **one capture per window plus a
desktop**, assembled on the viewer, so a window drag could be drawn without waiting for the host. That only pays off
on a slow, distant link. Since 10-25 the link is a 5 ms LAN, where it buys almost nothing.

Per-window capture is where macOS fights back. Window streams start one at a time, a still window sends nothing, an
unlock animation resizes every window, and filter switches race. Almost every bug of the last ten days, and every
mechanism added to hide one (placeholders, warm snapshots, stills, the whole-display handover, the fallback, the
safety net), lives at that seam. Each nightly fixed the symptom phrz reported and opened the next.

| | M1 (10-16) | Now (557) |
|---|---|---|
| Swift in Sources | 3,323 lines | 36,693 lines |
| DesktopStreamer.swift | 250 lines | 5,421 lines |
| Pipeline switches (tunables) | 0 | 14 on/off, plus 46 test-only environment knobs |
| Ways a changed pixel can be sent | 1 (video) | about 12 |

Also found: two test switches left on mac-daddy since the measurement runs took a full-screen screenshot every
second in every session. They're removed now. They probably worsened today's stalls, including 557's 5-second freeze.

## What still works, and is worth keeping

Transport, pairing and resume; the rate controller with today's LAN fixes; hardware video encode and decode with loss
recovery; input; the curtain; unlock with Face ID or Touch ID; the updater; the permissions window; device lists and
Get Info; the test tooling. The most reliable picture in the codebase today is **the whole display sent as video**:
the locked host ran at 26–28 fps with 0 partial frames of 101, and matched the host's own frames cell for cell while
typing.

## Proposed direction

1. **One base, always correct.** One capture of the whole display, one low-latency hardware video stream, decoded and
   drawn as one picture. That's how Screen Sharing, Parsec and Workbench work, and it's Mirage's own M1 plus today's
   lock path. One capture means one frame means one presentation: TRUTH holds by construction, and connect, lock and
   unlock need no handover.
2. **Sharp when still.** When the screen stops changing, one sharpening pass on that same picture: a high-quality
   video frame on fast links, and the brief's lossless tiles on slow ones.
3. **Extras on top, never instead.** The local cursor stays. Scroll and drag prediction become transforms over the
   last whole frame. Unified mode becomes a crop of the whole picture per window, with its own capture only for a
   window covered on the host. Per-window layers come back only if a slow-link test proves they're needed.
4. **Remove the rest.** The seam and compositor machinery, warm pool, placeholders, stills, handover, fovea, and the
   1 Mbps measures on fast links, first behind an off switch, then deleted. DesktopStreamer should end well under
   1,500 lines.
5. **A gate that isn't phrz.** Every nightly runs a scripted session through Mirage and Workbench on mac-daddy:
   connect, typing, scroll, window drag, video, lock and unlock. It records frame rate in motion, time to sharp at
   full scale, partial frames against the host's own picture, and input-to-photon latency, on LAN and on the shaper's
   slow-link profiles. A nightly that regresses, or falls behind Workbench on the LAN, doesn't ship. phrz's sessions
   then confirm results instead of finding bugs.

**The cost:** window drags in Desktop mode are no longer drawn locally. On the LAN that's invisible. On a 220 ms link
it's visible, and that case would wait for prediction over the whole picture.

## Decisions for phrz

1. Is whole-display video the base from now on?
2. Is losing locally drawn window drags at high latency acceptable for now?
3. Is the nightly gate against Workbench the bar, so you stop being the test?

## What happens without him meanwhile

Nothing ships. Work that needs no decision and changes no behaviour may continue: building a whole-display-only mode
behind a switch that's off by default, so it can be measured against today's pipeline and Workbench the moment
phrz is back; and the measurement harness itself.
