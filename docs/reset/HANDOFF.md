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

## Found: whole display showed wrong text cells (fix on main, awaiting a nightly)

Still whole-display run on 580, 2026-11-02 20:12Z (scratch `st2`, bench crops full size, bench frontmost, nothing over
it). The viewer's bench stayed a heavy blur, the 1/8-size start picture upscaled, for the whole 23 s; after 14 s only the
caret's 64x42 px ever changed. Two faults, both host-side, both fixed in `DesktopStreamer.swift`:

1. **The video tile key ranked the controller's rung, not the encoded size.** The connect probe set rung 0 at 1.1 s,
   but the encoder stayed 400x224, so each 1/8-size sharpening frame went out with the native rank (6). The real 3200x1800
   keyframe at 13 s (viewer decoded 3200x1800 at 8–9 fps from then on) had the same content seq and rank, and the viewer's
   "equal keys keep what is there" rule rejected it on every still tile. Now the rank comes from the encoder's own width
   (`encodedRung`, tested).
2. **The encoder stayed at the tiny rung for 13 s on a LAN start.** `applyBudget` waited for the layered pipeline's fresh
   picture (`d.fresh == .done`), which whole display never finishes on a local link. It no longer waits in whole display.

Earlier starts that sent lossless refinement tiles looked exact only because those tiles (rank 9) beat the stuck video.
Not verified live yet (no test copies on hosts): needs a nightly, then the still run (`still.sh`) and the A/B again.

## Next steps, in order

1. After the next nightly: rerun the still whole-display run (sharp bench crops from ~1 s) and the A/B comparison.
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
