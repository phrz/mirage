Corpus: 30 layers, 16910 non-solid 64x64 tiles measured, 6958 solid tiles skipped.

### Tiles (64x64 at 2x): mean bytes and ratio to A

| content | n | A: WebP-LL 2x | 1x base (WebP-LL) | base / A | detail: WebP img | zstd-19 | LZ4-HC | ctx | squeeze+ctx | squeeze+zstd-19 | B total best / A | JXL-LL 2x | JXL squeeze 2x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| text | 5535 | 602 | 304 | 50 % | 828 (137 %) | 860 (143 %) | 1,142 (189 %) | 774 (129 %) | 654 (108 %) | 735 (122 %) | 159 % | 811 (135 %) | 1,119 (186 %) |
| ui | 4734 | 810 | 282 | 35 % | 872 (108 %) | 959 (118 %) | 1,701 (210 %) | 1,057 (130 %) | 1,004 (124 %) | 902 (111 %) | 140 % | 1,131 (140 %) | 1,326 (164 %) |
| photo | 2277 | 3,070 | 970 | 32 % | 2,625 (86 %) | 2,670 (87 %) | 4,461 (145 %) | 2,548 (83 %) | 2,688 (88 %) | 2,856 (93 %) | 115 % | 2,837 (92 %) | 3,434 (112 %) |
| mixed | 4364 | 962 | 373 | 39 % | 1,038 (108 %) | 1,143 (119 %) | 1,909 (199 %) | 1,322 (137 %) | 1,212 (126 %) | 1,027 (107 %) | 137 % | 1,307 (136 %) | 1,551 (161 %) |
| all | 16910 | 1,085 | 405 | 37 % | 1,137 (105 %) | 1,204 (111 %) | 1,943 (179 %) | 1,233 (114 %) | 1,170 (108 %) | 1,143 (105 %) | 138 % | 1,301 (120 %) | 1,600 (147 %) |

### Tiles: bytes on the wire for each viewer path, relative to A (2x WebP lossless, sent once)

| content | 1x only | 1x then 2x, non-scalable (base + A) | 1x then 2x, scalable B (base + best detail) | 2x only via B | D: lossy 1x q75 + 2x completion | today: lossy 2x q75 + A | lossy 1x q75 + A |
|---|---|---|---|---|---|---|---|
| text | 50 % | 150 % | 159 % | 159 % | 272 % | 204 % | 151 % |
| ui | 35 % | 135 % | 140 % | 140 % | 204 % | 127 % | 115 % |
| photo | 32 % | 132 % | 115 % | 115 % | 149 % | 110 % | 104 % |
| mixed | 39 % | 139 % | 137 % | 137 % | 245 % | 134 % | 119 % |
| all | 37 % | 137 % | 138 % | 138 % | 205 % | 136 % | 118 % |

### Tiles by colour count (all content): detail vs A

| tiles | n | A mean B | 1x base / A | best detail / A | JXL-LL / A | JXL squeeze / A |
|---|---|---|---|---|---|---|
| 2-16 colours (flat UI) | 2527 | 131 | 62 % | 100 % | 95 % | 235 % |
| 17-256 (text, simple UI) | 10688 | 708 | 43 % | 123 % | 148 % | 181 % |
| 257-4096 (rich UI, AA) | 3695 | 2,830 | 33 % | 91 % | 100 % | 121 % |

### Layers (whole 2200x1500-class windows): mean bytes and ratio to A

| content | n | A: WebP-LL 2x | 1x base (WebP-LL) | base / A | detail: WebP img | zstd-19 | LZ4-HC | ctx | squeeze+ctx | squeeze+zstd-19 | B total best / A | JXL-LL 2x | JXL squeeze 2x |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| text | 11 | 167,537 | 76,936 | 46 % | 230,447 (138 %) | 222,591 (133 %) | 387,530 (231 %) | 321,640 (192 %) | 277,541 (166 %) | 201,080 (120 %) | 167 % | 320,651 (191 %) | 159,585 (95 %) |
| ui | 9 | 322,946 | 75,498 | 23 % | 259,202 (80 %) | 257,356 (80 %) | 468,232 (145 %) | 471,492 (146 %) | 456,313 (141 %) | 243,174 (75 %) | 103 % | 457,660 (142 %) | 409,865 (127 %) |
| photo | 3 | 2,241,465 | 660,356 | 29 % | 1,899,849 (85 %) | 1,809,410 (81 %) | 2,755,395 (123 %) | 1,873,278 (84 %) | 2,002,574 (89 %) | 1,909,474 (85 %) | 110 % | 2,035,031 (91 %) | 2,281,586 (102 %) |
| mixed | 7 | 405,762 | 153,289 | 38 % | 398,193 (98 %) | 445,823 (110 %) | 675,593 (167 %) | 711,178 (175 %) | 659,895 (163 %) | 405,007 (100 %) | 126 % | 623,991 (154 %) | 556,186 (137 %) |
| all | 30 | 477,139 | 152,662 | 32 % | 445,154 (93 %) | 443,790 (93 %) | 715,742 (150 %) | 612,652 (128 %) | 592,892 (124 %) | 432,130 (91 %) | 124 % | 603,971 (127 %) | 539,409 (113 %) |

### Layers: bytes on the wire for each viewer path, relative to A (2x WebP lossless, sent once)

| content | 1x only | 1x then 2x, non-scalable (base + A) | 1x then 2x, scalable B (base + best detail) | 2x only via B | D: lossy 1x q75 + 2x completion | today: lossy 2x q75 + A | lossy 1x q75 + A |
|---|---|---|---|---|---|---|---|
| text | 46 % | 146 % | 167 % | 167 % | 421 % | 249 % | 162 % |
| ui | 23 % | 123 % | 103 % | 103 % | 239 % | 124 % | 110 % |
| photo | 29 % | 129 % | 110 % | 110 % | 149 % | 107 % | 102 % |
| mixed | 38 % | 138 % | 126 % | 126 % | 328 % | 137 % | 116 % |
| all | 32 % | 132 % | 124 % | 124 % | 238 % | 135 % | 114 % |

### Layers: JPEG XL lossless variants (effort 7), relative to A

| content | A (KB) | JXL plain | JXL plain + patches | JXL squeeze (patches default on) | … bytes to 2:1 pass | JXL squeeze, patches off | … bytes to 2:1 pass | 1x base WebP (KB) |
|---|---|---|---|---|---|---|---|---|
| text | 168 | 191 % | 62 % | 95 % | 76 % (11/11) | 291 % | 181 % (11/11) | 77 |
| ui | 323 | 142 % | 119 % | 127 % | 71 % (9/9) | 142 % | 80 % (9/9) | 75 |
| photo | 2,241 | 91 % | 88 % | 102 % | 68 % (3/3) | 102 % | 68 % (3/3) | 660 |
| mixed | 406 | 154 % | 124 % | 137 % | 93 % (7/7) | 174 % | 103 % (7/7) | 153 |
| all | 477 | 127 % | 98 % | 113 % | 74 % (30/30) | 149 % | 92 % (30/30) | 153 |

### Layers, one by one (KB)

| image | content | A | 1x base | B best detail | JXL plain | JXL+patches | JXL squeeze | to 2:1 | squeeze no patches | to 2:1 |
|---|---|---|---|---|---|---|---|---|---|---|
| r-document-japanese.png | text | 216 | 107 | 210 | 321 | 149 | 216 | 216 | 465 | 294 |
| r-document-sans-dark.png | text | 135 | 76 | 186 | 347 | 57 | 87 | 80 | 539 | 334 |
| r-document-sans.png | text | 133 | 74 | 185 | 354 | 52 | 79 | 73 | 535 | 328 |
| r-document-serif.png | text | 139 | 76 | 197 | 382 | 120 | 182 | 181 | 552 | 342 |
| r-document-small.png | text | 114 | 60 | 167 | 301 | 90 | 126 | 125 | 426 | 251 |
| r-spreadsheet.png | text | 116 | 57 | 160 | 323 | 28 | 71 | 65 | 486 | 312 |
| r-terminal-seed2.png | text | 115 | 61 | 144 | 230 | 53 | 80 | 61 | 373 | 231 |
| w-code.png | text | 378 | 111 | 333 | 392 | 337 | 535 | 338 | 617 | 379 |
| w-terminal.png | text | 228 | 88 | 297 | 328 | 210 | 307 | 196 | 485 | 291 |
| w-text-dark.png | text | 144 | 76 | 134 | 271 | 26 | 40 | 31 | 441 | 284 |
| w-text.png | text | 125 | 61 | 140 | 278 | 23 | 32 | 27 | 444 | 282 |
| r-controls.png | ui | 41 | 20 | 51 | 66 | 35 | 58 | 42 | 100 | 63 |
| r-gradients.png | ui | 1107 | 206 | 810 | 1129 | 1173 | 1414 | 717 | 1414 | 718 |
| r-icons-dark.png | ui | 186 | 64 | 159 | 204 | 160 | 217 | 128 | 261 | 151 |
| r-icons.png | ui | 191 | 65 | 165 | 210 | 160 | 219 | 128 | 267 | 153 |
| r-vibrancy-dark.png | ui | 277 | 77 | 236 | 250 | 148 | 264 | 160 | 430 | 256 |
| w-controls-dark.png | ui | 50 | 26 | 71 | 86 | 45 | 85 | 61 | 162 | 101 |
| w-controls.png | ui | 93 | 32 | 87 | 102 | 72 | 115 | 98 | 160 | 135 |
| w-vibrancy-dark.png | ui | 511 | 101 | 310 | 1108 | 845 | 689 | 387 | 690 | 388 |
| w-vibrancy.png | ui | 451 | 88 | 281 | 963 | 828 | 628 | 350 | 631 | 350 |
| r-noise-photo.png | photo | 1982 | 622 | 1637 | 1855 | 1737 | 2045 | 971 | 2045 | 971 |
| r-wallpaper.png | photo | 2446 | 654 | 1951 | 2271 | 2258 | 2464 | 1275 | 2464 | 1275 |
| w-photos.png | photo | 2297 | 705 | 1526 | 1979 | 1950 | 2336 | 2295 | 2337 | 2296 |
| r-chat.png | mixed | 107 | 55 | 158 | 209 | 60 | 123 | 118 | 490 | 311 |
| r-dashboard-dark.png | mixed | 115 | 46 | 103 | 185 | 172 | 315 | 244 | 322 | 190 |
| r-dashboard.png | mixed | 104 | 42 | 99 | 158 | 145 | 323 | 253 | 331 | 197 |
| r-mixed-seed2.png | mixed | 661 | 241 | 590 | 691 | 555 | 710 | 426 | 910 | 543 |
| w-chat-dark.png | mixed | 537 | 181 | 454 | 1443 | 1209 | 940 | 534 | 941 | 532 |
| w-mixed-dark.png | mixed | 654 | 254 | 555 | 876 | 721 | 744 | 539 | 977 | 584 |
| w-mixed.png | mixed | 662 | 253 | 552 | 806 | 657 | 738 | 535 | 969 | 577 |

### Tiles (64x64): encode / decode ms (single thread, M4 Max P-core; median, mean in brackets)

| codec | encode | decode |
|---|---|---|
| A: WebP-LL 2x (effort 4) | 0.218 (0.468) | 0.024 (0.032) |
| 1x base alone (WebP-LL effort 4) | 0.119 (0.167) | 0.015 (0.018) |
| B: Haar + base WebP + detail WebP | 0.393 (0.449) | 0.048 (0.055) |
| B: Haar + base WebP + detail zstd-19 (decode only) | - | 0.032 (0.036) |
| B: Haar + base WebP + detail ctx | 0.209 (0.268) | 0.113 (0.133) |
| B: squeeze + base WebP + detail ctx | 0.226 (0.288) | 0.163 (0.187) |
| C: JXL-LL e7 | 1.900 (1.907) | 0.223 (0.264) |
| C: JXL squeeze e7 | 2.173 (2.819) | 0.227 (0.251) |

### Layers (~3.3 MP): encode / decode ms (single thread, M4 Max P-core; median, mean in brackets)

| codec | encode | decode |
|---|---|---|
| A: WebP-LL 2x (effort 4) | 427 (359) | 10 (11) |
| 1x base alone (WebP-LL effort 4) | 46 (90) | 2 (3) |
| B: Haar + base WebP + detail WebP | 185 (221) | 13 (15) |
| B: Haar + base WebP + detail zstd-19 (decode only) | - | 11 (12) |
| B: Haar + base WebP + detail ctx | 116 (146) | 50 (62) |
| B: squeeze + base WebP + detail ctx | 190 (179) | 101 (116) |
| C: JXL-LL e7 | 814 (942) | 153 (174) |
| C: JXL squeeze e7 | 1073 (1556) | 117 (131) |
| C: JXL e7 + patches | 1007 (1321) | 145 (194) |

### Scroll by dy 2x pixels, whole layers: can a 1x client follow the copy?

| content | dy | 1x samples exact from base alone | exact from base + LH band | fresh 1x base (WebP) / A | residual vs guess (ctx) / A | LH band (ctx) / A |
|---|---|---|---|---|---|---|
| text | 1 | 86.7 % | 100.0 % | 46 % | 65 % | 63 % |
| text | 2 | 100.0 % | 100.0 % | 46 % | 1 % | 63 % |
| ui | 1 | 90.0 % | 100.0 % | 24 % | 33 % | 46 % |
| ui | 2 | 100.0 % | 100.0 % | 23 % | 1 % | 46 % |
| photo | 1 | 45.6 % | 100.0 % | 29 % | 21 % | 30 % |
| photo | 2 | 100.0 % | 100.0 % | 29 % | 0 % | 30 % |
| mixed | 1 | 81.1 % | 100.0 % | 38 % | 46 % | 58 % |
| mixed | 2 | 100.0 % | 100.0 % | 38 % | 0 % | 58 % |
| all | 1 | 82.3 % | 100.0 % | 32 % | 34 % | 43 % |
| all | 2 | 100.0 % | 100.0 % | 32 % | 0 % | 43 % |

### A plain (non-scalable) ladder: WebP lossless of the same screen area at 2x, 1.5x and 1x

| content | layers: 1.5x / 2x | layers: 1x / 2x | tiles: 1.5x / 2x | tiles: 1x / 2x | tiles vs whole layer at 2x |
|---|---|---|---|---|---|
| text | 112 % | 46 % | 95 % | 50 % | 181 % |
| ui | 67 % | 23 % | 68 % | 32 % | 132 % |
| photo | 62 % | 30 % | 64 % | 32 % | 104 % |
| mixed | 76 % | 38 % | 71 % | 38 % | 148 % |
| all | 72 % | 32 % | 72 % | 37 % | 128 % |

### B as a Laplacian pyramid: 2x residual against the upsampled 1x base, mod 256, as a WebP lossless image (tiles)

| content | 1x base / A | residual, nearest / A | residual, bilinear / A | base + best residual / A |
|---|---|---|---|---|
| text | 50 % | 140 % | 196 % | 191 % |
| ui | 35 % | 104 % | 122 % | 139 % |
| photo | 32 % | 105 % | 103 % | 135 % |
| mixed | 39 % | 113 % | 128 % | 151 % |
| all | 37 % | 113 % | 130 % | 150 % |
