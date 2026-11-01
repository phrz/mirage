# textbench — does whole-display HEVC move text far enough for the gate to call it wrong?

`swiftc -O textbench.swift -o /tmp/textbench && /tmp/textbench` (no host, no screen). A 3200×1800 picture like the
bench's (monospaced text at the stream's scale, black, red and blue; the purple caption band with white text) goes
through a hardware HEVC session set up as HEVCEncoder's, as a keyframe and then the same picture as P-frames, and is
decoded. It reports the truth checker's own measure (32×18 cell means of luminance, cells over 15 levels off) plus PSNR,
the mean RGB error inside the text, and bytes.

Results on phrz-mini-m4-pro, 2026-11-01 (`results.txt`):

- No configuration moves any cell more than 1.8 levels: 4:2:0 at no ceiling, QP ≤ 30, 20 or 10, and from the host's
  coarse first IDR (MinAllowedFrameQP 40, 32.5 dB) followed by P-frames at QP ≤ 30 or ≤ 20 (48–51 dB within four frames).
- `Main42210` produced byte-identical output to Main from BGRA input, so 4:2:2 did not take effect here (VideoToolbox has
  no HEVC 4:4:4 profile at all).

So encoding loss, chroma subsampling included, cannot make the gate's 43 wrong text cells on a still screen
(compare-2026-11-01.md): the viewer was showing something other than the host's screen.
