# Mirage M2 code review (2026-10-17)

Scope: `main` from 460ae55 to 2fca7ab (97 commits), i.e. the M2 hybrid codec as built: `FrameAssembler`
and the NACK/parity path, the two tile streams and `ControlSender`, `MacDesktopStreamer` (scheduler,
fresh-picture sequence, token buckets, pacing, recovery), `RateController`/`LinkTier`, the viewer
(`ViewerSession`, `Compositor`, `Predictor`, reconnect, scenario runner) and the input-safety guards.
Read against DESIGN §3.3–3.5, §3.9, §4a, §6 and REVIEW-2026-10-17 §2/§4. Read-only; `swift test`
passes (50 tests) on Xcode 27.1 beta. Nothing was run against mac-daddy.

Line numbers are as of 2fca7ab. Severity: **High** = wrong pixels, a stall, or a multiple of the
bytes the design promises, under conditions the design says are normal (loss, 400 ms RTT, 800 kbps);
**Medium** = visible defect or resource issue under common conditions; **Low** = correctness in a corner,
hygiene, or efficiency.

---

## 1. Findings, ranked

### High

#### H1. Parity reconstruction truncates a missing *non-last* fragment when the only known fragment in its group is the short last one — a corrupt frame is delivered as complete
`Sources/MirageCore/Wire/Video.swift:316-323`

```swift
let known = (lo..<hi).filter { $0 != missing[0] }.compactMap { p.parts[$0] }
let full = known.map(\.count).max() ?? acc.count
let isLast = missing[0] == p.count - 1
let len = isLast ? p.total - (p.count - 1) * full : full
```

Scenario: a two-fragment frame (the common shape of a tiny-rung keyframe or an Extreme/motion P-frame
of 1.2–2.3 KB; parity is always sent on key/recovery frames). Fragment 0 (1157 B) is lost, fragment 1
(say 300 B) and the parity datagram arrive. `known = [frag1]`, `full = 300`, `isLast = false`,
`len = 300`; the guard `len <= acc.count` (1157) passes, so fragment 0 is "rebuilt" as 300 bytes,
`received == count`, the frame completes with 857 bytes missing from the middle of the HEVC sample,
`recoveredByParity` increments, and the decoder gets garbage. VideoToolbox either fails (→ `lost` ack
→ keyframe, which parity existed to avoid) or conceals (→ corrupt reference for every following
P-frame until the next keyframe, and the host never learns). `testParityRebuildsOneLostFragment`
covers "last of 4 missing" and "middle of 4 missing with a full-size neighbour known", not this case.

Fix: the parity payload is zero-padded to the longest member of its group, and a missing non-last
fragment is itself full-size, so its length is `acc.count`. For a missing last fragment the length is
`total − (count−1)·full` where `full` must come from a known *non-last* member; if the group is the last
fragment alone (group size 1), the parity payload is the fragment and `len = acc.count`.

```swift
let len: Int
if !isLast { len = acc.count }
else if let fullKnown = (lo..<hi).first(where: { $0 != p.count - 1 && p.parts[$0] != nil }).map({ p.parts[$0]!.count }) {
    len = p.total - (p.count - 1) * fullKnown
} else { len = acc.count }   // group == [last]
```
Add the 2-fragment test (§2, T1).

#### H2. A frame whose every fragment is lost is invisible: no sequence-gap detection, so no NACK and no `lost` verdict; the next P-frame goes to the decoder with its reference missing
`Sources/MirageCore/Wire/Video.swift:273, 332-348`

`drain()` delivers `partials.keys.min()` whenever it is complete; nothing compares it with
`delivered + 1`. The in-order hold only works for frames the assembler has *heard of* (≥1 fragment or a
parity datagram). Scenario: at the tiny rung a motion P-frame is 1–2 datagrams; at 5 % loss (the §4a
acceptance case) a one-datagram frame vanishes entirely 5 % of the time. Frame N+1 arrives complete,
is delivered, decodes against a missing reference (concealed corruption or a `BadData` error),
and the host is told nothing about N; REVIEW §2.3's "the viewer detects a gap when a later fragment
*or frame* arrives and sends nack" is only half built. Parity cannot help (none is generated for
1-fragment frames; for 2-fragment frames both were lost).

Fix: track `expectedNext = (delivered ?? 0) + 1`. In `drain()`, if the head's seq is greater than
`expectedNext` and the head has been waiting longer than `nackAfterNanos`, emit
`.nack(seq: expectedNext, fragments: [])` (empty = "all"; the host already keeps the datagrams for 2 s)
and hold; give it up with `.lost(expectedNext)` after `timeoutNanos` measured from the head's
`firstNanos`. On the host, `handle(nack:)` (DesktopStreamer.swift:207-213) treats an empty list as every
datagram of that frame (including parity). This also fixes M13.

#### H3. Unacked frames are purged as "stale" after `max(3·srtt, 1 s)`, which is shorter than a paced keyframe's legitimate ack time; the late ack is then ignored, so srtt never learns, the fresh-picture state never advances, and a keyframe loop follows
`Sources/MirageHost/DesktopStreamer.swift:813-816, 959-973, 928-941`

```swift
let staleAfter = UInt64(max(3 * srttNanos, 1_000_000_000))
for (s, f) in unacked where now - f.sentNanos > staleAfter { unacked[s] = nil; statLost += 1; requestRecovery() }
...
if let f = unacked.removeValue(forKey: ack.seq) { /* srtt, rc.frameAcked, freshAcked, LTR */ }
```

`sentNanos` is taken when the first pacing slice is scheduled; a keyframe sized to ~1 s of video budget
is paced over ~0.8 s, then needs RTT/2 + decode + RTT/2 for its ack. `srttNanos` starts at 250 ms and
only updates from acks of frames *still in `unacked`*. Scenario (the Japan bus link, 414–451 ms RTT,
3200×1800): first tiny keyframe acked at ~0.5 s fine; the climb step to rung 3 (1200×675, ~20 KB)
at the backed-off 173 kbps target is paced over ~0.9 s and acked at ~1.3 s > `staleAfter` = 1 s
(srtt still < 333 ms). The host purges it, `requestRecovery()` → `wantKeyframe` → another keyframe at the
same rung while the first is still on the wire (doubling the load); when the first ack arrives it is
dropped (`removeValue` fails), so `freshAcked` never runs, srtt never grows, and the cycle repeats:
a keyframe every ~1 s, `fresh` stuck in `.climb`, so `refine()` (line 772) never runs — no
lossless ever, exactly the "video froze while…" class §6 describes. The 144 ms Shibuya runs sit just
inside the margin (36 KB at 1.25×~500 kbps ≈ 0.6 s + 0.15 s), which is why it was not seen.

Fix (three parts, all small):
1. Size the deadline per frame: `staleAfter(frame) = serialization(frame.bytes at 1.25×budget) + 3·srtt`,
   and store `bytes` (already there) and the pacing rate used.
2. Never purge the frame `fresh` is waiting on (`.base(seq)`/`.climb(seq)`); it has its own timeout
   semantics, and a lost base already arrives as a `lost` ack.
3. Keep a small `recentlyPurged: [UInt32: InFlight]` (≤ 16 entries, 10 s) so a late ack still feeds
   `srttNanos`, `rc.frameAcked` and `freshAcked`. Related: the 1.5 s "viewer skipping frames" safety net
   (line 978) should also add the recovery frame's serialization time before resending.

#### H4. The fresh-picture climb and `tryEncode` use different affordability tests, so the ladder can oscillate tiny→…→N→tiny forever and the lossless-block phase never starts
`Sources/MirageHost/DesktopStreamer.swift:517-525` vs `833-842`

`freshAcked` climbs when `targetKbps ≥ kpix·scale²·0.18` (P-frame density); `tryEncode` then demotes
*any* keyframe whose estimate `w·h·0.025 B` exceeds one second of `lastBudget.videoKbps`. The keyframe is
encoded at the tiny rung, `send()` records `fresh = .climb(seq)`, its ack calls `freshAcked`, which
climbs again from tiny. The loop runs whenever `0.18 ≤ target/(kpix·s²) < 0.2/(videoShare)`; with the
early `videoKbps = 0.9·target` the band is 0.18–0.222, and once tiles are flowing (`reserved` up to
45 %) it is 0.18–0.36 — e.g. a 2 Mbps cap on 3200×1800 at rung 0 (0.347) or 800 kbps at rung 1 (0.247).
Each cycle costs several keyframes (3 + 13 + 23 + … KB), the picture pulses through the crossfade every
few hundred ms, `fresh` never reaches `.blocks`, and per-tile refinement is gated off (line 772).
The only exit is `rc.queueMs ≥ 90` (line 521), i.e. the keyframes themselves building a queue, which is
probably why the hotel runs settled at "rung 2 at 800 kbps" rather than the affordable rung 1.

Fix: one predicate. In `freshAcked`, climb only if the *keyframe* at the next rung fits
(`Double(ew·eh)·0.025 ≤ videoBudgetBytesPerSecond`, the same expression `tryEncode` uses), and in
`tryEncode` skip the tiny-rung demotion when `progressiveKeyframe` is set (that keyframe was just
approved). Log once if they ever disagree.

#### H5. The assembler NACKs fragments that have not been sent yet, and the host resends them unpaced: a paced keyframe goes out 2–3× on the wire
`Sources/MirageCore/Wire/Video.swift:355-357`, `Sources/MirageHost/DesktopStreamer.swift:207-213`

A NACK fires when the head frame has had no fragment for 30 ms and asks for `(0..<count).filter { nil }`
— every index not yet seen, including the tail still being paced. Pacing slices are `queue.asyncAfter`
closures on the same serial queue that runs `captured()` (10–25 ms on a big dirty frame) and the
encoder completion, so 30 ms gaps mid-keyframe are routine, plus Wi-Fi jitter. The host then sends the
whole remainder immediately from `sentFrames` (no pacing, no check that it was sent), and again
`nackRepeatNanos` later (`maxNacks = 2`). On exactly the links where pacing matters, a 36 KB keyframe
costs up to ~100 KB and builds the queue the pacer was meant to avoid, which the controller answers
with ×0.85. `testPacedFrameIsNotDeclaredLostWhileStillArriving` only asserts "not lost".

Fix: (a) gap-based NACK: only indices below the highest index received are candidates after
`nackAfterNanos`; the tail is NACKed only after `nackAfterNanos + k × observed inter-fragment gap`
(k ≈ 4) or when a later frame's fragment has arrived (proof the tail should have landed); (b) host:
keep `sentFrames[seq].sentCount` advanced by the pacing closures and ignore NACKs for indices ≥ it;
(c) rate-limit resends to the pacer (push them into the same slice schedule).

#### H6. Datagram pacing has a floor of one datagram per 5 ms (≈1.85 Mbps), so "paced at 1.25× the video budget" is false below ~1.5 Mbps
`Sources/MirageHost/DesktopStreamer.swift:930-931`

```swift
let bytesPerSec = Double(max(150, lastBudget.videoKbps)) * 1000 / 8 * 1.25
let perSlice = max(1, Int(bytesPerSec * 0.005 / Double(maxPayload)))
```
At 440 kbps of video budget `bytesPerSec·0.005/1157 = 0.30 → 0 → max(1, 0) = 1`: one 1.2 KB datagram
every 5 ms = 231 KB/s, 4.2× the budget; at the bus's 173 kbps it is ~11×. Every keyframe is therefore a
burst at ~1.85 Mbps into a 0.5–1 Mbps bottleneck, which is the queue spike (101 ms at t = 3 s) and the
×0.85 back-off §6 reports, and the reason H5's NACK gaps appear.

Fix: derive the interval from the rate, not the slice: `interval = Double(maxPayload) / bytesPerSec`
seconds per datagram (16.8 ms at 68.75 KB/s), batching only when the interval drops below ~2 ms.
Schedule slices on a dedicated low-contention queue (or a `DispatchSourceTimer`), not on `queue`.

#### H7. The fps-shortfall ladder drop measures against `maxVideoFPS` (30), but the host itself caps small regions at 15 fps — a small animation drives the rung to tiny and oscillates with a keyframe every ~5 s
`Sources/MirageCore/Rate/RateController.swift:169-178`, `Sources/MirageHost/DesktopStreamer.swift:824-828, 1063-1064`

`tryEncode` uses `fpsCap = 15` when the pending video region is < 3 % of the screen; `videoRate()` is
fed `wantedFPS = min(maxFPS, policy.maxVideoFPS) = 30` and drops a rung when achieved < 18 for 2 s.
Scenario: a 300×200 looping GIF in a browser (20 tiles, ≥ 8 sustained → video, 1.4 % of the screen):
achieved ≤ 15 by construction → rung += 1 every 3 s to the tiny rung (12 s), `applyBudget` rebuilds the
encoder with a keyframe at each step, then `updateRung` climbs back (`upNanos` 5 s) because the kbps
density allows it, then the shortfall drops it again: a keyframe every ~5 s and the whole screen's
motion at 1/8 scale while a thumbnail animates.

Fix: report the shortfall against what the host actually asked for: pass `wantedFPS = min(policy.maxVideoFPS,
lastFpsCap)` (remember the cap used in the last second), and only count a shortfall when frames were
skipped for budget (`statSkippedBudget`/`tokens < 0`), not for the interval gate (`statDropped`).

### Medium

#### M1. The compositor's crossfade commits stale pixels over newer direct writes and copy-rects; in headless mode (or while the display link is paused) fades never settle at all
`Sources/MirageCore/Render/Compositor.swift:113-116, 202-230, 234-258, 261-274, 299-301`

Refinement tiles and progressive keyframes are written to `incoming` and copied to `canvas` by
`settleFades`, which runs only inside `render()`. The comment on `beginFade` promises "A rect still
fading when overwritten is committed first", but `applyTiles(crossfade: false)`, `applyCopyRect` and
`applyVideo(crossfade: false)` do not touch `fades`. Scenarios: (a) a refinement block over the password
field is fading (150 ms) and a keystroke's glyph lands on the canvas; at fade end the block's pre-glyph
pixels are copied over it and the glyph disappears until that tile changes again (the host believes it
is crisp, so never). (b) A refined strip is fading during a scroll burst; the copy-rect shifts the canvas
but not `incoming`; at fade end an unshifted 64-px strip pops back over the scrolled content (the
measured scrolls refine strips while the next wheel events arrive, so this is routine). (c) `--headless`
never calls `render`, so `incoming` is never committed, every refinement tile appends a `Fade` forever
(~30 B each, ~10 MB/h at the measured rates), and `sampleEdgeColor` (the scenario runner's caption-band
guard) reads a canvas that lacks every progressive step and refinement block.

Fix: in each non-crossfade write, first commit (blit `incoming → canvas`) the fades intersecting the
written rect and remove them, so the new write wins ("committed first" as documented); for copy-rects,
commit intersecting fades *before* the copy so they move with the canvas. Call `settleFades` from the
video queue too (at the top of every `apply*`, with its own command buffer) so settlement never depends
on a renderer.

#### M2. `isFresh` applies a whole stale rect when *any* 64-px tile under it is not newer, so a refinement block that arrives after an interactive update reverts the newer tiles inside it
`Sources/mirage-viewer/ViewerSession.swift:304-315`

The rule is per rect, not per tile: `stale` is cleared by the first tile with `tileCaptureSeq <= captureSeq`,
and then the whole rect (a 300×300 block, or a merged multi-tile rect) is blitted, including tiles that
hold a newer capture. Scenario: typing during the opening refinement (the login criterion): the glyph
(fast stream, capture 105) lands; the block from capture ≤ 104 (slow stream, ~0.3 s of serialization)
lands after it and reverts the glyph's tile. The tight-box diff means the next keystroke re-sends only
the *new* glyph, so the lost one stays lost. The design's "the client drops a tile older than the
capture it already holds" needs to hold per tile.

Fix: decode the rect once, then blit per 64-px sub-rect, skipping sub-rects whose `tileCaptureSeq` is
newer (`Compositor.applyTiles` can take a `(PixelRect) -> Bool` predicate or a list of excluded tiles).

#### M3. Refinement blocks are not 64-px aligned, so every tile straddling a block boundary is never marked crisp and is re-sent afterwards as a per-tile march (~40 % of the screen twice)
`Sources/MirageHost/DesktopStreamer.swift:529-532, 574-575`

`bw = ceil(width / cols)` (e.g. 291 px for 3200 px at ~300 px blocks) and `covered` keeps only tiles
*fully inside* a block, so the tile column at every vertical boundary and the row at every horizontal
boundary (≈ 10×29 + 6×50 ≈ 600 of 1400 tiles at 3200×1800) remain `pending/viaVideo` and are sent again
by `refine()` once `fresh == .done`, in 64-px tiles, which is the "march of tiny tiles" the rule exists to
prevent, and a few hundred KB per fresh picture.

Fix: snap `bw`/`bh` to multiples of 64 (`bw = ((bw + 63) / 64) * 64`, recompute `cols`), so every tile
lies in exactly one block; then `covered = tracker.tiles(covering: [rect])`.

#### M4. The assembler is never reset when the host restarts the stream on the same connection, and the host's `seq` restarts from 1 per streamer, so every new frame is below `delivered` and dropped: black video until a reconnect
`Sources/mirage-viewer/ViewerSession.swift:161, 253-254, 353-358`; `Sources/MirageCore/Session/HostSession.swift:95-99`; `DesktopStreamer.swift:55`

`connectOnce` resets the assembler per connection only. `serveStream` builds a *new* `MacDesktopStreamer`
within a connection when the datagram flow or tile stream died ("flow died; start over") or after
`streamStop`; its `seq` starts at 0. The viewer's `tileCaptureSeq` is cleared by the `.reset` message, but
`assembler.delivered` keeps the old high-water mark, so `ingest` discards everything (`f.frameSeq <= d`).
The control stream is alive, so reconnect-forever never triggers; lossless tiles keep the picture
half-alive and video is gone.

Fix: reset `assembler`, `awaitingRecovery`, `lastRecoverySeq` on `.reset` and on `streamInfo` (both already
mark a fresh picture); or keep `seq` monotonic across streamers (a static counter) — do both.

#### M5. Reconnect leaks the previous `QUICClient` (connection group) and its three receive loops
`Sources/mirage-viewer/ViewerSession.swift:159-203, 606-610`

On a failed connection `connectOnce` returns without `client.close()`; `self.client`, `control`,
`tileStream`, `fastTileStream`, `flow` are overwritten on the next attempt. The old `NWConnectionGroup`
lives until Network.framework gives up on it, and the detached `receiveTiles`/`receiveDatagrams` tasks
keep running until their connections fail, able to deliver a stale tile into the fresh
`tileCaptureSeq` grid. Over a multi-hour flaky session this is a steady leak of groups, queues and tasks.

Fix: `defer { client.close() }` in `connectOnce`, cancel the per-connection tasks (store the `Task`s and
`cancel()` them), and tag queued `apply`/`ingest` closures with a connection generation that `apply`
checks.

#### M6. The delay signal from reliable-stream tile acks is contaminated by QUIC retransmission, and the base one-way-delay never ages out when video is idle
`Sources/MirageCore/Rate/RateController.swift:104-106, 125-133`

A lost QUIC packet on the tile stream adds one RTT to the arrival of every byte behind it; `delaySample`
feeds that into the same EWMA (0.3 weight) as the video datagrams. At the §4a 5 % loss point a visible
fraction of tile messages carry +RTT, so `queueMs` sits in the 40–90 ms dead band and the target never
climbs after a back-off; it is also the likely cause of the "EWMA sits ~30 ms above its minimum on an
idle link" note in §6. Separately, the 20 s base-OWD window is advanced only in `frameAcked`, so on an
idle or Extreme desktop a route change that raises the base delay inflates `queueMs` permanently and
pins the target at the floor until video resumes.

Fix: weight tile-ack samples at ~0.1 (or use a windowed minimum rather than an EWMA for them), and run the
base-window expiry in `delaySample` too.

#### M7. The tier cannot recover from Extreme on a quiet desktop: min-RTT is updated only from video frame acks
`Sources/MirageCore/Rate/RateController.swift:93-98`, `Sources/MirageHost/DesktopStreamer.swift:215-225`

`tiers.update(rttMs: minRttMs)` uses `minRTTNanos`, maintained in `frameAcked` only. After a transient
spike > 400 ms for 2 s the tier goes Extreme; with no motion there are no video frames, so the 30 s window
never rolls over and the tier stays Extreme (5 fps, tiny rung, 16-colour policy seam) until something
animates. Tile acks already carry a true RTT sample (`now − sent.nanos` in `handle(tileAck:)`).

Fix: add `rttSample(_:now:)` to the controller and call it from `handle(tileAck:)`; make the window
rollover time-driven (also in `delaySample`).

#### M8. `--probe-input` sends unmarked (non-scripted) input, bypassing the console-lock guard: ⌘Space, a space keystroke and Esc reach the login window
`Sources/mirage-viewer/ViewerSession.swift:584-604`, `Sources/MirageHost/InputInjector.swift:62-66`

The guard is a flag the viewer sets; `probeInput()` calls `send(...)` without `scripted: true`, so on a
locked host it types a space into the password field and opens/closes Spotlight.

Fix: `send(..., scripted: true)` in `probeInput`, and treat every input the viewer generates without a
human event (`ScenarioRunner`, `probeInput`) through one helper that always marks it.

#### M9. Scenario safety checks run once; a long `typing`/`login` run keeps injecting after host focus changes, and ends with ⌘A + ⌫ into whatever is focused
`Sources/mirage-viewer/Scenarios.swift:107-115, 155-158, 159-170, 171-189`

The console/frontmost/caption guards are evaluated before the first click only. If the person at the
host (or a notification, a dialog, Spotlight) takes focus during the 30–60 s run, keystrokes go there;
`login` finishes with select-all + delete, which in an editor erases the document. `fovea` skips the
guards entirely (a mouse move only; the host-side lock guard still covers it).

Fix: re-check `session.hostStatus` (updated every second) before every burst/keystroke batch and abort
on any change of `frontmostWindowID`; drop the ⌘A/⌫ cleanup (or gate it on the field still being
frontmost). Stronger, host side: refuse *scripted* input unless `WindowTracker.frontmost().app` is the
bench (or an allow-list), so the invariant does not depend on the viewer.

#### M10. The interactive tile stream has no backpressure: near-locus tiles and copy-rects are unbudgeted and can queue without bound on a slow link
`Sources/MirageHost/DesktopStreamer.swift:424-430, 357, 382`; `Sources/MirageCore/Session/Streaming.swift:179-184`

Priority-1 tiles bypass `tileTokens` by design, copy-rects are sent as found, and `sendTiles` is
fire-and-forget into Network.framework's buffer. A 40-event scroll burst is ~270 copy-rects plus strips;
at 64–150 kbps the fast stream's backlog grows for the length of the burst and every later interactive
update waits behind it (the controller only trims the budgeted paths). `refinementInFlight` bounds the
slow stream; nothing bounds the fast one.

Fix: track unacked bytes per stream from `tileSent`; when the fast stream holds more than ~1 RTT of the
target, coalesce (drop superseded copy-rects of the same window, merge strips) and fall back to video
for the rest, logging it.

#### M11. `.reset` on every stream start clears the kept picture: reconnect shows grey for 1–2 s before the tiny keyframe, against the stated intent
`Sources/MirageHost/DesktopStreamer.swift:144`, `Sources/mirage-viewer/ViewerSession.swift:353-358`

`configure()` sends `.reset(w, h)` unconditionally; the viewer calls `compositor.clear()` on it. The
"last picture stays" promise therefore holds only during the outage, then flashes to the clear colour.

Fix: clear only when the size changed (`configure` already does that); on a same-size reset keep the
pixels, reset `tileCaptureSeq`, the predictor and (M4) the assembler. The host could carry a `keep` flag
in the message if a true clear is ever wanted.

#### M12. The host-pressure signal's `captureMs` term measures how expensive the *content* is, not whether the host is busy, so effort drops exactly under motion
`Sources/MirageHost/HostEffort.swift:22-26`, `Sources/MirageHost/DesktopStreamer.swift:302-304`

`captured()`'s wall time includes the full-dirty CPU diff, shift search, pixel copies and canvas copies;
a scroll or wallpaper animation on a 3200×1800 panel pushes it over 15 ms (→ `reduced`: WebP effort 2,
smaller search) or 25 ms (→ `minimal`: no tight boxes, so typing costs 2–3× bytes). That inverts the
rule "host load is cheap, wire bytes are not" when the wire is busiest.

Fix: use capture time relative to the capture interval *and* only when the run queue is also loaded
(`loadPerCore > 0.8`), or measure the host's idle fraction (`host_processor_info`) instead; never let
`captureMs` alone pick `minimal`.

#### M13. A parity datagram that arrives before any fragment creates a placeholder that cannot be NACKed and holds the line for the full timeout
`Sources/MirageCore/Wire/Video.swift:296-299, 355`

`count == 0` placeholders are excluded from the NACK condition; if the frame's fragments were all lost
the head waits `timeoutNanos` (2.5 RTT + 300 ms) with every later frame held, where without the parity
datagram the frame would (today, H2) be skipped instantly. Fixed by H2's "NACK all" path (allow
`count == 0` there).

#### M14. NACKs, frame acks, tile acks and input all share one reliable control stream; one lost control packet delays the NACK (and the recovery it buys) by a full RTT
`Sources/MirageCore/Session/Streaming.swift:127-154`, `Sources/mirage-viewer/ViewerSession.swift:383`

The design (§3.9) moves input and loss signalling to datagrams in every tier. Today the NACK's "1 RTT"
is 2 RTT whenever the control stream itself is recovering, which at 5 % loss is often. Not a bug in the
code written, but the resilience numbers depend on it.

Fix: add `DatagramType.nack` (and later input) on the flow; `serveDatagrams` already dispatches by type
byte. Keep the control-stream NACK as the fallback when no flow exists.

#### M15. `refine()` is gated on `fresh == .done`, which also blocks *deferred changed* tiles (not refinement) for the whole fresh-picture phase
`Sources/MirageHost/DesktopStreamer.swift:444, 764-776`

Far-from-locus changed tiles that found `tileTokens ≤ 0` are `defer`red into the pending set and are
served only by `refine()`; during a fresh picture (tens of seconds at 800 kbps on a large screen)
`refine()` returns at line 772 after `freshBlocksStep`. Typing with the pointer parked elsewhere while the
opening refinement runs can therefore wait for the blocks. (The caret is not a locus today, so this is
the normal typing posture.)

Fix: serve `viaVideo == false` pending tiles from `refine()` regardless of `fresh`, ahead of
`freshBlocksStep`.

#### M16. One serial `tileQueue` encodes refinement blocks and interactive tiles: a block's WebP encode (tens of ms at effort 4 for ~100 k px) sits in front of the next glyph
`Sources/MirageHost/DesktopStreamer.swift:679, 717, 742`

Ordering within a stream is needed, but the two streams are independent. Fix: a second queue for the
refinement stream's encodes (`tileQueueSlow`), sequence numbers still assigned on `queue` under one
counter so acks stay unambiguous; or encode refinement at `qos: .utility`.

### Low

- **L1.** Duplicate fragments (a NACK resend racing the late original) refresh `p.lastNanos`
  (Video.swift:288) and `recoveredByNack` counts any fragment arriving after a NACK (286). Move
  `lastNanos = now` inside the `parts[idx] == nil` branch; count a recovery only for an index that was
  in the last NACK list.
- **L2.** NACK decisions run only for the head of line (Video.swift:355-359); a burst that hits N and
  N+1 recovers N+1 one RTT later than necessary. Iterate all partials for NACKs, deliver in order.
- **L3.** `rc.lossDetected` runs for the stale "late lost verdict" acks the host otherwise ignores
  (DesktopStreamer.swift:975); gate it on `ack.seq >= recoverySeq` too.
- **L4.** `pendingScroll` never ages (DesktopStreamer.swift:49-51, 371): a wheel event with no capture
  for seconds is attributed to the next unrelated capture. Ignore if older than ~500 ms.
- **L5.** `configure()` on a resize builds a fresh `RateController` and so resets the tier to
  Constrained, min-RTT, loss window (DesktopStreamer.swift:132-134); carry `tiers`, `minRTT` and the
  loss counters over.
- **L6.** Cross-thread reads without a lock: `samples` (MainActor append vs. runner read,
  ViewerSession.swift:89 — a Swift array is not safe to read during a reallocating append),
  `hostStatus`/`watchRect`/`lastWatched*` between the runner task and the video queue, `assembler`
  read from the stats loop (459, 648), `output` read on `tileQueue` (DesktopStreamer.swift:746),
  `injector`/`target` on `inputQueue` vs. `queue`. None is likely to crash today; `samples` is the one
  that can. Snapshot under `statsLock` / mark the hot ones `@unchecked` with a lock.
- **L7.** `Predictor.predict` carries a comment about cancelling opposite-direction wheel jitter that
  is not implemented (Predictor.swift:46); reversals become mismatches by design — either implement or
  delete the comment.
- **L8.** When a scroll's exposed strips fall back to video (≥ 12 tiles, no tokens), the datagram can
  beat the copy-rect on the fast stream; `hostUpdate(region)` then retires the prediction with a
  remainder → mismatch → confidence lost for 2 s (ViewerSession.swift:411, 349-350). Stamp video frames
  with the tile msgSeq they follow, or treat a video update as "due" only after the copy-rect of the same
  captureSeq has been applied.
- **L9.** `WindowTracker.learned`/`axRects` grow per window id for the life of the session (never
  pruned when a window closes); `Predictor.windows` and `bandColors` likewise on the viewer. Prune ids
  absent from the list for > 60 s.
- **L10.** QUIC idle timeout 10 s (QUIC.swift:24, 109) versus §4a's 30 s outage survival in the same
  session: documented in §3.3b as a choice, but §4a still reads as an acceptance criterion. Pick one.
- **L11.** `WindowTracker.frontmost()` calls `NSRunningApplication(processIdentifier:)` on the video
  queue every second; move the name lookup off the hot queue or cache per pid.
- **L12.** `applyTiles` allocates a shared `MTLBuffer` per tile (Compositor.swift:213, 220); a small
  ring of reusable buffers removes hundreds of allocations per second during refinement.
- **L13.** `submitLossless` and `submitRects` duplicate the encode-job body (DesktopStreamer.swift:
  679-699 vs 717-736); the viewer repeats the 64-px grid index math three times (ViewerSession.swift:
  306-313, 325-329, 492-496). Extract `encodeJobs(_:)` and a `TileGrid` helper.
- **L14.** `tileChangedBox` returns `y0`/`y1` in frame coordinates and `x0`/`x1` tile-relative
  (DesktopStreamer.swift:293-296); correct, but easy to break — name them.

---

## 2. Tests worth adding

- **T1.** `FrameAssembler`: 2-fragment frame, fragment 0 lost, fragment 1 + parity arrive → sample
  equals the payload byte for byte (fails today, H1). Also the group-of-one tail case (9 fragments,
  last lost) → either exact recovery or no recovery, never a short frame.
- **T2.** Whole-frame loss: frames 1 and 3 complete, nothing of 2 → expect `.nack(2, [])` after
  `nackAfterNanos`, frame 3 held, then `.lost(2)` then `.completed(3)` after the timeout (H2, M13).
- **T3.** Paced frame with 40 ms inter-fragment gaps and no loss → zero NACK events (H5).
- **T4.** Pure fresh-picture state machine (extract `Fresh` + the affordability predicate from
  `MacDesktopStreamer`): at target/pixel ratios across 0.15–0.40 the climb terminates in `.blocks`
  within `scales.count` steps and never revisits the tiny rung (H4).
- **T5.** Block grid for 3200×1800 and 2560×1440 at several budgets: every tile is fully inside exactly
  one block; after all blocks are `sent`, `tracker.due(now:)` is empty (M3).
- **T6.** `Compositor`: refinement tile fading over rect R, then a direct tile into R, then a settle →
  direct pixels remain; copy-rect of R during a fade → settled pixels are at the shifted position (M1).
  Also: `applyTiles(crossfade: true)` × 1000 with no `render` → `fades` bounded after a settle call.
- **T7.** `isFresh` per-tile: a 2×2-tile rect with one newer tile applies the other three only (M2).
- **T8.** `RateController.videoRate(achieved: 15, wanted: 15)` for a small region does not drop a rung;
  `achieved: 15, wanted: 30` only when budget skips were recorded (H7).
- **T9.** Pacing schedule at 200 kbps and 2 Mbps: datagram timestamps spaced `maxPayload / (1.25 × budget)`
  within 20 % (H6) — needs the scheduler extracted from `send()`.
- **T10.** `TierSelector` + controller: Extreme on RTT 450 ms, then RTT samples of 150 ms from tile acks
  only → Normal/Constrained after the 10 s dwell (M7).
- **T11.** Viewer accepts frame seq 1 after a `.reset`/`streamInfo` when `delivered` was 5000 (M4).
- **T12.** `probeInput` and every `ScenarioRunner.send` produce messages with `isScripted == true` (M8);
  host `InputInjector.handle` ignores scripted input while locked (existing) and, if adopted, while the
  frontmost app is not the bench (M9).
- **T13.** Stale-purge: a frame of 36 KB at 55 KB/s video budget with srtt 250 ms is not purged before
  `serialization + 3·srtt`, and a late ack still advances `fresh` (H3) — again needs the in-flight
  bookkeeping extracted into a testable struct.

---

## 3. Done well; do not break

- **Delay-based control with 1–2 frames in flight** (`inflightBudget` = one srtt + 50 ms of budget,
  ×0.85 per RTT above the dead band, `tokens` debt bounded): the 2 Mbps/30 ms-queue result rests on it.
  H3/H6 change timing, not this rule.
- **In-order assembler with the timeout measured from the last fragment** (2711e3e) and a hard age
  cap: a paced keyframe is never declared lost mid-flight. H2/H5 add to `drain()`; keep its shape and
  the `delivered` monotonic guard.
- **Tile mask inside a full-frame HEVC session, flattened masked-out tiles, one client canvas with
  arrival-order writes**: crisp tiles survive keyframes for free. M1 must preserve "arrival order wins".
- **Two reliable tile streams** (interactive vs refinement) with `refinementInFlight` bounded to ~300 ms
  of link and one block in flight: the right structure; M10 only adds the missing bound on the fast one.
- **Lossy-first from the tiny rung on every start, resize, tier downgrade and oversize recovery**, and
  the recovery keyframe from a fresh session (QP floor honoured). H4 aligns two predicates; it must not
  reintroduce a native-size first keyframe.
- **`TileScheduler` as a pure, unit-tested ordering** and the 150 ms yield after real change (≥ 3
  tiles), with copy-rects first: keep the priority order exactly; M15 only unblocks deferred changes.
- **Input-sequence stamping of every pixel update (≥ 40 ms before capture) and the predictor's FIFO /
  confidence rules**; the ±4 tolerant diff and ±16 tolerant shift verification; tight changed boxes.
- **The scripted flag + console-lock refusal on the host, the host-status publication, and the
  runner's three guards** — the design is right; M8/M9 close gaps in coverage, not in the idea.
- **Reconnect-forever with backoff, kept picture, re-requested stream; per-connection registry with
  single-shot `FlowWaiter`s; unknown tile kinds/formats skipped, never fatal; control bytes counted;
  coalesced window-list deltas at ≤ 10 Hz.**
- **Measurement discipline**: `--headless --stats`, scenario crisp/legibility metrics, the static-picture
  loopback assertion script. T4/T9/T13 ask to pull three pieces of `MacDesktopStreamer` into pure structs
  so the same discipline reaches the host's state machines.
