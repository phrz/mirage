"""Assemble ../Mirage.icon (plus Mirage-1024.png and Mirage.icns) from the Sketch layer exports.
Run from this folder: uv run --with numpy --with pillow python -I make_icon.py"""
import json, shutil, os, subprocess
import numpy as np
from PIL import Image, ImageFilter

ICON = "../Mirage.icon"
os.makedirs(f"{ICON}/Assets", exist_ok=True)
for src, dst in [("01 Sky.png", "sky.png"), ("02 Sand.png", "sand.png"), ("03 Cursor.png", "cursor.png")]:
    shutil.copy(f"export/layers/{src}", f"{ICON}/Assets/{dst}")

# Mono (Clear/Tinted) variant of the sand: those modes discard colour and render the layer as frosted
# glass, which flattens the relief. Amplify luminance detail so ripples, grain and the reflection survive.
sand = Image.open("export/layers/02 Sand.png").convert("RGBA")
rgb = np.asarray(sand, np.float32) / 255.0
lum = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
alpha = rgb[..., 3]
# band-pass the luminance so the relief is the ripples (and the reflection), not the fine grain
lum8 = Image.fromarray((np.clip(lum, 0, 1) * 255).astype(np.uint8))
mid = np.asarray(lum8.filter(ImageFilter.GaussianBlur(2.2)), np.float32) / 255.0
low = np.asarray(lum8.filter(ImageFilter.GaussianBlur(9)), np.float32) / 255.0
detail = mid - low
# Mono renders each layer as its alpha shape filled with a system colour, so relief must live in alpha.
# Build a separate "relief" layer: crests opaque, troughs transparent. Hidden by default, shown in Mono.
# relief map: ripples and grain as alpha; gentler than the first cut so Mono reads as sand, not etched glass
relief = np.clip(0.5 + detail * 9.0, 0, 1)
relief_alpha = alpha * np.clip((relief - 0.5) / 0.5, 0, 1) * 0.9
white = np.ones_like(relief)
Image.fromarray((np.dstack([white, white, white, relief_alpha]) * 255).astype(np.uint8), "RGBA").save(f"{ICON}/Assets/sand-relief.png", optimize=True)
if os.path.exists(f"{ICON}/Assets/sand-mono.png"): os.remove(f"{ICON}/Assets/sand-mono.png")

# Mono renders luminance as opacity of a light tint, so the pale sand plate becomes a washed-out slab.
# Mono-only helpers restore contrast: a horizon hairline and the sand relief; the pointer keeps its outline.
HORIZON = 620
w = np.ones((1024, 1024), np.float32)
hz = np.zeros((1024, 1024), np.float32); hz[HORIZON - 1:HORIZON + 2, :] = 1.0; hz[HORIZON - 2, :] = 0.5; hz[HORIZON + 2, :] = 0.5
Image.fromarray((np.dstack([w, w, w, hz]) * 255).astype(np.uint8), "RGBA").save(f"{ICON}/Assets/horizon-line.png", optimize=True)

mono_only = [{"appearance": "tinted", "value": True}]
def mono_opacity(default, mono):
    # Icon Composer 27.1 ignores opacity-specializations in Mono but honours visibility specializations
    # for the light and dark appearances, so a Mono-only layer is: full opacity, hidden in light and dark.
    if default == 0.0:
        return {"opacity": mono, "hidden-specializations": [{"appearance": "light", "value": True}, {"appearance": "dark", "value": True}]}
    return {"opacity": default, "opacity-specializations": [{"appearance": "tinted", "value": mono}]}
# In Mono every layer is clear glass unless given a system fill for that appearance; this makes a layer solid there
mono_solid = {"fill-specializations": [{"appearance": "tinted", "value": "system-light"}]}
doc = {
  "fill": "automatic",
  "groups": [
    # Liquid Glass is off on every layer (phrz's call: it added artifacts and nothing the design needs)
    # In Mono the pointer renders as its keyline outline (phrz prefers that to a solid fill)
    {"layers": [{"image-name": "cursor.png", "name": "Cursor", "glass": False}],
     "shadow": {"kind": "neutral", "opacity": 0.5}, "specular": False, "translucency": {"enabled": True, "value": 0.2}},
    {"layers": [dict({"image-name": "horizon-line.png", "name": "Horizon Line (Mono)", "glass": False}, **mono_opacity(0.0, 0.9), **mono_solid),
                dict({"image-name": "sand-relief.png", "name": "Sand Relief (Mono)", "glass": False}, **mono_opacity(0.0, 1.0))],
     "shadow": {"kind": "neutral", "opacity": 0.0}, "specular": False, "translucency": {"enabled": False, "value": 0.0}},
    {"layers": [dict({"image-name": "sand.png", "name": "Sand", "glass": False}, **mono_opacity(1.0, 0.55))],
     "shadow": {"kind": "neutral", "opacity": 0.0}, "specular": False, "translucency": {"enabled": False, "value": 0.0}},
    {"layers": [{"image-name": "sky.png", "name": "Sky", "glass": False, "hidden-specializations": mono_only}],
     "shadow": {"kind": "neutral", "opacity": 0.0}, "specular": False, "translucency": {"enabled": False, "value": 0.0}}
  ],
  "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}
}
json.dump(doc, open(f"{ICON}/icon.json", "w"), indent=2)
# flat PNG and legacy icns next to the bundle
shutil.copy("export/layers/00 Composite.png", "../Mirage-1024.png")
shutil.rmtree("Mirage.iconset", ignore_errors=True); os.makedirs("Mirage.iconset")
for sz in (16, 32, 128, 256, 512):
    for scale, suffix in ((1, ""), (2, "@2x")):
        Image.open("../Mirage-1024.png").resize((sz * scale, sz * scale), Image.LANCZOS).save(f"Mirage.iconset/icon_{sz}x{sz}{suffix}.png")
subprocess.run(["iconutil", "-c", "icns", "Mirage.iconset", "-o", "../Mirage.icns"], check=True)
shutil.rmtree("Mirage.iconset")
print("icon.json, Mirage-1024.png, Mirage.icns ok")
