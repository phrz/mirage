# seqbench — HEVC hardware P-frame cost and quality for desktop interactions

Synthetic sequences built from a real 3024×1964 desktop capture (and a 1x 1512×982 downscale),
fed to a VideoToolbox HEVC hardware session, decoded again, PSNR measured on the dirty region.
40 frames per scenario, first 5 dropped from the means. M4 Max, macOS 27, 2026-10-16.

Scenarios: `static` (nothing changes), `typing` (one 64×64 text tile changes per frame),
`scroll` (1200×900 region scrolls 40 px/frame), `drag` (900×600 window moves 24×12 px/frame).

Run: `swift build -c release && .build/release/seqbench img.png [kbps] [scenario|all] [lowlat 1|0]`

## Low-latency mode, 2x desktop (3024×1964)

| target | scenario | first frame | mean P | max P | wire time @target | PSNR (dirty) | encode |
|---|---|---|---|---|---|---|---|
| 800 kbps | static | KEY 161 KB | 24 B | 572 B | 0.2 ms | – | 3 ms |
| 800 kbps | typing | | 1.0 KB | 9.4 KB | 10 ms | **19.9 dB** | 10 ms |
| 800 kbps | scroll | | 3.4 KB | 21.6 KB | 34 ms | 35.6 dB | 16 ms |
| 800 kbps | drag | | 3.1 KB | 32.5 KB | 31 ms | 37.9 dB | 15 ms |
| 2000 kbps | static | KEY 128 KB | 2.0 KB | **48.6 KB** | 8 ms | – | 11 ms |
| 2000 kbps | typing | | 9.1 KB | 80 KB | 36 ms | 45.5 dB | 15 ms |
| 2000 kbps | scroll | | 7.3 KB | 72 KB | 29 ms | 43.9 dB | 15 ms |
| 2000 kbps | drag | | 3.8 KB | 7.4 KB | 15 ms | 45.9 dB | 15 ms |

Normal mode (MaxFrameDelayCount=0), 800 kbps, 2x: KEY 39 KB; typing 2.4 KB / 30.2 dB;
scroll 1.8 KB / 27.0 dB; drag 2.4 KB / 30.3 dB.

1x desktop (1512×982), low-latency, 800 kbps: KEY 72 KB; typing 3.2 KB / 34.7 dB;
scroll 3.3 KB / 39.0 dB; drag 3.1 KB / 16.4 dB (drag region metric is pessimistic).

## Conclusions for M1/M2

1. **Never feed unchanged frames to the encoder.** In low-latency mode the rate controller
   keeps spending its budget on refreshes of a static picture (2 KB mean, 48 KB spikes at
   2 Mbps). SCK only delivers frames on change; keep it that way and let the stream go idle.
2. **Sparse changes do not belong in the video stream.** One changed text tile costs 1 KB
   per frame at 800 kbps and comes out at 19.9 dB, which is unreadable mush, while the same
   tile is 0.55 KB *lossless* as WebP (tilebench). Typing, caret blink, hover highlights go
   through the lossless tile path; video is for sustained large motion only. This is the
   measured justification for the hybrid codec.
3. **Video for motion works at 800 kbps**: scroll and drag cost ~3 KB per frame at ~36–38 dB
   in low-latency mode (readable, slightly soft), i.e. ~30 fps fits in 800 kbps. Normal
   mode gives worse quality for the same bytes on scroll (27 dB) and should not be used.
4. **The keyframe is the stall.** Low-latency mode emits a 161 KB keyframe at 2x (1.6 s on
   a 1 Mbps link) and 72 KB at 1x. Options: cap keyframe QP via `MaxAllowedFrameQP` on the
   first frame, start at a lower rung of the resolution ladder, and let lossless tiles
   refine. Avoid later keyframes entirely with LTR acks.
5. **Resolution ladder matters less for motion than expected**: 1x costs about the same bytes
   per frame as 2x for scroll (the controller hits its target either way) but gives +3.5 dB.
   The ladder's job is the keyframe and the lossless refresh, not the P-frames.
6. Hardware encode is 3–16 ms per frame at 3024×1964; not a bottleneck.
