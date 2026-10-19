#!/usr/bin/env python3
"""Markdown tables from results/*.json (byterace run --out)."""
import json, glob, os, sys

ORDER = ["typing", "terminal", "scroll", "spinner", "anim", "anim-rich", "video", "mixed"]
STRATS = ["classifier", "all-lossless", "all-video", "race", "race-fast", "race-q", "hybrid", "veto", "oracle"]
d = sys.argv[1] if len(sys.argv) > 1 else "results"

def load(scene):
    p = os.path.join(d, scene + ".json")
    if not os.path.exists(p): return None
    rep = json.load(open(p))
    for extra_name in ("race-q", "veto"):
        q = os.path.join(d, extra_name, scene + ".json")
        if not os.path.exists(q): continue
        extra = json.load(open(q))
        for la, lb in zip(rep["layers"], extra["layers"]):
            for ra, rb in zip(la["runs"], lb["runs"]):
                if extra_name in rb: ra[extra_name] = rb[extra_name]
    return rep

def rows(scene, rep):
    out = []
    for layer in rep["layers"]:
        name = f'{scene}' + (f'/{layer["name"]}' if len(rep["layers"]) > 1 else "")
        for run in layer["runs"]:
            out.append((name, layer, run))
    return out

print("### Average kbps per strategy (all layers of the sequence; lower is better)\n")
print("| sequence | video budget | " + " | ".join(STRATS) + " |")
print("|---|---|" + "---|" * len(STRATS))
for scene in ORDER:
    rep = load(scene)
    if not rep: continue
    by_kbps = {}
    for layer in rep["layers"]:
        for run in layer["runs"]:
            acc = by_kbps.setdefault(run["kbps"], {})
            for s in STRATS:
                if s in run:
                    a = acc.setdefault(s, [0, 0.0])
                    a[0] += run[s]["total"]; a[1] = max(a[1], run[s]["seconds"])
    for k, acc in sorted(by_kbps.items()):
        best = min(v[0] for v in acc.values())
        cells = []
        for s in STRATS:
            if s not in acc: cells.append("–"); continue
            b, secs = acc[s]
            v = b * 8 / 1000 / max(secs, 1e-3)
            cells.append(f"**{v:.0f}**" if b == best else f"{v:.0f}")
        print(f"| {scene} | {k} | " + " | ".join(cells) + " |")

print("\n### Text shown soft (share of time a changed text/UI tile is video-quality), switches to video, text PSNR\n")
print("| layer | budget | " + " | ".join(STRATS) + " |")
print("|---|---|" + "---|" * len(STRATS))
for scene in ORDER:
    rep = load(scene)
    if not rep: continue
    for name, layer, run in rows(scene, rep):
        cells = []
        for s in STRATS:
            r = run.get(s)
            if not r: cells.append("–"); continue
            sw = f' ·{r["toVideo"]}↗' if r["toVideo"] else ""
            ps = f' ·{r["textPSNR"]:.0f} dB' if r["textPSNR"] > 0 and r["softFraction"] > 0.005 else ""
            cells.append(f'{r["softFraction"]*100:.0f} %{sw}{ps}')
        print(f"| {name} | {run['kbps']} | " + " | ".join(cells) + " |")

print("\n### Per layer: bytes by path for the classifier and the veto policy (KB: direct lossless / refinement / copy-rect / video incl. keyframes)\n")
print("| layer | budget | frames | dirty tiles/frame | copy-rects | classifier | veto | veto: sampled lossless estimate CPU per frame |")
print("|---|---|---|---|---|---|---|---|")
for scene in ORDER:
    rep = load(scene)
    if not rep: continue
    for name, layer, run in rows(scene, rep):
        def br(r): return f'{r["direct"]/1000:.0f} / {r["refinement"]/1000:.0f} / {r["copyRect"]/1000:.0f} / {r["video"]/1000:.0f}'
        c, h = run.get("classifier"), run.get("veto")
        est = f'{h["estLosslessCPUmsPerFrame"]:.2f} ms' if h else "–"
        print(f'| {name} | {run["kbps"]} | {layer["frames"]} | {layer["dirtyTilesPerFrame"]:.1f} | {layer.get("copyRects", "?")} | {br(c) if c else "–"} | {br(h) if h else "–"} | {est} |')
