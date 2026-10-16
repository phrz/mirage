# tilebench — lossless tile codec cost on real Mac screens

Question: when a settled region needs a crisp (lossless) refresh, what does a tile cost, and
which codec should Mirage use? Measured 2026-10-16 on 2x Retina captures of a Claude window,
Mail, Finder, Sketch, Icon Composer and a full 3024×1964 desktop, M4 Max, macOS 27.

Run: `swift build -c release && .build/release/tilebench img.png ...` (TILE=128 for larger
tiles, NO_CLI=1 to skip cwebp/zstd). Raw results: `results-64.txt`, `results-128.txt`.

## Mean bytes per 64×64 tile, by content class

| class (unique colours) | zlib | pal+LZFSE | **WebP lossless** | WebP near-lossless 60 | zstd -19 (Paeth) |
|---|---|---|---|---|---|
| uniform (1) | 30 | 150 | 44 | 44 | 24 |
| flat (≤16) | 95–140 | 190–210 | 76–98 | same | 62–96 |
| text (≤256) | 950–1190 | 980–1230 | **527–786** | same | 960–1370 |
| rich (>256) | 1740–5400 | 1870–4960 | 1340–3530 | 1120–2890 | 1670–4390 |

Whole-frame totals (all tiles lossless) vs hardware HEVC intra of the same frame:

| frame | WebP lossless | best Apple-framework | HEVC qp26 | HEVC qp32 | JPEG q.75 |
|---|---|---|---|---|---|
| Claude window 1510×1898 | 220 KB | 404 KB | 125 KB | 88 KB | 330 KB |
| Mail 2410×1898 | 299 KB | 544 KB | 125 KB | 82 KB | 346 KB |
| full desktop 3024×1964 | 623 KB | 1108 KB | 275 KB | 194 KB | 745 KB |

## Conclusions for M2

1. **Use libwebp lossless for refinement tiles.** It is ~2x smaller than anything in Apple's
   Compression framework on text and UI, and decodes fast. Link the C library; the CLI was
   only for measurement.
2. **Predictors are useless here.** Sub/Paeth filtering before LZFSE/zstd is *worse* than
   raw LZ on UI content; flat UI wins on long exact matches, not on residual entropy. WebP's
   own palette/colour-cache modes are what make the difference.
3. **Near-lossless only pays on rich tiles** (photos, gradients: −20 %); on text it is
   identical, so classify and apply it per tile, not globally.
4. **Bigger tiles compress ~2x better per pixel** (128 px text tile ≈ 2.0 KB with
   pal+LZFSE vs 4×1.0 KB for 64 px). Keep the 64 px dirty-tracking grid for sparse updates,
   but encode the union of adjacent dirty tiles as one WebP rect so large refreshes get the
   big-tile efficiency.
5. **Serialization budget at 1 Mbps (125 KB/s):** one text tile ≈ 4 ms, a keystroke
   dirtying 2–3 tiles ≈ 10 ms, a full window of text lossless ≈ 1.5–2 s, HEVC intra of the
   same window at qp32 ≈ 0.7 s. So at 1 Mbps the resolution ladder must drop motion to 1x,
   and lossless refinement must be budgeted and prioritised (viewport centre first, oldest
   dirty first), never sent as a block.
6. HEVC intra is 2–3x smaller than lossless at qp26–32 and text is still readable at qp26;
   this is the right first picture for a newly opened window, with lossless tiles catching
   up behind it.
