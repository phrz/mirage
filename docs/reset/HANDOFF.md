# Handoff: Mirage director, 2026-11-02

For a new Claude Code session on phrz-mini-m4-pro taking over as Mirage's coordinator ("director"). Read
`CLAUDE.md` (UI rules), `docs/reset/README.md` (the reset, approved by phrz), then this file, then the two comparison
write-ups `docs/reset/compare-2026-10-31.md` and `docs/reset/compare-2026-11-01.md`.

## Where things stand

- **Direction (approved 2026-10-28):** the render and stream pipeline resets to a known-good base: one whole-display
  capture → low-latency hardware HEVC → datagrams → one presented picture. The viewer-side "mirages" (local
  illusions such as drag prediction) come back later, on top of that base, and must each win a recorded comparison.
  Background: `docs/reset/assessment-brief-vs-reality.md`, `docs/reset/pipeline-inventory.md`,
  `docs/reset/workbench-research.md`.
- **Nightly 580 is current** and installed on the mini. It has the encoder deadlock fix (55a123b) and the
  whole-display connect fix (45fd4fe: the link probe fires on the first acked frame, so a LAN start sharpens about
  200 ms in instead of 1.5 s).
- **Done:** gate additions; baseline and the `wholeDisplayOnly` comparison on the mini (whole display wins scroll and
  drag at about 1/30 the kbps, typing latency equal); gate motion handling (ba6df2f: frames from a burst's first input
  until the next whole frame are not judged, and a "settle" column reports that time); release.sh commits and pushes
  the channel floor itself (bbd12b9).
- **Ruled out (experiments/textbench, 1838c16):** encoding loss and 4:2:0 chroma. Through the same hardware HEVC setup a
  bench-like picture's cells move at most 1.8 levels (the gate's threshold is 15), even from the coarse first IDR.
  VideoToolbox has no HEVC 4:4:4; Main42210 gave output identical to Main.

## Open: whole display shows wrong text cells (blocks making it the default)

In a whole-display scroll run on 580 (scratch output `wm`, 2026-11-01 20:27Z), a still screen had 43–45 cells of
the bench's text (rows 5, 7, 9, 11; cols 5–14; viewer lighter than the host) more than 15 levels off from 0.84 s until
the first scroll at about 12 s. That was through a sharpening frame every second that, per the code, re-encodes the
whole display (`sharpenIfStill` copies all of `d.lastFrame` to the canvas and marks every tile). Starts that also sent
lossless refinement tiles were exact. So the viewer was showing something other than the host's screen.

Leads, unexamined:
- The viewer ignores or masks part of what arrives (tile mask, `tracker.isCrisp` filtering in the encode path,
  viewer compositing).
- The bench changed just after the stream started (that run's stream began as the bench opened) and the change never
  reached the viewer.
- The 1 Hz truth reference (`startTruthReference`, SCK display shot at 640 wide) differs from the stream's capture.

**Next run:** a still whole-display run with full-size bench crops from the viewer. The script is
`/private/tmp/claude-501/-Users-phrz-Repos-mirage/4e9884c6-4479-4492-bbb3-9d5357ab6e98/scratchpad/still.sh`
(scratch; it may be gone). It sets tunables `{"curtain": 0, "wholeDisplayOnly": 1}`, opens
`.build/MirageTestBench.app`, runs `.build/debug/mirage-viewer localhost --headless --truth --window 1600x900
--scale 2 --duration 14 --scenario idle:10` with `MIRAGE_TEST_FRAMES` (quarter-size frames for the truth checker) and
`MIRAGE_TEST_BENCH_SHOTS`/`MIRAGE_TEST_BENCH_FPS=2` (full-size crops of the bench window), then removes the tunables
and closes the bench. To reproduce the bad case, start the stream right as the bench opens, as the gate's A/B script
did.

The first attempt (2026-11-01 23:12Z) was invalid: autonomous Chrome and ChatGPT Computer Use windows sat in front of
the bench, so the run measured Chrome. **A bench crop shows whatever covers the bench:** before viewing one, check that
the bench is the first layer-0 window and nothing overlaps it, and delete crops that caught other windows. A
"… quit unexpectedly" crash dialog (UserNotificationCenter, flagged by the host at 22:08:26Z, not caused by a test)
was up on the mini then; it is phrz's to dismiss. Waiting on phrz: the bench free to be in front.

## Next steps, in order

1. Find the wrong-text-cells bug above and fix it (through a nightly), then rerun the A/B comparison.
2. Make whole display the default.
3. Workbench lessons where still needed: lossless tiles from the same capture for small changes (typing, caret) in the
   same frame transaction as the video; codec choice by content, never by RTT. (4:4:4 HEVC is not available.)
4. Resolution matching (phrz: "Yes, try it"): an option where the host switches its display mode to the viewer's
   size for the session (`kCGConfigureForSession`), with a guaranteed restore on session end, suspend expiry, host
   restart and crash (persist the original mode), and never while someone is at the Mac.
5. Shrink: put the seam and compositor machinery behind an off switch, then delete it.

Deferred by phrz ("later"): a headless synthetic-frame gate path. Available: the VMPal macOS VM "Word Clone Test Mac
Automation" has a paravirtualized hardware HEVC encoder (a 3200×1800 session opens), so a VM can test the encoder.

## How the work runs

- **Roles:** the director reviews and merges; worker sessions or agents implement on branches. Before merging
  updater or security-sensitive code, get an independent read-only review. Merge by fast-forward or squash in a
  scratch clone, run `swift test` (DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer), then push `main` and
  `universal-app`.
- **Releases:** phrz runs `scripts/release.sh nightly --skip-tests` himself (an automated permission check blocks
  agents from publishing). It commits and pushes the `MIN_BUILD_NIGHTLY` floor itself; he should `git pull` first.
  Never commit in the main checkout while a release runs (`pgrep -fil release.sh`).
- **Updating hosts:** `/Applications/Mirage.app/Contents/MacOS/miraged update --check`, then `--now`. Restarting the
  mini's host is fine when no viewer session is connected (status probes from phrz-mbp-m4 are not sessions).
- **The gate:** `tools/gate/gate.sh localhost LAN connect,typing,scroll,drag` on the mini (loopback), with the bench
  open; `GATE_KEEP_FRAMES=1` keeps frames. Run `caffeinate -d` during runs (the mini locks after 10 minutes without
  local input). Lock check: `ioreg -n Root -d1 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*'` (empty = unlocked).
- **iOS:** `scripts/testflight.sh` uploads a TestFlight build.

## Rules from phrz (keep them)

- These are his real personal and business Macs: never comb through personal files, never take full-desktop
  screenshots, never kill other people's processes, and never click macOS permission prompts (only phrz does).
  Never handle or type his password. Window-only frames of the bench are allowed.
- **No test copies of the host on his Macs.** Every new binary that starts screen capture triggers macOS's
  screen-picker bypass consent prompt. Test through the installed app after a nightly.
- **Visible or injected tests:** nobody connected and no system prompt on screen; check first, act second, as separate
  steps. On the mini the idle requirement is relaxed (phrz: not on it, but autonomous work may be). An unexplained
  new window may be a consent prompt: stop and report.
- **Never use osascript or System Events** on his Macs (raises an Automation prompt).
- Test tunables (`curtain: 0`, `wholeDisplayOnly: 1` in the mini's tunables.json) are approved for runs and must be
  removed after.
- **Latency is not bandwidth:** never lower quality because of round-trip time. On a probe-confirmed LAN, start at
  LAN rate.
- **phrz is not the test.** Every candidate passes the gate before he sees it. Report what wasn't verified.
- **UI:** follow `CLAUDE.md`. Say something as an alert or not at all, and never alarm.
- Requesting Apple's persistent content-capture entitlement (for remote-desktop apps) is phrz's to-do.

## Hosts

- **mac-daddy (Mac Studio): off limits** while it runs LLM profiling: no SSH, gate runs or updates.
- **phrz-mini-m4-pro:** where the director runs and the test host (loopback gate).
- green-machine (iMac), big-mac. phrz-mbp-m4 is viewer only ("Share This Mac" off).
