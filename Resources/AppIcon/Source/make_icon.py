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
low = np.asarray(Image.fromarray((np.clip(lum, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(7)), np.float32) / 255.0
detail = lum - low
# Mono renders each layer as its alpha shape filled with a system colour, so relief must live in alpha.
# Build a separate "relief" layer: crests opaque, troughs transparent. Hidden by default, shown in Mono.
relief = np.clip(0.5 + detail * 7.0, 0, 1)
relief_alpha = alpha * np.clip((relief - 0.42) / 0.5, 0, 1)
white = np.ones_like(relief)
Image.fromarray((np.dstack([white, white, white, relief_alpha]) * 255).astype(np.uint8), "RGBA").save(f"{ICON}/Assets/sand-relief.png", optimize=True)
if os.path.exists(f"{ICON}/Assets/sand-mono.png"): os.remove(f"{ICON}/Assets/sand-mono.png")

mono_only = [{"appearance": "tinted", "value": True}]
doc = {
  "fill": "automatic",
  "groups": [
    {"layers": [{"image-name": "cursor.png", "name": "Cursor", "glass": True}],
     "shadow": {"kind": "neutral", "opacity": 0.5}, "specular": True, "translucency": {"enabled": True, "value": 0.2}},
    {"layers": [{"image-name": "sand-relief.png", "name": "Sand Relief (Mono)", "glass": True, "hidden": True,
                 }],
     "shadow": {"kind": "neutral", "opacity": 0.35}, "specular": True, "translucency": {"enabled": True, "value": 0.25}},
    {"layers": [{"image-name": "sand.png", "name": "Sand", "glass": False}],
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
