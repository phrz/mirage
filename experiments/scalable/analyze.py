#!/usr/bin/env python3
"""Turns results/{tiles,layers,scroll}.csv into the markdown tables of RESULTS.md (printed to stdout)."""
import csv, gzip, statistics, sys, os

D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "results")
def load(name):
    p = os.path.join(D, name)
    if os.path.exists(p): rows = list(csv.DictReader(open(p)))
    elif os.path.exists(p + ".gz"): rows = list(csv.DictReader(gzip.open(p + ".gz", "rt")))
    else: return []
    return [r for r in rows if None not in r.values()]   # drop a row still being written
tiles, layers, scroll, scales, lap = (load(n) for n in ["tiles.csv", "layers.csv", "scroll.csv", "scales.csv", "lap.csv"])
CATS = ["text", "ui", "photo", "mixed"]

def f(r, k): return float(r[k])
def S(rows, k): return sum(f(r, k) for r in rows)
def by(rows, c): return [r for r in rows if r["cat"] == c]
def groups(rows): return [(c, by(rows, c)) for c in CATS] + [("all", rows)]

def table(head, lines):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(str(x) for x in l) + " |" for l in lines]
    return "\n".join(out)

def pct(a, b): return f"{100 * a / b:.0f} %"

def section_bytes(rows, unit, per):
    """Mean bytes per unit and ratios to A."""
    print(f"\n### {unit}: mean bytes and ratio to A\n")
    head = ["content", "n", "A: WebP-LL 2x", "1x base (WebP-LL)", "base / A",
            "detail: WebP img", "zstd-19", "LZ4-HC", "ctx", "squeeze+ctx", "squeeze+zstd-19",
            "B total best / A", "JXL-LL 2x", "JXL squeeze 2x"]
    lines = []
    for c, rs in groups(rows):
        if not rs: continue
        n = len(rs); A = S(rs, "A"); base = S(rs, "base_haar")
        det = {k: S(rs, k) for k in ["dwebp_haar", "dz19_haar", "dlz4_haar", "dctx_haar", "dctx_sq", "dz19_sq"]}
        btot = min(S(rs, "base_haar") + min(S(rs, k) for k in ["dwebp_haar", "dz19_haar", "dctx_haar"]),
                   S(rs, "base_sq") + min(S(rs, k) for k in ["dwebp_sq", "dz19_sq", "dctx_sq"]))
        lines.append([c, n, f"{A / n:,.0f}", f"{base / n:,.0f}", pct(base, A)] +
                     [f"{det[k] / n:,.0f} ({pct(det[k], A)})" for k in det] +
                     [pct(btot, A), f"{S(rs, 'jxl') / n:,.0f} ({pct(S(rs, 'jxl'), A)})", f"{S(rs, 'jxlsq_full') / n:,.0f} ({pct(S(rs, 'jxlsq_full'), A)})"])
    print(table(head, lines))

def section_paths(rows, unit):
    print(f"\n### {unit}: bytes on the wire for each viewer path, relative to A (2x WebP lossless, sent once)\n")
    head = ["content", "1x only", "1x then 2x, non-scalable (base + A)", "1x then 2x, scalable B (base + best detail)",
            "2x only via B", "D: lossy 1x q75 + 2x completion", "today: lossy 2x q75 + A", "lossy 1x q75 + A"]
    lines = []
    for c, rs in groups(rows):
        if not rs: continue
        A = S(rs, "A"); base = S(rs, "base_haar")
        best = min(S(rs, "base_haar") + min(S(rs, k) for k in ["dwebp_haar", "dz19_haar", "dctx_haar"]),
                   S(rs, "base_sq") + min(S(rs, k) for k in ["dwebp_sq", "dz19_sq", "dctx_sq"]))
        lines.append([c, pct(base, A), pct(base + A, A), pct(best, A), pct(best, A), pct(S(rs, "lossy1x") + S(rs, "compl"), A),
                      pct(S(rs, "lossy2x") + A, A), pct(S(rs, "lossy1x") + A, A)])
    print(table(head, lines))

def section_jxl_layers(rows):
    print("\n### Layers: JPEG XL lossless variants (effort 7), relative to A\n")
    head = ["content", "A (KB)", "JXL plain", "JXL plain + patches", "JXL squeeze (patches default on)", "… bytes to 2:1 pass",
            "JXL squeeze, patches off", "… bytes to 2:1 pass", "1x base WebP (KB)"]
    lines = []
    for c, rs in groups(rows):
        if not rs: continue
        A = S(rs, "A")
        two = [r for r in rs if f(r, "jxlsq_2x") > 0]; twonp = [r for r in rs if f(r, "jxlsq_np_2x") > 0]
        lines.append([c, f"{A / len(rs) / 1000:,.0f}", pct(S(rs, "jxl"), A), pct(S(rs, "jxlp"), A), pct(S(rs, "jxlsq_full"), A),
                      f"{pct(S(two, 'jxlsq_2x'), S(two, 'A'))} ({len(two)}/{len(rs)})" if two else "-",
                      pct(S(rs, "jxlsq_np"), A),
                      f"{pct(S(twonp, 'jxlsq_np_2x'), S(twonp, 'A'))} ({len(twonp)}/{len(rs)})" if twonp else "-",
                      f"{S(rs, 'base_haar') / len(rs) / 1000:,.0f}"])
    print(table(head, lines))

def section_layer_list(rows):
    print("\n### Layers, one by one (KB)\n")
    head = ["image", "content", "A", "1x base", "B best detail", "JXL plain", "JXL+patches", "JXL squeeze", "to 2:1", "squeeze no patches", "to 2:1"]
    lines = []
    for r in sorted(rows, key=lambda r: (CATS.index(r["cat"]), r["image"])):
        best = min(f(r, "base_haar") + min(f(r, k) for k in ["dwebp_haar", "dz19_haar", "dctx_haar"]), f(r, "base_sq") + min(f(r, k) for k in ["dwebp_sq", "dz19_sq", "dctx_sq"]))
        lines.append([r["image"], r["cat"], f"{f(r,'A')/1000:.0f}", f"{f(r,'base_haar')/1000:.0f}", f"{(best - f(r,'base_haar'))/1000:.0f}",
                      f"{f(r,'jxl')/1000:.0f}", f"{f(r,'jxlp')/1000:.0f}", f"{f(r,'jxlsq_full')/1000:.0f}", f"{f(r,'jxlsq_2x')/1000:.0f}",
                      f"{f(r,'jxlsq_np')/1000:.0f}", f"{f(r,'jxlsq_np_2x')/1000:.0f}"])
    print(table(head, lines))

def section_times(rows, unit):
    print(f"\n### {unit}: encode / decode ms (single thread, M4 Max P-core; median, mean in brackets)\n")
    def m(k):
        v = [f(r, k) for r in rows]
        return f"{statistics.median(v):.3f} ({statistics.mean(v):.3f})" if unit.startswith("Tiles") else f"{statistics.median(v):.0f} ({statistics.mean(v):.0f})"
    lines = [["A: WebP-LL 2x (effort 4)", m("tA_enc"), m("tA_dec")],
             ["1x base alone (WebP-LL effort 4)", m("tbase_enc"), m("tbase_dec")],
             ["B: Haar + base WebP + detail WebP", m("tBw_enc"), m("tBw_dec")],
             ["B: Haar + base WebP + detail zstd-19 (decode only)", "-", m("tz_dec")],
             ["B: Haar + base WebP + detail ctx", m("tBctx_enc"), m("tBctx_dec")],
             ["B: squeeze + base WebP + detail ctx", m("tBsq_enc"), m("tBsq_dec")],
             ["C: JXL-LL e7", m("tJ_enc"), m("tJ_dec")],
             ["C: JXL squeeze e7", m("tJsq_enc"), m("tJsq_dec")]]
    if not unit.startswith("Tiles"): lines.append(["C: JXL e7 + patches", m("tJp_enc"), m("tJp_dec")])
    print(table(["codec", "encode", "decode"], lines))

def section_colours(rows):
    print("\n### Tiles by colour count (all content): detail vs A\n")
    bins = [(1, 16, "2-16 colours (flat UI)"), (17, 256, "17-256 (text, simple UI)"), (257, 4096, "257-4096 (rich UI, AA)"), (4097, 10**9, "> 4096 (photo, gradients)")]
    lines = []
    for lo, hi, name in bins:
        rs = [r for r in rows if lo <= int(r["colours"]) <= hi]
        if not rs: continue
        A = S(rs, "A")
        lines.append([name, len(rs), f"{A / len(rs):,.0f}", pct(S(rs, "base_haar"), A), pct(min(S(rs, "dwebp_haar"), S(rs, "dz19_haar"), S(rs, "dctx_haar"), S(rs, "dctx_sq")), A),
                      pct(S(rs, "jxl"), A), pct(S(rs, "jxlsq_full"), A)])
    print(table(["tiles", "n", "A mean B", "1x base / A", "best detail / A", "JXL-LL / A", "JXL squeeze / A"], lines))

def section_scroll(rows):
    print("\n### Scroll by dy 2x pixels, whole layers: can a 1x client follow the copy?\n")
    head = ["content", "dy", "1x samples exact from base alone", "exact from base + LH band", "fresh 1x base (WebP) / A",
            "residual vs guess (ctx) / A", "LH band (ctx) / A"]
    lines = []
    for c, rs0 in groups(rows):
        for dy in ["1", "2"]:
            rs = [r for r in rs0 if r["dy"] == dy]
            if not rs: continue
            n = S(rs, "n"); A = S(rs, "full2x")
            lines.append([c, dy, f"{100 * sum(f(r,'exact_guess') * f(r,'n') for r in rs) / n:.1f} %", f"{100 * sum(f(r,'exact_base_lh') * f(r,'n') for r in rs) / n:.1f} %",
                          pct(S(rs, "fresh_base"), A), pct(S(rs, "resid_vs_guess"), A), pct(S(rs, "lh_band"), A)])
    print(table(head, lines))

def section_scales(rows):
    print("\n### A plain (non-scalable) ladder: WebP lossless of the same screen area at 2x, 1.5x and 1x\n")
    head = ["content", "layers: 1.5x / 2x", "layers: 1x / 2x", "tiles: 1.5x / 2x", "tiles: 1x / 2x", "tiles vs whole layer at 2x"]
    lines = []
    for c, rs in groups(rows):
        if not rs: continue
        L2, T2 = S(rs, "layer2x"), S(rs, "tiles2x")
        lines.append([c, pct(S(rs, "layer15x"), L2), pct(S(rs, "layer1x"), L2), pct(S(rs, "tiles15x"), T2), pct(S(rs, "tiles1x"), T2), pct(T2, L2)])
    print(table(head, lines))

def section_lap(rows):
    print("\n### B as a Laplacian pyramid: 2x residual against the upsampled 1x base, mod 256, as a WebP lossless image (tiles)\n")
    head = ["content", "1x base / A", "residual, nearest / A", "residual, bilinear / A", "base + best residual / A"]
    lines = []
    for c, rs in groups(rows):
        if not rs: continue
        A = S(rs, "A")
        lines.append([c, pct(S(rs, "base"), A), pct(S(rs, "lap_nearest"), A), pct(S(rs, "lap_bilinear"), A),
                      pct(S(rs, "base") + min(S(rs, "lap_nearest"), S(rs, "lap_bilinear")), A)])
    print(table(head, lines))

if __name__ == "__main__":
    nt = len(tiles)
    print(f"Corpus: {len(layers)} layers, {nt} non-solid 64x64 tiles measured, {sum(int(r['colours']) for r in layers)} solid tiles skipped.")
    section_bytes(tiles, "Tiles (64x64 at 2x)", True)
    section_paths(tiles, "Tiles")
    section_colours(tiles)
    section_bytes(layers, "Layers (whole 2200x1500-class windows)", False)
    section_paths(layers, "Layers")
    section_jxl_layers(layers)
    section_layer_list(layers)
    section_times(tiles, "Tiles (64x64)")
    section_times(layers, "Layers (~3.3 MP)")
    section_scroll(scroll)
    if scales: section_scales(scales)
    if lap: section_lap(lap)
