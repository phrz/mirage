# scalable: is resolution-scalable lossless worth it for Mirage?

Question: Mirage streams the host at native 2x and codes 64 px tiles with WebP lossless. Viewers often need less
(a phone at fit or a non-Retina Mac needs 1x; a poor link wants less still). Could the tile codec be
*resolution-scalable*, so a 1x viewer gets a 1x layer and a later upgrade to 2x sends only the extra detail? Or is
a plain per-viewer ladder (WebP at 1x, WebP at 2x, resend on upgrade) as good?

Measured 2026-10-21 on an M4 Max MacBook Pro (macOS 27.0.1), single thread, libwebp 1.6.0 (Homebrew, the same
version as the vendored `CWebP`), libjxl 0.12.0, zstd 1.5.7, LZ4 1.10.0. Every transform and every coder was
round-tripped and checked bit-exact on every tile and layer (16,910 tiles, 30 layers, no failure).

## Short answer

**No. Resolution-scalable lossless is not worth it on screen content. Use a plain ladder: WebP lossless at 1x or
2x per viewer, and on an upgrade, resend the 2x tiles.**

- **The upgrade costs as much as the 2x tile.** The best detail coder needs 105–137 % of A (2x WebP lossless,
  sent once) on text, UI and mixed tiles. Sending only the extra data costs about the same as sending the 2x tile
  again. Base plus detail is 159 % (text), 140 % (UI) and 137 % (mixed) of A, against 150 %, 135 % and 139 % for
  "1x WebP, then 2x WebP": worse on text and UI, a wash on mixed content. Scalability only pays on photographic
  and smooth tiles (115 % against 132 %), and those go to video anyway.
- **The 1x layer is cheaper than people expect, but it is not a quarter.** 1x WebP of the 2x2 box-filtered tile
  is 50 % of the 2x bytes on text, 35 % on UI, 32 % on photo and 39 % on mixed content. A 1x viewer halves the
  lossless cost of text, not quarters it.
- **Do not stream 1.5x lossless.** A 4:3 area resample breaks the pixel structure WebP exploits. Text at 1.5x
  costs 95 % (tiles) to 112 % (whole layers) of the 2x bytes. Send 2x, or 1x, and scale on the viewer.
- **JPEG XL is not the answer either, at tile scale.** Lossless JXL is 120 % of WebP per 64 px tile, and 147 %
  with squeeze. A 64 px tile is a single JXL group, so it cannot be decoded progressively at all. On whole
  layers, JXL's 2:1 pass costs 74 % of a full WebP 2x (WebP's 1x costs 32 %).
- **A side finding worth its own experiment: JPEG XL's *patches* (a glyph dictionary).** These are off by default
  for lossless; forcing them on makes whole text layers 62 % of WebP (18–24 % on repetitive text, 86–92 % on
  code and terminals). They lose on UI and mixed layers (119–124 %) and do nothing per tile. They cost 2.4x the
  encode time and about 14x the decode time of WebP.

## Corpus

30 images, all at 2x (Retina), with nothing from phrz's own screen:

- **12 real window-server captures** of the Mirage Test Bench (`experiments/testbench`). New `--scene NAME
  [--dark]` modes show a still, non-activating 1100×750 pt window: text, terminal, code, controls,
  vibrancy, mixed (article + photo + charts), photos and chat. `corpus/capture.sh` runs `screencapture -l <that
  window> -o` and nothing else. Screen Recording was already granted (`CGPreflightScreenCaptureAccess` checked
  first), so no prompt appeared. Vibrancy blends *within* the window over the bench's own gradients, so nothing
  behind the window is ever sampled. Every capture was inspected.
- **18 offscreen AppKit renders** of the same scene code (`corpus/render.swift`, `cacheDisplay` into a 2x
  bitmap): documents in SF, New York, Helvetica and Hiragino (Japanese), a dark document, a 10 pt spreadsheet,
  dashboards (light and dark), cards over gradients, system app icons (light and dark), controls, a dark vibrancy
  sidebar, chat, terminal, mixed, the bench's noise "photo" and a crop of macOS's rendered *Mac Blue* wallpaper.
- Photos are real photographs, but only as macOS's own wallpaper thumbnails: a photo-browser grid, and a scaled
  photo in the mixed scenes.
- Classes: text 11 layers, UI 9, photo 3, mixed 7. Images are cropped to whole 64 px tiles. Window corners are
  flattened over grey. Solid tiles are skipped (6,958 of them; Mirage sends those as 4 bytes in any scheme).
- The images are not committed. `corpus/capture.sh` and `corpus/render.sh` regenerate them into `corpus/out/`.

## Candidates

- **A: WebP lossless at 2x.** Effort 4 (`HostEffort.full`), `exact` off, which is the product's tile codec.
- **B: 1x base plus lossless 2x detail.**
  - The base is the LL band of a one-level integer lifting transform, WebP lossless at 1x. It is an exact, defined
    filter.
  - **Haar / S-transform**, horizontal step first: `l = (a+b)>>1, h = a−b`, then the same on the l's. LL is a 2x2
    mean, floored at each step. Its bands HL, LH and HH are block-local.
  - **Squeeze**, which is JPEG XL's: `avg = (A+B+(A>B))>>1`, with the residual `A−B` minus a "smooth tendency"
    predicted from neighbouring averages. That is a 5/3-like prediction that keeps an 8-bit base.
  - A true 5/3 lifting was not used: its low-pass leaves [0,255], so the base could not be a WebP image.
  - Four detail coders:
    - **WebP image**: the bands stacked into one RGBA image, RGB = low byte of v+128, alpha = packed high parts.
    - **zstd-3 / zstd-19 / LZ4-HC** over planar G, R−G, B−G, zigzag, low and high byte planes.
    - **ctx**: an adaptive binary range coder with contexts from the neighbouring magnitudes, the G plane and the
      sibling bands, plus a "same as above" flag.
    - Also, outside B proper, a **Laplacian** variant: the 2x residual against the upsampled base, mod 256, as a
      WebP image.
- **C: JPEG XL lossless (libjxl).**
  - Variants: plain e7; squeeze (`RESPONSIVE=1`, which libjxl turns into two passes, shift ≥1 then full); squeeze
    with patches off; plain with patches forced on.
  - "Bytes to the 2:1 pass" is the shortest prefix after which `JxlDecoderFlushImage` renders an image whose 2x2
    block means are within ±6 of the truth. libjxl renders a 2:1 pass with a non-mean-preserving upsampler, so the
    bound cannot be exact.
  - libjxl never emitted `JXL_DEC_FRAME_PROGRESSION` events for these files, not even for a VarDCT `-p` file,
    so the flush probe replaces them.
- **D: lossy 1x base (WebP q75, preset TEXT, method 3, as in `encodeLossy`) plus a lossless 2x completion.**
  The completion is the 2x residual against the pixel-replicated lossy base, coded with ctx. For reference, the
  table also has today's path (lossy 2x q75, then A) and lossy 1x q75 then A.

## Results per 64×64 tile (16,910 non-solid tiles)

Mean bytes per tile; the percentages are relative to A.

| content | n | A: WebP-LL 2x | 1x base | base / A | detail as WebP | zstd-19 | LZ4-HC | ctx | squeeze + ctx | squeeze + zstd-19 | best B total | JXL-LL | JXL squeeze |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| text | 5535 | 602 | 304 | 50 % | 828 (137 %) | 860 (143 %) | 1,142 (189 %) | 774 (129 %) | **654 (108 %)** | 735 (122 %) | **159 %** | 811 (135 %) | 1,119 (186 %) |
| UI | 4734 | 810 | 282 | 35 % | **872 (108 %)** | 959 (118 %) | 1,701 (210 %) | 1,057 (130 %) | 1,004 (124 %) | 902 (111 %) | **140 %** | 1,131 (140 %) | 1,326 (164 %) |
| photo | 2277 | 3,070 | 970 | 32 % | 2,625 (86 %) | 2,670 (87 %) | 4,461 (145 %) | **2,548 (83 %)** | 2,688 (88 %) | 2,856 (93 %) | **115 %** | 2,837 (92 %) | 3,434 (112 %) |
| mixed | 4364 | 962 | 373 | 39 % | 1,038 (108 %) | 1,143 (119 %) | 1,909 (199 %) | 1,322 (137 %) | 1,212 (126 %) | **1,027 (107 %)** | **137 %** | 1,307 (136 %) | 1,551 (161 %) |

zstd-3 is 8–27 % larger than zstd-19 (raw rows in `results/tiles.csv.gz`). The Laplacian variant (2x residual
against the upsampled base, as a WebP image) is worse still: base plus residual is 191 % of A on text, 139 % on
UI and 150 % overall.

What each viewer path puts on the wire, per tile, relative to A:

| content | 1x only | 1x then 2x, plain (base + A) | 1x then 2x, scalable B | D: lossy 1x + lossless completion | today: lossy 2x q75 + A | lossy 1x q75 + A |
|---|---|---|---|---|---|---|
| text | 50 % | **150 %** | 159 % | 272 % | 204 % | 151 % |
| UI | 35 % | **135 %** | 140 % | 204 % | 127 % | 115 % |
| photo | 32 % | 132 % | **115 %** | 149 % | 110 % | 104 % |
| mixed | 39 % | 139 % | **137 %** | 245 % | 134 % | 119 % |

By colour count, all content: flat tiles (2–16 colours) have a 1x base at 62 % of A and best detail at 100 %;
text and simple UI (17–256) are at 43 % and 123 %; rich tiles (257–4096) at 33 % and 91 %.

## Results per whole layer (30 windows, ~2200×1500 px)

Summed per-tile WebP is 1.0–1.8x a single whole-layer WebP (1.8x on text, 1.3x UI, 1.5x mixed, 1.0x photo), which
is why Mirage merges dirty tiles into rects. The layer numbers are the merged-rect limit.

| content | A (KB) | 1x base / A | best B detail / A | best B total / A | JXL plain | JXL + patches | JXL squeeze | JXL squeeze, to 2:1 pass | squeeze, patches off | … to 2:1 pass |
|---|---|---|---|---|---|---|---|---|---|---|
| text | 168 | 46 % | 120 % (squeeze + zstd-19) | 167 % | 191 % | **62 %** | 95 % | 76 % | 291 % | 181 % |
| UI | 323 | 23 % | 75 % (squeeze + zstd-19) | 103 % | 142 % | 119 % | 127 % | 71 % | 142 % | 80 % |
| photo | 2,241 | 29 % | 81 % (zstd-19) | 110 % | 91 % | 88 % | 102 % | 68 % | 102 % | 68 % |
| mixed | 406 | 38 % | 98 % (WebP image) | 126 % | 154 % | 124 % | 137 % | 93 % | 174 % | 103 % |

The "1x base" column is the Haar base. Squeeze's base rounds differently (`(A+B+(A>B))>>1`) and can cost more:
on UI layers it is 30 % of A against 23 %. The totals use each transform's own base.

Layer paths: 1x then 2x costs 146 / 123 / 129 / 138 % of A plain, against 167 / 103 / 110 / 126 % scalable (text /
UI / photo / mixed). The one case where B pays is layers dominated by big smooth areas: gradients, the vibrancy
blur, wallpapers. There the squeeze tendency predicts the detail well. On text it never pays.

JPEG XL patches, layer by layer (KB, A → JXL e7 with patches):

| layer | A → patches |
|---|---|
| bench text | 125 → 23 |
| bench text, dark | 144 → 26 |
| spreadsheet | 116 → 28 |
| SF document | 133 → 52 |
| terminal | 115 → 53 |
| Japanese document | 216 → 149 |
| serif document | 139 → 120 |
| code | 378 → 337 |
| UI and mixed layers | worse than WebP |

Full table: `results/tables.md`.

## Encode / decode time on Apple silicon

M4 Max, single thread, one pass. The median is shown, with the mean in brackets.

Per 64×64 tile (ms):

| codec | encode | decode |
|---|---|---|
| A: WebP-LL 2x, effort 4 | 0.22 (0.47) | 0.024 (0.032) |
| 1x base alone, WebP-LL | 0.12 (0.17) | 0.015 (0.018) |
| B: Haar + base + detail as WebP | 0.39 (0.45) | 0.048 (0.055) |
| B: Haar + base + detail zstd-19 | – | 0.032 (0.036) |
| B: Haar + base + detail ctx | 0.21 (0.27) | 0.11 (0.13) |
| B: squeeze + base + detail ctx | 0.23 (0.29) | 0.16 (0.19) |
| C: JXL-LL e7 | 1.90 (1.91) | 0.22 (0.26) |
| C: JXL squeeze e7 | 2.17 (2.82) | 0.23 (0.25) |

Per ~3.3 MP layer (ms):

| codec | encode | decode |
|---|---|---|
| A: WebP-LL 2x, effort 4 | 427 (359) | 10 (11) |
| 1x base alone | 46 (90) | 2 (3) |
| B: Haar + base + detail as WebP | 185 (221) | 13 (15) |
| B: Haar + base + detail ctx | 116 (146) | 50 (62) |
| C: JXL-LL e7 | 814 (942) | 153 (174) |
| C: JXL squeeze e7 | 1073 (1556) | 117 (131) |
| C: JXL e7 + patches | 1007 (1321) | 145 (194) |

All the B variants are cheap. Time is not B's problem; bytes are. JXL takes about 9x WebP's encode and decode
time per tile, and 12–15x its decode time on layers.

## JPEG XL in ImageIO

Checked with `jxlcheck.swift` on macOS 27.0.1 and in the iOS 18.3 simulator.

- **Decoding works on both.** `public.jpeg-xl` is a decodable type. Encoding is not offered.
- **RGB lossless files decode bit-exactly**: plain, squeeze and patches. 3.4 MP takes about 115–190 ms including
  the draw.
- **Squeeze with an alpha channel decodes wrong on both.** It gives a blank, all-zero image, while libjxl's djxl
  decodes the same file exactly. Mirage's window layers have alpha, so ImageIO could not be trusted with
  responsive JXL there.
- **No progressive decode.**
  - On macOS, `CGImageSourceCreateIncremental` returns no image for any prefix from 10 % to 90 %. The status
    stays incomplete until all bytes are in.
  - On the iOS simulator it returns an image for every prefix, but it is blank.
  - So progressive JXL would mean shipping libjxl (C++ with highway) in the viewer.

## Scroll copy-rects with a 1x base derived from the 2x grid

Copy-rects stay in 2x pixels. Write dy for the scroll in 2x pixels.

- **The 2x grid stays exact.** A viewer that holds 2x pixels applies the copy exactly, as today. It re-derives the
  base of the moved tiles itself, since the base is a deterministic function of the 2x pixels.
- **Even dy (and dx): the base copy is exact.** 2x2 blocks map onto 2x2 blocks, so the 1x base moves by dy/2. Haar
  bands are block-local, so they move exactly too. Squeeze bands are not exact at a rect's edges, because the
  tendency reads the neighbouring averages, which is one more reason to prefer Haar if scalability ever came back.
  Measured: 100 % of 1x samples exact for dy = 2 on all 30 layers.
- **Odd dy with base only: not exact.** The new 1x row straddles two old blocks.
  - The base-only viewer's best guess, the mean of the two base rows, gets **82 %** of 1x samples exact over all
    content: 87 % text, 90 % UI, 81 % mixed, 46 % photo. The rest are anti-aliased edges, off by a half-pixel
    resample.
- **Odd dy with base plus the LH band: exact.** With the S-transform (horizontal step first), `l1 = LL +
  ((LH+1)>>1), l2 = l1 − LH` are the two row-pair means of each block. After an odd shift the new block is (old
  l2 of block j+k, old l1 of block j+k+1), so the new `LL = (l2 + l1')>>1` exactly. Measured: 100 %.
  - Horizontal odd shifts need the per-row differences, which means HL and HH, the full detail.
  - Holding LH costs 43 % of A over all content (63 % on text), more than a fresh 1x base (32 %, 46 % on text).
    Keeping it "in case of a scroll" never pays.
- **Proposed scheme:**
  1. Copy-rects stay on the 2x grid; the host is unchanged. The host's per-viewer tile state records, for each
     tile, whether the viewer holds it at 2x-exact, 1x-exact or 1x-approximate.
  2. A viewer holding 2x applies the copy at 2x and re-derives the 1x it displays. This is always exact.
  3. A 1x viewer, even dy and dx: shift the base by (dx/2, dy/2). This is exact; no refresh is needed.
  4. A 1x viewer, odd dy or dx: apply the copy as a half-pixel resample of its base (the two-row mean; 82–90 % of
     text and UI samples exact), shown at once during the scroll. Mark the destination tiles 1x-approximate. When
     the scroll settles, the host refreshes those tiles' base through the normal lossless refinement queue,
     viewport first. That costs one 1x paint of the scrolled area: 46 % of the 2x cost on text, 32 % overall.
     Coding it as a residual against the guess is no cheaper.
  5. Intermediate frames of a continuous trackpad scroll stay approximate. Only the settled position is
     refreshed, so during motion the copy-rect saving is kept.
  6. A host-side refinement: when a 1x viewer's scroll ends on an odd offset, refresh only the rows that differ
     (the 18 % of samples on edges). The tile tracker already works per tile, so this is the same mechanism.
- **Unmeasured: how often real scrolls are odd.** macOS scrolls in points; line and wheel scrolls at 2x are even
  in pixels, while smooth trackpad scrolling lands on half points. The byterace scroll recordings could answer
  it; the sequences are not in the repo.

## Recommendation

1. **Do not build resolution-scalable lossless (B or C) into the tile path.** On text and UI, the upgrade detail
   costs 105–137 % of the 2x tile it replaces, and base plus detail is 1.4–1.6x the 2x tile. The best variants
   (squeeze + ctx on text, detail as a WebP image on UI) would need a custom coder in every client to beat
   resending the 2x by nothing. If it were ever wanted for smooth layers, the variant to take is Haar with detail
   as a WebP image or zstd-19: it is block-local (exact under even copies), uses only libraries Mirage has, and
   costs 0.39 ms to encode a tile and 0.05 ms to decode it.
2. **Make the stream's scale a per-viewer choice with plain WebP lossless:**
   - 1x tiles for a phone at fit, a non-Retina Mac or a poor link. Derive them from the 2x capture with the
     exact 2x2 S-transform LL (or `(a+b+c+d+2)>>2`) so that even copies stay exact.
   - 2x tiles for Retina viewers.
   - On an upgrade (zoom in, link improves), resend 2x for the tiles in view, in priority order. That is +100 %
     of A over what the 1x cost, against +105–137 % for any scalable detail.
3. **Never stream 1.5x lossless.** Send 2x (or 1x on a weak link) and let the viewer resample.
4. **Below 1x on poor links, go lossy**, not lossless at a lower scale.
   - Lossy 1x q75 then A costs 118 % of A per tile, against 136 % for today's lossy 2x q75 then A. So a 1x lossy
     first picture is the cheaper preview, even for 2x viewers.
   - D (lossy base plus lossless completion) is always worse (205 %): the completion residual costs more than A.
5. **Follow up on JPEG XL patches** for merged text rects or whole-window lossless paints: 62 % of WebP on text
   layers. That needs a measurement of per-rect sizes (256–512 px), libjxl's encode time at lower efforts, and the
   viewer's decode cost: about 145 ms per 3.3 MP, and ImageIO can be used for RGB but not responsive+alpha.

## Not verified

- **iOS** was checked only in the iOS 18.3 simulator's ImageIO, not on a device and not on iOS 26/27. **macOS
  27.0.1** only.
- **JXL's 2:1 pass is located by a flush-and-compare probe** (block means within ±6), because libjxl 0.12 emitted
  no progression events. It is approximate. Layers 1–13 used 256-byte probe steps; the rest used size/400.
- **Photo content is thin**: 3 layers, one of them synthetic noise. Real camera photos and web pages are missing.
  Text is bench and AppKit-rendered, and more repetitive than real documents; that flatters JXL patches most.
- **The ctx coder is a quick design.** A stronger detail coder could shave detail by perhaps 10–20 %. The text and
  UI conclusions would hold unless detail fell below ~50 % of A, and nothing measured comes close (best 105 %).
- **Timings** come from one pass per tile on the M4 Max laptop (not the M3 Ultra host). Part of the run shared the
  machine with the bytes-only side study.
- **The Laplacian variant was not round-tripped.** It is invertible by construction (mod 256 against a known base).
- **The libwebp is Homebrew's 1.6.0**, the same version as the vendored `CWebP`, not the vendored build itself.

## Files and reproduction

```
sh make.sh                         # .build/scalebench (C), .build/render; needs Homebrew webp, jpeg-xl, zstd, lz4
sh corpus/capture.sh corpus/out    # 12 Test Bench window captures (needs Screen Recording already granted)
sh corpus/render.sh                # 18 offscreen renders
sh run.sh                          # results/{tiles,layers,scroll,scales,lap}.csv (about 40 min)
python3 analyze.py > results/tables.md
swiftc -O -o .build/jxlcheck jxlcheck.swift && .build/jxlcheck REF.png FILE.jxl …   # ImageIO check
```

- `scalebench.c` holds all the candidates and the round-trip checks. Its other modes are `--scroll` (the
  copy-rect study), `--scales` (the plain 1x / 1.5x / 2x ladder), `--lap` (the Laplacian variant), and
  `--jxlprobe` / `--jxlfile` (libjxl progression probes).
- `results/tiles.csv.gz` holds the raw per-tile rows; `analyze.py` reads it directly.
- The scene code is shared with the Test Bench: `experiments/testbench/scenes.swift`.
