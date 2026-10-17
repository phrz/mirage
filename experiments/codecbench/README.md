# codecbench — lossless screen-content codecs: size, encode time, decode time

Question: is WebP lossless (chosen for Mirage's tile path) the right pick against JPEG XL,
AVIF and HEIC lossless on real desktop captures? Measured 2026-10-17 on an M4 Max with the
Homebrew CLIs (libwebp 1.6.0, libjxl 0.12.0, libavif 1.4.2/aom 3.15.1, libheif 1.23.5/x265),
process spawn overhead measured per tool and subtracted, median of 5 runs. `bench.py`.

## Whole images

| codec | Claude window 1510×1898 (PNG 505 KB) | | | full desktop 3024×1964 (PNG 1435 KB) | | |
|---|---|---|---|---|---|---|
| | KB | enc ms | dec ms | KB | enc ms | dec ms |
| **WebP lossless z6** | **119** | 89 | 77 | **545** | 1271 | 197 |
| WebP lossless z9 | 110 | 2575 | 75 | 473 | 5653 | 190 |
| JPEG XL lossless e3 | 367 | 52 | 81 | 867 | 91 | 158 |
| JPEG XL lossless e7 | 206 | 116 | 67 | 605 | 198 | 139 |
| JPEG XL d=1 (visually lossless) | 257 | 72 | 85 | 579 | 128 | 185 |
| AVIF lossless s10 | 1192 | 180 | 160 | 2874 | 339 | 365 |
| AVIF lossless s6 | 572 | 1362 | 122 | 1302 | 2659 | 273 |
| HEIC lossless (x265) | 730 | 226 | 140 | 1818 | 438 | 369 |

## 256×256 rects (the unit M2 actually sends after merging dirty tiles)

| codec | text rect (PNG 16 KB) KB / enc / dec | desktop rect (PNG 14 KB) KB / enc / dec |
|---|---|---|
| **WebP lossless z6** | **2.8** / 5.7 ms / <1 ms | **4.1** / 2.8 ms / <1 ms |
| JPEG XL lossless e3 | 6.2 / 11 / 2.3 | 8.6 / 9 / 1.7 |
| JPEG XL lossless e7 | 4.8 / 18 / 2.8 | 6.7 / 18 / 3.3 |
| AVIF lossless s10 | 21 / 3 / 2 | 41 / 4 / 3 |
| HEIC lossless | 16 / 32 / 8.5 | 28 / 22 / 7 |

(Per-64-px-tile class breakdown, including QOI and JXL/AVIF/HEIC, in
`../tilebench/results-codecs-64.txt`.)

## Conclusions

1. **WebP lossless is the right codec for UI pixels, by a wide margin.** On screen content it
   is 1.7–3x smaller than JPEG XL lossless and 5–10x smaller than AVIF or HEIC lossless, and
   it decodes fastest. The reason is structural: WebP lossless has a colour cache, palette
   mode and LZ77 over pixels, which is exactly what flat UI with repeated glyphs wants; JXL's
   modular mode and the video-derived intra coders (AV1, HEVC) are built for photographs.
2. **JPEG XL is the only credible alternative**, and only if encode time of large regions
   becomes the bottleneck: at e3 it encodes a whole 6-megapixel desktop in 91 ms versus
   WebP's 1.27 s, at 1.6x the bytes. Mirage never encodes whole desktops losslessly (that is
   the video path's job) and 256 px rects take WebP 3–6 ms, so WebP stays. If a big lossless
   region is ever needed quickly, split it into rects and encode them in parallel, or drop
   to `-z 4`.
3. **AVIF and HEIC lossless are out**: large, slow, and there is no hardware help for lossless
   on Apple silicon anyway.
4. Decoding cost is a non-issue for every candidate at rect size; WebP is still the cheapest,
   which matters on iPhone later.
